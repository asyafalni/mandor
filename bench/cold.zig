//! Cold-path complexity check: the two largest theoretical terms in mandor.
//!
//! 1. Compactor.feed  — O(distinct) linear scan per line, over the WHOLE ring
//!    (256 KB, so ~10k short lines) with cap 200. Worst case is all-distinct
//!    lines: the table fills, then every later line scans all 200 and is
//!    dropped.
//! 2. listIncidents insertion sort — O(n^2) at n = 216.
//!
//! Both run per incident, i.e. exactly when a worker is crashing.
const std = @import("std");

fn signature(cause_kind: []const u8, name: []const u8, err_line: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (cause_kind) |c| h = (h ^ c) *% 0x100000001b3;
    h = (h ^ 0xff) *% 0x100000001b3;
    for (name) |c| h = (h ^ c) *% 0x100000001b3;
    h = (h ^ 0xff) *% 0x100000001b3;
    for (err_line) |c| {
        if (c >= '0' and c <= '9') continue;
        h = (h ^ c) *% 0x100000001b3;
    }
    return h;
}

const cap = 200;

const Compactor = struct {
    hashes: [cap]u64 = undefined,
    counts: [cap]u32 = undefined,
    n: usize = 0,
    dropped: u32 = 0,

    fn feed(self: *Compactor, text: []const u8) void {
        const h = signature("", "", text);
        for (self.hashes[0..self.n], 0..) |seen, i| {
            if (seen == h) {
                self.counts[i] += 1;
                return;
            }
        }
        if (self.n == cap) {
            self.dropped += 1;
            return;
        }
        self.hashes[self.n] = h;
        self.counts[self.n] = 1;
        self.n += 1;
    }
};

fn nowNs() u64 {
    var ts = std.os.linux.timespec{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @intCast(ts.sec * 1_000_000_000 + ts.nsec);
}

const Entry = struct { key: u64, name: [64]u8 };

pub fn main() void {
    // --- 1. compactor over a full ring, worst case: every line distinct ---
    var line_buf: [64]u8 = undefined;
    const lines_in_ring = 10_000; // 256 KB of short lines

    var t0 = nowNs();
    var c: Compactor = .{};
    for (0..lines_in_ring) |i| {
        // Distinct text that is NOT digit-only-different, since signature
        // strips digits -- otherwise every line would collapse to one entry
        // and the scan would never grow.
        const text = std.fmt.bufPrint(&line_buf, "worker task {c}{c} failed to acquire lease", .{
            @as(u8, 'a' + @as(u8, @intCast(i % 26))),
            @as(u8, 'a' + @as(u8, @intCast((i / 26) % 26))),
        }) catch unreachable;
        c.feed(text);
    }
    const compact_ns = nowNs() - t0;

    // --- 2. insertion sort at the prune buffer size ---
    var entries: [216]Entry = undefined;
    var seed: u64 = 12345;
    for (&entries) |*e| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        e.key = seed >> 32;
    }
    t0 = nowNs();
    var rounds: usize = 0;
    while (rounds < 100) : (rounds += 1) {
        var work = entries;
        var i: usize = 1;
        while (i < work.len) : (i += 1) {
            const tmp = work[i];
            var j = i;
            while (j > 0 and work[j - 1].key > tmp.key) : (j -= 1) work[j] = work[j - 1];
            work[j] = tmp;
        }
        std.mem.doNotOptimizeAway(&work);
    }
    const sort_ns = (nowNs() - t0) / 100;

    std.debug.print(
        \\compactor  {d} lines (full 256KB ring, all distinct)
        \\           {d:>9} ns  ({d} entries kept, {d} dropped)
        \\sort       216 entries, insertion sort
        \\           {d:>9} ns
        \\
    , .{ lines_in_ring, compact_ns, c.n, c.dropped, sort_ns });
}
