//! Core-side telemetry emit path. Owns the write end of the pipe to the
//! long-lived `mandor relay --daemon` child (spawned only when `photon=` is
//! set) and the daemon's pid.
//!
//! THE MOTTO GOVERNS THIS FILE. "push the stability to the sky, light like a
//! feather, fast like the flash":
//!   - STABILITY: every emit is a single NON-BLOCKING write into a fixed stack
//!     buffer; on EAGAIN (pipe full) / EPIPE (daemon gone) / any error it drops
//!     the record and returns. The supervision loop never blocks, allocates, or
//!     dies because of telemetry. No `unreachable`, no panic. If the daemon
//!     spawn fails, telemetry stays disabled and supervision is unaffected.
//!   - LIGHT: zero heap allocation; each frame is built in a stack buffer and
//!     written in one syscall. No steady-state allocation.
//!   - FAST: the emit helper is O(frame size) — no scan, sort, or search.
//!
//! Frames are `frame.zig`'s compact wire format; the daemon re-encodes them as
//! OTLP. If no daemon (photon unset), `emitMetric`/`emitLifecycle` are no-ops.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const frame = @import("frame.zig");
const spawner = @import("spawner.zig");

/// Write end of the pipe to the daemon; -1 = telemetry disabled (no daemon).
var write_fd: i32 = -1;
/// The relay daemon's pid; 0 = none spawned.
var daemon_pid: i32 = 0;

/// True once a daemon is running and the pipe is live. Lets the sampler skip
/// the supervisor self-sample when telemetry is off.
pub fn enabled() bool {
    return write_fd >= 0;
}

/// Wall-clock nanoseconds for a telemetry timestamp (vDSO — cheap). Saturating
/// arithmetic so a bad clock can never trap on the emit path.
pub fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @as(u64, @intCast(ts.sec)) *| 1_000_000_000 +| @as(u64, @intCast(ts.nsec));
}

