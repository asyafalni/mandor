//! `mandor relay <bundle.json>` — ships an incident bundle to photon's
//! OTLP/HTTP logs endpoint (PHOTON_OTLP=ip:port, default 127.0.0.1:4318).
//! Runs ONLY when explicitly invoked as this subcommand — the supervisor
//! itself never opens outbound connections. Wire it up with
//! `on_incident = "/mandor relay"`. Mapping: docs/INTEGRATION-PHOTON.md.

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

/// Wall-clock ceiling on each blocking socket call. Generous enough that a
/// merely slow collector still succeeds, short enough that a hung one cannot
/// strand a process for the life of the container.
const relay_timeout_s = 10;

// The largest OTLP message mandor ever builds is an incident bundle embedded
// raw as the `mandor.bundle` attribute. A bundle is capped at 128 KB (spool's
// bundle_buf) and protobuf embeds strings UNESCAPED, so that message is the
// bundle plus ~1 KB of framing. Every other encoder is far smaller: process /
// host / GPU metrics are tens of KB, and the streamed-log batch is bounded by
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
            error.TooLarge => "bundle exceeds 256KB — refusing to ship a truncated incident",
        });
        return 1;
    };

    var host: u32 = 0x7f000001; // 127.0.0.1
    var port: u16 = 4318;
    const spec = endpoint_arg orelse spawner.findEnv(environ, "PHOTON_OTLP");
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
    return post(host, port, "/v1/logs", body, token);
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

// ------------------------------------------------------- protobuf encoding
//
// OTLP/HTTP requires servers to accept protobuf; JSON support is optional in
// practice and many collectors (photon included) never implemented it. Encoding
// by hand keeps the no-dependency rule: the wire format is varints plus
// length-delimited fields, and mandor already hand-rolls its JSON.
//
// Field numbers are from opentelemetry-proto (logs/v1, common/v1, resource/v1).
// All are <= 15, so every tag fits in one byte.

const wire_varint: u8 = 0;
const wire_fixed64: u8 = 1;
const wire_len: u8 = 2;

fn tagByte(comptime field: u8, comptime wire: u8) u8 {
    return (field << 3) | wire;
}

fn varintLen(v: u64) usize {
    var n: usize = 1;
    var x = v >> 7;
    while (x != 0) : (x >>= 7) n += 1;
    return n;
}

/// Bytes taken by `tag + length + payload` for a length-delimited field.
fn delimLen(payload: usize) usize {
    return 1 + varintLen(payload) + payload;
}

const Writer = struct {
    buf: []u8,
    pos: usize = 0,

    fn byte(self: *Writer, b: u8) void {
        self.buf[self.pos] = b;
        self.pos += 1;
    }

    fn varint(self: *Writer, v: u64) void {
        var x = v;
        while (x >= 0x80) : (x >>= 7) self.byte(@as(u8, @truncate(x)) | 0x80);
        self.byte(@truncate(x));
    }

    fn fixed64(self: *Writer, comptime field: u8, v: u64) void {
        self.byte(tagByte(field, wire_fixed64));
        var i: usize = 0;
        while (i < 8) : (i += 1) self.byte(@truncate(v >> @intCast(i * 8)));
    }

    fn uint(self: *Writer, comptime field: u8, v: u64) void {
        self.byte(tagByte(field, wire_varint));
        self.varint(v);
    }

    /// Opens a length-delimited field whose payload length is already known.
    fn delim(self: *Writer, comptime field: u8, payload: usize) void {
        self.byte(tagByte(field, wire_len));
        self.varint(payload);
    }

    fn string(self: *Writer, comptime field: u8, s: []const u8) void {
        self.delim(field, s.len);
        @memcpy(self.buf[self.pos..][0..s.len], s);
        self.pos += s.len;
    }
};

/// AnyValue{string_value=1}
fn anyValueLen(v: []const u8) usize {
    return delimLen(v.len);
}

/// KeyValue{key=1, value=AnyValue=2}
fn keyValueLen(k: []const u8, v: []const u8) usize {
    return delimLen(k.len) + delimLen(anyValueLen(v));
}

fn putAnyValue(w: *Writer, comptime field: u8, v: []const u8) void {
    w.delim(field, anyValueLen(v));
    w.string(1, v); // AnyValue.string_value
}

fn putKeyValue(w: *Writer, comptime field: u8, k: []const u8, v: []const u8) void {
    w.delim(field, keyValueLen(k, v));
    w.string(1, k); // KeyValue.key
    putAnyValue(w, 2, v); // KeyValue.value
}

/// AnyValue{int_value=3} — a varint-encoded int64 (used for the Tier-2 digest's
/// numeric attributes mandor.count / .first_ts / .last_ts). The string arm above
/// uses field 1; this is the same AnyValue message with the int_value arm.
fn anyValueIntLen(v: u64) usize {
    return 1 + varintLen(v); // tag(field 3, varint) + the varint value
}

/// KeyValue{key=1, value=AnyValue(int)=2} — the int-valued sibling of keyValueLen.
fn keyValueIntLen(k: []const u8, v: u64) usize {
    return delimLen(k.len) + delimLen(anyValueIntLen(v));
}

