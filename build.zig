const std = @import("std");
const builtin = @import("builtin");

// The Zig version this project builds with lives in EXACTLY ONE place in the
// tree: `build.zig.zon`'s `.minimum_zig_version`. We import the manifest at
// comptime and parse that string, so `build.zig` holds NO second copy of the
// number — change the pin in one file and both the manifest floor and the guard
// below move together. (The CI/release `setup-zig` `version:` in
// `.github/workflows/` is the only other mention; it provisions the toolchain
// and is checked BY this guard at build time, so a drift there fails the build.)
//
// `minimum_zig_version` alone is only a FLOOR (it rejects a too-OLD compiler);
// it does nothing about a too-NEW one, and Zig's language/std/build API churn
// between minors means a mismatched local compiler fails cryptically or passes
// against different behaviour. `assertZigVersion` below closes that gap: it runs
// under whatever `zig` the caller actually invoked and refuses any non-matching
// minor with an actionable message. This is why dropping the `zvm`-pinned
// launcher from `dorfl.json` is safe — the toolchain is pinned by the build
// itself, so `zig build` is correct regardless of HOW zig got onto PATH.
const pinned_zig = std.SemanticVersion.parse(@import("build.zig.zon").minimum_zig_version) catch unreachable;

/// Fail fast if the running Zig's major.minor differs from `pinned_zig`. Patch
/// differences are allowed (0.16.x is fine); a different minor (0.15/0.17) or
/// major is rejected with the exact version to install.
fn assertZigVersion() void {
    const running = builtin.zig_version;
    if (running.major != pinned_zig.major or running.minor != pinned_zig.minor) {
        std.debug.print(
            "\nwezig requires Zig {d}.{d}.x, but this is Zig {f}.\n" ++
                "Install the pinned version (see build.zig.zon .minimum_zig_version)\n" ++
                "and re-run. CI/release pin it via setup-zig; locally use any\n" ++
                "install (a manager or a tarball) that puts Zig {d}.{d}.x on PATH.\n\n",
            .{ pinned_zig.major, pinned_zig.minor, running, pinned_zig.major, pinned_zig.minor },
        );
        std.process.exit(1);
    }
}

