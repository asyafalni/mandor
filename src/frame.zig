//! The compact pipe wire format shared by the supervisor core (writer) and the
//! relay daemon (reader). Pure — NO syscalls, no allocation, no panic. One
//! responsibility: framing mandor's internal telemetry records (metric samples,
//! lifecycle events, and opt-in streamed log lines) into bytes and back.
//!
//! This is mandor's own form, NOT OTLP: the daemon re-encodes these into OTLP
//! protobuf before shipping. Keeping the pipe format tiny and fixed keeps the
//! hot-path writer allocation-free and its decode side total (a corrupt or
//! partial frame yields `null`, never a trap).
//!
//! Frame = [u8 kind][u16 len LE][payload]. Little-endian throughout. Worker
//! names are capped at 255 bytes (one length byte).

const std = @import("std");

pub const Kind = enum(u8) { metric_sample = 1, lifecycle_event = 2, log_line = 3, digest_entry = 4 };

/// Compact fixed payload — mandor's internal form, NOT OTLP. `name` is a slice
/// into caller-owned memory at encode time; `decode` copies it into caller
/// scratch so the returned record borrows the scratch, not the input buffer.
pub const MetricSample = struct {
    name: []const u8, // worker name
    rss_kb: u64,
    cpu_pct: u16,
    fds: u16,
    threads: u16,
    restarts: u32,
    t_unix_ns: u64,
};

pub const Event = enum(u8) { started, exited_ok, exited_err, restarting, oom, health_up, health_down };

pub const Lifecycle = struct {
    name: []const u8,
    ev: Event,
    code: i32 = 0, // exit code or signal number, per ev
    backoff_ms: u32 = 0,
    restarts: u32 = 0,
    t_unix_ns: u64,
};

/// Opt-in full worker-log streaming (default off). Carries the worker name
/// (for service.name), which stream it came from, a severity tier, a timestamp,
/// and the line bytes. `name` is copied into caller scratch by `decode`; `line`
/// borrows the decode input buffer (see `decode`).
pub const LogLine = struct {
    name: []const u8, // worker name (<= name_cap)
    iostream: u8, // 0 = stdout, 1 = stderr
    severity: u8, // 0 = info, 1 = warn, 2 = error
    t_unix_ns: u64,
    line: []const u8, // captured line bytes (<= line_cap)
};

/// Curated Tier-2 warn/error digest (default on when `photon=`). One entry per
/// signature: the worker name (for service.name), a severity tier, the
/// deduplicated occurrence `count`, the first/last occurrence timestamps of the
/// window, and one sample line. Emitted low-rate (per window, NOT per line), so
/// this is the curated tier — never routed through the streaming shed gate.
/// `name` is copied into caller scratch by `decode`; `sample` borrows the decode
/// input buffer (same contract as `LogLine.line`).
pub const DigestEntry = struct {
    name: []const u8, // worker name (<= name_cap)
    severity: u8, // 0 = info, 1 = warn, 2 = error
    count: u64, // deduplicated occurrences this window
    first_unix_ns: u64, // first occurrence in the window
    last_unix_ns: u64, // last occurrence in the window
    sample: []const u8, // one representative line (<= line_cap)
};

pub const Decoded = union(Kind) { metric_sample: MetricSample, lifecycle_event: Lifecycle, log_line: LogLine, digest_entry: DigestEntry };

/// Fixed bytes after the name in each payload. Kept as named constants so the
/// encoder's sizing and the decoder's bounds check cannot drift apart.
const metric_fixed = 8 + 2 + 2 + 2 + 4 + 8; // rss,cpu,fds,threads,restarts,t_ns
const lifecycle_fixed = 1 + 4 + 4 + 4 + 8; // ev,code,backoff,restarts,t_ns
const logline_fixed = 1 + 1 + 8; // iostream,severity,t_ns (the line adds a u16 len + bytes)
const digest_fixed = 1 + 8 + 8 + 8; // severity,count,first_ns,last_ns (the sample adds a u16 len + bytes)

