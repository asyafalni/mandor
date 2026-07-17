//! Incident emission glue (Linux): pulls together a dead/leaky worker's ring
//! tail, trace extraction, dedup and verdicts, and hands the bundle to spool.

const std = @import("std");
const linux = std.os.linux;
const spawner = @import("spawner.zig");
const sampler = @import("sampler.zig");
const summarize = @import("summarize.zig");
const detector = @import("detector.zig");
const spool = @import("spool.zig");
const ring = @import("ring.zig");

const max_tail = 200;

/// Incidents written this run (metrics counter).
pub var total: u64 = 0;

// Shared scratch (single-threaded supervisor; BSS, faulted lazily).
var tail_bufs: [max_tail][4096]u8 = undefined;
var tail_lines: [max_tail]summarize.LogLine = undefined;
var trace_storage: summarize.TraceStorage = .{};
var stats_scratch: [sampler.window_len]sampler.Sample = undefined;
var verdict_buf: [256]u8 = undefined;
var cause_buf: [32]u8 = undefined;
var siblings_scratch: [64]spool.Sibling = undefined;
// Whole-ring log compaction (repeated lines -> one entry + count), so
// bundles stay token-lean for LLM analysis. Cold path only.
var compactor: summarize.Compactor(max_tail, 512) = .{};

/// Sweep the ENTIRE ring (not just the tail) through the deduplicator.
fn collectCompact(w: *spawner.Worker) []const summarize.CompactLine {
    compactor.reset();
    var copy_buf: [4096]u8 = undefined;
    var it = w.log.iterate(&copy_buf);
    while (it.next()) |rec| compactor.feed(rec.line, rec.flags, rec.t_ms);
    return compactor.lines();
}

// Supervisor-wide snapshot, read once at startup (cold path).
const cgroup = @import("cgroup.zig");
var snap_environ: [:null]const ?[*:0]const u8 = &spool.empty_environ;
var snap_cwd_buf: [512]u8 = undefined;
var snap_cwd_len: usize = 0;
var snap_nofile: u64 = 0;
var snap_memory_max: ?u64 = null;
var snap_release: []const u8 = "";

const history = @import("history.zig");
const cli = @import("cli.zig");

// On-incident hook: exec'd after each bundle write, bundle path appended.
var hook_buf: [1024]u8 = undefined;
var hook_argv: [18]?[*:0]const u8 = undefined;
var hook_argc: usize = 0;
var hook_path_buf: [641]u8 = undefined;
var snap_path_env: []const u8 = "";

/// Tokenize the hook command into fixed storage. Returns false on bad cmd.
pub fn setHook(cmd: []const u8) bool {
    var toks: [16][]const u8 = undefined;
    const argv = cli.tokenize(cmd, &hook_buf, &toks) catch return false;
    for (argv, 0..) |t, i| hook_argv[i] = @ptrCast(t.ptr);
    hook_argc = argv.len;
    return true;
}

fn fireHook(bundle_path: []const u8) void {
    if (hook_argc == 0 or bundle_path.len >= hook_path_buf.len) return;
    @memcpy(hook_path_buf[0..bundle_path.len], bundle_path);
    hook_path_buf[bundle_path.len] = 0;
    hook_argv[hook_argc] = @ptrCast(&hook_path_buf);
    hook_argv[hook_argc + 1] = null;
    spawner.spawnDetached(@ptrCast(&hook_argv), snap_environ.ptr, snap_path_env);
}

// photon auto-forward: enabled ONLY by the `photon` config key — mandor
// stays offline otherwise. Fire-and-forget self-exec keeps network syscalls
// off the supervision path entirely.
var photon_endpoint_buf: [64]u8 = undefined;
var photon_endpoint_len: usize = 0;

pub fn setPhoton(endpoint: []const u8) bool {
    if (endpoint.len >= photon_endpoint_buf.len) return false;
    @memcpy(photon_endpoint_buf[0..endpoint.len], endpoint);
    photon_endpoint_buf[endpoint.len] = 0;
    photon_endpoint_len = endpoint.len;
    return true;
}

