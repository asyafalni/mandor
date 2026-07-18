# mandor configuration reference

Precedence: **TOML < environment < CLI**. CLI-only always works; `mandor.toml`
is loaded from `--config=PATH` (must exist) or `./mandor.toml` (best-effort).
Per-worker keys use flat `"worker-name=value"` pairs; the worker name is the
basename of the command's first token (duplicates get `-2`, `-3`…).

## Global keys

| Key (TOML) | CLI | Default | Meaning |
|---|---|---|---|
| `workers = ["CMD", …]` | positional args | — | Worker command lines (tokenized by mandor; quotes supported, no shell) |
| `restart = "never\|on-failure\|always"` | `--restart=` | `never` | Global restart policy |
| `backoff_max = "30s"` | `--backoff-max=` | `30s` | Exponential backoff cap (initial 200ms, ×2, reset after 10s stable uptime) |
| `max_restarts = 10` | `--max-restarts=` | `0` (never) | Consecutive failed restarts before mandor gives up and exits with the worker's code |
| `stop_grace = "10s"` | `--stop-grace=` | `10s` | TERM→KILL escalation window on shutdown |
| `expected_exit = "143,129"` | `--expected-exit=` | none | Exit codes treated exactly like 0 (policy, incidents, propagation) |
| `state_dir = "/path"` | `--state-dir=` / `MANDOR_STATE_DIR` | `/var/lib/mandor` | State file + incident spool + history |
| `metrics_port = 9464` | `--metrics=` | off | Prometheus text endpoint on 127.0.0.1 |
| `photon = "127.0.0.1:4318"` | `--photon=` | off | Auto-forward incidents to photon (OTLP); offline without it. Auth via `PHOTON_TOKEN` env |
| `on_incident = "CMD"` | `--on-incident=` | off | Exec CMD after each bundle write, bundle path appended |
| `health_interval = "30s"` | `--health-interval=` | `30s` | Probe cadence |
| `health_start_period = "10s"` | `--health-start-period=` | `10s` | Probe failures ignored this long after spawn (until first success) |
| `restart_on_unhealthy = true` | `--restart-on-unhealthy` | `false` | SIGTERM a worker after 3 consecutive failed probes |
| `ready_fd = 5` | `--ready-fd=` | off | s6-style readiness: workers write a newline to this fd |
| `restart_dependents = true` | — | `false` | OTP `rest_for_one`: a dependency's restart recycles its dependents |
| `env_file = ".env"` | — | off | KEY=VAL file loaded into every worker's environment |

## Per-worker keys (arrays of `"name=value"`)

| Key | Example | Meaning |
|---|---|---|
| `health` | `["api=/bin/check --fast"]` | Liveness probe command (exit 0 = healthy; also `--health=` on CLI, repeatable) |
| `start_after` | `["worker=api"]` | Start `worker` once `api` is up (ready, or alive 1s); dead dependencies unblock |
| `oneshot` | `["migrate"]` (names) | Init task: runs first, gates all regular workers; failure aborts startup with its code |
| `essential` | `["api"]` (names) | Leader: its permanent exit stops the fleet and propagates its code |
| `env` | `["api=PORT=8080"]` | Extra environment (repeatable per worker) |
| `cwd` | `["api=/srv/app"]` | Working directory |
| `user` | `["api=1000:1000"]` | Privilege drop before exec (numeric uid:gid; fail-closed, exit 126) |
| `oom_score_adj` | `["cache=500"]` | Steer the kernel OOM killer (-1000..1000) |
| `nice` | `["batch=10"]` | Scheduling niceness |
| `max_rss_mb` | `["api=768"]` | Recycle (graceful planned restart) beyond this RSS |
| `max_lifetime` | `["api=12h"]` | Periodic recycle |
| `restart` | `["cron=never"]` | Per-worker override of the global policy |
| `pre_stop` | `["api=/bin/drain"]` | Drain command on graceful shutdown; TERM follows its completion |

## Signals & exit codes

TERM/INT: graceful shutdown (forwarded to process groups, `pre_stop` hooks
first, second signal or `stop_grace` expiry ⇒ KILL). HUP/QUIT/USR1/USR2/WINCH:
passed through. Exit code = worst worker code (128+N for signals), the
give-up/essential/oneshot worker's code when those trigger, honoring
`expected_exit`.

## Subcommands

- `mandor report [NAME|PID] [--json]` — live state (name/pid filter optional).
- `mandor report --incidents [NAME] [--since=DUR]` — crash history from the
  spool (kept to the newest 200 bundles), numbered oldest-first.
- `mandor report --incident=N` — dump bundle N as raw JSON (pipe to `jq`).
- `mandor validate [--config=PATH]` — apply the full config to the worker
  table without spawning anything; exit 0 = sound, non-zero on bad values,
  cycles, or unknown worker references (typo detection).
- Durations everywhere: `500ms`, `30s`, `2m`, `12h` (integers only).

## Conventions read from the environment

`MANDOR_RELEASE` / `GIT_SHA` (release id in bundles), `MANDOR_STATE_DIR`,
`PHOTON_TOKEN` (relay bearer auth). `/dev/termination-log`, when present
(Kubernetes), receives the latest incident verdict automatically.
