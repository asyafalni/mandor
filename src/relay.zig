//! OTLP to photon. Two entry points: `mandor relay --daemon`, the one
//! long-lived child the supervisor spawns when `photon` is set (owns the
//! socket, ships the spool, drains the telemetry pipe), and the one-shot
//! `mandor relay <bundle.json> [endpoint]` (else PHOTON_OTLP_HTTP_ENDPOINT,
//! the same variable the supervisor reads; default 127.0.0.1:4318). The supervisor itself never opens an outbound connection.
//! Mapping: docs/INTEGRATION-PHOTON.md.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const spawner = @import("spawner.zig");
const resolve = @import("resolve.zig");
const frame = @import("frame.zig");
const spool = @import("spool.zig");
const hostid = @import("hostid.zig");
const sampler = @import("sampler.zig");
const summarize = @import("summarize.zig");
const otlp = @import("otlp.zig");
const env = @import("env.zig");
const proto = @import("nilo_proto");

/// Wall-clock ceiling on each blocking socket call. Generous enough that a
/// merely slow collector still succeeds, short enough that a hung one cannot
/// strand a process for the life of the container.
const relay_timeout_s = 10;

// The largest OTLP message mandor ever builds is an incident bundle embedded
// raw as the `mandor.bundle` attribute. A bundle is capped at 128 KB (spool's
// bundle_buf) and protobuf embeds strings UNESCAPED, so that message is the
// bundle plus ~1 KB of framing. Every other encoder is far smaller: per-worker
// process metrics are tens of KB, and the streamed-log batch is bounded by
// the 64 KB log_arena. So the body buffer only needs the bundle cap plus a
// generous OTLP-framing margin; a message that would exceed it returns
// error.TooLarge and is dropped (the incident stays durable on the spool).
// These were 320/321/256 KB — over-provisioned for a 128 KB-max message.
const max_bundle = 128 * 1024;
var file_buf: [max_bundle]u8 = undefined; // reads one on-disk bundle (<= 128 KB by construction)
var body_buf: [max_bundle + 32 * 1024]u8 = undefined; // 160 KB: bundle + framing margin
var req_buf: [body_buf.len + 4 * 1024]u8 = undefined; // body + HTTP request line/headers

pub fn run(path: [*:0]const u8, endpoint_arg: ?[]const u8, environ: [:null]const ?[*:0]const u8) u8 {
    const bundle = readFile(path) catch |e| {
        err(switch (e) {
            error.Unreadable => "cannot read bundle",
            error.TooLarge => "bundle exceeds 128KB — refusing to ship a truncated incident",
        });
        return 1;
    };

    var host: u32 = 0x7f000001; // 127.0.0.1
    var port: u16 = 4318;
    // Same source and rules as the supervisor's photon: a URL or host:port,
    // scheme stripped, an empty variable ignored.
    const spec = if (endpoint_arg) |a| env.stripScheme(a) else env.resolvePhoton(
        spawner.findEnv(environ, "PHOTON_OTLP_HTTP_ENDPOINT"),
        null,
    );
    if (spec) |s| {
        if (parseHostPort(s)) |hp| {
            host = hp.host;
            port = hp.port;
        } else {
            err("bad photon endpoint (want ip:port)");
            return 2;
        }
    }

    const body = buildOtlp(bundle) catch |e| {
        err(switch (e) {
            error.TooLarge => "bundle too large for one OTLP record",
            error.Malformed => "bundle has a malformed JSON string escape — refusing to ship",
        });
        return 1;
    };
    // photon requires a bearer token; inherited env keeps it off /proc cmdline.
    const token = photonToken(environ);
    return if (post(host, port, "/v1/logs", body, token) == .ok) 0 else 1;
}

fn err(msg: []const u8) void {
    _ = linux.write(2, msg.ptr, msg.len);
    _ = linux.write(2, "\n", 1);
}

const ReadError = error{ Unreadable, TooLarge };

/// Read the bundle whole. `read()` is looped because a single call may return
/// short, and a buffer filled to the brim is reported as TooLarge rather than
/// shipped: a silently truncated bundle is worse than a refused one, because
/// photon stores it and nobody learns the incident was clipped.
fn readFile(path: [*:0]const u8) ReadError![]const u8 {
    const rc = linux.openat(linux.AT.FDCWD, path, .{}, 0);
    if (posix.errno(rc) != .SUCCESS) return error.Unreadable;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var n: usize = 0;
    while (n < file_buf.len) {
        const got = linux.read(fd, file_buf[n..].ptr, file_buf.len - n);
        if (posix.errno(got) != .SUCCESS) return error.Unreadable;
        if (got == 0) break;
        n += got;
    }
    if (n == 0) return error.Unreadable;
    if (n == file_buf.len) return error.TooLarge;
    return file_buf[0..n];
}

/// `ip:port` or `hostname:port`. Names go through `/etc/hosts` then DNS —
/// compose and Kubernetes address services by name, so an IP-only endpoint
/// made the documented deployment impossible to write.
pub fn parseHostPort(spec: []const u8) ?resolve.HostPort {
    return resolve.resolve(spec);
}

fn scanStr(chunk: []const u8, comptime key: []const u8) ?[]const u8 {
    const pat = "\"" ++ key ++ "\":\"";
    const i = std.mem.indexOf(u8, chunk, pat) orelse return null;
    const start = i + pat.len;
    var j = start;
    while (j < chunk.len) : (j += 1) {
        if (chunk[j] == '\\') {
            j += 1;
            continue;
        }
        if (chunk[j] == '"') return chunk[start..j];
    }
    return null;
}

/// Scratch for decoded field text. Unescaping only ever shrinks, so this is
/// sized for the three scanned fields at their source lengths.
var unesc_buf: [4 * 1024]u8 = undefined;
var unesc_pos: usize = 0;

// ------------------------------------------------------- service-name prefix
//
// Multi-tenancy: photon is shared, and two mandor origins may run a worker with
// the same name (e.g. `api`), colliding on `service.name`. An operator sets
// `service_prefix` (config) to tag every OTLP emission with an origin prefix so
// the origins stay distinct (docs/…/2026-08-06-log-signal-v2-design.md). Default
// "" is byte-identical to a build without this feature. The prefix is applied in
// ONE place — the putServiceName/serviceKvLen helpers below — and touches ONLY
// `service.name`: the bare worker name is unchanged everywhere else (log `[name]`
// echo, report, Prometheus label, the incident bundle's own JSON).

/// Max prefix length. Matches cli.max_service_prefix (config rejects anything
/// longer), so the daemon's copy below never truncates.
pub const service_prefix_cap = 64;

/// The active prefix, copied into BSS at daemon start (setServicePrefix) so the
/// slice is stable for the daemon's whole life regardless of argv storage.
var service_prefix_buf: [service_prefix_cap]u8 = undefined;
var service_prefix: []const u8 = "";

/// Install the origin prefix (runDaemon calls this once before the loop). Copies
/// into BSS and clamps to the cap; an over-long value is a config error caught
/// earlier, but clamp here too so this can never overflow or trap.
pub fn setServicePrefix(p: []const u8) void {
    const n = @min(p.len, service_prefix_buf.len);
    @memcpy(service_prefix_buf[0..n], p[0..n]);
    service_prefix = service_prefix_buf[0..n];
}

/// Decode JSON string source into the bytes it denotes.
///
/// `scanStr` hands back *source* text — the spool writer escaped it. A JSON
/// payload could carry that verbatim because the consumer unescapes it, but a
/// protobuf string field holds raw bytes: shipping the source would put
/// literal backslashes in front of the operator, which is the 1.5.2
/// double-escape bug arriving from the other direction. Returns null if the
/// text is malformed or does not fit.
fn unescape(s: []const u8) ?[]const u8 {
    const start = unesc_pos;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (unesc_pos >= unesc_buf.len) return null;
        const c = s[i];
        if (c < 0x20) return null; // raw control byte: source was corrupt
        if (c != '\\') {
            unesc_buf[unesc_pos] = c;
            unesc_pos += 1;
            continue;
        }
        i += 1;
        if (i >= s.len) return null; // trailing backslash
        const e = s[i];
        const lit: u8 = switch (e) {
            '"' => '"',
            '\\' => '\\',
            '/' => '/',
            'b' => 0x08,
            'f' => 0x0c,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'u' => {
                if (i + 4 >= s.len) return null;
                var cp: u21 = 0;
                for (s[i + 1 ..][0..4]) |h| {
                    const d: u8 = switch (h) {
                        '0'...'9' => h - '0',
                        'a'...'f' => h - 'a' + 10,
                        'A'...'F' => h - 'A' + 10,
                        else => return null,
                    };
                    cp = cp * 16 + d;
                }
                i += 4;
                // Lone surrogates are not encodable; the spool writer only
                // emits \u for control chars, so treat anything else as
                // corruption rather than guess.
                if (cp >= 0xd800 and cp <= 0xdfff) return null;
                var utf8: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &utf8) catch return null;
                if (unesc_pos + n > unesc_buf.len) return null;
                @memcpy(unesc_buf[unesc_pos..][0..n], utf8[0..n]);
                unesc_pos += n;
                continue;
            },
            else => return null, // not a legal JSON escape
        };
        unesc_buf[unesc_pos] = lit;
        unesc_pos += 1;
    }
    return unesc_buf[start..unesc_pos];
}

// ------------------------------------------------------- OTLP encoding
//
// OTLP/HTTP requires servers to accept protobuf; JSON support is optional in
// practice and many collectors (photon included) never implemented it. The
// messages are plain structs in otlp.zig, and nilo_proto encodes them straight
// into body_buf: sized once, written once, no allocator, and a message that
// does not fit is refused before a byte is written.
//
// Every value below is built on the stack and encoded before the next one is
// built, so the slices it borrows (svc_buf, the event scratch) never outlive
// the record they belong to.

/// Scratch for `service_prefix ++ name`, joined and consumed within one
/// record's encode (single-threaded daemon, no cross-call state). Sized to the
/// prefix cap plus the largest name any encoder passes: the incident path's
/// name_txt is bounded by unesc_buf and every frame-sourced name is far
/// smaller, so the join never truncates in practice — meaning an empty prefix
/// yields the bare name verbatim (byte-identical to a build without it).
var svc_buf: [service_prefix_cap + unesc_buf.len]u8 = undefined;

/// The `service.name` resource attribute, origin-prefixed. The ONE place the
/// prefix is applied; it touches only service.name.
fn serviceName(name: []const u8) otlp.KeyValue {
    const n = @min(service_prefix.len +| name.len, svc_buf.len);
    const plen = @min(service_prefix.len, n);
    @memcpy(svc_buf[0..plen], service_prefix[0..plen]);
    @memcpy(svc_buf[plen..n], name[0 .. n - plen]);
    return .str("service.name", svc_buf[0..n]);
}

/// A non-negative count as OTLP's int64. A bit cast, not a range check: the
/// varint of a u64 and of the i64 with the same bits are the same bytes.
fn int64(v: u64) i64 {
    return @bitCast(v);
}

const BuildError = error{ TooLarge, Malformed };

/// Map the bundle onto one OTLP LogRecord (docs/INTEGRATION-PHOTON.md).
pub fn buildOtlp(bundle: []const u8) BuildError![]const u8 {
    const name = scanStr(bundle, "name") orelse "unknown";
    const kind = scanStr(bundle, "kind") orelse "unknown";
    const verdict = scanStr(bundle, "verdict") orelse "";
    const release = scanStr(bundle, "release") orelse "";
    const warn = std.mem.eql(u8, kind, "leak-suspect") or std.mem.eql(u8, kind, "restart-loop");

    // Decode the scanned fields: they are JSON source, and a protobuf string
    // holds raw bytes. This both unescapes and validates — a bundle truncated
    // mid-write or hand-edited fails here rather than filing a damaged
    // incident. The bundle attribute itself is raw JSON text and ships as-is.
    unesc_pos = 0;
    const name_txt = unescape(name) orelse return error.Malformed;
    const release_txt = unescape(release) orelse return error.Malformed;
    const verdict_txt = unescape(verdict) orelse return error.Malformed;

    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    const ns: u64 = @as(u64, @intCast(ts.sec)) *| 1_000_000_000 +| @as(u64, @intCast(ts.nsec));

    const resource = [_]otlp.KeyValue{
        serviceName(name_txt),
        .str("service.version", release_txt),
    };
    const attrs = [_]otlp.KeyValue{.str("mandor.bundle", bundle)};
    const record = [_]otlp.LogRecord{.{
        .time_unix_nano = ns,
        .observed_time_unix_nano = ns,
        .severity_number = if (warn) .warn else .err,
        .severity_text = if (warn) "WARN" else "ERROR",
        .body = .str(verdict_txt),
        .attributes = &attrs,
    }};
    const scope = [_]otlp.ScopeLogs{.{ .log_records = &record }};
    return otlp.appendLogs(&body_buf, .{
        .resource = .{ .attributes = &resource },
        .scope_logs = &scope,
    }) catch error.TooLarge;
}

// ------------------------------------------------------- OTLP metrics
//
// One ResourceMetrics PER worker so service.name in the resource matches the
// incident logs' service grouping. rss/cpu/fds/threads ship as Gauge, restarts
// as a monotonic cumulative Sum.

