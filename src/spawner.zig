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
const names = @import("names.zig");

pub const max_args = 64;
pub const name_cap = names.cap;
pub const log_ring_capacity = 256 * 1024;
const default_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";

pub const Status = union(enum) {
    not_started,
    running,
    exited: u8,
    signaled: u8,
};

/// One secret granted to a worker for a single spawn. The delivery layer owns
/// this shape; the supervisor (Task 4) fills each with slices INTO its mlock'd
/// registry — the bytes are never copied here. `value` is written to a pipe (a
/// trailing '\n' is added unless `raw`); only the fd NUMBER reaches the child,
/// via `env`. The value never enters env, argv, or disk.
pub const Grant = struct {
    value: []const u8,
    env: []const u8,
    raw: bool,
};

/// Default per-worker health-probe timing (v1.14; overridable per `[worker.NAME]`).
pub const default_health_interval_ms: u64 = 30_000;
pub const default_health_start_period_ms: u64 = 10_000;

pub const Worker = struct {
    name: [name_cap]u8 = undefined,
    name_len: u8 = 0,
    cmd: []const u8 = "", // original command string (argv memory, lives forever)
    cmd_buf: [4096]u8 = undefined,
    argv: [max_args + 1]?[*:0]const u8 = undefined, // null-terminated for execve
    argc: u8 = 0,
    pid: i32 = 0, // 0 = not running
    /// Process-group id (== the pid at spawn). Kept after `pid` is
    /// cleared on reap so a graceful shutdown can still reach
    /// grandchildren whose leader has already exited.
    pgid: i32 = 0,
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
    // Per-worker probe timing (v1.14; `[worker.NAME] health_interval` /
    // `health_start_period`). Default when unset; a binary's readiness cadence
    // and warm-up time are properties of that binary, not the fleet.
    health_interval_ms: u64 = default_health_interval_ms,
    health_start_period_ms: u64 = default_health_start_period_ms,

    // Per-worker extras (v0.8): env additions, working dir, oneshot marker.
    extra_env_buf: [1024]u8 = undefined,
    extra_env: [17]?[*:0]const u8 = undefined,
    extra_env_n: u8 = 0,
    extra_env_used: u16 = 0,
    cwd_buf: [256]u8 = undefined,
    cwd_len: u16 = 0, // NUL-terminated in cwd_buf when set
    is_oneshot: bool = false,
    /// Per-worker opt-in log streaming (`[worker.NAME] stream = true`). Default
    /// false ⇒ this worker's captured lines are never enqueued to photon, so the
    /// capture path pays nothing. Armed in applyConfig only when photon is set.
    stream: bool = false,
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
    /// Per-worker `expected_exit`, parsed once at startup into a 256-bit set
    /// (32 bytes). Keeping the parse out of the death path matters: inlining
    /// the string parser into the supervision loop cost ~20 KB of .text.
    /// `expected_set = false` means fall back to the global set.
    expected_bits: [32]u8 = .{0} ** 32,
    expected_set: bool = false,
    /// Set when mandor TERMs a worker for failing its health probe. The death
    /// that follows is a failure regardless of the exit code it reports.
    health_killed: bool = false,
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

    // App-shared secrets granted to this worker (v1.7). Populated by the
    // supervisor before each (re)spawn with slices into its mlock'd registry;
    // default 0 = no secrets = behavior unchanged. See spawner's per-spawn
    // delivery: one inherited pipe fd per grant, only the fd number in env.
    secrets: [cli.max_secrets]Grant = undefined,
    secrets_n: usize = 0,

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
    w.pgid = 0;
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
    w.health_interval_ms = default_health_interval_ms;
    w.health_start_period_ms = default_health_start_period_ms;
    w.health_pid = 0;
    w.health_started_ms = 0;
    w.next_health_ms = 0;
    w.health_fails = 0;
    w.health_done = false;
    w.health_ok = false;
    w.health_ever_ok = false;
    w.extra_env_n = 0;
    w.extra_env_used = 0;
    w.secrets_n = 0;
    w.cwd_len = 0;
    w.is_oneshot = false;
    w.stream = false;
    w.drop_uid = null;
    w.drop_gid = null;
    w.cap_drop_mask = 0;
    w.drop_all_caps = false;
    w.oom_adj = null;
    w.nice_val = null;
    w.max_rss_kb = null;
    w.max_lifetime_ms = null;
    w.recycling = false;
    w.expected_set = false;
    w.health_killed = false;
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

/// Monotonic milliseconds — local to spawner so `runCheck`'s bounded wait
/// needs no dependency on the supervisor's own `nowMs`.
fn monoMs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

fn sleepMs(ms: u64) void {
    var ts: linux.timespec = .{ .sec = 0, .nsec = @intCast(ms * std.time.ns_per_ms) };
    _ = linux.nanosleep(&ts, null);
}

/// `[require.NAME]` boot-gate check: fork/exec `cmd` (tokenized the same way
/// as a worker command) and BLOCK until it exits or `timeout_ms` elapses.
/// Boot has no fleet to protect yet — unlike every other spawn path in this
/// file, a bounded blocking wait here is fine because it runs once, strictly
/// before any worker exists. Fail-closed: a tokenize/fork/exec problem, or a
/// timeout (SIGKILL + reap), returns 255; otherwise the child's real exit
/// code. No allocation, no panic — every syscall errno is handled.
pub fn runCheck(
    cmd: []const u8,
    timeout_ms: u64,
    envp: [*:null]const ?[*:0]const u8,
    path_env: []const u8,
) u8 {
    var buf: [4096]u8 = undefined;
    var toks: [max_args][]const u8 = undefined;
    const toked = cli.tokenize(cmd, &buf, &toks) catch return 255;
    if (toked.len == 0) return 255;
    var argv: [max_args + 1]?[*:0]const u8 = undefined;
    for (toked, 0..) |t, i| argv[i] = @ptrCast(t.ptr);
    argv[toked.len] = null;

    const supervisor_pid = linux.getpid();
    const rc = linux.fork();
    if (posix.errno(rc) != .SUCCESS) return 255;
    if (rc == 0) {
        // Dies with the supervisor — it holds no state worth draining.
        _ = linux.prctl(@intFromEnum(linux.PR.SET_PDEATHSIG), @intFromEnum(posix.SIG.KILL), 0, 0, 0);
        if (linux.getppid() != supervisor_pid) linux.exit(1);
        const empty = posix.sigemptyset();
        posix.sigprocmask(posix.SIG.SETMASK, &empty, null);
        execArgv(@ptrCast(&argv), envp, path_env);
    }
    const pid: i32 = @intCast(rc);
    const deadline = monoMs() +| timeout_ms;

    while (true) {
        var st: u32 = 0;
        const wrc = linux.waitpid(pid, &st, linux.W.NOHANG);
        switch (posix.errno(wrc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return 255, // fail-closed: treat as not met
        }
        if (wrc == pid) {
            if (linux.W.IFEXITED(st)) return linux.W.EXITSTATUS(st);
            return 255; // signaled or other abnormal exit: fail-closed
        }
        if (monoMs() >= deadline) {
            posix.kill(pid, .KILL) catch {};
            // Bounded reap: SIGKILL lands almost immediately, but never spin
            // forever waiting for it.
            var tries: u32 = 0;
            while (tries < 2000) : (tries += 1) {
                var st2: u32 = 0;
                const wrc2 = linux.waitpid(pid, &st2, linux.W.NOHANG);
                if (posix.errno(wrc2) != .SUCCESS or wrc2 == pid) break;
                sleepMs(1);
            }
            return 255;
        }
        sleepMs(5);
    }
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
    assignName(w, names.basename(argv0), prior);
}

/// Finalize `raw` into `w.name` via the shared `names.finalize` (cap + dedup +
/// neutralize). Both basename derivation and the TOML `name` override flow
/// through here, and `config` resolves secret grants against the SAME
/// `names.finalize`, so a worker's name and the name a grant matches on can
/// never diverge.
fn assignName(w: *Worker, raw: []const u8, prior: []const Worker) void {
    var pn_buf: [cli.max_workers][]const u8 = undefined;
    for (prior, 0..) |*p, i| pn_buf[i] = p.nameSlice();
    const name = names.finalize(raw, pn_buf[0..prior.len], w.name[0..]);
    w.name_len = @intCast(name.len);
}

/// Apply a TOML `name` override to an already-initialized worker, reusing the
/// basename path's cap + dedup + neutralize (so a colliding or Prometheus-unsafe
/// override is handled identically). Returns false — a hard config error — when
/// the override is empty, longer than the name buffer allows, or made entirely
/// of bytes that would neutralize away: configs are small, so a typo stops
/// startup rather than silently keeping the derived name. `prior` are the
/// workers to dedup against (those already finalized, i.e. lower index).
pub fn setNameOverride(w: *Worker, override: []const u8, prior: []const Worker) bool {
    if (override.len == 0) return false;
    if (override.len > name_cap - 4) return false; // explicit intent: don't truncate
    var has_valid = false;
    for (override) |c| {
        if (!names.unsafeByte(c)) {
            has_valid = true;
            break;
        }
    }
    if (!has_valid) return false; // every byte would become '_'
    assignName(w, override, prior);
    return true;
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

/// Is `name` an executable resolvable on `path_env`? A pure PATH walk with an
/// `faccessat(X_OK)` probe — no fork/exec — so a caller can skip spawning a
/// subprocess that isn't installed (e.g. `nvidia-smi` on a GPU-less image). A
/// name containing '/' is treated as a path and checked directly. Mirrors the
/// resolution `resolveExe`/`execArgv` do at exec time. Cold path only.
pub fn onPath(name: []const u8, path_env: []const u8) bool {
    var cand: [4200]u8 = undefined;
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        const p = std.fmt.bufPrintZ(&cand, "{s}", .{name}) catch return false;
        return posix.errno(linux.faccessat(linux.AT.FDCWD, p.ptr, 1, 0)) == .SUCCESS; // X_OK
    }
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0 or dir.len + 1 + name.len + 1 > cand.len) continue;
        const path = std.fmt.bufPrintZ(&cand, "{s}/{s}", .{ dir, name }) catch continue;
        if (posix.errno(linux.faccessat(linux.AT.FDCWD, path.ptr, 1, 0)) == .SUCCESS) return true; // X_OK
    }
    return false;
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
    // Build one inherited pipe per granted secret BEFORE fork (writes the
    // value + records the child read fd and its `env=<fd>` C-string). Static
    // per-spawn scratch, no alloc; fail-closed per secret (see prepSecrets).
    const nsec = prepSecrets(w);
    // Merge parent env + per-worker extras + secret fd envs BEFORE fork (no
    // alloc, static scratch — spawns are serialized in the single-threaded
    // supervisor). Secret envs must be included even with no other extras.
    const child_envp: [*:null]const ?[*:0]const u8 = if (w.extra_env_n > 0 or g_env_n > 0 or nsec > 0)
        mergeEnv(envp, w, nsec)
    else
        envp;
    const supervisor_pid = linux.getpid(); // must be pre-fork for the guard
    const rc = linux.fork();
    if (posix.errno(rc) != .SUCCESS) {
        closePair(out_p);
        closePair(err_p);
        closePair(ready_p);
        closeSecrets(nsec); // mirror closePair cleanup: no leaked secret fds
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
        // Generalized `keep_fd`: clear FD_CLOEXEC on each granted secret's read
        // end so exactly those fds survive execve. The write ends stay CLOEXEC
        // and auto-close, so the child can only read (never re-write) its value.
        {
            var si: usize = 0;
            while (si < nsec) : (si += 1) _ = linux.fcntl(secret_r[si], linux.F.SETFD, 0);
        }
        execChild(w, child_envp, path_env);
    }
    // Parent sets it too — whichever side wins the race, the group exists
    // before we ever signal it.
    _ = linux.setpgid(@intCast(rc), @intCast(rc));
    w.pgid = @intCast(rc);
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
    // Parent (long-lived PID 1) keeps NEITHER end of any secret pipe: the child
    // kept its CLOEXEC-cleared read copy. Closing both here avoids leaking an fd
    // per respawn (write end) and holding a reader that would hide the child's
    // EOF (read end).
    closeSecrets(nsec);
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

// Parent env (cap 480) + g_env (32) + extra_env (16) + secret fd envs
// (cli.max_secrets) + null terminator.
var merged_env: [513 + 17 + cli.max_secrets]?[*:0]const u8 = undefined;

fn mergeEnv(envp: [*:null]const ?[*:0]const u8, w: *const Worker, nsec: usize) [*:null]const ?[*:0]const u8 {
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
    // Secret fd envs (`env=<read_fd>`) built by prepSecrets into static scratch.
    for (secret_env[0..nsec]) |e| {
        merged_env[n] = e;
        n += 1;
    }
    merged_env[n] = null;
    return @ptrCast(&merged_env);
}

// -------------------------------------------------------- secret delivery
//
// Per-spawn secret scratch. Serialized single-threaded spawns let these be
// static (same rationale as merged_env) — zero heap, no secret bytes copied
// (grants hold slices into the mlock'd registry; only value bytes transit the
// pipe). `secret_r`/`secret_w` are index-aligned; `secret_env[i]` points into
// `secret_env_buf[i]`.
var secret_r: [cli.max_secrets]i32 = undefined; // child read ends (CLOEXEC-cleared pre-exec)
var secret_w: [cli.max_secrets]i32 = undefined; // parent write ends (stay CLOEXEC)
var secret_env_buf: [cli.max_secrets][64]u8 = undefined;
var secret_env: [cli.max_secrets]?[*:0]const u8 = undefined;
var secret_n: usize = 0; // secrets delivered this spawn (also prepSecrets' return)

/// Format "<env>=<fd>\0" into `out`, returning the null-terminated slice. Pure
/// (no syscalls) so the env formatting is testable without a pipe. Returns null
/// on overflow — the caller treats that as a skip (fail-closed), never a panic.
fn fmtFdEnv(env: []const u8, fd: i32, out: []u8) ?[:0]const u8 {
    return std.fmt.bufPrintZ(out, "{s}={d}", .{ env, fd }) catch null;
}

/// Write `bytes` in full to `fd`. Handles short writes; false on any error or a
/// zero-length write (fail-closed). Secret values are ≤ ~5.5KB < the 64KB pipe
/// capacity, so a pre-fork write never blocks even with no reader yet.
fn writeFull(fd: i32, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (posix.errno(rc) != .SUCCESS) return false;
        if (rc == 0) return false;
        off += rc;
    }
    return true;
}

