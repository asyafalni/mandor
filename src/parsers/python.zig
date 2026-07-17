//! Python traceback parser.
//!   Traceback (most recent call last):
//!     File "/app/x.py", line 10, in <module>
//!       main()
//!     File "/app/x.py", line 7, in main
//!       return 1/0
//!   ZeroDivisionError: division by zero

const std = @import("std");
const summarize = @import("../summarize.zig");

pub fn detect(lines: []const summarize.LogLine, st: *summarize.TraceStorage) ?summarize.TraceInfo {
    var tb_idx: ?usize = null;
    for (lines, 0..) |l, i| {
        if (std.mem.startsWith(u8, l.text, "Traceback (most recent call last):")) tb_idx = i;
    }
    const start = tb_idx orelse return null;

    var nframes: usize = 0;
    var end = start + 1;
    var i = start + 1;
    while (i < lines.len) : (i += 1) {
        const trimmed = std.mem.trimStart(u8, lines[i].text, " ");
        if (std.mem.startsWith(u8, trimmed, "File \"")) {
            if (nframes < st.frames.len) {
                if (parseFileLine(trimmed, &st.frame_texts[nframes])) |frame| {
                    st.frames[nframes] = frame;
                    nframes += 1;
                }
            }
            end = i + 1;
        } else if (lines[i].text.len > 0 and lines[i].text[0] != ' ') {
            end = i + 1; // "SomeError: msg" terminator
            break;
        } else {
            end = i + 1; // source echo line
        }
    }
    if (nframes == 0) return null;

    // Python prints outermost first; reverse so frames[0] is the crash site.
    std.mem.reverse([]const u8, st.frames[0..nframes]);

    return .{
        .lang = "python",
        .frames = st.frames[0..nframes],
        .raw = summarize.joinRaw(lines, start, @min(end, lines.len), st),
    };
}

/// `File "/app/x.py", line 7, in main` -> "main /app/x.py:7"
fn parseFileLine(trimmed: []const u8, out: *[192]u8) ?[]const u8 {
    const q1 = "File \"".len;
    const q2 = std.mem.indexOfScalarPos(u8, trimmed, q1, '"') orelse return null;
    const file = trimmed[q1..q2];
    const line_pat = ", line ";
    const lp = std.mem.indexOfPos(u8, trimmed, q2, line_pat) orelse return null;
    var j = lp + line_pat.len;
    const num_start = j;
    while (j < trimmed.len and trimmed[j] >= '0' and trimmed[j] <= '9') j += 1;
    if (j == num_start) return null;
    const lineno = trimmed[num_start..j];
    var func: []const u8 = "?";
    const in_pat = ", in ";
    if (std.mem.indexOfPos(u8, trimmed, j, in_pat)) |ip| func = trimmed[ip + in_pat.len ..];
    return std.fmt.bufPrint(out, "{s} {s}:{s}", .{ func, file, lineno }) catch null;
}

// ---------------------------------------------------------------- tests

const t = std.testing;
const F = summarize.LogLine;

test "parses a python traceback, crash site first" {
    const lines = [_]F{
        .{ .text = "starting up", .flags = 0 },
        .{ .text = "Traceback (most recent call last):", .flags = 1 },
        .{ .text = "  File \"/app/x.py\", line 10, in <module>", .flags = 1 },
        .{ .text = "    main()", .flags = 1 },
        .{ .text = "  File \"/app/x.py\", line 7, in main", .flags = 1 },
        .{ .text = "    return 1/0", .flags = 1 },
        .{ .text = "ZeroDivisionError: division by zero", .flags = 1 },
    };
    var st: summarize.TraceStorage = .{};
    const tr = detect(&lines, &st).?;
    try t.expectEqualStrings("python", tr.lang);
    try t.expectEqual(@as(usize, 2), tr.frames.len);
    try t.expectEqualStrings("main /app/x.py:7", tr.frames[0]);
    try t.expectEqualStrings("<module> /app/x.py:10", tr.frames[1]);
    try t.expect(std.mem.endsWith(u8, tr.raw, "ZeroDivisionError: division by zero"));
}

test "no traceback -> null" {
    const lines = [_]F{.{ .text = "ok", .flags = 0 }};
    var st: summarize.TraceStorage = .{};
    try t.expectEqual(@as(?summarize.TraceInfo, null), detect(&lines, &st));
}
