//! Entrypoint for the webview shell executable (ADR-0005/0006). It stands up
//! the minimal chrome over the two seams (`Renderer` + `Toolkit`); the wiring
//! and headless verification live in `shell.zig`.
//!
//! One executable, several modes, chosen at build time by the
//! `shell_options.mode` string so every build step shares exactly one set of
//! bindings + one window path:
//!   - `zig build shell`             -> "interactive" -> `runShell`.
//!   - `zig build shell-test`        -> "smoke"       -> `smokeTest` (headless
//!                                       navigate + snapshot; under `xvfb-run`).
//!   - `zig build shell-bridge-test` -> "bridge"      -> `bridgeTest` (headless
//!                                       script-message bridge proof; xvfb).
//!   - `zig build shell-scheme-test` -> "scheme"      -> `schemeTest` (headless
//!                                       custom-scheme interception proof; xvfb).
//!   - `zig build ipfs-secure-origin-test` -> "ipfs-secure" ->
//!                                       `ipfsSecureOriginTest` (headless secure-
//!                                       origin seam-extension proof; xvfb).
//! WebKitGTK/GTK are linked ONLY into THIS executable; the `wezig` library, the
//! v0 SDL app, and the golden tests never see them (see `build.zig`).

const std = @import("std");
const shell = @import("shell.zig");
const options = @import("shell_options");

/// The selected mode. A build-time string keeps ONE selector for N modes (vs a
/// fan of booleans); each build step sets exactly one value.
const Mode = enum { interactive, smoke, bridge, scheme, @"ipfs-secure" };

pub fn main() !void {
    const mode = std.meta.stringToEnum(Mode, options.mode) orelse {
        std.log.err("unknown shell mode '{s}'", .{options.mode});
        return error.UnknownShellMode;
    };
    switch (mode) {
        .interactive => shell.runShell() catch |err| {
            std.log.err("could not run the webview shell ({s}); is a display available?", .{@errorName(err)});
            return err;
        },
        .smoke => try runVerify("smoke", shell.smokeTest, "page loaded and snapshot is non-blank"),
        .bridge => try runVerify("bridge", shell.bridgeTest, "script-message bridge round-tripped both ways"),
        .scheme => try runVerify("scheme", shell.schemeTest, "custom scheme served from native and rendered"),
        .@"ipfs-secure" => try runVerify("ipfs-secure", shell.ipfsSecureOriginTest, "ipfs:// declared a secure origin at the seam and a CID body served+rendered on it"),
    }
}

/// Run one headless verification mode, logging a uniform PASS/FAIL line and
/// turning its verdict into the process exit code.
fn runVerify(
    name: []const u8,
    verify: *const fn (std.mem.Allocator) shell.ShellError!void,
    pass_msg: []const u8,
) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    verify(gpa_state.allocator()) catch |err| {
        std.log.err("shell {s} test FAILED: {s}", .{ name, @errorName(err) });
        return err;
    };
    std.log.info("shell {s} test PASSED: {s}.", .{ name, pass_msg });
}
