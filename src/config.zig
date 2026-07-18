//! mandor.toml — a deliberately tiny TOML subset. CLI-only operation is the
//! first-class path; this file only ever *lowers* friction.
//!
//! Supported: `key = "string"`, `key = 123`, `key = ["a", "b"]` (single line
//! or multiline), `#` comments, blank lines. Nothing else.

const std = @import("std");
const cli = @import("cli.zig");

pub const FileConfig = struct {
    restart: ?cli.RestartPolicy = null,
    backoff_max_ms: ?u64 = null,
    state_dir: ?[]const u8 = null, // slice into the file buffer
    metrics_port: ?u16 = null,
    stop_grace_ms: ?u64 = null,
    expected_exit: ?[256]bool = null,
    ready_fd: ?u8 = null,
    health: [cli.max_health]cli.HealthSpec = undefined,
    health_n: u8 = 0,
    health_interval_ms: ?u64 = null,
    restart_on_unhealthy: ?bool = null,
    max_restarts: ?u32 = null,
    health_start_period_ms: ?u64 = null,
    on_incident: ?[]const u8 = null,
    photon: ?[]const u8 = null,
    /// "dependent=dependency" worker-name pairs.
    start_after: [cli.max_workers]cli.HealthSpec = undefined,
    start_after_n: u8 = 0,
    env_pairs: [64]cli.HealthSpec = undefined,
    env_pairs_n: u8 = 0,
    cwd_pairs: [16]cli.HealthSpec = undefined,
    cwd_pairs_n: u8 = 0,
    oneshot: [16][]const u8 = undefined,
    oneshot_n: u8 = 0,
    user_pairs: [16]cli.HealthSpec = undefined,
    user_pairs_n: u8 = 0,
    oom_pairs: [16]cli.HealthSpec = undefined,
    oom_pairs_n: u8 = 0,
    nice_pairs: [16]cli.HealthSpec = undefined,
    nice_pairs_n: u8 = 0,
    max_rss_pairs: [16]cli.HealthSpec = undefined,
    max_rss_pairs_n: u8 = 0,
    lifetime_pairs: [16]cli.HealthSpec = undefined,
    lifetime_pairs_n: u8 = 0,
    restart_pairs: [16]cli.HealthSpec = undefined,
    restart_pairs_n: u8 = 0,
    essential: [16][]const u8 = undefined,
    essential_n: u8 = 0,
    env_file: ?[]const u8 = null,
    restart_dependents: ?bool = null,
    prestop_pairs: [16]cli.HealthSpec = undefined,
    prestop_pairs_n: u8 = 0,
    commands: []const []const u8 = &.{},
};

const ArrayTarget = enum { none, workers, health, start_after, env, cwd, oneshot, user, oom, nice, max_rss, lifetime, restart_override, essential, pre_stop };

/// name=value array keys share one parse shape; map key -> target + slot.
fn pairSlot(cfg: *FileConfig, target: ArrayTarget) ?struct { arr: []cli.HealthSpec, n: *u8 } {
    return switch (target) {
        .health => .{ .arr = &cfg.health, .n = &cfg.health_n },
        .start_after => .{ .arr = &cfg.start_after, .n = &cfg.start_after_n },
        .env => .{ .arr = &cfg.env_pairs, .n = &cfg.env_pairs_n },
        .cwd => .{ .arr = &cfg.cwd_pairs, .n = &cfg.cwd_pairs_n },
        .user => .{ .arr = &cfg.user_pairs, .n = &cfg.user_pairs_n },
        .oom => .{ .arr = &cfg.oom_pairs, .n = &cfg.oom_pairs_n },
        .nice => .{ .arr = &cfg.nice_pairs, .n = &cfg.nice_pairs_n },
        .max_rss => .{ .arr = &cfg.max_rss_pairs, .n = &cfg.max_rss_pairs_n },
        .lifetime => .{ .arr = &cfg.lifetime_pairs, .n = &cfg.lifetime_pairs_n },
        .restart_override => .{ .arr = &cfg.restart_pairs, .n = &cfg.restart_pairs_n },
        .pre_stop => .{ .arr = &cfg.prestop_pairs, .n = &cfg.prestop_pairs_n },
        else => null,
    };
}

pub const ParseError = error{ Syntax, BadValue, TooManyWorkers };

