# TOML Behavior-Overlay Over the CLI Worker Set — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the CLI-spawned worker set the source of truth and the `mandor.toml` a static, name-keyed behavior overlay — orphan `[worker.NAME]` sections are ignored, `[secret.*]` grants resolve against the CLI worker set and deliver to the present subset (never error), and `validate` stops hard-failing on orphans.

**Architecture:** Move `[secret.*]` worker-name→index resolution out of `config.parse` (which runs before the CLI workers are known) into a pure `config.resolveSecretGrants` called from `main.zig` *after* the CLI/TOML worker set is finalized; it skips absent workers (inert on empty). Remove `main.zig`'s CLI-workers+secrets refusal and `supervisor.validate`'s orphan hard-fail. `config.parse` keeps only the worker-set-independent env-collision check.

**Tech Stack:** Zig 0.16 (pinned in `.zigversion`); static musl; no external deps; raw `std.os.linux`. Build/test via WSL: `zig build test`, `zig build`.

## Global Constraints

- Zig 0.16.0, pinned — verify `std` signatures against the local install; compile after every module.
- No panic / `unreachable` on the supervision path; `config.zig` is a pure, dependency-free module (no OS/logmod imports) — keep it that way.
- Zero steady-state allocation; resolution uses the existing fixed config buffers.
- ReleaseSafe + strip; stripped x86_64/aarch64 musl < **500 KB**.
- **Deny-by-default secrets:** only workers PRESENT in the active set AND listed in a `[secret.*]` grant ever receive it. Skip-on-absent is more restrictive, never less.
- **Non-breaking:** no previously-valid config may change behavior. Only loosen.
- **Command line is CLI-only:** never add a `command`/`args` key to `[worker.NAME]`.
- Commit messages: plain, no AI attribution. Commit + build in WSL.
- Target release: **v1.13.0**.

---

### Task 1: Defer secret resolution to post-merge (config.zig + main.zig)

Atomic: `config.parse` stops resolving grants to indices, a pure resolver is added, `main.zig` calls it after the worker set is final, and the CLI-workers+secrets refusal is removed. Kept as one task so `[secret.*]` works end-to-end at the commit.

**Files:**
- Modify: `src/config.zig` — split `resolveSecrets` (~line 522); change its call site (~line 305); add `resolveSecretGrants`; update existing secret tests.
- Modify: `src/main.zig` — remove the refusal (~lines 247–250); call the resolver after `cfg.commands` is finalized (~line 251).

**Interfaces:**
- Consumes: `cli.SecretDef { name, env, fmt, n, workers: [max_secret_workers]u8, workers_len: usize }`; `FileConfig.secret_refs: [max_secrets][max_secret_workers][]const u8`; the private `deriveOne(cmd, out, prior) []const u8` and `matchWorker(derived, ref) ?u8` in `config.zig`.
- Produces: `pub fn resolveSecretGrants(secrets: []cli.SecretDef, refs: []const [cli.max_secret_workers][]const u8, commands: []const []const u8) void` — rewrites each `SecretDef.workers`/`workers_len` in place to the indices of the *present* listed workers.

- [ ] **Step 1: Write the failing resolver tests** — add to `src/config.zig` (near the other secret tests):