/// The four gauge metrics, in emit order (memory first — see the test that walks
/// the first metric). OTel process semantic-convention names/units so any OTLP
/// backend (photon, collectors) reads them without a translation table.
/// cpu.utilization is a 0..1 fraction (as_double); the rest are byte/count ints.
const gauge_metrics = [_]struct { name: []const u8, unit: []const u8 }{
    .{ .name = "process.memory.usage", .unit = "By" },
    .{ .name = "process.cpu.utilization", .unit = "1" },
    .{ .name = "process.unix.file_descriptor.count", .unit = "{count}" },
    .{ .name = "process.thread.count", .unit = "{thread}" },
};
// No OTel semconv equivalent for a supervisor restart counter — kept as a
// mandor-specific extension (a monotonic cumulative Sum).
const restart_metric_name = "process.restarts";
const restart_metric_unit = "{restart}";

/// Encode a batch of per-worker samples as one OTLP ExportMetricsServiceRequest,
/// one ResourceMetrics per sample. Metrics are not the lossy tier's batch: a
/// batch that does not fit body_buf whole is refused, never clipped.
pub fn buildOtlpMetrics(samples: []const frame.MetricSample, host_name: []const u8) error{TooLarge}![]const u8 {
    var pos: usize = 0;
    for (samples) |s| {
        // Values in the semconv order of gauge_metrics: memory.usage is bytes
        // (rss is kB → ×1024, saturating), cpu.utilization is a 0..1 fraction,
        // the counts pass through.
        const values = [gauge_metrics.len]otlp.NumberDataPoint.Value{
            .{ .as_int = int64(s.rss_kb *| 1024) },
            .{ .as_double = @as(f64, @floatFromInt(s.cpu_pct)) / 100.0 },
            .{ .as_int = s.fds },
            .{ .as_int = s.threads },
        };
        var points: [gauge_metrics.len + 1][1]otlp.NumberDataPoint = undefined;
        var metrics: [gauge_metrics.len + 1]otlp.Metric = undefined;
        for (gauge_metrics, values, 0..) |g, v, i| {
            points[i] = .{.{ .time_unix_nano = s.t_unix_ns, .value = v }};
            metrics[i] = .{ .name = g.name, .unit = g.unit, .data = .{ .gauge = .{ .data_points = &points[i] } } };
        }
        const last = gauge_metrics.len;
        points[last] = .{.{ .time_unix_nano = s.t_unix_ns, .value = .{ .as_int = s.restarts } }};
        metrics[last] = .{ .name = restart_metric_name, .unit = restart_metric_unit, .data = .{ .sum = .{
            .data_points = &points[last],
            .aggregation_temporality = .cumulative,
            .is_monotonic = true,
        } } };

        const resource = [_]otlp.KeyValue{
            serviceName(s.name),
            .str("host.name", host_name), // so the process is attributable to its node
        };
        const scope = [_]otlp.ScopeMetrics{.{ .metrics = &metrics }};
        const out = otlp.appendMetrics(body_buf[pos..], .{
            .resource = .{ .attributes = &resource },
            .scope_metrics = &scope,
        }) catch return error.TooLarge;
        pos += out.len;
    }
    return body_buf[0..pos];
}

// ------------------------------------------------------- OTLP lifecycle event
//
// One LogRecord, same nesting as buildOtlp's logs path: the body is a rendered
// human line, severity follows the event kind, service.name = worker, and a
// small set of string attributes carries the numeric context (exit.code,
// backoff.ms, restart.count) for the events where it is meaningful.

/// Render the human-readable body line for a lifecycle event into `buf`.
/// A negative `code` on `exited_err` is a fatal signal (rendered "signal:N");
/// a non-negative one is an exit status (rendered "code:N").
fn renderEventBody(buf: []u8, e: frame.Lifecycle) error{TooLarge}![]const u8 {
    return (switch (e.ev) {
        .started => std.fmt.bufPrint(buf, "worker {s} started", .{e.name}),
        .exited_ok => std.fmt.bufPrint(buf, "worker {s} exited ok", .{e.name}),
        .exited_err => if (e.code < 0)
            std.fmt.bufPrint(buf, "worker {s} exited signal:{d}", .{ e.name, -@as(i64, e.code) })
        else
            std.fmt.bufPrint(buf, "worker {s} exited code:{d}", .{ e.name, e.code }),
        .restarting => std.fmt.bufPrint(buf, "worker {s} restarting (backoff {d}ms)", .{ e.name, e.backoff_ms }),
        .oom => std.fmt.bufPrint(buf, "worker {s} OOM-killed", .{e.name}),
        .health_up => std.fmt.bufPrint(buf, "worker {s} healthy", .{e.name}),
        .health_down => std.fmt.bufPrint(buf, "worker {s} unhealthy", .{e.name}),
    }) catch return error.TooLarge;
}

const Sev = struct { num: otlp.Severity, text: []const u8 };

/// Event kind → OTLP severity number + text.
fn eventSev(ev: frame.Event) Sev {
    return switch (ev) {
        .started, .exited_ok, .health_up => .{ .num = .info, .text = "INFO" },
        .restarting, .health_down => .{ .num = .warn, .text = "WARN" },
        .exited_err, .oom => .{ .num = .err, .text = "ERROR" },
    };
}

/// Numeric context for an event as string attributes (photon reads string
/// attrs), rendered into caller scratch.
fn eventAttrs(e: frame.Lifecycle, attrs: *[2]otlp.KeyValue, num_a: *[12]u8, num_b: *[12]u8) error{TooLarge}![]const otlp.KeyValue {
    var n: usize = 0;
    switch (e.ev) {
        .exited_err, .oom => {
            attrs[n] = .str("exit.code", std.fmt.bufPrint(num_a, "{d}", .{e.code}) catch return error.TooLarge);
            n += 1;
        },
        .restarting => {
            attrs[n] = .str("backoff.ms", std.fmt.bufPrint(num_a, "{d}", .{e.backoff_ms}) catch return error.TooLarge);
            n += 1;
            attrs[n] = .str("restart.count", std.fmt.bufPrint(num_b, "{d}", .{e.restarts}) catch return error.TooLarge);
            n += 1;
        },
        else => {},
    }
    return attrs[0..n];
}

/// Encode one lifecycle event's resource_logs entry at the front of `buf`.
fn appendEvent(buf: []u8, e: frame.Lifecycle) error{ TooLarge, NoSpaceLeft }![]u8 {
    const sev = eventSev(e.ev);
    var body_scratch: [256]u8 = undefined;
    const body_txt = try renderEventBody(&body_scratch, e);
    var attrs: [2]otlp.KeyValue = undefined;
    var num_a: [12]u8 = undefined;
    var num_b: [12]u8 = undefined;
    const kvs = try eventAttrs(e, &attrs, &num_a, &num_b);

    const resource = [_]otlp.KeyValue{serviceName(e.name)};
    const record = [_]otlp.LogRecord{.{
        .time_unix_nano = e.t_unix_ns,
        .observed_time_unix_nano = e.t_unix_ns,
        .severity_number = sev.num,
        .severity_text = sev.text,
        .body = .str(body_txt),
        .attributes = kvs,
    }};
    const scope = [_]otlp.ScopeLogs{.{ .log_records = &record }};
    return otlp.appendLogs(buf, .{ .resource = .{ .attributes = &resource }, .scope_logs = &scope });
}

/// Encode one lifecycle event as an OTLP ExportLogsServiceRequest (one
/// resource_logs). Thin wrapper over the batch encoder so both share one code
/// path — a 1-event batch is byte-identical to the single output.
pub fn buildOtlpEvent(e: frame.Lifecycle) error{TooLarge}![]const u8 {
    return buildOtlpEvents(&.{e});
}

/// Encode a batch of lifecycle events as ONE OTLP ExportLogsServiceRequest, one
/// resource_logs per event. Ephemeral tier: encode events until one does not
/// fit body_buf (or cannot be rendered) and drop the rest; only a first event
/// that cannot go yields error.TooLarge (caller then drops the batch).
pub fn buildOtlpEvents(events: []const frame.Lifecycle) error{TooLarge}![]const u8 {
    var pos: usize = 0;
    var nfit: usize = 0;
    for (events) |e| {
        const out = appendEvent(body_buf[pos..], e) catch break;
        pos += out.len;
        nfit += 1;
    }
    if (nfit == 0) return error.TooLarge;
    return body_buf[0..pos];
}

// ------------------------------------------------------- OTLP streamed logs
//
// Opt-in full worker-log streaming (P3). Each batched log line becomes ONE
// LogRecord, same nesting as buildOtlp/buildOtlpEvent: resource
// {service.name=<worker>, host.name, host.id, os.type} (the SAME identity as the
// worker's process.* metrics — and as photon-agent's host metrics, so photon
// lines a worker's logs up with its metrics and its node), scope_logs{log_records[one]} with body =
// the line text, severity from the frame's tier, and attribute log.iostream.
// One resource_logs entry per record: correct, and cheap enough at the bounded
// batch sizes here (see the arena/cap in drainPipe).

/// One batched log line, resolved to slices that outlive the encode
/// (drainPipe copies name+line into log_arena; the fuzz/unit tests pass literals).
pub const LogRecord = struct {
    name: []const u8, // worker name → service.name
    line: []const u8, // captured line bytes → body
    iostream: u8, // 0 = stdout, 1 = stderr
    severity: u8, // 0 = info, 1 = warn, 2 = error (frame tier)
    t_ns: u64,
    // Curated Tier-2 digest fields. Default 0: a plain streamed line leaves them
    // 0, and `count == 0` means "not a digest" — no extra attributes are emitted,
    // so the streamed-log output stays byte-identical to before this feature.
    count: u64 = 0, // deduplicated occurrences (> 0 ⇒ this is a digest record)
    first_ns: u64 = 0, // first occurrence in the window
    last_ns: u64 = 0, // last occurrence in the window
};

/// Frame severity tier (0/1/2) → OTLP severity_number + text. Anything outside
/// 0..2 (a corrupt frame byte) maps to INFO rather than trapping.
fn logSeverity(sev: u8) Sev {
    return switch (sev) {
        1 => .{ .num = .warn, .text = "WARN" },
        2 => .{ .num = .err, .text = "ERROR" },
        else => .{ .num = .info, .text = "INFO" },
    };
}

fn ioStreamName(io: u8) []const u8 {
    return if (io == 1) "stderr" else "stdout";
}

/// Encode one streamed line's resource_logs entry at the front of `buf`.
fn appendLog(buf: []u8, r: LogRecord, host_name: []const u8, host_id: []const u8) error{NoSpaceLeft}![]u8 {
    const sev = logSeverity(r.severity);
    // log.iostream always; a digest record (count > 0) adds three int
    // attributes. A plain streamed line adds none, so its output is unchanged.
    const attrs = [_]otlp.KeyValue{
        .str("log.iostream", ioStreamName(r.iostream)),
        .int("mandor.count", int64(r.count)),
        .int("mandor.first_ts", int64(r.first_ns)),
        .int("mandor.last_ts", int64(r.last_ns)),
    };
    const resource = [_]otlp.KeyValue{
        serviceName(r.name),
        .str("host.name", host_name), // SAME identity as the worker's metrics
        .str("host.id", host_id),
        .str("os.type", "linux"),
    };
    const record = [_]otlp.LogRecord{.{
        .time_unix_nano = r.t_ns,
        .observed_time_unix_nano = r.t_ns,
        .severity_number = sev.num,
        .severity_text = sev.text,
        .body = .str(r.line),
        .attributes = if (r.count > 0) &attrs else attrs[0..1],
    }};
    const scope = [_]otlp.ScopeLogs{.{ .log_records = &record }};
    return otlp.appendLogs(buf, .{ .resource = .{ .attributes = &resource }, .scope_logs = &scope });
}

/// Encode a batch of streamed log lines as one OTLP ExportLogsServiceRequest,
/// one resource_logs per record. This is the lossy ephemeral tier: if the
/// whole batch will not fit body_buf, encode as many records as fit and DROP
/// the rest (counting them in `log_drops`) rather than refusing the batch. Only
/// a first record too large to fit alone yields error.TooLarge (the caller then
/// drops the batch). The frame decoder caps a line at 4095 bytes and
/// drainPipe's arena caps the batch, so in practice the whole batch always fits.
pub fn buildOtlpLogs(records: []const LogRecord, host_name: []const u8, host_id: []const u8) error{TooLarge}![]const u8 {
    var pos: usize = 0;
    var nfit: usize = 0;
    for (records) |r| {
        const out = appendLog(body_buf[pos..], r, host_name, host_id) catch break;
        pos += out.len;
        nfit += 1;
    }
    if (nfit == 0) return error.TooLarge; // not even one record fits
    if (nfit < records.len) log_drops +|= records.len - nfit; // ephemeral: drop the tail
    return body_buf[0..pos];
}

/// True only for a genuine HTTP status line reporting 2xx.
///
/// The `HTTP/` prefix check is the point: without it, any reply at least 12
/// bytes long whose bytes 9..11 happen to read `200` — a plain-text error
/// page, another protocol's banner — would be taken as a successful delivery
/// and the incident silently dropped. Any 2xx counts, not just `200`: OTLP
/// receivers may answer `202 Accepted`, and treating that as a rejection
/// would report a delivery that actually worked as a failure.
fn statusOk(resp: []const u8) bool {
    if (resp.len < 12) return false;
    if (!std.mem.startsWith(u8, resp, "HTTP/")) return false;
    return resp[9] == '2';
}

