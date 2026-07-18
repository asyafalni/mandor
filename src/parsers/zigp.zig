//! Zig panic-trace parser (dogfood: mandor is Zig).
//!   thread 190879 panic: integer overflow
//!   /app/src/main.zig:12:15: 0x10488d1 in add (main)
//!       return a + b;
//!                 ^
//!   /app/src/main.zig:18:20: 0x1048a02 in main (main)

const std = @import("std");
const summarize = @import("../summarize.zig");

pub fn detect(lines: []const summarize.LogLine, st: *summarize.TraceStorage) ?summarize.TraceInfo {
    var header: ?usize = null;
    for (lines, 0..) |l, i| {
        if (std.mem.indexOf(u8, l.text, "panic: ")) |p| {
            // "thread N panic: msg" or bare "panic: msg" at line start
            const pre = l.text[0..p];
            const ok = pre.len == 0 or
                (std.mem.startsWith(u8, pre, "thread ") and pre.len < 24);
            if (ok and i + 1 < lines.len and parseFrame(lines[i + 1].text) != null)
                header = i;
        }
    }
    const start = header orelse return null;

    var nframes: usize = 0;
    var end = start + 1;
    var i = start + 1;
    while (i < lines.len and nframes < st.frames.len) : (i += 1) {
        if (parseFrame(lines[i].text)) |frame| {
            st.frames[nframes] = frame;
            nframes += 1;
            end = i + 1;
        } else if (std.mem.startsWith(u8, lines[i].text, " ") or
            std.mem.indexOfScalar(u8, lines[i].text, '^') != null)
        {
            end = i + 1; // source echo / caret lines
        } else break;
    }
    if (nframes == 0) return null;

    const head = lines[start].text;
    const msg_at = std.mem.indexOf(u8, head, "panic: ").? + "panic: ".len;
    return .{
        .lang = "zig",
        .frames = st.frames[0..nframes],
        .raw = summarize.joinRaw(lines, start, @min(end, lines.len), st),
        .exc_type = "panic",
        .exc_msg = head[msg_at..],
    };
}

/// "/app/src/main.zig:12:15: 0x10488d1 in add (main)" -> Frame
fn parseFrame(text: []const u8) ?summarize.Frame {
    const in_pat = " in ";
    const zig_ext = ".zig:";
    const ext = std.mem.indexOf(u8, text, zig_ext) orelse return null;
    const in_pos = std.mem.indexOfPos(u8, text, ext, in_pat) orelse return null;
    if (std.mem.indexOfPos(u8, text, ext, "0x") == null) return null;
    const file = text[0 .. ext + 4];
    var j = ext + zig_ext.len;
    var line: u32 = 0;
    while (j < text.len and text[j] >= '0' and text[j] <= '9') : (j += 1) {
        line = line *| 10 +| (text[j] - '0');
    }
    if (line == 0) return null;
    var func = text[in_pos + in_pat.len ..];
    if (std.mem.indexOf(u8, func, " (")) |p| func = func[0..p];
    return .{
        .function = func,
        .file = file,
        .line = line,
        .in_app = std.mem.indexOf(u8, file, "/lib/std/") == null and
            !std.mem.startsWith(u8, func, "std."),
    };
}

// ---------------------------------------------------------------- tests

const t = std.testing;
const F = summarize.LogLine;

test "parses a zig panic trace" {
    const lines = [_]F{
        .{ .text = "thread 190879 panic: integer overflow", .flags = 1 },
        .{ .text = "/app/src/main.zig:12:15: 0x10488d1 in add (main)", .flags = 1 },
        .{ .text = "    return a + b;", .flags = 1 },
        .{ .text = "              ^", .flags = 1 },
        .{ .text = "/opt/zig/lib/std/start.zig:642:22: 0x1047c9d in std.start.main (main)", .flags = 1 },
    };
    var st: summarize.TraceStorage = .{};
    const tr = detect(&lines, &st).?;
    try t.expectEqualStrings("zig", tr.lang);
    try t.expectEqualStrings("panic", tr.exc_type);
    try t.expectEqualStrings("integer overflow", tr.exc_msg);
    try t.expectEqual(@as(usize, 2), tr.frames.len);
    try t.expectEqualStrings("add", tr.frames[0].function);
    try t.expectEqualStrings("/app/src/main.zig", tr.frames[0].file);
    try t.expectEqual(@as(u32, 12), tr.frames[0].line);
    try t.expect(tr.frames[0].in_app);
    try t.expect(!tr.frames[1].in_app);
}

test "no panic -> null" {
    const lines = [_]F{.{ .text = "info: listening", .flags = 0 }};
    var st: summarize.TraceStorage = .{};
    try t.expectEqual(@as(?summarize.TraceInfo, null), detect(&lines, &st));
}
