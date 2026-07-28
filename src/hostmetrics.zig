//! Node-level host metrics: /proc + statfs readers producing a HostSample.
//! Mirrors sampler.zig's discipline: raw std.os.linux syscalls (openat/read/
//! close via posix.errno), line-oriented std.mem scanning, and SATURATING
//! arithmetic on every byte parsed out of /proc (untrusted input). The text
//! parsers take []const u8 so they are deterministically unit-testable with
//! fixture strings; the file-reading Sampler.sample() does openat+read then
//! hands the bytes to them. sample() NEVER fails — unreadable files yield
//! zeros. Zero heap allocation: fixed stack buffers + one prior-reading struct.

const std = @import("std");
const builtin = @import("builtin");

pub const HostSample = struct {
    // memory (bytes)
    mem_total: u64 = 0,
    mem_used: u64 = 0,
    // cpu — caller derives utilization = 1 - idle_delta/total_delta
    cpu_total_delta: u64 = 0,
    cpu_idle_delta: u64 = 0,
    logical_cpus: u32 = 0,
    load1_milli: u32 = 0, // /proc/loadavg field1 * 1000 (integer, no float on wire)
    // network (cumulative monotonic bytes across non-loopback ifaces)
    net_rx: u64 = 0,
    net_tx: u64 = 0,
    // filesystem "/" (bytes)
    fs_total: u64 = 0,
    fs_used: u64 = 0,
};

// ------------------------------------------------------ pure parsers

pub const Mem = struct { total: u64 = 0, used: u64 = 0 };

/// /proc/meminfo: MemTotal (limit) and MemAvailable (both in kB). used =
/// (MemTotal - MemAvailable) * 1024. Every multiply/subtract saturates, so a
/// garbage or absurdly long number yields 0 (parseInt overflow -> 0), never a
/// trap. O(input): one pass over the lines.
pub fn parseMeminfo(text: []const u8) Mem {
    var total_kb: u64 = 0;
    var avail_kb: u64 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal:")) {
            total_kb = firstUint(line["MemTotal:".len..]);
        } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            avail_kb = firstUint(line["MemAvailable:".len..]);
        }
    }
    return .{
        .total = total_kb *| 1024,
        .used = (total_kb -| avail_kb) *| 1024,
    };
}

pub const Cpu = struct { total: u64 = 0, idle: u64 = 0, logical: u32 = 0 };

/// /proc/stat: the aggregate `cpu ` line -> total = sum of all fields, idle =
/// field4 + field5 (idle + iowait). logical = count of per-core `cpuN` lines
/// (a "cpu" prefix followed by a digit). All sums saturate; garbage tokens
/// parse to 0. O(input): single pass.
pub fn parseStatCpu(text: []const u8) Cpu {
    var res: Cpu = .{};
    var got_agg = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "cpu")) continue;
        if (line.len > 3 and line[3] >= '0' and line[3] <= '9') {
            // per-core line "cpuN" — count it, not the aggregate
            res.logical +|= 1;
            continue;
        }
        if (!got_agg and line.len > 3 and (line[3] == ' ' or line[3] == '\t')) {
            got_agg = true;
            var it = std.mem.tokenizeAny(u8, line[3..], " \t\r");
            var i: usize = 1;
            while (it.next()) |tok| : (i += 1) {
                const v = std.fmt.parseInt(u64, tok, 10) catch 0;
                res.total +|= v;
                if (i == 4 or i == 5) res.idle +|= v; // idle + iowait
            }
        }
    }
    return res;
}

/// /proc/loadavg field 1 ("1.25") -> milli (1250), integer only — NO float on
/// the wire. Manual digit scan so the whole part saturates a u32 and at most 3
/// fractional digits are taken (padded to 3). O(input).
pub fn parseLoadavg(text: []const u8) u32 {
    var i: usize = 0;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) : (i += 1) {}
    var whole: u32 = 0;
    while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {
        whole = whole *| 10 +| (text[i] - '0');
    }
    var frac: u32 = 0;
    var fdigits: u32 = 0;
    if (i < text.len and text[i] == '.') {
        i += 1;
        while (i < text.len and text[i] >= '0' and text[i] <= '9' and fdigits < 3) : (i += 1) {
            frac = frac * 10 + (text[i] - '0'); // bounded: <=3 digits -> <1000
            fdigits += 1;
        }
    }
    while (fdigits < 3) : (fdigits += 1) frac *= 10; // "25" -> 250
    return whole *| 1000 +| frac;
}

pub const Net = struct { rx: u64 = 0, tx: u64 = 0 };

