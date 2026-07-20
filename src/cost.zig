//! Per-worker resource-cost profiling — "what does each worker cost to run".
//! Zero worker cooperation: everything is inferred from the /proc samples
//! mandor already collects. Fixed-size histograms (no allocation) give
//! approximate idle/typical/peak percentiles over long horizons; the profile
//! persists to the state dir so it accumulates across worker restarts.
//!
//! State classifier (the idle-vs-active problem): a sample whose CPU is below
//! `idle_threshold_pct` is "idle", else "active". No app knowledge needed.

const std = @import("std");
const jb = @import("jsonbuf.zig");
const report = @import("report.zig");

pub const buckets = 32;
pub const idle_threshold_pct: u16 = 5;

/// One worker's accumulated cost profile. ~400 bytes; lives in a parallel
/// array (NOT the Worker struct, which resets on restart — cost is lifetime).
pub const Profile = struct {
    rss_idle: [buckets]u32 = .{0} ** buckets, // RSS histogram, idle samples
    rss_active: [buckets]u32 = .{0} ** buckets, // RSS histogram, active samples
    cpu_active: [buckets]u32 = .{0} ** buckets, // CPU histogram, active samples
    peak_rss_kb: u64 = 0,
    peak_cpu_pct: u16 = 0,
    peak_fds: u16 = 0,
    peak_threads: u16 = 0,
    idle_n: u32 = 0,
    active_n: u32 = 0,
    core_ms: u64 = 0, // cpu-core-milliseconds (integral of cpu% × dt)
    rss_kb_ms: u64 = 0, // kilobyte-milliseconds (→ GB-hours)
    first_ms: u64 = 0, // wall epoch ms of first sample
    last_ms: u64 = 0,

    /// RSS bucket: log2(MB), clamped. Bucket i ≈ [2^i, 2^(i+1)) MB.
    fn rssBucket(rss_kb: u64) usize {
        const mb = rss_kb / 1024;
        if (mb == 0) return 0;
        const i = 63 - @clz(mb);
        return @min(i, buckets - 1);
    }
    /// CPU bucket: 10-percent bands (0..319%+), clamped.
    fn cpuBucket(cpu_pct: u16) usize {
        return @min(cpu_pct / 10, buckets - 1);
    }
    /// Bucket → representative MB (geometric midpoint 1.5×2^i).
    fn rssRepMb(i: usize) u64 {
        return (@as(u64, 3) << @intCast(i)) / 2;
    }

    pub fn update(p: *Profile, rss_kb: u64, cpu_pct: u16, fds: u16, threads: u16, dt_ms: u64, wall_ms: u64) void {
        if (p.first_ms == 0) p.first_ms = wall_ms;
        p.last_ms = wall_ms;
        p.peak_rss_kb = @max(p.peak_rss_kb, rss_kb);
        p.peak_cpu_pct = @max(p.peak_cpu_pct, cpu_pct);
        p.peak_fds = @max(p.peak_fds, fds);
        p.peak_threads = @max(p.peak_threads, threads);
        // Saturating throughout. These accumulate for the life of the
        // container and are reloaded from cost.json across restarts, so a
        // corrupt file can seed a counter at its maximum — the next sample
        // would then trap on the increment, on the sampler tick path.
        p.core_ms +|= @as(u64, cpu_pct) *| dt_ms / 100;
        p.rss_kb_ms +|= rss_kb *| dt_ms;
        const rb = rssBucket(rss_kb);
        if (cpu_pct < idle_threshold_pct) {
            p.idle_n +|= 1;
            p.rss_idle[rb] +|= 1;
        } else {
            p.active_n +|= 1;
            p.rss_active[rb] +|= 1;
            p.cpu_active[cpuBucket(cpu_pct)] +|= 1;
        }
    }

    /// Percentile RSS (MB) over a histogram; 0 if empty.
    fn rssPercentile(hist: *const [buckets]u32, total: u32, frac_num: u32, frac_den: u32) u64 {
        if (total == 0) return 0;
        const target = (@as(u64, total) * frac_num) / frac_den;
        var acc: u64 = 0;
        for (hist, 0..) |c, i| {
            acc += c;
            if (acc >= target) return rssRepMb(i);
        }
        return rssRepMb(buckets - 1);
    }

    fn cpuPercentile(p: *const Profile, frac_num: u32, frac_den: u32) u16 {
        if (p.active_n == 0) return 0;
        const target = (@as(u64, p.active_n) * frac_num) / frac_den;
        var acc: u64 = 0;
        for (p.cpu_active, 0..) |c, i| {
            acc += c;
            if (acc >= target) return @intCast(i * 10 + 5);
        }
        return @intCast((buckets - 1) * 10);
    }

    pub const Summary = struct {
        idle_rss_mb: u64,
        typical_rss_mb: u64,
        peak_rss_mb: u64,
        typical_cpu_pct: u16,
        peak_cpu_pct: u16,
        peak_fds: u16,
        peak_threads: u16,
        duty_pct: u8, // % of samples that were active
        gb_hours: u64, // mean RSS × uptime, ×100 (two decimals)
        core_seconds: u64,
        obs_seconds: u64,
        // sizing suggestion
        sug_mem_mb: u64, // peak × 1.15
        sug_cpu_req: u16, // typical (p50) cpu%
        sug_cpu_lim: u16, // p95 cpu%
    };

    pub fn summary(p: *const Profile) Summary {
        // Widened: two u32 sample counters sum into a u32 otherwise, and both
        // can arrive at their maximum from a corrupt cost.json.
        const total = @as(u64, p.idle_n) + p.active_n;
        const obs_s = (p.last_ms -| p.first_ms) / 1000;
        const peak_mb = p.peak_rss_kb / 1024;
        // GB-hours ×100: rss_kb_ms / (1024*1024 KB/GB) / (3_600_000 ms/h) ×100
        const gbh = p.rss_kb_ms / 1024 / 1024 * 100 / 3_600_000;
        return .{
            .idle_rss_mb = rssPercentile(&p.rss_idle, p.idle_n, 1, 2),
            .typical_rss_mb = rssPercentile(&p.rss_active, p.active_n, 1, 2),
            .peak_rss_mb = peak_mb,
            .typical_cpu_pct = p.cpuPercentile(1, 2),
            .peak_cpu_pct = p.peak_cpu_pct,
            .peak_fds = p.peak_fds,
            .peak_threads = p.peak_threads,
            .duty_pct = if (total == 0) 0 else @intCast(@as(u64, p.active_n) * 100 / total),
            .gb_hours = gbh,
            .core_seconds = p.core_ms / 1000,
            .obs_seconds = obs_s,
            .sug_mem_mb = peak_mb * 115 / 100,
            .sug_cpu_req = p.cpuPercentile(1, 2),
            .sug_cpu_lim = p.cpuPercentile(95, 100),
        };
    }
};

