//! The on-screen app path: open an SDL3 window and PRESENT a painted surface to
//! it. This is the browser's window entrypoint (ADR-0003), NOT the test path:
//! SDL3 is linked into the app executable ONLY, so the headless golden-image
//! tests (which render into a `Surface` and never open a window) do not depend
//! on SDL at all. A future SDL+GL/Skia compositor replaces THIS file; the seam
//! and the `Surface` it presents are unchanged.
//!
//! The flow is deliberately simple for v0: lay out a fixture, paint it into an
//! offscreen `Surface` with `StbSoftwareBackend` (the SAME surface the goldens
//! use), then upload that surface as a texture and present it each frame until
//! the window is closed. No GPU-accelerated compositing yet.

const std = @import("std");
const wezig = @import("wezig");

const c = @cImport({
    @cInclude("SDL3/SDL.h");
});

const Surface = wezig.surface.Surface;

/// Open a window of `surf`'s size titled `title`, blit `surf` into it, and run
/// the event loop until the user closes the window. Returns after the window is
/// closed. Errors if SDL initialisation or window/renderer/texture creation
/// fails.
pub fn showSurface(title: [*:0]const u8, surf: *const Surface) !void {
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return error.SdlInit;
    defer c.SDL_Quit();

    var window: ?*c.SDL_Window = null;
    var renderer: ?*c.SDL_Renderer = null;
    if (!c.SDL_CreateWindowAndRenderer(
        title,
        @intCast(surf.width),
        @intCast(surf.height),
        0,
        &window,
        &renderer,
    )) return error.SdlWindow;
    defer c.SDL_DestroyWindow(window);

    // Our surface is R,G,B,A in memory order; on a little-endian host that is
    // SDL's ABGR8888 (= RGBA32) byte layout.
    const texture = c.SDL_CreateTexture(
        renderer,
        c.SDL_PIXELFORMAT_ABGR8888,
        c.SDL_TEXTUREACCESS_STREAMING,
        @intCast(surf.width),
        @intCast(surf.height),
    ) orelse return error.SdlTexture;
    defer c.SDL_DestroyTexture(texture);

    if (!c.SDL_UpdateTexture(texture, null, surf.pixels.ptr, @intCast(surf.width * 4))) {
        return error.SdlUpload;
    }

    var running = true;
    while (running) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            if (event.type == c.SDL_EVENT_QUIT) running = false;
        }
        _ = c.SDL_RenderClear(renderer);
        _ = c.SDL_RenderTexture(renderer, texture, null, null);
        _ = c.SDL_RenderPresent(renderer);
        c.SDL_Delay(16);
    }
}