/// A non-2xx that rejects THIS payload, not the endpoint: OTLP/HTTP says a
/// client MUST NOT retry `400 Bad Request`, and 413 / 422 are the same verdict
/// on the body. Everything else — 401/403 (token), 404/415 (wrong endpoint or
/// encoding), 429, 5xx — is photon or its config, which the operator fixes, so
/// the durable tier keeps retrying those.
fn rejectedForGood(resp: []const u8) bool {
    if (resp.len < 12 or !std.mem.startsWith(u8, resp, "HTTP/")) return false;
    const code = resp[9..12];
    return std.mem.eql(u8, code, "400") or std.mem.eql(u8, code, "413") or
        std.mem.eql(u8, code, "422");
}

/// Does a 2xx response come from a web UI rather than an OTLP receiver? photon's
/// UI answers `200 OK` with an SPA (`Content-Type: text/html`) for any unknown
/// path, so a mandor pointed at the UI port (not the OTLP ingest port, e.g. :4318)
/// gets a 200 for `/v1/logs` and the payload is swallowed by the SPA catch-all —
/// never ingested. We key ONLY on a `text/html` content type, not loose body
/// substrings: a real OTLP receiver answers `application/x-protobuf`
/// (ExportLogsServiceResponse), so `text/html` is an unambiguous wrong-endpoint
/// signal, while `<html`/`<!doctype` bytes could in principle appear inside a
/// legitimate protobuf body and wrongly condemn a working endpoint to retry-forever.
fn looksLikeHtml(resp: []const u8) bool {
    return summarize.containsIgnoreCase(resp, "text/html");
}

/// One-time guard so a wrong-endpoint warning is logged once, not per POST
/// (incidents fire per restart — a crash loop must not spam stderr).
var warned_html_endpoint: bool = false;

const Delivery = enum {
    ok,
    /// Not delivered for a reason outside this payload: retry it.
    retry,
    /// photon refused this payload itself (`rejectedForGood`): never retry it.
    rejected,
};

fn post(host: u32, port: u16, path: []const u8, body: []const u8, token: []const u8) Delivery {
    const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (posix.errno(rc) != .SUCCESS) {
        err("socket failed");
        return .retry;
    }
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    // Bound every blocking call. relay is spawned fire-and-forget and is never
    // waited on, so a peer that accepts the connection and then never answers
    // wedges this process forever — and incidents fire *per restart*, so a
    // crash loop against a stalled photon would strand one stuck relay per
    // crash. Timeouts turn that into a reported failure instead.
    const tv = linux.timeval{ .sec = relay_timeout_s, .usec = 0 };
    const tvp: [*]const u8 = @ptrCast(&tv);
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, tvp, @sizeOf(linux.timeval));
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.SNDTIMEO, tvp, @sizeOf(linux.timeval));
    var addr: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, host),
    };
    if (posix.errno(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
        err("connect failed — is photon listening?");
        return .retry;
    }
    var auth_buf: [300]u8 = undefined;
    const auth: []const u8 = if (token.len > 0)
        std.fmt.bufPrint(&auth_buf, "Authorization: Bearer {s}\r\n", .{token}) catch ""
    else
        "";
    const req = std.fmt.bufPrint(&req_buf, "POST {s} HTTP/1.1\r\nHost: photon\r\n" ++
        "Content-Type: application/x-protobuf\r\n{s}Content-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{
        path, auth, body.len, body,
    }) catch {
        err("request too large to send");
        return .retry;
    };
    var off: usize = 0;
    while (off < req.len) {
        const n = linux.write(fd, req.ptr + off, req.len - off);
        switch (posix.errno(n)) {
            .SUCCESS => {},
            // A signal landing mid-send is not a delivery failure; retry.
            .INTR => continue,
            .AGAIN => {
                err("send timed out — photon accepted the connection but stopped reading");
                return .retry;
            },
            else => {
                err("send failed");
                return .retry;
            },
        }
        off += n;
    }
    // 512, not 128: enough to see the response's Content-Type header (and the
    // SPA body start) so a 200-with-HTML wrong-endpoint reply is detectable.
    var resp: [512]u8 = undefined;
    const got = linux.read(fd, &resp, resp.len);
    if (posix.errno(got) == .AGAIN) {
        err("photon accepted the connection but never answered (timed out) — see docs/INTEGRATION-PHOTON.md");
        return .retry;
    }
    if (posix.errno(got) == .SUCCESS and got > 0) {
        const rslice = resp[0..@min(@as(usize, @intCast(got)), resp.len)];
        if (statusOk(rslice)) {
            // A 2xx from photon's OTLP receiver is a real delivery — UNLESS it is
            // an HTML page, which means the address is photon's web UI, not its
            // OTLP ingest port: the SPA catch-all 200s and the payload is
            // dropped. Treat that as NOT delivered (so the durable incident tier
            // keeps retrying and nothing is falsely marked shipped) and warn once.
            if (!looksLikeHtml(rslice)) return .ok;
            if (!warned_html_endpoint) {
                warned_html_endpoint = true;
                err("photon answered 200 with an HTML page, not OTLP — the address is likely photon's web UI, not its OTLP ingest port (e.g. :4318). Nothing is being ingested. See docs/INTEGRATION-PHOTON.md");
            }
            return .retry;
        }
        // Non-2xx: echo the status line. "did not accept the payload" alone gives
        // the operator nothing to act on, and the most likely cause is a receiver
        // that decodes OTLP protobuf only while mandor sends OTLP/JSON — which the
        // status plus docs/INTEGRATION-PHOTON.md makes diagnosable.
        const line = rslice[0..@min(rslice.len, 64)];
        const cut = std.mem.indexOfScalar(u8, line, '\r') orelse line.len;
        err("photon rejected the payload — see docs/INTEGRATION-PHOTON.md");
        err(line[0..cut]);
        if (rejectedForGood(rslice)) return .rejected;
    } else {
        err("photon rejected the payload (no response) — see docs/INTEGRATION-PHOTON.md");
    }
    return .retry;
}

// ------------------------------------------------------- long-lived daemon
//
// `mandor relay --daemon <endpoint> <spool_dir> <pipe_fd>` is spawned once when
// `photon=` is set (Task 4 wires the spawn). It OWNS the socket so the
// supervision path never touches one. Each cycle it:
//   1. SPOOL FIRST (priority, durable): ships every incident bundle on disk
//      that it has not shipped yet; a send failure leaves it for the next cycle
//      so an incident is never dropped.
//   2. DRAINS THE PIPE (routine, best-effort): decodes framed metric/lifecycle
//      records the core wrote non-blocking, re-encodes them as OTLP, and POSTs;
//      anything that will not fit or will not send is dropped, never retried.
// It exits 0 on pipe EOF (parent gone) or SIGTERM (clean-shutdown request),
// flushing the spool one last time first. STABILITY LEADS: no syscall error,
// bad frame, or send failure ever ends the loop — worst case is a skipped cycle.

/// Minimum interval between spool-dir scans (getdents64). The daemon loop is
/// poll-driven (below) and can wake many times a second under pipe load, so the
/// durable spool tier is rate-limited here: a worker-death lifecycle frame on
/// the pipe still wakes us, so a correlated incident ships within one interval,
/// and the idle tick (below) is the safety-net scan.
const spool_scan_ms = 1000;
/// How often an otherwise idle daemon wakes to rescan the spool. 5s, the
/// supervisor's sampler cadence.
const idle_tick_ms = 5000;

// Shipped-set watermark.
//
// A single epoch-ms high-watermark is NOT safe here. Spool filenames are
// `<epoch_ms>-<name>-<seq>.json` (spool.zig:310): the epoch-ms prefix is
// monotonic but NOT unique — two incidents in the same millisecond share it —
// and the `seq` tiebreaker is not zero-padded, so lexical filename order
// inverts (`…-9.json` sorts after `…-10.json`) and a REALTIME clock step can
// even move a later bundle's prefix backwards. Any of those would let a single
// watermark silently skip a bundle, i.e. drop an incident. So the daemon tracks
// the SET of filenames it has shipped. The spool self-caps at
// spool.max_incidents (spool.zig), so a set one window larger always covers a
// full spool; entries whose files have since been pruned are swept out each
// cycle so the set stays bounded to what is actually on disk.
const ship_name_cap = 64; // == spool.DirEntry.name length; spool caps names at 63
const ship_cap = spool.max_incidents + 32;
const dir_cap = spool.max_incidents + 32;

var dir_entries: [dir_cap]spool.DirEntry = undefined;

pub const Shipped = struct {
    names: [ship_cap][ship_name_cap]u8 = undefined,
    lens: [ship_cap]u8 = undefined,
    /// Per-cycle mark for the sweep: reset to false, set true for every set
    /// entry still present on disk, then survivors are compacted down.
    present: [ship_cap]bool = undefined,
    /// Delivered (true) vs skipped (false). Only delivered names are saved, so
    /// a restarted daemon retries a skipped bundle — after the operator fixes
    /// photon, it gets another chance.
    delivered: [ship_cap]bool = undefined,
    n: usize = 0,
    /// The delivered subset changed since the last save.
    dirty: bool = false,

    fn find(self: *const Shipped, name: []const u8) ?usize {
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (self.lens[i] == name.len and
                std.mem.eql(u8, self.names[i][0..self.lens[i]], name)) return i;
        }
        return null;
    }

    /// Record a shipped filename. A name that will not fit, or a full set, is
    /// silently not tracked — the bundle simply gets re-shipped later (a
    /// duplicate at photon, never a dropped incident).
    fn add(self: *Shipped, name: []const u8) void {
        self.addAs(name, true);
    }

    /// Track a bundle passed over this daemon's life, never saved.
    fn addSkipped(self: *Shipped, name: []const u8) void {
        self.addAs(name, false);
    }

    fn addAs(self: *Shipped, name: []const u8, delivered: bool) void {
        if (name.len == 0 or name.len > ship_name_cap or self.n >= ship_cap) return;
        if (self.find(name) != null) return;
        @memcpy(self.names[self.n][0..name.len], name);
        self.lens[self.n] = @intCast(name.len);
        self.present[self.n] = true;
        self.delivered[self.n] = delivered;
        self.n += 1;
        if (delivered) self.dirty = true;
    }

    /// Drop entries not marked present this cycle (their files were pruned),
    /// keeping the set bounded to the on-disk spool.
    fn sweep(self: *Shipped) void {
        var w: usize = 0;
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (!self.present[i]) {
                if (self.delivered[i]) self.dirty = true;
                continue;
            }
            if (w != i) {
                @memcpy(self.names[w][0..self.lens[i]], self.names[i][0..self.lens[i]]);
                self.lens[w] = self.lens[i];
                self.delivered[w] = self.delivered[i];
            }
            w += 1;
        }
        self.n = w;
    }
};

const ShipResult = enum {
    shipped,
    /// The send failed: photon is down or rejecting. Retry next cycle.
    failed,
    /// The bundle itself can never go — unreadable, empty, over the cap, a
    /// broken JSON escape, or refused by photon as a payload. Retrying cannot
    /// help, and stopping on it would hold back every newer incident, so the
    /// caller skips it.
    unshippable,
};

/// `<state_dir>/relay-shipped`: the delivered names, one per line, so a
/// restarted daemon does not send the whole spool to photon again. It sits
/// beside incidents/, not in it — the sidecar watches that directory.
const shipped_file = "relay-shipped";
var shipped_text: [ship_cap * (ship_name_cap + 1)]u8 = undefined;

/// Add every name in a saved list as delivered. The file is mandor's own, but
/// a truncated or hand-edited one must not trap: lines that are empty or too
/// long are ignored, and a name that is not on disk is swept next cycle.
pub fn parseShipped(s: *Shipped, text: []const u8) void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| s.add(line);
    s.dirty = false; // what was just read is what is on disk
}

fn loadShipped(s: *Shipped, state_dir: []const u8) void {
    var path_buf: [640]u8 = undefined;
    const path = std.mem.printSentinel(&path_buf, "{s}/" ++ shipped_file, .{state_dir}, 0) catch return;
    const text = readFile(path.ptr) catch return; // absent / empty / oversized: start empty
    parseShipped(s, text);
}

/// Write the delivered names atomically (tmp + rename) when they changed. A
/// failed write leaves the old file; the worst case is a re-send after a
/// restart, the behavior before this file existed.
fn saveShipped(s: *Shipped, state_dir: []const u8) void {
    if (!s.dirty) return;
    var len: usize = 0;
    for (0..s.n) |i| {
        if (!s.delivered[i]) continue;
        const name = s.names[i][0..s.lens[i]];
        @memcpy(shipped_text[len..][0..name.len], name);
        len += name.len;
        shipped_text[len] = '\n';
        len += 1;
    }
    var path_buf: [640]u8 = undefined;
    var tmp_buf: [640]u8 = undefined;
    const path = std.mem.printSentinel(&path_buf, "{s}/" ++ shipped_file, .{state_dir}, 0) catch return;
    const tmp = std.mem.printSentinel(&tmp_buf, "{s}/." ++ shipped_file ++ ".tmp", .{state_dir}, 0) catch return;
    const rc = linux.openat(linux.AT.FDCWD, tmp.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (posix.errno(rc) != .SUCCESS) return;
    const fd: i32 = @intCast(rc);
    var off: usize = 0;
    while (off < len) {
        const w = linux.write(fd, shipped_text[off..].ptr, len - off);
        if (posix.errno(w) != .SUCCESS or w == 0) break;
        off += w;
    }
    _ = linux.close(fd);
    if (off != len) return;
    if (posix.errno(linux.rename(tmp.ptr, path.ptr)) == .SUCCESS) s.dirty = false;
}

/// Read one bundle, encode it, ship it.
fn shipOne(spool_dir: []const u8, name: []const u8, host: u32, port: u16, token: []const u8) ShipResult {
    var path_buf: [640]u8 = undefined;
    const path = std.mem.printSentinel(&path_buf, "{s}/incidents/{s}", .{ spool_dir, name }, 0) catch
        return skip(name, "path too long");
    const bundle = readFile(path.ptr) catch |e| return skip(name, switch (e) {
        error.Unreadable => "unreadable or empty",
        error.TooLarge => "exceeds 128KB",
    });
    const body = buildOtlp(bundle) catch |e| return skip(name, switch (e) {
        error.TooLarge => "too large for one OTLP record",
        error.Malformed => "malformed JSON string escape",
    });
    return switch (post(host, port, "/v1/logs", body, token)) {
        .ok => .shipped,
        .retry => .failed,
        .rejected => skip(name, "photon rejected it (HTTP 400/413/422, not retryable)"),
    };
}

/// Say once, on stderr, which bundle is being left out of photon and why. It
/// stays on the spool for `mandor report` and the sidecar; a restarted daemon
/// looks at it afresh.
fn skip(name: []const u8, why: []const u8) ShipResult {
    var buf: [384]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "relay: not shipping incident {s}: {s}", .{ name, why }) catch
        "relay: not shipping an incident: unshippable";
    err(msg);
    return .unshippable;
}

