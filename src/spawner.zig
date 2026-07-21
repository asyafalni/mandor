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
const elf = @import("elf.zig");
const caps = @import("caps.zig");

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
    exe_buf: [256]u8 = undefined,
    exe_len: u16 = 0,
    spawned_at_epoch: i64 = 0,
    build_id_buf: [64]u8 = undefined,
    build_id_len: u8 = 0,
    ready: bool = false,
    ready_r: i32 = -1, // read end of the readiness pipe (-1 = none/closed)

    // Health checks (v0.6): probe command + tracking of the running probe.
    has_health: bool = false,
    health_cmd_buf: [1024]u8 = undefined,
    health_argv: [17]?[*:0]const u8 = undefined,
    health_pid: i32 = 0,
    health_started_ms: u64 = 0,
    next_health_ms: u64 = 0,
    health_fails: u8 = 0,
    health_done: bool = false, // set by reaper when a probe was collected
    health_ok: bool = false,
    health_ever_ok: bool = false, // start-period grace ends at first success

    // Per-worker extras (v0.8): env additions, working dir, oneshot marker.
    extra_env_buf: [1024]u8 = undefined,
    extra_env: [17]?[*:0]const u8 = undefined,
    extra_env_n: u8 = 0,
    extra_env_used: u16 = 0,
    cwd_buf: [256]u8 = undefined,
    cwd_len: u16 = 0, // NUL-terminated in cwd_buf when set
    is_oneshot: bool = false,
    drop_uid: ?u32 = null,
    drop_gid: ?u32 = null,
    /// Capability bits to drop from the bounding set; drop_all_caps drops
    /// every known cap (cap_drop = "all").
    cap_drop_mask: u64 = 0,
    drop_all_caps: bool = false,
    oom_adj: ?i16 = null, // -1000..1000, written to /proc/self/oom_score_adj
    nice_val: ?i8 = null,
    max_rss_kb: ?u64 = null, // planned recycle thresholds
    max_lifetime_ms: ?u64 = null,
    recycling: bool = false, // current death is planned, not a failure
    restart_override: ?cli.RestartPolicy = null,
    essential: bool = false, // leader semantics: its exit stops everything
    /// This worker's last spawn failed outright (fork/exec setup), so it never
    /// ran. Reported as a death so restart policy, `essential`, and `oneshot`
    /// all apply — only the log wording differs.
    spawn_failed: bool = false,
    color: u8 = 0, // ANSI 31..36 cycle for TTY prefixes

    // pre_stop drain hook (v0.13): runs before TERM on graceful shutdown.
    has_prestop: bool = false,
    prestop_cmd_buf: [512]u8 = undefined,
    prestop_argv: [9]?[*:0]const u8 = undefined,
    prestop_pid: i32 = 0,
    prestop_done: bool = false,
    restarts: u32 = 0,
    /// Consecutive unclean deaths (reset by clean exit or stable uptime).
    fail_streak: u32 = 0,
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
    w.fail_streak = 0;
    w.cur_delay_ms = 0;
    w.last_start_ms = 0;
    w.next_restart_ms = 0;
    w.final_code = 0;
    w.done = false;
    w.spawn_failed = false;
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
    w.exe_len = 0;
    w.spawned_at_epoch = 0;
    w.build_id_len = 0;
    w.ready = false;
    w.ready_r = -1;
    w.has_health = false;
    w.health_pid = 0;
    w.health_started_ms = 0;
    w.next_health_ms = 0;
    w.health_fails = 0;
    w.health_done = false;
    w.health_ok = false;
    w.health_ever_ok = false;
    w.extra_env_n = 0;
    w.extra_env_used = 0;
    w.cwd_len = 0;
    w.is_oneshot = false;
    w.drop_uid = null;
    w.drop_gid = null;
    w.cap_drop_mask = 0;
    w.drop_all_caps = false;
    w.oom_adj = null;
    w.nice_val = null;
    w.max_rss_kb = null;
    w.max_lifetime_ms = null;
    w.recycling = false;
    w.restart_override = null;
    w.essential = false;
    w.color = 0;
    w.has_prestop = false;
    w.prestop_pid = 0;
    w.prestop_done = false;
}

pub fn setPreStop(w: *Worker, cmd: []const u8) InitError!void {
    var toks: [8][]const u8 = undefined;
    const argv = cli.tokenize(cmd, &w.prestop_cmd_buf, &toks) catch return error.BadCommand;
    for (argv, 0..) |t, i| w.prestop_argv[i] = @ptrCast(t.ptr);
    w.prestop_argv[argv.len] = null;
    w.has_prestop = true;
}

