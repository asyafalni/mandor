# Declarative Checks Implementation Plan — `[require.*]` + `[prober.*]`

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add two small TOML-declared "run a command and react" features to mandor — `[require.NAME]` fail-closed boot gates and `[prober.NAME]` periodic report/incident monitors — without any GPU/vendor code and without a new restart path.

**Architecture:** `[require.*]` runs a bounded command at boot before any worker; non-zero aborts boot. `[prober.*]` runs a command on a timer from the poll loop (mirroring the non-blocking `health` machinery) and reports/incidents on failure — never restarts. Both call operator-supplied commands (nvidia-smi/curl/etc.); mandor parses none of it.

**Tech Stack:** Zig 0.16.0 (pinned; verify std signatures against the LOCAL std, `zig env` → std_dir). Static musl, ReleaseSafe + strip.

## Global Constraints

- **Motto governs.** Stability first: no `unreachable`/panic on the supervision path; every syscall error handled; PID 1 never blocks beyond a bounded timeout. Zero steady-state allocations — all state in fixed preallocated buffers. ReleaseSafe; **stripped size must stay < 500 KB** (CI-gated).
- **No GPU/vendor/version code enters the core.** Checks are opaque commands.
- **`health` is the sole restart authority.** `[prober.*]` MUST NOT restart, kill, or gate any worker, and MUST NOT touch `max_restarts` accounting.
- **Offline-by-default unchanged.** A prober's `report`/`incident` output ships to photon only when `photon=` is set (reuse the existing emit paths, which are inert without a daemon). `[require.*]`/`[prober.*]` never open a socket themselves.
- **Fail-closed everywhere.** A check that errors, times out, or exits non-zero is a failure. Bounded timeouts on every check.
- **Config discipline.** New sections parse in the hand-rolled `config.zig` (pure — no OS/logmod imports); unknown keys and bad values are hard errors with clear messages, like every existing section. Fixed capacity: `max_require = 8`, `max_probers = 8`.
- **Commits:** no AI attribution (no `Co-Authored-By`). Compile early/often — `zig build` after each module.
- Verify per task in WSL: `zig fmt --check src && zig build test`. Target version **1.15.0** (bumped in the final task only).

---

### Task 1: Config data structures + parsing for `[require.*]` and `[prober.*]`

**Files:**
- Modify: `src/cli.zig` (add `max_require`/`max_probers` consts, `ReqDef`/`ProbeDef` structs, and `Config` arrays)
- Modify: `src/config.zig` (add fields to `FileConfig`, extend `Section` + `sectionHeader` + the section dispatch, add `requireSetting`/`proberSetting`, add `ParseError` needs none new)
- Modify: `src/main.zig` (merge the two arrays from `file_cfg` into `cfg`)
- Test: unit tests appended in `src/config.zig`

**Interfaces:**
- Produces (used by Tasks 2–3):
  - `cli.ReqDef = struct { name: []const u8, cmd: []const u8, timeout_ms: u64 = 60_000 }`
  - `cli.ProbeDef = struct { name: []const u8, cmd: []const u8, interval_ms: u64, timeout_ms: u64 = 10_000, on_fail: OnFail = .report, fail_threshold: u8 = 1 }` with `pub const OnFail = enum { report, incident };`
  - `cli.Config.require: [max_require]ReqDef`, `require_n: u8`; `cli.Config.probers: [max_probers]ProbeDef`, `probers_n: u8`
  - Same-named fields on `config.FileConfig`.

- [ ] **Step 1: Add consts + structs to `src/cli.zig`.** Near the other `max_*` consts add `pub const max_require = 8;` and `pub const max_probers = 8;`. Define the structs above (with the `OnFail` enum) near `HealthSpec`/`SecretDef`. Add to `Config`: `require: [max_require]ReqDef = undefined, require_n: u8 = 0, probers: [max_probers]ProbeDef = undefined, probers_n: u8 = 0,`.

- [ ] **Step 2: Add matching fields to `FileConfig` in `src/config.zig`** (mirror the `cli` types): `require: [cli.max_require]cli.ReqDef = undefined, require_n: u8 = 0, probers: [cli.max_probers]cli.ProbeDef = undefined, probers_n: u8 = 0,`.

