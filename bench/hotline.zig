//! Micro-benchmark for the per-captured-line hot path WHEN photon is on.
//!
//! With `photon=` set, mandor classifies every captured line's severity on the
//! supervision capture path (`summarize.logSeverity`) so the Tier-2 digest can
//! bucket warn/error lines. A high-volume INFO flood (access/debug logs — the
//! common spammy-worker case) is the worst case: every line is scanned to its
//! full length finding no keyword, and the classifier never early-returns.
//!
//! This measures that classifier on realistic input, against a first-char
//! dispatch variant that computes toLower(line[i]) ONCE per position and only
//! probes the keyword(s) starting with that char — semantically identical to the
//! current per-position ×6 `kwAt` scan. It also measures the warn/error-only
//! digest.record cost (signature FNV over the line + linear scan of the table).
//!
//! Mirrors src/summarize.zig and src/digest.zig (bench/ convention: self-
//! contained, run manually). Run: zig run bench/hotline.zig -OReleaseSafe

const std = @import("std");

// ---- current logSeverity (mirror of src/summarize.zig) --------------------

inline fn kwAt(line: []const u8, at: usize, comptime kw: []const u8) bool {
    if (at + kw.len > line.len) return false;
    inline for (kw, 0..) |c, k| {
        if (std.ascii.toLower(line[at + k]) != c) return false;
    }
    return true;
}

fn logSeverityCur(line: []const u8) u8 {
    var sev: u8 = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (kwAt(line, i, "error") or kwAt(line, i, "panic") or
            kwAt(line, i, "fatal") or kwAt(line, i, "exception") or
            kwAt(line, i, "traceback")) return 2;
        if (sev == 0 and kwAt(line, i, "warn")) sev = 1;
    }
    return sev;
}

// ---- first-char dispatch variant (semantically identical) -----------------
//
// Keyword initials are unique per group: error/exception -> 'e', panic -> 'p',
// fatal -> 'f', traceback -> 't', warn -> 'w'. So one toLower(line[i]) and a
// switch on it reaches the same keywords `kwAt` would, without recomputing the
// first char once per keyword and without touching positions whose char starts
// no keyword at all.

fn kwRest(line: []const u8, at: usize, comptime kw: []const u8) bool {
    // First char already matched by the switch; verify the remainder.
    if (at + kw.len > line.len) return false;
    inline for (kw, 0..) |c, k| {
        if (k == 0) continue;
        if (std.ascii.toLower(line[at + k]) != c) return false;
    }
    return true;
}

fn logSeverityFast(line: []const u8) u8 {
    var sev: u8 = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        switch (std.ascii.toLower(line[i])) {
            'e' => if (kwRest(line, i, "error") or kwRest(line, i, "exception")) return 2,
            'p' => if (kwRest(line, i, "panic")) return 2,
            'f' => if (kwRest(line, i, "fatal")) return 2,
            't' => if (kwRest(line, i, "traceback")) return 2,
            'w' => if (sev == 0 and kwRest(line, i, "warn")) {
                sev = 1;
            },
            else => {},
        }
    }
    return sev;
}

// ---- digest.record hot part (mirror of src/digest.zig) --------------------

fn signature(cause_kind: []const u8, name: []const u8, err_line: []const u8) u64 {
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

const max_sigs = 64;
var sigs: [max_sigs]u64 = undefined;
var counts: [max_sigs]u32 = undefined;
var live: usize = 0;

fn recordDigest(name: []const u8, sev: u8, line: []const u8) void {
    if (sev == 0) return;
    const label: []const u8 = if (sev >= 2) "error" else "warn";
    const sig = signature(label, name, line);
    for (sigs[0..live], 0..) |s, k| {
        if (s == sig) {
            counts[k] +|= 1;
            return;
        }
    }
    if (live == max_sigs) return;
    sigs[live] = sig;
    counts[live] = 1;
    live += 1;
}

fn nowNs() u64 {
    var ts = std.os.linux.timespec{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @intCast(ts.sec * 1_000_000_000 + ts.nsec);
}

pub fn main() void {
    // Realistic flood: an access-log-shaped INFO line dominates; 1-in-50 warn,
    // 1-in-100 error. INFO lines never early-return in the classifier, so they
    // set the worst-case cost.
    const info = "2026-08-21T11:00:00Z INF request completed method=GET path=/api/v1/things status=200 duration_ms=13 bytes=4096 remote=10.0.0.42 trace=abc123def456 user=svc-account-7 region=ap-southeast-1";
    const warn = "2026-08-21T11:00:00Z WARN backpressure: queue depth 8123 exceeds soft limit, shedding";
    const err = "2026-08-21T11:00:00Z ERROR upstream refused connection after 3 retries, giving up";

    var lines: [1000][]const u8 = undefined;
    for (&lines, 0..) |*l, i| {
        l.* = if (i % 100 == 99) err else if (i % 50 == 49) warn else info;
    }

    const rounds = 4000;
    var sink: u64 = 0;

    // Classifier: current.
    var t0 = nowNs();
    for (0..rounds) |_| for (lines) |l| {
        sink +%= logSeverityCur(l);
    };
    const cur_ns = nowNs() - t0;

    // Classifier: first-char dispatch.
    t0 = nowNs();
    for (0..rounds) |_| for (lines) |l| {
        sink +%= logSeverityFast(l);
    };
    const fast_ns = nowNs() - t0;

    // Equivalence guard: both classifiers must agree on every line.
    var mismatch: usize = 0;
    for (lines) |l| if (logSeverityCur(l) != logSeverityFast(l)) {
        mismatch += 1;
    };

    // digest.record for the warn/error subset (info is skipped by the caller).
    live = 0;
    t0 = nowNs();
    for (0..rounds) |_| for (lines) |l| {
        const sev = logSeverityFast(l);
        if (sev != 0) recordDigest("api", sev, l);
    };
    const digest_ns = nowNs() - t0;

    const n_lines = rounds * lines.len;
    std.debug.print(
        \\lines               {d} ({d} bytes info, warn 1/50, err 1/100)
        \\logSeverity  current {d:>7.1} ns/line
        \\logSeverity  fast    {d:>7.1} ns/line   ({d:.2}x)
        \\classify+digest      {d:>7.1} ns/line   (fast classify + record on warn/err)
        \\equivalence          {s}
        \\(sink {d}, live {d})
        \\
    , .{
        n_lines,
        info.len,
        @as(f64, @floatFromInt(cur_ns)) / @as(f64, @floatFromInt(n_lines)),
        @as(f64, @floatFromInt(fast_ns)) / @as(f64, @floatFromInt(n_lines)),
        @as(f64, @floatFromInt(cur_ns)) / @as(f64, @floatFromInt(@max(fast_ns, 1))),
        @as(f64, @floatFromInt(digest_ns)) / @as(f64, @floatFromInt(n_lines)),
        if (mismatch == 0) "OK (identical on all lines)" else "MISMATCH",
        sink,
        live,
    });
}