/// Fork/exec the pre_stop drain hook; tracked so the supervisor can TERM
/// the worker only after the hook finishes.
pub fn spawnPreStop(
    w: *Worker,
    envp: [*:null]const ?[*:0]const u8,
    path_env: []const u8,
) bool {
    const supervisor_pid = linux.getpid();
    const rc = linux.fork();
    if (posix.errno(rc) != .SUCCESS) return false;
    if (rc == 0) {
        _ = linux.prctl(@intFromEnum(linux.PR.SET_PDEATHSIG), @intFromEnum(posix.SIG.KILL), 0, 0, 0);
        if (linux.getppid() != supervisor_pid) linux.exit(1);
        const empty = posix.sigemptyset();
        posix.sigprocmask(posix.SIG.SETMASK, &empty, null);
        execArgv(@ptrCast(&w.prestop_argv), envp, path_env);
    }
    w.prestop_pid = @intCast(rc);
    return true;
}

/// "1000:1000" -> numeric uid/gid privilege drop for this worker.
pub fn setUser(w: *Worker, spec: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, spec, ':') orelse return false;
    w.drop_uid = std.fmt.parseInt(u32, spec[0..colon], 10) catch return false;
    w.drop_gid = std.fmt.parseInt(u32, spec[colon + 1 ..], 10) catch return false;
    return true;
}

/// Comma-separated capability names to drop from the bounding set, or "all".
pub fn setCapDrop(w: *Worker, spec: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(spec, "all")) {
        w.drop_all_caps = true;
        return true;
    }
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " ");
        if (name.len == 0) continue;
        const b = caps.bit(name) orelse return false;
        w.cap_drop_mask |= @as(u64, 1) << b;
    }
    return true;
}

/// Add one KEY=VAL to a worker's environment.
pub fn addEnv(w: *Worker, entry: []const u8) bool {
    if (w.extra_env_n == w.extra_env.len - 1) return false;
    if (w.extra_env_used + entry.len + 1 > w.extra_env_buf.len) return false;
    const start = w.extra_env_used;
    @memcpy(w.extra_env_buf[start..][0..entry.len], entry);
    w.extra_env_buf[start + entry.len] = 0;
    w.extra_env[w.extra_env_n] = @ptrCast(&w.extra_env_buf[start]);
    w.extra_env_n += 1;
    w.extra_env_used += @intCast(entry.len + 1);
    return true;
}

pub fn setCwd(w: *Worker, path: []const u8) bool {
    if (path.len + 1 > w.cwd_buf.len) return false;
    @memcpy(w.cwd_buf[0..path.len], path);
    w.cwd_buf[path.len] = 0;
    w.cwd_len = @intCast(path.len);
    return true;
}

/// Attach a health probe command to a worker (tokenized into fixed storage).
pub fn setHealth(w: *Worker, cmd: []const u8) InitError!void {
    var toks: [16][]const u8 = undefined;
    const argv = cli.tokenize(cmd, &w.health_cmd_buf, &toks) catch return error.BadCommand;
    for (argv, 0..) |t, i| w.health_argv[i] = @ptrCast(t.ptr);
    w.health_argv[argv.len] = null;
    w.has_health = true;
}

/// Fork/exec a health probe: stdio to /dev/null, no process group of its
/// own (worker-group signals must not hit probes). Returns the probe pid.
pub fn spawnCheck(
    w: *Worker,
    envp: [*:null]const ?[*:0]const u8,
    path_env: []const u8,
    now_ms: u64,
) bool {
    const supervisor_pid = linux.getpid();
    const rc = linux.fork();
    if (posix.errno(rc) != .SUCCESS) return false;
    if (rc == 0) {
        // Probes die with the supervisor — hard, they hold no state.
        _ = linux.prctl(@intFromEnum(linux.PR.SET_PDEATHSIG), @intFromEnum(posix.SIG.KILL), 0, 0, 0);
        if (linux.getppid() != supervisor_pid) linux.exit(1);
        const empty = posix.sigemptyset();
        posix.sigprocmask(posix.SIG.SETMASK, &empty, null);
        const null_rc = linux.openat(linux.AT.FDCWD, "/dev/null", .{ .ACCMODE = .WRONLY }, 0);
        if (posix.errno(null_rc) == .SUCCESS) {
            const null_fd: i32 = @intCast(null_rc);
            _ = linux.dup2(null_fd, 1);
            _ = linux.dup2(null_fd, 2);
        }
        execArgv(@ptrCast(&w.health_argv), envp, path_env);
    }
    w.health_pid = @intCast(rc);
    w.health_started_ms = now_ms;
    return true;
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
        w.color = @intCast(31 + (idx % 6)); // red..cyan cycle
    }
}

// Global env additions (env_file), applied to every worker.
var g_env_buf: [2048]u8 = undefined;
var g_env: [32]?[*:0]const u8 = undefined;
var g_env_n: u8 = 0;
var g_env_used: u16 = 0;

