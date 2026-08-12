# mandor

<p align="center">
  <img src="docs/mandor-logo.webp" alt="mandor logo" width="140">
</p>

> **the foreman for your containers** — a tiny PID-1 process supervisor that
> watches your workers, captures their logs, and tells you *why* they died.

[![Zig 0.16.0](https://img.shields.io/badge/zig-0.16.0-f7a41d?logo=zig&logoColor=white)](https://ziglang.org/download/#release-0.16.0)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Static binary](https://img.shields.io/badge/binary-static%2C%20~359KB-success)
![No dependencies](https://img.shields.io/badge/dependencies-zero-success)

*Mandor* (Indonesian): the site foreman — the one who supervises the workers.

Run several processes in one container without an init system, a shell, or a
supervisor daemon that outweighs your app. `mandor` is a single static binary
that runs as PID 1, spawns your workers, forwards signals, reaps zombies,
restarts what crashes — and when something dies, it writes an incident summary
explaining what happened instead of leaving you to scroll logs.

```console
$ mandor --max-restarts=3 -- "./api --port 8080" "./worker" "./cron-loop"
[mandor] spawned api (pid 12)
[mandor] spawned worker (pid 13)
[mandor] spawned cron-loop (pid 14)
```

## Why mandor?

| | `mandor` | multirun | s6 / supervisord |
|---|---|---|---|
| Single static binary | ✅ | ✅ | ❌ |
| Works in `scratch` / distroless | ✅ | ✅ | ❌ |
| Full signal forwarding + process groups (dumb-init parity) | ✅ | partial | ✅ |
| Bounded retries + backoff, then exit so the orchestrator acts | ✅ | ❌ | partial |
| Log capture with per-worker prefix | ✅ | ✅ | ✅ |
| CPU / RSS / fd tracking | ✅ | ❌ | ❌ |
| Crash summaries ("restart loop", "leak suspect") | ✅ | ❌ | ❌ |
| Per-worker cost + right-sizing report | ✅ | ❌ | ❌ |
| Release correlation ("did the fix hold?") | ✅ | ❌ | ❌ |
| OTLP telemetry to an observability backend | ✅ opt-in | ❌ | ❌ |
| Node + GPU host metrics (node-exporter style) | ✅ opt-in | ❌ | ❌ |
| Size | **~359 KB** | ~50 KB | MBs + runtime |
| Network access | **off by default** (opt-in OTLP) | never | varies |

The `mandor` binary is **offline by default** and self-contained: no accounts,
no LLM, and no network at all unless you opt in with the `photon =` key (see
[Observability](#observability-optional)). Incident bundles are plain JSON on
disk — yours to ignore, ship, or feed to tooling. Repeated log lines are
deduplicated (`"repeat": 47`,
digit-insensitive, first/last timestamps kept), so a retry storm costs one
bundle entry instead of thousands of tokens. The upcoming **mandor premium** sidecar picks those same
bundles up and hands them to an AI coding agent that root-causes the crash,
fixes the code, and opens a PR — supervision that closes the loop.

## Quick start

### Install

Grab a package from the [latest release](https://github.com/asyafalni/mandor/releases):

```console
# Debian / Ubuntu
dpkg -i mandor_*_amd64.deb

# Alpine
apk add --allow-untrusted mandor_*_amd64.apk

# or just the raw static binary — it runs on any Linux
curl -LO https://github.com/asyafalni/mandor/releases/latest/download/mandor-x86_64-linux
install -m755 mandor-x86_64-linux /usr/bin/mandor
```

### In a Dockerfile

```dockerfile
FROM scratch
COPY --from=build /app/api /api
COPY --from=build /app/worker /worker
COPY --from=ghcr.io/asyafalni/mandor:latest /mandor /mandor
ENTRYPOINT ["/mandor", "--max-restarts=3", "/api", "/worker"]
```

### On the command line

```console
# run two workers, exit when both exit, propagate the worst exit code
mandor "./api --port 8080" "./worker"

# retry a failed worker 3 times (200ms → 30s backoff), then exit with its code
mandor --max-restarts=3 -- "./api" "./worker"

# what happened while I was away?
mandor report            # live worker status
mandor report --incidents  # crash history with diagnosis verdicts
mandor report --cost     # per-worker resource cost + right-sizing suggestions

# check a config against the workers this run would spawn, without running
mandor validate --config=mandor.toml -- "./api" "./worker"
```

### Flags

Everyday — this is the whole surface most deployments need:

| Flag | Values | Default |
|---|---|---|
| `--max-restarts` | retries for a *failed* worker: `0` = none, `-1` = forever | `0` |
| `--config` | path to `mandor.toml` | `./mandor.toml` if present |
| `--metrics` | port for Prometheus text metrics on 127.0.0.1 | off |
| `--state-dir` | state + incident spool dir (or `MANDOR_STATE_DIR`) | `/var/lib/mandor` |

**That is the entire CLI.** Everything else — liveness probes, drain hooks,
ordering, privilege drops, tuning — is a `mandor.toml` key with a sane default,
so the command line stays something you can read at a glance in a Dockerfile.
Settings that used to have flags kept the same name without the dashes
(`--stop-grace` → `stop_grace`), and passing the old flag tells you so.

### What happens when a worker exits

mandor's whole lifecycle model, in one table:

| The worker… | mandor… |
|---|---|
| exits `0` (or an `expected_exit` code) | leaves it finished; the run continues |
| fails, retries remain | retries it after backoff (200ms, doubling, capped) |
| fails, retries exhausted | **stops the other workers gracefully and exits with its code** |
| fails, but is `essential = false` | leaves it dead; the run continues |
| is a `oneshot` and fails | aborts startup — dependents never start |
| fails its health probe 3× | is stopped, then treated as any other failure |

The default is `max_restarts = 0` — **don't retry, end the run**. That is
deliberate: restarting is the orchestrator's job, and it can only do that job
if mandor exits instead of quietly retrying forever. Set `-1` if you really
want unlimited in-container retries, knowing nothing upstream will be told.

You don't have to remember any of this — mandor prints the resolved plan at
startup, so it shows up in `docker logs` on every deploy:

```console
[mandor] 3 worker(s) | a failed worker retries 3x, then the run ends
[mandor]   migrate: init task — runs first, failure aborts startup
[mandor]   api: health probe — 3 failures stop the worker
[mandor]   metrics: essential=false — its failure will not end the run
```

A config with nothing unusual prints exactly one line.

### Surviving container restarts

Everything durable — live state and the incident archive — lives under one
directory (`/var/lib/mandor`), written atomically. A `docker restart` keeps
it automatically. To survive **new** containers (redeploys, pod
rescheduling), mount a volume there:

```console
docker run -v mandor-state:/var/lib/mandor ... my-image
```

Kubernetes: an `emptyDir` volume survives container restarts within a pod; a
PersistentVolumeClaim survives rescheduling. Then recall history any time:

```console
$ mandor report --incidents
3 incident(s) in /var/lib/mandor/incidents (oldest first)

  # TIME                  WORKER   CAUSE           VERDICT
  1 2026-07-17T13:31:37Z  api      exit:3          exit:3 after 0s uptime
  2 2026-07-17T13:31:38Z  worker   signal:SIGSEGV  go panic in main.crash (main.go:10)
  3 2026-07-18T09:02:11Z  worker   signal:SIGSEGV  go panic in main.crash  [REGRESSED v1.0.0->v1.0.1]
```

Set `MANDOR_RELEASE` (or `GIT_SHA`) at build time and mandor tracks which
builds each crash appeared on — a crash that survives a code change is flagged
`[REGRESSED …]`, answering "did the last fix hold?". The spool keeps the newest
200 incidents and prunes older ones, so a persistent volume never fills up.

### Shift report

When mandor shuts down it prints one summary of the whole run to stdout — so
`kubectl logs` (or an AI post-mortem) shows what happened over the container's
life without opening a single incident file. Always on, no configuration:

```console
[mandor] shift report — 2 worker(s), 3600s run, 3 restart(s), 2 incident(s)
[mandor]   api: exit 0, 3 restart(s), peak 812MB, 2.10 GB-h
[mandor]   worker: exit 0, 0 restart(s), peak 96MB, 0.34 GB-h
```

### Configuration file (optional)

CLI-only always works — `mandor.toml` just saves typing. CLI flags override
file values. Four deploy-varying keys also read from the environment, which
overrides the file (`MANDOR_STATE_DIR` for `state_dir`, and as of v1.12
`PHOTON_OTLP_HTTP_ENDPOINT` for `photon`, `PHOTON_OTLP_TOKEN` for the relay
bearer token, `MANDOR_SERVICE_PREFIX` for `service_prefix`) — see
[Config keys](#config-keys). Everything else is TOML/CLI only.

Global settings sit at the top; anything specific to one worker goes in a
`[worker.NAME]` section, where `NAME` is the basename of its command.

The TOML is a **behavior overlay, not the worker list.** The active worker set
is whatever the CLI `--` args spawn (or, if the CLI gives none, the TOML
`workers=`); every `[worker.NAME]` section and `[secret.*]` grant is matched to
that set **by name**. A section for a worker not spawned this run is ignored (a
one-line warning), never an error, and never itself spawns anything — so one
static `mandor.toml` can describe a *superset* of every worker your deploys
might run, and each container start picks its subset (with per-deploy params) on
the CLI. `mandor validate -- <cmds>` validates against exactly those workers.

```toml
max_restarts = 3
metrics_port = 9464
psi_mem_pct = 80               # incident if container memory pressure sustains >80%
env_file = ".env"              # KEY=VAL lines for all workers
on_incident = "/notify"        # exec'd with each incident bundle path
photon = "127.0.0.1:4318"      # auto-forward incidents to photon (OTLP)
workers = [
  "./migrate",
  "./api --port 8080",
  "./worker",
  "./cron",
]

[worker.migrate]
oneshot = true                 # runs first; failure aborts startup

[worker.api]
env = ["PORT=8080", "LOG_LEVEL=info"]
cwd = "/srv/app"
user = "1000:1000"             # drop root before exec (numeric uid:gid)
cap_drop = "all"               # drop Linux capabilities + set no_new_privs
health = "/bin/check-api"
essential = true               # api exiting stops everything (leader)
max_rss_mb = 768               # recycle beyond this RSS (planned, not a failure)
max_lifetime = "12h"           # periodic recycle as a leak crutch

[worker.worker]
start_after = "api"            # starts once api is up (ready or alive 1s)

[worker.cron]
expected_exit = "3"            # exit 3 means success for this worker only
```

Signals (dumb-init parity): every worker runs in its own process group, so
signals reach shell-spawned grandchildren too. `SIGTERM`/`SIGINT` are
forwarded and start graceful shutdown (a second one escalates to `SIGKILL`);
`SIGHUP`, `SIGQUIT`, `SIGUSR1`, `SIGUSR2`, and `SIGWINCH` are passed through
untouched — log rotation and graceful reloads just work. Exit code is the
worst worker exit code (`128+signal` for signal deaths).

## Architecture

```
mandor (PID 1)
├── spawner        fork/exec workers from CLI args
├── reaper         waitpid loop, zombie reaping, exit-cause classification
├── signals        signalfd → forward TERM/INT/HUP, graceful shutdown
├── capture        stdout/stderr → ring buffers, [name] line prefixes
├── sampler        /proc polling: CPU%, RSS, fds, threads
├── detector       nonzero exit, fatal signal, OOM, restart-loop, RSS climb
├── summarize      heuristic verdicts — error dedup, trace parsing, instant
├── spool          incident bundles → /var/lib/mandor/incidents/*.json
├── secret         per-session app secrets → granted workers over pipe fds (opt-in)
└── relay --daemon OTLP telemetry to photon (opt-in, off the hot path): incidents,
                   per-process + node + GPU metrics, lifecycle, opt-in logs
```

Design rules the code lives by:

- **PID 1 must not die.** No panics on the supervision path; every syscall
  error is handled. Worst case: log to stderr and keep supervising.
- **Zero allocations in steady state.** Fixed ring buffers, preallocated
  worker tables, raw syscalls via `std.os.linux` — no libc. CI soaks a live
  supervisor under full-rate log capture, restart churn, and incident writes,
  and fails the build if mandor's own RSS, fd count, or thread count drifts.
  Measured over a 30-minute soak: **~1.1 MB RSS, 10 fds, 1 thread — 4 KB
  drift**.
- **Single thread, one poll loop.** Signals arrive via `signalfd`, not async
  handlers.
- **No dependencies, no regex.** Trace parsing is line-oriented scanning.
- **Untrusted input is fuzzed.** Worker stderr, the worker's ELF header,
  config, `/proc` text, and mandor's own state files all run through a
  mutation-fuzzing harness on every CI build — a parser panic would kill
  PID 1, so arithmetic on untrusted bytes saturates rather than traps.

## Building from source

Requires [Zig 0.16.0](https://ziglang.org/download/#release-0.16.0) exactly
(pinned in `.zigversion`).

```console
zig build                                                  # debug
zig build test                                             # unit tests
zig build -Doptimize=ReleaseSafe                           # release
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe   # container
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe  # arm64
```

Linux-only by design — supervision is built on `signalfd`, `/proc`, and
PID-1 semantics. On other systems the binary compiles for cross-target use.

The binary is libc-free static (raw syscalls, no glibc/musl runtime), so the
same file runs on **Alpine, Debian, Ubuntu, scratch, and distroless** images
unchanged — CI runs the full integration harness on all three distro bases.

## Status

**Stable (1.x).** Core supervision has been stable since 1.0; the 1.7–1.11 line
added opt-in OTLP telemetry, node + GPU host metrics (superseding a standalone
node agent), an app-shared secret store, per-worker log streaming, and a curated
warn/error digest that surfaces an app's own log trouble without a crash — all
gated by `photon=`, none of it on the supervision path. The incident-bundle schema
is a versioned contract, the untrusted-input surface is fuzz-hardened in CI, and every
build is soaked under load to prove the supervisor's own footprint stays flat.
Version history:
[CHANGELOG.md](CHANGELOG.md) · every
config key: [docs/CONFIG.md](docs/CONFIG.md) · planned and
researched-but-parked work: [docs/ROADMAP.md](docs/ROADMAP.md).

## Observability (optional)

mandor is offline by default. Set one key — `photon = "ip:port"` — and it ships
its whole story to [photon](https://github.com/nevindra/photon) (mandor's
OTEL-native sister project) as OTLP, **no collector required**. All network I/O
lives in a single long-lived `mandor relay --daemon` child; the supervision path
never touches a socket, and telemetry is dropped under backpressure before it can
ever stall supervision. Auth via the `PHOTON_OTLP_TOKEN` env var. The endpoint
and token, along with `service_prefix` and `state_dir`, are also settable from
the environment — see [Config keys](#config-keys) below. With `photon` unset,
none of this activates.

What it ships when `photon` is set:

- **Incidents** → OTLP logs (durable: spooled and retried).
- **Per-process + supervisor metrics** → OTLP metrics (one `service.name` per
  worker: cpu/rss/fds/threads + restarts, using OTel semantic conventions).
- **Node / host metrics** → OTLP metrics, sampled by the daemon itself:
  per-core CPU, per-mount filesystem, per-interface network, memory, swap, load
  (1/5/15m), disk I/O, uptime, CPU temperature. Every worker and the node share
  one `host.name`, so photon shows each process against the node it runs on.
- **GPU metrics** (auto-detected — no `[gpu] enabled` toggle; the relay daemon
  probes once at startup) → NVIDIA via `nvidia-smi`, AMD/Intel via DRM sysfs.
  Fail-closed when no GPU is present.
- **Process-lifecycle events** → OTLP logs (started / exited / restarting /
  unhealthy).
- **Curated warn/error digest** (on by default when `photon=` is set) → OTLP logs.
  A worker that is healthy but *logs* warnings and errors produces no incident, so
  mandor deduplicates its warn/error lines by signature into a bounded table and
  ships a compact digest — one record per signature (body = a sample line,
  `mandor.count` / `mandor.first_ts` / `mandor.last_ts`), every `digest_interval`
  (default 30s), early when a signature crosses `digest_threshold`, and at shutdown.
  A million identical `ERROR db timeout` lines collapse to **one** record with
  `count=1000000` — flood-proof, curated, not real-time. Turn off with
  `[logs] digest = false`.
- **Full per-worker log streaming** (opt-in, `[worker.NAME] stream = true`) → OTLP
  logs. The real-time firehose, selected per worker (not global) so a chatty worker
  can stay curated while another streams; rate-limitable via `[logs] max_rate` and
  self-capping under backpressure (drops before encode, never stalls supervision).
  Traces are never shipped.

Multi-tenant photon? Set `service_prefix` to tag `service.name` on every emission
so several mandor origins can share one photon without their worker names
colliding.

### The warn/error digest — telling you about trouble that never crashes

Most log signal never becomes an incident. A service that is *up* but spraying
`ERROR db timeout` a thousand times a minute is in trouble, yet nothing died, so
a crash-only supervisor stays silent — and full log streaming to catch it means
paying a per-line encode+send for a firehose you mostly don't want. The digest is
the middle path: **on by default the moment `photon=` is set**, no streaming
required.

At capture time mandor already flags every warn/error line (by content —
`error`/`warn`/`panic`/`fatal`/`exception`/`traceback` — on stdout *or* stderr).
The digest folds each flagged line into a fixed 64-entry table keyed by its
*signature* (the line with digits stripped, so `conn 17 refused` and
`conn 4021 refused` are the same entry), bumping a count. Every `digest_interval`
(default 30s), early when any one signature crosses `digest_threshold`, and once
at shutdown, it ships the table as OTLP `/v1/logs` — **one record per signature**,
never per line. A distinct-signature flood past the 64 slots collapses into one
`(other)` overflow record, so both memory and CPU are bounded no matter how dirty
the app's logging gets.

```toml
photon = "photon:4318"      # the OTLP ingest port (not photon's web UI)
# digest is on by default; these are the knobs, all optional:
[logs]
digest           = true     # false to turn the whole tier off
digest_interval  = "30s"    # flush cadence
digest_threshold = 100      # early-flush when one signature hits this count
```

What one signature looks like in photon after a burst of identical errors —
1287 lines became a single record carrying the count and the first/last sighting:

```json
{ "service": "api", "severity": "error", "body": "ERROR db timeout",
  "attributes": { "mandor.count": "1287", "log.iostream": "stderr",
                  "mandor.first_ts": "1786119239510000000",
                  "mandor.last_ts":  "1786119271884000000" } }
```

Curated, not real-time — the trade is a bounded delay for a signal that can't be
drowned out by volume. When you *do* need every line, opt a specific worker into
Tier 3 streaming; the digest keeps working for the rest.

Run one mandor with the host `/proc`, `/sys`, `/etc/machine-id` (and
`/dev/nvidia*` for GPU) mounted in and it reports the **host** — node-exporter
style, superseding a standalone node agent — while still supervising its workers.
Full details and the OTLP field mapping: [docs/INTEGRATION-PHOTON.md](docs/INTEGRATION-PHOTON.md);
every config key: [docs/CONFIG.md](docs/CONFIG.md).

A local Prometheus text endpoint (`--metrics=PORT`, 127.0.0.1) is a separate,
always-offline pull option unrelated to the photon push path.

## Config keys

Every key mandor understands, and where you can set it from. Defaults and full
descriptions live in [docs/CONFIG.md](docs/CONFIG.md); this is the map of
TOML/CLI/ENV surface. **ENV overrides TOML (CLI > ENV > TOML > default); only
these four deploy-varying keys are env-settable — the rest is TOML/CLI.**

| Key | TOML | CLI | ENV |
|---|---|---|---|
| `workers` | global | positional args | |
| `backoff_max` | global | — | |
| `max_restarts` | global | `--max-restarts=` | |
| `stop_grace` | global | — | |
| `expected_exit` | global | — | |
| `state_dir` | global | `--state-dir=` | `MANDOR_STATE_DIR` |
| `metrics_port` | global | `--metrics=` | |
| `photon` | global | — | `PHOTON_OTLP_HTTP_ENDPOINT` |
| (relay bearer token) | — | — | `PHOTON_OTLP_TOKEN` |
| `service_prefix` | global | — | `MANDOR_SERVICE_PREFIX` |
| `on_incident` | global | — | |
| `health_interval` | global | — | |
| `health_start_period` | global | — | |
| `ready_fd` | global | — | |
| `restart_dependents` | global | — | |
| `env_file` | global | — | |
| `psi_mem_pct` | global | — | |
| `psi_cpu_pct` | global | — | |
| `interval` | `[gpu]` | — | |
| `digest` | `[logs]` | — | |
| `digest_interval` | `[logs]` | — | |
| `digest_threshold` | `[logs]` | — | |
| `max_rate` | `[logs]` | — | |
| `stream` | `[worker.NAME]` | — | |
| `health` | `[worker.NAME]` | also `--health=NAME=CMD`, repeatable | |
| `start_after` | `[worker.NAME]` | — | |
| `oneshot` | `[worker.NAME]` | — | |
| `essential` | `[worker.NAME]` | — | |
| `env` | `[worker.NAME]` | — | |
| `cwd` | `[worker.NAME]` | — | |
| `user` | `[worker.NAME]` | — | |
| `cap_drop` | `[worker.NAME]` | — | |
| `oom_score_adj` | `[worker.NAME]` | — | |
| `nice` | `[worker.NAME]` | — | |
| `max_rss_mb` | `[worker.NAME]` | — | |
| `max_lifetime` | `[worker.NAME]` | — | |
| `expected_exit` | `[worker.NAME]` | — | |
| `pre_stop` | `[worker.NAME]` | — | |
| `name` | `[worker.NAME]` | — | |
| `workers` | `[secret.NAME]` | — | |
| `bytes` | `[secret.NAME]` | — | |
| `format` | `[secret.NAME]` | — | |
| `env` | `[secret.NAME]` | — | |

GPU metrics are auto-detected (no `[gpu] enabled` toggle) — `[gpu]` now holds
only the sample `interval`.

### App-shared secrets (`[secret.NAME]`)

A `[secret.NAME]` section mints a per-session random secret at boot and hands it
only to the workers you list, over an inherited pipe fd — the env var
(`CONFD_<NAME>`, or an `env=` override) holds the **fd number**, never the value,
so the secret never touches argv, `/proc`, or disk.

```toml
[secret.integration]
workers = ["gateway", "proxy"]   # both receive the SAME per-session value
format  = "b64url"
bytes   = 32
```

Like every overlay, a grant resolves against the active worker set: a listed
worker not spawned this run is skipped, and a grant with no present recipient
(including an explicit `workers = []`) is **inert, not an error**. Deny-by-default
holds — a worker only ever receives a secret it is explicitly listed for — and
the only hard error is two secrets resolving to the same env var name. Full
details in [docs/CONFIG.md](docs/CONFIG.md).

## Contributing

Issues and PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for build,
test, and the ground rules (size budget, offline-by-default, simplicity).
Working config recipes live in [examples/](examples/).

## License

[MIT](LICENSE)
