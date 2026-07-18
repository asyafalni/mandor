# mandor roadmap — ranked by value ÷ complexity

Derived from the 2026-07-17 supervisor-landscape research
([full report](research/2026-07-17-supervisor-landscape-and-bundle-v2.md)).
Ordering rule: lowest-hanging fruit first — each tier is roughly "one
milestone of work", and within a tier items are sorted by value-per-effort.
Complexity scale: **XS** (< 1h) · **S** (half day) · **M** (1–3 days) ·
**L** (a week+).

## Tier 1 — v0.5 "forensics upgrade" — ✅ SHIPPED 2026-07-17 (bundle schema v2)

These convert the incident bundle from human-readable postmortem into
LLM-localizable repair input. One coordinated schema bump to `"v": 2` with
fixture tests.

| # | Feature | Cx | Value | Why first |
|---|---------|----|-------|-----------|
| 1 | `core_dumped` flag from wait status | XS | ● ● ○ | One bit already in the wait status; disambiguates crash class for free |
| 2 | Uptime / `spawned_at` / time-to-crash in bundle | XS | ● ● ○ | Instant-crash-on-boot vs. slow-death is a different fix; data already held |
| 3 | `MANDOR_RELEASE` / `GIT_SHA` env passthrough → `build` field | XS | ● ● ● | The #1 RCA lever ("what changed"); Sentry-style convention, ~20 lines |
| 4 | Sibling worker status in bundle | XS | ● ○ ○ | Isolated vs. cascade; state already in the worker table |
| 5 | Per-line log timestamps (wall ms) in ring records | S | ● ● ● | Without them logs can't be ordered against the stats timeline; ~8 bytes/line |
| 6 | Spawn-time /proc snapshot: `cwd`, `exe`, ulimits, filtered env | S | ● ● ● | Vanishes at exit — must be read at fork; maps runtime paths → repo paths |
| 7 | First-class `exception.type` + `message` (parsers already find them) | S | ● ● ● | Ablation-proven: exception type beats the raw trace for LLM localization |
| 8 | Structured `cause` object (kind / exit_code / signal / oom delta) | S | ● ● ○ | Kills "exit 137 archaeology"; mirrors old string during transition |
| 9 | `--stop-grace=DUR` + `--expected-exit=CODES` | S | ● ● ○ | Exit-143-after-TERM must not spawn false incidents; table stakes elsewhere |

## Tier 2 — v0.6 "liveness" — ✅ SHIPPED 2026-07-17

| # | Feature | Cx | Value | Notes |
|---|---------|----|-------|-------|
| 10 | Structured trace frames `{file, line, function, in_app}` | M | ● ● ● | The 15–17× repair lever; rework parsers to emit fields, Sentry vocabulary |
| 11 | Command health checks + `--restart-on-unhealthy` | M | ● ● ● | The one failure exit-based supervision can't see: a hung worker. New incident cause `unhealthy` |
| 12 | Readiness fd (s6-style newline notification) | M | ● ● ○ | Enables "died before ever becoming ready" — very high-signal field |
| 13 | ELF build-id extraction from worker exe | M | ● ● ○ | Release correlation without app cooperation; small ELF note parser |

## Tier 3 — v0.7 — ✅ SHIPPED 2026-07-17 (#16 dropped: built-in redaction + simplicity)

