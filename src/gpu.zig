//! NVIDIA GPU metrics via an `nvidia-smi` shell-out. 100% opt-in and
//! fail-closed: absent binary / exec fail / non-zero exit / timeout yields
//! ZERO GPU points, a single stderr log, and no effect on supervision or any
//! other telemetry.
//!
//! THE MOTTO GOVERNS THIS FILE. "push the stability to the sky, light like a
//! feather, fast like the flash":
//!   - STABILITY: the subprocess + bounded read run ONLY in the relay daemon,
//!     NEVER on PID 1. The parser saturates — a non-numeric field becomes 0, a
//!     short/garbage row is skipped, oversize input truncates to `max_gpus`. No
//!     `unreachable`, no panic, no `catch |_|`-that-hides. The daemon loop is
//!     never blocked beyond a hard ~2s poll timeout.
//!   - LIGHT: zero heap. Every buffer is fixed and preallocated. Static musl:
//!     nvidia-smi is a SUBPROCESS — no libc, no dlopen, no NVML linkage.
//!   - FAST: the parser is a single O(input) line scan (std.mem, no regex).

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const spawner = @import("spawner.zig");
const capture = @import("capture.zig");

/// Hard cap on GPUs per sample. Excess rows are truncated, never overrun.
pub const max_gpus = 16;

/// One GPU's snapshot. Memory in BYTES, power in MILLIWATTS — the units the
/// OTLP encoder wants — so the encoder never has to re-scale.
pub const GpuSample = struct {
    index: u32 = 0,
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: u8 = 0,
    util_pct: u32 = 0,
    mem_used: u64 = 0, // bytes
    mem_total: u64 = 0, // bytes
    temp_c: u32 = 0,
    power_mw: u64 = 0, // milliwatts

    pub fn nameSlice(g: *const GpuSample) []const u8 {
        return g.name[0..g.name_len];
    }
};

/// GPU names longer than this are truncated in storage (the buffer holds 64 so
/// one byte is always spare — nothing here relies on NUL-termination).
const name_cap = 63;

/// Read leading decimal digits, saturating. A field with no leading digit
/// ("[N/A]", nvidia-smi's missing-value token; empty; garbage) parses to 0 and
/// never traps — this is the fail-closed contract for a single field.
fn parseUint(comptime T: type, s: []const u8) T {
    var v: T = 0;
    var i: usize = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        v = v *| 10 +| (s[i] - '0');
    }
    return v;
}

/// Parse a watts string ("35.20", "320.5", "[N/A]") to MILLIWATTS, saturating.
/// Mirrors hostmetrics.parseLoadavg: the whole part ×1000 plus up to three
/// fractional digits normalized to thousandths (so "320.5" -> 320500 mW). A
/// non-numeric / [N/A] value yields 0. Watts→mW is exactly this ×1000 scaling.
fn parseWattsMw(s: []const u8) u64 {
    var i: usize = 0;
    var whole: u64 = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        whole = whole *| 10 +| (s[i] - '0');
    }
    var frac: u64 = 0;
    var fdigits: u32 = 0;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and s[i] >= '0' and s[i] <= '9' and fdigits < 3) : (i += 1) {
            frac = frac * 10 + (s[i] - '0'); // bounded: <=3 digits -> <1000
            fdigits += 1;
        }
    }
    while (fdigits < 3) : (fdigits += 1) frac *= 10; // "5" -> 500 (thousandths)
    return whole *| 1000 +| frac;
}

