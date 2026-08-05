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

    // `mandor relay --daemon <endpoint> <state_dir> <read_fd> <gpu> <interval>` —
    // main.zig routes it. The string buffers live on this stack frame;
    // spawnDetached forks and the child execs from its copy before this function
    // returns, so they are valid for the exec.
    const argv = [_:null]?[*:0]const u8{
        "/proc/self/exe",
        "relay",
        "--daemon",
        @ptrCast(ep_str.ptr),
        @ptrCast(sd_str.ptr),
        @ptrCast(fd_str.ptr),
        @ptrCast(gpu_str.ptr),
        @ptrCast(gi_str.ptr),
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
    writeFrame(bytes);
}

/// Emit one lifecycle event (drops silently if no daemon or the pipe is full).
pub fn emitLifecycle(e: frame.Lifecycle) void {
    if (write_fd < 0) return;
    var buf: [128]u8 = undefined;
    const bytes = frame.encodeLifecycle(&buf, e) catch return;
    writeFrame(bytes);
}

/// One non-blocking write; drop on anything but a full success. Never blocks,
/// never retries — the supervision loop outranks telemetry. Frames are far
/// below PIPE_BUF (4096), so a pipe write is atomic: it either writes the whole
/// frame or, with O_NONBLOCK on a full pipe, writes nothing and returns EAGAIN.
/// No partial frame can therefore desync the daemon's stream.
fn writeFrame(bytes: []const u8) void {
    const rc = linux.write(write_fd, bytes.ptr, bytes.len);
    switch (posix.errno(rc)) {
        .SUCCESS => {}, // whole frame written (atomic below PIPE_BUF)
        .PIPE => {
            // Daemon gone: stop trying so we neither spin nor keep tripping the
            // (blocked) SIGPIPE. Incidents still reach the spool regardless.
            _ = linux.close(write_fd);
            write_fd = -1;
        },
        else => {}, // EAGAIN (pipe full) / EINTR / other → drop this record
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
