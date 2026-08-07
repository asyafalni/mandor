//! mandor.toml — a deliberately tiny TOML subset. CLI-only operation is the
//! first-class path; this file only ever *lowers* friction.
//!
//! Supported: `key = "string"`, `key = 123`, `key = ["a", "b"]` (single line
//! or multiline), `#` comments, blank lines. Nothing else.

const std = @import("std");
const cli = @import("cli.zig");
const names = @import("names.zig");
const secret = @import("secret.zig");

pub const FileConfig = struct {
    backoff_max_ms: ?u64 = null,
    state_dir: ?[]const u8 = null, // slice into the file buffer
    /// Tenant/origin tag prepended to `service.name` on every OTLP emission so
    /// multiple mandor origins publishing to one multi-tenant photon stay
    /// distinct. null = key absent (caller keeps the cli.Config default of "").
    service_prefix: ?[]const u8 = null, // slice into the file buffer
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
    /// `[gpu]` section: null = key absent (caller keeps the cli.Config default).
    gpu_enabled: ?bool = null,
    gpu_interval_ms: ?u64 = null,
    /// `[logs]` section: null = key absent (caller keeps the cli.Config default).
    logs_stream: ?bool = null,
    logs_max_rate: ?u32 = null,
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
    /// Per-worker display/telemetry `name` overrides ("start.sh" -> "api").
    /// Keyed by the DERIVED basename (the section name); the value replaces it.
    name_pairs: [16]cli.HealthSpec = undefined,
    name_pairs_n: u8 = 0,
    /// Workers marked `essential = false`. Every worker is essential by
    /// default, so this records the *opt-outs*.
    not_essential: [16][]const u8 = undefined,
    not_essential_n: u8 = 0,
    env_file: ?[]const u8 = null,
    restart_dependents: ?bool = null,
    prestop_pairs: [16]cli.HealthSpec = undefined,
    prestop_pairs_n: u8 = 0,
    commands: []const []const u8 = &.{},
    /// `[secret.NAME]` sections. `name`/`env`/`fmt`/`n` and the resolved worker
    /// indices are filled here and copied into cli.Config verbatim.
    secrets: [cli.max_secrets]cli.SecretDef = undefined,
    secrets_n: usize = 0,
    /// Per-secret worker-name refs (slices into `text`), collected during
    /// parse and resolved to indices in `resolveSecrets` at the end. Transient:
    /// never copied into cli.Config, so `secrets[*].workers` holds indices only.
    secret_refs: [cli.max_secrets][cli.max_secret_workers][]const u8 = undefined,
};

/// Backing store for derived `CONFD_<NAME>` env names (used only when a secret
/// omits `env`). Module-level so the `SecretDef.env` slice survives a by-value
/// `FileConfig` return — a slice into `FileConfig`'s own storage would dangle.
/// Boot-only writes, read-only thereafter.
var env_store: [cli.max_secrets][64]u8 = undefined;

/// Mirrors `spawner.name_cap`. Kept as a local const so config.zig stays a pure,
/// dependency-free module (it must not import the OS-coupled spawner). Worker
/// name derivation below reproduces `spawner.setName` so a `[secret.*]` grant
/// resolves to exactly the worker `start_after` and the other name refs see.
const worker_max_args = 64; // mirrors spawner.max_args