/// PURE parser for `nvidia-smi --format=csv,noheader,nounits` output. Each row
/// is 7 comma-separated fields in order:
///   index, name, utilization.gpu, memory.used, memory.total,
///   temperature.gpu, power.draw
/// utilization/temperature are integer %/°C; memory.used/total are MiB (stored
/// as bytes); power.draw is watts, possibly fractional (stored as mW). A row
/// with fewer than 7 fields is skipped; every numeric field parses saturating
/// (garbage / [N/A] -> 0). Bounded to `max_gpus` (excess rows truncated). No
/// allocation, no syscalls: unit-testable with a fixture string.
pub fn parseNvidiaSmi(csv: []const u8, out: *[max_gpus]GpuSample) []const GpuSample {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, csv, '\n');
    while (lines.next()) |raw| {
        if (n >= max_gpus) break; // bounded: truncate excess GPUs
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;

        // Split into the 7 expected fields, each trimmed. A short row (fewer
        // than 7) is a header/garbage line and is skipped.
        var fields: [7][]const u8 = undefined;
        var nf: usize = 0;
        var it = std.mem.splitScalar(u8, line, ',');
        while (it.next()) |f| : (nf += 1) {
            if (nf < fields.len) fields[nf] = std.mem.trim(u8, f, " \t");
        }
        if (nf < fields.len) continue; // short/garbage row -> skip

        var g = GpuSample{};
        g.index = parseUint(u32, fields[0]);
        const nlen = @min(fields[1].len, name_cap);
        @memcpy(g.name[0..nlen], fields[1][0..nlen]);
        g.name_len = @intCast(nlen);
        g.util_pct = parseUint(u32, fields[2]);
        // MUTATION SENTINEL: fields[3]=memory.used, fields[4]=memory.total,
        // fields[5]=temperature.gpu, fields[6]=power.draw. Swapping any two of
        // these field indices misassigns a named value and a unit test fails.
        g.mem_used = parseUint(u64, fields[3]) *| (1024 * 1024); // MiB -> bytes
        g.mem_total = parseUint(u64, fields[4]) *| (1024 * 1024); // MiB -> bytes
        g.temp_c = parseUint(u32, fields[5]);
        g.power_mw = parseWattsMw(fields[6]); // W -> mW
        out[n] = g;
        n += 1;
    }
    return out[0..n];
}

// ------------------------------------------------------- DRM sysfs (AMD/Intel)
//
// A SECOND GPU source with the SAME GpuSample shape, filled from pure sysfs file
// reads (no subprocess — unlike the nvidia-smi path). AMD amdgpu primarily,
// Intel best-effort. These samples flow through the SAME buildOtlpGpuMetrics
// encoder as the nvidia-smi samples — no encoder change, one merged POST.
//
// STABILITY (the motto): every read is fail-closed (unreadable file -> "" -> the
// field is 0, or the whole card is skipped); every parse saturates; the set is
// bounded to max_gpus; no subprocess, no alloc, no unreachable/panic. Runs ONLY
// in the relay daemon (off PID 1), under the SAME `[gpu] enabled` toggle.

/// PURE per-card core: given the (already-file-read) CONTENTS of one card's
/// sysfs files, produce a GpuSample — or `null` to SKIP the card. The skip rule
/// is the whole point: a card with no `gpu_busy_percent` (empty `util`) is an
/// NVIDIA GPU (or a non-GPU DRM node) already covered by nvidia-smi, so it is
/// dropped here to avoid double-counting. Units: VRAM is bytes as-is; temp is
/// milli-°C ÷1000 -> °C; power is micro-W ÷1000 -> mW. Every field parses
/// saturating (garbage/over-long -> saturates; missing -> ""/0). `index` becomes
/// the sample's index; `name` is copied (truncated to name_cap). No syscalls, no
/// allocation: deterministically unit-testable with fixture strings.
///
/// MUTATION SENTINEL: the `util_t.len == 0 -> return null` guard is the "skip a
/// card without gpu_busy_percent" rule. Treating empty util as 0 and keeping the
/// card (dropping this return) makes the "parseDrmCard skips a card without
/// gpu_busy_percent" test fail.
pub fn parseDrmCard(
    index: u32,
    name: []const u8,
    util: []const u8, // gpu_busy_percent (0..100); empty -> skip the card
    vram_used: []const u8, // mem_info_vram_used (bytes)
    vram_total: []const u8, // mem_info_vram_total (bytes)
    temp: []const u8, // hwmon tempN_input (milli-°C); may be empty -> 0
    power: []const u8, // hwmon power1_average (micro-W); may be empty -> 0
) ?GpuSample {
    const ws = " \t\r\n\x00";
    const util_t = std.mem.trim(u8, util, ws);
    if (util_t.len == 0) return null; // no gpu_busy_percent -> not an amdgpu -> skip

    var g = GpuSample{};
    g.index = index;
    const nlen = @min(name.len, name_cap);
    @memcpy(g.name[0..nlen], name[0..nlen]);
    g.name_len = @intCast(nlen);
    g.util_pct = parseUint(u32, util_t);
    g.mem_used = parseUint(u64, std.mem.trim(u8, vram_used, ws)); // bytes as-is
    g.mem_total = parseUint(u64, std.mem.trim(u8, vram_total, ws)); // bytes as-is
    g.temp_c = parseUint(u32, std.mem.trim(u8, temp, ws)) / 1000; // milli-°C -> °C
    g.power_mw = parseUint(u64, std.mem.trim(u8, power, ws)) / 1000; // micro-W -> mW
    return g;
}

