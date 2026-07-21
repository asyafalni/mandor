//! mandor.toml — a deliberately tiny TOML subset. CLI-only operation is the
//! first-class path; this file only ever *lowers* friction.
//!
//! Supported: `key = "string"`, `key = 123`, `key = ["a", "b"]` (single line
//! or multiline), `#` comments, blank lines. Nothing else.

const std = @import("std");
const cli = @import("cli.zig");

pub const FileConfig = struct {
    backoff_max_ms: ?u64 = null,
    state_dir: ?[]const u8 = null, // slice into the file buffer
    metrics_port: ?u16 = null,
    stop_grace_ms: ?u64 = null,
    expected_exit: ?[256]bool = null,
    ready_fd: ?u8 = null,
    health: [cli.max_health]cli.HealthSpec = undefined,
    health_n: u8 = 0,
    health_interval_ms: ?u64 = null,
    max_restarts: ?i32 = null,
    health_start_period_ms: ?u64 = null,
    on_incident: ?[]const u8 = null,
    photon: ?[]const u8 = null,
    psi_mem_pct: ?u16 = null,
    psi_cpu_pct: ?u16 = null,
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
    cap_drop_pairs: [16]cli.HealthSpec = undefined,
    cap_drop_pairs_n: u8 = 0,
    oom_pairs: [16]cli.HealthSpec = undefined,
    oom_pairs_n: u8 = 0,
    nice_pairs: [16]cli.HealthSpec = undefined,
    nice_pairs_n: u8 = 0,
    max_rss_pairs: [16]cli.HealthSpec = undefined,
    max_rss_pairs_n: u8 = 0,
    lifetime_pairs: [16]cli.HealthSpec = undefined,
    lifetime_pairs_n: u8 = 0,
    /// Per-worker `expected_exit` overrides ("name" -> "143,129").
    expected_pairs: [16]cli.HealthSpec = undefined,
    expected_pairs_n: u8 = 0,
    /// Workers marked `essential = false`. Every worker is essential by
    /// default, so this records the *opt-outs*.
    not_essential: [16][]const u8 = undefined,
    not_essential_n: u8 = 0,
    env_file: ?[]const u8 = null,
    restart_dependents: ?bool = null,
    prestop_pairs: [16]cli.HealthSpec = undefined,
    prestop_pairs_n: u8 = 0,
    commands: []const []const u8 = &.{},
};

const ArrayTarget = enum { none, workers, health, start_after, env, cwd, user, cap_drop, oom, nice, max_rss, lifetime, expected, pre_stop };

/// Per-worker settings all land in `worker -> value` pair arrays; map the
/// section key to its slot.
fn pairSlot(cfg: *FileConfig, target: ArrayTarget) ?struct { arr: []cli.HealthSpec, n: *u8 } {
    return switch (target) {
        .health => .{ .arr = &cfg.health, .n = &cfg.health_n },
        .start_after => .{ .arr = &cfg.start_after, .n = &cfg.start_after_n },
        .env => .{ .arr = &cfg.env_pairs, .n = &cfg.env_pairs_n },
        .cwd => .{ .arr = &cfg.cwd_pairs, .n = &cfg.cwd_pairs_n },
        .user => .{ .arr = &cfg.user_pairs, .n = &cfg.user_pairs_n },
        .cap_drop => .{ .arr = &cfg.cap_drop_pairs, .n = &cfg.cap_drop_pairs_n },
        .oom => .{ .arr = &cfg.oom_pairs, .n = &cfg.oom_pairs_n },
        .nice => .{ .arr = &cfg.nice_pairs, .n = &cfg.nice_pairs_n },
        .max_rss => .{ .arr = &cfg.max_rss_pairs, .n = &cfg.max_rss_pairs_n },
        .lifetime => .{ .arr = &cfg.lifetime_pairs, .n = &cfg.lifetime_pairs_n },
        .expected => .{ .arr = &cfg.expected_pairs, .n = &cfg.expected_pairs_n },
        .pre_stop => .{ .arr = &cfg.prestop_pairs, .n = &cfg.prestop_pairs_n },
        else => null,
    };
}

