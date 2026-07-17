//! Fixed-size framed byte ring buffer. Stores line records
//! `[u16 len][u8 flags][u64 wall_ms][bytes]`; evicts oldest records when
//! full. Pure code — unit-tests run on any host.

const std = @import("std");

pub const flag_stderr: u8 = 1 << 0;
pub const flag_errorish: u8 = 1 << 1;
pub const flag_continuation: u8 = 1 << 2;

const header_len = 11; // u16 len (LE) + u8 flags + u64 wall-clock ms (LE)

pub fn Ring(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buf: [capacity]u8 = undefined,
        head: usize = 0, // oldest byte
        used: usize = 0,
        records: usize = 0,

        /// Append one record, evicting oldest records to make room.
        /// Records longer than the ring (or the 4 KB iterator copy buffer)
        /// are rejected. `t_ms` = wall-clock ms at line arrival.
        pub fn push(self: *Self, line: []const u8, flags: u8, t_ms: u64) bool {
            const needed = header_len + line.len;
            if (needed > capacity or line.len > 4095) return false;
            while (capacity - self.used < needed) self.evictOldest();
            self.setAt(self.used, @truncate(line.len));
            self.setAt(self.used + 1, @truncate(line.len >> 8));
            self.setAt(self.used + 2, flags);
            inline for (0..8) |b| self.setAt(self.used + 3 + b, @truncate(t_ms >> (8 * b)));
            for (line, 0..) |c, i| self.setAt(self.used + header_len + i, c);
            self.used += needed;
            self.records += 1;
            return true;
        }

        fn evictOldest(self: *Self) void {
            const len = @as(usize, self.at(0)) | (@as(usize, self.at(1)) << 8);
            const total = header_len + len;
            self.head = (self.head + total) % capacity;
            self.used -= total;
            self.records -= 1;
        }

        fn at(self: *const Self, logical: usize) u8 {
            return self.buf[(self.head + logical) % capacity];
        }

        fn setAt(self: *Self, logical: usize, value: u8) void {
            self.buf[(self.head + logical) % capacity] = value;
        }

        pub const Record = struct { line: []const u8, flags: u8, t_ms: u64 };

        pub const Iterator = struct {
            ring: *const Self,
            offset: usize, // bytes consumed from head
            copy_buf: *[4096]u8,

            /// Oldest-first. Bytes may wrap in the ring, so each record is
            /// copied into copy_buf; the returned slice is invalidated by
            /// the following next() call.
            pub fn next(self: *Iterator) ?Record {
                const r = self.ring;
                if (self.offset >= r.used) return null;
                const len = @as(usize, r.at(self.offset)) |
                    (@as(usize, r.at(self.offset + 1)) << 8);
                const flags = r.at(self.offset + 2);
                var t_ms: u64 = 0;
                inline for (0..8) |b| t_ms |= @as(u64, r.at(self.offset + 3 + b)) << (8 * b);
                for (0..len) |i| self.copy_buf[i] = r.at(self.offset + header_len + i);
                self.offset += header_len + len;
                return .{ .line = self.copy_buf[0..len], .flags = flags, .t_ms = t_ms };
            }
        };

        pub fn iterate(self: *const Self, copy_buf: *[4096]u8) Iterator {
            return .{ .ring = self, .offset = 0, .copy_buf = copy_buf };
        }

        /// Number of stored records.
        pub fn count(self: *const Self) usize {
            return self.records;
        }
    };
}

// ---------------------------------------------------------------- tests

const T = Ring(96); // tiny ring so eviction is easy to exercise
var test_copy: [4096]u8 = undefined;

test "push then iterate FIFO with flags and timestamps" {
    var r: T = .{};
    try std.testing.expect(r.push("hello", 0, 1111));
    try std.testing.expect(r.push("world", flag_stderr, 0x1_0000_2222));
    try std.testing.expectEqual(@as(usize, 2), r.count());

    var it = r.iterate(&test_copy);
    const a = it.next().?;
    try std.testing.expectEqualStrings("hello", a.line);
    try std.testing.expectEqual(@as(u8, 0), a.flags);
    try std.testing.expectEqual(@as(u64, 1111), a.t_ms);
    const b = it.next().?;
    try std.testing.expectEqualStrings("world", b.line);
    try std.testing.expectEqual(flag_stderr, b.flags);
    try std.testing.expectEqual(@as(u64, 0x1_0000_2222), b.t_ms);
    try std.testing.expectEqual(@as(?T.Record, null), it.next());
}

test "eviction keeps newest records" {
    var r: T = .{};
    // 96-byte ring, each record costs 11 + len
    try std.testing.expect(r.push("aaaaaaaaaa", 0, 1)); // 21
    try std.testing.expect(r.push("bbbbbbbbbb", 0, 2)); // 42
    try std.testing.expect(r.push("cccccccccc", 0, 3)); // 63
    try std.testing.expect(r.push("dddddddddd", 0, 4)); // 84
    try std.testing.expect(r.push("eeeeeeeeee", 0, 5)); // would be 105 -> evict "a"
    var it = r.iterate(&test_copy);
    const first = it.next().?;
    try std.testing.expectEqualStrings("bbbbbbbbbb", first.line);
    var n: usize = 1;
    while (it.next()) |_| n += 1;
    try std.testing.expectEqual(@as(usize, 4), n);
}

test "record larger than ring is rejected" {
    var r: T = .{};
    const big = "x" ** 100;
    try std.testing.expect(!r.push(big, 0, 0));
    try std.testing.expectEqual(@as(usize, 0), r.count());
}

test "wrap-around record comes back contiguous" {
    var r: T = .{};
    try std.testing.expect(r.push("0123456789012345678901234567890123456789012345678901234567890123456789", 0, 7)); // 81 bytes used
    try std.testing.expect(r.push("abcdefghijklmnopqrstuvwxyz", 0, 8)); // evicts, wraps
    var it = r.iterate(&test_copy);
    const rec = it.next().?;
    try std.testing.expectEqualStrings("abcdefghijklmnopqrstuvwxyz", rec.line);
    try std.testing.expectEqual(@as(u64, 8), rec.t_ms);
    try std.testing.expectEqual(@as(?T.Record, null), it.next());
}
