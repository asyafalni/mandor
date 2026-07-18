# Changelog

All notable changes to mandor. Format follows [Keep a Changelog](https://keepachangelog.com/);
versions correspond to git tags. Planned work lives in [docs/ROADMAP.md](docs/ROADMAP.md).

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