```zig
test "resolveSecretGrants: grant to the present subset, skip absent" {
    var storage: [cli.max_workers][]const u8 = undefined;
    // Parse succeeds even though `pmtiles.sh` is not in this TOML's workers.
    const text =
        \\workers = ["gateway.sh", "proxy.sh"]
        \\
        \\[secret.integration-lock]
        \\workers = ["gateway.sh", "pmtiles.sh"]
    ;
    var fc = try parseTest(text, &storage);
    // The active set spawns gateway.sh + proxy.sh (no pmtiles.sh).
    const cmds = [_][]const u8{ "gateway.sh", "proxy.sh" };
    resolveSecretGrants(fc.secrets[0..fc.secrets_n], fc.secret_refs[0..fc.secrets_n], &cmds);
    // Only the present worker (gateway.sh = index 0) is granted; pmtiles.sh skipped.
    try t.expectEqual(@as(usize, 1), fc.secrets[0].workers_len);
    try t.expectEqual(@as(u8, 0), fc.secrets[0].workers[0]);
}

test "resolveSecretGrants: all-absent (and empty) grants are inert, not errors" {
    var storage: [cli.max_workers][]const u8 = undefined;
    const text =
        \\workers = ["gateway.sh"]
        \\
        \\[secret.s]
        \\workers = ["nope.sh"]
    ;
    var fc = try parseTest(text, &storage); // parse must NOT error on the absent ref
    const cmds = [_][]const u8{"gateway.sh"};
    resolveSecretGrants(fc.secrets[0..fc.secrets_n], fc.secret_refs[0..fc.secrets_n], &cmds);
    try t.expectEqual(@as(usize, 0), fc.secrets[0].workers_len); // inert (no recipients)
}

test "resolveSecretGrants resolves against CLI-only workers (no TOML workers=)" {
    var storage: [cli.max_workers][]const u8 = undefined;
    // No `workers =` key at all — the set comes from the CLI at runtime.
    const text =
        \\[secret.integration-lock]
        \\workers = ["gateway.sh", "proxy.sh"]
    ;
    var fc = try parseTest(text, &storage); // must parse (Gap 2 fixed)
    const cmds = [_][]const u8{ "gateway.sh", "proxy.sh", "pmtiles.sh" };
    resolveSecretGrants(fc.secrets[0..fc.secrets_n], fc.secret_refs[0..fc.secrets_n], &cmds);
    try t.expectEqual(@as(usize, 2), fc.secrets[0].workers_len);
    try t.expectEqual(@as(u8, 0), fc.secrets[0].workers[0]); // gateway.sh
    try t.expectEqual(@as(u8, 1), fc.secrets[0].workers[1]); // proxy.sh
}
```