const ArrayTarget = enum { none, workers, health, start_after, env, cwd, user, cap_drop, oom, nice, max_rss, lifetime, expected, pre_stop, name, secret_workers };

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
        .name => .{ .arr = &cfg.name_pairs, .n = &cfg.name_pairs_n },
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
    var array_secret: ?usize = null; // secret owning an open workers array, if any
    var cur_worker: ?[]const u8 = null; // active [worker.NAME] section
    var cur_secret: ?usize = null; // active [secret.NAME] section (index)
    var cur_gpu = false; // active [gpu] section
    var cur_logs = false; // active [logs] section

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
            if (target == .secret_workers) {
                const si = array_secret orelse return error.Syntax;
                try appendSecretRef(cfg, si, s);
            } else {
                try appendItem(cfg, cmd_storage, &ncmd, target, array_worker, s);
            }
            if (std.mem.endsWith(u8, line, "]")) target = .none;
            continue;
        }

        // [worker.NAME] / [secret.NAME] — every key below scopes to it.
        if (line[0] == '[') {
            switch (try sectionHeader(line)) {
                .worker => |nm| {
                    cur_worker = nm;
                    cur_secret = null;
                    cur_gpu = false;
                    cur_logs = false;
                },
                .secret => |nm| {
                    cur_worker = null;
                    cur_gpu = false;
                    cur_logs = false;
                    cur_secret = try beginSecret(cfg, nm);
                },
                .gpu => {
                    cur_worker = null;
                    cur_secret = null;
                    cur_gpu = true;
                    cur_logs = false;
                },
                .logs => {
                    cur_worker = null;
                    cur_secret = null;
                    cur_gpu = false;
                    cur_logs = true;
                },
            }
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.Syntax;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (cur_worker) |w| {
            try workerSetting(cfg, cmd_storage, &ncmd, &target, &array_worker, w, key, value);
            continue;
        }

        if (cur_secret) |si| {
            try secretSetting(cfg, si, &target, &array_secret, key, value);
            continue;
        }

        if (cur_gpu) {
            try gpuSetting(cfg, key, value);
            continue;
        }

        if (cur_logs) {
            try logsSetting(cfg, key, value);
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
        } else if (std.mem.eql(u8, key, "service_prefix")) {
            // Origin tag for multi-tenant photon. Capped so it always fits the
            // daemon's fixed BSS copy buffer (relay.service_prefix_cap); an
            // over-long value is a hard error, never a silent truncation.
            const s = parseString(value) orelse return error.BadValue;
            if (s.len > cli.max_service_prefix) return error.BadValue;
            cfg.service_prefix = s;
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
    try resolveSecrets(cfg);
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
        .{ "name", ArrayTarget.name },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, key, entry[0])) return entry[1];
    }
    return null;
}

const Section = union(enum) { worker: []const u8, secret: []const u8, gpu, logs };

/// `[worker.NAME]` / `[secret.NAME]` / `[gpu]` / `[logs]` -> the section kind
/// (+ NAME for the first two). Any other header is a hard error: configs are
/// small, so a typo should stop startup rather than be silently ignored.
fn sectionHeader(line: []const u8) ParseError!Section {
    if (line[line.len - 1] != ']') return error.Syntax;
    const inner = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
    if (std.mem.eql(u8, inner, "gpu")) return .gpu;
    if (std.mem.eql(u8, inner, "logs")) return .logs;
    if (sectionName(inner, "worker.")) |nm| return .{ .worker = nm };
    if (sectionName(inner, "secret.")) |nm| return .{ .secret = nm };
    return error.Syntax;
}

/// Apply one `key = value` inside `[gpu]`. `enabled` is a bare bool; `interval`
/// is a quoted duration string ("15s"). Unknown key -> hard Syntax error.
fn gpuSetting(cfg: *FileConfig, key: []const u8, value: []const u8) ParseError!void {
    if (std.mem.eql(u8, key, "enabled")) {
        cfg.gpu_enabled = if (std.mem.eql(u8, value, "true"))
            true
        else if (std.mem.eql(u8, value, "false"))
            false
        else
            return error.BadValue;
    } else if (std.mem.eql(u8, key, "interval")) {
        const s = parseString(value) orelse return error.BadValue;
        cfg.gpu_interval_ms = cli.parseDuration(s) orelse return error.BadValue;
    } else {
        return error.Syntax; // unknown key inside a [gpu] section
    }
}

