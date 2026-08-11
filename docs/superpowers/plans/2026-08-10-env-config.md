# ENV Configuration for mandor's Deploy-Varying Keys — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** mandor reads its four deploy-varying settings from the environment (ENV overrides TOML), and GPU metrics become auto-detected instead of a config toggle — so an ENV-native app configures mandor via `-e` over a static TOML.

**Architecture:** A new pure `src/env.zig` resolves the deploy-varying values with `CLI > ENV > TOML > default` precedence; `main.zig` calls it after the TOML merge. The bearer-token literal is renamed in `relay.zig`. The `[gpu] enabled` key is removed end-to-end and the relay daemon probes for a GPU once at startup.

**Tech Stack:** Zig 0.16 (pinned in `.zigversion`); static musl; no external deps; raw `std.os.linux` syscalls. Build/test via WSL: `zig build test`, `zig build`.

## Global Constraints

- Zig 0.16.0, pinned — verify `std` signatures against the local install; compile after every module.
- No panic / `unreachable` on the supervision path; every syscall error handled. Env reads are startup-path only.
- Zero steady-state allocation; env values borrow the process `environ` (stable for the process life).
- ReleaseSafe + strip; stripped x86_64/aarch64 musl must stay **< 500 KB** (measure).
- Offline-by-default is absolute: no `photon` from any source ⇒ no socket, no relay child.
- Precedence for the four env-settable keys: **CLI flag > ENV > TOML > default**.
- Commit messages: plain, no AI attribution. Commit in WSL (`git` identity is there); the build is `zig build` in WSL.
- Target release: **v1.12.0**. Two breaking changes: `PHOTON_TOKEN` → `PHOTON_OTLP_TOKEN`, `[gpu] enabled` removed.

---

### Task 1: `src/env.zig` — pure env-resolution helpers

**Files:**
- Create: `src/env.zig`
- Modify (register the test): `src/main.zig` (the `test {}` aggregator block — add `_ = @import("env.zig");`)

**Interfaces:**
- Consumes: nothing (pure, `std` only).
- Produces:
  - `pub fn stripScheme(s: []const u8) []const u8`
  - `pub fn resolvePhoton(cli_v: ?[]const u8, env_v: ?[]const u8, toml_v: ?[]const u8) ?[]const u8`
  - `pub fn resolveServicePrefix(env_v: ?[]const u8, toml_v: ?[]const u8) []const u8`

- [ ] **Step 1: Write the failing tests** — create `src/env.zig` with only the tests first:

```zig
//! Pure resolution of mandor's deploy-varying config from CLI/ENV/TOML sources.
//! No syscalls, no allocation — the caller supplies the already-read values.
//! Precedence: CLI > ENV > TOML > default. See
//! docs/superpowers/specs/2026-08-10-env-config-deploy-varying-keys-design.md.

const std = @import("std");

const testing = std.testing;

test "stripScheme drops http/https, leaves bare host:port" {
    try testing.expectEqualStrings("h:9", stripScheme("http://h:9"));
    try testing.expectEqualStrings("h:9", stripScheme("https://h:9"));
    try testing.expectEqualStrings("h:9", stripScheme("h:9"));
    try testing.expectEqualStrings("", stripScheme(""));
    // Only a leading scheme is stripped; an embedded one is left alone.
    try testing.expectEqualStrings("a/http://b", stripScheme("a/http://b"));
}

test "resolvePhoton: CLI > ENV > TOML, scheme-stripped, null when none" {
    // ENV wins over TOML; scheme stripped.
    try testing.expectEqualStrings("e:1", resolvePhoton(null, "http://e:1", "t:2").?);
    // CLI wins over ENV.
    try testing.expectEqualStrings("c:1", resolvePhoton("c:1", "e:1", "t:2").?);
    // TOML used when no CLI/ENV.
    try testing.expectEqualStrings("t:2", resolvePhoton(null, null, "t:2").?);
    // None set ⇒ null (offline).
    try testing.expect(resolvePhoton(null, null, null) == null);
}

test "resolveServicePrefix: ENV > TOML > empty" {
    try testing.expectEqualStrings("e-", resolveServicePrefix("e-", "t-"));
    try testing.expectEqualStrings("t-", resolveServicePrefix(null, "t-"));
    try testing.expectEqualStrings("", resolveServicePrefix(null, null));
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test` (in WSL)
Expected: FAIL — `stripScheme`/`resolvePhoton`/`resolveServicePrefix` not defined.

