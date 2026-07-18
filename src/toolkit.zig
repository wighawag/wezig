//! The chrome/toolkit seam, SPLIT into two composed halves (ADR-0006, ADR-0008).
//!
//! The chrome (one window, a URL bar, back/forward buttons) talks to THIS
//! interface for everything it puts on screen, never to GTK directly. `GtkToolkit`
//! is the first and only implementation today; a Qt or a Zig-native chrome layer
//! implements the SAME interface later.
//!
//! ## Why the seam is split into two halves (ADR-0008, mobile lifecycle inversion)
//!
//! The original `Toolkit` bundled TWO concerns that swap along DIFFERENT axes:
//!
//!   - **chrome-surface** — the widgets + intents BOTH desktop and mobile
//!     implement: `embedView`, `setUrlText`, `setBackEnabled`/`setForwardEnabled`,
//!     `setChromeCallback`. On mobile this is hosted inside an OS-owned
//!     `UIViewController`/`Activity`.
//!   - **host/loop** — desktop-only windowing + main loop: `createWindow`,
//!     `setTitle`, `present`, `run`, `quit`. On MOBILE the OS owns the window and
//!     the run loop, so a mobile toolkit CANNOT honestly implement this half —
//!     there is nothing to `createWindow` or `run`.
//!
//! Splitting along that axis lets a mobile backend implement `ChromeSurface`
//! WITHOUT `HostLoop`. On desktop, `GtkToolkit` composes BOTH halves and the
//! chrome's behaviour is unchanged: the composed `Toolkit` value still exposes
//! the full method set `chrome.zig` calls, delegating each call to the right
//! half. (SDL/native windowing from ADR-0004 is a SEPARATE leaf, the
//! `WezigRenderer`-direct harness, untouched by this seam.)
//!
//! This file imports NO GTK binding: it is pure interface, exactly like
//! `renderer.zig`. The two content/chrome seams stay independent: `Renderer`
//! owns the CONTENT backend, this seam owns the CHROME host; the chrome is the
//! only place that holds both and wires them together.
//!
//! ## Shape (vtables, like `Renderer` / `PaintBackend`)
//!
//! Each half is a `{ ptr, vtable }` value. `Toolkit` is the desktop COMPOSITE
//! that holds one of each and re-exposes the flat method surface the chrome
//! uses, so `chrome.zig` is unchanged by the split.
//!
//!   - `ChromeSurface` (both platforms): `embedView` (host the renderer's opaque
//!     view), `setUrlText` (the URL bar), `setBackEnabled` / `setForwardEnabled`
//!     (the nav buttons' sensitivity), `setChromeCallback` (user intents UP to
//!     the chrome).
//!   - `HostLoop` (desktop-only): `createWindow` (the shell window; windowing
//!     behind the seam), `setTitle`, `present`, `run` / `quit` (the chrome-host
//!     main loop).

const std = @import("std");
const renderer = @import("renderer.zig");

/// A user intent the chrome host raises UP to the chrome. The chrome turns each
/// into a `Renderer` call (or a quit). Kept a closed set: a URL-bar chrome has
/// exactly these controls.
pub const ChromeIntent = union(enum) {
    /// The user entered/submitted a URL in the URL bar. The slice is borrowed
    /// for the callback's duration (the toolkit owns the entry's storage).
    navigate: []const u8,
    /// The user clicked Reload.
    reload,
    /// The user clicked Back.
    back,
    /// The user clicked Forward.
    forward,
    /// The window was closed (the chrome should quit the loop).
    closed,
};

/// The chrome's subscription to user intents from the chrome host.
pub const ChromeCallback = struct {
    ctx: *anyopaque,
    onIntent: *const fn (ctx: *anyopaque, intent: ChromeIntent) void,
};

// ---------------------------------------------------------------------------
// Half 1: `ChromeSurface` — the widgets + intents BOTH platforms implement.
// ---------------------------------------------------------------------------

