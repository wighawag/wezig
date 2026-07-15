//! The minimal chrome: one window, a URL bar, back/forward buttons (ADR-0006).
//!
//! This is the whole point of the two seams: the chrome wires a `Renderer`
//! (content) to a `Toolkit` (chrome host) and talks ONLY to those two
//! interfaces. It imports NEITHER `webkit` NOR `gtk` (a later task adds a
//! conformance check for exactly that: grep this module for `webkit_`/`gtk_`
//! and expect zero hits). Swapping WebKitGTK for `WezigRenderer`, or GTK for
//! Qt, is a change to which backend value is passed in `run` below, NOT a
//! change to this file.
//!
//! ## What it does
//!
//!   - subscribes to the toolkit's user intents (URL entered, Back, Forward,
//!     Reload, window closed) and turns each into a `Renderer` call;
//!   - subscribes to the renderer's load-lifecycle events and reflects them in
//!     the toolkit's widgets (URL bar text, Back/Forward button sensitivity,
//!     window title);
//!   - builds the window, embeds the renderer's opaque view, presents, and runs
//!     the toolkit main loop.
//!
//! The chrome owns NO GTK/WebKit state; both backends are opaque values.

const std = @import("std");
const renderer_mod = @import("renderer.zig");
const toolkit_mod = @import("toolkit.zig");
const branding = @import("branding.zig");

const Renderer = renderer_mod.Renderer;
const Toolkit = toolkit_mod.Toolkit;
const LifecycleEvent = renderer_mod.LifecycleEvent;
const ChromeIntent = toolkit_mod.ChromeIntent;

/// The minimal chrome. Holds the two seam values and mediates between them.
/// Construct with `init`, wire it with `attach`, then either drive it directly
/// (tests) or hand control to the toolkit loop via `start`.
pub const Chrome = struct {
    renderer: Renderer,
    toolkit: Toolkit,

    pub fn init(renderer: Renderer, toolkit: Toolkit) Chrome {
        return .{ .renderer = renderer, .toolkit = toolkit };
    }

    /// Subscribe to both seams' event streams. Call once before driving.
    pub fn attach(self: *Chrome) void {
        self.renderer.setLifecycleCallback(.{ .ctx = self, .onEvent = onRendererEvent });
        self.toolkit.setChromeCallback(.{ .ctx = self, .onIntent = onChromeIntent });
    }

    /// Build the window, embed the content view, present, and start navigating
    /// to `start_uri`. Does NOT run the loop (the caller does), so tests can
    /// build the chrome without blocking on a main loop.
    pub fn build(self: *Chrome, start_uri: [*:0]const u8) void {
        self.toolkit.createWindow(window_w, window_h);
        self.toolkit.setTitle(window_title);
        self.toolkit.embedView(self.renderer.view());
        self.renderer.setViewportSize(window_w, window_h);
        self.toolkit.present();
        self.renderer.navigate(start_uri);
    }

    /// Build then run the toolkit main loop (blocks until the window closes).
    /// This is the interactive entrypoint; NOT used as an automated gate.
    pub fn start(self: *Chrome, start_uri: [*:0]const u8) void {
        self.attach();
        self.build(start_uri);
        self.toolkit.run();
    }

    // --- toolkit intents -> renderer calls ---
    fn onChromeIntent(ctx: *anyopaque, intent: ChromeIntent) void {
        const self: *Chrome = @ptrCast(@alignCast(ctx));
        switch (intent) {
            .navigate => |url| {
                // The toolkit hands a borrowed, NUL-less slice; the renderer's
                // navigate wants a C string. Copy onto a small stack buffer.
                var buf: [2048]u8 = undefined;
                if (url.len >= buf.len) return;
                @memcpy(buf[0..url.len], url);
                buf[url.len] = 0;
                self.renderer.navigate(buf[0..url.len :0]);
            },
            .reload => self.renderer.reload(),
            .back => self.renderer.goBack(),
            .forward => self.renderer.goForward(),
            .closed => self.toolkit.quit(),
        }
    }

    // --- renderer events -> toolkit widget updates ---
    fn onRendererEvent(ctx: *anyopaque, event: LifecycleEvent) void {
        const self: *Chrome = @ptrCast(@alignCast(ctx));
        switch (event) {
            .uri_changed => |uri| self.setUrlBar(uri),
            .load_changed => |lc| {
                if (lc.uri) |uri| self.setUrlBar(uri);
                // Any state transition can change history availability.
                self.refreshNavButtons();
            },
            .title_changed => {
                // Title is reflected into the window in the interactive path;
                // the minimal chrome keeps a fixed shell title for now.
            },
            .progress_changed => {},
        }
    }

    fn setUrlBar(self: *Chrome, uri: []const u8) void {
        var buf: [2048]u8 = undefined;
        if (uri.len >= buf.len) return;
        @memcpy(buf[0..uri.len], uri);
        buf[uri.len] = 0;
        self.toolkit.setUrlText(buf[0..uri.len :0]);
    }

    fn refreshNavButtons(self: *Chrome) void {
        self.toolkit.setBackEnabled(self.renderer.canGoBack());
        self.toolkit.setForwardEnabled(self.renderer.canGoForward());
    }
};

