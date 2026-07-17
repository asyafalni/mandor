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
    return st.raw[0 .. @max(pos, 1) - 1];
}

// ------------------------------------------------------- diagnosis

const sampler = @import("sampler.zig");

/// Known failure patterns scanned in the log tail — each maps symptom to a
/// "what's actually wrong" explanation.
const known_patterns = .{
    .{ "address already in use", "port already in use — something else bound it first" },
    .{ "permission denied", "permission denied — check file/dir ownership in the image" },
    .{ "no such file or directory", "references a missing file or directory" },
    .{ "cannot allocate memory", "memory allocation failures before death" },
    .{ "out of memory", "memory allocation failures before death" },
    .{ "connection refused", "downstream dependency refusing connections" },
    .{ "unable to open database", "database unreachable or locked" },
    .{ "too many open files", "fd exhaustion — raise ulimit or fix an fd leak" },
};

fn knownPattern(lines: []const LogLine) ?[]const u8 {
    inline for (known_patterns) |kp| {
        for (lines) |l| {
            if (containsIgnoreCase(l.text, kp[0])) return kp[1];
        }
    }
    return null;
}

/// Most-repeated error-ish line (digit-insensitive), when it fired >= 3 times.
fn repeatedError(lines: []const LogLine, rep_buf: *[96]u8) ?[]const u8 {
    var hashes: [16]u64 = .{0} ** 16;
    var counts: [16]u32 = .{0} ** 16;
    var reps: [16][]const u8 = undefined;
    var n: usize = 0;
    for (lines) |l| {
        if (!errorish(l.text)) continue;
        const h = signature("rep", "", l.text);
        var found = false;
        for (0..n) |i| {
            if (hashes[i] == h) {
                counts[i] += 1;
                found = true;
                break;
            }
        }
        if (!found and n < hashes.len) {
            hashes[n] = h;
            counts[n] = 1;
            reps[n] = l.text;
            n += 1;
        }
    }
    var best: usize = 0;
    var best_count: u32 = 0;
    for (0..n) |i| {
        if (counts[i] > best_count) {
            best = i;
            best_count = counts[i];
        }
    }
    if (best_count < 3) return null;
    const text = reps[best][0..@min(reps[best].len, 60)];
    return std.fmt.bufPrint(rep_buf, "error repeated {d}x: \"{s}\"", .{
        counts[best], text,
    }) catch null;
}

/// Pre-death resource anomaly from the stats window.
fn statsAnomaly(stats: []const sampler.Sample, killed: bool, buf: *[96]u8) ?[]const u8 {
    if (stats.len == 0) return null;
    const last = stats[stats.len - 1];
    if (killed and last.rss_kb >= 100 * 1024) {
        return std.fmt.bufPrint(buf, "SIGKILL with RSS at {d}MB — possible OOM kill", .{
            last.rss_kb / 1024,
        }) catch null;
    }
    if (last.cpu_pct >= 95) {
        return std.fmt.bufPrint(buf, "CPU pegged at {d}% before death", .{last.cpu_pct}) catch null;
    }
    if (stats.len >= 4) {
        const first = stats[0];
        if (last.rss_kb > first.rss_kb and last.rss_kb - first.rss_kb >= 16 * 1024) {
            return std.fmt.bufPrint(buf, "RSS climbed +{d}MB before death", .{
                (last.rss_kb - first.rss_kb) / 1024,
            }) catch null;
        }
        if (first.fds > 0 and last.fds >= first.fds * 4 and last.fds > 64) {
            return std.fmt.bufPrint(buf, "fd count climbing ({d} open)", .{last.fds}) catch null;
        }
    }
    return null;
}

