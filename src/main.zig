//! The app entrypoint: render a v0 page fragment to an offscreen `Surface` with
//! the software paint backend and PRESENT it in an on-screen SDL3 window (see
//! `sdl.zig`). This is the "a real page fragment appears on screen" milestone
//! path. It reuses the SAME `renderScene` the headless golden-image tests
//! assert on, so what the window shows is exactly what the goldens pin.
//!
//! Run with `zig build run`. The window stays open until closed. The display
//! name is read from the single branding source of truth, never hard-coded.

const std = @import("std");
const wezig = @import("wezig");
const sdl = @import("sdl.zig");

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    // Paint the v0 page-fragment fixture into an offscreen surface (the same
    // scene the golden tests pin), then show it on screen.
    const scene = wezig.paint.golden_scenes[wezig.paint.golden_scenes.len - 1];
    var surf = try wezig.paint.renderScene(gpa, scene);
    defer surf.deinit();

    const title = try gpa.dupeZ(u8, wezig.branding.display_name);
    defer gpa.free(title);
    sdl.showSurface(title, &surf) catch |err| {
        // A headless environment (no display) can't open a window; report it
        // rather than crash. The paint itself already succeeded offscreen.
        std.log.err("could not open a window ({s}); the page painted offscreen but cannot be shown here.", .{@errorName(err)});
        return err;
    };
}
