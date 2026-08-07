//! Tier 2 curated warn/error digest: a bounded, dedup'd, flood-proof-by-
//! construction accumulator for warn/error log lines. Free-tier heuristic —
//! NO LLM, NO network here. This module owns ONLY the data structure and its
//! record/query API; the periodic emission + timer + config is Task 4 and lives
//! elsewhere. It is NOT wired into the supervisor capture hot path yet.
//!
//! Dedup reuses `summarize.signature` (FNV-1a, digits stripped), so identical
//! lines that differ only in numbers ("conn 17 refused" == "conn 42 refused")
//! collapse into ONE counted entry. A flood of a million identical lines becomes
//! a single entry with count=1_000_000; a flood of DISTINCT signatures past the
//! table cap collapses into the `overflow_lines` counter. Memory and CPU are
//! bounded regardless of input rate.
//!
//! Module-level fixed BSS state, zero allocation, saturating arithmetic, no
//! `unreachable`/panic. The O(max_sigs) linear scan is fine: max_sigs is small
//! and this is the curated tier, off the per-line-critical path.

const std = @import("std");
const summarize = @import("summarize.zig");

/// Caps. BSS cost per entry is ~360 bytes (scalars + name + sample buffers, 8B
/// aligned), so max_sigs entries ≈ 23 KB of BSS — an accepted cost for the
/// digest feature. Kept modest deliberately: this is a curated summary, not a
/// log store.
pub const max_sigs: usize = 64;
pub const name_cap: usize = 64;
pub const sample_cap: usize = 256;

/// One deduplicated warn/error signature seen this window.
pub const Entry = struct {
    /// summarize.signature(sevLabel, name, line) — the dedup key.
    sig: u64 = 0,
    /// How many lines collapsed into this signature this window (saturating).
    count: u32 = 0,
    /// First sighting (ns), preserved across repeats.
    first_ns: u64 = 0,
    /// Most recent sighting (ns).
    last_ns: u64 = 0,
    /// Max severity seen for this signature: 1 = warn, 2 = error.
    sev: u8 = 0,
    name_len: u16 = 0,
    sample_len: u16 = 0,
    /// Owning worker name, truncated to name_cap (preserved from first sight).
    name_buf: [name_cap]u8 = undefined,
    /// First raw line for this signature, truncated to sample_cap.
    sample_buf: [sample_cap]u8 = undefined,

    pub fn nameSlice(self: *const Entry) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    pub fn sampleSlice(self: *const Entry) []const u8 {
        return self.sample_buf[0..self.sample_len];
    }
};

// --------------------------------------------------------- module-level state

var entries: [max_sigs]Entry = [_]Entry{.{}} ** max_sigs;
var live: usize = 0;
/// Distinct-signature lines that arrived while the table was full — the
/// "+N more warn/error lines" bucket. Counted, never dropped silently.
var overflow_lines: u64 = 0;
/// Total warn/error lines accepted since the last clear (dedup'd + overflowed).
/// Task 4 uses this for the threshold early-flush decision.
var pending_total: u64 = 0;

// ---------------------------------------------------------------------- record

/// Accumulate one warn/error line into the window table. Cheap, non-blocking,
/// zero-alloc, saturating. Designed to be called from the capture path (Task 4).
///
/// - `sev`: 1 = warn, 2 = error (matches capture.severityFromFlags). `sev == 0`
///   (info) is ignored defensively — the caller only feeds warn/error.
/// - The signature's cause-kind is a severity LABEL ("warn"/"error"), so a warn
///   and an error with identical text stay in SEPARATE buckets.
pub fn record(name: []const u8, sev: u8, t_ns: u64, line: []const u8) void {
    if (sev == 0) return; // info: not part of the digest
    pending_total +|= 1;

    const label: []const u8 = if (sev >= 2) "error" else "warn";
    const sig = summarize.signature(label, name, line);

    // Linear scan the live entries for a matching signature.
    for (entries[0..live]) |*e| {
        if (e.sig == sig) {
            e.count +|= 1;
            e.last_ns = t_ns;
            if (sev > e.sev) e.sev = sev; // defensive: sig encodes sev, so this
            // never actually raises given the caller contract — but it costs
            // nothing and keeps the invariant true under a hash collision.
            return; // first sample/name/first_ns intentionally preserved
        }
    }

    // New signature. If the table is full, collapse into the overflow bucket.
    if (live == max_sigs) {
        overflow_lines +|= 1;
        return;
    }

    // Fill a fresh entry, copying name/line truncated to the fixed caps.
    const e = &entries[live];
    e.sig = sig;
    e.count = 1;
    e.first_ns = t_ns;
    e.last_ns = t_ns;
    e.sev = sev;

    const nl = @min(name.len, name_cap);
    @memcpy(e.name_buf[0..nl], name[0..nl]);
    e.name_len = @intCast(nl);

    const sl = @min(line.len, sample_cap);
    @memcpy(e.sample_buf[0..sl], line[0..sl]);
    e.sample_len = @intCast(sl);

    live += 1;
}

// ----------------------------------------------------------------- query / view

/// Number of live (distinct) entries in the current window.
pub fn count() usize {
    return live;
}

/// Read entry `i` (0 <= i < count()). Zero-copy view; slices via
/// `entry.nameSlice()` / `entry.sampleSlice()`.
pub fn get(i: usize) *const Entry {
    return &entries[i];
}

