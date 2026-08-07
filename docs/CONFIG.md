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
| `photon = "127.0.0.1:4318"` | — | off | Ship incidents + metrics + lifecycle events to photon as OTLP; fully offline without it. Auth via `PHOTON_TOKEN` env. See "photon telemetry" below |
| `on_incident = "CMD"` | — | off | Exec CMD after each bundle write, bundle path appended |
| `health_interval = "30s"` | — | `30s` | Probe cadence |
| `health_start_period = "10s"` | — | `10s` | Probe failures ignored this long after spawn (until first success) |
| `ready_fd = 5` | — | off | s6-style readiness: workers write a newline to this fd |
| `restart_dependents = true` | — | `false` | OTP `rest_for_one`: a dependency's restart recycles its dependents |
| `env_file = ".env"` | — | off | KEY=VAL file loaded into every worker's environment |
| `psi_mem_pct = 80` | — | off | Incident when container memory pressure (PSI some avg60) sustains above this % |
| `psi_cpu_pct = 90` | — | off | Incident when container CPU pressure sustains above this % |

### photon telemetry (the `photon` key)

Setting `photon = "host:port"` is the single switch that makes mandor speak
OTLP. With it unset, mandor opens no socket and spawns no relay child — the
offline default is unchanged. With it set, the supervisor spawns one long-lived
`mandor relay --daemon` child that owns the socket; the supervision path itself
never touches one. That child ships three things to photon:

- **Incidents** → OTLP logs (`/v1/logs`). Read from the durable incident spool,
  so they are **never dropped** — a bundle that fails to send is retried next
  cycle. Each bundle already carries the flagged log-tail summary and
  deduplicated error signatures, so log *content* reaches photon this way.
- **Per-process + supervisor metrics** → OTLP metrics (`/v1/metrics`). One
  `service.name` per worker (rss / cpu% / open-fds / threads as gauges, restarts
  as a monotonic sum), plus one `service.name="mandor"` self-metric. Sampled on
  the same cadence as the `/proc` sampler (5 s) and delivered over a
  **non-blocking** pipe: best-effort, dropped under backpressure so telemetry
  can never stall supervision.
- **Node / host metrics** → OTLP metrics (`/v1/metrics`). One host-scoped
  resource (`host.name` / `host.id` / `os.type="linux"`) carrying the node totals
  so each worker is visible against its host baseline in photon's Infrastructure
  view. Emitted automatically whenever `photon` is set — there is **no separate
  toggle** (same minimal-surface rule as the rest of telemetry), sampled every
  5 s over the non-blocking, drop-under-backpressure pipe. Metrics shipped:
  `system.cpu.utilization` (`cpu=total` **and one point per core** `cpu=<n>`),
  `system.cpu.logical.count`, `system.cpu.load_average.1m` / `.5m` / `.15m`,
  `system.memory.usage` (`state=used|free`), `system.memory.limit`,
  `system.memory.utilization`, `system.paging.usage` (`state=used|free`, swap;
  emitted only when the host has swap), `system.network.io` (monotonic sum, **per
  interface** `device=<if>` × `direction=receive|transmit`), and
  `system.filesystem.usage` / `system.filesystem.utilization` (**per mount**
  `mountpoint=<mp>`, real filesystems only). Two **mandor-extension** gauges
  (no OTel semantic-convention name): `system.uptime` (seconds) and
  `system.cpu.temperature` (`Cel`; first CPU-temp hwmon chip — `coretemp`,
  `k10temp`, `zenpower`, `cpu_thermal`, `k8temp` — emitted only when present).
  Host identity comes from `/proc/sys/kernel/hostname` and
  `/etc/machine-id` (falling back to `boot_id`, then the literal `unknown`).
- **GPU metrics** (opt-in) → OTLP metrics (`/v1/metrics`). With `[gpu] enabled`,
  the relay daemon shells out to `nvidia-smi` every `[gpu] interval` (default
  15 s) and emits per-GPU `system.gpu.utilization`, `system.gpu.memory.usage`,
  `system.gpu.memory.utilization`, `system.gpu.temperature`, `system.gpu.power`
  (attrs `gpu=<i>`, `gpu.name=<n>`), same host identity as the node metrics.
  Fail-closed: no `nvidia-smi`, any error, or no GPU ⇒ no GPU points and no
  effect on supervision or other telemetry. NVIDIA only; no dynamic linking.
- **Process-lifecycle events** → OTLP logs (`/v1/logs`): `started`, `exited`
  (ok / error / OOM), `restarting` (with backoff), `unhealthy`. Best-effort,
  same pipe.

