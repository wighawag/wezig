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

    // --- Webview SHELL: WebKitGTK 6.0 / GTK4 (ADR-0005 tracer bullet) -----
    // The `Renderer`-seam exploration's thin vertical spike: a GTK4 window
    // hosting a `WebKitWebView` that loads one real, interactive page. Like
    // SDL (above), the webview is an on-screen host path, so it links into a
    // NEW shell executable ONLY -- NEVER the `wezig` library module. That is
    // what keeps the v0 SDL render path and the headless golden tests (which
    // live in the library) completely free of WebKitGTK, and keeps the core
    // `zig build test` gate display-free. Unlike SDL (built from source), this
    // is a SYSTEM dependency: `linkSystemLibrary("webkitgtk-6.0")` resolves it
    // (and GTK4 + GLib) via pkg-config. Requires `libwebkitgtk-6.0-dev`.
    //
    // `shell_options.smoke` selects the mode: the interactive `shell` step and
    // the headless `shell-test` step share ONE binding and ONE window path.
    const shell_opts_interactive = b.addOptions();
    shell_opts_interactive.addOption(bool, "smoke", false);
    const shell_opts_smoke = b.addOptions();
    shell_opts_smoke.addOption(bool, "smoke", true);

    // The interactive shell executable (`zig build shell`).
    const shell_exe = b.addExecutable(.{
        .name = "wezig-shell",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shell_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "wezig", .module = mod }},
        }),
    });
    shell_exe.root_module.addImport("shell_options", shell_opts_interactive.createModule());
    shell_exe.root_module.link_libc = true;
    // WebKitGTK's `@cImport` bridge (`src/webkit_c.h`) lives in `src/`.
    shell_exe.root_module.addIncludePath(b.path("src"));
    // pkg-config resolves webkitgtk-6.0 + GTK4 + GLib headers and libs.
    shell_exe.root_module.linkSystemLibrary("webkitgtk-6.0", .{});
    const run_shell = b.addRunArtifact(shell_exe);
    const shell_step = b.step("shell", "Open the WebKitGTK webview shell window (ADR-0005)");
    shell_step.dependOn(&run_shell.step);

    // The SAME shell binary in smoke mode (`zig build shell-test`). Kept OUT of
    // `zig build test` on purpose: WebKitGTK has NO native headless mode and
    // `GtkOffscreenWindow` does not work with a WebView (WebKit bug #76911), so
    // this MUST run under a virtual X display. We wrap it in `xvfb-run` so the
    // step is self-contained. NOTE: `xvfb` (`xvfb-run`) is a SYSTEM PROVISION
    // this step needs and is NOT yet installed on the dev box or in CI; until
    // `xvfb` is provisioned this step will fail to find `xvfb-run`. The
    // interactive `zig build shell` step above does NOT need Xvfb.
    const shell_test_exe = b.addExecutable(.{
        .name = "wezig-shell-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/shell_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "wezig", .module = mod }},
        }),
    });
    shell_test_exe.root_module.addImport("shell_options", shell_opts_smoke.createModule());
    shell_test_exe.root_module.link_libc = true;
    shell_test_exe.root_module.addIncludePath(b.path("src"));
    shell_test_exe.root_module.linkSystemLibrary("webkitgtk-6.0", .{});
    // `xvfb-run -a <binary>`: -a picks a free display number automatically.
    const run_shell_test = b.addSystemCommand(&.{ "xvfb-run", "-a" });
    run_shell_test.addArtifactArg(shell_test_exe);
    run_shell_test.expectExitCode(0);
    const shell_test_step = b.step("shell-test", "Headless WebKitGTK smoke test under Xvfb (needs xvfb-run; NOT in `test`)");
    shell_test_step.dependOn(&run_shell_test.step);

    // --- PROTOTYPE (throwaway, ADR-0004): a native X11 window with NO SDL ---
    // `zig build proto-x11` builds prototypes/x11_window.zig, which presents the
    // same `renderScene` Surface via Xlib, linking ONLY the OS's libX11. It is
    // deliberately NOT part of `installArtifact`/`test`; delete this block and
    // prototypes/ once the windowing question is settled.
    const proto_x11 = b.addExecutable(.{
        .name = "proto-x11",
        .root_module = b.createModule(.{
            .root_source_file = b.path("prototypes/x11_window.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "wezig", .module = mod }},
        }),
    });
    proto_x11.root_module.link_libc = true;
    proto_x11.root_module.linkSystemLibrary("X11", .{});
    const run_proto = b.addRunArtifact(proto_x11);
    const proto_step = b.step("proto-x11", "PROTOTYPE: native X11 window, no SDL (ADR-0004)");
    proto_step.dependOn(&run_proto.step);

    // `zig build test` runs the library's and executable's `test` blocks.
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
