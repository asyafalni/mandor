//! Node.js stack-trace parser.
//!   Error: boom
//!       at crash (/app/server.js:10:9)
//!       at Object.<anonymous> (/app/server.js:14:1)
//!       at Module._compile (node:internal/modules/cjs/loader:1358:14)
//! Also bare frames: "    at /app/server.js:10:9".

const std = @import("std");
const summarize = @import("../summarize.zig");

pub fn detect(lines: []const summarize.LogLine, st: *summarize.TraceStorage) ?summarize.TraceInfo {
    // Header: last "SomethingError: msg" (or bare "Error: msg") line that is
    // followed by an "at " frame.
    var header: ?usize = null;
    for (lines, 0..) |l, i| {
        if (!isErrorHeader(l.text)) continue;
        if (i + 1 < lines.len and isFrameLine(lines[i + 1].text)) header = i;
    }
    const start = header orelse return null;

    var nframes: usize = 0;
    var end = start + 1;
    var i = start + 1;
    while (i < lines.len and nframes < st.frames.len) : (i += 1) {
        const trimmed = std.mem.trimStart(u8, lines[i].text, " ");
        if (!std.mem.startsWith(u8, trimmed, "at ")) break;
        if (parseFrame(trimmed[3..])) |frame| {
            st.frames[nframes] = frame;
            nframes += 1;
        }
        end = i + 1;
    }
    if (nframes == 0) return null;

    const head = lines[start].text;
    const colon = std.mem.indexOf(u8, head, ": ");
    return .{
        .lang = "node",
        .frames = st.frames[0..nframes],
        .raw = summarize.joinRaw(lines, start, @min(end, lines.len), st),
        .exc_type = if (colon) |c| head[0..c] else head,
        .exc_msg = if (colon) |c| head[c + 2 ..] else "",
    };
}

fn isErrorHeader(text: []const u8) bool {
    // "Error: ..." or "TypeError: ..." etc. — an identifier ending in Error
    // (or AssertionError variants) followed by ": ".
    const colon = std.mem.indexOf(u8, text, ": ") orelse return false;
    const name = text[0..colon];
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '$') return false;
    }
    return std.mem.endsWith(u8, name, "Error") or std.mem.endsWith(u8, name, "Exception");
}

fn isFrameLine(text: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trimStart(u8, text, " "), "at ");
}

/// "crash (/app/server.js:10:9)" | "/app/server.js:10:9" -> Frame
fn parseFrame(rest: []const u8) ?summarize.Frame {
    var function: []const u8 = "<anonymous>";
    var loc = rest;
    if (std.mem.indexOf(u8, rest, " (")) |p| {
        if (std.mem.endsWith(u8, rest, ")")) {
            function = rest[0..p];
            loc = rest[p + 2 .. rest.len - 1];
        }
    }
    // loc = file:line:col — line is the SECOND-to-last colon field
    const last = std.mem.lastIndexOfScalar(u8, loc, ':') orelse return null;
    const second = std.mem.lastIndexOfScalar(u8, loc[0..last], ':') orelse return null;
    const line = std.fmt.parseInt(u32, loc[second + 1 .. last], 10) catch return null;
    const file = loc[0..second];
    return .{
        .function = function,
        .file = file,
        .line = line,
        .in_app = !std.mem.startsWith(u8, file, "node:") and
            std.mem.indexOf(u8, file, "node_modules") == null,
    };
}

// ---------------------------------------------------------------- tests

const t = std.testing;
const F = summarize.LogLine;

test "parses a node stack trace" {
    const lines = [_]F{
        .{ .text = "listening", .flags = 0 },
        .{ .text = "TypeError: Cannot read properties of undefined (reading 'x')", .flags = 1 },
        .{ .text = "    at crash (/app/server.js:10:9)", .flags = 1 },
        .{ .text = "    at Object.<anonymous> (/app/server.js:14:1)", .flags = 1 },
        .{ .text = "    at Module._compile (node:internal/modules/cjs/loader:1358:14)", .flags = 1 },
    };
    var st: summarize.TraceStorage = .{};
    const tr = detect(&lines, &st).?;
    try t.expectEqualStrings("node", tr.lang);
    try t.expectEqualStrings("TypeError", tr.exc_type);
    try t.expectEqualStrings("Cannot read properties of undefined (reading 'x')", tr.exc_msg);
    try t.expectEqual(@as(usize, 3), tr.frames.len);
    try t.expectEqualStrings("crash", tr.frames[0].function);
    try t.expectEqualStrings("/app/server.js", tr.frames[0].file);
    try t.expectEqual(@as(u32, 10), tr.frames[0].line);
    try t.expect(tr.frames[0].in_app);
    try t.expect(!tr.frames[2].in_app); // node:internal
}

test "bare frame form and no-trace input" {
    const lines = [_]F{
        .{ .text = "Error: boom", .flags = 1 },
        .{ .text = "    at /app/x.js:3:1", .flags = 1 },
    };
    var st: summarize.TraceStorage = .{};
    const tr = detect(&lines, &st).?;
    try t.expectEqualStrings("<anonymous>", tr.frames[0].function);
    try t.expectEqual(@as(u32, 3), tr.frames[0].line);

    const none = [_]F{.{ .text = "Error: lonely without frames", .flags = 1 }};
    var st2: summarize.TraceStorage = .{};
    try t.expectEqual(@as(?summarize.TraceInfo, null), detect(&none, &st2));
}
