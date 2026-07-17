const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");

const version = "0.1.0-dev";

const usage_text =
    \\mandor — the foreman for your containers
    \\
    \\usage:
    \\  mandor [flags] [--] "CMD" ["CMD" ...]
    \\  mandor --help | --version
    \\
    \\flags:
    \\  --restart=never|on-failure|always   restart policy (default: never)
    \\  --backoff-max=DUR                   restart backoff cap, e.g. 500ms|30s|2m (default: 30s)
    \\
    \\Each CMD is one worker: quoted command line, tokenized by mandor
    \\(no shell needed). Signals TERM/INT/HUP are forwarded to workers.
    \\mandor exits with the worst worker exit code (128+N for signal deaths).
    \\
;

fn writeOut(text: []const u8) void {
    if (builtin.os.tag == .linux) {
        _ = std.os.linux.write(1, text.ptr, text.len);
    }
}

pub fn main(init: std.process.Init.Minimal) u8 {
    if (comptime builtin.os.tag != .linux) {
        std.debug.print("mandor supervises processes on Linux only\n", .{});
        return 2;
    }

    const vec = init.args.vector; // []const [*:0]const u8 on Linux
    var args_buf: [cli.max_workers + 16][]const u8 = undefined;
    if (vec.len == 0 or vec.len - 1 > args_buf.len) {
        writeOut(usage_text);
        return 2;
    }
    for (vec[1..], 0..) |p, i| args_buf[i] = std.mem.span(p);
    const args = args_buf[0 .. vec.len - 1];

    var cmd_storage: [cli.max_workers][]const u8 = undefined;
    const cfg = cli.parse(args, &cmd_storage) catch |err| {
        std.debug.print("[mandor] {s}\n\n", .{switch (err) {
            error.UnknownFlag => "unknown flag",
            error.BadValue => "bad flag value",
            error.NoCommands => "no worker commands given",
            error.TooManyWorkers => "too many workers (max 64)",
        }});
        writeOut(usage_text);
        return 2;
    };
    if (cfg.help) {
        writeOut(usage_text);
        return 0;
    }
    if (cfg.version) {
        writeOut("mandor " ++ version ++ "\n");
        return 0;
    }

    const supervisor = @import("supervisor.zig");
    return supervisor.run(cfg, init.environ.block.slice);
}

test {
    _ = @import("cli.zig");
    _ = @import("backoff.zig");
    _ = @import("ring.zig");
    if (builtin.os.tag == .linux) {
        _ = @import("signals.zig");
        _ = @import("spawner.zig");
        _ = @import("reaper.zig");
    }
}
