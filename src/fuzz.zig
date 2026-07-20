//! Mutational property harness over every parser that eats untrusted input.
//!
//! Threat model: a worker's stderr, its ELF header, the config file, /proc
//! text, and mandor's own state files are all attacker- or corruption-
//! influenced. A panic in any of them is not a parse failure — it kills PID 1,
//! which kills the container. These tests assert only one property: **no input
//! panics**. Return values are deliberately ignored.
//!
//! Why not `std.testing.fuzz`: coverage-guided fuzzing is broken in the pinned
//! Zig 0.16.0 (the fuzz-mode test runner fails to compile with error tracing
//! on, and instruments zero PCs with it off). Mutating a real crash corpus is
//! a better fit here regardless — random bytes would essentially never produce
//! `goroutine 1 [running]:`, so the seeds matter more than the guidance. Each
//! target is a plain `fn (bytes) void`, so wiring the real fuzzer in later is
//! a one-line change per target.
//!
//! Seeds vary per run (`std.testing.random_seed`); the test runner prints the
//! seed, and `zig build test -- --seed=0x…` replays a failure exactly.

const std = @import("std");

const summarize = @import("summarize.zig");
const spool = @import("spool.zig");
const config = @import("config.zig");
const sampler = @import("sampler.zig");
const elf = @import("elf.zig");
const history = @import("history.zig");
const report = @import("report.zig");
const cost = @import("cost.zig");
const capture = @import("capture.zig");
const cli = @import("cli.zig");
const ring = @import("ring.zig");
const backoff = @import("backoff.zig");

/// Real crash output — the seeds worth mutating. Doubles as the fixture set
/// CLAUDE.md calls for.
/// Wired as anonymous imports in build.zig — `test/fixtures/` sits outside
/// the module root, so a relative @embedFile path cannot reach it.
const corpus = [_][]const u8{
    @embedFile("fixture_go"),
    @embedFile("fixture_rust"),
    @embedFile("fixture_python"),
    @embedFile("fixture_node"),
    @embedFile("fixture_java"),
    @embedFile("fixture_zig"),
};

/// A config that exercises every key, used as the TOML seed.
const config_seed =
    \\restart = "on-failure"
    \\metrics_port = 9464
    \\state_dir = "/var/lib/mandor"
    \\stop_grace = "10s"
    \\photon = "127.0.0.1:4318"
    \\psi_mem_pct = 80
    \\workers = [
    \\  "./api --port 8080",
    \\  "./worker",
    \\]
    \\
    \\[worker.api]
    \\health = "/bin/check"
    \\env = ["PORT=8080", "LOG=debug"]
    \\cwd = "/srv"
    \\user = "1000:1000"
    \\max_rss_mb = 768
    \\essential = true
    \\
    \\[worker.worker]
    \\start_after = "api"
    \\restart = "never"
    \\
;

const stat_seed = "1234 (my (evil) worker) S 1 1234 1234 0 -1 4194560 900 0 0 0 12 5 0 0 20 0 3 0 8400 12582912 512";
const psi_seed = "some avg10=0.00 avg60=12.34 avg300=0.00 total=1234\nfull avg10=0.00 avg60=5.00 avg300=0.00 total=99";
// Must match history.serialize byte-for-byte in shape: the loader keys off the
// literal `{"sig":"` prefix and a fixed 16-digit hex field. A seed in any other
// shape silently matches nothing and fuzzes an early return.
const history_seed = "{\"v\":2,\"entries\":[" ++
    "{\"sig\":\"00000000deadbeef\",\"first\":1700000000,\"last\":1700009999,\"count\":3,\"builds\":2,\"fb\":\"v1.0.0\",\"lb\":\"v1.0.1\"}," ++
    "{\"sig\":\"ffffffffffffffff\",\"first\":1,\"last\":2,\"count\":1,\"builds\":0,\"fb\":\"\",\"lb\":\"\"}]}";
const cost_seed = "{\"v\":1,\"workers\":[{\"name\":\"api\",\"obs\":600,\"rss\":[1,2,3],\"cpu\":[4,5,6]}]}";
const report_seed = "{\"v\":1,\"now\":1000,\"workers\":[{\"name\":\"api\",\"pid\":42,\"state\":\"running\",\"restarts\":3,\"rss_kb\":2048,\"cpu_pct\":12}]}";

