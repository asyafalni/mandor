# mandor configuration reference

Precedence: **CLI > ENV > TOML > default**. The CLI carries only
`--max-restarts`, `--config`, `--metrics` and `--state-dir`; every other
setting is a TOML key, so the command line stays readable. CLI-only always works; `mandor.toml`
is loaded from `--config=PATH` (must exist) or `./mandor.toml` (best-effort).
Only four deploy-varying keys are env-settable — `photon` (`PHOTON_OTLP_HTTP_ENDPOINT`),
the relay bearer token (`PHOTON_OTLP_TOKEN`), `service_prefix`
(`MANDOR_SERVICE_PREFIX`), and `state_dir` (`MANDOR_STATE_DIR`) — each marked
below; ENV overrides a TOML value for those four, and CLI (where a flag
exists) overrides ENV. Everything else is TOML/CLI only.
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
| `state_dir = "/path"` | `--state-dir=` / `MANDOR_STATE_DIR` | `/var/lib/mandor` | State file + incident spool + history |
| `metrics_port = 9464` | `--metrics=` | off | Prometheus text endpoint on 127.0.0.1 |
| `photon = "127.0.0.1:4318"` | — / `PHOTON_OTLP_HTTP_ENDPOINT` | off | Ship incidents + metrics + lifecycle events to photon as OTLP; fully offline without it. `PHOTON_OTLP_HTTP_ENDPOINT` overrides the TOML value — a full URL or a bare `host:port`, mandor strips the scheme either way. Auth via `PHOTON_OTLP_TOKEN` env. See "photon telemetry" below |
| `service_prefix = "tenant-a-"` | — / `MANDOR_SERVICE_PREFIX` | `""` | Origin/tenant tag prepended to `service.name` on **every** OTLP emission (metrics, incidents, lifecycle, streamed logs, the digest), so several mandor origins can share one multi-tenant photon without `service.name` colliding. Telemetry-only — the bare worker name is unchanged in the log `[name]` prefix, `report`, and Prometheus labels; `host.id` still distinguishes hosts. Default `""` = unchanged; inert without `photon=` |
| `on_incident = "CMD"` | — | off | Exec CMD after each bundle write, bundle path appended |
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
- **GPU metrics** (auto-detected) → OTLP metrics (`/v1/metrics`). The relay
  daemon probes for a GPU once at startup (no enable toggle — see
  "GPU metrics" below) and, if one is present, shells out to `nvidia-smi`
  every `gpu_interval` (default 15 s) and emits per-GPU
  `system.gpu.utilization`, `system.gpu.memory.usage`,
  `system.gpu.memory.utilization`, `system.gpu.temperature`, `system.gpu.power`
  (attrs `gpu=<i>`, `gpu.name=<n>`), same host identity as the node metrics.
  Fail-closed: no GPU found at the startup probe ⇒ no GPU points, logged once,
  and no effect on supervision or other telemetry.
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
keeping to the four-CLI-flag / minimal-key rule. `PHOTON_OTLP_TOKEN` (env, kept
off the process cmdline; the bearer var's name changed in v1.12) sets the
bearer token when photon requires auth.

### GPU metrics (the `gpu_interval` key)

Auto-detected, not a toggle: the relay daemon probes for a GPU once at
startup (no re-probe — a GPU appearing later needs a restart) and samples it
only if present, off the supervision path. mandor is a static binary, so it
collects GPU metrics by shelling out to `nvidia-smi` rather than linking
NVML. GPU sampling is on automatically when a device is found, and silent
(logged once) when it isn't — there is no enable/disable toggle. The one
tunable is the sample cadence, a **global** key (the old `[gpu]` section was
flattened to it in v1.14; an old `[gpu]` section now gives a migration error):

| Key (global) | Type | Default | Meaning |
| --- | --- | --- | --- |
| `gpu_interval` | duration | `15s` | GPU sample cadence (the 15 s default suits most cases) |

### The three-tier log → photon model

There are three ways worker log signal reaches photon, in increasing volume and
decreasing curation. **All three are gated by `photon=`** — with no `photon` key
mandor opens no socket, spawns no relay child, and ships no digest, so the
offline-by-default guarantee is absolute.

- **Tier 1 — Incidents (durable, always on).** Crash / OOM / unhealthy /
  restart-loop / leak bundles → OTLP `/v1/logs`, read from the durable spool and
  **retried, never dropped**. Each bundle already carries the flagged log-tail
  and deduplicated error signatures, so this is how log *content* normally
  reaches photon.
- **Tier 2 — Curated warn/error digest (NEW; default ON when `photon=` is set).**
  A healthy worker that only *logs* warnings and errors produces no incident, so
  mandor would otherwise stay silent about real trouble. This tier deduplicates
  warn/error-flagged capture lines by signature into a bounded per-run table and
  periodically ships a compact digest — **one OTLP `/v1/logs` record per
  signature**: body = a sample line, severity = warn/error, attributes
  `mandor.count` / `mandor.first_ts` / `mandor.last_ts`, `service.name` = worker.
  Flushed every `digest_interval` (default 30s), **early** when any one
  signature's count crosses `digest_threshold` (default 100), and once at
  shutdown. **Flood-proof by construction:** a million identical
  `ERROR db timeout` lines collapse to ONE record with `count=1000000`, sent once
  per window — never a per-line firehose. This is the "tell me about warnings and
  errors even without a crash" signal: **curated, not real-time.** Turn it off
  with `[logs] digest = false`; tune it with `digest_interval` /
  `digest_threshold`.
- **Tier 3 — Full per-worker streaming (opt-in firehose).** `[worker.NAME]
  stream = true` streams *every* stdout/stderr line of that worker to
  `/v1/logs`. Ephemeral, best-effort, **dropped under backpressure** (including
  automatic shedding when the daemon falls behind), never spooled, capped by
  `[logs] max_rate`. Use it for the specific workers whose raw firehose you need;
  leave it off and Tier 2 still surfaces their errors.

The default curated signal is Tier 2 (plus Tier 1 on a real incident). Tier 3 is
the opt-in exception, per worker.

Curated warn/error digest (the `[logs] digest*` keys):

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `digest` | bool | `true` | The curated Tier-2 warn/error digest, **on by default when `photon=` is set**. Dedups flagged capture lines by signature and ships one OTLP `/v1/logs` record per signature. `false` disables it |
| `digest_interval` | duration | `30s` | Flush cadence — the digest table is emitted and reset on this timer |
| `digest_threshold` | int | `100` | Early-flush the whole table as soon as any one signature's count crosses this within a window (`0` = timer only) |

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
`NAME` is the worker's derived name (see above). An unknown *key* inside a
section is a hard error, and a bad *value* stops startup — configs are small, so
those typos should fail loudly rather than be silently ignored. A section whose
`NAME` matches no worker in the active set is **not** an error, though — it is a
name-keyed overlay for a worker that simply wasn't spawned this run (a one-line
warning, see "Workers: CLI vs config" below). A name containing a dot can be
quoted so it reads naturally: `[worker."start.sh"]`. Use the `name` key inside a
section to override that derived name everywhere it surfaces.