/// Ship every spooled bundle not yet shipped, oldest first. Returns false if a
/// send failed (photon unreachable/rejecting) so the caller can re-resolve.
/// Never advances past a failed send: incidents are durable and retried. A
/// bundle that can never encode is passed over (tracked as handled) instead,
/// so one bad file cannot hold back every newer incident.
fn shipSpool(shipped: *Shipped, spool_dir: []const u8, host: u32, port: u16, token: []const u8) bool {
    // Oldest-first, newest-wins on the (rare) overflow — mirrors spool.prune.
    const n = spool.listIncidents(spool_dir, &dir_entries, .newest);

    // Mark which already-shipped entries still exist; the rest get swept.
    for (shipped.present[0..shipped.n]) |*p| p.* = false;
    for (dir_entries[0..n]) |*e| {
        if (shipped.find(e.name[0..e.name_len])) |idx| shipped.present[idx] = true;
    }

    var ok = true;
    for (dir_entries[0..n]) |*e| {
        const name = e.name[0..e.name_len];
        if (shipped.find(name) != null) continue; // already shipped
        switch (shipOne(spool_dir, name, host, port, token)) {
            .shipped => shipped.add(name),
            .unshippable => shipped.addSkipped(name),
            .failed => {
                // photon is down or rejecting: stop this cycle (one bounded
                // connect rather than one per bundle), leave the rest for the
                // next cycle.
                ok = false;
                break;
            },
        }
    }
    shipped.sweep();
    saveShipped(shipped, spool_dir);
    return ok;
}

// Routine pipe drain state — fixed, preallocated, zero allocation.
var pipe_buf: [16 * 1024]u8 = undefined;
var pipe_filled: usize = 0;
const metric_batch_cap = 64;
var metric_samples: [metric_batch_cap]frame.MetricSample = undefined;
var metric_names: [metric_batch_cap][ship_name_cap]u8 = undefined;

// One drain cycle's lifecycle events, batched into a single /v1/logs POST (like
// the metric batch) instead of one TCP round trip each — a full-fleet start or
// crash cascade is one POST, not N. Sized to the worker cap; a burst past it
// drops the overflow (ephemeral tier, same as a full metric batch). `ev_names`
// holds the name bytes, which alias into pipe_buf/scratch otherwise.
const event_batch_cap = 64;
var event_batch: [event_batch_cap]frame.Lifecycle = undefined;
var event_names: [event_batch_cap][ship_name_cap]u8 = undefined;

// Streamed-log batch (P3, opt-in) — bounded, daemon-local, zero-alloc. Each
// drain cycle accumulates the cycle's log lines here and ships them in ONE
// /v1/logs POST after the loop (same one-cycle lifetime as the metric batch, so
// no cross-call state or flush timer). This is the LOSSY ephemeral tier: names
// and lines are copied into a fixed arena as they are drained (a decoded frame's
// slices point into pipe_buf/scratch, both reused on the next decode), and when
// the record cap OR the arena is exhausted the line is DROPPED with a counter —
// never spooled, never blocking. Sizing: 128 records × up to ~4KB lines would
// overflow the arena, so the 64KB arena is the real bound and body_buf (160KB)
// always fits a full batch.
const max_log_batch = 128;
var log_arena: [64 * 1024]u8 = undefined;
var log_arena_used: usize = 0;
var log_records: [max_log_batch]LogRecord = undefined;
var n_logs: usize = 0;

/// Streamed log frames seen on the pipe (diagnostic). Every decoded log frame
/// bumps this; the subset that could not be batched bumps `log_drops` too.
var log_frames_seen: u64 = 0;

/// Streamed log lines dropped on the floor: batch full / arena full during
/// drain, or the encoder's body_buf overflow tail. Ephemeral tier — dropping is
/// correct, and this counter is the only trace they left.
var log_drops: u64 = 0;

/// Clear the log batch for a new drain cycle. Zeroes the record count and the
/// arena high-water mark; the backing storage is reused (no free, no alloc).
fn resetLogBatch() void {
    n_logs = 0;
    log_arena_used = 0;
}

/// Append one decoded log line to the current batch, copying its name+line into
/// the arena (the frame's slices borrow buffers reused on the next decode). The
/// two bounds — the record cap and the arena capacity — are the batch's ONLY
/// backstop against unbounded growth: if either would be exceeded the line is
/// refused (returns false) and the arena is left untouched, so the caller drops
/// it. Dropping these checks lets the @memcpy below run off the end of the fixed
/// buffers — a safe-mode trap — which is exactly what the batch-bound tests pin.
fn batchLog(l: frame.LogLine) bool {
    if (n_logs >= max_log_batch) return false;
    const need = l.name.len + l.line.len;
    if (log_arena_used + need > log_arena.len) return false;
    const name_off = log_arena_used;
    @memcpy(log_arena[name_off..][0..l.name.len], l.name);
    const line_off = name_off + l.name.len;
    @memcpy(log_arena[line_off..][0..l.line.len], l.line);
    log_arena_used = line_off + l.line.len;
    log_records[n_logs] = .{
        .name = log_arena[name_off..][0..l.name.len],
        .line = log_arena[line_off..][0..l.line.len],
        .iostream = l.iostream,
        .severity = l.severity,
        .t_ns = l.t_unix_ns,
    };
    n_logs += 1;
    return true;
}

/// Append one decoded Tier-2 digest entry to the current log batch, copying its
/// name+sample into the arena (the frame's slices borrow buffers reused on the
/// next decode). Same record-cap + arena bounds as batchLog — if either would be
/// exceeded the entry is refused (returns false, arena untouched) so the caller
/// drops it. Digest records ride the SAME batch/POST as streamed lines; the
/// count/first/last fields make buildOtlpLogs emit the mandor.* int attributes.
/// The digest has no stream, so iostream is tagged stderr; t_ns is the window's
/// last occurrence.
fn batchDigest(d: frame.DigestEntry) bool {
    if (n_logs >= max_log_batch) return false;
    const need = d.name.len + d.sample.len;
    if (log_arena_used + need > log_arena.len) return false;
    const name_off = log_arena_used;
    @memcpy(log_arena[name_off..][0..d.name.len], d.name);
    const sample_off = name_off + d.name.len;
    @memcpy(log_arena[sample_off..][0..d.sample.len], d.sample);
    log_arena_used = sample_off + d.sample.len;
    log_records[n_logs] = .{
        .name = log_arena[name_off..][0..d.name.len],
        .line = log_arena[sample_off..][0..d.sample.len], // sample → body
        .iostream = 1, // digest has no stream; stderr is the reasonable tag
        .severity = d.severity,
        .t_ns = d.last_unix_ns,
        .count = d.count,
        .first_ns = d.first_unix_ns,
        .last_ns = d.last_unix_ns,
    };
    n_logs += 1;
    return true;
}

// Host identity, read ONCE at daemon start (it does not change for the
// daemon's life) into these fixed buffers. It only LABELS per-worker data —
// host.name/host.id on each worker's metrics and logs, so photon joins a
// worker to the photon-agent on its node; mandor measures nothing about the
// host. drainPipe reuses the slices, so nothing re-reads /proc or allocates. Default
// to "unknown" until runDaemon populates them.
var daemon_host_name_buf: [256]u8 = undefined;
var daemon_host_id_buf: [256]u8 = undefined;
var daemon_host_name: []const u8 = "unknown";
var daemon_host_id: []const u8 = "unknown";

/// Drain everything currently readable from the pipe, ship it best-effort, and
/// report whether EOF (parent gone) was seen. Metric samples, streamed log
/// lines, and lifecycle events are each batched into a single OTLP request per
/// cycle. Any encode or send failure drops the batch — routine telemetry is
/// ephemeral.
fn drainPipe(pipe_fd: i32, host: u32, port: u16, token: []const u8) bool {
    var eof = false;
    while (pipe_filled < pipe_buf.len) {
        const rc = linux.read(pipe_fd, pipe_buf[pipe_filled..].ptr, pipe_buf.len - pipe_filled);
        switch (posix.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) {
                    eof = true;
                    break;
                }
                pipe_filled += rc;
            },
            .INTR => continue,
            .AGAIN => break, // nothing more queued right now
            else => break, // read error: keep what we have, retry next cycle
        }
    }

    var n_samples: usize = 0;
    var n_events: usize = 0;
    resetLogBatch(); // one cycle's log lines only
    var scratch: [256]u8 = undefined;
    var off: usize = 0;
    while (true) {
        const d = frame.decode(pipe_buf[off..pipe_filled], &scratch) orelse break;
        switch (d.rec) {
            .metric_sample => |m| {
                if (n_samples < metric_batch_cap and m.name.len <= ship_name_cap) {
                    @memcpy(metric_names[n_samples][0..m.name.len], m.name);
                    metric_samples[n_samples] = m;
                    metric_samples[n_samples].name = metric_names[n_samples][0..m.name.len];
                    n_samples += 1;
                } // batch full → drop (best-effort routine metric)
            },
            .lifecycle_event => |e| {
                // Batch (like the metric path) → one /v1/logs POST after the
                // loop. Copy the name out of the decode scratch so it outlives it.
                if (n_events < event_batch_cap and e.name.len <= ship_name_cap) {
                    @memcpy(event_names[n_events][0..e.name.len], e.name);
                    event_batch[n_events] = e;
                    event_batch[n_events].name = event_names[n_events][0..e.name.len];
                    n_events += 1;
                } // batch full or name too long → drop (ephemeral)
            },
            .log_line => |l| {
                // Accumulate into the batch shipped after the loop (mirrors the
                // metric path). Streamed logs are the lossy tier: a full batch or
                // arena drops the line with a counter, never blocking or spooling.
                log_frames_seen +|= 1;
                if (!batchLog(l)) log_drops +|= 1;
            },
            .digest_entry => |dg| {
                // Curated Tier-2 digest: ride the SAME log batch/POST as streamed
                // lines. A full batch or arena drops the entry with a counter,
                // never blocking or spooling (curated, best-effort like metrics).
                if (!batchDigest(dg)) log_drops +|= 1;
            },
        }
        off += d.used;
    }

    // Compact the undecoded tail (a partial frame) back to the front.
    if (off > 0) {
        const rem = pipe_filled - off;
        if (rem > 0) std.mem.copyForwards(u8, pipe_buf[0..rem], pipe_buf[off..pipe_filled]);
        pipe_filled = rem;
    } else if (pipe_filled == pipe_buf.len) {
        // Full yet nothing decodes: only reachable on a corrupt/misaligned
        // stream (max frame ≪ buffer). Drop it to avoid a permanent wedge —
        // "drop oldest" taken to its limit. Never happens on our own writer.
        pipe_filled = 0;
    }

    if (n_samples > 0) {
        if (buildOtlpMetrics(metric_samples[0..n_samples], daemon_host_name)) |b| {
            _ = post(host, port, "/v1/metrics", b, token);
        } else |_| {
            // batch too large → drop
        }
    }

    // Streamed logs (opt-in): one /v1/logs POST for the whole cycle's batch.
    // Ephemeral — an encode or send failure drops the batch (no retry, no spool).
    if (n_logs > 0) {
        if (buildOtlpLogs(log_records[0..n_logs], daemon_host_name, daemon_host_id)) |b| {
            _ = post(host, port, "/v1/logs", b, token);
        } else |_| {
            // whole batch too large to encode → drop (ephemeral tier)
        }
    }

    // Lifecycle events: one /v1/logs POST for the whole cycle's batch (was one
    // TCP round trip per event). Ephemeral — an encode/send failure drops it.
    if (n_events > 0) {
        if (buildOtlpEvents(event_batch[0..n_events])) |b| {
            _ = post(host, port, "/v1/logs", b, token);
        } else |_| {
            // whole batch too large to encode → drop (ephemeral tier)
        }
    }
    return eof;
}

/// photon's ingest bearer token from the environment: `PHOTON_INGEST_TOKEN`
/// (the name photon itself, photon-agent and photon-loadgen use — one name
/// across the stack) or the older `PHOTON_OTLP_TOKEN` (v1.12–v1.16.0), first
/// non-empty wins. Empty = no bearer header.
pub fn photonToken(environ: [:null]const ?[*:0]const u8) []const u8 {
    if (spawner.findEnv(environ, "PHOTON_INGEST_TOKEN")) |t| {
        if (t.len != 0) return t;
    }
    return spawner.findEnv(environ, "PHOTON_OTLP_TOKEN") orelse "";
}

