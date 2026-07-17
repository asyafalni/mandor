//! Incident trigger state machines: restart-loop window, RSS-climb leak
//! heuristic, and signature dedup. Pure — lives per-worker, tested anywhere.

const std = @import("std");
const sampler = @import("sampler.zig");

pub const restart_loop_threshold: u32 = 5;
pub const restart_loop_window_ms: u64 = 5 * 60 * 1000;
pub const restart_loop_rearm_ms: u64 = 10 * 60 * 1000;
pub const leak_min_growth_kb: u64 = 32 * 1024;
pub const leak_min_consecutive: usize = 6;
pub const leak_cooldown_ms: u64 = 30 * 60 * 1000;
pub const dedup_cooldown_ms: u64 = 10 * 60 * 1000;

pub const LeakInfo = struct { growth_mb: u64, minutes: u64 };

pub const State = struct {
    death_times: [restart_loop_threshold]u64 = .{0} ** restart_loop_threshold,
    death_next: u8 = 0,
    loop_fired_at_ms: u64 = 0,
    leak_fired_at_ms: u64 = 0,
    last_sig: u64 = 0,
    last_sig_at_ms: u64 = 0,
    suppressed: u32 = 0,

    pub fn recordDeath(self: *State, now_ms: u64) void {
        self.death_times[self.death_next] = now_ms;
        self.death_next = @intCast((self.death_next + 1) % restart_loop_threshold);
    }

    /// After recordDeath: did this death cross the restart-loop threshold?
    /// Returns the count in the window exactly when firing (with re-arm).
    pub fn restartLoopTriggered(self: *State, now_ms: u64) ?u32 {
        var in_window: u32 = 0;
        for (self.death_times) |death_t| {
            if (death_t != 0 and now_ms -| death_t <= restart_loop_window_ms) in_window += 1;
        }
        if (in_window < restart_loop_threshold) return null;
        if (self.loop_fired_at_ms != 0 and
            now_ms -| self.loop_fired_at_ms < restart_loop_rearm_ms) return null;
        self.loop_fired_at_ms = now_ms;
        return in_window;
    }

    /// Monotonic RSS climb over the sample window.
    pub fn leakCheck(self: *State, w: *const sampler.Window, now_ms: u64) ?LeakInfo {
        if (self.leak_fired_at_ms != 0 and
            now_ms -| self.leak_fired_at_ms < leak_cooldown_ms) return null;
        if (w.len < leak_min_consecutive + 1) return null;
        // longest strictly-increasing suffix of the window
        var suffix_start: usize = w.len - 1;
        var i: usize = w.len - 1;
        while (i > 0) : (i -= 1) {
            if (w.at(i).rss_kb > w.at(i - 1).rss_kb) suffix_start = i - 1 else break;
        }
        const climbs = w.len - 1 - suffix_start;
        if (climbs < leak_min_consecutive) return null;
        const first = w.at(suffix_start);
        const last = w.at(w.len - 1);
        const growth_kb = last.rss_kb -| first.rss_kb;
        if (growth_kb < leak_min_growth_kb) return null;
        self.leak_fired_at_ms = now_ms;
        return .{
            .growth_mb = growth_kb / 1024,
            .minutes = @max((last.t_ms -| first.t_ms) / 60_000, 1),
        };
    }

    /// Signature dedup gate: identical incident within cooldown is suppressed.
    pub fn shouldEmit(self: *State, sig: u64, now_ms: u64) bool {
        if (sig == self.last_sig and now_ms -| self.last_sig_at_ms < dedup_cooldown_ms) {
            self.suppressed += 1;
            return false;
        }
        self.last_sig = sig;
        self.last_sig_at_ms = now_ms;
        return true;
    }
};

// ---------------------------------------------------------------- tests

const t = std.testing;

test "restart loop fires at threshold, re-arms after cooldown" {
    var s: State = .{};
    var now: u64 = 100_000;
    for (0..4) |_| {
        s.recordDeath(now);
        try t.expectEqual(@as(?u32, null), s.restartLoopTriggered(now));
        now += 10_000;
    }
    s.recordDeath(now);
    try t.expectEqual(@as(?u32, 5), s.restartLoopTriggered(now));
    // immediately after: suppressed
    s.recordDeath(now + 1000);
    try t.expectEqual(@as(?u32, null), s.restartLoopTriggered(now + 1000));
    // after re-arm window with fresh deaths: fires again
    var later = now + restart_loop_rearm_ms + 1;
    for (0..5) |_| {
        s.recordDeath(later);
        later += 1000;
    }
    try t.expect(s.restartLoopTriggered(later) != null);
}

test "slow crashers never trigger the loop" {
    var s: State = .{};
    var now: u64 = 0;
    for (0..20) |_| {
        now += restart_loop_window_ms; // one death per window — never 5 inside
        s.recordDeath(now);
        try t.expectEqual(@as(?u32, null), s.restartLoopTriggered(now));
    }
}

test "leak fires on monotonic climb with enough growth" {
    var s: State = .{};
    var w: sampler.Window = .{};
    var rss: u64 = 100 * 1024;
    var tms: u64 = 0;
    for (0..8) |_| {
        w.push(.{ .t_ms = tms, .rss_kb = rss });
        rss += 8 * 1024; // +8MB per 5s sample
        tms += 5_000;
    }
    const info = s.leakCheck(&w, tms).?;
    try t.expectEqual(@as(u64, 56), info.growth_mb);
    // cooldown suppresses immediate refire
    try t.expectEqual(@as(?LeakInfo, null), s.leakCheck(&w, tms + 1000));
}

test "leak does not fire on flat or sawtooth rss" {
    var s: State = .{};
    var w: sampler.Window = .{};
    for (0..10) |i| {
        const rss: u64 = if (i % 2 == 0) 100 * 1024 else 140 * 1024;
        w.push(.{ .t_ms = i * 5_000, .rss_kb = rss });
    }
    try t.expectEqual(@as(?LeakInfo, null), s.leakCheck(&w, 60_000));
    var w2: sampler.Window = .{};
    for (0..10) |i| w2.push(.{ .t_ms = i * 5_000, .rss_kb = 100 * 1024 });
    try t.expectEqual(@as(?LeakInfo, null), s.leakCheck(&w2, 60_000));
}

test "dedup suppresses identical signature within cooldown" {
    var s: State = .{};
    try t.expect(s.shouldEmit(0xabc, 1000));
    try t.expect(!s.shouldEmit(0xabc, 2000));
    try t.expectEqual(@as(u32, 1), s.suppressed);
    try t.expect(s.shouldEmit(0xdef, 3000)); // different signature passes
    try t.expect(s.shouldEmit(0xabc, 3000 + dedup_cooldown_ms + 1));
}