### Workers: CLI vs config

**The active worker set is whatever the CLI spawns** — the `--` command lines —
or, when the CLI gives none, the TOML `workers = [...]` (the CLI set wins when
both are present). Everything else in the TOML — every `[worker.NAME]` section
and every `[secret.*]` grant — is a **name-keyed overlay** applied to whichever
of those workers actually launched:

- **spawned worker ∩ has a section** → the section's `name` / `stream` / etc. apply.
- **section for a worker not spawned this run** → ignored (a one-line warning), never an error. *The TOML never spawns anything.*
- **spawned worker with no section** → runs on defaults (basename as name, no stream).

The command line is **CLI-only** — there is no `command`/`args` TOML key. This
lets one *static, never-rewritten* `mandor.toml` describe a **superset** of
every worker a deployment might run, while each container start selects its
subset (with per-deploy params) on the CLI:

```bash
mandor --config=/etc/mandor.toml -- ./gateway ./proxy [./pmtiles] [./visionaire-hub]
```

`mandor validate --config=X -- <cmds>` validates the overlay against exactly
`<cmds>`, so the same static TOML validates cleanly against any CLI subset.

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
| `health` | string | Liveness probe command (exit 0 = healthy) |
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
| `expected_exit` | string | Exit codes that mean success for this worker — e.g. `"3"` for a job that reports "nothing to do". Default: only `0`. Per-worker only (v1.14) |
| `health_interval` | duration string | Cadence of this worker's health probe. Default `30s`. Per-worker only (v1.14) |
| `health_start_period` | duration string | Grace after (re)spawn during which probe failures don't count, until the first success (the k8s startupProbe lesson). Default `10s`. Per-worker only (v1.14) |
| `pre_stop` | string | Drain command on graceful shutdown; TERM follows its completion |
| `name` | string | Override the display/telemetry name (log prefix, `report`, Prometheus label, incident `service.name`). The section is still keyed by the derived basename; the override replaces it everywhere. Empty, too long (>28 bytes), or all-invalid overrides are rejected; collisions dedup (`-2`) like basenames |

`oneshot` defaults to `false`; `essential` defaults to **`true`**, so the
value you write is the one that differs from the default.

**Why these are per-worker but `max_restarts` is not.** `expected_exit`,
`health_interval`, and `health_start_period` all *describe the worker* — "exit 3
means success for this program", "this binary takes 45s to warm up" are
properties of the binary. `max_restarts` (and `backoff_max`) are *policy
decisions* — "how hard should the supervisor try" is a property of the
deployment. Descriptions belong to the worker; policy belongs to the fleet.
(v1.14 moved the three descriptive keys from global to per-worker only; a
top-level `expected_exit` / `health_interval` / `health_start_period` now gives
a migration error pointing you into a `[worker.NAME]` section.)

## App-shared secrets — `[secret.NAME]` sections