/// Parse TOML-subset text. String values are slices into `text`; worker
/// commands land in `cmd_storage`.
pub fn parse(
    text: []const u8,
    cmd_storage: *[cli.max_workers][]const u8,
) ParseError!FileConfig {
    var cfg: FileConfig = .{};
    var ncmd: usize = 0;
    var target: ArrayTarget = .none;

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, stripComment(raw_line), " \t\r");
        if (line.len == 0) continue;

        if (target != .none) {
            if (std.mem.eql(u8, line, "]")) {
                target = .none;
                continue;
            }
            const item = std.mem.trim(u8, line, " \t,");
            if (item.len == 0) continue;
            const s = parseString(item) orelse return error.Syntax;
            try appendItem(&cfg, cmd_storage, &ncmd, target, s);
            if (std.mem.endsWith(u8, line, "]")) target = .none;
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.Syntax;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (std.mem.eql(u8, key, "restart") and value.len > 0 and value[0] == '[') {
            // per-worker override form: restart = ["api=always"]
            var rest = std.mem.trim(u8, value[1..], " \t");
            const closed = std.mem.endsWith(u8, rest, "]");
            if (closed) rest = std.mem.trim(u8, rest[0 .. rest.len - 1], " \t");
            var items = std.mem.splitScalar(u8, rest, ',');
            while (items.next()) |item_raw| {
                const item = std.mem.trim(u8, item_raw, " \t");
                if (item.len == 0) continue;
                const s = parseString(item) orelse return error.BadValue;
                try appendItem(&cfg, cmd_storage, &ncmd, .restart_override, s);
            }
            if (!closed) target = .restart_override;
        } else if (std.mem.eql(u8, key, "restart")) {
            const s = parseString(value) orelse return error.BadValue;
            cfg.restart = if (std.mem.eql(u8, s, "never"))
                .never
            else if (std.mem.eql(u8, s, "on-failure"))
                .on_failure
            else if (std.mem.eql(u8, s, "always"))
                .always
            else
                return error.BadValue;
        } else if (std.mem.eql(u8, key, "backoff_max")) {
            const s = parseString(value) orelse return error.BadValue;
            cfg.backoff_max_ms = cli.parseDuration(s) orelse return error.BadValue;
        } else if (std.mem.eql(u8, key, "state_dir")) {
            cfg.state_dir = parseString(value) orelse return error.BadValue;
        } else if (std.mem.eql(u8, key, "stop_grace")) {
            const s = parseString(value) orelse return error.BadValue;
            cfg.stop_grace_ms = cli.parseDuration(s) orelse return error.BadValue;
        } else if (std.mem.eql(u8, key, "expected_exit")) {
            const s = parseString(value) orelse return error.BadValue;
            var set = [1]bool{true} ++ [1]bool{false} ** 255;
            if (!cli.parseExpectedExit(s, &set)) return error.BadValue;
            cfg.expected_exit = set;
        } else if (std.mem.eql(u8, key, "metrics_port")) {
            cfg.metrics_port = std.fmt.parseInt(u16, value, 10) catch return error.BadValue;
        } else if (std.mem.eql(u8, key, "ready_fd")) {
            const fd = std.fmt.parseInt(u8, value, 10) catch return error.BadValue;
            if (fd < 3) return error.BadValue;
            cfg.ready_fd = fd;
        } else if (std.mem.eql(u8, key, "max_restarts")) {
            cfg.max_restarts = std.fmt.parseInt(u32, value, 10) catch return error.BadValue;
        } else if (std.mem.eql(u8, key, "health_start_period")) {
            const s = parseString(value) orelse return error.BadValue;
            cfg.health_start_period_ms = cli.parseDuration(s) orelse return error.BadValue;
        } else if (std.mem.eql(u8, key, "on_incident")) {
            cfg.on_incident = parseString(value) orelse return error.BadValue;
        } else if (std.mem.eql(u8, key, "photon")) {
            cfg.photon = parseString(value) orelse return error.BadValue;
        } else if (std.mem.eql(u8, key, "env_file")) {
            cfg.env_file = parseString(value) orelse return error.BadValue;
        } else if (std.mem.eql(u8, key, "restart_dependents")) {
            cfg.restart_dependents = if (std.mem.eql(u8, value, "true"))
                true
            else if (std.mem.eql(u8, value, "false"))
                false
            else
                return error.BadValue;
        } else if (std.mem.eql(u8, key, "health_interval")) {
            const s = parseString(value) orelse return error.BadValue;
            cfg.health_interval_ms = cli.parseDuration(s) orelse return error.BadValue;
        } else if (std.mem.eql(u8, key, "restart_on_unhealthy")) {
            cfg.restart_on_unhealthy = if (std.mem.eql(u8, value, "true"))
                true
            else if (std.mem.eql(u8, value, "false"))
                false
            else
                return error.BadValue;
        } else if (arrayKey(key)) |this_target| {
            if (value.len == 0 or value[0] != '[') return error.BadValue;
            var rest = std.mem.trim(u8, value[1..], " \t");
            const closed = std.mem.endsWith(u8, rest, "]");
            if (closed) rest = std.mem.trim(u8, rest[0 .. rest.len - 1], " \t");
            var items = std.mem.splitScalar(u8, rest, ',');
            while (items.next()) |item_raw| {
                const item = std.mem.trim(u8, item_raw, " \t");
                if (item.len == 0) continue;
                const s = parseString(item) orelse return error.BadValue;
                try appendItem(&cfg, cmd_storage, &ncmd, this_target, s);
            }
            if (!closed) target = this_target;
        } else {
            return error.Syntax; // unknown key: fail loudly, configs are small
        }
    }
    if (target != .none) return error.Syntax;
    cfg.commands = cmd_storage[0..ncmd];
    return cfg;
}

