# mandor: declarative checks — `[require.*]` boot gates + `[prober.*]` monitors

> Design doc. Target: **v1.15.0**. Two small, reusable "run a command and react"
> capabilities, distilled from the visionaire4_app supervisor-replacement grilling.
> They exist so a deployment can declare **boot preconditions** and **periodic
> status checks** in TOML, while every vendor/app-specific detail stays in the
> command the check runs. mandor writes no GPU code and gains no new restart path.

## Why (the visionaire4_app cutover)

Replacing a bespoke Python supervisor for `visionaire4_app` mapped almost
entirely onto primitives mandor already has (`oneshot` gate, `health`
restart-probe, sidecar worker, `max_restarts`/`backoff_max`). Two ergonomic gaps
remained, each worth a first-class, reusable knob:

1. **Boot precondition gating** — "refuse to start unless the GPU/driver
   requirement is met." Achievable today with a `oneshot` worker, but a
   dedicated `[require.*]` reads as intent and logs a clear rejection.
2. **Periodic status monitoring** — a status checker (pipeline/seat/license
   probe) that runs on a timer and **reports**, without the check script having
   to own a `while true; sleep` loop. `[prober.*]` lets mandor own the interval.

**Non-negotiables carried from the grilling:**
- mandor never parses GPU hardware itself. Both features run an operator-supplied
  **command** (which calls `nvidia-smi`/`rocm-smi`/`xpu-smi`/`curl`/…). No
  vendor code, no version-string parsing, in the <500KB core.
- **One restart authority per worker: `health`.** The prober is report/incident
  only — it never restarts anything (a second restart path would race `health`
  and corrupt `max_restarts` accounting). Deep/zombie/hung → bundle the checks
  into the worker's `health` command.
- Offline-by-default is unchanged: a prober's `report`/`incident` output ships to
  photon only when `photon=` is set; otherwise it logs locally. `[require.*]`
  and `[prober.*]` never open a socket themselves.

## Feature 1 — `[require.NAME]`: fail-closed boot preconditions

A boot gate. Before any worker (or oneshot) is spawned, mandor runs each
`[require.*]` check; a non-zero exit **aborts the boot** — mandor logs the
rejection and exits non-zero, so the container runtime's restart policy decides
what happens next (mandor never reboots the host).

```toml
[require.gpu-driver]
check   = "/opt/checks/gpu-require.sh --driver-min 525"   # calls nvidia-smi etc.
timeout = "60s"                                            # optional; default 60s
```

**Semantics (settled):**
- **Order:** `[require.*]` → `oneshot` init tasks → regular workers. Requires
  answer "can we start at all?"; oneshots are "init work"; both precede the fleet.
- **Runs once**, at boot only. Any waiting/retry (e.g. the old "wait 30s for the
  nvidia driver") lives *inside* the check script, not in mandor.
- **All must pass.** The first failing require aborts boot; mandor prints
  `[mandor] requirement '<name>' not met (exit <n>)` plus the check's captured
  stderr tail, then exits non-zero.
- **`timeout`** bounds a hung check (default **60s**); a timeout counts as
  failure with a distinct message. Fail-closed everywhere.
- **`mandor validate`** parses and reports `[require.*]` but does **not** execute
  the checks (validate never spawns) — it only confirms the config is sound.
- Output is **local log only** (boot never completed → no incident/telemetry).

**Keys:** `check` (string, required), `timeout` (duration, optional, default 60s).
Unknown key → hard error, like every other section.

## Feature 2 — `[prober.NAME]`: periodic status monitors (report-only)

A recurring check mandor runs on a timer once the fleet is up. It **reports** the
result; it never restarts or gates.

```toml
[prober.pipeline-status]
check    = "/opt/checks/pipeline-status.sh"   # simple check-once script; mandor loops it
interval = "2m"                               # required
on_fail  = "report"                           # "report" (default) | "incident"
timeout  = "10s"                              # optional; default 10s
```

**Semantics (settled):**
- **mandor owns the interval.** The check is a run-once command; mandor schedules
  it every `interval`, spawns it non-blocking on the poll loop (reusing the
  `health`-probe machinery — spawn, bounded poll, reap), and never blocks PID 1.
- **Starts after boot** (after requires pass and workers are spawned). Does not
  count toward `max_restarts` and cannot restart anything.
- **`on_fail`:**
  - `report` (default) — a failing check emits one OTLP **log** record to photon
    (name, exit code, output tail) and a local warn line; a passing check is
    quiet (debug-level).
  - `incident` — a failing check additionally spools an **incident bundle**
    (shows in `report --incidents` + photon), **subject to the existing incident
    dedup cooldown** so a persistently-failing prober can't flood the spool.
- **`fail_threshold`** (optional, default **1**): consecutive failures before
  `on_fail` fires, so a flaky one-off doesn't alarm. (Defaulting to 1 keeps
  simple monitors immediate; raise it for noisy checks.)