By default mandor does **not** ship raw per-line worker logs and never ships
traces: it *curates*, so log content travels only inside incident bundles. That
default is opt-out only for logs — set `[worker.NAME] stream = true` (see below)
on the specific workers whose stdout/stderr firehose you want streamed to photon's
`/v1/logs`. Traces are
never shipped either way. The other telemetry behaviours (metrics on when
`photon` is set, the 5 s sample cadence, the daemon's internal buffer size) are
fixed and intentionally not exposed as separate keys — `photon`, the per-worker
`stream` toggle, plus the small `[logs]` rate cap are the whole telemetry surface,
keeping to the four-CLI-flag / minimal-key rule. `PHOTON_TOKEN` (env, kept off the process cmdline) sets the
bearer token when photon requires auth.

### GPU metrics (the `[gpu]` section)

Off by default. mandor is a static binary, so it collects GPU metrics by shelling
out to `nvidia-smi` rather than linking NVML. The relay daemon samples on its own
timer, off the supervision path, and is silent when `nvidia-smi` is absent.

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `enabled` | bool | `false` | Turn on GPU sampling (requires `nvidia-smi` on `PATH`) |
| `interval` | duration | `15s` | GPU sample cadence |

### Worker log streaming (per-worker `stream`, plus the `[logs]` rate cap)

Off by default — mandor **curates** (incident bundles + metrics + lifecycle) and
does not ship raw per-line logs. Streaming is selected **per worker**: set
`stream = true` inside a `[worker.NAME]` section to stream that worker's
stdout/stderr lines to photon's `/v1/logs` as OTLP logs (one `service.name` per
worker, the line as the log `body`, stderr/severity flagged). Only the workers you
mark stream; every other worker stays curated. Streaming also requires `photon=`
to be set — with no relay daemon there is nowhere to stream to, so the toggle is
inert on its own. The `[logs]` section now holds only the global `max_rate` cap
that applies across all streaming workers.

This is the **ephemeral, best-effort tier**: streamed lines ride the same
non-blocking pipe as metrics and are **dropped under backpressure** (slow/absent
photon, a full pipe, or the `max_rate` cap) — they are **never spooled** and never
retried, unlike incidents, which are durable. Streaming never blocks or slows
supervision; drops are counted internally.

**PII / volume caveat.** Full worker logs can carry secrets, tokens, and personal
data, and a chatty fleet is a lot of egress. This is why streaming is strictly
opt-in and rate-limitable — the operator decides which workers ship the firehose.
Prefer the curated tier (leave `stream` off) unless you specifically need a given
worker's raw logs in photon.

Per-worker toggle (inside a `[worker.NAME]` section):

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `stream` | bool | `false` | Stream this worker's stdout/stderr to photon `/v1/logs` (opt-in; requires `photon=`). Ephemeral/best-effort, never spooled |

Global rate cap (the `[logs]` section):

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `max_rate` | int | `0` | Rate cap in lines/sec across all streaming workers. `0` = unlimited; above it, excess lines in each 1-second window are dropped (counted, never spooled) before a frame is built |

### Deploying mandor as a node monitor

The `system.*` / `system.gpu.*` metrics describe the **node**, read from `/proc`,
`/sys`, `statfs`, and `nvidia-smi`. mandor reports whatever those show: inside a
normal container that is the container's cgroup-scoped view. To report the
**host** (superseding a standalone node agent), run one mandor with the host
mounted in — `/proc`, `/sys`, `/etc/machine-id`, and, for GPU, `/dev/nvidia*`
plus `nvidia-smi` in the image — the node-exporter model. This is additive: the
same binary still supervises its workers.

## Per-worker keys — `[worker.NAME]` sections

Anything specific to one worker lives in a `[worker.NAME]` section, where
`NAME` is the worker's derived name (see above). Unknown sections and unknown
keys inside a section are hard errors — configs are small, so a typo should
stop startup rather than be silently ignored. A name containing a dot can be
quoted so it reads naturally: `[worker."start.sh"]`. Use the `name` key inside a
section to override that derived name everywhere it surfaces.

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
| `name` | string | Override the display/telemetry name (log prefix, `report`, Prometheus label, incident `service.name`). The section is still keyed by the derived basename; the override replaces it everywhere. Empty, too long (>28 bytes), or all-invalid overrides are rejected; collisions dedup (`-2`) like basenames |