/// CLOCK_MONOTONIC in milliseconds — the daemon's scheduling clock for the idle
/// tick. Saturating so a bad clock read can never trap. Monotonic (not
/// REALTIME) so a wall-clock step cannot skew the cadence.
fn monoMs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) *| 1000 +| @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

/// Non-blocking check: has a clean-shutdown signal (TERM/INT) arrived?
fn shutdownRequested(sigfd: posix.fd_t) bool {
    if (sigfd < 0) return false;
    var sbuf: [4]linux.signalfd_siginfo = undefined;
    const n = posix.read(sigfd, std.mem.sliceAsBytes(&sbuf)) catch return false; // WouldBlock → none
    return n > 0;
}

/// Long-lived: owns the socket, ships incidents (durable) + routine telemetry
/// (best-effort). `endpoint` is "host:port"; `spool_dir` is the mandor STATE
/// dir (the one that contains `incidents/`, passed straight to
/// spool.listIncidents); `pipe_fd` is the inherited non-blocking read end.
/// Returns an exit code (0 = clean shutdown / parent gone). Never traps.
pub fn runDaemon(
    endpoint: []const u8,
    spool_dir: []const u8,
    pipe_fd: i32,
    service_prefix_arg: []const u8,
    environ: [:null]const ?[*:0]const u8,
) u8 {
    // Install the origin prefix once, up front: every encoder's service.name
    // helper reads the module global, and copying to BSS here keeps the slice
    // stable for the daemon's whole life independent of argv storage. Empty ""
    // leaves OTLP byte-identical to a build without the feature.
    setServicePrefix(service_prefix_arg);
    // Log-line frames are drained, batched, and shipped to /v1/logs by drainPipe.
    // Streaming is gated at the frame source: the SUPERVISOR writes a log frame
    // only for a worker with `stream = true`, so with none selected no frames
    // reach the pipe and the batch stays empty (nothing ships). The daemon needs
    // no toggle — it ships whatever log frames it drains.
    // Resolve once up front; re-resolved on a send failure below because photon
    // may restart with a new IP under compose. A literal IP short-circuits with
    // no network (resolve.zig), so re-resolving is free in that case.
    var hp = resolve.resolve(endpoint) orelse {
        err("bad photon endpoint (want ip:port)");
        return 2;
    };
    const token = photonToken(environ);

    // Block SIGPIPE so a photon that resets the connection mid-write makes the
    // socket write return EPIPE (handled as an ordinary send failure) instead of
    // killing this long-lived daemon. Kept OUT of the signalfd set below so a
    // broken pipe is never mistaken for a shutdown request.
    var pipe_set = posix.sigemptyset();
    posix.sigaddset(&pipe_set, .PIPE);
    posix.sigprocmask(posix.SIG.BLOCK, &pipe_set, null);

    // Clean shutdown via signalfd (same synchronous model as signals.zig — no
    // async handlers). Block TERM/INT and poll the fd each cycle. If signalfd
    // setup fails, degrade to EOF-only shutdown rather than dying.
    var sigset = posix.sigemptyset();
    posix.sigaddset(&sigset, .TERM);
    posix.sigaddset(&sigset, .INT);
    posix.sigprocmask(posix.SIG.BLOCK, &sigset, null);
    const sigfd: posix.fd_t = posix.signalfd(-1, &sigset, linux.SFD.CLOEXEC | linux.SFD.NONBLOCK) catch -1;
    defer {
        if (sigfd >= 0) _ = linux.close(sigfd);
    }

    // Host identity for the resource attributes on every OTLP emission: read
    // once here (it is stable for the daemon's life) so the ship paths never
    // re-read /proc. mandor describes its WORKERS to photon; the host itself
    // (system.* / node GPU) is photon-agent's job, so nothing here samples
    // the node — see docs/INTEGRATION-PHOTON.md.
    daemon_host_name = hostid.hostName(&daemon_host_name_buf);
    daemon_host_id = hostid.hostId(&daemon_host_id_buf);

    // The idle safety-net tick: with nothing on the pipe the loop still wakes
    // every idle_tick_ms to rescan the spool (a bundle written by a crashed
    // supervisor, a retry after photon was down). Advanced by a FIXED interval
    // so the cadence stays anchored to absolute time rather than drifting.
    var next_idle_tick_ms: u64 = monoMs() +| idle_tick_ms;

    var shipped: Shipped = .{};
    loadShipped(&shipped, spool_dir); // what earlier daemons already delivered
    var last_spool_ms: u64 = 0;

    while (true) {
        // Spool tier: durable, retried on failure — rate-limited to spool_scan_ms
        // so a poll-driven loop waking fast under pipe load can't turn into a
        // getdents64 storm. A frame on the pipe (below) wakes us, so a correlated
        // incident still ships within one interval; the idle tick is the
        // safety-net.
        const loop_now = monoMs();
        if (loop_now -| last_spool_ms >= spool_scan_ms) {
            last_spool_ms = loop_now;
            if (!shipSpool(&shipped, spool_dir, hp.host, hp.port, token)) {
                if (resolve.resolve(endpoint)) |new_hp| hp = new_hp;
            }
        }

        // Routine: drain the pipe (best-effort). EOF means the parent is gone.
        if (drainPipe(pipe_fd, hp.host, hp.port, token)) {
            _ = shipSpool(&shipped, spool_dir, hp.host, hp.port, token); // final flush
            return 0;
        }

        // Clean-shutdown request: final flush of both tiers, then exit.
        if (shutdownRequested(sigfd)) {
            _ = drainPipe(pipe_fd, hp.host, hp.port, token);
            _ = shipSpool(&shipped, spool_dir, hp.host, hp.port, token);
            return 0;
        }

        if (monoMs() >= next_idle_tick_ms) next_idle_tick_ms +|= idle_tick_ms;

        // Wait event-driven until the next idle tick OR a pipe/signal event — no
        // fixed cycle, so an idle daemon consumes no CPU between ticks instead
        // of waking every second to rescan the spool. A pipe frame (metric/log/
        // lifecycle, or EOF) or a TERM on the signalfd wakes us immediately; the
        // timeout only bounds the next tick. The deadline is in the future here
        // (advanced above when due), so the timeout is >= 0 and the loop never
        // busy-spins.
        const timeout_ms: u64 = next_idle_tick_ms -| monoMs();
        var pfds = [_]posix.pollfd{
            .{ .fd = pipe_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = sigfd, .events = posix.POLL.IN, .revents = 0 }, // fd < 0 is ignored by poll
        };
        const to: i32 = @intCast(@min(timeout_ms, @as(u64, std.math.maxInt(i32))));
        _ = posix.poll(&pfds, to) catch 0; // EINTR/spurious wake → loop re-checks deadlines + drains
    }
}

const testing = std.testing;

test "photonToken: PHOTON_INGEST_TOKEN first, PHOTON_OTLP_TOKEN as the alias, empty when neither" {
    const both: [:null]const ?[*:0]const u8 = &.{ "PHOTON_OTLP_TOKEN=old", "PHOTON_INGEST_TOKEN=new" };
    try testing.expectEqualStrings("new", photonToken(both));
    const old_only: [:null]const ?[*:0]const u8 = &.{"PHOTON_OTLP_TOKEN=old"};
    try testing.expectEqualStrings("old", photonToken(old_only));
    const blank_new: [:null]const ?[*:0]const u8 = &.{ "PHOTON_INGEST_TOKEN=", "PHOTON_OTLP_TOKEN=old" };
    try testing.expectEqualStrings("old", photonToken(blank_new));
    const none: [:null]const ?[*:0]const u8 = &.{"PATH=/bin"};
    try testing.expectEqualStrings("", photonToken(none));
}

test "statusOk accepts real 2xx and nothing else" {
    try testing.expect(statusOk("HTTP/1.1 200 OK\r\n"));
    try testing.expect(statusOk("HTTP/1.0 200 OK\r\n"));
    // OTLP receivers may answer 202; treating that as a rejection would report
    // a delivery that actually succeeded as a failure.
    try testing.expect(statusOk("HTTP/1.1 202 Accepted\r\n"));
    try testing.expect(statusOk("HTTP/1.1 204 No Content\r\n"));

    try testing.expect(!statusOk("HTTP/1.1 500 Internal Server Error\r\n"));
    try testing.expect(!statusOk("HTTP/1.1 404 Not Found\r\n"));
    try testing.expect(!statusOk("HTTP/1.1 400 Bad Request\r\n"));

    // The false-positive class this guards: a non-HTTP reply whose bytes 9..11
    // read "200" was previously accepted as a successful delivery, silently
    // dropping the incident.
    try testing.expect(!statusOk("error at 200ms while decoding"));
    try testing.expect(!statusOk("SSH-2.0-OpenSSH_8.9p1 200"));
    try testing.expect(!statusOk("\x00\x00\x00\x00\x00\x00\x00\x00\x00200"));

    // Too short to hold a status line at all.
    try testing.expect(!statusOk(""));
    try testing.expect(!statusOk("HTTP/1.1 2"));
    try testing.expect(!statusOk("200 OK"));
}

test "looksLikeHtml flags a web-UI 200 but not a real OTLP response" {
    // photon's SPA catch-all: 200 with a text/html content type (wrong endpoint).
    try testing.expect(looksLikeHtml("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<x>"));
    // Case-insensitive: header casing varies across servers.
    try testing.expect(looksLikeHtml("HTTP/1.1 200 OK\r\nContent-Type: TEXT/HTML; charset=utf-8\r\n\r\n"));

    // A genuine OTLP/HTTP receiver: protobuf ExportLogsServiceResponse (\n\x00 =
    // empty partial_success = 0 rejected). Must NOT be mistaken for HTML.
    try testing.expect(!looksLikeHtml("HTTP/1.1 200 OK\r\nContent-Type: application/x-protobuf\r\n\r\n\n\x00"));
    try testing.expect(!looksLikeHtml("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{}"));
    // We key on the content type only — stray `<html`/`<!doctype` bytes in a
    // protobuf body must NOT condemn a working endpoint (the retry-forever risk).
    try testing.expect(!looksLikeHtml("HTTP/1.1 200 OK\r\nContent-Type: application/x-protobuf\r\n\r\n<html>"));
    try testing.expect(!looksLikeHtml(""));
}

test "parseHostPort accepts and rejects" {
    const ok = parseHostPort("127.0.0.1:4318").?;
    try testing.expectEqual(@as(u32, 0x7f000001), ok.host);
    try testing.expectEqual(@as(u16, 4318), ok.port);
    try testing.expectEqual(@as(u32, 0xffffffff), parseHostPort("255.255.255.255:1").?.host);
    try testing.expectEqual(@as(u16, 65535), parseHostPort("0.0.0.0:65535").?.port);

    // Structural rejections: no port, out-of-range port, empty. Bad *octets*
    // are no longer rejected outright — "256.0.0.1" is not a dotted quad, so
    // it is treated as a name and looked up, which is what lets
    // `photon = "photon:4318"` work at all.
    try testing.expect(parseHostPort("127.0.0.1") == null);
    try testing.expect(parseHostPort("127.0.0.1:65536") == null);
    try testing.expect(parseHostPort("127.0.0.1:") == null);
    try testing.expect(parseHostPort("") == null);
    try testing.expect(parseHostPort(":") == null);
    try testing.expect(parseHostPort(":4318") == null);

    // Name resolution itself is tested in resolve.zig, where the parsing is
    // pure. Exercising it here would depend on the machine's /etc/hosts and
    // could put a real 3s DNS query in the unit-test path.
}

test "scanStr walks escapes and stops at the real closing quote" {
    try testing.expectEqualStrings("api", scanStr("{\"name\":\"api\"}", "name").?);
    // An escaped quote inside the value must not end it.
    try testing.expectEqualStrings("a\\\"b", scanStr("{\"v\":\"a\\\"b\"}", "v").?);
    // A value ending in an escaped backslash still terminates correctly.
    try testing.expectEqualStrings("a\\\\", scanStr("{\"v\":\"a\\\\\"}", "v").?);
    try testing.expectEqualStrings("", scanStr("{\"v\":\"\"}", "v").?);
    try testing.expect(scanStr("{\"v\":\"unterminated", "v") == null);
    try testing.expect(scanStr("{\"other\":\"x\"}", "v") == null);
}

// OTLP SeverityNumber as it appears on the wire, written out rather than read
// from otlp.Severity so the tests check the numbers, not the enum.
const sev_info: u64 = 9;
const sev_warn: u64 = 13;
const sev_error: u64 = 17;