// ------------------------------------------------------- daemon-side sampling

/// Bounded scratch for nvidia-smi's stdout. 16 GPUs × one CSV line each is far
/// below this; a runaway child cannot grow it (the read stops at the brim).
var stdout_buf: [16 * 1024]u8 = undefined;

/// Hard ceiling on the whole sample: the poll read and the reap each obey it,
/// so a hung nvidia-smi can never stall the daemon loop beyond ~this.
const gpu_timeout_ms: u64 = 2000;

/// Fail-closed logging is once-only: a GPU-less node must not spam a line every
/// interval. Latched true on the first failure for the daemon's life.
var logged_fail = false;

fn failOnce() void {
    if (logged_fail) return;
    logged_fail = true;
    const msg = "[mandor] gpu: nvidia-smi unavailable or failed; GPU metrics disabled (fail-closed)\n";
    _ = linux.write(2, msg, msg.len);
}

/// CLOCK_MONOTONIC in ms — the sample's own deadline clock. Saturating so a bad
/// clock read cannot trap; monotonic so a wall-clock step cannot skew the bound.
fn monoMs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) *| 1000 +| @as(u64, @intCast(ts.nsec)) / 1_000_000;
}

/// Fork/exec `nvidia-smi`, capture its stdout through a CLOEXEC pipe with a
/// bounded, poll-timed read, reap it, then parse. Returns an empty slice AND
/// logs once on ANY failure — absent binary, fork/exec failure, non-zero exit,
/// or timeout (fail-closed). Runs ONLY in the daemon; never blocks the loop
/// beyond `gpu_timeout_ms`; never panics.
///
/// `path_env` resolves the bare `nvidia-smi` (findPath idiom); `envp` is the
/// daemon's environment for the child. `out` is caller-owned fixed storage.
pub fn sample(
    path_env: []const u8,
    envp: [*:null]const ?[*:0]const u8,
    out: *[max_gpus]GpuSample,
) []const GpuSample {
    const p = capture.makePipe() orelse {
        failOnce();
        return out[0..0];
    };

    const supervisor_pid = linux.getpid();
    const rc = linux.fork();
    if (posix.errno(rc) != .SUCCESS) {
        _ = linux.close(p.r);
        _ = linux.close(p.w);
        failOnce();
        return out[0..0];
    }
    if (rc == 0) {
        // Child: die with the daemon (never orphan an nvidia-smi), restore the
        // signal mask, route stdout into the pipe and stderr to /dev/null so
        // nvidia-smi chatter never pollutes the daemon's own stderr.
        _ = linux.prctl(@intFromEnum(linux.PR.SET_PDEATHSIG), @intFromEnum(posix.SIG.KILL), 0, 0, 0);
        if (linux.getppid() != supervisor_pid) linux.exit(1);
        const empty = posix.sigemptyset();
        posix.sigprocmask(posix.SIG.SETMASK, &empty, null);
        _ = linux.dup2(p.w, 1); // stdout -> pipe (dup2 clears CLOEXEC on fd 1)
        const null_rc = linux.openat(linux.AT.FDCWD, "/dev/null", .{ .ACCMODE = .WRONLY }, 0);
        if (posix.errno(null_rc) == .SUCCESS) _ = linux.dup2(@intCast(null_rc), 2);
        // The pipe's read end and the original write end are CLOEXEC, so they
        // close at exec — the child keeps only fd 1.
        const argv = [_:null]?[*:0]const u8{
            "nvidia-smi",
            "--query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw",
            "--format=csv,noheader,nounits",
        };
        spawner.execArgv(&argv, envp, path_env); // noreturn (127 on exec fail)
    }

    const child: i32 = @intCast(rc);
    _ = linux.close(p.w); // parent keeps only the read end

    // Bounded, poll-timed read: never wait past the overall deadline, so a
    // wedged nvidia-smi costs at most gpu_timeout_ms.
    var filled: usize = 0;
    var read_ok = true;
    const deadline = monoMs() +| gpu_timeout_ms;
    while (filled < stdout_buf.len) {
        const now = monoMs();
        if (now >= deadline) {
            read_ok = false;
            break;
        }
        const remaining: i32 = @intCast(@min(deadline - now, gpu_timeout_ms));
        var pfd = [_]posix.pollfd{.{ .fd = p.r, .events = posix.POLL.IN, .revents = 0 }};
        const pr = posix.poll(&pfd, remaining) catch {
            read_ok = false;
            break;
        };
        if (pr == 0) { // timed out
            read_ok = false;
            break;
        }
        const got = linux.read(p.r, stdout_buf[filled..].ptr, stdout_buf.len - filled);
        switch (posix.errno(got)) {
            .SUCCESS => {
                if (got == 0) break; // EOF: child closed stdout / exited
                filled += got;
            },
            .INTR, .AGAIN => continue, // signal / spurious wakeup: re-poll
            else => {
                read_ok = false;
                break;
            },
        }
    }
    _ = linux.close(p.r);

    // Reap the child, bounded. If the read timed out, KILL it first so the
    // reap cannot itself block. A killed or already-exited child reaps at once.
    if (!read_ok) posix.kill(child, .KILL) catch {};
    var status: u32 = 0;
    var reaped = false;
    var waited: u64 = 0;
    while (waited < gpu_timeout_ms) {
        const wr = linux.waitpid(child, &status, linux.W.NOHANG);
        if (posix.errno(wr) == .SUCCESS and wr != 0) {
            reaped = true;
            break;
        }
        var ts = linux.timespec{ .sec = 0, .nsec = 10 * 1_000_000 }; // 10ms
        _ = linux.nanosleep(&ts, &ts);
        waited += 10;
    }
    if (!reaped) {
        // Still alive after the budget: force it and reap the zombie (KILL is
        // delivered promptly, so this final wait returns at once).
        posix.kill(child, .KILL) catch {};
        _ = linux.waitpid(child, &status, 0);
        failOnce();
        return out[0..0];
    }

    // Fail-closed on timeout or a non-zero / signalled exit: no GPU points.
    if (!read_ok or !(linux.W.IFEXITED(status) and linux.W.EXITSTATUS(status) == 0)) {
        failOnce();
        return out[0..0];
    }
    return parseNvidiaSmi(stdout_buf[0..filled], out);
}

