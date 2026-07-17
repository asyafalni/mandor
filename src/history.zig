//! Persistent incident history: signature -> {first_seen, count}. Survives
//! supervisor restarts via <state-dir>/history.json so bundles can say
//! "5th time this exact crash since Tuesday" instead of "brand new".

const std = @import("std");
const jb = @import("jsonbuf.zig");
const report = @import("report.zig");

pub const max_entries = 64;

pub const Entry = struct {
    sig: u64,
    first_seen: i64, // epoch seconds
    last_seen: i64,
    count: u32,
};

var entries: [max_entries]Entry = undefined;
var n: usize = 0;

/// Bump (or insert) a signature; evicts the stalest entry when full.
pub fn record(sig: u64, now_epoch: i64) Entry {
    for (entries[0..n]) |*e| {
        if (e.sig == sig) {
            e.count += 1;
            e.last_seen = now_epoch;
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
    entries[slot] = .{ .sig = sig, .first_seen = now_epoch, .last_seen = now_epoch, .count = 1 };
    return entries[slot];
}

pub fn serialize(buf: []u8) ?[]const u8 {
    var pos: usize = 0;
    const p = &pos;
    if (!jb.appendf(buf, p, "{{\"v\":1,\"entries\":[", .{})) return null;
    for (entries[0..n], 0..) |e, i| {
        if (i > 0 and !jb.appendf(buf, p, ",", .{})) return null;
        if (!jb.appendf(buf, p, "{{\"sig\":\"{x:0>16}\",\"first\":{d},\"last\":{d},\"count\":{d}}}", .{
            e.sig, e.first_seen, e.last_seen, e.count,
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
        entries[n] = .{
            .sig = sig,
            .first_seen = @intCast(report.scanU64(chunk, "first") orelse continue),
            .last_seen = @intCast(report.scanU64(chunk, "last") orelse continue),
            .count = @intCast(@min(report.scanU64(chunk, "count") orelse continue, std.math.maxInt(u32))),
        };
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
    const got = linux.read(fd, &file_buf, file_buf.len);
    if (posix.errno(got) != .SUCCESS) return;
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

test "record bumps counts and round-trips through text" {
    n = 0;
    const a = record(0xabc123, 1000);
    try std.testing.expectEqual(@as(u32, 1), a.count);
    const b = record(0xabc123, 2000);
    try std.testing.expectEqual(@as(u32, 2), b.count);
    try std.testing.expectEqual(@as(i64, 1000), b.first_seen);
    _ = record(0xdef456, 3000);

    var buf: [4096]u8 = undefined;
    const json = serialize(&buf).?;
    n = 0;
    loadFromText(json);
    try std.testing.expectEqual(@as(usize, 2), n);
    const c = record(0xabc123, 4000);
    try std.testing.expectEqual(@as(u32, 3), c.count);
    try std.testing.expectEqual(@as(i64, 1000), c.first_seen);
}

test "eviction replaces the stalest entry when full" {
    n = 0;
    for (0..max_entries) |i| _ = record(@intCast(i + 1), @intCast(i));
    _ = record(0x9999, 10_000); // evicts sig 1 (last_seen 0)
    try std.testing.expectEqual(@as(usize, max_entries), n);
    const again = record(1, 10_001); // sig 1 is gone -> fresh entry
    try std.testing.expectEqual(@as(u32, 1), again.count);
    n = 0; // leave clean state for other tests
}
