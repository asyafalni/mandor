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
| 34 ✅ | Ultra-low-latency capture path, nanozlog-inspired (https://github.com/wyzdwdz/nanozlog) | M | ● ● ○ ○ | SHIPPED v0.18 — all three levers landed: batched `writev` echo (one syscall per drained pipe), one `wallMs()` per drain (not per line), single-copy framing (complete contiguous lines skip the assembler staging copy — only boundary-straddling lines stage). Read buffer sized to the pipe's 64 KB capacity so a saturated pipe drains in one `read()`. Zero new config, no size cost (BSS buffer). Compared vs logly.zig 2026-07-17: nanozlog wins decisively (6.8 ns/msg ~147M msg/s lock-free SPSC vs logly's 8.5 µs simple path; logly is a feature-rich app logger — wrong shape for a PID-1 hot path). Reference stays nanozlog. |

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
| 39 ✅ | Cost / right-sizing report (`mandor report --cost`) | M | ● ● ● ○ | SHIPPED v0.17 — CPU-signal state classifier, fixed histograms persisted to cost.json, GB-hours + core-seconds, right-sizing suggestions + JSON. Design below |

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

## Tier 8 — foreman↔owner reporting (user, 2026-07-19)

From the "mandor as site foreman" lens: the *downward* channel (supervising
workers) is near-complete, so the remaining value is in the *upward* channel —
what the foreman reports back to the developer/owner (human **or** AI agent).
mandor already speaks in point-events (bundles) and present-tense snapshots
(`report`); these add the two tenses it was missing.

| # | Feature | Cx | Value | Notes |
|---|---------|----|-------|-------|
| 40 ✅ | Release-aware incident correlation ("did the fix work?") | S | ● ● ● ● | SHIPPED v0.19 — signature history now tracks builds; `regressed` when a crash survives a code change. `report --incidents` shows `[REGRESSED a→b]`; bundle `history.{builds,first_build,last_build,regressed}`. Closes the AI-fix loop's feedback edge. Reuses signature index + `MANDOR_RELEASE`/`GIT_SHA`; zero config |
| 41 ✅ | Shift report / run digest at shutdown | S | ● ● ● ○ | SHIPPED v0.20 — at shutdown prints one `[mandor] shift report` block to stdout: workers, run duration, total restarts + incidents, then per worker exit code / restarts / peak RSS / GB-hours. Post-mortem for human or AI without scraping the spool. Reuses worker table + cost profiles; zero config. Complements #40 (digest = this shift; #40 = the trend across shifts) |

**Rejected here (aligned-looking but off-identity):** runtime per-worker control
(`ctl restart`) — needs a control socket (attack surface + size) and fights
immutable-infra; config hot-reload (SIGHUP) — same immutable-infra objection
(config change = new image). Both already on the rejected list.

## Tier 9 — parked (found during v1.0.x hardening)

| # | Item | Cx | Value | Notes |
|---|------|----|-------|-------|
| 42 ✅ | Route a failed spawn through the death path (fixes fork-retry, `essential`, `oneshot`) | S | ● ● ● ● | SHIPPED v1.2.0 — all 3 defects fixed by one structural change; +496 B. See below |
| 43 ✅ | Exit once all *essential* workers are done | XS | ● ● ● ○ | SHIPPED v1.4.0 — the loop-exit test asks it of essential workers only; sidecars are drained and the exit code is the essential outcome |
| 44 ✅ | Per-worker `expected_exit` | XS | ● ● ○ ○ | SHIPPED v1.3.0 |
| 45 | `relay.zig` has no test coverage | S | ● ● ● ○ | PARKED 2026-07-21 — zero fuzz targets, zero harness cases; parses two untrusted inputs |
| 46 | `supervisor.run` is very large | M | ● ● ○ ○ | IN PROGRESS — steps 1–2 shipped (`Shutdown` struct, `handleDeaths`); `run` 451 → 344 lines |
| 47 | Post-death group sweep can cut short a grandchild's own TERM handler | S | ● ● ○ ○ | PARKED 2026-07-21 — found via a flaky harness case; see below |

### #42 — `fork` failure permanently retires a worker

`supervisor.zig` currently handles a failed spawn by marking the worker
`done` with `final_code = 125`:

```zig
spawner.spawn(...) catch {
    logmod.print("[mandor] fork failed for {s}\n", ...);
    w.done = true;
    w.final_code = 125;
```

But `fork` returning `EAGAIN` — a pids-cgroup limit or `RLIMIT_NPROC` under
load, entirely plausible in a container during a restart storm — is
*transient*. mandor retires the worker permanently even after the pressure
clears, and keeps running, so the orchestrator sees a healthy container with a
silently missing worker. Silent degradation is arguably worse than dying.

**Proposed:** treat a failed spawn as a failed *start* — apply the restart
policy and backoff, giving up only at `max_restarts`. That is exactly what the
backoff machinery exists for, and it preserves the give-up signal for genuinely
permanent failures.

**A worker that never starts also silently defeats `essential`** (user
question, 2026-07-20 — verified by forcing `spawn()` to return `ForkFailed`):

```
[mandor] fork failed for sleep     <- essential worker, never started
[mandor] spawned sleep-2 (pid 639) <- fleet carries on regardless
(mandor still running when an external timeout killed it)
```

No `essential worker … stopping all`. The leader semantics live at
`supervisor.zig:471`, *inside the reap/death block* — they only run when a
worker that was running exits. The spawn-failure path sets `w.done = true;
w.final_code = 125;` and returns, never reaching that check. So the fleet keeps
running with a leader that never existed, and the shift report lists the
worker as `exit 125` as though it had run. The `essential` guarantee breaks in
precisely the situation it exists for, and mandor never exits, so no
orchestrator restarts the container either.

**A oneshot that never starts is treated as SUCCESS** (verified the same way,
injecting `ForkFailed` for the init task):

```
[mandor] fork failed for setup
[mandor] api waits for init tasks
[mandor] spawned api (pid 459)          <- gate opened anyway
[api] API SERVING (db may be unmigrated!)
```

Controls confirm the normal paths are correct: a oneshot that exits 0 logs
`init task setup completed` and releases the fleet; one that exits nonzero logs
`init task setup failed, shutting down` and the dependents never start. Only
the never-started case misbehaves. `allOneshotsDone` (`supervisor.zig:650`)
tests just `w.done`, which the spawn-failure path sets — so the failed init
task reads as finished.

This is the worst of the three: not a missing guarantee but a **failure
silently converted into a success**, with dependents proceeding against
uninitialized state. Migrations never ran; the API serves anyway.

**Three defects, one root cause** — every terminal-state handler (restart
policy, `essential` at `supervisor.zig:471`, `oneshot` at `:418`) lives inside
the reap/death block, and the spawn-failure path bypasses all of them:

1. A transient `EAGAIN` retires the worker permanently instead of retrying
   under the restart policy and backoff.
2. That retirement skips leader semantics — the fleet runs on without its
   leader and mandor never exits.
3. A failed oneshot counts as a completed one, releasing its dependents.

Fixing (1) by routing a failed spawn through the same path as a worker death
fixes (2) and (3) for free. That is a strong argument against special-casing
each check at the spawn site: the bug is the second terminal path, not the
individual handlers.

**SHIPPED v1.2.0** exactly that way. `spawnWorker` now stages a synthetic
death (`status = exited(125)`, `spawn_failed = true`) instead of retiring the
worker, and the death path runs even without a `SIGCHLD` — no child existed to
send one. All four behaviours verified by injection: on-failure retries and
recovers, `never` does not retry, `essential` stops the fleet, a failed
`oneshot` shuts down with dependents unstarted.

**Size lesson worth keeping.** The obvious formulation — adding `and
!spawn_deaths` to the loop's `break` condition — cost **+6,528 B**, traced by
symbol diff to `supervisor.run` itself: an extra term there makes the compiler
duplicate the loop body. Counting the spawn-failed worker as *pending* in the
existing live/pending tally is behaviourally identical and costs **+496 B**.
When a small change grows `.text` disproportionately, `nm --print-size` on a
`-Dstrip=false` build names the function responsible.

**Why parked:** it changes restart semantics and the observable exit code 125.
Not a crash — mandor stays alive either way — so it did not gate the 1.0.x
stability line. Note this is about a worker that *never started*, which is a
different trigger from #43 (workers that started and later exited).

### #43 — exit when all significant workers are gone

**Prompted by the user's question (2026-07-20): what modes should exist when
*some* workers exit?** Three obvious ones already exist and should not be
re-spelled as a new `mode =` knob — that would be a second way to say the same
thing:

| Mode | Already expressed as |
|------|----------------------|
| Shut the fleet down | `essential = true` (exit stops the fleet, code propagates) |
| Restart the exited worker | `restart = "on-failure"` / `"always"` |
| Leave it dead, keep going | `restart = "never"` and not essential (the default) |

These map onto OTP's child restart types (`permanent` / `transient` /
`temporary`), and mandor already has `one_for_one` (per-worker restart) and
`rest_for_one` (`restart_dependents`). `one_for_all` stays rejected —
"restart everything" is the orchestrator's job.

