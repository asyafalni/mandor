//! The supervision loop: a single-threaded poll on the signalfd, driving
//! spawning, reaping, signal forwarding, restart backoff, and shutdown.
//! Nothing in here may panic — PID 1 dying kills the container.

const std = @import("std");
const logmod = @import("log.zig");
const linux = std.os.linux;
const posix = std.posix;
const cli = @import("cli.zig");
const backoff = @import("backoff.zig");
const detector = @import("detector.zig");
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
const cost = @import("cost.zig");

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

/// Worker-table + per-worker config application shared by run() and
/// validate(): worker init, the pair-settings table, essential/oneshot
/// flags, and the start_after dependency graph (with cycle check). Fills
/// `dep_of`; returns an exit code on any hard error, else null.
/// Unknown-worker-name references seen during the last applyConfig — a
/// warning for run() (setting ignored, keep supervising) but a hard failure
/// for validate() (typo detection is the point).
var setup_warnings: u32 = 0;

fn applyConfig(
    cfg: *const cli.Config,
    workers: []spawner.Worker,
    dep_of: *[cli.max_workers]?u8,
    oneshot_count: *usize,
) ?u8 {
    setup_warnings = 0;
    spawner.initWorkers(workers, cfg.commands) catch {
        logmod.print("[mandor] invalid command line\n", .{});
        return 2;
    };
    // One table drives every "name=value" per-worker setting: unknown worker
    // warns, bad value fails startup (fail-fast on typos beats silence).
    const pair_actions = [_]struct {
        pairs: []const cli.HealthSpec,
        label: []const u8,
        apply: *const fn (*spawner.Worker, []const u8) bool,
    }{
        .{ .pairs = cfg.env_pairs[0..cfg.env_pairs_n], .label = "env", .apply = applyEnv },
        .{ .pairs = cfg.cwd_pairs[0..cfg.cwd_pairs_n], .label = "cwd", .apply = applyCwd },
        .{ .pairs = cfg.user_pairs[0..cfg.user_pairs_n], .label = "user", .apply = applyUser },
        .{ .pairs = cfg.cap_drop_pairs[0..cfg.cap_drop_pairs_n], .label = "cap_drop", .apply = applyCapDrop },
        .{ .pairs = cfg.oom_pairs[0..cfg.oom_pairs_n], .label = "oom_score_adj", .apply = applyOom },
        .{ .pairs = cfg.nice_pairs[0..cfg.nice_pairs_n], .label = "nice", .apply = applyNice },
        .{ .pairs = cfg.max_rss_pairs[0..cfg.max_rss_pairs_n], .label = "max_rss_mb", .apply = applyMaxRss },
        .{ .pairs = cfg.lifetime_pairs[0..cfg.lifetime_pairs_n], .label = "max_lifetime", .apply = applyLifetime },
        .{ .pairs = cfg.expected_pairs[0..cfg.expected_pairs_n], .label = "expected_exit", .apply = applyExpected },
        .{ .pairs = cfg.prestop_pairs[0..cfg.prestop_pairs_n], .label = "pre_stop", .apply = applyPreStop },
        .{ .pairs = cfg.health[0..cfg.health_n], .label = "health", .apply = applyHealth },
    };
    for (pair_actions) |action| {
        for (action.pairs) |pair| {
            const w = findWorker(workers, pair.worker) orelse {
                logmod.print("[mandor] {s}: no worker named {s}\n", .{ action.label, pair.worker });
                setup_warnings += 1;
                continue;
            };
            if (!action.apply(w, pair.cmd)) {
                logmod.print("[mandor] {s}: bad value for {s}\n", .{ action.label, pair.worker });
                return 2;
            }
        }
    }
    // Every worker is essential unless it opted out: a failure that exhausts
    // retries must reach the orchestrator, so silence is never the default.
    for (workers) |*w| w.essential = true;
    for (cfg.not_essential[0..cfg.not_essential_n]) |name| {
        if (findWorker(workers, name)) |w| {
            w.essential = false;
        } else {
            logmod.print("[mandor] essential: no worker named {s}\n", .{name});
            setup_warnings += 1;
        }
    }
    oneshot_count.* = 0;
    for (cfg.oneshot[0..cfg.oneshot_n]) |name| {
        if (findWorker(workers, name)) |w| {
            w.is_oneshot = true;
            oneshot_count.* += 1;
        } else {
            logmod.print("[mandor] oneshot: no worker named {s}\n", .{name});
            setup_warnings += 1;
        }
    }
    // A oneshot's failure always aborts startup, so `essential` never applies
    // to it. Silently ignoring the key is how contradictory config goes
    // unnoticed, so say so and stop.
    for (workers) |*w| {
        if (w.is_oneshot and !w.essential) {
            logmod.print("[mandor] {s}: 'essential' is meaningless on a oneshot — " ++
                "an init task's failure always stops startup\n", .{w.nameSlice()});
            return 2;
        }
    }
    // start-after ordering: dep_of[i] = worker index i must wait for.
    for (cfg.start_after[0..cfg.start_after_n]) |pair| {
        var dependent: ?usize = null;
        var dependency: ?usize = null;
        for (workers, 0..) |*w, i| {
            if (std.mem.eql(u8, w.nameSlice(), pair.worker)) dependent = i;
            if (std.mem.eql(u8, w.nameSlice(), pair.cmd)) dependency = i;
        }
        if (dependent == null or dependency == null or dependent.? == dependency.?) {
            logmod.print("[mandor] start_after: bad pair {s}={s}\n", .{ pair.worker, pair.cmd });
            return 2;
        }
        dep_of[dependent.?] = @intCast(dependency.?);
    }
    for (0..workers.len) |start_i| {
        var cur = dep_of[start_i];
        var steps: usize = 0;
        while (cur) |c| : (steps += 1) {
            if (steps > workers.len) {
                logmod.print("[mandor] start_after: dependency cycle\n", .{});
                return 2;
            }
            cur = dep_of[c];
        }
    }
    if (cfg.on_incident) |cmd| {
        if (!incident.setHook(cmd)) {
            logmod.print("[mandor] invalid on-incident command\n", .{});
            return 2;
        }
    }
    if (cfg.photon) |endpoint| {
        if (@import("relay.zig").parseHostPort(endpoint) == null) {
            logmod.print("[mandor] invalid photon endpoint (want ip:port)\n", .{});
            return 2;
        }
    }
    return null;
}

