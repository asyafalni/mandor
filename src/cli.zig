//! CLI parsing for mandor. Pure code — no OS calls — so it unit-tests on any host.

const std = @import("std");

pub const max_workers = 64;
pub const max_health = 8;
pub const default_state_dir = "/var/lib/mandor";

pub const HealthSpec = struct { worker: []const u8, cmd: []const u8 };

pub const RestartPolicy = enum { never, on_failure, always };
pub const Mode = enum { supervise, report };

pub const Config = struct {
    mode: Mode = .supervise,
    restart: RestartPolicy = .never,
    backoff_max_ms: u64 = 30_000,
    commands: []const []const u8 = &.{},
    help: bool = false,
    version: bool = false,
    json: bool = false,
    incidents: bool = false,
    /// null = not given on the CLI; caller resolves env/config/default.
    state_dir: ?[]const u8 = null,
    config_path: ?[]const u8 = null,
    metrics_port: ?u16 = null,
    /// Exit codes treated exactly like exit 0 (restart policy, incidents,
    /// worst-code propagation). Index = code; 0 is always clean.
    expected_exit: [256]bool = [1]bool{true} ++ [1]bool{false} ** 255,
    /// Grace period between forwarding TERM/INT and escalating to SIGKILL.
    stop_grace_ms: u64 = 10_000,
    /// s6-style readiness: workers write a newline to this fd when ready.
    ready_fd: ?u8 = null,
    /// Health checks: worker-name -> probe command (exit 0 = healthy).
    health: [max_health]HealthSpec = undefined,
    health_n: u8 = 0,
    health_interval_ms: u64 = 30_000,
    health_interval_set: bool = false,
    restart_on_unhealthy: bool = false,
    /// Track explicit CLI flags so a config file never overrides them.
    restart_set: bool = false,
    backoff_set: bool = false,
    stop_grace_set: bool = false,
    expected_exit_set: bool = false,
};

/// "143,129" -> set the listed codes (on top of the always-clean 0).
pub fn parseExpectedExit(s: []const u8, out: *[256]bool) bool {
    var it = std.mem.splitScalar(u8, s, ',');
    var any = false;
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        const code = std.fmt.parseInt(u8, trimmed, 10) catch return false;
        out[code] = true;
        any = true;
    }
    return any;
}

pub const ParseError = error{ UnknownFlag, BadValue, TooManyWorkers };