// --------------------------------------------------------------- mutation

const max_input = 16 * 1024;

/// Splice, truncate, corrupt, and bloat a seed. Structure-preserving edits
/// (line duplication/removal) sit alongside byte-level noise so the mutant
/// still reaches deep parser states instead of bouncing off the first check.
fn mutate(rnd: std.Random, src: []const u8, out: *[max_input]u8) []u8 {
    // Explicit usize: @min against a comptime bound would narrow this to u15.
    var len: usize = @min(src.len, max_input);
    @memcpy(out[0..len], src[0..len]);

    const rounds = rnd.intRangeAtMost(usize, 1, 8);
    for (0..rounds) |_| {
        if (len == 0) break;
        switch (rnd.intRangeLessThan(u8, 0, 10)) {
            // Truncate — every parser must survive a half-written line.
            0 => len = rnd.intRangeAtMost(usize, 0, len),
            // Flip a byte.
            1 => out[rnd.uintLessThan(usize, len)] = rnd.int(u8),
            // Overwrite a run with a single byte (long-token stress).
            2 => {
                const at = rnd.uintLessThan(usize, len);
                const n = @min(len - at, rnd.intRangeAtMost(usize, 1, 512));
                @memset(out[at..][0..n], rnd.int(u8));
            },
            // Delete a range.
            3 => {
                const at = rnd.uintLessThan(usize, len);
                const n = @min(len - at, rnd.intRangeAtMost(usize, 1, 256));
                std.mem.copyForwards(u8, out[at .. len - n], out[at + n .. len]);
                len -= n;
            },
            // Insert noise.
            4 => {
                const at = rnd.uintLessThan(usize, len);
                const n = @min(max_input - len, rnd.intRangeAtMost(usize, 1, 256));
                std.mem.copyBackwards(u8, out[at + n .. len + n], out[at..len]);
                for (out[at..][0..n]) |*b| b.* = rnd.int(u8);
                len += n;
            },
            // Splice a second corpus entry in.
            5 => {
                const other = corpus[rnd.uintLessThan(usize, corpus.len)];
                const n = @min(max_input - len, other.len);
                @memcpy(out[len..][0..n], other[0..n]);
                len += n;
            },
            // Duplicate the buffer (repeated frames / restart storms).
            6 => {
                const n = @min(max_input - len, len);
                @memcpy(out[len..][0..n], out[0..n]);
                len += n;
            },
            // Strip all newlines — one enormous line.
            7 => {
                var w: usize = 0;
                for (out[0..len]) |c| {
                    if (c == '\n') continue;
                    out[w] = c;
                    w += 1;
                }
                len = w;
            },
            // Plant a boundary integer. Uniform byte flips almost never set the
            // high bits of a u64 offset, so overflow paths stay unexplored
            // without this — measured: it took detection of a known ELF
            // overflow from 1-in-5 runs to every run.
            8 => {
                const val = interesting[rnd.uintLessThan(usize, interesting.len)];
                const width = @as(usize, 1) << @intCast(rnd.intRangeAtMost(u8, 1, 3)); // 2, 4, or 8
                if (len >= width) {
                    const at = rnd.uintLessThan(usize, len - width + 1);
                    switch (width) {
                        2 => std.mem.writeInt(u16, out[at..][0..2], @truncate(val), .little),
                        4 => std.mem.writeInt(u32, out[at..][0..4], @truncate(val), .little),
                        else => std.mem.writeInt(u64, out[at..][0..8], val, .little),
                    }
                }
            },
            // Splat a syntactically loaded byte — long digit runs, quote and
            // bracket storms are what break text parsers.
            9 => {
                const at = rnd.uintLessThan(usize, len);
                const n = @min(len - at, rnd.intRangeAtMost(usize, 1, 512));
                const spicy = "0123456789\"'[]{}:=,.\\\t\n";
                @memset(out[at..][0..n], spicy[rnd.uintLessThan(usize, spicy.len)]);
            },
            else => unreachable,
        }
    }
    return out[0..len];
}

