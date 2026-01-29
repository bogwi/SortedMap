const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    _ = b.addModule(
        "SortedMap",
        .{ .root_source_file = b.path("src/sorted_map.zig") },
    );

    // Library artifact removed - use the module directly instead

    // BENCH
    const bench = b.addExecutable(.{
        .name = "SortedMap_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const bench_run = b.addRunArtifact(bench);
    if (b.args) |args| {
        bench_run.addArgs(args);
    }
    const bench_step = b.step("bench", "Run benchmark");
    bench_step.dependOn(&bench_run.step);

    // TEST
    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sorted_map.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    const run_main_tests = b.addRunArtifact(main_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
}
