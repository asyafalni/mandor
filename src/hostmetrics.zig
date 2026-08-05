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

/// Upper bound on per-core CPU tracking. Matches the 32 KiB /proc/stat read in
/// sample() (a few hundred cores' worth of `cpuN` lines). Per-core state lives
/// in fixed arrays of this length; a `cpuN` with N >= max_cores is truncated
/// (counted toward `logical` but never captured), never an overrun.
pub const max_cores = 256;

/// Upper bound on per-mount filesystem tracking. /proc/self/mountinfo can list
/// hundreds of entries (bind mounts, cgroup subtrees), but the real
/// filesystems worth a usage/utilization gauge are few. parseMountinfo caps its
/// output at this length (excess mounts truncated, never an overrun) and
/// HostSample carries a fixed array of this size.
pub const max_mounts = 32;

/// One real (non-pseudo) filesystem mount with its measured bytes. Daemon-local
/// (never on the wire), so a fixed-size stored path is fine. `path`/`path_len`
/// hold the mountpoint; a mountpoint that will not fit is skipped upstream, so
/// path_len is always <= path.len. total/used come from statfs (saturating).
pub const Mount = struct {
    path: [128]u8 = [_]u8{0} ** 128,
    path_len: u8 = 0,
    total: u64 = 0,
    used: u64 = 0,
};

