# mandor absorbs photon-agent — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: subagent-driven-development. Steps
> use checkbox (`- [ ]`) syntax. Design:
> `docs/superpowers/specs/2026-08-05-mandor-absorbs-photon-agent-design.md`.
> Branch: `feat/absorb-photon-agent`.

**Goal:** a single static mandor binary supersedes photon-agent — node `system.*`
host metrics (per-core CPU, per-mount FS, per-interface net, mem-free) + NVIDIA
`system.gpu.*` via `nvidia-smi` (P1), then AMD/Intel GPU + disk.io/swap/temp/
uptime/load extras (P2), then opt-in full log streaming to OTLP `/v1/logs` (P3) —
all coherent with mandor's existing per-worker `process.*` metrics under one host.

**Architecture:** node + GPU telemetry lives in the long-lived `relay --daemon`
child (owns socket/spool/pipe), off PID-1's supervision path. The daemon samples
`/proc`+`statfs` itself on a node timer (no more `frame.Host` over the pipe) and
`nvidia-smi`/sysfs on a GPU timer. `host.name`/`host.id` are resolved once in the
daemon and applied identically to the process, host, and GPU encoders.

## Global constraints (every task — the motto governs)

- **Stability leads.** No `unreachable`, no panic on any reachable path;
  ReleaseSafe ships. Every byte parsed from `/proc`/`sysfs`/`nvidia-smi` is
  UNTRUSTED → **saturating** arithmetic, `parseInt … catch 0`. A subprocess or
  file failure logs once and yields zero points — never aborts the daemon, never
  touches supervision. A test isn't done until a MUTATION makes a named test fail.
- **Light.** Fixed/preallocated buffers, zero steady-state allocation, no deps.
  `nvidia-smi` is the only subprocess (GPU); everything else is raw syscalls.
  Watch the `< 500 KB` size gate and the config-surface gate every phase.
- **Fast.** Parsers O(n); node sampling and GPU sampling on their own timers in
  the daemon, never on the poll/supervision hot path.
- **DRY / SOLID / YAGNI.** Reuse the existing OTLP encoders in `relay.zig` (bundle
  logs, number datapoints) and `hostmetrics.zig` parsers; each new file has one
  clear responsibility (`gpu.zig` = GPU sampling only). No feature not in the spec.
- **Simplicity.** New settings are TOML-only (`[gpu]`, `[logs]`); the 4-flag CLI
  is untouched. Each phase that adds config keys bumps the surface budget with a
  CHANGELOG line.
- Zig 0.16: `catch |_|` / `else |e| { _ = e; }` are compile errors — use
  `catch {}` / `catch return X` / `else |_| {}`. Verify std signatures against the
  LOCAL std (esp. any new syscall). `zig build test` does NOT analyze daemon/main-
  only code — the **exe build** does; run both.
- Build/test in WSL (`ZIG_LOCAL_CACHE_DIR=$HOME/.cache/mandor-zig`,
  `~/tools/zig-x86_64-linux-0.16.0/zig`). `zig fmt --check src build.zig` before
  each commit. **Commit in WSL** (no AI attribution), **push in PowerShell** (SSH
  key is Windows-side). Subagents write; the parent builds/verifies.

## File structure

- **`src/hostmetrics.zig`** (extend) — pure `/proc`+`statfs` parsers gain per-core
  CPU, per-mount FS (mountinfo+statfs), per-interface net, mem-free; P2 adds
  diskstats, swap, hwmon temp, uptime, 5m/15m load. Stays pure + unit-testable.
- **`src/gpu.zig`** (new) — GPU sampling: `nvidia-smi` CSV parser (pure) + the
  daemon-side fork/exec + (P2) DRM sysfs reader. One responsibility.
- **`src/relay.zig`** (extend) — daemon node timer + GPU timer; extend
  `buildOtlpHostMetrics`; new `buildOtlpGpuMetrics`; (P3) log-record batching to
  `/v1/logs`. Remove the `frame.Host` receive path.
- **`src/frame.zig`** (edit) — drop `Host` (node metrics now daemon-sampled); (P3)
  add a log-line frame type (worker idx, stream, severity, ts, bytes).
- **`src/telemetry.zig`** (edit) — drop `emitHost`; (P3) add `emitLog`.
- **`src/supervisor.zig` / `src/capture.zig`** (edit, P3 only) — enqueue completed
  captured lines to the daemon when streaming is on.
