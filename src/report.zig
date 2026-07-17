//! State snapshot: the supervisor serializes worker state to
//! `<state-dir>/state.json` (tmp + rename); `mandor report` reads and
//! renders it. Serialization is pure and unit-tested; file IO is Linux-only.

const std = @import("std");
const builtin = @import("builtin");
const spawner = @import("spawner.zig");
const sampler = @import("sampler.zig");

pub const state_version = 1;
pub const default_state_dir = "/var/lib/mandor";
const state_buf_cap = 256 * 1024;

// ------------------------------------------------------- serialization

const jb = @import("jsonbuf.zig");
const appendf = jb.appendf;
const appendJsonString = jb.appendJsonString;

/// Serialize supervisor state as JSON into `buf`. Returns the written slice,
/// or null if the buffer is too small (never panics).
pub fn serialize(buf: []u8, workers: []const spawner.Worker, now_ms: u64) ?[]const u8 {
    var pos: usize = 0;
    const p = &pos;
    if (!appendf(buf, p, "{{\"v\":{d},\"ts_ms\":{d},\"workers\":[", .{ state_version, now_ms }))
        return null;
    for (workers, 0..) |*w, i| {
        if (i > 0 and !appendf(buf, p, ",", .{})) return null;
        if (!appendf(buf, p, "{{\"name\":", .{})) return null;
        if (!appendJsonString(buf, p, w.nameSlice())) return null;
        if (!appendf(buf, p, ",\"cmd\":", .{})) return null;
        if (!appendJsonString(buf, p, w.cmd)) return null;
        const state: []const u8 = switch (w.status) {
            .not_started => "not-started",
            .running => "running",
            .exited => "exited",
            .signaled => "signaled",
        };
        const code: u32 = switch (w.status) {
            .exited => |c| c,
            .signaled => |s| s,
            else => 0,
        };
        if (!appendf(buf, p, ",\"state\":\"{s}\",\"code\":{d},\"pid\":{d},\"restarts\":{d},\"stats\":[", .{
            state, code, w.pid, w.restarts,
        })) return null;
        for (0..w.stats.len) |si| {
            const s = w.stats.at(si);
            if (si > 0 and !appendf(buf, p, ",", .{})) return null;
            if (!appendf(buf, p, "{{\"t_ms\":{d},\"rss_kb\":{d},\"cpu_pct\":{d},\"fds\":{d},\"threads\":{d}}}", .{
                s.t_ms, s.rss_kb, s.cpu_pct, s.fds, s.threads,
            })) return null;
        }
        if (!appendf(buf, p, "]}}", .{})) return null;
    }
    if (!appendf(buf, p, "]}}", .{})) return null;
    return buf[0..pos];
}

// ------------------------------------------------------- report parsing
//
// The state file is our own machine-written format, so the reader is a
// known-shape scanner: ~100 lines instead of std.json's tables (which blew
// the 500 KB binary budget).

fn scanU64(chunk: []const u8, comptime key: []const u8) ?u64 {
    const pat = "\"" ++ key ++ "\":";
    const i = std.mem.indexOf(u8, chunk, pat) orelse return null;
    var j = i + pat.len;
    var v: u64 = 0;
    var any = false;
    while (j < chunk.len and chunk[j] >= '0' and chunk[j] <= '9') : (j += 1) {
        v = v *| 10 +| (chunk[j] - '0');
        any = true;
    }
    return if (any) v else null;
}

fn scanStr(chunk: []const u8, comptime key: []const u8) ?[]const u8 {
    const pat = "\"" ++ key ++ "\":\"";
    const i = std.mem.indexOf(u8, chunk, pat) orelse return null;
    const start = i + pat.len;
    var j = start;
    while (j < chunk.len) : (j += 1) {
        if (chunk[j] == '\\') {
            j += 1;
            continue;
        }
        if (chunk[j] == '"') return chunk[start..j];
    }
    return null;
}

