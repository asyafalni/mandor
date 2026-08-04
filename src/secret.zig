//! Per-session secret store: one CSPRNG draw (`getrandom`) rendered through six
//! hand-rolled encoders. Everything here is off the supervision hot path (only
//! touched at boot + per spawn) and allocation-free — encoders write into a
//! caller-provided `out`. Stability leads: no `unreachable`, no panic; a bad
//! draw or an undersized buffer is an ERROR, never a trap. Size arithmetic
//! saturates so a wild `n` can never overflow into a small length.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const posix = std.posix;

/// Upper bound on entropy bytes (and thus scratch) for a single draw. Matches
/// the config `bytes` range ceiling (1..4096); a request above it is refused
/// rather than silently clamped.
pub const max_bytes: usize = 4096;

pub const Format = enum { hex, b10, b32, b64, b64url, raw };

/// Enum field names ARE the accepted spellings ("hex".."raw"), so the mapping
/// cannot drift from the enum. Junk / wrong case → null.
pub fn parseFormat(s: []const u8) ?Format {
    return std.meta.stringToEnum(Format, s);
}

/// Exact encoded length for `(fmt, n)` so callers can size buffers. Saturating
/// throughout: an absurd `n` yields an absurd-but-finite length that the
/// caller's buffer check then rejects — it never wraps to a small value.
///   hex    = 2n
///   b32    = ceil(8n/5)  (RFC4648, unpadded)      = (8n+4)/5
///   b64    = 4*ceil(n/3) (RFC4648 §4, padded)     = ((n+2)/3)*4
///   b64url = ceil(4n/3)  (RFC4648 §5, unpadded)   = (4n+2)/3
///   b10    = n           (n is the DIGIT count)
///   raw    = n
pub fn encodedLen(fmt: Format, n: usize) usize {
    return switch (fmt) {
        .hex => n *| 2,
        .b32 => (n *| 8 +| 4) / 5,
        .b64 => ((n +| 2) / 3) *| 4,
        .b64url => (n *| 4 +| 2) / 3,
        .b10, .raw => n,
    };
}

// --------------------------------------------------------------- encoders
//
// Each encoder is pure: fixed input slice -> written prefix of `out`, returned
// as a slice. That makes them deterministic under test (feed known bytes) with
// no getrandom in the loop. `generate` below composes a draw + the right one.

const hex_alpha = "0123456789abcdef";

/// base16, lowercase, 2 chars/byte.
fn hexEncode(src: []const u8, out: []u8) []const u8 {
    var j: usize = 0;
    for (src) |b| {
        out[j] = hex_alpha[b >> 4];
        out[j + 1] = hex_alpha[b & 0x0f];
        j += 2;
    }
    return out[0..j];
}

const b32_alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

/// RFC4648 base32, uppercase, NO padding. Bit accumulator: fold bytes in 8 at a
/// time, emit a symbol per 5 bits, flush a final partial group left-aligned.
fn b32Encode(src: []const u8, out: []u8) []const u8 {
    var acc: u32 = 0;
    var nbits: u32 = 0;
    var j: usize = 0;
    for (src) |b| {
        acc = (acc << 8) | @as(u32, b);
        nbits += 8;
        while (nbits >= 5) {
            nbits -= 5;
            out[j] = b32_alpha[(acc >> @as(u5, @intCast(nbits))) & 0x1f];
            j += 1;
        }
        // Keep only the still-buffered low bits so `acc` cannot grow unbounded
        // across a long input (bits shifted past what we mask are already
        // emitted). nbits is now 0..4 here.
        acc &= (@as(u32, 1) << @as(u5, @intCast(nbits))) -% 1;
    }
    if (nbits > 0) {
        out[j] = b32_alpha[(acc << @as(u5, @intCast(5 - nbits))) & 0x1f];
        j += 1;
    }
    return out[0..j];
}