const header = 3; // [u8 kind][u16 len]
const name_cap = 255; // one length byte
/// Mirrors capture.max_line (4095). Kept local so frame.zig stays a pure,
/// dependency-free module (like config.zig mirroring spawner's caps). A longer
/// line is refused by encodeLog; capture never produces one, so it cannot occur.
const line_cap = 4095; // fits a u16 length field

/// Encode one metric sample into `out`; returns the framed slice or
/// `error.Overflow` if the name is over 255 bytes or the frame will not fit.
pub fn encodeMetric(out: []u8, s: MetricSample) error{Overflow}![]const u8 {
    if (s.name.len > name_cap) return error.Overflow;
    const nl: u8 = @intCast(s.name.len);
    const payload_len = 1 + @as(usize, nl) + metric_fixed;
    const total = header + payload_len;
    if (total > out.len) return error.Overflow;

    out[0] = @intFromEnum(Kind.metric_sample);
    std.mem.writeInt(u16, out[1..][0..2], @intCast(payload_len), .little);
    var p: usize = header;
    out[p] = nl;
    p += 1;
    @memcpy(out[p..][0..nl], s.name);
    p += nl;
    std.mem.writeInt(u64, out[p..][0..8], s.rss_kb, .little);
    p += 8;
    std.mem.writeInt(u16, out[p..][0..2], s.cpu_pct, .little);
    p += 2;
    std.mem.writeInt(u16, out[p..][0..2], s.fds, .little);
    p += 2;
    std.mem.writeInt(u16, out[p..][0..2], s.threads, .little);
    p += 2;
    std.mem.writeInt(u32, out[p..][0..4], s.restarts, .little);
    p += 4;
    std.mem.writeInt(u64, out[p..][0..8], s.t_unix_ns, .little);
    p += 8;
    return out[0..total];
}

/// Encode one lifecycle event into `out`; returns the framed slice or
/// `error.Overflow` if the name is over 255 bytes or the frame will not fit.
pub fn encodeLifecycle(out: []u8, e: Lifecycle) error{Overflow}![]const u8 {
    if (e.name.len > name_cap) return error.Overflow;
    const nl: u8 = @intCast(e.name.len);
    const payload_len = 1 + @as(usize, nl) + lifecycle_fixed;
    const total = header + payload_len;
    if (total > out.len) return error.Overflow;

    out[0] = @intFromEnum(Kind.lifecycle_event);
    std.mem.writeInt(u16, out[1..][0..2], @intCast(payload_len), .little);
    var p: usize = header;
    out[p] = nl;
    p += 1;
    @memcpy(out[p..][0..nl], e.name);
    p += nl;
    out[p] = @intFromEnum(e.ev);
    p += 1;
    std.mem.writeInt(i32, out[p..][0..4], e.code, .little);
    p += 4;
    std.mem.writeInt(u32, out[p..][0..4], e.backoff_ms, .little);
    p += 4;
    std.mem.writeInt(u32, out[p..][0..4], e.restarts, .little);
    p += 4;
    std.mem.writeInt(u64, out[p..][0..8], e.t_unix_ns, .little);
    p += 8;
    return out[0..total];
}

