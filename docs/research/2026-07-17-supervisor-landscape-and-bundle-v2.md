# Process Supervisor Landscape Survey & Incident-Bundle Design for mandor

*Research report, 2026-07-17. Method: five parallel web-research passes
(heavyweight supervisors; daemontools lineage; minimal PID-1s + systemd;
Procfile runners + container-community sentiment; crash-context literature for
automated RCA), cross-verified. Sources inline.*

## 1. Feature matrix

● = built-in, ◐ = partial/add-on/opt-in, — = absent.

| Tool | Multi-proc | Restart + backoff | Log capture/rotate | Log timestamps | Res. monitor | Res. limits | Health check | Readiness | Dep. order | Exit-cause report | Crash forensics |
|---|---|---|---|---|---|---|---|---|---|---|---|
| supervisord | ● | ◐ no exp. backoff | ● (buggy rotation) | ◐ | — | — | ◐ superlance | — | ◐ priority only | ◐ expected-exit flag, events | — |
| s6 / s6-overlay | ● | ◐ fixed pause | ● s6-log | ● TAI64N | — | ◐ softlimit | ◐ notifyoncheck | ● notification-fd | ● s6-rc DAG | ◐ finish(code, sig); 125=stop | — |
| runit | ● | ◐ fixed 1s | ● svlogd | ● opt-in | — | ◐ chpst | ◐ ./check | — | — | ◐ finish(code, sig) | — |
| daemontools | ● | ◐ fixed pause | ● multilog | ● TAI64N | — | ◐ softlimit | — | — | — | — | — |
| tini | — (1 child) | — | — passthrough | — | — | — | — | — | — | ◐ 128+signum | — |
| dumb-init | — (1 child) | — | — passthrough | — | — | — | — | — | — | ◐ 128+signum | — |
| multirun | ● | — by design | — passthrough | — | — | — | — | — | — | ◐ generic error only | — |
| systemd | ● | ● RestartSec + StartLimit | ● journald | ● structured | ● cgroup acct. | ● CPUQuota/MemoryMax | ◐ WatchdogSec | ● sd_notify | ● After/Requires | ● SERVICE_RESULT/EXIT_CODE | ● systemd-coredump |
| pm2 | ● | ● exp. backoff | ◐ rotation module buggy | ◐ opt-in | ● pm2 monit | ◐ max_memory_restart | ◐ | ● wait_ready | — | ◐ | ◐ paid SaaS |
| foreman | ● | — | ◐ pipes buffer/clip | ◐ | — | — | — | — | — | — | — |
| overmind/hivemind | ● | ◐ opt-in env | ● PTY fidelity | ◐ opt-in `-T` | — | — | — | — | — | — | ◐ tmux attach (live only) |
| immortal | ● | ● retries/wait | ● built-in rotation | ◐ | — | — | — | — | ◐ require | ◐ JSON status socket | — |
| horust | ● | ● configurable backoff | ◐ | ◐ | — | — | ● http/file/cmd | ◐ via health | ● start-after | ◐ successful-exit-code | — |
| monit | ◐ not parent | ● | — cannot capture | n/a | ● thresholds | ◐ threshold actions | ● protocol probes | — | ● depends on | ◐ alerts | — |
| **mandor (v0.4)** | ● | ● | ● ring buffers | **—** | ● /proc sampler | **—** | **—** | **—** | **—** | ● incident bundles | ● **unique among tiny inits** |

Key sources: https://supervisord.org/subprocess.html, https://skarnet.org/software/s6/notifywhenup.html, https://smarden.org/runit/runsv.8.html, https://github.com/krallin/tini, https://github.com/nicolas-van/multirun, https://manpages.debian.org/testing/systemd/systemd.service.5.en.html, https://federicoponzi.github.io/Horust/, https://github.com/immortal/immortal, https://mmonit.com/monit/documentation/monit.html, https://github.com/DarthSim/overmind, https://evilmartians.com/chronicles/introducing-overmind-and-hivemind.

