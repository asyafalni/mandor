# CLAUDE.md — mandor

> mandor — the foreman for your containers. A tiny PID-1 process supervisor
> (multirun-class size) that captures logs, tracks resource stats, summarizes
> incidents locally, and — in the paid tier — hands incidents to an AI agent
> that can fix the code and open a PR.

## What this is

- **Language: Zig** (pin to one release, see "Zig discipline" below)
- **Target: single static binary, < 500KB stripped**, runs as PID 1 on
  Docker/Podman (`scratch`/distroless friendly), x86_64 + aarch64 musl-free
  static via Zig cross-compilation.
- **Free tier (this binary):** multirun parity + log capture + perf stats +
  heuristic incident summaries. **Offline by default (see the OTLP note below),
  no account, no LLM.**
- **Premium (separate sidecar binary, later):** ships incident bundles to a
  relay → AI root-cause analysis → optional repo access → auto-fix PR.
- **mandor OPTIONALLY speaks OTLP.** Off by default: with no `photon` configured
  (neither the `photon=` TOML key nor the `PHOTON_OTLP_HTTP_ENDPOINT` env var) the
  binary opens no socket, spawns no child, and phones nowhere — the
  offline-by-default guarantee is unchanged. When `photon` IS set (either source),
  mandor ships incidents, per-process/supervisor metrics, and process-lifecycle
  events to photon as OTLP. All network I/O lives in a single long-lived
  `mandor relay --daemon` child (it owns the socket, watches the spool, drains a
  non-blocking pipe); **the supervision path itself never touches a socket.**
  The other network toggle is the local metrics endpoint (`--metrics`). No
  config, no network.

## Architecture

```
mandor (PID 1, this repo)
├── spawner        fork/exec workers from CLI args or mandor.toml
├── reaper         waitpid loop, zombie reaping, exit-cause classification
├── signals        signalfd: forward TERM/INT/HUP to workers, graceful shutdown
├── capture        per-worker stdout/stderr pipes → ring buffers (default 256KB)
├── sampler        /proc/<pid>/{stat,status} poll (default 5s): CPU%, RSS, fds, threads
├── detector       incident triggers: nonzero exit, fatal signal, cgroup OOM,
│                  restart-loop (N in M min), monotonic RSS climb, PSI stall
├── summarize      heuristic engine (NO LLM): error dedup by signature,
│                  trace parsing, pattern verdicts ("restart loop", "leak suspect")
├── report         `mandor report` → human text or --json (+ --incidents, --cost)
├── secret         per-session app secrets (CSPRNG) handed to workers over pipe fds;
│                  granted by name against the ACTIVE worker set (CLI --, else TOML
│                  workers=), delivered to the present subset, inert if none present
├── spool          incident bundles written to /var/lib/mandor/incidents/*.json
│                  (premium sidecar watches this dir — clean tier boundary)
└── telemetry      OPT-IN, only when `photon=` set — else this whole path is dead:
    ├── telemetry  supervisor-side emit: non-blocking pipe (frame.zig wire format)
    ├── relay      the `mandor relay --daemon` child: owns the socket, OTLP
    │              encoders, watches the spool, drains the pipe, retries incidents
    ├── hostmetrics node /proc + statfs sampling (daemon-side, node-monitor mode)
    └── gpu         NVIDIA (nvidia-smi shell-out) + AMD/Intel (DRM sysfs), auto-detected
```

### Incident bundle schema (stable contract — sidecar + AI depend on it)

> Illustrative shape below. The **live schema is v7** (structured `cause`
> object, first-class `exception.type`/`message`, structured trace frames,
> release-correlation `history`) — the authority is `src/spool.zig` and the
> golden fixtures; every change bumps `"v"`. See docs/INTEGRATION-PHOTON.md for
> the current field-by-field OTLP mapping.

```json
{
  "v": 1,
  "ts": "2026-07-17T22:47:03Z",
  "process": {"name": "api", "cmd": "./api --port 8080", "pid": 42, "restarts": 3},
  "cause": "signal:SIGSEGV | exit:1 | oom | restart-loop | leak-suspect",
  "trace": {"lang": "go|rust|python|unknown", "frames": [], "raw": "..."},
  "logs_tail": ["last ~200 lines, error/warn lines flagged"],
  "stats_timeline": [{"t": "-60s", "rss_mb": 812, "cpu_pct": 97}],
  "verdict": "heuristic one-liner, e.g. 'RSS grew 40MB/min for 12min before OOM kill'"
}
```

