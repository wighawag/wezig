const std = @import("std");

// Build graph for the project. v0 is a single library module (`wezig`) with a
// test step; later tasks EXTEND this file additively (register their own
// modules, and for paint link SDL3), so keep additions local and avoid
// rewriting the shape below.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The public library module. Consumers import it as `@import("wezig")`.
    // Later subsystem tasks re-export from `src/root.zig`.
    const mod = b.addModule("wezig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Minimal executable so `zig build run` launches something real. Its root
    // module imports the library above; the CLI/UI grows in later tasks.
    const exe = b.addExecutable(.{
        .name = "wezig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "wezig", .module = mod }},
        }),
    });
    b.installArtifact(exe);

    // `zig build run` builds and runs the executable (forwarding `-- args`).
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` runs the library's and executable's `test` blocks.
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