- **`src/config.zig` / `src/cli.zig`** (extend) — `[gpu]` (P1), `[logs]` (P3).
- **`src/main.zig`** (edit) — add `gpu.zig` to the test block.
- **`docs/CONFIG.md`** (extend) — `[gpu]`/`[logs]` keys + node-monitor deployment.
- **`test/harness/run_tests.sh`** (extend) — P3 streaming on/off + backpressure.

---

# Phase 1 — parity + NVIDIA GPU (replaces photon-agent)

### Task 1: move node host-metric sampling into the relay daemon

**Files:** `src/relay.zig`, `src/telemetry.zig`, `src/frame.zig`, `src/supervisor.zig`.

**Why first:** isolates the location change from the new metrics. Per-mount/per-
interface need mount/interface NAME strings — packing those over the pipe frame is
awkward; sampling in the daemon (which reads the same host `/proc`) avoids it and
keeps PID-1 leaner. Output must be byte-identical to today.

- Consumes: `hostmetrics.Sampler` (already exists), `buildOtlpHostMetrics`.
- Produces: the daemon owns a `hostmetrics.Sampler` and, on a node timer
  (`sampler.interval_ms` = 5s), samples + encodes + ships. `frame.Host`,
  `telemetry.emitHost`, and the supervisor's host-sample send are removed.

- [ ] Add a node-sample timer to the daemon poll loop (it already polls the pipe +
  watches the spool with timeouts — add a "next node sample at" deadline).
- [ ] Daemon calls `host_sampler.sample()` → `buildOtlpHostMetrics(sample,
  daemon_host_name, daemon_host_id)` → ship to `/v1/metrics` (same path metrics
  already take). First tick primes CPU deltas (no emit), matching current behavior.
- [ ] Remove `frame.Host`, `telemetry.emitHost`, and the supervisor call site.
- [ ] **Verify (parent):** fmt; `zig build test`; **exe build**; then a LIVE check
  against photon (as in the v1.5.0 verification) — `/api/infra/hosts` still shows
  the node with cpu/mem/disk/net/load, unchanged. Commit
  (`refactor: sample node host metrics in the relay daemon, not over the pipe`).

### Task 2: per-core CPU utilization

**Files:** `src/hostmetrics.zig`, `src/relay.zig`.

- Produces: `HostSample` carries per-core total/idle deltas (bounded
  `max_cores`, e.g. 256); `buildOtlpHostMetrics` emits `system.cpu.utilization`
  with `cpu="total"` (existing) AND one point per core `cpu=<n>`.
- The `Sampler` keeps prior per-core readings (fixed array) for deltas, like the
  aggregate. `parseStatCpu` already sees `cpuN` lines — extend it to fill a
  per-core array (index from the `cpuN` suffix), saturating, bounded.

- [ ] Unit tests (fixture `/proc/stat` with `cpu` + `cpu0..cpu3`): per-core util
  computed from deltas; core count correct; a >max_cores input truncates (no
  overrun); garbage core line → 0, no trap.
- [ ] Mutation: drop the per-core bound check (or the index clamp) → confirm the
  truncation test fails. Commit (`feat: per-core system.cpu.utilization`).

### Task 3: per-mount filesystem

**Files:** `src/hostmetrics.zig`, `src/relay.zig`.

- Produces: parse `/proc/self/mountinfo` for mount points (dedup real
  filesystems; skip pseudo-fs like proc/sys/cgroup/tmpfs-overlay per a small
  allowlist/denylist by fs type in mountinfo), `statfs` each, fill a bounded
  `max_mounts` (e.g. 32) array of `{mountpoint, total, used}`;
  `buildOtlpHostMetrics` emits `system.filesystem.{usage,utilization}` per mount
  with `mountpoint=<mp>` (+ `state="used"` on usage). Replaces the `/`-only path.
- Mount point strings live in fixed buffers (bounded length); zero heap.

- [ ] Unit tests (fixture mountinfo string): correct mountpoints extracted;
  pseudo-filesystems skipped; >max_mounts truncates; a malformed line → skipped,
  no trap. `statfs` per mount is exercised by the existing live `sample` test.
- [ ] Mutation: break the pseudo-fs skip (include everything) OR the mount cap →
  confirm the named test fails. Commit (`feat: per-mount system.filesystem.*`).

### Task 4: per-interface network + memory free

**Files:** `src/hostmetrics.zig`, `src/relay.zig`.

- Produces: `parseNetDev` fills a bounded `max_ifaces` (e.g. 16) array of
  `{name, rx, tx}` (still skipping `lo`) instead of summing; `buildOtlpHostMetrics`
  emits `system.network.io` (Sum, cumulative) per `device=<if>` × `direction`.
  Plus a `system.memory.usage` `state="free"` gauge (`total - used`, saturating).