fn secretSkip() void {
    const msg = "[mandor] secret pipe failed; worker will not receive it (fail-closed)\n";
    _ = linux.write(2, msg, msg.len);
}

/// Record one delivered secret into the per-spawn scratch: its child read fd,
/// parent write fd, and the `env=<fd>` C-string. Pure (no syscalls) so the
/// fd/env list assembly is testable without a pipe. Returns false if the env
/// string overflows its slot (caller skips — fail-closed).
fn recordSecret(env: []const u8, read_fd: i32, write_fd: i32) bool {
    const env_z = fmtFdEnv(env, read_fd, &secret_env_buf[secret_n]) orelse return false;
    secret_r[secret_n] = read_fd;
    secret_w[secret_n] = write_fd;
    secret_env[secret_n] = env_z.ptr;
    secret_n += 1;
    return true;
}

/// Build one CLOEXEC pipe per granted secret, write its value (+ '\n' unless
/// raw), and record the child read fd + `env=<fd>`. Static scratch, zero heap.
/// Fail-closed: a makePipe failure, a short/failed write, or an env overflow for
/// ONE secret logs + skips it (the child never gets that env → the worker's own
/// read fails) and NEVER aborts the spawn. Returns the count delivered.
fn prepSecrets(w: *const Worker) usize {
    secret_n = 0;
    for (w.secrets[0..w.secrets_n]) |g| {
        const p = capture.makePipe() orelse {
            secretSkip();
            continue;
        };
        if (!writeFull(p.w, g.value) or (!g.raw and !writeFull(p.w, "\n"))) {
            _ = linux.close(p.r);
            _ = linux.close(p.w);
            secretSkip();
            continue;
        }
        if (!recordSecret(g.env, p.r, p.w)) {
            _ = linux.close(p.r);
            _ = linux.close(p.w);
            secretSkip();
            continue;
        }
    }
    return secret_n;
}

