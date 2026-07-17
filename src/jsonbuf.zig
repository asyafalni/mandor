//! Tiny hand-rolled JSON emission into fixed buffers. Shared by the state
//! file (report.zig) and incident bundles (spool.zig). No allocator.

const std = @import("std");

pub fn appendf(buf: []u8, pos: *usize, comptime fmt: []const u8, args: anytype) bool {
    const out = std.fmt.bufPrint(buf[pos.*..], fmt, args) catch return false;
    pos.* += out.len;
    return true;
}

pub fn appendJsonString(buf: []u8, pos: *usize, s: []const u8) bool {
    if (!appendf(buf, pos, "\"", .{})) return false;
    for (s) |c| {
        const ok = switch (c) {
            '"' => appendf(buf, pos, "\\\"", .{}),
            '\\' => appendf(buf, pos, "\\\\", .{}),
            0x00...0x1f => appendf(buf, pos, "\\u{x:0>4}", .{c}),
            else => appendf(buf, pos, "{c}", .{c}),
        };
        if (!ok) return false;
    }
    return appendf(buf, pos, "\"", .{});
}

test "json string escaping" {
    var buf: [64]u8 = undefined;
    var pos: usize = 0;
    try std.testing.expect(appendJsonString(&buf, &pos, "a\"b\\c\n"));
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\u000a\"", buf[0..pos]);
}