/// Encode one streamed log line into `out`; returns the framed slice or
/// `error.Overflow` if the name is over 255 bytes, the line is over `line_cap`,
/// or the frame will not fit `out`. Layout: name (len byte + bytes), iostream,
/// severity, t_ns, then a u16 line length + the line bytes.
pub fn encodeLog(out: []u8, l: LogLine) error{Overflow}![]const u8 {
    if (l.name.len > name_cap) return error.Overflow;
    if (l.line.len > line_cap) return error.Overflow;
    const nl: u8 = @intCast(l.name.len);
    const ll: u16 = @intCast(l.line.len);
    const payload_len = 1 + @as(usize, nl) + logline_fixed + 2 + @as(usize, ll);
    const total = header + payload_len;
    if (total > out.len) return error.Overflow;

    out[0] = @intFromEnum(Kind.log_line);
    std.mem.writeInt(u16, out[1..][0..2], @intCast(payload_len), .little);
    var p: usize = header;
    out[p] = nl;
    p += 1;
    @memcpy(out[p..][0..nl], l.name);
    p += nl;
    out[p] = l.iostream;
    p += 1;
    out[p] = l.severity;
    p += 1;
    std.mem.writeInt(u64, out[p..][0..8], l.t_unix_ns, .little);
    p += 8;
    std.mem.writeInt(u16, out[p..][0..2], ll, .little);
    p += 2;
    @memcpy(out[p..][0..ll], l.line);
    p += ll;
    return out[0..total];
}

/// Encode one curated digest entry into `out`; returns the framed slice or
/// `error.Overflow` if the name is over 255 bytes, the sample is over `line_cap`,
/// or the frame will not fit `out`. Layout mirrors encodeLog: name (len byte +
/// bytes), severity, count, first_unix_ns, last_unix_ns, then a u16 sample length
/// + the sample bytes.
pub fn encodeDigest(out: []u8, d: DigestEntry) error{Overflow}![]const u8 {
    if (d.name.len > name_cap) return error.Overflow;
    if (d.sample.len > line_cap) return error.Overflow;
    const nl: u8 = @intCast(d.name.len);
    const sl: u16 = @intCast(d.sample.len);
    const payload_len = 1 + @as(usize, nl) + digest_fixed + 2 + @as(usize, sl);
    const total = header + payload_len;
    if (total > out.len) return error.Overflow;

    out[0] = @intFromEnum(Kind.digest_entry);
    std.mem.writeInt(u16, out[1..][0..2], @intCast(payload_len), .little);
    var p: usize = header;
    out[p] = nl;
    p += 1;
    @memcpy(out[p..][0..nl], d.name);
    p += nl;
    out[p] = d.severity;
    p += 1;
    std.mem.writeInt(u64, out[p..][0..8], d.count, .little);
    p += 8;
    std.mem.writeInt(u64, out[p..][0..8], d.first_unix_ns, .little);
    p += 8;
    std.mem.writeInt(u64, out[p..][0..8], d.last_unix_ns, .little);
    p += 8;
    std.mem.writeInt(u16, out[p..][0..2], sl, .little);
    p += 2;
    @memcpy(out[p..][0..sl], d.sample);
    p += sl;
    return out[0..total];
}