/// `mandor validate` — apply the full config to the worker table without
/// spawning anything, then report. Exit 0 = config is sound.
pub fn validate(cfg: *const cli.Config) u8 {
    const workers = workers_buf[0..cfg.commands.len];
    var dep_of: [cli.max_workers]?u8 = .{null} ** cli.max_workers;
    var oneshot_count: usize = 0;
    if (applyConfig(cfg, workers, &dep_of, &oneshot_count)) |code| {
        logmod.print("[mandor] config invalid\n", .{});
        return code;
    }
    if (setup_warnings > 0) {
        logmod.print("[mandor] config invalid: {d} unknown worker reference(s)\n", .{setup_warnings});
        return 1;
    }
    printPlan(cfg, workers, &dep_of);
    return 0;
}

/// One-time summary of the resolved lifecycle, printed by both `run` and
/// `validate`. This is how the model reaches people who never open the docs:
/// it lands in `docker logs` / `kubectl logs` on every deployment.
///
/// Deliberately quiet — a worker with default lifecycle prints nothing, so a
/// plain two-worker config produces exactly one line. Two format strings for
/// the whole plan is also deliberate: each distinct format instantiates its
/// own copy of the `std.fmt` machinery.
fn printPlan(cfg: *const cli.Config, workers: []const spawner.Worker, dep_of: []const ?u8) void {
    var buf: [96]u8 = undefined;
    const summary: []const u8 = if (cfg.max_restarts == 0)
        "a failure ends the run (max_restarts=0)"
    else if (cfg.max_restarts < 0)
        "failed workers retry forever (max_restarts=-1)"
    else
        std.fmt.bufPrint(&buf, "a failed worker retries {d}x, then the run ends", .{
            cfg.max_restarts,
        }) catch "retries are bounded";
    logmod.print("[mandor] {d} worker(s) | {s}\n", .{ workers.len, summary });

    for (workers, 0..) |*w, i| {
        if (w.is_oneshot) planLine(w, "init task — runs first, failure aborts startup");
        if (!w.essential) planLine(w, "essential=false — its failure will not end the run");
        if (dep_of[i]) |di| {
            var dep_buf: [96]u8 = undefined;
            planLine(w, std.fmt.bufPrint(&dep_buf, "starts after {s}", .{
                workers[di].nameSlice(),
            }) catch "starts after a dependency");
        }
        if (w.has_health) planLine(w, "health probe — 3 failures stop the worker");
    }
}

fn planLine(w: *const spawner.Worker, note: []const u8) void {
    logmod.print("[mandor]   {s}: {s}\n", .{ w.nameSlice(), note });
}