- [ ] **Step 3: Extend the `Section` union + `sectionHeader`.** Add `require: []const u8` and `prober: []const u8` variants to `const Section = union(enum){…}`. In `sectionHeader`, after the `secret.` match add:
```zig
if (sectionName(inner, "require.")) |nm| return .{ .require = nm };
if (sectionName(inner, "prober.")) |nm| return .{ .prober = nm };
```

- [ ] **Step 4: Wire the section dispatch.** In `parse`, mirror how `[secret.NAME]` opens a section: add `cur_require: ?usize` / `cur_prober: ?usize` locals (default null), reset them in every arm of the section `switch` (set the others to null when one opens), and in the `.require`/`.prober` arms call `beginRequire(cfg, nm)` / `beginProber(cfg, nm)` (new fns that append a zeroed entry with the name + defaults and return its index, erroring on overflow → `error.TooManyWorkers` reuse or a bounded check → `error.BadValue`). Add the key-dispatch blocks after the `cur_secret` block:
```zig
if (cur_require) |ri| { try requireSetting(cfg, ri, key, value); continue; }
if (cur_prober)  |pi| { try proberSetting(cfg, pi, key, value); continue; }
```

- [ ] **Step 5: Implement `requireSetting` / `proberSetting`** (pure, near `secretSetting`). `requireSetting`: `check` → `cfg.require[ri].cmd = parseString(value) orelse return error.BadValue;`  `timeout` → duration into `timeout_ms` (reject 0 → `error.BadValue`); else `error.Syntax`. `proberSetting`: `check` → cmd; `interval` → duration into `interval_ms` (reject 0); `timeout` → duration (reject 0); `on_fail` → `report`/`incident` else `error.BadValue`; `fail_threshold` → `parseInt(u8)` with `>= 1` else `error.BadValue`; else `error.Syntax`. Names come from `beginRequire`/`beginProber` (store the section NAME slice into `.name`). Add a check-name validator like `validSecretName` if you want, or accept any non-empty trimmed name.

- [ ] **Step 6: Enforce `check` is required.** A `[require.NAME]`/`[prober.NAME]` (and prober `interval`) with no `check` must error. Simplest: at end of `parse`, loop the collected require/prober entries and `if (e.cmd.len == 0) return error.BadValue;` and for probers `if (e.interval_ms == 0) return error.BadValue;` (also catches a `[prober]` with no interval).

- [ ] **Step 7: Merge in `src/main.zig`** (in the `if (text) |txt|` block, next to the other pair-array merges): `cfg.require = file_cfg.require; cfg.require_n = file_cfg.require_n; cfg.probers = file_cfg.probers; cfg.probers_n = file_cfg.probers_n;`.