/// Decode one frame from the front of `buf`. Returns the record (with its name
/// copied into `name_scratch`) and the number of bytes consumed, or `null` if
/// `buf` holds less than one whole frame, the kind/event byte is unknown, the
/// payload length disagrees with its own name length, or the name will not fit
/// in `name_scratch`. Never traps — a garbage byte on the pipe is a dropped
/// frame, not a dead daemon.
pub fn decode(buf: []const u8, name_scratch: []u8) ?struct { rec: Decoded, used: usize } {
    if (buf.len < header) return null;
    const len = std.mem.readInt(u16, buf[1..][0..2], .little);
    const total = header + @as(usize, len);
    if (buf.len < total) return null;
    const payload = buf[header..total];

    const kind: Kind = switch (buf[0]) {
        @intFromEnum(Kind.metric_sample) => .metric_sample,
        @intFromEnum(Kind.lifecycle_event) => .lifecycle_event,
        @intFromEnum(Kind.log_line) => .log_line,
        @intFromEnum(Kind.digest_entry) => .digest_entry,
        else => return null,
    };

    if (payload.len < 1) return null;
    const nl = payload[0];
    if (nl > name_scratch.len) return null;

    switch (kind) {
        .metric_sample => {
            if (payload.len < 1 + @as(usize, nl) + metric_fixed) return null;
            @memcpy(name_scratch[0..nl], payload[1..][0..nl]);
            var p: usize = 1 + @as(usize, nl);
            const rss = std.mem.readInt(u64, payload[p..][0..8], .little);
            p += 8;
            const cpu = std.mem.readInt(u16, payload[p..][0..2], .little);
            p += 2;
            const fds = std.mem.readInt(u16, payload[p..][0..2], .little);
            p += 2;
            const threads = std.mem.readInt(u16, payload[p..][0..2], .little);
            p += 2;
            const restarts = std.mem.readInt(u32, payload[p..][0..4], .little);
            p += 4;
            const t_ns = std.mem.readInt(u64, payload[p..][0..8], .little);
            return .{ .rec = .{ .metric_sample = .{
                .name = name_scratch[0..nl],
                .rss_kb = rss,
                .cpu_pct = cpu,
                .fds = fds,
                .threads = threads,
                .restarts = restarts,
                .t_unix_ns = t_ns,
            } }, .used = total };
        },
        .lifecycle_event => {
            if (payload.len < 1 + @as(usize, nl) + lifecycle_fixed) return null;
            @memcpy(name_scratch[0..nl], payload[1..][0..nl]);
            var p: usize = 1 + @as(usize, nl);
            const ev: Event = switch (payload[p]) {
                @intFromEnum(Event.started) => .started,
                @intFromEnum(Event.exited_ok) => .exited_ok,
                @intFromEnum(Event.exited_err) => .exited_err,
                @intFromEnum(Event.restarting) => .restarting,
                @intFromEnum(Event.oom) => .oom,
                @intFromEnum(Event.health_up) => .health_up,
                @intFromEnum(Event.health_down) => .health_down,
                else => return null,
            };
            p += 1;
            const code = std.mem.readInt(i32, payload[p..][0..4], .little);
            p += 4;
            const backoff = std.mem.readInt(u32, payload[p..][0..4], .little);
            p += 4;
            const restarts = std.mem.readInt(u32, payload[p..][0..4], .little);
            p += 4;
            const t_ns = std.mem.readInt(u64, payload[p..][0..8], .little);
            return .{ .rec = .{ .lifecycle_event = .{
                .name = name_scratch[0..nl],
                .ev = ev,
                .code = code,
                .backoff_ms = backoff,
                .restarts = restarts,
                .t_unix_ns = t_ns,
            } }, .used = total };
        },
        .log_line => {
            // name_len(1) + name + iostream(1) + severity(1) + t_ns(8) + line_len(2)
            if (payload.len < 1 + @as(usize, nl) + logline_fixed + 2) return null;
            @memcpy(name_scratch[0..nl], payload[1..][0..nl]);
            var p: usize = 1 + @as(usize, nl);
            const iostream = payload[p];
            p += 1;
            const severity = payload[p];
            p += 1;
            const t_ns = std.mem.readInt(u64, payload[p..][0..8], .little);
            p += 8;
            const ll = std.mem.readInt(u16, payload[p..][0..2], .little);
            p += 2;
            // The declared line length must fit the remaining payload. Dropping
            // this check would let the slice below run past the buffer end (a
            // trap in safe modes) on a corrupt or truncated frame — instead we
            // return null, exactly like the name/fixed-field checks above.
            if (payload.len < p + @as(usize, ll)) return null;
            return .{
                .rec = .{
                    .log_line = .{
                        .name = name_scratch[0..nl],
                        .iostream = iostream,
                        .severity = severity,
                        .t_unix_ns = t_ns,
                        // Borrows `buf` (not name_scratch): a line can be up to 4095
                        // bytes, far larger than the name scratch. The caller must
                        // consume it before the input buffer is reused (drainPipe does).
                        .line = payload[p..][0..ll],
                    },
                },
                .used = total,
            };
        },
        .digest_entry => {
            // name_len(1) + name + severity(1) + count(8) + first(8) + last(8) + sample_len(2)
            if (payload.len < 1 + @as(usize, nl) + digest_fixed + 2) return null;
            @memcpy(name_scratch[0..nl], payload[1..][0..nl]);
            var p: usize = 1 + @as(usize, nl);
            const severity = payload[p];
            p += 1;
            const count = std.mem.readInt(u64, payload[p..][0..8], .little);
            p += 8;
            const first = std.mem.readInt(u64, payload[p..][0..8], .little);
            p += 8;
            const last = std.mem.readInt(u64, payload[p..][0..8], .little);
            p += 8;
            const sl = std.mem.readInt(u16, payload[p..][0..2], .little);
            p += 2;
            // The declared sample length must fit the remaining payload, exactly
            // like the log_line line-length check: a corrupt/truncated frame
            // returns null instead of slicing past the buffer end (a trap).
            if (payload.len < p + @as(usize, sl)) return null;
            return .{
                .rec = .{
                    .digest_entry = .{
                        .name = name_scratch[0..nl],
                        .severity = severity,
                        .count = count,
                        .first_unix_ns = first,
                        .last_unix_ns = last,
                        // Borrows `buf` (not name_scratch), same contract as
                        // log_line.line: consume before the input buffer is reused.
                        .sample = payload[p..][0..sl],
                    },
                },
                .used = total,
            };
        },
    }
}

