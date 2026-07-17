//! Minimal stderr logging: std.fmt into a stack buffer + one raw write(2).
//! Replaces std.debug.print, whose 0.16 implementation drags Io.Threaded's
//! vtable (DNS, spawn, flate, DWARF printing) into the binary — a six-figure
//! byte cost for a supervisor that only ever prints short lines.

const std = @import("std");
const builtin = @import("builtin");

pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (comptime builtin.os.tag != .linux) return;
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch blk: {
        break :blk buf[0..]; // truncated: still worth emitting
    };
    _ = std.os.linux.write(2, msg.ptr, msg.len);
}