**What the landscape says.** The forensics column is empty everywhere except
systemd (host-scale, not container-viable) and pm2 (paid SaaS, and its daemon
itself crashes opaquely — https://github.com/Unitech/pm2/issues/2013,
https://github.com/Unitech/pm2/issues/5579). The community's documented pain
maps directly onto that hole: "exit 137 but OOMKilled=false" archaeology
threads (https://forums.docker.com/t/docker-exiting-with-code-137-but-oomkilled-is-false/137273),
crashed distroless containers that can't be exec'd into
(https://edu.chainguard.dev/chainguard/chainguard-images/troubleshooting/debugging_distroless/),
and supervisord's cardinal sin of masking crash loops from the orchestrator
(https://serversideup.net/open-source/docker-php/docs/guide/using-s6-overlay).
mandor's exit-cause bundle is genuinely unoccupied territory. Two cautionary
tales: supervisord's log rotation can block the child on a full pipe
(https://github.com/Supervisor/supervisor/issues/240) — ring buffers avoid
this class entirely; and pm2 proves a supervisor that itself dies is worse
than none.

## 2. Crucial missing features for mandor (ranked)

1. **Per-line log timestamps (wall + monotonic) in the ring buffer.** Every
   respected logger in the lineage does this (svlogd/s6-log TAI64N —
   https://skarnet.org/software/s6/s6-log.html; journald
   `_SOURCE_REALTIME_TIMESTAMP` —
   https://www.freedesktop.org/software/systemd/man/latest/systemd.journal-fields.html).
   Without timestamps, `logs_tail` cannot be correlated with
   `stats_timeline` — the RCA agent can't tell whether the error burst
   preceded or followed the RSS climb. Cost: ~8 bytes/line. Highest
   value-to-effort ratio on this list.

2. **Spawn-time process snapshot: cwd, exe path, ELF build-id, filtered env,
   ulimits, cgroup path.** This is exactly what systemd-coredump captures
   (https://systemd.io/COREDUMP/,
   https://man7.org/linux/man-pages/man8/systemd-coredump.8.html) and it's
   free: read `/proc/<pid>/{cwd,exe,environ,limits,cgroup}` once at fork time
   (they vanish at exit — snapshot early, as parent mandor can). The
   build-id/git-SHA is the single biggest RCA lever (see section 3).

3. **Stop-grace escalation + expected-exit-code config.** SIGTERM →
   configurable timeout → SIGKILL is table stakes (pm2 `kill_timeout` —
   https://pm2.keymetrics.io/docs/usage/signals-clean-restart/; foreman `-t`;
   s6 `timeout-finish`). Pair with supervisord-style `exitcodes` / tini `-e`
   remapping (https://github.com/krallin/tini) so exit 143 after SIGTERM
   doesn't spawn a false incident — a documented orchestrator pain point.
   Also adopt tini's 128+signum convention for mandor's own exit code
   (mandor already does this).

4. **Command-based health checks (liveness).** Exit-based supervision cannot
   detect a *hung* worker — the failure mode `WatchdogSec` exists for
   (https://blog.hackeriet.no/systemd-service-type-notify-and-watchdog-c/)
   and monit/horust's most-praised capability. A periodic `exec` probe (no
   HTTP client — size budget) with `--restart-on-unhealthy` closes it, and
   "hung, health check failing for 90s" becomes a new incident cause the trio
   of tiny inits can't produce.

5. **Readiness notification, s6-style.** A worker writes a newline to a
   numbered fd → mandor marks it ready
   (https://skarnet.org/software/s6/notifywhenup.html). Trivial to implement,
   widely admired, and it upgrades "started" from "survived 1s"
   (supervisord's weak `startsecs` semantics) to real state — and it is the
   prerequisite for #6. Also lets mandor report "died before ever becoming
   ready," a high-signal incident field.

6. **Dependency ordering (`start-after`).** Wanted (s6-rc's DAG is the gold
   standard — https://www.skarnet.org/software/s6-rc/overview.html; horust
   and immortal both ship simple versions) but rankable below the others: a
   flat `start-after` list per worker in TOML is enough; do not build a
   service-database compiler. Defer full DAG/oneshot semantics.

7. **Sibling status in incidents.** When worker A crashes, record what B and
   C were doing (state, uptime, recent restarts). Monit's `depends on`
   propagation shows why: cascading failures are the norm, and the RCA agent
   needs to know whether the crash was isolated. Near-zero cost since mandor
   already holds this state.

Explicitly *not* recommended: HTTP metrics beyond the existing Prometheus
route, time-based log rotation, PTY allocation (hivemind's niche), tmux-style
attach, resource *enforcement* via rlimits (chpst/softlimit prior art exists,
but cgroup limits are the container runtime's job —
https://manpages.debian.org/testing/runit/chpst.8.en.html).

## 3. Incident-bundle fields for an LLM PR-authoring agent

**What the research says matters.** The strongest empirical findings: stack
traces are the single best localization signal, and file-level localization
is the dominant factor in agentic repair success — 15–17× improvement
(https://arxiv.org/abs/2412.03905, https://arxiv.org/html/2411.10213v2).
Explicit exception *type* matters more than the raw trace for code-bug
localization — ablations show removing it breaks localization even with the
trace present (https://arxiv.org/abs/2312.10448). "What changed" is the #1
RCA question: ~70% of outages are caused by changes
(https://sre.google/sre-book/introduction/); Sentry's suspect-commit feature
and Meta's change-ranking RCA (42% accuracy from ranking recent diffs alone —
https://engineering.fb.com/2024/06/24/data-infrastructure/leveraging-ai-for-efficient-incident-response/)
both hinge on one field: **a release identifier in the crash event**
(https://docs.sentry.io/product/issues/suspect-commits/).

**What PID-1 gets for free (no app cooperation):** wait status (exit code vs
signal + core-dumped flag); everything under `/proc/<pid>/` snapshotted at
spawn (cmdline, environ, cwd, exe → ELF build-id, limits, cgroup); the
sampler timeline; captured stderr (which *is* the stack trace for Go panics,
Rust panics with `RUST_BACKTRACE`, Python tracebacks); cgroup v2
`memory.events` oom_kill counters — read immediately on suspicious SIGKILL,
before cgroup teardown, per conmon's documented race
(https://github.com/containers/conmon/issues/426). **Not free:** symbolized
C/C++/Zig native stacks (need core_pattern + debug info; core_pattern is
host-global in containers), git SHA (unless passed as env or embedded as
build-id), image digest, "recent config changes."

**Top 10 fields by value-per-byte** (✱ = missing from current v1 schema
`{v, ts, process{name,cmd,pid,restarts}, cause, trace{lang,frames,raw},
logs_tail, stats_timeline, verdict}`):

| # | Field | Why | Bytes |
|---|---|---|---|
| 1 | Structured exit cause: exit code *or* signal number+name, core_dumped, oom_kill delta | Ablation-proven; disambiguates the "137 archaeology" problem | ~50 |
| 2 | Exception type + message as first-class fields ✱ (currently buried in `trace.raw`) | Removing it breaks LLM localization even with full trace | ~100 |
| 3 | Trace frames as `{file, line, function, in_app}` (Sentry frame model) | File-level localization = the 15–17× repair lever | ~1–3KB |
| 4 | Release/build id: `MANDOR_RELEASE`/`GIT_SHA` env passthrough + ELF build-id of exe ✱ | Enables suspect-commit-style "what changed"; #1 RCA question | ~60 |
| 5 | `cwd` + resolved `exe` path ✱ | Maps runtime paths → repo paths so the agent opens the right files | ~100 |
| 6 | Timestamped `logs_tail` with severity flags (ts ✱) | Breadcrumbs-equivalent; ordering vs. stats timeline | ~10KB |
| 7 | Filtered env at spawn (allowlist/redacted) ✱ | Config-driven crashes (bad URL, missing var) are localizable only from env | ~1KB |
| 8 | `stats_timeline` (have) + uptime-at-death, time-to-crash ✱ | Distinguishes leak vs. spike vs. instant-crash-on-boot | ~1KB |
| 9 | ulimits + cgroup memory.max ✱ | "OOM at 512MB limit" vs. "leak" is a different PR | ~200 |
| 10 | Sibling worker status + prior incident signatures (first_seen/count) ✱ | Isolated vs. cascade; recurrence context steers fix vs. revert | ~500 |

`verdict` stays — a heuristic hypothesis is a cheap, useful prior. `pid` and
`v` stay.

### Proposed bundle schema v2

```json
{
  "v": 2,
  "ts": "2026-07-17T22:47:03Z",
  "process": {
    "name": "api", "cmd": "./api --port 8080", "pid": 42,
    "cwd": "/app", "exe": "/app/api",
    "build": {"git_sha_env": "9f2c1ab", "elf_build_id": "a1b2c3...", "release_env": "api@1.4.2"},
    "env": {"PORT": "8080", "DATABASE_URL": "<redacted>", "GOMAXPROCS": "2"},
    "limits": {"nofile": 1024, "memory_max_bytes": 536870912},
    "restarts": 3, "uptime_s": 47, "spawned_at": "2026-07-17T22:46:16Z",
    "ready": false
  },
  "cause": {
    "kind": "signal", "exit_code": null,
    "signal": {"num": 11, "name": "SIGSEGV"},
    "core_dumped": true, "oom_kill_delta": 0,
    "during": "steady"
  },
  "exception": {"type": "runtime error: invalid memory address", "message": "nil pointer dereference"},
  "trace": {
    "lang": "go",
    "frames": [{"file": "handlers/user.go", "line": 87, "function": "GetUser", "in_app": true}],
    "raw": "panic: runtime error: ..."
  },
  "logs_tail": [{"t": "2026-07-17T22:47:02.881Z", "level": "error", "line": "lookup failed for id="}],
  "stats_timeline": [{"t_rel_s": -60, "rss_mb": 812, "cpu_pct": 97, "fds": 210, "threads": 8}],
  "siblings": [{"name": "worker", "state": "running", "uptime_s": 3600, "restarts": 0}],
  "history": {"signature": "go:GetUser:user.go:87", "first_seen": "2026-07-16T04:11:00Z", "count": 5},
  "verdict": "3rd SIGSEGV at same frame since yesterday; crashes 47s after start, before readiness"
}
```

Migration notes: `cause` becomes structured (keep a `cause_str` mirror during
transition if the sidecar needs it); `trace.frames` adopts Sentry's frame
vocabulary (https://develop.sentry.dev/sdk/data-model/event-payloads/stacktrace/);
every field is capturable by mandor alone except
`build.git_sha_env`/`release_env`, which are opt-in env passthrough —
document `MANDOR_RELEASE` as the convention, exactly as Sentry documents
`release`. Per the schema contract rule, this bumps `"v"` to 2 with fixture
tests.

**Bottom line.** The survey confirms mandor's roadmap sits in an empty
quadrant: tiny inits have no forensics, forensic-capable systems aren't
container-viable. The three cheapest high-impact additions are log
timestamps, the spawn-time /proc snapshot (esp. build-id/release), and
structured exception type — together they convert the bundle from
"human-readable postmortem" to "LLM-localizable repair input," which the
localization literature suggests is the difference between a plausible-
sounding PR and a correct one.
