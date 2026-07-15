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
//! Entrypoints, mirroring the build steps (selected at build time by the
//! `shell_options.mode` string so ONE executable + ONE set of bindings covers
//! them all):
//!   - `runShell`  (`zig build shell`)          builds the chrome and runs the
//!     GTK main loop interactively (blocks until the window is closed).
//!   - `smokeTest` (`zig build shell-test`)      drives it headlessly under
//!     Xvfb: navigate through the `Renderer` seam, wait for the seam's
//!     `.finished` lifecycle event (proving seam-level navigation reaches the
//!     chrome), snapshot the view, and assert the snapshot is non-blank.
//!   - `bridgeTest` (`zig build shell-bridge-test`) proves the script-message
//!     bridge hook (ADR-0005) end-to-end through the REAL WebKitGTK backend:
//!     inject `window.wezig.ping`, register the page->native channel, load a
//!     page that calls it, and assert native received the payload AND that
//!     native's `evaluateScript` reply reached the page (both legs).
//!   - `schemeTest` (`zig build shell-scheme-test`) proves the custom-scheme
//!     interception hook (ADR-0005) end-to-end through the REAL WebKitGTK
//!     backend: register `wezig-test://`, navigate to it, and assert the
//!     native-generated body was served AND rendered (its `<title>` reaches the
//!     seam's `.title_changed` event).
//!
//! All three verification modes run the hooks through the SEAM against the real
//! backend, which is why they are their OWN build steps and NOT part of
//! `zig build test`: WebKitGTK has NO native headless mode and
//! `GtkOffscreenWindow` does not work with a WebView (WebKit bug #76911), so a
//! virtual X display (`xvfb-run`) is the supported approach. The seam-CONTRACT
//! tests (that both hooks exist and round-trip through a fake backend) live in
//! `renderer.zig`'s `zig build test` block; these prove the WebKitGTK IMPL.

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

/// The bridge test's page. A self-contained `data:` document whose inline
/// script calls the injected `window.wezig.ping(...)` at load, driving the
/// page->native leg of the script-message bridge with a known payload.
const bridge_page =
    "data:text/html," ++
    "<body><script>window.wezig.ping('ping-from-page')</script></body>";

/// The payload the bridge page posts, and the reply native evaluates back into
/// the page: the two ends the bridge test asserts round-trip.
const bridge_ping = "ping-from-page";
const bridge_pong = "pong-from-native";

/// The custom scheme the interception test registers, and the URI it navigates.
/// A distinct, throwaway scheme (NOT `ipfs`, which `explore-web3-capabilities`
/// owns): this only proves the hook.
const scheme_name = "wezig-test";
const scheme_uri = "wezig-test://hello";

/// The document title the scheme handler embeds in its native-served body. The
/// test asserts THIS string reaches the seam's `.title_changed` event, which
/// proves the native bytes were both served (the handler ran) and rendered
/// (WebKit parsed the served HTML).
const scheme_marker = "WEZIG-SCHEME-OK";

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
    /// The script-message bridge's page->native leg did not deliver the
    /// expected payload (the page called `window.wezig.ping` but native never
    /// received the value, or received the wrong one).
    BridgePageToNativeFailed,
    /// The bridge's native->page leg did not land: after native evaluated its
    /// reply script, the page did not observe it.
    BridgeNativeToPageFailed,
    /// The custom-scheme handler was never invoked for the registered scheme.
    SchemeNotServed,
    /// The custom scheme was served, but the native body did not render (its
    /// `<title>` marker never reached the seam's `.title_changed` event).
    SchemeNotRendered,
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

// --- Bridge hook headless proof (`zig build shell-bridge-test`, under xvfb) --

/// Shared state for the script-message bridge proof. Threaded through the seam
/// callbacks so `bridgeTest` reads the verdict after the loop ends.
const Bridge = struct {
    loop: *c.GMainLoop,
    r: wezig.renderer.Renderer,
    /// Set true once native received the page's `ping` payload (page->native).
    got_ping: bool = false,
    /// Set true once native observed its OWN reply come back through the page
    /// (native->page): native `evaluateScript`s a call that re-posts `pong`.
    got_pong: bool = false,
    result: ShellError!void = error.NoResult,
};