/// Minimal protobuf reader, test-only. Walks one nesting level and hands back
/// each field so a test can assert on structure rather than on bytes that
/// happen to appear somewhere in the payload.
const Fields = struct {
    b: []const u8,
    i: usize = 0,

    const Field = struct { num: u8, wire: u8, bytes: []const u8, int: u64 };

    fn varint(self: *Fields) u64 {
        var v: u64 = 0;
        var shift: u6 = 0;
        while (self.i < self.b.len) {
            const c = self.b[self.i];
            self.i += 1;
            v |= @as(u64, c & 0x7f) << shift;
            if (c & 0x80 == 0) break;
            shift += 7;
        }
        return v;
    }

    fn next(self: *Fields) ?Field {
        if (self.i >= self.b.len) return null;
        const key = self.varint();
        const num: u8 = @intCast(key >> 3);
        const wire: u8 = @intCast(key & 7);
        switch (wire) {
            0 => return .{ .num = num, .wire = wire, .bytes = &.{}, .int = self.varint() },
            1 => {
                var v: u64 = 0;
                for (0..8) |k| v |= @as(u64, self.b[self.i + k]) << @intCast(k * 8);
                self.i += 8;
                return .{ .num = num, .wire = wire, .bytes = &.{}, .int = v };
            },
            2 => {
                const n: usize = @intCast(self.varint());
                const out = self.b[self.i .. self.i + n];
                self.i += n;
                return .{ .num = num, .wire = wire, .bytes = out, .int = 0 };
            },
            else => return null,
        }
    }

    /// First field with this number, or null.
    fn get(b: []const u8, num: u8) ?Field {
        var it = Fields{ .b = b };
        while (it.next()) |f| if (f.num == num) return f;
        return null;
    }
};

/// AnyValue{string_value=1}
fn avStr(b: []const u8) []const u8 {
    return (Fields.get(b, 1) orelse return "").bytes;
}

/// Walk request -> resource_logs -> scope_logs -> log_records.
fn firstRecord(body: []const u8) []const u8 {
    const rl = Fields.get(body, 1).?.bytes; // resource_logs
    const sl = Fields.get(rl, 2).?.bytes; // scope_logs
    return Fields.get(sl, 2).?.bytes; // log_records
}

test "buildOtlp emits a well-formed OTLP protobuf record" {
    // photon decodes protobuf only; this walks the payload the way its
    // mapping layer does, so wrong field numbers or wire types fail here
    // rather than at ingest.
    const bundle =
        "{\"name\":\"api\",\"kind\":\"crash\"," ++
        "\"verdict\":\"said \\\"boom\\\"\",\"release\":\"v1\"}";
    const body = try buildOtlp(bundle);

    const rl = Fields.get(body, 1).?.bytes;
    const res = Fields.get(rl, 1).?.bytes; // resource
    // Resource.attributes: service.name first, then service.version.
    var attrs = Fields{ .b = res };
    const a1 = attrs.next().?.bytes;
    const a2 = attrs.next().?.bytes;
    try testing.expectEqualStrings("service.name", Fields.get(a1, 1).?.bytes);
    try testing.expectEqualStrings("api", avStr(Fields.get(a1, 2).?.bytes));
    try testing.expectEqualStrings("service.version", Fields.get(a2, 1).?.bytes);
    try testing.expectEqualStrings("v1", avStr(Fields.get(a2, 2).?.bytes));

    const rec = firstRecord(body);
    // time_unix_nano and observed_time_unix_nano are fixed64 and both set;
    // photon falls back to the observed time when the event time is 0.
    try testing.expectEqual(@as(u8, 1), Fields.get(rec, 1).?.wire); // fixed64
    try testing.expect(Fields.get(rec, 1).?.int > 0);
    try testing.expectEqual(Fields.get(rec, 1).?.int, Fields.get(rec, 11).?.int);
    try testing.expectEqual(sev_error, Fields.get(rec, 2).?.int);
    try testing.expectEqualStrings("ERROR", Fields.get(rec, 3).?.bytes);

    // The verdict arrives as the text the operator wrote. The bundle stores it
    // JSON-escaped; a protobuf string field holds raw bytes, so relay decodes
    // it on the way out. Shipping the source instead would put literal
    // backslashes in front of the operator — the 1.5.2 double-escape bug
    // arriving from the other direction.
    try testing.expectEqualStrings(
        "said \"boom\"",
        avStr(Fields.get(rec, 5).?.bytes),
    );

    // attributes: mandor.bundle carries the whole bundle, unescaped.
    const kv = Fields.get(rec, 6).?.bytes;
    try testing.expectEqualStrings("mandor.bundle", Fields.get(kv, 1).?.bytes);
    try testing.expectEqualStrings(bundle, avStr(Fields.get(kv, 2).?.bytes));
}

test "buildOtlp maps severity and tolerates missing fields" {
    inline for (.{ "leak-suspect", "restart-loop" }) |k| {
        const body = try buildOtlp("{\"kind\":\"" ++ k ++ "\"}");
        const rec = firstRecord(body);
        try testing.expectEqualStrings("WARN", Fields.get(rec, 3).?.bytes);
        try testing.expectEqual(sev_warn, Fields.get(rec, 2).?.int);
    }
    const oops = try buildOtlp("{\"kind\":\"signal\"}");
    try testing.expectEqualStrings("ERROR", Fields.get(firstRecord(oops), 3).?.bytes);
    try testing.expectEqual(sev_error, Fields.get(firstRecord(oops), 2).?.int);

    // An empty bundle still produces a well-formed record, not a crash.
    const bare = try buildOtlp("{}");
    const rl = Fields.get(bare, 1).?.bytes;
    const res = Fields.get(rl, 1).?.bytes;
    var attrs = Fields{ .b = res };
    try testing.expectEqualStrings("unknown", avStr(Fields.get(attrs.next().?.bytes, 2).?.bytes));
}

test "buildOtlp refuses a bundle with a broken escape" {
    // A half-written or hand-edited bundle must be refused, not spliced into
    // the payload where it would corrupt the whole OTLP record.
    try testing.expectError(error.Malformed, buildOtlp("{\"name\":\"a\\qb\"}"));
    try testing.expectError(error.Malformed, buildOtlp("{\"name\":\"a\\u00zz\"}"));
    try testing.expectError(error.Malformed, buildOtlp("{\"name\":\"a\\u01\"}"));
}

test "buildOtlp rejects a bundle too large for the body buffer" {
    // Protobuf embeds the bundle verbatim, so overflowing body_buf needs an
    // input larger than the buffer rather than one that doubles on the way in.
    const big = &struct {
        var b: [400 * 1024]u8 = undefined;
    }.b;
    @memset(big, 'x');
    try testing.expectError(error.TooLarge, buildOtlp(big));
}

test "buildOtlpMetrics emits per-worker gauges photon can walk" {
    const s = frame.MetricSample{ .name = "api", .rss_kb = 1000, .cpu_pct = 50, .fds = 10, .threads = 4, .restarts = 2, .t_unix_ns = 1_700_000_000_000_000_000 };
    const body = try buildOtlpMetrics(&.{s}, "node-1");

    const rm = Fields.get(body, 1).?.bytes; // resource_metrics
    const res = Fields.get(rm, 1).?.bytes; // resource
    // Two resource attributes, in order: service.name then host.name (the latter
    // lets photon attribute the process to its node for the Host-detail view).
    var res_attrs = Fields{ .b = res };
    const attr = res_attrs.next().?.bytes; // service.name
    try testing.expectEqualStrings("service.name", Fields.get(attr, 1).?.bytes);
    try testing.expectEqualStrings("api", avStr(Fields.get(attr, 2).?.bytes));
    const hattr = res_attrs.next().?.bytes; // host.name
    try testing.expectEqualStrings("host.name", Fields.get(hattr, 1).?.bytes);
    try testing.expectEqualStrings("node-1", avStr(Fields.get(hattr, 2).?.bytes));

    const sm = Fields.get(rm, 2).?.bytes; // scope_metrics
    // Gauges in semconv order: memory.usage (bytes, as_int) then cpu.utilization
    // (0..1, as_double). Collect the first two Metric (field 2) entries.
    var mit = Fields{ .b = sm };
    var m_mem: []const u8 = &.{};
    var m_cpu: []const u8 = &.{};
    var midx: usize = 0;
    while (mit.next()) |f| {
        if (f.num != 2) continue;
        if (midx == 0) m_mem = f.bytes;
        if (midx == 1) m_cpu = f.bytes;
        midx += 1;
    }
    // process.memory.usage: rss_kb (1000) × 1024 as_int bytes.
    try testing.expectEqualStrings("process.memory.usage", Fields.get(m_mem, 1).?.bytes);
    const mem_dp = Fields.get(Fields.get(m_mem, 5).?.bytes, 1).?.bytes; // gauge → data_points
    try testing.expectEqual(@as(u8, 1), Fields.get(mem_dp, 3).?.wire); // time fixed64
    try testing.expectEqual(@as(u64, 1000 * 1024), Fields.get(mem_dp, 6).?.int); // as_int bytes
    // process.cpu.utilization: 0..1 fraction as_double (field 4, NOT as_int/6).
    try testing.expectEqualStrings("process.cpu.utilization", Fields.get(m_cpu, 1).?.bytes);
    const cpu_dp = Fields.get(Fields.get(m_cpu, 5).?.bytes, 1).?.bytes;
    try testing.expect(Fields.get(cpu_dp, 6) == null); // not as_int
    try testing.expectEqual(@as(f64, 0.5), @as(f64, @bitCast(Fields.get(cpu_dp, 4).?.int))); // cpu_pct 50 → 0.5

    // restarts is the last metric and a Sum (field 7), not a Gauge.
    var it = Fields{ .b = sm };
    var last_metric: []const u8 = &.{};
    while (it.next()) |f| if (f.num == 2) {
        last_metric = f.bytes;
    };
    const sum = Fields.get(last_metric, 7).?.bytes;
    try testing.expect(Fields.get(last_metric, 5) == null); // not a gauge
    try testing.expectEqual(@as(u64, 2), Fields.get(sum, 2).?.int); // aggregation_temporality = CUMULATIVE
    try testing.expectEqual(@as(u64, 1), Fields.get(sum, 3).?.int); // is_monotonic = true
    const sdp = Fields.get(sum, 1).?.bytes;
    try testing.expectEqual(@as(u64, 2), Fields.get(sdp, 6).?.int); // as_int == restarts
}

test "buildOtlpMetrics rejects a batch too large for body_buf" {
    // Each worker encodes to well over 200 bytes (five metrics apiece), so this
    // many workers cannot fit in body_buf. Expect the error, never a trap.
    const many = &struct {
        var arr: [body_buf.len / 200 + 1]frame.MetricSample = undefined;
    }.arr;
    for (many) |*s| s.* = .{ .name = "api", .rss_kb = 1, .cpu_pct = 1, .fds = 1, .threads = 1, .restarts = 1, .t_unix_ns = 1 };
    try testing.expectError(error.TooLarge, buildOtlpMetrics(many, "host"));
}

test "buildOtlpLogs emits one OTLP LogRecord per line photon can walk" {
    // photon decodes protobuf only; walk the payload the way its mapping layer
    // does so a wrong field number / wire type / severity fails here, not at
    // ingest. One resource_logs entry per record (field 1, repeated).
    const recs = [_]LogRecord{
        .{ .name = "api", .line = "listening on :8080", .iostream = 0, .severity = 0, .t_ns = 1_700_000_000_000_000_000 },
        .{ .name = "worker", .line = "panic: nil map write", .iostream = 1, .severity = 2, .t_ns = 1_700_000_000_000_000_111 },
        .{ .name = "cron", .line = "slow tick", .iostream = 1, .severity = 1, .t_ns = 1_700_000_000_000_000_222 },
    };
    const body = try buildOtlpLogs(&recs, "node-1", "abc123");

    var it = Fields{ .b = body };
    var idx: usize = 0;
    while (it.next()) |f| {
        if (f.num != 1) continue; // resource_logs (repeated, one per record)
        const rl = f.bytes;
        const res = Fields.get(rl, 1).?.bytes; // resource
        // Resource attrs in order: service.name, host.name, host.id, os.type —
        // the SAME host identity the worker's process metrics carry.
        var ra = Fields{ .b = res };
        const a_svc = ra.next().?.bytes;
        const a_hn = ra.next().?.bytes;
        const a_hid = ra.next().?.bytes;
        const a_os = ra.next().?.bytes;
        try testing.expectEqualStrings("service.name", Fields.get(a_svc, 1).?.bytes);
        try testing.expectEqualStrings(recs[idx].name, avStr(Fields.get(a_svc, 2).?.bytes));
        try testing.expectEqualStrings("host.name", Fields.get(a_hn, 1).?.bytes);
        try testing.expectEqualStrings("node-1", avStr(Fields.get(a_hn, 2).?.bytes));
        try testing.expectEqualStrings("host.id", Fields.get(a_hid, 1).?.bytes);
        try testing.expectEqualStrings("abc123", avStr(Fields.get(a_hid, 2).?.bytes));
        try testing.expectEqualStrings("os.type", Fields.get(a_os, 1).?.bytes);
        try testing.expectEqualStrings("linux", avStr(Fields.get(a_os, 2).?.bytes));

        const sl = Fields.get(rl, 2).?.bytes; // scope_logs
        const rec = Fields.get(sl, 2).?.bytes; // log_records
        // time_unix_nano + observed_time_unix_nano are fixed64, both = t_ns.
        try testing.expectEqual(@as(u8, 1), Fields.get(rec, 1).?.wire);
        try testing.expectEqual(recs[idx].t_ns, Fields.get(rec, 1).?.int);
        try testing.expectEqual(recs[idx].t_ns, Fields.get(rec, 11).?.int);
        // body = the raw line text.
        try testing.expectEqualStrings(recs[idx].line, avStr(Fields.get(rec, 5).?.bytes));
        // attribute log.iostream = stdout|stderr.
        const kv = Fields.get(rec, 6).?.bytes;
        try testing.expectEqualStrings("log.iostream", Fields.get(kv, 1).?.bytes);
        const want_stream: []const u8 = if (recs[idx].iostream == 1) "stderr" else "stdout";
        try testing.expectEqualStrings(want_stream, avStr(Fields.get(kv, 2).?.bytes));
        // severity_number + severity_text per frame tier (0→INFO/9, 1→WARN/13, 2→ERROR/17).
        var want_num: u64 = sev_info;
        var want_text: []const u8 = "INFO";
        if (recs[idx].severity == 1) {
            want_num = sev_warn;
            want_text = "WARN";
        }
        if (recs[idx].severity == 2) {
            want_num = sev_error;
            want_text = "ERROR";
        }
        try testing.expectEqual(want_num, Fields.get(rec, 2).?.int);
        try testing.expectEqualStrings(want_text, Fields.get(rec, 3).?.bytes);
        idx += 1;
    }
    try testing.expectEqual(@as(usize, 3), idx); // all three records present
}

