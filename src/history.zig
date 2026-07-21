//! Persistent incident history: signature -> {first_seen, count, builds}.
//! Survives supervisor restarts via <state-dir>/history.json so bundles can
//! say "5th time this exact crash since Tuesday" instead of "brand new" AND
//! "seen across 2 builds (v1.4.1 -> v1.4.2)" — i.e. whether the owner's fix
//! actually held. The build correlation is the feedback edge of the premium
//! incident -> AI-fix -> redeploy loop.

const std = @import("std");
const jb = @import("jsonbuf.zig");
const report = @import("report.zig");

pub const max_entries = 64;
/// Cap on a stored release string (full git sha is 40; semver tags shorter).
pub const max_build = 40;

pub const Entry = struct {
    sig: u64,
    first_seen: i64, // epoch seconds
    last_seen: i64,
    count: u32,
    /// Distinct builds this signature has recurred across (0 = no release
    /// wired). >=2 means the crash survived a code change — a regression.
    builds: u32,
    first_build: [max_build]u8,
    first_build_len: u8,
    last_build: [max_build]u8,
    last_build_len: u8,

    pub fn firstBuild(self: *const Entry) []const u8 {
        return self.first_build[0..self.first_build_len];
    }
    pub fn lastBuild(self: *const Entry) []const u8 {
        return self.last_build[0..self.last_build_len];
    }
};

var entries: [max_entries]Entry = undefined;
var n: usize = 0;

fn safeBuildChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
        (c >= '0' and c <= '9') or c == '.' or c == '-' or c == '_' or
        c == '+' or c == ':' or c == '@' or c == '/';
}

/// Copy a release string into a fixed slot, truncated to max_build and
/// sanitized to a quote/backslash-free charset so it serializes with a plain
/// %s and the naive loader can never be broken by a hostile env value.
fn setBuild(dst: *[max_build]u8, dst_len: *u8, build: []const u8) void {
    const len = @min(build.len, max_build);
    for (build[0..len], 0..) |c, i| dst[i] = if (safeBuildChar(c)) c else '_';
    dst_len.* = @intCast(len);
}

/// Note the current build against an entry: sets first/last on first sight,
/// and on a *changed* build bumps `builds` (the regression signal).
fn noteBuild(e: *Entry, build: []const u8) void {
    if (build.len == 0) return; // no MANDOR_RELEASE / GIT_SHA — degrade silently
    var tmp: [max_build]u8 = undefined;
    var tlen: u8 = 0;
    setBuild(&tmp, &tlen, build);
    if (e.builds == 0) {
        @memcpy(e.first_build[0..tlen], tmp[0..tlen]);
        e.first_build_len = tlen;
        @memcpy(e.last_build[0..tlen], tmp[0..tlen]);
        e.last_build_len = tlen;
        e.builds = 1;
        return;
    }
    if (!std.mem.eql(u8, e.lastBuild(), tmp[0..tlen])) {
        @memcpy(e.last_build[0..tlen], tmp[0..tlen]);
        e.last_build_len = tlen;
        e.builds += 1;
    }
}

/// Bump (or insert) a signature under the current build; evicts the stalest
/// entry when full. `build` is the MANDOR_RELEASE/GIT_SHA passthrough ("" ok).
pub fn record(sig: u64, now_epoch: i64, build: []const u8) Entry {
    for (entries[0..n]) |*e| {
        if (e.sig == sig) {
            e.count += 1;
            e.last_seen = now_epoch;
            noteBuild(e, build);
            return e.*;
        }
    }
    var slot: usize = n;
    if (n == max_entries) {
        slot = 0;
        for (entries[0..n], 0..) |e, i| {
            if (e.last_seen < entries[slot].last_seen) slot = i;
        }
    } else {
        n += 1;
    }
    entries[slot] = .{
        .sig = sig,
        .first_seen = now_epoch,
        .last_seen = now_epoch,
        .count = 1,
        .builds = 0,
        .first_build = undefined,
        .first_build_len = 0,
        .last_build = undefined,
        .last_build_len = 0,
    };
    noteBuild(&entries[slot], build);
    return entries[slot];
}

pub fn serialize(buf: []u8) ?[]const u8 {
    var pos: usize = 0;
    const p = &pos;
    if (!jb.appendf(buf, p, "{{\"v\":2,\"entries\":[", .{})) return null;
    for (entries[0..n], 0..) |e, i| {
        if (i > 0 and !jb.appendf(buf, p, ",", .{})) return null;
        if (!jb.appendf(buf, p, "{{\"sig\":\"{x:0>16}\",\"first\":{d},\"last\":{d},\"count\":{d},\"builds\":{d},\"fb\":\"{s}\",\"lb\":\"{s}\"}}", .{
            e.sig, e.first_seen, e.last_seen, e.count, e.builds, e.firstBuild(), e.lastBuild(),
        })) return null;
    }
    if (!jb.appendf(buf, p, "]}}", .{})) return null;
    return buf[0..pos];
}