fn arrayKey(key: []const u8) ?ArrayTarget {
    const map = .{
        .{ "workers", ArrayTarget.workers },         .{ "health", ArrayTarget.health },
        .{ "start_after", ArrayTarget.start_after }, .{ "env", ArrayTarget.env },
        .{ "cwd", ArrayTarget.cwd },                 .{ "oneshot", ArrayTarget.oneshot },
        .{ "user", ArrayTarget.user },               .{ "oom_score_adj", ArrayTarget.oom },
        .{ "nice", ArrayTarget.nice },               .{ "max_rss_mb", ArrayTarget.max_rss },
        .{ "max_lifetime", ArrayTarget.lifetime },   .{ "essential", ArrayTarget.essential },
        .{ "pre_stop", ArrayTarget.pre_stop },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, key, entry[0])) return entry[1];
    }
    return null;
}

fn appendItem(
    cfg: *FileConfig,
    cmd_storage: *[cli.max_workers][]const u8,
    ncmd: *usize,
    target: ArrayTarget,
    s: []const u8,
) ParseError!void {
    switch (target) {
        .workers => {
            if (ncmd.* == cli.max_workers) return error.TooManyWorkers;
            cmd_storage[ncmd.*] = s;
            ncmd.* += 1;
        },
        .oneshot => {
            if (cfg.oneshot_n == cfg.oneshot.len) return error.BadValue;
            cfg.oneshot[cfg.oneshot_n] = s;
            cfg.oneshot_n += 1;
        },
        .essential => {
            if (cfg.essential_n == cfg.essential.len) return error.BadValue;
            cfg.essential[cfg.essential_n] = s;
            cfg.essential_n += 1;
        },
        else => {
            const slot = pairSlot(cfg, target) orelse unreachable; // real target
            const eq = std.mem.indexOfScalar(u8, s, '=') orelse return error.BadValue;
            if (eq == 0 or eq + 1 >= s.len) return error.BadValue;
            if (slot.n.* == slot.arr.len) return error.BadValue;
            slot.arr[slot.n.*] = .{ .worker = s[0..eq], .cmd = s[eq + 1 ..] };
            slot.n.* += 1;
        },
    }
}

fn stripComment(line: []const u8) []const u8 {
    var in_str = false;
    for (line, 0..) |c, i| {
        if (c == '"') in_str = !in_str;
        if (c == '#' and !in_str) return line[0..i];
    }
    return line;
}

fn parseString(v: []const u8) ?[]const u8 {
    if (v.len < 2 or v[0] != '"' or v[v.len - 1] != '"') return null;
    return v[1 .. v.len - 1];
}

// ---------------------------------------------------------------- tests

const t = std.testing;

test "full config parses" {
    const text =
        \\# mandor config
        \\restart = "on-failure"
        \\backoff_max = "45s"   # comment after value
        \\state_dir = "/data/mandor"
        \\metrics_port = 9464
        \\workers = ["./api --port 8080", "./worker"]
    ;
    var storage: [cli.max_workers][]const u8 = undefined;
    const cfg = try parse(text, &storage);
    try t.expectEqual(cli.RestartPolicy.on_failure, cfg.restart.?);
    try t.expectEqual(@as(u64, 45_000), cfg.backoff_max_ms.?);
    try t.expectEqualStrings("/data/mandor", cfg.state_dir.?);
    try t.expectEqual(@as(u16, 9464), cfg.metrics_port.?);
    try t.expectEqual(@as(usize, 2), cfg.commands.len);
    try t.expectEqualStrings("./api --port 8080", cfg.commands[0]);
}