- [ ] **Step 3: Implement the helpers** (add above the `const testing` line):

```zig
/// Drop a leading `http://` / `https://` so a full URL or a bare `host:port`
/// both reduce to `host:port` (mandor's endpoint parser + TOML `photon=` want
/// bare host:port; mandor is OTLP/HTTP-only so the scheme is redundant).
pub fn stripScheme(s: []const u8) []const u8 {
    if (std.mem.startsWith(u8, s, "http://")) return s["http://".len..];
    if (std.mem.startsWith(u8, s, "https://")) return s["https://".len..];
    return s;
}

/// Resolve the photon endpoint with CLI > ENV > TOML precedence, scheme-stripped.
/// null (no source set) ⇒ offline. Validation (host:port) happens downstream in
/// supervisor.run via parseHostPort — same path a TOML value takes.
pub fn resolvePhoton(cli_v: ?[]const u8, env_v: ?[]const u8, toml_v: ?[]const u8) ?[]const u8 {
    const raw = cli_v orelse env_v orelse toml_v orelse return null;
    return stripScheme(raw);
}

/// Resolve service_prefix with ENV > TOML precedence (no CLI flag exists); the
/// default is "" (no prefix). Length is validated by the caller (cli.max_service_prefix).
pub fn resolveServicePrefix(env_v: ?[]const u8, toml_v: ?[]const u8) []const u8 {
    return env_v orelse toml_v orelse "";
}
```

- [ ] **Step 4: Register the test module** — in `src/main.zig`, find the `test {}` block that lists `_ = @import("...zig");` lines and add:

```zig
    _ = @import("env.zig");
```

- [ ] **Step 5: Run to verify pass**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/env.zig src/main.zig
git commit -m "feat: pure env-config resolution helpers (env.zig)"
```

---

### Task 2: Wire ENV resolution for `photon` + `service_prefix` into main.zig

**Files:**
- Modify: `src/main.zig` — remove the TOML-only merges at lines 198–199; add an unconditional ENV-override resolution near the `state_dir` block (~278).

**Interfaces:**
- Consumes: `env.resolvePhoton`, `env.resolveServicePrefix` (Task 1); `spawner.findEnv(environ, name) ?[]const u8`; `cli.max_service_prefix` (= 64); `logmod.print`.
- Produces: `cfg.photon` (scheme-stripped, ENV-overriding) and `cfg.service_prefix` set before `supervisor.run`.

- [ ] **Step 1: Add the `env` import** — near the other `const … = @import(...)` lines at the top of `src/main.zig`:

```zig
const env = @import("env.zig");
```

- [ ] **Step 2: Remove the TOML-only photon/prefix merges** — delete these two lines inside the `if (text) |txt| { … }` block (currently lines 198–199):

```zig
            if (cfg.photon == null) cfg.photon = file_cfg.photon;
            if (file_cfg.service_prefix) |v| cfg.service_prefix = v;
```

(Removing them from inside `if (text)` is required: the env resolution below runs unconditionally, so photon/prefix must resolve even when there is no `mandor.toml`. `file_cfg` still holds its defaults — `photon = null`, `service_prefix = null` — when no TOML was read.)

- [ ] **Step 3: Add unconditional ENV-override resolution** — immediately BEFORE the existing `const state_dir = cfg.state_dir orelse …` line (~278), add:

```zig
    // Deploy-varying keys resolve CLI > ENV > TOML > default (state_dir just below
    // follows the same shape). ENV overrides a TOML value; the photon value is
    // scheme-stripped so PHOTON_OTLP_HTTP_ENDPOINT (a full URL) or a bare host:port
    // both work. cfg.photon has no CLI flag, so it is null here unless already set.
    cfg.photon = env.resolvePhoton(
        cfg.photon,
        spawner.findEnv(environ, "PHOTON_OTLP_HTTP_ENDPOINT"),
        file_cfg.photon,
    );
    cfg.service_prefix = env.resolveServicePrefix(
        spawner.findEnv(environ, "MANDOR_SERVICE_PREFIX"),
        file_cfg.service_prefix,
    );
    if (cfg.service_prefix.len > cli.max_service_prefix) {
        logmod.print("[mandor] service_prefix too long (max {d})\n", .{cli.max_service_prefix});
        return 2;
    }
```

