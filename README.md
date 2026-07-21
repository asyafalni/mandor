# mandor

<p align="center">
  <img src="docs/mandor-logo.webp" alt="mandor logo" width="140">
</p>

> **the foreman for your containers** — a tiny PID-1 process supervisor that
> watches your workers, captures their logs, and tells you *why* they died.

[![Zig 0.16.0](https://img.shields.io/badge/zig-0.16.0-f7a41d?logo=zig&logoColor=white)](https://ziglang.org/download/#release-0.16.0)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Static binary](https://img.shields.io/badge/binary-static%2C%20~268KB-success)
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
| Size | **~268 KB** | ~50 KB | MBs + runtime |
| Network access required | **never** | never | varies |

The `mandor` binary is fully offline and self-contained: no accounts, no
phoning home. Incident bundles are plain JSON on disk — yours to ignore, ship,
or feed to tooling. Repeated log lines are deduplicated (`"repeat": 47`,
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
mandor --max-restarts=3 --backoff-max=30s -- "./api" "./worker"

# what happened while I was away?
mandor report            # live worker status
mandor report --incidents  # crash history with diagnosis verdicts
mandor report --cost     # per-worker resource cost + right-sizing suggestions
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
file values; `MANDOR_STATE_DIR` overrides the file's `state_dir`.

Global settings sit at the top; anything specific to one worker goes in a
`[worker.NAME]` section, where `NAME` is the basename of its command.

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
└── spool          incident bundles → /var/lib/mandor/incidents/*.json
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

**1.0** — stable. The incident-bundle schema is a versioned contract, the
untrusted-input surface is fuzz-hardened in CI, and every build is soaked
under load to prove the supervisor's own footprint stays flat. Version
history:
[CHANGELOG.md](CHANGELOG.md) · every
config key: [docs/CONFIG.md](docs/CONFIG.md) · planned and
researched-but-parked work: [docs/ROADMAP.md](docs/ROADMAP.md).

## Sister project: photon

[photon](https://github.com/nevindra/photon) is an OTEL-native single-binary
observability platform — and mandor's natural display layer: worker metrics
via the Prometheus endpoint, worker logs via stdout collection, and incident
bundles via the upcoming `on_incident` hook. Integration contract:
[docs/INTEGRATION-PHOTON.md](docs/INTEGRATION-PHOTON.md).

## Contributing

Issues and PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for build,
test, and the ground rules (size budget, offline-by-default, simplicity).
Working config recipes live in [examples/](examples/).

## License

[MIT](LICENSE)