/// Prove the script-message bridge hook (ADR-0005) end-to-end through the real
/// WebKitGTK backend, headless under Xvfb. Both legs are exercised THROUGH the
/// `Renderer` seam (never a raw webview call): `injectUserScript` sets up
/// `window.wezig.ping`, `setScriptMessageHandler` opens the page->native
/// channel, and `evaluateScript` posts native's reply back. A page-world call
/// (`window.wezig.ping('ping-from-page')`) must reach native, and native's
/// evaluated reply must come back through the page. This is the real-backend
/// counterpart of `renderer.zig`'s fake-backend seam-contract test.
pub fn bridgeTest(gpa: std.mem.Allocator) ShellError!void {
    var toolkit = GtkToolkit.init() catch return error.GtkInit;
    var view_renderer = SystemWebviewRenderer.init();
    const r = view_renderer.renderer();

    const loop = c.g_main_loop_new(null, 0) orelse return error.NoResult;
    defer c.g_main_loop_unref(loop);

    var bridge = Bridge{ .loop = loop, .r = r };

    // Inject the page-world object BEFORE loading, so `window.wezig` exists when
    // the page's inline script runs (INJECT_AT_DOCUMENT_START). `ping` posts its
    // argument over the `wezig` channel.
    r.injectUserScript(
        \\window.wezig = { ping: function(v) {
        \\  window.webkit.messageHandlers.wezig.postMessage(v);
        \\} };
    );
    // Register the page->native channel; the handler drives BOTH legs' asserts.
    r.setScriptMessageHandler("wezig", .{ .ctx = &bridge, .onMessage = onBridgeMessage });

    // The view must be realized in a window for WebKit to load; embed it via the
    // toolkit seam exactly as the chrome would, then navigate the bridge page.
    var chrome = Chrome.init(r, toolkit.toolkit());
    chrome.attach();
    chrome.build(bridge_page);

    _ = c.g_timeout_add_seconds(30, @ptrCast(&onBridgeTimeout), &bridge);
    c.g_main_loop_run(loop);
    _ = gpa; // symmetry with the other modes; the bridge proof allocates nothing.
    return bridge.result;
}

/// The page->native handler for the bridge proof. First message is the page's
/// `ping`; native then evaluates a reply that re-posts `pong` over the same
/// channel, so the SECOND message proves the native->page leg landed. Both seen
/// == success.
fn onBridgeMessage(ctx: *anyopaque, name: []const u8, body: []const u8) void {
    const bridge: *Bridge = @ptrCast(@alignCast(ctx));
    _ = name;
    if (!bridge.got_ping) {
        if (!std.mem.eql(u8, body, bridge_ping)) {
            bridge.result = error.BridgePageToNativeFailed;
            c.g_main_loop_quit(bridge.loop);
            return;
        }
        bridge.got_ping = true;
        // native->page leg: evaluate a reply that posts `pong` back through the
        // SAME injected channel. If the value comes back, native<->page both work.
        bridge.r.evaluateScript("window.wezig.ping('" ++ bridge_pong ++ "');");
        return;
    }
    // Second message: native's reply came back through the page.
    if (std.mem.eql(u8, body, bridge_pong)) {
        bridge.got_pong = true;
        bridge.result = {};
    } else {
        bridge.result = error.BridgeNativeToPageFailed;
    }
    c.g_main_loop_quit(bridge.loop);
}

fn onBridgeTimeout(data: c.gpointer) callconv(.c) c.gboolean {
    const bridge: *Bridge = @ptrCast(@alignCast(data));
    // Distinguish which leg never fired so the failure names the broken hook.
    bridge.result = if (!bridge.got_ping)
        error.BridgePageToNativeFailed
    else
        error.BridgeNativeToPageFailed;
    c.g_main_loop_quit(bridge.loop);
    return 0; // G_SOURCE_REMOVE
}