/// Spawn the long-lived relay daemon and keep the pipe write end. Best-effort:
/// on ANY failure telemetry stays disabled and supervision continues untouched.
///
/// The read end must survive the daemon's fork+exec while neither end leaks
/// into the workers we fork later. Both ends are created O_CLOEXEC; the daemon
/// child clears CLOEXEC on the read end itself (spawnDetached's `keep_fd`) just
/// before its execve, so only that one process inherits it. The core keeps the
/// write end CLOEXEC, so later worker execs never see it.
pub fn spawnDaemon(
    endpoint: []const u8,
    state_dir: []const u8,
    gpu_enabled: bool,
    gpu_interval_ms: u64,
    service_prefix: []const u8,
    envp: [*:null]const ?[*:0]const u8,
    path_env: []const u8,
) void {
    var fds: [2]i32 = undefined;
    // O_NONBLOCK: the core write never blocks (a full pipe → EAGAIN → drop).
    // O_CLOEXEC: neither end leaks across an exec by default.
    if (posix.errno(linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true })) != .SUCCESS) return;
    const read_fd = fds[0];
    const write_end = fds[1];

    var fd_buf: [16]u8 = undefined;
    var ep_buf: [96]u8 = undefined;
    var sd_buf: [512]u8 = undefined;
    var gpu_buf: [2]u8 = undefined;
    var gi_buf: [24]u8 = undefined;
    var sp_buf: [96]u8 = undefined;
    const fd_str = std.fmt.bufPrintZ(&fd_buf, "{d}", .{read_fd}) catch {
        _ = linux.close(read_fd);
        _ = linux.close(write_end);
        return;
    };
    const ep_str = std.fmt.bufPrintZ(&ep_buf, "{s}", .{endpoint}) catch {
        _ = linux.close(read_fd);
        _ = linux.close(write_end);
        return;
    };
    const sd_str = std.fmt.bufPrintZ(&sd_buf, "{s}", .{state_dir}) catch {
        _ = linux.close(read_fd);
        _ = linux.close(write_end);
        return;
    };
    // GPU config as two trailing argv strings ("0"|"1" + interval ms).
    const gpu_str = std.fmt.bufPrintZ(&gpu_buf, "{d}", .{@intFromBool(gpu_enabled)}) catch {
        _ = linux.close(read_fd);
        _ = linux.close(write_end);
        return;
    };
    const gi_str = std.fmt.bufPrintZ(&gi_buf, "{d}", .{gpu_interval_ms}) catch {
        _ = linux.close(read_fd);
        _ = linux.close(write_end);
        return;
    };
    // Service prefix as one trailing argv string (the origin tag, "" = none).
    // Capped upstream (cli.max_service_prefix) so it always fits sp_buf.
    const sp_str = std.fmt.bufPrintZ(&sp_buf, "{s}", .{service_prefix}) catch {
        _ = linux.close(read_fd);
        _ = linux.close(write_end);
        return;
    };

    // `mandor relay --daemon <endpoint> <state_dir> <read_fd> <gpu> <interval> <service_prefix>` —
    // main.zig routes it. Log streaming is decided supervisor-side per worker,
    // so no streaming toggle is passed. The string buffers live on this stack
    // frame; spawnDetached forks and the child execs from its copy before this
    // function returns, so they are valid for the exec.
    const argv = [_:null]?[*:0]const u8{
        "/proc/self/exe",
        "relay",
        "--daemon",
        @ptrCast(ep_str.ptr),
        @ptrCast(sd_str.ptr),
        @ptrCast(fd_str.ptr),
        @ptrCast(gpu_str.ptr),
        @ptrCast(gi_str.ptr),
        @ptrCast(sp_str.ptr),
    };
    const pid = spawner.spawnDetached(&argv, envp, path_env, read_fd);
    // The read end belongs to the daemon now; the core keeps only the write end.
    _ = linux.close(read_fd);
    if (pid <= 0) {
        _ = linux.close(write_end);
        return; // fork failed → telemetry disabled, supervision unaffected
    }

    // A telemetry write races the daemon's lifetime: if the daemon has exited,
    // the pipe has no reader and write() would raise SIGPIPE, whose default
    // action would kill PID 1 and take the container with it. Block it (only
    // now that telemetry is actually enabled) so the write returns EPIPE, which
    // writeFrame handles. Blocking (not SIG_IGN) is deliberate: a blocked mask
    // is reset to empty in every child before exec, so workers keep the default
    // disposition — an ignored disposition would instead be inherited by them.
    var pipe_set = posix.sigemptyset();
    posix.sigaddset(&pipe_set, .PIPE);
    posix.sigprocmask(posix.SIG.BLOCK, &pipe_set, null);

    daemon_pid = pid;
    write_fd = write_end;
}

/// Emit one metric sample (drops silently if no daemon or the pipe is full).
pub fn emitMetric(s: frame.MetricSample) void {
    if (write_fd < 0) return;
    var buf: [128]u8 = undefined;
    const bytes = frame.encodeMetric(&buf, s) catch return; // name too long → drop
    _ = writeFrame(bytes);
}

/// Emit one lifecycle event (drops silently if no daemon or the pipe is full).
pub fn emitLifecycle(e: frame.Lifecycle) void {
    if (write_fd < 0) return;
    var buf: [128]u8 = undefined;
    const bytes = frame.encodeLifecycle(&buf, e) catch return;
    _ = writeFrame(bytes);
}

/// Largest streamed-log frame we build. Held at PIPE_BUF (4096) so a single
/// non-blocking pipe write is atomic (all-or-nothing): the write either lands
/// the whole frame or writes nothing (EAGAIN), so a partial write can never
/// desync the daemon's length-prefixed stream. A line whose frame would exceed
/// this is refused by encodeLog and dropped (counted); near-max lines are rare
/// and the stream tier is lossy. This is a fixed per-line LENGTH bound; the
/// `[logs] max_rate` cap (lines/sec, enforced supervisor-side before a frame is
/// built) is the separate volume knob.
const max_log_frame = 4096;