mandor can mint a per-session secret at boot and hand it only to the workers you
name, over a private inherited pipe fd — never in any process's environment
value, argv, or on disk. This replaces the "generate a value and drop it on a
shared file" pattern. `[secret.*]` is **TOML-only** (the everyday CLI stays at
four flags). A grant is name-keyed like every other overlay (see "Workers: CLI
vs config"): it resolves against the **active worker set** — the CLI `--` args,
else `workers = [...]` — and delivers to the *present* listed subset. A listed
worker that wasn't spawned this run is simply not granted; a grant with no
present recipient is **inert** (minted for nobody, a one-line warning), never an
error. So a static superset TOML can grant to workers that only some deployments
launch. Deny-by-default holds exactly: a worker only ever receives a secret it
is explicitly listed for.

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
| `workers` | string list | — (**required**) | Which workers receive this secret, by name. Names not in the active worker set are skipped; if none are present (including an empty list) the secret is inert, not an error |
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

## Boot preconditions — `[require.NAME]` sections

A `[require.NAME]` runs a command **before any worker (or oneshot) spawns**; a
non-zero exit **aborts the boot** — mandor logs `requirement '<name>' not met`
and exits non-zero, so the container runtime's restart policy decides what
happens (mandor never reboots the host). All requires must pass, in order.

The `check` is an **opaque command** — it's where a GPU/driver/hardware
requirement lives (`nvidia-smi`, `rocm-smi`, `xpu-smi`, …); mandor runs no
vendor code and does no version parsing itself. Any wait/retry (e.g. "wait 30s
for the driver") belongs inside the check script.

```toml
[require.gpu-driver]
check   = "/opt/checks/gpu-require.sh --driver-min 525"   # your script calls nvidia-smi etc.
timeout = "60s"                                           # optional; default 60s
```

| Key | Type | Default | Meaning |
|---|---|---|---|
| `check` | string | — (**required**) | Command to run; exit 0 = requirement met |
| `timeout` | duration | `60s` | A check that runs longer is SIGKILLed and counts as a failure |

`mandor validate` reports the requires but never executes them (validate never
spawns). Fail-closed: a tokenize/exec error or timeout is a failure.

## Status probers — `[prober.NAME]` sections

A `[prober.NAME]` runs a command **on a timer** once the fleet is up and
**reports** the result. mandor owns the interval, so the check stays a simple
"check once, exit" command instead of a hand-written `while true; sleep` loop.

A prober **never restarts, kills, or gates a worker** — `health` is the sole
restart authority. If a check should trigger a restart, put it in the worker's
`health` command instead. Use a prober for monitoring that should *report*, not
act (e.g. a pipeline/license status check).

```toml
[prober.pipeline-status]
check    = "/opt/checks/pipeline-status.sh"   # simple check-once script
interval = "2m"                               # required
on_fail  = "report"                           # "report" (default) | "incident"
timeout  = "10s"                              # optional; default 10s
# fail_threshold = 1                          # optional; consecutive fails before on_fail
```

| Key | Type | Default | Meaning |
|---|---|---|---|
| `check` | string | — (**required**) | Command to run on the timer; exit 0 = healthy |
| `interval` | duration | — (**required**) | How often to run the check (must be > 0) |
| `on_fail` | string | `report` | `report` → an OTLP log to photon + a local warn line; `incident` → that plus a spooled incident bundle (cooldown-guarded) |
| `timeout` | duration | `10s` | A check running longer is SIGKILLed and counts as a failure |
| `fail_threshold` | int ≥ 1 | `1` | Consecutive failures before `on_fail` fires |

Like all telemetry, a prober's `report`/`incident` output ships to photon only
when `photon=` is set; the local log line prints regardless.

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
- `mandor validate [--config=PATH] [-- <cmds>]` — apply the full config to the
  active worker set (the `-- <cmds>`, else the TOML `workers=`) without spawning
  anything; exit 0 = sound, non-zero on bad values, dependency cycles, or an
  env-var collision. A `[worker.NAME]`/`[secret.*]` reference to a worker not in
  the set is a tolerated warning, not a failure — so a superset TOML validates
  against any CLI subset.
- Durations everywhere: `500ms`, `30s`, `2m`, `12h` (integers only).

## Conventions read from the environment

`MANDOR_RELEASE` / `GIT_SHA` (release id in bundles); the four deploy-varying
config keys — `MANDOR_STATE_DIR`, `PHOTON_OTLP_HTTP_ENDPOINT`,
`PHOTON_OTLP_TOKEN` (relay bearer auth, renamed in v1.12),
`MANDOR_SERVICE_PREFIX` — override their TOML equivalents (see "Precedence"
above). `/dev/termination-log`, when present (Kubernetes), receives the
latest incident verdict automatically.

Set `MANDOR_RELEASE` (or `GIT_SHA`) at build time to unlock **release
correlation**: mandor remembers which builds each crash signature appeared on,
so `mandor report --incidents` flags a crash that survived a code change as
`[REGRESSED v1.0.0->v1.0.1]` and the bundle's `history` object carries
`builds` / `first_build` / `last_build` / `regressed`. It answers "did the
last fix hold?". Without a release wired the feature is simply absent — no
configuration, no behavior change.