/// The chrome-surface half of the seam: the toolbar widgets a chrome controls
/// and the user intents it subscribes to. A mobile toolkit implements ONLY this
/// half (its widgets live in an OS-owned `UIViewController`/`Activity`, not a
/// window this code creates). A `{ ptr, vtable }` value like `Renderer`.
pub const ChromeSurface = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Embed the renderer's opaque interactive view into the content slot
        /// (below the toolbar on desktop; the OS-owned content area on mobile).
        /// The toolkit interprets the handle; the chrome only passes it through
        /// from `Renderer.view()`.
        embedView: *const fn (ctx: *anyopaque, view: renderer.ViewHandle) void,
        /// Set the URL bar's displayed text (e.g. after a `uri_changed` event).
        setUrlText: *const fn (ctx: *anyopaque, text: [*:0]const u8) void,
        /// Enable/disable the Back and Forward buttons.
        setBackEnabled: *const fn (ctx: *anyopaque, enabled: bool) void,
        setForwardEnabled: *const fn (ctx: *anyopaque, enabled: bool) void,
        /// Subscribe the chrome to user intents. At most one sink.
        setChromeCallback: *const fn (ctx: *anyopaque, cb: ChromeCallback) void,
    };

    pub fn embedView(self: ChromeSurface, view: renderer.ViewHandle) void {
        self.vtable.embedView(self.ptr, view);
    }
    pub fn setUrlText(self: ChromeSurface, text: [*:0]const u8) void {
        self.vtable.setUrlText(self.ptr, text);
    }
    pub fn setBackEnabled(self: ChromeSurface, enabled: bool) void {
        self.vtable.setBackEnabled(self.ptr, enabled);
    }
    pub fn setForwardEnabled(self: ChromeSurface, enabled: bool) void {
        self.vtable.setForwardEnabled(self.ptr, enabled);
    }
    pub fn setChromeCallback(self: ChromeSurface, cb: ChromeCallback) void {
        self.vtable.setChromeCallback(self.ptr, cb);
    }
};

// ---------------------------------------------------------------------------
// Half 2: `HostLoop` — desktop-only windowing + main loop.
// ---------------------------------------------------------------------------

/// The host/loop half of the seam: the shell WINDOW and the chrome-host main
/// loop. This half is DESKTOP-ONLY — on mobile the OS owns the window and the
/// run loop, so a mobile toolkit does NOT implement it (there is nothing to
/// `createWindow` or `run`). A `{ ptr, vtable }` value like `ChromeSurface`.
pub const HostLoop = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Create the shell window at `width` x `height`. The toolkit owns the
        /// native window; the chrome never calls a windowing API directly.
        createWindow: *const fn (ctx: *anyopaque, width: c_int, height: c_int) void,
        /// Set the shell window's title.
        setTitle: *const fn (ctx: *anyopaque, title: [*:0]const u8) void,
        /// Show the window on screen.
        present: *const fn (ctx: *anyopaque) void,
        /// Run the chrome-host main loop until `quit` is called (or the window
        /// closes). This is the windowing event loop, owned by the toolkit.
        run: *const fn (ctx: *anyopaque) void,
        /// Ask the main loop to stop (from an intent handler, e.g. on `closed`).
        quit: *const fn (ctx: *anyopaque) void,
    };

    pub fn createWindow(self: HostLoop, width: c_int, height: c_int) void {
        self.vtable.createWindow(self.ptr, width, height);
    }
    pub fn setTitle(self: HostLoop, title: [*:0]const u8) void {
        self.vtable.setTitle(self.ptr, title);
    }
    pub fn present(self: HostLoop) void {
        self.vtable.present(self.ptr);
    }
    pub fn run(self: HostLoop) void {
        self.vtable.run(self.ptr);
    }
    pub fn quit(self: HostLoop) void {
        self.vtable.quit(self.ptr);
    }
};

// ---------------------------------------------------------------------------
// The desktop COMPOSITE: `Toolkit` = a `ChromeSurface` + a `HostLoop`.
// ---------------------------------------------------------------------------