pub fn run(cfg: *const cli.Config, state_dir: []const u8, environ: [:null]const ?[*:0]const u8) u8 {
    const workers = workers_buf[0..cfg.commands.len];
    var dep_of: [cli.max_workers]?u8 = .{null} ** cli.max_workers;
    var oneshot_count: usize = 0;
    if (applyConfig(cfg, workers, &dep_of, &oneshot_count)) |code| return code;
    printPlan(cfg, workers, &dep_of);

    tty_out = if (posix.tcgetattr(1)) |_| true else |_| false;
    tty_err = if (posix.tcgetattr(2)) |_| true else |_| false;
    const path_env = spawner.findPath(environ);
    const envp: [*:null]const ?[*:0]const u8 = environ.ptr;

    const sigs = signals.Signals.init() catch {
        logmod.print("[mandor] cannot create signalfd\n", .{});
        return 2;
    };

    incident.initSnapshot(state_dir, environ);
    var name_slots: [cli.max_workers][]const u8 = undefined;
    for (workers, 0..) |*w, i| name_slots[i] = w.nameSlice();
    cost.init(state_dir, name_slots[0..workers.len]);
    if (cfg.photon) |endpoint| {
        _ = incident.setPhoton(endpoint);
        logmod.print("[mandor] forwarding incidents to photon at {s}\n", .{endpoint});
    }
    var give_up_code: ?u8 = null;

    var waiting: [cli.max_workers]bool = .{false} ** cli.max_workers;

    var shutting_down = false;
    var kill_escalated = false;
    var shutdown_deadline_ms: u64 = 0;
    const run_start_ms = nowMs();
    var next_sample_ms: u64 = run_start_ms + sampler.interval_ms;
    var sample_tick: u32 = 0;
    var oom_kills: u64 = cgroup.readOomKills() orelse 0;
    var stall_det: detector.StallState = .{};
    const metrics_server: ?metrics.Server = if (cfg.metrics_port) |port| blk: {
        const srv = metrics.Server.init(port);
        if (srv == null)
            logmod.print("[mandor] cannot bind metrics port {d}; continuing without\n", .{port})
        else
            logmod.print("[mandor] metrics on 127.0.0.1:{d}\n", .{port});
        break :blk srv;
    } else null;

    // Set when a spawn fails: the death path must run even without a SIGCHLD,
    // since no child was ever created to report one.
    var spawn_deaths = false;

    for (workers, 0..) |*w, i| {
        if (dep_of[i] != null or (oneshot_count > 0 and !w.is_oneshot)) {
            waiting[i] = true;
            logmod.print("[mandor] {s} waits for {s}\n", .{
                w.nameSlice(),
                if (dep_of[i]) |di| workers[di].nameSlice() else "init tasks",
            });
        } else {
            spawnWorker(w, envp, path_env, cfg.ready_fd);
            if (w.spawn_failed) spawn_deaths = true;
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
            } else if (!w.done and w.spawn_failed) {
                // Spawn failed and the death path has not run yet: real work
                // is outstanding, so the fleet is not finished. Counted here
                // rather than added to the break condition below — an extra
                // term there makes the compiler duplicate the loop body and
                // costs ~6 KB.
                pending += 1;
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
                var ok = true;
                if (dep_of[i]) |di| {
                    const dep = &workers[di];
                    const up = dep.ready or
                        (dep.pid > 0 and now_dep -| dep.last_start_ms >= 1000);
                    if (dep.done and !up) logmod.print("[mandor] {s} is gone; starting {s} anyway\n", .{
                        dep.nameSlice(), w.nameSlice(),
                    });
                    ok = up or dep.done;
                }
                if (ok and !w.is_oneshot) ok = allOneshotsDone(workers);
                if (ok) {
                    waiting[i] = false;
                    spawnWorker(w, envp, path_env, cfg.ready_fd);
                    if (w.spawn_failed) spawn_deaths = true;
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
                const di = dep_of[i] orelse continue; // oneshot-gated: chld-driven
                const dep = &workers[di];
                if (dep.pid > 0) {
                    const t = dep.last_start_ms + 1000;
                    if (t < wake_at) wake_at = t;
                }
            }
        }
        const now_for_timeout = nowMs();
        const timeout: i32 = if (spawn_deaths or wake_at <= now_for_timeout)
            0 // a pending spawn-death must be handled now, not one tick later
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
                logmod.print("[mandor] SIG{t} received, forwarding to workers\n", .{sig});
                stopWorkers(workers, envp, path_env, sig);
                for (workers, 0..) |*w, i| {
                    w.next_restart_ms = 0;
                    waiting[i] = false;
                    if (w.pid == 0) w.done = true;
                }
            } else if (!kill_escalated) {
                kill_escalated = true;
                logmod.print("[mandor] second signal, sending SIGKILL\n", .{});
                killAll(workers);
            }
        }
        if (shutting_down and !kill_escalated and shutdown_deadline_ms != 0 and
            nowMs() >= shutdown_deadline_ms)
        {
            kill_escalated = true;
            logmod.print("[mandor] stop-grace expired, sending SIGKILL\n", .{});
            killAll(workers);
        }
        for (ev.pass[0..ev.pass_n]) |sig| forwardAll(workers, sig);

        if (ev.chld or spawn_deaths) {
            spawn_deaths = false;
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
                var clean = switch (w.status) {
                    .exited => |code| expectedFor(w, cfg, code),
                    .signaled => false,
                    else => continue, // not_started/running: nothing new here
                };
                const was_recycle = w.recycling;
                if (was_recycle) {
                    w.recycling = false;
                    clean = true; // planned recycling is never a failure
                    w.final_code = 0;
                }
                if (w.health_killed) {
                    // We killed it because its probe failed. That is a failure
                    // whatever code it exited with — otherwise `expected_exit`
                    // containing 143 (the usual graceful-shutdown code) would
                    // silently turn a hung worker into a successful run.
                    w.health_killed = false;
                    clean = false;
                }
                if (clean) w.final_code = 0; // expected codes count as success
                const uptime_ms = now -| w.last_start_ms;
                w.fail_streak = if (clean)
                    0
                else if (uptime_ms >= backoff.stable_uptime_ms) 1 else w.fail_streak + 1;
                closePipes(w);
                logDeath(w);
                var loop_detected = false;
                if (!shutting_down and !clean) {
                    w.det.recordDeath(now);
                    incident.onDeath(state_dir, workers, w, now, oom_hit);
                    if (w.det.restartLoopTriggered(now)) |count| {
                        incident.onRestartLoop(state_dir, workers, w, count, now);
                        loop_detected = true;
                    }
                }
                if (w.is_oneshot) {
                    // Init task: never restarted. Success unblocks the fleet;
                    // failure takes the whole container down, visibly.
                    w.done = true;
                    if (clean) {
                        logmod.print("[mandor] init task {s} completed\n", .{w.nameSlice()});
                    } else if (!shutting_down) {
                        logmod.print("[mandor] init task {s} failed, shutting down\n", .{w.nameSlice()});
                        beginShutdown(workers, &waiting, envp, path_env, &shutting_down, &shutdown_deadline_ms, &give_up_code, now, cfg.stop_grace_ms, w.final_code);
                    }
                    continue;
                }
                if (!shutting_down and was_recycle) {
                    // planned recycle: always come back, immediately
                    w.next_restart_ms = now;
                    continue;
                }
                // Only failures are retried — a clean exit means the worker
                // finished. A detected restart loop stops retrying too: the
                // fail-streak resets after 10s of uptime, so a worker crashing
                // every 11s would otherwise retry forever and never signal.
                if (!shutting_down and !clean and !loop_detected and
                    retriesLeft(cfg.max_restarts, w.fail_streak))
                {
                    w.cur_delay_ms = backoff.next(w.cur_delay_ms, now -| w.last_start_ms, cfg.backoff_max_ms);
                    w.next_restart_ms = now + w.cur_delay_ms;
                    logmod.print("[mandor] restarting {s} in {d}ms\n", .{
                        w.nameSlice(), w.cur_delay_ms,
                    });
                } else {
                    w.done = true;
                }
                // A failure that will not be retried ends the run, propagating
                // the worker's code, so the layer above is signalled. A worker
                // marked `essential = false` is exempt — but mandor still says
                // it has stopped trying, because silently abandoning a worker
                // is the same invisible degradation this release exists to
                // remove; it is only the *scope* that the opt-out changes.
                if (w.done and !clean and !shutting_down) {
                    // One format string; the varying parts are composed first.
                    // Separate formats each cost their own copy of std.fmt.
                    var why_buf: [48]u8 = undefined;
                    const why: []const u8 = if (loop_detected)
                        "is in a restart loop"
                    else if (cfg.max_restarts != 0)
                        std.fmt.bufPrint(&why_buf, "failed {d} restart(s)", .{
                            cfg.max_restarts,
                        }) catch "failed"
                    else
                        "failed";
                    const what: []const u8 = if (w.essential)
                        "stopping all"
                    else
                        "not restarting it (essential = false)";
                    logmod.print("[mandor] {s} {s}, {s}\n", .{ w.nameSlice(), why, what });
                    if (w.essential)
                        beginShutdown(workers, &waiting, envp, path_env, &shutting_down, &shutdown_deadline_ms, &give_up_code, now, cfg.stop_grace_ms, w.final_code);
                }
            }
        }

        // preStop ordering: a finished drain hook (recorded by the reaper
        // just above) releases its worker's TERM in the same iteration.
        if (shutting_down) {
            for (workers) |*w| {
                if (w.prestop_done and w.pid > 0) {
                    w.prestop_done = false;
                    posix.kill(-w.pid, .TERM) catch {
                        posix.kill(w.pid, .TERM) catch {};
                    };
                }
            }
        }

        if (!shutting_down) {
            const now = nowMs();
            for (workers, 0..) |*w, wi| {
                if (w.done or w.pid != 0 or w.next_restart_ms == 0 or w.next_restart_ms > now)
                    continue;
                w.restarts += 1;
                spawnWorker(w, envp, path_env, cfg.ready_fd);
                if (w.spawn_failed) spawn_deaths = true;
                // OTP rest_for_one (opt-in): a dependency's restart recycles
                // its live dependents — planned, never counted as failure.
                if (cfg.restart_dependents) {
                    for (workers, 0..) |*dep_w, di| {
                        if (dep_w.pid <= 0 or dep_w.recycling) continue;
                        var cur = dep_of[di];
                        var hops: usize = 0;
                        while (cur) |c| : (hops += 1) {
                            if (hops > workers.len) break;
                            if (c == wi) {
                                logmod.print("[mandor] restarting {s} with its dependency {s}\n", .{
                                    dep_w.nameSlice(), w.nameSlice(),
                                });
                                dep_w.recycling = true;
                                posix.kill(-dep_w.pid, .TERM) catch {};
                                break;
                            }
                            cur = dep_of[c];
                        }
                    }
                }
            }
        }

        const now_sample = nowMs();
        if (now_sample >= next_sample_ms) {
            next_sample_ms = now_sample + sampler.interval_ms;
            sample_tick +%= 1;
            const psi = sampler.readPsi(); // container-wide, read once per tick
            const wall = wallMs();
            for (workers, 0..) |*w, i| {
                if (w.pid > 0) {
                    sampler.sample(&w.stats, w.pid, now_sample, psi);
                    const s = w.stats.at(w.stats.len - 1);
                    cost.get(i).update(s.rss_kb, s.cpu_pct, s.fds, s.threads, sampler.interval_ms, wall);
                    if (w.det.leakCheck(&w.stats, now_sample)) |info|
                        incident.onLeak(state_dir, workers, w, info, now_sample);
                    checkRecycle(w, now_sample);
                }
            }
            // PSI stall is container-scoped: check once, attribute the
            // incident to the largest consumer of the pressured resource.
            if (stall_det.stallCheck(psi, cfg.psi_mem_pct, cfg.psi_cpu_pct, now_sample)) |res|
                incident.onStall(state_dir, workers, res, psi, now_sample);
            // Near-zero idle footprint: deaths flush state immediately, so
            // the periodic freshness write only needs to run every 30 s.
            if (sample_tick % 6 == 0) {
                report.writeState(state_dir, workers, now_sample);
                cost.save(state_dir);
            }
        }
    }

    report.writeState(state_dir, workers, nowMs());
    cost.save(state_dir);
    emitDigest(workers, run_start_ms);

    var worst: u8 = 0;
    for (workers) |*w| worst = @max(worst, w.final_code);
    // On give-up, report the flapping worker's code — not the TERM fallout
    // from shutting its siblings down.
    return give_up_code orelse worst;
}

