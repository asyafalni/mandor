# App Shared Secret Store — implementation plan

> Design: `docs/superpowers/specs/2026-08-04-app-shared-secret-store-design.md`.
> Branch: `feat/app-shared-secret-store`. REQUIRED: subagent-driven; each task
> ends green + committed with a mutation check. Motto governs every task.

**Goal:** mandor mints per-session secrets and delivers each only to its granted
workers over an inherited pipe fd (env `CONFD_<NAME>` or a configured `env`),
never via ENV value/argv/disk; deny-by-default; persist + re-deliver for the
session.

## Global constraints (every task)
- **Stability leads:** no `unreachable`, no panic on any reachable path;
  ReleaseSafe. Arithmetic on sizes saturates. A test isn't done until a MUTATION
  makes a named test fail.
- **Light:** fixed/preallocated buffers, zero steady-state allocation, no deps
  (`getrandom` is a raw `std.os.linux` syscall; encoders are hand-rolled tables).
- **Fast:** encoders are O(n); secret work happens only at boot + per spawn,
  never on the poll hot path.
- **Security:** secret values live only in mandor's `mlock`-ed buffers + the
  per-spawn pipe; only the fd *number* enters a child's env; the read end is
  CLOEXEC and cleared only for granted workers (the `keep_fd` trick, generalized
  to a list). No file, no socket, no fetch path.
- Build/test in WSL (`ZIG_LOCAL_CACHE_DIR=$HOME/.cache/mandor-zig`,
  `~/tools/zig-x86_64-linux-0.16.0/zig`). `zig fmt --check src build.zig` BEFORE
  tagging/each commit (a separate CI gate). Commit in WSL (no AI attribution),
  push in PowerShell. **Subagents write; parent builds/verifies** (WSL builds are
  ~9 min; `zig build test` does NOT analyze main-only code — the exe build does).
- Zig 0.16: `catch |_|` and `else |e| { _ = e; }` are compile errors — use
  `catch {}` / `catch return X` / `else |_| {}`.

## File structure
- **Create `src/secret.zig`** — CSPRNG draw + the six encoders. Pure, unit-testable.
- **Modify `src/config.zig`** — parse `[secret.NAME]` sections into `SecretDef`s
  + validation; carry them in the config.
- **Modify `src/cli.zig`** — carry `SecretDef`s through `cli.Config`.
- **Modify `src/spawner.zig`** — per-spawn secret delivery: pipe per granted
  secret, write value, inherit read end (multi-fd CLOEXEC-clear), inject the fd
  env var into the child; generalize `keep_fd` → a small fd list.
- **Modify `src/supervisor.zig`** — a secret registry: generate each value once
  (mlock) at boot; on each worker (re)spawn, deliver its granted secrets; wipe at
  shutdown.
- **Modify `src/main.zig`** — add `secret.zig` to the `test {}` block.
- **Modify `docs/CONFIG.md`** — document `[secret.NAME]` (final task, with code).

---

### Task 1: `secret.zig` — CSPRNG + encoders

**Files:** create `src/secret.zig`; modify `src/main.zig` (test import).

**Produces:**
```zig
pub const Format = enum { hex, b10, b32, b64, b64url, raw };
pub fn parseFormat(s: []const u8) ?Format;      // "hex".. -> enum, else null

/// Fill `out` with the encoded secret. For raw/hex/b32/b64/b64url, `n` = entropy
/// bytes; for b10, `n` = digit count. Draws fresh CSPRNG bytes internally
/// (getrandom). Returns the encoded slice (out[0..len]) or error.
///   - printable formats: NO trailing newline here (the delivery layer adds it)
///   - raw: exactly `n` raw bytes
pub fn generate(out: []u8, fmt: Format, n: usize) error{ Rand, Overflow }![]const u8;

/// Max output length for (fmt, n) so callers can size buffers.
pub fn encodedLen(fmt: Format, n: usize) usize;

// internal, tested directly: hexEncode, b32Encode (RFC4648 upper, no pad),
// b64Encode (std +/=), b64urlEncode (-_ no pad), b10 rejection sampler.
```

