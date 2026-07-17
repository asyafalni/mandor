//! Worker table and fork/exec. Raw std.os.linux syscalls — no libc, no
//! allocations: each worker owns fixed buffers sized at comptime.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const cli = @import("cli.zig");
const capture = @import("capture.zig");
const ring = @import("ring.zig");
const sampler = @import("sampler.zig");
const detector = @import("detector.zig");

pub const max_args = 64;
pub const name_cap = 32;
pub const log_ring_capacity = 256 * 1024;
const default_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";

pub const Status = union(enum) {
    not_started,
    running,
    exited: u8,
    signaled: u8,
};

pub const Worker = struct {
    name: [name_cap]u8 = undefined,
    name_len: u8 = 0,
    cmd: []const u8 = "", // original command string (argv memory, lives forever)
    cmd_buf: [4096]u8 = undefined,
    argv: [max_args + 1]?[*:0]const u8 = undefined, // null-terminated for execve
    argc: u8 = 0,
    pid: i32 = 0, // 0 = not running
    status: Status = .not_started,
    core_dumped: bool = false,
    restarts: u32 = 0,
    cur_delay_ms: u64 = 0,
    last_start_ms: u64 = 0,
    next_restart_ms: u64 = 0, // 0 = no restart scheduled
    final_code: u8 = 0,
    done: bool = false, // permanently finished; no restart coming

    // v0.2: output capture. Read ends of the worker's stdout/stderr pipes
    // (-1 = closed), per-stream line assemblers, and the log ring that
    // survives restarts.
    out_r: i32 = -1,
    err_r: i32 = -1,
    asm_out: capture.Assembler = .{},
    asm_err: capture.Assembler = .{},
    log: ring.Ring(log_ring_capacity) = .{},
    stats: sampler.Window = .{},
    det: detector.State = .{},

    pub fn nameSlice(w: *const Worker) []const u8 {
        return w.name[0..w.name_len];
    }
};

/// Field-by-field reset. Deliberately NOT `w.* = .{}`: that would materialize
/// a ~270 KB comptime Worker constant (ring buffer included) in .rodata.
fn resetWorker(w: *Worker) void {
    w.name_len = 0;
    w.cmd = "";
    w.argc = 0;
    w.pid = 0;
    w.status = .not_started;
    w.core_dumped = false;
    w.restarts = 0;
    w.cur_delay_ms = 0;
    w.last_start_ms = 0;
    w.next_restart_ms = 0;
    w.final_code = 0;
    w.done = false;
    w.out_r = -1;
    w.err_r = -1;
    w.asm_out.len = 0;
    w.asm_out.continued = false;
    w.asm_err.len = 0;
    w.asm_err.continued = false;
    w.log.head = 0;
    w.log.used = 0;
    w.log.records = 0;
    w.stats.next = 0;
    w.stats.len = 0;
    w.stats.prev_ticks = 0;
    w.stats.prev_t_ms = 0;
    w.det = .{};
}

pub const InitError = error{BadCommand};

/// Tokenize each command into its worker's fixed buffers and derive log names.
pub fn initWorkers(workers: []Worker, commands: []const []const u8) InitError!void {
    for (commands, 0..) |cmd, idx| {
        const w = &workers[idx];
        resetWorker(w);
        w.cmd = cmd;
        var toks: [max_args][]const u8 = undefined;
        const argv = cli.tokenize(cmd, &w.cmd_buf, &toks) catch return error.BadCommand;
        for (argv, 0..) |t, i| w.argv[i] = @ptrCast(t.ptr);
        w.argv[argv.len] = null;
        w.argc = @intCast(argv.len);
        setName(w, argv[0], workers[0..idx]);
    }
}

fn setName(w: *Worker, argv0: []const u8, prior: []const Worker) void {
    var base = argv0;
    if (std.mem.lastIndexOfScalar(u8, argv0, '/')) |i| base = argv0[i + 1 ..];
    if (base.len > name_cap - 4) base = base[0 .. name_cap - 4]; // room for "-NN"
    var dupes: usize = 0;
    for (prior) |*p| {
        const pn = p.nameSlice();
        if (std.mem.eql(u8, pn, base) or
            (pn.len > base.len + 1 and std.mem.startsWith(u8, pn, base) and pn[base.len] == '-'))
        {
            dupes += 1;
        }
    }
    if (dupes == 0) {
        @memcpy(w.name[0..base.len], base);
        w.name_len = @intCast(base.len);
    } else {
        var fbs: []u8 = w.name[0..];
        @memcpy(fbs[0..base.len], base);
        const suffix = std.fmt.bufPrint(fbs[base.len..], "-{d}", .{dupes + 1}) catch
            fbs[base.len..base.len];
        w.name_len = @intCast(base.len + suffix.len);
    }
}

