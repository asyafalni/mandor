//! CLI parsing for mandor. Pure code — no OS calls — so it unit-tests on any host.

const std = @import("std");

pub const max_workers = 64;
pub const default_state_dir = "/var/lib/mandor";

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
    /// null = not given on the CLI; caller resolves env/default.
    state_dir: ?[]const u8 = null,
};

pub const ParseError = error{ UnknownFlag, BadValue, NoCommands, TooManyWorkers };

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
            } else if (std.mem.startsWith(u8, arg, "--backoff-max=")) {
                cfg.backoff_max_ms = parseDuration(arg["--backoff-max=".len..]) orelse
                    return error.BadValue;
            } else if (std.mem.startsWith(u8, arg, "--state-dir=")) {
                const v = arg["--state-dir=".len..];
                if (v.len == 0) return error.BadValue;
                cfg.state_dir = v;
            } else if (std.mem.eql(u8, arg, "--json")) {
                if (cfg.mode != .report) return error.UnknownFlag;
                cfg.json = true;
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
    if (cfg.mode == .report) {
        if (n != 0) return error.BadValue; // report takes no commands
        return cfg;
    }
    if (n == 0 and !cfg.help and !cfg.version) return error.NoCommands;
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
    try expectError(error.NoCommands, parse(&.{}, &storage));
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

test "parse help and version short-circuit NoCommands" {
    var storage: [max_workers][]const u8 = undefined;
    try expect((try parse(&.{"--help"}, &storage)).help);
    try expect((try parse(&.{"--version"}, &storage)).version);
}