/// Apply one `key = value` inside `[logs]`. `stream` is a bare bool; `max_rate`
/// is a bare non-negative int (lines/sec, 0 = unlimited). Unknown key -> hard
/// Syntax error (a mistyped key should stop startup, not be silently ignored).
fn logsSetting(cfg: *FileConfig, key: []const u8, value: []const u8) ParseError!void {
    if (std.mem.eql(u8, key, "stream")) {
        cfg.logs_stream = if (std.mem.eql(u8, value, "true"))
            true
        else if (std.mem.eql(u8, value, "false"))
            false
        else
            return error.BadValue;
    } else if (std.mem.eql(u8, key, "max_rate")) {
        // Bare int, lines/sec. Range 0..u32-max; a negative or non-numeric value
        // (parseInt rejects the sign for an unsigned type) is a hard BadValue so a
        // typo cannot silently disable the cap.
        cfg.logs_max_rate = std.fmt.parseInt(u32, value, 10) catch return error.BadValue;
    } else {
        return error.Syntax; // unknown key inside a [logs] section
    }
}

/// `<prefix>NAME` -> NAME, else null (unknown prefix or empty name).
fn sectionName(inner: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, inner, prefix)) return null;
    var name = std.mem.trim(u8, inner[prefix.len..], " \t");
    // A TOML-quoted key lets a name with a dot read naturally —
    // `[worker."start.sh"]` — since a bare dot would otherwise look like a
    // nested table. The subset takes the literal remainder either way.
    if (name.len >= 2 and name[0] == '"' and name[name.len - 1] == '"')
        name = name[1 .. name.len - 1];
    if (name.len == 0) return null;
    return name;
}

/// Start a `[secret.NAME]` section: validate the name, reject a duplicate, then
/// seed defaults (hex / 32 bytes) and the derived `CONFD_<NAME>` env. Returns
/// the new secret's index.
fn beginSecret(cfg: *FileConfig, name: []const u8) ParseError!usize {
    if (!validSecretName(name)) return error.Syntax;
    for (cfg.secrets[0..cfg.secrets_n]) |*s| {
        if (std.mem.eql(u8, s.name, name)) return error.BadValue; // duplicate secret
    }
    if (cfg.secrets_n == cfg.secrets.len) return error.BadValue; // too many secrets
    const idx = cfg.secrets_n;
    cfg.secrets[idx] = .{
        .name = name,
        .env = try deriveEnv(idx, name),
        .fmt = .hex,
        .n = 32,
        .workers = undefined,
        .workers_len = 0,
    };
    cfg.secrets_n += 1;
    return idx;
}

/// Apply one `key = value` inside `[secret.NAME]`.
fn secretSetting(
    cfg: *FileConfig,
    si: usize,
    target: *ArrayTarget,
    array_secret: *?usize,
    key: []const u8,
    value: []const u8,
) ParseError!void {
    if (std.mem.eql(u8, key, "workers")) {
        if (value.len == 0 or value[0] != '[') return error.BadValue;
        var rest = std.mem.trim(u8, value[1..], " \t");
        const closed = std.mem.endsWith(u8, rest, "]");
        if (closed) rest = std.mem.trim(u8, rest[0 .. rest.len - 1], " \t");
        var items = std.mem.splitScalar(u8, rest, ',');
        while (items.next()) |item_raw| {
            const item = std.mem.trim(u8, item_raw, " \t");
            if (item.len == 0) continue;
            const s = parseString(item) orelse return error.BadValue;
            try appendSecretRef(cfg, si, s);
        }
        if (!closed) {
            target.* = .secret_workers;
            array_secret.* = si;
        }
    } else if (std.mem.eql(u8, key, "bytes")) {
        const nbytes = std.fmt.parseInt(usize, value, 10) catch return error.BadValue;
        if (nbytes == 0 or nbytes > secret.max_bytes) return error.BadValue; // range 1..4096
        cfg.secrets[si].n = nbytes;
    } else if (std.mem.eql(u8, key, "format")) {
        const s = parseString(value) orelse return error.BadValue;
        cfg.secrets[si].fmt = secret.parseFormat(s) orelse return error.BadValue; // unknown format
    } else if (std.mem.eql(u8, key, "env")) {
        const s = parseString(value) orelse return error.BadValue;
        if (!validEnvName(s)) return error.BadValue; // ^[A-Z_][A-Z0-9_]*$
        cfg.secrets[si].env = s; // slice into `text`
    } else {
        return error.Syntax; // unknown key inside a [secret.*] section
    }
}