- [ ] Unit tests: two interfaces yield two rx/tx pairs, `lo` excluded; >max_ifaces
  truncates; free = total-used and saturates when used>total.
- [ ] Mutation: drop the `lo` skip → confirm the "lo excluded" test fails. Commit
  (`feat: per-interface system.network.io + memory free`).

### Task 5: NVIDIA GPU via nvidia-smi

**Files:** create `src/gpu.zig`; `src/relay.zig`; `src/config.zig`; `src/cli.zig`;
`src/main.zig` (test import).

- Produces:
  - `gpu.parseNvidiaSmi(csv: []const u8, out: []GpuSample) []const GpuSample` —
    pure parser of `--format=csv,noheader,nounits` rows: `index,name,
    utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw`. Fields
    saturating; a short/garbage row is skipped; bounded `max_gpus` (e.g. 16). MiB
    → bytes for memory; util `/100`.
  - daemon-side sampling: on a GPU timer (`[gpu] interval`, default 15s), fork/exec
    `nvidia-smi` with the query args, bounded stdout read, short timeout; parse;
    `buildOtlpGpuMetrics(samples, host_name, host_id)` → `/v1/metrics`. Absent
    binary / non-zero exit / timeout → no points, log once (fail-closed).
  - `buildOtlpGpuMetrics` → `system.gpu.{utilization,memory.usage,
    memory.utilization,temperature,power}` per GPU, attrs `gpu=<i>`,`gpu.name=<n>`.
  - config `[gpu] enabled=false, interval="15s"` in `cli.Config` (SOLID: a tiny
    GpuConfig struct).
- **Static-musl:** subprocess only — NO dlopen/NVML. Reuse the existing fork/exec
  idiom (raw `std.os.linux`), not libc.

- [ ] Unit tests (fixture CSV, no `nvidia-smi` invoked): a 2-GPU CSV → 2
  GpuSamples with correct util/mem/temp/power/name; a short row skipped; nounits
  garbage → saturates/skips, no trap; >max_gpus truncates.
- [ ] Extend fuzz `relayTarget`/`protoWalk` so `buildOtlpGpuMetrics` output stays
  a decodable protobuf.
- [ ] Mutation: swap two CSV field indices (e.g. temp/power) → confirm a value
  test fails. Commit (`feat: NVIDIA GPU metrics via nvidia-smi (daemon, opt-in)`).

### Task 6: P1 wiring, docs, config gate, live verification

**Files:** `src/config.zig`, `docs/CONFIG.md`, `.github/workflows/ci.yml`,
`CHANGELOG.md`.

- [ ] `docs/CONFIG.md`: document `[gpu]` keys and the **node-monitor deployment**
  (host `/proc`,`/sys`,`/etc/machine-id`,`/dev/nvidia*` mounts; needs `nvidia-smi`
  in the image for GPU). Keep the 4-flag CLI rule.
- [ ] Bump the config-surface budget for the `[gpu]` keys (CHANGELOG justified).
- [ ] **Verify (parent):** fmt; `zig build test`; exe build; size gate; then the
  LIVE gate — one mandor run against photon v1.5.0 asserting, under ONE host:
  per-core `cpu` series, per-mount `diskUtil`, per-interface `network`, GPU panels
  (on a GPU box; else `hasGpu=false` and no error), AND
  `/api/infra/hosts/:host/processes` populated with the workers — proving the
  per-process + node views are coherent. Commit + this is the point photon-agent
  is fully replaceable.

---

# Phase 2 — extras (superset of photon-agent)

### Task 7: AMD/Intel GPU via DRM sysfs

**Files:** `src/gpu.zig`, `src/relay.zig`.

