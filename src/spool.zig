//! Incident bundles: stable JSON schema v1 written to
//! `<state-dir>/incidents/`. The premium sidecar consumes these files; any
//! schema change MUST bump bundle_version and the fixture test.

const std = @import("std");
const jb = @import("jsonbuf.zig");
const sampler = @import("sampler.zig");
const ring = @import("ring.zig");
const summarize = @import("summarize.zig");

pub const bundle_version = 2;

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

/// "2026-07-17T22:47:03.881Z" from wall-clock milliseconds.
pub fn iso8601Ms(buf: *[24]u8, epoch_ms: u64) []const u8 {
    const c = civilFromEpoch(@intCast(epoch_ms / 1000));
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        @as(u64, @intCast(@max(c.y, 0))), c.mo, c.d, c.h, c.mi, c.s, epoch_ms % 1000,
    }) catch buf[0..0];
}

/// Env value redaction: any variable whose NAME smells like a credential.
pub fn envRedacted(name: []const u8) bool {
    return summarize.containsIgnoreCase(name, "secret") or
        summarize.containsIgnoreCase(name, "token") or
        summarize.containsIgnoreCase(name, "password") or
        summarize.containsIgnoreCase(name, "passwd") or
        summarize.containsIgnoreCase(name, "key") or
        summarize.containsIgnoreCase(name, "credential");
}

// ------------------------------------------------------- bundle input

pub const LogLine = summarize.LogLine;
pub const TraceInfo = summarize.TraceInfo;

pub const CauseInfo = struct {
    kind: []const u8, // exit | signal | oom | restart-loop | leak-suspect
    exit_code: ?u8 = null,
    sig_num: ?u8 = null,
    sig_name: []const u8 = "",
    core_dumped: bool = false,
    oom_kill_delta: u64 = 0,
};

pub const Sibling = struct {
    name: []const u8,
    state: []const u8,
    uptime_s: u64,
    restarts: u32,
};

pub const empty_environ = [_:null]?[*:0]const u8{};

pub const BundleInput = struct {
    ts_epoch: i64,
    name: []const u8,
    cmd: []const u8,
    pid: i32,
    restarts: u32,
    cwd: []const u8 = "",
    exe: []const u8 = "",
    spawned_at_epoch: i64 = 0,
    uptime_s: u64 = 0,
    release: []const u8 = "", // MANDOR_RELEASE / GIT_SHA passthrough
    environ: [:null]const ?[*:0]const u8 = &empty_environ,
    limits_nofile: u64 = 0,
    memory_max_bytes: ?u64 = null,
    cause: CauseInfo,
    cause_str: []const u8, // v1-compatible mirror for the sidecar transition
    trace: TraceInfo,
    logs_tail: []const LogLine, // oldest-first, already limited to ~200
    stats: []const sampler.Sample, // oldest-first
    now_ms: u64, // monotonic reference for stats "t" offsets
    siblings: []const Sibling = &.{},
    verdict: []const u8,
};

const max_env_vars = 32;