| # | Feature | Cx | Value | Notes |
|---|---------|----|-------|-------|
| 14 | `start-after` dependency ordering (flat list, no DAG) | M | ● ○ ○ | Needs readiness (#12) to be meaningful |
| 15 | Incident history persistence (`first_seen`, `count` across supervisor restarts) | M | ● ○ ○ | Requires on-disk signature index in state dir |
| 16 | Env redaction allowlist in mandor.toml | S | ● ○ ○ | Policy design > code; default-redact `*SECRET*`, `*TOKEN*`, `*PASSWORD*`, `*KEY*` |
| 17 | Release binaries + `ghcr.io` image publishing in CI | S | ● ● ○ | Distribution, not features — do whenever convenient |

## Tier 4 — v0.8 (round-2 research, 2026-07-17) — ordered by value ÷ effort

From the [second landscape pass](research/2026-07-17-round2-tier4-features.md)
(OpenRC, launchd, circus, god/eye, compose/k8s probe semantics, systemd deep
cuts, s6 oneshots, pm2). Strict lowest-hanging-fruit order: build top-down.

| # | Feature | Cx | Value | Notes |
|---|---------|----|-------|-------|
| 18 ✅ | `max_restarts` give-up → mandor exits nonzero | XS | ● ● ● ● | SHIPPED 2026-07-17 |
| 19 ✅ | On-incident hook (exec argv + bundle path, no shell) | XS | ● ● ● ● | SHIPPED 2026-07-17 — premium sidecar bridge AND the [photon integration](INTEGRATION-PHOTON.md) primitive |
| 20 ✅ | Health-check `start_period` grace | XS | ● ● ● ○ | SHIPPED 2026-07-17 (default 10s) |
| 21 ✅ | Per-worker `env` / `cwd` | XS | ● ● ● ○ | No shell in scratch to set these; snapshot reporting already free |
| 22 ✅ | Oneshot init tasks (gates dependents via `start_after`) | S | ● ● ● ● | Migrations-before-workers; failed oneshot = LLM-fixable bundle + hard exit |
| 23 ✅ | Per-worker `user = "uid:gid"` drop (numeric) | S | ● ● ● ○ | SHIPPED 2026-07-17 — fail-closed (worker exits 126 if the drop fails) |
| 24 ✅ | `oom_score_adj` / `nice` knobs | XS | ● ● ○ ○ | SHIPPED 2026-07-17 (TOML-only) |
| ~~25~~ | ~~`replicas = N` scaling~~ | S | — | REJECTED 2026-07-18 (user): replication belongs outside the binary — bash/orchestrator territory |
| ~~26~~ | ~~Watchdog heartbeat over readiness fd~~ | S | — | REJECTED 2026-07-18 (user): would make worker-code cooperation *load-bearing* for the core restart function — mandor's identity is zero-cooperation supervision. (`ready_fd` stays: it's an optional ordering enhancement, not load-bearing.) Command health checks cover ~90% of hangs with no app changes. |

## Tier 5 — v0.10 candidates (round-3 research, 2026-07-17)

From the [third landscape pass](research/2026-07-17-round3-tier5-features.md)
(process-compose, Erlang/OTP, Nomad, SMF, Upstart, k8s lifecycle,
Go-supervisord). Top 3 ≈ <10 KB total; build top-down.