- [ ] **Step 1: failing tests** (inline in secret.zig). Test encoders with a
  FIXED byte input (inject bytes rather than getrandom, so deterministic — factor
  each encoder as `fn xEncode(src: []const u8, out: []u8) []const u8`):
```zig
test "hex lowercases 2 chars/byte" { try expectEqualStrings("00ff10", hexEncode(&.{0,255,16}, &buf)); }
test "b32 RFC4648 upper no pad" { /* known vector, e.g. bytes "foob" */ }
test "b64 standard padded" { try expectEqualStrings("Zm9vYmFy", b64Encode("foobar", &buf)); }
test "b64url urlsafe no pad" { /* bytes -> -_ , no = */ }
test "b10 digit count + charset" { var s = seededSampler(...); const d = b10(&s, 6, &buf); try expectEqual(@as(usize,6), d.len); for (d) |c| try expect(c>='0' and c<='9'); }
test "b10 rejection is unbiased" { /* draw many digits from a controlled byte stream incl. 250..255; assert 250..255 are skipped, 0..249 map 0..9 evenly */ }
test "encodedLen matches encoders" { /* len(hex)==2n, b64 padded len, etc. */ }
test "generate raw returns exactly n bytes" { var o:[16]u8=undefined; try expectEqual(@as(usize,16),(try generate(&o,.raw,16)).len); }
```

- [ ] **Step 2** run → fail. **Step 3** implement (getrandom via
  `std.os.linux.getrandom`/`syscall`; encoders table-driven; b10 rejection: byte
  `<250` → `%10`, else redraw; `generate` composes draw+encode; `encodedLen`
  exact). Verify `getrandom` signature against local std. **Step 4** run → pass.

- [ ] **Step 5 mutation:** change the b10 bound `250` → `256`; confirm the
  unbiased test fails. Restore.
- [ ] **Step 6 size + commit** (`feat: secret.zig — CSPRNG + hex/b10/b32/b64/b64url/raw encoders`).

---

### Task 2: `[secret.NAME]` config parsing + validation

**Files:** `src/config.zig`, `src/cli.zig`.

- Consumes: `secret.Format`/`parseFormat` (Task 1).
- Produces (in `cli.Config`, fixed capacity, e.g. `max_secrets = 16`):
```zig
pub const SecretDef = struct {
    name: []const u8,          // lowercase [a-z0-9-]
    env: []const u8,           // resolved: configured `env` or "CONFD_" ++ UPPER(name, - -> _)
    fmt: secret.Format = .hex,
    n: usize = 32,             // bytes, or digits for b10
    workers: [max_secret_workers]u8 = undefined, // worker INDICES into the workers array
    workers_len: usize = 0,
};
```

**Read first:** how `config.zig` parses `[worker.NAME]` sections (`sectionWorker`,
`workerKey`, the quoted-section-key handling added for the name override) and how
`applyConfig` resolves worker names → indices. Mirror that for `[secret.NAME]`.

- [ ] TDD (inline config tests):
  - parse `[secret.integration] workers=["gateway","proxy"]` → one SecretDef,
    env `CONFD_INTEGRATION`, fmt hex, n 32, two worker indices.
  - `bytes`/`format`/`env` overrides parse; `env` default derives correctly
    (`db-signing` → `CONFD_DB_SIGNING`).
  - **Rejections (each a hard error):** unknown worker name; empty `workers`;
    `bytes` 0 or >4096; unknown `format`; `env` not matching `^[A-Z_][A-Z0-9_]*$`;
    two secrets resolving to the same `env`; unknown key in a `[secret.*]` section.
- [ ] Mutation: drop the `bytes` upper-bound check; confirm the ">4096 rejected"
  test fails. Commit (`feat: parse [secret.NAME] sections with validation`).

---

