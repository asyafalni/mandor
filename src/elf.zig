//! Minimal ELF64 GNU build-id extraction: walk PT_NOTE program headers for
//! an NT_GNU_BUILD_ID note. Pure parser over a prefix of the file — no full
//! ELF machinery, no allocation. Release correlation without app cooperation.

const std = @import("std");

const pt_note = 4;
const nt_gnu_build_id = 3;

/// Extract the build-id from an ELF file prefix; hex-encodes into `out`.
pub fn parseBuildId(data: []const u8, out: *[64]u8) ?[]const u8 {
    if (data.len < 64) return null;
    if (!std.mem.eql(u8, data[0..4], "\x7fELF")) return null;
    if (data[4] != 2 or data[5] != 1) return null; // ELF64 little-endian only

    const phoff = std.mem.readInt(u64, data[32..40], .little);
    const phentsize = std.mem.readInt(u16, data[54..56], .little);
    const phnum = std.mem.readInt(u16, data[56..58], .little);
    if (phentsize < 56) return null;

    var i: usize = 0;
    while (i < phnum) : (i += 1) {
        const off = phoff + i * phentsize;
        if (off + 56 > data.len) return null; // header table beyond our prefix
        const p_type = std.mem.readInt(u32, data[off..][0..4], .little);
        if (p_type != pt_note) continue;
        const p_offset = std.mem.readInt(u64, data[off + 8 ..][0..8], .little);
        const p_filesz = std.mem.readInt(u64, data[off + 32 ..][0..8], .little);
        if (parseNotes(data, p_offset, p_filesz, out)) |id| return id;
    }
    return null;
}

fn parseNotes(data: []const u8, start: u64, size: u64, out: *[64]u8) ?[]const u8 {
    var off = start;
    const end = @min(start + size, data.len);
    while (off + 12 <= end) {
        const namesz = std.mem.readInt(u32, data[@intCast(off)..][0..4], .little);
        const descsz = std.mem.readInt(u32, data[@intCast(off + 4)..][0..4], .little);
        const note_type = std.mem.readInt(u32, data[@intCast(off + 8)..][0..4], .little);
        const name_off = off + 12;
        const desc_off = name_off + std.mem.alignForward(u64, namesz, 4);
        const next = desc_off + std.mem.alignForward(u64, descsz, 4);
        if (next > end) return null;
        if (note_type == nt_gnu_build_id and namesz == 4 and
            std.mem.eql(u8, data[@intCast(name_off)..][0..4], "GNU\x00") and
            descsz > 0 and descsz <= 32)
        {
            const desc = data[@intCast(desc_off)..][0..descsz];
            var pos: usize = 0;
            for (desc) |byte| {
                const hex = "0123456789abcdef";
                out[pos] = hex[byte >> 4];
                out[pos + 1] = hex[byte & 0xf];
                pos += 2;
            }
            return out[0..pos];
        }
        off = next;
    }
    return null;
}

// ------------------------------------------------------- Linux reader

const linux = std.os.linux;
const posix = std.posix;

var read_buf: [8192]u8 = undefined;

/// Read the exe's prefix and extract its build-id (spawn-time cold path).
pub fn readBuildId(exe_path: []const u8, out: *[64]u8) ?[]const u8 {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}", .{exe_path}) catch return null;
    const rc = linux.openat(linux.AT.FDCWD, path.ptr, .{}, 0);
    if (posix.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const n = linux.read(fd, &read_buf, read_buf.len);
    if (posix.errno(n) != .SUCCESS) return null;
    return parseBuildId(read_buf[0..n], out);
}

// ---------------------------------------------------------------- tests

fn makeTestElf(buf: *[160]u8) void {
    @memset(buf, 0);
    @memcpy(buf[0..4], "\x7fELF");
    buf[4] = 2; // ELF64
    buf[5] = 1; // little-endian
    std.mem.writeInt(u64, buf[32..40], 64, .little); // e_phoff
    std.mem.writeInt(u16, buf[54..56], 56, .little); // e_phentsize
    std.mem.writeInt(u16, buf[56..58], 1, .little); // e_phnum
    // phdr @64: PT_NOTE, offset 120, filesz 24
    std.mem.writeInt(u32, buf[64..68], pt_note, .little);
    std.mem.writeInt(u64, buf[72..80], 120, .little);
    std.mem.writeInt(u64, buf[96..104], 24, .little);
    // note @120: namesz 4, descsz 8, NT_GNU_BUILD_ID, "GNU\0", desc
    std.mem.writeInt(u32, buf[120..124], 4, .little);
    std.mem.writeInt(u32, buf[124..128], 8, .little);
    std.mem.writeInt(u32, buf[128..132], nt_gnu_build_id, .little);
    @memcpy(buf[132..136], "GNU\x00");
    @memcpy(buf[136..144], &[8]u8{ 0xde, 0xad, 0xbe, 0xef, 0x01, 0x02, 0x03, 0x04 });
}

test "extracts build-id from a crafted ELF" {
    var elf_bytes: [160]u8 = undefined;
    makeTestElf(&elf_bytes);
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("deadbeef01020304", parseBuildId(&elf_bytes, &out).?);
}

test "rejects non-ELF and truncated input" {
    var out: [64]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), parseBuildId("#!/bin/sh\n", &out));
    try std.testing.expectEqual(@as(?[]const u8, null), parseBuildId("\x7fELF", &out));
    var elf_bytes: [160]u8 = undefined;
    makeTestElf(&elf_bytes);
    elf_bytes[5] = 2; // big-endian: unsupported
    try std.testing.expectEqual(@as(?[]const u8, null), parseBuildId(&elf_bytes, &out));
}

test "real /proc/self/exe on linux has parseable shape" {
    const builtin = @import("builtin");
    if (builtin.os.tag != .linux) return;
    var out: [64]u8 = undefined;
    // May or may not have a build-id; must not crash either way.
    _ = readBuildId("/proc/self/exe", &out);
}