// ------------------------------------------------------- rendering

/// Human cost report from a cost.json text (loaded by `mandor report --cost`).
/// Renders a per-worker table + a one-line right-sizing suggestion each.
pub fn formatHuman(out: []u8, text: []const u8) []const u8 {
    var pos: usize = 0;
    const p = &pos;
    _ = jb.appendf(out, p, "worker resource cost (observed)\n\n", .{});
    _ = jb.appendf(out, p, "{s:<14} {s:>10} {s:>10} {s:>10} {s:>8} {s:>6} {s:>9} {s:>9}\n", .{
        "NAME", "IDLE-RSS", "TYP-RSS", "PEAK-RSS", "TYP-CPU", "DUTY", "GB-HOURS", "CORE-SEC",
    });
    var it: usize = 0;
    const pat = "{\"name\":\"";
    while (std.mem.indexOfPos(u8, text, it, pat)) |start| : (it = start + pat.len) {
        const ns = start + pat.len;
        const ne = std.mem.indexOfScalarPos(u8, text, ns, '"') orelse break;
        const nm = text[ns..ne];
        const end = std.mem.indexOfPos(u8, text, ne, pat) orelse text.len;
        var prof: Profile = .{};
        loadInto(&prof, text[start..end]);
        const s = prof.summary();
        var gbh: [16]u8 = undefined;
        const gbh_txt = std.fmt.bufPrint(&gbh, "{d}.{d:0>2}", .{ s.gb_hours / 100, s.gb_hours % 100 }) catch "?";
        _ = jb.appendf(out, p, "{s:<14} {d:>8}MB {d:>8}MB {d:>8}MB {d:>7}% {d:>5}% {s:>9} {d:>9}\n", .{
            nm, s.idle_rss_mb, s.typical_rss_mb, s.peak_rss_mb, s.typical_cpu_pct, s.duty_pct, gbh_txt, s.core_seconds,
        });
    }
    // suggestions block
    _ = jb.appendf(out, p, "\nright-sizing suggestions:\n", .{});
    it = 0;
    while (std.mem.indexOfPos(u8, text, it, pat)) |start| : (it = start + pat.len) {
        const ns = start + pat.len;
        const ne = std.mem.indexOfScalarPos(u8, text, ns, '"') orelse break;
        const nm = text[ns..ne];
        const end = std.mem.indexOfPos(u8, text, ne, pat) orelse text.len;
        var prof: Profile = .{};
        loadInto(&prof, text[start..end]);
        const s = prof.summary();
        _ = jb.appendf(out, p, "  {s}: memory {d}MB (peak {d}MB ×1.15), cpu request {d}% / limit {d}%, {d}% duty over {d}s\n", .{
            nm, s.sug_mem_mb, s.peak_rss_mb, s.sug_cpu_req, s.sug_cpu_lim, s.duty_pct, s.obs_seconds,
        });
    }
    return out[0..pos];
}