pub const ParseError = error{ Syntax, BadValue, TooManyWorkers, RestartRemoved, UnhealthyKeyRemoved };

/// Parse TOML-subset text. String values are slices into `text`; worker
/// commands land in `cmd_storage`.
pub fn parse(
    text: []const u8,
    cmd_storage: *[cli.max_workers][]const u8,
    out: *FileConfig,
) ParseError!void {
    // Filled through a pointer, not returned by value: an error union
    // carrying a ~10 KB payload materializes that payload in .rodata once
    // per distinct error-return path.
    out.* = .{};
    const cfg = out;
    var ncmd: usize = 0;
    var target: ArrayTarget = .none; // open multiline array
    var array_worker: ?[]const u8 = null; // worker owning that array, if any
    var cur_worker: ?[]const u8 = null; // active [worker.NAME] section

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
            try appendItem(cfg, cmd_storage, &ncmd, target, array_worker, s);
            if (std.mem.endsWith(u8, line, "]")) target = .none;
            continue;
        }

        // [worker.NAME] — every key below it scopes to that worker.
        if (line[0] == '[') {
            cur_worker = try sectionWorker(line);
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.Syntax;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (cur_worker) |w| {
            try workerSetting(cfg, cmd_storage, &ncmd, &target, &array_worker, w, key, value);
            continue;
        }

        if (std.mem.eql(u8, key, "restart")) {
            return error.RestartRemoved;
        } else if (std.mem.eql(u8, key, "restart_on_unhealthy")) {
            return error.UnhealthyKeyRemoved;
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
            cfg.max_restarts = std.fmt.parseInt(i32, value, 10) catch return error.BadValue;
            if (cfg.max_restarts.? < -1) return error.BadValue;
        } else if (std.mem.eql(u8, key, "health_start_period")) {
            const s = parseString(value) orelse return error.BadValue;
            cfg.health_start_period_ms = cli.parseDuration(s) orelse return error.BadValue;
        } else if (std.mem.eql(u8, key, "on_incident")) {
            cfg.on_incident = parseString(value) orelse return error.BadValue;
        } else if (std.mem.eql(u8, key, "photon")) {
            cfg.photon = parseString(value) orelse return error.BadValue;
        } else if (std.mem.eql(u8, key, "psi_mem_pct")) {
            cfg.psi_mem_pct = std.fmt.parseInt(u16, value, 10) catch return error.BadValue;
        } else if (std.mem.eql(u8, key, "psi_cpu_pct")) {
            cfg.psi_cpu_pct = std.fmt.parseInt(u16, value, 10) catch return error.BadValue;
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
        } else if (std.mem.eql(u8, key, "workers")) {
            if (value.len == 0 or value[0] != '[') return error.BadValue;
            var rest = std.mem.trim(u8, value[1..], " \t");
            const closed = std.mem.endsWith(u8, rest, "]");
            if (closed) rest = std.mem.trim(u8, rest[0 .. rest.len - 1], " \t");
            var items = std.mem.splitScalar(u8, rest, ',');
            while (items.next()) |item_raw| {
                const item = std.mem.trim(u8, item_raw, " \t");
                if (item.len == 0) continue;
                const s = parseString(item) orelse return error.BadValue;
                try appendItem(cfg, cmd_storage, &ncmd, .workers, null, s);
            }
            if (!closed) target = .workers;
        } else {
            return error.Syntax; // unknown key: fail loudly, configs are small
        }
    }
    if (target != .none) return error.Syntax;
    cfg.commands = cmd_storage[0..ncmd];
}