/// /proc/net/dev: sum rx-bytes (col 1) and tx-bytes (col 9) across every
/// NON-loopback interface (skip `lo`). Header lines have no ':' and are
/// skipped. Sums saturate; garbage tokens parse to 0. O(input).
pub fn parseNetDev(text: []const u8) Net {
    var res: Net = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        if (std.mem.eql(u8, name, "lo")) continue; // loopback excluded
        var it = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t\r");
        var i: usize = 1;
        while (it.next()) |tok| : (i += 1) {
            if (i == 1) {
                res.rx +|= std.fmt.parseInt(u64, tok, 10) catch 0;
            } else if (i == 9) {
                res.tx +|= std.fmt.parseInt(u64, tok, 10) catch 0;
                break; // nothing past tx-bytes matters
            }
        }
    }
    return res;
}

/// First unsigned integer in a slice (e.g. "   65808388 kB"). parseInt
/// overflow (a too-long digit run) -> 0. Saturating by construction.
fn firstUint(s: []const u8) u64 {
    var it = std.mem.tokenizeAny(u8, s, " \t\r");
    const tok = it.next() orelse return 0;
    return std.fmt.parseInt(u64, tok, 10) catch 0;
}

// ------------------------------------------------------- Linux readers

const linux = std.os.linux;
const posix = std.posix;

/// Kernel `struct statfs` (asm-generic, 64-bit words) — Zig 0.16 std ships no
/// `linux.Statfs`/`linux.statfs` wrapper, so we declare the layout and invoke
/// the raw syscall. 120 bytes on x86_64 and aarch64 (both target arches use
/// the 64-bit `__statfs_word` layout; `statfs` syscall = 99 / 43).
const Statfs = extern struct {
    f_type: i64,
    f_bsize: i64,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_fsid: [2]i32,
    f_namelen: i64,
    f_frsize: i64,
    f_flags: i64,
    f_spare: [4]i64,
};

