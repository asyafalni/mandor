# bench/ — where "fast like the flash" gets numbers

The motto has three terms. Stability and size are gated in CI; speed is the one
that needs evidence rather than assertion. This directory holds it.

## Complexity micro-benchmarks (algorithmic cost)

```
zig run bench/scan.zig -OReleaseSafe
zig run bench/cold.zig -OReleaseSafe
zig run bench/hotline.zig -OReleaseSafe
```

`scan`/`cold` measure the two places with worse-than-linear *shape*, both on the
**cold** (per-incident) path. `hotline` measures the one per-line **hot**-path
cost that only appears when `photon=` is set: the warn/error severity classifier
(`summarize.logSeverity`), which runs on every captured line so the Tier-2 digest
can bucket it.

### Findings (2026-07-22, x86_64 WSL, ReleaseSafe)

| Term | Where | Theoretical | Measured | Kept? |
|---|---|---|---|---|
| `errorish` × 200-line tail | `summarize` | 44M char-ops | **0.29 ms** | yes |
| `Compactor.feed`, full 256 KB ring | `summarize` | O(200 × 10k) | **1.37 ms** | yes |
| `listIncidents` insertion sort | `spool` | O(216²) | **0.014 ms** | yes |

**Nothing is worth changing, and that is the recorded conclusion — not a
to-do.** The reasoning, so no one re-optimizes on a hunch:

- All three are per *incident*, not per line. Incidents fire on crashes. Even a
  restart loop (5 deaths / 5 min, the detector threshold) spends ~8 ms total.
- Replacing the compactor's linear scan with a hash table adds a table, a hash
  policy, and collision handling to save ~1 ms on a cold path — it fails YAGNI
  and now the per-commit size gate too.
- `errorish` was *predicted* to be a 26× win from a first-byte fast-reject.
  Measured: **1.16×**. The naive inner loop already short-circuits on the first
  mismatched byte, so the "optimization" was already happening. Measure before
  optimizing.

The offline hot path — `Assembler.feed`, `echoLine`, `ring.push` — is O(line
length) with no scan, sort, or search per line. That path "fast like the flash"
is really about, and it is already optimal.

### `logSeverity` classifier, photon on (2026-08-21, x86_64 WSL, ReleaseSafe)

`hotline.zig` measures the per-line severity classifier that runs **only when
`photon=` is set** (offline, it never executes — so this never contradicts the
"offline hot path is optimal" line above). Worst case is a high-volume INFO
flood: every line is scanned to full length, finding no keyword.

Numbers are noisy on this WSL2 VM (5 isolated runs shown as a range); the
*structural* win is the reliable part — the old form lowercased each byte up to
six times, the new one does it once.

| Variant | Measured (187 B line, 5 runs) | Kept? |
|---|---|---|
| per-position ×6 `kwAt` (pre-v1.15.5) | **~1.3–1.7 µs/line** | no |
| first-char dispatch (v1.15.5) | **~0.4–0.7 µs/line** (~**2–4×**) | yes |

Unlike `errorish`, this one *was* worth changing — and only measurement showed
why. `errorish`'s inner loop short-circuits on the first byte; `logSeverity`
did not — it probed six keywords at every position, re-lowercasing the same
character six times. A `switch` on one `toLower(line[i])`, dispatched on the
keyword initial (each is distinct: error/exception→`e`, panic→`p`, fatal→`f`,
traceback→`t`, warn→`w`), computes the lowercase once and reaches only the
keyword(s) that could match. Byte-identical (a fuzzed differential test vs a
whole-line `containsIgnoreCase` reference guards it). At a 100k line/s flood
this is ~140 ms/s of a core down to ~50 ms/s — CPU, the top-priority resource,
on the one per-line branch that scales with external load. (The measured
multiple swings 2–4× with VM load; ~6× fewer `toLower` calls per byte is the
floor the constant factors erode.)

## End-to-end comparison (vs other init/supervisors)

```
bash bench/compare.sh          # podman by default; ENGINE=docker also works
```

Builds one Alpine image with mandor, tini, dumb-init, s6, and supervisord, then
measures the dimensions that matter for a PID-1 supervisor. Skips cleanly when
no container engine is present. Results are printed, not committed — they are
machine-specific; what's committed is the reproducible method.

### Findings (2026-07-22, Alpine 3.20 under podman, x86_64)

| | mandor | tini | dumb-init | s6 | supervisord |
|---|---|---|---|---|---|
| deployable size | 256 KB | 28 KB | 59 KB | 1.0 MB (63 files) | 40 MB (Python) |
| single static binary | ✅ | ✅ | ✅ | ❌ suite | ❌ needs runtime |
| idle RSS as PID 1 (KB) | **384** | 564 | 72 | — | — |
| TERM → worker (ms, best of 5) | 2 | 93 | 2 | — | — |

**Read this honestly:**

- **mandor is not the smallest binary, and does not claim to be.** tini and
  dumb-init are ~30–60 KB because they *only* reap zombies and forward signals.
  mandor is 256 KB because it also captures logs, samples `/proc`, detects
  incidents, parses traces, and forwards to photon. The fair comparison by
  *scope* is s6 and supervisord — and there mandor is one static binary against
  a 63-binary suite and a 40 MB Python install.
- **Idle RSS is now *below* tini** (384 KB vs 564), and flat — the soak holds
  it at zero drift over 30 minutes. This took a fix: Zig installs a 256 KB
  `sigaltstack` at startup so a signal handler can print a stack trace, and
  mandor prints none (custom panic, segfault handler off, signalfd rather than
  async handlers). Setting `signal_stack_size = null` dropped idle RSS from
  640 KB to 384. What's left is ~208 KB of code pages — intrinsic to the work —
  plus the ring, which faults in only as logs are actually written.
- **Signal forwarding is fast**: 2 ms, matching dumb-init. tini's 93 ms is
  likely its default forwarding mode rather than raw speed — treat the reaper
  numbers as "all effectively instant". The 5 ms poll granularity puts
  single-digit readings at the measurement floor.

The honest one-line summary: **mandor does far more than a bare reaper, is
lighter than every tool in its actual feature class, now idles below tini, and
forwards signals as fast as the reapers — as a single dependency-free static
binary.**

s6 and supervisord are compared on footprint only; running them needs a service
directory, out of scope for this quick pass. Their idle-RSS and latency would
round out the table but are unlikely to change the shape of the story.