/// Keys valid inside a `[worker.NAME]` section.
fn workerKey(key: []const u8) ?ArrayTarget {
    const map = .{
        .{ "health", ArrayTarget.health },          .{ "start_after", ArrayTarget.start_after },
        .{ "env", ArrayTarget.env },                .{ "cwd", ArrayTarget.cwd },
        .{ "user", ArrayTarget.user },              .{ "cap_drop", ArrayTarget.cap_drop },
        .{ "oom_score_adj", ArrayTarget.oom },      .{ "nice", ArrayTarget.nice },
        .{ "max_rss_mb", ArrayTarget.max_rss },     .{ "max_lifetime", ArrayTarget.lifetime },
        .{ "expected_exit", ArrayTarget.expected }, .{ "pre_stop", ArrayTarget.pre_stop },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, key, entry[0])) return entry[1];
    }
    return null;
}

/// `[worker.NAME]` -> NAME. Any other section header is a hard error: configs
/// are small, so a typo should stop startup rather than be silently ignored.
fn sectionWorker(line: []const u8) ParseError!?[]const u8 {
    if (line[line.len - 1] != ']') return error.Syntax;
    const inner = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
    const prefix = "worker.";
    if (!std.mem.startsWith(u8, inner, prefix)) return error.Syntax;
    const name = std.mem.trim(u8, inner[prefix.len..], " \t");
    if (name.len == 0) return error.Syntax;
    return name;
}

/// A quoted string, or a bare token (integers, `true`/`false`).
fn scalarValue(v: []const u8) ?[]const u8 {
    if (v.len == 0) return null;
    if (v[0] == '"') return parseString(v);
    return v;
}

/// Apply one `key = value` inside `[worker.NAME]`.
fn workerSetting(
    cfg: *FileConfig,
    cmd_storage: *[cli.max_workers][]const u8,
    ncmd: *usize,
    target: *ArrayTarget,
    array_worker: *?[]const u8,
    w: []const u8,
    key: []const u8,
    value: []const u8,
) ParseError!void {
    // Membership flags: the worker's name joins a list rather than carrying a
    // value. `essential` is inverted — every worker is essential by default,
    // so the list records the opt-outs and `true` records nothing.
    if (std.mem.eql(u8, key, "essential")) {
        if (std.mem.eql(u8, value, "true")) return; // the default
        if (!std.mem.eql(u8, value, "false")) return error.BadValue;
        if (cfg.not_essential_n == cfg.not_essential.len) return error.BadValue;
        cfg.not_essential[cfg.not_essential_n] = w;
        cfg.not_essential_n += 1;
        return;
    }
    if (std.mem.eql(u8, key, "oneshot")) {
        if (std.mem.eql(u8, value, "false")) return; // the default
        if (!std.mem.eql(u8, value, "true")) return error.BadValue;
        if (cfg.oneshot_n == cfg.oneshot.len) return error.BadValue;
        cfg.oneshot[cfg.oneshot_n] = w;
        cfg.oneshot_n += 1;
        return;
    }

    const tgt = workerKey(key) orelse return error.Syntax;

    // `env` is the one list-valued per-worker key: ["KEY=VALUE", ...].
    if (value.len > 0 and value[0] == '[') {
        if (tgt != .env) return error.BadValue;
        var rest = std.mem.trim(u8, value[1..], " \t");
        const closed = std.mem.endsWith(u8, rest, "]");
        if (closed) rest = std.mem.trim(u8, rest[0 .. rest.len - 1], " \t");
        var items = std.mem.splitScalar(u8, rest, ',');
        while (items.next()) |item_raw| {
            const item = std.mem.trim(u8, item_raw, " \t");
            if (item.len == 0) continue;
            const s = parseString(item) orelse return error.BadValue;
            try appendItem(cfg, cmd_storage, ncmd, tgt, w, s);
        }
        if (!closed) {
            target.* = tgt;
            array_worker.* = w;
        }
        return;
    }

    const s = scalarValue(value) orelse return error.BadValue;
    try appendItem(cfg, cmd_storage, ncmd, tgt, w, s);
}

