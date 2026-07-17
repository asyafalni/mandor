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
  heuristic incident summaries. **Fully offline. No network, no account, no LLM.**
- **Premium (separate sidecar binary, later):** ships incident bundles to a
  relay → AI root-cause analysis → optional repo access → auto-fix PR.
  The core binary NEVER contains networking except the optional local
  metrics endpoint.

## Architecture

```
mandor (PID 1, this repo)
├── spawner        fork/exec workers from CLI args or mandor.toml
├── reaper         waitpid loop, zombie reaping, exit-cause classification
├── signals        signalfd: forward TERM/INT/HUP to workers, graceful shutdown
├── capture        per-worker stdout/stderr pipes → ring buffers (default 256KB)
├── sampler        /proc/<pid>/{stat,status} poll (default 5s): CPU%, RSS, fds, threads
├── detector       incident triggers: nonzero exit, fatal signal, cgroup OOM,
│                  restart-loop (N in M min), monotonic RSS climb
├── summarize      heuristic engine (NO LLM): error dedup by signature,
│                  trace parsing, pattern verdicts ("restart loop", "leak suspect")
├── report         `mandor report` → human text or --json
└── spool          incident bundles written to /var/lib/mandor/incidents/*.json
                   (premium sidecar watches this dir — clean tier boundary)
```

### Incident bundle schema (stable contract — sidecar + AI depend on it)

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

## Build order (do not skip ahead)

1. **v0.1 — multirun parity.** Spawn N workers from argv, forward signals,
   reap zombies, exit when all workers exit (propagate worst exit code).
   Restart policy `--restart=always|on-failure|never` + exponential backoff.
2. **v0.2 — capture + stats.** Pipe stdout/stderr through ring buffers
   (prefix lines `[name]` like multirun), /proc sampler, `mandor report`.
3. **v0.3 — detector + summarize.** Incident triggers, error dedup by
   signature, spool dir writer. Trace parsers: **Go and Rust first**
   (panic formats are structured stderr text), Python third (traceback),
   C++ (needs symbolization — defer), Zig last.
4. **v0.4 — polish.** cgroup v2 OOM detection, optional Prometheus text
   endpoint (hand-rolled, one route), mandor.toml config (CLI-only must
   always work — zero-config is a feature).
5. **v1.x — premium sidecar** (separate repo/binary, possibly Rust for rustls):
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
mandor --restart=on-failure --backoff-max=30s -- "./api" "./worker"
mandor report            # human summary     mandor report --json
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
│   ├── main.zig  spawner.zig  reaper.zig  signals.zig
│   ├── capture.zig  sampler.zig  detector.zig
│   ├── summarize.zig  report.zig  spool.zig
│   └── parsers/ (go.zig  rust.zig  python.zig)
└── test/ (fixtures/  harness/)
```

## Product boundaries (do not blur)

- Free binary: never phones home, never requires an account, never embeds an
  API key, never calls an LLM. Its excellence is the funnel for premium.
- Premium logic lives in the sidecar + relay only. The spool dir JSON is the
  ONLY interface between tiers.
- Do not add features that grow the core past the size budget without
  explicit discussion (each v0.x milestone: check stripped size in CI).

## Naming

Project/binary: `mandor` (Indonesian: site foreman — the one who supervises
workers). Tagline: "the foreman for your containers."
