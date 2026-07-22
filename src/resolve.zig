//! Endpoint resolution for `mandor relay`: `ip:port` or `hostname:port`.
//!
//! mandor is libc-free, so there is no `getaddrinfo`. std ships a resolver
//! (`std.Io.net.HostName.lookup`) but it dispatches through the `std.Io`
//! vtable, which means an event loop and allocator this binary does not have.
//!
//! What std *does* give us for free is the part worth not writing twice: the
//! DNS response walk, including name compression, as a pure fixed-size parser
//! with no I/O. So the answer parsing is std's, and the ~90 lines here are the
//! easy half — read /etc/hosts, read the nameservers out of /etc/resolv.conf,
//! send one A query over UDP.
//!
//! This runs only in the relay subprocess. The supervision path never resolves
//! anything and never opens a socket.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const DnsResponse = std.Io.net.HostName.DnsResponse;

pub const HostPort = struct { host: u32, port: u16 };

/// Seconds to wait for a nameserver. Short on purpose: a relay that cannot
/// resolve should give up and let the operator see the failure, not hold an
/// incident forward open while DNS is broken.
const dns_timeout_s = 3;

/// `1.2.3.4` -> packed u32, or null if it is not a dotted quad.
pub fn parseIpv4(s: []const u8) ?u32 {
    var host: u32 = 0;
    var it = std.mem.splitScalar(u8, s, '.');
    var octets: usize = 0;
    while (it.next()) |o| : (octets += 1) {
        if (octets == 4) return null;
        const v = std.fmt.parseInt(u8, o, 10) catch return null;
        host = (host << 8) | v;
    }
    return if (octets == 4) host else null;
}

/// Split `host:port`. The host half may be an address or a name.
pub fn split(spec: []const u8) ?struct { host: []const u8, port: u16 } {
    const colon = std.mem.lastIndexOfScalar(u8, spec, ':') orelse return null;
    const port = std.fmt.parseInt(u16, spec[colon + 1 ..], 10) catch return null;
    if (colon == 0) return null;
    return .{ .host = spec[0..colon], .port = port };
}

/// Resolve `ip:port` or `name:port`. Addresses are used as-is; names go to
/// /etc/hosts first, then DNS — the order every resolver uses, and the one
/// container runtimes rely on.
pub fn resolve(spec: []const u8) ?HostPort {
    const s = split(spec) orelse return null;
    if (parseIpv4(s.host)) |ip| return .{ .host = ip, .port = s.port };
    const ip = lookupHosts(s.host) orelse lookupDns(s.host) orelse return null;
    return .{ .host = ip, .port = s.port };
}

var file_buf: [8 * 1024]u8 = undefined;

fn readSmall(path: [*:0]const u8) ?[]const u8 {
    const rc = linux.openat(linux.AT.FDCWD, path, .{}, 0);
    if (posix.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var n: usize = 0;
    while (n < file_buf.len) {
        const got = linux.read(fd, file_buf[n..].ptr, file_buf.len - n);
        if (posix.errno(got) != .SUCCESS) return null;
        if (got == 0) break;
        n += got;
    }
    return file_buf[0..n];
}

/// `/etc/hosts`: `<address> <name> [alias...]`, `#` comments.
pub fn parseHosts(text: []const u8, name: []const u8) ?u32 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len];
        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        const addr = it.next() orelse continue;
        const ip = parseIpv4(addr) orelse continue; // skips IPv6 entries
        while (it.next()) |host| {
            if (std.ascii.eqlIgnoreCase(host, name)) return ip;
        }
    }
    return null;
}

fn lookupHosts(name: []const u8) ?u32 {
    return parseHosts(readSmall("/etc/hosts") orelse return null, name);
}

/// First `nameserver <ipv4>` in resolv.conf. Falling back to 127.0.0.1 matches
/// what resolvers do when the file is missing.
pub fn parseNameserver(text: []const u8) ?u32 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len];
        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        const kw = it.next() orelse continue;
        if (!std.mem.eql(u8, kw, "nameserver")) continue;
        if (parseIpv4(it.next() orelse continue)) |ip| return ip;
    }
    return null;
}

/// Build a single A-record query. Returns the used slice of `out`.
pub fn buildQuery(out: []u8, name: []const u8, id: u16) ?[]const u8 {
    if (name.len + 18 > out.len) return null;
    std.mem.writeInt(u16, out[0..2], id, .big);
    std.mem.writeInt(u16, out[2..4], 0x0100, .big); // standard query, recursion desired
    std.mem.writeInt(u16, out[4..6], 1, .big); // one question
    @memset(out[6..12], 0);
    var p: usize = 12;
    var it = std.mem.splitScalar(u8, name, '.');
    while (it.next()) |label| {
        if (label.len == 0 or label.len > 63) return null;
        out[p] = @intCast(label.len);
        p += 1;
        @memcpy(out[p..][0..label.len], label);
        p += label.len;
    }
    out[p] = 0; // root label
    p += 1;
    std.mem.writeInt(u16, out[p..][0..2], 1, .big); // QTYPE A
    std.mem.writeInt(u16, out[p + 2 ..][0..2], 1, .big); // QCLASS IN
    return out[0 .. p + 4];
}