pub fn parse(args: []const []const u8, cmd_storage: *[max_workers][]const u8) ParseError!Config {
    var cfg: Config = .{};
    var n: usize = 0;
    var no_more_flags = false;
    for (args, 0..) |arg, arg_idx| {
        if (arg_idx == 0 and std.mem.eql(u8, arg, "report")) {
            cfg.mode = .report;
            continue;
        }
        if (!no_more_flags and std.mem.eql(u8, arg, "--")) {
            no_more_flags = true;
            continue;
        }
        if (!no_more_flags and std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.eql(u8, arg, "--help")) {
                cfg.help = true;
            } else if (std.mem.eql(u8, arg, "--version")) {
                cfg.version = true;
            } else if (std.mem.startsWith(u8, arg, "--restart=")) {
                const v = arg["--restart=".len..];
                cfg.restart = if (std.mem.eql(u8, v, "never"))
                    .never
                else if (std.mem.eql(u8, v, "on-failure"))
                    .on_failure
                else if (std.mem.eql(u8, v, "always"))
                    .always
                else
                    return error.BadValue;
                cfg.restart_set = true;
            } else if (std.mem.startsWith(u8, arg, "--backoff-max=")) {
                cfg.backoff_max_ms = parseDuration(arg["--backoff-max=".len..]) orelse
                    return error.BadValue;
                cfg.backoff_set = true;
            } else if (std.mem.startsWith(u8, arg, "--health=")) {
                const v = arg["--health=".len..];
                const eq2 = std.mem.indexOfScalar(u8, v, '=') orelse return error.BadValue;
                if (eq2 == 0 or eq2 + 1 >= v.len) return error.BadValue;
                if (cfg.health_n == max_health) return error.BadValue;
                cfg.health[cfg.health_n] = .{ .worker = v[0..eq2], .cmd = v[eq2 + 1 ..] };
                cfg.health_n += 1;
            } else if (std.mem.startsWith(u8, arg, "--health-interval=")) {
                cfg.health_interval_ms = parseDuration(arg["--health-interval=".len..]) orelse
                    return error.BadValue;
                cfg.health_interval_set = true;
            } else if (std.mem.eql(u8, arg, "--restart-on-unhealthy")) {
                cfg.restart_on_unhealthy = true;
            } else if (std.mem.startsWith(u8, arg, "--ready-fd=")) {
                const fd = std.fmt.parseInt(u8, arg["--ready-fd=".len..], 10) catch
                    return error.BadValue;
                if (fd < 3) return error.BadValue; // stdio is taken
                cfg.ready_fd = fd;
            } else if (std.mem.startsWith(u8, arg, "--stop-grace=")) {
                cfg.stop_grace_ms = parseDuration(arg["--stop-grace=".len..]) orelse
                    return error.BadValue;
                cfg.stop_grace_set = true;
            } else if (std.mem.startsWith(u8, arg, "--expected-exit=")) {
                if (!parseExpectedExit(arg["--expected-exit=".len..], &cfg.expected_exit))
                    return error.BadValue;
                cfg.expected_exit_set = true;
            } else if (std.mem.startsWith(u8, arg, "--config=")) {
                const v = arg["--config=".len..];
                if (v.len == 0) return error.BadValue;
                cfg.config_path = v;
            } else if (std.mem.startsWith(u8, arg, "--metrics=")) {
                cfg.metrics_port = std.fmt.parseInt(u16, arg["--metrics=".len..], 10) catch
                    return error.BadValue;
            } else if (std.mem.startsWith(u8, arg, "--state-dir=")) {
                const v = arg["--state-dir=".len..];
                if (v.len == 0) return error.BadValue;
                cfg.state_dir = v;
            } else if (std.mem.eql(u8, arg, "--json")) {
                if (cfg.mode != .report) return error.UnknownFlag;
                cfg.json = true;
            } else if (std.mem.eql(u8, arg, "--incidents")) {
                if (cfg.mode != .report) return error.UnknownFlag;
                cfg.incidents = true;
            } else {
                return error.UnknownFlag;
            }
            continue;
        }
        if (n == max_workers) return error.TooManyWorkers;
        cmd_storage[n] = arg;
        n += 1;
    }
    cfg.commands = cmd_storage[0..n];
    if (cfg.mode == .report and n != 0) return error.BadValue; // report takes no commands
    // Zero commands is legal here: a config file may provide the workers.
    return cfg;
}

/// "500ms" | "30s" | "2m" -> milliseconds. Integer only, no whitespace.
pub fn parseDuration(s: []const u8) ?u64 {
    var mult: u64 = undefined;
    var unit_len: usize = undefined;
    if (std.mem.endsWith(u8, s, "ms")) {
        mult = 1;
        unit_len = 2;
    } else if (std.mem.endsWith(u8, s, "s")) {
        mult = 1000;
        unit_len = 1;
    } else if (std.mem.endsWith(u8, s, "m")) {
        mult = 60_000;
        unit_len = 1;
    } else return null;
    const digits = s[0 .. s.len - unit_len];
    if (digits.len == 0) return null;
    const value = std.fmt.parseInt(u64, digits, 10) catch return null;
    return std.math.mul(u64, value, mult) catch null;
}

pub const TokenizeError = error{ Empty, UnterminatedQuote, TooManyArgs, TooLong };

/// Split a command string into whitespace-separated tokens, honoring single
/// quotes (literal) and double quotes (with \" and \\ escapes). Tokens are
/// copied into `buf`, each followed by a NUL so they can feed execve directly;
/// returned slices exclude the NUL.
pub fn tokenize(cmd: []const u8, buf: []u8, argv_out: [][]const u8) TokenizeError![]const []const u8 {
    var ntok: usize = 0;
    var w: usize = 0; // next write position in buf
    var i: usize = 0;
    while (i < cmd.len) {
        while (i < cmd.len and isSpace(cmd[i])) i += 1;
        if (i >= cmd.len) break;
        if (ntok == argv_out.len) return error.TooManyArgs;
        const tok_start = w;
        while (i < cmd.len and !isSpace(cmd[i])) {
            const c = cmd[i];
            if (c == '\'') {
                i += 1;
                const close = std.mem.indexOfScalarPos(u8, cmd, i, '\'') orelse
                    return error.UnterminatedQuote;
                const chunk = cmd[i..close];
                if (w + chunk.len + 1 > buf.len) return error.TooLong;
                @memcpy(buf[w..][0..chunk.len], chunk);
                w += chunk.len;
                i = close + 1;
            } else if (c == '"') {
                i += 1;
                while (true) {
                    if (i >= cmd.len) return error.UnterminatedQuote;
                    const d = cmd[i];
                    if (d == '"') {
                        i += 1;
                        break;
                    }
                    if (d == '\\' and i + 1 < cmd.len and
                        (cmd[i + 1] == '"' or cmd[i + 1] == '\\'))
                    {
                        i += 1; // emit the escaped character below
                    }
                    if (w + 2 > buf.len) return error.TooLong;
                    buf[w] = cmd[i];
                    w += 1;
                    i += 1;
                }
            } else {
                if (w + 2 > buf.len) return error.TooLong;
                buf[w] = c;
                w += 1;
                i += 1;
            }
        }
        if (w >= buf.len) return error.TooLong;
        buf[w] = 0; // NUL for execve
        argv_out[ntok] = buf[tok_start..w];
        w += 1;
        ntok += 1;
    }
    if (ntok == 0) return error.Empty;
    return argv_out[0..ntok];
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}

