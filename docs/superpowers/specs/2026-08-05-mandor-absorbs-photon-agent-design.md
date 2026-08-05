# mandor absorbs photon-agent — node & GPU host metrics

> Design doc. Branch: `feat/absorb-photon-agent`. Companion to the existing
> photon integration (`docs/INTEGRATION-PHOTON.md`) and the self-sufficient OTLP
> telemetry work (v1.7.x).

## Goal

Make a single static mandor binary fully supersede **photon-agent** (photon's
standalone per-host resource-metrics daemon), so a node no longer needs a
separate agent. Wire fidelity is exact — identical OTLP metric names, units,
types, and attributes — so photon's existing Infrastructure/Hosts views light up
with **zero photon-side changes**.

Crucially, the absorbed **node/host** resource role must merge *coherently* with
mandor's existing **per-worker (per-process)** fine-grained metrics: photon must
show each supervised process's resource usage AND the node it runs on, under one
host, so an operator can read a process against the node's totals.

Separately, P3 adds an **opt-in** capability for operators who want more than the
curated view: streaming full worker logs to photon as OTLP logs. It is default-off
and independent of the host-metric work — mandor still curates by default.

## Background

**photon-agent** (photon repo, `crates/photon-agent/`) is a standalone glibc
binary, one per host, sampling every 15s and POSTing OTLP to `/v1/metrics` with a
bearer token. It emits `system.*` host metrics (CPU/mem/filesystem/network/load)
and NVIDIA `system.gpu.*` via NVML (`dlopen`). It has **no** process metrics, no
spool/retry, and no host registration (a host "exists" once its
`system.cpu.utilization` points arrive).

**mandor already** (v1.7.1–v1.7.2) emits, from `hostmetrics.zig` +
`relay.buildOtlpHostMetrics`, the node as a host — `system.cpu.utilization`
(total), `system.cpu.logical.count`, `system.cpu.load_average.1m`,
`system.memory.{limit,usage,utilization}`, `system.filesystem.{usage,utilization}`
(root `/` only), `system.network.io` (aggregated), plus resource attrs
`host.name`/`host.id`/`os.type`. mandor **also** emits per-worker `process.*`
metrics (semconv names, carrying `host.name` since v1.7.1) that feed photon's
per-host **Processes** table (a mandor-built feature, upstream since photon
v1.5.0). So mandor is ~70% of photon-agent already, plus the process metrics
photon-agent never had.

## Non-goals

- **Deleting photon-agent** from the photon repo — the upstream developer does
  that once mandor's coverage is verified. No photon-repo changes in this work.
- **NVML / `dlopen`** — mandor is a static, libc-free binary; it cannot `dlopen`.
  GPU is collected by shelling out to `nvidia-smi` (decided) / reading DRM sysfs.
- **Cgroup-limit-scoped host metrics** — like photon-agent, host metrics are
  node-scoped (read from `/proc`); they describe the node, not a cgroup slice.
- **Per-node process enumeration** — mandor reports the processes it supervises,
  not every process on the host (photon-agent reported none).

## Architecture

Node telemetry (host + GPU) consolidates into the long-lived
`mandor relay --daemon` child, which already owns the socket, the spool, and the
telemetry pipe. This keeps every subprocess and `/proc` sweep **off PID-1's
supervision path**, and avoids bloating the supervisor→daemon pipe frame with
per-core/per-mount/per-interface arrays.

```
supervisor (PID 1)                     relay --daemon (child)
  per-worker sampler ── process.* ──▶ pipe ─▶ OTLP  (unchanged)
                                        │
                                        ├─ node timer (5s): hostmetrics.Sampler
                                        │    reads /proc + statfs  → system.*
                                        └─ gpu  timer (15s): nvidia-smi / DRM sysfs
                                             → system.gpu.*
  (host.name / host.id resolved ONCE in the daemon, applied to every resource)
```

- **`hostmetrics.zig` (extend)** — the node `/proc`+`statfs` readers, moved to run
  in the daemon on a node timer (today they run in the supervisor and cross the
  pipe as `frame.Host`; this work removes the node metrics from the frame path and
  samples them daemon-side). New granularity, all pure parsers, saturating,
  zero-alloc, unit-testable with fixture strings:
  - **per-core CPU** util (`/proc/stat` `cpuN` lines, per-core deltas) → `cpu=<n>`
  - **per-mount filesystem** (`/proc/self/mountinfo` → `statfs` each) → `mountpoint`
  - **per-interface network** (`/proc/net/dev`, no longer summed) → `device`
  - memory `state="free"` point