fn putAnyValueInt(w: *Writer, comptime field: u8, v: u64) void {
    w.delim(field, anyValueIntLen(v));
    w.uint(3, v); // AnyValue.int_value
}

fn putKeyValueInt(w: *Writer, comptime field: u8, k: []const u8, v: u64) void {
    w.delim(field, keyValueIntLen(k, v));
    w.string(1, k); // KeyValue.key
    putAnyValueInt(w, 2, v); // KeyValue.value
}

/// Scratch for `service_prefix ++ name`, formed and consumed within a single
/// putServiceName call (single-threaded daemon, no cross-call state). Sized to
/// the prefix cap plus the largest name any encoder passes: the incident path's
/// name_txt is bounded by unesc_buf and every frame-sourced name is far smaller,
/// so the join never truncates in practice — meaning an empty prefix yields the
/// bare name verbatim (byte-identical to a build without this feature).
var svc_buf: [service_prefix_cap + unesc_buf.len]u8 = undefined;

/// Encoded value length of the prefixed `service.name` (prefix.len + name.len),
/// clamped to the scratch so the sizing pass and the write can never disagree.
/// Length-only: pass 1 needs no scratch and never concatenates.
fn svcNameLen(name: []const u8) usize {
    return @min(service_prefix.len +| name.len, svc_buf.len);
}

/// KeyValue length for `service.name = service_prefix ++ name`. Drop-in for
/// `keyValueLen("service.name", name)` in every sizing pass. Expands to the same
/// shape keyValueLen produces: delimLen(key.len) + delimLen(anyValueLen(vlen)),
/// where anyValueLen(v) == delimLen(v.len).
fn serviceKvLen(name: []const u8) usize {
    const vlen = svcNameLen(name);
    return delimLen("service.name".len) + delimLen(delimLen(vlen));
}

/// Write `service.name = service_prefix ++ name` as resource attribute (field 1).
/// Forms the joined value in svc_buf and hands it to putKeyValue, so the on-wire
/// bytes are exactly serviceKvLen(name). With an empty prefix the value is the
/// bare name — byte-identical to the previous putKeyValue(w, 1, "service.name",
/// name) call sites.
fn putServiceName(w: *Writer, name: []const u8) void {
    const vlen = svcNameLen(name);
    const plen = @min(service_prefix.len, vlen);
    @memcpy(svc_buf[0..plen], service_prefix[0..plen]);
    const nlen = vlen - plen;
    @memcpy(svc_buf[plen..][0..nlen], name[0..nlen]);
    putKeyValue(w, 1, "service.name", svc_buf[0..vlen]);
}

/// OTLP SeverityNumber. INFO for routine lifecycle, WARN for recoverable
/// trouble, ERROR for a failed/killed worker or an incident.
const sev_info: u64 = 9;
const sev_warn: u64 = 13;
const sev_error: u64 = 17;

const BuildError = error{ TooLarge, Malformed };

/// Map the bundle onto one OTLP LogRecord (docs/INTEGRATION-PHOTON.md).
pub fn buildOtlp(bundle: []const u8) BuildError![]const u8 {
    const name = scanStr(bundle, "name") orelse "unknown";
    const kind = scanStr(bundle, "kind") orelse "unknown";
    const verdict = scanStr(bundle, "verdict") orelse "";
    const release = scanStr(bundle, "release") orelse "";
    const severity: []const u8 = if (std.mem.eql(u8, kind, "leak-suspect") or
        std.mem.eql(u8, kind, "restart-loop")) "WARN" else "ERROR";

    const sev_num: u64 = if (std.mem.eql(u8, severity, "WARN")) sev_warn else sev_error;

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

    // Pass 1: sizes, innermost first. Protobuf writes a nested message's length
    // *before* its bytes and mandor has no allocator to build-then-measure in,
    // so two passes over a handful of known fields beats a scratch buffer.
    const rec_len =
        9 + // time_unix_nano (fixed64, field 1)
        9 + // observed_time_unix_nano (fixed64, field 11)
        1 + varintLen(sev_num) + // severity_number (field 2)
        delimLen(severity.len) + // severity_text (field 3)
        delimLen(anyValueLen(verdict_txt)) + // body (field 5)
        delimLen(keyValueLen("mandor.bundle", bundle)); // attributes (field 6)
    const scope_len = delimLen(rec_len); // ScopeLogs.log_records (field 2)
    const resource_len =
        delimLen(serviceKvLen(name_txt)) +
        delimLen(keyValueLen("service.version", release_txt));
    const rl_len = delimLen(resource_len) + delimLen(scope_len);
    const total = delimLen(rl_len); // ExportLogsServiceRequest.resource_logs
    if (total > body_buf.len) return error.TooLarge;

    // Pass 2: write.
    var w = Writer{ .buf = &body_buf };
    w.delim(1, rl_len); // resource_logs
    w.delim(1, resource_len); //   resource
    putServiceName(&w, name_txt); //     attributes (origin-prefixed)
    putKeyValue(&w, 1, "service.version", release_txt);
    w.delim(2, scope_len); //   scope_logs
    w.delim(2, rec_len); //     log_records
    w.fixed64(1, ns); //       time_unix_nano
    w.fixed64(11, ns); //       observed_time_unix_nano
    w.uint(2, sev_num); //       severity_number
    w.string(3, severity); //       severity_text
    putAnyValue(&w, 5, verdict_txt); //       body
    putKeyValue(&w, 6, "mandor.bundle", bundle); //       attributes

    std.debug.assert(w.pos == total); // sizing and writing must agree
    return body_buf[0..w.pos];
}