/// Close BOTH ends of the first `n` secret pipes recorded this spawn.
fn closeSecrets(n: usize) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        _ = linux.close(secret_r[i]);
        _ = linux.close(secret_w[i]);
    }
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
/// Fork+exec a side process (incident hook, telemetry relay daemon). Returns
/// its pid so the caller can wait for it at shutdown -- mandor is PID 1 in a
/// container, so exiting while one is mid-flight kills it. 0 means the fork
/// failed.
///
/// `keep_fd` (>= 0) is an fd the child must INHERIT across execve. The caller
/// creates it O_CLOEXEC so it never leaks into other children; here the child
/// clears CLOEXEC on its own copy right before exec, so exactly this one process
/// keeps it open and the parent's copy still closes on any later exec. Pass -1
/// when no fd needs to survive (the on_incident hook case).
pub fn spawnDetached(
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    path_env: []const u8,
    keep_fd: i32,
) i32 {
    const rc = linux.fork();
    if (posix.errno(rc) != .SUCCESS) return 0;
    if (rc == 0) {
        const empty = posix.sigemptyset();
        posix.sigprocmask(posix.SIG.SETMASK, &empty, null);
        // Clear FD_CLOEXEC (the only fd flag) so this fd survives execve.
        if (keep_fd >= 0) _ = linux.fcntl(keep_fd, linux.F.SETFD, 0);
        execArgv(argv, envp, path_env);
    }
    return @intCast(rc);
}