/// First A record in a response, using std's parser so the answer walk and
/// name compression are not reimplemented here.
pub fn firstA(packet: []const u8) ?u32 {
    var resp = DnsResponse.init(packet) catch return null;
    while (resp.next() catch return null) |ans| {
        if (ans.rr != .A or ans.data_len != 4) continue;
        const b = ans.packet[ans.data_off..][0..4];
        return std.mem.readInt(u32, b, .big);
    }
    return null;
}

fn lookupDns(name: []const u8) ?u32 {
    const ns = parseNameserver(readSmall("/etc/resolv.conf") orelse "") orelse 0x7f000001;

    var qbuf: [512]u8 = undefined;
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    const id: u16 = @truncate(@as(u64, @bitCast(ts.nsec)));
    const query = buildQuery(&qbuf, name, id) orelse return null;

    const rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (posix.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);

    // Bounded like every other socket mandor opens: a silent resolver must not
    // hold the relay open.
    const tv = linux.timeval{ .sec = dns_timeout_s, .usec = 0 };
    const tvp: [*]const u8 = @ptrCast(&tv);
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, tvp, @sizeOf(linux.timeval));

    var addr: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, 53),
        .addr = std.mem.nativeToBig(u32, ns),
    };
    if (posix.errno(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) != .SUCCESS)
        return null;

    var off: usize = 0;
    while (off < query.len) {
        const n = linux.write(fd, query.ptr + off, query.len - off);
        switch (posix.errno(n)) {
            .SUCCESS => off += n,
            .INTR => continue,
            else => return null,
        }
    }

    var rbuf: [512]u8 = undefined;
    const got = linux.read(fd, &rbuf, rbuf.len);
    if (posix.errno(got) != .SUCCESS) return null;
    const len: usize = @intCast(got);
    if (len < 12) return null;
    // Ignore a reply to somebody else's question.
    if (std.mem.readInt(u16, rbuf[0..2], .big) != id) return null;
    return firstA(rbuf[0..len]);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "parseIpv4 accepts dotted quads and rejects the rest" {
    try testing.expectEqual(@as(u32, 0x7f000001), parseIpv4("127.0.0.1").?);
    try testing.expectEqual(@as(u32, 0xffffffff), parseIpv4("255.255.255.255").?);
    try testing.expectEqual(@as(u32, 0), parseIpv4("0.0.0.0").?);
    try testing.expect(parseIpv4("256.0.0.1") == null);
    try testing.expect(parseIpv4("1.2.3") == null);
    try testing.expect(parseIpv4("1.2.3.4.5") == null);
    try testing.expect(parseIpv4("photon") == null);
    try testing.expect(parseIpv4("") == null);
}

test "split separates host from port" {
    const a = split("127.0.0.1:4318").?;
    try testing.expectEqualStrings("127.0.0.1", a.host);
    try testing.expectEqual(@as(u16, 4318), a.port);
    const b = split("photon:4318").?;
    try testing.expectEqualStrings("photon", b.host);
    try testing.expect(split("photon") == null);
    try testing.expect(split("photon:") == null);
    try testing.expect(split("photon:99999") == null);
    try testing.expect(split(":4318") == null);
}

test "parseHosts finds names and aliases, skipping comments and IPv6" {
    const hosts =
        "# comment\n" ++
        "127.0.0.1\tlocalhost\n" ++
        "::1\tlocalhost ip6-localhost\n" ++
        "10.89.0.2\tphoton photon.local  # trailing comment\n" ++
        "192.168.1.5 other\n";
    try testing.expectEqual(@as(u32, 0x7f000001), parseHosts(hosts, "localhost").?);
    try testing.expectEqual(@as(u32, 0x0a590002), parseHosts(hosts, "photon").?);
    try testing.expectEqual(@as(u32, 0x0a590002), parseHosts(hosts, "photon.local").?);
    // Case-insensitive, per the hosts file convention.
    try testing.expectEqual(@as(u32, 0x0a590002), parseHosts(hosts, "PHOTON").?);
    try testing.expect(parseHosts(hosts, "missing") == null);
    // A commented-out entry must not match.
    try testing.expect(parseHosts("# 1.2.3.4 ghost\n", "ghost") == null);
}