// ------------------------------------------------------- persistence
//
// Profiles live in a parallel array indexed like the worker table, and are
// keyed by worker name in cost.json so they survive supervisor restarts.

const linux = std.os.linux;
const posix = std.posix;
const cli = @import("cli.zig");

var profiles: [cli.max_workers]Profile = undefined;
var names: [cli.max_workers][]const u8 = undefined;
var n_profiles: usize = 0;
var io_buf: [64 * 1024]u8 = undefined;

pub fn get(idx: usize) *Profile {
    return &profiles[idx];
}

/// Initialize one profile slot per worker, restoring persisted counters when
/// a matching name is found in cost.json.
pub fn init(state_dir: []const u8, worker_names: []const []const u8) void {
    n_profiles = worker_names.len;
    for (worker_names, 0..) |nm, i| {
        profiles[i] = .{};
        names[i] = nm;
    }
    const text = readState(state_dir) orelse return;
    // Each object: {"name":"…", <u64 fields>, "rss_idle":[…],…}
    var it: usize = 0;
    const pat = "{\"name\":\"";
    while (std.mem.indexOfPos(u8, text, it, pat)) |start| : (it = start + pat.len) {
        const ns = start + pat.len;
        const ne = std.mem.indexOfScalarPos(u8, text, ns, '"') orelse break;
        const nm = text[ns..ne];
        const end = std.mem.indexOfPos(u8, text, ne, pat) orelse text.len;
        const chunk = text[start..end];
        for (worker_names, 0..) |wn, i| {
            if (std.mem.eql(u8, wn, nm)) {
                loadInto(&profiles[i], chunk);
                break;
            }
        }
    }
}

fn scanU64(chunk: []const u8, comptime key: []const u8) u64 {
    return report.scanU64(chunk, key) orelse 0;
}