/// Shell window geometry (a real, comfortable size, like the app's window).
const window_w: c_int = 1024;
const window_h: c_int = 768;
const window_title = branding.display_name ++ " — webview shell";

// ---------------------------------------------------------------------------
// Tests: the chrome drives navigation THROUGH the seams, headlessly, with the
// fake backends (no webview, no GTK, no display).
// ---------------------------------------------------------------------------

const FakeRenderer = renderer_mod.FakeRenderer;
const FakeToolkit = toolkit_mod.FakeToolkit;

test "chrome: a navigate intent drives the renderer and updates the URL bar" {
    var fr = FakeRenderer.init(std.testing.allocator);
    defer fr.deinit();
    var ft = FakeToolkit{};

    var chrome = Chrome.init(fr.renderer(), ft.toolkit());
    chrome.attach();
    chrome.build("https://start.example/");

    // build() embedded the renderer's view through the toolkit seam.
    try std.testing.expect(ft.embedded_view != null);
    // The start navigation flowed renderer -> lifecycle event -> URL bar.
    try std.testing.expectEqualStrings("https://start.example/", ft.urlText());

    // A user-entered URL (toolkit intent) drives the renderer, which emits a
    // uri_changed the chrome reflects back into the URL bar.
    ft.fireIntent(.{ .navigate = "https://typed.example/" });
    try std.testing.expectEqualStrings("https://typed.example/", ft.urlText());
    try std.testing.expect(ft.back_enabled); // history now has two entries
}

test "chrome: back/forward intents drive the renderer and button sensitivity" {
    var fr = FakeRenderer.init(std.testing.allocator);
    defer fr.deinit();
    var ft = FakeToolkit{};

    var chrome = Chrome.init(fr.renderer(), ft.toolkit());
    chrome.attach();
    chrome.build("https://one.example/");
    ft.fireIntent(.{ .navigate = "https://two.example/" });

    try std.testing.expect(ft.back_enabled);
    try std.testing.expect(!ft.forward_enabled);

    ft.fireIntent(.back);
    try std.testing.expectEqualStrings("https://one.example/", ft.urlText());
    try std.testing.expect(!ft.back_enabled);
    try std.testing.expect(ft.forward_enabled);

    ft.fireIntent(.forward);
    try std.testing.expectEqualStrings("https://two.example/", ft.urlText());
    try std.testing.expect(ft.back_enabled);
    try std.testing.expect(!ft.forward_enabled);
}

test "chrome: a closed intent quits the toolkit loop" {
    var fr = FakeRenderer.init(std.testing.allocator);
    defer fr.deinit();
    var ft = FakeToolkit{};
    ft.running = true;

    var chrome = Chrome.init(fr.renderer(), ft.toolkit());
    chrome.attach();
    ft.fireIntent(.closed);
    try std.testing.expect(!ft.running);
}
