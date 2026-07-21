const std = @import("std");
const logmod = @import("log.zig");
const builtin = @import("builtin");
const cli = @import("cli.zig");

/// Size diet: a panic is a bug (the supervision path never panics by
/// design), so skip std.debug's DWARF/ELF/decompression stack-trace
/// machinery (~100 KB) — print the message and trap.
pub const panic = std.debug.FullPanic(rawPanic);
pub const std_options: std.Options = .{ .enable_segfault_handler = false };

/// Raw-syscall panic: message to stderr, immediate exit. Avoids
/// std.debug's stderr lock machinery (Progress + Io.Threaded vtable orbit).
fn rawPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    if (comptime builtin.os.tag == .linux) {
        const pre = "panic: ";
        _ = std.os.linux.write(2, pre, pre.len);
        _ = std.os.linux.write(2, msg.ptr, msg.len);
        _ = std.os.linux.write(2, "\n", 1);
        std.os.linux.exit(127);
    }
    @trap();
}

const build_options = @import("build_options");
const version = build_options.version;

const usage_text =
    \\mandor — the foreman for your containers
    \\
    \\usage:
    \\  mandor [flags] [--] "CMD" ["CMD" ...]     supervise workers
    \\  mandor report [NAME|PID] [--json]         live worker status
    \\  mandor report --incidents [NAME]          crash history (--incident=N dumps one)
    \\  mandor report --cost                      per-worker resource cost + right-sizing
    \\  mandor validate [--config=PATH]           check config without running
    \\  mandor --help | --version
    \\
    \\flags:
    \\  --max-restarts=N                    retry a failed worker N times (default: 0,
    \\                                      don't retry; -1 retries forever)
    \\  --config=PATH                       mandor.toml (default: ./mandor.toml if present)
    \\  --metrics=PORT                      Prometheus metrics on 127.0.0.1:PORT
    \\  --state-dir=PATH                    state + incident spool (or MANDOR_STATE_DIR)
    \\
    \\Workers are quoted command lines — no shell needed. Signals are forwarded
    \\(grandchildren included). A worker that fails is retried up to
    \\--max-restarts times; when retries run out mandor stops the rest
    \\gracefully and exits with that worker's code.
    \\These four flags are the whole CLI. Everything else — probes, drain
    \\hooks, per-worker settings, tuning — is a mandor.toml key with sane
    \\defaults; see `man mandor` or docs/CONFIG.md.
    \\
;

fn writeOut(text: []const u8) void {
    if (builtin.os.tag == .linux) {
        _ = std.os.linux.write(1, text.ptr, text.len);
    }
}

pub fn main(init: std.process.Init.Minimal) u8 {
    if (comptime builtin.os.tag != .linux) {
        logmod.print("mandor supervises processes on Linux only\n", .{});
        return 2;
    }

    const vec = init.args.vector; // []const [*:0]const u8 on Linux
    var args_buf: [cli.max_workers + 16][]const u8 = undefined;
    if (vec.len == 0 or vec.len - 1 > args_buf.len) {
        writeOut(usage_text);
        return 2;
    }
    // Invisible subcommand: `mandor relay <bundle.json>` (photon bridge).
    // The supervisor path never networks; this runs only when invoked.
    if (vec.len >= 3 and std.mem.eql(u8, std.mem.span(vec[1]), "relay")) {
        const endpoint: ?[]const u8 = if (vec.len >= 4) std.mem.span(vec[3]) else null;
        return @import("relay.zig").run(vec[2], endpoint, init.environ.block.slice);
    }

    for (vec[1..], 0..) |p, i| args_buf[i] = std.mem.span(p);
    const args = args_buf[0 .. vec.len - 1];

    var cmd_storage: [cli.max_workers][]const u8 = undefined;
    var cfg: cli.Config = undefined;
    cli.parse(args, &cmd_storage, &cfg) catch |err| {
        logmod.print("[mandor] {s}\n\n", .{switch (err) {
            error.UnknownFlag => "unknown flag",
            error.BadValue => "bad flag value",
            error.TooManyWorkers => "too many workers (max 64)",
            // Removed flags get an answer, not just a rejection.
            error.RestartRemoved => "--restart was removed: use --max-restarts=N " ++
                "(0 = don't retry, the default; -1 = retry forever)",
            error.UnhealthyFlagRemoved => "--restart-on-unhealthy was removed: " ++
                "a configured health probe is always acted on",
            error.MovedToToml => "that setting moved to mandor.toml (same name, no " ++
                "dashes). The CLI keeps only --max-restarts, --config, --metrics " ++
                "and --state-dir; see `man mandor` or docs/CONFIG.md",
        }});
        writeOut(usage_text);
        return 2;
    };
    if (cfg.help) {
        writeOut(usage_text);
        return 0;
    }
    if (cfg.version) {
        writeOut("mandor " ++ version ++ "\n");
        return 0;
    }

    const environ = init.environ.block.slice;
    const spawner = @import("spawner.zig");

    // Config file (TOML < env < CLI). CLI-only always works; the implicit
    // ./mandor.toml is best-effort, an explicit --config= must exist.
    const config = @import("config.zig");
    var file_cfg: config.FileConfig = .{};
    var file_cmds: [cli.max_workers][]const u8 = undefined;
    if (cfg.mode == .supervise or cfg.mode == .validate) {
        var text: ?[]const u8 = null;
        if (cfg.config_path) |path| {
            text = readSmallFile(path, &config_buf) orelse {
                logmod.print("[mandor] cannot read config file {s}\n", .{path});
                return 2;
            };
        } else {
            text = readSmallFile("mandor.toml", &config_buf);
        }
        if (text) |txt| {
            config.parse(txt, &file_cmds, &file_cfg) catch |err| {
                logmod.print("[mandor] invalid config file: {s}\n", .{switch (err) {
                    error.RestartRemoved => "'restart' was removed — use max_restarts = N " ++
                        "(0 = don't retry, the default; -1 = retry forever). A worker whose " ++
                        "death should not stop the run takes essential = false",
                    error.UnhealthyKeyRemoved => "'restart_on_unhealthy' was removed — " ++
                        "a configured health probe is always acted on",
                    error.Syntax => "syntax",
                    error.BadValue => "bad value",
                    error.TooManyWorkers => "too many workers (max 64)",
                }});
                return 2;
            };
            if (file_cfg.backoff_max_ms) |b| cfg.backoff_max_ms = b;
            if (cfg.metrics_port == null) cfg.metrics_port = file_cfg.metrics_port;
            if (file_cfg.stop_grace_ms) |g| cfg.stop_grace_ms = g;
            if (file_cfg.expected_exit) |set| cfg.expected_exit = set;
            if (cfg.ready_fd == null) cfg.ready_fd = file_cfg.ready_fd;
            if (file_cfg.health_interval_ms) |ms| cfg.health_interval_ms = ms;
            cfg.health = file_cfg.health;
            cfg.health_n = file_cfg.health_n;
            cfg.start_after = file_cfg.start_after;
            cfg.start_after_n = file_cfg.start_after_n;
            if (!cfg.max_restarts_set) {
                if (file_cfg.max_restarts) |m| cfg.max_restarts = m;
            }
            if (file_cfg.health_start_period_ms) |ms| cfg.health_start_period_ms = ms;
            if (cfg.on_incident == null) cfg.on_incident = file_cfg.on_incident;
            if (cfg.photon == null) cfg.photon = file_cfg.photon;
            if (cfg.psi_mem_pct == 0) {
                if (file_cfg.psi_mem_pct) |v| cfg.psi_mem_pct = v;
            }
            if (cfg.psi_cpu_pct == 0) {
                if (file_cfg.psi_cpu_pct) |v| cfg.psi_cpu_pct = v;
            }
            cfg.not_essential = file_cfg.not_essential;
            cfg.not_essential_n = file_cfg.not_essential_n;
            if (file_cfg.restart_dependents) |b| cfg.restart_dependents = b;
            cfg.prestop_pairs = file_cfg.prestop_pairs;
            cfg.prestop_pairs_n = file_cfg.prestop_pairs_n;
            if (cfg.env_file == null) cfg.env_file = file_cfg.env_file;
            cfg.env_pairs = file_cfg.env_pairs;
            cfg.env_pairs_n = file_cfg.env_pairs_n;
            cfg.cwd_pairs = file_cfg.cwd_pairs;
            cfg.cwd_pairs_n = file_cfg.cwd_pairs_n;
            cfg.oneshot = file_cfg.oneshot;
            cfg.oneshot_n = file_cfg.oneshot_n;
            cfg.user_pairs = file_cfg.user_pairs;
            cfg.user_pairs_n = file_cfg.user_pairs_n;
            cfg.cap_drop_pairs = file_cfg.cap_drop_pairs;
            cfg.cap_drop_pairs_n = file_cfg.cap_drop_pairs_n;
            cfg.oom_pairs = file_cfg.oom_pairs;
            cfg.oom_pairs_n = file_cfg.oom_pairs_n;
            cfg.nice_pairs = file_cfg.nice_pairs;
            cfg.nice_pairs_n = file_cfg.nice_pairs_n;
            cfg.max_rss_pairs = file_cfg.max_rss_pairs;
            cfg.max_rss_pairs_n = file_cfg.max_rss_pairs_n;
            cfg.lifetime_pairs = file_cfg.lifetime_pairs;
            cfg.lifetime_pairs_n = file_cfg.lifetime_pairs_n;
            cfg.expected_pairs = file_cfg.expected_pairs;
            cfg.expected_pairs_n = file_cfg.expected_pairs_n;
            if (cfg.commands.len == 0) cfg.commands = file_cfg.commands;
        }
        if (cfg.env_file) |path| {
            const ef_text = readSmallFile(path, &envfile_buf) orelse {
                logmod.print("[mandor] cannot read env_file {s}\n", .{path});
                return 2;
            };
            var lines = std.mem.splitScalar(u8, ef_text, '\n');
            while (lines.next()) |raw| {
                const line = std.mem.trim(u8, raw, " \t\r");
                if (line.len == 0 or line[0] == '#') continue;
                if (std.mem.indexOfScalar(u8, line, '=') == null) continue;
                const spawner2 = @import("spawner.zig");
                if (!spawner2.addGlobalEnv(line))
                    logmod.print("[mandor] env_file overflow, ignoring: {s}\n", .{line});
            }
        }
        if (cfg.commands.len == 0) {
            logmod.print("[mandor] no worker commands given\n\n", .{});
            writeOut(usage_text);
            return 2;
        }
    }

    const state_dir = cfg.state_dir orelse
        (spawner.findEnv(environ, "MANDOR_STATE_DIR") orelse
            (file_cfg.state_dir orelse cli.default_state_dir));

    if (cfg.mode == .report) {
        if (cfg.cost) return runCostReport(state_dir, cfg.json);
        if (cfg.incidents) return runIncidentList(state_dir, cfg.report_filter, cfg.since_ms, cfg.incident_index);
        return runReport(state_dir, cfg.json, cfg.report_filter);
    }

    const supervisor = @import("supervisor.zig");
    if (cfg.mode == .validate) return supervisor.validate(&cfg);
    return supervisor.run(&cfg, state_dir, environ);
}

var config_buf: [64 * 1024]u8 = undefined;
var envfile_buf: [8 * 1024]u8 = undefined;
var incident_entries: [256]@import("spool.zig").DirEntry = undefined;

/// `mandor report --incidents` — recall the spooled history (survives
/// restarts when the state dir is a mounted volume).
fn readIncidentFile(state_dir: []const u8, e: *const @import("spool.zig").DirEntry) ?[]const u8 {
    const linux = std.os.linux;
    var path_buf: [640]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/incidents/{s}", .{
        state_dir, e.name[0..e.name_len],
    }) catch return null;
    const rc = linux.openat(linux.AT.FDCWD, path.ptr, .{}, 0);
    if (std.posix.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const got = linux.read(fd, &report_read_buf, report_read_buf.len);
    if (std.posix.errno(got) != .SUCCESS) return null;
    return report_read_buf[0..got];
}