### Task 3: per-spawn secret delivery (pipe + fd inherit + env inject)

**Files:** `src/spawner.zig` (+ a small registry surface used by supervisor).

**Read first:** the worker spawn path — how `spawner` builds the child's **envp**
(mandor environ + per-worker `[worker.NAME] env`) and execs, and `spawnDetached`'s
existing single `keep_fd` CLOEXEC-clear. Generalize to: a list of `(fd, env_name)`
the child must inherit + have injected.

- Produces a spawn-time hook: given a worker and the resolved list of its granted
  secrets `[]struct { value: []const u8, env: []const u8, raw: bool }`, for each:
  1. `pipe2(.{ .CLOEXEC = true })`; write `value` (+ `\n` unless `raw`) to the
     write end (≤ few KB < PIPE_BUF, never blocks);
  2. record `(read_fd, env_name)` for the child;
  3. in the child pre-exec: clear CLOEXEC on each read_fd; add `env_name=<read_fd>`
     to envp;
  4. parent closes both ends after fork.
- Zero alloc on the steady path beyond fixed per-spawn scratch; no `unreachable`;
  a pipe/getrandom failure for one secret logs + skips that secret (worker's read
  gets EOF → fails its own check — fail-closed), never crashes the spawn.

- [ ] Unit-test the pieces that are pure (env-name formatting; the child fd/env
  list assembly). The full spawn is integration (Task 4 harness). Commit
  (`feat: deliver secrets to workers over inherited pipe fds`).

---

### Task 4: supervisor wiring, lifecycle, docs, e2e

**Files:** `src/supervisor.zig`, `src/main.zig`, `docs/CONFIG.md`.

- **Registry/generation:** at startup, for each `SecretDef`, `secret.generate`
  into a fixed, `mlock`-ed buffer held for the session (a `[max_secrets]` array of
  fixed value buffers). Map worker index → its granted secrets.
- **Delivery:** in the worker (re)spawn path, pass the worker's granted secrets to
  the Task-3 hook — so restarts re-deliver the same session value.
- **Lifecycle:** value generated once per mandor process; re-delivered on each
  spawn; best-effort `memset`-wipe at shutdown. No fetch path anywhere.
- **Docs:** `docs/CONFIG.md` — a `[secret.NAME]` section (keys, formats, the
  `CONFD_<NAME>`/`env` var, deny-by-default, the consumer one-liners). Keep the
  4-flag CLI rule (TOML-only). Watch the config-surface CI gate.

- [ ] **Verify (parent):** `zig fmt --check`; `zig build test`; **exe** build
  (analyzes the spawn/supervisor path). Then a harness e2e (`test/harness/` or
  `test/secret/`): a mandor.toml with `[secret.s] workers=["a"]`, worker `a`
  reads `CONFD_S` and echoes the length/charset (assert matches format); worker
  `b` (not granted) has **no** `CONFD_S` in its env; two workers granted the same
  secret echo the **same** value; a worker restart re-delivers the **same** value;
  a `raw`/`b10` format round-trips. Poll for state — no fixed-sleep races.
- [ ] **Mutation:** disable the CLOEXEC-clear (deliver the read end to every
  worker) → confirm the "worker b has no CONFD_S" harness case fails; restore.
- [ ] Size (`[size]` if >2 KB, with reason). Commit (`feat: wire app shared
  secret store — generate, deliver per spawn, lock by construction`).

## Self-review
- Deny-by-default: a worker only gets fds/env for secrets whose `workers` include
  it (Task 2 indices → Task 3 delivery) ✓
- Non-ENV value / non-disk / non-argv: only the fd number is in env; value only in
  mlock'd mem + transient pipe ✓
- Persist + re-deliver on restart: value generated once, delivered each spawn ✓
- b10 unbiased, formats byte-exact ✓ (Task 1 mutation)
- Order: T1 (leaf) → T2 (config) → T3 (delivery mechanics) → T4 (wiring + e2e).
