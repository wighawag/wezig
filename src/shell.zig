//! The webview SHELL path: stand up the minimal chrome (one window, URL bar,
//! back/forward) driving a real page THROUGH the two seams (ADR-0005, ADR-0006,
//! spec `explore-webview-shell`). This file is the SHELL exe's wiring + its
//! headless smoke verification; it owns NO seam logic itself:
//!
//!   - the `Renderer` seam (content) is `renderer.zig`, implemented by
//!     `SystemWebviewRenderer` (WebKitGTK) in `system_webview_renderer.zig`;
//!   - the chrome/toolkit seam (chrome host + windowing) is `toolkit.zig`,
//!     implemented by `GtkToolkit` (GTK4) in `gtk_toolkit.zig`;
//!   - the minimal chrome that talks ONLY to those two seams is `chrome.zig`.
//!
//! WebKitGTK/GTK are touched ONLY by the two backend files + this file's smoke
//! snapshot (WebKit has no seam-level snapshot API yet); the chrome never sees
//! them. Like `sdl.zig`, everything here links native libraries and lives in
//! the shell executable ONLY, so the v0 SDL render path and the headless golden
//! tests never see WebKitGTK/GTK.
//!
//! Two entrypoints, mirroring the two build steps:
//!   - `runShell`  (`zig build shell`)      builds the chrome and runs the GTK
//!     main loop interactively (blocks until the window is closed).
//!   - `smokeTest` (`zig build shell-test`) drives it headlessly under Xvfb:
//!     navigate through the `Renderer` seam, wait for the seam's `.finished`
//!     lifecycle event (proving seam-level navigation reaches the chrome),
//!     snapshot the view, and assert the snapshot is non-blank. WebKitGTK has
//!     NO native headless mode and `GtkOffscreenWindow` does not work with a
//!     WebView (WebKit bug #76911), so a virtual X display (`xvfb-run`) is the
//!     supported approach; `smokeTest` therefore still needs a (virtual)
//!     display, which is why it is its OWN build step and NOT part of
//!     `zig build test`.

const std = @import("std");
const wezig = @import("wezig");
const SystemWebviewRenderer = @import("system_webview_renderer.zig").SystemWebviewRenderer;
const GtkToolkit = @import("gtk_toolkit.zig").GtkToolkit;
const Chrome = wezig.chrome.Chrome;

/// The GTK/WebKit binding, needed ONLY for the smoke test's snapshot (there is
/// no seam-level snapshot API yet). The interactive/chrome paths never use it.
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

// --- Interactive entrypoint (`zig build shell`) --------------------------

/// Build the minimal chrome over the two seams and run the toolkit main loop
/// until the user closes the window. Requires a real display; returns
/// `error.GtkInit` in a headless environment with no Xvfb.
pub fn runShell() ShellError!void {
    var toolkit = GtkToolkit.init() catch return error.GtkInit;
    var view_renderer = SystemWebviewRenderer.init();
    var chrome = Chrome.init(view_renderer.renderer(), toolkit.toolkit());
    // `start` attaches both seams' callbacks, builds the window, embeds the
    // view, navigates to the default page, and runs the GTK main loop until the
    // window's "destroy" -> `.closed` intent -> `toolkit.quit()`.
    chrome.start(default_url);
}

// --- Headless smoke test (`zig build shell-test`, under xvfb-run) --------

/// Shared state the smoke test's callbacks hand back to `smokeTest`.
const Smoke = struct {
    loop: *c.GMainLoop,
    view: *c.WebKitWebView,
    /// Set true once the `Renderer` seam delivered a `.finished` lifecycle
    /// event to the chrome-observing sink (proves seam-level navigation).
    seam_finished: bool = false,
    /// Set once a verdict is reached; `smokeTest` reads it after the loop ends.
    result: ShellError!void = error.NoResult,
    /// The pixel scan's allocator (freed by `smokeTest`).
    gpa: std.mem.Allocator,
};

/// Drive the chrome headlessly THROUGH the seams and verify it rendered.
/// Intended to run under a virtual display (`xvfb-run zig build shell-test`).
/// Navigates via the `Renderer` seam, waits for the seam's `.finished`
/// lifecycle event, snapshots the view, and asserts the snapshot is non-blank.
/// Returns the verdict; the shell executable turns it into an exit code.
pub fn smokeTest(gpa: std.mem.Allocator) ShellError!void {
    var toolkit = GtkToolkit.init() catch return error.GtkInit;
    var view_renderer = SystemWebviewRenderer.init();
    const r = view_renderer.renderer();

    const loop = c.g_main_loop_new(null, 0) orelse return error.NoResult;
    defer c.g_main_loop_unref(loop);

    // The seam hands the view across as an OPAQUE handle; it is the underlying
    // `WebKitWebView` (a GtkWidget). Re-cast it through THIS file's cImport so
    // the local snapshot API accepts it (the backend's cImport is a distinct
    // translation unit, so its `*WebKitWebView` type is not shared here).
    const view: *c.WebKitWebView = @ptrCast(@alignCast(r.view()));
    var smoke = Smoke{ .loop = loop, .view = view, .gpa = gpa };

    // Build the chrome over the two seams, then subscribe the smoke observer
    // to the SAME renderer seam so we assert navigation crosses the seam.
    var chrome = Chrome.init(r, toolkit.toolkit());
    chrome.attach();
    r.setLifecycleCallback(.{ .ctx = &smoke, .onEvent = onSeamEvent });
    chrome.build(smoke_page);

    // Safety net: if the load never finishes, stop the loop after a while so
    // the test fails loudly instead of hanging CI.
    _ = c.g_timeout_add_seconds(30, @ptrCast(&onTimeout), &smoke);

    c.g_main_loop_run(loop);
    return smoke.result;
}

/// The `Renderer`-seam lifecycle observer for the smoke test. When the seam
/// reports the load `.finished`, request a snapshot of the view.
fn onSeamEvent(ctx: *anyopaque, event: wezig.renderer.LifecycleEvent) void {
    const smoke: *Smoke = @ptrCast(@alignCast(ctx));
    switch (event) {
        .load_changed => |lc| {
            if (lc.state != .finished or smoke.seam_finished) return;
            smoke.seam_finished = true;
            c.webkit_web_view_get_snapshot(
                smoke.view,
                c.WEBKIT_SNAPSHOT_REGION_VISIBLE,
                c.WEBKIT_SNAPSHOT_OPTIONS_NONE,
                null,
                @ptrCast(&onSnapshotReady),
                smoke,
            );
        },
        else => {},
    }
}

fn onTimeout(data: c.gpointer) callconv(.c) c.gboolean {
    const smoke: *Smoke = @ptrCast(@alignCast(data));
    smoke.result = error.LoadFailed;
    c.g_main_loop_quit(smoke.loop);
    return 0; // G_SOURCE_REMOVE
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