- **`timeout`** bounds a hung check (default **10s**), counted as a failure.

**Keys:** `check` (string, required), `interval` (duration, required), `on_fail`
(`report`|`incident`, optional, default `report`), `timeout` (duration, optional,
default 10s), `fail_threshold` (int ≥1, optional, default 1). Unknown key → hard
error.

## Non-goals (explicitly rejected in the grilling)
- **No restart in the prober.** `health` is the sole restart authority per worker.
- **No GPU/vendor/version code in mandor.** The check command owns all of it.
- **No cross-target restart, no multiple-`health`-probes-per-worker.** If a real
  need appears later, each is its own deliberate feature — not smuggled in here.
- **No host reboot.** mandor exits non-zero; the runtime recovers.

## Where it plugs in
- `src/cli.zig` — `Config`: add fixed arrays for require checks
  (`require: [max_require]ReqDef`) and probers (`probers: [max_probers]ProbeDef`),
  each a small struct (name, cmd, timeout, and prober's interval/on_fail/
  threshold). Fixed capacity (e.g. 8 each), zero-alloc.
- `src/config.zig` — parse `[require.NAME]` / `[prober.NAME]` sections (new
  `Section` kinds + per-section key handlers), pure, fail-loud on bad values.
- `src/supervisor.zig` — run `[require.*]` in the boot path before `spawner`
  brings workers up (reuse the check-spawn+reap+timeout helpers); drive
  `[prober.*]` from the existing poll loop next to `runHealth` (a prober timer
  per probe, `spawnCheck`-style, `on_fail` action on threshold). `validate`
  reports both without executing.
- `src/main.zig` — merge the two arrays from the parsed file config; migration
  errors already cover removed keys (no change needed here).
- Telemetry: a prober `report` reuses the lifecycle-event OTLP log path; `incident`
  reuses the incident spool + dedup cooldown. Both inert without `photon=`.

## Testing
- **Unit (config):** `[require.*]`/`[prober.*]` parse to the right structs;
  defaults (timeout 60s/10s, on_fail=report, fail_threshold=1); unknown key and
  bad duration/`on_fail` value are hard errors.
- **Behavior (supervisor):** `validate` passes with requires/probers present and
  does not execute them; a require's non-zero check aborts boot with the named
  message; a prober fires `on_fail` at `fail_threshold` and never touches
  `max_restarts`; `on_fail=incident` respects the dedup cooldown.
- **Harness e2e:** a `[require.*]` with a failing check aborts boot (exit
  non-zero, message logged); a passing require lets the worker start; a
  `[prober.*]` with a failing check emits a report/incident while the worker
  keeps running (proving no restart).
- fmt / `zig build test` green; **size gate < 500KB**; mutate each new guard
  (timeout=0, threshold=0, unknown on_fail).

## Constraints (motto governs)
Stability: requires run at boot (off the steady-state path); probers reuse the
non-blocking, bounded, zero-alloc health-probe machinery on the poll loop — no
new blocking syscalls on PID 1, no panics/`unreachable`, every check
fail-closed. Simplicity: two small sections, each a command + a couple of knobs;
no vendor/GPU logic enters the core. Bump to **v1.15.0**.

## Sequencing note
The visionaire4_app cutover itself (the consumer: `mandor.toml` + entrypoint for
device-mode detection, `health = "curl …"`, the sidecar/prober monitor, the
`[require.gpu-driver]` gate) is a **separate follow-up** in the app's repo, done
once these features land and are proven — not part of this branch.
