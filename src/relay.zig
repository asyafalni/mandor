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

fn ap(pos: *usize, comptime fmt: []const u8, args: anytype) bool {
    const out = std.fmt.bufPrint(body_buf[pos.*..], fmt, args) catch return false;
    pos.* += out.len;
    return true;
}

fn apEscaped(pos: *usize, s: []const u8) bool {
    for (s) |c| {
        const ok = switch (c) {
            '"' => ap(pos, "\\\"", .{}),
            '\\' => ap(pos, "\\\\", .{}),
            0x00...0x1f => ap(pos, "\\u{x:0>4}", .{c}),
            else => ap(pos, "{c}", .{c}),
        };
        if (!ok) return false;
    }
    return true;
}

/// Copy already-escaped JSON string source through verbatim, rejecting
/// anything that would not survive as the body of a JSON string.
///
/// Values from `scanStr` are *source* text — the spool writer already escaped
/// them — so running them through `apEscaped` would escape a second time and
/// show the operator a literal `\"` where the incident said `"`. Passing them
/// through raw is correct, but only if they really are well-formed: a bundle
/// on disk outlives mandor and nothing stops it being edited or half-written,
/// so a bad escape must be refused rather than splice broken JSON into the
/// payload.
fn apJsonSource(pos: *usize, s: []const u8) bool {
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
    if (pos.* +| s.len > body_buf.len) return false;
    @memcpy(body_buf[pos.*..][0..s.len], s);
    pos.* += s.len;
    return true;
}

const BuildError = error{ TooLarge, Malformed };

/// Map the bundle onto one OTLP LogRecord (docs/INTEGRATION-PHOTON.md).
pub fn buildOtlp(bundle: []const u8) BuildError![]const u8 {
    const name = scanStr(bundle, "name") orelse "unknown";
    const kind = scanStr(bundle, "kind") orelse "unknown";
    const verdict = scanStr(bundle, "verdict") orelse "";
    const release = scanStr(bundle, "release") orelse "";
    const severity: []const u8 = if (std.mem.eql(u8, kind, "leak-suspect") or
        std.mem.eql(u8, kind, "restart-loop")) "WARN" else "ERROR";

    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    const ns = @as(u128, @intCast(ts.sec)) * 1_000_000_000 + @as(u128, @intCast(ts.nsec));

    var pos: usize = 0;
    const p = &pos;
    // `name`, `release` and `verdict` are escaped source text -> copied
    // through. `bundle` is raw JSON being embedded *as* a string -> escaped.
    if (!ap(p, "{{\"resourceLogs\":[{{\"resource\":{{\"attributes\":[" ++
        "{{\"key\":\"service.name\",\"value\":{{\"stringValue\":\"", .{})) return error.TooLarge;
    if (!apJsonSource(p, name)) return error.Malformed;
    if (!ap(p, "\"}}}},{{\"key\":\"service.version\",\"value\":{{\"stringValue\":\"", .{}))
        return error.TooLarge;
    if (!apJsonSource(p, release)) return error.Malformed;
    if (!ap(p, "\"}}}}]}},\"scopeLogs\":[{{\"logRecords\":[{{\"timeUnixNano\":\"{d}\"," ++
        "\"severityText\":\"{s}\",\"body\":{{\"stringValue\":\"", .{ ns, severity }))
        return error.TooLarge;
    if (!apJsonSource(p, verdict)) return error.Malformed;
    if (!ap(p, "\"}},\"attributes\":[{{\"key\":\"mandor.bundle\",\"value\":{{\"stringValue\":\"", .{}))
        return error.TooLarge;
    if (!apEscaped(p, bundle)) return error.TooLarge;
    if (!ap(p, "\"}}}}]}}]}}]}}]}}", .{})) return error.TooLarge;
    return body_buf[0..pos];
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
        "Content-Type: application/json\r\n{s}Content-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{
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
    if (posix.errno(got) == .SUCCESS and got > 12 and std.mem.eql(u8, resp[9..12], "200")) return 0;
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

test "buildOtlp does not double-escape scanned values" {
    // The spool writer stores verdict already escaped, so relay must copy it
    // through. Escaping again shipped `said \"boom\"` — literal backslashes
    // in the operator's incident text.
    const bundle =
        "{\"name\":\"api\",\"kind\":\"crash\"," ++
        "\"verdict\":\"said \\\"boom\\\"\",\"release\":\"v1\"}";
    const body = try buildOtlp(bundle);
    try testing.expect(std.mem.indexOf(u8, body, "\"stringValue\":\"said \\\"boom\\\"\"") != null);
    // Scope the "not double-escaped" check to everything *before* the embedded
    // bundle copy: that copy is raw JSON escaped on purpose, so `\"` correctly
    // becomes `\\\"` there and would match this pattern legitimately.
    const head = body[0..std.mem.indexOf(u8, body, "mandor.bundle").?];
    try testing.expect(std.mem.indexOf(u8, head, "\\\\\"boom") == null);
    // The bundle copy *is* raw JSON embedded as a string, so it stays escaped.
    try testing.expect(std.mem.indexOf(u8, body, "{\\\"name\\\":\\\"api\\\"") != null);
}

test "buildOtlp maps severity and tolerates missing fields" {
    const warn = try buildOtlp("{\"kind\":\"leak-suspect\"}");
    try testing.expect(std.mem.indexOf(u8, warn, "\"severityText\":\"WARN\"") != null);
    const loop = try buildOtlp("{\"kind\":\"restart-loop\"}");
    try testing.expect(std.mem.indexOf(u8, loop, "\"severityText\":\"WARN\"") != null);
    const oops = try buildOtlp("{\"kind\":\"signal\"}");
    try testing.expect(std.mem.indexOf(u8, oops, "\"severityText\":\"ERROR\"") != null);
    // An empty bundle still produces a well-formed record, not a crash.
    const bare = try buildOtlp("{}");
    try testing.expect(std.mem.indexOf(u8, bare, "\"stringValue\":\"unknown\"") != null);
}

test "buildOtlp refuses a bundle with a broken escape" {
    // A half-written or hand-edited bundle must be refused, not spliced into
    // the payload where it would corrupt the whole OTLP record.
    try testing.expectError(error.Malformed, buildOtlp("{\"name\":\"a\\qb\"}"));
    try testing.expectError(error.Malformed, buildOtlp("{\"name\":\"a\\u00zz\"}"));
    try testing.expectError(error.Malformed, buildOtlp("{\"name\":\"a\\u01\"}"));
}

test "apJsonSource accepts every legal escape" {
    var pos: usize = 0;
    try testing.expect(apJsonSource(&pos, "plain \\\" \\\\ \\/ \\b \\f \\n \\r \\t \\u00e9"));
    pos = 0;
    try testing.expect(!apJsonSource(&pos, "trailing \\"));
    pos = 0;
    try testing.expect(!apJsonSource(&pos, "raw \x01 control"));
}

test "buildOtlp rejects a bundle too large for the body buffer" {
    // Fill past body_buf: the bundle is embedded escaped, so a buffer-sized
    // input of quotes doubles on the way in.
    const big = &struct {
        var b: [200 * 1024]u8 = undefined;
    }.b;
    @memset(big, '"');
    try testing.expectError(error.TooLarge, buildOtlp(big));
}
