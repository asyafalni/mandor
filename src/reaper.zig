//! Zombie reaping and exit classification. As PID 1, mandor also inherits
//! orphans — they are reaped and discarded silently.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const cli = @import("cli.zig");
const spawner = @import("spawner.zig");

/// One `[prober.NAME]` check pid reaped this pass: `idx` indexes the
/// supervisor's own `cfg.probers[]` / `prober_state[]` (never a worker
/// index — probers and workers are separate index spaces entirely).
pub const ProberReap = struct { idx: u8, ok: bool };

pub const ReapSummary = struct {
    reaped_workers: u8 = 0,
    /// Prober checks reaped this pass — bounded, fixed capacity, no alloc.
    prober_reaped: [cli.max_probers]ProberReap = undefined,
    prober_reaped_n: u8 = 0,
};

/// Drain every exited child without blocking. Dead workers get their status
/// classified (exit code, or 128+signal) and pid cleared.
/// `sweep_kill` KILLs a dead worker's process group so a restart never
/// inherits strays. It is false during a graceful shutdown: the group was
/// already sent TERM, and killing it here would cut short grandchildren
/// still running their own handlers inside stop-grace. They are reached
/// via `Worker.pgid` if stop-grace expires.
///
/// `prober_pids[i]` is the pid `[prober.NAME]` slot `i` is currently
/// running (0 = none) — the supervisor's `prober_state[pi].pid` mirrored
/// into a plain slice so this module never needs to know the supervisor's
/// `ProberState` type. A pid is checked against this slice ONLY after it
/// has failed to match every worker/health/prestop pid above, so a prober
/// pid can never be mistaken for (or shadow) a worker pid, and vice versa.
pub fn drain(workers: []spawner.Worker, sweep_kill: bool, prober_pids: []const i32) ReapSummary {
    var summary: ReapSummary = .{};
    while (true) {
        var st: u32 = 0;
        const rc = linux.waitpid(-1, &st, linux.W.NOHANG);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return summary, // ECHILD: nothing left to reap
        }
        const pid: i32 = @intCast(rc);
        if (pid == 0) return summary; // children exist, none exited
        var matched = false;
        for (workers) |*w| {
            if (w.pid == pid and sweep_kill) {
                // Leader is dead and we are still supervising: sweep any
                // grandchildren left in its process group so a restart never
                // inherits strays. The group is gone, so drop the id — a
                // recorded pgid must only ever mean "left draining during a
                // shutdown", never a stale id the kernel may have recycled.
                posix.kill(-pid, .KILL) catch {};
                w.pgid = 0;
            }
            if (w.health_pid == pid) {
                w.health_pid = 0;
                w.health_done = true;
                w.health_ok = linux.W.IFEXITED(st) and linux.W.EXITSTATUS(st) == 0;
                matched = true;
                break;
            }
            if (w.prestop_pid == pid) {
                w.prestop_pid = 0;
                w.prestop_done = true;
                matched = true;
                break;
            }
            if (w.pid != pid) continue;
            w.pid = 0;
            if (linux.W.IFEXITED(st)) {
                const code = linux.W.EXITSTATUS(st);
                w.status = .{ .exited = code };
                w.final_code = code;
            } else if (linux.W.IFSIGNALED(st)) {
                const sig: u8 = @truncate(@intFromEnum(linux.W.TERMSIG(st)));
                w.status = .{ .signaled = sig };
                w.final_code = 128 +| sig;
                w.core_dumped = (st & 0x80) != 0; // WCOREDUMP bit
            } else {
                w.status = .{ .exited = 255 };
                w.final_code = 255;
            }
            summary.reaped_workers += 1;
            matched = true;
            break;
        }
        if (matched) continue;
        // Not a worker/health/prestop pid at all — check the probers. A
        // never-configured or already-idle slot has pid 0, which this reaped
        // `pid` (always > 0) can never equal, so no accidental match.
        for (prober_pids, 0..) |ppid, pi| {
            if (ppid != pid) continue;
            if (summary.prober_reaped_n < summary.prober_reaped.len) {
                summary.prober_reaped[summary.prober_reaped_n] = .{
                    .idx = @intCast(pi),
                    .ok = linux.W.IFEXITED(st) and linux.W.EXITSTATUS(st) == 0,
                };
                summary.prober_reaped_n += 1;
            }
            break;
        }
        // Neither a worker/health/prestop pid nor a known prober pid: an
        // inherited orphan (mandor is PID 1) — reaped and discarded silently,
        // same as before this change.
    }
}

// ---------------------------------------------------------------- tests

fn sleepMs(ms: u64) void {
    var ts: linux.timespec = .{ .sec = 0, .nsec = @intCast(ms * std.time.ns_per_ms) };
    _ = linux.nanosleep(&ts, null);
}

test "spawn, reap, classify exit and signal deaths" {
    var workers: [2]spawner.Worker = undefined;
    try spawner.initWorkers(workers[0..2], &.{ "/bin/true", "/bin/sleep 30" });
    const empty_env = [_:null]?[*:0]const u8{};
    const envp: [*:null]const ?[*:0]const u8 = &empty_env;

    try spawner.spawn(&workers[0], envp, "", 0, null);
    try spawner.spawn(&workers[1], envp, "", 0, null);
    try std.testing.expect(workers[0].pid > 0);
    try std.testing.expect(workers[1].pid > 0);

    // Let the child reach execve before signaling it, otherwise the SEGV
    // lands in the pre-exec fork child (which still shares our handlers).
    sleepMs(100);
    try posix.kill(workers[1].pid, .SEGV);

    var reaped: u8 = 0;
    var tries: u32 = 0;
    while (reaped < 2 and tries < 5000) : (tries += 1) {
        reaped += drain(workers[0..2], true, &.{}).reaped_workers;
        if (reaped < 2) sleepMs(1);
    }
    try std.testing.expectEqual(@as(u8, 2), reaped);
    try std.testing.expectEqual(spawner.Status{ .exited = 0 }, workers[0].status);
    try std.testing.expectEqual(
        spawner.Status{ .signaled = @intFromEnum(posix.SIG.SEGV) },
        workers[1].status,
    );
    try std.testing.expectEqual(@as(u8, 139), workers[1].final_code);
    try std.testing.expectEqual(@as(i32, 0), workers[1].pid);
}
