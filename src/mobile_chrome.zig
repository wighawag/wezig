//! The shared mobile chrome loop: the mobile analogue of `src/chrome.zig`, over
//! the `ChromeSurface` half of the split `Toolkit` (ADR-0008) — with NO
//! `HostLoop` (the OS owns the window + run loop on mobile). This is the ONE
//! shared piece of chrome logic mobile adds; both platform shells (iOS/Android)
//! construct it and feed it the native `ChromeSurface` + `Renderer`.
//!
//! ## What it does (the desktop `chrome.zig` shape, host-loop-free)
//!
//! Exactly like `Chrome`, `MobileChrome` wires a `Renderer` (content) to a
//! chrome host and talks ONLY to the two seams. It:
//!
//!   - subscribes to the surface's user intents (URL entered, Back, Forward,
//!     Reload) and turns each into a `Renderer` call;
//!   - subscribes to the renderer's load-lifecycle events and reflects them into
//!     the surface's widgets (URL bar text, Back/Forward button sensitivity);
//!   - embeds the renderer's opaque `ViewHandle` via `ChromeSurface.embedView`.
//!
//! The chrome owns NO WebKit/UIKit/`android.webkit.*` state; both backends are
//! opaque values reached only through the `Renderer` + `ChromeSurface` seams, so
//! this file imports NEITHER a webview NOR a native-UI binding (the same
//! binding-free discipline `chrome.zig` keeps and `chrome_conformance` guards on
//! the desktop chrome).
//!
//! ## Why a new `MobileChrome` instead of reusing `Chrome` (the recorded choice)
//!
//! DECISION: add this dedicated `MobileChrome` rather than driving the existing
//! `src/chrome.zig` `Chrome` host-loop-free.
//!
//! WHY: `Chrome` is NOT a clean host-loop-free drop-in. `Chrome.init` takes a
//! COMPOSED `Toolkit` (a `ChromeSurface` + a `HostLoop`), and its `build`/`start`/
//! `onChromeIntent` paths call the `HostLoop` half DIRECTLY —
//! `createWindow`/`setTitle`/`present`/`run` in `build`/`start`, and `quit` on a
//! `.closed` intent. On mobile there is no `HostLoop` to compose (the OS owns the
//! window and the run loop — ADR-0008), so reusing `Chrome` would force one of:
//!   (a) refactoring `Chrome` to accept a bare `ChromeSurface` and hoisting every
//!       `HostLoop` call out of `build`/`start`/`onChromeIntent` — widening the
//!       blast radius into the desktop wiring, `chrome.zig`'s tests, and the
//!       `chrome_conformance` guard, for a chrome whose behaviour is otherwise
//!       identical; or
//!   (b) handing `Chrome` a fake/no-op `HostLoop` on mobile — smuggling a
//!       desktop-only concept (a window + a main loop) into a platform that has
//!       neither, which is exactly the coupling ADR-0008 split the seam to avoid.
//! Both are worse than a small, self-contained `MobileChrome` that composes the
//! SAME two seams minus the half mobile does not have. `src/chrome.zig` is left
//! UNCHANGED (spec `build-mobile-shell`, Implementation Decisions: "`src/chrome.zig`
//! stays unchanged; `chrome_conformance` stays green"), and the desktop and mobile
//! chromes share the `Renderer`/`ChromeSurface`/lifecycle vocabulary without
//! sharing a struct that bakes in a `HostLoop`.
//!
//! ALTERNATIVE CONSIDERED: refactor `Chrome` to split cleanly (option (a)). The
//! task's EXPECTED PATH permits it only "WITHOUT touching desktop behaviour",
//! which (a) cannot honour — it re-shapes `Chrome.init`'s signature and moves the
//! `HostLoop` calls, changing the desktop wiring. So the new-struct path is taken.
//!
//! ## What this file does NOT do
//!
//! No `HostLoop` — no `createWindow`/`setTitle`/`present`/`run`/`quit`. There is
//! no main loop to run or quit here: the OS drives the run loop and calls the
//! native shell, which drives THIS chrome's intents. `.closed` is therefore a
//! no-op at this seam (the OS owns app teardown; there is no loop to stop), noted
//! at the intent handler.

const std = @import("std");
const renderer_mod = @import("renderer.zig");
const toolkit_mod = @import("toolkit.zig");

const Renderer = renderer_mod.Renderer;
const ChromeSurface = toolkit_mod.ChromeSurface;
const LifecycleEvent = renderer_mod.LifecycleEvent;
const ChromeIntent = toolkit_mod.ChromeIntent;