/// Boundary values worth planting verbatim, in the spirit of a libFuzzer
/// dictionary: overflow triggers and off-by-one edges.
const interesting = [_]u64{
    0,
    1,
    std.math.maxInt(u8),
    std.math.maxInt(u16),
    std.math.maxInt(u32),
    std.math.maxInt(u64),
    std.math.maxInt(u64) - 8,
    std.math.maxInt(u64) - 64,
    std.math.maxInt(u63),
    1 << 31,
    1 << 63,
};

// ---------------------------------------------------------------- targets
//
// Each target takes raw bytes and must not panic. Results are ignored: the
// property under test is survival, not correctness.

const max_lines = 256;
var line_storage: [max_lines]summarize.LogLine = undefined;

fn splitLines(text: []const u8) []const summarize.LogLine {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (n == max_lines) break;
        line_storage[n] = .{
            .text = line[0..@min(line.len, capture.max_line)],
            .flags = @truncate(n),
            .t_ms = n * 100,
        };
        n += 1;
    }
    return line_storage[0..n];
}

var trace_storage: summarize.TraceStorage = .{};
var diag_buf: [512]u8 = undefined;
var compactor: summarize.Compactor(32, 128) = .{};

/// Worker stderr: the trace parsers, the verdict engine, and log compaction.
fn traceTarget(text: []const u8) void {
    const lines = splitLines(text);
    const trace = summarize.extractTrace(lines, &trace_storage);
    _ = summarize.diagnose(&diag_buf, "signal:SIGSEGV", trace, lines, &.{}, 42, true);
    _ = summarize.firstErrorLine(lines);
    _ = summarize.signature("exit", "api", summarize.firstErrorLine(lines));
    compactor.reset();
    for (lines) |l| compactor.feed(l.text, l.flags, l.t_ms);
}

var cmd_storage: [cli.max_workers][]const u8 = undefined;

fn configTarget(text: []const u8) void {
    _ = config.parse(text, &cmd_storage) catch return;
}

fn procTarget(text: []const u8) void {
    const fields = sampler.parseStat(text);
    _ = sampler.parsePsiAvg60(text);
    // Feed parsed /proc values onward the way sample() does. parseStat yields
    // whatever the text held, so the consumers must survive it too.
    if (fields) |f| {
        const ticks = f.utime +| f.stime;
        _ = sampler.cpuPct(ticks / 2, ticks, 5000);
        _ = sampler.cpuPct(0, ticks, 1);
    }
}

var elf_out: [64]u8 = undefined;

fn elfTarget(bytes: []const u8) void {
    _ = elf.parseBuildId(bytes, &elf_out);
}

/// Pick a field value: usually plausible, sometimes a boundary, sometimes
/// noise. Keeping most fields coherent is the point — an ELF whose every
/// field is garbage dies at the first bounds check and tests nothing.
fn fieldValue(rnd: std.Random, plausible: u64) u64 {
    return switch (rnd.intRangeLessThan(u8, 0, 4)) {
        0, 1 => plausible,
        2 => interesting[rnd.uintLessThan(usize, interesting.len)],
        else => rnd.int(u64),
    };
}

/// Structured ELF generator. Byte-flipping a header almost never preserves the
/// several fields that must stay coherent to reach the offset arithmetic
/// (phentsize >= 56, phnum >= 1, a PT_NOTE entry), so each field is drawn
/// independently instead.
fn genElf(rnd: std.Random, out: *[max_input]u8) []u8 {
    const len = @min(max_input, rnd.intRangeAtMost(usize, 64, 2048));
    @memset(out[0..len], 0);
    @memcpy(out[0..4], "\x7fELF");
    out[4] = 2;
    out[5] = 1;

    const phoff = fieldValue(rnd, 64);
    const phentsize = fieldValue(rnd, 56);
    const phnum = fieldValue(rnd, rnd.intRangeAtMost(u64, 1, 4));
    std.mem.writeInt(u64, out[32..40], phoff, .little);
    std.mem.writeInt(u16, out[54..56], @truncate(phentsize), .little);
    std.mem.writeInt(u16, out[56..58], @truncate(phnum), .little);

    // Program headers at the plausible offset, whether or not e_phoff agrees.
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const off = 64 + i * 56;
        if (off + 56 > len) break;
        std.mem.writeInt(u32, out[off..][0..4], if (rnd.boolean()) 4 else rnd.int(u32), .little);
        std.mem.writeInt(u64, out[off + 8 ..][0..8], fieldValue(rnd, 320), .little);
        std.mem.writeInt(u64, out[off + 32 ..][0..8], fieldValue(rnd, 32), .little);
    }

    // A note block at the offset the plausible p_offset points at.
    if (len >= 320 + 32) {
        std.mem.writeInt(u32, out[320..324], @truncate(fieldValue(rnd, 4)), .little);
        std.mem.writeInt(u32, out[324..328], @truncate(fieldValue(rnd, 8)), .little);
        std.mem.writeInt(u32, out[328..332], if (rnd.boolean()) 3 else rnd.int(u32), .little);
        @memcpy(out[332..336], "GNU\x00");
    }
    return out[0..len];
}