// ------------------------------------------------------- OTLP metrics
//
// opentelemetry-proto metrics/v1. All field numbers <= 15 → one-byte tags.
// One ResourceMetrics PER worker so service.name in the resource matches the
// incident logs' service grouping. rss/cpu/fds/threads ship as Gauge, restarts
// as a monotonic cumulative Sum. NumberDataPoint carries time_unix_nano
// (fixed64) and as_int (fixed64 wire) — non-negative values, so a plain u64.

/// NumberDataPoint { time_unix_nano = 3 (fixed64), then either as_int = 6 or
/// as_double = 4 (both fixed64 wire) }. Every datapoint is time + one value =
/// tag(1)+8 twice → 18, constant regardless of int-vs-double.
fn numberDataPointLen() usize {
    return 9 + 9;
}

/// `value` is the raw 8 bytes: a u64 for as_int, or an f64 bit pattern
/// (@bitCast) for as_double. as_double is used for ratio metrics like
/// process.cpu.utilization (0..1) per OTel semconv; as_int for byte/count ones.
fn putNumberDataPoint(w: *Writer, t_ns: u64, value: u64, is_double: bool) void {
    w.fixed64(3, t_ns); // time_unix_nano
    if (is_double) w.fixed64(4, value) else w.fixed64(6, value); // as_double | as_int
}

/// Gauge { data_points = 1 }.
fn gaugeBodyLen() usize {
    return delimLen(numberDataPointLen());
}

/// Sum { data_points = 1, aggregation_temporality = 2, is_monotonic = 3 }.
fn sumBodyLen() usize {
    return delimLen(numberDataPointLen()) +
        (1 + varintLen(2)) + // aggregation_temporality = CUMULATIVE
        (1 + varintLen(1)); //  is_monotonic = true
}

/// Metric { name = 1, unit = 3, gauge = 5 } body length.
fn gaugeMetricLen(name: []const u8, unit: []const u8) usize {
    return delimLen(name.len) + delimLen(unit.len) + delimLen(gaugeBodyLen());
}

/// Metric { name = 1, unit = 3, sum = 7 } body length.
fn sumMetricLen(name: []const u8, unit: []const u8) usize {
    return delimLen(name.len) + delimLen(unit.len) + delimLen(sumBodyLen());
}

fn putGaugeMetric(w: *Writer, name: []const u8, unit: []const u8, t_ns: u64, value: u64, is_double: bool) void {
    w.string(1, name); // Metric.name
    w.string(3, unit); // Metric.unit
    w.delim(5, gaugeBodyLen()); // Metric.gauge
    w.delim(1, numberDataPointLen()); //   Gauge.data_points
    putNumberDataPoint(w, t_ns, value, is_double);
}

fn putSumMetric(w: *Writer, name: []const u8, unit: []const u8, t_ns: u64, value: u64) void {
    w.string(1, name); // Metric.name
    w.string(3, unit); // Metric.unit
    w.delim(7, sumBodyLen()); // Metric.sum
    w.delim(1, numberDataPointLen()); //   Sum.data_points
    putNumberDataPoint(w, t_ns, value, false); // restarts is a monotonic int counter
    w.uint(2, 2); //   Sum.aggregation_temporality = CUMULATIVE
    w.uint(3, 1); //   Sum.is_monotonic = true
}

/// The four gauge metrics, in emit order (memory first — see the test that walks
/// the first metric). OTel process semantic-convention names/units so any OTLP
/// backend (photon, collectors) reads them without a translation table.
/// cpu.utilization is a 0..1 fraction (as_double); the rest are byte/count ints.
const gauge_metrics = [_]struct { name: []const u8, unit: []const u8, is_double: bool }{
    .{ .name = "process.memory.usage", .unit = "By", .is_double = false },
    .{ .name = "process.cpu.utilization", .unit = "1", .is_double = true },
    .{ .name = "process.unix.file_descriptor.count", .unit = "{count}", .is_double = false },
    .{ .name = "process.thread.count", .unit = "{thread}", .is_double = false },
};
// No OTel semconv equivalent for a supervisor restart counter — kept as a
// mandor-specific extension (a monotonic cumulative Sum).
const restart_metric_name = "process.restarts";
const restart_metric_unit = "{restart}";

