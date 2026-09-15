//! Host identity for the OTLP resource attributes mandor stamps on everything
//! it ships (`host.name` / `host.id`) — so photon attributes a worker's
//! metrics, logs, incidents and lifecycle events to its node, where the
//! node's own resource metrics come from photon-agent. Read once by the relay
//! daemon at startup; raw syscalls, fixed buffers, never traps.
//!
//! This is all that remains of the node-metrics module: mandor stopped
//! sampling the host in v1.16 (see docs/INTEGRATION-PHOTON.md) — the
//! supervisor describes its workers, the host agent describes the host.
const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

fn readFile(path: [*:0]const u8, buf: []u8) ?[]const u8 {
    const rc = linux.openat(linux.AT.FDCWD, path, .{}, 0);
    if (posix.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const n = linux.read(fd, buf.ptr, buf.len);
    if (posix.errno(n) != .SUCCESS) return null;
    return buf[0..n];
}

fn readTrimmed(path: [*:0]const u8, buf: []u8) []const u8 {
    const text = readFile(path, buf) orelse return "";
    return std.mem.trim(u8, text, " \t\r\n\x00");
}

/// host.name from /proc/sys/kernel/hostname (trimmed). Falls back to the
/// stable literal "unknown" so the OTLP resource attribute is never empty.
pub fn hostName(buf: []u8) []const u8 {
    const name = readTrimmed("/proc/sys/kernel/hostname", buf);
    if (name.len == 0) return "unknown";
    return name;
}

/// host.id from /etc/machine-id, falling back to
/// /proc/sys/kernel/random/boot_id, then the literal "unknown".
pub fn hostId(buf: []u8) []const u8 {
    const id = readTrimmed("/etc/machine-id", buf);
    if (id.len != 0) return id;
    const boot = readTrimmed("/proc/sys/kernel/random/boot_id", buf);
    if (boot.len != 0) return boot;
    return "unknown";
}

const testing = std.testing;

test "hostName and hostId never yield an empty string" {
    var a: [256]u8 = undefined;
    var b: [256]u8 = undefined;
    try testing.expect(hostName(&a).len > 0);
    try testing.expect(hostId(&b).len > 0);
}

test "readTrimmed on a missing file is empty, not an error" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("", readTrimmed("/definitely/not/here", &buf));
}