fn historyTarget(text: []const u8) void {
    history.loadFromText(text);
}

var fmt_buf: [64 * 1024]u8 = undefined;

/// mandor's own state files — a corrupt or truncated state dir must not crash
/// `mandor report`.
fn stateTarget(text: []const u8) void {
    _ = report.formatHuman(&fmt_buf, text, 1_000_000, null);
    _ = report.formatHuman(&fmt_buf, text, 1_000_000, "api");
    _ = report.scanStr(text, "name");
    _ = report.scanU64(text, "pid");
    _ = cost.formatHuman(&fmt_buf, text);
}

var tok_buf: [8192]u8 = undefined;
var argv_out: [64][]const u8 = undefined;
var arg_slots: [16][]const u8 = undefined;

/// argv and command-string tokenization. Not hostile in practice, but a
/// malformed flag or an unterminated quote must fail cleanly, not trap.
fn cliTarget(text: []const u8) void {
    _ = cli.tokenize(text, &tok_buf, &argv_out) catch {};
    // Feed the mutant as argv too, split on whitespace.
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, text, " \t\n");
    while (it.next()) |a| {
        if (n == arg_slots.len) break;
        arg_slots[n] = a;
        n += 1;
    }
    _ = cli.parse(arg_slots[0..n], &cmd_storage) catch {};
}

const cli_seed =
    "--restart=on-failure --backoff-max=30s --stop-grace=10s --metrics=9464 " ++
    "--health=api=/bin/check --expected-exit=143,129 --max-restarts=5 " ++
    "--ready-fd=3 --state-dir=/var/lib/mandor --incident=2 -- " ++
    "'./api --port 8080' \"./worker -v\"";

fn ignoreLine(_: void, _: []const u8, _: u8) void {}

// The two targets below assert invariants rather than mere survival — these
// are pure functions with contracts worth pinning, not parsers.

/// Backoff must never exceed the configured cap, on any path.
fn backoffTarget(rnd: std.Random) !void {
    const prev = if (rnd.boolean()) 0 else rnd.int(u64);
    const uptime = if (rnd.boolean()) rnd.intRangeAtMost(u64, 0, 20_000) else rnd.int(u64);
    const max_ms = if (rnd.boolean()) rnd.intRangeAtMost(u64, 0, 60_000) else rnd.int(u64);
    const d = backoff.next(prev, uptime, max_ms);
    try std.testing.expect(d <= max_ms);
}

/// Cost accumulators persist in cost.json across restarts, so a corrupt file
/// can seed any counter at its clamped maximum; the next sampler tick then
/// increments it. Start from arbitrary state and keep ticking.
fn costTarget(rnd: std.Random) void {
    var p: cost.Profile = .{};
    p.idle_n = rnd.int(u32);
    p.active_n = rnd.int(u32);
    p.core_ms = rnd.int(u64);
    p.rss_kb_ms = rnd.int(u64);
    p.peak_rss_kb = rnd.int(u64);
    for (&p.rss_idle) |*c| c.* = rnd.int(u32);
    for (&p.rss_active) |*c| c.* = rnd.int(u32);
    for (&p.cpu_active) |*c| c.* = rnd.int(u32);
    for (0..4) |_| {
        p.update(rnd.int(u64), rnd.int(u16), rnd.int(u16), rnd.int(u16), rnd.int(u64), rnd.int(u64));
    }
    _ = p.summary();
}