- **`gpu.zig` (new)** — daemon-side, own interval (default 15s), OFF by default,
  **silent** when `nvidia-smi` is absent or errors (fail-closed, never affects
  supervision or other telemetry). Phase 1 = NVIDIA via `nvidia-smi`; Phase 2 adds
  AMD/Intel via DRM sysfs into the same encoder.
- **`relay.zig` (extend)** — `buildOtlpHostMetrics` gains the per-core/per-mount/
  per-interface series; a new `buildOtlpGpuMetrics` for `system.gpu.*`. Same
  `host.name`/`host.id` resource attrs as the process-metrics encoder.
- **config** — a small TOML section (GPU on/off + interval); respects the 4-flag
  CLI rule (TOML-only) and needs a config-surface budget bump.
- **docs** — `docs/CONFIG.md` + a "node-monitor deployment" note (host mounts).

## Integration: one coherent per-process + node view

This is the point of the merge. All three metric families carry the **same**
resource identity so photon groups them under one host:

- `process.*` (per worker) — resource attrs `service.name` (worker) **+
  `host.name`** (added v1.7.1).
- `system.*` (node) — `host.name`/`host.id`/`os.type`.
- `system.gpu.*` (node GPU) — same `host.name`/`host.id`/`os.type`.

Requirement: `host.name` and `host.id` are resolved **once** (in the daemon) and
applied identically to the process, host, and GPU encoders — never derived twice
with a risk of divergence. Result in photon, with no photon changes:

- **Hosts view** — the node appears with cpuUtil/memUtil/diskUtil/gpuUtil/hasGpu.
- **Host detail → panels** — CPU (per-core), memory, disk (per-mount), network
  (per-interface), GPU (util/mem/temp/power), load.
- **Host detail → Processes table** — each supervised worker's
  cpu/rss/fds/threads/restarts, i.e. *fine-grained per-process usage against the
  node's totals* — exactly the "which process is heaviest on this node" story.

A verification gate (below) asserts a single live run shows both the host panels
AND the Processes table populated under the same host.

## Metric contract

### Phase 1 — full photon-agent parity (all map to existing photon panels)

| Metric | Type | Unit | Attributes | Status |
|---|---|---|---|---|
| `system.cpu.utilization` | Gauge | `1` | `cpu="total"` | have |
| `system.cpu.utilization` | Gauge | `1` | `cpu=<n>` (per core) | **new** |
| `system.cpu.logical.count` | Gauge | `{cpu}` | — | have |
| `system.cpu.load_average.1m` | Gauge | `1` | — | have |
| `system.memory.limit` | Gauge | `By` | — | have |
| `system.memory.usage` | Gauge | `By` | `state="used"` | have |
| `system.memory.usage` | Gauge | `By` | `state="free"` | **new** |
| `system.memory.utilization` | Gauge | `1` | — | have |
| `system.filesystem.usage` | Gauge | `By` | `mountpoint=<mp>`,`state="used"` | **per-mount** |
| `system.filesystem.utilization` | Gauge | `1` | `mountpoint=<mp>` | **per-mount** |
| `system.network.io` | Sum (mono, cumulative) | `By` | `device=<if>`,`direction=receive\|transmit` | **per-iface** |
| `system.gpu.utilization` | Gauge | `1` | `gpu=<i>`,`gpu.name=<n>` | **new (nvidia-smi)** |
| `system.gpu.memory.usage` | Gauge | `By` | `gpu=<i>`,`gpu.name=<n>` | **new** |
| `system.gpu.memory.utilization` | Gauge | `1` | `gpu=<i>`,`gpu.name=<n>` | **new** |
| `system.gpu.temperature` | Gauge | `Cel` | `gpu=<i>`,`gpu.name=<n>` | **new** |
| `system.gpu.power` | Gauge | `W` | `gpu=<i>`,`gpu.name=<n>` | **new** |

After Phase 1, photon-agent is fully replaceable — every metric above already has
a photon panel/query (Hosts enumeration, host detail, timeseries resources
`cpu/memory/disk/network/gpu/gpu_memory/gpu_temp/gpu_power/load`).

### Phase 2 — extras (superset of photon-agent)

