//! JVM stack-trace parser (frame lines are tab-indented "at ..."):
//!   Exception in thread "main" java.lang.NullPointerException: msg
//!   <tab>at com.example.App.crash(App.java:10)
//!   Caused by: java.lang.IllegalStateException: root

const std = @import("std");
const summarize = @import("../summarize.zig");

pub fn detect(lines: []const summarize.LogLine, st: *summarize.TraceStorage) ?summarize.TraceInfo {
    // Header: FIRST non-frame line followed by a tab-"at " frame — the JVM
    // prints the outermost exception first; "Caused by:" chains follow.
    var header: ?usize = null;
    for (lines, 0..) |l, i| {
        _ = l;
        if (i + 1 < lines.len and isFrameLine(lines[i + 1].text) and
            !isFrameLine(lines[i].text))
        {
            header = i;
            break;
        }
    }
    const start = header orelse return null;

    var nframes: usize = 0;
    var end = start + 1;
    var i = start + 1;
    while (i < lines.len and nframes < st.frames.len) : (i += 1) {
        const text = lines[i].text;
        if (isFrameLine(text)) {
            if (parseFrame(std.mem.trimStart(u8, text, "\t "))) |frame| {
                st.frames[nframes] = frame;
                nframes += 1;
            }
            end = i + 1;
        } else if (std.mem.startsWith(u8, text, "Caused by: ") or
            std.mem.startsWith(u8, std.mem.trimStart(u8, text, "\t "), "... "))
        {
            end = i + 1; // keep suppressed-frames + cause chain in raw
        } else break;
    }
    if (nframes == 0) return null;

    // Header: "Exception in thread "x" TYPE: msg" | "TYPE: msg" | "TYPE"
    var head = lines[start].text;
    if (std.mem.startsWith(u8, head, "Exception in thread ")) {
        if (std.mem.indexOf(u8, head[20..], "\" ")) |q| head = head[20 + q + 2 ..];
    }
    const colon = std.mem.indexOf(u8, head, ": ");
    return .{
        .lang = "java",
        .frames = st.frames[0..nframes],
        .raw = summarize.joinRaw(lines, start, @min(end, lines.len), st),
        .exc_type = if (colon) |c| head[0..c] else head,
        .exc_msg = if (colon) |c| head[c + 2 ..] else "",
    };
}

fn isFrameLine(text: []const u8) bool {
    const trimmed = std.mem.trimStart(u8, text, "\t ");
    return trimmed.len != text.len and std.mem.startsWith(u8, trimmed, "at ");
}

/// "at com.example.App.crash(App.java:10)" -> Frame
fn parseFrame(trimmed: []const u8) ?summarize.Frame {
    const body = trimmed[3..];
    const open = std.mem.lastIndexOfScalar(u8, body, '(') orelse return null;
    if (!std.mem.endsWith(u8, body, ")")) return null;
    const function = body[0..open];
    const loc = body[open + 1 .. body.len - 1]; // File.java:10 | Native Method
    var file: []const u8 = loc;
    var line: u32 = 0;
    if (std.mem.lastIndexOfScalar(u8, loc, ':')) |c| {
        line = std.fmt.parseInt(u32, loc[c + 1 ..], 10) catch 0;
        file = loc[0..c];
    }
    return .{
        .function = function,
        .file = file,
        .line = line,
        .in_app = !std.mem.startsWith(u8, function, "java.") and
            !std.mem.startsWith(u8, function, "javax.") and
            !std.mem.startsWith(u8, function, "jdk.") and
            !std.mem.startsWith(u8, function, "sun.") and
            !std.mem.startsWith(u8, function, "kotlin."),
    };
}

// ---------------------------------------------------------------- tests

const t = std.testing;
const F = summarize.LogLine;

test "parses a jvm stack trace with cause chain" {
    const lines = [_]F{
        .{ .text = "Exception in thread \"main\" java.lang.NullPointerException: oops", .flags = 1 },
        .{ .text = "\tat com.example.App.crash(App.java:10)", .flags = 1 },
        .{ .text = "\tat java.base/java.lang.Thread.run(Thread.java:833)", .flags = 1 },
        .{ .text = "Caused by: java.lang.IllegalStateException: root", .flags = 1 },
        .{ .text = "\tat com.example.Db.open(Db.java:42)", .flags = 1 },
    };
    var st: summarize.TraceStorage = .{};
    const tr = detect(&lines, &st).?;
    try t.expectEqualStrings("java", tr.lang);
    try t.expectEqualStrings("java.lang.NullPointerException", tr.exc_type);
    try t.expectEqualStrings("oops", tr.exc_msg);
    try t.expectEqual(@as(usize, 3), tr.frames.len);
    try t.expectEqualStrings("com.example.App.crash", tr.frames[0].function);
    try t.expectEqualStrings("App.java", tr.frames[0].file);
    try t.expectEqual(@as(u32, 10), tr.frames[0].line);
    try t.expect(tr.frames[0].in_app);
    try t.expect(std.mem.indexOf(u8, tr.raw, "Caused by") != null);
}

test "no trace -> null" {
    const lines = [_]F{.{ .text = "Started App in 2.3 seconds", .flags = 0 }};
    var st: summarize.TraceStorage = .{};
    try t.expectEqual(@as(?summarize.TraceInfo, null), detect(&lines, &st));
}
