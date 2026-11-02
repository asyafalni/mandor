//! mandor's own stdout/stderr, written so they can never stop PID 1.
//!
//! Worker output is echoed to mandor's stdout/stderr, and mandor's own
//! `[mandor] …` lines go to stderr. Whoever reads those — containerd-shim,
//! dockerd's log driver, journald — runs on the host and can stall (memory
//! pressure is the usual cause). A blocking write then parks the supervision
//! loop in `pipe_write` once the 64 KB pipe fills: nothing is reaped, no
//! signal is forwarded, no probe runs. And a reader that goes away raised
//! SIGPIPE, which killed PID 1.
//!
//! So a write here never waits. `init` opens a PRIVATE non-blocking
//! description of each stream by reopening `/proc/self/fd/N` (a pipe, FIFO or
//! tty); setting O_NONBLOCK on fd 1 itself would leak to every process sharing
//! it, the operator's terminal included. A socket (journald) is written with
//! MSG_DONTWAIT instead. A regular file is left as it is: a file write does
//! not wait on a reader. Children keep the ordinary blocking fd 1/2 — the
//! private ones are close-on-exec.
//!
//! What does not fit is dropped and counted, and once the reader is back one
//! line says how much was lost. Only the live echo loses lines: the capture
//! ring, incident bundles and the photon digest are fed before this point.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

pub const Stream = struct {
    /// The standard descriptor this stream stands for (1 or 2).
    std_fd: i32,
    /// The descriptor to write: the private non-blocking reopen, else std_fd.
    fd: i32,
    /// std_fd is a socket: write with MSG_DONTWAIT.
    sock: bool = false,
    /// Lines (iovecs / messages) dropped since the last notice.
    dropped: u64 = 0,
    /// The last write stopped part-way through a line.
    cut: bool = false,
};

pub var out: Stream = .{ .std_fd = 1, .fd = 1 };
pub var err: Stream = .{ .std_fd = 2, .fd = 2 };

/// Prepare both streams. Called once at supervisor boot, before any worker
/// is spawned. Until then (and in the CLI's report/validate paths) writes go
/// to fd 1/2 as plain blocking writes, which is right for a short command.
pub fn init() void {
    // A reader that goes away must fail the write with EPIPE, not kill PID 1.
    // Every fork path resets the mask before exec, so workers keep default
    // SIGPIPE behavior.
    var pipe_set = posix.sigemptyset();
    posix.sigaddset(&pipe_set, .PIPE);
    posix.sigprocmask(posix.SIG.BLOCK, &pipe_set, null);
    prepare(&out);
    prepare(&err);
}

fn prepare(s: *Stream) void {
    var st: linux.Statx = undefined;
    if (posix.errno(linux.statx(s.std_fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true }, &st)) != .SUCCESS) return;
    const mode: linux.mode_t = st.mode;
    if (linux.S.ISSOCK(mode)) {
        s.sock = true;
        return;
    }
    if (!linux.S.ISFIFO(mode) and !linux.S.ISCHR(mode)) return; // file: never waits on a reader
    var path_buf: [32]u8 = undefined;
    const path = std.mem.printSentinel(&path_buf, "/proc/self/fd/{d}", .{s.std_fd}, 0) catch return;
    const rc = linux.openat(linux.AT.FDCWD, path.ptr, .{
        .ACCMODE = .WRONLY,
        .NONBLOCK = true,
        .CLOEXEC = true,
        .NOCTTY = true,
    }, 0);
    if (posix.errno(rc) != .SUCCESS) return; // no /proc: stay blocking, as before
    s.fd = @intCast(rc);
}

