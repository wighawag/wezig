//! The app entrypoint: render a v0 page fragment to an offscreen `Surface` with
//! the software paint backend and PRESENT it in an on-screen SDL3 window (see
//! `sdl.zig`). This is the "a real page fragment appears on screen" milestone
//! path. It paints through the SAME `renderScene` seam the headless golden
//! tests use, so the on-screen result is produced by exactly the same pipeline.
//!
//! Run with `zig build run`. The window stays open until closed. The display
//! name is read from the single branding source of truth, never hard-coded.

const std = @import("std");
const wezig = @import("wezig");
const sdl = @import("sdl.zig");

/// The on-screen window size. This is deliberately a REAL window size, NOT one
/// of the `golden_scenes` (those are kept small so their reference PNGs stay
/// maintainable). At the golden scenes' tiny sizes the window falls below the
/// compositor's minimum width and the un-painted strip shows the desktop, so
/// the app renders its own full-window scene instead.
const window_w: u32 = 800;
const window_h: u32 = 600;

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    // The app's own page-fragment scene, sized to the window. The background
    // fills the ENTIRE surface (opaque) so the whole window is painted; text is
    // laid out and painted through the same `renderScene` seam as the goldens.
    const scene = wezig.paint.GoldenScene{
        .name = "app",
        .html_src = "<body><p>wezig paints text</p></body>",
        .css_src = "p { font-size: 16px; }",
        .viewport = @floatFromInt(window_w),
        .w = window_w,
        .h = window_h,
        .background = .{
            .rect = .{ .x = 0, .y = 0, .w = @floatFromInt(window_w), .h = @floatFromInt(window_h) },
            .color = .{ .r = 250, .g = 248, .b = 240 },
        },
        .text_color = .{ .r = 30, .g = 30, .b = 40 },
    };
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
