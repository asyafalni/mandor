const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");

const version = "0.1.0-dev";

const usage_text =
    \\mandor — the foreman for your containers
    \\
    \\usage:
    \\  mandor [flags] [--] "CMD" ["CMD" ...]     supervise workers
    \\  mandor report [--json | --incidents]      live status / crash history
    \\  mandor --help | --version
    \\
    \\flags:
    \\  --restart=never|on-failure|always   restart crashed workers (default: never)
    \\  --config=PATH                       mandor.toml (default: ./mandor.toml if present)
    \\  --health="NAME=CMD"                 liveness probe for a worker (exit 0 = healthy)
    \\  --metrics=PORT                      Prometheus metrics on 127.0.0.1:PORT
    \\
    \\Workers are quoted command lines — no shell needed. Signals are forwarded
    \\(grandchildren included); mandor exits with the worst worker exit code.
    \\Everything else has sane defaults; advanced flags (--backoff-max,
    \\--stop-grace, --expected-exit, --state-dir, --ready-fd, --health-interval,
    \\--restart-on-unhealthy) are in the README.
    \\
;

fn writeOut(text: []const u8) void {
    if (builtin.os.tag == .linux) {
        _ = std.os.linux.write(1, text.ptr, text.len);
    }
}

pub fn main(init: std.process.Init.Minimal) u8 {
    if (comptime builtin.os.tag != .linux) {
        std.debug.print("mandor supervises processes on Linux only\n", .{});
        return 2;
    }

    const vec = init.args.vector; // []const [*:0]const u8 on Linux
    var args_buf: [cli.max_workers + 16][]const u8 = undefined;
    if (vec.len == 0 or vec.len - 1 > args_buf.len) {
        writeOut(usage_text);
        return 2;
    }
    for (vec[1..], 0..) |p, i| args_buf[i] = std.mem.span(p);
    const args = args_buf[0 .. vec.len - 1];

    var cmd_storage: [cli.max_workers][]const u8 = undefined;
    var cfg = cli.parse(args, &cmd_storage) catch |err| {
        std.debug.print("[mandor] {s}\n\n", .{switch (err) {
            error.UnknownFlag => "unknown flag",
            error.BadValue => "bad flag value",
            error.TooManyWorkers => "too many workers (max 64)",
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
    if (cfg.mode == .supervise) {
        var text: ?[]const u8 = null;
        if (cfg.config_path) |path| {
            text = readSmallFile(path, &config_buf) orelse {
                std.debug.print("[mandor] cannot read config file {s}\n", .{path});
                return 2;
            };
        } else {
            text = readSmallFile("mandor.toml", &config_buf);
        }
        if (text) |txt| {
            file_cfg = config.parse(txt, &file_cmds) catch |err| {
                std.debug.print("[mandor] invalid config file: {s}\n", .{@errorName(err)});
                return 2;
            };
            if (!cfg.restart_set) {
                if (file_cfg.restart) |r| cfg.restart = r;
            }
            if (!cfg.backoff_set) {
                if (file_cfg.backoff_max_ms) |b| cfg.backoff_max_ms = b;
            }
            if (cfg.metrics_port == null) cfg.metrics_port = file_cfg.metrics_port;
            if (!cfg.stop_grace_set) {
                if (file_cfg.stop_grace_ms) |g| cfg.stop_grace_ms = g;
            }
            if (!cfg.expected_exit_set) {
                if (file_cfg.expected_exit) |set| cfg.expected_exit = set;
            }
            if (cfg.ready_fd == null) cfg.ready_fd = file_cfg.ready_fd;
            if (!cfg.health_interval_set) {
                if (file_cfg.health_interval_ms) |ms| cfg.health_interval_ms = ms;
            }
            if (file_cfg.restart_on_unhealthy) |b| {
                if (b) cfg.restart_on_unhealthy = true;
            }
            if (cfg.health_n == 0) {
                cfg.health = file_cfg.health;
                cfg.health_n = file_cfg.health_n;
            }
            cfg.start_after = file_cfg.start_after;
            cfg.start_after_n = file_cfg.start_after_n;
            if (cfg.commands.len == 0) cfg.commands = file_cfg.commands;
        }
        if (cfg.commands.len == 0) {
            std.debug.print("[mandor] no worker commands given\n\n", .{});
            writeOut(usage_text);
            return 2;
        }
    }

    const state_dir = cfg.state_dir orelse
        (spawner.findEnv(environ, "MANDOR_STATE_DIR") orelse
            (file_cfg.state_dir orelse cli.default_state_dir));

    if (cfg.mode == .report) {
        if (cfg.incidents) return runIncidentList(state_dir);
        return runReport(state_dir, cfg.json);
    }

    const supervisor = @import("supervisor.zig");
    return supervisor.run(cfg, state_dir, environ);
}

var config_buf: [64 * 1024]u8 = undefined;
var incident_entries: [256]@import("spool.zig").DirEntry = undefined;

/// `mandor report --incidents` — recall the spooled history (survives
/// restarts when the state dir is a mounted volume).
fn runIncidentList(state_dir: []const u8) u8 {
    const spool = @import("spool.zig");
    const report = @import("report.zig");
    const linux = std.os.linux;
    const n = spool.listIncidents(state_dir, &incident_entries);
    if (n == 0) {
        std.debug.print("[mandor] no incidents in {s}/incidents\n", .{state_dir});
        return 0;
    }
    var out_pos: usize = 0;
    const jb = @import("jsonbuf.zig");
    _ = jb.appendf(&report_out_buf, &out_pos, "{d} incident(s) in {s}/incidents (oldest first)\n\n", .{ n, state_dir });
    _ = jb.appendf(&report_out_buf, &out_pos, "{s:<21} {s:<14} {s:<14} {s}\n", .{ "TIME", "WORKER", "CAUSE", "VERDICT" });
    for (incident_entries[0..n]) |*e| {
        var path_buf: [640]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "{s}/incidents/{s}", .{
            state_dir, e.name[0..e.name_len],
        }) catch continue;
        const rc = linux.openat(linux.AT.FDCWD, path.ptr, .{}, 0);
        if (std.posix.errno(rc) != .SUCCESS) continue;
        const fd: i32 = @intCast(rc);
        const got = linux.read(fd, &report_read_buf, report_read_buf.len);
        _ = linux.close(fd);
        if (std.posix.errno(got) != .SUCCESS) continue;
        const text = report_read_buf[0..got];
        _ = jb.appendf(&report_out_buf, &out_pos, "{s:<21} {s:<14} {s:<14} {s}\n", .{
            report.scanStr(text, "ts") orelse "?",
            report.scanStr(text, "name") orelse "?",
            report.scanStr(text, "cause_str") orelse "?",
            report.scanStr(text, "verdict") orelse "?",
        });
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

fn runReport(state_dir: []const u8, json: bool) u8 {
    const report = @import("report.zig");
    const supervisor = @import("supervisor.zig");
    const text = report.readState(state_dir, &report_read_buf) catch {
        std.debug.print("[mandor] no state at {s}/state.json — is a supervisor running with this state dir?\n", .{state_dir});
        return 1;
    };
    if (json) {
        writeOut(text);
        return 0;
    }
    const human = report.formatHuman(&report_out_buf, text, supervisor.nowMs()) orelse {
        std.debug.print("[mandor] state file is corrupt or from an incompatible version\n", .{});
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
    if (builtin.os.tag == .linux) {
        _ = @import("signals.zig");
        _ = @import("spawner.zig");
        _ = @import("reaper.zig");
        _ = @import("report.zig");
        _ = @import("spool.zig");
        _ = @import("metrics.zig");
        _ = @import("elf.zig");
    }
}
