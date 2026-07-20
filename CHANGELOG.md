# Changelog

All notable changes to mandor. Format follows [Keep a Changelog](https://keepachangelog.com/);
versions correspond to git tags. Planned work lives in [docs/ROADMAP.md](docs/ROADMAP.md).

## [1.0.1] - 2026-07-20

A second hunting pass over the untrusted-input surface, after finding that one
fuzz target had been silently testing nothing.

### Fixed
- **Integer-cast trap loading a corrupt `history.json`**
  (`history.loadFromText`). A recurrence timestamp past `maxInt(i64)` trapped
  on the `@intCast` — and this runs on the startup load path, so it killed
  PID 1. `count`/`builds` were already clamped; `first`/`last` were not.
- **Prometheus label injection via worker names.** A worker name is a
  basename, so it can hold any byte a filename can, and it was interpolated
  raw into `worker="…"`. A quote or backslash silently corrupted every scrape.
  Names are now neutralized once at derivation, so all sinks benefit. (JSON
  sinks were already correctly escaped — bundles were never affected.)
- Histogram counts from a corrupt `cost.json` used wrapping arithmetic, which
  could not crash but could load nonsense values. Now saturating.
### Changed
- One `report.clamp(T, v)` helper replaces the `@intCast(@min(…, maxInt(T)))`
  pattern that was duplicated across `history.zig` and `cost.zig`. The
  duplication *was* the bug class: the one site that forgot the clamp is the
  crash above. The safe form is now the short form.
- `--help` no longer enumerates advanced flags. The list had already drifted
  out of date (it omitted `--max-restarts`, `--health-start-period`, and
  `--on-incident`), and it duplicated the man page and `docs/CONFIG.md`.
  Advanced settings are pointed at `mandor.toml` instead. No flag changed;
  every existing flag still works.
- Fuzz harness: added an argv/command-tokenization target, and corrected the
  `history.json` seed. The old seed used `"sig":123` where the loader keys off
  `{"sig":"` plus a fixed 16-digit hex field, so it matched nothing and fuzzed
  an early return — which is why the crash above survived 1.0.0.

## [1.0.0] - 2026-07-20

First stable release. The supervision path is now hardened against the inputs
it cannot trust, which was the last item standing between 0.x and 1.0.

### Added
- Mutation-fuzzing harness (`src/fuzz.zig`) over every parser that consumes
  untrusted input: worker stderr through the six trace parsers, the worker's
  ELF header, `mandor.toml`, `/proc` and cgroup pressure text, and mandor's
  own state files. Seeded with real crash output in `test/fixtures/`, with a
  boundary-value dictionary and a structured ELF generator. It runs inside
  `zig build test` (fresh seed per invocation) and across 12 seeds in CI;
  failures replay with `zig build test --seed 0x…`.
### Fixed
- **Integer overflow parsing a malformed ELF header** (`elf.zig`). mandor
  reads a worker's ELF at spawn time to extract its build-id; a corrupt,
  truncated, or hostile binary could wrap the program-header offset
  arithmetic and panic PID 1 — killing the container. All offsets derived
  from file bytes now saturate.
- **Integer overflow parsing cgroup pressure text** (`sampler.parsePsiAvg60`).
  A long digit run in a corrupt `*.pressure` file overflowed the accumulator;
  it now saturates and clamps as before.
- Formatting drift in `spool.zig` that had been failing the CI `zig fmt
  --check` step since 0.19.0.

## [0.20.0] - 2026-07-19
### Added
- Shift report — at shutdown mandor prints one consolidated summary of the
  whole run to stdout: worker count, run duration, total restarts and
  incidents, then per worker its exit code, restarts, peak RSS, and GB-hours.
  A human (`kubectl logs`) or an AI post-mortem sees what happened across the
  container's whole life without scraping the incident spool. Zero config,
  always on; reuses the worker table and cost profiles.

## [0.19.0] - 2026-07-19
### Added
- Release-aware incident correlation — "did your fix work?". Each crash
  signature now remembers which builds it appeared on; when the same crash
  recurs after a code change, mandor flags it a regression. Bundles gain
  `history.builds` / `first_build` / `last_build` / `regressed`, and
  `report --incidents` marks it inline (`[REGRESSED v1.0.0->v1.0.1]`). This
  is the feedback edge of the incident → AI-fix → redeploy loop: mandor now
  tells the developer (or the premium agent) whether the last fix held. Uses
  the `MANDOR_RELEASE`/`GIT_SHA` passthrough already captured; with no
  release wired it degrades silently (zero config).
### Changed
- Incident bundle schema v6 → v7 (added the `history` build fields).
  `history.json` → v2 (build correlation persisted; v1 files still load).

## [0.18.0] - 2026-07-19
### Changed
- Faster log capture (nanozlog-inspired hot path). Complete lines that arrive
  contiguous in one read now go straight from the read buffer to the ring and
  the batched `writev` — the intermediate line-assembly copy is skipped for
  the common case (only lines that straddle a read boundary are staged). The
  pipe read buffer is sized to a pipe's 64 KB capacity, so a saturated pipe
  drains in one `read()` instead of ~16 under log spam. No new config, no
  behavior change; fewer syscalls and one less copy per line.

## [0.17.0] - 2026-07-18
### Added
- `mandor report --cost` — per-worker resource-cost profiling: idle / typical
  / peak RSS and CPU (idle-vs-active inferred from the CPU signal, zero worker
  cooperation), GB-hours, CPU-core-seconds, duty cycle, and a right-sizing
  suggestion (memory limit, CPU request/limit). `--json` for the LLM/premium
  agent. Profiling is automatic; the profile persists in
  `<state-dir>/cost.json` (fixed-size histograms, no allocation) and
  accumulates across worker restarts.

## [0.16.0] - 2026-07-18
### Added
- PSI stall detection: samples cgroup v2 memory/cpu/io pressure once per
  tick; `psi_mem_pct`/`psi_cpu_pct` thresholds raise a `stall:memory|cpu`
  incident attributed to the largest consumer. PSI recorded in every
  bundle stats timeline (schema v6).
- Per-worker `cap_drop` (capability bounding-set drop; names or "all") plus
  automatic `no_new_privs` after a uid drop — closes the setuid
  re-escalation hole. No libcap dependency.
- `limits.core` (RLIMIT_CORE) in bundles, alongside the existing
  core_dumped flag.
### Notes
- #37 JSON supervisor-log folded into existing paths: offline = plain
  `[mandor]` stdout lines; online = photon. No separate sink built.

## [0.15.0] - 2026-07-18
### Added
- `mandor validate [--config=PATH]` — dry-run config check (bad values,
  cycles, and unknown worker references), sharing run()'s exact setup path.
- `mandor report --incident=N` — dump one bundle raw; incident list now
  numbered oldest-first.
- Version stamped into the binary at build time (`-Dversion=`).
- `docs/mandor.1` man page, `CONTRIBUTING.md`, `examples/` recipes
  (web+worker+cron, migrations, photon).
### Changed
- Setup phase extracted to a shared `applyConfig` so `run` and `validate`
  can never drift.

## [0.14.0] - 2026-07-18
### Added
- Zig panic-trace parser (dogfood) — six languages now: Go, Rust, Python,
  Zig, Java, Node.
- `mandor report [NAME|PID]` row filtering; `report --incidents [NAME]
  [--since=DUR]` history filtering; `h` duration unit.
- HEALTH column and distinct `recycling` / `gave-up` labels in `report`.
- `docs/CONFIG.md` — complete configuration reference.
- CI: capture perf-regression gate; aarch64 unit tests under qemu.
### Changed
- Setup code DRY: one table drives all per-worker settings (bad values now
  consistently fail startup).

## [0.13.0] - 2026-07-18
### Added
- `restart_dependents = true` — OTP `rest_for_one`: a dependency's restart
  recycles its `start_after` dependents (planned, never counted as failure).
- `pre_stop = ["name=CMD"]` drain hooks: on graceful shutdown the hook runs
  first and TERM follows its completion; stop-grace KILLs hung hooks.
### Removed
- `replicas` scaling rejected permanently: replication belongs outside the
  binary (scripts/orchestrator).

## [0.12.0] - 2026-07-18
### Added
- Node.js and JVM stack-trace parsers: structured `file:line` frames with
  `in_app` heuristics (`node:`/`node_modules`, `java.`/`jdk.`/`kotlin.`
  filtered), first-class exception type/message, Caused-by chains in raw.
- Relay bearer-token auth: set `PHOTON_TOKEN` and `mandor relay` sends
  `Authorization: Bearer …` (env-inherited, never on the cmdline).
### Docs
- photon-side contribution spec (`docs/photon-contrib/`): exact OTLP/JSON
  ingest change for photon's `/v1/logs`, written from code reconnaissance.

## [0.11.1] - 2026-07-17
### Changed
- nanozlog-inspired batched capture: one `writev` (and one clock read) per
  drained pipe instead of per line — 2.1× wall, 6× less kernel time on a
  200k-line burst.

## [0.11.0] - 2026-07-17
### Added
- TTY color-cycled `[name]` prefixes (real terminals only; piped logs stay clean).
- `env_file` — KEY=VAL file loaded into every worker's environment.
- `essential` workers — leader semantics: its exit stops the fleet and
  propagates its code (Nomad leader-task heritage).
### Fixed
- No-orphan hardening: `PR_SET_PDEATHSIG` on workers (TERM) and probes
  (KILL) with fork-race guard; process-group sweep when a worker dies so
  grandchildren never linger across restarts.

## [0.10.1] - 2026-07-17
### Changed
- Size diet: custom raw panic handler severs std.debug's machinery —
  **487 KB → 214 KB** (x86_64), safety checks unchanged.

## [0.10.0] - 2026-07-17
### Added
- Kubernetes termination-log death rattle: when `/dev/termination-log`
  exists, incidents rewrite it so `kubectl describe pod` shows the verdict.
- Recycle thresholds `max_rss_mb` / `max_lifetime` — planned recycling that
  never counts as failure (pm2 `max_memory_restart` heritage).
- Per-worker `restart` policy overrides.

## [0.9.1] - 2026-07-17
### Changed
- photon integration folded into the single binary: `photon = "ip:port"`
  auto-forwards incidents via a fire-and-forget self-exec relay; mandor
  stays fully offline until the key is set.

## [0.9.0] - 2026-07-17
### Added
- Per-worker privilege drop `user = "name=uid:gid"` (fail-closed).
- `oom_score_adj` / `nice` per-worker knobs.
- Alpine `APKBUILD` (packaging/alpine) and release `.deb`/`.apk`/`.rpm`
  packages via nFPM.

## [0.8.0] - 2026-07-17
### Added
- `max_restarts` give-up: consecutive failed restarts make mandor exit with
  the flapping worker's code — visible to the orchestrator.
- `on_incident` hook: exec any command with each bundle path (no shell).
- Health-check `start_period` grace (default 10s; the startupProbe lesson).
- Oneshot init tasks (migrations-before-workers; failure aborts startup).
- Per-worker `env` / `cwd`.

## [0.7.1] - 2026-07-17
### Added
- Distro CI matrix (Alpine/Debian/Ubuntu run the full harness).
- Package publishing in releases.

## [0.7.0] - 2026-07-17
Initial public release — everything from the v0.1–v0.7 build-out:
- multirun parity: spawn N workers, restart policies + exponential backoff,
  zombie/orphan reaping, worst-exit-code propagation.
- dumb-init parity: full signal forwarding (TERM/INT/HUP/QUIT/USR1/USR2/
  WINCH) with per-worker process groups; stop-grace TERM→KILL escalation.
- Log capture: 256 KB ring buffers, timestamped lines, `[name]` prefixes.
- /proc sampler (CPU/RSS/fds/threads), state file, `mandor report`
  (+ `--json`, `--incidents` history recall with 200-file retention).
- Incident bundles (schema v5): structured cause/exception/frames
  (file:line/in_app), spawn snapshot, ELF build-id, `MANDOR_RELEASE`,
  deduplicated log tail with repeat counts, siblings, persistent recurrence
  history; Go/Rust/Python trace parsers; restart-loop / RSS-leak / cgroup
  OOM detection; heuristic diagnosis verdicts.
- Health checks + `--restart-on-unhealthy`, s6-style readiness fd,
  `start_after` ordering, `--expected-exit`.
- Prometheus text endpoint, TOML config (CLI-only always works),
  GitHub Releases + ghcr.io multi-arch image.
