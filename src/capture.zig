//! Worker output capture: line assembly (pure) and pipe plumbing (Linux).
//! Chunks read from a worker pipe are assembled into lines, echoed to
//! mandor's own stdout/stderr with a `[name] ` prefix, and framed into the
//! worker's ring buffer.

const std = @import("std");
const builtin = @import("builtin");
const ring = @import("ring.zig");

pub const max_line = 4095;

/// Reassembles stream chunks into lines. Pure — tests run anywhere.
/// Lines longer than max_line are split; the split-off remainder records
/// carry ring.flag_continuation. Trailing \r is stripped.
pub const Assembler = struct {
    buf: [max_line]u8 = undefined,
    len: usize = 0,
    continued: bool = false,

    pub fn feed(
        self: *Assembler,
        base_flags: u8,
        chunk: []const u8,
        ctx: anytype,
        comptime sink: fn (@TypeOf(ctx), []const u8, u8) void,
    ) void {
        var rest = chunk;
        while (rest.len > 0) {
            if (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
                self.append(base_flags, rest[0..nl], true, ctx, sink);
                rest = rest[nl + 1 ..];
            } else {
                self.append(base_flags, rest, false, ctx, sink);
                break;
            }
        }
    }

    /// Stream closed: emit any partial data as a final line.
    pub fn flushEof(
        self: *Assembler,
        base_flags: u8,
        ctx: anytype,
        comptime sink: fn (@TypeOf(ctx), []const u8, u8) void,
    ) void {
        if (self.len > 0) self.emit(base_flags, ctx, sink);
        self.continued = false;
    }

    fn append(
        self: *Assembler,
        base_flags: u8,
        part: []const u8,
        complete: bool,
        ctx: anytype,
        comptime sink: fn (@TypeOf(ctx), []const u8, u8) void,
    ) void {
        var p = part;
        while (self.len + p.len > max_line) {
            const take = max_line - self.len;
            @memcpy(self.buf[self.len..][0..take], p[0..take]);
            self.len = max_line;
            self.emit(base_flags, ctx, sink);
            self.continued = true;
            p = p[take..];
        }
        @memcpy(self.buf[self.len..][0..p.len], p);
        self.len += p.len;
        if (complete) {
            if (self.len > 0 and self.buf[self.len - 1] == '\r') self.len -= 1;
            self.emit(base_flags, ctx, sink);
            self.continued = false;
        }
    }

    fn emit(
        self: *Assembler,
        base_flags: u8,
        ctx: anytype,
        comptime sink: fn (@TypeOf(ctx), []const u8, u8) void,
    ) void {
        const flags = base_flags | (if (self.continued) ring.flag_continuation else 0);
        sink(ctx, self.buf[0..self.len], flags);
        self.len = 0;
    }
};

// ------------------------------------------------------- Linux plumbing

const linux = std.os.linux;
const posix = std.posix;

pub const Pipes = struct {
    out_r: i32 = -1,
    err_r: i32 = -1,
};

/// Create stdout+stderr pipes for a worker about to be spawned.
/// Returns parent read ends (nonblocking, cloexec) and child write ends.
pub const PipePair = struct { r: i32, w: i32 };

pub fn makePipe() ?PipePair {
    var fds: [2]i32 = undefined;
    if (posix.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return null;
    // Nonblocking on the parent read end only — the child keeps a normal
    // blocking stdout so worker writes never see EAGAIN.
    const fl = linux.fcntl(fds[0], linux.F.GETFL, 0);
    const nonblock: u32 = @bitCast(linux.O{ .NONBLOCK = true });
    _ = linux.fcntl(fds[0], linux.F.SETFL, fl | nonblock);
    return .{ .r = fds[0], .w = fds[1] };
}

pub fn closeFd(fd: *i32) void {
    if (fd.* >= 0) {
        _ = linux.close(fd.*);
        fd.* = -1;
    }
}

// ---------------------------------------------------------------- tests

const TestSink = struct {
    lines: [8][max_line]u8 = undefined,
    lens: [8]usize = .{0} ** 8,
    flags: [8]u8 = .{0} ** 8,
    n: usize = 0,

    fn sink(self: *TestSink, text: []const u8, flags: u8) void {
        @memcpy(self.lines[self.n][0..text.len], text);
        self.lens[self.n] = text.len;
        self.flags[self.n] = flags;
        self.n += 1;
    }

    fn line(self: *const TestSink, i: usize) []const u8 {
        return self.lines[i][0..self.lens[i]];
    }
};

test "partial chunks join into one line" {
    var a: Assembler = .{};
    var s: TestSink = .{};
    a.feed(0, "hel", &s, TestSink.sink);
    a.feed(0, "lo\nwor", &s, TestSink.sink);
    a.feed(0, "ld\n", &s, TestSink.sink);
    try std.testing.expectEqual(@as(usize, 2), s.n);
    try std.testing.expectEqualStrings("hello", s.line(0));
    try std.testing.expectEqualStrings("world", s.line(1));
}

test "crlf stripped, empty lines kept, base flags pass through" {
    var a: Assembler = .{};
    var s: TestSink = .{};
    a.feed(ring.flag_stderr, "a\r\nb\n\n", &s, TestSink.sink);
    try std.testing.expectEqual(@as(usize, 3), s.n);
    try std.testing.expectEqualStrings("a", s.line(0));
    try std.testing.expectEqualStrings("b", s.line(1));
    try std.testing.expectEqualStrings("", s.line(2));
    try std.testing.expectEqual(ring.flag_stderr, s.flags[0]);
}

test "oversized line splits with continuation flag" {
    var a: Assembler = .{};
    var s: TestSink = .{};
    const big = "x" ** 5000;
    a.feed(0, big ++ "\n", &s, TestSink.sink);
    try std.testing.expectEqual(@as(usize, 2), s.n);
    try std.testing.expectEqual(@as(usize, max_line), s.lens[0]);
    try std.testing.expectEqual(@as(usize, 5000 - max_line), s.lens[1]);
    try std.testing.expectEqual(@as(u8, 0), s.flags[0]);
    try std.testing.expectEqual(ring.flag_continuation, s.flags[1]);
}

test "eof flushes partial line" {
    var a: Assembler = .{};
    var s: TestSink = .{};
    a.feed(0, "no newline", &s, TestSink.sink);
    try std.testing.expectEqual(@as(usize, 0), s.n);
    a.flushEof(0, &s, TestSink.sink);
    try std.testing.expectEqual(@as(usize, 1), s.n);
    try std.testing.expectEqualStrings("no newline", s.line(0));
}