/// Record one worker-name ref for a secret (resolved to an index at parse end).
fn appendSecretRef(cfg: *FileConfig, si: usize, name: []const u8) ParseError!void {
    const len = cfg.secrets[si].workers_len;
    if (len == cfg.secret_refs[si].len) return error.BadValue; // too many workers
    cfg.secret_refs[si][len] = name;
    cfg.secrets[si].workers_len = len + 1;
}

fn validSecretName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-')) return false;
    }
    return true;
}

/// `^[A-Z_][A-Z0-9_]*$` — the env-var naming rule for an `env` override.
fn validEnvName(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!((s[0] >= 'A' and s[0] <= 'Z') or s[0] == '_')) return false;
    for (s[1..]) |c| {
        if (!((c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_')) return false;
    }
    return true;
}

/// Default env var name: `CONFD_` + NAME uppercased with `-` -> `_`. Written
/// into `env_store[idx]`; the derived name always matches `validEnvName`.
fn deriveEnv(idx: usize, name: []const u8) ParseError![]const u8 {
    const prefix = "CONFD_";
    if (prefix.len + name.len > env_store[idx].len) return error.BadValue; // name too long
    var w: usize = 0;
    for (prefix) |c| {
        env_store[idx][w] = c;
        w += 1;
    }
    for (name) |c| {
        env_store[idx][w] = if (c == '-') '_' else std.ascii.toUpper(c);
        w += 1;
    }
    return env_store[idx][0..w];
}

/// End-of-parse pass: resolve each secret's worker-name refs to indices, reject
/// an empty grant or an unknown worker, and reject two secrets sharing an env
/// var. Every failure is a hard error — a mis-grant must stop startup, never be
/// applied silently (deny-by-default is only safe if the grant is exact).
fn resolveSecrets(cfg: *FileConfig) ParseError!void {
    if (cfg.secrets_n == 0) return;

    // Worker display names, derived once through the SAME names.finalize the
    // spawner uses, so a grant keys on the same pre-override name that
    // start_after and the other name refs resolve against.
    var name_bufs: [cli.max_workers][names.cap]u8 = undefined;
    var derived: [cli.max_workers][]const u8 = undefined;
    for (cfg.commands, 0..) |cmd, i| derived[i] = deriveOne(cmd, name_bufs[i][0..], derived[0..i]);
    const resolved = derived[0..cfg.commands.len];

    var si: usize = 0;
    while (si < cfg.secrets_n) : (si += 1) {
        const sec = &cfg.secrets[si];
        if (sec.workers_len == 0) return error.BadValue; // empty workers
        var k: usize = 0;
        while (k < sec.workers_len) : (k += 1) {
            sec.workers[k] = matchWorker(resolved, cfg.secret_refs[si][k]) orelse
                return error.BadValue; // unknown worker in `workers`
        }
    }
    // Env collisions: derived or overridden, two secrets must not share an env.
    var a: usize = 0;
    while (a < cfg.secrets_n) : (a += 1) {
        var b: usize = a + 1;
        while (b < cfg.secrets_n) : (b += 1) {
            if (std.mem.eql(u8, cfg.secrets[a].env, cfg.secrets[b].env)) return error.BadValue;
        }
    }
}

/// A worker's finalized name from its command string, derived the same way the
/// spawner does at spawn time: basename of argv0 through `names.finalize` (cap +
/// dedup + neutralize). Empty on a tokenize failure — `matchWorker` skips empty
/// names, so a malformed command simply matches no grant.
fn deriveOne(cmd: []const u8, out: []u8, prior: []const []const u8) []const u8 {
    var tokbuf: [4096]u8 = undefined; // matches spawner.Worker.cmd_buf
    var toks: [worker_max_args][]const u8 = undefined;
    const argv = cli.tokenize(cmd, &tokbuf, &toks) catch return out[0..0];
    return names.finalize(names.basename(argv[0]), prior, out);
}

/// Match a grant's worker-name ref to a worker index by the derived names.
fn matchWorker(derived: []const []const u8, ref: []const u8) ?u8 {
    for (derived, 0..) |nm, i| {
        if (nm.len != 0 and std.mem.eql(u8, nm, ref)) return @as(u8, @intCast(i));
    }
    return null;
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

test "service_prefix parses and rejects an over-long value" {
    var storage: [cli.max_workers][]const u8 = undefined;
    // A short prefix parses (slice into the file text).
    const cfg = try parseTest("service_prefix = \"tenant-a-\"", &storage);
    try t.expectEqualStrings("tenant-a-", cfg.service_prefix.?);
    // Absent -> null (caller keeps the cli.Config default of "").
    const none = try parseTest("workers = [\"./a\"]", &storage);
    try t.expectEqual(@as(?[]const u8, null), none.service_prefix);
    // Exactly at the cap is accepted; one past it is a hard BadValue (no silent
    // truncation — the daemon's copy buffer is fixed at cli.max_service_prefix).
    const at_cap = "service_prefix = \"" ++ ("p" ** cli.max_service_prefix) ++ "\"";
    _ = try parseTest(at_cap, &storage);
    const over = "service_prefix = \"" ++ ("p" ** (cli.max_service_prefix + 1)) ++ "\"";
    try t.expectError(error.BadValue, parseTest(over, &storage));
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

test "worker section: name override keyed by derived basename" {
    var storage: [cli.max_workers][]const u8 = undefined;
    const text =
        \\workers = ["./start.sh --serve", "./worker"]
        \\
        \\[worker."start.sh"]
        \\name = "api"
    ;
    const cfg = try parseTest(text, &storage);
    try t.expectEqual(@as(u8, 1), cfg.name_pairs_n);
    try t.expectEqualStrings("start.sh", cfg.name_pairs[0].worker);
    try t.expectEqualStrings("api", cfg.name_pairs[0].cmd);
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

test "secret section: defaults and worker index resolution" {
    var storage: [cli.max_workers][]const u8 = undefined;
    const text =
        \\workers = ["gateway", "proxy"]
        \\
        \\[secret.integration]
        \\workers = ["gateway", "proxy"]
    ;
    const cfg = try parseTest(text, &storage);
    try t.expectEqual(@as(usize, 1), cfg.secrets_n);
    const s = cfg.secrets[0];
    try t.expectEqualStrings("integration", s.name);
    try t.expectEqualStrings("CONFD_INTEGRATION", s.env);
    try t.expectEqual(secret.Format.hex, s.fmt);
    try t.expectEqual(@as(usize, 32), s.n);
    try t.expectEqual(@as(usize, 2), s.workers_len);
    // "gateway" is worker 0, "proxy" is worker 1 (order = commands order).
    try t.expectEqual(@as(u8, 0), s.workers[0]);
    try t.expectEqual(@as(u8, 1), s.workers[1]);
}

test "secret section: bytes/format/env overrides" {
    var storage: [cli.max_workers][]const u8 = undefined;
    const text =
        \\workers = ["gateway"]
        \\
        \\[secret.otp]
        \\workers = ["gateway"]
        \\bytes = 6
        \\format = "b10"
        \\env = "APP_CODE"
    ;
    const cfg = try parseTest(text, &storage);
    try t.expectEqual(@as(usize, 1), cfg.secrets_n);
    const s = cfg.secrets[0];
    try t.expectEqual(@as(usize, 6), s.n);
    try t.expectEqual(secret.Format.b10, s.fmt);
    try t.expectEqualStrings("APP_CODE", s.env);
}

test "secret section: default env derives from a hyphenated name" {
    var storage: [cli.max_workers][]const u8 = undefined;
    const text =
        \\workers = ["db"]
        \\
        \\[secret.db-signing]
        \\workers = ["db"]
    ;
    const cfg = try parseTest(text, &storage);
    try t.expectEqualStrings("db-signing", cfg.secrets[0].name);
    try t.expectEqualStrings("CONFD_DB_SIGNING", cfg.secrets[0].env);
}

test "secret section: multiline workers array resolves" {
    var storage: [cli.max_workers][]const u8 = undefined;
    const text =
        \\workers = ["gateway", "proxy"]
        \\
        \\[secret.integration]
        \\workers = [
        \\  "gateway",
        \\  "proxy",
        \\]
    ;
    const cfg = try parseTest(text, &storage);
    try t.expectEqual(@as(usize, 2), cfg.secrets[0].workers_len);
    try t.expectEqual(@as(u8, 0), cfg.secrets[0].workers[0]);
    try t.expectEqual(@as(u8, 1), cfg.secrets[0].workers[1]);
}

test "secret section: two secrets are independent" {
    var storage: [cli.max_workers][]const u8 = undefined;
    const text =
        \\workers = ["gateway", "proxy", "cron"]
        \\
        \\[secret.integration]
        \\workers = ["gateway", "proxy"]
        \\
        \\[secret.cron-token]
        \\workers = ["cron"]
    ;
    const cfg = try parseTest(text, &storage);
    try t.expectEqual(@as(usize, 2), cfg.secrets_n);
    try t.expectEqualStrings("CONFD_INTEGRATION", cfg.secrets[0].env);
    try t.expectEqualStrings("CONFD_CRON_TOKEN", cfg.secrets[1].env);
    try t.expectEqual(@as(u8, 2), cfg.secrets[1].workers[0]); // "cron" is worker 2
}

test "secret section: every rejection is a hard error" {
    var storage: [cli.max_workers][]const u8 = undefined;
    const W = "workers = [\"gateway\"]\n";
    // unknown worker in `workers`
    try t.expectError(error.BadValue, parseTest(W ++ "[secret.s]\nworkers = [\"nope\"]", &storage));
    // empty `workers`
    try t.expectError(error.BadValue, parseTest(W ++ "[secret.s]\nworkers = []", &storage));
    // bytes == 0 and bytes > 4096
    try t.expectError(error.BadValue, parseTest(W ++ "[secret.s]\nworkers = [\"gateway\"]\nbytes = 0", &storage));
    try t.expectError(error.BadValue, parseTest(W ++ "[secret.s]\nworkers = [\"gateway\"]\nbytes = 4097", &storage));
    // unknown format
    try t.expectError(error.BadValue, parseTest(W ++ "[secret.s]\nworkers = [\"gateway\"]\nformat = \"base58\"", &storage));
    // env not matching ^[A-Z_][A-Z0-9_]*$ (lowercase, and a space)
    try t.expectError(error.BadValue, parseTest(W ++ "[secret.s]\nworkers = [\"gateway\"]\nenv = \"lower\"", &storage));
    try t.expectError(error.BadValue, parseTest(W ++ "[secret.s]\nworkers = [\"gateway\"]\nenv = \"HAS SPACE\"", &storage));
    // two secrets resolving to the same env (collision)
    try t.expectError(error.BadValue, parseTest(
        W ++ "[secret.a]\nworkers = [\"gateway\"]\nenv = \"SHARED\"\n[secret.b]\nworkers = [\"gateway\"]\nenv = \"SHARED\"",
        &storage,
    ));
    // unknown key inside a [secret.*] section
    try t.expectError(error.Syntax, parseTest(W ++ "[secret.s]\nworkers = [\"gateway\"]\nbogus = \"x\"", &storage));
    // duplicate secret name
    try t.expectError(error.BadValue, parseTest(
        W ++ "[secret.dup]\nworkers = [\"gateway\"]\n[secret.dup]\nworkers = [\"gateway\"]",
        &storage,
    ));
}

test "gpu section: enabled + interval" {
    var storage: [cli.max_workers][]const u8 = undefined;
    const text =
        \\[gpu]
        \\enabled = true
        \\interval = "10s"
    ;
    const cfg = try parseTest(text, &storage);
    try t.expectEqual(@as(?bool, true), cfg.gpu_enabled);
    try t.expectEqual(@as(?u64, 10_000), cfg.gpu_interval_ms);
}

test "gpu section: absent keys stay null; bad values and unknown key rejected" {
    var storage: [cli.max_workers][]const u8 = undefined;
    // No [gpu] section at all -> both fields null (caller keeps cli defaults).
    const none = try parseTest("workers = [\"./a\"]", &storage);
    try t.expectEqual(@as(?bool, null), none.gpu_enabled);
    try t.expectEqual(@as(?u64, null), none.gpu_interval_ms);
    // enabled defaults off when the section exists but omits it.
    const off = try parseTest("[gpu]\ninterval = \"5s\"", &storage);
    try t.expectEqual(@as(?bool, null), off.gpu_enabled);
    try t.expectEqual(@as(?u64, 5_000), off.gpu_interval_ms);
    // Bad bool, bad duration, unknown key.
    try t.expectError(error.BadValue, parseTest("[gpu]\nenabled = yes", &storage));
    try t.expectError(error.BadValue, parseTest("[gpu]\ninterval = \"soon\"", &storage));
    try t.expectError(error.Syntax, parseTest("[gpu]\nbogus = \"x\"", &storage));
}

test "logs section: stream true/false and default-absent" {
    var storage: [cli.max_workers][]const u8 = undefined;
    // stream = true
    const on = try parseTest("[logs]\nstream = true", &storage);
    try t.expectEqual(@as(?bool, true), on.logs_stream);
    // stream = false is the explicit default
    const off = try parseTest("[logs]\nstream = false", &storage);
    try t.expectEqual(@as(?bool, false), off.logs_stream);
    // No [logs] section at all -> null (caller keeps the cli.Config default).
    const none = try parseTest("workers = [\"./a\"]", &storage);
    try t.expectEqual(@as(?bool, null), none.logs_stream);
    // Bad bool and unknown key inside [logs] are hard errors.
    try t.expectError(error.BadValue, parseTest("[logs]\nstream = yes", &storage));
    try t.expectError(error.Syntax, parseTest("[logs]\nbogus = \"x\"", &storage));
}

test "logs section: max_rate parses, defaults absent, rejects bad values" {
    var storage: [cli.max_workers][]const u8 = undefined;
    // A positive cap parses as a bare int.
    const cap = try parseTest("[logs]\nstream = true\nmax_rate = 500", &storage);
    try t.expectEqual(@as(?u32, 500), cap.logs_max_rate);
    // 0 = unlimited is a legal explicit value.
    const unlimited = try parseTest("[logs]\nmax_rate = 0", &storage);
    try t.expectEqual(@as(?u32, 0), unlimited.logs_max_rate);
    // Absent -> null (caller keeps the cli.Config default of 0/unlimited).
    const none = try parseTest("[logs]\nstream = true", &storage);
    try t.expectEqual(@as(?u32, null), none.logs_max_rate);
    // Non-numeric and negative are hard errors (parseInt rejects the sign for a
    // u32), so a typo cannot silently disable the cap.
    try t.expectError(error.BadValue, parseTest("[logs]\nmax_rate = fast", &storage));
    try t.expectError(error.BadValue, parseTest("[logs]\nmax_rate = -1", &storage));
    // A value past u32 overflows parseInt -> BadValue (guards the upper bound).
    try t.expectError(error.BadValue, parseTest("[logs]\nmax_rate = 9999999999", &storage));
}

test "secret section: bare (non-derived) collision between two default envs" {
    var storage: [cli.max_workers][]const u8 = undefined;
    // `foo-bar` and `foo_bar` are distinct names, but both derive to
    // CONFD_FOO_BAR — the collision check must catch derived-vs-derived too.
    // (`foo_bar` is not a valid secret name — '_' is disallowed — so use an
    // override that lands on a derived name instead.)
    const text =
        \\workers = ["gateway"]
        \\
        \\[secret.foo-bar]
        \\workers = ["gateway"]
        \\
        \\[secret.other]
        \\workers = ["gateway"]
        \\env = "CONFD_FOO_BAR"
    ;
    try t.expectError(error.BadValue, parseTest(text, &storage));
}
