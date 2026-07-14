//! PROTOTYPE — throwaway. Delete once it has answered its question.
//!
//! QUESTION (ADR-0004): can we open an opaque on-screen window and present the
//! SAME painted `Surface` WITHOUT SDL — using only native OS bindings from pure
//! Zig? This binds Xlib directly via `@cImport(<X11/Xlib.h>)` and links ONLY the
//! OS's own `libX11` (no third-party windowing library). It is the concrete
//! counterpart to SDL's `src/sdl.zig`, to feel the raw-native path before
//! committing to any long-term windowing choice.
//!
//! Run:  zig build proto-x11        (see prototypes/build_proto.zig usage below)
//! or:   zig run prototypes/x11_window.zig --dep wezig ... -lX11   (fiddly; use the step)
//!
//! It renders the same app-sized page fragment via `wezig.paint.renderScene`,
//! then blits it to an X11 window with `XPutImage` and runs a minimal event
//! loop until the window is closed (WM_DELETE_WINDOW) or a key is pressed.
//!
//! NOT production: no error handling beyond runnable, no HiDPI, no input beyond
//! close, X11 only (XWayland presents it on Wayland). The point is to prove the
//! plumbing, not to be a backend.
//!
//! VERDICT (answered 2026-07-14): YES. This opens an opaque window and presents
//! the same `renderScene` Surface with NO SDL; `ldd` shows it links only libc +
//! libX11 (and X11's transport libs), never SDL. Swapping SDL -> X11 touched
//! ZERO engine/paint/test code, which validates the `PaintBackend` seam
//! (ADR-0002/0003): the engine output is windowing-agnostic. Takeaways: (1)
//! "remove linking" is not achievable (X11 is still an OS lib), but "remove the
//! third-party windowing lib" IS; (2) the cost is per-platform (~130 lines for
//! ONE platform; a real native stack repeats this for Wayland/Win32/Cocoa, which
//! is why `mach` exists); (3) papercuts: X11 wants BGRA channel order (we swap
//! R<->B) and `XDestroyImage` is a fn-ptr macro `@cImport` can't call (we use
//! `XFree` + detach). Kept as a living starting point for a future native
//! backend per ADR-0004. See `docs/adr/0004-windowing-sdl-as-v0-leaf-native-as-target.md`.

const std = @import("std");
const wezig = @import("wezig");

const x = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
});

const window_w: u32 = 800;
const window_h: u32 = 600;

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    // Same scene the SDL app entrypoint paints: a full-window opaque page
    // fragment through the SAME renderScene seam. This is the whole point: the
    // engine output (a `Surface`) is windowing-agnostic; only the present path
    // below is native X11 instead of SDL.
    const scene = wezig.paint.GoldenScene{
        .name = "proto-x11",
        .html_src = "<body><p>wezig paints text (native X11, no SDL)</p></body>",
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

    // --- native X11: open a display + a simple window (links only libX11) ---
    const dpy = x.XOpenDisplay(null) orelse {
        std.log.err("cannot open X display (is DISPLAY set / XWayland running?)", .{});
        return error.NoDisplay;
    };
    defer _ = x.XCloseDisplay(dpy);

    const screen = x.XDefaultScreen(dpy);
    const root = x.XRootWindow(dpy, screen);
    const depth = x.XDefaultDepth(dpy, screen);
    const visual = x.XDefaultVisual(dpy, screen);

    const win = x.XCreateSimpleWindow(
        dpy,
        root,
        0,
        0,
        window_w,
        window_h,
        0,
        x.XBlackPixel(dpy, screen),
        x.XWhitePixel(dpy, screen),
    );
    const title = try gpa.dupeZ(u8, wezig.branding.display_name);
    defer gpa.free(title);
    _ = x.XStoreName(dpy, win, title.ptr);
    _ = x.XSelectInput(dpy, win, x.ExposureMask | x.KeyPressMask | x.StructureNotifyMask);

    // Let the WM tell us when the user closes the window.
    var wm_delete = x.XInternAtom(dpy, "WM_DELETE_WINDOW", x.False);
    _ = x.XSetWMProtocols(dpy, win, &wm_delete, 1);
    _ = x.XMapWindow(dpy, win);

    // Wrap our RGBA surface bytes in an XImage. X wants the visual's channel
    // order; on a typical little-endian TrueColor display that is BGRA in
    // memory. Our surface is RGBA, so swap R<->B into a scratch buffer.
    const buf = try gpa.alloc(u8, surf.pixels.len);
    defer gpa.free(buf);
    swapRB(surf.pixels, buf);

    const img = x.XCreateImage(
        dpy,
        visual,
        @intCast(depth),
        x.ZPixmap,
        0,
        buf.ptr,
        window_w,
        window_h,
        32,
        0,
    ) orelse return error.XImage;
    // XDestroyImage would free `buf` (which WE own via the allocator). Detach the
    // data pointer, then free only the XImage struct with XFree. (Avoids the
    // destroy_image function-pointer macro too.)
    defer {
        img.*.data = null;
        _ = x.XFree(img);
    }

    const gc = x.XDefaultGC(dpy, screen);

    var running = true;
    while (running) {
        var ev: x.XEvent = undefined;
        _ = x.XNextEvent(dpy, &ev);
        switch (ev.type) {
            x.Expose => {
                _ = x.XPutImage(dpy, win, gc, img, 0, 0, 0, 0, window_w, window_h);
            },
            x.KeyPress => running = false,
            x.ClientMessage => {
                // WM_DELETE_WINDOW: the [0] data long is the atom.
                if (@as(x.Atom, @intCast(ev.xclient.data.l[0])) == wm_delete) running = false;
            },
            else => {},
        }
    }
}

/// Swap R and B channels (RGBA -> BGRA) for X11 TrueColor visuals. Alpha byte is
/// carried through unchanged; X ignores it on a 24-bit-depth visual (opaque).
fn swapRB(srcpix: []const u8, dst: []u8) void {
    var i: usize = 0;
    while (i + 3 < srcpix.len) : (i += 4) {
        dst[i + 0] = srcpix[i + 2]; // B
        dst[i + 1] = srcpix[i + 1]; // G
        dst[i + 2] = srcpix[i + 0]; // R
        dst[i + 3] = srcpix[i + 3]; // A (ignored by X at depth 24)
    }
}