test "buildOtlpLogs encodes the fitting prefix and counts the overflow drops" {
    // Lines large enough that the whole set overflows body_buf: the ephemeral
    // encoder must ship the prefix that fits and drop the rest with a counter,
    // never trap and never refuse the whole batch.
    const big = &struct {
        var b: [5000]u8 = undefined;
    }.b;
    @memset(big, 'x');
    var recs: [200]LogRecord = undefined;
    for (&recs) |*r| r.* = .{ .name = "svc", .line = big, .iostream = 0, .severity = 0, .t_ns = 1 };
    log_drops = 0;
    const body = try buildOtlpLogs(&recs, "node", "id");
    try testing.expect(body.len > 0 and body.len <= body_buf.len);
    try testing.expect(log_drops > 0); // the tail that did not fit was dropped
    // The encoded prefix is still a decodable protobuf.
    const rl = Fields.get(body, 1).?.bytes;
    const sl = Fields.get(rl, 2).?.bytes;
    const rec = Fields.get(sl, 2).?.bytes;
    try testing.expectEqualStrings(big, avStr(Fields.get(rec, 5).?.bytes));
}

test "log batch stops at the record cap" {
    // Tiny lines so the RECORD cap (not the arena) is the binding bound. An
    // off-by-one on the cap would write past log_records[] (a safe-mode trap);
    // dropping the check would over-count. Exactly max_log_batch must be taken.
    resetLogBatch();
    var added: usize = 0;
    var i: usize = 0;
    while (i < max_log_batch + 8) : (i += 1) {
        if (batchLog(.{ .name = "a", .iostream = 0, .severity = 0, .t_unix_ns = 1, .line = "hi" }))
            added += 1;
    }
    try testing.expectEqual(@as(usize, max_log_batch), added);
    try testing.expectEqual(@as(usize, max_log_batch), n_logs);
}

test "log batch refuses lines once the arena is full" {
    // Big lines so the ARENA (not the record cap) is the binding bound. Dropping
    // the "arena can't fit → refuse" check lets batchLog's @memcpy run off
    // log_arena — a safe-mode trap — so this test pins that bound. The accepted
    // prefix must still encode cleanly, proving the arena copies are intact.
    resetLogBatch();
    const big = &@as([4000]u8, @splat('y'));
    var added: usize = 0;
    var refused = false;
    var i: usize = 0;
    while (i < max_log_batch) : (i += 1) {
        if (batchLog(.{ .name = "svc", .iostream = 0, .severity = 0, .t_unix_ns = 1, .line = big })) {
            added += 1;
        } else {
            refused = true;
            break;
        }
    }
    try testing.expect(refused); // hit the arena bound before the record cap
    try testing.expect(added > 0 and added < max_log_batch);
    try testing.expect(log_arena_used <= log_arena.len); // never overran the arena
    const body = try buildOtlpLogs(log_records[0..n_logs], "node", "id");
    try testing.expect(body.len > 0);
}

test "buildOtlpLogs emits mandor digest int attributes when count > 0" {
    // MUTATION TARGET: in buildOtlpLogs, gate the three digest attributes on
    // `r.count >= 2` instead of `> 0` (a count==1 digest then loses them) OR drop
    // `mandor.count` from pass 2 while keeping it in pass 1 (w.pos != total, the
    // assert fires). Either way this test fails.
    const recs = [_]LogRecord{
        // count==1 so the `>= 2` mutation is caught too (a single-occurrence digest).
        .{ .name = "api", .line = "ERROR: db timeout", .iostream = 1, .severity = 2, .t_ns = 2000, .count = 1, .first_ns = 1000, .last_ns = 2000 },
    };
    const body = try buildOtlpLogs(&recs, "node-1", "abc123");

    const rl = Fields.get(body, 1).?.bytes;
    // service.name is still emitted via putServiceName (origin-prefixed).
    const res = Fields.get(rl, 1).?.bytes;
    const a_svc = Fields.get(res, 1).?.bytes;
    try testing.expectEqualStrings("service.name", Fields.get(a_svc, 1).?.bytes);
    try testing.expectEqualStrings("api", avStr(Fields.get(a_svc, 2).?.bytes));

    const sl = Fields.get(rl, 2).?.bytes;
    const rec = Fields.get(sl, 2).?.bytes;
    // Walk EVERY field-6 attribute; pull the three int-valued digest keys.
    var count_v: ?u64 = null;
    var first_v: ?u64 = null;
    var last_v: ?u64 = null;
    var it = Fields{ .b = rec };
    while (it.next()) |f| {
        if (f.num != 6) continue;
        const kv = f.bytes;
        const key = Fields.get(kv, 1).?.bytes;
        const av = Fields.get(kv, 2).?.bytes; // AnyValue
        if (std.mem.eql(u8, key, "mandor.count")) count_v = Fields.get(av, 3).?.int;
        if (std.mem.eql(u8, key, "mandor.first_ts")) first_v = Fields.get(av, 3).?.int;
        if (std.mem.eql(u8, key, "mandor.last_ts")) last_v = Fields.get(av, 3).?.int;
    }
    try testing.expectEqual(@as(u64, 1), count_v.?);
    try testing.expectEqual(@as(u64, 1000), first_v.?);
    try testing.expectEqual(@as(u64, 2000), last_v.?);
}

test "buildOtlpLogs emits no mandor attributes for a plain streamed line (count == 0)" {
    // Protects the existing streamed-log shape: a count==0 record must produce
    // exactly one field-6 attribute (log.iostream) and none of the mandor.* keys,
    // so streamed output stays byte-identical to the pre-digest encoder.
    const recs = [_]LogRecord{
        .{ .name = "api", .line = "listening on :8080", .iostream = 0, .severity = 0, .t_ns = 1 },
    };
    const body = try buildOtlpLogs(&recs, "node-1", "abc123");

    const rl = Fields.get(body, 1).?.bytes;
    const sl = Fields.get(rl, 2).?.bytes;
    const rec = Fields.get(sl, 2).?.bytes;
    var it = Fields{ .b = rec };
    var n_attrs: usize = 0;
    while (it.next()) |f| {
        if (f.num != 6) continue;
        n_attrs += 1;
        const key = Fields.get(f.bytes, 1).?.bytes;
        try testing.expect(!std.mem.startsWith(u8, key, "mandor.")); // no digest keys
    }
    try testing.expectEqual(@as(usize, 1), n_attrs); // only log.iostream
}

test "digest batch stops at the record cap" {
    // Tiny samples so the RECORD cap (not the arena) is the binding bound.
    // Exactly max_log_batch entries must be taken — mirrors the batchLog test.
    resetLogBatch();
    var added: usize = 0;
    var i: usize = 0;
    while (i < max_log_batch + 8) : (i += 1) {
        if (batchDigest(.{ .name = "a", .severity = 2, .count = 3, .first_unix_ns = 1, .last_unix_ns = 2, .sample = "hi" }))
            added += 1;
    }
    try testing.expectEqual(@as(usize, max_log_batch), added);
    try testing.expectEqual(@as(usize, max_log_batch), n_logs);
    resetLogBatch();
}

test "digest batch refuses entries once the arena is full" {
    // Big samples so the ARENA (not the record cap) is the binding bound; dropping
    // the "arena can't fit → refuse" check would let batchDigest's @memcpy run off
    // log_arena. The accepted prefix must still encode (with its digest ints).
    resetLogBatch();
    const big = &@as([4000]u8, @splat('y'));
    var added: usize = 0;
    var refused = false;
    var i: usize = 0;
    while (i < max_log_batch) : (i += 1) {
        if (batchDigest(.{ .name = "svc", .severity = 2, .count = 7, .first_unix_ns = 1, .last_unix_ns = 2, .sample = big })) {
            added += 1;
        } else {
            refused = true;
            break;
        }
    }
    try testing.expect(refused); // hit the arena bound before the record cap
    try testing.expect(added > 0 and added < max_log_batch);
    try testing.expect(log_arena_used <= log_arena.len); // never overran the arena
    const body = try buildOtlpLogs(log_records[0..n_logs], "node", "id");
    try testing.expect(body.len > 0);
    resetLogBatch();
}

test "Shipped set tracks names and sweeps entries no longer on disk" {
    // The daemon's durability hinges on this set: a shipped bundle must be
    // recognized (never re-shipped forever), an unshipped one must not, and a
    // bundle pruned from disk must fall out so the set stays bounded.
    var s: Shipped = .{};
    try testing.expect(s.find("a.json") == null);
    s.add("100-api-1.json");
    s.add("100-api-2.json"); // same epoch-ms prefix: a single watermark would miss this
    s.add("101-api-3.json");
    try testing.expectEqual(@as(usize, 3), s.n);
    try testing.expect(s.find("100-api-2.json") != null);
    try testing.expect(s.find("102-api-4.json") == null);

    // Simulate a cycle where only the two newest still exist on disk.
    for (s.present[0..s.n]) |*p| p.* = false;
    if (s.find("100-api-2.json")) |i| s.present[i] = true;
    if (s.find("101-api-3.json")) |i| s.present[i] = true;
    s.sweep();
    try testing.expectEqual(@as(usize, 2), s.n);
    try testing.expect(s.find("100-api-1.json") == null); // pruned → forgotten
    try testing.expect(s.find("100-api-2.json") != null);
    try testing.expect(s.find("101-api-3.json") != null);
}

fn writeTestFile(path: [*:0]const u8, text: []const u8) !void {
    const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (posix.errno(rc) != .SUCCESS) return error.TestUnexpectedResult;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    _ = linux.write(fd, text.ptr, text.len);
}

test "an unshippable bundle is skipped, not retried forever ahead of the queue" {
    // A bundle that can never encode (broken JSON escape, oversized, empty) used
    // to fail like a down photon: the cycle stopped on it, every cycle, so every
    // newer incident stayed behind it for the daemon's whole life.
    var dir_buf: [128]u8 = undefined;
    const dir = try std.mem.printSentinel(&dir_buf, "/tmp/mandor-poison-{d}", .{linux.getpid()}, 0);
    var inc_buf: [160]u8 = undefined;
    const inc = try std.mem.printSentinel(&inc_buf, "{s}/incidents", .{dir}, 0);
    _ = linux.mkdirat(linux.AT.FDCWD, dir.ptr, 0o755);
    _ = linux.mkdirat(linux.AT.FDCWD, inc.ptr, 0o755);
    var bad_buf: [200]u8 = undefined;
    const bad = try std.mem.printSentinel(&bad_buf, "{s}/1000-api-1.json", .{inc}, 0);
    var good_buf: [200]u8 = undefined;
    const good = try std.mem.printSentinel(&good_buf, "{s}/2000-api-2.json", .{inc}, 0);
    var saved_buf: [200]u8 = undefined;
    const saved = try std.mem.printSentinel(&saved_buf, "{s}/" ++ shipped_file, .{dir}, 0);
    defer {
        _ = linux.unlinkat(linux.AT.FDCWD, bad.ptr, 0);
        _ = linux.unlinkat(linux.AT.FDCWD, good.ptr, 0);
        _ = linux.unlinkat(linux.AT.FDCWD, saved.ptr, 0);
        _ = linux.unlinkat(linux.AT.FDCWD, inc.ptr, linux.AT.REMOVEDIR);
        _ = linux.unlinkat(linux.AT.FDCWD, dir.ptr, linux.AT.REMOVEDIR);
    }
    try writeTestFile(bad.ptr, "{\"v\":8,\"name\":\"api\",\"verdict\":\"broken \\q escape\"}");
    try writeTestFile(good.ptr, "{\"v\":8,\"name\":\"api\",\"kind\":\"exit\",\"verdict\":\"exit 1\"}");

    // Nothing listens on 127.0.0.1:1, so the good bundle's send fails at once.
    var shipped: Shipped = .{};
    try testing.expect(!shipSpool(&shipped, dir, 0x7f000001, 1, ""));
    try testing.expect(shipped.find("1000-api-1.json") != null); // skipped for good
    try testing.expect(shipped.find("2000-api-2.json") == null); // still queued, retried

    // With only the unshippable bundle left, a cycle is not a delivery failure
    // (that would make the daemon re-resolve photon for nothing).
    _ = linux.unlinkat(linux.AT.FDCWD, good.ptr, 0);
    var only_bad: Shipped = .{};
    try testing.expect(shipSpool(&only_bad, dir, 0x7f000001, 1, ""));
    // A skipped bundle is never saved as delivered: a restarted daemon (after
    // the operator fixes photon) gets to try it again.
    try testing.expect(readFile(saved.ptr) == error.Unreadable);
}

