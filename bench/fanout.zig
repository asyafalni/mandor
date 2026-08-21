//! Micro-benchmark for the per-poll-wake bookkeeping cost as worker count grows.
//!
//! pumpIo rebuilds three parallel arrays (pollfd + owner + kind) every wake,
//! one entry per live out/err/ready fd, then poll()s, then scans the returned
//! fds. Only this CPU bookkeeping is potentially optimizable (e.g. by caching
//! the pollfd set and rebuilding only on spawn/death); the poll() syscall and
//! the per-line drain are inherent. This measures the rebuild + post-poll scan
//! at N = 1, 16, 64 workers (2 fds each: stdout+stderr) to see whether caching
//! could save anything meaningful relative to the poll() syscall (~1 us) it sits
//! next to.
//!
//! Mirrors src/supervisor.zig pumpIo (bench/ convention: self-contained).
//! Run: zig run bench/fanout.zig -OReleaseSafe

const std = @import("std");
const linux = std.os.linux;

const max_workers = 64;

const Worker = struct { out_r: i32, err_r: i32, ready_r: i32 };
const PollKind = enum { out, err, ready };

fn nowNs() u64 {
    var ts = linux.timespec{ .sec = 0, .nsec = 0 };
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @intCast(ts.sec * 1_000_000_000 + ts.nsec);
}

var pfds: [2 + 3 * max_workers]linux.pollfd = undefined;
var owners: [2 + 3 * max_workers]*Worker = undefined;
var kinds: [2 + 3 * max_workers]PollKind = undefined;

// One wake's CPU bookkeeping: rebuild the arrays, then scan them as the
// post-poll dispatch does (revents check). No poll() syscall — we are measuring
// only the part that caching could remove.
fn oneWake(workers: []Worker, sig_fd: i32) usize {
    pfds[0] = .{ .fd = sig_fd, .events = linux.POLL.IN, .revents = 0 };
    var nf: usize = 1;
    for (workers) |*w| {
        if (w.out_r >= 0) {
            pfds[nf] = .{ .fd = w.out_r, .events = linux.POLL.IN, .revents = 0 };
            owners[nf] = w;
            kinds[nf] = .out;
            nf += 1;
        }
        if (w.err_r >= 0) {
            pfds[nf] = .{ .fd = w.err_r, .events = linux.POLL.IN, .revents = 0 };
            owners[nf] = w;
            kinds[nf] = .err;
            nf += 1;
        }
        if (w.ready_r >= 0) {
            pfds[nf] = .{ .fd = w.ready_r, .events = linux.POLL.IN, .revents = 0 };
            owners[nf] = w;
            kinds[nf] = .ready;
            nf += 1;
        }
    }
    // Post-poll dispatch scan (nothing readable in this synthetic run).
    var hits: usize = 0;
    for (pfds[1..nf], 1..) |*pfd, i| {
        if (pfd.revents & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR) == 0) continue;
        _ = i;
        hits += 1;
    }
    return nf + hits;
}

fn measure(n: usize) u64 {
    var workers: [max_workers]Worker = undefined;
    for (0..n) |i| workers[i] = .{ .out_r = @intCast(100 + i * 2), .err_r = @intCast(101 + i * 2), .ready_r = -1 };
    const rounds = 2_000_000;
    var sink: usize = 0;
    const t0 = nowNs();
    for (0..rounds) |_| sink +%= oneWake(workers[0..n], 3);
    const dt = nowNs() - t0;
    std.mem.doNotOptimizeAway(&sink);
    return dt / rounds;
}

pub fn main() void {
    const ns1 = measure(1);
    const ns16 = measure(16);
    const ns64 = measure(64);
    std.debug.print(
        \\per-wake bookkeeping (rebuild pollfd/owner/kind + post-poll scan)
        \\  N=1    {d:>5} ns/wake  ( 2 fds + sigfd)
        \\  N=16   {d:>5} ns/wake  (32 fds + sigfd)
        \\  N=64   {d:>5} ns/wake  (128 fds + sigfd)
        \\context: a poll() syscall alone is ~1000-5000 ns.
        \\
    , .{ ns1, ns16, ns64 });
}