/// The shared mobile chrome. Holds the `Renderer` + `ChromeSurface` seam values
/// and mediates between them, exactly as `Chrome` does on desktop but with no
/// `HostLoop`. Construct with `init`, wire it with `attach`, then drive it: the
/// native shell calls `build` to embed + start, and delivers user intents by
/// firing them into the surface (which the chrome subscribed to in `attach`).
pub const MobileChrome = struct {
    renderer: Renderer,
    surface: ChromeSurface,

    pub fn init(renderer: Renderer, surface: ChromeSurface) MobileChrome {
        return .{ .renderer = renderer, .surface = surface };
    }

    /// Subscribe to both seams' event streams. Call once before driving.
    pub fn attach(self: *MobileChrome) void {
        self.renderer.setLifecycleCallback(.{ .ctx = self, .onEvent = onRendererEvent });
        self.surface.setChromeCallback(.{ .ctx = self, .onIntent = onChromeIntent });
    }

    /// Embed the renderer's opaque content view through the surface, size the
    /// viewport, and start navigating to `start_uri`. The mobile analogue of
    /// `Chrome.build` MINUS the `HostLoop` calls (no `createWindow`/`present`):
    /// the OS already owns the window + content area, so the chrome only embeds
    /// into it and navigates.
    pub fn build(self: *MobileChrome, start_uri: [*:0]const u8) void {
        self.surface.embedView(self.renderer.view());
        self.renderer.setViewportSize(content_w, content_h);
        self.renderer.navigate(start_uri);
    }

    // --- surface intents -> renderer calls ---
    fn onChromeIntent(ctx: *anyopaque, intent: ChromeIntent) void {
        const self: *MobileChrome = @ptrCast(@alignCast(ctx));
        switch (intent) {
            .navigate => |url| {
                // The surface hands a borrowed, NUL-less slice; the renderer's
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
            // No `HostLoop` on mobile: the OS owns the run loop + app teardown,
            // so there is no loop to `quit` here (unlike desktop `chrome.zig`).
            .closed => {},
        }
    }

    // --- renderer events -> surface widget updates ---
    fn onRendererEvent(ctx: *anyopaque, event: LifecycleEvent) void {
        const self: *MobileChrome = @ptrCast(@alignCast(ctx));
        switch (event) {
            .uri_changed => |uri| self.setUrlText(uri),
            .load_changed => |lc| {
                if (lc.uri) |uri| self.setUrlText(uri);
                // Any state transition can change history availability.
                self.refreshNavButtons();
            },
            .title_changed => {
                // The mobile chrome keeps no window title (the OS owns the app
                // frame); title changes need no surface reflection here.
            },
            .progress_changed => {},
        }
    }

    fn setUrlText(self: *MobileChrome, uri: []const u8) void {
        var buf: [2048]u8 = undefined;
        if (uri.len >= buf.len) return;
        @memcpy(buf[0..uri.len], uri);
        buf[uri.len] = 0;
        self.surface.setUrlText(buf[0..uri.len :0]);
    }

    fn refreshNavButtons(self: *MobileChrome) void {
        self.surface.setBackEnabled(self.renderer.canGoBack());
        self.surface.setForwardEnabled(self.renderer.canGoForward());
    }
};

/// The content-area size the chrome reports to the renderer's viewport. The OS
/// owns the actual frame on mobile; this is a sane non-zero default the native
/// shell overrides via the seam when it knows the real bounds. Kept here so
/// `build` reaches the `setViewportSize` seam exactly as desktop does.
const content_w: c_int = 1024;
const content_h: c_int = 768;

// ---------------------------------------------------------------------------
// Tests: the mobile chrome drives navigation THROUGH the two seams, headlessly,
// with the fake backends (no webview, no UIKit, no JVM, no display). Mirrors the
// desktop `chrome.zig` tests, driving a `ChromeSurface` fake in place of the
// composed `FakeToolkit` — the mobile shape (surface half, no host/loop).
// ---------------------------------------------------------------------------

const FakeRenderer = renderer_mod.FakeRenderer;

/// A minimal in-memory `ChromeSurface` for the mobile chrome tests: records the
/// URL text + back/forward flags + the embedded handle, and lets a test SIMULATE
/// user intents (`fireIntent`) so the chrome<->surface contract is asserted with
/// no native UI. Mirrors `FakeToolkit`'s surface half and `MobileChromeSurface`'s
/// widget contract, but stands entirely on the `ChromeSurface` seam (no `HostLoop`).
const FakeSurface = struct {
    url_text: [512]u8 = undefined,
    url_len: usize = 0,
    back_enabled: bool = false,
    forward_enabled: bool = false,
    embedded_view: ?renderer_mod.ViewHandle = null,
    cb: ?toolkit_mod.ChromeCallback = null,

    fn chromeSurface(self: *FakeSurface) ChromeSurface {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Simulate a user intent arriving from the (fake) native shell.
    fn fireIntent(self: *FakeSurface, intent: ChromeIntent) void {
        if (self.cb) |cb| cb.onIntent(cb.ctx, intent);
    }

    /// The URL bar's current text (for assertions).
    fn urlText(self: *FakeSurface) []const u8 {
        return self.url_text[0..self.url_len];
    }

    const vtable = ChromeSurface.VTable{
        .embedView = embedView,
        .setUrlText = setUrlText,
        .setBackEnabled = setBackEnabled,
        .setForwardEnabled = setForwardEnabled,
        .setChromeCallback = setChromeCallback,
    };

    fn embedView(ctx: *anyopaque, view: renderer_mod.ViewHandle) void {
        const self: *FakeSurface = @ptrCast(@alignCast(ctx));
        self.embedded_view = view;
    }
    fn setUrlText(ctx: *anyopaque, text: [*:0]const u8) void {
        const self: *FakeSurface = @ptrCast(@alignCast(ctx));
        const slice = std.mem.span(text);
        const n = @min(slice.len, self.url_text.len);
        @memcpy(self.url_text[0..n], slice[0..n]);
        self.url_len = n;
    }
    fn setBackEnabled(ctx: *anyopaque, enabled: bool) void {
        const self: *FakeSurface = @ptrCast(@alignCast(ctx));
        self.back_enabled = enabled;
    }
    fn setForwardEnabled(ctx: *anyopaque, enabled: bool) void {
        const self: *FakeSurface = @ptrCast(@alignCast(ctx));
        self.forward_enabled = enabled;
    }
    fn setChromeCallback(ctx: *anyopaque, cb: toolkit_mod.ChromeCallback) void {
        const self: *FakeSurface = @ptrCast(@alignCast(ctx));
        self.cb = cb;
    }
};

test "mobile chrome: a navigate intent drives the renderer and updates the URL text" {
    var fr = FakeRenderer.init(std.testing.allocator);
    defer fr.deinit();
    var fs = FakeSurface{};

    var chrome = MobileChrome.init(fr.renderer(), fs.chromeSurface());
    chrome.attach();
    chrome.build("https://start.example/");

    // build() embedded the renderer's view through the chrome-surface seam.
    try std.testing.expect(fs.embedded_view != null);
    try std.testing.expectEqual(fr.renderer().view(), fs.embedded_view.?);
    // The start navigation flowed renderer -> lifecycle event -> URL text.
    try std.testing.expectEqualStrings("https://start.example/", fs.urlText());

    // A user-entered URL (surface intent) drives the renderer, which emits a
    // uri_changed the chrome reflects back into the URL text.
    fs.fireIntent(.{ .navigate = "https://typed.example/" });
    try std.testing.expectEqualStrings("https://typed.example/", fs.urlText());
    try std.testing.expect(fs.back_enabled); // history now has two entries
}

test "mobile chrome: back/forward intents drive the renderer and button sensitivity" {
    var fr = FakeRenderer.init(std.testing.allocator);
    defer fr.deinit();
    var fs = FakeSurface{};

    var chrome = MobileChrome.init(fr.renderer(), fs.chromeSurface());
    chrome.attach();
    chrome.build("https://one.example/");
    fs.fireIntent(.{ .navigate = "https://two.example/" });

    try std.testing.expect(fs.back_enabled);
    try std.testing.expect(!fs.forward_enabled);

    fs.fireIntent(.back);
    try std.testing.expectEqualStrings("https://one.example/", fs.urlText());
    try std.testing.expect(!fs.back_enabled);
    try std.testing.expect(fs.forward_enabled);

    fs.fireIntent(.forward);
    try std.testing.expectEqualStrings("https://two.example/", fs.urlText());
    try std.testing.expect(fs.back_enabled);
    try std.testing.expect(!fs.forward_enabled);
}

test "mobile chrome: a reload intent drives the renderer without changing history" {
    var fr = FakeRenderer.init(std.testing.allocator);
    defer fr.deinit();
    var fs = FakeSurface{};

    var chrome = MobileChrome.init(fr.renderer(), fs.chromeSurface());
    chrome.attach();
    chrome.build("https://only.example/");

    fs.fireIntent(.reload);
    // Reload keeps the same single-entry history: no back/forward available.
    try std.testing.expectEqualStrings("https://only.example/", fs.urlText());
    try std.testing.expect(!fs.back_enabled);
    try std.testing.expect(!fs.forward_enabled);
}

test "mobile chrome: a closed intent is a no-op (the OS owns the run loop, no HostLoop)" {
    // Unlike desktop `chrome.zig` (which quits the toolkit loop on `.closed`),
    // the mobile chrome has no `HostLoop` to stop — the OS owns the run loop and
    // app teardown. The intent must be accepted without touching a loop or
    // crashing; it simply does nothing at this seam.
    var fr = FakeRenderer.init(std.testing.allocator);
    defer fr.deinit();
    var fs = FakeSurface{};

    var chrome = MobileChrome.init(fr.renderer(), fs.chromeSurface());
    chrome.attach();
    fs.fireIntent(.closed);
    // No observable state change; the chrome is still usable.
    fs.fireIntent(.{ .navigate = "https://after-close.example/" });
    try std.testing.expectEqualStrings("https://after-close.example/", fs.urlText());
}
