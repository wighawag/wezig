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

    // `zig build test` runs the module's `test` blocks.
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
