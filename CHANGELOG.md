# Changelog

All notable changes to mandor. Format follows [Keep a Changelog](https://keepachangelog.com/);
versions correspond to git tags. Planned work lives in [docs/ROADMAP.md](docs/ROADMAP.md).

## [1.5.6] - 2026-07-21

### Fixed
- **The harness aborted at its first failure** (regression introduced in
  1.5.2). The failure-name logging added there referenced `$MANDOR_FAILLOG`
  unguarded while the script runs under `set -u`, so an unset variable killed
  the run at the first `bad` call — every later case never executed and no
  summary printed. The logging meant to make failures more visible was instead
  hiding all but the first. Guarded with `${MANDOR_FAILLOG:-}`. It stayed
  hidden because every run since was either green or had the variable exported.

### Added
- **Harness case 73: fd count must not grow across restarts.** Every spawn
  makes three pipes; a read end outliving its worker would walk mandor into
  `EMFILE`, and PID 1 hitting `EMFILE` takes the container down. Restarts stay
  under the loop detector (5 deaths / 5 min) and the check compares the *floor*
  of repeated samples, which is phase-independent — raw counts swing by 3 per
  live worker depending on when you look. Result: the floor holds flat, so the
  pipe lifecycle is confirmed correct rather than merely assumed.

### Docs
- `README`: the photon section still called the incident hook "upcoming" — both
  `photon = "ip:port"` and `on_incident` ship today; the caveat is photon's
  protobuf-only `/v1/logs`, now stated. Removed `--backoff-max` from a quick
  start example — the flag moved to `mandor.toml` in 1.3.0, so the documented
  command errored.
- `docs/mandor.1`: SIGNALS and EXIT STATUS still cited `--stop-grace` and
  `--expected-exit` as flags; both are TOML keys now.
- Size claims normalized to the measured 248 KB across README, CONTRIBUTING
  and the man page (they read 268 KB, 230 KB and 250 KB respectively).
- `docs/INTEGRATION-PHOTON.md`: documented the 10s socket timeout and that any
  2xx counts as accepted.

## [1.5.5] - 2026-07-21

### Fixed
- **Incident pruning could neither see nor count the files it needed to
  delete.** `listIncidents` keeps the *newest* entries when a directory holds
  more files than its output buffer — correct for `report --incidents`,
  backwards for `prune`, which needs the oldest precisely because those are the
  ones it removes. `prune` also sized the deletion from the *listed* count
  rather than the real total. With 300 incidents against a 200 cap and a
  216-entry buffer, one prune deleted 16 files and left 284 — and the 16 it
  deleted were recent incidents from inside the newest window, while the truly
  ancient files were never visible to it at all. The retained end is now
  selectable (`Keep.newest` / `Keep.oldest`), the directory is counted before
  deleting, and the oldest are removed a window at a time until the cap is met.
  Same scenario now lands on exactly 200, in one pass.

  Reachable on a persistent volume seeded by an older build, a shared state
  dir, or a lowered `max_incidents` — anywhere the directory can start out
  larger than one listing window.

## [1.5.4] - 2026-07-21

### Fixed
- **A successful delivery could be reported as a rejection.** The response
  check matched the status line against exactly `"200"`, so a receiver
  answering `202 Accepted` — valid for OTLP ingest — printed "photon rejected
  the payload" and exited 1, sending the operator to investigate a working
  integration. Any 2xx now counts. Proven by mutation: restoring the exact
  match makes harness case 72 fail.
- **A non-HTTP reply could be mistaken for success.** The same check indexed
  offset 9 without verifying the response was HTTP at all, so any reply of at
  least 12 bytes whose bytes 9..11 happened to read `200` — a plain-text error
  page, another protocol's banner — was taken as a successful delivery and the
  incident silently dropped. The status line is now validated as HTTP first.

### Added
- **`post()` has coverage.** It previously had none beyond the happy path.
  `statusOk` is now a tested unit (2xx, 4xx/5xx, non-HTTP look-alikes, short
  replies), plus harness cases for a rejection with its status echoed, a peer
  that closes without answering, and a 202.
- **A metrics boundary test at full worker-table capacity.** `render` writes
  into a 32KB buffer via an `ap` that drops silently on overflow, with
  Content-Length taken from whatever survived — so an overflow would lose
  series with no error anywhere. Worst case (64 workers, 32-char names,
  near-maximum counters) measures 28,974 bytes: it fits, but with only ~3.8KB
  spare, and one more metric family would cost ~5KB. The test pins every
  series so a future addition fails loudly instead of silently truncating.

### Checked, no change needed
- The metrics listener and its accepted connections are already `SOCK.NONBLOCK`,
  so a client that connects and never sends cannot stall the supervision loop.
  This was the worst-case suspicion behind the audit; it does not hold.

## [1.5.3] - 2026-07-21

### Fixed
- **`mandor relay` could hang forever on a peer that never answers.** The
  socket had no timeouts at all, and relay is spawned fire-and-forget — forked,
  exec'd, never waited on. A collector that accepts the TCP connection and then
  stalls (a hung ingest, a half-open connection through a firewall, an LB that
  accepts and never forwards) wedged `read()` permanently. Because incidents
  fire *per restart*, a crash loop against such a peer stranded one hung relay
  per crash, without bound, exactly while the container was already failing.
  `SO_RCVTIMEO`/`SO_SNDTIMEO` now bound every blocking call at 10s.
  Reproduced with a listener that accepts and sleeps: relay hung until killed;
  it now exits in ~11s saying so. Pinned by harness case 69.
- **A signal landing mid-send was reported as a delivery failure.** `write()`
  returning `EINTR` printed "send failed" and gave up; it now retries.
- **A timed-out send or read is named as such** instead of being folded into
  "rejected the payload (no response)", which pointed at the wrong cause.

### Hardened (latent, not reachable today)
- `writeTermLog` opens `/dev/termination-log` with `TRUNC` and then bailed out
  if the message exceeded 1024 bytes — which would leave `kubectl describe pod`
  showing an *empty* termination message rather than a long one. Current bounds
  (`name` <= 32, `verdict` <= 256) put the maximum near 325 bytes, so it is not
  reachable; it now degrades to a short form rather than silence, because the
  destructive open makes silence the wrong failure mode to leave in place.
  Also dropped a dead `@min(msg.len, 4096)` — `msg` cannot exceed 1024.

## [1.5.2] - 2026-07-21

### Fixed
- **Incident verdicts reached photon with literal backslashes.** `relay` scans
  values out of a bundle that the spool writer already escaped, then escaped
  them a second time — so an incident reading `go panic: said "boom"` shipped
  as `said \"boom\"`. Scanned values are now copied through as the JSON source
  they already are, and validated on the way: a bundle with a broken escape is
  refused rather than spliced into the payload. (The whole-bundle copy is still
  escaped — that one really is raw JSON embedded as a string.)
- **`relay` silently truncated any bundle at 256KB.** One un-looped `read()`
  with no size check, so an oversize or short-read bundle shipped clipped and
  photon stored it with nobody the wiser. Reads are looped and an oversize
  bundle is now refused loudly.
- **A too-large HTTP request failed with no message at all** — `bufPrint`'s
  error returned exit 1 and printed nothing.

### Added
- **`relay` has test coverage.** It had none: `relay.zig` is only `@import`ed
  inside a subcommand branch, so it never entered the test graph — the module
  was invisible to `zig build test` rather than merely untested. It is now
  referenced explicitly, with 7 unit tests (endpoint parsing, escape-aware
  string scanning, severity mapping, refusal paths), 3 fuzz targets over a
  validated seed bundle, and 4 harness cases that POST to a real socket and
  parse what lands there. Each fix was mutation-tested: reverting it makes a
  named test fail.
- **The harness names its failing cases** in a `failing cases:` block at the
  end of a run, and in `$MANDOR_FAILLOG` when set. A transient failure here was
  briefly unexplainable because the only record of *which* case failed was one
  line in the middle of the output, and the run had been piped through `tail`.

### Test
- **Harness case 65 was itself racy** (introduced above, caught before release).
  It listened with `nc -q 1`, which means "quit 1s after EOF on *stdin*" — and
  in a script stdin is at EOF immediately, so the listener tore itself down
  whether or not relay had connected. Under load the capture came back empty.
  Replaced with a listener that binds an ephemeral port, publishes it as a
  readiness signal, reads exactly `Content-Length` bytes and answers 200 (so
  relay's success path is covered too). 12/12 clean under CPU+I/O load.

## [1.5.1] - 2026-07-21

### Fixed
- **The post-death group sweep no longer cuts short a grandchild's own TERM
  handler.** When a worker died, the reaper immediately `SIGKILL`ed its process
  group so a restart could never inherit strays. During a *graceful shutdown*
  that raced the grandchildren: mandor had already TERMed the whole group, and
  the leader exiting (having handled TERM promptly) killed processes that were
  still draining well inside `stop_grace`.

  The sweep is now conditional on what mandor is actually doing. Still
  supervising — a restart is coming, nothing is draining — it KILLs as before.
  Shutting down, it leaves the group alone; those processes are draining on
  purpose and the existing stop-grace escalation is the right backstop.

  Skipping the sweep alone would have orphaned them instead: the escalation
  only ever signalled workers with a live pid, and the leader is already
  reaped. `Worker.pgid` is therefore recorded at spawn and outlives the reap,
  and the stop-grace `SIGKILL` now also reaches recorded groups whose leader
  has exited. The reaper clears `pgid` when it does sweep, so a recorded pgid
  means exactly one thing — "left draining during a shutdown" — and can never
  be a stale id the kernel has since recycled.

  Found via harness case 13 (`TERM reaches grandchildren`), which failed
  roughly 1-in-5 under heavy I/O; it now passes 6/6 under the same load.
  Cost: +160 bytes.

## [1.5.0] - 2026-07-21

### Changed
- **`supervisor.run` split into named units.** It carried the poll loop, spawn
  gating, the death path, health probes, the sampler tick and shutdown in one
  451-line function — the function that must not panic, and where most of the
  1.x defects lived. Six steps, each measured before and after:

  | Step | Binary | `run` |
  |---|---|---|
  | v1.4.0 | 252,920 | 56,043 B / 451 lines |
  | 1 — `Shutdown` struct | 251,896 | 55,011 |
  | 2 — `handleDeaths` | 252,248 | 55,095 / 344 |
  | 3 — `runSamplerTick` | 248,248 | 51,124 / 323 |
  | 4 — `pumpIo` | 247,672 | 50,551 / 280 |
  | 5 — `startDueRestarts` | 247,672 | 50,551 / 252 |
  | 6 — `assessFleet` | **247,768** | **50,646 / 208** |

  Net **−5,152 bytes** and **−243 lines** (54% shorter), perf neutral: the
  200k-line capture gate measures 16 ms before and 17 ms after (ReleaseSafe,
  minimum of 8 alternating runs).

  The wins were not where intuition said. Moving 22 lines (`runSamplerTick`)
  saved 4,000 bytes because `cost.update`, `incident.onLeak/onStall`,
  `report.writeState` and `cost.save` were expanding directly into `run`;
  moving 107 lines (`handleDeaths`) *cost* 352. Each step was kept or dropped
  on measurement, not on how much code it moved.

## [1.4.0] - 2026-07-21

### Added
- **The run ends once every essential worker has finished.** Previously mandor
  waited for *all* workers, so a never-exiting sidecar kept the container alive
  after the real work was done — healthy-looking, doing nothing. Sidecars are
  now stopped gracefully (`pre_stop`, TERM, stop-grace) and mandor exits with
  the **essential** workers' outcome, so the 143 from the TERM mandor sends a
  sidecar cannot report a successful run as a failure.

  Behaviour is unchanged for the default fleet: when every worker is essential,
  "all essential finished" is identical to "all finished". It only differs once
  a worker opts out with `essential = false`. A fleet with *no* essential
  worker keeps supervising rather than exiting instantly.

  This was roadmap #43, parked since 2026-07-20 behind four open design
  questions; v1.3's essential-by-default answered all of them, leaving a single
  loop-exit condition.

## [1.3.1] - 2026-07-21

### Fixed
- **Abandoning a non-essential worker was silent.** Once a worker marked
  `essential = false` hit a restart loop, mandor stopped retrying it and said
  nothing — the log showed a routine exit line and then silence, with no way
  to tell that mandor had given up. `essential = false` opts a worker out of
  *ending the run*, not out of being reported. It now says so:
  `bad is in a restart loop, not restarting it (essential = false)`.
- **Three fuzz seeds were not valid inputs, so their targets fuzzed an early
  error instead of the parser.** `cli_seed` still listed flags 1.3 moved to
  TOML; `config_seed` still used the removed `restart` key; and `report_seed`
  had no `ts_ms`, which `report.formatHuman` requires — that last one had been
  fuzzing nothing since 1.0.0. All three are fixed.

### Added
- **A seed-validity guard** (`seed valid: …` tests). Every fuzz seed must
  parse successfully and populate what the target needs. This failure mode has
  now bitten three times — the `history.json` seed through 1.0.0, and two more
  found here — and it is invisible by construction: a broken seed makes the
  suite *greener*, not redder. The guard makes it loud.
- Harness cases for the non-essential give-up message, and for recycling not
  tripping essential-by-default (a planned restart must never read as a
  failure now that any failure can end the run).

## [1.3.0] - 2026-07-21

Lifecycle simplification. mandor now defaults to **giving up** rather than
retrying quietly, because a retry the orchestrator never hears about is a
failure that never gets fixed.

### Changed — breaking (config)
- **`restart` is gone; `max_restarts` is the only retry knob.** One integer
  replaces the policy enum, with the intuitive encoding:

  ```toml
  max_restarts = 0     # default — don't retry; a failure ends the run
  max_restarts = 3     # retry a failed worker 3 times, then exit with its code
  max_restarts = -1    # retry forever (explicit opt-in; nothing upstream is told)
  ```

  Previously `0` meant *unlimited*, which was backwards from every intuition
  and meant `restart = "on-failure"` retried forever by default. Only
  **failures** are retried — a worker exiting 0 has finished, so
  `restart = "always"` has no successor. Per-worker `restart` is gone too:
  policy is a fleet decision.
- **`essential` defaults to `true`.** A failure that exhausts its retries stops
  the fleet and propagates that worker's code, so the layer above is always
  signalled. `essential = false` opts a sidecar out. A *clean* exit still stops
  nothing, so "run several things until they finish" is unchanged. `essential`
  on a `oneshot` is now a hard error rather than silently ignored.
- **`restart_on_unhealthy` is gone.** A configured probe is always acted on —
  detecting a hung worker and leaving it running was the quietest failure
  mandor could produce, and it was the flag's default.
- Removed flags and keys produce errors that **name the replacement** instead
  of a bare "unknown key".

- **The CLI is now four flags:** `--max-restarts`, `--config`, `--metrics`,
  `--state-dir` (plus `report`/`validate`/`--help`/`--version`). Eleven runtime
  flags moved to `mandor.toml` only — `--health`, `--health-interval`,
  `--health-start-period`, `--backoff-max`, `--stop-grace`, `--expected-exit`,
  `--ready-fd`, `--on-incident`, `--photon`, `--psi-mem`, `--psi-cpu`. None are
  things you would type in a Dockerfile `ENTRYPOINT`, and `--health=api=/bin/x`
  was the same `name=value=value` awkwardness this release removed from TOML.
  Each keeps its name minus the dashes (`--stop-grace` → `stop_grace`), and
  passing an old flag says exactly that.

### Added
- **Per-worker `expected_exit`.** Declares which codes mean success for one
  worker without whitelisting them fleet-wide. This is what makes
  essential-by-default safe: a job that legitimately exits 3 can say so
  instead of killing the container.
- **Startup plan line.** mandor prints the resolved lifecycle on start, so the
  model lands in `docker logs` without anyone reading documentation. Verbosity
  scales with the config — a plain two-worker setup prints one line.
- **Config surface gate in CI**, budgeted like binary size. Every knob looks
  justified alone; surface grows one reasonable-seeming addition at a time.

### Fixed
- **A health-kill counted as success if `expected_exit` contained 143.** mandor
  would detect a hung worker, SIGTERM it, see 143, treat it as a graceful
  shutdown, and **exit 0** — reporting a hung app as a successful run. A
  health-kill is now a failure whatever code the worker reports.
- **A slow crash loop never escalated.** The fail-streak resets after 10s of
  uptime, so a worker crashing every 11 seconds could never reach
  `max_restarts` at any value — it retried forever while the container looked
  healthy. A detected restart loop now ends the run.

### Notes
- **The binary shrank by 17 KB despite everything above** (269,128 → 251,992
  on x86_64). `cli.parse` and `config.parse` returned a ~10 KB struct by
  value, and an error union carrying that payload materializes a full copy in
  `.rodata` *per distinct error-return path* — the release build was carrying
  six of them. Returning through an out-pointer (`ParseError!void`) dropped
  that to two. The waste predated this release; adding two error returns is
  what made it visible.

## [1.2.0] - 2026-07-21

### Fixed
- **A worker that fails to spawn is now reported as a death, so every
  terminal-state rule applies to it.** Previously the spawn-failure path set
  `done` and returned, bypassing the restart policy, `essential`, and
  `oneshot` — all three of which live on the death path. Three verified
  defects, one root cause:

  - A transient `fork` `EAGAIN` (pids-cgroup limit or `RLIMIT_NPROC` under
    load) retired the worker **permanently** instead of retrying under the
    restart policy and backoff.
  - An **`essential`** worker that never started did **not** stop the fleet.
    mandor kept running leaderless and never exited, so no orchestrator ever
    restarted the container — silent degradation rather than a visible crash.
  - A **`oneshot`** init task that never started read as a **completed** one
    and released its dependents. Migrations never ran and the API served
    against uninitialized state. This is the severe one: a failure silently
    converted into a success.

  All four behaviours are now verified by injection (see CONTRIBUTING):
  on-failure retries and recovers, `never` does not retry, `essential` stops
  the fleet, and a failed `oneshot` shuts down with its dependents unstarted.
  Exit code 125 still marks a worker that could not be spawned, and the log
  now says `failed to start (fork failed)` rather than reporting an exit that
  never happened.

### Notes
- The loop-exit accounting counts a spawn-failed worker via `w.spawn_failed`
  in the existing live/pending tally rather than adding a term to the `break`
  condition. Both are correct; the latter makes the compiler duplicate the
  loop body and cost ~6 KB of `.text`. Measured: +496 B this way versus
  +6,528 B the naive way.

## [1.1.0] - 2026-07-20

### Changed — breaking (config only)
- **Per-worker settings move from flat `"name=value"` arrays to
  `[worker.NAME]` sections.** The old form put two `=` in one string
  (`env = ["api=PORT=8080"]`), which read as ambiguous even though it parsed
  fine. Grouping by worker removes the doubled separator entirely and puts
  everything about one worker in one place:

  ```toml
  workers = ["./migrate", "./api --port 8080", "./worker"]

  [worker.migrate]
  oneshot = true

  [worker.api]
  env = ["PORT=8080", "LOG_LEVEL=info"]
  cwd = "/srv/app"
  health = "/bin/check-api"
  essential = true

  [worker.worker]
  start_after = "api"
  ```

  `env` keeps `KEY=VALUE` deliberately — it is the format `execve`, `.env`,
  `docker -e`, compose, and Kubernetes all use, and it matches the `KEY=VAL`
  lines `env_file` reads. The ambiguity was the `worker-name=` prefix, not the
  environment pair.

  `oneshot` and `essential` become booleans on the worker (`oneshot = true`)
  instead of separate name lists. Unknown sections and unknown keys inside a
  section are hard errors. CLI flags are unchanged (`--health=NAME=CMD` still
  works); this is a `mandor.toml` change only.

  Done now, in 1.x, because nothing has been published yet — the same change
  after release would cost a major version.

## [1.0.3] - 2026-07-20

Turns the last asserted-but-unmeasured claim into a measured one, and covers
the hostile conditions fuzzing cannot reach. No source changes — tests, CI,
and docs only.

### Added
- **Soak test** (`test/harness/soak.sh`, 3 minutes in CI). Runs capture at
  full rate, restart churn, incident writes, the sampler, health probes, and
  the metrics listener simultaneously, then asserts mandor's *own* RSS, fd
  count, and thread count stay flat, that the incident spool respects its
  retention bound, that `report` still works afterward, and that TERM still
  shuts down cleanly. This is what now backs "zero allocations in steady
  state": over a 30-minute run under full-rate log capture, **~1.1 MB RSS,
  10 fds, 1 thread, 4 KB drift**. `SOAK_SECONDS=1800` for a deep local run.
  Calibrated by injecting a 64 KB-per-tick leak and confirming it fails
  (640 KB drift against a 256 KB budget) — a soak that cannot detect a leak
  proves nothing.
- Six integration cases (harness now 54). Four cover hostile environments —
  the real-world form of the traps fixed in 1.0.1/1.0.2: a `history.json` and
  `cost.json` full of out-of-range values, truncated and random-garbage state
  files, and a read-only state directory. In every case supervision must
  continue: bookkeeping failures never outrank keeping PID 1 alive. Two cover
  the worker-table boundary — the table is a fixed `[64]`, so exactly-full
  must supervise cleanly and one-over must be rejected rather than overrun it.

## [1.0.2] - 2026-07-20

Third hunting pass, widening the harness past parsers into the pure logic and
the persisted-state paths. Four more traps, all reachable without a hostile
actor — a corrupt state file or an unusual `/proc` read is enough.

### Fixed
- **Overflow in `civilFromEpoch`** (`spool.zig`). Near the `i64` extremes,
  `@divFloor(secs, 86_400) * 86_400` falls outside `i64`. This runs on the
  **incident-write path**, so it killed PID 1 exactly when a worker had
  crashed and mandor was recording why — and it was reachable end-to-end: a
  corrupt `history.json` clamps a timestamp to `maxInt(i64)`, which flows into
  the bundle as `history_first_epoch`. Epochs are now clamped to the range
  ISO-8601's 4-digit year can express.
- **Overflow in `sampler.cpuPct`** — `dticks * 1000 * 100` on tick counts from
  `/proc`. On the sampler tick path, which runs every 5s for the life of the
  container. Now saturating, as are `utime + stime` and `rss_pages * page_kb`.
- **Overflow in the cost accumulators** (`cost.zig`). `idle_n`/`active_n` and
  the histogram buckets are `u32` counters that persist in `cost.json` across
  restarts; a corrupt file seeds one at `maxInt(u32)` (post-clamp) and the next
  sampler tick's `+= 1` trapped. `Profile.summary()` also summed two `u32`
  counters into a `u32`. Increments now saturate and the sum is widened.
- **`backoff.next` could exceed the configured cap.** The stable-uptime reset
  returned `initial_delay_ms` (200ms) unclamped, so `--backoff-max` below
  200ms was violated after a worker had run 10s. Every path now clamps.
### Changed
- Fuzz harness widened from 7 targets to 12: the bundle serializer (with
  adversarial epochs and strings), the capture ring buffer, the cost
  accumulators, `cpuPct`, and `backoff`. The last two assert *invariants*
  rather than mere survival — backoff must never exceed its cap, and the ring's
  record count must match what iteration yields.
### Notes
- Audited and found clean: every untrusted string reaching JSON goes through
  `appendJsonString` (so incident bundles were never corruptible), and time
  subtraction across the supervisor already used saturating `-|` throughout.

## [1.0.1] - 2026-07-20

A second hunting pass over the untrusted-input surface, after finding that one
fuzz target had been silently testing nothing.

### Fixed
- **Integer-cast trap loading a corrupt `history.json`**
  (`history.loadFromText`). A recurrence timestamp past `maxInt(i64)` trapped
  on the `@intCast` — and this runs on the startup load path, so it killed
  PID 1. `count`/`builds` were already clamped; `first`/`last` were not.
- **Prometheus label injection via worker names.** A worker name is a
  basename, so it can hold any byte a filename can, and it was interpolated
  raw into `worker="…"`. A quote or backslash silently corrupted every scrape.
  Names are now neutralized once at derivation, so all sinks benefit. (JSON
  sinks were already correctly escaped — bundles were never affected.)
- Histogram counts from a corrupt `cost.json` used wrapping arithmetic, which
  could not crash but could load nonsense values. Now saturating.
### Changed
- One `report.clamp(T, v)` helper replaces the `@intCast(@min(…, maxInt(T)))`
  pattern that was duplicated across `history.zig` and `cost.zig`. The
  duplication *was* the bug class: the one site that forgot the clamp is the
  crash above. The safe form is now the short form.
- `--help` no longer enumerates advanced flags. The list had already drifted
  out of date (it omitted `--max-restarts`, `--health-start-period`, and
  `--on-incident`), and it duplicated the man page and `docs/CONFIG.md`.
  Advanced settings are pointed at `mandor.toml` instead. No flag changed;
  every existing flag still works.
- Fuzz harness: added an argv/command-tokenization target, and corrected the
  `history.json` seed. The old seed used `"sig":123` where the loader keys off
  `{"sig":"` plus a fixed 16-digit hex field, so it matched nothing and fuzzed
  an early return — which is why the crash above survived 1.0.0.

## [1.0.0] - 2026-07-20

First stable release. The supervision path is now hardened against the inputs
it cannot trust, which was the last item standing between 0.x and 1.0.

### Added
- Mutation-fuzzing harness (`src/fuzz.zig`) over every parser that consumes
  untrusted input: worker stderr through the six trace parsers, the worker's
  ELF header, `mandor.toml`, `/proc` and cgroup pressure text, and mandor's
  own state files. Seeded with real crash output in `test/fixtures/`, with a
  boundary-value dictionary and a structured ELF generator. It runs inside
  `zig build test` (fresh seed per invocation) and across 12 seeds in CI;
  failures replay with `zig build test --seed 0x…`.
### Fixed
- **Integer overflow parsing a malformed ELF header** (`elf.zig`). mandor
  reads a worker's ELF at spawn time to extract its build-id; a corrupt,
  truncated, or hostile binary could wrap the program-header offset
  arithmetic and panic PID 1 — killing the container. All offsets derived
  from file bytes now saturate.
- **Integer overflow parsing cgroup pressure text** (`sampler.parsePsiAvg60`).
  A long digit run in a corrupt `*.pressure` file overflowed the accumulator;
  it now saturates and clamps as before.
- Formatting drift in `spool.zig` that had been failing the CI `zig fmt
  --check` step since 0.19.0.

## [0.20.0] - 2026-07-19
### Added
- Shift report — at shutdown mandor prints one consolidated summary of the
  whole run to stdout: worker count, run duration, total restarts and
  incidents, then per worker its exit code, restarts, peak RSS, and GB-hours.
  A human (`kubectl logs`) or an AI post-mortem sees what happened across the
  container's whole life without scraping the incident spool. Zero config,
  always on; reuses the worker table and cost profiles.

## [0.19.0] - 2026-07-19
### Added
- Release-aware incident correlation — "did your fix work?". Each crash
  signature now remembers which builds it appeared on; when the same crash
  recurs after a code change, mandor flags it a regression. Bundles gain
  `history.builds` / `first_build` / `last_build` / `regressed`, and
  `report --incidents` marks it inline (`[REGRESSED v1.0.0->v1.0.1]`). This
  is the feedback edge of the incident → AI-fix → redeploy loop: mandor now
  tells the developer (or the premium agent) whether the last fix held. Uses
  the `MANDOR_RELEASE`/`GIT_SHA` passthrough already captured; with no
  release wired it degrades silently (zero config).
### Changed
- Incident bundle schema v6 → v7 (added the `history` build fields).
  `history.json` → v2 (build correlation persisted; v1 files still load).

## [0.18.0] - 2026-07-19
### Changed
- Faster log capture (nanozlog-inspired hot path). Complete lines that arrive
  contiguous in one read now go straight from the read buffer to the ring and
  the batched `writev` — the intermediate line-assembly copy is skipped for
  the common case (only lines that straddle a read boundary are staged). The
  pipe read buffer is sized to a pipe's 64 KB capacity, so a saturated pipe
  drains in one `read()` instead of ~16 under log spam. No new config, no
  behavior change; fewer syscalls and one less copy per line.

## [0.17.0] - 2026-07-18
### Added
- `mandor report --cost` — per-worker resource-cost profiling: idle / typical
  / peak RSS and CPU (idle-vs-active inferred from the CPU signal, zero worker
  cooperation), GB-hours, CPU-core-seconds, duty cycle, and a right-sizing
  suggestion (memory limit, CPU request/limit). `--json` for the LLM/premium
  agent. Profiling is automatic; the profile persists in
  `<state-dir>/cost.json` (fixed-size histograms, no allocation) and
  accumulates across worker restarts.

## [0.16.0] - 2026-07-18
### Added
- PSI stall detection: samples cgroup v2 memory/cpu/io pressure once per
  tick; `psi_mem_pct`/`psi_cpu_pct` thresholds raise a `stall:memory|cpu`
  incident attributed to the largest consumer. PSI recorded in every
  bundle stats timeline (schema v6).
- Per-worker `cap_drop` (capability bounding-set drop; names or "all") plus
  automatic `no_new_privs` after a uid drop — closes the setuid
  re-escalation hole. No libcap dependency.
- `limits.core` (RLIMIT_CORE) in bundles, alongside the existing
  core_dumped flag.
### Notes
- #37 JSON supervisor-log folded into existing paths: offline = plain
  `[mandor]` stdout lines; online = photon. No separate sink built.

## [0.15.0] - 2026-07-18
### Added
- `mandor validate [--config=PATH]` — dry-run config check (bad values,
  cycles, and unknown worker references), sharing run()'s exact setup path.
- `mandor report --incident=N` — dump one bundle raw; incident list now
  numbered oldest-first.
- Version stamped into the binary at build time (`-Dversion=`).
- `docs/mandor.1` man page, `CONTRIBUTING.md`, `examples/` recipes
  (web+worker+cron, migrations, photon).
### Changed
- Setup phase extracted to a shared `applyConfig` so `run` and `validate`
  can never drift.

## [0.14.0] - 2026-07-18
### Added
- Zig panic-trace parser (dogfood) — six languages now: Go, Rust, Python,
  Zig, Java, Node.
- `mandor report [NAME|PID]` row filtering; `report --incidents [NAME]
  [--since=DUR]` history filtering; `h` duration unit.
- HEALTH column and distinct `recycling` / `gave-up` labels in `report`.
- `docs/CONFIG.md` — complete configuration reference.
- CI: capture perf-regression gate; aarch64 unit tests under qemu.
### Changed
- Setup code DRY: one table drives all per-worker settings (bad values now
  consistently fail startup).

## [0.13.0] - 2026-07-18
### Added
- `restart_dependents = true` — OTP `rest_for_one`: a dependency's restart
  recycles its `start_after` dependents (planned, never counted as failure).
- `pre_stop = ["name=CMD"]` drain hooks: on graceful shutdown the hook runs
  first and TERM follows its completion; stop-grace KILLs hung hooks.
### Removed
- `replicas` scaling rejected permanently: replication belongs outside the
  binary (scripts/orchestrator).

## [0.12.0] - 2026-07-18
### Added
- Node.js and JVM stack-trace parsers: structured `file:line` frames with
  `in_app` heuristics (`node:`/`node_modules`, `java.`/`jdk.`/`kotlin.`
  filtered), first-class exception type/message, Caused-by chains in raw.
- Relay bearer-token auth: set `PHOTON_TOKEN` and `mandor relay` sends
  `Authorization: Bearer …` (env-inherited, never on the cmdline).
### Docs
- photon-side contribution spec (`docs/photon-contrib/`): exact OTLP/JSON
  ingest change for photon's `/v1/logs`, written from code reconnaissance.

## [0.11.1] - 2026-07-17
### Changed
- nanozlog-inspired batched capture: one `writev` (and one clock read) per
  drained pipe instead of per line — 2.1× wall, 6× less kernel time on a
  200k-line burst.

## [0.11.0] - 2026-07-17
### Added
- TTY color-cycled `[name]` prefixes (real terminals only; piped logs stay clean).
- `env_file` — KEY=VAL file loaded into every worker's environment.
- `essential` workers — leader semantics: its exit stops the fleet and
  propagates its code (Nomad leader-task heritage).
### Fixed
- No-orphan hardening: `PR_SET_PDEATHSIG` on workers (TERM) and probes
  (KILL) with fork-race guard; process-group sweep when a worker dies so
  grandchildren never linger across restarts.

## [0.10.1] - 2026-07-17
### Changed
- Size diet: custom raw panic handler severs std.debug's machinery —
  **487 KB → 214 KB** (x86_64), safety checks unchanged.

## [0.10.0] - 2026-07-17
### Added
- Kubernetes termination-log death rattle: when `/dev/termination-log`
  exists, incidents rewrite it so `kubectl describe pod` shows the verdict.
- Recycle thresholds `max_rss_mb` / `max_lifetime` — planned recycling that
  never counts as failure (pm2 `max_memory_restart` heritage).
- Per-worker `restart` policy overrides.

## [0.9.1] - 2026-07-17
### Changed
- photon integration folded into the single binary: `photon = "ip:port"`
  auto-forwards incidents via a fire-and-forget self-exec relay; mandor
  stays fully offline until the key is set.

## [0.9.0] - 2026-07-17
### Added
- Per-worker privilege drop `user = "name=uid:gid"` (fail-closed).
- `oom_score_adj` / `nice` per-worker knobs.
- Alpine `APKBUILD` (packaging/alpine) and release `.deb`/`.apk`/`.rpm`
  packages via nFPM.

## [0.8.0] - 2026-07-17
### Added
- `max_restarts` give-up: consecutive failed restarts make mandor exit with
  the flapping worker's code — visible to the orchestrator.
- `on_incident` hook: exec any command with each bundle path (no shell).
- Health-check `start_period` grace (default 10s; the startupProbe lesson).
- Oneshot init tasks (migrations-before-workers; failure aborts startup).
- Per-worker `env` / `cwd`.

## [0.7.1] - 2026-07-17
### Added
- Distro CI matrix (Alpine/Debian/Ubuntu run the full harness).
- Package publishing in releases.

## [0.7.0] - 2026-07-17
Initial public release — everything from the v0.1–v0.7 build-out:
- multirun parity: spawn N workers, restart policies + exponential backoff,
  zombie/orphan reaping, worst-exit-code propagation.
- dumb-init parity: full signal forwarding (TERM/INT/HUP/QUIT/USR1/USR2/
  WINCH) with per-worker process groups; stop-grace TERM→KILL escalation.
- Log capture: 256 KB ring buffers, timestamped lines, `[name]` prefixes.
- /proc sampler (CPU/RSS/fds/threads), state file, `mandor report`
  (+ `--json`, `--incidents` history recall with 200-file retention).
- Incident bundles (schema v5): structured cause/exception/frames
  (file:line/in_app), spawn snapshot, ELF build-id, `MANDOR_RELEASE`,
  deduplicated log tail with repeat counts, siblings, persistent recurrence
  history; Go/Rust/Python trace parsers; restart-loop / RSS-leak / cgroup
  OOM detection; heuristic diagnosis verdicts.
- Health checks + `--restart-on-unhealthy`, s6-style readiness fd,
  `start_after` ordering, `--expected-exit`.
- Prometheus text endpoint, TOML config (CLI-only always works),
  GitHub Releases + ghcr.io multi-arch image.