// --- Scheme hook headless proof (`zig build shell-scheme-test`, under xvfb) --

/// Shared state for the custom-scheme interception proof.
const Scheme = struct {
    loop: *c.GMainLoop,
    /// Set true once the native scheme handler was invoked (proves the request
    /// was intercepted and served from native code).
    served: bool = false,
    result: ShellError!void = error.NoResult,
};

/// Prove the request-interception / custom-scheme hook (ADR-0005) end-to-end
/// through the real WebKitGTK backend, headless under Xvfb. Registers
/// `wezig-test://` through the `Renderer` seam's `registerScheme`, navigates to
/// `wezig-test://hello`, and asserts the native-generated body was BOTH served
/// (the handler ran) and rendered (its `<title>` marker reaches the seam's
/// `.title_changed` event). Real-backend counterpart of `renderer.zig`'s
/// fake-backend scheme test.
pub fn schemeTest(gpa: std.mem.Allocator) ShellError!void {
    var toolkit = GtkToolkit.init() catch return error.GtkInit;
    var view_renderer = SystemWebviewRenderer.init();
    const r = view_renderer.renderer();

    const loop = c.g_main_loop_new(null, 0) orelse return error.NoResult;
    defer c.g_main_loop_unref(loop);

    var scheme = Scheme{ .loop = loop };

    // Register the custom scheme through the seam; its handler serves a native
    // HTML body carrying the marker `<title>`.
    r.registerScheme(scheme_name, .{ .ctx = &scheme, .onRequest = onSchemeRequest });
    // Observe the seam's lifecycle: the marker title arriving proves render.
    r.setLifecycleCallback(.{ .ctx = &scheme, .onEvent = onSchemeEvent });

    var chrome = Chrome.init(r, toolkit.toolkit());
    // NB: do NOT call chrome.attach() here (it would install the chrome's own
    // lifecycle sink over ours); build the window and navigate the scheme URI.
    chrome.build(scheme_uri);

    _ = c.g_timeout_add_seconds(30, @ptrCast(&onSchemeTimeout), &scheme);
    c.g_main_loop_run(loop);
    _ = gpa;
    return scheme.result;
}

/// The native scheme handler for the proof: serves a small HTML body whose
/// `<title>` is the marker string. Records that it ran (so a title that never
/// arrives is distinguishable from a scheme that was never intercepted).
fn onSchemeRequest(ctx: *anyopaque, uri: []const u8) wezig.renderer.SchemeResponse {
    const scheme: *Scheme = @ptrCast(@alignCast(ctx));
    _ = uri;
    scheme.served = true;
    return .{
        .body = "<html><head><title>" ++ scheme_marker ++ "</title></head>" ++
            "<body><h1>" ++ scheme_marker ++ "</h1></body></html>",
        .content_type = "text/html",
    };
}

/// Lifecycle observer for the scheme proof: the marker `<title>` arriving proves
/// WebKit parsed+rendered the native-served body.
fn onSchemeEvent(ctx: *anyopaque, event: wezig.renderer.LifecycleEvent) void {
    const scheme: *Scheme = @ptrCast(@alignCast(ctx));
    switch (event) {
        .title_changed => |title| {
            if (std.mem.eql(u8, title, scheme_marker)) {
                scheme.result = if (scheme.served) {} else error.SchemeNotServed;
                c.g_main_loop_quit(scheme.loop);
            }
        },
        else => {},
    }
}

fn onSchemeTimeout(data: c.gpointer) callconv(.c) c.gboolean {
    const scheme: *Scheme = @ptrCast(@alignCast(data));
    scheme.result = if (!scheme.served) error.SchemeNotServed else error.SchemeNotRendered;
    c.g_main_loop_quit(scheme.loop);
    return 0; // G_SOURCE_REMOVE
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
