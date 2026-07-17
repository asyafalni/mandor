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
const report = @import("report.zig");
const incident = @import("incident.zig");
const cgroup = @import("cgroup.zig");
const metrics = @import("metrics.zig");

// Worker table lives in BSS, not on the stack: each worker embeds a 256 KB
// log ring, and untouched pages cost nothing until logs actually flow.
var workers_buf: [cli.max_workers]spawner.Worker = undefined;

pub fn nowMs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

/// Wall-clock ms since epoch (vDSO — cheap enough per log line).
pub fn wallMs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

pub fn run(cfg: cli.Config, state_dir: []const u8, environ: [:null]const ?[*:0]const u8) u8 {
    const workers = workers_buf[0..cfg.commands.len];
    spawner.initWorkers(workers, cfg.commands) catch {
        std.debug.print("[mandor] invalid command line\n", .{});
        return 2;
    };
    for (cfg.health[0..cfg.health_n]) |spec| {
        var matched = false;
        for (workers) |*w| {
            if (std.mem.eql(u8, w.nameSlice(), spec.worker)) {
                spawner.setHealth(w, spec.cmd) catch {
                    std.debug.print("[mandor] invalid health command for {s}\n", .{spec.worker});
                    return 2;
                };
                matched = true;
                break;
            }
        }
        if (!matched)
            std.debug.print("[mandor] --health: no worker named {s}\n", .{spec.worker});
    }
    const path_env = spawner.findPath(environ);
    const envp: [*:null]const ?[*:0]const u8 = environ.ptr;

    const sigs = signals.Signals.init() catch {
        std.debug.print("[mandor] cannot create signalfd\n", .{});
        return 2;
    };

    incident.initSnapshot(environ);

    // start-after ordering: dep_of[i] = worker index i must wait for.
    var dep_of: [cli.max_workers]?u8 = .{null} ** cli.max_workers;
    var waiting: [cli.max_workers]bool = .{false} ** cli.max_workers;
    for (cfg.start_after[0..cfg.start_after_n]) |pair| {
        var dependent: ?usize = null;
        var dependency: ?usize = null;
        for (workers, 0..) |*w, i| {
            if (std.mem.eql(u8, w.nameSlice(), pair.worker)) dependent = i;
            if (std.mem.eql(u8, w.nameSlice(), pair.cmd)) dependency = i;
        }
        if (dependent == null or dependency == null or dependent.? == dependency.?) {
            std.debug.print("[mandor] start_after: bad pair {s}={s}\n", .{ pair.worker, pair.cmd });
            return 2;
        }
        dep_of[dependent.?] = @intCast(dependency.?);
    }
    for (0..workers.len) |start_i| {
        var cur = dep_of[start_i];
        var steps: usize = 0;
        while (cur) |c| : (steps += 1) {
            if (steps > workers.len) {
                std.debug.print("[mandor] start_after: dependency cycle\n", .{});
                return 2;
            }
            cur = dep_of[c];
        }
    }

    var shutting_down = false;
    var kill_escalated = false;
    var shutdown_deadline_ms: u64 = 0;
    var next_sample_ms: u64 = nowMs() + sampler.interval_ms;
    var sample_tick: u32 = 0;
    var oom_kills: u64 = cgroup.readOomKills() orelse 0;
    const metrics_server: ?metrics.Server = if (cfg.metrics_port) |port| blk: {
        const srv = metrics.Server.init(port);
        if (srv == null)
            std.debug.print("[mandor] cannot bind metrics port {d}; continuing without\n", .{port})
        else
            std.debug.print("[mandor] metrics on 127.0.0.1:{d}\n", .{port});
        break :blk srv;
    } else null;

    for (workers, 0..) |*w, i| {
        if (dep_of[i] != null) {
            waiting[i] = true;
            std.debug.print("[mandor] {s} waits for {s}\n", .{
                w.nameSlice(), workers[dep_of[i].?].nameSlice(),
            });
        } else {
            spawnWorker(w, envp, path_env, cfg.ready_fd);
        }
    }
    report.writeState(state_dir, workers, nowMs());

    while (true) {
        var live: usize = 0;
        var pending: usize = 0;
        var next_deadline: u64 = 0;
        for (workers, 0..) |*w, i| {
            if (w.pid != 0) {
                live += 1;
            } else if (waiting[i]) {
                pending += 1;
            } else if (!w.done and w.next_restart_ms != 0) {
                pending += 1;
                if (next_deadline == 0 or w.next_restart_ms < next_deadline)
                    next_deadline = w.next_restart_ms;
            }
        }
        if (live == 0 and (shutting_down or pending == 0)) break;

        // Deferred starts: a dependency is "up" once ready (readiness fd) or
        // simply alive for 1 s; a permanently-dead dependency unblocks its
        // dependents rather than deadlocking them.
        if (!shutting_down) {
            const now_dep = nowMs();
            for (workers, 0..) |*w, i| {
                if (!waiting[i]) continue;
                const dep = &workers[dep_of[i].?];
                const up = dep.ready or (dep.pid > 0 and now_dep -| dep.last_start_ms >= 1000);
                if (up or dep.done) {
                    if (dep.done) std.debug.print("[mandor] {s} is gone; starting {s} anyway\n", .{
                        dep.nameSlice(), w.nameSlice(),
                    });
                    waiting[i] = false;
                    spawnWorker(w, envp, path_env, cfg.ready_fd);
                }
            }
        }

        // Before computing the poll timeout so first probes schedule
        // immediately after a (re)spawn.
        if (!shutting_down) runHealth(cfg, workers, state_dir, envp, path_env);

        var wake_at: u64 = next_sample_ms;
        if (!shutting_down and next_deadline != 0 and next_deadline < wake_at)
            wake_at = next_deadline;
        if (!shutting_down) {
            for (workers) |*w| {
                if (!w.has_health or w.pid == 0) continue;
                if (w.health_pid != 0) {
                    const to = w.health_started_ms + health_timeout_ms;
                    if (to < wake_at) wake_at = to;
                } else if (w.next_health_ms != 0 and w.next_health_ms < wake_at) {
                    wake_at = w.next_health_ms;
                }
            }
        }
        if (shutting_down and !kill_escalated and shutdown_deadline_ms != 0 and
            shutdown_deadline_ms < wake_at)
            wake_at = shutdown_deadline_ms;
        if (!shutting_down) {
            for (0..workers.len) |i| {
                if (!waiting[i]) continue;
                const dep = &workers[dep_of[i].?];
                if (dep.pid > 0) {
                    const t = dep.last_start_ms + 1000;
                    if (t < wake_at) wake_at = t;
                }
            }
        }
        const now_for_timeout = nowMs();
        const timeout: i32 = if (wake_at <= now_for_timeout)
            0
        else
            @intCast(@min(wake_at - now_for_timeout, 3_600_000));

        const PollKind = enum { out, err, ready };
        var pfds: [2 + 3 * cli.max_workers]posix.pollfd = undefined;
        var owners: [2 + 3 * cli.max_workers]*spawner.Worker = undefined;
        var kinds: [2 + 3 * cli.max_workers]PollKind = undefined;
        pfds[0] = .{ .fd = sigs.fd, .events = posix.POLL.IN, .revents = 0 };
        var nf: usize = 1;
        var metrics_idx: usize = 0; // 0 = not in the set
        if (metrics_server) |srv| {
            pfds[nf] = .{ .fd = srv.fd, .events = posix.POLL.IN, .revents = 0 };
            metrics_idx = nf;
            nf += 1;
        }
        for (workers) |*w| {
            if (w.out_r >= 0) {
                pfds[nf] = .{ .fd = w.out_r, .events = posix.POLL.IN, .revents = 0 };
                owners[nf] = w;
                kinds[nf] = .out;
                nf += 1;
            }
            if (w.err_r >= 0) {
                pfds[nf] = .{ .fd = w.err_r, .events = posix.POLL.IN, .revents = 0 };
                owners[nf] = w;
                kinds[nf] = .err;
                nf += 1;
            }
            if (w.ready_r >= 0) {
                pfds[nf] = .{ .fd = w.ready_r, .events = posix.POLL.IN, .revents = 0 };
                owners[nf] = w;
                kinds[nf] = .ready;
                nf += 1;
            }
        }
        _ = posix.poll(pfds[0..nf], timeout) catch 0;

        for (pfds[1..nf], 1..) |*pfd, i| {
            if (pfd.revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) == 0) continue;
            if (i == metrics_idx) {
                metrics_server.?.onReadable(workers, incident.total);
            } else switch (kinds[i]) {
                .out => readPipe(owners[i], false),
                .err => readPipe(owners[i], true),
                .ready => readReady(owners[i]),
            }
        }

        const ev = sigs.drain();

        if (ev.term_or_int) |sig| {
            if (!shutting_down) {
                shutting_down = true;
                shutdown_deadline_ms = nowMs() + cfg.stop_grace_ms;
                std.debug.print("[mandor] SIG{t} received, forwarding to workers\n", .{sig});
                forwardAll(workers, sig);
                for (workers, 0..) |*w, i| {
                    w.next_restart_ms = 0;
                    waiting[i] = false;
                    if (w.pid == 0) w.done = true;
                }
            } else if (!kill_escalated) {
                kill_escalated = true;
                std.debug.print("[mandor] second signal, sending SIGKILL\n", .{});
                forwardAll(workers, .KILL);
            }
        }
        if (shutting_down and !kill_escalated and shutdown_deadline_ms != 0 and
            nowMs() >= shutdown_deadline_ms)
        {
            kill_escalated = true;
            std.debug.print("[mandor] stop-grace expired, sending SIGKILL\n", .{});
            forwardAll(workers, .KILL);
        }
        for (ev.pass[0..ev.pass_n]) |sig| forwardAll(workers, sig);

        if (ev.chld) {
            const reaped = reaper.drain(workers).reaped_workers;
            const now = nowMs();
            if (reaped > 0) report.writeState(state_dir, workers, now);
            var oom_hit = false;
            if (reaped > 0) {
                const cur = cgroup.readOomKills() orelse oom_kills;
                oom_hit = cur > oom_kills;
                oom_kills = cur;
            }
            for (workers) |*w| {
                if (w.pid != 0 or w.done or w.next_restart_ms != 0) continue;
                const clean = switch (w.status) {
                    .exited => |code| cfg.expected_exit[code],
                    .signaled => false,
                    else => continue, // not_started/running: nothing new here
                };
                if (clean) w.final_code = 0; // expected codes count as success
                closePipes(w);
                logDeath(w);
                if (!shutting_down and !clean) {
                    w.det.recordDeath(now);
                    incident.onDeath(state_dir, workers, w, now, oom_hit);
                    if (w.det.restartLoopTriggered(now)) |count|
                        incident.onRestartLoop(state_dir, workers, w, count, now);
                }
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
                spawnWorker(w, envp, path_env, cfg.ready_fd);
            }
        }

        const now_sample = nowMs();
        if (now_sample >= next_sample_ms) {
            next_sample_ms = now_sample + sampler.interval_ms;
            sample_tick +%= 1;
            for (workers) |*w| {
                if (w.pid > 0) {
                    sampler.sample(&w.stats, w.pid, now_sample);
                    if (w.det.leakCheck(&w.stats, now_sample)) |info|
                        incident.onLeak(state_dir, workers, w, info, now_sample);
                }
            }
            // Near-zero idle footprint: deaths flush state immediately, so
            // the periodic freshness write only needs to run every 30 s.
            if (sample_tick % 6 == 0) report.writeState(state_dir, workers, now_sample);
        }
    }

    report.writeState(state_dir, workers, nowMs());

    var worst: u8 = 0;
    for (workers) |*w| worst = @max(worst, w.final_code);
    return worst;
}

