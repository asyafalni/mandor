//! The compact pipe wire format shared by the supervisor core (writer) and the
//! relay daemon (reader). Pure — NO syscalls, no allocation, no panic. One
//! responsibility: framing mandor's internal telemetry records (metric samples
//! and lifecycle events) into bytes and back.
//!
//! This is mandor's own form, NOT OTLP: the daemon re-encodes these into OTLP
//! protobuf before shipping. Keeping the pipe format tiny and fixed keeps the
//! hot-path writer allocation-free and its decode side total (a corrupt or
//! partial frame yields `null`, never a trap).
//!
//! Frame = [u8 kind][u16 len LE][payload]. Little-endian throughout. Worker
//! names are capped at 255 bytes (one length byte).

const std = @import("std");

pub const Kind = enum(u8) { metric_sample = 1, lifecycle_event = 2 };

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

pub const Decoded = union(Kind) { metric_sample: MetricSample, lifecycle_event: Lifecycle };

/// Fixed bytes after the name in each payload. Kept as named constants so the
/// encoder's sizing and the decoder's bounds check cannot drift apart.
const metric_fixed = 8 + 2 + 2 + 2 + 4 + 8; // rss,cpu,fds,threads,restarts,t_ns
const lifecycle_fixed = 1 + 4 + 4 + 4 + 8; // ev,code,backoff,restarts,t_ns

const header = 3; // [u8 kind][u16 len]
const name_cap = 255; // one length byte

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