/// Read a whole small /proc/sys or /proc file into `buf`. Mirrors
/// sampler.zig:122-130 (openat AT.FDCWD -> read -> close via posix.errno).
/// Returns null on any syscall error — callers substitute "".
fn readFile(path: [*:0]const u8, buf: []u8) ?[]const u8 {
    const rc = linux.openat(linux.AT.FDCWD, path, .{}, 0);
    if (posix.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const n = linux.read(fd, buf.ptr, buf.len);
    if (posix.errno(n) != .SUCCESS) return null;
    return buf[0..n];
}

/// statfs("/") -> (total, used) bytes. Raw syscall via linux.syscall2 (same
/// idiom as spawner.zig:445's linux.syscall3(.setpriority, ...)). On any error
/// or garbage, returns zeros. total = f_blocks*f_bsize; used =
/// (f_blocks-f_bfree)*f_bsize — both saturating.
fn readRootFs() struct { total: u64, used: u64 } {
    var sf: Statfs = undefined;
    const path: [*:0]const u8 = "/";
    const rc: usize = @intCast(linux.syscall2(.statfs, @intFromPtr(path), @intFromPtr(&sf)));
    if (posix.errno(rc) != .SUCCESS) return .{ .total = 0, .used = 0 };
    const bsize: u64 = if (sf.f_bsize > 0) @intCast(sf.f_bsize) else 0;
    return .{
        .total = sf.f_blocks *| bsize,
        .used = (sf.f_blocks -| sf.f_bfree) *| bsize,
    };
}

/// Read a file into `buf` and return it trimmed of trailing newline/space/nul.
/// Returns "" when unreadable or empty.
fn readTrimmed(path: [*:0]const u8, buf: []u8) []const u8 {
    const text = readFile(path, buf) orelse return "";
    return std.mem.trim(u8, text, " \t\r\n\x00");
}

/// host.name from /proc/sys/kernel/hostname (trimmed). Falls back to the
/// stable literal "unknown" so the OTLP resource attribute is never empty.
pub fn hostName(buf: []u8) []const u8 {
    const name = readTrimmed("/proc/sys/kernel/hostname", buf);
    if (name.len == 0) return "unknown";
    return name;
}

/// host.id from /etc/machine-id, falling back to
/// /proc/sys/kernel/random/boot_id, then the literal "unknown".
pub fn hostId(buf: []u8) []const u8 {
    const id = readTrimmed("/etc/machine-id", buf);
    if (id.len != 0) return id;
    const boot = readTrimmed("/proc/sys/kernel/random/boot_id", buf);
    if (boot.len != 0) return boot;
    return "unknown";
}

/// Keeps one prior CPU reading so utilization can be derived from a delta.
/// Fixed struct, zero allocation.
pub const Sampler = struct {
    prev_cpu_total: u64 = 0,
    prev_cpu_idle: u64 = 0,
    have_prev: bool = false,

    /// Reads /proc + statfs and returns a HostSample. NEVER fails: any
    /// unreadable or garbage file yields zeros for its fields. All buffers are
    /// fixed stack allocations; no heap. First tick emits zero CPU deltas
    /// (no prior reading yet), same as the per-worker cpu%.
    pub fn sample(self: *Sampler) HostSample {
        var out: HostSample = .{};

        // /proc/stat can be large on many-core hosts (one cpuN line per core);
        // 32 KiB covers a few hundred cores. Truncation is safe (we parse what
        // we read), never a trap.
        var stat_buf: [32768]u8 = undefined;
        const stat_text = readFile("/proc/stat", &stat_buf) orelse "";
        const cpu = parseStatCpu(stat_text);
        out.logical_cpus = cpu.logical;
        if (self.have_prev) {
            out.cpu_total_delta = cpu.total -| self.prev_cpu_total;
            out.cpu_idle_delta = cpu.idle -| self.prev_cpu_idle;
        }
        self.prev_cpu_total = cpu.total;
        self.prev_cpu_idle = cpu.idle;
        self.have_prev = true;

        var mem_buf: [4096]u8 = undefined;
        const mem = parseMeminfo(readFile("/proc/meminfo", &mem_buf) orelse "");
        out.mem_total = mem.total;
        out.mem_used = mem.used;

        var load_buf: [128]u8 = undefined;
        out.load1_milli = parseLoadavg(readFile("/proc/loadavg", &load_buf) orelse "");

        var net_buf: [8192]u8 = undefined;
        const net = parseNetDev(readFile("/proc/net/dev", &net_buf) orelse "");
        out.net_rx = net.rx;
        out.net_tx = net.tx;

        const fs = readRootFs();
        out.fs_total = fs.total;
        out.fs_used = fs.used;

        return out;
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "parseMeminfo pulls MemTotal and MemAvailable" {
    const s = "MemTotal:       65808388 kB\nMemFree: 100 kB\nMemAvailable:   40000000 kB\n";
    const m = parseMeminfo(s);
    try testing.expectEqual(@as(u64, 65808388 * 1024), m.total);
    try testing.expectEqual(@as(u64, (65808388 - 40000000) * 1024), m.used);
}

test "parseStatCpu sums fields and extracts idle" {
    const c = parseStatCpu("cpu  100 20 30 400 50 0 0 0 0 0\ncpu0 1 2 3 4\n");
    try testing.expectEqual(@as(u64, 100 + 20 + 30 + 400 + 50), c.total);
    try testing.expectEqual(@as(u64, 400 + 50), c.idle); // idle + iowait
    try testing.expectEqual(@as(u32, 1), c.logical);
}

test "parseNetDev sums non-loopback rx/tx" {
    const n = parseNetDev("Inter-|...\n face |...\n  lo: 5 0 0 0 0 0 0 0 5 0 0 0 0 0 0 0\n eth0: 1000 0 0 0 0 0 0 0 2000 0 0 0 0 0 0 0\n");
    try testing.expectEqual(@as(u64, 1000), n.rx); // lo excluded
    try testing.expectEqual(@as(u64, 2000), n.tx);
}

test "parseLoadavg reads the 1m field as milli" {
    try testing.expectEqual(@as(u32, 1250), parseLoadavg("1.25 0.80 0.66 1/234 5678"));
    try testing.expectEqual(@as(u32, 0), parseLoadavg("0.00 0.80 0.66"));
    try testing.expectEqual(@as(u32, 12000), parseLoadavg("12 0.0 0.0")); // no fraction
}

test "overflow-safe: a giant /proc number saturates, no trap" {
    const m = parseMeminfo("MemTotal: 99999999999999999999999 kB\nMemAvailable: 88888888888888888888888 kB\n");
    // parseInt overflow -> 0, so no multiply can trap.
    try testing.expectEqual(@as(u64, 0), m.total);
    try testing.expectEqual(@as(u64, 0), m.used);
    // A giant load average must also saturate its u32, not trap.
    _ = parseLoadavg("99999999999999999999.99999999999999 0 0");
    // A giant net counter saturates u64 across many interfaces, not trap.
    _ = parseNetDev(" eth0: 99999999999999999999 0 0 0 0 0 0 0 99999999999999999999 0\n");
    // A giant cpu field saturates the running total, not trap.
    _ = parseStatCpu("cpu 99999999999999999999999 99999999999999999999999\n");
}

test "sample reads live host values (validates statfs layout + /proc)" {
    // The pure parsers are covered above; this exercises the file-reading path
    // and the hand-rolled `struct statfs` on real /proc + a real filesystem.
    // The asserts are ">0", true on any live Linux/WSL host, so it is stable —
    // but a wrong statfs offset would make fs_total 0/garbage and fail here,
    // which is the whole point (a compile cannot catch a bad struct layout).
    if (builtin.os.tag != .linux) return; // /proc + statfs are Linux-only
    var s = Sampler{};
    _ = s.sample(); // prime the prior CPU reading
    const h = s.sample();
    try testing.expect(h.mem_total > 0); // /proc/meminfo MemTotal parsed
    try testing.expect(h.fs_total > 0); // statfs("/") struct offsets correct
    try testing.expect(h.fs_used <= h.fs_total);
    try testing.expect(h.logical_cpus > 0); // /proc/stat cpuN lines counted
}