(If `parseTest` returns a value type without addressable fields, bind it to a `var` as above so the slices are addressable. Confirm `parseTest`'s return shape while implementing and adapt the field access — it exposes `.secrets`, `.secrets_n`, `.secret_refs`, `.commands`.)

- [ ] **Step 2: Run to verify they fail**

Run: `zig build test` (WSL)
Expected: FAIL — `resolveSecretGrants` undefined, and the `[secret.s] workers=["nope.sh"]` / no-`workers=` cases still `error.BadValue` at parse.

- [ ] **Step 3: Split `resolveSecrets` in `config.zig`.** Replace the whole `fn resolveSecrets(cfg: *FileConfig) ParseError!void { … }` (currently ~line 522) with a slimmer parse-time env check plus the pure resolver:

```zig
/// Parse-time secret check that needs NO worker set: two secrets must not resolve
/// to the same env var name (both would write CONFD_X — a clobber). Worker-name
/// resolution is deferred to `resolveSecretGrants` (run after the CLI/TOML worker
/// set is final), so an unknown or absent worker is NOT an error here.
fn checkSecretEnvs(cfg: *FileConfig) ParseError!void {
    var a: usize = 0;
    while (a < cfg.secrets_n) : (a += 1) {
        var b: usize = a + 1;
        while (b < cfg.secrets_n) : (b += 1) {
            if (std.mem.eql(u8, cfg.secrets[a].env, cfg.secrets[b].env)) return error.BadValue;
        }
    }
}

/// Resolve each secret's worker-name refs to indices in `commands` — the FINAL,
/// post-merge worker set (CLI `--` args, or TOML `workers=`). Keeps only the
/// workers PRESENT in the set: an absent listed worker is skipped; a grant with
/// no present workers (or an empty list) resolves to zero recipients (inert) —
/// never an error. Deny-by-default: only present, listed workers receive a
/// secret. `refs[si][k]` is the k-th worker name of secret si (parsed, unresolved);
/// `secrets[si].workers_len` on entry is the parsed ref count, on exit the present
/// count. Pure — no alloc beyond the fixed name buffers, no error, no panic.
pub fn resolveSecretGrants(
    secrets: []cli.SecretDef,
    refs: []const [cli.max_secret_workers][]const u8,
    commands: []const []const u8,
) void {
    if (secrets.len == 0) return;
    var name_bufs: [cli.max_workers][names.cap]u8 = undefined;
    var derived: [cli.max_workers][]const u8 = undefined;
    for (commands, 0..) |cmd, i| derived[i] = deriveOne(cmd, name_bufs[i][0..], derived[0..i]);
    const resolved = derived[0..commands.len];
    for (secrets, 0..) |*sec, si| {
        var present: usize = 0;
        var k: usize = 0;
        while (k < sec.workers_len) : (k += 1) {
            if (matchWorker(resolved, refs[si][k])) |idx| {
                sec.workers[present] = idx;
                present += 1;
            } // absent → skip (deny-by-default; inert if none remain)
        }
        sec.workers_len = present; // present count (0 = inert)
    }
}
```

- [ ] **Step 4: Change the parse call site.** At `config.zig` ~line 305, replace `try resolveSecrets(cfg);` with `try checkSecretEnvs(cfg);` so `config.parse` no longer resolves indices (it keeps `secret_refs` + the env-collision check).

- [ ] **Step 5: Wire the resolver into `main.zig`.** Remove the refusal block (currently ~lines 247–250):

```zig
            if (cfg.secrets_n > 0 and cfg.commands.len > 0) {
                logmod.print("[mandor] [secret.*] requires workers defined in the config file, not on the CLI\n", .{});
                return 2;
            }
```

and, immediately AFTER the existing `if (cfg.commands.len == 0) cfg.commands = file_cfg.commands;` line, add:

```zig
            // Resolve [secret.*] grants against the FINAL worker set (CLI args, or
            // TOML workers=). By name, post-merge — so a grant naming a CLI-only
            // worker resolves correctly (no stale indices) and an absent worker is
            // just skipped. This runs for both `run` and `validate`.
            config.resolveSecretGrants(cfg.secrets[0..cfg.secrets_n], file_cfg.secret_refs[0..cfg.secrets_n], cfg.commands);
```

- [ ] **Step 6: Update the existing config secret tests.** These asserted parse-time resolution, which no longer happens:
  - `"secret section: defaults and worker index resolution"`, `"secret section: multiline workers array resolves"`, `"secret section: two secrets are independent"` — after the `parseTest(...)` call, add a `resolveSecretGrants(fc.secrets[0..fc.secrets_n], fc.secret_refs[0..fc.secrets_n], fc.commands)` call and keep the existing index/`workers_len` assertions (they now check the resolver's output). Use `fc.commands` as the worker set (the parsed TOML `workers=`), so the numbers are unchanged.
  - `"secret section: every rejection is a hard error"` — the **unknown-worker** and **empty `workers = []`** cases are no longer errors. Remove those `expectError(error.BadValue, …)` assertions (they move to the resolver tests in Step 1, which prove inert behavior). KEEP any assertions that are still real parse errors (bad `bytes`, bad `format`, a malformed section). Do NOT delete the whole test — trim it to the cases that remain hard errors.
  - `"secret section: bare (non-derived) collision between two default envs"` — UNCHANGED (env-collision still `error.BadValue` at parse).

- [ ] **Step 7: Build + full test**

Run: `zig build test && zig build`
Expected: PASS. `grep -n 'resolveSecrets\b' src/config.zig` returns nothing (renamed). `grep -n 'requires workers defined in the config file' src/main.zig` returns nothing (refusal removed).

- [ ] **Step 8: Commit**

```bash
git add src/config.zig src/main.zig
git commit -m "feat: resolve [secret.*] grants post-merge against the active worker set, skip absent"
```

---

### Task 2: `validate` tolerates orphans; warn on an inert secret (supervisor.zig)

**Files:**
- Modify: `src/supervisor.zig` — `validate` (~lines 225–239): drop the `setup_warnings > 0 → return 1` block; `initSecrets` (~line 289): warn when a grant resolves to zero recipients.

**Interfaces:**
- Consumes: `resolveSecretGrants` output (`SecretDef.workers_len == 0` ⇒ inert); `applyConfig`'s existing per-ref warnings.

- [ ] **Step 1: Write the failing test** — add to `src/supervisor.zig` (near other supervisor tests, or a new inline test). It exercises `validate` with an orphan `[worker.NAME]` section against a CLI-style worker set:

```zig
test "validate tolerates an orphan [worker.NAME] section" {
    // A [worker.NAME] section for a worker not in `commands` is a no-op, not a
    // failure — a static superset TOML must validate against any CLI subset.
    var cfg = cli.Config{};
    var cmds = [_][]const u8{"gateway.sh"};
    cfg.commands = &cmds;
    // One name override for a worker that IS spawned, one for an ORPHAN.
    var name_pairs = [_]cli.HealthSpec{
        .{ .worker = "gateway.sh", .cmd = "backend" },
        .{ .worker = "pmtiles.sh", .cmd = "map-svc" }, // orphan — not spawned
    };
    cfg.name_pairs = undefined;
    @memcpy(cfg.name_pairs[0..2], &name_pairs);
    cfg.name_pairs_n = 2;
    try std.testing.expectEqual(@as(u8, 0), validate(&cfg)); // orphan → warn, exit 0
}
```

(Adapt the `cli.Config` field wiring to how `name_pairs` / `cli.HealthSpec` are actually shaped — read `cli.Config` while implementing. The essential assertion is `validate(&cfg) == 0` with an orphan name/stream ref present. If `cli.Config`'s fixed arrays make inline construction awkward, drive it through `applyConfig` the way the existing supervisor tests do.)

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test`
Expected: FAIL — `validate` returns 1 (`config invalid: N unknown worker reference(s)`) for the orphan ref.

- [ ] **Step 3: Drop the orphan hard-fail in `validate`.** Remove this block (currently ~lines 233–236):

```zig
    if (setup_warnings > 0) {
        logmod.print("[mandor] config invalid: {d} unknown worker reference(s)\n", .{setup_warnings});
        return 1;
    }
```

Leave the rest of `validate` (the `applyConfig` call — which still returns non-zero on real errors like a dependency cycle or a bad value — and `printPlan`). The per-ref `"[mandor] name: no worker named X"` warnings from `applyConfig` stay; they are now informative, not fatal.

- [ ] **Step 4: Warn on an inert secret in `initSecrets`.** In `initSecrets` (~line 289), inside the `for (cfg.secrets[0..cfg.secrets_n], 0..) |def, si|` loop, before or after generating, add a warning when the grant has no recipients:

```zig
        if (def.workers_len == 0) {
            logmod.print("[mandor] secret {s}: no present worker to grant to (ignored)\n", .{def.name});
            continue;
        }
```

(Place it so an inert secret is skipped cleanly — no `secret.generate`, no grant. Confirm `def.name` is in scope.)

- [ ] **Step 5: Build + test**

Run: `zig build test && zig build`
Expected: PASS — the orphan-validate test passes; existing supervisor tests still pass.

- [ ] **Step 6: Commit**

```bash
git add src/supervisor.zig
git commit -m "feat: validate tolerates orphan [worker.*] sections; warn on an inert secret grant"
```

---

### Task 3: Harness e2e — static superset TOML + CLI subset

**Files:**
- Modify: `test/harness/run_tests.sh` — add one case before the `passed $pass, failed $fail` tail.

**Interfaces:**
- Consumes: `$MANDOR` (= `zig-out/bin/mandor`), `$TMP`, the `ok`/`bad` helpers.

- [ ] **Step 1: Add the e2e case** (before the summary `echo` tail):

```bash
# 83. TOML behavior-overlay over the CLI worker set (v1.13). A STATIC superset TOML
# declares [worker.*] name/stream + a [secret.*] grant for workers a AND b, plus an
# orphan [worker."b"] for a worker NOT spawned this run. The CLI spawns only `a`.
# mandor must: validate 0, apply a's overlay, grant the secret to a (present) and
# NOT b (absent), and treat the orphan [worker."b"] as a warning, not a failure.
cat > "$TMP/overlay.toml" <<'TOML'
[worker."a.sh"]
name = "svc-a"
stream = true

[worker."b.sh"]
name = "svc-b"

[secret.lock]
workers = ["a.sh", "b.sh"]
bytes = 16
format = "b64url"
TOML
# validate against a CLI subset (only a.sh) — must pass despite the orphan b.sh section.
if "$MANDOR" validate --config="$TMP/overlay.toml" -- "sh $TMP/a.sh" >/dev/null 2>&1; then
  vok=1
else vok=""; fi
# a.sh prints its granted secret env (CONFD_LOCK) so we can prove it received it.
cat > "$TMP/a.sh" <<'SH'
echo "A_SECRET=[${CONFD_LOCK:-MISSING}]"
sleep 30
SH
"$MANDOR" --config="$TMP/overlay.toml" --state-dir="$TMP/ov_state" -- "sh $TMP/a.sh" >"$TMP/83out" 2>&1 &
mpid=$!
for _ in $(seq 1 60); do grep -q 'A_SECRET=' "$TMP/83out" 2>/dev/null && break; sleep 0.1; done
kill -TERM "$mpid" 2>/dev/null; wait "$mpid" 2>/dev/null
# a.sh got a non-empty secret; validate passed; the orphan b.sh section didn't fail the run.
if [ -n "$vok" ] \
   && grep -q 'A_SECRET=\[..*\]' "$TMP/83out" 2>/dev/null \
   && ! grep -q 'A_SECRET=\[MISSING\]' "$TMP/83out" 2>/dev/null; then
  ok "overlay: static superset TOML applies to the CLI subset; secret reaches the present worker only; orphan section ignored"
else bad "toml overlay" \
  "validate_ok=[$vok] secret_line=[$(grep -o 'A_SECRET=\[[^]]*\]' "$TMP/83out" 2>/dev/null | head -1)]"; fi
```

- [ ] **Step 2: Build the binary + run the harness**

Run (WSL): `zig build && bash test/harness/run_tests.sh`
Expected: the new case prints `ok  overlay: …`; the final line is `passed 83, failed 0` (count +1 from the prior total).

- [ ] **Step 3: Commit**

```bash
git add test/harness/run_tests.sh
git commit -m "test: harness e2e for the TOML behavior-overlay (superset TOML, CLI subset, secret to present worker)"
```

---

### Task 4: Docs + version bump to 1.13.0

**Files:**
- Modify: `build.zig` (`1.12.1` → `1.13.0`), `docs/CONFIG.md`, `CLAUDE.md`, `CHANGELOG.md`.

- [ ] **Step 1: Bump the version** in `build.zig`:

```zig
    const version = b.option([]const u8, "version", "Version string") orelse "1.13.0";
```

- [ ] **Step 2: `docs/CONFIG.md`** — add a short "Workers: CLI vs config" subsection near the `[worker.NAME]` / `[secret.*]` docs stating the model: the active worker set is the CLI `--` args (else TOML `workers=`); `[worker.NAME]` / `[secret.*]` are name-keyed overlays applied to whichever workers the CLI launched; a section for a non-spawned worker is ignored (a warning); a `[secret.*]` grant delivers to the present listed workers and is inert (never an error) if none are present. Note `mandor validate --config=X -- <cmds>` validates against exactly `<cmds>`.

- [ ] **Step 3: `CLAUDE.md`** — update the secret/worker product-boundary note to reflect: secrets resolve against the active worker set (CLI or TOML) and degrade gracefully (present subset; inert if none), deny-by-default preserved; a `[worker.NAME]`/`[secret.*]` reference never spawns anything and an orphan is ignored.

- [ ] **Step 4: `CHANGELOG.md`** — add `## [1.13.0] - 2026-08-12` above `## [1.12.1]`:
  - **Added/Changed:** the TOML is now a name-keyed behavior overlay over the CLI-chosen worker set. `[worker.NAME]` sections and `[secret.*]` grants for workers not spawned this run are ignored (warned), so one static, never-rewritten TOML can describe a superset of possible workers. `[secret.*]` grants resolve against the CLI `--` worker set (incl. `mandor validate -- <cmds>`) and deliver to the present subset — an absent or empty grant is inert, never an error. The "`[secret.*]` requires config-file workers" restriction is removed. Non-breaking; the worker command line stays CLI-only.

- [ ] **Step 5: Full verify (WSL)**

```bash
zig fmt --check src && zig build test && zig build
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe -p /tmp/x64 && strip /tmp/x64/bin/mandor && stat -c %s /tmp/x64/bin/mandor   # < 512000
zig-out/bin/mandor --version   # mandor 1.13.0
```

- [ ] **Step 6: Commit**

```bash
git add build.zig docs/CONFIG.md CLAUDE.md CHANGELOG.md
git commit -m "docs: TOML behavior-overlay model + graceful secrets; bump to 1.13.0"
```

---

## Self-Review

- **Spec coverage:** Gap 1 orphan tolerance (Task 2 validate) ✓; Gap 2 resolve against CLI set + `validate -- <cmds>` (Task 1 defers resolution to post-merge; the resolver runs for run + validate) ✓; secrets grant present subset / inert-never-error (Task 1 resolver) ✓; env-collision stays an error (Task 1 `checkSecretEnvs`) ✓; refusal removed (Task 1) ✓; CLI-only command line (unchanged; no key added) ✓; non-breaking (existing tests kept where behavior is unchanged; loosened cases updated) ✓; harness proof (Task 3) ✓; docs + 1.13.0 (Task 4) ✓; deny-by-default (resolver grants only present+listed) ✓.
- **Placeholder scan:** none — the new function + tests are shown in full. Existing-test adaptations name the exact tests and the exact change (the implementer reads their bodies).
- **Type consistency:** `resolveSecretGrants(secrets: []cli.SecretDef, refs: []const [cli.max_secret_workers][]const u8, commands: []const []const u8) void` is defined in Task 1 and called identically in Task 1 Step 5 and the Task 1 tests; `SecretDef.workers_len` semantics (parsed ref count in → present count out) are consistent across the resolver, its tests, and the `initSecrets` inert check (Task 2).
- Note: `deriveOne`/`matchWorker` stay private in `config.zig` and are used only by the co-located resolver — no visibility change needed.