// ---------------------------------------------------------------- tests

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expectEqualStrings = std.testing.expectEqualStrings;

test "parseDuration accepts ms/s/m and rejects junk" {
    try expectEqual(@as(?u64, 500), parseDuration("500ms"));
    try expectEqual(@as(?u64, 30_000), parseDuration("30s"));
    try expectEqual(@as(?u64, 120_000), parseDuration("2m"));
    try expectEqual(@as(?u64, null), parseDuration("abc"));
    try expectEqual(@as(?u64, null), parseDuration(""));
    try expectEqual(@as(?u64, null), parseDuration("12"));
    try expectEqual(@as(?u64, null), parseDuration("ms"));
    try expectEqual(@as(?u64, null), parseDuration("s"));
}

test "tokenize splits plain words" {
    var buf: [256]u8 = undefined;
    var argv: [64][]const u8 = undefined;
    const toks = try tokenize("./api --port 8080", &buf, &argv);
    try expectEqual(@as(usize, 3), toks.len);
    try expectEqualStrings("./api", toks[0]);
    try expectEqualStrings("--port", toks[1]);
    try expectEqualStrings("8080", toks[2]);
    // each token is NUL-terminated in buf (execve contract)
    try expectEqual(@as(u8, 0), toks[0].ptr[toks[0].len]);
}

test "tokenize honors quotes and escapes" {
    var buf: [256]u8 = undefined;
    var argv: [64][]const u8 = undefined;
    const toks = try tokenize("say 'a b' \"c d\" \"e\\\"f\\\\\"", &buf, &argv);
    try expectEqual(@as(usize, 4), toks.len);
    try expectEqualStrings("a b", toks[1]);
    try expectEqualStrings("c d", toks[2]);
    try expectEqualStrings("e\"f\\", toks[3]);
}

test "tokenize joins adjacent quoted chunks into one token" {
    var buf: [256]u8 = undefined;
    var argv: [64][]const u8 = undefined;
    const toks = try tokenize("a'b c'd", &buf, &argv);
    try expectEqual(@as(usize, 1), toks.len);
    try expectEqualStrings("ab cd", toks[0]);
}

test "tokenize errors" {
    var buf: [256]u8 = undefined;
    var argv2: [2][]const u8 = undefined;
    var argv: [64][]const u8 = undefined;
    try expectError(error.TooManyArgs, tokenize("a b c", &buf, &argv2));
    try expectError(error.UnterminatedQuote, tokenize("a 'oops", &buf, &argv));
    try expectError(error.UnterminatedQuote, tokenize("a \"oops", &buf, &argv));
    try expectError(error.Empty, tokenize("   ", &buf, &argv));
    var tiny: [4]u8 = undefined;
    try expectError(error.TooLong, tokenize("abcdefgh", &tiny, &argv));
}

test "parse defaults and commands" {
    var storage: [max_workers][]const u8 = undefined;
    const cfg = try parse(&.{ "./api --port 8080", "./worker" }, &storage);
    try expectEqual(RestartPolicy.never, cfg.restart);
    try expectEqual(@as(u64, 30_000), cfg.backoff_max_ms);
    try expectEqual(@as(usize, 2), cfg.commands.len);
    try expectEqualStrings("./worker", cfg.commands[1]);
}

test "parse flags" {
    var storage: [max_workers][]const u8 = undefined;
    const cfg = try parse(&.{ "--restart=on-failure", "--backoff-max=5s", "./a" }, &storage);
    try expectEqual(RestartPolicy.on_failure, cfg.restart);
    try expectEqual(@as(u64, 5_000), cfg.backoff_max_ms);
    try expectEqual(@as(usize, 1), cfg.commands.len);
}

