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

/// Worker died uncleanly (outside shutdown): classify, dedup, spool.
/// `oom` = the cgroup's oom_kill counter rose across this death.
pub fn onDeath(state_dir: []const u8, w: *spawner.Worker, now_ms: u64, oom: bool) void {
    const killed_by_sigkill = switch (w.status) {
        .signaled => |sig| sig == 9,
        else => false,
    };
    const cause: []const u8 = if (oom and killed_by_sigkill)
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
    const kind: []const u8 = if (oom and killed_by_sigkill)
        "oom"
    else switch (w.status) {
        .exited => "exit",
        else => "signal",
    };

    const tail = collectTail(w);
    const trace = summarize.extractTrace(tail, &trace_storage);
    const err_line = summarize.firstErrorLine(tail);
    const sig_hash = summarize.signature(kind, w.nameSlice(), if (err_line.len > 0) err_line else cause);
    if (!w.det.shouldEmit(sig_hash, now_ms)) return;

    total += 1;
    const uptime_s = (now_ms -| w.last_start_ms) / 1000;
    const killed_by_kill = switch (w.status) {
        .signaled => |sig| sig == 9,
        else => false,
    };
    const stats = collectStats(w);
    spool.write(state_dir, .{
        .ts_epoch = epochNow(),
        .name = w.nameSlice(),
        .cmd = w.cmd,
        .pid = 0,
        .restarts = w.restarts,
        .cause = cause,
        .trace = trace,
        .logs_tail = tail,
        .stats = stats,
        .now_ms = now_ms,
        .verdict = summarize.diagnose(&verdict_buf, cause, trace, tail, stats, uptime_s, killed_by_kill),
    });
}

/// Restart-loop threshold crossed.
pub fn onRestartLoop(state_dir: []const u8, w: *spawner.Worker, count: u32, now_ms: u64) void {
    total += 1;
    const tail = collectTail(w);
    const last_cause: []const u8 = switch (w.status) {
        .exited => |code| std.fmt.bufPrint(&cause_buf, "exit:{d}", .{code}) catch "exit:?",
        .signaled => |sig| std.fmt.bufPrint(&cause_buf, "signal:{d}", .{sig}) catch "signal:?",
        else => "unknown",
    };
    spool.write(state_dir, .{
        .ts_epoch = epochNow(),
        .name = w.nameSlice(),
        .cmd = w.cmd,
        .pid = 0,
        .restarts = w.restarts,
        .cause = "restart-loop",
        .trace = summarize.extractTrace(tail, &trace_storage),
        .logs_tail = tail,
        .stats = collectStats(w),
        .now_ms = now_ms,
        .verdict = summarize.verdictRestartLoop(&verdict_buf, count, detector.restart_loop_window_ms / 1000, last_cause),
    });
}

/// RSS climb detected on a live worker.
pub fn onLeak(state_dir: []const u8, w: *spawner.Worker, info: detector.LeakInfo, now_ms: u64) void {
    total += 1;
    spool.write(state_dir, .{
        .ts_epoch = epochNow(),
        .name = w.nameSlice(),
        .cmd = w.cmd,
        .pid = w.pid,
        .restarts = w.restarts,
        .cause = "leak-suspect",
        .trace = .{},
        .logs_tail = collectTail(w),
        .stats = collectStats(w),
        .now_ms = now_ms,
        .verdict = summarize.verdictLeak(&verdict_buf, info.growth_mb, info.minutes),
    });
}
