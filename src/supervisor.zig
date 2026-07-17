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
const capture = @import("capture.zig");
const ring = @import("ring.zig");
const sampler = @import("sampler.zig");

// Worker table lives in BSS, not on the stack: each worker embeds a 256 KB
// log ring, and untouched pages cost nothing until logs actually flow.
var workers_buf: [cli.max_workers]spawner.Worker = undefined;

pub fn nowMs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

pub fn run(cfg: cli.Config, environ: [:null]const ?[*:0]const u8) u8 {
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
    var next_sample_ms: u64 = nowMs() + sampler.interval_ms;

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

        var wake_at: u64 = next_sample_ms;
        if (!shutting_down and next_deadline != 0 and next_deadline < wake_at)
            wake_at = next_deadline;
        const now_for_timeout = nowMs();
        const timeout: i32 = if (wake_at <= now_for_timeout)
            0
        else
            @intCast(@min(wake_at - now_for_timeout, 3_600_000));

        var pfds: [1 + 2 * cli.max_workers]posix.pollfd = undefined;
        var owners: [1 + 2 * cli.max_workers]*spawner.Worker = undefined;
        var errs: [1 + 2 * cli.max_workers]bool = undefined;
        pfds[0] = .{ .fd = sigs.fd, .events = posix.POLL.IN, .revents = 0 };
        var nf: usize = 1;
        for (workers) |*w| {
            if (w.out_r >= 0) {
                pfds[nf] = .{ .fd = w.out_r, .events = posix.POLL.IN, .revents = 0 };
                owners[nf] = w;
                errs[nf] = false;
                nf += 1;
            }
            if (w.err_r >= 0) {
                pfds[nf] = .{ .fd = w.err_r, .events = posix.POLL.IN, .revents = 0 };
                owners[nf] = w;
                errs[nf] = true;
                nf += 1;
            }
        }
        _ = posix.poll(pfds[0..nf], timeout) catch 0;

        for (pfds[1..nf], 1..) |*pfd, i| {
            if (pfd.revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) != 0)
                readPipe(owners[i], errs[i]);
        }

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
                closePipes(w);
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

        const now_sample = nowMs();
        if (now_sample >= next_sample_ms) {
            next_sample_ms = now_sample + sampler.interval_ms;
            for (workers) |*w| {
                if (w.pid > 0) sampler.sample(&w.stats, w.pid, now_sample);
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

// ------------------------------------------------------- output capture

const EchoCtx = struct { w: *spawner.Worker, err: bool };

/// Ring-record the line and echo it, `[name] `-prefixed, to our own
/// stdout/stderr in a single write (atomic below PIPE_BUF).
fn echoLine(ctx: *EchoCtx, text: []const u8, flags: u8) void {
    _ = ctx.w.log.push(text, flags);
    var buf: [capture.max_line + spawner.name_cap + 8]u8 = undefined;
    const name = ctx.w.nameSlice();
    buf[0] = '[';
    @memcpy(buf[1..][0..name.len], name);
    buf[1 + name.len] = ']';
    buf[2 + name.len] = ' ';
    @memcpy(buf[3 + name.len ..][0..text.len], text);
    buf[3 + name.len + text.len] = '\n';
    const fd: i32 = if (flags & ring.flag_stderr != 0) 2 else 1;
    _ = linux.write(fd, &buf, 4 + name.len + text.len);
}

/// Drain a readable pipe until EAGAIN; on EOF flush partials and close.
fn readPipe(w: *spawner.Worker, is_err: bool) void {
    const fd = if (is_err) w.err_r else w.out_r;
    if (fd < 0) return;
    const asm_ptr = if (is_err) &w.asm_err else &w.asm_out;
    const base_flags: u8 = if (is_err) ring.flag_stderr else 0;
    var ctx: EchoCtx = .{ .w = w, .err = is_err };
    var chunk: [4096]u8 = undefined;
    while (true) {
        const rc = linux.read(fd, &chunk, chunk.len);
        switch (posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return, // EAGAIN: drained for now
        }
        if (rc == 0) { // EOF: writer side fully closed
            asm_ptr.flushEof(base_flags, &ctx, echoLine);
            if (is_err) capture.closeFd(&w.err_r) else capture.closeFd(&w.out_r);
            return;
        }
        asm_ptr.feed(base_flags, chunk[0..rc], &ctx, echoLine);
    }
}

/// Final drain + close at worker death. Data still in flight is read;
/// grandchildren keeping the pipe open lose their audience by design.
fn closePipes(w: *spawner.Worker) void {
    readPipe(w, false);
    readPipe(w, true);
    var ctx_out: EchoCtx = .{ .w = w, .err = false };
    w.asm_out.flushEof(0, &ctx_out, echoLine);
    var ctx_err: EchoCtx = .{ .w = w, .err = true };
    w.asm_err.flushEof(ring.flag_stderr, &ctx_err, echoLine);
    capture.closeFd(&w.out_r);
    capture.closeFd(&w.err_r);
}
