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
    ready_fd: ?u8 = null,
    health: [cli.max_health]cli.HealthSpec = undefined,
    health_n: u8 = 0,
    max_restarts: ?i32 = null,
    on_incident: ?[]const u8 = null,
    photon: ?[]const u8 = null,
    /// `gpu_interval` global key: null = absent (caller keeps the cli.Config
    /// default). GPU sampling is auto-detected by the daemon (no enable toggle).
    gpu_interval_ms: ?u64 = null,
    /// `[logs]` section: null = key absent (caller keeps the cli.Config default).
    logs_max_rate: ?u32 = null,
    /// `[logs]` Tier-2 digest knobs: null = key absent (caller keeps the
    /// cli.Config default of on / 30s / 100).
    logs_digest: ?bool = null,
    logs_digest_interval_ms: ?u64 = null,
    logs_digest_threshold: ?u32 = null,
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
    /// Workers with `[worker.NAME] stream = true` — per-worker log streaming
    /// opt-in. Like `oneshot`, the worker's NAME joins this list rather than
    /// carrying a value; default (absent) leaves the worker non-streaming.
    stream: [16][]const u8 = undefined,
    stream_n: u8 = 0,
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
    /// Per-worker `health_interval` / `health_start_period` ("name" -> "10s").
    health_interval_pairs: [16]cli.HealthSpec = undefined,
    health_interval_pairs_n: u8 = 0,
    health_start_pairs: [16]cli.HealthSpec = undefined,
    health_start_pairs_n: u8 = 0,
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
    /// `[secret.NAME]` sections. `name`/`env`/`fmt`/`n` are filled here and
    /// copied into cli.Config verbatim; `workers`/`workers_len` stay as the
    /// parsed (unresolved) ref count until `resolveSecretGrants` runs post-merge.
    secrets: [cli.max_secrets]cli.SecretDef = undefined,
    secrets_n: usize = 0,
    /// Per-secret worker-name refs (slices into `text`), collected during parse
    /// and resolved to indices by `resolveSecretGrants`, called by the caller
    /// after the final worker set (CLI or TOML) is known. Transient: never
    /// copied into cli.Config, so `secrets[*].workers` holds indices only.
    secret_refs: [cli.max_secrets][cli.max_secret_workers][]const u8 = undefined,
    /// `[require.NAME]` fail-closed boot gates.
    require: [cli.max_require]cli.ReqDef = undefined,
    require_n: u8 = 0,
    /// `[prober.NAME]` periodic report/incident monitors.
    probers: [cli.max_probers]cli.ProbeDef = undefined,
    probers_n: u8 = 0,
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

const ArrayTarget = enum { none, workers, health, health_interval, health_start, start_after, env, cwd, user, cap_drop, oom, nice, max_rss, lifetime, expected, pre_stop, name, secret_workers };

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
        .health_interval => .{ .arr = &cfg.health_interval_pairs, .n = &cfg.health_interval_pairs_n },
        .health_start => .{ .arr = &cfg.health_start_pairs, .n = &cfg.health_start_pairs_n },
        .pre_stop => .{ .arr = &cfg.prestop_pairs, .n = &cfg.prestop_pairs_n },
        .name => .{ .arr = &cfg.name_pairs, .n = &cfg.name_pairs_n },
        else => null,
    };
}

