//! The chrome/toolkit seam: the chrome-host boundary (ADR-0006).
//!
//! The chrome (one window, a URL bar, back/forward buttons) talks to THIS
//! interface for everything it puts on screen, never to GTK directly. `GtkToolkit`
//! is the first and only implementation today; a Qt or a Zig-native chrome layer
//! implements the SAME interface later. Crucially, **windowing sits behind this
//! seam** (story 6): GTK owns the shell WINDOW now, but the chrome reaches it
//! through `Toolkit` (it never calls `gtk_window_new`), so the windowing layer is
//! a swappable component. (SDL/native windowing from ADR-0004 is a SEPARATE leaf,
//! the `WezigRenderer`-direct harness, untouched by this seam.)
//!
//! This file imports NO GTK binding: it is pure interface, exactly like
//! `renderer.zig`. The two seams are independent: `Renderer` owns the CONTENT
//! backend, `Toolkit` owns the CHROME host; the chrome is the only place that
//! holds both and wires them together.
//!
//! ## Shape (vtable, like `Renderer` / `PaintBackend`)
//!
//! `Toolkit` is a `{ ptr, vtable }` value. The widget set is MINIMAL: exactly
//! what a one-window, URL-bar, back/forward chrome needs.
//!
//!   - window:   `createWindow` (the shell window; windowing behind the seam),
//!               `setTitle`, `embedView` (host the renderer's opaque view),
//!               `present`, `run` / `quit` (the chrome-host main loop)
//!   - widgets:  `setUrlText` / `getUrlText` (the URL bar), `setBackEnabled` /
//!               `setForwardEnabled` (the nav buttons' sensitivity)
//!   - events:   `setChromeCallback` delivers user intents (URL entered, a nav
//!               button clicked, window closed) UP to the chrome, so the chrome
//!               reacts by calling the `Renderer` seam.
//!
//! The URL bar text and button-enabled state are toolkit-owned widget state the
//! chrome sets; the chrome never reaches into a `GtkEntry`/`GtkButton`.

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

/// The `Toolkit` seam value: a context pointer plus a function-pointer table.
pub const Toolkit = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // --- window (windowing behind the seam, story 6) ---
        /// Create the shell window at `width` x `height`. The toolkit owns the
        /// native window; the chrome never calls a windowing API directly.
        createWindow: *const fn (ctx: *anyopaque, width: c_int, height: c_int) void,
        /// Set the shell window's title.
        setTitle: *const fn (ctx: *anyopaque, title: [*:0]const u8) void,
        /// Embed the renderer's opaque interactive view into the window's
        /// content slot (below the toolbar). The toolkit interprets the handle;
        /// the chrome only passes it through from `Renderer.view()`.
        embedView: *const fn (ctx: *anyopaque, view: renderer.ViewHandle) void,
        /// Show the window on screen.
        present: *const fn (ctx: *anyopaque) void,
        /// Run the chrome-host main loop until `quit` is called (or the window
        /// closes). This is the windowing event loop, owned by the toolkit.
        run: *const fn (ctx: *anyopaque) void,
        /// Ask the main loop to stop (from an intent handler, e.g. on `closed`).
        quit: *const fn (ctx: *anyopaque) void,

        // --- widgets ---
        /// Set the URL bar's displayed text (e.g. after a `uri_changed` event).
        setUrlText: *const fn (ctx: *anyopaque, text: [*:0]const u8) void,
        /// Enable/disable the Back and Forward buttons.
        setBackEnabled: *const fn (ctx: *anyopaque, enabled: bool) void,
        setForwardEnabled: *const fn (ctx: *anyopaque, enabled: bool) void,

        // --- events ---
        /// Subscribe the chrome to user intents. At most one sink.
        setChromeCallback: *const fn (ctx: *anyopaque, cb: ChromeCallback) void,
    };

    pub fn createWindow(self: Toolkit, width: c_int, height: c_int) void {
        self.vtable.createWindow(self.ptr, width, height);
    }
    pub fn setTitle(self: Toolkit, title: [*:0]const u8) void {
        self.vtable.setTitle(self.ptr, title);
    }
    pub fn embedView(self: Toolkit, view: renderer.ViewHandle) void {
        self.vtable.embedView(self.ptr, view);
    }
    pub fn present(self: Toolkit) void {
        self.vtable.present(self.ptr);
    }
    pub fn run(self: Toolkit) void {
        self.vtable.run(self.ptr);
    }
    pub fn quit(self: Toolkit) void {
        self.vtable.quit(self.ptr);
    }
    pub fn setUrlText(self: Toolkit, text: [*:0]const u8) void {
        self.vtable.setUrlText(self.ptr, text);
    }
    pub fn setBackEnabled(self: Toolkit, enabled: bool) void {
        self.vtable.setBackEnabled(self.ptr, enabled);
    }
    pub fn setForwardEnabled(self: Toolkit, enabled: bool) void {
        self.vtable.setForwardEnabled(self.ptr, enabled);
    }
    pub fn setChromeCallback(self: Toolkit, cb: ChromeCallback) void {
        self.vtable.setChromeCallback(self.ptr, cb);
    }
};

// ---------------------------------------------------------------------------
// A fake `Toolkit` for headless chrome tests (no GTK, no display).
// ---------------------------------------------------------------------------

/// A minimal in-memory `Toolkit` for the library's `zig build test` block: it
/// records widget state (URL text, button-enabled flags, the embedded view) and
/// lets a test SIMULATE user intents (`fireIntent`) so the chrome<->toolkit
/// contract can be asserted without GTK or a display. The real GTK chrome host
/// is exercised end-to-end by the `shell-test` build step under Xvfb.
pub const FakeToolkit = struct {
    url_text: [512]u8 = undefined,
    url_len: usize = 0,
    back_enabled: bool = false,
    forward_enabled: bool = false,
    embedded_view: ?renderer.ViewHandle = null,
    window_created: bool = false,
    running: bool = false,
    cb: ?ChromeCallback = null,

    pub fn toolkit(self: *FakeToolkit) Toolkit {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Simulate a user intent arriving from the (fake) chrome host.
    pub fn fireIntent(self: *FakeToolkit, intent: ChromeIntent) void {
        if (self.cb) |cb| cb.onIntent(cb.ctx, intent);
    }

    /// The URL bar's current text (for assertions).
    pub fn urlText(self: *FakeToolkit) []const u8 {
        return self.url_text[0..self.url_len];
    }

    const vtable = Toolkit.VTable{
        .createWindow = createWindow,
        .setTitle = setTitle,
        .embedView = embedView,
        .present = present,
        .run = run,
        .quit = quit,
        .setUrlText = setUrlText,
        .setBackEnabled = setBackEnabled,
        .setForwardEnabled = setForwardEnabled,
        .setChromeCallback = setChromeCallback,
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

test "FakeToolkit: records widget state and delivers intents" {
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
