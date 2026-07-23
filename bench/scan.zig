//! Micro-benchmark for the incident-path substring scan.
//!
//! `errorish` runs six `containsIgnoreCase` calls per log line, over a 200-line
//! tail, every time a worker dies. This measures the current naive scan against
//! a first-byte fast reject, on input shaped like real logs: mostly lines that
//! do NOT match, which is the case the scan spends its time on.
const std = @import("std");

fn containsNaive(haystack: []const u8, comptime needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len and std.ascii.toLower(haystack[i + j]) == needle[j]) j += 1;
        if (j == needle.len) return true;
    }
    return false;
}

fn containsFast(haystack: []const u8, comptime needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    // Needles are comptime lowercase; check the first byte before entering the
    // inner loop so non-matching positions cost one compare instead of one
    // compare per needle character.
    const c0 = needle[0];
    const c0_up = std.ascii.toUpper(needle[0]);
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        const h = haystack[i];
        if (h != c0 and h != c0_up) continue;
        var j: usize = 1;
        while (j < needle.len and std.ascii.toLower(haystack[i + j]) == needle[j]) j += 1;
        if (j == needle.len) return true;
    }
    return false;
}

const needles = .{ "panic", "error", "fatal", "exception", "traceback", "warn" };

fn errorishNaive(line: []const u8) bool {
    inline for (needles) |n| if (containsNaive(line, n)) return true;
    return false;
}

fn errorishFast(line: []const u8) bool {
    inline for (needles) |n| if (containsFast(line, n)) return true;
    return false;
}

pub fn main() void {
    // A realistic tail: mostly ordinary lines, a few real errors. Non-matching
    // lines dominate, which is where the scan actually spends its time.
    var lines: [200][]const u8 = undefined;
    const ordinary = "2026-07-22T11:00:00Z INF request completed method=GET path=/api/v1/things status=200 duration_ms=13 bytes=4096 remote=10.0.0.42 trace=abc123def456 user=svc-account-7 region=ap-southeast-1";
    const matching = "2026-07-22T11:00:00Z ERROR upstream refused connection after 3 retries";
    for (&lines, 0..) |*l, i| l.* = if (i % 25 == 24) matching else ordinary;

    const rounds = 2000;
    var sink: usize = 0;

    var t0 = std.os.linux.timespec{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &t0);
    for (0..rounds) |_| for (lines) |l| {
        if (errorishNaive(l)) sink += 1;
    };
    var t1 = std.os.linux.timespec{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &t1);
    const naive_ns: u64 = @intCast((t1.sec - t0.sec) * 1_000_000_000 + (t1.nsec - t0.nsec));

    _ = std.os.linux.clock_gettime(.MONOTONIC, &t0);
    for (0..rounds) |_| for (lines) |l| {
        if (errorishFast(l)) sink += 1;
    };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &t1);
    const fast_ns: u64 = @intCast((t1.sec - t0.sec) * 1_000_000_000 + (t1.nsec - t0.nsec));

    const per_incident_naive = naive_ns / rounds;
    const per_incident_fast = fast_ns / rounds;
    std.debug.print(
        \\lines/tail      200   ({d} bytes each)
        \\naive           {d:>8} ns per incident tail
        \\first-byte      {d:>8} ns per incident tail
        \\speedup         {d:>8.2}x
        \\(sink {d})
        \\
    , .{
        ordinary.len,
        per_incident_naive,
        per_incident_fast,
        @as(f64, @floatFromInt(per_incident_naive)) / @as(f64, @floatFromInt(@max(per_incident_fast, 1))),
        sink,
    });
}
