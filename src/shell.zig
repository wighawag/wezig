//! The webview SHELL path: open a GTK4 window hosting a `WebKitWebView` and
//! load one real, interactive page. This is the tracer bullet for the
//! `Renderer` seam exploration (ADR-0005, spec `explore-webview-shell`): proof
//! that WebKitGTK 6.0 renders a real page from Zig. It is NOT a browser and NOT
//! the seam itself yet; those are follow-on tasks. It is the webview twin of
//! `sdl.zig`: an on-screen host path linked ONLY into the shell executable, so
//! the v0 SDL render path and the headless golden tests never see WebKitGTK.
//!
//! Two entrypoints, mirroring the two build steps:
//!   - `runShell`  (`zig build shell`)      opens the window interactively.
//!   - `smokeTest` (`zig build shell-test`) drives it headlessly under Xvfb:
//!     load a page, wait for the load-finished signal, snapshot the view, and
//!     assert the snapshot is non-blank. WebKitGTK has NO native headless mode
//!     and `GtkOffscreenWindow` does not work with a WebView (WebKit bug
//!     #76911), so a virtual X display (`xvfb-run`) is the supported approach;
//!     `smokeTest` therefore still needs a (virtual) display, which is why it
//!     is its OWN build step and NOT part of `zig build test`.
//!
//! The GTK4/WebKit binding comes through `webkit_c.h` (see that header for why
//! a thin translate-c shim is needed instead of a bare `@cInclude`).

const std = @import("std");
const wezig = @import("wezig");

const c = @cImport({
    @cDefine("__GI_SCANNER__", "1");
    @cDefine("GTK_COMPILATION", "1");
    @cInclude("webkit_c.h");
});

/// The interactive shell's default page. A real, networked URL so the human can
/// verify the three interactions the acceptance criteria call for: scroll,
/// click a link, and type into a field.
const default_url = "https://example.com/";

/// The headless smoke test's page. A self-contained `data:` document (no
/// network, so the test is deterministic offline) with an opaque coloured
/// background and text, so a correct render produces a decisively non-blank
/// snapshot.
const smoke_page =
    "data:text/html," ++
    "<body style='margin:0;background:%23204080;color:%23ffffff;font:48px sans-serif'>" ++
    "<h1>wezig webview shell</h1><p>hello, window</p></body>";

/// Window size for the shell. A real, comfortable size (not the goldens' tiny
/// sizes), like `main.zig`'s on-screen window.
const window_w: c_int = 1024;
const window_h: c_int = 768;

/// Errors the shell can report to its caller (the shell executable's `main`).
pub const ShellError = error{
    /// GTK could not initialise (e.g. no display / no `$DISPLAY`, and no Xvfb).
    GtkInit,
    /// The page reported a load FAILURE (network error, bad URL, ...).
    LoadFailed,
    /// `webkit_web_view_get_snapshot` returned no texture.
    SnapshotFailed,
    /// The snapshot came back but every pixel was blank (nothing rendered).
    SnapshotBlank,
    /// The smoke run finished the main loop without ever reaching a verdict.
    NoResult,
    /// Could not allocate the pixel buffer for the snapshot scan.
    OutOfMemory,
};

/// Initialise GTK4, returning false (rather than aborting like `gtk_init`) when
/// there is no usable display, so the caller can report a clean error in a
/// headless environment with no Xvfb.
fn gtkInit() bool {
    return c.gtk_init_check() != 0;
}

/// `g_signal_connect` is a macro over `g_signal_connect_data`; replicate it.
fn signalConnect(instance: c.gpointer, detailed_signal: [*:0]const u8, handler: c.GCallback, data: c.gpointer) void {
    _ = c.g_signal_connect_data(instance, detailed_signal, handler, data, null, 0);
}

/// Build a GTK4 window hosting a `WebKitWebView` sized to the window and
/// loading `uri`. Shared by both entrypoints. Returns the window and view.
fn buildWindow(uri: [*:0]const u8) struct { window: *c.GtkWindow, view: *c.WebKitWebView } {
    const window: *c.GtkWindow = @ptrCast(c.gtk_window_new());
    c.gtk_window_set_default_size(window, window_w, window_h);
    const title = wezig.branding.display_name ++ " — webview shell";
    c.gtk_window_set_title(window, title);

    const view: *c.WebKitWebView = @ptrCast(c.webkit_web_view_new());
    c.gtk_window_set_child(window, @ptrCast(view));
    c.webkit_web_view_load_uri(view, uri);

    return .{ .window = window, .view = view };
}

// --- Interactive entrypoint (`zig build shell`) --------------------------

/// Open the window and run the GTK main loop until the user closes it. This is
/// the `zig build shell` path: a real, interactive page (scroll, click a link,
/// type into a field). Requires a real display; returns `error.GtkInit` in a
/// headless environment with no Xvfb.
pub fn runShell() ShellError!void {
    if (!gtkInit()) return error.GtkInit;

    const w = buildWindow(default_url);
    // Quit the process-wide main loop when the window is closed.
    signalConnect(@ptrCast(w.window), "destroy", @ptrCast(&onDestroyQuit), null);
    c.gtk_window_present(w.window);

    // GTK4 dropped `gtk_main`; drive the default context directly until the
    // window's "destroy" handler tears it down.
    running = true;
    while (running) {
        _ = c.g_main_context_iteration(null, 1); // may_block = TRUE
    }
}