// Build graph for the project. v0 is a single library module (`wezig`) with a
// test step; later tasks EXTEND this file additively (register their own
// modules, and for paint link SDL3), so keep additions local and avoid
// rewriting the shape below.
pub fn build(b: *std.Build) void {
    // Pin the toolchain at the build itself (see `pinned_zig` above): reject a
    // mismatched local Zig before doing any work, with a clear message.
    assertZigVersion();

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

    // --- Webview SHELL: WebKitGTK 6.0 / GTK4 (ADR-0005/0006, two seams) ----
    // The webview shell: a minimal chrome (window + URL bar + back/forward)
    // driving a real page through TWO seams -- the `Renderer` seam (content;
    // `SystemWebviewRenderer` on WebKitGTK) and the `Toolkit` seam (chrome
    // host + windowing; `GtkToolkit` on GTK4). Both backend files + the shell's
    // smoke snapshot are the ONLY WebKitGTK/GTK touchers; the chrome talks to
    // the seams alone. Like SDL (above), these are on-screen host paths, so
    // they link into the shell executables ONLY -- NEVER the `wezig` library
    // module. That keeps the v0 SDL render path and the headless golden tests
    // (which live in the library) completely free of WebKitGTK/GTK, and keeps
    // the core `zig build test` gate display-free (the seam-contract tests use
    // fake in-memory backends and run inside `zig build test`). Unlike SDL
    // (built from source), this is a SYSTEM dependency:
    // `linkSystemLibrary("webkitgtk-6.0")` resolves it (and GTK4 + GLib) via
    // pkg-config. Requires `libwebkitgtk-6.0-dev`. The two backend files
    // (`system_webview_renderer.zig`, `gtk_toolkit.zig`) are pulled in
    // transitively via `shell.zig`, so no extra `addImport` is needed.
    //
    // `shell_options.mode` selects the mode: the interactive `shell` step and
    // the headless verification steps (`shell-test`, `shell-bridge-test`,
    // `shell-scheme-test`) all share ONE set of bindings and ONE chrome. A
    // small local helper builds the shell exe for a given mode so the four
    // steps stay identical except for that one option + (for the verify steps)
    // the `xvfb-run` wrapper.
    const ShellBuild = struct {
        b: *std.Build,
        mod: *std.Build.Module,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        fn make(self: @This(), name: []const u8, mode: []const u8) *std.Build.Step.Compile {
            const opts = self.b.addOptions();
            opts.addOption([]const u8, "mode", mode);
            const e = self.b.addExecutable(.{
                .name = name,
                .root_module = self.b.createModule(.{
                    .root_source_file = self.b.path("src/shell_main.zig"),
                    .target = self.target,
                    .optimize = self.optimize,
                    .imports = &.{.{ .name = "wezig", .module = self.mod }},
                }),
            });
            e.root_module.addImport("shell_options", opts.createModule());
            e.root_module.link_libc = true;
            // WebKitGTK's `@cImport` bridge (`src/webkit_c.h`) lives in `src/`.
            e.root_module.addIncludePath(self.b.path("src"));
            // pkg-config resolves webkitgtk-6.0 + GTK4 + GLib headers and libs.
            e.root_module.linkSystemLibrary("webkitgtk-6.0", .{});
            return e;
        }
    };
    const shell_build = ShellBuild{ .b = b, .mod = mod, .target = target, .optimize = optimize };

    // The interactive shell executable (`zig build shell`).
    const shell_exe = shell_build.make("wezig-shell", "interactive");
    const run_shell = b.addRunArtifact(shell_exe);
    const shell_step = b.step("shell", "Open the webview shell (minimal chrome over the two seams; ADR-0005/0006)");
    shell_step.dependOn(&run_shell.step);

    // The headless verification steps. All are kept OUT of `zig build test` on
    // purpose: WebKitGTK has NO native headless mode and `GtkOffscreenWindow`
    // does not work with a WebView (WebKit bug #76911), so they MUST run under a
    // virtual X display. Each wraps the shell binary (in its own mode) in
    // `xvfb-run` so the step is self-contained. `xvfb` (`xvfb-run`) is a SYSTEM
    // PROVISION these steps need; it is installed on the dev box. The
    // interactive `zig build shell` step above does NOT need Xvfb.
    //
    //   - `shell-test`        navigates THROUGH the `Renderer` seam, asserts the
    //                         seam's `.finished` lifecycle event reached a
    //                         subscriber, and snapshots the view non-blank.
    //   - `shell-bridge-test` proves the seam's script-message bridge hook
    //                         (ADR-0005) round-trips both ways through the real
    //                         WebKitGTK backend (`window.wezig.ping`).
    //   - `shell-scheme-test` proves the seam's custom-scheme interception hook
    //                         (ADR-0005) serves a native body that renders
    //                         (`wezig-test://hello`).
    // The seam-CONTRACT tests (both hooks exist + round-trip through a fake
    // backend) live in `renderer.zig`'s `zig build test` block; these prove the
    // real backend.
    const VerifyStep = struct {
        name: []const u8,
        exe_name: []const u8,
        mode: []const u8,
        desc: []const u8,
    };
    const verify_steps = [_]VerifyStep{
        .{ .name = "shell-test", .exe_name = "wezig-shell-test", .mode = "smoke", .desc = "Headless WebKitGTK smoke test under Xvfb (needs xvfb-run; NOT in `test`)" },
        .{ .name = "shell-bridge-test", .exe_name = "wezig-shell-bridge-test", .mode = "bridge", .desc = "Headless script-message bridge proof under Xvfb (ADR-0005; NOT in `test`)" },
        .{ .name = "shell-scheme-test", .exe_name = "wezig-shell-scheme-test", .mode = "scheme", .desc = "Headless custom-scheme interception proof under Xvfb (ADR-0005; NOT in `test`)" },
    };
    for (verify_steps) |vs| {
        const vexe = shell_build.make(vs.exe_name, vs.mode);
        // `xvfb-run -a <binary>`: -a picks a free display number automatically.
        const run_v = b.addSystemCommand(&.{ "xvfb-run", "-a" });
        run_v.addArtifactArg(vexe);
        run_v.expectExitCode(0);
        const step = b.step(vs.name, vs.desc);
        step.dependOn(&run_v.step);
    }

    // --- MOBILE static libraries (ADR-0008 split Toolkit; explore-mobile-shell) --
    // On mobile the Zig core builds a STATIC LIBRARY (`libwezig_mobile.a`) that
    // an OS-native shell hosts and calls through the C-ABI in `src/mobile_abi.zig`
    // (iOS: Swift/Xcode over a bridging header; Android: a JNI shim over the NDK).
    // These steps CROSS-COMPILE that lib for the mobile target triples; they are
    // additive and OUT of the desktop `zig build`/`zig build test` gate (they take
    // an explicit `-Dmobile-target=...`), so the desktop path is untouched. The
    // native app packaging + on-device/simulator RUN lives in the per-platform CI
    // legs (`.github/workflows/mobile-*.yml`), not here.
    //
    // Usage: `zig build ios-lib -Dmobile-target=aarch64-ios-simulator`
    //        `zig build android-lib -Dmobile-target=aarch64-linux-android`
    // The mobile target is a build option (not the host `-Dtarget`) so the desktop
    // artifacts keep resolving from the host target with no cross-compile.
    const mobile_target_str = b.option(
        []const u8,
        "mobile-target",
        "Target triple for the mobile static lib steps (e.g. aarch64-ios-simulator)",
    );
    // The mobile C dependency (stb_truetype) needs the target platform's libc
    // headers (`math.h` etc.), which Zig does NOT bundle for iOS/Android: they
    // come from the platform SDK sysroot. `-Dmobile-sysroot=<path>` points the C
    // compile at that sysroot's headers/libs:
    //   iOS:     $(xcrun --sdk iphonesimulator --show-sdk-path)
    //   Android: <NDK>/toolchains/llvm/prebuilt/<host>/sysroot
    // Absent it, the pure-Zig code still cross-compiles, but the stb C dep fails
    // on the missing libc headers — exactly the gap the toolchain tasks close.
    const mobile_sysroot = b.option(
        []const u8,
        "mobile-sysroot",
        "Platform SDK sysroot for the mobile static lib's C deps (iOS SDK path / Android NDK sysroot)",
    );
    // Android's NDK sysroot puts ARCH-specific headers (e.g. <asm/types.h>) under
    // `usr/include/<triple>` (e.g. usr/include/aarch64-linux-android), separate
    // from the shared `usr/include`. iOS has no such split. When set, this adds
    // that arch include dir so bionic's <linux/types.h> -> <asm/types.h> resolves.
    const mobile_sysroot_arch_include = b.option(
        []const u8,
        "mobile-sysroot-arch-include",
        "Extra arch-specific include dir under the sysroot (Android NDK: the <triple> subdir of usr/include)",
    );
    const MobileLib = struct {
        b: *std.Build,
        mobile_target_str: ?[]const u8,
        mobile_sysroot: ?[]const u8,
        mobile_sysroot_arch_include: ?[]const u8,
        fn make(self: @This(), step_name: []const u8, desc: []const u8, default_triple: []const u8) void {
            const triple = self.mobile_target_str orelse default_triple;
            const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch |err| {
                std.debug.panic("invalid -Dmobile-target '{s}': {s}", .{ triple, @errorName(err) });
            };
            const resolved = self.b.resolveTargetQuery(query);
            // The mobile lib re-imports the library sources at the mobile target
            // (NOT the desktop `mod`, which is resolved for the host). It links
            // libc for stb_truetype and vendors stb, exactly like `mod`.
            //
            // Force ReleaseSafe (NOT the desktop `optimize`, which defaults to
            // Debug): a Debug build pulls in Zig's stack-unwinding/`SelfInfo`
            // symbolication, which references host-runtime symbols the mobile
            // link cannot resolve statically — `__dyld_get_image_header_...` on
            // iOS (dyld) and `__tls_get_addr` on x86_64 Android. ReleaseSafe keeps
            // safety checks but drops that debug machinery, so the static archive
            // stays self-contained across all mobile targets (and is the right
            // mode for a shipped mobile core anyway).
            const lib_mod = self.b.createModule(.{
                .root_source_file = self.b.path("src/root.zig"),
                .target = resolved,
                .optimize = .ReleaseSafe,
                // Strip debug info + the stack-trace/`SelfInfo` symbolication it
                // pulls: even in ReleaseSafe, a panic path references
                // `debug.writeCurrentStackTrace` -> `__dyld_get_image_header_...`
                // (iOS) which the static mobile link cannot resolve. Stripping
                // removes that machinery; a mobile core reports through the seam,
                // not a host stack dump.
                .strip = true,
                // Disable the stack-probe helper (`__zig_probe_stack`) the NDK
                // link does not provide; the mobile lib does not need guard-page
                // stack probing.
                .stack_check = false,
                .stack_protector = false,
            });
            lib_mod.addIncludePath(self.b.path("src/vendor"));
            // Disable UBSan on the vendored C source for mobile: Zig's default
            // debug UBSan emits `__ubsan_handle_*` calls whose runtime the iOS
            // SDK does not ship for static linking (the desktop/Android builds
            // resolve it, iOS does not). stb_truetype is well-exercised C; the
            // toolchain proof does not need C UBSan. Keeps the archive
            // self-contained across all mobile targets.
            lib_mod.addCSourceFile(.{
                .file = self.b.path("src/vendor/stb_truetype_impl.c"),
                .flags = &.{"-fno-sanitize=undefined"},
            });
            lib_mod.link_libc = true;
            // Point the C compile at the platform SDK's libc headers (math.h),
            // which Zig does not bundle for iOS/Android. `<sysroot>/usr/include`
            // is the iOS SDK layout; the Android NDK sysroot uses the same
            // `usr/include` root, so one form covers both.
            if (self.mobile_sysroot) |sysroot| {
                lib_mod.addSystemIncludePath(.{ .cwd_relative = self.b.pathJoin(&.{ sysroot, "usr", "include" }) });
                // Android NDK: also make the arch-specific headers dir resolvable
                // for <asm/*.h>. Absolute path if given, else <sysroot>/usr/include/<name>.
                if (self.mobile_sysroot_arch_include) |arch_inc| {
                    const path = if (std.fs.path.isAbsolute(arch_inc))
                        arch_inc
                    else
                        self.b.pathJoin(&.{ sysroot, "usr", "include", arch_inc });
                    lib_mod.addSystemIncludePath(.{ .cwd_relative = path });
                }
            }
            const lib = self.b.addLibrary(.{
                .name = "wezig_mobile",
                .root_module = lib_mod,
                .linkage = .static,
            });
            const install = self.b.addInstallArtifact(lib, .{});
            const step = self.b.step(step_name, desc);
            step.dependOn(&install.step);
        }
    };
    const mobile_lib = MobileLib{ .b = b, .mobile_target_str = mobile_target_str, .mobile_sysroot = mobile_sysroot, .mobile_sysroot_arch_include = mobile_sysroot_arch_include };
    mobile_lib.make("ios-lib", "Cross-compile the wezig mobile static lib for iOS (-Dmobile-target, default aarch64-ios-simulator)", "aarch64-ios-simulator");
    mobile_lib.make("android-lib", "Cross-compile the wezig mobile static lib for Android (-Dmobile-target, default aarch64-linux-android)", "aarch64-linux-android");

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