// ------------------------------------------------------- DRM sysfs reader
//
// Fixed buffers + raw openat/read/close (posix.errno), mirroring
// hostmetrics.readFile/readTrimmed. NEVER fails: an unreadable/absent file is ""
// (fail-closed). No allocation, no subprocess.

/// Read a small sysfs file into `buf`, returning it trimmed of surrounding
/// whitespace/NUL — or "" on ANY error (absent, EACCES, read error). Mirrors
/// hostmetrics.readTrimmed's fail-closed contract.
fn readTrimmed(path: [*:0]const u8, buf: []u8) []const u8 {
    const rc = linux.openat(linux.AT.FDCWD, path, .{}, 0);
    if (posix.errno(rc) != .SUCCESS) return "";
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    const n = linux.read(fd, buf.ptr, buf.len);
    if (posix.errno(n) != .SUCCESS) return "";
    return std.mem.trim(u8, buf[0..n], " \t\r\n\x00");
}

/// Read `/sys/class/drm/card<card>/device/<leaf>` into `buf` (trimmed), "" on
/// any failure. Building `card<card>` from an integer sidesteps the
/// `card<N>-<connector>` output nodes entirely — we never enumerate them, so
/// only bare-card device attributes are ever read.
fn readLeaf(card: u32, comptime leaf: []const u8, buf: []u8) []const u8 {
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "/sys/class/drm/card{d}/device/" ++ leaf, .{card}) catch return "";
    return readTrimmed(path, buf);
}

