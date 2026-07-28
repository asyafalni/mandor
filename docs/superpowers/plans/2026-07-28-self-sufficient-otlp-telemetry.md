# Self-sufficient OTLP telemetry — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: use superpowers:executing-plans
> (or subagent-driven-development) to implement task-by-task. Steps use checkbox
> (`- [ ]`) syntax. Design: `docs/superpowers/specs/2026-07-28-self-sufficient-otlp-telemetry-design.md`.

**Goal:** When `photon = "host:port"` is set, mandor ships incidents, process
lifecycle events, and per-process/supervisor metrics to photon as OTLP protobuf,
via one long-lived relay child — no collector in the container. Off by default.

**Architecture:** A long-lived `mandor relay --daemon` child owns the socket. The
supervisor core writes compact framed records to it over a non-blocking pipe
(lifecycle events, metric samples) and writes incidents to the durable spool as
today; the daemon watches the spool (priority, never dropped) and drains the pipe
(routine, dropped under backpressure), encodes OTLP, and POSTs. Priority is the
durability tier, not an in-memory heap.

**Tech stack:** Zig 0.16.0, raw `std.os.linux` syscalls (no libc), hand-rolled
OTLP protobuf (extend `relay.zig`'s existing encoder), fixed preallocated buffers.

## Global constraints (every task inherits these — copied from the spec)

- **Supervision path touches no socket, ever.** All network I/O is in the daemon
  child. The core's pipe write is **non-blocking**; on `EAGAIN` it drops and
  moves on — never blocks, never retries, never allocates on the hot path.
- **Offline by default:** no `photon=` → no daemon spawned → no socket.
- **Incidents are never dropped:** durable on the spool, retried by the daemon.
- **ReleaseSafe; no `unreachable`, no panic** on any path a running mandor
  reaches, including the daemon. Every syscall error handled.
- **Size budget:** stripped x64 currently ~256 KB; hard gate 500 KB, per-commit
  2 KB delta gate (`[size]` in the commit subject bypasses, with a recorded
  reason in the body). Measure every task.
- **Build/test in WSL, commit in WSL, push in PowerShell** (identity is WSL-only,
  SSH key is Windows-only):
  ```
  wsl -e sh -c 'cd /mnt/c/Users/nodeflux/Downloads/mandor && \
    ZIG_LOCAL_CACHE_DIR=$HOME/.cache/mandor-zig \
    ~/tools/zig-x86_64-linux-0.16.0/zig build test'
  ```
  Size check: `... zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl && \
  strip -s zig-out/bin/mandor && wc -c zig-out/bin/mandor`.
- **Verify Zig signatures against local std**, not memory (`std.posix` lacks
  fork/pipe2/write — use `std.os.linux` raw + `posix.errno(rc)`). Compile after
  every task, not every feature.
- **Mutation-test every fix:** after green, break the guard, confirm a *named*
  test fails, restore. "Unreferenced" ≠ "unneeded".

## File structure

- **Create `src/frame.zig`** — the pipe wire format shared by core (writer) and
  daemon (reader): `Kind` enum, `MetricSample`/`LifecycleEvent` payload structs,
  `encode()`/`decode()`. Pure, no syscalls, fully unit-testable. One
  responsibility: framing.
- **Modify `src/relay.zig`** — add `runDaemon(...)` (the long-lived loop),
  `buildOtlpMetrics(...)`, `buildOtlpEvent(...)`. Reuse existing `Writer`,
  `tagByte`/`varint*`/`delimLen`, `putKeyValue`/`putAnyValue`, `post`,
  `statusOk`, `resolve`. Keep the existing one-shot `run()` (still used by the
  `on_incident` hook).
- **Modify `src/incident.zig`** — retire the per-incident `firePhoton` re-exec
  (the daemon watches the spool now). Keep `spool.write`. Repurpose
  `noteForward`/`drainForwards` into daemon lifecycle helpers, or replace with
  `telemetry.zig` glue (Task 2 decides the smaller diff).
- **Modify `src/supervisor.zig`** — spawn the daemon when `photon=` set
  (near `:241`); write framed records at the sampler tick (`:825`) and lifecycle
  points (`:561`, `:902`, `:904`, and the spawn site); drain the daemon at
  shutdown (`:427`).
- **Modify `src/main.zig`** — route `relay --daemon`; add `frame.zig` to the
  `test {}` import block.
- **Modify `docs/CONFIG.md`, `CLAUDE.md`, `docs/INTEGRATION-PHOTON.md`** — in the
  FINAL task only, with the code: flip the boundary to "mandor optionally speaks
  OTLP" and document `telemetry.*` keys.

---

### Task 1: `frame.zig` — the pipe wire format

**Files:**
- Create: `src/frame.zig`
- Modify: `src/main.zig` (add `_ = @import("frame.zig");` to `test {}`)

**Interfaces — Produces:**
```zig
pub const Kind = enum(u8) { metric_sample = 1, lifecycle_event = 2 };

// Compact fixed payloads — mandor's internal form, NOT OTLP. Names are slices
// into caller-owned memory at encode time; decode copies into caller scratch.
pub const MetricSample = struct {
    name: []const u8, // worker name
    rss_kb: u64, cpu_pct: u16, fds: u16, threads: u16, restarts: u32,
    t_unix_ns: u64,
};
pub const Lifecycle = struct {
    name: []const u8,
    ev: Event, // enum { started, exited, restarting, oom, health_up, health_down }
    code: i32 = 0,      // exit code or signal number, per ev
    backoff_ms: u32 = 0,
    restarts: u32 = 0,
    t_unix_ns: u64,
};
pub const Event = enum(u8) { started, exited_ok, exited_err, restarting, oom, health_up, health_down };

/// Encode one record into `out`; returns the framed slice or error.Overflow.
/// Frame = [u8 kind][u16 len LE][payload]. Names capped at 255 bytes.
pub fn encodeMetric(out: []u8, s: MetricSample) error{Overflow}![]const u8;
pub fn encodeLifecycle(out: []u8, e: Lifecycle) error{Overflow}![]const u8;

/// Decode one frame from the front of `buf`. Returns the record and the number
/// of bytes consumed, or null if `buf` holds less than one whole frame.
pub const Decoded = union(Kind) { metric_sample: MetricSample, lifecycle_event: Lifecycle };
pub fn decode(buf: []const u8, name_scratch: []u8) ?struct { rec: Decoded, used: usize };
```

- [ ] **Step 1: Write the failing round-trip test**

```zig
const std = @import("std");
const frame = @import("frame.zig");
const testing = std.testing;

test "metric sample survives encode -> decode" {
    var out: [512]u8 = undefined;
    const s = frame.MetricSample{ .name = "api", .rss_kb = 812_000, .cpu_pct = 97,
        .fds = 42, .threads = 8, .restarts = 3, .t_unix_ns = 1_700_000_000_000_000_000 };
    const bytes = try frame.encodeMetric(&out, s);

    var scratch: [256]u8 = undefined;
    const d = frame.decode(bytes, &scratch).?;
    try testing.expectEqual(@as(usize, bytes.len), d.used);
    const got = d.rec.metric_sample;
    try testing.expectEqualStrings("api", got.name);
    try testing.expectEqual(s.rss_kb, got.rss_kb);
    try testing.expectEqual(s.cpu_pct, got.cpu_pct);
    try testing.expectEqual(s.restarts, got.restarts);
    try testing.expectEqual(s.t_unix_ns, got.t_unix_ns);
}

test "decode returns null on a partial frame" {
    var out: [512]u8 = undefined;
    const bytes = try frame.encodeMetric(&out, .{ .name = "x", .rss_kb = 1, .cpu_pct = 0,
        .fds = 0, .threads = 0, .restarts = 0, .t_unix_ns = 1 });
    var scratch: [256]u8 = undefined;
    try testing.expect(frame.decode(bytes[0 .. bytes.len - 1], &scratch) == null);
}

test "encode refuses a name that would overflow the frame" {
    var out: [8]u8 = undefined; // deliberately tiny
    try testing.expectError(error.Overflow,
        frame.encodeMetric(&out, .{ .name = "toolongforthisbuffer", .rss_kb = 0,
        .cpu_pct = 0, .fds = 0, .threads = 0, .restarts = 0, .t_unix_ns = 0 }));
}
```

- [ ] **Step 2: Run, verify it fails to compile (frame.zig absent)**
  `zig build test` → expected FAIL: `import of file outside module path` / undefined.

- [ ] **Step 3: Implement `src/frame.zig`.** Fixed little-endian layout, no
  allocation. Metric payload = `[u8 name_len][name][u64 rss][u16 cpu][u16 fds]
  [u16 threads][u32 restarts][u64 t_ns]`; lifecycle = `[u8 name_len][name]
  [u8 ev][i32 code][u32 backoff][u32 restarts][u64 t_ns]`. `encode*` bounds-check
  `1 + 2 + payload <= out.len` and return `error.Overflow` otherwise (names
  capped 255). `decode` reads the `[u8 kind][u16 len]` header, returns null if
  `buf.len < 3 + len`, copies the name into `name_scratch`, and reads the fields.
  Use `std.mem.writeInt`/`readInt` with `.little`. No `unreachable`.

- [ ] **Step 4: Add `_ = @import("frame.zig");` to the `test {}` block in main.zig**, run `zig build test` → PASS.

- [ ] **Step 5: Mutation check.** Change `decode`'s `buf.len < 3 + len` guard to
  `<= 3 + len` (or drop it); confirm "decode returns null on a partial frame"
  now fails; restore.

- [ ] **Step 6: Size + commit.**
```bash
git add src/frame.zig src/main.zig
git commit -m "feat: frame.zig — compact pipe wire format for telemetry records"
```

**Interfaces — Consumes:** none (leaf module).

---

### Task 2: OTLP encoders for metrics and lifecycle events

**Files:**
- Modify: `src/relay.zig` (add `buildOtlpMetrics`, `buildOtlpEvent`, tests)

**Interfaces:**
- Consumes: `frame.MetricSample`, `frame.Lifecycle` (Task 1); reuses `relay.zig`
  private `Writer`, `tagByte`, `varintLen`, `delimLen`, `keyValueLen`,
  `putKeyValue`, `putAnyValue`, `body_buf`.
- Produces:
  ```zig
  pub fn buildOtlpMetrics(samples: []const frame.MetricSample) error{TooLarge}![]const u8;
  pub fn buildOtlpEvent(e: frame.Lifecycle) error{TooLarge}![]const u8; // one LogRecord
  ```

**OTLP metrics wire shape** (opentelemetry-proto metrics/v1, all field numbers ≤ 15
→ one-byte tags). One `ResourceMetrics` **per worker** so `service.name` in the
resource matches the incident logs' service grouping:

```
ExportMetricsServiceRequest { resource_metrics = 1 }
  ResourceMetrics { resource = 1 (service.name attr), scope_metrics = 2 }
    ScopeMetrics { metrics = 2 }
      Metric { name = 1, unit = 3, gauge = 5 | sum = 7 }
        Gauge { data_points = 1 }  |  Sum { data_points=1, aggregation_temporality=2, is_monotonic=3 }
          NumberDataPoint { time_unix_nano = 3 (fixed64), as_int = 6 (sfixed64/fixed64 wire) }
```
Emit rss/cpu/fds/threads as **Gauge**; restarts as **Sum** (temporality =
2 CUMULATIVE, is_monotonic = true). `as_int` is field 6, wire type 1 (fixed64).

- [ ] **Step 1: Write the failing metrics-encoder test** (reuses the in-file
  `Fields` reader that already validates `buildOtlp`):

```zig
test "buildOtlpMetrics emits per-worker gauges photon can walk" {
    const s = frame.MetricSample{ .name = "api", .rss_kb = 1000, .cpu_pct = 50,
        .fds = 10, .threads = 4, .restarts = 2, .t_unix_ns = 1_700_000_000_000_000_000 };
    const body = try buildOtlpMetrics(&.{s});

    const rm = Fields.get(body, 1).?.bytes;        // resource_metrics
    const res = Fields.get(rm, 1).?.bytes;          // resource
    const attr = Fields.get(res, 1).?.bytes;        // first attribute
    try testing.expectEqualStrings("service.name", Fields.get(attr, 1).?.bytes);
    try testing.expectEqualStrings("api", avStr(Fields.get(attr, 2).?.bytes));

    const sm = Fields.get(rm, 2).?.bytes;           // scope_metrics
    // first Metric is rss gauge; datapoint as_int == rss_kb bytes (1000)
    const metric = Fields.get(sm, 2).?.bytes;
    const gauge = Fields.get(metric, 5).?.bytes;
    const dp = Fields.get(gauge, 1).?.bytes;
    try testing.expectEqual(@as(u8, 1), Fields.get(dp, 3).?.wire); // time fixed64
    try testing.expectEqual(@as(u64, 1000), Fields.get(dp, 6).?.int); // as_int
}

test "buildOtlpMetrics rejects a batch too large for body_buf" {
    // Build enough samples to overflow body_buf; expect error, not a panic.
    // (size the array from body_buf.len / per-sample bytes at implementation.)
}
```

- [ ] **Step 2: Run → FAIL** (`buildOtlpMetrics` undefined).

- [ ] **Step 3: Implement `buildOtlpMetrics`** mirroring `buildOtlp`'s **two-pass
  sizing** exactly (size innermost-first, check `> body_buf.len` → `error.TooLarge`,
  then write; end with `std.debug.assert(w.pos == total)`). Add a private
  `numberDataPoint`/`gaugeMetric`/`sumMetric` helper trio to keep it DRY. Field
  numbers per the shape above. **Verify each field number against a local copy of
  opentelemetry-proto or a captured photon request before trusting it** — a wrong
  tag fails the test above, which is the point.

- [ ] **Step 4: Run → PASS.**

- [ ] **Step 5: Write + pass `buildOtlpEvent`** — one `LogRecord` from a
  `frame.Lifecycle` (body = rendered string e.g. `"worker api exited signal:SIGSEGV"`,
  severity WARN/ERROR/INFO per `ev`, `service.name` = worker, attrs
  `exit.code`/`restart.count`/`backoff.ms`). Reuse the logs nesting from
  `buildOtlp`. Test via `firstRecord`/`Fields` that body + severity + service.name
  are correct for `exited_err` and `health_down`.

- [ ] **Step 6: Mutation check.** Flip the rss gauge field from 5 to 7 (sum);
  confirm the metrics test fails on wire/shape; restore. Change one severity
  mapping in `buildOtlpEvent`; confirm its test fails; restore.

- [ ] **Step 7: Size + commit.**
```bash
git add src/relay.zig
git commit -m "feat: OTLP metrics + lifecycle-event encoders (reuse the relay protobuf writer)"
```

---

### Task 3: the long-lived relay daemon

**Files:**
- Modify: `src/relay.zig` (add `runDaemon`), `src/main.zig` (route `relay --daemon`)

**Interfaces:**
- Consumes: `buildOtlpMetrics`/`buildOtlpEvent`/`buildOtlp`/`post`/`resolve`
  (this file), `frame.decode` (Task 1), `spool.listIncidents` (enumerate the
  spool, already sorted), `spool` bundle path convention.
- Produces:
  ```zig
  /// Long-lived: owns the socket. Loops until stdin/pipe EOF or SIGTERM.
  /// endpoint like "host:port"; spool_dir is the incidents dir; pipe_fd is the
  /// inherited read end (nonblocking). Returns an exit code.
  pub fn runDaemon(endpoint: []const u8, spool_dir: []const u8, pipe_fd: i32,
      environ: [:null]const ?[*:0]const u8) u8;
  ```

**Behavior (each cycle, interval default 1 s):**
1. **Spool first (priority, durable):** enumerate `spool_dir`; for every bundle
   name lexically greater than the in-memory `watermark` (last shipped), ship it
   via existing `buildOtlp` + `post`. On success advance the watermark; on send
   failure leave the watermark (retry next cycle — never dropped). Spool names are
   monotonic epoch-ms, so a single high-watermark string suffices; verify the
   naming in `spool.zig` and fall back to a small shipped-set if collisions exist.
2. **Drain the pipe (routine, best-effort):** `read` the nonblocking pipe into a
   fixed ring; `frame.decode` each whole frame; batch metric samples and encode
   one `buildOtlpMetrics`, POST to `/v1/metrics`; encode lifecycle events and POST
   to `/v1/logs`. On ring-full, drop-oldest. On `post` failure, drop the routine
   batch (do NOT retry — routine is ephemeral).
3. Sleep to the next interval (nanosleep), re-check pipe EOF (parent gone → flush
   and exit).

`post` currently hardcodes `POST /v1/logs`. **Refactor `post` to take a path
argument** (`/v1/logs` or `/v1/metrics`) — small, and its existing tests stay
green since logs is the default.

- [ ] **Step 1: Refactor `post(host, port, body, token)` →
  `post(host, port, path, body, token)`.** Update the one existing caller in
  `run()`. Run `zig build test` → existing relay tests PASS (no behavior change).

- [ ] **Step 2: Implement `runDaemon`.** Non-blocking pipe read loop + spool scan.
  Handle `SIGTERM` for clean shutdown (signalfd or a flag — match how the child is
  told to exit in Task 4's drain). No `unreachable`; every syscall error → skip
  this cycle, keep looping. Reuse `resolve.resolve(endpoint)` once at startup;
  re-resolve on connect failure (photon may restart with a new IP under compose).

- [ ] **Step 3: Route the subcommand in `main.zig`.** `mandor relay --daemon`
  reads endpoint/spool_dir/pipe_fd from argv/env (the parent passes them). Keep
  the existing `mandor relay <file> [endpoint]` one-shot path untouched.

- [ ] **Step 4: Harness integration test** (`test/harness/`, new case): start a
  fake photon (a shell `nc`/python one-liner that accepts and 200s, logging
  requests), run `mandor relay --daemon` against a temp spool dir with two
  pre-written bundle files + a few framed records piped in, **poll** (no fixed
  sleep — this repo has been bitten ≥4×) until the fake photon has logged the
  incident POSTs, assert both bundles shipped and a `/v1/metrics` POST arrived.

- [ ] **Step 5: Backpressure test.** Point the daemon at a black-hole photon
  (accepts, never reads). Assert: it does not wedge (10 s socket timeout fires),
  the spool bundles remain on disk (not deleted), and the process stays alive to
  retry. Poll for state.

- [ ] **Step 6: Mutation check.** Make the spool step run *after* the pipe drain
  (break "spool first"); confirm the priority-ordering assertion fails. Make the
  routine `post` failure retry-forever; confirm the backpressure test hangs
  (detected by the harness timeout). Restore both.

- [ ] **Step 7: Size + commit.**
```bash
git add src/relay.zig src/main.zig test/harness/*
git commit -m "feat: long-lived relay daemon — watches spool (priority), drains pipe (routine)"
```

---

### Task 4: wire the core — spawn the daemon, feed it, drain it

**Files:**
- Modify: `src/supervisor.zig`, `src/incident.zig`, `docs/CONFIG.md`,
  `CLAUDE.md`, `docs/INTEGRATION-PHOTON.md`

**Interfaces:**
- Consumes: `runDaemon` (via re-exec of `/proc/self/exe relay --daemon`),
  `frame.encodeMetric`/`encodeLifecycle`, `spawner.spawnDetached`.
- Produces: framed records on the pipe at the four emit points; daemon lifecycle.

**Emit points (verified line numbers, re-confirm before editing):**
- `supervisor.zig:241` — after `incident.setPhoton`, spawn the daemon: create
  `pipe2(O_NONBLOCK|O_CLOEXEC)`, `spawnDetached("/proc/self/exe","relay","--daemon",…)`
  with the read end dup'd to a known fd (or passed via arg), keep the write end.
- `:825` `runSamplerTick` — after `sampler.sample(...)` yields `s`, build a
  `frame.MetricSample` and **non-blocking** write to the pipe; on `EAGAIN`, drop.
- `:902` `onDeath` / `:904` `onRestartLoop` / `:561` `onUnhealthy` / spawn site —
  emit the matching `frame.Lifecycle` event (exited_err/oom, restarting, health_down,
  started). These are in `incident.zig`/`supervisor.zig`; put the pipe write in
  one `telemetry.emit*` helper so all four sites are one line (DRY).
- `:427` shutdown — replace `incident.drainForwards(forward_drain_ms)` with:
  signal the daemon to flush (send SIGTERM, or write a `flush` frame), wait up to
  the drain budget for it to exit (reuse the existing bounded-wait loop shape),
  then exit.

**Retire the per-incident re-exec:** in `incident.zig`, `writeBundle` no longer
calls `firePhoton` (the daemon watches the spool). Remove `firePhoton` and the
`photon_endpoint` re-exec; keep `setPhoton` only as the enable flag the supervisor
reads to decide whether to spawn the daemon. `fireHook` (the generic `on_incident`
hook) stays — it is a separate feature.

- [ ] **Step 1: Add the non-blocking pipe writer helper** (core side, e.g. in a
  small `telemetry.zig` or top of supervisor): holds the write fd, exposes
  `emitMetric(s)` / `emitLifecycle(e)` that encode via `frame` into a stack buffer
  and `linux.write`; on `EAGAIN`/`EPIPE` return silently (drop). Unit-test the
  encode path (the drop path is covered by Task 3's backpressure harness).

- [ ] **Step 2: Spawn the daemon when `photon=` is set** (`:241`). Guard: only
  when the key is present — no key, no pipe, no child (offline default preserved).
  `zig build test` + a harness case asserting no `relay` child exists without the
  key.

- [ ] **Step 3: Emit at the four points.** Wire `:825` (metric), `:902/:904/:561`
  + spawn (lifecycle). Keep each site to one helper call.

- [ ] **Step 4: Replace the shutdown drain** (`:427`) and **remove `firePhoton`**.
  Confirm the existing "forward not killed at exit" behavior still holds — the
  daemon must get its flush budget. Reuse/rename `drainForwards`.

- [ ] **Step 5: Extend the photon e2e** (`test/photon/e2e.sh`): a real crash +
  live metrics through the daemon to a containerized photon. Assert
  `/api/search` shows the incident (with its log summary), `/api/storage` shows
  metric rows, and a lifecycle event log is queryable. Poll photon's WAL flush
  (~25 s) — do not fixed-sleep.

- [ ] **Step 6: Flip the product boundary — docs, WITH the code.**
  - `CLAUDE.md`: change the non-goal to **"mandor optionally speaks OTLP"** (off
    by default; the daemon, never the supervision path, ships when `photon=` set).
  - `docs/INTEGRATION-PHOTON.md`: mandor is now self-sufficient — no collector
    needed for incidents/metrics/lifecycle; the collector note stays only as the
    alternative for third-party pull metrics.
  - `docs/CONFIG.md`: document `telemetry.metrics` / `telemetry.interval` /
    `telemetry.ring`.

- [ ] **Step 7: Full verification.**
  - `zig build test` (all unit) + full harness + soak (assert daemon RSS/fd flat,
    no leak) + the photon e2e.
  - Size gate: stripped x64 musl `wc -c`; record delta in the commit body; if it
    crosses the 2 KB per-commit gate, `[size]` subject + reason (the OTLP metrics
    encoder is the expected growth).
  - Mutation check: disable the `photon=` guard so the daemon spawns unconditionally
    → confirm the "no child without the key" harness case fails; restore.

- [ ] **Step 8: Commit.**
```bash
git add -A
git commit -m "feat: self-sufficient OTLP telemetry — daemon ships incidents, metrics, lifecycle to photon

mandor optionally speaks OTLP now: with photon= set, a long-lived relay child
ships incidents (from the durable spool, priority) plus per-process metrics and
lifecycle events (over a non-blocking pipe, best-effort). Supervision path still
touches no socket. Boundary wording updated with the code, not ahead of it."
```

---

## Self-review notes (checked against the spec)

- **Spec coverage:** incidents (Task 3 spool watch) ✓, lifecycle events (T2 encoder,
  T4 emit) ✓, per-process metrics (T2 encoder, T4 emit) ✓, supervisor self-metrics
  (fold into T4 `:825` as an extra `MetricSample` with `service.name=mandor`) ✓,
  priority-by-durability (T3 spool-first) ✓, non-blocking drop (T4 `EAGAIN`) ✓,
  offline default (T4 guard) ✓, raw logs cut (never emitted) ✓, traces rejected ✓.
- **Boundary discipline:** the "optionally speaks OTLP" wording lands only in Task
  4 Step 6, in the same commit as the working code — never ahead of it.
- **Order/independence:** T1 (leaf) → T2 (encoders, needs T1 types) → T3 (daemon,
  needs T2+T1) → T4 (core wiring, needs T3). Each ends green + committed.
- **Open item to confirm at T3:** spool filename monotonicity (single watermark vs
  a shipped-set). Verify in `spool.zig` before relying on lexical ordering.
```
