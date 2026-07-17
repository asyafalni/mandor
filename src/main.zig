const std = @import("std");

pub fn main() !void {
    std.debug.print("mandor v0.1.0-dev\n", .{});
}

test {
    _ = @import("cli.zig");
}