var bundle_out: [128 * 1024]u8 = undefined;
var log_lines: [8]summarize.CompactLine = undefined;
var samples: [8]sampler.Sample = undefined;

/// The incident-bundle serializer — the contract photon and the premium agent
/// parse. Epoch fields are calendar math on an arbitrary i64, and one of them
/// (`history_first_epoch`) can arrive clamped to maxInt(i64) straight out of a
/// corrupt history.json.
fn bundleTarget(rnd: std.Random, text: []const u8) void {
    const epoch = [_]i64{
        0,                        1,            -1, std.math.maxInt(i64), std.math.minInt(i64),
        std.math.maxInt(i64) - 1, rnd.int(i64),
    };
    const pick = struct {
        fn s(r: std.Random, t: []const u8) []const u8 {
            if (t.len == 0) return "";
            const a = r.uintLessThan(usize, t.len);
            return t[a..@min(t.len, a + r.uintLessThan(usize, 256) + 1)];
        }
    };

    for (&log_lines, 0..) |*l, i| l.* = .{
        .text = pick.s(rnd, text),
        .flags = @truncate(i),
        .first_t_ms = rnd.int(u64),
        .last_t_ms = rnd.int(u64),
        .count = rnd.int(u32),
    };
    for (&samples) |*s| s.* = .{
        .t_ms = rnd.int(u64),
        .rss_kb = rnd.int(u64),
        .cpu_pct = rnd.int(u16),
        .fds = rnd.int(u16),
        .threads = rnd.int(u16),
    };

    _ = spool.serialize(&bundle_out, .{
        .ts_epoch = epoch[rnd.uintLessThan(usize, epoch.len)],
        .name = pick.s(rnd, text),
        .cmd = pick.s(rnd, text),
        .pid = rnd.int(i32),
        .restarts = rnd.int(u32),
        .cwd = pick.s(rnd, text),
        .exe = pick.s(rnd, text),
        .spawned_at_epoch = epoch[rnd.uintLessThan(usize, epoch.len)],
        .uptime_s = rnd.int(u64),
        .release = pick.s(rnd, text),
        .build_id = pick.s(rnd, text),
        .limits_nofile = rnd.int(u64),
        .limits_core = rnd.int(u64),
        .cause = .{ .kind = "signal", .sig_num = rnd.int(u8) },
        .cause_str = pick.s(rnd, text),
        .trace = .{ .lang = "go", .raw = pick.s(rnd, text) },
        .logs_tail = log_lines[0..rnd.uintLessThan(usize, log_lines.len + 1)],
        .logs_dropped = rnd.int(u32),
        .stats = samples[0..rnd.uintLessThan(usize, samples.len + 1)],
        .now_ms = rnd.int(u64),
        .history_sig = rnd.int(u64),
        .history_first_epoch = epoch[rnd.uintLessThan(usize, epoch.len)],
        .history_count = rnd.int(u32),
        .history_builds = rnd.int(u32),
        .history_first_build = pick.s(rnd, text),
        .history_last_build = pick.s(rnd, text),
        .verdict = pick.s(rnd, text),
    });
}

const RingT = ring.Ring(1024);
var ring_copy: [4096]u8 = undefined;

/// Random push/evict/iterate traffic against the capture hot-path buffer.
/// Invariants: accounting stays consistent and every stored record reads back.
fn ringTarget(rnd: std.Random, text: []const u8) !void {
    var r: RingT = .{};
    var pos: usize = 0;
    while (pos < text.len) {
        const n = @min(text.len - pos, rnd.intRangeAtMost(usize, 0, 5000));
        _ = r.push(text[pos..][0..n], rnd.int(u8), rnd.int(u64));
        pos += n + 1;

        if (rnd.intRangeLessThan(u8, 0, 8) == 0) {
            var seen: usize = 0;
            var it = r.iterate(&ring_copy);
            while (it.next()) |rec| {
                seen += 1;
                try std.testing.expect(rec.line.len <= 4095);
            }
            try std.testing.expectEqual(r.count(), seen);
        }
    }
}

