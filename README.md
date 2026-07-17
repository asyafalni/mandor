# mandor

> **the foreman for your containers** — a tiny PID-1 process supervisor that
> watches your workers, captures their logs, and tells you *why* they died.

[![Zig 0.16.0](https://img.shields.io/badge/zig-0.16.0-f7a41d?logo=zig&logoColor=white)](https://ziglang.org/download/#release-0.16.0)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Static binary](https://img.shields.io/badge/binary-static%2C%20%3C500KB-success)
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
| Size | < 500 KB | ~50 KB | MBs + runtime |
| Network access required | **never** | never | varies |

The `mandor` binary is fully offline and self-contained: no accounts, no
phoning home. Incident bundles are plain JSON on disk — yours to ignore, ship,
or feed to tooling. The upcoming **mandor premium** sidecar picks those same
bundles up and hands them to an AI coding agent that root-causes the crash,
fixes the code, and opens a PR — supervision that closes the loop.

## Quick start

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

| Flag | Values | Default |
|---|---|---|
| `--restart` | `never` \| `on-failure` \| `always` | `never` |
| `--backoff-max` | duration (`500ms`, `30s`, `2m`) | `30s` |
| `--config` | path to `mandor.toml` | `./mandor.toml` if present |
| `--state-dir` | state + incident spool dir | `/var/lib/mandor` |
| `--metrics` | port for Prometheus text metrics on 127.0.0.1 | off |

### Configuration file (optional)

CLI-only always works — `mandor.toml` just saves typing. CLI flags override
file values; `MANDOR_STATE_DIR` overrides the file's `state_dir`.

```toml
restart = "on-failure"
backoff_max = "30s"
state_dir = "/var/lib/mandor"
metrics_port = 9464
workers = [
  "./api --port 8080",
  "./worker",
]
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

## Status

- [x] **v0.1** — multirun parity: spawn, forward signals, reap, restart
      policies with exponential backoff, worst-exit-code propagation
- [x] **v0.2** — log capture (ring buffers, `[name]` prefixes), `/proc`
      sampler, `mandor report`
- [x] **v0.3** — incident detection with diagnosis verdicts, Go/Rust/Python
      trace parsing, restart-loop + leak detection, spool dir
- [x] **v0.4** — cgroup v2 OOM detection, optional Prometheus text endpoint,
      `mandor.toml` (CLI-only always works)

## Contributing

Issues and PRs welcome. Before submitting:

```console
zig build test    # all unit tests green
zig fmt src       # formatting
```

The size budget is a feature: changes that grow the stripped ReleaseSafe
binary past 500 KB need a very good story.

## License

[MIT](LICENSE)
