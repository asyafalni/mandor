//! Go panic parser. Line-oriented scan, no regex.
//!
//! Shape:
//!   panic: runtime error: invalid memory address or nil pointer dereference
//!   [signal SIGSEGV: ...]
//!
//!   goroutine 1 [running]:
//!   main.crash(0x0?)
//!   \t/app/main.go:10 +0x18
//!   main.main()
//!   \t/app/main.go:4 +0x1c

const std = @import("std");
const summarize = @import("../summarize.zig");

pub fn detect(lines: []const summarize.LogLine, st: *summarize.TraceStorage) ?summarize.TraceInfo {
    var panic_idx: ?usize = null;
    for (lines, 0..) |l, i| {
        if (std.mem.startsWith(u8, l.text, "panic: ")) {
            panic_idx = i; // keep the LAST panic in the tail (freshest crash)
        }
    }
    const start = panic_idx orelse return null;

    var nframes: usize = 0;
    var i = start + 1;
    var end = start + 1;
    var in_goroutine = false;
    while (i < lines.len and nframes < st.frames.len) : (i += 1) {
        const text = lines[i].text;
        if (std.mem.startsWith(u8, text, "goroutine ")) {
            in_goroutine = true;
            end = i + 1;
            continue;
        }
        if (!in_goroutine) {
            end = i + 1;
            continue;
        }
        if (text.len == 0) break;
        // frame = function line followed by a tab-indented "file.go:123 +0x.." line
        if (text[0] != '\t' and i + 1 < lines.len and lines[i + 1].text.len > 1 and
            lines[i + 1].text[0] == '\t')
        {
            const func = stripArgs(text);
            var loc = std.mem.trim(u8, lines[i + 1].text, "\t ");
            if (std.mem.indexOfScalar(u8, loc, ' ')) |sp| loc = loc[0..sp]; // drop "+0x18"
            const fl = summarize.splitFileLine(loc);
            st.frames[nframes] = .{
                .function = func,
                .file = fl.file,
                .line = fl.line,
                .in_app = !std.mem.startsWith(u8, func, "runtime."),
            };
            nframes += 1;
            end = i + 2;
        }
    }
    if (nframes == 0) return null;

    // "panic: runtime error: nil deref" -> type "runtime error", msg tail;
    // "panic: custom message" -> type "panic", msg as-is.
    const payload = lines[start].text["panic: ".len..];
    var exc_type: []const u8 = "panic";
    var exc_msg = payload;
    if (std.mem.startsWith(u8, payload, "runtime error: ")) {
        exc_type = "runtime error";
        exc_msg = payload["runtime error: ".len..];
    }

    return .{
        .lang = "go",
        .frames = st.frames[0..nframes],
        .raw = summarize.joinRaw(lines, start, @min(end, lines.len), st),
        .exc_type = exc_type,
        .exc_msg = exc_msg,
    };
}

/// "main.crash(0x0?)" -> "main.crash"
fn stripArgs(func: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, func, '(')) |p| return func[0..p];
    return func;
}

// ---------------------------------------------------------------- tests

const t = std.testing;
const F = summarize.LogLine;

test "parses a real go panic" {
    const lines = [_]F{
        .{ .text = "listening on :8080", .flags = 0 },
        .{ .text = "panic: runtime error: invalid memory address or nil pointer dereference", .flags = 1 },
        .{ .text = "[signal SIGSEGV: segmentation violation code=0x1 addr=0x0 pc=0x47b8d8]", .flags = 1 },
        .{ .text = "", .flags = 1 },
        .{ .text = "goroutine 1 [running]:", .flags = 1 },
        .{ .text = "main.crash(0x0?)", .flags = 1 },
        .{ .text = "\t/app/main.go:10 +0x18", .flags = 1 },
        .{ .text = "main.main()", .flags = 1 },
        .{ .text = "\t/app/main.go:4 +0x1c", .flags = 1 },
    };
    var st: summarize.TraceStorage = .{};
    const tr = detect(&lines, &st).?;
    try t.expectEqualStrings("go", tr.lang);
    try t.expectEqualStrings("runtime error", tr.exc_type);
    try t.expectEqualStrings("invalid memory address or nil pointer dereference", tr.exc_msg);
    try t.expectEqual(@as(usize, 2), tr.frames.len);
    try t.expectEqualStrings("main.crash", tr.frames[0].function);
    try t.expectEqualStrings("/app/main.go", tr.frames[0].file);
    try t.expectEqual(@as(u32, 10), tr.frames[0].line);
    try t.expect(tr.frames[0].in_app);
    try t.expectEqualStrings("main.main", tr.frames[1].function);
    try t.expectEqual(@as(u32, 4), tr.frames[1].line);
    try t.expect(std.mem.startsWith(u8, tr.raw, "panic: runtime error"));
}

test "no panic -> null" {
    const lines = [_]F{.{ .text = "all good", .flags = 0 }};
    var st: summarize.TraceStorage = .{};
    try t.expectEqual(@as(?summarize.TraceInfo, null), detect(&lines, &st));
}
