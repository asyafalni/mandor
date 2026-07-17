//! Heuristic incident summarization: error-line detection, dedup signatures,
//! trace-parser dispatch, verdict one-liners. Pure — no OS calls, no LLM.

const std = @import("std");
const ring = @import("ring.zig");

pub const LogLine = struct { text: []const u8, flags: u8 };

pub const TraceInfo = struct {
    lang: []const u8 = "unknown",
    frames: []const []const u8 = &.{},
    raw: []const u8 = "",
};

/// Fixed storage a parser fills; owned by the caller (static in supervisor).
pub const TraceStorage = struct {
    frame_texts: [16][192]u8 = undefined,
    frames: [16][]const u8 = undefined,
    raw: [4096]u8 = undefined,
};

pub fn containsIgnoreCase(haystack: []const u8, comptime needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len and std.ascii.toLower(haystack[i + j]) == needle[j]) j += 1;
        if (j == needle.len) return true;
    }
    return false;
}

/// Does this log line look like an error/warning?
pub fn errorish(line: []const u8) bool {
    return containsIgnoreCase(line, "panic") or
        containsIgnoreCase(line, "error") or
        containsIgnoreCase(line, "fatal") or
        containsIgnoreCase(line, "exception") or
        containsIgnoreCase(line, "traceback") or
        containsIgnoreCase(line, "warn");
}

/// Dedup signature: FNV-1a over cause kind + worker name + the error line
/// with digits stripped (so "worker 17 died" == "worker 42 died").
pub fn signature(cause_kind: []const u8, name: []const u8, err_line: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (cause_kind) |c| h = (h ^ c) *% 0x100000001b3;
    h = (h ^ 0xff) *% 0x100000001b3;
    for (name) |c| h = (h ^ c) *% 0x100000001b3;
    h = (h ^ 0xff) *% 0x100000001b3;
    for (err_line) |c| {
        if (c >= '0' and c <= '9') continue;
        h = (h ^ c) *% 0x100000001b3;
    }
    return h;
}

/// First error-looking line (prefer stderr), for signatures and verdicts.
pub fn firstErrorLine(lines: []const LogLine) []const u8 {
    for (lines) |l| {
        if (l.flags & ring.flag_stderr != 0 and errorish(l.text)) return l.text;
    }
    for (lines) |l| {
        if (errorish(l.text)) return l.text;
    }
    return "";
}

const go = @import("parsers/go.zig");
const rust = @import("parsers/rust.zig");
const python = @import("parsers/python.zig");

/// Try each language parser over the log tail; go/rust first (structured
/// stderr), python third, per CLAUDE.md build order.
pub fn extractTrace(lines: []const LogLine, st: *TraceStorage) TraceInfo {
    if (go.detect(lines, st)) |t| return t;
    if (rust.detect(lines, st)) |t| return t;
    if (python.detect(lines, st)) |t| return t;
    return .{};
}

/// Join lines[from..to] into st.raw (capped), for TraceInfo.raw.
pub fn joinRaw(lines: []const LogLine, from: usize, to: usize, st: *TraceStorage) []const u8 {
    var pos: usize = 0;
    for (lines[from..to]) |l| {
        const need = l.text.len + 1;
        if (pos + need > st.raw.len) break;
        @memcpy(st.raw[pos..][0..l.text.len], l.text);
        pos += l.text.len;
        st.raw[pos] = '\n';
        pos += 1;
    }
    return st.raw[0..@max(pos, 1) - 1];
}

// ------------------------------------------------------- verdicts

pub fn verdictDeath(buf: []u8, cause: []const u8, trace: TraceInfo, uptime_s: u64) []const u8 {
    if (trace.frames.len > 0) {
        return std.fmt.bufPrint(buf, "{s} panic in {s} ({s})", .{
            trace.lang, trace.frames[0], cause,
        }) catch cause;
    }
    return std.fmt.bufPrint(buf, "{s} after {d}s uptime", .{ cause, uptime_s }) catch cause;
}

pub fn verdictRestartLoop(buf: []u8, count: u32, window_s: u64, last_cause: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "restart loop: {d} restarts in {d}min, last cause {s}", .{
        count, window_s / 60, last_cause,
    }) catch "restart loop";
}

pub fn verdictLeak(buf: []u8, growth_mb: u64, minutes: u64) []const u8 {
    const rate10 = if (minutes == 0) 0 else growth_mb * 10 / minutes;
    return std.fmt.bufPrint(buf, "RSS grew ~{d}.{d}MB/min for {d}min (+{d}MB) — leak suspect", .{
        rate10 / 10, rate10 % 10, minutes, growth_mb,
    }) catch "leak suspect";
}

// ---------------------------------------------------------------- tests

test "errorish detection" {
    try std.testing.expect(errorish("PANIC: oh no"));
    try std.testing.expect(errorish("some Error occurred"));
    try std.testing.expect(errorish("[WARN] disk full"));
    try std.testing.expect(errorish("Traceback (most recent call last):"));
    try std.testing.expect(!errorish("listening on :8080"));
    try std.testing.expect(!errorish(""));
}

test "signature ignores digits, distinguishes cause and name" {
    const a = signature("exit", "api", "worker 17 died at 0x1234");
    const b = signature("exit", "api", "worker 42 died at 0x9999");
    const c = signature("exit", "api", "different message");
    const d = signature("signal", "api", "worker 17 died at 0x1234");
    const e = signature("exit", "web", "worker 17 died at 0x1234");
    try std.testing.expectEqual(a, b);
    try std.testing.expect(a != c);
    try std.testing.expect(a != d);
    try std.testing.expect(a != e);
}

test "verdict builders" {
    var buf: [128]u8 = undefined;
    const frames = [_][]const u8{"main.crash main.go:10"};
    const v1 = verdictDeath(&buf, "signal:SIGSEGV", .{ .lang = "go", .frames = &frames }, 5);
    try std.testing.expectEqualStrings("go panic in main.crash main.go:10 (signal:SIGSEGV)", v1);
    const v2 = verdictDeath(&buf, "exit:1", .{}, 42);
    try std.testing.expectEqualStrings("exit:1 after 42s uptime", v2);
    const v3 = verdictRestartLoop(&buf, 5, 300, "exit:1");
    try std.testing.expectEqualStrings("restart loop: 5 restarts in 5min, last cause exit:1", v3);
    const v4 = verdictLeak(&buf, 480, 12);
    try std.testing.expectEqualStrings("RSS grew ~40.0MB/min for 12min (+480MB) — leak suspect", v4);
}
