//! Optional Prometheus text endpoint — the one allowed piece of networking
//! in the core binary (CLAUDE.md). Hand-rolled: one listener on 127.0.0.1,
//! one route, one connection at a time, no keep-alive.

const std = @import("std");
const spawner = @import("spawner.zig");

// ------------------------------------------------------- text renderer

/// Render the Prometheus exposition text. Pure and unit-tested.
pub fn render(buf: []u8, workers: []const spawner.Worker, incidents_total: u64) []const u8 {
    var pos: usize = 0;
    const p = &pos;
    ap(buf, p, "# TYPE mandor_worker_up gauge\n", .{});
    for (workers) |*w| {
        ap(buf, p, "mandor_worker_up{{worker=\"{s}\"}} {d}\n", .{
            w.nameSlice(), @as(u8, if (w.pid > 0) 1 else 0),
        });
    }
    ap(buf, p, "# TYPE mandor_worker_restarts_total counter\n", .{});
    for (workers) |*w| {
        ap(buf, p, "mandor_worker_restarts_total{{worker=\"{s}\"}} {d}\n", .{
            w.nameSlice(), w.restarts,
        });
    }
    ap(buf, p, "# TYPE mandor_worker_rss_kilobytes gauge\n", .{});
    ap(buf, p, "# TYPE mandor_worker_cpu_percent gauge\n", .{});
    ap(buf, p, "# TYPE mandor_worker_fds gauge\n", .{});
    ap(buf, p, "# TYPE mandor_worker_threads gauge\n", .{});
    for (workers) |*w| {
        if (w.stats.len == 0 or w.pid <= 0) continue;
        const s = w.stats.at(w.stats.len - 1);
        ap(buf, p, "mandor_worker_rss_kilobytes{{worker=\"{s}\"}} {d}\n", .{ w.nameSlice(), s.rss_kb });
        ap(buf, p, "mandor_worker_cpu_percent{{worker=\"{s}\"}} {d}\n", .{ w.nameSlice(), s.cpu_pct });
        ap(buf, p, "mandor_worker_fds{{worker=\"{s}\"}} {d}\n", .{ w.nameSlice(), s.fds });
        ap(buf, p, "mandor_worker_threads{{worker=\"{s}\"}} {d}\n", .{ w.nameSlice(), s.threads });
    }
    ap(buf, p, "# TYPE mandor_incidents_total counter\n", .{});
    ap(buf, p, "mandor_incidents_total {d}\n", .{incidents_total});
    return buf[0..pos];
}

fn ap(buf: []u8, pos: *usize, comptime fmt: []const u8, args: anytype) void {
    const out = std.fmt.bufPrint(buf[pos.*..], fmt, args) catch return;
    pos.* += out.len;
}

// ------------------------------------------------------- Linux server

const linux = std.os.linux;
const posix = std.posix;

var body_buf: [32 * 1024]u8 = undefined;
var resp_buf: [33 * 1024]u8 = undefined;

