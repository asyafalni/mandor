//! `mandor relay <bundle.json>` — ships an incident bundle to photon's
//! OTLP/HTTP logs endpoint (PHOTON_OTLP=ip:port, default 127.0.0.1:4318).
//! Runs ONLY when explicitly invoked as this subcommand — the supervisor
//! itself never opens outbound connections. Wire it up with
//! `on_incident = "/mandor relay"`. Mapping: docs/INTEGRATION-PHOTON.md.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const spawner = @import("spawner.zig");

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
    return post(host, port, body, token);
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

pub fn parseHostPort(spec: []const u8) ?struct { host: u32, port: u16 } {
    const colon = std.mem.lastIndexOfScalar(u8, spec, ':') orelse return null;
    const port = std.fmt.parseInt(u16, spec[colon + 1 ..], 10) catch return null;
    var host: u32 = 0;
    var it = std.mem.splitScalar(u8, spec[0..colon], '.');
    var octets: usize = 0;
    while (it.next()) |o| : (octets += 1) {
        if (octets == 4) return null;
        const v = std.fmt.parseInt(u8, o, 10) catch return null;
        host = (host << 8) | v;
    }
    if (octets != 4) return null;
    return .{ .host = host, .port = port };
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

/// Is this already-escaped JSON string source well-formed?
///
/// Values from `scanStr` are *source* text the spool writer already escaped.
/// The protobuf payload carries them verbatim — lengths are explicit, so
/// there is no escaping and no injection risk — which makes this purely a
/// corruption check: a trailing backslash, a bad `\u`, or a raw control byte
/// means the bundle was truncated mid-write or hand-edited, and shipping it
/// would file a damaged incident rather than report a real one.
fn validJsonSource(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c < 0x20) return false; // raw control char — should have been escaped
        if (c != '\\') continue;
        i += 1;
        if (i >= s.len) return false; // trailing backslash
        switch (s[i]) {
            '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => {},
            'u' => {
                if (i + 4 >= s.len) return false;
                for (s[i + 1 ..][0..4]) |h| if (!std.ascii.isHex(h)) return false;
                i += 4;
            },
            else => return false,
        }
    }
    return true;
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

/// OTLP SeverityNumber. Only the two mandor emits.
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

fn post(host: u32, port: u16, body: []const u8, token: []const u8) u8 {
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
    const req = std.fmt.bufPrint(&req_buf, "POST /v1/logs HTTP/1.1\r\nHost: photon\r\n" ++
        "Content-Type: application/x-protobuf\r\n{s}Content-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{
        auth, body.len, body,
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

    // Every rejection path: no port, too few/many octets, out-of-range octet
    // and port, non-numeric, and a hostname (there is no resolver here).
    try testing.expect(parseHostPort("127.0.0.1") == null);
    try testing.expect(parseHostPort("127.0.0:4318") == null);
    try testing.expect(parseHostPort("1.2.3.4.5:4318") == null);
    try testing.expect(parseHostPort("256.0.0.1:4318") == null);
    try testing.expect(parseHostPort("127.0.0.1:65536") == null);
    try testing.expect(parseHostPort("127.0.0.1:") == null);
    try testing.expect(parseHostPort("localhost:4318") == null);
    try testing.expect(parseHostPort("") == null);
    try testing.expect(parseHostPort(":") == null);
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

test "validJsonSource accepts every legal escape" {
    try testing.expect(validJsonSource("plain \\\" \\\\ \\/ \\b \\f \\n \\r \\t \\u00e9"));
    try testing.expect(!validJsonSource("trailing \\"));
    try testing.expect(!validJsonSource("raw \x01 control"));
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