/// Encode a batch of per-worker samples as one OTLP ExportMetricsServiceRequest,
/// one ResourceMetrics per sample. Mirrors buildOtlp's two-pass sizing: pass 1
/// sizes innermost-first and refuses a batch that will not fit body_buf, pass 2
/// writes, and the final assert proves the two agree.
pub fn buildOtlpMetrics(samples: []const frame.MetricSample, host_name: []const u8) error{TooLarge}![]const u8 {
    // scope_len is sample-invariant (a fixed metric set), so derive it ONCE
    // instead of recomputing it per sample in BOTH the sizing and write passes.
    var scope_len: usize = 0;
    for (gauge_metrics) |g| scope_len += delimLen(gaugeMetricLen(g.name, g.unit));
    scope_len += delimLen(sumMetricLen(restart_metric_name, restart_metric_unit));

    // Pass 1: sizes, innermost first.
    var total: usize = 0;
    for (samples) |s| {
        const resource_len = delimLen(serviceKvLen(s.name)) +
            delimLen(keyValueLen("host.name", host_name));
        const rm_len = delimLen(resource_len) + delimLen(scope_len);
        total += delimLen(rm_len);
    }
    if (total > body_buf.len) return error.TooLarge;

    // Pass 2: write.
    var w = Writer{ .buf = &body_buf };
    for (samples) |s| {
        const resource_len = delimLen(serviceKvLen(s.name)) +
            delimLen(keyValueLen("host.name", host_name));
        const rm_len = delimLen(resource_len) + delimLen(scope_len);

        w.delim(1, rm_len); // resource_metrics
        w.delim(1, resource_len); //   resource
        putServiceName(&w, s.name); //     attributes (origin-prefixed)
        putKeyValue(&w, 1, "host.name", host_name); //     (so the process is attributable to its node)
        w.delim(2, scope_len); //   scope_metrics

        // Values in the semconv order of gauge_metrics: memory.usage is bytes
        // (rss is kB → ×1024, saturating), cpu.utilization is a 0..1 fraction
        // carried as an f64 bit pattern (as_double), the counts pass through.
        const cpu_util: f64 = @as(f64, @floatFromInt(s.cpu_pct)) / 100.0;
        const values = [_]u64{
            s.rss_kb *| 1024, // process.memory.usage (By)
            @bitCast(cpu_util), // process.cpu.utilization (as_double)
            s.fds, // process.unix.file_descriptor.count
            s.threads, // process.thread.count
        };
        for (gauge_metrics, 0..) |g, i| {
            w.delim(2, gaugeMetricLen(g.name, g.unit)); //   metrics (Metric)
            putGaugeMetric(&w, g.name, g.unit, s.t_unix_ns, values[i], g.is_double);
        }
        w.delim(2, sumMetricLen(restart_metric_name, restart_metric_unit)); // metrics (Metric)
        putSumMetric(&w, restart_metric_name, restart_metric_unit, s.t_unix_ns, s.restarts);
    }
    std.debug.assert(w.pos == total); // sizing and writing must agree
    return body_buf[0..w.pos];
}

// ------------------------------------------------------- OTLP host metrics
//
// Node-level `system.*` metrics: ONE ResourceMetrics scoped to the host
// (host.name/host.id/os.type), a mix of Gauges and one monotonic Sum. Unlike
// the per-worker path each metric can carry MULTIPLE datapoints and each
// datapoint carries attributes (cpu/state/direction/mountpoint), so this path
// uses its own datapoint helpers rather than the single-point per-worker ones.
//
// Value encoding: NumberDataPoint.value is a oneof. Byte/count metrics use
// as_int = field 6 (fixed64 wire, the integer verbatim). Ratio/load metrics
// (utilization, load average) use as_double = field 4 (fixed64 wire, the IEEE-
// 754 bits via @bitCast(f64)). Both tags are one byte and both bodies are 8
// bytes, so a datapoint's value costs 9 bytes regardless of which arm is used —
// which is why the sizing helper does not branch on is_double.

/// One datapoint attribute (all host attrs are string-valued KeyValues).
const HAttr = struct { k: []const u8, v: []const u8 };

/// One NumberDataPoint: the pre-`@bitCast` u64 `value_bits` (as_int verbatim,
/// or as_double bit pattern when `is_double`), plus its attribute set.
const HDp = struct { value_bits: u64, is_double: bool, attrs: []const HAttr };

const HKind = enum { gauge, sum };
const HMetric = struct { name: []const u8, unit: []const u8, kind: HKind, dps: []const HDp };

/// NumberDataPoint { time_unix_nano=3 (fixed64), as_double=4 | as_int=6
/// (fixed64), attributes=7 (repeated KeyValue) }. time + value are 9 bytes
/// each; is_double does not change the size (see the note above).
fn hDataPointLen(attrs: []const HAttr) usize {
    var n: usize = 9 + 9;
    for (attrs) |a| n += delimLen(keyValueLen(a.k, a.v));
    return n;
}

fn putHDataPoint(w: *Writer, t_ns: u64, value_bits: u64, is_double: bool, attrs: []const HAttr) void {
    w.fixed64(3, t_ns); // time_unix_nano
    if (is_double) w.fixed64(4, value_bits) else w.fixed64(6, value_bits); // as_double | as_int
    for (attrs) |a| putKeyValue(w, 7, a.k, a.v); // attributes
}

/// Sum of every datapoint body — shared by the Gauge and Sum data messages.
fn hDataPointsLen(dps: []const HDp) usize {
    var n: usize = 0;
    for (dps) |d| n += delimLen(hDataPointLen(d.attrs));
    return n;
}