pub const Server = struct {
    fd: i32,

    /// Bind 127.0.0.1:port. Returns null (with a stderr note) on failure —
    /// metrics are optional, supervision never depends on them.
    pub fn init(port: u16) ?Server {
        const rc = linux.socket(
            linux.AF.INET,
            linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC,
            0,
        );
        if (posix.errno(rc) != .SUCCESS) return null;
        const fd: i32 = @intCast(rc);
        const one: u32 = 1;
        _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, @ptrCast(&one), 4);
        var addr: linux.sockaddr.in = .{
            .port = std.mem.nativeToBig(u16, port),
            .addr = std.mem.nativeToBig(u32, 0x7f000001), // 127.0.0.1
        };
        if (posix.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
            _ = linux.close(fd);
            return null;
        }
        if (posix.errno(linux.listen(fd, 4)) != .SUCCESS) {
            _ = linux.close(fd);
            return null;
        }
        return .{ .fd = fd };
    }

    /// Accept + answer everything queued. Any request path gets the metrics.
    pub fn onReadable(self: *const Server, workers: []const spawner.Worker, incidents_total: u64) void {
        while (true) {
            const rc = linux.accept4(self.fd, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
            if (posix.errno(rc) != .SUCCESS) return;
            const conn: i32 = @intCast(rc);
            defer _ = linux.close(conn);
            var req: [1024]u8 = undefined;
            _ = linux.read(conn, &req, req.len); // request content is irrelevant
            const body = render(&body_buf, workers, incidents_total);
            const resp = std.fmt.bufPrint(&resp_buf, "HTTP/1.1 200 OK\r\n" ++
                "Content-Type: text/plain; version=0.0.4\r\n" ++
                "Content-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }) catch return;
            var off: usize = 0;
            while (off < resp.len) {
                const n = linux.write(conn, resp.ptr + off, resp.len - off);
                if (posix.errno(n) != .SUCCESS) break;
                off += n;
            }
        }
    }
};

// ---------------------------------------------------------------- tests

test "a full worker table still renders every series" {
    // The worst realistic case: the table at capacity, names at name_cap, and
    // counters wide enough to be near-maximum width. `ap` drops silently on
    // overflow and Content-Length is taken from whatever survived, so a
    // too-small body_buf loses metrics with no error anywhere.
    var workers: [64]spawner.Worker = undefined;
    for (&workers, 0..) |*w, i| {
        w.name_len = 32;
        for (0..32) |c| w.name[c] = 'a' + @as(u8, @intCast((i + c) % 26));
        w.pid = @intCast(i + 1);
        w.restarts = std.math.maxInt(u32);
        w.stats.next = 0;
        w.stats.len = 0;
        w.stats.push(.{
            .t_ms = 0,
            .rss_kb = std.math.maxInt(u64),
            .cpu_pct = 100,
            .fds = std.math.maxInt(u16),
            .threads = std.math.maxInt(u16),
        });
    }
    const text = render(&body_buf, &workers, std.math.maxInt(u64));

    // Every worker must appear in every metric family -- six lines each.
    for (&workers) |*w| {
        const n = w.nameSlice();
        var needle: [96]u8 = undefined;
        inline for (.{
            "mandor_worker_up{{worker=\"{s}\"}} ",
            "mandor_worker_restarts_total{{worker=\"{s}\"}} ",
            "mandor_worker_rss_kilobytes{{worker=\"{s}\"}} ",
            "mandor_worker_cpu_percent{{worker=\"{s}\"}} ",
            "mandor_worker_fds{{worker=\"{s}\"}} ",
            "mandor_worker_threads{{worker=\"{s}\"}} ",
        }) |fmt| {
            const want = try std.fmt.bufPrint(&needle, fmt, .{n});
            try std.testing.expect(std.mem.indexOf(u8, text, want) != null);
        }
    }
    // ...and the trailing counter, which is emitted last and so is the first
    // thing a silent truncation would eat.
    try std.testing.expect(std.mem.indexOf(u8, text, "mandor_incidents_total ") != null);

    // The rendered response must also fit the response buffer with headers.
    try std.testing.expect(text.len + 128 < resp_buf.len);

    // Worst case measures ~28.9KB against a 32KB buffer: it fits, but only by
    // ~3.8KB. One more metric family costs 64 workers * ~80 bytes = ~5KB and
    // would overflow -- silently, since `ap` drops on overflow and
    // Content-Length is taken from whatever survived. If this assertion fires,
    // grow body_buf and resp_buf together rather than shrinking the output.
    try std.testing.expect(text.len < body_buf.len);
}

test "renders prometheus text" {
    var workers: [1]spawner.Worker = undefined;
    const w = &workers[0];
    w.name_len = 3;
    @memcpy(w.name[0..3], "api");
    w.pid = 42;
    w.restarts = 3;
    w.stats.next = 0;
    w.stats.len = 0;
    w.stats.push(.{ .t_ms = 0, .rss_kb = 2048, .cpu_pct = 97, .fds = 12, .threads = 8 });

    var buf: [4096]u8 = undefined;
    const text = render(&buf, &workers, 5);
    try std.testing.expect(std.mem.indexOf(u8, text, "mandor_worker_up{worker=\"api\"} 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "mandor_worker_restarts_total{worker=\"api\"} 3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "mandor_worker_rss_kilobytes{worker=\"api\"} 2048\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "mandor_incidents_total 5\n") != null);
}