/// The desktop composite toolkit: a `ChromeSurface` half plus a `HostLoop` half,
/// re-exposing the flat method surface the chrome calls. `chrome.zig` holds ONE
/// `Toolkit` and is UNCHANGED by the split — it still calls `createWindow`,
/// `embedView`, `run`, etc. on this value, which delegates each to the right
/// half. A desktop backend (`GtkToolkit`) provides both halves; a mobile backend
/// provides only a `ChromeSurface` and is driven WITHOUT a `Toolkit`/`HostLoop`.
pub const Toolkit = struct {
    surface: ChromeSurface,
    host: HostLoop,

    /// Compose a `Toolkit` from its two halves. A desktop backend that
    /// implements both hands its `ChromeSurface` and `HostLoop` here.
    pub fn compose(surface: ChromeSurface, host: HostLoop) Toolkit {
        return .{ .surface = surface, .host = host };
    }

    // --- host/loop half ---
    pub fn createWindow(self: Toolkit, width: c_int, height: c_int) void {
        self.host.createWindow(width, height);
    }
    pub fn setTitle(self: Toolkit, title: [*:0]const u8) void {
        self.host.setTitle(title);
    }
    pub fn present(self: Toolkit) void {
        self.host.present();
    }
    pub fn run(self: Toolkit) void {
        self.host.run();
    }
    pub fn quit(self: Toolkit) void {
        self.host.quit();
    }

    // --- chrome-surface half ---
    pub fn embedView(self: Toolkit, view: renderer.ViewHandle) void {
        self.surface.embedView(view);
    }
    pub fn setUrlText(self: Toolkit, text: [*:0]const u8) void {
        self.surface.setUrlText(text);
    }
    pub fn setBackEnabled(self: Toolkit, enabled: bool) void {
        self.surface.setBackEnabled(enabled);
    }
    pub fn setForwardEnabled(self: Toolkit, enabled: bool) void {
        self.surface.setForwardEnabled(enabled);
    }
    pub fn setChromeCallback(self: Toolkit, cb: ChromeCallback) void {
        self.surface.setChromeCallback(cb);
    }
};

// ---------------------------------------------------------------------------
// A fake `Toolkit` for headless chrome tests (no GTK, no display).
// ---------------------------------------------------------------------------

/// A minimal in-memory toolkit for the library's `zig build test` block. It
/// implements BOTH halves (`chromeSurface()` + `hostLoop()`) and composes them
/// into a desktop `Toolkit` via `toolkit()`; it records widget + window state
/// and lets a test SIMULATE user intents (`fireIntent`) so the chrome<->toolkit
/// contract can be asserted without GTK or a display. The real GTK chrome host
/// is exercised end-to-end by the `shell-test` build step under Xvfb.
///
/// It ALSO models the mobile shape: `chromeSurface()` alone is exactly what a
/// mobile toolkit provides — the chrome-surface half with no host/loop — so a
/// test can prove the surface half stands on its own (see the tests below).
pub const FakeToolkit = struct {
    url_text: [512]u8 = undefined,
    url_len: usize = 0,
    back_enabled: bool = false,
    forward_enabled: bool = false,
    embedded_view: ?renderer.ViewHandle = null,
    window_created: bool = false,
    running: bool = false,
    cb: ?ChromeCallback = null,

    /// The chrome-surface half (widgets + intents). A mobile toolkit provides
    /// ONLY this.
    pub fn chromeSurface(self: *FakeToolkit) ChromeSurface {
        return .{ .ptr = self, .vtable = &surface_vtable };
    }

    /// The host/loop half (window + main loop). Desktop-only.
    pub fn hostLoop(self: *FakeToolkit) HostLoop {
        return .{ .ptr = self, .vtable = &host_vtable };
    }

    /// The composed desktop toolkit (both halves).
    pub fn toolkit(self: *FakeToolkit) Toolkit {
        return Toolkit.compose(self.chromeSurface(), self.hostLoop());
    }

    /// Simulate a user intent arriving from the (fake) chrome host.
    pub fn fireIntent(self: *FakeToolkit, intent: ChromeIntent) void {
        if (self.cb) |cb| cb.onIntent(cb.ctx, intent);
    }

    /// The URL bar's current text (for assertions).
    pub fn urlText(self: *FakeToolkit) []const u8 {
        return self.url_text[0..self.url_len];
    }

    const surface_vtable = ChromeSurface.VTable{
        .embedView = embedView,
        .setUrlText = setUrlText,
        .setBackEnabled = setBackEnabled,
        .setForwardEnabled = setForwardEnabled,
        .setChromeCallback = setChromeCallback,
    };

    const host_vtable = HostLoop.VTable{
        .createWindow = createWindow,
        .setTitle = setTitle,
        .present = present,
        .run = run,
        .quit = quit,
    };

    fn createWindow(ctx: *anyopaque, width: c_int, height: c_int) void {
        _ = width;
        _ = height;
        const self: *FakeToolkit = @ptrCast(@alignCast(ctx));
        self.window_created = true;
    }
    fn setTitle(ctx: *anyopaque, title: [*:0]const u8) void {
        _ = ctx;
        _ = title;
    }
    fn embedView(ctx: *anyopaque, view: renderer.ViewHandle) void {
        const self: *FakeToolkit = @ptrCast(@alignCast(ctx));
        self.embedded_view = view;
    }
    fn present(ctx: *anyopaque) void {
        _ = ctx;
    }
    fn run(ctx: *anyopaque) void {
        const self: *FakeToolkit = @ptrCast(@alignCast(ctx));
        self.running = true;
    }
    fn quit(ctx: *anyopaque) void {
        const self: *FakeToolkit = @ptrCast(@alignCast(ctx));
        self.running = false;
    }
    fn setUrlText(ctx: *anyopaque, text: [*:0]const u8) void {
        const self: *FakeToolkit = @ptrCast(@alignCast(ctx));
        const slice = std.mem.span(text);
        const n = @min(slice.len, self.url_text.len);
        @memcpy(self.url_text[0..n], slice[0..n]);
        self.url_len = n;
    }
    fn setBackEnabled(ctx: *anyopaque, enabled: bool) void {
        const self: *FakeToolkit = @ptrCast(@alignCast(ctx));
        self.back_enabled = enabled;
    }
    fn setForwardEnabled(ctx: *anyopaque, enabled: bool) void {
        const self: *FakeToolkit = @ptrCast(@alignCast(ctx));
        self.forward_enabled = enabled;
    }
    fn setChromeCallback(ctx: *anyopaque, cb: ChromeCallback) void {
        const self: *FakeToolkit = @ptrCast(@alignCast(ctx));
        self.cb = cb;
    }
};