fn firePhoton(bundle_path: []const u8) void {
    if (photon_endpoint_len == 0 or bundle_path.len >= hook_path_buf.len) return;
    @memcpy(hook_path_buf[0..bundle_path.len], bundle_path);
    hook_path_buf[bundle_path.len] = 0;
    const argv = [_:null]?[*:0]const u8{
        "/proc/self/exe",
        "relay",
        @ptrCast(&hook_path_buf),
        @ptrCast(&photon_endpoint_buf),
    };
    spawner.spawnDetached(&argv, snap_environ.ptr, snap_path_env);
}

fn writeBundle(state_dir: []const u8, in: spool.BundleInput) void {
    if (spool.write(state_dir, in)) |path| {
        firePhoton(path);
        fireHook(path);
    }
}

pub fn initSnapshot(state_dir: []const u8, environ: [:null]const ?[*:0]const u8) void {
    history.load(state_dir);
    snap_environ = environ;
    const rc = linux.getcwd(&snap_cwd_buf, snap_cwd_buf.len);
    if (std.posix.errno(rc) == .SUCCESS and rc > 0) snap_cwd_len = rc - 1; // drop NUL
    if (std.posix.getrlimit(.NOFILE)) |lim| {
        snap_nofile = @intCast(@min(lim.cur, std.math.maxInt(u63)));
    } else |_| {}
    snap_memory_max = cgroup.readMemoryMax();
    snap_release = spawner.findEnv(environ, "MANDOR_RELEASE") orelse
        (spawner.findEnv(environ, "GIT_SHA") orelse "");
    snap_path_env = spawner.findPath(environ);
}

fn epochNow() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return ts.sec;
}

fn collectTail(w: *spawner.Worker) []summarize.LogLine {
    var copy_buf: [4096]u8 = undefined;
    const record_count = w.log.count();
    const skip = record_count -| max_tail;
    var it = w.log.iterate(&copy_buf);
    var i: usize = 0;
    var n: usize = 0;
    while (it.next()) |rec| : (i += 1) {
        if (i < skip) continue;
        const len = @min(rec.line.len, tail_bufs[n].len);
        @memcpy(tail_bufs[n][0..len], rec.line[0..len]);
        tail_lines[n] = .{ .text = tail_bufs[n][0..len], .flags = rec.flags, .t_ms = rec.t_ms };
        n += 1;
        if (n == max_tail) break;
    }
    return tail_lines[0..n];
}

fn collectStats(w: *const spawner.Worker) []const sampler.Sample {
    for (0..w.stats.len) |i| stats_scratch[i] = w.stats.at(i);
    return stats_scratch[0..w.stats.len];
}

pub fn sigName(sig: u8) []const u8 {
    return switch (sig) {
        1 => "SIGHUP",
        2 => "SIGINT",
        3 => "SIGQUIT",
        4 => "SIGILL",
        6 => "SIGABRT",
        7 => "SIGBUS",
        8 => "SIGFPE",
        9 => "SIGKILL",
        11 => "SIGSEGV",
        13 => "SIGPIPE",
        15 => "SIGTERM",
        else => "",
    };
}

fn collectSiblings(workers: []spawner.Worker, self: *const spawner.Worker, now_ms: u64) []const spool.Sibling {
    var n: usize = 0;
    for (workers) |*other| {
        if (other == self or n == siblings_scratch.len) continue;
        siblings_scratch[n] = .{
            .name = other.nameSlice(),
            .state = switch (other.status) {
                .not_started => "not-started",
                .running => "running",
                .exited => "exited",
                .signaled => "signaled",
            },
            .uptime_s = if (other.pid > 0) (now_ms -| other.last_start_ms) / 1000 else 0,
            .restarts = other.restarts,
        };
        n += 1;
    }
    return siblings_scratch[0..n];
}

