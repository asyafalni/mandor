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

### Fuzzing

`src/fuzz.zig` mutation-fuzzes every parser that touches untrusted input:
worker stderr (the six trace parsers), the worker's ELF header, `mandor.toml`,
`/proc` and cgroup text, and mandor's own state files. It runs as part of
`zig build test`, with a different seed each invocation.

```console
zig build test --seed 0xdeadbeef   # replay a specific seed
```

A failure prints the seed it ran with — pass it back to reproduce exactly.
Touching a parser? Run a handful of seeds before pushing, and raise
`iterations` in `src/fuzz.zig` for a deep local session.

The property is **survival, not correctness**: return values are ignored, and
a panic is the only failure. That is the whole point — a parser panic kills
PID 1, which kills the container. Any arithmetic on a value read from
untrusted bytes must saturate (`+|`, `*|`) rather than risk a ReleaseSafe
overflow trap.

Note: coverage-guided `zig build test --fuzz` is unusable on the pinned Zig
0.16.0 (its fuzz-mode test runner fails to compile with error tracing on, and
instruments zero PCs with it off), which is why the harness is in-repo.

## Ground rules

- **Size is a feature.** The stripped ReleaseSafe binary must stay under
  500 KB (CI gates it); it currently sits near ~230 KB. A new dependency or
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