- Produces: read `/sys/class/drm/card*/device/{gpu_busy_percent,mem_info_vram_*}`
  + `hwmon/*/temp1_input,power1_average`; emit the SAME `system.gpu.*` names
  (reuses photon's GPU panels, no photon change). Merge with NVIDIA results
  (distinct `gpu.name`). Pure file reads (mandor style), no subprocess.
- [ ] Unit tests with fixture sysfs contents (via a path-injectable reader).
  Mutation on a parse guard. Commit (`feat: AMD/Intel GPU metrics via DRM sysfs`).

### Task 8: system.disk.io per device

**Files:** `src/hostmetrics.zig`, `src/relay.zig`.

- Produces: parse `/proc/diskstats` (sectors read/written × 512), bounded
  `max_disks`, skip partitions/loop/ram; emit `system.disk.io` (Sum, cumulative)
  `device`,`direction=read|write`.
- [ ] Unit tests (fixture diskstats); mutation on the device filter. Commit
  (`feat: system.disk.io per device`).

### Task 9: swap + CPU temp + uptime + 5m/15m load

**Files:** `src/hostmetrics.zig`, `src/relay.zig`.

- Produces: `system.paging.usage` (state used/free from `/proc/meminfo`
  SwapTotal/Free); CPU temperature from `hwmon` (mandor-extension metric name —
  finalize in this task); host uptime (`/proc/uptime`); `system.cpu.load_average.
  5m`/`.15m` (fields 2,3 of `/proc/loadavg`). All pure parsers, saturating.
- [ ] Unit tests per source; mutation on one. Note in CHANGELOG which of these
  have no photon panel yet (data lands, UI is upstream's call). Commit
  (`feat: swap, cpu temp, uptime, 5m/15m load`).

---

# Phase 3 — optional full log streaming (opt-in)

### Task 10: log-line frame + capture enqueue (off by default)

**Files:** `src/frame.zig`, `src/telemetry.zig`, `src/capture.zig`,
`src/supervisor.zig`, `src/config.zig`, `src/cli.zig`.

- Produces: a `frame.LogLine` pipe message (worker index, iostream stdout/stderr,
  severity flag, `t_unix_ns`, line bytes ≤ `capture.max_line`); `telemetry.emitLog`
  (non-blocking pipe write, drop-on-full with a counter). When `[logs] stream` is
  on, `capture`/supervisor calls `emitLog` for each COMPLETED line (it already
  flags error/warn lines — reuse that for severity). Default off ⇒ zero calls,
  behavior unchanged.
- `[logs] stream=false` (+ optional `max_rate`) in `cli.Config`.
- [ ] Unit-test the pure pieces (frame encode/decode; severity mapping;
  drop-counter on a full ring). Commit (`feat: log-line frame + opt-in capture
  enqueue (default off)`).

### Task 11: daemon batches log records → OTLP /v1/logs

**Files:** `src/relay.zig`.

- Produces: the daemon drains `LogLine` frames into a bounded batch buffer, flushes
  every N records or T ms as one OTLP `/v1/logs` POST via a `buildOtlpLogs`
  encoder — resource `service.name=<worker>` + `host.name`/`host.id` (SAME identity
  as `process.*`), record `time/body/severity` + `log.iostream`. Reuses the
  bundle OTLP-logs encoder. **Ephemeral tier:** bounded buffer, drop-oldest with a
  counter under backpressure; NEVER spooled; never blocks the pipe drain.
- [ ] Unit-test `buildOtlpLogs` shape (protoWalk) + batch flush/drop logic.
  Mutation on the batch-cap. Commit (`feat: stream worker logs to photon /v1/logs
  (daemon, ephemeral)`).

### Task 12: P3 config, caps, docs, live + soak

**Files:** `src/relay.zig`, `docs/CONFIG.md`, `.github/workflows/ci.yml`,
`test/harness/run_tests.sh`, `CHANGELOG.md`.

- [ ] Optional `max_rate` line/sec cap + line-length cap (drop over-cap with the
  counter). `docs/CONFIG.md` `[logs]` + a PII/volume caveat. Config-surface bump.
- [ ] Harness: `[logs] stream=true` → a worker's lines appear in photon
  `/api/search` under its `service.name`; default (off) → only incident-bundle
  logs (no firehose). Backpressure: a log storm at a dead endpoint drops (counter
  up) without stalling capture or growing mandor RSS (soak-style).
- [ ] **Verify (parent):** fmt; test; exe; size; live. Commit (`feat: opt-in full
  log streaming — config, caps, docs, e2e`).

## Self-review

- P1 metrics ALL map to existing photon panels ⇒ photon-agent replaceable after
  P1, zero photon changes ✓
- `host.name`/`host.id` resolved once (daemon), applied to process + host + GPU +
  logs ⇒ coherent single-host view ✓ (the user's core requirement)
- Static-musl respected: GPU = subprocess, never dlopen ✓
- Curate-by-default preserved: logs stream only with `photon=` AND `[logs] stream`
  ✓; offline-by-default (no `photon=` ⇒ no network) intact ✓
- Every `/proc`/CSV/sysfs parser saturating + fixture-tested + mutation ✓
- Order: T1 (relocate) → T2–T4 (host granularity) → T5–T6 (GPU + P1 gate) →
  T7–T9 (P2) → T10–T12 (P3).
