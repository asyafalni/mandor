//! CLI parsing for mandor. Pure code — no OS calls — so it unit-tests on any host.

const std = @import("std");

pub const max_workers = 64;
pub const max_health = 8;
pub const default_state_dir = "/var/lib/mandor";

pub const HealthSpec = struct { worker: []const u8, cmd: []const u8 };

pub const Mode = enum { supervise, report, validate };

pub const Config = struct {
    mode: Mode = .supervise,
    backoff_max_ms: u64 = 30_000,
    commands: []const []const u8 = &.{},
    help: bool = false,
    version: bool = false,
    json: bool = false,
    incidents: bool = false,
    cost: bool = false,
    /// report mode: limit rows to a worker name or pid.
    report_filter: ?[]const u8 = null,
    /// report --incidents: only bundles newer than now - since.
    since_ms: ?u64 = null,
    /// report --incident=N: dump the Nth incident bundle (1-based) raw.
    incident_index: ?usize = null,
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
    /// "dependent=dependency" ordering pairs (TOML-only; no CLI flag).
    start_after: [max_workers]HealthSpec = undefined,
    start_after_n: u8 = 0,
    /// How many times a *failed* worker is retried before mandor gives up and
    /// exits with its code. `0` (the default) means don't retry: a failure
    /// ends the run so the layer above is signalled. `-1` retries forever.
    /// Clean exits are never retried — a worker that exits 0 has finished.
    max_restarts: i32 = 0,
    max_restarts_set: bool = false,
    /// Probe failures within this window after spawn (and before the first
    /// success) don't count — the k8s startupProbe lesson.
    health_start_period_ms: u64 = 10_000,
    /// Command exec'd after each incident bundle write, bundle path appended.
    on_incident: ?[]const u8 = null,
    /// photon OTLP endpoint ("ip:port"); when set, incidents auto-forward.
    photon: ?[]const u8 = null,
    /// Container-wide PSI stall thresholds (whole percent; 0 = off).
    psi_mem_pct: u16 = 0,
    psi_cpu_pct: u16 = 0,
    /// Per-worker extras (TOML-only): "name=KEY=VAL" env pairs, "name=/path"
    /// working dirs, and names of workers that are one-shot init tasks.
    env_pairs: [64]HealthSpec = undefined,
    env_pairs_n: u8 = 0,
    cwd_pairs: [16]HealthSpec = undefined,
    cwd_pairs_n: u8 = 0,
    oneshot: [16][]const u8 = undefined,
    oneshot_n: u8 = 0,
    /// "name=uid:gid" privilege drops (numeric only — scratch has no passwd).
    user_pairs: [16]HealthSpec = undefined,
    user_pairs_n: u8 = 0,
    cap_drop_pairs: [16]HealthSpec = undefined,
    cap_drop_pairs_n: u8 = 0,
    oom_pairs: [16]HealthSpec = undefined,
    oom_pairs_n: u8 = 0,
    nice_pairs: [16]HealthSpec = undefined,
    nice_pairs_n: u8 = 0,
    max_rss_pairs: [16]HealthSpec = undefined,
    max_rss_pairs_n: u8 = 0,
    lifetime_pairs: [16]HealthSpec = undefined,
    lifetime_pairs_n: u8 = 0,
    /// Per-worker `expected_exit` overrides ("name" -> "143,129").
    expected_pairs: [16]HealthSpec = undefined,
    expected_pairs_n: u8 = 0,
    /// Workers marked `essential = false`. Every worker is essential by
    /// default — its failure ends the run — so this records the opt-outs.
    not_essential: [16][]const u8 = undefined,
    not_essential_n: u8 = 0,
    /// OTP rest_for_one: a dependency's restart also restarts dependents.
    restart_dependents: bool = false,
    /// "name=CMD" drain hooks exec'd before TERM on graceful shutdown.
    prestop_pairs: [16]HealthSpec = undefined,
    prestop_pairs_n: u8 = 0,
    /// Optional KEY=VAL file loaded into every worker's environment.
    env_file: ?[]const u8 = null,
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

pub const ParseError = error{ UnknownFlag, BadValue, TooManyWorkers, RestartRemoved, UnhealthyFlagRemoved, MovedToToml };

pub fn parse(
    args: []const []const u8,
    cmd_storage: *[max_workers][]const u8,
    out: *Config,
) ParseError!void {
    // See config.parse: returning this by value costs ~10 KB of .rodata
    // for every distinct error-return path.
    out.* = .{};
    const cfg = out;
    var n: usize = 0;
    var no_more_flags = false;
    for (args, 0..) |arg, arg_idx| {
        if (arg_idx == 0 and std.mem.eql(u8, arg, "report")) {
            cfg.mode = .report;
            continue;
        }
        if (arg_idx == 0 and std.mem.eql(u8, arg, "validate")) {
            cfg.mode = .validate;
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
                // Removed in 1.3: one integer replaces the policy enum.
                return error.RestartRemoved;
            } else if (std.mem.startsWith(u8, arg, "--restart-on-unhealthy")) {
                // Removed in 1.3: a configured probe is always acted on.
                return error.UnhealthyFlagRemoved;
            } else if (std.mem.startsWith(u8, arg, "--backoff-max=") or
                std.mem.startsWith(u8, arg, "--health-start-period=") or
                std.mem.startsWith(u8, arg, "--on-incident=") or
                std.mem.startsWith(u8, arg, "--photon=") or
                std.mem.startsWith(u8, arg, "--psi-mem=") or
                std.mem.startsWith(u8, arg, "--psi-cpu=") or
                std.mem.startsWith(u8, arg, "--health=") or
                std.mem.startsWith(u8, arg, "--health-interval=") or
                std.mem.startsWith(u8, arg, "--ready-fd=") or
                std.mem.startsWith(u8, arg, "--stop-grace=") or
                std.mem.startsWith(u8, arg, "--expected-exit="))
            {
                // Advanced settings live in mandor.toml, so the everyday CLI
                // stays at four flags. Nothing is lost: every one of these is
                // a TOML key with the same name minus the dashes.
                return error.MovedToToml;
            } else if (std.mem.startsWith(u8, arg, "--max-restarts=")) {
                cfg.max_restarts = std.fmt.parseInt(i32, arg["--max-restarts=".len..], 10) catch
                    return error.BadValue;
                if (cfg.max_restarts < -1) return error.BadValue;
                cfg.max_restarts_set = true;
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
            } else if (std.mem.eql(u8, arg, "--cost")) {
                if (cfg.mode != .report) return error.UnknownFlag;
                cfg.cost = true;
            } else if (std.mem.eql(u8, arg, "--incidents")) {
                if (cfg.mode != .report) return error.UnknownFlag;
                cfg.incidents = true;
            } else if (std.mem.startsWith(u8, arg, "--since=")) {
                if (cfg.mode != .report) return error.UnknownFlag;
                cfg.since_ms = parseDuration(arg["--since=".len..]) orelse
                    return error.BadValue;
            } else if (std.mem.startsWith(u8, arg, "--incident=")) {
                if (cfg.mode != .report) return error.UnknownFlag;
                cfg.incidents = true;
                cfg.incident_index = std.fmt.parseInt(usize, arg["--incident=".len..], 10) catch
                    return error.BadValue;
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
        // report takes at most one positional: a worker name or pid filter
        if (n > 1) return error.BadValue;
        if (n == 1) {
            cfg.report_filter = cmd_storage[0];
            cfg.commands = cmd_storage[0..0];
        }
        return;
    }
    // Zero commands is legal here: a config file may provide the workers.
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
    } else if (std.mem.endsWith(u8, s, "h")) {
        mult = 3_600_000;
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

/// By-value wrapper so tests read naturally. Test-only: never in the binary.
fn parseTest(args: []const []const u8, cmd_storage: *[max_workers][]const u8) ParseError!Config {
    var cfg: Config = undefined;
    try parse(args, cmd_storage, &cfg);
    return cfg;
}

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
    const cfg = try parseTest(&.{ "./api --port 8080", "./worker" }, &storage);
    try expectEqual(@as(i32, 0), cfg.max_restarts); // give up first by default
    try expectEqual(@as(u64, 30_000), cfg.backoff_max_ms);
    try expectEqual(@as(usize, 2), cfg.commands.len);
    try expectEqualStrings("./worker", cfg.commands[1]);
}

test "parse flags" {
    var storage: [max_workers][]const u8 = undefined;
    const cfg = try parseTest(&.{ "--max-restarts=3", "./a" }, &storage);
    try expectEqual(@as(i32, 3), cfg.max_restarts);
    try expectEqual(@as(usize, 1), cfg.commands.len);
}

test "parse double-dash separator makes flag-looking args commands" {
    var storage: [max_workers][]const u8 = undefined;
    const cfg = try parseTest(&.{ "--max-restarts=-1", "--", "--weird-command" }, &storage);
    try expectEqual(@as(i32, -1), cfg.max_restarts); // -1 = retry forever
    try expectEqual(@as(usize, 1), cfg.commands.len);
    try expectEqualStrings("--weird-command", cfg.commands[0]);
}

test "parse errors" {
    var storage: [max_workers][]const u8 = undefined;
    try expectError(error.UnknownFlag, parseTest(&.{ "--nope", "./a" }, &storage));
    // Removed flags report *why*, so the message can name the replacement.
    try expectError(error.RestartRemoved, parseTest(&.{ "--restart=on-failure", "./a" }, &storage));
    try expectError(error.UnhealthyFlagRemoved, parseTest(&.{ "--restart-on-unhealthy", "./a" }, &storage));
    try expectError(error.BadValue, parseTest(&.{ "--max-restarts=-2", "./a" }, &storage));
    try expectError(error.BadValue, parseTest(&.{ "--max-restarts=lots", "./a" }, &storage));
    try expectError(error.BadValue, parseTest(&.{ "--metrics=nope", "./a" }, &storage));
}

test "zero commands allowed (config file may supply workers)" {
    var storage: [max_workers][]const u8 = undefined;
    const cfg = try parseTest(&.{}, &storage);
    try expectEqual(@as(usize, 0), cfg.commands.len);
}

test "the CLI is four flags; everything else moved to mandor.toml" {
    var storage: [max_workers][]const u8 = undefined;
    const cfg = try parseTest(&.{
        "--config=/etc/mandor.toml", "--metrics=9464", "--state-dir=/srv/s",
        "--max-restarts=2",          "./a",
    }, &storage);
    try expectEqualStrings("/etc/mandor.toml", cfg.config_path.?);
    try expectEqual(@as(u16, 9464), cfg.metrics_port.?);
    try expectEqualStrings("/srv/s", cfg.state_dir.?);
    try expect(cfg.max_restarts_set);

    // Advanced settings are TOML keys now, and say so rather than being
    // reported as an unknown flag.
    for ([_][]const u8{
        "--backoff-max=1s",  "--stop-grace=5s",      "--expected-exit=143",
        "--health=a=/bin/t", "--health-interval=1s", "--health-start-period=1s",
        "--ready-fd=5",      "--on-incident=/n",     "--photon=1.2.3.4:1",
        "--psi-mem=80",      "--psi-cpu=90",
    }) |flag| {
        try expectError(error.MovedToToml, parseTest(&.{ flag, "./a" }, &storage));
    }
}

test "parse report subcommand" {
    var storage: [max_workers][]const u8 = undefined;
    const cfg = try parseTest(&.{ "report", "--json", "--state-dir=/tmp/x" }, &storage);
    try expectEqual(Mode.report, cfg.mode);
    try expect(cfg.json);
    try expectEqualStrings("/tmp/x", cfg.state_dir.?);
    const cf = try parseTest(&.{ "report", "api", "--since=1h" }, &storage);
    try expectEqualStrings("api", cf.report_filter.?);
    try expectEqual(@as(u64, 3_600_000), cf.since_ms.?);
    try expectError(error.BadValue, parseTest(&.{ "report", "a", "b" }, &storage));
    // --json is report-only
    try expectError(error.UnknownFlag, parseTest(&.{ "--json", "./cmd" }, &storage));
}

test "parse help and version short-circuit NoCommands" {
    var storage: [max_workers][]const u8 = undefined;
    try expect((try parseTest(&.{"--help"}, &storage)).help);
    try expect((try parseTest(&.{"--version"}, &storage)).version);
}
