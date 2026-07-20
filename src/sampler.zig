//! /proc sampler: CPU%, RSS, fd count, thread count per worker.
//! Text parsing is pure (tested anywhere); readers are Linux-only.

const std = @import("std");
const builtin = @import("builtin");

/// Kernel USER_HZ. sysconf needs libc; 100 is correct on every mainstream
/// Linux arch/config this binary targets.
pub const user_hz: u64 = 100;
pub const page_kb: u64 = 4; // 4096-byte pages on x86_64/aarch64
pub const interval_ms: u64 = 5_000;
pub const window_len = 24; // 2 minutes of history at 5 s cadence

pub const Sample = struct {
    t_ms: u64 = 0,
    rss_kb: u64 = 0,
    cpu_pct: u16 = 0,
    fds: u16 = 0,
    threads: u16 = 0,
    /// cgroup v2 pressure-stall: "some avg60" ×100 (whole percent) for
    /// memory / cpu / io. 0 when PSI is unavailable.
    psi_mem: u16 = 0,
    psi_cpu: u16 = 0,
    psi_io: u16 = 0,
};

/// Parse the `some avg60=` field of a PSI line block, ×100 as whole percent.
/// Input is the full /proc or cgroup pressure file (memory has some+full;
/// we take the first "some" line). Fixed scan, no regex.
pub fn parsePsiAvg60(text: []const u8) u16 {
    const some = std.mem.indexOf(u8, text, "some ") orelse return 0;
    const pat = "avg60=";
    const at = std.mem.indexOfPos(u8, text, some, pat) orelse return 0;
    var j = at + pat.len;
    // parse a decimal like 12.34 -> 1234 (percent ×100), clamp to u16
    // Saturating: a corrupt pressure file can carry an arbitrarily long digit
    // run, and the result is clamped to u16 below regardless.
    var whole: u32 = 0;
    while (j < text.len and text[j] >= '0' and text[j] <= '9') : (j += 1) {
        whole = whole *| 10 +| (text[j] - '0');
    }
    var frac: u32 = 0;
    var fdigits: u32 = 0;
    if (j < text.len and text[j] == '.') {
        j += 1;
        while (j < text.len and text[j] >= '0' and text[j] <= '9' and fdigits < 2) : (j += 1) {
            frac = frac * 10 + (text[j] - '0');
            fdigits += 1;
        }
    }
    while (fdigits < 2) : (fdigits += 1) frac *= 10;
    return @intCast(@min(whole *| 100 +| frac, std.math.maxInt(u16)));
}

/// Rolling window of the most recent samples.
pub const Window = struct {
    samples: [window_len]Sample = undefined,
    next: usize = 0,
    len: usize = 0,
    prev_ticks: u64 = 0,
    prev_t_ms: u64 = 0,

    pub fn push(self: *Window, s: Sample) void {
        self.samples[self.next] = s;
        self.next = (self.next + 1) % window_len;
        if (self.len < window_len) self.len += 1;
    }

    /// Oldest-first iteration index -> sample.
    pub fn at(self: *const Window, i: usize) Sample {
        const start = (self.next + window_len - self.len) % window_len;
        return self.samples[(start + i) % window_len];
    }
};

pub const StatFields = struct {
    utime: u64,
    stime: u64,
    threads: u64,
    rss_pages: u64,
};

/// Parse /proc/<pid>/stat. comm may contain spaces and parens, so fields
/// are counted after the LAST ')'. 1-based field numbers (per proc(5)):
/// utime=14, stime=15, num_threads=20, rss=24.
pub fn parseStat(text: []const u8) ?StatFields {
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return null;
    var it = std.mem.tokenizeAny(u8, text[close + 1 ..], " \t\n");
    var fields: StatFields = .{ .utime = 0, .stime = 0, .threads = 0, .rss_pages = 0 };
    var idx: usize = 3; // first token after ')' is field 3 (state)
    while (it.next()) |tok| : (idx += 1) {
        switch (idx) {
            14 => fields.utime = std.fmt.parseInt(u64, tok, 10) catch return null,
            15 => fields.stime = std.fmt.parseInt(u64, tok, 10) catch return null,
            20 => fields.threads = std.fmt.parseInt(u64, tok, 10) catch return null,
            24 => {
                fields.rss_pages = std.fmt.parseInt(u64, tok, 10) catch return null;
                return fields;
            },
            else => {},
        }
    }
    return null;
}

/// Whole-percent CPU usage across one sampling interval (can exceed 100 on
/// multicore). 0 when the clock has not advanced.
pub fn cpuPct(prev_ticks: u64, cur_ticks: u64, dt_ms: u64) u16 {
    if (dt_ms == 0 or cur_ticks <= prev_ticks) return 0;
    const dticks = cur_ticks - prev_ticks;
    const pct = (dticks * 1000 * 100) / (user_hz * dt_ms);
    return @intCast(@min(pct, 60_000));
}

// ------------------------------------------------------- Linux readers

const linux = std.os.linux;
const posix = std.posix;

