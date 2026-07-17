//! `mandor relay <bundle.json>` — ships an incident bundle to photon's
//! OTLP/HTTP logs endpoint (PHOTON_OTLP=ip:port, default 127.0.0.1:4318).
//! Runs ONLY when explicitly invoked as this subcommand — the supervisor
//! itself never opens outbound connections. Wire it up with
//! `on_incident = "/mandor relay"`. Mapping: docs/INTEGRATION-PHOTON.md.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const spawner = @import("spawner.zig");

var file_buf: [256 * 1024]u8 = undefined;
var body_buf: [320 * 1024]u8 = undefined;
var req_buf: [321 * 1024]u8 = undefined;

pub fn run(path: [*:0]const u8, endpoint_arg: ?[]const u8, environ: [:null]const ?[*:0]const u8) u8 {
    const bundle = readFile(path) orelse {
        err("cannot read bundle");
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

    const body = buildOtlp(bundle) orelse {
        err("bundle too large");
        return 1;
    };
    return post(host, port, body);
}

fn err(msg: []const u8) void {
    _ = linux.write(2, msg.ptr, msg.len);
    _ = linux.write(2, "\n", 1);
}

fn readFile(path: [*:0]const u8) ?[]const u8 {
    const rc = linux.openat(linux.AT.FDCWD, path, .{}, 0);
    if (posix.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const n = linux.read(fd, &file_buf, file_buf.len);
    if (posix.errno(n) != .SUCCESS or n == 0) return null;
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

/// Map the bundle onto one OTLP LogRecord (docs/INTEGRATION-PHOTON.md).
fn buildOtlp(bundle: []const u8) ?[]const u8 {
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
    if (!ap(p, "{{\"resourceLogs\":[{{\"resource\":{{\"attributes\":[" ++
        "{{\"key\":\"service.name\",\"value\":{{\"stringValue\":\"{s}\"}}}}," ++
        "{{\"key\":\"service.version\",\"value\":{{\"stringValue\":\"{s}\"}}}}]}}," ++
        "\"scopeLogs\":[{{\"logRecords\":[{{\"timeUnixNano\":\"{d}\"," ++
        "\"severityText\":\"{s}\",\"body\":{{\"stringValue\":\"", .{ name, release, ns, severity }))
        return null;
    if (!apEscaped(p, verdict)) return null;
    if (!ap(p, "\"}},\"attributes\":[{{\"key\":\"mandor.bundle\",\"value\":{{\"stringValue\":\"", .{}))
        return null;
    if (!apEscaped(p, bundle)) return null;
    if (!ap(p, "\"}}}}]}}]}}]}}]}}", .{})) return null;
    return body_buf[0..pos];
}

fn post(host: u32, port: u16, body: []const u8) u8 {
    const rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (posix.errno(rc) != .SUCCESS) {
        err("socket failed");
        return 1;
    }
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var addr: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, host),
    };
    if (posix.errno(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
        err("connect failed — is photon listening?");
        return 1;
    }
    const req = std.fmt.bufPrint(&req_buf, "POST /v1/logs HTTP/1.1\r\nHost: photon\r\n" ++
        "Content-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{
        body.len, body,
    }) catch return 1;
    var off: usize = 0;
    while (off < req.len) {
        const n = linux.write(fd, req.ptr + off, req.len - off);
        if (posix.errno(n) != .SUCCESS) {
            err("send failed");
            return 1;
        }
        off += n;
    }
    var resp: [128]u8 = undefined;
    const got = linux.read(fd, &resp, resp.len);
    if (posix.errno(got) == .SUCCESS and got > 12 and std.mem.eql(u8, resp[9..12], "200")) return 0;
    err("photon did not accept the payload");
    return 1;
}