## Build order (historical — v0.1–v0.4 and the telemetry milestones all SHIPPED)

The original milestones below are **all done** (the 1.x line is stable; see
docs/ROADMAP.md for the shipped ledger). Kept as a record of the intended order,
not future work. Note the restart model in v0.1 evolved: `--restart=…` was
replaced by the single `max_restarts` knob in v1.3 (`0` = don't retry, `-1` =
forever). New work follows the same discipline — compile early, size-gate, ship.

1. **v0.1 — multirun parity.** ✅ Spawn N workers from argv, forward signals,
   reap zombies, exit when all workers exit (propagate worst exit code).
   Restart policy + exponential backoff.
2. **v0.2 — capture + stats.** ✅ Pipe stdout/stderr through ring buffers
   (prefix lines `[name]` like multirun), /proc sampler, `mandor report`.
3. **v0.3 — detector + summarize.** ✅ Incident triggers, error dedup by
   signature, spool dir writer. Trace parsers now: Go, Rust, Python, Node, JVM,
   Zig (C++ still deferred — needs symbolization).
4. **v0.4 — polish.** ✅ cgroup v2 OOM detection, optional Prometheus text
   endpoint (hand-rolled, one route), mandor.toml config (CLI-only must
   always work — zero-config is a feature).
5. **Telemetry milestones (post-1.0, all SHIPPED).** ✅ OPT-IN
   OTLP telemetry via the `mandor relay --daemon` child (incidents, per-process
   + supervisor metrics, node/host metrics, auto-detected GPU metrics, lifecycle
   events); ✅ log-signal v2 (v1.11.0) — a curated warn/error **digest**
   (default-on when `photon=`, dedup-by-signature, flood-proof, `[logs] digest`),
   **per-worker** full streaming (`[worker.NAME] stream`, replacing the old global
   toggle) with automatic backpressure shedding, and `service_prefix` for
   multi-tenant photon; ✅ app-shared secret store (`[secret.NAME]`).
   Offline-by-default is unchanged — none of this activates without `photon=`.
   Since then: ✅ v1.12.0 — the four deploy-varying keys read from ENV
   (`PHOTON_OTLP_HTTP_ENDPOINT`, `PHOTON_OTLP_TOKEN`, `MANDOR_SERVICE_PREFIX`,
   `MANDOR_STATE_DIR`; ENV overrides TOML) and GPU became auto-detected; ✅
   v1.13.0 — the TOML is a name-keyed behavior overlay over the CLI-chosen worker
   set (orphan sections tolerated, secrets degrade to the present subset).
6. **v1.x — premium sidecar** (separate repo/binary, possibly Rust for rustls):
   watches spool dir, POSTs to relay, license check. NOT in this binary.

## Zig discipline (critical — read before writing code)

- **Pin the Zig version in `.zigversion` and build.zig.zon; develop against
  that exact release.** Zig is pre-1.0: std APIs churn between releases.
- **LLM caution (yes, you, Claude):** your Zig knowledge may be stale for the
  pinned release. When touching `std.posix`, `std.process`, `std.io`, or
  allocator APIs, verify signatures against the LOCAL installed std source
  (`zig env` → std_dir) instead of assuming. Compile early, compile often —
  `zig build` after every module, not after every feature.
- Allocators: single `GeneralPurposeAllocator` in debug, `page_allocator` or
  fixed buffers in release. Every alloc has a `defer`/`errdefer` free at the
  call site. Ring buffers are fixed-size preallocated — the steady state of
  PID 1 must be **zero allocations**.
- No `unreachable` and no panics on the supervision path. Every syscall error
  is handled; worst case = log to stderr and keep supervising. PID 1 dying
  kills the container — reliability beats elegance everywhere.
- Signal handling via `signalfd` + poll loop, NOT async signal handlers.
  Single-threaded event loop for supervision; one extra thread only if the
  sampler needs it (prefer integrating into the poll loop with timeouts).
- No external dependencies in the core. Trace "parsing" is line-oriented
  scanning (`std.mem` functions), not regex. If a regex ever feels needed,
  the parser design is wrong.
- ReleaseSafe (not ReleaseFast) for shipped binaries — keep safety checks;
  the size cost is small. Strip + `-Doptimize=ReleaseSafe`.

## Commands

```bash
zig build                                  # debug build
zig build -Doptimize=ReleaseSafe           # release
zig build test                             # unit tests
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe    # container target
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe   # arm64
ls -la zig-out/bin/mandor && strip zig-out/bin/mandor && ls -la  # size check — budget 500KB
```