const b64_std_alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const b64_url_alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// Shared base64 core, parameterized by alphabet and padding. Three input bytes
/// -> four symbols; a 1- or 2-byte tail emits 2 or 3 symbols, `=` padded to a
/// multiple of four only when `pad`.
fn b64Common(src: []const u8, out: []u8, comptime alpha: []const u8, comptime pad: bool) []const u8 {
    var i: usize = 0;
    var j: usize = 0;
    while (i + 3 <= src.len) : (i += 3) {
        const n = (@as(u32, src[i]) << 16) | (@as(u32, src[i + 1]) << 8) | @as(u32, src[i + 2]);
        out[j] = alpha[(n >> 18) & 0x3f];
        out[j + 1] = alpha[(n >> 12) & 0x3f];
        out[j + 2] = alpha[(n >> 6) & 0x3f];
        out[j + 3] = alpha[n & 0x3f];
        j += 4;
    }
    const rem = src.len - i;
    if (rem == 1) {
        const n = @as(u32, src[i]) << 16;
        out[j] = alpha[(n >> 18) & 0x3f];
        out[j + 1] = alpha[(n >> 12) & 0x3f];
        j += 2;
        if (pad) {
            out[j] = '=';
            out[j + 1] = '=';
            j += 2;
        }
    } else if (rem == 2) {
        const n = (@as(u32, src[i]) << 16) | (@as(u32, src[i + 1]) << 8);
        out[j] = alpha[(n >> 18) & 0x3f];
        out[j + 1] = alpha[(n >> 12) & 0x3f];
        out[j + 2] = alpha[(n >> 6) & 0x3f];
        j += 3;
        if (pad) {
            out[j] = '=';
            j += 1;
        }
    }
    return out[0..j];
}

/// RFC4648 §4 base64, standard alphabet (`+` `/`), `=` padded.
fn b64Encode(src: []const u8, out: []u8) []const u8 {
    return b64Common(src, out, b64_std_alpha, true);
}

/// RFC4648 §5 base64url, URL-safe alphabet (`-` `_`), NO padding.
fn b64urlEncode(src: []const u8, out: []u8) []const u8 {
    return b64Common(src, out, b64_url_alpha, false);
}

// --------------------------------------------------------------- b10 sampler
//
// Unbiased decimal digits by rejection sampling. A digit source hands out bytes
// one at a time; a byte is USED only when < 250 (the largest multiple of 10 that
// is <= 255), mapped `byte % 10`; a byte in 250..255 is DISCARDED and the next
// drawn. A naive `byte % 10` would over-represent 0..5. The byte source is a
// duck-typed `src` (any pointer with `fn next(self) ?u8`, null = exhausted /
// draw failed) so tests feed a fixed stream and `generate` feeds getrandom.

/// Fill `out[0..count]` with decimal digits. `error.Overflow` if `out` is too
/// small; `error.Rand` if the byte source runs dry before `count` digits.
fn b10Encode(src: anytype, count: usize, out: []u8) error{ Rand, Overflow }![]const u8 {
    if (out.len < count) return error.Overflow;
    var i: usize = 0;
    while (i < count) {
        const b = src.next() orelse return error.Rand;
        if (b < 250) {
            out[i] = '0' + (b % 10);
            i += 1;
        }
    }
    return out[0..count];
}

/// Deterministic byte source over a fixed slice — the test injection point for
/// every rejection-sampler behavior.
const SliceSource = struct {
    bytes: []const u8,
    i: usize = 0,
    fn next(self: *SliceSource) ?u8 {
        if (self.i >= self.bytes.len) return null;
        const b = self.bytes[self.i];
        self.i += 1;
        return b;
    }
};

/// Byte source backed by `getrandom`, refilling a small buffer on demand. Used
/// only by `generate` for b10, where the number of bytes consumed is unbounded
/// (rejections) but small in expectation.
const RandSource = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,
    pos: usize = 0,
    fn next(self: *RandSource) ?u8 {
        if (self.pos >= self.len) {
            const got = linux.getrandom(self.buf[0..].ptr, self.buf.len, 0);
            if (posix.errno(got) != .SUCCESS or got == 0) return null;
            self.len = got;
            self.pos = 0;
        }
        const b = self.buf[self.pos];
        self.pos += 1;
        return b;
    }
};

/// Draw exactly `buf.len` CSPRNG bytes, looping because getrandom may return
/// short. `error.Rand` on any syscall failure.
fn drawBytes(buf: []u8) error{Rand}!void {
    var off: usize = 0;
    while (off < buf.len) {
        const got = linux.getrandom(buf[off..].ptr, buf.len - off, 0);
        if (posix.errno(got) != .SUCCESS or got == 0) return error.Rand;
        off += got;
    }
}

// --------------------------------------------------------------- generate