/// The capture hot path: line reassembly across arbitrary read boundaries.
fn captureTarget(rnd: std.Random, text: []const u8) void {
    var asm_state: capture.Assembler = .{};
    var pos: usize = 0;
    while (pos < text.len) {
        const n = @min(text.len - pos, rnd.intRangeAtMost(usize, 1, 4096));
        asm_state.feed(1, text[pos..][0..n], {}, ignoreLine);
        pos += n;
    }
}

// ------------------------------------------------------------------ tests

const iterations = 3000;

var buf: [max_input]u8 = undefined;

fn prng() std.Random.DefaultPrng {
    return std.Random.DefaultPrng.init(std.testing.random_seed);
}

test "fuzz: trace parsers survive mutated crash output" {
    var p = prng();
    const rnd = p.random();
    for (0..iterations) |i| {
        const seed = corpus[i % corpus.len];
        traceTarget(mutate(rnd, seed, &buf));
    }
}

test "fuzz: config parser survives mutated toml" {
    var p = prng();
    const rnd = p.random();
    for (0..iterations) |_| configTarget(mutate(rnd, config_seed, &buf));
}

test "fuzz: /proc parsers survive mutated stat and pressure text" {
    var p = prng();
    const rnd = p.random();
    for (0..iterations) |i| {
        const seed = if (i % 2 == 0) stat_seed else psi_seed;
        procTarget(mutate(rnd, seed, &buf));
    }
}

test "fuzz: elf build-id parser survives hostile headers" {
    var p = prng();
    const rnd = p.random();
    for (0..iterations) |i| {
        // Mostly structured; every fourth mutant is byte-mangled too, so
        // truncation and magic-check paths still get exercised.
        const gen = genElf(rnd, &buf);
        if (i % 4 == 0) {
            var mutated: [max_input]u8 = undefined;
            @memcpy(mutated[0..gen.len], gen);
            elfTarget(mutate(rnd, mutated[0..gen.len], &buf));
        } else {
            elfTarget(gen);
        }
    }
}

test "fuzz: state-file loaders survive corruption" {
    var p = prng();
    const rnd = p.random();
    for (0..iterations) |i| {
        const seed = switch (i % 3) {
            0 => report_seed,
            1 => cost_seed,
            else => history_seed,
        };
        stateTarget(mutate(rnd, seed, &buf));
        if (i % 3 == 2) historyTarget(mutate(rnd, history_seed, &buf));
    }
}

test "fuzz: cli flags and command tokenization survive garbage" {
    var p = prng();
    const rnd = p.random();
    for (0..iterations) |_| cliTarget(mutate(rnd, cli_seed, &buf));
}

test "fuzz: cpuPct survives extreme tick counts" {
    var p = prng();
    const rnd = p.random();
    for (0..iterations) |_| {
        // /proc values are kernel-generated, but parseStat will hand back
        // whatever the text held, so the consumer must not trap on it.
        _ = sampler.cpuPct(rnd.int(u64), rnd.int(u64), rnd.int(u64));
        _ = sampler.cpuPct(0, std.math.maxInt(u64), rnd.intRangeAtMost(u64, 1, 10_000));
    }
}

test "fuzz: cost accumulators survive a corrupt reload plus more ticks" {
    var p = prng();
    const rnd = p.random();
    for (0..iterations) |_| costTarget(rnd);
}

test "fuzz: bundle serializer survives adversarial input" {
    var p = prng();
    const rnd = p.random();
    for (0..iterations) |i| {
        const seed = corpus[i % corpus.len];
        bundleTarget(rnd, mutate(rnd, seed, &buf));
    }
}

test "fuzz: backoff never exceeds the configured cap" {
    var p = prng();
    const rnd = p.random();
    for (0..iterations) |_| try backoffTarget(rnd);
}

test "fuzz: ring buffer accounting survives random traffic" {
    var p = prng();
    const rnd = p.random();
    for (0..iterations) |i| {
        const seed = corpus[i % corpus.len];
        try ringTarget(rnd, mutate(rnd, seed, &buf));
    }
}

test "fuzz: capture reassembles arbitrary chunk boundaries" {
    var p = prng();
    const rnd = p.random();
    for (0..iterations) |i| {
        const seed = corpus[i % corpus.len];
        captureTarget(rnd, mutate(rnd, seed, &buf));
    }
}
