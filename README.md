# mandor

<p align="center">
  <img src="docs/mandor-logo.webp" alt="mandor logo" width="140">
</p>

> **the foreman for your containers** — a tiny PID-1 process supervisor that
> watches your workers, captures their logs, and tells you *why* they died.

[![Zig 0.16.0](https://img.shields.io/badge/zig-0.16.0-f7a41d?logo=zig&logoColor=white)](https://ziglang.org/download/#release-0.16.0)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Static binary](https://img.shields.io/badge/binary-static%2C%20~210KB-success)
![No dependencies](https://img.shields.io/badge/dependencies-zero-success)

*Mandor* (Indonesian): the site foreman — the one who supervises the workers.

Run several processes in one container without an init system, a shell, or a
supervisor daemon that outweighs your app. `mandor` is a single static binary
that runs as PID 1, spawns your workers, forwards signals, reaps zombies,
restarts what crashes — and when something dies, it writes an incident summary
explaining what happened instead of leaving you to scroll logs.

```console
$ mandor --restart=on-failure -- "./api --port 8080" "./worker" "./cron-loop"
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
| Restart policies + backoff | ✅ | ❌ | ✅ |
| Log capture with per-worker prefix | ✅ | ✅ | ✅ |
| CPU / RSS / fd tracking | ✅ | ❌ | ❌ |
| Crash summaries ("restart loop", "leak suspect") | ✅ | ❌ | ❌ |
| Size | **~210 KB** | ~50 KB | MBs + runtime |
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
ENTRYPOINT ["/mandor", "--restart=on-failure", "/api", "/worker"]
```

### On the command line

```console
# run two workers, exit when both exit, propagate the worst exit code
mandor "./api --port 8080" "./worker"

# restart crashed workers with exponential backoff (200ms → 30s cap)
mandor --restart=on-failure --backoff-max=30s -- "./api" "./worker"

# what happened while I was away?
mandor report            # human summary
mandor report --json     # machine-readable
```

### Flags

Everyday — this is the whole surface most deployments need:

| Flag | Values | Default |
|---|---|---|
| `--restart` | `never` \| `on-failure` \| `always` | `never` |
| `--config` | path to `mandor.toml` | `./mandor.toml` if present |
| `--health` | `NAME=CMD` probe (repeatable; exit 0 = healthy) | none |
| `--metrics` | port for Prometheus text metrics on 127.0.0.1 | off |

<details>
<summary>Advanced flags (sane defaults — most users never touch these)</summary>

| Flag | Values | Default |
|---|---|---|
| `--backoff-max` | restart backoff cap (`500ms`, `30s`, `2m`) | `30s` |
| `--state-dir` | state + incident spool dir (or `MANDOR_STATE_DIR`) | `/var/lib/mandor` |
| `--stop-grace` | TERM→KILL escalation grace period | `10s` |
| `--expected-exit` | extra exit codes treated as success, e.g. `143,129` | none |
| `--health-interval` | probe cadence | `30s` |
| `--restart-on-unhealthy` | SIGTERM a worker after 3 failed probes | off |
| `--ready-fd` | fd workers write a newline to when ready (s6-style) | off |
| `--max-restarts` | consecutive failed restarts before mandor gives up and exits with the worker's code | `0` (never) |
| `--health-start-period` | probe failures ignored this long after spawn (until first success) | `10s` |
| `--on-incident` | command exec'd after each incident bundle write (bundle path appended) | off |

</details>

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
2 incident(s) in /var/lib/mandor/incidents (oldest first)

TIME                  WORKER   CAUSE           VERDICT
2026-07-17T13:31:37Z  api      exit:3          exit:3 after 0s uptime
2026-07-17T13:31:38Z  worker   signal:SIGSEGV  go panic in main.crash (main.go:10)
```

The spool keeps the newest 200 incidents and prunes older ones, so a
persistent volume never fills up.

### Configuration file (optional)

CLI-only always works — `mandor.toml` just saves typing. CLI flags override
file values; `MANDOR_STATE_DIR` overrides the file's `state_dir`.

```toml
restart = "on-failure"
metrics_port = 9464
workers = [
  "./api --port 8080",
  "./worker",
]
# optional: liveness probes, ordering, init tasks, per-worker settings
health = ["api=/bin/check-api"]
start_after = ["worker=api"]   # worker starts once api is up (ready or alive 1s)
oneshot = ["migrate"]          # init tasks run first; failure aborts startup
env = ["api=PORT=8080"]        # per-worker environment additions
cwd = ["api=/srv/app"]         # per-worker working directory
user = ["api=1000:1000"]       # drop root before exec (numeric uid:gid)
essential = ["api"]            # api exiting stops everything (leader)
env_file = ".env"              # KEY=VAL lines for all workers
max_rss_mb = ["api=768"]       # recycle worker beyond this RSS (planned, not a failure)
max_lifetime = ["api=12h"]     # periodic recycle as a leak crutch
restart = ["cron=never"]       # per-worker override of the global policy
on_incident = "/notify"        # exec'd with each incident bundle path
photon = "127.0.0.1:4318"      # auto-forward incidents to photon (OTLP)
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
  worker tables, raw syscalls via `std.os.linux` — no libc.
- **Single thread, one poll loop.** Signals arrive via `signalfd`, not async
  handlers.
- **No dependencies, no regex.** Trace parsing is line-oriented scanning.

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

Actively developed. Version history: [CHANGELOG.md](CHANGELOG.md) · every
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