- [ ] **Step 4: Build + full test**

Run: `zig build test && zig build`
Expected: PASS / EXE builds. (A malformed `PHOTON_OTLP_HTTP_ENDPOINT` is still caught by the existing `supervisor.zig:~214` `parseHostPort` check → exit 2.)

- [ ] **Step 5: Manual smoke (optional, in WSL)** — env overrides an absent TOML photon:

```bash
PHOTON_OTLP_HTTP_ENDPOINT=http://127.0.0.1:19999 zig-out/bin/mandor "sh -c 'sleep 1'" 2>&1 | grep -i "forwarding incidents to photon at 127.0.0.1:19999"
```
Expected: the line prints `127.0.0.1:19999` (scheme stripped, from env).

- [ ] **Step 6: Commit**

```bash
git add src/main.zig
git commit -m "feat: resolve photon (PHOTON_OTLP_HTTP_ENDPOINT) + service_prefix from env, ENV over TOML"
```

---

### Task 3: Rename bearer token `PHOTON_TOKEN` → `PHOTON_OTLP_TOKEN`

**Files:**
- Modify: `src/relay.zig` — two `findEnv` sites (the incident-ship `run` path ~line 68 and `runDaemon` ~line 1729).

**Interfaces:**
- Consumes: `spawner.findEnv`.
- Produces: the relay authenticates from `PHOTON_OTLP_TOKEN`.

- [ ] **Step 1: Rename both literals** — in `src/relay.zig`, both occurrences of:

```zig
    const token = spawner.findEnv(environ, "PHOTON_TOKEN") orelse "";
```

become:

```zig
    const token = spawner.findEnv(environ, "PHOTON_OTLP_TOKEN") orelse "";
```

Verify exactly two sites changed:

```bash
grep -n 'PHOTON_TOKEN\|PHOTON_OTLP_TOKEN' src/relay.zig
```
Expected: two lines, both `PHOTON_OTLP_TOKEN`, zero bare `PHOTON_TOKEN`.

- [ ] **Step 2: Update the two other in-repo references** so nothing still says the old name:
  - `src/telemetry.zig` — the doc comment on `spawnDaemon` mentions `PHOTON_TOKEN`; change to `PHOTON_OTLP_TOKEN`.
  - Search the tree: `grep -rn 'PHOTON_TOKEN' src/ docs/` — update any remaining code/doc mention to `PHOTON_OTLP_TOKEN` (docs are fully swept in Task 5; here just fix code comments so the rename is coherent).

- [ ] **Step 3: Build + test**

