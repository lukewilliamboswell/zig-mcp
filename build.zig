const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zig-mcp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run zig-mcp server");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // CI lint tools
    const tidy_exe = b.addExecutable(.{
        .name = "tidy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ci/tidy.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const tidy_cmd = b.addRunArtifact(tidy_exe);
    tidy_cmd.setCwd(b.path("."));

    const zig_lints_exe = b.addExecutable(.{
        .name = "zig_lints",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ci/zig_lints.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const zig_lints_cmd = b.addRunArtifact(zig_lints_exe);
    zig_lints_cmd.setCwd(b.path("."));

    // `zig build lint` — run CI lint checks
    const lint_step = b.step("lint", "Run CI lint checks");
    lint_step.dependOn(&tidy_cmd.step);
    lint_step.dependOn(&zig_lints_cmd.step);

    // Wire lints into `zig build test`
    test_step.dependOn(&tidy_cmd.step);
    test_step.dependOn(&zig_lints_cmd.step);
}