/// Planned recycling (pm2 max_memory_restart heritage): thresholds crossed
/// ⇒ graceful TERM to the group; the death path sees `recycling` and
/// restarts without counting failure or spooling an incident.
fn checkRecycle(w: *spawner.Worker, now_ms: u64) void {
    if (w.recycling) return;
    var reason: ?[]const u8 = null;
    if (w.max_rss_kb) |cap| {
        if (w.stats.len > 0 and w.stats.at(w.stats.len - 1).rss_kb > cap) reason = "rss over limit";
    }
    if (reason == null) {
        if (w.max_lifetime_ms) |cap| {
            if (now_ms -| w.last_start_ms > cap) reason = "max lifetime reached";
        }
    }
    if (reason) |r| {
        logmod.print("[mandor] recycling {s}: {s}\n", .{ w.nameSlice(), r });
        w.recycling = true;
        posix.kill(-w.pid, .TERM) catch {};
    }
}

// Per-worker setting appliers for the setup table (false = bad value).
fn applyEnv(w: *spawner.Worker, v: []const u8) bool {
    return spawner.addEnv(w, v);
}
fn applyCwd(w: *spawner.Worker, v: []const u8) bool {
    return spawner.setCwd(w, v);
}
fn applyUser(w: *spawner.Worker, v: []const u8) bool {
    return spawner.setUser(w, v);
}
fn applyCapDrop(w: *spawner.Worker, v: []const u8) bool {
    return spawner.setCapDrop(w, v);
}
fn applyOom(w: *spawner.Worker, v: []const u8) bool {
    w.oom_adj = std.fmt.parseInt(i16, v, 10) catch return false;
    return true;
}
fn applyNice(w: *spawner.Worker, v: []const u8) bool {
    w.nice_val = std.fmt.parseInt(i8, v, 10) catch return false;
    return true;
}
fn applyMaxRss(w: *spawner.Worker, v: []const u8) bool {
    const mb = std.fmt.parseInt(u64, v, 10) catch return false;
    w.max_rss_kb = mb * 1024;
    return true;
}
fn applyLifetime(w: *spawner.Worker, v: []const u8) bool {
    w.max_lifetime_ms = cli.parseDuration(v) orelse return false;
    return true;
}
fn applyExpected(w: *spawner.Worker, v: []const u8) bool {
    var set = [1]bool{true} ++ [1]bool{false} ** 255;
    if (!cli.parseExpectedExit(v, &set)) return false; // reject junk at startup
    w.expected_bits = .{0} ** 32;
    for (set, 0..) |ok, code| {
        if (ok) w.expected_bits[code >> 3] |= @as(u8, 1) << @intCast(code & 7);
    }
    w.expected_set = true;
    return true;
}
fn applyPreStop(w: *spawner.Worker, v: []const u8) bool {
    spawner.setPreStop(w, v) catch return false;
    return true;
}
fn applyHealth(w: *spawner.Worker, v: []const u8) bool {
    spawner.setHealth(w, v) catch return false;
    return true;
}

