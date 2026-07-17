//! Rust panic parser. Handles both message formats:
//!   new (1.65+): thread 'main' panicked at src/main.rs:10:5:
//!                attempt to divide by zero
//!   old:         thread 'main' panicked at 'msg', src/main.rs:10:5
//! Backtrace frames (RUST_BACKTRACE=1) when present:
//!    0: rust_begin_unwind
//!              at /rustc/.../std/src/panicking.rs:645:5

const std = @import("std");
const summarize = @import("../summarize.zig");

pub fn detect(lines: []const summarize.LogLine, st: *summarize.TraceStorage) ?summarize.TraceInfo {
    var panic_idx: ?usize = null;
    for (lines, 0..) |l, i| {
        if (std.mem.indexOf(u8, l.text, "panicked at ") != null) panic_idx = i;
    }
    const start = panic_idx orelse return null;
    const panic_line = lines[start].text;
    const at = std.mem.indexOf(u8, panic_line, "panicked at ").? + "panicked at ".len;

    var nframes: usize = 0;
    var end = start + 1;

    // Frame 0: the panic location itself.
    var loc = panic_line[at..];
    if (loc.len > 0 and loc[0] == '\'') {
        // old format: 'msg', src/main.rs:10:5
        if (std.mem.lastIndexOf(u8, loc, "', ")) |q| loc = loc[q + 3 ..];
    } else if (loc.len > 0 and loc[loc.len - 1] == ':') {
        loc = loc[0 .. loc.len - 1];
    }
    if (loc.len > 0) {
        const fl = summarize.splitFileLine(loc);
        st.frames[nframes] = .{
            .function = "panic site",
            .file = fl.file,
            .line = fl.line,
            .in_app = true,
        };
        nframes += 1;
    }

    // Optional backtrace listing: "   N: func" (+ optional "at file:line").
    var i = start + 1;
    while (i < lines.len and nframes < st.frames.len) : (i += 1) {
        const text = lines[i].text;
        const trimmed = std.mem.trimStart(u8, text, " ");
        if (numberedFrame(trimmed)) |func| {
            var location: []const u8 = "";
            if (i + 1 < lines.len) {
                const nxt = std.mem.trimStart(u8, lines[i + 1].text, " ");
                if (std.mem.startsWith(u8, nxt, "at ")) location = nxt[3..];
            }
            const fl = summarize.splitFileLine(location);
            st.frames[nframes] = .{
                .function = func,
                .file = fl.file,
                .line = fl.line,
                .in_app = !std.mem.startsWith(u8, func, "core::") and
                    !std.mem.startsWith(u8, func, "std::") and
                    !std.mem.startsWith(u8, func, "rust_begin_unwind") and
                    std.mem.indexOf(u8, fl.file, "/rustc/") == null,
            };
            nframes += 1;
            end = i + 1;
        } else if (std.mem.startsWith(u8, trimmed, "at ")) {
            end = i + 1;
        } else if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "note:") or
            std.mem.startsWith(u8, trimmed, "stack backtrace:"))
        {
            end = i + 1;
        } else if (i > start + 2) {
            break; // left the panic block
        } else {
            end = i + 1; // message line right after the panic line
        }
    }

    // Message: old format carries it inline in quotes; new format puts it on
    // the following line.
    var exc_msg: []const u8 = "";
    const after = panic_line[at..];
    if (after.len > 0 and after[0] == '\'') {
        if (std.mem.lastIndexOf(u8, after, "', ")) |q| exc_msg = after[1..q];
    } else if (start + 1 < lines.len) {
        const nxt = lines[start + 1].text;
        if (nxt.len > 0 and !std.mem.startsWith(u8, nxt, "note:") and
            !std.mem.startsWith(u8, nxt, "stack backtrace:"))
        {
            exc_msg = nxt;
        }
    }

    return .{
        .lang = "rust",
        .frames = st.frames[0..nframes],
        .raw = summarize.joinRaw(lines, start, @min(end, lines.len), st),
        .exc_type = "panic",
        .exc_msg = exc_msg,
    };
}

/// "12: core::panicking::panic_fmt" -> "core::panicking::panic_fmt"
fn numberedFrame(trimmed: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < trimmed.len and trimmed[i] >= '0' and trimmed[i] <= '9') i += 1;
    if (i == 0 or i + 2 > trimmed.len or trimmed[i] != ':' or trimmed[i + 1] != ' ')
        return null;
    return trimmed[i + 2 ..];
}

// ---------------------------------------------------------------- tests

const t = std.testing;
const F = summarize.LogLine;

test "new-format panic with backtrace" {
    const lines = [_]F{
        .{ .text = "thread 'main' panicked at src/main.rs:10:5:", .flags = 1 },
        .{ .text = "attempt to divide by zero", .flags = 1 },
        .{ .text = "stack backtrace:", .flags = 1 },
        .{ .text = "   0: rust_begin_unwind", .flags = 1 },
        .{ .text = "             at /rustc/abc/library/std/src/panicking.rs:645:5", .flags = 1 },
        .{ .text = "   1: core::panicking::panic_fmt", .flags = 1 },
    };
    var st: summarize.TraceStorage = .{};
    const tr = detect(&lines, &st).?;
    try t.expectEqualStrings("rust", tr.lang);
    try t.expectEqualStrings("panic", tr.exc_type);
    try t.expectEqualStrings("attempt to divide by zero", tr.exc_msg);
    try t.expectEqual(@as(usize, 3), tr.frames.len);
    try t.expectEqualStrings("panic site", tr.frames[0].function);
    try t.expectEqualStrings("src/main.rs", tr.frames[0].file);
    try t.expectEqual(@as(u32, 10), tr.frames[0].line);
    try t.expect(tr.frames[0].in_app);
    try t.expectEqualStrings("rust_begin_unwind", tr.frames[1].function);
    try t.expectEqual(@as(u32, 645), tr.frames[1].line);
    try t.expect(!tr.frames[1].in_app);
    try t.expectEqualStrings("core::panicking::panic_fmt", tr.frames[2].function);
    try t.expect(!tr.frames[2].in_app);
}

test "old-format single line panic" {
    const lines = [_]F{
        .{ .text = "thread 'main' panicked at 'index out of bounds: the len is 3 but the index is 7', src/lib.rs:42:13", .flags = 1 },
        .{ .text = "note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace", .flags = 1 },
    };
    var st: summarize.TraceStorage = .{};
    const tr = detect(&lines, &st).?;
    try t.expectEqualStrings("src/lib.rs", tr.frames[0].file);
    try t.expectEqual(@as(u32, 42), tr.frames[0].line);
    try t.expectEqualStrings("index out of bounds: the len is 3 but the index is 7", tr.exc_msg);
}

test "no panic -> null" {
    const lines = [_]F{.{ .text = "thread pool started", .flags = 0 }};
    var st: summarize.TraceStorage = .{};
    try t.expectEqual(@as(?summarize.TraceInfo, null), detect(&lines, &st));
}