/// Replace the in-memory table from serialized text (bad entries skipped).
pub fn loadFromText(text: []const u8) void {
    n = 0;
    var it: usize = 0;
    const pat = "{\"sig\":\"";
    while (std.mem.indexOfPos(u8, text, it, pat)) |i| : (it = i + pat.len) {
        if (n == max_entries) return;
        const hex_start = i + pat.len;
        if (hex_start + 16 > text.len) return;
        const chunk_end = std.mem.indexOfScalarPos(u8, text, hex_start, '}') orelse return;
        const chunk = text[i..chunk_end];
        const sig = std.fmt.parseInt(u64, text[hex_start..][0..16], 16) catch continue;
        var e: Entry = .{
            .sig = sig,
            .first_seen = report.clamp(i64, report.scanU64(chunk, "first") orelse continue),
            .last_seen = report.clamp(i64, report.scanU64(chunk, "last") orelse continue),
            .count = report.clamp(u32, report.scanU64(chunk, "count") orelse continue),
            // builds/fb/lb absent in v1 files -> 0/empty (backward compatible).
            .builds = report.clamp(u32, report.scanU64(chunk, "builds") orelse 0),
            .first_build = undefined,
            .first_build_len = 0,
            .last_build = undefined,
            .last_build_len = 0,
        };
        if (report.scanStr(chunk, "fb")) |fb| setBuild(&e.first_build, &e.first_build_len, fb);
        if (report.scanStr(chunk, "lb")) |lb| setBuild(&e.last_build, &e.last_build_len, lb);
        entries[n] = e;
        n += 1;
    }
}

// ------------------------------------------------------- Linux load/save

const linux = std.os.linux;
const posix = std.posix;

var file_buf: [16 * 1024]u8 = undefined;

pub fn load(state_dir: []const u8) void {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/history.json", .{state_dir}) catch return;
    const rc = linux.openat(linux.AT.FDCWD, path.ptr, .{}, 0);
    if (posix.errno(rc) != .SUCCESS) return;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    // Looped: one read() may return short, and a partial history parses as a
    // smaller history rather than an error — quietly losing recurrence counts,
    // which is the data that answers "did the last fix hold?". A full buffer
    // means the file is bigger than anything serialize() can produce (measured
    // worst case 13,907 of 16,384), so it has been tampered with or truncated;
    // ignore it rather than restore half of it.
    var got: usize = 0;
    while (got < file_buf.len) {
        const r = linux.read(fd, file_buf[got..].ptr, file_buf.len - got);
        if (posix.errno(r) != .SUCCESS) return;
        if (r == 0) break;
        got += r;
    }
    if (got == file_buf.len) return;
    loadFromText(file_buf[0..got]);
}

pub fn save(state_dir: []const u8) void {
    const json = serialize(&file_buf) orelse return;
    var path_buf: [512]u8 = undefined;
    var tmp_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/history.json", .{state_dir}) catch return;
    const tmp = std.fmt.bufPrintZ(&tmp_buf, "{s}/.history.tmp", .{state_dir}) catch return;
    const rc = linux.openat(linux.AT.FDCWD, tmp.ptr, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
    }, 0o644);
    if (posix.errno(rc) != .SUCCESS) return;
    const fd: i32 = @intCast(rc);
    var off: usize = 0;
    while (off < json.len) {
        const wrote = linux.write(fd, json.ptr + off, json.len - off);
        if (posix.errno(wrote) != .SUCCESS) break;
        off += wrote;
    }
    _ = linux.close(fd);
    if (off == json.len) _ = linux.rename(tmp.ptr, path.ptr);
}

// ---------------------------------------------------------------- tests