var running: bool = false;

fn onDestroyQuit(_: *c.GtkWidget, _: c.gpointer) callconv(.c) void {
    running = false;
}

// --- Headless smoke test (`zig build shell-test`, under xvfb-run) --------

/// Shared state the smoke test's GTK callbacks hand back to `smokeTest`.
const Smoke = struct {
    loop: *c.GMainLoop,
    view: *c.WebKitWebView,
    /// Set once a verdict is reached; `smokeTest` reads it after the loop ends.
    result: ShellError!void = error.NoResult,
    /// The pixel scan's allocator (freed by `smokeTest`).
    gpa: std.mem.Allocator,
};

/// Drive the shell headlessly and verify it rendered. Intended to run under a
/// virtual display (`xvfb-run zig build shell-test`). Loads `smoke_page`, waits
/// for the load-finished signal, snapshots the view, and asserts the snapshot
/// is non-blank. Returns the verdict; the shell executable turns it into an
/// exit code.
pub fn smokeTest(gpa: std.mem.Allocator) ShellError!void {
    if (!gtkInit()) return error.GtkInit;

    const loop = c.g_main_loop_new(null, 0) orelse return error.NoResult;
    defer c.g_main_loop_unref(loop);

    const w = buildWindow(smoke_page);
    // A WebView must be mapped on a (virtual) display to render; present it.
    c.gtk_window_present(w.window);

    var smoke = Smoke{ .loop = loop, .view = w.view, .gpa = gpa };
    signalConnect(@ptrCast(w.view), "load-changed", @ptrCast(&onLoadChanged), &smoke);

    // Safety net: if the load never finishes, stop the loop after a while so
    // the test fails loudly instead of hanging CI.
    _ = c.g_timeout_add_seconds(30, @ptrCast(&onTimeout), &smoke);

    c.g_main_loop_run(loop);
    return smoke.result;
}

fn onTimeout(data: c.gpointer) callconv(.c) c.gboolean {
    const smoke: *Smoke = @ptrCast(@alignCast(data));
    smoke.result = error.LoadFailed;
    c.g_main_loop_quit(smoke.loop);
    return 0; // G_SOURCE_REMOVE
}

fn onLoadChanged(_: *c.WebKitWebView, load_event: c.WebKitLoadEvent, data: c.gpointer) callconv(.c) void {
    const smoke: *Smoke = @ptrCast(@alignCast(data));
    if (load_event != c.WEBKIT_LOAD_FINISHED) return;
    // Page finished loading: request a snapshot of the visible region.
    c.webkit_web_view_get_snapshot(
        smoke.view,
        c.WEBKIT_SNAPSHOT_REGION_VISIBLE,
        c.WEBKIT_SNAPSHOT_OPTIONS_NONE,
        null,
        @ptrCast(&onSnapshotReady),
        data,
    );
}

fn onSnapshotReady(source: c.gpointer, res: *c.GAsyncResult, data: c.gpointer) callconv(.c) void {
    const smoke: *Smoke = @ptrCast(@alignCast(data));
    const view: *c.WebKitWebView = @ptrCast(@alignCast(source));

    var err: ?*c.GError = null;
    const texture = c.webkit_web_view_get_snapshot_finish(view, res, &err);
    if (texture == null) {
        if (err) |e| c.g_error_free(e);
        smoke.result = error.SnapshotFailed;
        c.g_main_loop_quit(smoke.loop);
        return;
    }
    defer c.g_object_unref(texture);

    smoke.result = scanNonBlank(smoke.gpa, texture.?);
    c.g_main_loop_quit(smoke.loop);
}

/// Download the snapshot texture's pixels and assert at least one non-blank
/// pixel. A blank snapshot (every pixel identical, or fully transparent) means
/// nothing rendered; a page with an opaque background and text does not produce
/// that. Returns `error.SnapshotBlank` if the whole image is uniform.
fn scanNonBlank(gpa: std.mem.Allocator, texture: *c.GdkTexture) ShellError!void {
    const width: usize = @intCast(c.gdk_texture_get_width(texture));
    const height: usize = @intCast(c.gdk_texture_get_height(texture));
    if (width == 0 or height == 0) return error.SnapshotBlank;

    const stride = width * 4; // GdkTexture downloads as 8-bit RGBA/BGRA.
    const buf = gpa.alloc(u8, stride * height) catch return error.OutOfMemory;
    defer gpa.free(buf);

    c.gdk_texture_download(texture, buf.ptr, stride);

    // Non-blank == not every pixel is identical. A rendered page (coloured
    // background + text) has at least two distinct pixel values; a blank/failed
    // render is a single uniform colour (or all-zero).
    const first = std.mem.bytesToValue(u32, buf[0..4]);
    var i: usize = 4;
    while (i + 4 <= buf.len) : (i += 4) {
        if (std.mem.bytesToValue(u32, buf[i..][0..4]) != first) return; // non-blank
    }
    return error.SnapshotBlank;
}
