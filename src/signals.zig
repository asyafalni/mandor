//! Signal handling for PID 1: block TERM/INT/HUP/CHLD and consume them
//! synchronously through a signalfd — no async handlers, no races.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// Aggregated result of draining the signalfd once.
pub const Event = struct {
    /// TERM or INT arrived; holds the signal to forward to workers.
    term_or_int: ?posix.SIG = null,
    chld: bool = false,
    /// Pass-through signals (HUP/QUIT/USR1/USR2/WINCH — the dumb-init set):
    /// forwarded to workers without changing supervisor state.
    pass: [8]posix.SIG = undefined,
    pass_n: u8 = 0,

    fn addPass(ev: *Event, sig: posix.SIG) void {
        if (ev.pass_n < ev.pass.len) {
            ev.pass[ev.pass_n] = sig;
            ev.pass_n += 1;
        }
    }
};

pub const Signals = struct {
    fd: posix.fd_t,

    pub fn init() !Signals {
        var set = posix.sigemptyset();
        posix.sigaddset(&set, .TERM);
        posix.sigaddset(&set, .INT);
        posix.sigaddset(&set, .CHLD);
        // dumb-init parity: consume-and-forward the app-control signals too.
        posix.sigaddset(&set, .HUP);
        posix.sigaddset(&set, .QUIT);
        posix.sigaddset(&set, .USR1);
        posix.sigaddset(&set, .USR2);
        posix.sigaddset(&set, .WINCH);
        posix.sigprocmask(posix.SIG.BLOCK, &set, null);
        const fd = try posix.signalfd(-1, &set, linux.SFD.CLOEXEC | linux.SFD.NONBLOCK);
        return .{ .fd = fd };
    }

    /// Read every queued siginfo record. Never fails: on any read error the
    /// supervisor simply proceeds with what it has (PID 1 must not die).
    pub fn drain(self: *const Signals) Event {
        var ev: Event = .{};
        var buf: [8]linux.signalfd_siginfo = undefined;
        while (true) {
            const n = posix.read(self.fd, std.mem.sliceAsBytes(&buf)) catch return ev;
            const count = n / @sizeOf(linux.signalfd_siginfo);
            for (buf[0..count]) |*si| {
                if (si.signo == @intFromEnum(posix.SIG.TERM)) {
                    ev.term_or_int = .TERM;
                } else if (si.signo == @intFromEnum(posix.SIG.INT)) {
                    ev.term_or_int = .INT;
                } else if (si.signo == @intFromEnum(posix.SIG.CHLD)) {
                    ev.chld = true;
                } else if (si.signo == @intFromEnum(posix.SIG.HUP)) {
                    ev.addPass(.HUP);
                } else if (si.signo == @intFromEnum(posix.SIG.QUIT)) {
                    ev.addPass(.QUIT);
                } else if (si.signo == @intFromEnum(posix.SIG.USR1)) {
                    ev.addPass(.USR1);
                } else if (si.signo == @intFromEnum(posix.SIG.USR2)) {
                    ev.addPass(.USR2);
                } else if (si.signo == @intFromEnum(posix.SIG.WINCH)) {
                    ev.addPass(.WINCH);
                }
            }
            if (count < buf.len) return ev;
        }
    }
};

// ---------------------------------------------------------------- tests

test "signalfd observes a blocked, raised SIGTERM" {
    var old: posix.sigset_t = undefined;
    posix.sigprocmask(posix.SIG.BLOCK, null, &old);
    defer posix.sigprocmask(posix.SIG.SETMASK, &old, null);

    var sigs = try Signals.init();
    defer _ = linux.close(sigs.fd);

    try posix.raise(.TERM);
    const ev = sigs.drain();
    try std.testing.expectEqual(@as(?posix.SIG, .TERM), ev.term_or_int);
    try std.testing.expect(!ev.chld);

    // drained: a second read reports nothing
    const ev2 = sigs.drain();
    try std.testing.expectEqual(@as(?posix.SIG, null), ev2.term_or_int);
}