fn readFile(path: [*:0]const u8, buf: []u8) ?[]const u8 {
    const rc = linux.openat(linux.AT.FDCWD, path, .{}, 0);
    if (posix.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const n = linux.read(fd, buf.ptr, buf.len);
    if (posix.errno(n) != .SUCCESS) return null;
    return buf[0..n];
}

fn countFds(pid: i32, path_buf: *[64]u8) u16 {
    const path = std.fmt.bufPrintZ(path_buf, "/proc/{d}/fd", .{pid}) catch return 0;
    const rc = linux.openat(linux.AT.FDCWD, path.ptr, .{ .DIRECTORY = true }, 0);
    if (posix.errno(rc) != .SUCCESS) return 0;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var count: usize = 0;
    var buf: [4096]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &buf, buf.len);
        if (posix.errno(n) != .SUCCESS or n == 0) break;
        var off: usize = 0;
        while (off < n) {
            const ent: *const linux.dirent64 = @ptrCast(@alignCast(&buf[off]));
            const name: [*:0]const u8 = @ptrCast(&ent.name);
            const s = std.mem.span(name);
            if (!std.mem.eql(u8, s, ".") and !std.mem.eql(u8, s, "..")) count += 1;
            off += ent.reclen;
        }
    }
    return @intCast(@min(count, std.math.maxInt(u16)));
}

pub const Psi = struct { mem: u16 = 0, cpu: u16 = 0, io: u16 = 0 };

fn readPsiFile(path: [*:0]const u8) u16 {
    var buf: [256]u8 = undefined;
    const text = readFile(path, &buf) orelse return 0;
    return parsePsiAvg60(text);
}

/// Container-wide pressure (cgroup v2, /proc fallback). Read once per tick —
/// PSI is cgroup-scoped, not per-process.
pub fn readPsi() Psi {
    return .{
        .mem = readPsiFile("/sys/fs/cgroup/memory.pressure"),
        .cpu = readPsiFile("/sys/fs/cgroup/cpu.pressure"),
        .io = readPsiFile("/sys/fs/cgroup/io.pressure"),
    };
}

/// Take one sample for a live pid and push it into the window.
pub fn sample(window: *Window, pid: i32, now_ms: u64, psi: Psi) void {
    var path_buf: [64]u8 = undefined;
    var stat_buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/stat", .{pid}) catch return;
    const text = readFile(path.ptr, &stat_buf) orelse return;
    const fields = parseStat(text) orelse return;

    const ticks = fields.utime + fields.stime;
    const dt = now_ms -| window.prev_t_ms;
    const pct = if (window.prev_t_ms == 0) 0 else cpuPct(window.prev_ticks, ticks, dt);
    window.prev_ticks = ticks;
    window.prev_t_ms = now_ms;

    window.push(.{
        .t_ms = now_ms,
        .rss_kb = fields.rss_pages * page_kb,
        .cpu_pct = pct,
        .fds = countFds(pid, &path_buf),
        .threads = @intCast(@min(fields.threads, std.math.maxInt(u16))),
        .psi_mem = psi.mem,
        .psi_cpu = psi.cpu,
        .psi_io = psi.io,
    });
}

// ---------------------------------------------------------------- tests

test "parseStat handles evil comm names" {
    const line = "1234 (my (evil) app) R 1 1234 1234 0 -1 4194304 500 0 0 0 " ++
        "700 300 0 0 20 0 7 0 12345 100000000 2048 18446744073709551615 " ++
        "1 1 0 0 0 0 0 0 0 0 0 0 17 3 0 0 0 0 0";
    const f = parseStat(line).?;
    try std.testing.expectEqual(@as(u64, 700), f.utime);
    try std.testing.expectEqual(@as(u64, 300), f.stime);
    try std.testing.expectEqual(@as(u64, 7), f.threads);
    try std.testing.expectEqual(@as(u64, 2048), f.rss_pages);
}

test "parsePsiAvg60 extracts some avg60 as percent x100" {
    const t = "some avg10=0.04 avg60=12.34 avg300=0.00 total=75201\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0";
    try std.testing.expectEqual(@as(u16, 1234), parsePsiAvg60(t));
    try std.testing.expectEqual(@as(u16, 0), parsePsiAvg60("some avg10=0.0 avg60=0.00 avg300=0.0 total=0"));
    try std.testing.expectEqual(@as(u16, 10000), parsePsiAvg60("some avg60=100.00 total=1"));
    try std.testing.expectEqual(@as(u16, 0), parsePsiAvg60("garbage"));
}

test "parseStat rejects garbage" {
    try std.testing.expectEqual(@as(?StatFields, null), parseStat("not a stat line"));
    try std.testing.expectEqual(@as(?StatFields, null), parseStat("1 (x) R 1 2"));
}

test "cpuPct math" {
    // 100 ticks over 1000ms at USER_HZ 100 => 100%
    try std.testing.expectEqual(@as(u16, 100), cpuPct(0, 100, 1000));
    // 50 ticks over 1000ms => 50%
    try std.testing.expectEqual(@as(u16, 50), cpuPct(100, 150, 1000));
    // 1000 ticks over 5000ms => 200% (two cores)
    try std.testing.expectEqual(@as(u16, 200), cpuPct(0, 1000, 5000));
    try std.testing.expectEqual(@as(u16, 0), cpuPct(100, 100, 1000));
    try std.testing.expectEqual(@as(u16, 0), cpuPct(0, 100, 0));
}

test "window rolls over keeping newest" {
    var w: Window = .{};
    for (0..30) |i| w.push(.{ .t_ms = i });
    try std.testing.expectEqual(@as(usize, window_len), w.len);
    try std.testing.expectEqual(@as(u64, 6), w.at(0).t_ms);
    try std.testing.expectEqual(@as(u64, 29), w.at(window_len - 1).t_ms);
}

test "live sample of our own pid" {
    if (builtin.os.tag != .linux) return;
    var w: Window = .{};
    sample(&w, @intCast(linux.getpid()), 1000, .{});
    try std.testing.expectEqual(@as(usize, 1), w.len);
    try std.testing.expect(w.at(0).rss_kb > 0);
    try std.testing.expect(w.at(0).threads >= 1);
    try std.testing.expect(w.at(0).fds >= 3);
}
