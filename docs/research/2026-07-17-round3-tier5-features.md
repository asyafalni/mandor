# Round-3 supervisor feature research — Tier 5 candidates

*2026-07-17. New ground only: process-compose, Erlang/OTP supervision trees,
Nomad task lifecycle, Solaris SMF, Upstart, k8s lifecycle hooks +
terminationMessagePath, Go-supervisord (ochinchina), mprocs/concurrently,
BSD rc. Judged against the ~26 KB size headroom and the simplicity mandate.*

## Ranked candidates

| # | Feature | Cx | Value | Rationale | Demand proof |
|---|---------|----|-------|-----------|--------------|
| 1 | k8s termination-log writer | XS | ●●●● | mandor's verdict appears in `kubectl describe pod` with ZERO config — k8s built `FallbackToLogsOnError` precisely because almost nothing writes this file | https://kubernetes.io/docs/tasks/debug/debug-application/determine-reason-pod-failure/ · https://github.com/kubernetes/kubernetes/issues/139 |
| 2 | Recycle thresholds: `max_rss_mb` + `max_lifetime` | XS | ●●●○ | pm2's most-cited flag (`max_memory_restart`); sampler already reads RSS every 5s — one comparison turns the leak-suspect *detector* into an *actor* | https://pm2.keymetrics.io/docs/usage/memory-limit/ · https://github.com/systemd/systemd/issues/25966 |
| 3 | Per-worker restart-policy override | XS | ●●●○ | supervisord/process-compose/Nomad are all per-process; mandor already scopes oneshot/env/cwd per worker — global-only restart is an inconsistency | https://f1bonacc1.github.io/process-compose/launcher/ |
| 4 | Restart propagation along start_after (`rest_for_one`) | S | ●●●○ | 30-year-proven OTP semantics; compose retrofitted `depends_on: restart: true` in v2.17 after years of demand; mandor owns the DAG, restart is the missing half. Defer until asked | https://github.com/docker/compose/issues/3397 · https://www.erlang.org/doc/system/sup_princ.html |
| 5 | `essential` worker (leader semantics) | XS | ●●○○ | Nomad leader-task / process-compose `exit_on_end`: designated worker exits ⇒ everything stops, its code propagates | https://developer.hashicorp.com/nomad/docs/job-specification/lifecycle |
| 6 | `pre_stop` drain hook | S | ●●○○ | Real (nginx-style non-signal stops) but the routing-drain half lives at pod level (kubelet preStop); narrower than it looks | https://devopscube.com/kubernetes-pod-graceful-shutdown/ |
| 7 | TTY color-coded prefixes | XS | ●○○○ | PID-1 stdout is rarely a TTY; only helps local config testing | https://github.com/open-cli-tools/concurrently/blob/main/docs/cli/prefixing.md |
| 8 | `.env` file loading | XS | ●○○○ | Container env comes from the runtime; process-compose immediately needed disable flags — complexity-creep smell | https://f1bonacc1.github.io/process-compose/configuration/ |

## Confirmed rejects

- **`one_for_all` restart groups** — over every worker it's just "restart the
  container", the orchestrator's job; OTP max-intensity = existing max-restarts.
- **process-compose namespaces & replica expansion** — dev-machine features;
  containers run 2–5 workers.
- **Go-supervisord's web GUI / XML-RPC / remote syslog** — violate the
  offline boundary and size budget; `restart_when_binary_changed` is a
  dev-machine feature (images are immutable).
- **mprocs-style PTY panes** — VT100 emulator cost; validates our plain
  prefix approach instead.
- **Upstart event bus** — died with Upstart; hook + ordering cover real uses.
- **SMF maintenance state / contracts** — give-up IS maintenance state; only
  action is report wording for given-up workers.
- **k8s postStart analog** — racy by design; oneshots + start_after +
  readiness already order better.
- **Nomad poststop phase; docker-autoheal** — covered by hooks /
  restart-on-unhealthy respectively.

## Design sketches (top 3)

**termination-log:** at startup `stat("/dev/termination-log")` — presence IS
the k8s signal (override/disable via `termination_log` key). On fatal-worker
exit (or first incident) write verdict + cause + restart count, ≤4096 bytes.
One openat+write on the death path; ~1–2 KB of code.

**recycle thresholds:** per-worker `max_rss_mb = 768`, `max_lifetime = "12h"`
checked in the existing 5s tick; trigger reuses stop-grace TERM restart
WITHOUT incrementing the give-up counter (planned recycling ≠ failure);
history records `recycled:rss` so the premium tier still sees the pattern.

**per-worker restart override:** global `restart`/`max_restarts`/`backoff_max`
become defaults; per-worker pairs (`restart = ["api=always"]`) shadow them.
Two-level lookup at spawn; no new state machine; unblocks `essential` later.

**Strategic note:** #1 and #2 compound mandor's actual differentiator (the
summarize engine) rather than chasing parity; top-3 together ≈ <10 KB.
