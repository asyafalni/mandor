//! cgroup v2 OOM detection: watch the container's memory.events oom_kill
//! counter. When it rises across a worker death by SIGKILL, the real cause
//! was the kernel OOM killer, not a polite signal.

const std = @import("std");

/// Extract `oom_kill N` from memory.events text.
pub fn parseOomKills(text: []const u8) ?u64 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "oom_kill ")) {
            return std.fmt.parseInt(u64, std.mem.trim(u8, line["oom_kill ".len..], " \r"), 10) catch null;
        }
    }
    return null;
}

// ------------------------------------------------------- Linux reader

const linux = std.os.linux;
const posix = std.posix;

const events_path = "/sys/fs/cgroup/memory.events";

/// Current oom_kill count for this container's cgroup, if cgroup v2 is
/// mounted (returns null on cgroup v1 hosts or outside containers).
pub fn readOomKills() ?u64 {
    const rc = linux.openat(linux.AT.FDCWD, events_path, .{}, 0);
    if (posix.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var buf: [512]u8 = undefined;
    const n = linux.read(fd, &buf, buf.len);
    if (posix.errno(n) != .SUCCESS) return null;
    return parseOomKills(buf[0..n]);
}

// ---------------------------------------------------------------- tests

test "parses oom_kill from memory.events" {
    const text =
        \\low 0
        \\high 12
        \\max 340
        \\oom 3
        \\oom_kill 2
        \\oom_group_kill 0
    ;
    try std.testing.expectEqual(@as(?u64, 2), parseOomKills(text));
    try std.testing.expectEqual(@as(?u64, null), parseOomKills("low 0\nhigh 0\n"));
    try std.testing.expectEqual(@as(?u64, null), parseOomKills(""));
    // "oom 3" must not match "oom_kill"
    try std.testing.expectEqual(@as(?u64, 7), parseOomKills("oom 3\noom_kill 7"));
}
