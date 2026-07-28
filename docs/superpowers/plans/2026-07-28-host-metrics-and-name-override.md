# Node host metrics + worker name override — implementation plan

> Design: `docs/superpowers/specs/2026-07-28-host-metrics-and-name-override-design.md`.
> Builds on shipped OTLP telemetry (frame.zig, relay.zig, telemetry.zig).
> REQUIRED: executing-plans / subagent-driven. Motto governs every task.

**Goal:** emit node-level `system.*` host metrics (the node-total baseline)
alongside the per-worker `process.*` metrics mandor already ships, so photon's
Infrastructure view populates and each process is visible against the node
total. Plus a TOML per-worker name override.

## Global constraints (every task)
- **Stability leads:** no `unreachable`, no panic on any reachable path;
  ReleaseSafe. **All arithmetic on `/proc` bytes saturates** (`+|`/`*|`) — the
  v1.0.x rule; `/proc` is untrusted input. A test isn't done until MUTATION
  proves it guards something.
- **Light:** fixed preallocated / stack buffers, ZERO steady-state allocation,
  no deps. Line-oriented `std.mem` scanning, no regex.
- **Fast:** O(input) parsers, no super-linear per-tick work.
- **Offline default preserved:** host metrics only flow when `photon=` is set,
  over the existing daemon; supervision path touches no socket.
- Build/test in WSL (`ZIG_LOCAL_CACHE_DIR=$HOME/.cache/mandor-zig`,
  `~/tools/zig-x86_64-linux-0.16.0/zig`). Commit in WSL, **no AI attribution**.
  **Subagents write code only; do NOT build/commit — the parent verifies**
  (builds are ~9 min; `zig build test` does NOT analyze daemon/main-only code —
  the EXE build does). Zig 0.16: `catch |_|` and `else |e|{_=e;}` are compile
  errors — use `catch {}`/`catch return X`/`else |_| {}`.
- Match photon-agent metric names EXACTLY (design "Contract" table) or the view
  stays empty.

## File structure
- **Create `src/hostmetrics.zig`** — node `/proc` + statfs readers producing a
  `HostSample`; keeps one prior reading for CPU/net deltas. Pure, unit-testable
  with fixture strings.
- **Modify `src/frame.zig`** — add a `host_sample` kind + `HostSample` payload +
  encode/decode.
- **Modify `src/relay.zig`** — generalize the metrics encoder to
  `buildOtlpMetrics(resource_attrs, samples)` OR add `buildOtlpHostMetrics`
  emitting the `host.name/host.id/os.type` resource + `system.*` metrics; daemon
  decodes `host_sample` and ships to `/v1/metrics`.
- **Modify `src/telemetry.zig`** — `emitHost(HostSample)`.
- **Modify `src/supervisor.zig`** — sample the host once per tick and emit.
- **Modify `src/config.zig` + `src/spawner.zig`** — parse `[worker.NAME] name`
  and apply at name resolution.
- **Modify `src/main.zig`** — `_ = @import("hostmetrics.zig");` in `test {}`.

---

### Task 1: `hostmetrics.zig` — node /proc readers

**Files:** create `src/hostmetrics.zig`; modify `src/main.zig` (test import).

**Produces:**
```zig
pub const HostSample = struct {
    // memory (bytes)
    mem_total: u64, mem_used: u64,
    // cpu
    cpu_total_delta: u64, cpu_idle_delta: u64, // caller derives utilization = 1 - idle/total
    logical_cpus: u32,
    load1_milli: u32,          // /proc/loadavg field1 * 1000 (integer, no float on wire)
    // network (cumulative monotonic bytes across non-loopback ifaces)
    net_rx: u64, net_tx: u64,
    // filesystem "/" (bytes)
    fs_total: u64, fs_used: u64,
};
pub const Sampler = struct {
    prev_cpu_total: u64 = 0, prev_cpu_idle: u64 = 0, have_prev: bool = false,
    pub fn sample(self: *Sampler) HostSample; // reads /proc + statfs; never traps
};
pub fn hostName(buf: []u8) []const u8;   // /proc/sys/kernel/hostname (trimmed)
pub fn hostId(buf: []u8) []const u8;     // /etc/machine-id | boot_id
```

- [ ] **Step 1: failing tests** — parse fixture strings (NOT live `/proc`, so
  tests are deterministic). Provide internal parse helpers that take `[]const u8`:
  `parseMeminfo`, `parseStatCpu`, `parseLoadavg`, `parseNetDev`. Tests assert:
```zig
test "parseMeminfo pulls MemTotal and MemAvailable" {
    const s = "MemTotal:       65808388 kB\nMemFree: 100 kB\nMemAvailable:   40000000 kB\n";
    const m = parseMeminfo(s);
    try testing.expectEqual(@as(u64, 65808388 * 1024), m.total);
    try testing.expectEqual(@as(u64, (65808388 - 40000000) * 1024), m.used);
}
test "parseStatCpu sums fields and extracts idle" {
    const c = parseStatCpu("cpu  100 20 30 400 50 0 0 0 0 0\ncpu0 ...\n");
    try testing.expectEqual(@as(u64, 100+20+30+400+50), c.total);
    try testing.expectEqual(@as(u64, 400+50), c.idle); // idle + iowait
}
test "parseNetDev sums non-loopback rx/tx" {
    const n = parseNetDev("Inter-|...\n face |...\n  lo: 5 0 0 0 0 0 0 0 5 0 ...\n eth0: 1000 0 0 0 0 0 0 0 2000 0 ...\n");
    try testing.expectEqual(@as(u64, 1000), n.rx); // lo excluded
    try testing.expectEqual(@as(u64, 2000), n.tx);
}
test "parseLoadavg reads the 1m field as milli" {
    try testing.expectEqual(@as(u32, 1250), parseLoadavg("1.25 0.80 0.66 1/234 5678"));
}
test "overflow-safe: a giant /proc number saturates, no trap" {
    _ = parseMeminfo("MemTotal: 99999999999999999999999 kB\n"); // must not panic
}
```

- [ ] **Step 2** run → fail. **Step 3** implement (all parsers saturating,
  `logical_cpus` = count of `cpuN` lines, statfs via `linux.statfs`). **Step 4**
  run → pass. **Step 5 mutation:** make `parseNetDev` include `lo`; the
  non-loopback test fails; restore. **Step 6 commit** (`feat: hostmetrics.zig`).

---

### Task 2: frame + OTLP host-metrics encoder

**Files:** `src/frame.zig`, `src/relay.zig`.

- Consumes `HostSample`. Produces `frame.encodeHost/decode` (new `host_sample`
  kind) and `buildOtlpHostMetrics(sample, host_name, host_id) ![]const u8`.
- OTLP shape: ONE `ResourceMetrics`, resource attrs `host.name`/`host.id`/
  `os.type="linux"`; metrics per the design Contract table (gauges for cpu
  util/count/load/mem*, filesystem*; **Sum monotonic** for `system.network.io`
  with `direction` datapoint attrs). Reuse the existing Writer / two-pass sizing
  from `buildOtlp`/`buildOtlpMetrics`; generalize the per-datapoint helper to
  accept datapoint attributes (`cpu=total`, `state=used/free`, `device`,
  `direction`, `mountpoint`).

- [ ] TDD: frame host round-trip test; `buildOtlpHostMetrics` walked with the
  in-file `Fields` reader — assert resource has `host.name`, a metric named
  `system.memory.usage` with `state=used` datapoint, and `system.network.io` is
  a Sum. Mutation: rename `system.memory.usage`→wrong; the walk test fails.
- [ ] Commit (`feat: OTLP host-metrics encoder + frame`).

---

### Task 3: wire host sampling into the tick + daemon; verify live

**Files:** `src/telemetry.zig`, `src/supervisor.zig`, `src/relay.zig` (daemon
decode), `docs/CONFIG.md`.

- `telemetry.emitHost(HostSample)` (non-blocking write, drop on EAGAIN/EPIPE).
- `supervisor.runSamplerTick`: after the per-worker loop, `hostSampler.sample()`
  + `telemetry.emitHost(...)` once per tick (guard on `telemetry.enabled()`).
- Daemon `drainPipe`: decode `host_sample` → `buildOtlpHostMetrics` → POST
  `/v1/metrics`.
- `telemetry.host = false` TOML disables host metrics (default on). Document in
  CONFIG.md.

- [ ] Verify (parent): exe build; extend `test/photon/supervised-e2e.sh` (or a
  new `host-metrics-e2e.sh`) against the local responder — assert a
  `/v1/metrics` POST carrying `system.memory.usage` / `host.name`. Then the
  **live** run against photon (192.168.103.76:10818, `PHOTON_TOKEN`) → confirm
  the host appears in the Infrastructure view / `system.*` queryable.
- [ ] Commit (`feat: ship node host metrics [size]`).

---

### Task 4: worker name override (TOML)

**Files:** `src/config.zig`, `src/spawner.zig` (+ tests).

- Parse optional `name` in `[worker.NAME]` sections; validate (non-empty,
  length-capped, neutralized like a derived name); unknown/invalid → hard error.
- Apply at name resolution so it flows to log prefix, report, Prometheus label,
  incident `service.name`, lifecycle events, per-worker metrics — one assignment,
  no call-site changes. If two workers resolve to the same overridden name, dedup
  like basenames (`-2`).

- [ ] TDD: config parse test (`[worker."start.sh"] name="api"` → worker name
  "api"); a neutralization test (bad bytes scrubbed); a dedup test. Mutation:
  skip applying the override; the parse test fails. Commit (`feat: TOML worker
  name override`).

## Self-review
- Contract names matched exactly (design table) — Task 2/3.
- `/proc` arithmetic saturates everywhere — Task 1.
- Offline default intact; host metrics gated on `photon=` — Task 3.
- Order: T1 (leaf) → T2 (encoder) → T3 (wire+verify) → T4 (independent, any time).