fn appendItem(
    cfg: *FileConfig,
    cmd_storage: *[cli.max_workers][]const u8,
    ncmd: *usize,
    target: ArrayTarget,
    worker: ?[]const u8,
    s: []const u8,
) ParseError!void {
    if (target == .workers) {
        if (ncmd.* == cli.max_workers) return error.TooManyWorkers;
        cmd_storage[ncmd.*] = s;
        ncmd.* += 1;
        return;
    }
    const slot = pairSlot(cfg, target) orelse return error.Syntax;
    const w = worker orelse return error.Syntax;
    if (slot.n.* == slot.arr.len) return error.BadValue;
    slot.arr[slot.n.*] = .{ .worker = w, .cmd = s };
    slot.n.* += 1;
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

/// By-value wrapper so tests read naturally. Test-only: never in the binary.
fn parseTest(text: []const u8, cmd_storage: *[cli.max_workers][]const u8) ParseError!FileConfig {
    var cfg: FileConfig = undefined;
    try parse(text, cmd_storage, &cfg);
    return cfg;
}

const t = std.testing;

test "full config parses" {
    const text =
        \\# mandor config
        \\max_restarts = 3
        \\backoff_max = "45s"   # comment after value
        \\state_dir = "/data/mandor"
        \\metrics_port = 9464
        \\workers = ["./api --port 8080", "./worker"]
    ;
    var storage: [cli.max_workers][]const u8 = undefined;
    const cfg = try parseTest(text, &storage);
    try t.expectEqual(@as(i32, 3), cfg.max_restarts.?);
    try t.expectEqual(@as(u64, 45_000), cfg.backoff_max_ms.?);
    try t.expectEqualStrings("/data/mandor", cfg.state_dir.?);
    try t.expectEqual(@as(u16, 9464), cfg.metrics_port.?);
    try t.expectEqual(@as(usize, 2), cfg.commands.len);
    try t.expectEqualStrings("./api --port 8080", cfg.commands[0]);
}

test "health, ready_fd and health_interval keys" {
    var storage: [cli.max_workers][]const u8 = undefined;
    const text =
        \\ready_fd = 5
        \\health_interval = "10s"
        \\
        \\[worker.api]
        \\health = "/bin/check --fast"
    ;
    const cfg = try parseTest(text, &storage);
    try t.expectEqual(@as(?u8, 5), cfg.ready_fd);
    try t.expectEqual(@as(u64, 10_000), cfg.health_interval_ms.?);
    try t.expectEqual(@as(u8, 1), cfg.health_n);
    try t.expectEqualStrings("api", cfg.health[0].worker);
    try t.expectEqualStrings("/bin/check --fast", cfg.health[0].cmd);
}

test "worker section: env, cwd, oneshot" {
    var storage: [cli.max_workers][]const u8 = undefined;
    const text =
        \\[worker.api]
        \\env = ["PORT=8080", "DEBUG=1"]
        \\cwd = "/srv"
        \\
        \\[worker.migrate]
        \\oneshot = true
    ;
    const cfg = try parseTest(text, &storage);
    try t.expectEqual(@as(u8, 2), cfg.env_pairs_n);
    try t.expectEqualStrings("api", cfg.env_pairs[0].worker);
    try t.expectEqualStrings("PORT=8080", cfg.env_pairs[0].cmd);
    try t.expectEqualStrings("DEBUG=1", cfg.env_pairs[1].cmd);
    try t.expectEqualStrings("api", cfg.cwd_pairs[0].worker);
    try t.expectEqualStrings("/srv", cfg.cwd_pairs[0].cmd);
    try t.expectEqual(@as(u8, 1), cfg.oneshot_n);
    try t.expectEqualStrings("migrate", cfg.oneshot[0]);
}

test "worker section: scalars, bare ints, membership flags" {
    var storage: [cli.max_workers][]const u8 = undefined;
    const text =
        \\[worker.api]
        \\start_after = "db"
        \\user = "1000:1000"
        \\max_rss_mb = 768
        \\nice = 5
        \\expected_exit = "2,3"
        \\essential = true
        \\
        \\[worker.cron]
        \\essential = false
    ;
    const cfg = try parseTest(text, &storage);
    try t.expectEqualStrings("api", cfg.start_after[0].worker);
    try t.expectEqualStrings("db", cfg.start_after[0].cmd);
    try t.expectEqualStrings("1000:1000", cfg.user_pairs[0].cmd);
    try t.expectEqualStrings("768", cfg.max_rss_pairs[0].cmd);
    try t.expectEqualStrings("5", cfg.nice_pairs[0].cmd);
    try t.expectEqualStrings("2,3", cfg.expected_pairs[0].cmd);
    // essential is inverted: `true` is the default and records nothing,
    // so only the explicit opt-out is listed.
    try t.expectEqual(@as(u8, 1), cfg.not_essential_n);
    try t.expectEqualStrings("cron", cfg.not_essential[0]);
}

test "worker section: multiline env array keeps its worker" {
    var storage: [cli.max_workers][]const u8 = undefined;
    const text =
        \\[worker.api]
        \\env = [
        \\  "PORT=8080",
        \\  "LOG=debug",
        \\]
        \\cwd = "/srv"
    ;
    const cfg = try parseTest(text, &storage);
    try t.expectEqual(@as(u8, 2), cfg.env_pairs_n);
    try t.expectEqualStrings("api", cfg.env_pairs[1].worker);
    try t.expectEqualStrings("LOG=debug", cfg.env_pairs[1].cmd);
    try t.expectEqualStrings("/srv", cfg.cwd_pairs[0].cmd);
}

test "bad sections and stray per-worker keys are rejected" {
    var storage: [cli.max_workers][]const u8 = undefined;
    // Unknown section, empty name, and a per-worker key outside any section.
    try t.expectError(error.Syntax, parseTest("[server.api]\ncwd = \"/srv\"", &storage));
    try t.expectError(error.Syntax, parseTest("[worker.]\ncwd = \"/srv\"", &storage));
    try t.expectError(error.Syntax, parseTest("cwd = \"/srv\"", &storage));
    // Only env takes a list inside a section.
    try t.expectError(error.BadValue, parseTest("[worker.api]\ncwd = [\"/srv\"]", &storage));
    // Unknown key inside a section.
    try t.expectError(error.Syntax, parseTest("[worker.api]\nbogus = \"x\"", &storage));
}

test "stop_grace and expected_exit keys" {
    var storage: [cli.max_workers][]const u8 = undefined;
    const cfg = try parseTest("stop_grace = \"5s\"\nexpected_exit = \"143\"", &storage);
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
    const cfg = try parseTest(text, &storage);
    try t.expectEqual(@as(usize, 2), cfg.commands.len);
    try t.expectEqualStrings("./worker", cfg.commands[1]);
}

test "empty and comment-only config is valid" {
    var storage: [cli.max_workers][]const u8 = undefined;
    const cfg = try parseTest("# nothing here\n\n", &storage);
    try t.expectEqual(@as(usize, 0), cfg.commands.len);
    try t.expectEqual(@as(?u64, null), cfg.backoff_max_ms);
}

test "errors: unknown key, bad values, unterminated array" {
    var storage: [cli.max_workers][]const u8 = undefined;
    try t.expectError(error.Syntax, parseTest("nope = 1", &storage));
    // Removed keys report *why*, so the message can name the replacement.
    try t.expectError(error.RestartRemoved, parseTest("restart = \"on-failure\"", &storage));
    try t.expectError(error.UnhealthyKeyRemoved, parseTest("restart_on_unhealthy = true", &storage));
    try t.expectError(error.BadValue, parseTest("max_restarts = -2", &storage));
    try t.expectError(error.BadValue, parseTest("backoff_max = \"fast\"", &storage));
    try t.expectError(error.BadValue, parseTest("metrics_port = \"abc\"", &storage));
    try t.expectError(error.Syntax, parseTest("workers = [\n  \"./a\",\n", &storage));
    try t.expectError(error.Syntax, parseTest("just text", &storage));
}

test "hash inside quoted string is not a comment" {
    var storage: [cli.max_workers][]const u8 = undefined;
    const cfg = try parseTest("workers = [\"./api #not-a-comment\"]", &storage);
    try t.expectEqualStrings("./api #not-a-comment", cfg.commands[0]);
}