**The actual gap.** mandor exits only when *every* worker is done. So:

> `api` and `worker` both die permanently. A log-shipper sidecar runs forever.
> mandor stays alive forever — the container looks healthy while doing nothing
> useful, and no orchestrator ever restarts it.

`essential` does not cover this: it fires when *any one* leader exits, not when
*all* the real workers are gone. There is currently no way to say "stay up
while at least one of api/worker lives; exit once none do, ignoring sidecars."
This is OTP 24's `auto_shutdown = all_significant`, and it is the one exit mode
mandor genuinely lacks.

**Re-scoped 2026-07-21 — v1.3 answered every open question.** The four
concerns below were the reason this was parked; the lifecycle rework resolved
all of them as a side effect, and what is left is a one-condition change.

| Was open | Answered by 1.3 |
|---|---|
| Which flag marks "significant"? | **`essential`** — it now defaults to `true`, so "significant" and "essential" are the same set. No new knob. |
| Which exit code? | A *failing* essential worker already ends the run with its code. This case is all-essential-workers-*finished*, so the existing worst-code rule applies. |
| Does a `max_restarts` give-up count as gone? | Moot — an exhausted essential worker already ends the run immediately. |
| Is the default safe? | Yes. When every worker is essential (the default), "all essential done" is identical to "all done". It only differs once a worker opts out with `essential = false` — which is exactly the sidecar case this targets. |

