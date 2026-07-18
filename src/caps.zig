//! Linux capability names → bit numbers, for per-worker cap_drop. A tiny
//! static table instead of a libcap dependency (keeps the no-deps rule).
//! Bit numbers are the stable ABI (include/uapi/linux/capability.h).

const std = @import("std");

const Entry = struct { name: []const u8, bit: u5 };
const table = [_]Entry{
    .{ .name = "CHOWN", .bit = 0 },
    .{ .name = "DAC_OVERRIDE", .bit = 1 },
    .{ .name = "DAC_READ_SEARCH", .bit = 2 },
    .{ .name = "FOWNER", .bit = 3 },
    .{ .name = "FSETID", .bit = 4 },
    .{ .name = "KILL", .bit = 5 },
    .{ .name = "SETGID", .bit = 6 },
    .{ .name = "SETUID", .bit = 7 },
    .{ .name = "SETPCAP", .bit = 8 },
    .{ .name = "LINUX_IMMUTABLE", .bit = 9 },
    .{ .name = "NET_BIND_SERVICE", .bit = 10 },
    .{ .name = "NET_BROADCAST", .bit = 11 },
    .{ .name = "NET_ADMIN", .bit = 12 },
    .{ .name = "NET_RAW", .bit = 13 },
    .{ .name = "IPC_LOCK", .bit = 14 },
    .{ .name = "IPC_OWNER", .bit = 15 },
    .{ .name = "SYS_MODULE", .bit = 16 },
    .{ .name = "SYS_RAWIO", .bit = 17 },
    .{ .name = "SYS_CHROOT", .bit = 18 },
    .{ .name = "SYS_PTRACE", .bit = 19 },
    .{ .name = "SYS_PACCT", .bit = 20 },
    .{ .name = "SYS_ADMIN", .bit = 21 },
    .{ .name = "SYS_BOOT", .bit = 22 },
    .{ .name = "SYS_NICE", .bit = 23 },
    .{ .name = "SYS_RESOURCE", .bit = 24 },
    .{ .name = "SYS_TIME", .bit = 25 },
    .{ .name = "SYS_TTY_CONFIG", .bit = 26 },
    .{ .name = "MKNOD", .bit = 27 },
    .{ .name = "LEASE", .bit = 28 },
    .{ .name = "AUDIT_WRITE", .bit = 29 },
    .{ .name = "AUDIT_CONTROL", .bit = 30 },
    .{ .name = "SETFCAP", .bit = 31 },
};
pub const last_cap: u8 = 40; // CAP_CHECKPOINT_RESTORE (kernel 5.9+); drop-all upper bound

/// Bit for a capability name (with or without a "CAP_" prefix), or null.
pub fn bit(name: []const u8) ?u5 {
    const n = if (std.ascii.startsWithIgnoreCase(name, "CAP_")) name[4..] else name;
    for (table) |e| {
        if (std.ascii.eqlIgnoreCase(e.name, n)) return e.bit;
    }
    return null;
}

test "cap name lookup" {
    try std.testing.expectEqual(@as(?u5, 13), bit("NET_RAW"));
    try std.testing.expectEqual(@as(?u5, 13), bit("CAP_NET_RAW"));
    try std.testing.expectEqual(@as(?u5, 21), bit("sys_admin"));
    try std.testing.expectEqual(@as(?u5, null), bit("NOPE"));
}