| Metric | Type | Unit | Attributes | photon UI today |
|---|---|---|---|---|
| `system.gpu.*` (AMD/Intel via DRM sysfs) | as above | — | `gpu`,`gpu.name` | **reuses GPU panels** ✓ |
| `system.disk.io` | Sum (mono) | `By` | `device`,`direction=read\|write` | needs a panel (upstream) |
| `system.paging.usage` (swap) | Gauge | `By` | `state=used\|free` | needs a panel |
| `system.cpu.load_average.5m` / `.15m` | Gauge | `1` | — | load panel is 1m only |
| CPU temperature (hwmon) | Gauge | `Cel` | `sensor` (name TBD) | needs a panel |
| host uptime / boot-time | Gauge | `s` | — | needs a panel |

**Note:** Phase-2 AMD/Intel GPU needs **no** photon change (same `system.gpu.*`
names → existing panels). The other Phase-2 metrics are ingested and queryable
but their UI panels are the upstream developer's call; the DATA lands regardless.

## GPU collection (nvidia-smi)

Daemon-side, own interval (default 15s). Invocation:

```
nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,\
temperature.gpu,power.draw --format=csv,noheader,nounits
```

Parse each CSV line (line-oriented `std.mem` scanning, no regex), one GPU per row:
`utilization.gpu`→`/100` (fraction), `memory.used`/`memory.total` (MiB→bytes,
plus utilization), `temperature.gpu` (Cel), `power.draw` (W). Fork/exec `nvidia-smi`
the same way mandor forks any child; a bounded read of stdout; a short timeout;
non-zero exit or absent binary → emit no GPU points and log once (fail-closed).
Never blocks or affects the supervision path (runs in the daemon on its timer).

Bounded: `max_gpus` (e.g. 16). GPU names cached per index.

## Config surface

TOML-only (advanced), e.g.:

```toml
[gpu]
enabled = true          # default false; when true, daemon shells out to nvidia-smi
interval = "15s"        # GPU sample cadence (default 15s)
```

Adds the `[gpu]` keys here plus the `[logs]` streaming key(s) in P3 (~3–4
documented keys total across the phases) → config-surface gate budget bump per
phase (currently 35/36), each with CHANGELOG justification (same discipline as
the secret-store keys). Keep the 4-flag CLI rule intact — all TOML-only.

## Deployment — node-monitor model

To be a true photon-agent replacement, mandor is deployed once per host with the
host's `/proc`, `/sys`, `/etc/machine-id` mounted in (and `/dev/nvidia*` +
`nvidia-smi` for GPU) — node-exporter style. Documented in CONFIG.md. Without
those mounts mandor reports container-scoped numbers (unchanged behavior). This
is additive: the same binary still supervises workers; a plain sidecar deployment
without host mounts simply reports its container's view.

## Optional full log streaming (P3)

mandor's default is unchanged: it **curates** — worker log content reaches photon
only inside incident bundles (the `logs_tail` summary + error dedup), never as a
firehose. P3 adds an **opt-in** mode that streams every captured worker line to
photon as OTLP logs, for operators who explicitly want full logs there. This is a
deliberate, bounded softening of the 2026-07-28 "curate, don't stream" decision:
**curate by default, stream only on explicit opt-in.**

**Opt-in, default off — even when `photon=` is set.** `photon=` alone still ships
only incidents + metrics + lifecycle (curated). Full logs require a second,
separate key, so a normal deployment never accidentally turns into a log firehose,
and the offline-by-default guarantee (no `photon=` ⇒ no network at all) is intact.

**Path (best-effort, never blocks PID-1).** Capture already assembles worker
stdout/stderr into per-worker ring buffers. When streaming is on, each completed
line is also enqueued to the relay daemon over the telemetry pipe as a new log
frame (worker index, stream, severity flag, timestamp, bytes). The daemon batches
them (flush every N records or T ms) into one OTLP `/v1/logs` POST. This rides the
existing **ephemeral** telemetry tier: the pipe write is non-blocking and the
daemon buffer is bounded — under backpressure (photon down/slow, or a log storm)
lines are **dropped with a counter**, never spooled and never allowed to stall
capture or supervision. Incidents remain the durable tier (spool + retry);
streamed logs are explicitly lossy, matching their volume.

**OTLP mapping (photon `/v1/logs`, already the incident-bundle sink).** Resource:
`service.name=<worker>` + `host.name`/`host.id` — the SAME identity as this
worker's `process.*` metrics, so in photon a worker's logs, its process metrics,
and the node line up under one service/host. Log record: `time_unix_nano`, `body`
= the line text, `severity_number`/`severity_text` from mandor's existing
error/warn line flagging (else INFO), attributes `log.iostream=stdout|stderr`.
Reuses the OTLP-logs encoder already built for incident bundles.

