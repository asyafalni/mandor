# mandor configuration reference

Precedence: **TOML < environment < CLI**. The CLI carries only
`--max-restarts`, `--config`, `--metrics` and `--state-dir`; every other
setting is a TOML key, so the command line stays readable. CLI-only always works; `mandor.toml`
is loaded from `--config=PATH` (must exist) or `./mandor.toml` (best-effort).
Per-worker settings live in `[worker.NAME]` sections (see below). The worker
name is the basename of the command's first token (duplicates get `-2`,
`-3`…). Quotes, backslashes, and control characters in a name become `_`, so
names stay safe in the Prometheus exposition format.

## Global keys

| Key (TOML) | CLI | Default | Meaning |
|---|---|---|---|
| `workers = ["CMD", …]` | positional args | — | Worker command lines (tokenized by mandor; quotes supported, no shell) |
| `backoff_max = "30s"` | — | `30s` | Exponential backoff cap (initial 200ms, ×2, reset after 10s stable uptime) |
| `max_restarts = 3` | `--max-restarts=` | `0` | Retries for a **failed** worker. `0` = none (a failure ends the run), `-1` = forever. Clean exits are never retried |
| `stop_grace = "10s"` | — | `10s` | TERM→KILL escalation window on shutdown |
| `expected_exit = "143,129"` | — | none | Exit codes treated exactly like 0. Overridable per worker |
| `state_dir = "/path"` | `--state-dir=` / `MANDOR_STATE_DIR` | `/var/lib/mandor` | State file + incident spool + history |
| `metrics_port = 9464` | `--metrics=` | off | Prometheus text endpoint on 127.0.0.1 |
| `photon = "127.0.0.1:4318"` | — | off | Auto-forward incidents to photon (OTLP); offline without it. Auth via `PHOTON_TOKEN` env |
| `on_incident = "CMD"` | — | off | Exec CMD after each bundle write, bundle path appended |
| `health_interval = "30s"` | — | `30s` | Probe cadence |
| `health_start_period = "10s"` | — | `10s` | Probe failures ignored this long after spawn (until first success) |
| `ready_fd = 5` | — | off | s6-style readiness: workers write a newline to this fd |
| `restart_dependents = true` | — | `false` | OTP `rest_for_one`: a dependency's restart recycles its dependents |
| `env_file = ".env"` | — | off | KEY=VAL file loaded into every worker's environment |
| `psi_mem_pct = 80` | — | off | Incident when container memory pressure (PSI some avg60) sustains above this % |
| `psi_cpu_pct = 90` | — | off | Incident when container CPU pressure sustains above this % |

## Per-worker keys — `[worker.NAME]` sections

Anything specific to one worker lives in a `[worker.NAME]` section, where
`NAME` is the worker's derived name (see above). Unknown sections and unknown
keys inside a section are hard errors — configs are small, so a typo should
stop startup rather than be silently ignored.

```toml
workers = ["./migrate", "./api --port 8080", "./worker", "./metrics-shipper"]

[worker.migrate]
oneshot = true

[worker.api]
env = ["PORT=8080", "LOG_LEVEL=info"]
cwd = "/srv/app"
health = "/bin/check --fast"

[worker.worker]
start_after = "api"

[worker.metrics-shipper]
essential = false   # a sidecar: its death should not take the app down
```

| Key | Type | Meaning |
|---|---|---|
| `health` | string | Liveness probe command (exit 0 = healthy; also `--health=NAME=CMD` on CLI, repeatable) |
| `start_after` | string | Start this worker once the named one is up (ready, or alive 1s); dead dependencies unblock |
| `oneshot` | bool | Init task: runs first, gates all regular workers; failure aborts startup with its code. Never retried, and `essential` is rejected on it |
| `essential` | bool | **Default `true`.** A failure that exhausts retries stops the fleet and propagates its code. Set `false` for a sidecar whose death should not end the run |
| `env` | array of `"KEY=VALUE"` | Extra environment. `KEY=VALUE` matches `execve`, `.env`, `docker -e`, and the lines `env_file` reads |
| `cwd` | string | Working directory |
| `user` | string | Privilege drop before exec (numeric `uid:gid`; fail-closed, exit 126) |
| `cap_drop` | string | `"NET_RAW,SYS_ADMIN"` or `"all"` — drop Linux capabilities from the bounding set; sets `no_new_privs` when a uid is also dropped |
| `oom_score_adj` | int | Steer the kernel OOM killer (-1000..1000) |
| `nice` | int | Scheduling niceness |
| `max_rss_mb` | int | Recycle (graceful planned restart) beyond this RSS |
| `max_lifetime` | duration string | Periodic recycle |
| `expected_exit` | string | Exit codes that mean success **for this worker only** — e.g. `"3"` for a job that reports "nothing to do". Replaces the global set |
| `pre_stop` | string | Drain command on graceful shutdown; TERM follows its completion |

`oneshot` defaults to `false`; `essential` defaults to **`true`**, so the
value you write is the one that differs from the default.

**Why `expected_exit` is per-worker but `max_restarts` is not.** `expected_exit`
*describes the worker* — "exit 3 means success for this program" is a property
of the binary. `max_restarts` is a *policy decision* — "how hard should the
supervisor try" is a property of the deployment. Descriptions belong to the
worker; policy belongs to the fleet.

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
- `mandor report --cost [--json]` — per-worker resource cost (idle/typical/peak
  RSS+CPU, GB-hours, core-seconds, duty %) with right-sizing suggestions.
  Profiling is automatic and zero-config; the profile persists in
  `<state-dir>/cost.json` and accumulates across worker restarts.
- `mandor validate [--config=PATH]` — apply the full config to the worker
  table without spawning anything; exit 0 = sound, non-zero on bad values,
  cycles, or unknown worker references (typo detection).
- Durations everywhere: `500ms`, `30s`, `2m`, `12h` (integers only).

## Conventions read from the environment

`MANDOR_RELEASE` / `GIT_SHA` (release id in bundles), `MANDOR_STATE_DIR`,
`PHOTON_TOKEN` (relay bearer auth). `/dev/termination-log`, when present
(Kubernetes), receives the latest incident verdict automatically.

Set `MANDOR_RELEASE` (or `GIT_SHA`) at build time to unlock **release
correlation**: mandor remembers which builds each crash signature appeared on,
so `mandor report --incidents` flags a crash that survived a code change as
`[REGRESSED v1.0.0->v1.0.1]` and the bundle's `history` object carries
`builds` / `first_build` / `last_build` / `regressed`. It answers "did the
last fix hold?". Without a release wired the feature is simply absent — no
configuration, no behavior change.
