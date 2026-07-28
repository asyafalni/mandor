# Self-sufficient OTLP telemetry to photon — design

> **Status:** design, approved direction — not yet built. When implemented,
> the product-boundary wording in `CLAUDE.md` and `docs/INTEGRATION-PHOTON.md`
> changes **in the same commit as the code**, never ahead of it.

**Goal:** When `photon = "host:port"` is set, mandor delivers its full story —
incidents, process lifecycle events, per-process resource metrics, supervisor
self-metrics, and worker logs — to photon as OTLP, with **no collector in the
container**. Without the key, mandor touches no socket.

**One-line boundary (the revised non-goal):**
**mandor optionally speaks OTLP** — off by default; when `photon=` is set a
long-lived relay child (never the supervision path) pushes telemetry as OTLP
protobuf. No key, no socket.

---

## Global constraints (inherited, non-negotiable)

- **Supervision path touches no socket, ever.** All network I/O lives in a
  child process. PID 1's poll loop never blocks on or allocates for telemetry.
- **Zero steady-state allocation in the core.** Fixed buffers, preallocated.
- **Offline by default.** No `photon=` → no child spawned → no network.
- **Size budget < 500 KB stripped** (currently ~256 KB). This is the largest
  addition yet; it is staged across commits and each step respects the
  per-commit 2 KB delta gate (`[size]` bypass only with a recorded reason).
- **Simplicity: 4 CLI flags stay 4.** The whole feature turns on with the
  existing `photon=` key. Per-signal disable and interval tuning are TOML-only.
- **No new dependencies.** OTLP protobuf is hand-encoded, extending the encoder
  `relay.zig` already has.
- **ReleaseSafe, no `unreachable` / no panic on any path a running mandor
  reaches**, including the child.

---

## The architectural heart: priority by durability, not an in-memory heap

The user requirement is: *under backpressure (photon down/slow), the incident
that explains a crash must survive; a routine 5 s RSS sample may be dropped.*

The naive reading is an in-memory priority queue in the sender. We get the same
guarantee for free by using the **durability tier that already exists**:

- **Incidents are already written durably** to the self-pruning, atomic-rename
  spool dir (`/var/lib/mandor/incidents/*.json`, `spool.zig`). They survive a
  process death, a photon outage, and a crash loop.
- **Routine telemetry (metrics, log lines, lifecycle events) is ephemeral** —
  it lives only in mandor's fixed rings and is regenerated every tick.

So the priority policy is realized structurally:

| Class | Path core → child | Durability | Under backpressure |
|---|---|---|---|
| **Incident bundles** | spool dir (child watches it) | durable on disk | **retried; never dropped** |
| Lifecycle events | pipe | ephemeral | dropped after bounded buffer |
| Per-process metrics | pipe | ephemeral | dropped (newest wins) |
| Worker logs | pipe | ephemeral | dropped (newest wins) |

The child ships the **spool first** every cycle, then whatever routine
telemetry fits. No priority heap, no comparator, no extra allocation — the
"queue" is the filesystem for the high class and a fixed ring for the low
class. This is the smallest design that satisfies the requirement, and it
reuses the spool that the premium sidecar already watches.

---

## Components

```
mandor core (PID 1, poll loop)                 mandor relay child (long-lived)
├── sampler   ──┐                               ├── watches spool dir ──▶ incidents
├── capture   ──┼─ framed records ─▶ pipe ─────▶├── reads pipe ──▶ routine ring
├── detector  ──┤   (non-blocking write)        ├── batches + OTLP-encodes
└── lifecycle ──┘                               ├── POST /v1/logs, /v1/metrics
   writes incidents ─────────▶ spool dir ◀──────┘   (bearer PHOTON_TOKEN, DNS,
                                                      10 s socket timeouts)
```

### Consolidation: the child replaces per-incident re-exec

Today `incident.firePhoton` re-execs `/proc/self/exe relay <file>`
**once per incident** (fire-and-forget, tracked in `forward_pids[16]`). A crash
loop spawns one relay process per crash. The new design **subsumes** that: one
long-lived `mandor relay` child is spawned when `photon=` is set, watches the
spool, and ships incidents itself. Benefits:

- crash loops no longer spawn N processes — bounded to one child;
- one persistent connection amortizes DNS + TCP setup;
- the same child carries routine telemetry.