const health_timeout_ms: u64 = 10_000;
const health_fail_threshold: u8 = 3;

/// Drive health probes: consume results, time out hung probes, start due
/// ones, and declare workers unhealthy at the failure threshold.
fn runHealth(
    cfg: cli.Config,
    workers: []spawner.Worker,
    state_dir: []const u8,
    envp: [*:null]const ?[*:0]const u8,
    path_env: []const u8,
) void {
    const now = nowMs();
    for (workers) |*w| {
        if (!w.has_health) continue;
        if (w.health_done) {
            w.health_done = false;
            if (w.health_ok) {
                w.health_fails = 0;
            } else {
                w.health_fails += 1;
                std.debug.print("[mandor] health check failed for {s} ({d}/{d})\n", .{
                    w.nameSlice(), w.health_fails, health_fail_threshold,
                });
                if (w.health_fails >= health_fail_threshold and w.pid > 0) {
                    w.health_fails = 0;
                    incident.onUnhealthy(state_dir, workers, w, health_fail_threshold, now);
                    if (cfg.restart_on_unhealthy) {
                        std.debug.print("[mandor] {s} unhealthy, sending SIGTERM\n", .{w.nameSlice()});
                        posix.kill(-w.pid, .TERM) catch {};
                    }
                }
            }
        }
        if (w.pid == 0) continue;
        if (w.health_pid == 0 and w.next_health_ms == 0) {
            // freshly (re)spawned: first probe one interval from now
            w.next_health_ms = now + cfg.health_interval_ms;
        }
        if (w.health_pid != 0 and now -| w.health_started_ms > health_timeout_ms) {
            posix.kill(w.health_pid, .KILL) catch {}; // reaped as a failure
        }
        if (w.health_pid == 0 and w.next_health_ms != 0 and now >= w.next_health_ms) {
            w.next_health_ms = now + cfg.health_interval_ms;
            _ = spawner.spawnCheck(w, envp, path_env, now);
        }
    }
}