/// Look up NAME= in the environ block.
pub fn findEnv(environ: [:null]const ?[*:0]const u8, name: []const u8) ?[]const u8 {
    for (environ) |maybe| {
        const entry = std.mem.span(maybe orelse continue);
        if (entry.len > name.len and entry[name.len] == '=' and
            std.mem.startsWith(u8, entry, name))
        {
            return entry[name.len + 1 ..];
        }
    }
    return null;
}

/// PATH value from the environ block, or a sane container default.
pub fn findPath(environ: [:null]const ?[*:0]const u8) []const u8 {
    return findEnv(environ, "PATH") orelse default_path;
}

pub const SpawnError = error{ForkFailed};

pub fn spawn(
    w: *Worker,
    envp: [*:null]const ?[*:0]const u8,
    path_env: []const u8,
    now_ms: u64,
) SpawnError!void {
    const out_p = capture.makePipe();
    const err_p = capture.makePipe();
    const rc = linux.fork();
    if (posix.errno(rc) != .SUCCESS) {
        closePair(out_p);
        closePair(err_p);
        return error.ForkFailed;
    }
    if (rc == 0) {
        // Child: own process group so signals reach shell-spawned
        // grandchildren too (dumb-init behavior), then route stdout/stderr
        // into the pipes. dup2 clears CLOEXEC on fds 1/2; the original pipe
        // fds close automatically at execve.
        _ = linux.setpgid(0, 0);
        if (out_p) |p| _ = linux.dup2(p.w, 1);
        if (err_p) |p| _ = linux.dup2(p.w, 2);
        execChild(w, envp, path_env);
    }
    // Parent sets it too — whichever side wins the race, the group exists
    // before we ever signal it.
    _ = linux.setpgid(@intCast(rc), @intCast(rc));
    if (out_p) |p| {
        _ = linux.close(p.w);
        w.out_r = p.r;
    }
    if (err_p) |p| {
        _ = linux.close(p.w);
        w.err_r = p.r;
    }
    w.pid = @intCast(rc);
    w.status = .running;
    w.last_start_ms = now_ms;
    w.next_restart_ms = 0;
    // New pid: CPU tick baseline restarts from zero (history stays).
    w.stats.prev_ticks = 0;
    w.stats.prev_t_ms = 0;
}

fn closePair(pair: ?capture.PipePair) void {
    if (pair) |p| {
        _ = linux.close(p.r);
        _ = linux.close(p.w);
    }
}

/// Child side: restore signal mask, exec (with PATH search when argv0 has no
/// slash). On total failure: message to stderr, _exit(127).
fn execChild(
    w: *const Worker,
    envp: [*:null]const ?[*:0]const u8,
    path_env: []const u8,
) noreturn {
    const empty = posix.sigemptyset();
    posix.sigprocmask(posix.SIG.SETMASK, &empty, null);

    const argv: [*:null]const ?[*:0]const u8 = @ptrCast(&w.argv);
    const argv0z = w.argv[0].?;
    const argv0 = std.mem.span(argv0z);

    if (std.mem.indexOfScalar(u8, argv0, '/') != null) {
        _ = linux.execve(argv0z, argv, envp);
    } else {
        var cand: [4200]u8 = undefined;
        var it = std.mem.splitScalar(u8, path_env, ':');
        while (it.next()) |dir| {
            if (dir.len == 0 or dir.len + 1 + argv0.len + 1 > cand.len) continue;
            @memcpy(cand[0..dir.len], dir);
            cand[dir.len] = '/';
            @memcpy(cand[dir.len + 1 ..][0..argv0.len], argv0);
            cand[dir.len + 1 + argv0.len] = 0;
            _ = linux.execve(@ptrCast(&cand), argv, envp);
        }
    }
    const pre = "[mandor] exec failed: ";
    _ = linux.write(2, pre, pre.len);
    _ = linux.write(2, argv0.ptr, argv0.len);
    _ = linux.write(2, "\n", 1);
    linux.exit(127);
}

// ---------------------------------------------------------------- tests

test "initWorkers derives names and dedups" {
    var workers: [3]Worker = undefined;
    try initWorkers(workers[0..3], &.{ "./bin/api --port 8080", "api", "/usr/bin/api -x" });
    try std.testing.expectEqualStrings("api", workers[0].nameSlice());
    try std.testing.expectEqualStrings("api-2", workers[1].nameSlice());
    try std.testing.expectEqualStrings("api-3", workers[2].nameSlice());
    try std.testing.expectEqual(@as(u8, 3), workers[0].argc);
    try std.testing.expectEqual(@as(?[*:0]const u8, null), workers[0].argv[3]);
}

test "findPath falls back to default" {
    const empty_env = [_:null]?[*:0]const u8{};
    try std.testing.expectEqualStrings(default_path, findPath(&empty_env));
}