fn loadArray(chunk: []const u8, comptime key: []const u8, out: *[buckets]u32) void {
    const pat = "\"" ++ key ++ "\":[";
    const at = std.mem.indexOf(u8, chunk, pat) orelse return;
    var j = at + pat.len;
    var i: usize = 0;
    while (i < buckets and j < chunk.len and chunk[j] != ']') : (i += 1) {
        var v: u32 = 0;
        while (j < chunk.len and chunk[j] >= '0' and chunk[j] <= '9') : (j += 1)
            v = v *| 10 +| (chunk[j] - '0');
        out[i] = v;
        if (j < chunk.len and chunk[j] == ',') j += 1;
    }
}

fn loadInto(p: *Profile, chunk: []const u8) void {
    p.peak_rss_kb = scanU64(chunk, "peak_rss_kb");
    p.peak_cpu_pct = report.clamp(u16, scanU64(chunk, "peak_cpu_pct"));
    p.peak_fds = report.clamp(u16, scanU64(chunk, "peak_fds"));
    p.peak_threads = report.clamp(u16, scanU64(chunk, "peak_threads"));
    p.idle_n = report.clamp(u32, scanU64(chunk, "idle_n"));
    p.active_n = report.clamp(u32, scanU64(chunk, "active_n"));
    p.core_ms = scanU64(chunk, "core_ms");
    p.rss_kb_ms = scanU64(chunk, "rss_kb_ms");
    p.first_ms = scanU64(chunk, "first_ms");
    p.last_ms = scanU64(chunk, "last_ms");
    loadArray(chunk, "rss_idle", &p.rss_idle);
    loadArray(chunk, "rss_active", &p.rss_active);
    loadArray(chunk, "cpu_active", &p.cpu_active);
}

fn appendArray(pos: *usize, comptime key: []const u8, hist: *const [buckets]u32) bool {
    if (!jb.appendf(&io_buf, pos, ",\"" ++ key ++ "\":[", .{})) return false;
    for (hist, 0..) |c, i| {
        if (i > 0 and !jb.appendf(&io_buf, pos, ",", .{})) return false;
        if (!jb.appendf(&io_buf, pos, "{d}", .{c})) return false;
    }
    return jb.appendf(&io_buf, pos, "]", .{});
}

pub fn serialize() ?[]const u8 {
    var pos: usize = 0;
    if (!jb.appendf(&io_buf, &pos, "{{\"v\":1,\"workers\":[", .{})) return null;
    for (0..n_profiles) |i| {
        const p = &profiles[i];
        if (i > 0 and !jb.appendf(&io_buf, &pos, ",", .{})) return null;
        if (!jb.appendf(&io_buf, &pos, "{{\"name\":", .{})) return null;
        if (!jb.appendJsonString(&io_buf, &pos, names[i])) return null;
        if (!jb.appendf(&io_buf, &pos, ",\"peak_rss_kb\":{d},\"peak_cpu_pct\":{d},\"peak_fds\":{d},\"peak_threads\":{d},\"idle_n\":{d},\"active_n\":{d},\"core_ms\":{d},\"rss_kb_ms\":{d},\"first_ms\":{d},\"last_ms\":{d}", .{
            p.peak_rss_kb, p.peak_cpu_pct, p.peak_fds, p.peak_threads,
            p.idle_n,      p.active_n,     p.core_ms,  p.rss_kb_ms,
            p.first_ms,    p.last_ms,
        })) return null;
        if (!appendArray(&pos, "rss_idle", &p.rss_idle)) return null;
        if (!appendArray(&pos, "rss_active", &p.rss_active)) return null;
        if (!appendArray(&pos, "cpu_active", &p.cpu_active)) return null;
        if (!jb.appendf(&io_buf, &pos, "}}", .{})) return null;
    }
    if (!jb.appendf(&io_buf, &pos, "]}}", .{})) return null;
    return io_buf[0..pos];
}