pub const ParseError = error{ Syntax, BadValue, TooManyWorkers, RestartRemoved, UnhealthyKeyRemoved, LogsStreamRemoved, GpuSectionRemoved, PerWorkerOnly };

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
    var cur_logs = false; // active [logs] section
    var cur_require: ?usize = null; // active [require.NAME] section (index)
    var cur_prober: ?usize = null; // active [prober.NAME] section (index)

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
                    cur_logs = false;
                    cur_require = null;
                    cur_prober = null;
                },
                .secret => |nm| {
                    cur_worker = null;
                    cur_logs = false;
                    cur_require = null;
                    cur_prober = null;
                    cur_secret = try beginSecret(cfg, nm);
                },
                .logs => {
                    cur_worker = null;
                    cur_secret = null;
                    cur_require = null;
                    cur_prober = null;
                    cur_logs = true;
                },
                .require => |nm| {
                    cur_worker = null;
                    cur_secret = null;
                    cur_logs = false;
                    cur_prober = null;
                    cur_require = try beginRequire(cfg, nm);
                },
                .prober => |nm| {
                    cur_worker = null;
                    cur_secret = null;
                    cur_logs = false;
                    cur_require = null;
                    cur_prober = try beginProber(cfg, nm);
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

        if (cur_require) |ri| {
            try requireSetting(cfg, ri, key, value);
            continue;
        }

        if (cur_prober) |pi| {
            try proberSetting(cfg, pi, key, value);
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
        } else if (std.mem.eql(u8, key, "metrics_port")) {
            cfg.metrics_port = std.fmt.parseInt(u16, value, 10) catch return error.BadValue;
        } else if (std.mem.eql(u8, key, "ready_fd")) {
            const fd = std.fmt.parseInt(u8, value, 10) catch return error.BadValue;
            if (fd < 3) return error.BadValue;
            cfg.ready_fd = fd;
        } else if (std.mem.eql(u8, key, "max_restarts")) {
            cfg.max_restarts = std.fmt.parseInt(i32, value, 10) catch return error.BadValue;
            if (cfg.max_restarts.? < -1) return error.BadValue;
        } else if (std.mem.eql(u8, key, "on_incident")) {
            cfg.on_incident = parseString(value) orelse return error.BadValue;
        } else if (std.mem.eql(u8, key, "photon")) {
            cfg.photon = parseString(value) orelse return error.BadValue;
        } else if (std.mem.eql(u8, key, "psi_mem_pct")) {
            cfg.psi_mem_pct = std.fmt.parseInt(u16, value, 10) catch return error.BadValue;
        } else if (std.mem.eql(u8, key, "psi_cpu_pct")) {
            cfg.psi_cpu_pct = std.fmt.parseInt(u16, value, 10) catch return error.BadValue;
        } else if (std.mem.eql(u8, key, "gpu_interval")) {
            // GPU sampling cadence (daemon-side; GPU itself is auto-detected).
            const s = parseString(value) orelse return error.BadValue;
            cfg.gpu_interval_ms = cli.parseDuration(s) orelse return error.BadValue;
        } else if (std.mem.eql(u8, key, "env_file")) {
            cfg.env_file = parseString(value) orelse return error.BadValue;
        } else if (std.mem.eql(u8, key, "restart_dependents")) {
            cfg.restart_dependents = if (std.mem.eql(u8, value, "true"))
                true
            else if (std.mem.eql(u8, value, "false"))
                false
            else
                return error.BadValue;
        } else if (std.mem.eql(u8, key, "expected_exit") or
            std.mem.eql(u8, key, "health_interval") or
            std.mem.eql(u8, key, "health_start_period"))
        {
            // v1.14: these describe a specific binary, not the fleet — they are
            // now per-worker only (set them inside a [worker.NAME] section).
            return error.PerWorkerOnly;
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
    try checkSecretEnvs(cfg);
    // `check` is mandatory for every [require.*] / [prober.*]; a [prober.*]
    // additionally requires `interval` (also catches a section with no keys
    // at all, since both fields default to zero-length/zero).
    for (cfg.require[0..cfg.require_n]) |r| {
        if (r.cmd.len == 0) return error.BadValue;
    }
    for (cfg.probers[0..cfg.probers_n]) |p| {
        if (p.cmd.len == 0) return error.BadValue;
        if (p.interval_ms == 0) return error.BadValue;
    }
}

/// Keys valid inside a `[worker.NAME]` section.
fn workerKey(key: []const u8) ?ArrayTarget {
    const map = .{
        .{ "health", ArrayTarget.health },                   .{ "start_after", ArrayTarget.start_after },
        .{ "env", ArrayTarget.env },                         .{ "cwd", ArrayTarget.cwd },
        .{ "user", ArrayTarget.user },                       .{ "cap_drop", ArrayTarget.cap_drop },
        .{ "oom_score_adj", ArrayTarget.oom },               .{ "nice", ArrayTarget.nice },
        .{ "max_rss_mb", ArrayTarget.max_rss },              .{ "max_lifetime", ArrayTarget.lifetime },
        .{ "expected_exit", ArrayTarget.expected },          .{ "pre_stop", ArrayTarget.pre_stop },
        .{ "health_interval", ArrayTarget.health_interval }, .{ "health_start_period", ArrayTarget.health_start },
        .{ "name", ArrayTarget.name },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, key, entry[0])) return entry[1];
    }
    return null;
}