test "a full history table still serializes and fits the load buffer" {
    // Worst case: every slot used, both build strings at max_build, and every
    // counter near maximum width. serialize() returning null means save()
    // writes nothing and recurrence history silently stops persisting.
    n = 0;
    for (0..max_entries) |i| _ = record(@intCast(i + 1), @intCast(i), "v1");
    for (0..max_entries) |i| {
        entries[i].sig = std.math.maxInt(u64);
        entries[i].first_seen = std.math.maxInt(i64);
        entries[i].last_seen = std.math.maxInt(i64);
        entries[i].count = std.math.maxInt(u32);
        entries[i].builds = std.math.maxInt(u32);
        entries[i].first_build_len = max_build;
        entries[i].last_build_len = max_build;
        for (0..max_build) |j| {
            entries[i].first_build[j] = 'a' + @as(u8, @intCast((i + j) % 26));
            entries[i].last_build[j] = 'z' - @as(u8, @intCast((i + j) % 26));
        }
    }

    var buf: [file_buf.len]u8 = undefined;
    const json = serialize(&buf);
    try std.testing.expect(json != null);
    // ...and it must fit the buffer load() reads it back with, with room to
    // tell "full file" apart from "truncated".
    try std.testing.expect(json.?.len < file_buf.len);
    n = 0;
}

test "record bumps counts and round-trips through text" {
    n = 0;
    const a = record(0xabc123, 1000, "v1");
    try std.testing.expectEqual(@as(u32, 1), a.count);
    const b = record(0xabc123, 2000, "v1");
    try std.testing.expectEqual(@as(u32, 2), b.count);
    try std.testing.expectEqual(@as(i64, 1000), b.first_seen);
    _ = record(0xdef456, 3000, "v1");

    var buf: [4096]u8 = undefined;
    const json = serialize(&buf).?;
    n = 0;
    loadFromText(json);
    try std.testing.expectEqual(@as(usize, 2), n);
    const c = record(0xabc123, 4000, "v1");
    try std.testing.expectEqual(@as(u32, 3), c.count);
    try std.testing.expectEqual(@as(i64, 1000), c.first_seen);
}

test "build correlation: same crash across builds is a regression" {
    n = 0;
    // First appears on v1.0.0.
    const a = record(0x5157, 1000, "v1.0.0");
    try std.testing.expectEqual(@as(u32, 1), a.builds);
    try std.testing.expectEqualStrings("v1.0.0", a.firstBuild());
    // Recurs on the same build — not a new build.
    const b = record(0x5157, 1500, "v1.0.0");
    try std.testing.expectEqual(@as(u32, 1), b.builds);
    // Owner ships v1.0.1 but the crash survives — regression across 2 builds.
    const c = record(0x5157, 2000, "v1.0.1");
    try std.testing.expectEqual(@as(u32, 2), c.builds);
    try std.testing.expectEqualStrings("v1.0.0", c.firstBuild());
    try std.testing.expectEqualStrings("v1.0.1", c.lastBuild());

    // builds survive a save/load round-trip.
    var buf: [4096]u8 = undefined;
    const json = serialize(&buf).?;
    n = 0;
    loadFromText(json);
    const d = record(0x5157, 2500, "v1.0.1");
    try std.testing.expectEqual(@as(u32, 2), d.builds);
    try std.testing.expectEqualStrings("v1.0.0", d.firstBuild());
    try std.testing.expectEqualStrings("v1.0.1", d.lastBuild());
    n = 0;
}

test "empty release degrades silently (no build data)" {
    n = 0;
    const a = record(0x1234, 1000, "");
    try std.testing.expectEqual(@as(u32, 0), a.builds);
    try std.testing.expectEqual(@as(u8, 0), a.first_build_len);
    n = 0;
}

test "hostile release chars are sanitized" {
    n = 0;
    const a = record(0x1234, 1000, "v1\"; rm -rf\n/");
    try std.testing.expect(std.mem.indexOfScalar(u8, a.firstBuild(), '"') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, a.firstBuild(), '\n') == null);
    n = 0;
}

test "out-of-range timestamps in a corrupt state file are clamped, not trapped" {
    n = 0;
    // 2^64-1 does not fit i64; a bare @intCast would trap here, and this runs
    // on the startup load path.
    loadFromText("{\"v\":2,\"entries\":[{\"sig\":\"00000000deadbeef\"," ++
        "\"first\":18446744073709551615,\"last\":18446744073709551615," ++
        "\"count\":18446744073709551615,\"builds\":9999999999999999999," ++
        "\"fb\":\"a\",\"lb\":\"b\"}]}");
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), entries[0].first_seen);
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), entries[0].count);
    n = 0;
}

test "eviction replaces the stalest entry when full" {
    n = 0;
    for (0..max_entries) |i| _ = record(@intCast(i + 1), @intCast(i), "v1");
    _ = record(0x9999, 10_000, "v1"); // evicts sig 1 (last_seen 0)
    try std.testing.expectEqual(@as(usize, max_entries), n);
    const again = record(1, 10_001, "v1"); // sig 1 is gone -> fresh entry
    try std.testing.expectEqual(@as(u32, 1), again.count);
    n = 0; // leave clean state for other tests
}