/// hwmon is optional and its instance number varies (`hwmon0`, `hwmon3`, ...).
/// Without getdents we PROBE a bounded set of instances and take the first that
/// yields the leaf; absent hwmon -> "" (best-effort, 0 downstream). Bounded loop.
fn readHwmon(card: u32, comptime leaf: []const u8, buf: []u8) []const u8 {
    var h: u32 = 0;
    while (h < 8) : (h += 1) { // bounded probe: hwmon0..hwmon7
        var path_buf: [160]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/sys/class/drm/card{d}/device/hwmon/hwmon{d}/" ++ leaf, .{ card, h }) catch continue;
        const v = readTrimmed(path, buf);
        if (v.len != 0) return v;
    }
    return "";
}

/// Enumerate DRM cards via a bounded PROBE (card0..card{max_gpus-1}) — no
/// getdents needed, and constructing `card<N>` by integer never touches the
/// `card<N>-<connector>` output nodes. For each card, read `gpu_busy_percent`
/// first: absent -> the card is an NVIDIA GPU (already covered by nvidia-smi) or
/// not a GPU, so it is SKIPPED (this cleanly avoids double-counting). Present ->
/// read VRAM + hwmon temp/power (best-effort, 0 if missing) and fill a GpuSample
/// via the pure `parseDrmCard`.
///
/// Samples are written into `out` STARTING at `start_index` and each is given a
/// UNIQUE `index` continuing from `start_index`, so a merged {nvidia ++ drm} set
/// shares one contiguous buffer and never collides on the index attribute
/// (gpu.name disambiguates further). Bounded to max_gpus; NEVER fails (unreadable
/// -> skip); no allocation, no subprocess. Runs ONLY in the daemon.
pub fn sampleDrm(out: *[max_gpus]GpuSample, start_index: u32) []const GpuSample {
    const base: u32 = if (start_index < max_gpus) start_index else max_gpus;
    var w: u32 = base;
    var card: u32 = 0;
    while (card < max_gpus and w < max_gpus) : (card += 1) {
        // Each field reads into its OWN buffer so all slices stay valid until the
        // single parseDrmCard call (no read clobbers a prior field's bytes).
        var b_util: [64]u8 = undefined;
        var b_vu: [64]u8 = undefined;
        var b_vt: [64]u8 = undefined;
        var b_temp: [64]u8 = undefined;
        var b_power: [64]u8 = undefined;
        var b_name: [96]u8 = undefined;

        const util = readLeaf(card, "gpu_busy_percent", &b_util);
        if (util.len == 0) continue; // no gpu_busy_percent -> skip (NVIDIA / non-GPU)

        const vu = readLeaf(card, "mem_info_vram_used", &b_vu);
        const vt = readLeaf(card, "mem_info_vram_total", &b_vt);
        const temp = readHwmon(card, "temp1_input", &b_temp); // milli-°C, optional
        const power = readHwmon(card, "power1_average", &b_power); // micro-W, optional

        // Name: prefer product_name; else the stable fallback "card<N>".
        var name = readLeaf(card, "product_name", &b_name);
        if (name.len == 0) name = std.fmt.bufPrint(&b_name, "card{d}", .{card}) catch "card";

        const g = parseDrmCard(w, name, util, vu, vt, temp, power) orelse continue;
        out[w] = g;
        w += 1;
    }
    return out[base..w];
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "parseNvidiaSmi parses a 2-GPU fixture with correct units" {
    const csv =
        "0, NVIDIA RTX 4090, 55, 2048, 24576, 61, 320.50\n" ++
        "1, NVIDIA A100, 0, 100, 40960, 40, 55.00\n";
    var out: [max_gpus]GpuSample = undefined;
    const g = parseNvidiaSmi(csv, &out);
    try testing.expectEqual(@as(usize, 2), g.len);

    try testing.expectEqual(@as(u32, 0), g[0].index);
    try testing.expectEqualStrings("NVIDIA RTX 4090", g[0].nameSlice());
    try testing.expectEqual(@as(u32, 55), g[0].util_pct);
    try testing.expectEqual(@as(u64, 2048 * 1024 * 1024), g[0].mem_used); // MiB -> bytes
    try testing.expectEqual(@as(u64, 24576 * 1024 * 1024), g[0].mem_total);
    try testing.expectEqual(@as(u32, 61), g[0].temp_c);
    try testing.expectEqual(@as(u64, 320_500), g[0].power_mw); // 320.50 W -> mW

    try testing.expectEqual(@as(u32, 1), g[1].index);
    try testing.expectEqualStrings("NVIDIA A100", g[1].nameSlice());
    try testing.expectEqual(@as(u32, 0), g[1].util_pct);
    try testing.expectEqual(@as(u64, 100 * 1024 * 1024), g[1].mem_used);
    try testing.expectEqual(@as(u64, 40960 * 1024 * 1024), g[1].mem_total);
    try testing.expectEqual(@as(u32, 40), g[1].temp_c);
    try testing.expectEqual(@as(u64, 55_000), g[1].power_mw); // 55.00 W -> mW
}

test "parseNvidiaSmi skips a short row and never traps on [N/A]" {
    // Row 1 is short (4 fields) -> skipped. Row 2 has [N/A] in numeric fields
    // (nvidia-smi's missing-value token) -> those fields parse to 0, no trap.
    const csv =
        "garbage, only, four, fields\n" ++
        "0, Tesla T4, [N/A], [N/A], 16384, [N/A], [N/A]\n";
    var out: [max_gpus]GpuSample = undefined;
    const g = parseNvidiaSmi(csv, &out);
    try testing.expectEqual(@as(usize, 1), g.len);
    try testing.expectEqualStrings("Tesla T4", g[0].nameSlice());
    try testing.expectEqual(@as(u32, 0), g[0].util_pct); // [N/A] -> 0
    try testing.expectEqual(@as(u64, 0), g[0].mem_used); // [N/A] -> 0
    try testing.expectEqual(@as(u64, 16384 * 1024 * 1024), g[0].mem_total);
    try testing.expectEqual(@as(u32, 0), g[0].temp_c); // [N/A] -> 0
    try testing.expectEqual(@as(u64, 0), g[0].power_mw); // [N/A] -> 0
}

test "parseNvidiaSmi truncates beyond max_gpus" {
    // max_gpus + 3 valid rows -> only max_gpus are kept (bounded, no overrun).
    var csv_buf: [1024]u8 = undefined;
    var pos: usize = 0;
    var i: usize = 0;
    while (i < max_gpus + 3) : (i += 1) {
        const line = std.fmt.bufPrint(csv_buf[pos..], "{d}, GPU, 1, 1, 2, 30, 10.00\n", .{i}) catch unreachable;
        pos += line.len;
    }
    var out: [max_gpus]GpuSample = undefined;
    const g = parseNvidiaSmi(csv_buf[0..pos], &out);
    try testing.expectEqual(@as(usize, max_gpus), g.len);
    try testing.expectEqual(@as(u32, 0), g[0].index);
    try testing.expectEqual(@as(u32, max_gpus - 1), g[max_gpus - 1].index);
}

test "parseNvidiaSmi truncates an over-long GPU name" {
    // A name longer than name_cap (63) must truncate the STORED name.
    const long = "X" ** 100;
    const csv = "0, " ++ long ++ ", 10, 1, 2, 30, 5.00\n";
    var out: [max_gpus]GpuSample = undefined;
    const g = parseNvidiaSmi(csv, &out);
    try testing.expectEqual(@as(usize, 1), g.len);
    try testing.expectEqual(@as(u8, name_cap), g[0].name_len);
    try testing.expectEqual(@as(usize, name_cap), g[0].nameSlice().len);
}

test "parseDrmCard builds a GpuSample from AMD sysfs fixtures with correct units" {
    // Real amdgpu sysfs shapes (trailing newlines included): gpu_busy_percent is
    // an integer %, VRAM is bytes as-is, temp is milli-°C (÷1000), power is
    // micro-W (÷1000 = mW).
    const g = parseDrmCard(
        0,
        "card0",
        "42\n",
        "2147483648\n", // 2 GiB used, bytes as-is
        "17179869184\n", // 16 GiB total, bytes as-is
        "65000\n", // 65.000 °C
        "120000000\n", // 120 W -> 120000 mW
    ) orelse return error.UnexpectedNull;
    try testing.expectEqual(@as(u32, 0), g.index);
    try testing.expectEqualStrings("card0", g.nameSlice());
    try testing.expectEqual(@as(u32, 42), g.util_pct);
    try testing.expectEqual(@as(u64, 2147483648), g.mem_used); // bytes, no rescale
    try testing.expectEqual(@as(u64, 17179869184), g.mem_total);
    try testing.expectEqual(@as(u32, 65), g.temp_c); // 65000 milli-°C -> 65
    try testing.expectEqual(@as(u64, 120000), g.power_mw); // 120000000 micro-W -> 120000 mW
}

// MUTATION TARGET: the `util_t.len == 0 -> return null` guard in parseDrmCard.
// Treating an empty gpu_busy_percent as 0 and KEEPING the card (dropping the
// return) makes this test fail — the card must be SKIPPED, because a DRM node
// without gpu_busy_percent is an NVIDIA GPU (already covered by nvidia-smi) or
// not a GPU at all, and keeping it double-counts.
test "parseDrmCard skips a card without gpu_busy_percent" {
    // Empty util (file absent -> readLeaf returned "") must skip the card.
    try testing.expect(parseDrmCard(0, "card0", "", "1", "2", "65000", "1000") == null);
    // Whitespace-only util is likewise "no gpu_busy_percent" -> skipped.
    try testing.expect(parseDrmCard(0, "card0", "  \n", "1", "2", "65000", "1000") == null);
}

test "parseDrmCard: missing temp/power are 0 and garbage/over-long saturates" {
    // Missing hwmon temp/power (empty) -> 0, no trap.
    const g = parseDrmCard(3, "card3", "10\n", "", "", "", "") orelse return error.UnexpectedNull;
    try testing.expectEqual(@as(u32, 3), g.index);
    try testing.expectEqual(@as(u32, 10), g.util_pct);
    try testing.expectEqual(@as(u64, 0), g.mem_used);
    try testing.expectEqual(@as(u64, 0), g.mem_total);
    try testing.expectEqual(@as(u32, 0), g.temp_c);
    try testing.expectEqual(@as(u64, 0), g.power_mw);

    // A garbage/over-long value must saturate (parseUint saturates), never trap.
    const big = "999999999999999999999999999999";
    const g2 = parseDrmCard(0, "card0", "999", big, big, big, big) orelse return error.UnexpectedNull;
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), g2.mem_used); // saturated
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), g2.mem_total);
    try testing.expectEqual(@as(u32, std.math.maxInt(u32) / 1000), g2.temp_c); // saturate then ÷1000
    try testing.expectEqual(@as(u64, std.math.maxInt(u64) / 1000), g2.power_mw);
}