test "rejectedForGood: only payload verdicts, never endpoint or outage" {
    try testing.expect(rejectedForGood("HTTP/1.1 400 Bad Request\r\n"));
    try testing.expect(rejectedForGood("HTTP/1.1 413 Payload Too Large\r\n"));
    try testing.expect(rejectedForGood("HTTP/1.1 422 Unprocessable\r\n"));
    // Token, endpoint, encoding, throttling and outages stay retryable.
    for ([_][]const u8{ "401", "403", "404", "415", "429", "500", "502", "503" }) |c| {
        var buf: [32]u8 = undefined;
        const resp = try std.fmt.bufPrint(&buf, "HTTP/1.1 {s} X\r\n", .{c});
        try testing.expect(!rejectedForGood(resp));
    }
    try testing.expect(!rejectedForGood("garbage 400 response"));
    try testing.expect(!rejectedForGood("HTTP/1.1 4"));
}

test "shipped set: delivered names survive a save and load, skipped ones do not" {
    var dir_buf: [128]u8 = undefined;
    const dir = try std.mem.printSentinel(&dir_buf, "/tmp/mandor-shipped-{d}", .{linux.getpid()}, 0);
    _ = linux.mkdirat(linux.AT.FDCWD, dir.ptr, 0o755);
    var saved_buf: [200]u8 = undefined;
    const saved = try std.mem.printSentinel(&saved_buf, "{s}/" ++ shipped_file, .{dir}, 0);
    defer {
        _ = linux.unlinkat(linux.AT.FDCWD, saved.ptr, 0);
        _ = linux.unlinkat(linux.AT.FDCWD, dir.ptr, linux.AT.REMOVEDIR);
    }

    var a: Shipped = .{};
    a.add("100-api-1.json");
    a.addSkipped("150-api-x.json");
    a.add("200-api-2.json");
    saveShipped(&a, dir);
    try testing.expect(!a.dirty);

    var b: Shipped = .{};
    loadShipped(&b, dir);
    try testing.expectEqual(@as(usize, 2), b.n);
    try testing.expect(b.find("100-api-1.json") != null);
    try testing.expect(b.find("200-api-2.json") != null);
    try testing.expect(b.find("150-api-x.json") == null); // skipped: retried next life

    // A pruned bundle falls out of the saved list on the next save.
    for (b.present[0..b.n]) |*p| p.* = false;
    if (b.find("200-api-2.json")) |i| b.present[i] = true;
    b.sweep();
    try testing.expect(b.dirty);
    saveShipped(&b, dir);
    var c: Shipped = .{};
    loadShipped(&c, dir);
    try testing.expectEqual(@as(usize, 1), c.n);
}

test "parseShipped tolerates a damaged file" {
    var s: Shipped = .{};
    const junk: [ship_name_cap + 10]u8 = @splat('n');
    var text_buf: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&text_buf, "a.json\n\n\n{s}\nb.json", .{&junk});
    parseShipped(&s, text);
    try testing.expectEqual(@as(usize, 2), s.n); // empty and over-long lines dropped
    try testing.expect(s.find("b.json") != null); // last line needs no newline
    try testing.expect(!s.dirty);
}

test "buildOtlpEvent renders body, severity, and service.name" {
    // A worker killed by SIGSEGV: negative code renders as a signal, severity
    // ERROR, and the resource carries the worker's service.name.
    const e1 = frame.Lifecycle{ .name = "api", .ev = .exited_err, .code = -11, .t_unix_ns = 1_700_000_000_000_000_000 };
    const body = try buildOtlpEvent(e1);

    const rl = Fields.get(body, 1).?.bytes;
    const res = Fields.get(rl, 1).?.bytes;
    const attr = Fields.get(res, 1).?.bytes;
    try testing.expectEqualStrings("service.name", Fields.get(attr, 1).?.bytes);
    try testing.expectEqualStrings("api", avStr(Fields.get(attr, 2).?.bytes));

    const rec = firstRecord(body);
    try testing.expectEqual(@as(u8, 1), Fields.get(rec, 1).?.wire); // time fixed64
    try testing.expectEqual(sev_error, Fields.get(rec, 2).?.int);
    try testing.expectEqualStrings("ERROR", Fields.get(rec, 3).?.bytes);
    try testing.expectEqualStrings("worker api exited signal:11", avStr(Fields.get(rec, 5).?.bytes));
    // exit.code attribute carries the raw code.
    const kv = Fields.get(rec, 6).?.bytes;
    try testing.expectEqualStrings("exit.code", Fields.get(kv, 1).?.bytes);
    try testing.expectEqualStrings("-11", avStr(Fields.get(kv, 2).?.bytes));

    // A failing health check: WARN, body "unhealthy", service.name = worker.
    // buildOtlpEvent reuses body_buf, so finish e1 before encoding e2.
    const e2 = frame.Lifecycle{ .name = "db", .ev = .health_down, .t_unix_ns = 1_700_000_000_000_000_000 };
    const b2 = try buildOtlpEvent(e2);
    const rl2 = Fields.get(b2, 1).?.bytes;
    const res2 = Fields.get(rl2, 1).?.bytes;
    const attr2 = Fields.get(res2, 1).?.bytes;
    try testing.expectEqualStrings("db", avStr(Fields.get(attr2, 2).?.bytes));
    const rec2 = firstRecord(b2);
    try testing.expectEqual(sev_warn, Fields.get(rec2, 2).?.int);
    try testing.expectEqualStrings("WARN", Fields.get(rec2, 3).?.bytes);
    try testing.expectEqualStrings("worker db unhealthy", avStr(Fields.get(rec2, 5).?.bytes));
}

test "buildOtlpEvents batches multiple events into one request" {
    const evs = [_]frame.Lifecycle{
        .{ .name = "api", .ev = .started, .t_unix_ns = 1_700_000_000_000_000_000 },
        .{ .name = "db", .ev = .exited_err, .code = 7, .t_unix_ns = 1_700_000_000_000_000_001 },
    };
    const body = try buildOtlpEvents(&evs);
    // Two resource_logs entries (field 1), one per event, each with its own
    // service.name — proving the events rode ONE request instead of two POSTs.
    var it = Fields{ .b = body };
    var n_rl: usize = 0;
    var saw_api = false;
    var saw_db = false;
    while (it.next()) |f| {
        if (f.num != 1) continue; // resource_logs
        n_rl += 1;
        const res = Fields.get(f.bytes, 1).?.bytes;
        const attr = Fields.get(res, 1).?.bytes;
        const nm = avStr(Fields.get(attr, 2).?.bytes);
        if (std.mem.eql(u8, nm, "api")) saw_api = true;
        if (std.mem.eql(u8, nm, "db")) saw_db = true;
    }
    try testing.expectEqual(@as(usize, 2), n_rl);
    try testing.expect(saw_api and saw_db);
}

test "buildOtlpEvents truncates the batch at the first un-renderable event" {
    // Pass 1 sizes each event; an event whose body overflows renderEventBody's
    // 256-byte scratch trips `catch break`, so the batch stops there and ships
    // only the events already counted (ephemeral "drop the rest"). This locks in
    // the partial-batch accounting: pass 2 writes exactly nfit events and the
    // w.pos == total assert must still hold (a divergence would panic here).
    const huge = &@as([250]u8, @splat('x')); // "worker " ++ huge ++ " started" > 256 → TooLarge
    const evs = [_]frame.Lifecycle{
        .{ .name = "api", .ev = .started, .t_unix_ns = 1_700_000_000_000_000_000 },
        .{ .name = huge, .ev = .started, .t_unix_ns = 1_700_000_000_000_000_001 },
        .{ .name = "db", .ev = .started, .t_unix_ns = 1_700_000_000_000_000_002 }, // after the break → dropped
    };
    const body = try buildOtlpEvents(&evs);
    // Only the first event survives: one resource_logs, service.name "api".
    var it = Fields{ .b = body };
    var n_rl: usize = 0;
    while (it.next()) |f| {
        if (f.num != 1) continue;
        n_rl += 1;
        try testing.expectEqualStrings("api", firstServiceName(body));
    }
    try testing.expectEqual(@as(usize, 1), n_rl);

    // A first event too large alone yields error.TooLarge (caller drops the batch).
    const only_huge = [_]frame.Lifecycle{
        .{ .name = huge, .ev = .started, .t_unix_ns = 1_700_000_000_000_000_000 },
    };
    try testing.expectError(error.TooLarge, buildOtlpEvents(&only_huge));
}

// ------------------------------------------------- service_prefix (multi-tenant)

/// service.name of a logs-shaped request (buildOtlp / buildOtlpEvent / logs):
/// request → resource_logs(1) → resource(1) → attributes[0] → value string. The
/// per-worker metrics request nests under resource_metrics but with the SAME
/// resource(1)→attr[0] shape, so this reader works for it too.
fn firstServiceName(body: []const u8) []const u8 {
    const rl = Fields.get(body, 1).?.bytes; // resource_logs / resource_metrics
    const res = Fields.get(rl, 1).?.bytes; // resource
    var attrs = Fields{ .b = res };
    const a1 = attrs.next().?.bytes; // service.name is attribute 0
    // Guard against a silent attribute reordering making this read the wrong one.
    std.debug.assert(std.mem.eql(u8, "service.name", Fields.get(a1, 1).?.bytes));
    return avStr(Fields.get(a1, 2).?.bytes);
}

test "a batch is one request: per-record encodes concatenate into N entries" {
    // Every batch encoder writes one-entry requests end to end and relies on
    // protobuf reading that as one request with a repeated field. Prove it by
    // decoding the whole batch with nilo's own decoder, independently of the
    // hand walker above.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const recs = [_]LogRecord{
        .{ .name = "api", .line = "one", .iostream = 0, .severity = 0, .t_ns = 1 },
        .{ .name = "db", .line = "two", .iostream = 1, .severity = 2, .t_ns = 2, .count = 3, .first_ns = 1, .last_ns = 2 },
    };
    const body = try buildOtlpLogs(&recs, "h", "id");
    const req = try proto.decode(otlp.LogsRequest, arena.allocator(), body);
    try testing.expectEqual(@as(usize, 2), req.resource_logs.len);
    for (req.resource_logs, recs) |rl, want| {
        const rec = rl.scope_logs[0].log_records[0];
        try testing.expectEqualStrings(want.line, rec.body.?.value.?.string_value);
        try testing.expectEqual(want.t_ns, rec.time_unix_nano);
        try testing.expectEqualStrings(want.name, rl.resource.?.attributes[0].value.?.value.?.string_value);
        try testing.expectEqual(@as(usize, if (want.count > 0) 4 else 1), rec.attributes.len);
    }
}

test "service_prefix prepends to service.name in every OTLP encoder" {
    setServicePrefix("t-");
    defer setServicePrefix(""); // restore the default for the other tests

    // incident (buildOtlp)
    {
        const body = try buildOtlp("{\"name\":\"api\",\"kind\":\"crash\"}");
        try testing.expectEqualStrings("t-api", firstServiceName(body));
    }
    // per-worker process metrics (buildOtlpMetrics)
    {
        const s = frame.MetricSample{ .name = "api", .rss_kb = 1, .cpu_pct = 1, .fds = 1, .threads = 1, .restarts = 1, .t_unix_ns = 1 };
        const body = try buildOtlpMetrics(&.{s}, "node-1");
        try testing.expectEqualStrings("t-api", firstServiceName(body));
    }
    // lifecycle (buildOtlpEvent)
    {
        const e = frame.Lifecycle{ .name = "worker", .ev = .started, .t_unix_ns = 1 };
        const body = try buildOtlpEvent(e);
        try testing.expectEqualStrings("t-worker", firstServiceName(body));
    }
    // streamed logs (buildOtlpLogs)
    {
        const recs = [_]LogRecord{.{ .name = "cron", .line = "tick", .iostream = 0, .severity = 0, .t_ns = 1 }};
        const body = try buildOtlpLogs(&recs, "node-1", "id");
        try testing.expectEqualStrings("t-cron", firstServiceName(body));
    }
}

test "empty service_prefix leaves service.name byte-identical (bare name)" {
    setServicePrefix(""); // the default; explicit for clarity
    // incident
    {
        const body = try buildOtlp("{\"name\":\"api\",\"kind\":\"crash\"}");
        try testing.expectEqualStrings("api", firstServiceName(body));
    }
    // metrics
    {
        const s = frame.MetricSample{ .name = "api", .rss_kb = 1, .cpu_pct = 1, .fds = 1, .threads = 1, .restarts = 1, .t_unix_ns = 1 };
        const body = try buildOtlpMetrics(&.{s}, "node-1");
        try testing.expectEqualStrings("api", firstServiceName(body));
    }
    // lifecycle
    {
        const e = frame.Lifecycle{ .name = "worker", .ev = .started, .t_unix_ns = 1 };
        const body = try buildOtlpEvent(e);
        try testing.expectEqualStrings("worker", firstServiceName(body));
    }
    // logs
    {
        const recs = [_]LogRecord{.{ .name = "cron", .line = "tick", .iostream = 0, .severity = 0, .t_ns = 1 }};
        const body = try buildOtlpLogs(&recs, "node-1", "id");
        try testing.expectEqualStrings("cron", firstServiceName(body));
    }
}

test "setServicePrefix clamps an over-long prefix to the cap" {
    const long = &@as([service_prefix_cap + 10]u8, @splat('p'));
    setServicePrefix(long);
    defer setServicePrefix("");
    // Copied into the fixed BSS buffer, clamped — never overflows, never traps.
    try testing.expectEqual(@as(usize, service_prefix_cap), service_prefix.len);
}
