//! The supervision loop: a single-threaded poll on the signalfd, driving
//! spawning, reaping, signal forwarding, restart backoff, and shutdown.
//! Nothing in here may panic — PID 1 dying kills the container.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const cli = @import("cli.zig");
const backoff = @import("backoff.zig");
const signals = @import("signals.zig");
const spawner = @import("spawner.zig");
const reaper = @import("reaper.zig");

pub fn nowMs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

pub fn run(cfg: cli.Config, environ: [:null]const ?[*:0]const u8) u8 {
    var workers_buf: [cli.max_workers]spawner.Worker = undefined;
    const workers = workers_buf[0..cfg.commands.len];
    spawner.initWorkers(workers, cfg.commands) catch {
        std.debug.print("[mandor] invalid command line\n", .{});
        return 2;
    };
    const path_env = spawner.findPath(environ);
    const envp: [*:null]const ?[*:0]const u8 = environ.ptr;

    const sigs = signals.Signals.init() catch {
        std.debug.print("[mandor] cannot create signalfd\n", .{});
        return 2;
    };

    var shutting_down = false;
    var kill_escalated = false;

    for (workers) |*w| spawnWorker(w, envp, path_env);

    while (true) {
        var live: usize = 0;
        var pending: usize = 0;
        var next_deadline: u64 = 0;
        for (workers) |*w| {
            if (w.pid != 0) {
                live += 1;
            } else if (!w.done and w.next_restart_ms != 0) {
                pending += 1;
                if (next_deadline == 0 or w.next_restart_ms < next_deadline)
                    next_deadline = w.next_restart_ms;
            }
        }
        if (live == 0 and (shutting_down or pending == 0)) break;

        var timeout: i32 = -1;
        if (!shutting_down and next_deadline != 0) {
            const now = nowMs();
            timeout = if (next_deadline <= now)
                0
            else
                @intCast(@min(next_deadline - now, 3_600_000));
        }

        var pfd = [1]posix.pollfd{.{ .fd = sigs.fd, .events = posix.POLL.IN, .revents = 0 }};
        _ = posix.poll(&pfd, timeout) catch 0;

        const ev = sigs.drain();

        if (ev.term_or_int) |sig| {
            if (!shutting_down) {
                shutting_down = true;
                std.debug.print("[mandor] SIG{t} received, forwarding to workers\n", .{sig});
                forwardAll(workers, sig);
                for (workers) |*w| {
                    w.next_restart_ms = 0;
                    if (w.pid == 0) w.done = true;
                }
            } else if (!kill_escalated) {
                kill_escalated = true;
                std.debug.print("[mandor] second signal, sending SIGKILL\n", .{});
                forwardAll(workers, .KILL);
            }
        }
        if (ev.hup) forwardAll(workers, .HUP);

        if (ev.chld) {
            _ = reaper.drain(workers);
            const now = nowMs();
            for (workers) |*w| {
                if (w.pid != 0 or w.done or w.next_restart_ms != 0) continue;
                const clean = switch (w.status) {
                    .exited => |code| code == 0,
                    .signaled => false,
                    else => continue, // not_started/running: nothing new here
                };
                logDeath(w);
                if (!shutting_down and backoff.shouldRestart(cfg.restart, clean)) {
                    const uptime = now -| w.last_start_ms;
                    w.cur_delay_ms = backoff.next(w.cur_delay_ms, uptime, cfg.backoff_max_ms);
                    w.next_restart_ms = now + w.cur_delay_ms;
                    std.debug.print("[mandor] restarting {s} in {d}ms\n", .{
                        w.nameSlice(), w.cur_delay_ms,
                    });
                } else {
                    w.done = true;
                }
            }
        }

        if (!shutting_down) {
            const now = nowMs();
            for (workers) |*w| {
                if (w.done or w.pid != 0 or w.next_restart_ms == 0 or w.next_restart_ms > now)
                    continue;
                w.restarts += 1;
                spawnWorker(w, envp, path_env);
            }
        }
    }

    var worst: u8 = 0;
    for (workers) |*w| worst = @max(worst, w.final_code);
    return worst;
}

fn spawnWorker(
    w: *spawner.Worker,
    envp: [*:null]const ?[*:0]const u8,
    path_env: []const u8,
) void {
    spawner.spawn(w, envp, path_env, nowMs()) catch {
        std.debug.print("[mandor] fork failed for {s}\n", .{w.nameSlice()});
        w.done = true;
        w.final_code = 125;
        return;
    };
    std.debug.print("[mandor] spawned {s} (pid {d})\n", .{ w.nameSlice(), w.pid });
}

fn logDeath(w: *const spawner.Worker) void {
    switch (w.status) {
        .exited => |code| std.debug.print("[mandor] {s} exited with code {d}\n", .{
            w.nameSlice(), code,
        }),
        .signaled => |sig| std.debug.print("[mandor] {s} killed by signal {d}\n", .{
            w.nameSlice(), sig,
        }),
        else => {},
    }
}

fn forwardAll(workers: []spawner.Worker, sig: posix.SIG) void {
    for (workers) |*w| {
        if (w.pid > 0) posix.kill(w.pid, sig) catch {};
    }
}