test "FakeToolkit: the composed toolkit records widget + window state and delivers intents" {
    var ft = FakeToolkit{};
    const tk = ft.toolkit();

    tk.createWindow(1024, 768);
    try std.testing.expect(ft.window_created);

    tk.setUrlText("https://x.example/");
    try std.testing.expectEqualStrings("https://x.example/", ft.urlText());

    tk.setBackEnabled(true);
    try std.testing.expect(ft.back_enabled);

    const Sink = struct {
        got_reload: bool = false,
        fn onIntent(ctx: *anyopaque, intent: ChromeIntent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (intent == .reload) self.got_reload = true;
        }
    };
    var sink = Sink{};
    tk.setChromeCallback(.{ .ctx = &sink, .onIntent = Sink.onIntent });
    ft.fireIntent(.reload);
    try std.testing.expect(sink.got_reload);
}

test "ChromeSurface: the surface half stands alone (the mobile shape, no host/loop)" {
    // A mobile toolkit provides ONLY the chrome-surface half. Prove the widgets +
    // intents work through `ChromeSurface` with no `HostLoop`/`Toolkit` in sight.
    var ft = FakeToolkit{};
    const surface = ft.chromeSurface();

    surface.setUrlText("https://mobile.example/");
    try std.testing.expectEqualStrings("https://mobile.example/", ft.urlText());

    surface.setForwardEnabled(true);
    try std.testing.expect(ft.forward_enabled);

    const view_marker: *u8 = @constCast(&@as(u8, 7));
    surface.embedView(@ptrCast(view_marker));
    try std.testing.expect(ft.embedded_view != null);

    const Sink = struct {
        got_back: bool = false,
        fn onIntent(ctx: *anyopaque, intent: ChromeIntent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (intent == .back) self.got_back = true;
        }
    };
    var sink = Sink{};
    surface.setChromeCallback(.{ .ctx = &sink, .onIntent = Sink.onIntent });
    ft.fireIntent(.back);
    try std.testing.expect(sink.got_back);

    // The surface half never touched the window: no host/loop is required.
    try std.testing.expect(!ft.window_created);
    try std.testing.expect(!ft.running);
}

test "Toolkit.compose: delegates each call to the right half" {
    var ft = FakeToolkit{};
    // Compose explicitly from the two halves (the desktop backend's job).
    const tk = Toolkit.compose(ft.chromeSurface(), ft.hostLoop());

    tk.present(); // host/loop half — no observable state, just must not crash
    tk.run();
    try std.testing.expect(ft.running); // host/loop half toggled running
    tk.quit();
    try std.testing.expect(!ft.running);

    tk.setBackEnabled(true); // chrome-surface half
    try std.testing.expect(ft.back_enabled);
}