/// `mandor report --incidents [NAME] [--since=DUR]` lists history (survives
/// restarts on a mounted volume); `--incident=N` dumps bundle N raw JSON.
fn runIncidentList(state_dir: []const u8, filter: ?[]const u8, since_ms: ?u64, index: ?usize) u8 {
    const spool = @import("spool.zig");
    const report = @import("report.zig");
    const supervisor = @import("supervisor.zig");
    const cutoff_ms: u64 = if (since_ms) |s| supervisor.wallMs() -| s else 0;
    const n = spool.listIncidents(state_dir, &incident_entries);
    if (n == 0) {
        logmod.print("[mandor] no incidents in {s}/incidents\n", .{state_dir});
        return 0;
    }
    if (index) |want| {
        if (want == 0 or want > n) {
            logmod.print("[mandor] no incident #{d} (have 1..{d})\n", .{ want, n });
            return 1;
        }
        const text = readIncidentFile(state_dir, &incident_entries[want - 1]) orelse return 1;
        writeOut(text);
        writeOut("\n");
        return 0;
    }
    var out_pos: usize = 0;
    const jb = @import("jsonbuf.zig");
    _ = jb.appendf(&report_out_buf, &out_pos, "{d} incident(s) in {s}/incidents (oldest first)\n\n", .{ n, state_dir });
    _ = jb.appendf(&report_out_buf, &out_pos, "{s:>3} {s:<21} {s:<14} {s:<14} {s}\n", .{ "#", "TIME", "WORKER", "CAUSE", "VERDICT" });
    for (incident_entries[0..n], 1..) |*e, idx| {
        if (e.key < cutoff_ms) continue; // filename prefix = epoch ms
        const text = readIncidentFile(state_dir, e) orelse continue;
        if (filter) |f| {
            const bname = report.scanStr(text, "name") orelse "";
            if (!std.mem.eql(u8, bname, f)) continue;
        }
        _ = jb.appendf(&report_out_buf, &out_pos, "{d:>3} {s:<21} {s:<14} {s:<14} {s}", .{
            idx,
            report.scanStr(text, "ts") orelse "?",
            report.scanStr(text, "name") orelse "?",
            report.scanStr(text, "cause_str") orelse "?",
            report.scanStr(text, "verdict") orelse "?",
        });
        // Release correlation: flag a crash that survived a code change.
        if (std.mem.indexOf(u8, text, "\"regressed\":true") != null) {
            _ = jb.appendf(&report_out_buf, &out_pos, "  [REGRESSED {s}->{s}]", .{
                report.scanStr(text, "first_build") orelse "?",
                report.scanStr(text, "last_build") orelse "?",
            });
        }
        _ = jb.appendf(&report_out_buf, &out_pos, "\n", .{});
    }
    writeOut(report_out_buf[0..out_pos]);
    return 0;
}