/// Worker died uncleanly (outside shutdown): classify, dedup, spool.
/// `oom` = the cgroup's oom_kill counter rose across this death.
pub fn onDeath(state_dir: []const u8, workers: []spawner.Worker, w: *spawner.Worker, now_ms: u64, oom: bool) void {
    const killed_by_sigkill = switch (w.status) {
        .signaled => |sig| sig == 9,
        else => false,
    };
    const is_oom = oom and killed_by_sigkill;
    const cause_str: []const u8 = if (is_oom)
        "oom"
    else switch (w.status) {
        .exited => |code| std.fmt.bufPrint(&cause_buf, "exit:{d}", .{code}) catch "exit:?",
        .signaled => |sig| blk: {
            const name = sigName(sig);
            break :blk if (name.len > 0)
                std.fmt.bufPrint(&cause_buf, "signal:{s}", .{name}) catch "signal:?"
            else
                std.fmt.bufPrint(&cause_buf, "signal:{d}", .{sig}) catch "signal:?";
        },
        else => return,
    };
    const kind: []const u8 = if (is_oom) "oom" else switch (w.status) {
        .exited => "exit",
        else => "signal",
    };
    const cause: spool.CauseInfo = .{
        .kind = kind,
        .exit_code = switch (w.status) {
            .exited => |code| code,
            else => null,
        },
        .sig_num = switch (w.status) {
            .signaled => |sig| sig,
            else => null,
        },
        .sig_name = switch (w.status) {
            .signaled => |sig| sigName(sig),
            else => "",
        },
        .core_dumped = w.core_dumped,
        .oom_kill_delta = @intFromBool(is_oom),
    };

    const tail = collectTail(w);
    const trace = summarize.extractTrace(tail, &trace_storage);
    const err_line = summarize.firstErrorLine(tail);
    const sig_hash = summarize.signature(kind, w.nameSlice(), if (err_line.len > 0) err_line else cause_str);
    if (!w.det.shouldEmit(sig_hash, now_ms)) return;

    total += 1;
    const hist = history.record(sig_hash, epochNow());
    history.save(state_dir);
    const uptime_s = (now_ms -| w.last_start_ms) / 1000;
    const stats = collectStats(w);
    writeBundle(state_dir, .{
        .ts_epoch = epochNow(),
        .name = w.nameSlice(),
        .cmd = w.cmd,
        .pid = 0,
        .restarts = w.restarts,
        .cwd = if (w.cwd_len > 0) w.cwd_buf[0..w.cwd_len] else snap_cwd_buf[0..snap_cwd_len],
        .exe = w.exe_buf[0..w.exe_len],
        .spawned_at_epoch = w.spawned_at_epoch,
        .uptime_s = uptime_s,
        .ready = w.ready,
        .release = snap_release,
        .build_id = w.build_id_buf[0..w.build_id_len],
        .environ = snap_environ,
        .limits_nofile = snap_nofile,
        .memory_max_bytes = snap_memory_max,
        .cause = cause,
        .cause_str = cause_str,
        .trace = trace,
        .logs_tail = collectCompact(w),
        .logs_dropped = compactor.dropped,
        .stats = stats,
        .now_ms = now_ms,
        .siblings = collectSiblings(workers, w, now_ms),
        .history_sig = hist.sig,
        .history_first_epoch = hist.first_seen,
        .history_count = hist.count,
        .verdict = summarize.diagnose(&verdict_buf, cause_str, trace, tail, stats, uptime_s, killed_by_sigkill),
    });
}

/// Non-death incidents dedupe/recur on (kind, worker) alone.
fn recordKindHistory(state_dir: []const u8, kind: []const u8, w: *const spawner.Worker) history.Entry {
    const sig = summarize.signature(kind, w.nameSlice(), "");
    const e = history.record(sig, epochNow());
    history.save(state_dir);
    return e;
}

