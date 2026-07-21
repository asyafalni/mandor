//! Restart backoff math and restart-policy decisions. Pure — tests run anywhere.

const std = @import("std");

pub const initial_delay_ms: u64 = 200;
/// A run at least this long is considered stable; backoff resets.
pub const stable_uptime_ms: u64 = 10_000;

/// Next restart delay. `prev_delay_ms == 0` means first restart.
pub fn next(prev_delay_ms: u64, uptime_ms: u64, max_ms: u64) u64 {
    // Every path clamps: `max_ms` is a cap, so a reset must respect it too.
    if (uptime_ms >= stable_uptime_ms) return @min(initial_delay_ms, max_ms);
    if (prev_delay_ms == 0) return @min(initial_delay_ms, max_ms);
    return @min(prev_delay_ms *| 2, max_ms);
}

// ---------------------------------------------------------------- tests

const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

test "first restart uses initial delay" {
    try expectEqual(@as(u64, 200), next(0, 0, 30_000));
}

test "delay doubles up to max" {
    try expectEqual(@as(u64, 400), next(200, 1_000, 30_000));
    try expectEqual(@as(u64, 800), next(400, 0, 30_000));
    try expectEqual(@as(u64, 30_000), next(20_000, 0, 30_000));
    try expectEqual(@as(u64, 30_000), next(30_000, 0, 30_000));
}

test "stable uptime resets backoff" {
    try expectEqual(@as(u64, 200), next(6_400, 11_000, 30_000));
    try expectEqual(@as(u64, 200), next(6_400, 10_000, 30_000));
    try expectEqual(@as(u64, 12_800), next(6_400, 9_999, 30_000));
}

test "max smaller than initial clamps" {
    try expectEqual(@as(u64, 100), next(0, 0, 100));
    try expectEqual(@as(u64, 100), next(100, 0, 100));
    // The stable-uptime reset is a path too: it used to return the raw
    // initial delay and overshoot a cap below 200ms.
    try expectEqual(@as(u64, 100), next(6_400, 11_000, 100));
}