fn putHDataPoints(w: *Writer, t_ns: u64, dps: []const HDp) void {
    for (dps) |d| {
        w.delim(1, hDataPointLen(d.attrs)); // data_points (field 1, repeated)
        putHDataPoint(w, t_ns, d.value_bits, d.is_double, d.attrs);
    }
}

/// Sum body adds aggregation_temporality=CUMULATIVE and is_monotonic=true.
fn hSumBodyLen(dps: []const HDp) usize {
    return hDataPointsLen(dps) + (1 + varintLen(2)) + (1 + varintLen(1));
}

fn hMetricLen(m: HMetric) usize {
    const body_len = switch (m.kind) {
        .gauge => hDataPointsLen(m.dps),
        .sum => hSumBodyLen(m.dps),
    };
    return delimLen(m.name.len) + delimLen(m.unit.len) + delimLen(body_len);
}

fn putHMetric(w: *Writer, m: HMetric, t_ns: u64) void {
    w.string(1, m.name); // Metric.name
    w.string(3, m.unit); // Metric.unit
    switch (m.kind) {
        .gauge => {
            w.delim(5, hDataPointsLen(m.dps)); // Metric.gauge
            putHDataPoints(w, t_ns, m.dps);
        },
        .sum => {
            w.delim(7, hSumBodyLen(m.dps)); // Metric.sum
            putHDataPoints(w, t_ns, m.dps);
            w.uint(2, 2); // aggregation_temporality = CUMULATIVE
            w.uint(3, 1); // is_monotonic = true
        },
    }
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

const EventAttr = struct { k: []const u8, v: []const u8 };

/// Event kind → OTLP severity number + text.
fn eventSev(ev: frame.Event) struct { num: u64, text: []const u8 } {
    return switch (ev) {
        .started, .exited_ok, .health_up => .{ .num = sev_info, .text = "INFO" },
        .restarting, .health_down => .{ .num = sev_warn, .text = "WARN" },
        .exited_err, .oom => .{ .num = sev_error, .text = "ERROR" },
    };
}

/// Numeric context for an event as string attributes (photon reads string
/// attrs), written into caller scratch. Both the sizing and write passes call
/// this on the same event so they can never diverge.
fn eventAttrs(e: frame.Lifecycle, attrs: *[2]EventAttr, num_a: *[12]u8, num_b: *[12]u8) error{TooLarge}![]EventAttr {
    var n: usize = 0;
    switch (e.ev) {
        .exited_err, .oom => {
            attrs[n] = .{ .k = "exit.code", .v = std.fmt.bufPrint(num_a, "{d}", .{e.code}) catch return error.TooLarge };
            n += 1;
        },
        .restarting => {
            attrs[n] = .{ .k = "backoff.ms", .v = std.fmt.bufPrint(num_a, "{d}", .{e.backoff_ms}) catch return error.TooLarge };
            n += 1;
            attrs[n] = .{ .k = "restart.count", .v = std.fmt.bufPrint(num_b, "{d}", .{e.restarts}) catch return error.TooLarge };
            n += 1;
        },
        else => {},
    }
    return attrs[0..n];
}

/// Size of one lifecycle event's resource_logs entry — the pass-1 mirror of
/// writeEventRl. Renders the body + attrs into local scratch to measure them.
fn eventRlLen(e: frame.Lifecycle) error{TooLarge}!usize {
    const sev = eventSev(e.ev);
    var body_scratch: [256]u8 = undefined;
    const body_txt = try renderEventBody(&body_scratch, e);
    var attrs: [2]EventAttr = undefined;
    var num_a: [12]u8 = undefined;
    var num_b: [12]u8 = undefined;
    const kvs = try eventAttrs(e, &attrs, &num_a, &num_b);
    var attr_len: usize = 0;
    for (kvs) |kv| attr_len += delimLen(keyValueLen(kv.k, kv.v));
    const rec_len =
        9 + // time_unix_nano (fixed64, field 1)
        (1 + varintLen(sev.num)) + // severity_number (field 2)
        delimLen(sev.text.len) + // severity_text (field 3)
        delimLen(anyValueLen(body_txt)) + // body (field 5)
        attr_len + // attributes (field 6)
        9; // observed_time_unix_nano (fixed64, field 11)
    const scope_len = delimLen(rec_len);
    const resource_len = delimLen(serviceKvLen(e.name));
    const rl_len = delimLen(resource_len) + delimLen(scope_len);
    return delimLen(rl_len); // ExportLogsServiceRequest.resource_logs entry
}

/// Write one lifecycle event's resource_logs entry into `w`. Re-renders body +
/// attrs — deterministic, the same values eventRlLen sized.
fn writeEventRl(w: *Writer, e: frame.Lifecycle) error{TooLarge}!void {
    const sev = eventSev(e.ev);
    var body_scratch: [256]u8 = undefined;
    const body_txt = try renderEventBody(&body_scratch, e);
    var attrs: [2]EventAttr = undefined;
    var num_a: [12]u8 = undefined;
    var num_b: [12]u8 = undefined;
    const kvs = try eventAttrs(e, &attrs, &num_a, &num_b);
    var attr_len: usize = 0;
    for (kvs) |kv| attr_len += delimLen(keyValueLen(kv.k, kv.v));
    const rec_len = 9 + (1 + varintLen(sev.num)) + delimLen(sev.text.len) +
        delimLen(anyValueLen(body_txt)) + attr_len + 9;
    const scope_len = delimLen(rec_len);
    const resource_len = delimLen(serviceKvLen(e.name));
    const rl_len = delimLen(resource_len) + delimLen(scope_len);
    const ns = e.t_unix_ns;
    w.delim(1, rl_len); // resource_logs
    w.delim(1, resource_len); //   resource
    putServiceName(w, e.name); //     attributes (origin-prefixed)
    w.delim(2, scope_len); //   scope_logs
    w.delim(2, rec_len); //     log_records
    w.fixed64(1, ns); //       time_unix_nano
    w.uint(2, sev.num); //       severity_number
    w.string(3, sev.text); //       severity_text
    putAnyValue(w, 5, body_txt); //       body
    for (kvs) |kv| putKeyValue(w, 6, kv.k, kv.v); //       attributes
    w.fixed64(11, ns); //       observed_time_unix_nano
}

/// Encode one lifecycle event as an OTLP ExportLogsServiceRequest (one
/// resource_logs). Thin wrapper over the batch encoder so both share one code
/// path — a 1-event batch is byte-identical to the pre-batch single output.
pub fn buildOtlpEvent(e: frame.Lifecycle) error{TooLarge}![]const u8 {
    return buildOtlpEvents(&.{e});
}

/// Encode a batch of lifecycle events as ONE OTLP ExportLogsServiceRequest, one
/// resource_logs per event. Same two-pass sizing + ephemeral drop-the-rest
/// discipline as buildOtlpLogs: if the batch will not fit body_buf, encode as
/// many events as fit and drop the rest; only a first event too large alone
/// yields error.TooLarge (caller then drops the batch).
pub fn buildOtlpEvents(events: []const frame.Lifecycle) error{TooLarge}![]const u8 {
    // Pass 1: how many events fit, sizes innermost-first.
    var total: usize = 0;
    var nfit: usize = 0;
    for (events) |e| {
        const rl = eventRlLen(e) catch break; // un-renderable (never for capped names) → ship what we have
        if (total + rl > body_buf.len) break; // batch full → drop the rest (ephemeral tier)
        total += rl;
        nfit += 1;
    }
    if (nfit == 0) return error.TooLarge;

    // Pass 2: write the nfit events that fit.
    var w = Writer{ .buf = &body_buf };
    for (events[0..nfit]) |e| try writeEventRl(&w, e);
    std.debug.assert(w.pos == total); // sizing and writing must agree
    return body_buf[0..w.pos];
}

// ------------------------------------------------------- OTLP streamed logs
//
// Opt-in full worker-log streaming (P3). Each batched log line becomes ONE
// LogRecord, same nesting/encoding as buildOtlp/buildOtlpEvent: resource
// {service.name=<worker>, host.name, host.id, os.type} (the SAME identity as the
// worker's process.* metrics — and as photon-agent's host metrics, so photon
// lines a worker's logs up with its metrics and its node), scope_logs{log_records[one]} with body =
// the line text, severity from the frame's tier, and attribute log.iostream.
// One resource_logs entry per record: correct, and cheap enough at the bounded
// batch sizes here (see the arena/cap in drainPipe). Reuses the Writer and the
// putKeyValue/putAnyValue helpers verbatim — no new log_record layout.

/// One batched log line, resolved to slices that outlive the sizing/write passes
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
fn logSeverity(sev: u8) struct { num: u64, text: []const u8 } {
    return switch (sev) {
        1 => .{ .num = sev_warn, .text = "WARN" },
        2 => .{ .num = sev_error, .text = "ERROR" },
        else => .{ .num = sev_info, .text = "INFO" },
    };
}

fn ioStreamName(io: u8) []const u8 {
    return if (io == 1) "stderr" else "stdout";
}

/// Encoded bytes of the Tier-2 digest attributes for one record: the three int
/// KeyValues (all field 6) when this is a digest record (count > 0), or 0 for a
/// plain streamed line. ONE source of truth shared by pass 1 (logRlLen) and pass
/// 2 (putDigestAttrs) so the two-pass sizing can never drift.
fn digestAttrsLen(r: LogRecord) usize {
    if (r.count == 0) return 0;
    return delimLen(keyValueIntLen("mandor.count", r.count)) +
        delimLen(keyValueIntLen("mandor.first_ts", r.first_ns)) +
        delimLen(keyValueIntLen("mandor.last_ts", r.last_ns));
}

/// Write the Tier-2 digest attributes (count > 0) into the log_record's
/// attributes (field 6, same as log.iostream). No-op for a plain streamed line so
/// the streamed output is byte-identical. Writes exactly digestAttrsLen(r) bytes.
fn putDigestAttrs(w: *Writer, r: LogRecord) void {
    if (r.count == 0) return;
    putKeyValueInt(w, 6, "mandor.count", r.count);
    putKeyValueInt(w, 6, "mandor.first_ts", r.first_ns);
    putKeyValueInt(w, 6, "mandor.last_ts", r.last_ns);
}

/// Bytes of the resource_logs entry for one record (one resource per record).
fn logRlLen(r: LogRecord, host_name: []const u8, host_id: []const u8) usize {
    const sev = logSeverity(r.severity);
    var rec_len =
        9 + // time_unix_nano (fixed64, field 1)
        9 + // observed_time_unix_nano (fixed64, field 11)
        (1 + varintLen(sev.num)) + // severity_number (field 2)
        delimLen(sev.text.len) + // severity_text (field 3)
        delimLen(anyValueLen(r.line)) + // body (field 5)
        delimLen(keyValueLen("log.iostream", ioStreamName(r.iostream))); // attributes (field 6)
    // Curated Tier-2 digest: a digest record (count > 0) carries three int
    // attributes alongside log.iostream (all field 6). A plain streamed line
    // (count == 0) adds none — byte-identical to the pre-digest output. Sized
    // here in pass 1 and written in buildOtlpLogs pass 2 so `w.pos == total`.
    rec_len += digestAttrsLen(r);
    const scope_len = delimLen(rec_len); // ScopeLogs.log_records (field 2)
    const resource_len =
        delimLen(serviceKvLen(r.name)) +
        delimLen(keyValueLen("host.name", host_name)) +
        delimLen(keyValueLen("host.id", host_id)) +
        delimLen(keyValueLen("os.type", "linux"));
    const rl_len = delimLen(resource_len) + delimLen(scope_len);
    return delimLen(rl_len); // ExportLogsServiceRequest.resource_logs
}

/// Encode a batch of streamed log lines as one OTLP ExportLogsServiceRequest,
/// one resource_logs per record. Same two-pass sizing discipline as the metric
/// encoders: size innermost-first, and — because this is the lossy ephemeral
/// tier — if the whole batch will not fit body_buf, encode as many records as
/// fit and DROP the rest (counting them in `log_drops`) rather than refusing the
/// batch. Only a first record too large to fit alone yields error.TooLarge (the
/// caller then drops the batch). The frame decoder caps a line at 4095 bytes and
/// drainPipe's arena caps the batch, so in practice the whole batch always fits.
pub fn buildOtlpLogs(records: []const LogRecord, host_name: []const u8, host_id: []const u8) error{TooLarge}![]const u8 {
    // Pass 1: how many records fit, sizes innermost-first.
    var total: usize = 0;
    var nfit: usize = 0;
    for (records) |r| {
        const rl = logRlLen(r, host_name, host_id);
        if (total + rl > body_buf.len) break;
        total += rl;
        nfit += 1;
    }
    if (nfit == 0) return error.TooLarge; // not even one record fits
    if (nfit < records.len) log_drops +|= records.len - nfit; // ephemeral: drop the tail

    // Pass 2: write.
    var w = Writer{ .buf = &body_buf };
    for (records[0..nfit]) |r| {
        const sev = logSeverity(r.severity);
        var rec_len =
            9 +
            9 +
            (1 + varintLen(sev.num)) +
            delimLen(sev.text.len) +
            delimLen(anyValueLen(r.line)) +
            delimLen(keyValueLen("log.iostream", ioStreamName(r.iostream)));
        rec_len += digestAttrsLen(r); // digest ints (count > 0); 0 for a streamed line
        const scope_len = delimLen(rec_len);
        const resource_len =
            delimLen(serviceKvLen(r.name)) +
            delimLen(keyValueLen("host.name", host_name)) +
            delimLen(keyValueLen("host.id", host_id)) +
            delimLen(keyValueLen("os.type", "linux"));
        const rl_len = delimLen(resource_len) + delimLen(scope_len);

        w.delim(1, rl_len); // resource_logs
        w.delim(1, resource_len); //   resource
        putServiceName(&w, r.name); //     attributes (origin-prefixed)
        putKeyValue(&w, 1, "host.name", host_name); //     (SAME identity as the worker's metrics)
        putKeyValue(&w, 1, "host.id", host_id);
        putKeyValue(&w, 1, "os.type", "linux");
        w.delim(2, scope_len); //   scope_logs
        w.delim(2, rec_len); //     log_records
        w.fixed64(1, r.t_ns); //       time_unix_nano
        w.fixed64(11, r.t_ns); //       observed_time_unix_nano
        w.uint(2, sev.num); //       severity_number
        w.string(3, sev.text); //       severity_text
        putAnyValue(&w, 5, r.line); //       body
        putKeyValue(&w, 6, "log.iostream", ioStreamName(r.iostream)); // attributes
        putDigestAttrs(&w, r); //       mandor.count/.first_ts/.last_ts (digest only)
    }
    std.debug.assert(w.pos == total); // sizing and writing must agree
    return body_buf[0..w.pos];
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

fn post(host: u32, port: u16, path: []const u8, body: []const u8, token: []const u8) u8 {
    const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (posix.errno(rc) != .SUCCESS) {
        err("socket failed");
        return 1;
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
        return 1;
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
        return 1;
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
                return 1;
            },
            else => {
                err("send failed");
                return 1;
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
        return 1;
    }
    if (posix.errno(got) == .SUCCESS and got > 0) {
        const rslice = resp[0..@min(@as(usize, @intCast(got)), resp.len)];
        if (statusOk(rslice)) {
            // A 2xx from photon's OTLP receiver is a real delivery — UNLESS it is
            // an HTML page, which means the address is photon's web UI, not its
            // OTLP ingest port: the SPA catch-all 200s and the payload is
            // dropped. Treat that as NOT delivered (so the durable incident tier
            // keeps retrying and nothing is falsely marked shipped) and warn once.
            if (!looksLikeHtml(rslice)) return 0;
            if (!warned_html_endpoint) {
                warned_html_endpoint = true;
                err("photon answered 200 with an HTML page, not OTLP — the address is likely photon's web UI, not its OTLP ingest port (e.g. :4318). Nothing is being ingested. See docs/INTEGRATION-PHOTON.md");
            }
            return 1;
        }
        // Non-2xx: echo the status line. "did not accept the payload" alone gives
        // the operator nothing to act on, and the most likely cause is a receiver
        // that decodes OTLP protobuf only while mandor sends OTLP/JSON — which the
        // status plus docs/INTEGRATION-PHOTON.md makes diagnosable.
        const line = rslice[0..@min(rslice.len, 64)];
        const cut = std.mem.indexOfScalar(u8, line, '\r') orelse line.len;
        err("photon rejected the payload — see docs/INTEGRATION-PHOTON.md");
        err(line[0..cut]);
    } else {
        err("photon rejected the payload (no response) — see docs/INTEGRATION-PHOTON.md");
    }
    return 1;
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
/// How often an otherwise idle daemon wakes to rescan the spool. 5s, the cadence
/// the node sampler used to give the loop for free before it moved out.
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

const Shipped = struct {
    names: [ship_cap][ship_name_cap]u8 = undefined,
    lens: [ship_cap]u8 = undefined,
    /// Per-cycle mark for the sweep: reset to false, set true for every set
    /// entry still present on disk, then survivors are compacted down.
    present: [ship_cap]bool = undefined,
    n: usize = 0,

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
        if (name.len > ship_name_cap or self.n >= ship_cap) return;
        @memcpy(self.names[self.n][0..name.len], name);
        self.lens[self.n] = @intCast(name.len);
        self.present[self.n] = true;
        self.n += 1;
    }

    /// Drop entries not marked present this cycle (their files were pruned),
    /// keeping the set bounded to the on-disk spool.
    fn sweep(self: *Shipped) void {
        var w: usize = 0;
        var i: usize = 0;
        while (i < self.n) : (i += 1) {
            if (!self.present[i]) continue;
            if (w != i) {
                @memcpy(self.names[w][0..self.lens[i]], self.names[i][0..self.lens[i]]);
                self.lens[w] = self.lens[i];
            }
            w += 1;
        }
        self.n = w;
    }
};

/// Read one bundle, encode it, ship it. Returns true only on a 2xx.
fn shipOne(spool_dir: []const u8, name: []const u8, host: u32, port: u16, token: []const u8) bool {
    var path_buf: [640]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/incidents/{s}", .{ spool_dir, name }) catch return false;
    const bundle = readFile(path.ptr) catch return false;
    const body = buildOtlp(bundle) catch return false;
    return post(host, port, "/v1/logs", body, token) == 0;
}

/// Ship every spooled bundle not yet shipped, oldest first. Returns false if a
/// send failed (photon unreachable/rejecting) so the caller can re-resolve.
/// Never advances past a failed bundle: incidents are durable and retried.
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
        if (shipOne(spool_dir, name, host, port, token)) {
            shipped.add(name);
        } else {
            // photon is down or rejecting: stop this cycle (one bounded connect
            // rather than one per bundle), leave the rest for the next cycle.
            ok = false;
            break;
        }
    }
    shipped.sweep();
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
// overflow the arena, so the 64KB arena is the real bound and body_buf (320KB)
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

// Host identity for the `system.*` resource, read ONCE at daemon start (it does
// not change for the daemon's life) into these fixed buffers; the node-sample
// ship path (runDaemon) and the per-worker metric batch (drainPipe, host.name)
// both reuse the slices below, so neither re-reads /proc or allocates. Default
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
    const big = "y" ** 4000;
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
    const big = "y" ** 4000;
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
    const huge = "x" ** 250; // "worker " ++ huge ++ " started" > 256 → TooLarge
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

test "serviceKvLen agrees with the actual encoded service.name length" {
    // With a prefix set, serviceKvLen must equal keyValueLen for the JOINED value
    // (prefix ++ name). This is the mutation guard: drop `service_prefix.len` from
    // serviceKvLen and this fails directly, and every prefixed encoder's
    // `w.pos == total` assert traps too.
    setServicePrefix("t-");
    defer setServicePrefix("");
    try testing.expectEqual(keyValueLen("service.name", "t-api"), serviceKvLen("api"));

    // Default empty prefix: identical to the bare keyValueLen (byte-identical).
    setServicePrefix("");
    try testing.expectEqual(keyValueLen("service.name", "api"), serviceKvLen("api"));
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
    const long = "p" ** (service_prefix_cap + 10);
    setServicePrefix(long);
    defer setServicePrefix("");
    // Copied into the fixed BSS buffer, clamped — never overflows, never traps.
    try testing.expectEqual(@as(usize, service_prefix_cap), service_prefix.len);
}