**Still reproducible on 1.3.1** (`job` exits 0, `sidecar` has
`essential = false` and never exits): mandor idles indefinitely with no real
work left.

**Remaining work:** the loop-exit test currently asks "is any worker still
live or pending"; it should ask that of *essential* workers only. Non-essential
workers then get TERM'd through the normal graceful shutdown. One condition
plus a harness case — the design thinking is done.

### #47 — the group sweep can cut short a grandchild's TERM handler

When a worker dies, `reaper.drain` sweeps its process group with `SIGKILL` so
restarts never accumulate strays (`reaper.zig`, "Leader is dead"). Under load
that races a grandchild that is still running its *own* TERM handler: the
worker traps TERM and exits quickly, the sweep fires, and the grandchild is
killed mid-drain. `stop_grace` does not cover it — the sweep is immediate.

Found while investigating harness case 13, which failed ~40% of the time while
a large image pull was running. Making the test wait for readiness markers
instead of a fixed `sleep 1` removed one race, but roughly 1-in-5 failures
remain under heavy I/O, and the residual is this.

**The design question:** stray prevention versus letting grandchildren drain.
Both are legitimate. A middle option is to sweep with TERM first and reserve
KILL for the stop-grace expiry, matching how the fleet shutdown already
escalates — but that costs a deferred sweep and some state, and the current
behaviour is defensible for the "restart must not leak processes" case it was
written for. Worth deciding deliberately rather than by default.

Note the harness case is a *real* signal here, not just flakiness: it is
detecting genuine non-determinism in mandor's shutdown, so it should not be
"fixed" by loosening the assertion.

### #45 — `relay.zig` has no test coverage

The photon bridge (`mandor relay`, run via the `photon = "ip:port"` key) has
**zero fuzz targets and zero harness cases**, yet it parses two inputs it does
not control: the `ip:port` config value (`parseHostPort`) and the incident
bundle read back off disk (`scanStr`, `buildOtlp`).

One inconsistency to check while adding coverage: in `buildOtlp`, `verdict` and
the embedded `bundle` go through `apEscaped`, but `name` and `release` are
interpolated into the OTLP JSON with a bare `{s}`. Values reach it already
escaped (the bundle was written with `appendJsonString`), so it is probably
fine in practice — but "probably fine by accident" is what the fuzzer is for,
especially on a corrupt or truncated bundle.

Add the targets to `src/fuzz.zig` with a seed generated from a **real** bundle,
not hand-written — see the seed-validity rule.

### #46 — `supervisor.run` is very large

