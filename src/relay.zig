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
const hostmetrics = @import("hostmetrics.zig");

/// Wall-clock ceiling on each blocking socket call. Generous enough that a
/// merely slow collector still succeeds, short enough that a hung one cannot
/// strand a process for the life of the container.
const relay_timeout_s = 10;

var file_buf: [256 * 1024]u8 = undefined;
var body_buf: [320 * 1024]u8 = undefined;
var req_buf: [321 * 1024]u8 = undefined;

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
    const token = spawner.findEnv(environ, "PHOTON_TOKEN") orelse "";
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
        delimLen(keyValueLen("service.name", name_txt)) +
        delimLen(keyValueLen("service.version", release_txt));
    const rl_len = delimLen(resource_len) + delimLen(scope_len);
    const total = delimLen(rl_len); // ExportLogsServiceRequest.resource_logs
    if (total > body_buf.len) return error.TooLarge;

    // Pass 2: write.
    var w = Writer{ .buf = &body_buf };
    w.delim(1, rl_len); // resource_logs
    w.delim(1, resource_len); //   resource
    putKeyValue(&w, 1, "service.name", name_txt); //     attributes
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
    // Pass 1: sizes, innermost first.
    var total: usize = 0;
    for (samples) |s| {
        var scope_len: usize = 0;
        for (gauge_metrics) |g| scope_len += delimLen(gaugeMetricLen(g.name, g.unit));
        scope_len += delimLen(sumMetricLen(restart_metric_name, restart_metric_unit));

        const resource_len = delimLen(keyValueLen("service.name", s.name)) +
            delimLen(keyValueLen("host.name", host_name));
        const rm_len = delimLen(resource_len) + delimLen(scope_len);
        total += delimLen(rm_len);
    }
    if (total > body_buf.len) return error.TooLarge;

    // Pass 2: write.
    var w = Writer{ .buf = &body_buf };
    for (samples) |s| {
        var scope_len: usize = 0;
        for (gauge_metrics) |g| scope_len += delimLen(gaugeMetricLen(g.name, g.unit));
        scope_len += delimLen(sumMetricLen(restart_metric_name, restart_metric_unit));
        const resource_len = delimLen(keyValueLen("service.name", s.name)) +
            delimLen(keyValueLen("host.name", host_name));
        const rm_len = delimLen(resource_len) + delimLen(scope_len);

        w.delim(1, rm_len); // resource_metrics
        w.delim(1, resource_len); //   resource
        putKeyValue(&w, 1, "service.name", s.name); //     attributes
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

/// A ratio in [0,1] as f64 bits (as_double). Denominator 0 -> 0.0 (guard the
/// divide). Clamped to [0,1] so a slightly inconsistent /proc delta cannot emit
/// a nonsense utilization.
fn ratioBits(num: u64, den: u64) u64 {
    if (den == 0) return @bitCast(@as(f64, 0.0));
    var r = @as(f64, @floatFromInt(num)) / @as(f64, @floatFromInt(den));
    if (r < 0.0) r = 0.0;
    if (r > 1.0) r = 1.0;
    return @bitCast(r);
}

/// Encode one node HostSample as an OTLP ExportMetricsServiceRequest holding a
/// single host-scoped ResourceMetrics. Same two-pass sizing discipline as
/// buildOtlpMetrics: size innermost-first, refuse an oversize body, write, then
/// assert the two passes agree. Timestamp is taken here (the frame carries no
/// time), matching buildOtlp's clock read.
pub fn buildOtlpHostMetrics(h: frame.Host, host_name: []const u8, host_id: []const u8) error{TooLarge}![]const u8 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    const ns: u64 = @as(u64, @intCast(ts.sec)) *| 1_000_000_000 +| @as(u64, @intCast(ts.nsec));

    // Derived ratio/load values, as_double bit patterns.
    const cpu_util_bits = ratioBits(h.cpu_total_delta -| h.cpu_idle_delta, h.cpu_total_delta);
    const mem_util_bits = ratioBits(h.mem_used, h.mem_total);
    const fs_util_bits = ratioBits(h.fs_used, h.fs_total);
    const load1_bits: u64 = @bitCast(@as(f64, @floatFromInt(h.load1_milli)) / 1000.0);

    // Datapoint attribute sets.
    const a_cpu_total = [_]HAttr{.{ .k = "cpu", .v = "total" }};
    const a_state_used = [_]HAttr{.{ .k = "state", .v = "used" }};
    const a_state_free = [_]HAttr{.{ .k = "state", .v = "free" }};
    const a_dir_rx = [_]HAttr{.{ .k = "direction", .v = "receive" }};
    const a_dir_tx = [_]HAttr{.{ .k = "direction", .v = "transmit" }};
    const a_fs_used = [_]HAttr{ .{ .k = "mountpoint", .v = "/" }, .{ .k = "state", .v = "used" } };
    const a_fs_root = [_]HAttr{.{ .k = "mountpoint", .v = "/" }};
    const a_none = [_]HAttr{};

    // Datapoints (one array per metric so the slices outlive the sizing/write
    // passes below).
    const dp_cpu_util = [_]HDp{.{ .value_bits = cpu_util_bits, .is_double = true, .attrs = &a_cpu_total }};
    const dp_cpu_count = [_]HDp{.{ .value_bits = h.logical_cpus, .is_double = false, .attrs = &a_none }};
    const dp_load = [_]HDp{.{ .value_bits = load1_bits, .is_double = true, .attrs = &a_none }};
    const dp_mem = [_]HDp{
        .{ .value_bits = h.mem_used, .is_double = false, .attrs = &a_state_used },
        .{ .value_bits = h.mem_total -| h.mem_used, .is_double = false, .attrs = &a_state_free },
    };
    const dp_mem_limit = [_]HDp{.{ .value_bits = h.mem_total, .is_double = false, .attrs = &a_none }};
    const dp_mem_util = [_]HDp{.{ .value_bits = mem_util_bits, .is_double = true, .attrs = &a_none }};
    const dp_net = [_]HDp{
        .{ .value_bits = h.net_rx, .is_double = false, .attrs = &a_dir_rx },
        .{ .value_bits = h.net_tx, .is_double = false, .attrs = &a_dir_tx },
    };
    const dp_fs_usage = [_]HDp{.{ .value_bits = h.fs_used, .is_double = false, .attrs = &a_fs_used }};
    const dp_fs_util = [_]HDp{.{ .value_bits = fs_util_bits, .is_double = true, .attrs = &a_fs_root }};

    const metrics = [_]HMetric{
        .{ .name = "system.cpu.utilization", .unit = "1", .kind = .gauge, .dps = &dp_cpu_util },
        .{ .name = "system.cpu.logical.count", .unit = "{cpu}", .kind = .gauge, .dps = &dp_cpu_count },
        .{ .name = "system.cpu.load_average.1m", .unit = "1", .kind = .gauge, .dps = &dp_load },
        .{ .name = "system.memory.usage", .unit = "By", .kind = .gauge, .dps = &dp_mem },
        .{ .name = "system.memory.limit", .unit = "By", .kind = .gauge, .dps = &dp_mem_limit },
        .{ .name = "system.memory.utilization", .unit = "1", .kind = .gauge, .dps = &dp_mem_util },
        .{ .name = "system.network.io", .unit = "By", .kind = .sum, .dps = &dp_net },
        .{ .name = "system.filesystem.usage", .unit = "By", .kind = .gauge, .dps = &dp_fs_usage },
        .{ .name = "system.filesystem.utilization", .unit = "1", .kind = .gauge, .dps = &dp_fs_util },
    };

    // Pass 1: sizes, innermost first.
    var scope_len: usize = 0;
    for (metrics) |m| scope_len += delimLen(hMetricLen(m));
    const resource_len =
        delimLen(keyValueLen("host.name", host_name)) +
        delimLen(keyValueLen("host.id", host_id)) +
        delimLen(keyValueLen("os.type", "linux"));
    const rm_len = delimLen(resource_len) + delimLen(scope_len);
    const total = delimLen(rm_len); // ExportMetricsServiceRequest.resource_metrics
    if (total > body_buf.len) return error.TooLarge;

    // Pass 2: write.
    var w = Writer{ .buf = &body_buf };
    w.delim(1, rm_len); // resource_metrics
    w.delim(1, resource_len); //   resource
    putKeyValue(&w, 1, "host.name", host_name); //     attributes
    putKeyValue(&w, 1, "host.id", host_id);
    putKeyValue(&w, 1, "os.type", "linux");
    w.delim(2, scope_len); //   scope_metrics
    for (metrics) |m| {
        w.delim(2, hMetricLen(m)); //   metrics (Metric)
        putHMetric(&w, m, ns);
    }
    std.debug.assert(w.pos == total); // sizing and writing must agree
    return body_buf[0..w.pos];
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

/// Encode one lifecycle event as an OTLP ExportLogsServiceRequest holding a
/// single LogRecord. Two-pass sizing identical in shape to buildOtlp.
pub fn buildOtlpEvent(e: frame.Lifecycle) error{TooLarge}![]const u8 {
    const sev_num: u64 = switch (e.ev) {
        .started, .exited_ok, .health_up => sev_info,
        .restarting, .health_down => sev_warn,
        .exited_err, .oom => sev_error,
    };
    const sev_text: []const u8 = switch (e.ev) {
        .started, .exited_ok, .health_up => "INFO",
        .restarting, .health_down => "WARN",
        .exited_err, .oom => "ERROR",
    };

    var body_scratch: [256]u8 = undefined;
    const body_txt = try renderEventBody(&body_scratch, e);

    // Numeric context as string attributes (photon reads string attrs), sized
    // for an i32/u32 with sign. The set depends on the event kind; both passes
    // iterate the same slice so sizing and writing cannot diverge.
    var attrs: [2]EventAttr = undefined;
    var n_attrs: usize = 0;
    var num_a: [12]u8 = undefined;
    var num_b: [12]u8 = undefined;
    switch (e.ev) {
        .exited_err, .oom => {
            attrs[n_attrs] = .{ .k = "exit.code", .v = std.fmt.bufPrint(&num_a, "{d}", .{e.code}) catch return error.TooLarge };
            n_attrs += 1;
        },
        .restarting => {
            attrs[n_attrs] = .{ .k = "backoff.ms", .v = std.fmt.bufPrint(&num_a, "{d}", .{e.backoff_ms}) catch return error.TooLarge };
            n_attrs += 1;
            attrs[n_attrs] = .{ .k = "restart.count", .v = std.fmt.bufPrint(&num_b, "{d}", .{e.restarts}) catch return error.TooLarge };
            n_attrs += 1;
        },
        else => {},
    }
    const kvs = attrs[0..n_attrs];

    const ns = e.t_unix_ns;

    // Pass 1: sizes, innermost first.
    var attr_len: usize = 0;
    for (kvs) |kv| attr_len += delimLen(keyValueLen(kv.k, kv.v));
    const rec_len =
        9 + // time_unix_nano (fixed64, field 1)
        (1 + varintLen(sev_num)) + // severity_number (field 2)
        delimLen(sev_text.len) + // severity_text (field 3)
        delimLen(anyValueLen(body_txt)) + // body (field 5)
        attr_len + // attributes (field 6)
        9; // observed_time_unix_nano (fixed64, field 11)
    const scope_len = delimLen(rec_len); // ScopeLogs.log_records (field 2)
    const resource_len = delimLen(keyValueLen("service.name", e.name));
    const rl_len = delimLen(resource_len) + delimLen(scope_len);
    const total = delimLen(rl_len); // ExportLogsServiceRequest.resource_logs
    if (total > body_buf.len) return error.TooLarge;

    // Pass 2: write.
    var w = Writer{ .buf = &body_buf };
    w.delim(1, rl_len); // resource_logs
    w.delim(1, resource_len); //   resource
    putKeyValue(&w, 1, "service.name", e.name); //     attributes
    w.delim(2, scope_len); //   scope_logs
    w.delim(2, rec_len); //     log_records
    w.fixed64(1, ns); //       time_unix_nano
    w.uint(2, sev_num); //       severity_number
    w.string(3, sev_text); //       severity_text
    putAnyValue(&w, 5, body_txt); //       body
    for (kvs) |kv| putKeyValue(&w, 6, kv.k, kv.v); //       attributes
    w.fixed64(11, ns); //       observed_time_unix_nano

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
    var resp: [128]u8 = undefined;
    const got = linux.read(fd, &resp, resp.len);
    if (posix.errno(got) == .AGAIN) {
        err("photon accepted the connection but never answered (timed out) — see docs/INTEGRATION-PHOTON.md");
        return 1;
    }
    if (posix.errno(got) == .SUCCESS and got > 0 and
        statusOk(resp[0..@min(@as(usize, @intCast(got)), resp.len)])) return 0;
    // Echo the status line: "did not accept the payload" alone gives the
    // operator nothing to act on, and the most likely cause is a receiver that
    // decodes OTLP protobuf only while mandor sends OTLP/JSON — which the
    // status plus docs/INTEGRATION-PHOTON.md makes diagnosable.
    if (posix.errno(got) == .SUCCESS and got > 0) {
        const line = resp[0..@min(@as(usize, @intCast(got)), 64)];
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

/// Seconds between cycles. The pipe is drained fully each cycle, so this only
/// bounds shutdown/EOF latency and the spool retry cadence, not throughput.
const daemon_cycle_s = 1;

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

// Host identity for the `system.*` resource, read ONCE at daemon start (it does
// not change for the daemon's life) into these fixed buffers; drainPipe ships
// host samples with the slices below, so the drain path never re-reads /proc or
// allocates. Default to "unknown" until runDaemon populates them.
var daemon_host_name_buf: [256]u8 = undefined;
var daemon_host_id_buf: [256]u8 = undefined;
var daemon_host_name: []const u8 = "unknown";
var daemon_host_id: []const u8 = "unknown";

/// Drain everything currently readable from the pipe, ship it best-effort, and
/// report whether EOF (parent gone) was seen. Metric samples are batched into a
/// single OTLP request; lifecycle events post one LogRecord each. Any encode or
/// send failure drops the record — routine telemetry is ephemeral.
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
                if (buildOtlpEvent(e)) |b| {
                    _ = post(host, port, "/v1/logs", b, token);
                } else |_| {
                    // too large to encode → drop (routine telemetry is ephemeral)
                }
            },
            // Node host sample → one host-scoped ResourceMetrics on /v1/metrics.
            // Same best-effort shape as lifecycle_event: build inline into
            // body_buf, post, drop on any encode failure. daemon_host_name/id
            // were read once at daemon start.
            .host_sample => |h| {
                if (buildOtlpHostMetrics(h, daemon_host_name, daemon_host_id)) |b| {
                    _ = post(host, port, "/v1/metrics", b, token);
                } else |_| {
                    // too large to encode → drop (routine telemetry is ephemeral)
                }
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
    return eof;
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
    environ: [:null]const ?[*:0]const u8,
) u8 {
    // Resolve once up front; re-resolved on a send failure below because photon
    // may restart with a new IP under compose. A literal IP short-circuits with
    // no network (resolve.zig), so re-resolving is free in that case.
    var hp = resolve.resolve(endpoint) orelse {
        err("bad photon endpoint (want ip:port)");
        return 2;
    };
    const token = spawner.findEnv(environ, "PHOTON_TOKEN") orelse "";

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

    // Host identity for the system.* resource attributes: read once here (it is
    // stable for the daemon's life) so drainPipe's ship path never re-reads /proc.
    daemon_host_name = hostmetrics.hostName(&daemon_host_name_buf);
    daemon_host_id = hostmetrics.hostId(&daemon_host_id_buf);

    var shipped: Shipped = .{};

    while (true) {
        // Spool first: priority, durable, retried on failure.
        if (!shipSpool(&shipped, spool_dir, hp.host, hp.port, token)) {
            if (resolve.resolve(endpoint)) |new_hp| hp = new_hp;
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

        var ts = linux.timespec{ .sec = daemon_cycle_s, .nsec = 0 };
        _ = linux.nanosleep(&ts, &ts);
    }
}

const testing = std.testing;

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

test "buildOtlpHostMetrics emits a host resource + system.* metrics photon can walk" {
    const h = frame.Host{
        .mem_total = 1000,
        .mem_used = 400,
        .cpu_total_delta = 100,
        .cpu_idle_delta = 25, // utilization = 0.75
        .logical_cpus = 8,
        .load1_milli = 1250,
        .net_rx = 5000,
        .net_tx = 7000,
        .fs_total = 2000,
        .fs_used = 500,
    };
    const body = try buildOtlpHostMetrics(h, "node-1", "abc123");

    // Resource identity: host.name first, then host.id, then os.type=linux.
    const rm = Fields.get(body, 1).?.bytes; // resource_metrics
    const res = Fields.get(rm, 1).?.bytes; // resource
    var ra = Fields{ .b = res };
    const r1 = ra.next().?.bytes;
    const r2 = ra.next().?.bytes;
    const r3 = ra.next().?.bytes;
    try testing.expectEqualStrings("host.name", Fields.get(r1, 1).?.bytes);
    try testing.expectEqualStrings("node-1", avStr(Fields.get(r1, 2).?.bytes));
    try testing.expectEqualStrings("host.id", Fields.get(r2, 1).?.bytes);
    try testing.expectEqualStrings("abc123", avStr(Fields.get(r2, 2).?.bytes));
    try testing.expectEqualStrings("os.type", Fields.get(r3, 1).?.bytes);
    try testing.expectEqualStrings("linux", avStr(Fields.get(r3, 2).?.bytes));

    // Find metrics by name (a rename would leave these empty and fail below).
    const sm = Fields.get(rm, 2).?.bytes; // scope_metrics
    var mit = Fields{ .b = sm };
    var mem_usage: []const u8 = &.{};
    var net_io: []const u8 = &.{};
    var cpu_util: []const u8 = &.{};
    while (mit.next()) |f| {
        if (f.num != 2) continue; // Metric
        const name = Fields.get(f.bytes, 1).?.bytes;
        if (std.mem.eql(u8, name, "system.memory.usage")) mem_usage = f.bytes;
        if (std.mem.eql(u8, name, "system.network.io")) net_io = f.bytes;
        if (std.mem.eql(u8, name, "system.cpu.utilization")) cpu_util = f.bytes;
    }
    try testing.expect(mem_usage.len > 0);
    try testing.expect(net_io.len > 0);
    try testing.expect(cpu_util.len > 0);

    // system.memory.usage is a Gauge; its first datapoint is state=used, as_int
    // = mem_used. (Dropping the datapoint attr breaks the state assertion.)
    const gauge = Fields.get(mem_usage, 5).?.bytes;
    var gdps = Fields{ .b = gauge };
    const used_dp = gdps.next().?.bytes; // data_points[0]
    const used_kv = Fields.get(used_dp, 7).?.bytes; // NumberDataPoint.attributes
    try testing.expectEqualStrings("state", Fields.get(used_kv, 1).?.bytes);
    try testing.expectEqualStrings("used", avStr(Fields.get(used_kv, 2).?.bytes));
    try testing.expectEqual(@as(u64, 400), Fields.get(used_dp, 6).?.int); // as_int
    // second datapoint is state=free, mem_total-mem_used.
    const free_dp = gdps.next().?.bytes;
    const free_kv = Fields.get(free_dp, 7).?.bytes;
    try testing.expectEqualStrings("free", avStr(Fields.get(free_kv, 2).?.bytes));
    try testing.expectEqual(@as(u64, 600), Fields.get(free_dp, 6).?.int);

    // system.cpu.utilization carries an as_double (field 4), not as_int; the
    // bits decode to 0.75.
    const cpu_gauge = Fields.get(cpu_util, 5).?.bytes;
    const cpu_dp = Fields.get(cpu_gauge, 1).?.bytes;
    try testing.expect(Fields.get(cpu_dp, 6) == null); // no as_int
    const util: f64 = @bitCast(Fields.get(cpu_dp, 4).?.int); // as_double bits
    try testing.expectApproxEqAbs(@as(f64, 0.75), util, 1e-9);

    // system.network.io is a Sum (field 7, not a Gauge), monotonic cumulative,
    // and its first datapoint has a direction attribute.
    try testing.expect(Fields.get(net_io, 5) == null); // not a gauge
    const sum = Fields.get(net_io, 7).?.bytes;
    try testing.expectEqual(@as(u64, 2), Fields.get(sum, 2).?.int); // CUMULATIVE
    try testing.expectEqual(@as(u64, 1), Fields.get(sum, 3).?.int); // is_monotonic
    var sdps = Fields{ .b = sum };
    var first_sdp: []const u8 = &.{};
    while (sdps.next()) |f| {
        if (f.num == 1) {
            first_sdp = f.bytes;
            break;
        }
    }
    const dir_kv = Fields.get(first_sdp, 7).?.bytes; // NumberDataPoint.attributes
    try testing.expectEqualStrings("direction", Fields.get(dir_kv, 1).?.bytes);
    try testing.expectEqualStrings("receive", avStr(Fields.get(dir_kv, 2).?.bytes));
    try testing.expectEqual(@as(u64, 5000), Fields.get(first_sdp, 6).?.int); // net_rx
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
