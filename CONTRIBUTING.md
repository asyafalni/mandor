# Contributing to mandor

Thanks for helping. mandor is a small, opinionated tool — the bar for new
features is high, but fixes, tests, parsers, and docs are always welcome.

## Build & test

Requires [Zig 0.16.0](https://ziglang.org/download/#release-0.16.0) exactly
(pinned in `.zigversion`).

```console
zig build                 # debug build
zig build test            # unit tests
zig build && bash test/harness/run_tests.sh   # integration harness
zig fmt src build.zig     # formatting (CI enforces --check)
```

The harness needs Linux (PID-1/signalfd/procfs semantics). CI runs the full
suite on Alpine, Debian, and Ubuntu.

### Container (real PID 1)

```console
bash test/container/run.sh                 # podman by default
ENGINE=docker bash test/container/run.sh
```

The host harness runs mandor as an ordinary process: nothing is reparented to
it, and the process-group behaviour it relies on is never exercised. These
cases cover what the host cannot — that mandor really is PID 1, that it reaps
grandchildren the kernel reparents to it, that a grandchild's own TERM handler
drains rather than being cut short by the post-death sweep (the v1.5.1 case),
and the exit-code contract an orchestrator reads. It skips cleanly when no
container engine is present.

Set `MANDOR_MUSL=/path/to/mandor` to supply a prebuilt static binary instead of
cross-compiling — needed where the toolchain and the container engine live in
different environments (a Windows box building under WSL but running
`podman.exe` on the host).

`MANDOR_REQUIRE_ENGINE=1` turns a missing engine into a failure instead of a
skip. CI sets it: a job that goes green because it never ran is worse than no
job, and this suite exists precisely to catch tests that pass without testing.

CI runs this as its own `pid1` job. The existing `distros` job runs the harness
*inside* a container, but the runner's entrypoint is PID 1 there, so mandor is
still an ordinary process — only making mandor the ENTRYPOINT exercises orphan
reparenting and process-group signalling as init.

### photon end-to-end

```console
git clone https://github.com/nevindra/photon && (cd photon && podman build -t photon:latest .)
bash test/photon/e2e.sh
```

Everything else verifies mandor's half of the OTLP contract against a listener
we wrote, which only proves the bytes match *our reading* of photon. This runs
the real collector: crash a worker, let the relay ship the incident, then query
it back through photon's own API. It skips unless `photon:latest` is built
locally, since compiling photon is a multi-minute Rust build.

### Soak

```console
bash test/harness/soak.sh                    # ~2 min, the CI default is 3
SOAK_SECONDS=1800 bash test/harness/soak.sh  # deep local run
```

Runs capture, the sampler, restart churn, incident writes, health probes, and
the metrics listener all at once, then asserts mandor's **own** RSS, fd count,
and thread count stay flat. This is what backs the "zero allocations in steady
state" claim — treat a drift failure as a leak until proven otherwise. Fixed
buffers fault in lazily, so early samples are discarded (`WARMUP_PCT`).

Same rule as the fuzzer: **don't trust a green soak.** It was calibrated by
injecting a 64 KB-per-tick leak into the supervisor and confirming it fails
(640 KB drift vs a 256 KB budget, against 4-8 KB on a clean build). Inject the
leak on the *sampler tick*, not the poll loop — under full-rate log spam the
poll loop allocates gigabytes in seconds and simply OOM-kills mandor, which
tests nothing.

Two footguns, both found the hard way on 30-minute runs:

- Anything the script writes to a socket needs a subshell and `|| true`. The
  metrics endpoint closes the connection after responding, so a write that
  loses that race raises **SIGPIPE and kills the soak itself** (exit 141) —
  rare per scrape, near-certain across a long run. The script now also
  `trap '' PIPE`s.
- Bash reads a script incrementally as it executes, so editing `soak.sh` while
  a long soak runs can corrupt that run. Snapshot it
  (`cp test/harness/soak.sh /tmp/soak.sh`) before a long session.

### Speed (`bench/`)

```console
zig run bench/scan.zig -OReleaseSafe    # substring-scan cost per incident
zig run bench/cold.zig -OReleaseSafe    # compactor + prune sort
bash bench/compare.sh                   # vs tini/dumb-init/s6/supervisord
```

"Fast like the flash" is a motto term, so it gets numbers, not adjectives. The
hot path (per log line) has no super-linear work; the cold path (per incident)
tops out around 1.7 ms. See `bench/README.md` for the measurements and — just
as important — the recorded decisions *not* to optimize, so nobody re-derives
them. One lesson lives there: a predicted 26× substring win measured 1.16×,
because the naive loop already short-circuited. Measure before optimizing.

### Spawn-failure behaviour

A failed `fork` is impractical to trigger on demand (`ulimit -u` starves the
test harness before it starves mandor), so these paths are verified by
injection: add an early `return error.ForkFailed;` to `spawner.spawn` for one
named worker, rebuild, and check the behaviour. Four cases, all of which must
hold:

| Setup | Expected |
|---|---|
| plain worker, `--restart=on-failure` | `failed to start` → `restarting in 200ms` → recovers when the injection clears |
| plain worker, `--restart=never` | `failed to start`, no retry, exit 125 |
| `essential = true` | `essential worker … stopping all`, fleet stops, exit 125 |
| `oneshot = true` | `init task … failed, shutting down`, dependents never start |

The reason they all matter: a failed spawn is routed through the *death* path
precisely so restart policy, `essential`, and `oneshot` apply to it. Handling
it at the spawn site would bypass all three — which is exactly the bug fixed in
1.2.0, where a failed init task read as a *completed* one and released its
dependents.

If you touch this, also re-check the loop-exit accounting: a worker whose spawn
failed is neither live nor pending until the death path runs, so it is counted
via `w.spawn_failed` in the tally. Do **not** add a term to the `break`
condition instead — an extra term there makes the compiler duplicate the loop
body and costs ~6 KB of `.text` for identical behaviour.

### Fuzzing

`src/fuzz.zig` mutation-fuzzes everything that consumes input mandor does not
control: worker stderr (the six trace parsers), the worker's ELF header,
`mandor.toml`, argv, `/proc` and cgroup text, mandor's own state files, the
incident-bundle serializer, the capture ring buffer, and the cost
accumulators. It runs as part of `zig build test`, with a different seed each
invocation.

```console
zig build test --seed 0xdeadbeef   # replay a specific seed
```

A failure prints the seed it ran with — pass it back to reproduce exactly.
Touching a parser? Run a handful of seeds before pushing, and raise
`iterations` in `src/fuzz.zig` for a deep local session.

The property is **survival, not correctness**: return values are ignored, and
a panic is the only failure. That is the whole point — a parser panic kills
PID 1, which kills the container. Two rules follow, and both have already been
learned the hard way:

- **Arithmetic on untrusted bytes must saturate** (`+|`, `*|`) rather than
  risk a ReleaseSafe overflow trap. To narrow a scanned value, use
  `report.clamp(T, v)` — never a bare `@intCast`. "Untrusted" includes
  mandor's own persisted state: `history.json` and `cost.json` survive
  restarts, so a corrupt file can seed a counter at its maximum and the next
  increment traps. Watch mixed widths too — `u32 + u32` stays `u32`.
- **A seed must be a valid input, matching the real format byte-for-byte in
  shape.** This has bitten three times: the `history.json` seed used
  `"sig":123` while the loader keys off `{"sig":"` plus a fixed 16-hex-digit
  field; `report_seed` lacked the `ts_ms` that `formatHuman` requires; and
  `cli_seed` kept flags that a release had moved to TOML. Each made its target
  fuzz an early error while reporting green — a broken seed makes the suite
  *greener*, never redder, which is why it hides so well. The `seed valid: …`
  tests are the guard: **if you add or change a seed, assert it parses and
  populates what the target reads.** Changing a config format or removing a
  flag means revisiting the seeds.

And a rule for the harness itself: **do not trust a green fuzzer.** Revert a
known fix and check the harness catches it. That check is what upgraded the
mutator from byte flips (1-in-5 detection) to a boundary-value dictionary plus
a structured ELF generator (8-in-8).

Note: coverage-guided `zig build test --fuzz` is unusable on the pinned Zig
0.16.0 (its fuzz-mode test runner fails to compile with error tracing on, and
instruments zero PCs with it off), which is why the harness is in-repo.

## Ground rules

- **Size is a feature.** The stripped ReleaseSafe binary must stay under
  500 KB (CI gates it); it currently sits near ~248 KB. A new dependency or
  a large `std` pull-in needs a very good story.
- **PID 1 must not die.** No panics on the supervision path; every syscall
  error is handled. No allocations in the steady state (fixed buffers).
- **Offline by default.** The binary opens no network connection unless the
  user configures one (`--metrics`, `photon`).
- **Simplicity is a product value.** Prefer sane defaults over new flags;
  keep the everyday `--help` short. New config lands as TOML keys, not CLI
  flags, unless it's genuinely everyday.
- **Every behavior change ships with a harness case**, and any incident
  bundle change bumps the schema `"v"` with an updated golden test.

## Good first contributions

- New language trace parsers (see `src/parsers/` — Go/Rust/Python/Zig/Node/
  JVM exist; C++ needs symbolization and is deliberately deferred).
- Additional `mandor validate` checks.
- Example recipes under `examples/`.

## Scope

Planned and deliberately-rejected features (with rationale) live in
[docs/ROADMAP.md](docs/ROADMAP.md) — please skim it before proposing a
feature, so we don't re-litigate a settled decision.
