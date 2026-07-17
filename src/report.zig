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

fn appendf(buf: []u8, pos: *usize, comptime fmt: []const u8, args: anytype) bool {
    const out = std.fmt.bufPrint(buf[pos.*..], fmt, args) catch return false;
    pos.* += out.len;
    return true;
}

fn appendJsonString(buf: []u8, pos: *usize, s: []const u8) bool {
    if (!appendf(buf, pos, "\"", .{})) return false;
    for (s) |c| {
        const ok = switch (c) {
            '"' => appendf(buf, pos, "\\\"", .{}),
            '\\' => appendf(buf, pos, "\\\\", .{}),
            0x00...0x1f => appendf(buf, pos, "\\u{x:0>4}", .{c}),
            else => appendf(buf, pos, "{c}", .{c}),
        };
        if (!ok) return false;
    }
    return appendf(buf, pos, "\"", .{});
}

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

pub const StateWorkerSample = struct {
    t_ms: u64,
    rss_kb: u64,
    cpu_pct: u16,
    fds: u16,
    threads: u16,
};

pub const StateWorker = struct {
    name: []const u8,
    cmd: []const u8,
    state: []const u8,
    code: u32,
    pid: i64,
    restarts: u64,
    stats: []StateWorkerSample,
};

pub const State = struct {
    v: u32,
    ts_ms: u64,
    workers: []StateWorker,
};

pub fn parseState(arena: std.mem.Allocator, text: []const u8) ?State {
    const parsed = std.json.parseFromSliceLeaky(State, arena, text, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    return parsed;
}

/// Render the human report into buf.
pub fn formatHuman(buf: []u8, state: State, now_ms: u64) []const u8 {
    var pos: usize = 0;
    const p = &pos;
    const age_s = (now_ms -| state.ts_ms) / 1000;
    _ = appendf(buf, p, "mandor report — {d} worker(s), state from {d}s ago\n\n", .{
        state.workers.len, age_s,
    });
    _ = appendf(buf, p, "{s:<16} {s:<12} {s:>6} {s:>8} {s:>6} {s:>10} {s:>5} {s:>7}\n", .{
        "NAME", "STATE", "PID", "RESTARTS", "CPU%", "RSS", "FDS", "THREADS",
    });
    for (state.workers) |w| {
        var state_txt_buf: [24]u8 = undefined;
        const state_txt = if (std.mem.eql(u8, w.state, "exited") or
            std.mem.eql(u8, w.state, "signaled"))
            std.fmt.bufPrint(&state_txt_buf, "{s}({d})", .{ w.state, w.code }) catch w.state
        else
            w.state;
        var pid_buf: [12]u8 = undefined;
        const pid_txt = if (w.pid > 0)
            std.fmt.bufPrint(&pid_buf, "{d}", .{@as(u64, @intCast(w.pid))}) catch "-"
        else
            "-";
        if (w.stats.len > 0 and std.mem.eql(u8, w.state, "running")) {
            const s = w.stats[w.stats.len - 1];
            var rss_buf: [16]u8 = undefined;
            const rss_txt = std.fmt.bufPrint(&rss_buf, "{d}.{d}MB", .{
                s.rss_kb / 1024, (s.rss_kb % 1024) * 10 / 1024,
            }) catch "?";
            _ = appendf(buf, p, "{s:<16} {s:<12} {s:>6} {d:>8} {d:>6} {s:>10} {d:>5} {d:>7}\n", .{
                w.name, state_txt, pid_txt, w.restarts, s.cpu_pct, rss_txt, s.fds, s.threads,
            });
        } else {
            _ = appendf(buf, p, "{s:<16} {s:<12} {s:>6} {d:>8} {s:>6} {s:>10} {s:>5} {s:>7}\n", .{
                w.name, state_txt, pid_txt, w.restarts, "-", "-", "-", "-",
            });
        }
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

test "parse + human format round trip" {
    var workers: [1]spawner.Worker = .{testWorker("api", "./api")};
    workers[0].pid = 42;
    workers[0].status = .running;
    workers[0].stats.push(.{ .t_ms = 1000, .rss_kb = 831_488, .cpu_pct = 97, .fds = 12, .threads = 8 });

    var jbuf: [4096]u8 = undefined;
    const json = serialize(&jbuf, &workers, 5000).?;

    var arena_mem: [65536]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_mem);
    const state = parseState(fba.allocator(), json).?;
    try std.testing.expectEqual(@as(u32, 1), state.v);
    try std.testing.expectEqualStrings("api", state.workers[0].name);

    var hbuf: [4096]u8 = undefined;
    const human = formatHuman(&hbuf, state, 8000);
    try std.testing.expect(std.mem.indexOf(u8, human, "state from 3s ago") != null);
    try std.testing.expect(std.mem.indexOf(u8, human, "api") != null);
    try std.testing.expect(std.mem.indexOf(u8, human, "812.0MB") != null);
}