/// Write whole lines, one per iovec, without ever waiting.
pub fn writev(s: *Stream, iov: []const posix.iovec_const) void {
    if (iov.len == 0) return;
    if (s.dropped > 0 or s.cut) {
        if (!notice(s)) {
            s.dropped +|= iov.len;
            return;
        }
    }
    const rc = raw(s, iov);
    const e = posix.errno(rc);
    if (e != .SUCCESS) {
        // EAGAIN (reader stalled), EPIPE (reader gone), anything else: drop.
        if (e == .INTR) return writev(s, iov);
        s.dropped +|= iov.len;
        return;
    }
    // A non-blocking pipe may take part of the batch: keep what landed.
    var left: usize = rc;
    for (iov, 0..) |v, i| {
        if (left >= v.len) {
            left -= v.len;
            continue;
        }
        s.cut = left > 0; // stopped mid-line: the notice starts on a new line
        s.dropped +|= iov.len - i;
        return;
    }
}

/// Write one message (a `[mandor] …` line) the same way.
pub fn write(s: *Stream, bytes: []const u8) void {
    const iov = [_]posix.iovec_const{.{ .base = bytes.ptr, .len = bytes.len }};
    writev(s, &iov);
}

fn raw(s: *Stream, iov: []const posix.iovec_const) usize {
    if (s.sock) {
        const msg: linux.msghdr_const = .{
            .name = null,
            .namelen = 0,
            .iov = iov.ptr,
            .iovlen = iov.len,
            .control = null,
            .controllen = 0,
            .flags = 0,
        };
        return linux.sendmsg(s.std_fd, &msg, linux.MSG.DONTWAIT | linux.MSG.NOSIGNAL);
    }
    return linux.writev(s.fd, iov.ptr, iov.len);
}

/// Report the gap once the reader is back. Short enough to be one atomic pipe
/// write (< PIPE_BUF): it lands whole or not at all. True once written.
fn notice(s: *Stream) bool {
    var buf: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{s}[mandor] output could not keep up: {d} line(s) dropped\n", .{
        if (s.cut) "\n" else "", s.dropped,
    }) catch return false;
    const iov = [_]posix.iovec_const{.{ .base = text.ptr, .len = text.len }};
    const rc = raw(s, &iov);
    if (posix.errno(rc) != .SUCCESS or rc != text.len) return false;
    s.dropped = 0;
    s.cut = false;
    return true;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "a full pipe drops and counts, never blocks, and reports the gap once drained" {
    var fds: [2]i32 = undefined;
    try testing.expect(posix.errno(linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true })) == .SUCCESS);
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);
    var s: Stream = .{ .std_fd = fds[1], .fd = fds[1] };

    // Fill the pipe; a blocking writer would hang here forever.
    const line = @as([1000]u8, @splat('x')) ++ "\n";
    for (0..200) |_| write(&s, line);
    try testing.expect(s.dropped > 0);

    // Drain the reader, then the next write first reports the loss.
    var sink: [4096]u8 = undefined;
    while (posix.errno(linux.read(fds[0], &sink, sink.len)) == .SUCCESS) {}
    write(&s, "after\n");
    try testing.expectEqual(@as(u64, 0), s.dropped);
    var got: [512]u8 = undefined;
    const n = linux.read(fds[0], &got, got.len);
    try testing.expect(std.mem.indexOf(u8, got[0..n], "line(s) dropped") != null);
    try testing.expect(std.mem.endsWith(u8, got[0..n], "after\n"));
}

test "a reader that went away is EPIPE, dropped, and does not kill the writer" {
    var fds: [2]i32 = undefined;
    try testing.expect(posix.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) == .SUCCESS);
    _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);
    // Ignored for the test, not blocked: a blocked SIGPIPE would stay pending
    // and kill the test runner when the mask is restored.
    const ign: posix.Sigaction = .{ .handler = .{ .handler = linux.SIG.IGN }, .mask = posix.sigemptyset(), .flags = 0 };
    var old: posix.Sigaction = undefined;
    posix.sigaction(.PIPE, &ign, &old);
    defer posix.sigaction(.PIPE, &old, null);
    var s: Stream = .{ .std_fd = fds[1], .fd = fds[1] };
    write(&s, "nobody hears this\n");
    try testing.expectEqual(@as(u64, 1), s.dropped);
}