const Section = union(enum) { worker: []const u8, secret: []const u8, logs, require: []const u8, prober: []const u8 };

/// `[worker.NAME]` / `[secret.NAME]` / `[logs]` / `[require.NAME]` /
/// `[prober.NAME]` -> the section kind (+ NAME where applicable). `[gpu]` was
/// flattened to the global `gpu_interval` key in v1.14 and now gives a
/// migration error. Any other header is a hard error: configs are small, so a
/// typo should stop startup rather than be ignored.
fn sectionHeader(line: []const u8) ParseError!Section {
    if (line[line.len - 1] != ']') return error.Syntax;
    const inner = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
    if (std.mem.eql(u8, inner, "gpu")) return error.GpuSectionRemoved;
    if (std.mem.eql(u8, inner, "logs")) return .logs;
    if (sectionName(inner, "worker.")) |nm| return .{ .worker = nm };
    if (sectionName(inner, "secret.")) |nm| return .{ .secret = nm };
    if (sectionName(inner, "require.")) |nm| return .{ .require = nm };
    if (sectionName(inner, "prober.")) |nm| return .{ .prober = nm };
    return error.Syntax;
}

/// Apply one `key = value` inside `[logs]`. `max_rate` is a bare non-negative
/// int (lines/sec, 0 = unlimited). Streaming is now per-worker
/// (`[worker.NAME] stream = true`), so `[logs]` carries only the global rate
/// cap. Unknown key -> hard Syntax error (a mistyped key should stop startup,
/// not be silently ignored).
fn logsSetting(cfg: *FileConfig, key: []const u8, value: []const u8) ParseError!void {
    if (std.mem.eql(u8, key, "max_rate")) {
        // Bare int, lines/sec. Range 0..u32-max; a negative or non-numeric value
        // (parseInt rejects the sign for an unsigned type) is a hard BadValue so a
        // typo cannot silently disable the cap.
        cfg.logs_max_rate = std.fmt.parseInt(u32, value, 10) catch return error.BadValue;
    } else if (std.mem.eql(u8, key, "digest")) {
        // Bare bool, parsed the same way `restart_dependents` is: anything but
        // true/false is a hard BadValue (a typo can't silently flip the Tier-2
        // digest).
        cfg.logs_digest = if (std.mem.eql(u8, value, "true"))
            true
        else if (std.mem.eql(u8, value, "false"))
            false
        else
            return error.BadValue;
    } else if (std.mem.eql(u8, key, "digest_interval")) {
        const s = parseString(value) orelse return error.BadValue;
        const ms = cli.parseDuration(s) orelse return error.BadValue;
        // 0 is not a valid flush cadence: it makes the supervisor's flush deadline
        // never advance into the future, busy-spinning PID 1 at 100% CPU. Reject it
        // so the operator gets a clear error instead of a wedged container.
        if (ms == 0) return error.BadValue;
        cfg.logs_digest_interval_ms = ms;
    } else if (std.mem.eql(u8, key, "digest_threshold")) {
        // Bare int (a signature count). Negative/non-numeric → BadValue.
        cfg.logs_digest_threshold = std.fmt.parseInt(u32, value, 10) catch return error.BadValue;
    } else if (std.mem.eql(u8, key, "stream")) {
        // Removed in v1.11 (log-signal-v2): streaming is now per worker. Give a
        // migration hint, not a bare Syntax error, so an upgrade doesn't hard-fail
        // to boot with no clue — mirrors the `restart` / `restart_on_unhealthy`
        // removed-key treatment.
        return error.LogsStreamRemoved;
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

/// Start a `[require.NAME]` section: seed a defaulted entry (60s timeout, no
/// `check` yet — enforced present at parse end) and return its index.
fn beginRequire(cfg: *FileConfig, name: []const u8) ParseError!usize {
    if (cfg.require_n == cfg.require.len) return error.BadValue; // too many requires
    const idx = cfg.require_n;
    cfg.require[idx] = .{ .name = name, .cmd = "" };
    cfg.require_n += 1;
    return idx;
}

/// Start a `[prober.NAME]` section: seed a defaulted entry (no `check`/
/// `interval` yet — both enforced present at parse end) and return its index.
fn beginProber(cfg: *FileConfig, name: []const u8) ParseError!usize {
    if (cfg.probers_n == cfg.probers.len) return error.BadValue; // too many probers
    const idx = cfg.probers_n;
    cfg.probers[idx] = .{ .name = name, .cmd = "", .interval_ms = 0 };
    cfg.probers_n += 1;
    return idx;
}

/// Apply one `key = value` inside `[require.NAME]`.
fn requireSetting(cfg: *FileConfig, ri: usize, key: []const u8, value: []const u8) ParseError!void {
    if (std.mem.eql(u8, key, "check")) {
        cfg.require[ri].cmd = parseString(value) orelse return error.BadValue;
    } else if (std.mem.eql(u8, key, "timeout")) {
        const s = parseString(value) orelse return error.BadValue;
        const ms = cli.parseDuration(s) orelse return error.BadValue;
        if (ms == 0) return error.BadValue; // a 0 timeout can never pass
        cfg.require[ri].timeout_ms = ms;
    } else {
        return error.Syntax; // unknown key inside a [require.*] section
    }
}

/// Apply one `key = value` inside `[prober.NAME]`.
fn proberSetting(cfg: *FileConfig, pi: usize, key: []const u8, value: []const u8) ParseError!void {
    if (std.mem.eql(u8, key, "check")) {
        cfg.probers[pi].cmd = parseString(value) orelse return error.BadValue;
    } else if (std.mem.eql(u8, key, "interval")) {
        const s = parseString(value) orelse return error.BadValue;
        const ms = cli.parseDuration(s) orelse return error.BadValue;
        // 0 would fire the check every poll tick, busy-spinning PID 1.
        if (ms == 0) return error.BadValue;
        cfg.probers[pi].interval_ms = ms;
    } else if (std.mem.eql(u8, key, "timeout")) {
        const s = parseString(value) orelse return error.BadValue;
        const ms = cli.parseDuration(s) orelse return error.BadValue;
        if (ms == 0) return error.BadValue; // a 0 timeout can never pass
        cfg.probers[pi].timeout_ms = ms;
    } else if (std.mem.eql(u8, key, "on_fail")) {
        const s = parseString(value) orelse return error.BadValue;
        if (std.mem.eql(u8, s, "report")) {
            cfg.probers[pi].on_fail = .report;
        } else if (std.mem.eql(u8, s, "incident")) {
            cfg.probers[pi].on_fail = .incident;
        } else {
            return error.BadValue;
        }
    } else if (std.mem.eql(u8, key, "fail_threshold")) {
        // A bare integer, like every other int key (metrics_port, psi_*, …) — no quotes.
        const n = std.fmt.parseInt(u8, value, 10) catch return error.BadValue;
        if (n < 1) return error.BadValue;
        cfg.probers[pi].fail_threshold = n;
    } else {
        return error.Syntax; // unknown key inside a [prober.*] section
    }
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

/// Parse-time secret check that needs NO worker set: two secrets must not resolve
/// to the same env var name (both would write CONFD_X — a clobber). Worker-name
/// resolution is deferred to `resolveSecretGrants` (run after the CLI/TOML worker
/// set is final), so an unknown or absent worker is NOT an error here.
fn checkSecretEnvs(cfg: *FileConfig) ParseError!void {
    var a: usize = 0;
    while (a < cfg.secrets_n) : (a += 1) {
        var b: usize = a + 1;
        while (b < cfg.secrets_n) : (b += 1) {
            if (std.mem.eql(u8, cfg.secrets[a].env, cfg.secrets[b].env)) return error.BadValue;
        }
    }
}

/// Resolve each secret's worker-name refs to indices in `commands` — the FINAL,
/// post-merge worker set (CLI `--` args, or TOML `workers=`). Keeps only the
/// workers PRESENT in the set: an absent listed worker is skipped; a grant with
/// no present workers (or an empty list) resolves to zero recipients (inert) —
/// never an error. Deny-by-default: only present, listed workers receive a
/// secret. `refs[si][k]` is the k-th worker name of secret si (parsed, unresolved);
/// `secrets[si].workers_len` on entry is the parsed ref count, on exit the present
/// count. Pure — no alloc beyond the fixed name buffers, no error, no panic.
pub fn resolveSecretGrants(
    secrets: []cli.SecretDef,
    refs: []const [cli.max_secret_workers][]const u8,
    commands: []const []const u8,
) void {
    if (secrets.len == 0) return;
    var name_bufs: [cli.max_workers][names.cap]u8 = undefined;
    var derived: [cli.max_workers][]const u8 = undefined;
    for (commands, 0..) |cmd, i| derived[i] = deriveOne(cmd, name_bufs[i][0..], derived[0..i]);
    const resolved = derived[0..commands.len];
    for (secrets, 0..) |*sec, si| {
        var present: usize = 0;
        var k: usize = 0;
        while (k < sec.workers_len) : (k += 1) {
            if (matchWorker(resolved, refs[si][k])) |idx| {
                sec.workers[present] = idx;
                present += 1;
            } // absent → skip (deny-by-default; inert if none remain)
        }
        sec.workers_len = present; // present count (0 = inert)
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
    if (std.mem.eql(u8, key, "stream")) {
        if (std.mem.eql(u8, value, "false")) return; // the default
        if (!std.mem.eql(u8, value, "true")) return error.BadValue;
        if (cfg.stream_n == cfg.stream.len) return error.BadValue;
        cfg.stream[cfg.stream_n] = w;
        cfg.stream_n += 1;
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

test "health, ready_fd and per-worker health timing keys" {
    var storage: [cli.max_workers][]const u8 = undefined;
    const text =
        \\ready_fd = 5
        \\
        \\[worker.api]
        \\health = "/bin/check --fast"
        \\health_interval = "10s"
        \\health_start_period = "45s"
    ;
    const cfg = try parseTest(text, &storage);
    try t.expectEqual(@as(?u8, 5), cfg.ready_fd);
    try t.expectEqual(@as(u8, 1), cfg.health_n);
    try t.expectEqualStrings("api", cfg.health[0].worker);
    try t.expectEqualStrings("/bin/check --fast", cfg.health[0].cmd);
    // Per-worker probe timing (v1.14) is collected as name->value pairs.
    try t.expectEqual(@as(u8, 1), cfg.health_interval_pairs_n);
    try t.expectEqualStrings("api", cfg.health_interval_pairs[0].worker);
    try t.expectEqualStrings("10s", cfg.health_interval_pairs[0].cmd);
    try t.expectEqual(@as(u8, 1), cfg.health_start_pairs_n);
    try t.expectEqualStrings("45s", cfg.health_start_pairs[0].cmd);
}

test "expected_exit / health_interval / health_start_period are per-worker only" {
    var storage: [cli.max_workers][]const u8 = undefined;
    // At the top level (global) each now gives a dedicated migration error.
    try t.expectError(error.PerWorkerOnly, parseTest("expected_exit = \"143\"", &storage));
    try t.expectError(error.PerWorkerOnly, parseTest("health_interval = \"10s\"", &storage));
    try t.expectError(error.PerWorkerOnly, parseTest("health_start_period = \"5s\"", &storage));
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

test "stop_grace key" {
    var storage: [cli.max_workers][]const u8 = undefined;
    const cfg = try parseTest("stop_grace = \"5s\"", &storage);
    try t.expectEqual(@as(u64, 5_000), cfg.stop_grace_ms.?);
}

test "per-worker expected_exit resolves to a pair" {
    var storage: [cli.max_workers][]const u8 = undefined;
    const cfg = try parseTest("[worker.job]\nexpected_exit = \"143\"", &storage);
    try t.expectEqual(@as(u8, 1), cfg.expected_pairs_n);
    try t.expectEqualStrings("job", cfg.expected_pairs[0].worker);
    try t.expectEqualStrings("143", cfg.expected_pairs[0].cmd);
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
    var cfg = try parseTest(text, &storage);
    resolveSecretGrants(cfg.secrets[0..cfg.secrets_n], cfg.secret_refs[0..cfg.secrets_n], cfg.commands);
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
    var cfg = try parseTest(text, &storage);
    resolveSecretGrants(cfg.secrets[0..cfg.secrets_n], cfg.secret_refs[0..cfg.secrets_n], cfg.commands);
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
    var cfg = try parseTest(text, &storage);
    resolveSecretGrants(cfg.secrets[0..cfg.secrets_n], cfg.secret_refs[0..cfg.secrets_n], cfg.commands);
    try t.expectEqual(@as(usize, 2), cfg.secrets_n);
    try t.expectEqualStrings("CONFD_INTEGRATION", cfg.secrets[0].env);
    try t.expectEqualStrings("CONFD_CRON_TOKEN", cfg.secrets[1].env);
    try t.expectEqual(@as(u8, 2), cfg.secrets[1].workers[0]); // "cron" is worker 2
}

test "secret section: every rejection is a hard error" {
    var storage: [cli.max_workers][]const u8 = undefined;
    const W = "workers = [\"gateway\"]\n";
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

test "gpu_interval: global key parses" {
    var storage: [cli.max_workers][]const u8 = undefined;
    const cfg = try parseTest("gpu_interval = \"10s\"", &storage);
    try t.expectEqual(@as(?u64, 10_000), cfg.gpu_interval_ms);
}

test "gpu_interval: absent stays null; bad value rejected" {
    var storage: [cli.max_workers][]const u8 = undefined;
    // Absent -> field stays null (caller keeps the cli.Config default of 15s).
    const none = try parseTest("workers = [\"./a\"]", &storage);
    try t.expectEqual(@as(?u64, null), none.gpu_interval_ms);
    const set = try parseTest("gpu_interval = \"5s\"", &storage);
    try t.expectEqual(@as(?u64, 5_000), set.gpu_interval_ms);
    try t.expectError(error.BadValue, parseTest("gpu_interval = \"soon\"", &storage));
}

test "the old [gpu] section gives a migration error" {
    var storage: [cli.max_workers][]const u8 = undefined;
    // `[gpu] interval` / `[gpu] enabled` were flattened to the global
    // `gpu_interval` key in v1.14 — the section itself must give a dedicated
    // migration error, not a bare Syntax error.
    try t.expectError(error.GpuSectionRemoved, parseTest("[gpu]\ninterval = \"20s\"", &storage));
    try t.expectError(error.GpuSectionRemoved, parseTest("[gpu]\nenabled = true", &storage));
}

test "worker section: stream collects the worker name; others stay non-streaming" {
    var storage: [cli.max_workers][]const u8 = undefined;
    const text =
        \\[worker.api]
        \\stream = true
        \\
        \\[worker.cron]
        \\stream = false
        \\
        \\[worker.worker]
        \\cwd = "/srv"
    ;
    const cfg = try parseTest(text, &storage);
    // Only the worker that opted in is listed; `stream = false` and a worker
    // without the key record nothing (default = non-streaming).
    try t.expectEqual(@as(u8, 1), cfg.stream_n);
    try t.expectEqualStrings("api", cfg.stream[0]);
    // A non-true/false value is a hard error (a typo can't silently enable it).
    try t.expectError(error.BadValue, parseTest("[worker.api]\nstream = yes", &storage));
}

test "logs section: stream key is no longer accepted (now per-worker)" {
    var storage: [cli.max_workers][]const u8 = undefined;
    // `[logs] stream` was removed in log-signal-v2: streaming is per-worker now.
    // It gets a dedicated migration error (not a bare Syntax) so an upgrade fails
    // with an actionable message instead of an opaque "syntax" — mirrors the
    // removed `restart` / `restart_on_unhealthy` keys.
    try t.expectError(error.LogsStreamRemoved, parseTest("[logs]\nstream = true", &storage));
}

test "logs section: max_rate parses, defaults absent, rejects bad values" {
    var storage: [cli.max_workers][]const u8 = undefined;
    // A positive cap parses as a bare int.
    const cap = try parseTest("[logs]\nmax_rate = 500", &storage);
    try t.expectEqual(@as(?u32, 500), cap.logs_max_rate);
    // 0 = unlimited is a legal explicit value.
    const unlimited = try parseTest("[logs]\nmax_rate = 0", &storage);
    try t.expectEqual(@as(?u32, 0), unlimited.logs_max_rate);
    // Absent -> null (caller keeps the cli.Config default of 0/unlimited).
    const none = try parseTest("workers = [\"./a\"]", &storage);
    try t.expectEqual(@as(?u32, null), none.logs_max_rate);
    // Non-numeric and negative are hard errors (parseInt rejects the sign for a
    // u32), so a typo cannot silently disable the cap.
    try t.expectError(error.BadValue, parseTest("[logs]\nmax_rate = fast", &storage));
    try t.expectError(error.BadValue, parseTest("[logs]\nmax_rate = -1", &storage));
    // A value past u32 overflows parseInt -> BadValue (guards the upper bound).
    try t.expectError(error.BadValue, parseTest("[logs]\nmax_rate = 9999999999", &storage));
}

test "logs section: digest knobs parse, default absent, reject bad values" {
    var storage: [cli.max_workers][]const u8 = undefined;
    // digest = false parses to an explicit false.
    const off = try parseTest("[logs]\ndigest = false", &storage);
    try t.expectEqual(@as(?bool, false), off.logs_digest);
    // digest_interval is a quoted duration; digest_threshold a bare int.
    const tuned = try parseTest("[logs]\ndigest_interval = \"10s\"\ndigest_threshold = 250", &storage);
    try t.expectEqual(@as(?u64, 10_000), tuned.logs_digest_interval_ms);
    try t.expectEqual(@as(?u32, 250), tuned.logs_digest_threshold);
    // Absent -> all null (caller keeps the cli.Config defaults of on / 30s / 100).
    const none = try parseTest("workers = [\"./a\"]", &storage);
    try t.expectEqual(@as(?bool, null), none.logs_digest);
    try t.expectEqual(@as(?u64, null), none.logs_digest_interval_ms);
    try t.expectEqual(@as(?u32, null), none.logs_digest_threshold);
    // Bad bool, bad duration, non-numeric and negative threshold are hard errors.
    try t.expectError(error.BadValue, parseTest("[logs]\ndigest = yes", &storage));
    try t.expectError(error.BadValue, parseTest("[logs]\ndigest_interval = \"soon\"", &storage));
    // A 0 interval would busy-spin PID 1 (flush deadline never advances) — rejected.
    try t.expectError(error.BadValue, parseTest("[logs]\ndigest_interval = \"0s\"", &storage));
    try t.expectError(error.BadValue, parseTest("[logs]\ndigest_threshold = lots", &storage));
    try t.expectError(error.BadValue, parseTest("[logs]\ndigest_threshold = -1", &storage));
    // An unknown [logs] key is still a hard Syntax error.
    try t.expectError(error.Syntax, parseTest("[logs]\nbogus = 1", &storage));
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

test "resolveSecretGrants: grant to the present subset, skip absent" {
    var storage: [cli.max_workers][]const u8 = undefined;
    // Parse succeeds even though `pmtiles.sh` is not in this TOML's workers.
    const text =
        \\workers = ["gateway.sh", "proxy.sh"]
        \\
        \\[secret.integration-lock]
        \\workers = ["gateway.sh", "pmtiles.sh"]
    ;
    var fc = try parseTest(text, &storage);
    // The active set spawns gateway.sh + proxy.sh (no pmtiles.sh).
    const cmds = [_][]const u8{ "gateway.sh", "proxy.sh" };
    resolveSecretGrants(fc.secrets[0..fc.secrets_n], fc.secret_refs[0..fc.secrets_n], &cmds);
    // Only the present worker (gateway.sh = index 0) is granted; pmtiles.sh skipped.
    try t.expectEqual(@as(usize, 1), fc.secrets[0].workers_len);
    try t.expectEqual(@as(u8, 0), fc.secrets[0].workers[0]);
}

test "resolveSecretGrants: all-absent (and empty) grants are inert, not errors" {
    var storage: [cli.max_workers][]const u8 = undefined;
    // `s_absent` names a worker that isn't present; `s_empty` is an explicit
    // `workers = []` — both must parse (no BadValue) and resolve to zero
    // recipients, exercising both halves of the test's name.
    const text =
        \\workers = ["gateway.sh"]
        \\
        \\[secret.s-absent]
        \\workers = ["nope.sh"]
        \\
        \\[secret.s-empty]
        \\workers = []
    ;
    var fc = try parseTest(text, &storage); // parse must NOT error on either grant
    try t.expectEqual(@as(usize, 2), fc.secrets_n);
    const cmds = [_][]const u8{"gateway.sh"};
    resolveSecretGrants(fc.secrets[0..fc.secrets_n], fc.secret_refs[0..fc.secrets_n], &cmds);
    try t.expectEqual(@as(usize, 0), fc.secrets[0].workers_len); // absent ref → inert
    try t.expectEqual(@as(usize, 0), fc.secrets[1].workers_len); // workers = [] → inert
}

test "require section parses check + timeout default" {
    var s: [cli.max_workers][]const u8 = undefined;
    const cfg = try parseTest("[require.gpu]\ncheck = \"/gpu.sh --min 525\"", &s);
    try t.expectEqual(@as(u8, 1), cfg.require_n);
    try t.expectEqualStrings("gpu", cfg.require[0].name);
    try t.expectEqualStrings("/gpu.sh --min 525", cfg.require[0].cmd);
    try t.expectEqual(@as(u64, 60_000), cfg.require[0].timeout_ms);
}
test "require: missing check and timeout=0 are errors" {
    var s: [cli.max_workers][]const u8 = undefined;
    try t.expectError(error.BadValue, parseTest("[require.gpu]\ntimeout = \"30s\"", &s));
    try t.expectError(error.BadValue, parseTest("[require.gpu]\ncheck=\"x\"\ntimeout=\"0s\"", &s));
    try t.expectError(error.Syntax, parseTest("[require.gpu]\ncheck=\"x\"\nbogus=\"1\"", &s));
}
test "prober section parses with defaults and overrides" {
    var s: [cli.max_workers][]const u8 = undefined;
    const cfg = try parseTest("[prober.pipe]\ncheck=\"/m.sh\"\ninterval=\"2m\"", &s);
    try t.expectEqual(@as(u8, 1), cfg.probers_n);
    try t.expectEqualStrings("pipe", cfg.probers[0].name);
    try t.expectEqual(@as(u64, 120_000), cfg.probers[0].interval_ms);
    try t.expectEqual(@as(u64, 10_000), cfg.probers[0].timeout_ms);
    try t.expectEqual(cli.ProbeDef.OnFail.report, cfg.probers[0].on_fail);
    try t.expectEqual(@as(u8, 1), cfg.probers[0].fail_threshold);
    const c2 = try parseTest("[prober.p]\ncheck=\"x\"\ninterval=\"5s\"\non_fail=\"incident\"\nfail_threshold=3", &s);
    try t.expectEqual(cli.ProbeDef.OnFail.incident, c2.probers[0].on_fail);
    try t.expectEqual(@as(u8, 3), c2.probers[0].fail_threshold);
}
test "prober: missing interval/check, bad on_fail, threshold=0 are errors" {
    var s: [cli.max_workers][]const u8 = undefined;
    try t.expectError(error.BadValue, parseTest("[prober.p]\ncheck=\"x\"", &s)); // no interval
    try t.expectError(error.BadValue, parseTest("[prober.p]\ninterval=\"5s\"", &s)); // no check
    try t.expectError(error.BadValue, parseTest("[prober.p]\ncheck=\"x\"\ninterval=\"5s\"\non_fail=\"nope\"", &s));
    try t.expectError(error.BadValue, parseTest("[prober.p]\ncheck=\"x\"\ninterval=\"5s\"\nfail_threshold=0", &s));
}

test "resolveSecretGrants resolves against CLI-only workers (no TOML workers=)" {
    var storage: [cli.max_workers][]const u8 = undefined;
    // No `workers =` key at all — the set comes from the CLI at runtime.
    const text =
        \\[secret.integration-lock]
        \\workers = ["gateway.sh", "proxy.sh"]
    ;
    var fc = try parseTest(text, &storage); // must parse (Gap 2 fixed)
    const cmds = [_][]const u8{ "gateway.sh", "proxy.sh", "pmtiles.sh" };
    resolveSecretGrants(fc.secrets[0..fc.secrets_n], fc.secret_refs[0..fc.secrets_n], &cmds);
    try t.expectEqual(@as(usize, 2), fc.secrets[0].workers_len);
    try t.expectEqual(@as(u8, 0), fc.secrets[0].workers[0]); // gateway.sh
    try t.expectEqual(@as(u8, 1), fc.secrets[0].workers[1]); // proxy.sh
}