/// Fill `out` with an encoded secret and return the written slice. For every
/// format except b10, `n` is entropy bytes; for b10, `n` is the digit count.
/// NO trailing newline (the delivery layer adds one for printable formats).
/// `error.Overflow` if `out` is too small (or `n` exceeds `max_bytes` for the
/// byte formats); `error.Rand` on getrandom failure — fail-closed, never a
/// fabricated or reused value.
pub fn generate(out: []u8, fmt: Format, n: usize) error{ Rand, Overflow }![]const u8 {
    if (out.len < encodedLen(fmt, n)) return error.Overflow;
    switch (fmt) {
        .b10 => {
            var rs = RandSource{};
            return b10Encode(&rs, n, out);
        },
        .raw => {
            if (n > max_bytes) return error.Overflow;
            drawBytes(out[0..n]) catch return error.Rand;
            return out[0..n];
        },
        .hex, .b32, .b64, .b64url => {
            if (n > max_bytes) return error.Overflow;
            var ent: [max_bytes]u8 = undefined;
            drawBytes(ent[0..n]) catch return error.Rand;
            const src = ent[0..n];
            return switch (fmt) {
                .hex => hexEncode(src, out),
                .b32 => b32Encode(src, out),
                .b64 => b64Encode(src, out),
                .b64url => b64urlEncode(src, out),
                // Not reachable (outer arm restricts fmt) but expressed as a
                // hard error rather than `unreachable` — stability leads.
                .b10, .raw => error.Overflow,
            };
        },
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "hex lowercases 2 chars/byte" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("00ff10", hexEncode(&.{ 0, 255, 16 }, &buf));
    try testing.expectEqualStrings("", hexEncode(&.{}, &buf));
    try testing.expectEqualStrings("deadbeef", hexEncode(&.{ 0xde, 0xad, 0xbe, 0xef }, &buf));
}

test "b32 RFC4648 upper no pad" {
    var buf: [16]u8 = undefined;
    // RFC4648 vectors (padding stripped): "fooba" -> MZXW6YTB (exact 8, no pad),
    // "foob" -> MZXW6YQ (7 chars), "f" -> MY.
    try testing.expectEqualStrings("MZXW6YTB", b32Encode("fooba", &buf));
    try testing.expectEqualStrings("MZXW6YQ", b32Encode("foob", &buf));
    try testing.expectEqualStrings("MY", b32Encode("f", &buf));
    // No padding is ever emitted.
    try testing.expect(std.mem.indexOfScalar(u8, b32Encode("foob", &buf), '=') == null);
}

test "b64 standard padded" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("Zm9vYmFy", b64Encode("foobar", &buf));
    try testing.expectEqualStrings("Zg==", b64Encode("f", &buf));
    try testing.expectEqualStrings("Zm8=", b64Encode("fo", &buf));
    try testing.expectEqualStrings("Zm9v", b64Encode("foo", &buf));
}

test "b64url urlsafe no pad" {
    var buf: [16]u8 = undefined;
    // Bytes chosen to exercise both url-safe symbols: -> "-_-_".
    try testing.expectEqualStrings("-_-_", b64urlEncode(&.{ 0xfb, 0xff, 0xbf }, &buf));
    // Single byte -> 2 chars, NO padding (standard b64 would be "_w==").
    try testing.expectEqualStrings("_w", b64urlEncode(&.{0xff}, &buf));
    const s = b64urlEncode(&.{ 0xfb, 0xff, 0xbf }, &buf);
    try testing.expect(std.mem.indexOfScalar(u8, s, '=') == null);
    try testing.expect(std.mem.indexOfScalar(u8, s, '+') == null);
    try testing.expect(std.mem.indexOfScalar(u8, s, '/') == null);
}

test "b10 digit count + charset" {
    var buf: [8]u8 = undefined;
    var src = SliceSource{ .bytes = &.{ 3, 17, 42, 99, 100, 249 } };
    const d = try b10Encode(&src, 6, &buf);
    try testing.expectEqual(@as(usize, 6), d.len);
    for (d) |c| try testing.expect(c >= '0' and c <= '9');
    // 3%10=3, 17%10=7, 42%10=2, 99%10=9, 100%10=0, 249%10=9
    try testing.expectEqualStrings("372909", d);
}