fn findWorker(workers: []spawner.Worker, name: []const u8) ?*spawner.Worker {
    for (workers) |*w| {
        if (std.mem.eql(u8, w.nameSlice(), name)) return w;
    }
    return null;
}

fn allOneshotsDone(workers: []spawner.Worker) bool {
    for (workers) |*w| {
        if (w.is_oneshot and !w.done) return false;
    }
    return true;
}

const health_timeout_ms: u64 = 10_000;
const health_fail_threshold: u8 = 3;

/// Drive health probes: consume results, time out hung probes, start due
/// ones, and declare workers unhealthy at the failure threshold.
fn runHealth(
    cfg: *const cli.Config,
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
                w.health_ever_ok = true;
            } else if (!w.health_ever_ok and
                now -| w.last_start_ms < cfg.health_start_period_ms)
            {
                // start-period grace: slow booters aren't failures yet
            } else {
                w.health_fails += 1;
                logmod.print("[mandor] health check failed for {s} ({d}/{d})\n", .{
                    w.nameSlice(), w.health_fails, health_fail_threshold,
                });
                if (w.health_fails >= health_fail_threshold and w.pid > 0) {
                    // A configured probe is always acted on — detecting a hung
                    // worker and leaving it running would be the quietest
                    // failure mandor could produce.
                    w.health_fails = 0;
                    incident.onUnhealthy(state_dir, workers, w, health_fail_threshold, now);
                    logmod.print("[mandor] {s} unhealthy, sending SIGTERM\n", .{w.nameSlice()});
                    w.health_killed = true;
                    posix.kill(-w.pid, .TERM) catch {};
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

/// On failure sets `w.spawn_failed` and stages a synthetic death; the caller
/// must then let the death path run so it is handled like any other death.
fn spawnWorker(
    w: *spawner.Worker,
    envp: [*:null]const ?[*:0]const u8,
    path_env: []const u8,
    ready_fd: ?u8,
) void {
    spawner.spawn(w, envp, path_env, nowMs(), ready_fd) catch {
        // A failed spawn is reported as a death rather than handled here.
        // Every terminal-state rule — restart policy and backoff, `essential`
        // leader semantics, `oneshot` gating — lives on the death path, so
        // retiring the worker here would silently bypass all of them: a
        // transient EAGAIN would become permanent, an essential worker that
        // never started would not stop the fleet, and a failed init task
        // would read as a completed one and release its dependents.
        w.pid = 0;
        w.status = .{ .exited = spawn_fail_code };
        w.final_code = spawn_fail_code;
        w.spawn_failed = true;
        return;
    };
    w.spawn_failed = false;
    logmod.print("[mandor] spawned {s} (pid {d})\n", .{ w.nameSlice(), w.pid });
}

/// Exit code stamped on a worker that could not be spawned at all.
const spawn_fail_code: u8 = 125;

/// Is a *failed* worker still allowed a retry? `0` means no retries at all,
/// `-1` means unlimited, `N` allows N.
fn retriesLeft(max_restarts: i32, fail_streak: u32) bool {
    if (max_restarts < 0) return true;
    if (max_restarts == 0) return false;
    return fail_streak <= @as(u32, @intCast(max_restarts));
}

/// Does `code` count as success for this worker? A per-worker `expected_exit`
/// replaces the global set; parsing here keeps it off the hot path and out of
/// per-worker storage.
fn expectedFor(w: *const spawner.Worker, cfg: *const cli.Config, code: u8) bool {
    if (!w.expected_set) return cfg.expected_exit[code];
    return w.expected_bits[code >> 3] & (@as(u8, 1) << @intCast(code & 7)) != 0;
}

/// Start a graceful fleet shutdown propagating `code`: pre_stop hooks run
/// first, then TERM, and the stop-grace deadline escalates to KILL. One place
/// because three call sites (oneshot failure, unretried failure, and the
/// give-up path) must behave identically.
fn beginShutdown(
    workers: []spawner.Worker,
    waiting: []bool,
    envp: [*:null]const ?[*:0]const u8,
    path_env: []const u8,
    shutting_down: *bool,
    deadline_ms: *u64,
    give_up_code: *?u8,
    now: u64,
    grace_ms: u64,
    code: u8,
) void {
    give_up_code.* = code;
    shutting_down.* = true;
    deadline_ms.* = now + grace_ms;
    stopWorkers(workers, envp, path_env, .TERM);
    for (workers, 0..) |*other, oi| {
        other.next_restart_ms = 0;
        waiting[oi] = false;
        if (other.pid == 0) other.done = true;
    }
}

fn logDeath(w: *const spawner.Worker) void {
    if (w.spawn_failed) {
        // It never ran, so "exited with code 125" would be a lie.
        logmod.print("[mandor] {s} failed to start (fork failed)\n", .{w.nameSlice()});
        return;
    }
    switch (w.status) {
        .exited => |code| logmod.print("[mandor] {s} exited with code {d}\n", .{
            w.nameSlice(), code,
        }),
        .signaled => |sig| logmod.print("[mandor] {s} killed by signal {d}\n", .{
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

/// Shift report: one consolidated summary of the whole run, emitted to
/// stdout at shutdown. A human (`kubectl logs`) or an AI post-mortem sees
/// what happened across the container's life without scraping N incident
/// files. Zero config, always on; reuses the worker table + cost profiles.
fn emitDigest(workers: []spawner.Worker, run_start_ms: u64) void {
    const dur_s = (nowMs() -| run_start_ms) / 1000;
    var total_restarts: u32 = 0;
    for (workers) |*w| total_restarts += w.restarts;
    logmod.print("[mandor] shift report — {d} worker(s), {d}s run, {d} restart(s), {d} incident(s)\n", .{
        workers.len, dur_s, total_restarts, incident.total,
    });
    for (workers, 0..) |*w, i| {
        const s = cost.get(i).summary();
        logmod.print("[mandor]   {s}: exit {d}, {d} restart(s), peak {d}MB, {d}.{d:0>2} GB-h\n", .{
            w.nameSlice(), w.final_code, w.restarts, s.peak_rss_mb, s.gb_hours / 100, s.gb_hours % 100,
        });
    }
}

/// Escalation: KILL workers AND any still-running drain hooks.
fn killAll(workers: []spawner.Worker) void {
    forwardAll(workers, .KILL);
    for (workers) |*w| {
        if (w.prestop_pid > 0) posix.kill(w.prestop_pid, .KILL) catch {};
    }
}

/// Graceful stop with preStop ordering: hooked workers get their drain
/// command first — the TERM follows when the hook exits (or stop-grace
/// KILLs everything, hooks included). Un-hooked workers get the signal now.
fn stopWorkers(
    workers: []spawner.Worker,
    envp: [*:null]const ?[*:0]const u8,
    path_env: []const u8,
    sig: posix.SIG,
) void {
    for (workers) |*w| {
        if (w.pid <= 0) continue;
        if (w.has_prestop and w.prestop_pid == 0 and !w.prestop_done) {
            if (spawner.spawnPreStop(w, envp, path_env)) {
                logmod.print("[mandor] running pre_stop for {s}\n", .{w.nameSlice()});
                continue;
            }
        }
        posix.kill(-w.pid, sig) catch {
            posix.kill(w.pid, sig) catch {};
        };
    }
}

// ------------------------------------------------------- output capture

const EchoCtx = struct { w: *spawner.Worker, err: bool, t_ms: u64 = 0 };

/// Ring-record the line and echo it, `[name] `-prefixed, to our own
/// stdout/stderr in a single write (atomic below PIPE_BUF).
var tty_out = false;
var tty_err = false;

// nanozlog-inspired batching: lines from one pipe read are formatted into a
// shared scratch and flushed with a single writev — one syscall (and one
// wall-clock read) per chunk instead of per line. Single-threaded, so the
// statics are safe; flushEcho() runs before scratch or iovec can overflow.
var echo_scratch: [64 * 1024]u8 = undefined;
var echo_used: usize = 0;
var echo_iov: [128]posix.iovec_const = undefined;
var echo_iov_n: usize = 0;

// Shared read buffer sized to a pipe's default capacity (64 KB) so a full
// pipe drains in one read() under log spam instead of ~16. BSS, not stack —
// single-threaded and fully consumed before the next read, so one buffer
// serves every worker/pipe. read()'s return value bounds valid bytes.
var read_buf: [64 * 1024]u8 = undefined;

fn flushEcho(ctx: *EchoCtx) void {
    if (echo_iov_n == 0) return;
    const fd: usize = if (ctx.err) 2 else 1;
    _ = linux.writev(@intCast(fd), &echo_iov, echo_iov_n);
    echo_iov_n = 0;
    echo_used = 0;
}

fn echoLine(ctx: *EchoCtx, text: []const u8, flags: u8) void {
    _ = ctx.w.log.push(text, flags, ctx.t_ms);
    const name = ctx.w.nameSlice();
    const max_needed = text.len + spawner.name_cap + 24;
    if (echo_used + max_needed > echo_scratch.len or echo_iov_n == echo_iov.len)
        flushEcho(ctx);
    const buf = echo_scratch[echo_used..];
    const colored = if (ctx.err) tty_err else tty_out;
    var p: usize = 0;
    if (colored) {
        // \x1b[3Xm[name]\x1b[0m — 8-color cycle per worker, TTY only
        const esc = [_]u8{ 0x1b, '[', '3', '0' + (ctx.w.color - 30), 'm' };
        @memcpy(buf[p..][0..esc.len], &esc);
        p += esc.len;
    }
    buf[p] = '[';
    @memcpy(buf[p + 1 ..][0..name.len], name);
    buf[p + 1 + name.len] = ']';
    p += 2 + name.len;
    if (colored) {
        @memcpy(buf[p..][0..4], "\x1b[0m");
        p += 4;
    }
    buf[p] = ' ';
    @memcpy(buf[p + 1 ..][0..text.len], text);
    buf[p + 1 + text.len] = '\n';
    echo_iov[echo_iov_n] = .{ .base = buf.ptr, .len = p + 2 + text.len };
    echo_iov_n += 1;
    echo_used += p + 2 + text.len;
}

/// Drain a readable pipe until EAGAIN; on EOF flush partials and close.
fn readPipe(w: *spawner.Worker, is_err: bool) void {
    const fd = if (is_err) w.err_r else w.out_r;
    if (fd < 0) return;
    const asm_ptr = if (is_err) &w.asm_err else &w.asm_out;
    const base_flags: u8 = if (is_err) ring.flag_stderr else 0;
    var ctx: EchoCtx = .{ .w = w, .err = is_err, .t_ms = wallMs() };
    defer flushEcho(&ctx); // one writev per drained pipe
    while (true) {
        const rc = linux.read(fd, &read_buf, read_buf.len);
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
        asm_ptr.feed(base_flags, read_buf[0..rc], &ctx, echoLine);
    }
}

/// First byte on the readiness fd marks the worker ready; EOF without a
/// byte means it never signaled (or doesn't speak the protocol) — fine.
fn readReady(w: *spawner.Worker) void {
    var byte: [16]u8 = undefined;
    const rc = linux.read(w.ready_r, &byte, byte.len);
    if (posix.errno(rc) == .SUCCESS and rc > 0) {
        if (!w.ready) logmod.print("[mandor] {s} is ready\n", .{w.nameSlice()});
        w.ready = true;
    }
    capture.closeFd(&w.ready_r); // one-shot either way
}

/// Final drain + close at worker death. Data still in flight is read;
/// grandchildren keeping the pipe open lose their audience by design.
fn closePipes(w: *spawner.Worker) void {
    readPipe(w, false);
    readPipe(w, true);
    const now_wall = wallMs();
    var ctx_out: EchoCtx = .{ .w = w, .err = false, .t_ms = now_wall };
    w.asm_out.flushEof(0, &ctx_out, echoLine);
    flushEcho(&ctx_out);
    var ctx_err: EchoCtx = .{ .w = w, .err = true, .t_ms = now_wall };
    w.asm_err.flushEof(ring.flag_stderr, &ctx_err, echoLine);
    flushEcho(&ctx_err);
    capture.closeFd(&w.out_r);
    capture.closeFd(&w.err_r);
    capture.closeFd(&w.ready_r);
}