Usage target (v0.1, multirun-compatible feel):

```bash
mandor "./api --port 8080" "./worker" "./cron-loop"
mandor --max-restarts=3 -- "./api" "./worker"   # retry a failed worker 3x, then exit
mandor report            # human summary     mandor report --json
# (backoff_max, restart policy, etc. are mandor.toml keys — the CLI is 4 flags)
```

Dockerfile consumption:

```dockerfile
COPY --from=ghcr.io/OWNER/mandor:latest /mandor /mandor
ENTRYPOINT ["/mandor", "./api", "./worker"]
```

## Testing

- Unit: trace parsers (fixture files with real Go/Rust/Python crash output
  in `test/fixtures/`), ring buffer, backoff math, signature dedup.
- Integration: `test/harness/` tiny crasher programs (exit-code, segfault,
  mem-hog, log-spammer) + shell scripts asserting supervisor behavior.
  Run inside a container in CI (GitHub Actions) — signal/PID-1 semantics
  differ outside containers.
- Every incident-bundle change bumps `"v"` and gets a fixture test.

## Repo layout

```
mandor/
├── CLAUDE.md  build.zig  build.zig.zon  .zigversion
├── src/
│   ├── main.zig  cli.zig  config.zig  supervisor.zig
│   ├── spawner.zig  reaper.zig  signals.zig  backoff.zig  names.zig
│   ├── capture.zig  ring.zig  sampler.zig  detector.zig  cgroup.zig
│   ├── summarize.zig  incident.zig  spool.zig  history.zig
│   ├── report.zig  cost.zig  metrics.zig  elf.zig  caps.zig  secret.zig
│   ├── telemetry.zig  relay.zig  frame.zig  hostmetrics.zig  gpu.zig  resolve.zig
│   ├── log.zig  jsonbuf.zig  fuzz.zig
│   └── parsers/ (go.zig  rust.zig  python.zig  node.zig  java.zig  zigp.zig)
└── test/ (fixtures/  harness/  container/  photon/)
```

The telemetry cluster (`telemetry.zig` emit path, `relay.zig` OTLP encoders +
the `relay --daemon`, `frame.zig` pipe wire format, `hostmetrics.zig` node
sampling, `gpu.zig`, `resolve.zig` DNS) is inert unless `photon=` is set.

## Product boundaries (do not blur)

- Free binary: never requires an account, never embeds an API key, never calls
  an LLM. Its excellence is the funnel for premium.
- **Offline by default, opt-in telemetry.** With no `photon` configured from any
  source — neither the `photon=` TOML key nor the `PHOTON_OTLP_HTTP_ENDPOINT`
  environment variable — mandor opens no socket and spawns no relay child; the
  offline guarantee is absolute. When `photon` IS configured (either source; an
  empty env value does not count) it speaks OTLP to photon, but *only* through the
  long-lived `mandor relay --daemon` child: the supervision path itself must never
  touch a socket, and telemetry must never stall or slow supervision (non-blocking
  pipe, drop-under-backpressure — incidents are the one durable tier). Any new
  telemetry follows this shape.
- **Curate by default.** mandor ships log *content* two curated ways — inside
  incident bundles, and as the default-on warn/error **digest** (deduped by
  signature, low-rate, flood-proof). Full per-line streaming is strictly opt-in
  and **per worker** (`[worker.NAME] stream`). GPU sampling is **auto-detected**
  (the daemon probes once at startup — on when a device is present, off with a
  one-time log otherwise; no toggle). Traces are never shipped.
- **TOML is a behavior overlay, the CLI is the source of truth.** The active
  worker set is whatever the CLI `--` args spawn (else the TOML `workers=`); every
  `[worker.NAME]` section and `[secret.*]` grant is matched to that set *by name*.
  A section or grant for a worker not spawned this run is ignored (warned), never
  an error, and **never itself a reason to spawn anything** — one static,
  never-rewritten TOML can describe a superset of possible workers. The worker
  command line stays CLI-only (no `command`/`args` key). Secrets resolve against
  the active set and degrade to the present subset (inert if none); deny-by-default
  is preserved — a worker only receives a secret it is listed for.
- Premium (AI-fix) logic lives in the sidecar + relay only. The spool dir JSON
  is the tier boundary the sidecar watches; photon consumes the same contracts
  over OTLP.
- Do not add features that grow the core past the size budget without
  explicit discussion (CI gates stripped size per commit).

## Naming

Project/binary: `mandor` (Indonesian: site foreman — the one who supervises
workers). Tagline: "the foreman for your containers."