Run: `zig build test && zig build`
Expected: PASS. (Existing relay/fuzz tests don't assert the env name; the harness `test/harness/run_tests.sh` uses `PHOTON_TOKEN=any` — update those occurrences to `PHOTON_OTLP_TOKEN=any` in this step so the harness still exercises auth. `grep -n 'PHOTON_TOKEN' test/harness/run_tests.sh` and rename each.)

- [ ] **Step 4: Commit**

```bash
git add src/relay.zig src/telemetry.zig test/harness/run_tests.sh
git commit -m "feat!: rename the bearer env var PHOTON_TOKEN -> PHOTON_OTLP_TOKEN"
```

---

### Task 4: Remove `[gpu] enabled` — GPU is auto-detected end-to-end

This is **one atomic task**: the `gpu_enabled` value threads config.zig → cli.zig → main.zig → telemetry.zig → relay.zig, so the build only stays green if every site changes together.

**Files:**
- Modify: `src/config.zig` (drop `gpu_enabled` field + the `enabled` parse; add a `GpuEnabledRemoved` migration error)
- Modify: `src/main.zig` (drop the `gpu_enabled` merge; add the `GpuEnabledRemoved` message; drop `gpu` from the daemon argv parse; drop the arg at the `spawnDaemon` call)
- Modify: `src/cli.zig` (drop `GpuConfig.enabled`)
- Modify: `src/telemetry.zig` (`spawnDaemon`: drop the `gpu_enabled` param + its argv string)
- Modify: `src/relay.zig` (`runDaemon`: drop the `gpu_enabled` param; probe for a GPU once at startup; gate sampling on the probe result)

**Interfaces:**
- Produces: `runDaemon(endpoint, spool_dir, pipe_fd, gpu_interval_ms, service_prefix, environ)` (no `gpu_enabled`); `spawnDaemon(endpoint, state_dir, gpu_interval_ms, service_prefix, envp, path_env)` (no `gpu_enabled`).

- [ ] **Step 1: Write the failing config test** — in `src/config.zig`, near the other `[gpu]` / removed-key tests, add:

```zig
test "gpu section: enabled key removed gives a migration error" {
    var storage: [cli.max_workers][]const u8 = undefined;
    // `[gpu] enabled` was removed in v1.12 (GPU auto-detected). It must give a
    // dedicated migration error, not a bare Syntax error.
    try t.expectError(error.GpuEnabledRemoved, parseTest("[gpu]\nenabled = true", &storage));
    // `[gpu] interval` still parses.
    const cfg = try parseTest("[gpu]\ninterval = \"20s\"", &storage);
    try t.expectEqual(@as(?u64, 20_000), cfg.gpu_interval_ms);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test`
Expected: FAIL — `error.GpuEnabledRemoved` is not in `ParseError` (compile error), or the old parse accepts `enabled`.

- [ ] **Step 3: config.zig changes**

  a. Add `GpuEnabledRemoved` to the error set (find `pub const ParseError = error{ … };`):

```zig
pub const ParseError = error{ Syntax, BadValue, TooManyWorkers, RestartRemoved, UnhealthyKeyRemoved, LogsStreamRemoved, GpuEnabledRemoved };
```

  b. Remove the `gpu_enabled` field from `FileConfig` (delete the line `gpu_enabled: ?bool = null,`).

  c. In `gpuSetting`, replace the `enabled` branch with a migration error:

```zig
fn gpuSetting(cfg: *FileConfig, key: []const u8, value: []const u8) ParseError!void {
    if (std.mem.eql(u8, key, "interval")) {
        const s = parseString(value) orelse return error.BadValue;
        cfg.gpu_interval_ms = cli.parseDuration(s) orelse return error.BadValue;
    } else if (std.mem.eql(u8, key, "enabled")) {
        // Removed in v1.12: GPU is auto-detected (on when a device is present).
        return error.GpuEnabledRemoved;
    } else {
        return error.Syntax; // unknown key inside a [gpu] section
    }
}
```

- [ ] **Step 4: main.zig changes**

  a. Add the message arm in the config-error `switch` (next to `error.LogsStreamRemoved => …`):

```zig
                    error.GpuEnabledRemoved => "'[gpu] enabled' was removed — GPU metrics are " ++
                        "now auto-detected (on when a device is present, off otherwise); " ++
                        "[gpu] keeps only 'interval'",
```

  b. Remove the merge line `if (file_cfg.gpu_enabled) |v| cfg.gpu.enabled = v;` (currently ~line 200).

  c. In the `--daemon` argv parse (the block ~lines 87–111), drop the GPU-enabled slot so the layout becomes `<endpoint> <spool_dir> <pipe_fd> <interval> <service_prefix>`:

```zig
        if (std.mem.eql(u8, std.mem.span(vec[2]), "--daemon")) {
            if (vec.len < 6) {
                writeOut(usage_text);
                return 2;
            }
            const endpoint = std.mem.span(vec[3]);
            const spool_dir = std.mem.span(vec[4]);
            const pipe_fd = std.fmt.parseInt(i32, std.mem.span(vec[5]), 10) catch return 2;
            // vec[6] = gpu interval ms (absent on an older spawn -> 15s). vec[7] =
            // service prefix ("" = none). GPU on/off is auto-detected by the daemon,
            // not passed. Log streaming is per-worker, so no toggle is threaded.
            const gpu_interval_ms: u64 = if (vec.len >= 7)
                (std.fmt.parseInt(u64, std.mem.span(vec[6]), 10) catch 15_000)
            else
                15_000;
            const service_prefix: []const u8 = if (vec.len >= 8) std.mem.span(vec[7]) else "";
            return @import("relay.zig").runDaemon(endpoint, spool_dir, pipe_fd, gpu_interval_ms, service_prefix, init.environ.block.slice);
        }
```

- [ ] **Step 5: cli.zig change** — remove `enabled` from `GpuConfig`:

```zig
pub const GpuConfig = struct {
    interval_ms: u64 = 15_000,
};
```

- [ ] **Step 6: telemetry.zig change** — `spawnDaemon`: drop the `gpu_enabled: bool,` parameter and the `gpu_str` argv string. The argv it builds must match main.zig's new parse: `… <fd_str> <gi_str> <sp_str>` (interval, then prefix — no gpu-enabled string). Delete the `gpu_buf` / `gpu_str` block and remove `@ptrCast(gpu_str.ptr),` from the `argv` array so the order is `… fd_str, gi_str, sp_str`. Update the call site: `supervisor.zig` (or wherever `telemetry.spawnDaemon(...)` is called, ~supervisor line 348) — remove the `cfg.gpu.enabled` argument.

- [ ] **Step 7: relay.zig change — runDaemon signature + startup probe**

  a. Drop `gpu_enabled: bool,` from the `runDaemon` parameter list (~line 1707).

  b. Replace the `next_gpu_sample_ms` initialization (~line 1775, `var next_gpu_sample_ms: u64 = if (gpu_enabled) monoMs() +| gpu_interval_ms else 0;`) with a one-time probe:

```zig
    // GPU auto-detect (one-time, spec: no re-probe — a GPU appearing later needs a
    // restart). Probe both sources once; present if either returns a card. On a
    // GPU-less host say so once, then never sample (no periodic nvidia-smi fork).
    const gpu_present = blk: {
        const nv = gpu.sample(gpu_path_env, environ.ptr, &gpu_samples);
        const drm = gpu.sampleDrm(&gpu_samples, @intCast(nv.len));
        break :blk (nv.len + drm.len) > 0;
    };
    if (!gpu_present) err("no GPU detected; GPU metrics off");
    var next_gpu_sample_ms: u64 = if (gpu_present) monoMs() +| gpu_interval_ms else 0;
```

  c. Replace both remaining `gpu_enabled` reads in the loop (the sample gate ~line 1825 and the sleep-bound fold ~line 1859) with `gpu_present`.

- [ ] **Step 8: Run to verify the config test passes + build**

Run: `zig build test && zig build`
Expected: the `gpu section: enabled key removed` test PASSES; EXE builds. `grep -rn 'gpu_enabled' src/` returns nothing.

- [ ] **Step 9: Commit**

```bash
git add src/config.zig src/cli.zig src/main.zig src/telemetry.zig src/relay.zig src/supervisor.zig
git commit -m "feat!: remove [gpu] enabled — GPU auto-detected once at daemon start"
```

---

### Task 5: Docs, README config table, CHANGELOG, version bump, Lenz note

**Files:**
- Modify: `build.zig` (version `1.11.1` → `1.12.0`)
- Modify: `docs/CONFIG.md` (ENV annotations on the four keys; drop `[gpu] enabled`)
- Modify: `docs/INTEGRATION-PHOTON.md` (`PHOTON_OTLP_HTTP_ENDPOINT` + `PHOTON_OTLP_TOKEN`; GPU auto-detect)
- Modify: `README.md` (add the **Config keys** table with a TOML · CLI · ENV column)
- Modify: `CHANGELOG.md` (v1.12.0 entry; two breaking changes)
- Modify: `.github/workflows/ci.yml` (config-surface budget: `[gpu] enabled` removed ⇒ **lower** the count by 1; run the gate grep and set the number)

- [ ] **Step 1: Bump the version** in `build.zig`:

```zig
    const version = b.option([]const u8, "version", "Version string") orelse "1.12.0";
```

- [ ] **Step 2: README Config keys table** — add a section listing every config key with columns **Key · TOML · CLI · ENV**. The four env rows carry their var (`photon` → `PHOTON_OTLP_HTTP_ENDPOINT`, bearer → `PHOTON_OTLP_TOKEN`, `service_prefix` → `MANDOR_SERVICE_PREFIX`, `state_dir` → `MANDOR_STATE_DIR`); every other key's ENV cell is blank. Note in prose: "ENV overrides TOML (CLI > ENV > TOML > default); only these four deploy-varying keys are env-settable — the rest is TOML/CLI."

- [ ] **Step 3: CONFIG.md** — annotate the four keys with their env var (mirror the existing `state_dir | --state-dir= / MANDOR_STATE_DIR` row style); remove the `[gpu] enabled` row and note GPU is auto-detected; state the precedence rule once.

- [ ] **Step 4: INTEGRATION-PHOTON.md** — update the auth/endpoint prose: mandor reads `PHOTON_OTLP_HTTP_ENDPOINT` (scheme-stripped) and `PHOTON_OTLP_TOKEN` from the environment (overriding the TOML `photon=`); GPU metrics are auto-detected (no `[gpu] enabled`).

- [ ] **Step 5: CHANGELOG.md** — add `## [1.12.0] - 2026-08-10` above 1.11.1, Keep-a-Changelog style:
  - **Added:** ENV config for the four deploy-varying keys (`PHOTON_OTLP_HTTP_ENDPOINT`, `PHOTON_OTLP_TOKEN`, `MANDOR_SERVICE_PREFIX`, `MANDOR_STATE_DIR`), ENV overriding TOML; the photon endpoint accepts a full URL (scheme-stripped).
  - **Changed (breaking):** `PHOTON_TOKEN` renamed to `PHOTON_OTLP_TOKEN`; `[gpu] enabled` removed — GPU is auto-detected (on when a device is present, off with a one-time log otherwise).

- [ ] **Step 6: ci.yml config-surface gate** — the gate counts `grep -cE '^\| \`[a-z_]+' docs/CONFIG.md` against a budget. Removing `[gpu] enabled` drops the count by 1. Run the grep after the CONFIG.md edit and set `budget=` to the new count (keep the existing headroom convention).

- [ ] **Step 7: Verify docs coherence**

```bash
grep -rn 'PHOTON_TOKEN\b' src/ docs/ README.md CHANGELOG.md   # expect: none (all renamed)
grep -rn '\[gpu\] enabled\|gpu.*enabled = ' docs/ README.md     # expect: only "removed"/migration mentions
```

- [ ] **Step 8: Full verify (WSL)** — fmt, test, both musl release size gates:

```bash
zig fmt --check src && zig build test && zig build
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe -p /tmp/x64 && strip /tmp/x64/bin/mandor && stat -c %s /tmp/x64/bin/mandor   # < 512000
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseSafe -p /tmp/a64 && strip /tmp/a64/bin/mandor && stat -c %s /tmp/a64/bin/mandor  # < 512000
zig-out/bin/mandor --version   # mandor 1.12.0
```

- [ ] **Step 9: Commit**

```bash
git add build.zig README.md docs/CONFIG.md docs/INTEGRATION-PHOTON.md CHANGELOG.md .github/workflows/ci.yml
git commit -m "docs: env config + GPU auto-detect; bump to 1.12.0"
```

---

## Post-plan: Lenz entrypoint (separate repo, `../lenz`)

Not part of the mandor build, but the payoff — after mandor v1.12.0 ships, update `../lenz/scripts/entrypoint.sh` + `.gitlab-ci.yml`:
- delete the photon block (entrypoint lines ~157–169) and the `[logs] digest = true` emit;
- drop the CI `PHOTON_OTLP` derivation (gitlab-ci line 308) + the `-e PHOTON_OTLP` (321) + the redundant `-e PHOTON_TOKEN` (322);
- keep `-e PHOTON_OTLP_HTTP_ENDPOINT` + `-e PHOTON_OTLP_TOKEN` (already set) and add `-e MANDOR_SERVICE_PREFIX="${APP_NAME}-"`;
- the generated `mandor.toml` shrinks to the static workers + `[worker.*]` + `[secret.*]`.

## Self-Review

- **Spec coverage:** four env keys (Tasks 1–2 photon+prefix; `MANDOR_STATE_DIR` already resolves via main.zig:278, unchanged; token Task 3) ✓; ENV>TOML precedence (Task 1/2) ✓; scheme-strip (Task 1) ✓; token rename (Task 3) ✓; GPU auto-detect + `[gpu] enabled` removal + one-time-probe + log (Task 4) ✓; README table + docs + breaking-change notes + version (Task 5) ✓; offline-by-default preserved (photon null ⇒ no daemon, unchanged) ✓; size gate (Task 5 step 8) ✓.
- **Placeholder scan:** none — every code step shows real code.
- **Type consistency:** `runDaemon`/`spawnDaemon` signatures updated identically in Task 4 (relay.zig def, telemetry.zig caller, main.zig daemon route); `ParseError.GpuEnabledRemoved` defined (config.zig) and handled (main.zig); `env.*` helper names match between Task 1 (def) and Task 2 (use).
- Note: `MANDOR_STATE_DIR` already resolves with the exact CLI>ENV>TOML>default shape at `main.zig:278`; no change needed — it is the template the new keys mirror.