const testing = std.testing;

test "metric sample survives encode -> decode" {
    var out: [512]u8 = undefined;
    const s = MetricSample{ .name = "api", .rss_kb = 812_000, .cpu_pct = 97, .fds = 42, .threads = 8, .restarts = 3, .t_unix_ns = 1_700_000_000_000_000_000 };
    const bytes = try encodeMetric(&out, s);

    var scratch: [256]u8 = undefined;
    const d = decode(bytes, &scratch).?;
    try testing.expectEqual(@as(usize, bytes.len), d.used);
    const got = d.rec.metric_sample;
    try testing.expectEqualStrings("api", got.name);
    try testing.expectEqual(s.rss_kb, got.rss_kb);
    try testing.expectEqual(s.cpu_pct, got.cpu_pct);
    try testing.expectEqual(s.restarts, got.restarts);
    try testing.expectEqual(s.t_unix_ns, got.t_unix_ns);
}

test "decode returns null on a partial frame" {
    var out: [512]u8 = undefined;
    const bytes = try encodeMetric(&out, .{ .name = "x", .rss_kb = 1, .cpu_pct = 0, .fds = 0, .threads = 0, .restarts = 0, .t_unix_ns = 1 });
    var scratch: [256]u8 = undefined;
    try testing.expect(decode(bytes[0 .. bytes.len - 1], &scratch) == null);
}

test "encode refuses a name that would overflow the frame" {
    var out: [8]u8 = undefined; // deliberately tiny
    try testing.expectError(error.Overflow, encodeMetric(&out, .{ .name = "toolongforthisbuffer", .rss_kb = 0, .cpu_pct = 0, .fds = 0, .threads = 0, .restarts = 0, .t_unix_ns = 0 }));
}

test "log line survives encode -> decode" {
    var out: [512]u8 = undefined;
    const l = LogLine{ .name = "api", .iostream = 1, .severity = 2, .t_unix_ns = 1_700_000_000_123_456_789, .line = "panic: nil map write" };
    const bytes = try encodeLog(&out, l);

    var scratch: [256]u8 = undefined;
    const d = decode(bytes, &scratch).?;
    try testing.expectEqual(@as(usize, bytes.len), d.used);
    const got = d.rec.log_line;
    try testing.expectEqualStrings("api", got.name);
    try testing.expectEqual(@as(u8, 1), got.iostream);
    try testing.expectEqual(@as(u8, 2), got.severity);
    try testing.expectEqual(l.t_unix_ns, got.t_unix_ns);
    try testing.expectEqualStrings("panic: nil map write", got.line);
}