/// exec with PATH candidates; never returns (127 on total failure). Public so
/// the daemon's GPU sampler (gpu.zig) can reuse the exact same fork/exec idiom
/// for its `nvidia-smi` subprocess instead of duplicating PATH resolution.
pub fn execArgv(
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

test "name override replaces the derived name" {
    var w: Worker = undefined;
    setName(&w, "./start.sh", &.{}); // derives "start.sh"
    try std.testing.expect(setNameOverride(&w, "api", &.{}));
    // The override flows through the single nameSlice() everything reads.
    try std.testing.expectEqualStrings("api", w.nameSlice());
}

test "name override is neutralized like a basename" {
    var w: Worker = undefined;
    setName(&w, "./worker", &.{});
    try std.testing.expect(setNameOverride(&w, "a\"b\\c\td", &.{}));
    try std.testing.expectEqualStrings("a_b_c_d", w.nameSlice());
}

test "name overrides colliding on the same name dedup" {
    var workers: [2]Worker = undefined;
    setName(&workers[0], "./start.sh", &.{});
    setName(&workers[1], "./worker", workers[0..1]);
    // Applied in index order, each dedups against the workers before it.
    try std.testing.expect(setNameOverride(&workers[0], "api", workers[0..0]));
    try std.testing.expect(setNameOverride(&workers[1], "api", workers[0..1]));
    try std.testing.expectEqualStrings("api", workers[0].nameSlice());
    try std.testing.expectEqualStrings("api-2", workers[1].nameSlice());
}

test "name override rejects empty and all-invalid" {
    var w: Worker = undefined;
    setName(&w, "./worker", &.{});
    try std.testing.expect(!setNameOverride(&w, "", &.{})); // empty
    try std.testing.expect(!setNameOverride(&w, "\"\\\t", &.{})); // all neutralize
    const too_long = "x" ** (name_cap - 3);
    try std.testing.expect(!setNameOverride(&w, too_long, &.{})); // too long
    // A rejected override never touched the derived name.
    try std.testing.expectEqualStrings("worker", w.nameSlice());
}

test "findPath falls back to default" {
    const empty_env = [_:null]?[*:0]const u8{};
    try std.testing.expectEqualStrings(default_path, findPath(&empty_env));
}

test "onPath resolves an executable on PATH without forking" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    // `sh` is present on every POSIX image the tests run on (/bin or /usr/bin).
    try std.testing.expect(onPath("sh", "/usr/bin:/bin:/usr/local/bin"));
    // A bogus name resolves nowhere.
    try std.testing.expect(!onPath("mandor-no-such-binary-9z7q", "/usr/bin:/bin"));
    // An empty PATH finds nothing (the GPU-less scratch case — no nvidia-smi, no fork).
    try std.testing.expect(!onPath("nvidia-smi", ""));
    // A name with '/' is checked as a path directly.
    try std.testing.expect(onPath("/bin/sh", ""));
    try std.testing.expect(!onPath("/bin/definitely-not-here-x", ""));
}