/// The full "what went wrong" one-liner: cause + up to two insights, best
/// evidence first (trace > known pattern > repeated error > stats anomaly).
pub fn diagnose(
    buf: []u8,
    cause: []const u8,
    trace: TraceInfo,
    lines: []const LogLine,
    stats: []const sampler.Sample,
    uptime_s: u64,
    killed_by_kill: bool,
) []const u8 {
    var trace_buf: [224]u8 = undefined;
    var rep_buf: [96]u8 = undefined;
    var stat_buf: [96]u8 = undefined;

    var insights: [2][]const u8 = undefined;
    var n: usize = 0;
    if (trace.frames.len > 0) {
        if (std.fmt.bufPrint(&trace_buf, "{s} panic in {s}", .{
            trace.lang, trace.frames[0],
        }) catch null) |s| {
            insights[n] = s;
            n += 1;
        }
    }
    if (knownPattern(lines)) |s| {
        if (n < 2) {
            insights[n] = s;
            n += 1;
        }
    }
    if (n < 2) {
        if (repeatedError(lines, &rep_buf)) |s| {
            insights[n] = s;
            n += 1;
        }
    }
    if (n < 2) {
        if (statsAnomaly(stats, killed_by_kill, &stat_buf)) |s| {
            insights[n] = s;
            n += 1;
        }
    }

    return switch (n) {
        0 => std.fmt.bufPrint(buf, "{s} after {d}s uptime", .{ cause, uptime_s }) catch cause,
        1 => std.fmt.bufPrint(buf, "{s} after {d}s — {s}", .{
            cause, uptime_s, insights[0],
        }) catch cause,
        else => std.fmt.bufPrint(buf, "{s} after {d}s — {s}; {s}", .{
            cause, uptime_s, insights[0], insights[1],
        }) catch cause,
    };
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
    var buf: [256]u8 = undefined;
    const v3 = verdictRestartLoop(&buf, 5, 300, "exit:1");
    try std.testing.expectEqualStrings("restart loop: 5 restarts in 5min, last cause exit:1", v3);
    const v4 = verdictLeak(&buf, 480, 12);
    try std.testing.expectEqualStrings("RSS grew ~40.0MB/min for 12min (+480MB) — leak suspect", v4);
}

test "diagnose: trace beats everything" {
    var buf: [256]u8 = undefined;
    const frames = [_][]const u8{"main.crash main.go:10"};
    const v = diagnose(&buf, "signal:SIGSEGV", .{ .lang = "go", .frames = &frames }, &.{}, &.{}, 5, false);
    try std.testing.expectEqualStrings("signal:SIGSEGV after 5s — go panic in main.crash main.go:10", v);
}

test "diagnose: known pattern explains the failure" {
    var buf: [256]u8 = undefined;
    const lines = [_]LogLine{
        .{ .text = "bind: Address already in use", .flags = 1 },
    };
    const v = diagnose(&buf, "exit:1", .{}, &lines, &.{}, 2, false);
    try std.testing.expectEqualStrings(
        "exit:1 after 2s — port already in use — something else bound it first",
        v,
    );
}

test "diagnose: repeated errors counted digit-insensitively" {
    var buf: [256]u8 = undefined;
    const lines = [_]LogLine{
        .{ .text = "error: request 17 timed out", .flags = 1 },
        .{ .text = "error: request 42 timed out", .flags = 1 },
        .{ .text = "error: request 99 timed out", .flags = 1 },
        .{ .text = "listening", .flags = 0 },
    };
    const v = diagnose(&buf, "exit:1", .{}, &lines, &.{}, 60, false);
    try std.testing.expectEqualStrings(
        "exit:1 after 60s — error repeated 3x: \"error: request 17 timed out\"",
        v,
    );
}

test "diagnose: sigkill with high rss suggests oom" {
    var buf: [256]u8 = undefined;
    const stats = [_]sampler.Sample{
        .{ .t_ms = 0, .rss_kb = 831_488 },
    };
    const v = diagnose(&buf, "signal:SIGKILL", .{}, &.{}, &stats, 120, true);
    try std.testing.expectEqualStrings(
        "signal:SIGKILL after 120s — SIGKILL with RSS at 812MB — possible OOM kill",
        v,
    );
}

test "diagnose: two insights compose" {
    var buf: [256]u8 = undefined;
    const lines = [_]LogLine{
        .{ .text = "FATAL: could not connect: Connection refused", .flags = 1 },
    };
    const stats = [_]sampler.Sample{
        .{ .t_ms = 0, .cpu_pct = 99 },
    };
    const v = diagnose(&buf, "exit:1", .{}, &lines, &stats, 9, false);
    try std.testing.expectEqualStrings(
        "exit:1 after 9s — downstream dependency refusing connections; CPU pegged at 99% before death",
        v,
    );
}

test "diagnose: bare fallback" {
    var buf: [256]u8 = undefined;
    const v = diagnose(&buf, "exit:3", .{}, &.{}, &.{}, 42, false);
    try std.testing.expectEqualStrings("exit:3 after 42s uptime", v);
}