/// Common v2 plumbing for the non-death incident kinds.
fn commonInput(
    workers: []spawner.Worker,
    w: *spawner.Worker,
    now_ms: u64,
    kind: []const u8,
    pid: i32,
) spool.BundleInput {
    return .{
        .ts_epoch = epochNow(),
        .name = w.nameSlice(),
        .cmd = w.cmd,
        .pid = pid,
        .restarts = w.restarts,
        .cwd = if (w.cwd_len > 0) w.cwd_buf[0..w.cwd_len] else snap_cwd_buf[0..snap_cwd_len],
        .exe = w.exe_buf[0..w.exe_len],
        .spawned_at_epoch = w.spawned_at_epoch,
        .uptime_s = (now_ms -| w.last_start_ms) / 1000,
        .ready = w.ready,
        .release = snap_release,
        .build_id = w.build_id_buf[0..w.build_id_len],
        .environ = snap_environ,
        .limits_nofile = snap_nofile,
        .memory_max_bytes = snap_memory_max,
        .cause = .{ .kind = kind },
        .cause_str = kind,
        .trace = .{},
        .logs_tail = &.{},
        .stats = &.{},
        .now_ms = now_ms,
        .siblings = collectSiblings(workers, w, now_ms),
        .verdict = "",
    };
}

/// Restart-loop threshold crossed.
pub fn onRestartLoop(state_dir: []const u8, workers: []spawner.Worker, w: *spawner.Worker, count: u32, now_ms: u64) void {
    total += 1;
    const tail = collectTail(w);
    const last_cause: []const u8 = switch (w.status) {
        .exited => |code| std.fmt.bufPrint(&cause_buf, "exit:{d}", .{code}) catch "exit:?",
        .signaled => |sig| std.fmt.bufPrint(&cause_buf, "signal:{d}", .{sig}) catch "signal:?",
        else => "unknown",
    };
    var in = commonInput(workers, w, now_ms, "restart-loop", 0);
    const hist = recordKindHistory(state_dir, "restart-loop", w);
    in.history_sig = hist.sig;
    in.history_first_epoch = hist.first_seen;
    in.history_count = hist.count;
    in.trace = summarize.extractTrace(tail, &trace_storage);
    in.logs_tail = collectCompact(w);
    in.logs_dropped = compactor.dropped;
    in.stats = collectStats(w);
    in.verdict = summarize.verdictRestartLoop(&verdict_buf, count, detector.restart_loop_window_ms / 1000, last_cause);
    writeBundle(state_dir, in);
}

/// Health probe failed `fails` consecutive times: the worker is alive but
/// not doing its job — the failure mode exit-based supervision cannot see.
pub fn onUnhealthy(state_dir: []const u8, workers: []spawner.Worker, w: *spawner.Worker, fails: u8, now_ms: u64) void {
    total += 1;
    const tail = collectTail(w);
    var in = commonInput(workers, w, now_ms, "unhealthy", w.pid);
    const hist = recordKindHistory(state_dir, "unhealthy", w);
    in.history_sig = hist.sig;
    in.history_first_epoch = hist.first_seen;
    in.history_count = hist.count;
    in.trace = summarize.extractTrace(tail, &trace_storage);
    in.logs_tail = collectCompact(w);
    in.logs_dropped = compactor.dropped;
    in.stats = collectStats(w);
    in.verdict = summarize.verdictUnhealthy(&verdict_buf, fails, (now_ms -| w.last_start_ms) / 1000);
    writeBundle(state_dir, in);
}

/// RSS climb detected on a live worker.
pub fn onLeak(state_dir: []const u8, workers: []spawner.Worker, w: *spawner.Worker, info: detector.LeakInfo, now_ms: u64) void {
    total += 1;
    var in = commonInput(workers, w, now_ms, "leak-suspect", w.pid);
    const hist = recordKindHistory(state_dir, "leak-suspect", w);
    in.history_sig = hist.sig;
    in.history_first_epoch = hist.first_seen;
    in.history_count = hist.count;
    in.logs_tail = collectCompact(w);
    in.logs_dropped = compactor.dropped;
    in.stats = collectStats(w);
    in.verdict = summarize.verdictLeak(&verdict_buf, info.growth_mb, info.minutes);
    writeBundle(state_dir, in);
}