The v1.3 size investigation showed `run` dominating the named-symbol profile,
and it is the function every lifecycle change has to be threaded through. It
now carries the poll loop, spawn gating, the death path, health probes, the
sampler tick and shutdown. Splitting the death path and the health path into
their own functions would help reviewability, and possibly `.text` too, since
several `std.fmt` instantiations get inlined into it.

Not urgent, and worth doing only alongside a change that already touches the
loop — a pure refactor of PID 1's core for its own sake carries more risk than
it removes.

### #44 — per-worker `expected_exit` (SHIPPED v1.3.0)

`expected_exit` is global today, so "exit 2 is fine for `cron` but a failure
for `api`" is inexpressible. Small and mechanical; slots naturally into
`[worker.NAME]` now that the sections exist.

## Backlog status

Four research rounds complete; all surfaced features shipped or
rejected-with-reason, including the last parked code item (#34 fast capture,
v0.18), the user-originated #39 cost report (v0.17), and the Tier 8
foreman↔owner reporting pair (#40 release correlation v0.19, #41 shift report
v0.20). No feature backlog remains.

**v1.0 fuzz-hardening: done (v1.0.0).** `src/fuzz.zig` mutation-fuzzes the
whole untrusted-input surface — the six trace parsers, the worker ELF header,
`mandor.toml`, `/proc` + cgroup text, and mandor's own state files — seeded
from real crash output in `test/fixtures/`. It now runs **13 targets** and has
found **seven** PID-1-fatal traps plus a Prometheus label-injection bug and a
backoff-cap violation across the v1.0.x passes; all fixed
and pinned by regression tests. Every one was an integer overflow on a value
read from an untrusted or persisted source — a malformed worker ELF, a corrupt
pressure file, a corrupt `history.json` or `cost.json`, `/proc` tick counts,
and calendar math on an out-of-range epoch (that last one on the
incident-write path, i.e. firing exactly when a worker had crashed).

Two findings about the *method* are worth keeping: a seed whose shape does not
match the real serialized format silently fuzzes an early return (the
`history.json` target did this through the 1.0.0 release), and duplicated
clamping logic is itself the bug — the one site that forgot `@min` was the
crash. The harness was
itself validated by mutation testing: with the fixes reverted it catches both
bugs on 8 of 8 seeds. Coverage-guided `zig build test --fuzz` is unusable on
the pinned Zig 0.16.0, so the harness is in-repo and runs under plain
`zig build test`.

**Soak test: done (v1.0.3).** `test/harness/soak.sh` runs capture at full
rate, restart churn, incident writes, the sampler, health probes, and the
metrics listener at once, and fails the build if mandor's own RSS, fd count,
or thread count drifts. Measured over a 30-minute run: **~1.1 MB RSS, 10 fds,
1 thread, 4 KB drift** — the "zero allocations in steady state" claim is now
evidence rather than assertion. The harness was itself calibrated by injecting
a 64 KB-per-tick leak (640 KB drift → fail), the same don't-trust-a-green-test
discipline used on the fuzzer. Paired with four integration cases for
hostile environments (corrupt, truncated, and garbage state files; a
read-only state dir), since bookkeeping failures must never outrank keeping
PID 1 alive.

**Lifecycle simplification: done (v1.3.0).** `restart` and
`restart_on_unhealthy` are gone, `max_restarts` is the only retry knob with an
intuitive encoding (`0` = don't retry, the default; `-1` = forever),
`essential` defaults to `true` so a failure that exhausts retries always
reaches the orchestrator, and the CLI is down to four flags with everything
else a `mandor.toml` key. Per-worker `expected_exit` (#44) shipped alongside as
the escape valve that makes essential-by-default safe.

**The recurring bug shape, worth remembering:** nearly every real defect found
in 1.x has been *mandor knowing something is wrong and not saying so* — a
retired worker, a bypassed `essential`, a failed init task reading as success,
a hung worker killed and reported as a clean shutdown, an abandoned
non-essential worker. The design rule that falls out of it is in CLAUDE.md:
**never absorb a failure the orchestrator should see.** The same shape showed
up in the test suite itself, where a fuzz seed that fails to parse makes the
suite greener rather than redder (three occurrences; now guarded).

Remaining non-feature work: a benchmark page vs tini/dumb-init/s6/supervisord,
distribution (aports/apt/AUR, announcement), and the premium sidecar
(separate repo).