/// emitLog's frame-encode scratch. Module-level (not a stack local) on purpose:
/// emitLog is called from the per-line capture hot path and gets INLINED into
/// `echoLine`, so a 4 KB stack local would inflate echoLine's frame past Zig's
/// stack-probe threshold and cost a `__zig_probe_stack` on EVERY captured line —
/// even when streaming is off. As BSS it lives outside any frame; single-
/// threaded, and fully consumed within emitLog before the next call, so sharing
/// is safe (same rationale as the supervisor's echo_scratch/merged_env statics).
var emit_log_buf: [max_log_frame]u8 = undefined;

/// Streamed log lines dropped: pipe full, daemon gone, or a frame too large for
/// one atomic pipe write. Streamed logs are the lossy tier — a drop here never
/// touches supervision or the durable incident spool. Saturating so it cannot
/// wrap-trap under a sustained log storm.
var log_drops: u64 = 0;

/// Number of streamed log lines dropped so far (for tests / diagnostics).
pub fn logDrops() u64 {
    return log_drops;
}

/// Backpressure shed state (Tier 3 flood defense). When a streamed-log write
/// hits EAGAIN (pipe full ⇒ the daemon is behind) emitLog opens a short shed
/// window ending at this timestamp. While `t_ns < shed_until_ns` a line is
/// dropped BEFORE the encode — an O(1) timestamp compare + counter bump instead
/// of encode + write — so a flood into a backed-up daemon costs ~O(1)/line, not
/// encode+write per line. Once the window elapses a single line is attempted
/// again (a probe): if the pipe is still full a fresh window opens; if the write
/// succeeds no new window is set, so shedding ends naturally when the daemon
/// catches up. The clock is the per-line `t_ns` the caller already computed — no
/// extra syscall. 0 = not shedding.
var shed_until_ns: u64 = 0;

/// One shed window's length before the next probe. Short (100 ms) so recovery is
/// prompt once the daemon drains, yet long enough that a sustained flood pays the
/// encode+write only ~once per window.
const shed_cooldown_ns: u64 = 100 * 1000 * 1000; // 100ms

/// Streamed log lines dropped by backpressure shedding (pre-encode, inside a
/// shed window). A SIBLING of `log_drops` so the cheap shed drops stay
/// distinguishable from encode-too-large / write-failure drops. Saturating so a
/// sustained flood cannot wrap-trap.
var shed_drops: u64 = 0;

/// Number of streamed log lines shed under backpressure (for tests / diagnostics).
pub fn shedDrops() u64 {
    return shed_drops;
}

/// Streamed log lines dropped by the `[logs] max_rate` cap: the operator asked
/// mandor to shed load past N lines/sec, so these drops are deliberate, not
/// backpressure. Kept a SIBLING of `log_drops` so the two causes stay
/// distinguishable. Counted on the supervisor side (the frame is never built),
/// never spooled. Saturating so a sustained storm cannot wrap-trap.
var rate_drops: u64 = 0;

/// Record one line dropped by the rate cap. Called from the supervisor's O(1)
/// window limiter, which decides the drop before any frame is built.
pub fn noteRateDrop() void {
    rate_drops +|= 1;
}

/// Number of streamed log lines dropped by the rate cap (for tests / diagnostics).
pub fn rateDrops() u64 {
    return rate_drops;
}

/// Emit one streamed worker-log line (opt-in `[worker.NAME] stream`). No-op if no
/// daemon; drops (and counts) if the pipe is full, the daemon is gone, or the
/// frame will not fit one atomic write. Same non-blocking / zero-alloc / never-
/// trap contract as emitMetric/emitLifecycle — the supervision loop outranks
/// telemetry. `iostream`: 0 stdout / 1 stderr. `severity`: 0 info / 1 warn / 2
/// error (see capture.severityFromFlags).
pub fn emitLog(name: []const u8, iostream: u8, severity: u8, t_ns: u64, line: []const u8) void {
    if (write_fd < 0) return;
    // Backpressure shedding: inside a shed window (the daemon fell behind) a line
    // costs only this compare + a counter bump — NOT the encode below. This is
    // the O(1)/line self-cap under a sustained flood into a backed-up daemon.
    if (t_ns < shed_until_ns) {
        shed_drops +|= 1;
        return;
    }
    const bytes = frame.encodeLog(&emit_log_buf, .{
        .name = name,
        .iostream = iostream,
        .severity = severity,
        .t_unix_ns = t_ns,
        .line = line,
    }) catch {
        log_drops +|= 1; // name/line too large for one atomic pipe write → drop
        return;
    };
    if (!writeFrame(bytes)) {
        log_drops +|= 1; // pipe full / daemon gone → drop
        // Distinguish "pipe full but still connected" (EAGAIN — daemon behind)
        // from "daemon gone": writeFrame closes write_fd (sets -1) on EPIPE, so
        // write_fd >= 0 here means the write was EAGAIN. Only that is
        // backpressure — open a shed window so subsequent lines drop pre-encode
        // until the daemon catches up. Saturating so a late clock can't trap.
        if (write_fd >= 0) shed_until_ns = t_ns +| shed_cooldown_ns;
    }
}