pub fn addGlobalEnv(entry: []const u8) bool {
    if (g_env_n == g_env.len or g_env_used + entry.len + 1 > g_env_buf.len) return false;
    @memcpy(g_env_buf[g_env_used..][0..entry.len], entry);
    g_env_buf[g_env_used + entry.len] = 0;
    g_env[g_env_n] = @ptrCast(&g_env_buf[g_env_used]);
    g_env_n += 1;
    g_env_used += @intCast(entry.len + 1);
    return true;
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
    // The name is a basename, so it can hold any byte a filename can. JSON
    // sinks escape it, but the Prometheus exposition format has no escaping
    // for label values — a quote or backslash would silently corrupt every
    // scrape. Neutralize once here rather than at each sink.
    for (w.name[0..w.name_len]) |*c| {
        if (c.* == '"' or c.* == '\\' or c.* < 0x20) c.* = '_';
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
    ready_fd: ?u8,
) SpawnError!void {
    const out_p = capture.makePipe();
    const err_p = capture.makePipe();
    const ready_p = if (ready_fd != null) capture.makePipe() else null;
    // Merge parent env + per-worker extras BEFORE fork (no alloc, static
    // scratch — spawns are serialized in the single-threaded supervisor).
    const child_envp: [*:null]const ?[*:0]const u8 = if (w.extra_env_n > 0 or g_env_n > 0)
        mergeEnv(envp, w)
    else
        envp;
    const supervisor_pid = linux.getpid(); // must be pre-fork for the guard
    const rc = linux.fork();
    if (posix.errno(rc) != .SUCCESS) {
        closePair(out_p);
        closePair(err_p);
        closePair(ready_p);
        return error.ForkFailed;
    }
    if (rc == 0) {
        // Child: if the supervisor dies unexpectedly (non-PID-1 use), take
        // the worker down with it — no orphans. Guard the classic race:
        // parent may already be gone before prctl lands.
        _ = linux.prctl(@intFromEnum(linux.PR.SET_PDEATHSIG), @intFromEnum(posix.SIG.TERM), 0, 0, 0);
        if (linux.getppid() != supervisor_pid) linux.exit(1);
        // Own process group so signals reach shell-spawned grandchildren
        // too (dumb-init behavior), then route stdout/stderr into the
        // pipes. dup2 clears CLOEXEC on fds 1/2; originals close at execve.
        _ = linux.setpgid(0, 0);
        if (out_p) |p| _ = linux.dup2(p.w, 1);
        if (err_p) |p| _ = linux.dup2(p.w, 2);
        // s6-style readiness: the worker writes a newline to this fd.
        if (ready_p) |p| _ = linux.dup2(p.w, ready_fd.?);
        if (w.cwd_len > 0) _ = linux.chdir(@ptrCast(&w.cwd_buf));
        // OOM-killer steering + niceness: best-effort, before the drop
        // (negative oom_score_adj needs the privileges we may give up).
        if (w.oom_adj) |adj| {
            const orc = linux.openat(linux.AT.FDCWD, "/proc/self/oom_score_adj", .{ .ACCMODE = .WRONLY }, 0);
            if (posix.errno(orc) == .SUCCESS) {
                var nbuf: [8]u8 = undefined;
                const txt = std.fmt.bufPrint(&nbuf, "{d}", .{adj}) catch "0";
                _ = linux.write(@intCast(orc), txt.ptr, txt.len);
                _ = linux.close(@intCast(orc));
            }
        }
        if (w.nice_val) |n| {
            // setpriority(PRIO_PROCESS=0, self=0, n)
            _ = linux.syscall3(.setpriority, 0, 0, @bitCast(@as(isize, n)));
        }
        // Privilege drop is fail-closed: a worker configured as non-root must
        // never accidentally run as root. Order matters: groups, gid, uid.
        if (w.drop_gid) |gid| {
            const one_group = [1]linux.gid_t{gid};
            if (posix.errno(linux.setgroups(1, &one_group)) != .SUCCESS or
                posix.errno(linux.setgid(gid)) != .SUCCESS)
            {
                const msg = "[mandor] setgid failed\n";
                _ = linux.write(2, msg, msg.len);
                linux.exit(126);
            }
        }
        if (w.drop_uid) |uid| {
            if (posix.errno(linux.setuid(uid)) != .SUCCESS) {
                const msg = "[mandor] setuid failed\n";
                _ = linux.write(2, msg, msg.len);
                linux.exit(126);
            }
        }
        applyHardening(w);
        execChild(w, child_envp, path_env);
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
    if (ready_p) |p| {
        _ = linux.close(p.w);
        w.ready_r = p.r;
    }
    w.ready = false;
    w.pid = @intCast(rc);
    w.status = .running;
    w.last_start_ms = now_ms;
    w.next_restart_ms = 0;
    w.next_health_ms = 0; // runHealth reschedules the first probe
    w.health_fails = 0;
    w.health_ever_ok = false;
    // New pid: CPU tick baseline restarts from zero (history stays).
    w.stats.prev_ticks = 0;
    w.stats.prev_t_ms = 0;
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    w.spawned_at_epoch = ts.sec;
    resolveExe(w, path_env);
    if (w.exe_len > 0 and w.build_id_len == 0) {
        if (elf.readBuildId(w.exe_buf[0..w.exe_len], &w.build_id_buf)) |id|
            w.build_id_len = @intCast(id.len);
    }
}

/// Parent-side mirror of the child's exec resolution, so incident bundles
/// can map the command to a real file path. Runs once per spawn — cold path.
fn resolveExe(w: *Worker, path_env: []const u8) void {
    const argv0 = std.mem.span(w.argv[0].?);
    if (std.mem.indexOfScalar(u8, argv0, '/') != null) {
        const len = @min(argv0.len, w.exe_buf.len);
        @memcpy(w.exe_buf[0..len], argv0[0..len]);
        w.exe_len = @intCast(len);
        return;
    }
    var cand: [4200]u8 = undefined;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0 or dir.len + 1 + argv0.len + 1 > cand.len) continue;
        const path = std.fmt.bufPrintZ(&cand, "{s}/{s}", .{ dir, argv0 }) catch continue;
        if (posix.errno(linux.faccessat(linux.AT.FDCWD, path.ptr, 1, 0)) == .SUCCESS) { // X_OK
            const len = @min(path.len, w.exe_buf.len);
            @memcpy(w.exe_buf[0..len], path[0..len]);
            w.exe_len = @intCast(len);
            return;
        }
    }
}

