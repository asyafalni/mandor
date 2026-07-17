# Round-2 supervisor feature research — Tier 4 candidates

*2026-07-17. Second research pass over tools/areas round 1 skimmed: OpenRC,
sysvinit, launchd, circus, god/eye/bluepill, honcho, nodemon, docker-compose
depends_on/healthcheck, Kubernetes probes, systemd deep cuts, s6 oneshots,
pm2 cluster, supervisord numprocs/events. Evaluated against mandor v0.7
(everything through start_after + persistent history) and the product rules:
<500 KB, near-zero idle, minimal config surface, offline free tier, premium
LLM auto-fix.*

## Survey takeaways

- **Give-up semantics are universal.** sysvinit "respawning too fast:
  disabled for 5 minutes", OpenRC `--respawn-max`
  (https://www.mankier.com/8/supervise-daemon), pm2 `max_restarts`+`min_uptime`
  (https://pm2.keymetrics.io/docs/usage/restart-strategies/), circus flapping
  plugin, s6 finish-script exit 125
  (https://skarnet.org/software/s6/s6-supervise.html), launchd
  `ThrottleInterval`. mandor retries forever — inside a container that *hides*
  failure from the orchestrator (the classic supervisord complaint —
  https://ahmet.im/blog/minimal-init-process-for-containers/).
- **Oneshot-before-longrun is the most re-invented feature in the space:**
  s6-overlay `cont-init.d` (https://github.com/just-containers/s6-overlay),
  compose `service_completed_successfully`
  (https://docs.docker.com/compose/how-tos/startup-order/), k8s
  initContainers, systemd `ExecStartPre`.
- **Startup grace periods exist because health checks kill slow starters** —
  k8s invented `startupProbe` for exactly this
  (https://kubernetes.io/docs/concepts/workloads/pods/probes/).
- **Privilege drop is a supervisor job in shell-less images** — no `su`/`gosu`
  in scratch; only PID 1 can do it
  (https://skarnet.org/software/s6/s6-setuidgid.html).
- **Event hooks are the minimal alternative to control planes** — supervisord
  eventlisteners (https://supervisord.org/events.html), monit `exec`; the
  fork/exec hook is the 1%-cost 80%-value version of both.
- **Multi-worker-per-container is contested** — k8s says one process per pod,
  but mandor's audience is precisely the compose/VPS/scratch crowd where
  supervisord `numprocs` and pm2 `instances` prove steady demand.

## Ranked Tier 4 candidates

| # | Feature | Cx | Value | Rationale | Demand proof |
|---|---------|----|-------|-----------|--------------|
| 1 | Oneshot init tasks (`oneshot`, gates dependents via `start_after`) | S | ●●●● | Migrations before workers; reuses spawner/expected-exit/ordering; failed migration = perfect LLM-fixable incident | s6-overlay, compose `service_completed_successfully` |
| 2 | `max_restarts` give-up → mandor exits nonzero | XS | ●●●● | Silent flapping becomes a hard failure the orchestrator sees (CrashLoopBackOff); counter already exists | OpenRC respawn-max, pm2, s6 exit-125 |
| 3 | On-incident hook (exec argv + bundle path, no shell) | XS | ●●●● | Offline alerting without networking; push bridge for the premium sidecar | monit exec, supervisord eventlisteners |
| 4 | Health-check `start_period` | XS | ●●●○ | Stops restart-kill loops on slow booters (the k8s startupProbe lesson); de-noises incident data | k8s startupProbe, Docker `start_period` |
| 5 | Per-worker `env` / `cwd` | XS | ●●●○ | No shell in scratch to `cd`/set env; bundles already snapshot both | chpst -e/-C, supervisord `directory=` |
| 6 | Per-worker `user = "uid:gid"` drop (numeric only) | S | ●●●○ | Root PID 1 + non-root workers without gosu; setgroups→setgid→setuid pre-exec | s6-setuidgid, gosu pattern |
| 7 | `replicas = N` scaling (no fd sharing) | S | ●●○○ | Queue workers on compose/VPS; loop over existing spawner | supervisord numprocs, pm2 instances |
| 8 | `oom_score_adj` / `nice` knobs | XS | ●●○○ | Steer the OOM killer toward the sacrificial worker | chpst -n, systemd OOMScoreAdjust |
| 9 | Watchdog heartbeat over readiness fd | S | ●○○○ | Needs app integration; command health checks cover 90% — defer until asked | systemd WatchdogSec |

## Confirmed rejects (added to the standing list)

- **Socket activation** — needs app cooperation (LISTEN_FDS); host-systemd
  territory, near-zero container value.
- **File-watch auto-restart** — dev-laptop workflow (nodemon); prod restarts
  are image rollouts.
- **Control-plane API / pub-sub** (circus zmq, supervisord XML-RPC, pm2
  daemon) — size + attack surface + config sink; state file + report +
  metrics + hook covers observation.
- **Condition DSLs** (god/eye `restart_if mem > 300MB`) — what killed those
  tools' simplicity; opinionated zero-config detectors are the answer.
- **pm2 cluster fd-sharing** — Node-specific; honest version is `replicas`.
- **FDStore state preservation** — orchestrator rolling updates solve it at
  the right layer.
- **launchd KeepAlive conditions / cron scheduling** — orchestrator/cron's
  job; config-surface poison.
- **Per-worker resource limits** — cgroups are the runtime's job; mandor
  observes, never enforces.

## Top-3 design sketches

**Oneshots** — `oneshot = ["./manage migrate"]` style workers run first
through the normal spawner/capture path (ordinary bundles, `cause:
"oneshot-failed"`); nonzero/timeout ⇒ dependents never start, mandor exits
with the oneshot's code. No restart policy.

**Give-up** — `max_restarts = 10` (0 = never, default). "Consecutive" reuses
the backoff-reset uptime rule (pm2 `min_uptime` semantics for free). On
exhaustion: final bundle, stop-grace the rest, exit with the worker's code.

**Hook** — `on_incident = ["/notify", "--room", "ops"]` argv, exec'd after
each bundle write with the bundle path appended + `MANDOR_INCIDENT` env; one
concurrent hook, 30s TERM→KILL, failures logged, never recursive. Premium
sidecar ships as `on_incident = ["/mandor-relay"]`.

**Recommended order:** #2 + #4 (XS hardening) → #1 (biggest product +
premium win) → #3 → #5/#6. Hold #7–#9 until users ask.