/// Distinct-signature lines dropped into the overflow bucket this window.
pub fn overflowLines() u64 {
    return overflow_lines;
}

/// Total warn/error lines recorded since the last clear (all buckets summed:
/// dedup'd repeats + new entries + overflow). Task 4's early-flush threshold.
pub fn pending() u64 {
    return pending_total;
}

/// Reset the table and all counters for the next window. Task 4 calls this
/// immediately after emitting a digest snapshot.
pub fn clear() void {
    live = 0;
    overflow_lines = 0;
    pending_total = 0;
}

// ---------------------------------------------------------------------- tests

const testing = std.testing;

/// Build a distinct (digit-free, so signatures don't collapse) line for the i-th
/// bucket. Two letters give 26*26 = 676 distinct signatures — plenty.
fn distinctLine(buf: *[6]u8, i: usize) []const u8 {
    buf[0] = 'e';
    buf[1] = 'r';
    buf[2] = 'r';
    buf[3] = ' ';
    buf[4] = 'a' + @as(u8, @intCast(i / 26));
    buf[5] = 'a' + @as(u8, @intCast(i % 26));
    return buf[0..6];
}

test "digest: dedup collapses digit-variants into one counted entry" {
    clear();
    record("api", 2, 100, "conn 17 refused");
    record("api", 2, 200, "conn 42 refused");
    record("api", 2, 300, "conn 9999 refused");

    try testing.expectEqual(@as(usize, 1), count());
    try testing.expectEqual(@as(u64, 3), pending());

    const e = get(0);
    try testing.expectEqual(@as(u32, 3), e.count);
    try testing.expectEqual(@as(u64, 100), e.first_ns); // first preserved
    try testing.expectEqual(@as(u64, 300), e.last_ns); // last updated
    try testing.expectEqualStrings("conn 17 refused", e.sampleSlice()); // FIRST sample
    try testing.expectEqualStrings("api", e.nameSlice());
    try testing.expectEqual(@as(u8, 2), e.sev);
}

test "digest: warn and error with identical text are separate buckets" {
    clear();
    record("api", 1, 10, "disk pressure high");
    record("api", 2, 20, "disk pressure high");
    try testing.expectEqual(@as(usize, 2), count());

    // Locate each bucket by severity.
    var warn_seen = false;
    var err_seen = false;
    var i: usize = 0;
    while (i < count()) : (i += 1) {
        switch (get(i).sev) {
            1 => warn_seen = true,
            2 => err_seen = true,
            else => {},
        }
    }
    try testing.expect(warn_seen and err_seen);

    // Repeat the error bucket: sev stays at max (defensive branch exercised).
    record("api", 2, 30, "disk pressure high");
    try testing.expectEqual(@as(usize, 2), count()); // no new bucket
}

test "digest: distinct signatures each get their own entry" {
    clear();
    record("w", 2, 1, "alpha failed");
    record("w", 2, 2, "beta failed");
    record("w", 2, 3, "gamma failed");
    try testing.expectEqual(@as(usize, 3), count());
    try testing.expectEqual(@as(u64, 0), overflowLines());
}

test "digest: table-full flood collapses to overflow, live entries still update" {
    clear();
    var buf: [6]u8 = undefined;

    var i: usize = 0;
    while (i < max_sigs) : (i += 1) record("w", 2, i, distinctLine(&buf, i));
    try testing.expectEqual(max_sigs, count());
    try testing.expectEqual(@as(u64, 0), overflowLines());

    // 10 more DISTINCT signatures: table is full → overflow counter, no growth.
    var j: usize = 0;
    while (j < 10) : (j += 1) record("w", 2, 999, distinctLine(&buf, max_sigs + j));
    try testing.expectEqual(max_sigs, count());
    try testing.expectEqual(@as(u64, 10), overflowLines());

    // An existing signature still updates even when the table is full.
    const before = get(0).count;
    record("w", 2, 1000, distinctLine(&buf, 0));
    try testing.expectEqual(before + 1, get(0).count);
    try testing.expectEqual(@as(u64, 10), overflowLines()); // repeat != overflow
}

test "digest: over-cap name and line are stored truncated" {
    clear();
    const long_name = "n" ** (name_cap + 50);
    const long_line = "L" ** (sample_cap + 100); // digit-free
    record(long_name, 2, 5, long_line);

    const e = get(0);
    try testing.expectEqual(name_cap, e.nameSlice().len);
    try testing.expectEqual(sample_cap, e.sampleSlice().len);
    try testing.expectEqual(@as(usize, 1), count());
}

test "digest: clear resets entries, pending, and overflow" {
    clear();
    var buf: [6]u8 = undefined;
    record("w", 2, 1, "boom");
    record("w", 2, 2, "boom");
    var i: usize = 0;
    while (i < max_sigs + 5) : (i += 1) record("w", 2, i, distinctLine(&buf, i));
    try testing.expect(count() > 0);
    try testing.expect(pending() > 0);
    try testing.expect(overflowLines() > 0);

    clear();
    try testing.expectEqual(@as(usize, 0), count());
    try testing.expectEqual(@as(u64, 0), pending());
    try testing.expectEqual(@as(u64, 0), overflowLines());
}

test "digest: info severity is a no-op" {
    clear();
    record("w", 0, 1, "just fyi");
    try testing.expectEqual(@as(usize, 0), count());
    try testing.expectEqual(@as(u64, 0), pending());
}