/// Render the human report straight from the state JSON. Returns null if the
/// text is not a v1 state file.
pub fn formatHuman(buf: []u8, text: []const u8, now_ms: u64) ?[]const u8 {
    if (scanU64(text, "v") != state_version) return null;
    const ts = scanU64(text, "ts_ms") orelse return null;

    var pos: usize = 0;
    const p = &pos;
    const worker_pat = "{\"name\":";
    var count: usize = 0;
    var it: usize = 0;
    while (std.mem.indexOfPos(u8, text, it, worker_pat)) |i| : (it = i + worker_pat.len) {
        count += 1;
    }
    const age_s = (now_ms -| ts) / 1000;
    _ = appendf(buf, p, "mandor report — {d} worker(s), state from {d}s ago\n\n", .{ count, age_s });
    _ = appendf(buf, p, "{s:<16} {s:<12} {s:>6} {s:>8} {s:>6} {s:>10} {s:>5} {s:>7}\n", .{
        "NAME", "STATE", "PID", "RESTARTS", "CPU%", "RSS", "FDS", "THREADS",
    });

    var start = std.mem.indexOf(u8, text, worker_pat) orelse return buf[0..pos];
    while (true) {
        const next = std.mem.indexOfPos(u8, text, start + worker_pat.len, worker_pat);
        const chunk = text[start .. next orelse text.len];

        const name = scanStr(chunk, "name") orelse "?";
        const state = scanStr(chunk, "state") orelse "?";
        const code = scanU64(chunk, "code") orelse 0;
        const pid = scanU64(chunk, "pid") orelse 0;
        const restarts = scanU64(chunk, "restarts") orelse 0;

        var state_txt_buf: [24]u8 = undefined;
        const state_txt = if (std.mem.eql(u8, state, "exited") or
            std.mem.eql(u8, state, "signaled"))
            std.fmt.bufPrint(&state_txt_buf, "{s}({d})", .{ state, code }) catch state
        else
            state;
        var pid_buf: [12]u8 = undefined;
        const pid_txt = if (pid > 0)
            std.fmt.bufPrint(&pid_buf, "{d}", .{pid}) catch "-"
        else
            "-";

        // newest sample = last t_ms record inside this worker's chunk
        const last_sample = if (std.mem.lastIndexOf(u8, chunk, "\"t_ms\":")) |si|
            chunk[si..]
        else
            null;
        if (last_sample != null and std.mem.eql(u8, state, "running")) {
            const s = last_sample.?;
            const rss_kb = scanU64(s, "rss_kb") orelse 0;
            const cpu = scanU64(s, "cpu_pct") orelse 0;
            const fds = scanU64(s, "fds") orelse 0;
            const threads = scanU64(s, "threads") orelse 0;
            var rss_buf: [16]u8 = undefined;
            const rss_txt = std.fmt.bufPrint(&rss_buf, "{d}.{d}MB", .{
                rss_kb / 1024, (rss_kb % 1024) * 10 / 1024,
            }) catch "?";
            _ = appendf(buf, p, "{s:<16} {s:<12} {s:>6} {d:>8} {d:>6} {s:>10} {d:>5} {d:>7}\n", .{
                name, state_txt, pid_txt, restarts, cpu, rss_txt, fds, threads,
            });
        } else {
            _ = appendf(buf, p, "{s:<16} {s:<12} {s:>6} {d:>8} {s:>6} {s:>10} {s:>5} {s:>7}\n", .{
                name, state_txt, pid_txt, restarts, "-", "-", "-", "-",
            });
        }
        start = next orelse break;
    }
    return buf[0..pos];
}

// ------------------------------------------------------- Linux file IO

const linux = std.os.linux;
const posix = std.posix;

var state_buf: [state_buf_cap]u8 = undefined;
var warned_unwritable = false;

/// Serialize and atomically write state.json. Never fails loudly more than
/// once; the supervisor keeps running regardless.
pub fn writeState(state_dir: []const u8, workers: []const spawner.Worker, now_ms: u64) void {
    const json = serialize(&state_buf, workers, now_ms) orelse return;

    var path_buf: [512]u8 = undefined;
    var tmp_buf: [512]u8 = undefined;
    const final_path = std.fmt.bufPrintZ(&path_buf, "{s}/state.json", .{state_dir}) catch return;
    const tmp_path = std.fmt.bufPrintZ(&tmp_buf, "{s}/state.json.tmp", .{state_dir}) catch return;

    var dir_buf: [512]u8 = undefined;
    const dir_z = std.fmt.bufPrintZ(&dir_buf, "{s}", .{state_dir}) catch return;
    _ = linux.mkdirat(linux.AT.FDCWD, dir_z.ptr, 0o755); // EEXIST is fine

    const rc = linux.openat(linux.AT.FDCWD, tmp_path.ptr, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
    }, 0o644);
    if (posix.errno(rc) != .SUCCESS) {
        if (!warned_unwritable) {
            warned_unwritable = true;
            std.debug.print("[mandor] state dir {s} not writable; report disabled\n", .{state_dir});
        }
        return;
    }
    const fd: i32 = @intCast(rc);
    var off: usize = 0;
    while (off < json.len) {
        const n = linux.write(fd, json.ptr + off, json.len - off);
        if (posix.errno(n) != .SUCCESS) break;
        off += n;
    }
    _ = linux.close(fd);
    if (off == json.len) {
        _ = linux.rename(tmp_path.ptr, final_path.ptr);
    }
}