var merged_env: [513 + 17]?[*:0]const u8 = undefined;

fn mergeEnv(envp: [*:null]const ?[*:0]const u8, w: *const Worker) [*:null]const ?[*:0]const u8 {
    var n: usize = 0;
    while (envp[n] != null and n < 480) : (n += 1) merged_env[n] = envp[n];
    for (g_env[0..g_env_n]) |e| {
        merged_env[n] = e;
        n += 1;
    }
    for (w.extra_env[0..w.extra_env_n]) |e| {
        merged_env[n] = e;
        n += 1;
    }
    merged_env[n] = null;
    return @ptrCast(&merged_env);
}

/// Post-drop, pre-exec hardening (child only). cap_drop shrinks the
/// bounding set; no_new_privs is set unconditionally once a uid is dropped
/// so a setuid binary can never re-escalate. Best-effort: a container that
/// forbids these keeps running (worse case = no extra hardening).
fn applyHardening(w: *const Worker) void {
    if (w.drop_all_caps) {
        var b: u8 = 0;
        while (b <= caps.last_cap) : (b += 1) {
            _ = linux.prctl(@intFromEnum(linux.PR.CAPBSET_DROP), b, 0, 0, 0);
        }
    } else if (w.cap_drop_mask != 0) {
        var b: u6 = 0;
        while (b < 64) : (b += 1) {
            if (w.cap_drop_mask & (@as(u64, 1) << b) != 0)
                _ = linux.prctl(@intFromEnum(linux.PR.CAPBSET_DROP), b, 0, 0, 0);
        }
    }
    if (w.drop_uid != null or w.drop_all_caps or w.cap_drop_mask != 0)
        _ = linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0);
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
    execArgv(@ptrCast(&w.argv), envp, path_env);
}

/// Fire-and-forget child (incident hooks): inherits stdio, own signal mask
/// restored; reaped later as an ordinary orphan.
pub fn spawnDetached(
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    path_env: []const u8,
) void {
    const rc = linux.fork();
    if (posix.errno(rc) != .SUCCESS) return;
    if (rc == 0) {
        const empty = posix.sigemptyset();
        posix.sigprocmask(posix.SIG.SETMASK, &empty, null);
        execArgv(argv, envp, path_env);
    }
}

/// exec with PATH candidates; never returns (127 on total failure).
fn execArgv(
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    path_env: []const u8,
) noreturn {
    const argv0z = argv[0].?;
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

test "names are neutralized for the unescaped metrics sink" {
    // setName directly: a quote in the command string would not survive
    // tokenization, but a basename off the filesystem can hold any byte.
    var w: Worker = undefined;
    setName(&w, "./we\"ird\\na\nme", &.{});
    try std.testing.expectEqualStrings("we_ird_na_me", w.nameSlice());
}

test "findPath falls back to default" {
    const empty_env = [_:null]?[*:0]const u8{};
    try std.testing.expectEqualStrings(default_path, findPath(&empty_env));
}