/// Serialize a schema-v2 bundle. Returns null if buf is too small (never
/// panics). See docs/superpowers/plans/2026-07-17-v0.5-forensics.md.
pub fn serialize(buf: []u8, in: BundleInput) ?[]const u8 {
    var pos: usize = 0;
    const p = &pos;
    var ts_buf: [20]u8 = undefined;
    var ts2_buf: [20]u8 = undefined;

    // process
    if (!jb.appendf(buf, p, "{{\"v\":{d},\"ts\":\"{s}\",\"process\":{{\"name\":", .{
        bundle_version, iso8601(&ts_buf, in.ts_epoch),
    })) return null;
    if (!jb.appendJsonString(buf, p, in.name)) return null;
    if (!jb.appendf(buf, p, ",\"cmd\":", .{})) return null;
    if (!jb.appendJsonString(buf, p, in.cmd)) return null;
    if (!jb.appendf(buf, p, ",\"pid\":{d},\"restarts\":{d},\"cwd\":", .{ in.pid, in.restarts }))
        return null;
    if (!jb.appendJsonString(buf, p, in.cwd)) return null;
    if (!jb.appendf(buf, p, ",\"exe\":", .{})) return null;
    if (!jb.appendJsonString(buf, p, in.exe)) return null;
    if (!jb.appendf(buf, p, ",\"spawned_at\":\"{s}\",\"uptime_s\":{d},\"build\":{{\"release\":", .{
        iso8601(&ts2_buf, in.spawned_at_epoch), in.uptime_s,
    })) return null;
    if (!jb.appendJsonString(buf, p, in.release)) return null;
    if (!jb.appendf(buf, p, "}},\"env\":{{", .{})) return null;
    var env_n: usize = 0;
    for (in.environ) |maybe| {
        if (env_n == max_env_vars) break;
        const entry = std.mem.span(maybe orelse continue);
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (env_n > 0 and !jb.appendf(buf, p, ",", .{})) return null;
        if (!jb.appendJsonString(buf, p, entry[0..eq])) return null;
        if (!jb.appendf(buf, p, ":", .{})) return null;
        const value = if (envRedacted(entry[0..eq])) "<redacted>" else entry[eq + 1 ..];
        if (!jb.appendJsonString(buf, p, value)) return null;
        env_n += 1;
    }
    if (!jb.appendf(buf, p, "}},\"limits\":{{\"nofile\":{d},\"memory_max_bytes\":", .{
        in.limits_nofile,
    })) return null;
    if (in.memory_max_bytes) |m| {
        if (!jb.appendf(buf, p, "{d}}}}},", .{m})) return null;
    } else {
        if (!jb.appendf(buf, p, "null}}}},", .{})) return null;
    }

    // cause (structured) + v1 mirror
    if (!jb.appendf(buf, p, "\"cause\":{{\"kind\":\"{s}\",\"exit_code\":", .{in.cause.kind}))
        return null;
    if (in.cause.exit_code) |c| {
        if (!jb.appendf(buf, p, "{d},", .{c})) return null;
    } else if (!jb.appendf(buf, p, "null,", .{})) return null;
    if (in.cause.sig_num) |sn| {
        if (!jb.appendf(buf, p, "\"signal\":{{\"num\":{d},\"name\":\"{s}\"}},", .{
            sn, in.cause.sig_name,
        })) return null;
    } else if (!jb.appendf(buf, p, "\"signal\":null,", .{})) return null;
    if (!jb.appendf(buf, p, "\"core_dumped\":{},\"oom_kill_delta\":{d}}},\"cause_str\":\"{s}\",", .{
        in.cause.core_dumped, in.cause.oom_kill_delta, in.cause_str,
    })) return null;

    // exception + trace
    if (!jb.appendf(buf, p, "\"exception\":{{\"type\":", .{})) return null;
    if (!jb.appendJsonString(buf, p, in.trace.exc_type)) return null;
    if (!jb.appendf(buf, p, ",\"message\":", .{})) return null;
    if (!jb.appendJsonString(buf, p, in.trace.exc_msg)) return null;
    if (!jb.appendf(buf, p, "}},\"trace\":{{\"lang\":\"{s}\",\"frames\":[", .{in.trace.lang}))
        return null;
    for (in.trace.frames, 0..) |f, i| {
        if (i > 0 and !jb.appendf(buf, p, ",", .{})) return null;
        if (!jb.appendJsonString(buf, p, f)) return null;
    }
    if (!jb.appendf(buf, p, "],\"raw\":", .{})) return null;
    if (!jb.appendJsonString(buf, p, in.trace.raw)) return null;

    // logs_tail: objects with wall timestamp, stream, errorish flag
    if (!jb.appendf(buf, p, "}},\"logs_tail\":[", .{})) return null;
    for (in.logs_tail, 0..) |l, i| {
        if (i > 0 and !jb.appendf(buf, p, ",", .{})) return null;
        var lt_buf: [24]u8 = undefined;
        const stream: []const u8 = if (l.flags & ring.flag_stderr != 0) "E" else "O";
        if (!jb.appendf(buf, p, "{{\"t\":\"{s}\",\"s\":\"{s}\",\"err\":{},\"line\":", .{
            iso8601Ms(&lt_buf, l.t_ms), stream, summarize.errorish(l.text),
        })) return null;
        if (!jb.appendJsonString(buf, p, l.text)) return null;
        if (!jb.appendf(buf, p, "}}", .{})) return null;
    }

    // stats + siblings + verdict
    if (!jb.appendf(buf, p, "],\"stats_timeline\":[", .{})) return null;
    for (in.stats, 0..) |s, i| {
        if (i > 0 and !jb.appendf(buf, p, ",", .{})) return null;
        const dt_s = (in.now_ms -| s.t_ms) / 1000;
        if (!jb.appendf(buf, p, "{{\"t\":\"-{d}s\",\"rss_mb\":{d},\"cpu_pct\":{d}}}", .{
            dt_s, s.rss_kb / 1024, s.cpu_pct,
        })) return null;
    }
    if (!jb.appendf(buf, p, "],\"siblings\":[", .{})) return null;
    for (in.siblings, 0..) |sib, i| {
        if (i > 0 and !jb.appendf(buf, p, ",", .{})) return null;
        if (!jb.appendf(buf, p, "{{\"name\":", .{})) return null;
        if (!jb.appendJsonString(buf, p, sib.name)) return null;
        if (!jb.appendf(buf, p, ",\"state\":\"{s}\",\"uptime_s\":{d},\"restarts\":{d}}}", .{
            sib.state, sib.uptime_s, sib.restarts,
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

test "envRedacted heuristics" {
    try std.testing.expect(envRedacted("DATABASE_PASSWORD"));
    try std.testing.expect(envRedacted("api_key"));
    try std.testing.expect(envRedacted("GITHUB_TOKEN"));
    try std.testing.expect(envRedacted("AWS_SECRET_ACCESS_KEY"));
    try std.testing.expect(!envRedacted("PORT"));
    try std.testing.expect(!envRedacted("GOMAXPROCS"));
}

test "bundle golden output locks schema v2" {
    const frames = [_][]const u8{ "main.crash main.go:10", "main.main main.go:4" };
    const logs = [_]LogLine{
        .{ .text = "listening on :8080", .flags = 0, .t_ms = 1_784_328_420_500 },
        .{ .text = "panic: nil deref", .flags = ring.flag_stderr, .t_ms = 1_784_328_422_881 },
    };
    const stats = [_]sampler.Sample{
        .{ .t_ms = 40_000, .rss_kb = 831_488, .cpu_pct = 97 },
    };
    const environ = [_:null]?[*:0]const u8{ "PORT=8080", "DB_PASSWORD=hunter2" };
    const siblings = [_]Sibling{
        .{ .name = "worker", .state = "running", .uptime_s = 3600, .restarts = 0 },
    };
    var buf: [8192]u8 = undefined;
    const json = serialize(&buf, .{
        .ts_epoch = 1_784_328_423,
        .name = "api",
        .cmd = "./api --port 8080",
        .pid = 42,
        .restarts = 3,
        .cwd = "/app",
        .exe = "/app/api",
        .spawned_at_epoch = 1_784_328_376,
        .uptime_s = 47,
        .release = "api@1.4.2",
        .environ = &environ,
        .limits_nofile = 1024,
        .memory_max_bytes = 536_870_912,
        .cause = .{
            .kind = "signal",
            .sig_num = 11,
            .sig_name = "SIGSEGV",
            .core_dumped = true,
        },
        .cause_str = "signal:SIGSEGV",
        .trace = .{
            .lang = "go",
            .frames = &frames,
            .raw = "panic: nil deref",
            .exc_type = "runtime error",
            .exc_msg = "nil deref",
        },
        .logs_tail = &logs,
        .stats = &stats,
        .now_ms = 100_000,
        .siblings = &siblings,
        .verdict = "go panic in main.crash",
    }).?;
    const expected =
        "{\"v\":2,\"ts\":\"2026-07-17T22:47:03Z\"," ++
        "\"process\":{\"name\":\"api\",\"cmd\":\"./api --port 8080\",\"pid\":42,\"restarts\":3," ++
        "\"cwd\":\"/app\",\"exe\":\"/app/api\",\"spawned_at\":\"2026-07-17T22:46:16Z\",\"uptime_s\":47," ++
        "\"build\":{\"release\":\"api@1.4.2\"}," ++
        "\"env\":{\"PORT\":\"8080\",\"DB_PASSWORD\":\"<redacted>\"}," ++
        "\"limits\":{\"nofile\":1024,\"memory_max_bytes\":536870912}}," ++
        "\"cause\":{\"kind\":\"signal\",\"exit_code\":null,\"signal\":{\"num\":11,\"name\":\"SIGSEGV\"}," ++
        "\"core_dumped\":true,\"oom_kill_delta\":0},\"cause_str\":\"signal:SIGSEGV\"," ++
        "\"exception\":{\"type\":\"runtime error\",\"message\":\"nil deref\"}," ++
        "\"trace\":{\"lang\":\"go\",\"frames\":[\"main.crash main.go:10\",\"main.main main.go:4\"]," ++
        "\"raw\":\"panic: nil deref\"}," ++
        "\"logs_tail\":[" ++
        "{\"t\":\"2026-07-17T22:47:00.500Z\",\"s\":\"O\",\"err\":false,\"line\":\"listening on :8080\"}," ++
        "{\"t\":\"2026-07-17T22:47:02.881Z\",\"s\":\"E\",\"err\":true,\"line\":\"panic: nil deref\"}]," ++
        "\"stats_timeline\":[{\"t\":\"-60s\",\"rss_mb\":812,\"cpu_pct\":97}]," ++
        "\"siblings\":[{\"name\":\"worker\",\"state\":\"running\",\"uptime_s\":3600,\"restarts\":0}]," ++
        "\"verdict\":\"go panic in main.crash\"}";
    try std.testing.expectEqualStrings(expected, json);
}