`oneshot` defaults to `false`; `essential` defaults to **`true`**, so the
value you write is the one that differs from the default.

**Why `expected_exit` is per-worker but `max_restarts` is not.** `expected_exit`
*describes the worker* — "exit 3 means success for this program" is a property
of the binary. `max_restarts` is a *policy decision* — "how hard should the
supervisor try" is a property of the deployment. Descriptions belong to the
worker; policy belongs to the fleet.

## App-shared secrets — `[secret.NAME]` sections

mandor can mint a per-session secret at boot and hand it only to the workers you
name, over a private inherited pipe fd — never in any process's environment
value, argv, or on disk. This replaces the "generate a value and drop it on a
shared file" pattern. `[secret.*]` is **TOML-only** (the everyday CLI stays at
four flags), and it requires workers **defined in the config file** — a secret
grants to workers by name, so those workers must exist in `workers = [...]`.

```toml
workers = ["./gateway", "./proxy", "./cron"]

[secret.integration]
workers = ["gateway", "proxy"]   # both receive the SAME value

[secret.otp]
workers = ["gateway"]
bytes   = 6
format  = "b10"                  # a 6-digit numeric code
env     = "APP_OTP_FD"           # blend in with your own config vars
```

| Key | Type | Default | Meaning |
|---|---|---|---|
| `workers` | string list | — (**required**) | Which workers receive this secret. Every name must be a defined worker; an empty list is an error |
| `bytes` | int | `32` | Length knob. Range **1–4096**; out of range is an error. Entropy bytes for every format **except `b10`, where it is the digit count** |
| `format` | string | `"hex"` | One of `hex` \| `b10` \| `b32` \| `b64` \| `b64url` \| `raw`. Unknown is an error |
| `env` | string | `CONFD_<NAME>` | The env var mandor sets to this secret's **fd number** (never the value). `<NAME>` uppercased with `-`→`_` (`db-signing` → `CONFD_DB_SIGNING`). Override to blend with your app's own env. Validated `^[A-Z_][A-Z0-9_]*$`; two secrets resolving to the same env var is an error |

**Formats.** `hex` (lowercase, 2 chars/byte), `b32` (RFC 4648, uppercase, no
padding), `b64` (RFC 4648 §4, `=` padded), `b64url` (RFC 4648 §5, URL-safe, no
padding), `b10` (uniform decimal digits, `bytes` = digit count), `raw` (the raw
bytes, no newline). Printable formats arrive as one `\n`-terminated line; `raw`
is the bytes then EOF.

**Deny-by-default is structural.** A secret's `workers` list *is* its access
grant. Each worker receives an fd (and its `env` var) **only** for the secrets
whose `workers` names it — everything else is denied. The denial is not a
runtime check: the pipe's read end is `O_CLOEXEC` and is un-set (kept open across
`execve`) *only* for granted workers, and mandor closes its own ends after the
fork. An ungranted worker holds no descriptor to the pipe at all, and there is no
file/socket/API fallback.

**Lifecycle.** The value is minted once per mandor process (one `getrandom`
draw), held in an `mlock`'d buffer for the session, and **re-delivered on every
(re)spawn** — a restarted worker gets the same value back. It is renewed only on
container restart (a new mandor process), and best-effort zeroed at exit. If
`getrandom` fails at boot, mandor fails closed: it logs and exits **without
spawning any worker** rather than run a fleet missing its secrets.

### Consuming a secret

The env var (`CONFD_<NAME>` by default, or your `env`) holds the **fd number**;
read that fd once at startup, to EOF, and strip a trailing `\n` for printable
formats. An **absent** var means you were not granted the secret — fail rather
than proceed.

**POSIX shell** (`sh`/`dash`/busybox):
```sh
[ -n "$CONFD_S" ] || { echo "not granted the 's' secret" >&2; exit 1; }
secret=$(cat /proc/self/fd/$CONFD_S)
```

**Go:**
```go
fd, _ := strconv.Atoi(os.Getenv("CONFD_S"))
f := os.NewFile(uintptr(fd), "confd")
raw, _ := io.ReadAll(f)                 // read to EOF
secret := strings.TrimRight(string(raw), "\n") // omit TrimRight for format="raw"
```

**TypeScript / Node:**
```ts
const fd = parseInt(process.env.CONFD_S, 10);
const secret = fs.readFileSync(fd).toString("utf8").replace(/\n$/, "");
```

Reading via the fd does **not** put the value in your environ; if you then
`export` it, it re-enters *your* process's environ — avoid that unless you
deliberately ship the value onward.

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