| # | Feature | Cx | Value | Notes |
|---|---------|----|-------|-------|
| 27 ✅ | k8s termination-log writer (auto when `/dev/termination-log` exists) | XS | ● ● ● ● | The verdict in `kubectl describe pod`, zero config — cheapest possible k8s-native visibility for the summarize engine |
| 28 ✅ | Recycle thresholds `max_rss_mb` / `max_lifetime` (per worker) | XS | ● ● ● ○ | pm2's most-cited flag; sampler already has RSS — detector becomes actor; planned recycling never counts toward give-up |
| 29 ✅ | Per-worker `restart` / `max_restarts` / `backoff_max` overrides | XS | ● ● ● ○ | Consistency: everything else already scopes per worker |
| 30 ✅ | Restart propagation along start_after (OTP `rest_for_one`) | S | ● ● ● ○ | SHIPPED 2026-07-18 (opt-in `restart_dependents = true`; dependents recycle, never counted as failure) |
| 31 ✅ | `essential` worker (leader exits ⇒ all stop, code propagates) | XS | ● ● ○ ○ | SHIPPED 2026-07-17 |
| 32 ✅ | `pre_stop` drain hook | S | ● ● ○ ○ | SHIPPED 2026-07-18 (hook completes → TERM follows; stop-grace KILLs hung hooks) |
| 33 ✅ | TTY color prefixes + `env_file` loading | XS | ● ○ ○ ○ | SHIPPED 2026-07-17 |
| 34 ✅ | Ultra-low-latency capture path, nanozlog-inspired (https://github.com/wyzdwdz/nanozlog) | M | ● ● ○ ○ | User-parked 2026-07-17 — make logging MORE EFFICIENT: study nanozlog's lock-free SPSC/deferred-IO/zero-alloc techniques for the read→assemble→ring→echo hot path (batched writev echo, fewer wallMs calls, single-copy framing). Compared vs logly.zig 2026-07-17: nanozlog wins decisively (6.8 ns/msg ~147M msg/s lock-free SPSC vs logly's 8.5 µs simple path; logly is a feature-rich app logger — wrong shape for a PID-1 hot path). Reference stays nanozlog. |

## Explicitly rejected (research-backed)

- Log rotation to disk (ring buffers make the blocking-pipe failure class impossible)
- PTY allocation / tmux-style attach (overmind's niche, not container PID 1)
- rlimit *enforcement* (cgroup limits are the container runtime's job)
- Full s6-rc-style dependency DAG / oneshot compiler
- Socket activation (needs app cooperation; host-systemd territory)
- File-watch auto-restart (dev-laptop workflow; prod restarts are image rollouts)
- Control-plane API / pub-sub bus (size + attack surface; state file + report + metrics + hook suffice)
- Condition DSLs à la god/eye (opinionated zero-config detectors beat a language)
- pm2-style cluster fd-sharing (Node-specific; `replicas` is the honest version)
- FDStore-style state handoff, launchd KeepAlive conditions, cron scheduling (wrong layer)
- `one_for_all` restart groups (= "restart the container" — the orchestrator's job)
- Web GUI / XML-RPC control / remote syslog (Go-supervisord's additions; offline boundary + size)
- PTY panes à la mprocs (VT100 emulator cost; plain prefixes win for non-interactive)
- Upstart-style event bus; k8s postStart analog (racy); Nomad poststop phase; namespaces/replica expansion
- Watchdog/sd_notify heartbeat (would make worker-code cooperation load-bearing for core restart; health checks cover it with zero app changes)

## Tier 6 — round-4 research (2026-07-18)

From the [fourth landscape pass](research/2026-07-18-round4-tier6-features.md)
(procd/finit, preforking app servers, Linux security primitives, PSI,
core-dump, JSON logging). Only extensions of existing subsystems survived.

| # | Feature | Cx | Value | Notes |
|---|---------|----|-------|-------|
| 35 ✅ | PSI stall sampling (cgroup v2 pressure) → `stall:*` detector cause | S | ● ● ● ○ | SHIPPED v0.16 — psi_mem_pct/psi_cpu_pct, PSI in bundle stats (schema v6) |
| 36 ✅ | `no_new_privs` + `cap_drop` at exec | S | ● ● ● ○ | SHIPPED v0.16 — per-worker cap bounding-set (names or "all"), no libcap |
| 37 | JSON supervisor-event log | S | ● ● ○ ○ | Folded into existing paths: offline = plain `[mandor]` stdout lines; online = photon. No separate sink |
| 38 ✅ | `RLIMIT_CORE` in bundle | XS | ● ○ ○ ○ | SHIPPED v0.16 (`limits.core`) |

## Tier 7 — parked idea (user, 2026-07-18)

| # | Feature | Cx | Value | Notes |
|---|---------|----|-------|-------|
| 39 | Cost / right-sizing report (`mandor report --cost`) | M | ● ● ● ○ | PARKED — on-philosophy: "the foreman tells you what each worker costs." Design below |

### #39 design — resource-cost profiling without touching worker code

**The core problem the user named:** distinguishing idle / regular / peak
resource cost. Answer — mandor can't know app-semantic "busy", but it can
*infer state from the CPU signal it already samples*, with zero cooperation:

- **State classifier:** a sample with `cpu_pct < idle_threshold` (≈5%) is an
  *idle* sample; otherwise *active*. Pure /proc data, no app knowledge.
- **Per-state stats:** `idle_rss` = median RSS over idle samples (the memory
  floor); `regular_rss` = median RSS over active samples (steady-state);
  `peak_rss` = max RSS overall (the sizing ceiling). Same split for CPU.
- **Long horizon without heavy storage:** the 2-min sampler ring is too short
  for cost profiling. Keep per-worker fixed-size aggregates instead —
  **log-scale RSS histogram + linear CPU histogram** (a few hundred bytes
  each, zero alloc, O(1) update per 5s tick) → approximate percentiles.
  Persist to the state dir (like incident history) so profiles survive
  restarts. Fits the fixed-buffer / zero-alloc DNA exactly.
- **Cost proxies = the real billing units:** cumulative **CPU-core-seconds**
  (integral of cpu_pct over uptime) and **RSS-byte-seconds / GB-hours** (mean
  RSS × uptime) — what clouds actually charge for. Plus **duty cycle**
  (% active samples) to flag oversized/mostly-idle workers.

**Presentation.** Human: `mandor report --cost` → per-worker table (idle /
typical / peak RSS+CPU, GB-hours, core-seconds, duty%) with a one-line
**sizing suggestion** ("api: set memory 900MB [peak 812MB ×1.1], CPU request
0.3 / limit 0.9 cores, 78% duty"). LLM: a JSON cost profile with the
percentiles + suggestion so the premium agent can emit right-sizing PRs
(k8s `resources:` block, compose limits). Sizing rule of thumb: memory limit
= peak × margin (OOM-safety); CPU request = p50; CPU limit = p95.

## Backlog status

Four research rounds complete; all surfaced features shipped or
rejected-with-reason. One user-originated idea is parked (#39 cost report,
Tier 7). Remaining non-feature work: distribution (aports/apt/AUR,
announcement), v1.0 fuzz-hardening, and the premium sidecar (separate repo).