test "parseNameserver reads the first usable entry" {
    try testing.expectEqual(@as(u32, 0x08080808), parseNameserver("nameserver 8.8.8.8\n").?);
    try testing.expectEqual(
        @as(u32, 0x0a000001),
        parseNameserver("# c\nsearch example.com\nnameserver 10.0.0.1\nnameserver 9.9.9.9\n").?,
    );
    // IPv6 nameservers are skipped rather than mis-parsed.
    try testing.expectEqual(
        @as(u32, 0x0a000001),
        parseNameserver("nameserver fe80::1\nnameserver 10.0.0.1\n").?,
    );
    try testing.expect(parseNameserver("search example.com\n") == null);
    try testing.expect(parseNameserver("") == null);
}

test "buildQuery encodes a well-formed A question" {
    var buf: [512]u8 = undefined;
    const q = buildQuery(&buf, "photon.local", 0xbeef).?;
    try testing.expectEqual(@as(u16, 0xbeef), std.mem.readInt(u16, q[0..2], .big));
    try testing.expectEqual(@as(u16, 0x0100), std.mem.readInt(u16, q[2..4], .big));
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, q[4..6], .big));
    // 12 header + (1+6 "photon") + (1+5 "local") + 1 root + 4 type/class
    try testing.expectEqual(@as(usize, 12 + 7 + 6 + 1 + 4), q.len);
    try testing.expectEqual(@as(u8, 6), q[12]);
    try testing.expectEqualStrings("photon", q[13..19]);
    try testing.expectEqual(@as(u8, 5), q[19]);
    try testing.expectEqualStrings("local", q[20..25]);
    try testing.expectEqual(@as(u8, 0), q[25]);
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, q[26..28], .big)); // A
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, q[28..30], .big)); // IN

    // A label over 63 bytes, an empty label, and an oversize buffer are refused.
    try testing.expect(buildQuery(&buf, "a" ** 64, 1) == null);
    try testing.expect(buildQuery(&buf, "a..b", 1) == null);
    var tiny: [8]u8 = undefined;
    try testing.expect(buildQuery(&tiny, "photon", 1) == null);
}

test "firstA pulls the address out of a real response shape" {
    // Header (1 question, 1 answer), question for "photon" A/IN, then an
    // answer using a compression pointer back to the name.
    var pkt: [64]u8 = undefined;
    var p: usize = 0;
    std.mem.writeInt(u16, pkt[0..2], 0x1234, .big);
    std.mem.writeInt(u16, pkt[2..4], 0x8180, .big); // response, no error
    std.mem.writeInt(u16, pkt[4..6], 1, .big); // qdcount
    std.mem.writeInt(u16, pkt[6..8], 1, .big); // ancount
    std.mem.writeInt(u16, pkt[8..10], 0, .big);
    std.mem.writeInt(u16, pkt[10..12], 0, .big);
    p = 12;
    pkt[p] = 6;
    p += 1;
    @memcpy(pkt[p..][0..6], "photon");
    p += 6;
    pkt[p] = 0;
    p += 1;
    std.mem.writeInt(u16, pkt[p..][0..2], 1, .big);
    std.mem.writeInt(u16, pkt[p + 2 ..][0..2], 1, .big);
    p += 4;
    // answer: name pointer, type A, class IN, ttl, rdlength 4, 10.89.0.2
    pkt[p] = 0xc0;
    pkt[p + 1] = 0x0c;
    p += 2;
    std.mem.writeInt(u16, pkt[p..][0..2], 1, .big); // A
    std.mem.writeInt(u16, pkt[p + 2 ..][0..2], 1, .big); // IN
    std.mem.writeInt(u32, pkt[p + 4 ..][0..4], 60, .big); // ttl
    std.mem.writeInt(u16, pkt[p + 8 ..][0..2], 4, .big); // rdlength
    p += 10;
    pkt[p] = 10;
    pkt[p + 1] = 89;
    pkt[p + 2] = 0;
    pkt[p + 3] = 2;
    p += 4;

    try testing.expectEqual(@as(u32, 0x0a590002), firstA(pkt[0..p]).?);
    // Truncated and empty packets are refused, not read past.
    try testing.expect(firstA(pkt[0..8]) == null);
    try testing.expect(firstA(&.{}) == null);
}

test "resolve uses a literal address without touching the network" {
    const hp = resolve("10.89.0.2:4318").?;
    try testing.expectEqual(@as(u32, 0x0a590002), hp.host);
    try testing.expectEqual(@as(u16, 4318), hp.port);
    try testing.expect(resolve("10.89.0.2") == null); // no port
}
