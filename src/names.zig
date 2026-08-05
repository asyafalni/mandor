//! Worker display/telemetry name derivation — the single source of truth for how
//! a name is finalized. Shared by `spawner` (basename of argv0, the TOML `name`
//! override) and `config` (grant resolution keys on the same derived name that
//! `start_after` and the other name refs use). Keeping the algorithm and its cap
//! in one place means "the name a worker gets" and "the name a grant resolves to"
//! can never drift apart.

const std = @import("std");

/// Max stored name length (the `Worker.name` buffer size). `finalize` caps a
/// base to `cap - 4`, leaving room for a "-NN" dedup suffix within the cap.
pub const cap = 32;

/// Byte a name may not hold: the Prometheus exposition format has no escaping for
/// label values, so a quote/backslash/control byte would silently corrupt every
/// scrape. Neutralized to '_' before the name is stored. JSON sinks escape names
/// themselves, so this is the one place neutralization happens.
pub fn unsafeByte(c: u8) bool {
    return c == '"' or c == '\\' or c < 0x20;
}

/// The segment after the last '/'. Applied to argv0 so `./bin/api` names `api`.
pub fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}

/// Finalize `base` into `out`: length-cap (room for a "-NN" dedup suffix), dedup
/// against `prior` (append "-N" when `base` — or an earlier `base-…` — already
/// appears), then neutralize Prometheus-unsafe bytes. Returns `out[0..n]`.
/// `out` must be at least `cap` bytes.
pub fn finalize(base_in: []const u8, prior: []const []const u8, out: []u8) []const u8 {
    var base = base_in;
    if (base.len > cap - 4) base = base[0 .. cap - 4];
    var dupes: usize = 0;
    for (prior) |pn| {
        if (std.mem.eql(u8, pn, base) or
            (pn.len > base.len + 1 and std.mem.startsWith(u8, pn, base) and pn[base.len] == '-'))
        {
            dupes += 1;
        }
    }
    @memcpy(out[0..base.len], base);
    var n: usize = base.len;
    if (dupes != 0) {
        const suffix = std.fmt.bufPrint(out[base.len..], "-{d}", .{dupes + 1}) catch
            out[base.len..base.len];
        n = base.len + suffix.len;
    }
    for (out[0..n]) |*c| {
        if (unsafeByte(c.*)) c.* = '_';
    }
    return out[0..n];
}

// -------------------------------------------------------------------- tests

const t = std.testing;

test "basename takes the last path segment" {
    try t.expectEqualStrings("api", basename("./bin/api"));
    try t.expectEqualStrings("api", basename("api"));
    try t.expectEqualStrings("api", basename("/usr/local/bin/api"));
}

test "finalize passes a unique name through unchanged" {
    var buf: [cap]u8 = undefined;
    try t.expectEqualStrings("sh", finalize("sh", &.{}, &buf));
}

test "finalize dedups with a -N suffix" {
    var buf: [cap]u8 = undefined;
    try t.expectEqualStrings("sh-2", finalize("sh", &.{"sh"}, &buf));
    try t.expectEqualStrings("sh-3", finalize("sh", &.{ "sh", "sh-2" }, &buf));
}

test "finalize caps a long base leaving room for the suffix" {
    var buf: [cap]u8 = undefined;
    const long = "a" ** 40;
    const out = finalize(long, &.{}, &buf);
    try t.expectEqual(@as(usize, cap - 4), out.len); // 28
}

test "finalize neutralizes Prometheus-unsafe bytes" {
    var buf: [cap]u8 = undefined;
    try t.expectEqualStrings("a_b_", finalize("a\"b\x01", &.{}, &buf));
}
