//! Entrypoint for the webview shell executable (ADR-0005 tracer bullet).
//!
//! One executable, two modes, chosen at build time by the `shell_options.smoke`
//! flag so the two build steps share exactly one binding + one window path:
//!   - `zig build shell`      -> smoke = false -> `runShell` (interactive).
//!   - `zig build shell-test` -> smoke = true  -> `smokeTest` (headless verify,
//!                                                run under `xvfb-run`).
//! WebKitGTK is linked ONLY into THIS executable; the `wezig` library, the v0
//! SDL app, and the golden tests never see it (see `build.zig`).

const std = @import("std");
const shell = @import("shell.zig");
const options = @import("shell_options");

pub fn main() !void {
    if (options.smoke) {
        var gpa_state: std.heap.DebugAllocator(.{}) = .init;
        defer _ = gpa_state.deinit();
        shell.smokeTest(gpa_state.allocator()) catch |err| {
            std.log.err("shell smoke test FAILED: {s}", .{@errorName(err)});
            return err;
        };
        std.log.info("shell smoke test PASSED: page loaded and snapshot is non-blank.", .{});
    } else {
        shell.runShell() catch |err| {
            std.log.err("could not run the webview shell ({s}); is a display available?", .{@errorName(err)});
            return err;
        };
    }
}