fn spawnWorker(
    w: *spawner.Worker,
    envp: [*:null]const ?[*:0]const u8,
    path_env: []const u8,
    ready_fd: ?u8,
) void {
    spawner.spawn(w, envp, path_env, nowMs(), ready_fd) catch {
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
        // Negative pid = the worker's whole process group (set at spawn), so
        // grandchildren under a shell wrapper receive the signal too.
        if (w.pid > 0) posix.kill(-w.pid, sig) catch {
            posix.kill(w.pid, sig) catch {};
        };
    }
}

// ------------------------------------------------------- output capture

const EchoCtx = struct { w: *spawner.Worker, err: bool };

/// Ring-record the line and echo it, `[name] `-prefixed, to our own
/// stdout/stderr in a single write (atomic below PIPE_BUF).
fn echoLine(ctx: *EchoCtx, text: []const u8, flags: u8) void {
    _ = ctx.w.log.push(text, flags, wallMs());
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

/// First byte on the readiness fd marks the worker ready; EOF without a
/// byte means it never signaled (or doesn't speak the protocol) — fine.
fn readReady(w: *spawner.Worker) void {
    var byte: [16]u8 = undefined;
    const rc = linux.read(w.ready_r, &byte, byte.len);
    if (posix.errno(rc) == .SUCCESS and rc > 0) {
        if (!w.ready) std.debug.print("[mandor] {s} is ready\n", .{w.nameSlice()});
        w.ready = true;
    }
    capture.closeFd(&w.ready_r); // one-shot either way
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
    capture.closeFd(&w.ready_r);
}