- [ ] **Step 8: Unit tests** (append to `src/config.zig`; read `parseTest`'s shape first):
```zig
test "require section parses check + timeout default" {
    var s: [cli.max_workers][]const u8 = undefined;
    const cfg = try parseTest("[require.gpu]\ncheck = \"/gpu.sh --min 525\"", &s);
    try t.expectEqual(@as(u8, 1), cfg.require_n);
    try t.expectEqualStrings("gpu", cfg.require[0].name);
    try t.expectEqualStrings("/gpu.sh --min 525", cfg.require[0].cmd);
    try t.expectEqual(@as(u64, 60_000), cfg.require[0].timeout_ms);
}
test "require: missing check and timeout=0 are errors" {
    var s: [cli.max_workers][]const u8 = undefined;
    try t.expectError(error.BadValue, parseTest("[require.gpu]\ntimeout = \"30s\"", &s));
    try t.expectError(error.BadValue, parseTest("[require.gpu]\ncheck=\"x\"\ntimeout=\"0s\"", &s));
    try t.expectError(error.Syntax, parseTest("[require.gpu]\ncheck=\"x\"\nbogus=\"1\"", &s));
}
test "prober section parses with defaults and overrides" {
    var s: [cli.max_workers][]const u8 = undefined;
    const cfg = try parseTest("[prober.pipe]\ncheck=\"/m.sh\"\ninterval=\"2m\"", &s);
    try t.expectEqual(@as(u8, 1), cfg.probers_n);
    try t.expectEqualStrings("pipe", cfg.probers[0].name);
    try t.expectEqual(@as(u64, 120_000), cfg.probers[0].interval_ms);
    try t.expectEqual(@as(u64, 10_000), cfg.probers[0].timeout_ms);
    try t.expectEqual(cli.ProbeDef.OnFail.report, cfg.probers[0].on_fail);
    try t.expectEqual(@as(u8, 1), cfg.probers[0].fail_threshold);
    const c2 = try parseTest("[prober.p]\ncheck=\"x\"\ninterval=\"5s\"\non_fail=\"incident\"\nfail_threshold=\"3\"", &s);
    try t.expectEqual(cli.ProbeDef.OnFail.incident, c2.probers[0].on_fail);
    try t.expectEqual(@as(u8, 3), c2.probers[0].fail_threshold);
}
test "prober: missing interval/check, bad on_fail, threshold=0 are errors" {
    var s: [cli.max_workers][]const u8 = undefined;
    try t.expectError(error.BadValue, parseTest("[prober.p]\ncheck=\"x\"", &s));            // no interval
    try t.expectError(error.BadValue, parseTest("[prober.p]\ninterval=\"5s\"", &s));         // no check
    try t.expectError(error.BadValue, parseTest("[prober.p]\ncheck=\"x\"\ninterval=\"5s\"\non_fail=\"nope\"", &s));
    try t.expectError(error.BadValue, parseTest("[prober.p]\ncheck=\"x\"\ninterval=\"5s\"\nfail_threshold=\"0\"", &s));
}
```

- [ ] **Step 9:** `zig fmt --check src && zig build test` (WSL). Expect green. **Commit:** `feat: parse [require.*] and [prober.*] config sections`.

---

### Task 2: `[require.*]` boot-gate execution

**Files:**
- Modify: `src/spawner.zig` (add a bounded, blocking `runCheck(argv, timeout_ms) -> u8` returning the exit code, or 255 on exec/timeout failure — boot has no fleet to protect, so a bounded blocking wait is fine)
- Modify: `src/supervisor.zig` (run all `[require.*]` before workers are spawned in `run()`; report them in `validate()` WITHOUT executing)
- Test: supervisor tests

**Interfaces:**
- Consumes: `cli.Config.require[0..require_n]` (Task 1).
- Produces: a `runRequires(cfg) -> bool` (all passed) used by `run()`.

- [ ] **Step 1: `spawner.runCheck`.** Tokenize the cmd (reuse `cli.tokenize` into a fixed buf), fork/exec (reuse `execArgv`/`execChild` patterns), and wait with a bounded timeout: poll the child via a pidfd (`pidfd_open`) with `timeout_ms`, or a bounded `waitpid(WNOHANG)` + short sleep loop capped at `timeout_ms`. On exit → return the code; on timeout → `kill(SIGKILL)`, reap, return non-zero (e.g. 255). Fail-closed on any exec error → 255. No alloc; no panic.

- [ ] **Step 2: `supervisor.runRequires`.** For each `cfg.require[0..require_n]`: `logmod.print("[mandor] checking requirement '{s}'\n", .{r.name});` run `spawner.runCheck(r.cmd, r.timeout_ms)`; if non-zero → `logmod.print("[mandor] requirement '{s}' not met (exit {d})\n", .{r.name, code});` return `false`. All pass → return `true`.

- [ ] **Step 3: Wire into `run()`.** Immediately after config is applied and BEFORE the first worker spawn / oneshot gate, add: `if (!runRequires(cfg)) return 1;` (exit non-zero → fail-closed boot; the container runtime handles recovery). Confirm this is before `spawner` starts any worker.

- [ ] **Step 4: `validate()` reports, does not execute.** In `validate`/`printPlan`, add a line per require (e.g. `planLine`-style: `requirement '<name>' — /path/check`) but DO NOT call `runCheck`. validate must stay side-effect free.

- [ ] **Step 5: Tests** (supervisor, inline `cli.Config` like the existing validate tests):
```zig
test "validate reports requires without executing them" {
    var cfg = cli.Config{};
    var cmds = [_][]const u8{"api.sh"};
    cfg.commands = &cmds;
    cfg.require = undefined;
    cfg.require[0] = .{ .name = "gpu", .cmd = "/bin/false" }; // would fail if executed
    cfg.require_n = 1;
    try testing.expectEqual(@as(u8, 0), validate(&cfg)); // parses/reports, never runs /bin/false
}
```
(An end-to-end "a failing require aborts boot" assertion lives in the harness — Task 4 — since it needs a real fork.)

- [ ] **Step 6:** `zig build test` green. **Commit:** `feat: run [require.*] boot gates fail-closed before workers`.

---

### Task 3: `[prober.*]` periodic execution

**Files:**
- Modify: `src/spawner.zig` (a `spawnCheckArgv(cmd, ...) -> pid` that spawns a detached check like `spawnCheck` but from an arbitrary command string, non-blocking; or generalize existing `spawnCheck`)
- Modify: `src/supervisor.zig` (a `ProberState` runtime array mirroring the health fields — `pid`, `started_ms`, `next_ms`, `fails` — and `runProbers()` driven from the poll loop next to `runHealth`; on threshold, `on_fail` action; fold prober pids into the reaper + poll-timeout like health probes)
- Test: supervisor + harness (Task 4)

**Interfaces:**
- Consumes: `cli.Config.probers[0..probers_n]` (Task 1), `telemetry.emitLog`/`emitLifecycle`, and the incident spool path (`incident`-module public record fn used by the detector; read it and reuse — respect `detector.dedup_cooldown_ms`).

- [ ] **Step 1: Prober runtime.** A module-level `var prober_state: [cli.max_probers]ProberState = …;` with `ProberState = struct { pid: i32 = 0, started_ms: u64 = 0, next_ms: u64 = 0, fails: u8 = 0, last_incident_ms: u64 = 0 };`. Reset `next_ms` for each configured prober at startup (first run one interval from boot).

- [ ] **Step 2: `runProbers()`** (mirror `runHealth`, non-blocking): for each prober `pi`: if a probe pid is running and timed out (`now - started_ms > timeout_ms`) → SIGKILL (reaped as failure). If no pid and `now >= next_ms` → `spawnCheckArgv(cfg.probers[pi].cmd, …)`, set `started_ms`, `next_ms = now + interval_ms`. When a prober's check is reaped (hook the reaper like health, or poll `waitpid`), on non-zero/timeout → `fails += 1`; on success → `fails = 0`. When `fails >= fail_threshold` fire `on_fail` (below) and reset `fails = 0`.

- [ ] **Step 3: `on_fail` actions.**
  - `.report`: `logmod.print("[mandor] prober '{s}' failing (exit {d})\n", …)` + emit one OTLP log via `telemetry.emitLog(name, stream=2, severity=WARN, now_ns, "prober <name>: check failed exit <n>")` (inert without `photon=`).
  - `.incident`: same log PLUS spool an incident bundle through the same public path the detector uses, guarded by a per-prober cooldown: `if (now -| last_incident_ms >= detector.dedup_cooldown_ms) { spool…; last_incident_ms = now; }`. Read `incident.zig` for the exact record signature and the `BundleInput` shape; set a synthetic `cause`/verdict like `"prober:<name> failing"`.
  - **Never** touch any worker pid, `max_restarts`, or the restart scheduler.

- [ ] **Step 4: Poll-loop + reaper integration.** In the main loop next to `runHealth`, call `runProbers()`; fold prober pids into the poll `wake_at` computation (a running probe's timeout, else its `next_ms`) exactly like health; in the reaper's child-collection, recognize a prober pid and route it to prober bookkeeping (add a small helper `collectProber(pid, status)` alongside the health-collection path). Probers only run after boot (after `runRequires` + workers spawned).

- [ ] **Step 5: Tests** (supervisor, unit — drive the pure bits without a real fork where possible): a helper that simulates N consecutive failures and asserts `on_fail` fires exactly at `fail_threshold` and that `report` never mutates any worker/restart state. If the fork path can't be unit-tested cleanly, assert the scheduling math (`next_ms` advances by `interval_ms`, timeout kills at `timeout_ms`) and leave the real fork behavior to the harness (Task 4).

- [ ] **Step 6:** `zig build test` green. **Commit:** `feat: drive [prober.*] periodic checks (report/incident, never restart)`.

---

### Task 4: Harness e2e

**Files:**
- Modify: `test/harness/run_tests.sh` (add cases before the summary tail)

- [ ] **Step 1: require-abort + require-pass cases.** A config with `[require.blocker] check = "sh -c 'exit 1'"` → assert `mandor -- "<worker>"` exits non-zero and logs `requirement 'blocker' not met`, and the worker never started (its marker file never appears). A second config with `check = "sh -c 'exit 0'"` → assert the worker DOES start.

- [ ] **Step 2: prober report-without-restart case.** A long-lived worker + `[prober.p] check = "sh -c 'exit 1'" interval = "1s" fail_threshold = 1`. Run ~4s, TERM. Assert: the worker's pid never changed / its start marker printed exactly once (no restart), and mandor logged `prober 'p' failing`. This is the load-bearing proof that a prober never restarts.

- [ ] **Step 3:** `zig build && bash test/harness/run_tests.sh` (WSL) → all pass, count +N. **Commit:** `test: harness e2e for [require.*] boot gate and [prober.*] no-restart`.

---

### Task 5: Docs + version bump to 1.15.0

**Files:** `build.zig` (→ `1.15.0`), `docs/CONFIG.md`, `README.md`, `CHANGELOG.md`, `docs/ROADMAP.md`, `CLAUDE.md`.

- [ ] **Step 1:** `build.zig` version → `1.15.0`.
- [ ] **Step 2:** `docs/CONFIG.md` — new "Boot preconditions — `[require.NAME]`" and "Status probers — `[prober.NAME]`" sections (keys, defaults, semantics from the spec); add both to the README config-key table (new `[require.NAME]` / `[prober.NAME]` scopes). State plainly: checks are opaque commands (mandor runs no GPU code); `health` is the only restart authority; probers never restart.
- [ ] **Step 3:** `CLAUDE.md` — one line in the architecture + product-boundary notes: declarative checks run operator commands, prober is report-only, no vendor code in core.
- [ ] **Step 4:** `CHANGELOG.md` — `## [1.15.0] - <date>` with an Added entry for both features.
- [ ] **Step 5:** `docs/ROADMAP.md` — a shipped-ledger row (58) for declarative checks.
- [ ] **Step 6: Full verify (WSL):** `zig fmt --check src && zig build test && zig build`; the musl ReleaseSafe build + `strip` + size `< 512000`; `zig-out/bin/mandor --version` → `mandor 1.15.0`. **Commit:** `docs: [require.*]/[prober.*] docs + bump to 1.15.0`.

---

## Self-Review

- **Spec coverage:** `[require.*]` boot gate before workers, all-must-pass, timeout default 60s, validate-no-exec (Task 2) ✓; `[prober.*]` periodic, report/incident, threshold, timeout 10s, never restarts (Task 3) ✓; config parse + defaults + hard errors (Task 1) ✓; no GPU code (checks are opaque commands throughout) ✓; health = sole restart authority (Task 3 explicitly forbids worker/restart mutation; Task 4 proves no-restart) ✓; offline-by-default (report/incident reuse inert-without-photon emit paths) ✓; docs + 1.15.0 (Task 5) ✓; size gate (Task 5) ✓.
- **Placeholder scan:** structs, tests, and messages are concrete. The two spawn helpers (`runCheck`, `spawnCheckArgv`) reference existing `spawnCheck`/`execArgv`/`execChild` patterns the implementer reads and mirrors — flagged as "read surrounding code," not left vague on behavior (bounded, fail-closed, non-blocking-for-prober specified).
- **Type consistency:** `ReqDef`/`ProbeDef`/`OnFail` defined in Task 1 and consumed unchanged in Tasks 2–3; `require`/`probers` array + `_n` names identical across cli.Config, FileConfig, and the main.zig merge.
- **Risk note for the reviewer:** the prober reaper/poll integration touches the supervision loop — the final whole-branch review must adversarially check that a prober pid can never be mistaken for a worker/health pid, that a prober never advances `max_restarts` or restarts a worker, and that a hung check is always bounded by `timeout_ms`.