test "health, ready_fd and restart_on_unhealthy keys" {
    var storage: [cli.max_workers][]const u8 = undefined;
    const text =
        \\ready_fd = 5
        \\health_interval = "10s"
        \\restart_on_unhealthy = true
        \\health = ["api=/bin/check --fast"]
    ;
    const cfg = try parse(text, &storage);
    try t.expectEqual(@as(?u8, 5), cfg.ready_fd);
    try t.expectEqual(@as(u64, 10_000), cfg.health_interval_ms.?);
    try t.expect(cfg.restart_on_unhealthy.?);
    try t.expectEqual(@as(u8, 1), cfg.health_n);
    try t.expectEqualStrings("api", cfg.health[0].worker);
    try t.expectEqualStrings("/bin/check --fast", cfg.health[0].cmd);
}

test "env, cwd, oneshot keys" {
    var storage: [cli.max_workers][]const u8 = undefined;
    const cfg = try parse(
        "env = [\"api=PORT=8080\", \"api=DEBUG=1\"]\ncwd = [\"api=/srv\"]\noneshot = [\"migrate\"]",
        &storage,
    );
    try t.expectEqual(@as(u8, 2), cfg.env_pairs_n);
    try t.expectEqualStrings("PORT=8080", cfg.env_pairs[0].cmd);
    try t.expectEqualStrings("/srv", cfg.cwd_pairs[0].cmd);
    try t.expectEqualStrings("migrate", cfg.oneshot[0]);
}

test "start_after key" {
    var storage: [cli.max_workers][]const u8 = undefined;
    const cfg = try parse("start_after = [\"worker=api\", \"cron=worker\"]", &storage);
    try t.expectEqual(@as(u8, 2), cfg.start_after_n);
    try t.expectEqualStrings("worker", cfg.start_after[0].worker);
    try t.expectEqualStrings("api", cfg.start_after[0].cmd);
    try t.expectError(error.BadValue, parse("start_after = [\"nodeps\"]", &storage));
}

test "stop_grace and expected_exit keys" {
    var storage: [cli.max_workers][]const u8 = undefined;
    const cfg = try parse("stop_grace = \"5s\"\nexpected_exit = \"143\"", &storage);
    try t.expectEqual(@as(u64, 5_000), cfg.stop_grace_ms.?);
    try t.expect(cfg.expected_exit.?[143]);
    try t.expect(cfg.expected_exit.?[0]);
}

test "multiline workers array" {
    const text =
        \\workers = [
        \\  "./api --port 8080",
        \\  "./worker",
        \\]
    ;
    var storage: [cli.max_workers][]const u8 = undefined;
    const cfg = try parse(text, &storage);
    try t.expectEqual(@as(usize, 2), cfg.commands.len);
    try t.expectEqualStrings("./worker", cfg.commands[1]);
}

test "empty and comment-only config is valid" {
    var storage: [cli.max_workers][]const u8 = undefined;
    const cfg = try parse("# nothing here\n\n", &storage);
    try t.expectEqual(@as(usize, 0), cfg.commands.len);
    try t.expectEqual(@as(?u64, null), cfg.backoff_max_ms);
}

test "errors: unknown key, bad values, unterminated array" {
    var storage: [cli.max_workers][]const u8 = undefined;
    try t.expectError(error.Syntax, parse("nope = 1", &storage));
    try t.expectError(error.BadValue, parse("restart = \"sometimes\"", &storage));
    try t.expectError(error.BadValue, parse("backoff_max = \"fast\"", &storage));
    try t.expectError(error.BadValue, parse("metrics_port = \"abc\"", &storage));
    try t.expectError(error.Syntax, parse("workers = [\n  \"./a\",\n", &storage));
    try t.expectError(error.Syntax, parse("just text", &storage));
}

test "hash inside quoted string is not a comment" {
    var storage: [cli.max_workers][]const u8 = undefined;
    const cfg = try parse("workers = [\"./api #not-a-comment\"]", &storage);
    try t.expectEqualStrings("./api #not-a-comment", cfg.commands[0]);
}
