const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    std.debug.print("mandor v0.1.0-dev\n", .{});
}

test {
    _ = @import("cli.zig");
    _ = @import("backoff.zig");
    if (builtin.os.tag == .linux) {
        _ = @import("signals.zig");
        _ = @import("spawner.zig");
        _ = @import("reaper.zig");
    }
}