test "log line at max name and max line length round-trips" {
    var out: [8192]u8 = undefined;
    const name = "n" ** name_cap; // 255
    const line = "x" ** line_cap; // 4095
    const bytes = try encodeLog(&out, .{ .name = name, .iostream = 0, .severity = 0, .t_unix_ns = 42, .line = line });

    var scratch: [256]u8 = undefined;
    const d = decode(bytes, &scratch).?;
    const got = d.rec.log_line;
    try testing.expectEqual(@as(usize, name_cap), got.name.len);
    try testing.expectEqual(@as(usize, line_cap), got.line.len);
    try testing.expectEqualStrings(line, got.line);
}

test "decode returns null on a truncated log frame" {
    var out: [512]u8 = undefined;
    const bytes = try encodeLog(&out, .{ .name = "x", .iostream = 0, .severity = 0, .t_unix_ns = 1, .line = "hi" });
    var scratch: [256]u8 = undefined;
    try testing.expect(decode(bytes[0 .. bytes.len - 1], &scratch) == null);
}

test "decode rejects a log frame whose line length overruns its payload" {
    // A whole frame (buf.len == total, so the outer length check passes) but
    // with the internal line-length field inflated past the payload. The inner
    // bounds check must catch it and return null — this is the mutation target.
    var out: [512]u8 = undefined;
    const bytes = try encodeLog(&out, .{ .name = "api", .iostream = 0, .severity = 0, .t_unix_ns = 1, .line = "hi" });
    // The u16 line-length field is the last 2 bytes before the 2-byte line.
    const ll_off = bytes.len - 2 - 2;
    var corrupt: [512]u8 = undefined;
    @memcpy(corrupt[0..bytes.len], bytes);
    std.mem.writeInt(u16, corrupt[ll_off..][0..2], 9999, .little);
    var scratch: [256]u8 = undefined;
    try testing.expect(decode(corrupt[0..bytes.len], &scratch) == null);
}

test "digest entry survives encode -> decode" {
    var out: [512]u8 = undefined;
    const d = DigestEntry{ .name = "api", .severity = 2, .count = 1_000_000, .first_unix_ns = 1_700_000_000_000_000_000, .last_unix_ns = 1_700_000_030_000_000_000, .sample = "ERROR: db timeout" };
    const bytes = try encodeDigest(&out, d);

    var scratch: [256]u8 = undefined;
    const got = decode(bytes, &scratch).?;
    try testing.expectEqual(@as(usize, bytes.len), got.used);
    const e = got.rec.digest_entry;
    try testing.expectEqualStrings("api", e.name);
    try testing.expectEqual(@as(u8, 2), e.severity);
    try testing.expectEqual(d.count, e.count);
    try testing.expectEqual(d.first_unix_ns, e.first_unix_ns);
    try testing.expectEqual(d.last_unix_ns, e.last_unix_ns);
    try testing.expectEqualStrings("ERROR: db timeout", e.sample);
}

test "encodeDigest refuses a sample longer than line_cap" {
    var out: [8192]u8 = undefined;
    const big = "x" ** (line_cap + 1);
    try testing.expectError(error.Overflow, encodeDigest(&out, .{ .name = "api", .severity = 1, .count = 1, .first_unix_ns = 0, .last_unix_ns = 0, .sample = big }));
}

test "decode returns null on a truncated digest frame" {
    var out: [512]u8 = undefined;
    const bytes = try encodeDigest(&out, .{ .name = "api", .severity = 2, .count = 3, .first_unix_ns = 1, .last_unix_ns = 2, .sample = "boom" });
    var scratch: [256]u8 = undefined;
    try testing.expect(decode(bytes[0 .. bytes.len - 1], &scratch) == null);
}
