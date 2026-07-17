//! Incident bundles: stable JSON schema v1 written to
//! `<state-dir>/incidents/`. The premium sidecar consumes these files; any
//! schema change MUST bump bundle_version and the fixture test.

const std = @import("std");
const jb = @import("jsonbuf.zig");
const sampler = @import("sampler.zig");
const ring = @import("ring.zig");
const summarize = @import("summarize.zig");

pub const bundle_version = 1;

// ------------------------------------------------------- wall clock

pub const Civil = struct { y: i64, mo: u8, d: u8, h: u8, mi: u8, s: u8 };

/// Days-since-epoch -> civil date (Howard Hinnant's algorithm).
pub fn civilFromEpoch(secs: i64) Civil {
    const z0 = @divFloor(secs, 86_400);
    const sod: u32 = @intCast(secs - z0 * 86_400);
    const z = z0 + 719_468;
    const era = @divFloor(z, 146_097);
    const doe = z - era * 146_097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36_524) -
        @divFloor(doe, 146_096), 365);
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const mo: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{
        .y = if (mo <= 2) y + 1 else y,
        .mo = mo,
        .d = d,
        .h = @intCast(sod / 3600),
        .mi = @intCast((sod % 3600) / 60),
        .s = @intCast(sod % 60),
    };
}

/// "2026-07-17T22:47:03Z"
pub fn iso8601(buf: *[20]u8, epoch_secs: i64) []const u8 {
    const c = civilFromEpoch(epoch_secs);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u64, @intCast(@max(c.y, 0))), c.mo, c.d, c.h, c.mi, c.s,
    }) catch buf[0..0];
}

// ------------------------------------------------------- bundle input

pub const LogLine = summarize.LogLine;
pub const TraceInfo = summarize.TraceInfo;

pub const BundleInput = struct {
    ts_epoch: i64,
    name: []const u8,
    cmd: []const u8,
    pid: i32,
    restarts: u32,
    cause: []const u8, // "exit:1" | "signal:SIGSEGV" | "restart-loop" | "leak-suspect"
    trace: TraceInfo,
    logs_tail: []const LogLine, // oldest-first, already limited to ~200
    stats: []const sampler.Sample, // oldest-first
    now_ms: u64, // monotonic reference for stats "t" offsets
    verdict: []const u8,
};

/// Serialize a bundle. Returns null if buf is too small (never panics).
pub fn serialize(buf: []u8, in: BundleInput) ?[]const u8 {
    var pos: usize = 0;
    const p = &pos;
    var ts_buf: [20]u8 = undefined;
    if (!jb.appendf(buf, p, "{{\"v\":{d},\"ts\":\"{s}\",\"process\":{{\"name\":", .{
        bundle_version, iso8601(&ts_buf, in.ts_epoch),
    })) return null;
    if (!jb.appendJsonString(buf, p, in.name)) return null;
    if (!jb.appendf(buf, p, ",\"cmd\":", .{})) return null;
    if (!jb.appendJsonString(buf, p, in.cmd)) return null;
    if (!jb.appendf(buf, p, ",\"pid\":{d},\"restarts\":{d}}},\"cause\":\"{s}\",\"trace\":{{\"lang\":\"{s}\",\"frames\":[", .{
        in.pid, in.restarts, in.cause, in.trace.lang,
    })) return null;
    for (in.trace.frames, 0..) |f, i| {
        if (i > 0 and !jb.appendf(buf, p, ",", .{})) return null;
        if (!jb.appendJsonString(buf, p, f)) return null;
    }
    if (!jb.appendf(buf, p, "],\"raw\":", .{})) return null;
    if (!jb.appendJsonString(buf, p, in.trace.raw)) return null;
    if (!jb.appendf(buf, p, "}},\"logs_tail\":[", .{})) return null;
    for (in.logs_tail, 0..) |l, i| {
        if (i > 0 and !jb.appendf(buf, p, ",", .{})) return null;
        const stream: []const u8 = if (l.flags & ring.flag_stderr != 0) "E" else "O";
        const bang: []const u8 = if (summarize.errorish(l.text)) "!" else "";
        if (!jb.appendf(buf, p, "\"[{s}{s}] ", .{ stream, bang })) return null;
        // reuse string escaper minus the opening quote: emit escaped body + closing quote
        for (l.text) |c| {
            const ok = switch (c) {
                '"' => jb.appendf(buf, p, "\\\"", .{}),
                '\\' => jb.appendf(buf, p, "\\\\", .{}),
                0x00...0x1f => jb.appendf(buf, p, "\\u{x:0>4}", .{c}),
                else => jb.appendf(buf, p, "{c}", .{c}),
            };
            if (!ok) return null;
        }
        if (!jb.appendf(buf, p, "\"", .{})) return null;
    }
    if (!jb.appendf(buf, p, "],\"stats_timeline\":[", .{})) return null;
    for (in.stats, 0..) |s, i| {
        if (i > 0 and !jb.appendf(buf, p, ",", .{})) return null;
        const dt_s = (in.now_ms -| s.t_ms) / 1000;
        if (!jb.appendf(buf, p, "{{\"t\":\"-{d}s\",\"rss_mb\":{d},\"cpu_pct\":{d}}}", .{
            dt_s, s.rss_kb / 1024, s.cpu_pct,
        })) return null;
    }
    if (!jb.appendf(buf, p, "],\"verdict\":", .{})) return null;
    if (!jb.appendJsonString(buf, p, in.verdict)) return null;
    if (!jb.appendf(buf, p, "}}", .{})) return null;
    return buf[0..pos];
}

