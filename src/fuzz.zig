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
const config = @import("config.zig");
const sampler = @import("sampler.zig");
const elf = @import("elf.zig");
const history = @import("history.zig");
const report = @import("report.zig");
const cost = @import("cost.zig");
const capture = @import("capture.zig");
const cli = @import("cli.zig");

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
    \\health = ["api=/bin/check"]
    \\start_after = ["worker=api"]
    \\env = ["api=PORT=8080"]
    \\user = ["api=1000:1000"]
    \\max_rss_mb = ["api=768"]
    \\
;

const stat_seed = "1234 (my (evil) worker) S 1 1234 1234 0 -1 4194560 900 0 0 0 12 5 0 0 20 0 3 0 8400 12582912 512";
const psi_seed = "some avg10=0.00 avg60=12.34 avg300=0.00 total=1234\nfull avg10=0.00 avg60=5.00 avg300=0.00 total=99";
const history_seed = "{\"v\":2,\"entries\":[{\"sig\":123,\"first\":100,\"last\":200,\"count\":3,\"builds\":2,\"fb\":\"v1.0.0\",\"lb\":\"v1.0.1\"}]}";
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
    _ = sampler.parseStat(text);
    _ = sampler.parsePsiAvg60(text);
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

fn ignoreLine(_: void, _: []const u8, _: u8) void {}

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

test "fuzz: capture reassembles arbitrary chunk boundaries" {
    var p = prng();
    const rnd = p.random();
    for (0..iterations) |i| {
        const seed = corpus[i % corpus.len];
        captureTarget(rnd, mutate(rnd, seed, &buf));
    }
}