test "fmtFdEnv formats env=fd, null-terminated" {
    var buf: [64]u8 = undefined;
    const s = fmtFdEnv("CONFD_X", 7, &buf).?;
    try std.testing.expectEqualStrings("CONFD_X=7", s);
    try std.testing.expectEqual(@as(usize, 9), s.len);
    try std.testing.expectEqual(@as(u8, 0), buf[s.len]); // C-string terminator
}

test "fmtFdEnv handles a multi-digit fd" {
    var buf: [64]u8 = undefined;
    const s = fmtFdEnv("CONFD_X", 123, &buf).?;
    try std.testing.expectEqualStrings("CONFD_X=123", s);
    try std.testing.expectEqual(@as(usize, 11), s.len);
    try std.testing.expectEqual(@as(u8, 0), buf[s.len]);
}

test "secret fd/env list assembles in order" {
    // Drive the pure assembler with fake fds — no pipe, no fork.
    secret_n = 0;
    try std.testing.expect(recordSecret("CONFD_A", 11, 21));
    try std.testing.expect(recordSecret("CONFD_B", 123, 22));
    try std.testing.expectEqual(@as(usize, 2), secret_n);
    // Two read-fd entries recorded, in order.
    try std.testing.expectEqual(@as(i32, 11), secret_r[0]);
    try std.testing.expectEqual(@as(i32, 123), secret_r[1]);
    // Two env strings appended, in order, each carrying its own read fd.
    try std.testing.expectEqualStrings("CONFD_A=11", std.mem.span(secret_env[0].?));
    try std.testing.expectEqualStrings("CONFD_B=123", std.mem.span(secret_env[1].?));
}
