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