**Guards specific to the firehose:**
- Off by default; requires both `photon=` and the streaming key.
- Optional rate cap (lines/sec) and/or line-length cap so one chatty worker can't
  saturate the daemon or photon; over-cap lines dropped with the same counter.
- Zero effect on the curated path: incidents, metrics, and lifecycle are
  unchanged whether streaming is on or off.
- Never spooled to disk (that tier is for incidents only) — a down photon means
  streamed logs are lost for that window, by design.

**Config (TOML-only):**
```toml
[logs]
stream = true           # default false; opt-in full worker-log streaming to photon
# max_rate = "2000/s"   # optional: drop beyond this to protect mandor + photon
```

**Non-goals for P3:** no on-disk log spooling/retention beyond the existing ring
buffers; no log parsing/indexing (photon does that); no PII redaction (operator's
responsibility — flagged in docs, same as the incident env-snapshot caveat).

## Constraints / guardrails

- **Static musl, libc-free** — GPU is a subprocess, never `dlopen`. Everything
  else is raw `/proc`/`sysfs` reads.
- **`< 500 KB`** stripped size gate; **config-surface** gate; **no panic / no
  `unreachable`** on any path; every `/proc` byte **saturating**; **zero-alloc**
  sampling (fixed buffers).
- GPU subprocess + `/proc` sweeps run **only in the daemon**, on their own timers
  — PID-1's supervision loop is untouched.
- Bounded caps for per-core/per-mount/per-interface/per-GPU lists; overflow
  truncates with a log, never overruns.

## Phasing

1. **P1 — parity + NVIDIA GPU.** per-core CPU, per-mount FS, per-interface net,
   mem free, `system.gpu.*` via nvidia-smi; move node sampling into the daemon;
   unified `host.name`/`host.id` across process + host + GPU. Verify live vs
   photon v1.5.0 (Hosts view + all panels + Processes table under one host).
   → photon-agent is now fully replaceable.
2. **P2 — extras.** AMD/Intel GPU (DRM sysfs), `system.disk.io`, swap, CPU temp,
   uptime, 5m/15m load. mandor becomes a superset.
3. **P3 — optional full log streaming (opt-in).** Stream every captured worker
   stdout/stderr line to photon as OTLP logs, for operators who want the full
   firehose (see "Optional full log streaming" below). Independent of P1/P2 and
   the largest departure from mandor's defaults — kept strictly opt-in.

## Testing

- **Unit** — fixture-string parsers for each new source: `/proc/self/mountinfo`,
  per-core `/proc/stat`, per-interface `/proc/net/dev`, `nvidia-smi` CSV,
  `/proc/diskstats`, DRM sysfs, hwmon. Saturating-overflow cases. GPU CSV parser
  tested without invoking `nvidia-smi`.
- **Mutation** — e.g. break the per-mount `statfs` loop or the CSV field order and
  confirm a named test fails.
- **OTLP round-trip** — extend the fuzz `relayTarget`/`protoWalk` so the new
  encoders' output stays a decodable protobuf (as the secret/host work did).
- **Live** — one mandor run against photon v1.5.0 (as in the v1.5.0 verification):
  assert `/api/infra/hosts` shows the node with `hasGpu`/`gpuUtil` (on a GPU box),
  per-mount `diskUtil`, per-core `cpu` series, per-interface `network`, AND
  `/api/infra/hosts/:host/processes` populated with the workers — proving the
  per-process + node views are coherent under one host.
- **Size / harness** — size gate; harness unaffected (host/GPU are daemon-side).
- **P3 log streaming** — unit-test the log-frame encode/decode + severity mapping
  + OTLP `/v1/logs` record shape (protoWalk). A harness case: with `[logs] stream`
  on, a worker's lines land in photon `/api/search` under its `service.name`; with
  it off (default), only incident-bundle logs appear (no firehose). A backpressure
  test: a log storm against a dead endpoint drops lines (counter increments) and
  never stalls capture or raises mandor's RSS (soak-style).

## Open questions

- CPU-temperature and uptime metric **names** (no OTel semconv) — pick a mandor
  extension name in P2; they won't render in photon until upstream adds panels.
- `nvidia-smi` cadence default (15s proposed) and whether to expose it per the
  simplicity budget.
- Whether moving node sampling from supervisor→daemon should be its own
  preparatory commit (recommended: yes, isolate the move from the new metrics).