test "b10 rejection is unbiased" {
    var buf: [8]u8 = undefined;
    // Every value in 250..255 is interleaved with a valid byte; each 250..255
    // must be SKIPPED and only the valid bytes 0..5 mapped, giving "012345".
    // (With the bound broken to 256, 250->'0',251->'1',... would leak in and
    // the result would be "001122" — this is the mutation-sentinel test.)
    var src = SliceSource{ .bytes = &.{ 250, 0, 251, 1, 252, 2, 253, 3, 254, 4, 255, 5 } };
    const d = try b10Encode(&src, 6, &buf);
    try testing.expectEqualStrings("012345", d);

    // Even mapping of 0..249 across the ten digits: bytes 0..249 -> each digit
    // exactly 25 times.
    var stream: [250]u8 = undefined;
    for (&stream, 0..) |*b, k| b.* = @intCast(k);
    var counts = [_]usize{0} ** 10;
    var src2 = SliceSource{ .bytes = &stream };
    var out2: [250]u8 = undefined;
    const d2 = try b10Encode(&src2, 250, &out2);
    for (d2) |c| counts[c - '0'] += 1;
    for (counts) |cnt| try testing.expectEqual(@as(usize, 25), cnt);
}

test "b10 exhausted source fails closed" {
    var buf: [8]u8 = undefined;
    var src = SliceSource{ .bytes = &.{ 1, 2 } };
    try testing.expectError(error.Rand, b10Encode(&src, 6, &buf));
}

test "b10 too-small out overflows" {
    var buf: [2]u8 = undefined;
    var src = SliceSource{ .bytes = &.{ 1, 2, 3, 4 } };
    try testing.expectError(error.Overflow, b10Encode(&src, 4, &buf));
}

test "encodedLen matches encoders" {
    var buf: [64]u8 = undefined;
    // hex: exactly 2n.
    try testing.expectEqual(hexEncode("abc", &buf).len, encodedLen(.hex, 3));
    // b32: unpadded ceil(8n/5).
    try testing.expectEqual(b32Encode("fooba", &buf).len, encodedLen(.b32, 5));
    try testing.expectEqual(b32Encode("foob", &buf).len, encodedLen(.b32, 4));
    try testing.expectEqual(b32Encode("f", &buf).len, encodedLen(.b32, 1));
    // b64: padded 4*ceil(n/3).
    try testing.expectEqual(b64Encode("foobar", &buf).len, encodedLen(.b64, 6));
    try testing.expectEqual(b64Encode("f", &buf).len, encodedLen(.b64, 1));
    try testing.expectEqual(b64Encode("fo", &buf).len, encodedLen(.b64, 2));
    // b64url: unpadded ceil(4n/3).
    try testing.expectEqual(b64urlEncode(&.{ 0xfb, 0xff, 0xbf }, &buf).len, encodedLen(.b64url, 3));
    try testing.expectEqual(b64urlEncode(&.{0xff}, &buf).len, encodedLen(.b64url, 1));
    // b10 / raw are 1:1 with n.
    try testing.expectEqual(@as(usize, 6), encodedLen(.b10, 6));
    try testing.expectEqual(@as(usize, 32), encodedLen(.raw, 32));
}

test "encodedLen saturates on absurd n" {
    // Must not wrap to a small value for a wild request.
    try testing.expect(encodedLen(.hex, std.math.maxInt(usize)) >= std.math.maxInt(usize) / 2);
    try testing.expect(encodedLen(.b64, std.math.maxInt(usize)) > 0);
    try testing.expect(encodedLen(.b32, std.math.maxInt(usize)) > 0);
}

test "parseFormat round-trips and rejects junk" {
    try testing.expectEqual(Format.hex, parseFormat("hex").?);
    try testing.expectEqual(Format.b10, parseFormat("b10").?);
    try testing.expectEqual(Format.b32, parseFormat("b32").?);
    try testing.expectEqual(Format.b64, parseFormat("b64").?);
    try testing.expectEqual(Format.b64url, parseFormat("b64url").?);
    try testing.expectEqual(Format.raw, parseFormat("raw").?);
    try testing.expect(parseFormat("") == null);
    try testing.expect(parseFormat("HEX") == null);
    try testing.expect(parseFormat("base64") == null);
    try testing.expect(parseFormat("b16") == null);
}

test "generate smoke (live getrandom)" {
    if (builtin.os.tag != .linux) return;
    var o: [64]u8 = undefined;
    try testing.expectEqual(@as(usize, 16), (try generate(&o, .raw, 16)).len);
    try testing.expectEqual(@as(usize, 8), (try generate(&o, .hex, 4)).len);
    const h = try generate(&o, .hex, 4);
    for (h) |c| try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    const d = try generate(&o, .b10, 6);
    try testing.expectEqual(@as(usize, 6), d.len);
    for (d) |c| try testing.expect(c >= '0' and c <= '9');
}

test "generate rejects too-small out" {
    var tiny: [1]u8 = undefined;
    try testing.expectError(error.Overflow, generate(&tiny, .hex, 4));
}
