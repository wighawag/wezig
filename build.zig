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

    // --- Paint backend C dependency: stb_truetype (ADR-0003) -------------
    // stb_truetype is a public-domain single-header library vendored under
    // `src/vendor/`. It is glyph rasterisation ONLY (no window), so it links
    // into the LIBRARY module: the `StbSoftwareBackend` and the HEADLESS
    // golden-image tests use it with no SDL/window involved. `link_libc`
    // satisfies stb's malloc/free/math needs through Zig's bundled libc.
    mod.addIncludePath(b.path("src/vendor"));
    mod.addCSourceFile(.{ .file = b.path("src/vendor/stb_truetype_impl.c") });
    mod.link_libc = true;

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
    // --- Window/present C dependency: SDL3 (ADR-0003) --------------------
    // SDL3 (built from source via the `sdl` dependency, no system SDL) is
    // linked into the APP EXECUTABLE only: it is the on-screen window/input/
    // present path (the app entrypoint), NOT the test path. Keeping SDL out
    // of the library module is what keeps the golden-image tests headless and
    // CI-safe. `linkLibrary` also propagates SDL3's headers so `main.zig`'s
    // `@cInclude("SDL3/SDL.h")` resolves.
    const sdl_dep = b.dependency("sdl", .{ .target = target, .optimize = optimize });
    exe.root_module.linkLibrary(sdl_dep.artifact("SDL3"));

    b.installArtifact(exe);

    // `zig build run` builds and runs the executable (forwarding `-- args`).
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // `zig build gen-goldens` regenerates the committed golden reference PNGs
    // (ADR-0003). It is a MAINTENANCE step, not part of `test`: the golden
    // tests compare against the committed PNGs, and this step is how you refresh
    // them after an intentional raster change. It reuses the same `renderScene`
    // path the tests assert on, so the references stay self-consistent.
    const gen_goldens = b.addExecutable(.{
        .name = "gen-goldens",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_goldens.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "wezig", .module = mod }},
        }),
    });
    const run_gen = b.addRunArtifact(gen_goldens);
    run_gen.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_gen.addArgs(args);
    const gen_step = b.step("gen-goldens", "Regenerate committed golden reference PNGs");
    gen_step.dependOn(&run_gen.step);

    // `zig build test` runs the library's and executable's `test` blocks.
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