test "parse double-dash separator makes flag-looking args commands" {
    var storage: [max_workers][]const u8 = undefined;
    const cfg = try parse(&.{ "--restart=always", "--", "--weird-command" }, &storage);
    try expectEqual(RestartPolicy.always, cfg.restart);
    try expectEqual(@as(usize, 1), cfg.commands.len);
    try expectEqualStrings("--weird-command", cfg.commands[0]);
}

test "parse errors" {
    var storage: [max_workers][]const u8 = undefined;
    try expectError(error.UnknownFlag, parse(&.{ "--nope", "./a" }, &storage));
    try expectError(error.BadValue, parse(&.{ "--restart=sometimes", "./a" }, &storage));
    try expectError(error.BadValue, parse(&.{ "--backoff-max=fast", "./a" }, &storage));
    try expectError(error.BadValue, parse(&.{ "--metrics=nope", "./a" }, &storage));
}

test "zero commands allowed (config file may supply workers)" {
    var storage: [max_workers][]const u8 = undefined;
    const cfg = try parse(&.{}, &storage);
    try expectEqual(@as(usize, 0), cfg.commands.len);
}

test "config and metrics flags, explicit-set tracking" {
    var storage: [max_workers][]const u8 = undefined;
    const cfg = try parse(&.{ "--config=/etc/mandor.toml", "--metrics=9464", "./a" }, &storage);
    try expectEqualStrings("/etc/mandor.toml", cfg.config_path.?);
    try expectEqual(@as(u16, 9464), cfg.metrics_port.?);
    try expect(!cfg.restart_set);
    const cfg2 = try parse(&.{ "--restart=always", "--backoff-max=1s", "./a" }, &storage);
    try expect(cfg2.restart_set);
    try expect(cfg2.backoff_set);
}

test "parse report subcommand" {
    var storage: [max_workers][]const u8 = undefined;
    const cfg = try parse(&.{ "report", "--json", "--state-dir=/tmp/x" }, &storage);
    try expectEqual(Mode.report, cfg.mode);
    try expect(cfg.json);
    try expectEqualStrings("/tmp/x", cfg.state_dir.?);
    try expectError(error.BadValue, parse(&.{ "report", "./cmd" }, &storage));
    // --json is report-only
    try expectError(error.UnknownFlag, parse(&.{ "--json", "./cmd" }, &storage));
}

test "health flags" {
    var storage: [max_workers][]const u8 = undefined;
    const cfg = try parse(&.{
        "--health=api=/bin/check-api --fast",
        "--health=worker=/bin/check-w",
        "--health-interval=10s",
        "--restart-on-unhealthy",
        "./api",
    }, &storage);
    try expectEqual(@as(u8, 2), cfg.health_n);
    try expectEqualStrings("api", cfg.health[0].worker);
    try expectEqualStrings("/bin/check-api --fast", cfg.health[0].cmd);
    try expectEqual(@as(u64, 10_000), cfg.health_interval_ms);
    try expect(cfg.restart_on_unhealthy);
    try expectError(error.BadValue, parse(&.{ "--health=nocmd", "./a" }, &storage));
}

test "ready-fd flag" {
    var storage: [max_workers][]const u8 = undefined;
    const cfg = try parse(&.{ "--ready-fd=5", "./a" }, &storage);
    try expectEqual(@as(?u8, 5), cfg.ready_fd);
    try expectError(error.BadValue, parse(&.{ "--ready-fd=1", "./a" }, &storage));
    try expectError(error.BadValue, parse(&.{ "--ready-fd=x", "./a" }, &storage));
}

test "stop-grace and expected-exit flags" {
    var storage: [max_workers][]const u8 = undefined;
    const cfg = try parse(&.{ "--stop-grace=3s", "--expected-exit=143,129", "./a" }, &storage);
    try expectEqual(@as(u64, 3_000), cfg.stop_grace_ms);
    try expect(cfg.expected_exit[0]);
    try expect(cfg.expected_exit[143]);
    try expect(cfg.expected_exit[129]);
    try expect(!cfg.expected_exit[1]);
    try expectError(error.BadValue, parse(&.{ "--expected-exit=abc", "./a" }, &storage));
    try expectError(error.BadValue, parse(&.{ "--stop-grace=oops", "./a" }, &storage));
}

test "parse help and version short-circuit NoCommands" {
    var storage: [max_workers][]const u8 = undefined;
    try expect((try parse(&.{"--help"}, &storage)).help);
    try expect((try parse(&.{"--version"}, &storage)).version);
}