pub const ReadError = error{Unreadable};

/// Read state.json for the report subcommand.
pub fn readState(state_dir: []const u8, buf: []u8) ReadError![]const u8 {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/state.json", .{state_dir}) catch
        return error.Unreadable;
    const rc = linux.openat(linux.AT.FDCWD, path.ptr, .{}, 0);
    if (posix.errno(rc) != .SUCCESS) return error.Unreadable;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const n = linux.read(fd, buf.ptr, buf.len);
    if (posix.errno(n) != .SUCCESS) return error.Unreadable;
    return buf[0..n];
}

// ---------------------------------------------------------------- tests

fn testWorker(name: []const u8, cmd: []const u8) spawner.Worker {
    var w: spawner.Worker = .{};
    @memcpy(w.name[0..name.len], name);
    w.name_len = @intCast(name.len);
    w.cmd = cmd;
    return w;
}

test "serialize golden output" {
    var workers: [2]spawner.Worker = .{
        testWorker("api", "./api --port 8080"),
        testWorker("worker", "./worker \"x\""),
    };
    workers[0].pid = 42;
    workers[0].status = .running;
    workers[0].restarts = 3;
    workers[0].stats.push(.{ .t_ms = 1000, .rss_kb = 2048, .cpu_pct = 97, .fds = 12, .threads = 8 });
    workers[1].status = .{ .exited = 1 };

    var buf: [4096]u8 = undefined;
    const json = serialize(&buf, &workers, 5000).?;
    const expected =
        "{\"v\":1,\"ts_ms\":5000,\"workers\":[" ++
        "{\"name\":\"api\",\"cmd\":\"./api --port 8080\",\"state\":\"running\",\"code\":0," ++
        "\"pid\":42,\"restarts\":3,\"stats\":[" ++
        "{\"t_ms\":1000,\"rss_kb\":2048,\"cpu_pct\":97,\"fds\":12,\"threads\":8}]}," ++
        "{\"name\":\"worker\",\"cmd\":\"./worker \\\"x\\\"\",\"state\":\"exited\",\"code\":1," ++
        "\"pid\":0,\"restarts\":0,\"stats\":[]}]}";
    try std.testing.expectEqualStrings(expected, json);
}

test "serialize too-small buffer returns null, no panic" {
    var workers: [1]spawner.Worker = .{testWorker("api", "./api")};
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), serialize(&buf, &workers, 0));
}

test "serialize + human format round trip" {
    var workers: [2]spawner.Worker = .{
        testWorker("api", "./api"),
        testWorker("worker", "./worker"),
    };
    workers[0].pid = 42;
    workers[0].status = .running;
    workers[0].stats.push(.{ .t_ms = 500, .rss_kb = 100, .cpu_pct = 1, .fds = 3, .threads = 1 });
    workers[0].stats.push(.{ .t_ms = 1000, .rss_kb = 831_488, .cpu_pct = 97, .fds = 12, .threads = 8 });
    workers[1].status = .{ .exited = 1 };

    var jbuf: [4096]u8 = undefined;
    const json = serialize(&jbuf, &workers, 5000).?;

    var hbuf: [4096]u8 = undefined;
    const human = formatHuman(&hbuf, json, 8000).?;
    try std.testing.expect(std.mem.indexOf(u8, human, "2 worker(s)") != null);
    try std.testing.expect(std.mem.indexOf(u8, human, "state from 3s ago") != null);
    try std.testing.expect(std.mem.indexOf(u8, human, "api") != null);
    // newest sample wins: 812.0MB, cpu 97
    try std.testing.expect(std.mem.indexOf(u8, human, "812.0MB") != null);
    try std.testing.expect(std.mem.indexOf(u8, human, "97") != null);
    try std.testing.expect(std.mem.indexOf(u8, human, "exited(1)") != null);

    try std.testing.expectEqual(@as(?[]const u8, null), formatHuman(&hbuf, "{\"v\":99}", 0));
}