pub fn readState(state_dir: []const u8) ?[]const u8 {
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/cost.json", .{state_dir}) catch return null;
    const rc = linux.openat(linux.AT.FDCWD, path.ptr, .{}, 0);
    if (posix.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const got = linux.read(fd, &io_buf, io_buf.len);
    if (posix.errno(got) != .SUCCESS) return null;
    return io_buf[0..got];
}

pub fn save(state_dir: []const u8) void {
    // serialize() fills io_buf; nothing else touches it before the write, so
    // write directly — no second buffer.
    const json = serialize() orelse return;
    var path_buf: [512]u8 = undefined;
    var tmp_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/cost.json", .{state_dir}) catch return;
    const tmp = std.fmt.bufPrintZ(&tmp_buf, "{s}/.cost.tmp", .{state_dir}) catch return;
    const rc = linux.openat(linux.AT.FDCWD, tmp.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (posix.errno(rc) != .SUCCESS) return;
    const fd: i32 = @intCast(rc);
    var off: usize = 0;
    while (off < json.len) {
        const w = linux.write(fd, json.ptr + off, json.len - off);
        if (posix.errno(w) != .SUCCESS) break;
        off += w;
    }
    _ = linux.close(fd);
    if (off == json.len) _ = linux.rename(tmp.ptr, path.ptr);
}

// ---------------------------------------------------------------- tests

test "state classifier splits idle vs active by cpu" {
    var p: Profile = .{};
    // 3 idle samples at 100MB, 0% cpu
    for (0..3) |_| p.update(100 * 1024, 0, 5, 2, 5000, 1000);
    // 5 active samples at 800MB, 90% cpu
    for (0..5) |_| p.update(800 * 1024, 90, 12, 8, 5000, 1000);
    const s = p.summary();
    try std.testing.expectEqual(@as(u32, 3), p.idle_n);
    try std.testing.expectEqual(@as(u32, 5), p.active_n);
    // idle rss bucket for 100MB: log2(100)=6 → rep 1.5*64=96MB
    try std.testing.expectEqual(@as(u64, 96), s.idle_rss_mb);
    // active rss bucket for 800MB: log2(800)=9 → rep 1.5*512=768MB
    try std.testing.expectEqual(@as(u64, 768), s.typical_rss_mb);
    try std.testing.expectEqual(@as(u16, 90), s.peak_cpu_pct);
    try std.testing.expectEqual(@as(u8, 62), s.duty_pct); // 5/8
    try std.testing.expect(s.core_seconds > 0);
}

test "empty profile summarizes to zeros" {
    var p: Profile = .{};
    const s = p.summary();
    try std.testing.expectEqual(@as(u64, 0), s.peak_rss_mb);
    try std.testing.expectEqual(@as(u8, 0), s.duty_pct);
}

test "maxed-out counters from a corrupt reload summarize without trapping" {
    var p: Profile = .{};
    p.idle_n = std.math.maxInt(u32);
    p.active_n = std.math.maxInt(u32);
    p.core_ms = std.math.maxInt(u64);
    p.rss_kb_ms = std.math.maxInt(u64);
    p.peak_rss_kb = std.math.maxInt(u64);
    // The next sampler tick increments those saturated counters, then the
    // report sums them — both used to overflow.
    p.update(std.math.maxInt(u64), 60_000, 1024, 64, 5_000, 1_000_000);
    const s = p.summary();
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), p.idle_n + 0);
    try std.testing.expect(s.duty_pct <= 100);
}

test "serialize then re-init round-trips accumulators" {
    n_profiles = 1;
    profiles[0] = .{};
    names[0] = "api";
    for (0..4) |_| profiles[0].update(500 * 1024, 40, 9, 6, 5000, 2000);
    const before = profiles[0];
    const json = serialize().?;
    // simulate a fresh boot loading the same worker name
    var fresh: Profile = .{};
    loadInto(&fresh, json);
    try std.testing.expectEqual(before.active_n, fresh.active_n);
    try std.testing.expectEqual(before.peak_rss_kb, fresh.peak_rss_kb);
    try std.testing.expectEqual(before.core_ms, fresh.core_ms);
    try std.testing.expectEqual(before.rss_kb_ms, fresh.rss_kb_ms);
    try std.testing.expectEqualSlices(u32, &before.rss_active, &fresh.rss_active);
    n_profiles = 0;
}