/// One non-blocking write; drop on anything but a full success. Never blocks,
/// never retries — the supervision loop outranks telemetry. Frames are far
/// below PIPE_BUF (4096), so a pipe write is atomic: it either writes the whole
/// frame or, with O_NONBLOCK on a full pipe, writes nothing and returns EAGAIN.
/// No partial frame can therefore desync the daemon's stream. Returns true iff
/// the whole frame was written; false on any drop (pipe full, daemon gone,
/// error) so a caller can count the drop.
fn writeFrame(bytes: []const u8) bool {
    const rc = linux.write(write_fd, bytes.ptr, bytes.len);
    switch (posix.errno(rc)) {
        .SUCCESS => return true, // whole frame written (atomic at/below PIPE_BUF)
        .PIPE => {
            // Daemon gone: stop trying so we neither spin nor keep tripping the
            // (blocked) SIGPIPE. Incidents still reach the spool regardless.
            _ = linux.close(write_fd);
            write_fd = -1;
            return false;
        },
        else => return false, // EAGAIN (pipe full) / EINTR / other → drop this record
    }
}

/// Flush-and-exit the daemon at shutdown, bounded by `budget_ms`.
///
/// Closing the write end makes the daemon see EOF and do a final spool+pipe
/// flush; the SIGTERM is a belt-and-suspenders wake in case it is mid-sleep.
/// Then wait (bounded) for it to exit and reap it — mandor is PID 1, so a
/// daemon still shipping the incident that explains this crash must get its
/// moment. Best-effort: supervision outranks bookkeeping, so a wedged daemon
/// costs the budget and no more (the kernel reaps it when PID 1 exits).
pub fn shutdown(budget_ms: u64) void {
    if (daemon_pid <= 0) return;
    if (write_fd >= 0) {
        _ = linux.close(write_fd); // EOF → daemon final-flushes and exits
        write_fd = -1;
    }
    posix.kill(daemon_pid, .TERM) catch {};
    var waited: u64 = 0;
    while (waited < budget_ms) {
        var st: u32 = undefined;
        const rc = linux.waitpid(daemon_pid, &st, linux.W.NOHANG);
        if (posix.errno(rc) == .SUCCESS and rc != 0) {
            daemon_pid = 0;
            return;
        }
        const step: u64 = 20;
        var ts = linux.timespec{ .sec = 0, .nsec = @intCast(step * 1_000_000) };
        _ = linux.nanosleep(&ts, &ts);
        waited += step;
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "emitLog drops and counts an over-large line, ships a normal one" {
    // emitLog does a real pipe write, so this is Linux-only.
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    var fds: [2]i32 = undefined;
    if (posix.errno(linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true })) != .SUCCESS)
        return error.SkipZigTest;
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);

    const saved_fd = write_fd;
    const saved_drops = log_drops;
    defer write_fd = saved_fd; // LIFO: restore before the fds close
    write_fd = fds[1];

    // A line past the frame's line cap cannot be encoded → dropped + counted.
    var big: [5000]u8 = undefined;
    @memset(&big, 'x');
    emitLog("api", 0, 0, 1, &big);
    try testing.expectEqual(saved_drops + 1, log_drops);

    // A normal line fits and the (empty) pipe has room → written, no new drop.
    emitLog("api", 1, 2, 1, "boom");
    try testing.expectEqual(saved_drops + 1, log_drops);
}

