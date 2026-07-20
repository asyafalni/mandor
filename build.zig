const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug info from the binary") orelse
        (optimize != .Debug);

    // Version stamped into the binary; overridable in CI: -Dversion=v0.15.0.
    const version = b.option([]const u8, "version", "Version string") orelse "0.15.0-dev";
    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "version", version);

    const exe = b.addExecutable(.{
        .name = "mandor",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            // No error-return-trace tables: errors are handled, not dumped.
            .error_tracing = false,
        }),
    });
    exe.root_module.addOptions("build_options", build_opts);
    b.installArtifact(exe);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    // Real crash output seeded into the fuzz harness. Referenced only from
    // `test` blocks, so nothing lands in the shipped binary.
    for ([_][]const u8{ "go", "rust", "python", "node", "java", "zig" }) |lang| {
        exe_tests.root_module.addAnonymousImport(b.fmt("fixture_{s}", .{lang}), .{
            .root_source_file = b.path(b.fmt("test/fixtures/{s}.txt", .{lang})),
        });
    }
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);
}