pub const HostSample = struct {
    // memory (bytes)
    mem_total: u64 = 0,
    mem_used: u64 = 0,
    // cpu — caller derives utilization = 1 - idle_delta/total_delta
    cpu_total_delta: u64 = 0,
    cpu_idle_delta: u64 = 0,
    logical_cpus: u32 = 0,
    // per-core cpu — same derivation as the aggregate, one entry per core.
    // Only the first `core_n` (= min(logical, max_cores)) entries are valid.
    core_total_delta: [max_cores]u64 = [_]u64{0} ** max_cores,
    core_idle_delta: [max_cores]u64 = [_]u64{0} ** max_cores,
    core_n: u32 = 0,
    load1_milli: u32 = 0, // /proc/loadavg field1 * 1000 (integer, no float on wire)
    // network (cumulative monotonic bytes across non-loopback ifaces)
    net_rx: u64 = 0,
    net_tx: u64 = 0,
    // filesystem — one entry per real (non-pseudo) mount, bytes. Only the first
    // `mount_n` (<= max_mounts) entries of `mounts` are valid. Daemon-local, so
    // the fixed-size stored paths never touch the wire.
    mounts: [max_mounts]Mount = [_]Mount{.{}} ** max_mounts,
    mount_n: u32 = 0,
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

pub const Cpu = struct {
    total: u64 = 0,
    idle: u64 = 0,
    logical: u32 = 0,
    // per-core, indexed by the parsed N (< max_cores). Same math as the
    // aggregate: total = sum of a `cpuN` line's fields, idle = field4 + field5.
    core_total: [max_cores]u64 = [_]u64{0} ** max_cores,
    core_idle: [max_cores]u64 = [_]u64{0} ** max_cores,
};

/// /proc/stat: the aggregate `cpu ` line -> total = sum of all fields, idle =
/// field4 + field5 (idle + iowait). logical = count of per-core `cpuN` lines
/// (a "cpu" prefix followed by a digit); each such line's total/idle is also
/// captured into core_total[N]/core_idle[N] when N < max_cores (larger N is
/// truncated — counted but not captured, never an overrun). All sums saturate;
/// garbage tokens parse to 0. O(input): single pass.
pub fn parseStatCpu(text: []const u8) Cpu {
    var res: Cpu = .{};
    var got_agg = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "cpu")) continue;
        if (line.len > 3 and line[3] >= '0' and line[3] <= '9') {
            // per-core line "cpuN" — count it, not the aggregate
            res.logical +|= 1;
            // parse the core index N from the digit run after "cpu"
            var j: usize = 3;
            var n: u32 = 0;
            while (j < line.len and line[j] >= '0' and line[j] <= '9') : (j += 1) {
                n = n *| 10 +| (line[j] - '0'); // saturating: huge N stays huge
            }
            if (n >= max_cores) continue; // truncate — never index past the arrays
            // capture this core's total (sum of fields) + idle (field4+field5)
            var cit = std.mem.tokenizeAny(u8, line[j..], " \t\r");
            var ci: usize = 1;
            var ctotal: u64 = 0;
            var cidle: u64 = 0;
            while (cit.next()) |tok| : (ci += 1) {
                const v = std.fmt.parseInt(u64, tok, 10) catch 0;
                ctotal +|= v;
                if (ci == 4 or ci == 5) cidle +|= v; // idle + iowait
            }
            res.core_total[n] = ctotal;
            res.core_idle[n] = cidle;
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

pub const MountRef = struct { mountpoint: []const u8, fstype: []const u8 };

/// Pseudo/virtual filesystem types whose "usage" is meaningless — never
/// statfs'd, never emitted. Scanned per mount by isPseudoFs.
///
/// MUTATION SENTINEL: removing an entry here (or bypassing isPseudoFs in
/// parseMountinfo) lets a pseudo mount slip into the output — the
/// "parseMountinfo skips pseudo-fs" test then fails because a real mount is no
/// longer the first/only survivor.
const pseudo_fstypes = [_][]const u8{
    "proc",       "sysfs",  "cgroup", "cgroup2",     "devtmpfs",
    "devpts",     "tmpfs",  "mqueue", "debugfs",     "tracefs",
    "securityfs", "pstore", "bpf",    "configfs",    "fusectl",
    "hugetlbfs",  "ramfs",  "autofs", "binfmt_misc", "efivarfs",
    "nsfs",
};

fn isPseudoFs(fstype: []const u8) bool {
    for (pseudo_fstypes) |p| {
        if (std.mem.eql(u8, p, fstype)) return true;
    }
    return false;
}

/// Parse /proc/self/mountinfo into real-filesystem (mountpoint, fstype) refs.
/// Line layout: space-separated fields where the MOUNT POINT is field index 4
/// (0-based) and the FSTYPE is the first field AFTER the standalone " - "
/// separator. Only real filesystems survive: pseudo/virtual fstypes are
/// dropped, a mountpoint already seen is skipped (dedup, first wins), and the
/// output is bounded to max_mounts (excess lines truncated — never an overrun).
/// A malformed line (no " - " separator, or fewer than 5 pre-separator fields)
/// is skipped. Pure: every returned slice points into `text`; no syscalls, so
/// it is deterministically unit-testable with fixture strings.
pub fn parseMountinfo(text: []const u8, out: *[max_mounts]MountRef) []const MountRef {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    scan: while (lines.next()) |line| {
        if (n >= max_mounts) break; // bounded — truncate, never overrun
        // Split on the standalone " - " token: pre holds fields 0..5+optional,
        // post starts at the fstype. No separator -> malformed -> skip.
        const sep = std.mem.indexOf(u8, line, " - ") orelse continue;
        const pre = line[0..sep];
        const post = line[sep + 3 ..];
        // mount point = field index 4 (0-based) of the pre-separator fields.
        var it = std.mem.tokenizeScalar(u8, pre, ' ');
        var idx: usize = 0;
        var mp: []const u8 = &.{};
        while (it.next()) |f| : (idx += 1) {
            if (idx == 4) {
                mp = f;
                break;
            }
        }
        if (mp.len == 0) continue; // fewer than 5 fields -> malformed -> skip
        // fstype = first field after the separator.
        var pit = std.mem.tokenizeScalar(u8, post, ' ');
        const fstype = pit.next() orelse continue;
        if (isPseudoFs(fstype)) continue; // pseudo/virtual -> drop
        // dedup by mountpoint (first occurrence wins).
        var k: usize = 0;
        while (k < n) : (k += 1) {
            if (std.mem.eql(u8, out[k].mountpoint, mp)) continue :scan;
        }
        out[n] = .{ .mountpoint = mp, .fstype = fstype };
        n += 1;
    }
    return out[0..n];
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

/// statfs(path) -> (total, used) bytes. Raw syscall via linux.syscall2 (same
/// idiom as spawner.zig:445's linux.syscall3(.setpriority, ...)). On any error
/// or garbage, returns zeros — callers skip a zero-total mount (fail-closed).
/// total = f_blocks*f_bsize; used = (f_blocks-f_bfree)*f_bsize — both saturating.
fn statfsPath(path_z: [*:0]const u8) struct { total: u64, used: u64 } {
    var sf: Statfs = undefined;
    const rc: usize = @intCast(linux.syscall2(.statfs, @intFromPtr(path_z), @intFromPtr(&sf)));
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
    prev_core_total: [max_cores]u64 = [_]u64{0} ** max_cores,
    prev_core_idle: [max_cores]u64 = [_]u64{0} ** max_cores,
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
        const ncore: u32 = if (cpu.logical > max_cores) max_cores else cpu.logical;
        out.core_n = ncore;
        if (self.have_prev) {
            out.cpu_total_delta = cpu.total -| self.prev_cpu_total;
            out.cpu_idle_delta = cpu.idle -| self.prev_cpu_idle;
            var i: u32 = 0;
            while (i < ncore) : (i += 1) {
                out.core_total_delta[i] = cpu.core_total[i] -| self.prev_core_total[i];
                out.core_idle_delta[i] = cpu.core_idle[i] -| self.prev_core_idle[i];
            }
        }
        self.prev_cpu_total = cpu.total;
        self.prev_cpu_idle = cpu.idle;
        self.prev_core_total = cpu.core_total;
        self.prev_core_idle = cpu.core_idle;
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

        // Per-mount filesystem usage. Read /proc/self/mountinfo (64 KiB covers
        // hundreds of mounts; truncation is safe — we parse what we read),
        // parse to real-fs refs, then statfs each mountpoint. Fail-closed: a
        // mount whose statfs errors or reports total==0 (pseudo/unavailable) is
        // skipped, and a mountpoint too long to form a NUL-terminated C string
        // in the fixed buffer is skipped too (never a truncated wrong path).
        var mi_buf: [65536]u8 = undefined;
        const mi_text = readFile("/proc/self/mountinfo", &mi_buf) orelse "";
        var refs: [max_mounts]MountRef = undefined;
        const mounts = parseMountinfo(mi_text, &refs);
        var mn: u32 = 0;
        for (mounts) |ref| {
            // Need room for the path plus a NUL terminator in a 128-byte buffer.
            if (ref.mountpoint.len >= 128) continue; // will not fit -> skip (fail-closed)
            var path_z: [128]u8 = undefined;
            @memcpy(path_z[0..ref.mountpoint.len], ref.mountpoint);
            path_z[ref.mountpoint.len] = 0;
            const fs = statfsPath(@ptrCast(&path_z));
            if (fs.total == 0) continue; // pseudo/unavailable -> skip (fail-closed)
            out.mounts[mn].path_len = @intCast(ref.mountpoint.len);
            @memcpy(out.mounts[mn].path[0..ref.mountpoint.len], ref.mountpoint);
            out.mounts[mn].total = fs.total;
            out.mounts[mn].used = fs.used;
            mn += 1;
        }
        out.mount_n = mn;

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

test "parseStatCpu captures per-core total and idle" {
    const c = parseStatCpu(
        "cpu  100 20 30 400 50 0 0 0 0 0\n" ++
            "cpu0 1 2 3 4 5\n" ++ // total 15, idle field4+field5 = 4+5 = 9
            "cpu1 10 20 30 40 50\n" ++ // total 150, idle 40+50 = 90
            "cpu2 5 5 5 5 5\n" ++ // total 25, idle 5+5 = 10
            "cpu3 2 2 2 2 2\n", // total 10, idle 2+2 = 4
    );
    try testing.expectEqual(@as(u32, 4), c.logical);
    // aggregate line is unchanged by the per-core capture
    try testing.expectEqual(@as(u64, 100 + 20 + 30 + 400 + 50), c.total);
    try testing.expectEqual(@as(u64, 400 + 50), c.idle);
    // each cpuN line's total (sum of fields) + idle (field4+field5)
    try testing.expectEqual(@as(u64, 15), c.core_total[0]);
    try testing.expectEqual(@as(u64, 9), c.core_idle[0]);
    try testing.expectEqual(@as(u64, 150), c.core_total[1]);
    try testing.expectEqual(@as(u64, 90), c.core_idle[1]);
    try testing.expectEqual(@as(u64, 25), c.core_total[2]);
    try testing.expectEqual(@as(u64, 10), c.core_idle[2]);
    try testing.expectEqual(@as(u64, 10), c.core_total[3]);
    try testing.expectEqual(@as(u64, 4), c.core_idle[3]);
}

// MUTATION TARGET: loosening the per-core index bound in parseStatCpu
// (`n >= max_cores` -> `n > max_cores`, or dropping the clamp) makes this test
// overrun core_total[]/core_idle[] and trap.
test "parseStatCpu ignores cpuN with N beyond max_cores (no overrun)" {
    // cpu256 == max_cores (boundary: catches `>=`->`>`) and cpu9999 far past
    // the end (catches a dropped clamp). Both must be counted but not captured.
    const c = parseStatCpu(
        "cpu  1 1 1 1 1\n" ++
            "cpu0 1 1 1 1 1\n" ++ // in range: captured (total 5)
            "cpu256 9 9 9 9 9\n" ++ // == max_cores: out of range
            "cpu9999 9 9 9 9 9\n", // far out of range
    );
    try testing.expectEqual(@as(u64, 5), c.core_total[0]); // in-range core captured
    try testing.expectEqual(@as(u32, 3), c.logical); // every cpuN line still counted
}

test "per-core util: busy core -> ~1.0, idle core -> ~0.0" {
    // Two /proc/stat readings mirroring the Sampler's per-core deltas and the
    // encoder's util formula (1 - idle_delta/total_delta), applied per core.
    const first = parseStatCpu(
        "cpu  0 0 0 0 0\n" ++
            "cpu0 100 0 0 100 0\n" ++ // total 200, idle 100
            "cpu1 100 0 0 100 0\n", // total 200, idle 100
    );
    const second = parseStatCpu(
        "cpu  0 0 0 0 0\n" ++
            "cpu0 200 0 0 100 0\n" ++ // total 300 (+100 busy), idle 100 (+0)
            "cpu1 100 0 0 200 0\n", // total 300 (+100), idle 200 (+100 all idle)
    );
    const c0_total_delta = second.core_total[0] -| first.core_total[0]; // 100
    const c0_idle_delta = second.core_idle[0] -| first.core_idle[0]; // 0
    const c1_total_delta = second.core_total[1] -| first.core_total[1]; // 100
    const c1_idle_delta = second.core_idle[1] -| first.core_idle[1]; // 100
    const util0 = 1.0 - @as(f64, @floatFromInt(c0_idle_delta)) / @as(f64, @floatFromInt(c0_total_delta));
    const util1 = 1.0 - @as(f64, @floatFromInt(c1_idle_delta)) / @as(f64, @floatFromInt(c1_total_delta));
    try testing.expectApproxEqAbs(@as(f64, 1.0), util0, 1e-9); // fully busy
    try testing.expectApproxEqAbs(@as(f64, 0.0), util1, 1e-9); // fully idle
}

test "parseNetDev sums non-loopback rx/tx" {
    const n = parseNetDev("Inter-|...\n face |...\n  lo: 5 0 0 0 0 0 0 0 5 0 0 0 0 0 0 0\n eth0: 1000 0 0 0 0 0 0 0 2000 0 0 0 0 0 0 0\n");
    try testing.expectEqual(@as(u64, 1000), n.rx); // lo excluded
    try testing.expectEqual(@as(u64, 2000), n.tx);
}

test "parseMountinfo skips pseudo-fs, dedups, keeps real mounts in order" {
    // Realistic mountinfo: pseudo lines (proc/sysfs/devtmpfs/devpts/tmpfs/
    // cgroup2) interleaved with three real filesystems (/ ext4, /boot vfat,
    // /data xfs), plus a duplicate /data line that must coalesce to one.
    const text =
        "21 30 0:20 / /proc rw,nosuid,noexec - proc proc rw\n" ++
        "22 30 0:21 / /sys rw,nosuid,noexec - sysfs sysfs rw\n" ++
        "23 30 0:5 / /dev rw,nosuid - devtmpfs devtmpfs rw\n" ++
        "24 23 0:22 / /dev/pts rw,nosuid - devpts devpts rw\n" ++
        "25 30 0:23 / /run rw,nosuid - tmpfs tmpfs rw\n" ++
        "30 0 8:2 / / rw,relatime - ext4 /dev/sda2 rw\n" ++
        "40 30 0:30 / /sys/fs/cgroup rw - cgroup2 cgroup2 rw\n" ++
        "31 30 8:1 / /boot rw,relatime - vfat /dev/sda1 rw\n" ++
        "32 30 8:3 / /data rw,relatime - xfs /dev/sda3 rw\n" ++
        "33 30 8:3 / /data rw,relatime - xfs /dev/sda3 rw\n"; // duplicate mountpoint
    var refs: [max_mounts]MountRef = undefined;
    const got = parseMountinfo(text, &refs);
    // Exactly the three real mounts, in order; every pseudo-fs dropped; the
    // duplicate /data appears once. (MUTATION: bypassing the denylist makes
    // got.len jump and got[0] become "/proc" — this assertion then fails.)
    try testing.expectEqual(@as(usize, 3), got.len);
    try testing.expectEqualStrings("/", got[0].mountpoint);
    try testing.expectEqualStrings("ext4", got[0].fstype);
    try testing.expectEqualStrings("/boot", got[1].mountpoint);
    try testing.expectEqualStrings("vfat", got[1].fstype);
    try testing.expectEqualStrings("/data", got[2].mountpoint);
    try testing.expectEqualStrings("xfs", got[2].fstype);
}

test "parseMountinfo truncates beyond max_mounts and skips malformed lines" {
    var buf: [8192]u8 = undefined;
    var w: usize = 0;
    // A malformed line first (no " - " separator) — must be skipped, not counted.
    const bad = "99 30 8:9 / /bad rw noseparatorhere\n";
    @memcpy(buf[0..bad.len], bad);
    w += bad.len;
    // More than max_mounts distinct real ext4 mounts.
    var i: usize = 0;
    while (i < max_mounts + 8) : (i += 1) {
        const line = try std.fmt.bufPrint(buf[w..], "{d} 30 8:2 / /m{d} rw - ext4 /dev/sd{d} rw\n", .{ i, i, i });
        w += line.len;
    }
    var refs: [max_mounts]MountRef = undefined;
    const got = parseMountinfo(buf[0..w], &refs);
    // Bounded to max_mounts (no overrun of the out array), and the malformed
    // line was skipped so /m0 is the first captured mount.
    try testing.expectEqual(@as(usize, max_mounts), got.len);
    try testing.expectEqualStrings("/m0", got[0].mountpoint);
    try testing.expectEqualStrings("ext4", got[0].fstype);
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
    // A giant per-core field also saturates (parseInt overflow -> 0), not trap.
    const cg = parseStatCpu("cpu 0 0\ncpu0 99999999999999999999999 99999999999999999999999\n");
    try testing.expectEqual(@as(u64, 0), cg.core_total[0]);
    try testing.expectEqual(@as(u64, 0), cg.core_idle[0]);
}

test "sample reads live host values (validates statfs layout + /proc)" {
    // The pure parsers are covered above; this exercises the file-reading path
    // and the hand-rolled `struct statfs` on real /proc + a real filesystem.
    // The asserts are ">0", true on any live Linux/WSL host, so it is stable —
    // but a wrong statfs offset would make every mount total 0/garbage and fail
    // here, which is the whole point (a compile cannot catch a bad struct layout).
    if (builtin.os.tag != .linux) return; // /proc + statfs are Linux-only
    var s = Sampler{};
    _ = s.sample(); // prime the prior CPU reading
    const h = s.sample();
    try testing.expect(h.mem_total > 0); // /proc/meminfo MemTotal parsed
    // Per-mount filesystem: at least one real mount, one with total>0 and
    // used<=total (a wrong statfs offset would make every total 0/garbage and
    // fail here — a compile cannot catch a bad struct layout), and "/" present.
    try testing.expect(h.mount_n > 0);
    var saw_root = false;
    var saw_nonzero = false;
    var mi: u32 = 0;
    while (mi < h.mount_n) : (mi += 1) {
        const m = h.mounts[mi];
        if (std.mem.eql(u8, m.path[0..m.path_len], "/")) saw_root = true;
        if (m.total > 0) {
            saw_nonzero = true;
            try testing.expect(m.used <= m.total);
        }
    }
    try testing.expect(saw_root); // "/" is among the mounts
    try testing.expect(saw_nonzero); // statfs offsets correct -> real bytes
    try testing.expect(h.logical_cpus > 0); // /proc/stat cpuN lines counted
    // per-core path primed + delta'd without overrun: core_n is bounded by both
    // the logical count and max_cores.
    try testing.expect(h.core_n > 0);
    try testing.expect(h.core_n <= h.logical_cpus);
    try testing.expect(h.core_n <= max_cores);
}