// ------------------------------------------------------- Linux writer

const linux = std.os.linux;
const posix = std.posix;

var bundle_buf: [128 * 1024]u8 = undefined;
var seq: u32 = 0;

/// Serialize + write `<state_dir>/incidents/<ts>-<name>-<seq>.json` atomically.
pub fn write(state_dir: []const u8, in: BundleInput) void {
    const json = serialize(&bundle_buf, in) orelse return;

    var dir_buf: [512]u8 = undefined;
    const dir_z = std.fmt.bufPrintZ(&dir_buf, "{s}/incidents", .{state_dir}) catch return;
    var root_buf: [512]u8 = undefined;
    const root_z = std.fmt.bufPrintZ(&root_buf, "{s}", .{state_dir}) catch return;
    _ = linux.mkdirat(linux.AT.FDCWD, root_z.ptr, 0o755);
    _ = linux.mkdirat(linux.AT.FDCWD, dir_z.ptr, 0o755);

    seq +%= 1;
    var path_buf: [640]u8 = undefined;
    var tmp_buf: [640]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/incidents/{d}-{s}-{d}.json", .{
        state_dir, in.ts_epoch, in.name, seq,
    }) catch return;
    const tmp = std.fmt.bufPrintZ(&tmp_buf, "{s}/incidents/.tmp-{d}", .{ state_dir, seq }) catch return;

    const rc = linux.openat(linux.AT.FDCWD, tmp.ptr, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
    }, 0o644);
    if (posix.errno(rc) != .SUCCESS) return;
    const fd: i32 = @intCast(rc);
    var off: usize = 0;
    while (off < json.len) {
        const n = linux.write(fd, json.ptr + off, json.len - off);
        if (posix.errno(n) != .SUCCESS) break;
        off += n;
    }
    _ = linux.close(fd);
    if (off == json.len) _ = linux.rename(tmp.ptr, path.ptr);
}

// ---------------------------------------------------------------- tests

test "iso8601 known dates" {
    var buf: [20]u8 = undefined;
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", iso8601(&buf, 0));
    try std.testing.expectEqualStrings("2026-07-17T22:47:03Z", iso8601(&buf, 1_784_328_423));
    try std.testing.expectEqualStrings("2000-02-29T12:00:00Z", iso8601(&buf, 951_825_600));
    try std.testing.expectEqualStrings("2024-12-31T23:59:59Z", iso8601(&buf, 1_735_689_599));
}

test "bundle golden output locks schema v1" {
    const frames = [_][]const u8{ "main.crash main.go:10", "main.main main.go:4" };
    const logs = [_]LogLine{
        .{ .text = "listening on :8080", .flags = 0 },
        .{ .text = "panic: nil deref", .flags = ring.flag_stderr },
    };
    const stats = [_]sampler.Sample{
        .{ .t_ms = 40_000, .rss_kb = 831_488, .cpu_pct = 97 },
    };
    var buf: [4096]u8 = undefined;
    const json = serialize(&buf, .{
        .ts_epoch = 1_784_328_423,
        .name = "api",
        .cmd = "./api --port 8080",
        .pid = 42,
        .restarts = 3,
        .cause = "signal:SIGSEGV",
        .trace = .{ .lang = "go", .frames = &frames, .raw = "panic: nil deref" },
        .logs_tail = &logs,
        .stats = &stats,
        .now_ms = 100_000,
        .verdict = "go panic in main.crash",
    }).?;
    const expected =
        "{\"v\":1,\"ts\":\"2026-07-17T22:47:03Z\"," ++
        "\"process\":{\"name\":\"api\",\"cmd\":\"./api --port 8080\",\"pid\":42,\"restarts\":3}," ++
        "\"cause\":\"signal:SIGSEGV\"," ++
        "\"trace\":{\"lang\":\"go\",\"frames\":[\"main.crash main.go:10\",\"main.main main.go:4\"]," ++
        "\"raw\":\"panic: nil deref\"}," ++
        "\"logs_tail\":[\"[O] listening on :8080\",\"[E!] panic: nil deref\"]," ++
        "\"stats_timeline\":[{\"t\":\"-60s\",\"rss_mb\":812,\"cpu_pct\":97}]," ++
        "\"verdict\":\"go panic in main.crash\"}";
    try std.testing.expectEqualStrings(expected, json);
}