fn readSmallFile(path: []const u8, buf: []u8) ?[]const u8 {
    const linux = std.os.linux;
    var path_buf: [512]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return null;
    const rc = linux.openat(linux.AT.FDCWD, path_z.ptr, .{}, 0);
    if (std.posix.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const n = linux.read(fd, buf.ptr, buf.len);
    if (std.posix.errno(n) != .SUCCESS) return null;
    return buf[0..n];
}

var report_read_buf: [256 * 1024]u8 = undefined;
var report_out_buf: [64 * 1024]u8 = undefined;

var cost_out_buf: [64 * 1024]u8 = undefined;

/// `mandor report --cost` — per-worker resource cost + right-sizing. `--json`
/// passes the raw cost.json (for the LLM/premium agent) untouched.
fn runCostReport(state_dir: []const u8, json: bool) u8 {
    const costmod = @import("cost.zig");
    const text = costmod.readState(state_dir) orelse {
        logmod.print("[mandor] no cost data at {s}/cost.json yet\n", .{state_dir});
        return 1;
    };
    if (json) {
        writeOut(text);
        return 0;
    }
    writeOut(costmod.formatHuman(&cost_out_buf, text));
    return 0;
}

fn runReport(state_dir: []const u8, json: bool, filter: ?[]const u8) u8 {
    const report = @import("report.zig");
    const supervisor = @import("supervisor.zig");
    const text = report.readState(state_dir, &report_read_buf) catch {
        logmod.print("[mandor] no state at {s}/state.json — is a supervisor running with this state dir?\n", .{state_dir});
        return 1;
    };
    if (json) {
        writeOut(text);
        return 0;
    }
    const human = report.formatHuman(&report_out_buf, text, supervisor.nowMs(), filter) orelse {
        logmod.print("[mandor] state file is corrupt or from an incompatible version\n", .{});
        return 1;
    };
    writeOut(human);
    return 0;
}

test {
    _ = @import("cli.zig");
    _ = @import("backoff.zig");
    _ = @import("config.zig");
    _ = @import("ring.zig");
    _ = @import("capture.zig");
    _ = @import("sampler.zig");
    _ = @import("jsonbuf.zig");
    _ = @import("cgroup.zig");
    _ = @import("summarize.zig");
    _ = @import("detector.zig");
    _ = @import("parsers/go.zig");
    _ = @import("parsers/rust.zig");
    _ = @import("parsers/python.zig");
    _ = @import("parsers/node.zig");
    _ = @import("parsers/java.zig");
    _ = @import("parsers/zigp.zig");
    _ = @import("caps.zig");
    _ = @import("cost.zig");
    _ = @import("fuzz.zig");
    // relay.zig is only @imported inside a subcommand branch, so it never
    // reaches the test graph on its own — which is exactly why it shipped
    // with no coverage. Reference it explicitly.
    _ = @import("relay.zig");
    if (builtin.os.tag == .linux) {
        _ = @import("signals.zig");
        _ = @import("spawner.zig");
        _ = @import("reaper.zig");
        _ = @import("report.zig");
        _ = @import("spool.zig");
        _ = @import("metrics.zig");
        _ = @import("elf.zig");
        _ = @import("history.zig");
    }
}