`firePhoton`, `noteForward`, `reapForwards`, and the per-incident spawn are
removed; `drainForwards` becomes `drainTelemetry` (flush-and-exit signal to the
one child, same bounded-budget shape).

### Core → child IPC (the pipe)

- One `pipe2(O_NONBLOCK | O_CLOEXEC)`; child inherits the read end.
- Core writes **fixed-header framed records**: `[u8 kind][u16 len][payload]`.
  `kind ∈ {metric_sample, log_line, lifecycle_event}`. Payload is mandor's own
  compact internal form, **not** OTLP — OTLP encoding happens in the child so
  the core carries no protobuf cost.
- **The core write is non-blocking and never retried.** If the pipe is full
  (child stalled because photon is down), `write` returns `EAGAIN` and the core
  **drops the record and moves on**. This is the routine-class drop, and it is
  correct: the supervision loop must never block on telemetry. Incidents are
  unaffected — they are on the spool, not the pipe.
- No allocation: records are built in a per-record stack buffer and written in
  one syscall.

### Child internals

- Bounded routine ring (fixed KB, sized from measurement, e.g. 64 KB) holding
  framed records read from the pipe. Drop-oldest within the ring.
- Flush trigger: on a timer (default 1 s) **and** on ring-high-water.
- Each flush cycle: (1) scan spool, ship any new incident bundles (durable,
  priority); (2) drain routine ring, batch by signal, OTLP-encode, POST.
- Reuses `relay.zig`: `resolve.resolve` (DNS/hosts), the protobuf `Writer` and
  `buildOtlp` logs encoder, `statusOk`, socket timeouts, `PHOTON_TOKEN` bearer.
- **New encoder: OTLP metrics** (`buildOtlpMetrics`) — Gauge + Sum data points.
  ~150 lines, same varint/delimited machinery as logs.

---

## Signals & OTLP mappings

### 1. Incidents (already shipping) — OTLP logs `/v1/logs`

Unchanged wire shape (schema v7 bundle → LogRecord, `service.name` via resource
attrs, `mandor.bundle` attr). Only the *transport* changes: shipped by the
long-lived child from the spool instead of a per-incident re-exec.

### 2. Process lifecycle events — OTLP logs `/v1/logs`

The discrete facts only mandor knows. One LogRecord each:

| Event | body | severity | key attrs |
|---|---|---|---|
| started | `worker <name> started` | INFO | `process.pid`, `process.command` |
| exited | `worker <name> exited <cause>` | INFO / ERROR | `exit.code` or `exit.signal` |
| restarting | `worker <name> restarting (backoff <ms>)` | WARN | `restart.count`, `backoff.ms` |
| oom | `worker <name> OOM-killed` | ERROR | `process.pid` |
| health | `worker <name> <up\|down>` | INFO / WARN | `health.state` |

`service.name` = worker name. Low volume (events, not streams); a restart storm
is bounded by the detector threshold. Reuses the logs encoder verbatim.

### 3. Per-process resource metrics — OTLP metrics `/v1/metrics`

Straight from `sampler.zig`, one datapoint set per worker per tick (default 5 s):

| metric | type | unit |
|---|---|---|
| `mandor.process.rss` | Gauge | By (bytes) |
| `mandor.process.cpu` | Gauge | 1 (percent) |
| `mandor.process.fds` | Gauge | 1 |
| `mandor.process.threads` | Gauge | 1 |
| `mandor.process.restarts` | Sum (monotonic, cumulative) | 1 |

Resource attr `service.name` = worker name. **This is complementary, not
duplicative, of `photon-agent`** — the agent knows *host* CPU/RAM; only mandor
can attribute resources *per supervised worker*.

### 4. Supervisor self-metrics — OTLP metrics `/v1/metrics`

`mandor.supervisor.rss`, `mandor.supervisor.uptime`,
`mandor.supervisor.workers`, `mandor.incidents.total`. Trivial once the metrics
encoder exists.

### 5. Worker log stream — OTLP logs `/v1/logs`

Every captured line (`capture.zig` ring, already timestamped and `[name]`-
tagged) → LogRecord. `service.name` derived from the `[name]` prefix,
`time_unix_nano` from the capture timestamp. **Highest volume**, so it is the
signal most exposed to routine-class drop under backpressure — acceptable by
design (logs are best-effort; incidents are durable).