test "parseDrmCard assigns indices continuing from start_index (no nvidia collision)" {
    // sampleDrm hands parseDrmCard w = start_index, start_index+1, ... — mirror
    // that here so the merged {nvidia ++ drm} set can never collide on `index`.
    const start_index: u32 = 2; // e.g. 2 NVIDIA GPUs already occupy 0 and 1
    var seen: [4]u32 = undefined;
    var j: u32 = 0;
    while (j < 4) : (j += 1) {
        const g = parseDrmCard(start_index + j, "card", "5", "1", "2", "0", "0") orelse return error.UnexpectedNull;
        seen[j] = g.index;
    }
    try testing.expectEqual(@as(u32, 2), seen[0]); // starts AT start_index, not 0
    try testing.expectEqual(@as(u32, 3), seen[1]);
    try testing.expectEqual(@as(u32, 4), seen[2]);
    try testing.expectEqual(@as(u32, 5), seen[3]);
}

test "sampleDrm never traps and respects start_index bound" {
    // Exercises the file-reading path. On CI/dev hosts there is usually no amdgpu
    // (or no /sys at all), so the assertion is the FAIL-CLOSED contract: it must
    // return without trapping, bounded, and honour start_index. If a real amdgpu
    // IS present, every returned sample's index is >= start_index (continuation).
    var out: [max_gpus]GpuSample = undefined;
    const start_index: u32 = 3;
    const drm = sampleDrm(&out, start_index);
    try testing.expect(drm.len <= max_gpus - start_index); // bounded, appended after slot 2
    for (drm) |g| try testing.expect(g.index >= start_index);
    // start_index past the buffer -> empty, never an overrun.
    try testing.expectEqual(@as(usize, 0), sampleDrm(&out, max_gpus + 5).len);
}