/// Fill a non-blocking pipe's write end until a raw write would block (EAGAIN),
/// so the next emitLog write hits backpressure just like a daemon that fell
/// behind. Bounded by pipe capacity, so the loop terminates.
fn fillPipe(fd: i32) void {
    var filler: [4096]u8 = undefined;
    @memset(&filler, 'z');
    while (true) {
        const rc = linux.write(fd, &filler, filler.len);
        if (posix.errno(rc) != .SUCCESS) break; // EAGAIN: pipe full
    }
}

test "emitLog enters shed on a full pipe and cheap-drops within the window" {
    // MUTATION TARGET: remove the pre-encode `if (t_ns < shed_until_ns)` gate,
    // or never set `shed_until_ns` on EAGAIN, and this test fails.
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    var fds: [2]i32 = undefined;
    if (posix.errno(linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true })) != .SUCCESS)
        return error.SkipZigTest;
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);

    const saved_fd = write_fd;
    const saved_log = log_drops;
    const saved_shed = shed_drops;
    const saved_until = shed_until_ns;
    defer {
        write_fd = saved_fd; // LIFO: restore before the fds close
        shed_until_ns = saved_until;
    }
    write_fd = fds[1];
    shed_until_ns = 0;

    fillPipe(write_fd); // no reader ⇒ the pipe is now full

    // This line's write hits EAGAIN with write_fd still connected ⇒ enter shed.
    const t0: u64 = 1_000_000_000;
    emitLog("api", 0, 2, t0, "boom");
    try testing.expectEqual(saved_log + 1, log_drops); // the write-failure drop
    try testing.expectEqual(t0 +| shed_cooldown_ns, shed_until_ns); // window opened
    try testing.expectEqual(saved_shed, shed_drops); // it was attempted, not shed

    // A line INSIDE the window drops pre-encode: shed_drops rises and log_drops
    // does NOT (no encode, no write attempted).
    const log_before = log_drops;
    emitLog("api", 0, 2, t0 + 1, "boom");
    try testing.expectEqual(saved_shed + 1, shed_drops);
    try testing.expectEqual(log_before, log_drops);
}

test "emitLog probes past the shed window and re-arms if still full" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    var fds: [2]i32 = undefined;
    if (posix.errno(linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true })) != .SUCCESS)
        return error.SkipZigTest;
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);

    const saved_fd = write_fd;
    const saved_log = log_drops;
    const saved_until = shed_until_ns;
    defer {
        write_fd = saved_fd;
        shed_until_ns = saved_until;
    }
    write_fd = fds[1];
    // Pretend a prior shed window ends at t=500; the pipe is still full.
    shed_until_ns = 500;
    fillPipe(write_fd);

    // t_ns past the window ⇒ a line is PROBED (encode + write attempt). The pipe
    // is full, so the write fails (log_drops++) and a fresh window opens.
    const t: u64 = 1000;
    emitLog("api", 0, 2, t, "boom");
    try testing.expectEqual(saved_log + 1, log_drops); // a write was attempted
    try testing.expectEqual(t +| shed_cooldown_ns, shed_until_ns); // re-armed
}

test "emitLog with a draining reader never enters shed" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;

    var fds: [2]i32 = undefined;
    if (posix.errno(linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true })) != .SUCCESS)
        return error.SkipZigTest;
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);

    const saved_fd = write_fd;
    const saved_shed = shed_drops;
    const saved_until = shed_until_ns;
    defer {
        write_fd = saved_fd;
        shed_until_ns = saved_until;
    }
    write_fd = fds[1];
    shed_until_ns = 0;

    // The reader keeps draining, so every write succeeds and no window opens.
    var t: u64 = 1;
    while (t <= 5) : (t += 1) {
        emitLog("api", 0, 0, t, "hi");
        var sink: [512]u8 = undefined;
        _ = linux.read(fds[0], &sink, sink.len);
    }
    try testing.expectEqual(saved_shed, shed_drops); // no shed drops
    try testing.expectEqual(@as(u64, 0), shed_until_ns); // window never opened
}