### Rejected — traces / APM

A span per worker run is technically possible but **rejected**: meaningful app
traces require instrumentation *inside the workers*, which mandor cannot and
should not inject. Off-mission.

---

## Backpressure & failure behavior (the honest performance story)

Wire format (OTLP vs remote_write) is a wash at this volume; **the sender
architecture is what matters**:

- **Core never blocks:** non-blocking pipe write, drop on `EAGAIN`.
- **Child memory is bounded:** fixed routine ring, drop-oldest; no unbounded
  queue, no growth when photon is down.
- **Incidents are never dropped:** they sit durably on the spool and are retried
  next cycle; a photon outage delays them, never loses them.
- **Every socket call times out (10 s)** — a stalled photon cannot strand the
  child.
- **Child death is non-fatal:** if the child dies, the core respawns it with
  bounded backoff. Telemetry is best-effort by contract; supervision continues
  regardless. The core never depends on the child for correctness.
- **Shutdown:** on mandor exit, core signals the child to flush and drain within
  a bounded budget (reuses the `drainForwards` pattern), then exits. Unshipped
  incidents remain durable on the spool.

---

## Config surface (simplicity preserved)

- **CLI unchanged** — 4 flags. `photon=` (existing) turns the whole thing on.
- **Default when `photon=` set:** send *all* signals (incidents + lifecycle +
  metrics + self-metrics + logs). One key, full story.
- **TOML-only advanced keys** (documented in `docs/CONFIG.md`):
  - `telemetry.logs = false` — disable worker-log forwarding (the loudest one)
  - `telemetry.metrics = false` — disable metrics
  - `telemetry.interval = "1s"` — routine flush interval
  - `telemetry.ring = "64KiB"` — child routine buffer size
- `PHOTON_TOKEN` bearer auth and hostname resolution: unchanged, already exist.

---

## Size budget & staging

Largest addition to date. Staged so each commit is reviewable and gate-legal:

1. **Long-lived child + pipe IPC + spool watch** — replaces per-incident
   re-exec, ships incidents from the child. *Net size ~neutral* (removes
   per-incident spawn code, adds the loop).
2. **Lifecycle events over the pipe** → logs. Reuses logs encoder. Small.
3. **OTLP metrics encoder** (`buildOtlpMetrics`) + per-process & self-metrics.
   Largest single step (~150 lines); likely needs a `[size]` commit with a
   recorded reason.
4. **Worker log forwarding** + TOML disable knobs. Small.

Target ceiling after all four: **well under 300 KB**; hard gate 500 KB.

---

## Testing

- **Unit:** metrics protobuf decoded by an independent reader (mirror the
  existing logs unit test); framed-record encode/decode; ring drop-oldest;
  priority ordering (spool shipped before routine ring).
- **Backpressure (the bug-prone part):** child with a black-hole/stalled photon
  — assert core never blocks, routine records drop, **incident bundles still
  present on spool and shipped on recovery**. No fixed-sleep races — poll for
  state (this project has been bitten by fixed sleeps ≥4 times).
- **Mutation checks:** break the "ship spool before routine" ordering → a named
  test must fail; break non-blocking write (make it block) → a hang-detection
  test must fail.
- **e2e (`test/photon/e2e.sh`, extend):** real crash + real metrics + real logs
  through the live child to a containerized photon; assert `/api/search` shows
  the incident, `/api/storage` shows metric rows, logs queryable.

---

## Non-goals

- mandor does not scrape anything (it is a producer).
- No traces/APM (needs worker instrumentation).
- No native OTLP on the **supervision path** — only in the child.
- No config beyond the one key for the common case.

---

## Open questions for review

1. **Flush interval default** — 1 s routine flush vs aligning to the 5 s sampler
   tick. Leaning 1 s for logs/events responsiveness, metrics naturally at 5 s.
2. **Worker logs default on or off?** Self-sufficient argues *on*; the volume
   and drop exposure argue a conservative *off*-by-default with `telemetry.logs
   = true` to enable. Recommend **on** (matches "full story, one key") but flag
   it as the one place a user might be surprised by egress volume.
3. **Spool retention vs photon** — after the child ships an incident, does it
   mark/prune, or leave it for the premium sidecar too? Recommend: leave the
   spool's existing self-pruning untouched; the child tracks a shipped-watermark
   in memory so it does not re-ship within a run.
