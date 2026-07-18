//! `IosWebviewRenderer`: the `Renderer` seam (renderer.zig) implemented over a
//! `WKWebView` on iOS (spec `explore-mobile-shell`, Q3/story 4; ADR-0005,
//! ADR-0006). This is the iOS twin of the desktop `SystemWebviewRenderer`
//! (WebKitGTK): it satisfies the SAME pinned `Renderer` VTable, so everything
//! above the seam (the chrome, later the Ethereum provider + IPFS) stays
//! backend-agnostic and never learns it is talking to a `WKWebView`.
//!
//! ## Why this backend reaches the webview through a C-ABI ops table
//!
//! On desktop the backend is Zig calling WebKitGTK's C symbols DIRECTLY — same
//! language, one translation unit. On iOS the `WKWebView` / `WKNavigationDelegate`
//! live on the Obj-C/Swift side, and the pinned iOS toolchain (task
//! `ios-toolchain-crosslink`) has SWIFT own the `WKWebView` while ZIG owns the
//! portable core over a C-ABI (`src/mobile_abi.zig`). So the iOS `Renderer`
//! backend cannot `@cInclude` WebKit and call it inline the way the GTK backend
//! does; instead it holds a small **platform-ops table** (`WkPlatform`) of
//! C-ABI function pointers the Swift shell installs at construction, and the
//! nav-delegate callbacks flow BACK into this backend (which maps them to the
//! seam's `LifecycleEvent`s). The physical `WKWebView` calls live in exactly
//! ONE Swift file (`mobile/ios/Sources/WKWebViewBackend.swift`); THIS backend is
//! still the sole thing above the FFI that drives them, so the "the backend is
//! the only WKWebView toucher" discipline holds across the language boundary —
//! it is just split across the C-ABI the toolchain already pinned. (Decision +
//! alternatives recorded in
//! `work/notes/observations/ios-renderer-backend-c-abi-ops-table-decision-2026-07-18.md`,
//! linked from the done record; the alternative — calling the Obj-C runtime from
//! Zig — was rejected as fighting the settled toolchain.)
//!
//! The `WKNavigationDelegate` → `LifecycleEvent` mapping mirrors the GTK backend's
//! signal → event mapping:
//!   - `didStartProvisionalNavigation`  -> `.load_changed{ .started }`
//!   - `didCommit`                       -> `.load_changed{ .committed }`
//!   - `didFinish`                       -> `.load_changed{ .finished }`
//!   - `didFail` / `didFailProvisional`  -> `.load_changed{ .failed }`
//!   - `observeValue(title)` / `(url)`   -> `.title_changed` / `.uri_changed`
//!   - `observeValue(estimatedProgress)` -> `.progress_changed`
//! `view()` returns the `WKWebView`'s `UIView*` as the OPAQUE `ViewHandle` (the
//! Q3 decision: keep it opaque and prove it carries a mobile native view).
//!
//! Only the narrowest slice needed for spec story 4 (navigate + a `.finished`
//! event + a non-blank snapshot) is wired end-to-end here; the two web3 hooks
//! (`injectUserScript`/`setScriptMessageHandler`/`evaluateScript`/`registerScheme`)
//! forward to the ops table too, but proving THEM on iOS is `mobile-web3-hooks-parity`.

const std = @import("std");
const seam = @import("renderer.zig");

/// The C-ABI ops table the native (Swift) side installs, so this Zig backend can
/// drive a `WKWebView` it does not own. Every field is a C function pointer with
/// an opaque `wk` cookie (the Swift-side webview coordinator). This is the ONLY
/// surface the backend uses to touch the webview; the Swift file behind these
/// pointers is the sole importer of `WebKit`/`UIKit`.
pub const WkPlatform = extern struct {
    /// The Swift-side coordinator cookie handed to every op (identifies the
    /// `WKWebView` + its delegate). Opaque to Zig.
    wk: *anyopaque,

    /// The `WKWebView`'s `UIView*`, returned across the seam as the opaque
    /// `ViewHandle`. Non-null once the webview exists.
    view: *anyopaque,

    // --- navigation ---
    navigate: *const fn (wk: *anyopaque, uri: [*:0]const u8) callconv(.c) void,
    reload: *const fn (wk: *anyopaque) callconv(.c) void,
    stop: *const fn (wk: *anyopaque) callconv(.c) void,
    goBack: *const fn (wk: *anyopaque) callconv(.c) void,
    goForward: *const fn (wk: *anyopaque) callconv(.c) void,
    canGoBack: *const fn (wk: *anyopaque) callconv(.c) bool,
    canGoForward: *const fn (wk: *anyopaque) callconv(.c) bool,
    setViewportSize: *const fn (wk: *anyopaque, width: c_int, height: c_int) callconv(.c) void,

    // --- script-message bridge + custom-scheme hook (ADR-0005) ---
    // Forwarded for seam completeness; proving them on iOS is a separate task
    // (`mobile-web3-hooks-parity`). Kept on the ops table so `WezigRenderer`'s
    // iOS story and the hooks task have the boundary already pinned.
    injectUserScript: *const fn (wk: *anyopaque, source: [*:0]const u8) callconv(.c) void,
    evaluateScript: *const fn (wk: *anyopaque, source: [*:0]const u8) callconv(.c) void,
};

/// A `Renderer` backed by ONE `WKWebView` (driven through `WkPlatform`). Construct
/// with `init` (handing the ops table the Swift shell installed), obtain the seam
/// value with `renderer()`, and hand THAT to the chrome. The chrome never sees
/// the `WKWebView`; it flows to the toolkit only as an opaque `ViewHandle`.
pub const IosWebviewRenderer = struct {
    platform: WkPlatform,
    cb: ?seam.LifecycleCallback = null,

    pub fn init(platform: WkPlatform) IosWebviewRenderer {
        return .{ .platform = platform };
    }

    pub fn renderer(self: *IosWebviewRenderer) seam.Renderer {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // --- native -> seam: the WKNavigationDelegate callbacks map to events ---
    // The Swift delegate calls THESE (through the exported C-ABI thunks in
    // `mobile_abi.zig`) so the mapping lives on the Zig side of the seam, exactly
    // like the GTK backend's `onLoadChanged`.

    /// A load-state transition arrived from the nav delegate. `uri` may be null
    /// very early (before the provisional URL is known), matching the seam's
    /// `?[]const u8` contract.
    pub fn onLoadState(self: *IosWebviewRenderer, state: seam.LoadState, uri: ?[]const u8) void {
        self.emit(.{ .load_changed = .{ .state = state, .uri = uri } });
    }

    /// The document title changed (KVO on `WKWebView.title`).
    pub fn onTitle(self: *IosWebviewRenderer, title: []const u8) void {
        self.emit(.{ .title_changed = title });
    }

    /// The document URL changed (KVO on `WKWebView.URL`).
    pub fn onUri(self: *IosWebviewRenderer, uri: []const u8) void {
        self.emit(.{ .uri_changed = uri });
    }

    /// Load progress changed (KVO on `WKWebView.estimatedProgress`).
    pub fn onProgress(self: *IosWebviewRenderer, fraction: f64) void {
        self.emit(.{ .progress_changed = fraction });
    }

    fn emit(self: *IosWebviewRenderer, event: seam.LifecycleEvent) void {
        if (self.cb) |cb| cb.onEvent(cb.ctx, event);
    }

    const vtable = seam.Renderer.VTable{
        .navigate = navigate,
        .reload = reloadFn,
        .stop = stopFn,
        .goBack = goBack,
        .goForward = goForward,
        .canGoBack = canGoBack,
        .canGoForward = canGoForward,
        .view = viewHandle,
        .setViewportSize = setViewportSize,
        .setLifecycleCallback = setLifecycleCallback,
        .injectUserScript = injectUserScript,
        .setScriptMessageHandler = setScriptMessageHandler,
        .evaluateScript = evaluateScript,
        .registerScheme = registerScheme,
    };

    fn navigate(ctx: *anyopaque, uri: [*:0]const u8) void {
        const self: *IosWebviewRenderer = @ptrCast(@alignCast(ctx));
        self.platform.navigate(self.platform.wk, uri);
    }
    fn reloadFn(ctx: *anyopaque) void {
        const self: *IosWebviewRenderer = @ptrCast(@alignCast(ctx));
        self.platform.reload(self.platform.wk);
    }
    fn stopFn(ctx: *anyopaque) void {
        const self: *IosWebviewRenderer = @ptrCast(@alignCast(ctx));
        self.platform.stop(self.platform.wk);
    }
    fn goBack(ctx: *anyopaque) void {
        const self: *IosWebviewRenderer = @ptrCast(@alignCast(ctx));
        self.platform.goBack(self.platform.wk);
    }
    fn goForward(ctx: *anyopaque) void {
        const self: *IosWebviewRenderer = @ptrCast(@alignCast(ctx));
        self.platform.goForward(self.platform.wk);
    }
    fn canGoBack(ctx: *anyopaque) bool {
        const self: *IosWebviewRenderer = @ptrCast(@alignCast(ctx));
        return self.platform.canGoBack(self.platform.wk);
    }
    fn canGoForward(ctx: *anyopaque) bool {
        const self: *IosWebviewRenderer = @ptrCast(@alignCast(ctx));
        return self.platform.canGoForward(self.platform.wk);
    }
    fn viewHandle(ctx: *anyopaque) seam.ViewHandle {
        const self: *IosWebviewRenderer = @ptrCast(@alignCast(ctx));
        // The interactive view IS the WKWebView's UIView*; hand it across
        // opaquely (the Q3 decision: keep the handle `*anyopaque`).
        return self.platform.view;
    }
    fn setViewportSize(ctx: *anyopaque, width: c_int, height: c_int) void {
        const self: *IosWebviewRenderer = @ptrCast(@alignCast(ctx));
        self.platform.setViewportSize(self.platform.wk, width, height);
    }
    fn setLifecycleCallback(ctx: *anyopaque, cb: seam.LifecycleCallback) void {
        const self: *IosWebviewRenderer = @ptrCast(@alignCast(ctx));
        self.cb = cb;
    }

    // --- script-message bridge + custom-scheme hook (ADR-0005) ---
    // Forwarded to the ops table for seam completeness; the END-TO-END iOS proof
    // of these is `mobile-web3-hooks-parity`, not this task. `setScriptMessageHandler`
    // and `registerScheme` are seam methods `WezigRenderer` must satisfy too; on
    // iOS they need `WKScriptMessageHandler`/`WKURLSchemeHandler` wiring the hooks
    // task adds, so here they are inert placeholders (no-ops) rather than a half-
    // wired path the hooks task would have to unpick.

    fn injectUserScript(ctx: *anyopaque, source: [*:0]const u8) void {
        const self: *IosWebviewRenderer = @ptrCast(@alignCast(ctx));
        self.platform.injectUserScript(self.platform.wk, source);
    }
    fn setScriptMessageHandler(ctx: *anyopaque, name: [*:0]const u8, cb: seam.ScriptMessageCallback) void {
        _ = ctx;
        _ = name;
        _ = cb;
    }
    fn evaluateScript(ctx: *anyopaque, source: [*:0]const u8) void {
        const self: *IosWebviewRenderer = @ptrCast(@alignCast(ctx));
        self.platform.evaluateScript(self.platform.wk, source);
    }
    fn registerScheme(ctx: *anyopaque, scheme: [*:0]const u8, handler: seam.SchemeHandler) void {
        _ = ctx;
        _ = scheme;
        _ = handler;
    }
};

// ---------------------------------------------------------------------------
// Seam-contract test (headless, in `zig build test`): prove the backend maps a
// nav-delegate load sequence to the seam's `LifecycleEvent`s WITHOUT a WKWebView
// or a display, using a fake `WkPlatform`. This is the iOS twin of
// `renderer.zig`'s `FakeRenderer` lifecycle test; the REAL end-to-end proof (a
// live WKWebView renders a page) is the `ios-renderer-test` CI leg on a macos-14
// simulator, mirroring how the desktop `shell-test` proof stays out of `test`.
// ---------------------------------------------------------------------------

/// A fake `WkPlatform` for the headless contract test: records the last navigated
/// URI and a toy back/forward flag, so the seam methods are proven to reach the
/// ops table with NO webview. The nav-delegate → event mapping is driven directly
/// via the backend's `onLoadState`/... entry points (what the Swift delegate calls).
const FakeWk = struct {
    last_uri: [128]u8 = undefined,
    last_uri_len: usize = 0,
    navigated: bool = false,
    reloaded: bool = false,
    view_token: u8 = 0,

    fn navigate(wk: *anyopaque, uri: [*:0]const u8) callconv(.c) void {
        const self: *FakeWk = @ptrCast(@alignCast(wk));
        const slice = std.mem.span(uri);
        @memcpy(self.last_uri[0..slice.len], slice);
        self.last_uri_len = slice.len;
        self.navigated = true;
    }
    fn reload(wk: *anyopaque) callconv(.c) void {
        const self: *FakeWk = @ptrCast(@alignCast(wk));
        self.reloaded = true;
    }
    fn noop(wk: *anyopaque) callconv(.c) void {
        _ = wk;
    }
    fn falseFn(wk: *anyopaque) callconv(.c) bool {
        _ = wk;
        return false;
    }
    fn setViewportSize(wk: *anyopaque, width: c_int, height: c_int) callconv(.c) void {
        _ = wk;
        _ = width;
        _ = height;
    }
    fn withSource(wk: *anyopaque, source: [*:0]const u8) callconv(.c) void {
        _ = wk;
        _ = source;
    }

    fn platform(self: *FakeWk) WkPlatform {
        return .{
            .wk = self,
            .view = &self.view_token,
            .navigate = navigate,
            .reload = reload,
            .stop = noop,
            .goBack = noop,
            .goForward = noop,
            .canGoBack = falseFn,
            .canGoForward = falseFn,
            .setViewportSize = setViewportSize,
            .injectUserScript = withSource,
            .evaluateScript = withSource,
        };
    }
};

test "IosWebviewRenderer: navigate reaches the platform ops table" {
    var fake = FakeWk{};
    var ios = IosWebviewRenderer.init(fake.platform());
    const r = ios.renderer();

    r.navigate("https://page.example/");
    try std.testing.expect(fake.navigated);
    try std.testing.expectEqualStrings("https://page.example/", fake.last_uri[0..fake.last_uri_len]);

    r.reload();
    try std.testing.expect(fake.reloaded);
}

test "IosWebviewRenderer: nav-delegate callbacks map to the seam's .finished event" {
    // Mirror the desktop `shell-test` assertion at the seam-contract level: a
    // subscribed callback observes a `.finished` `LifecycleEvent` when the
    // (simulated) `WKNavigationDelegate` reports the load sequence.
    const Sink = struct {
        started: usize = 0,
        committed: usize = 0,
        finished: usize = 0,
        last_uri: [64]u8 = undefined,
        last_uri_len: usize = 0,
        fn onEvent(ctx: *anyopaque, event: seam.LifecycleEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (event) {
                .load_changed => |lc| switch (lc.state) {
                    .started => self.started += 1,
                    .committed => self.committed += 1,
                    .finished => self.finished += 1,
                    .failed => {},
                },
                .uri_changed => |u| {
                    @memcpy(self.last_uri[0..u.len], u);
                    self.last_uri_len = u.len;
                },
                else => {},
            }
        }
    };

    var fake = FakeWk{};
    var ios = IosWebviewRenderer.init(fake.platform());
    const r = ios.renderer();

    var sink = Sink{};
    r.setLifecycleCallback(.{ .ctx = &sink, .onEvent = Sink.onEvent });

    // The chrome drives the navigation through the seam...
    r.navigate("https://page.example/");
    // ...and the (simulated) WKNavigationDelegate reports the load sequence the
    // Swift delegate would deliver. This is exactly what the exported nav-event
    // thunks in `mobile_abi.zig` forward from Swift.
    const uri = "https://page.example/";
    ios.onLoadState(.started, uri);
    ios.onUri(uri);
    ios.onLoadState(.committed, uri);
    ios.onLoadState(.finished, uri);

    try std.testing.expectEqual(@as(usize, 1), sink.started);
    try std.testing.expectEqual(@as(usize, 1), sink.committed);
    try std.testing.expectEqual(@as(usize, 1), sink.finished);
    try std.testing.expectEqualStrings("https://page.example/", sink.last_uri[0..sink.last_uri_len]);
}

test "IosWebviewRenderer: view() returns the platform's opaque UIView handle" {
    var fake = FakeWk{};
    var ios = IosWebviewRenderer.init(fake.platform());
    const r = ios.renderer();
    // The handle is opaque (`*anyopaque`); the backend hands back exactly what
    // the platform installed as the WKWebView's UIView*.
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&fake.view_token)), r.view());
}

test "IosWebviewRenderer: a failed load surfaces .failed through the seam" {
    const Sink = struct {
        failed: usize = 0,
        fn onEvent(ctx: *anyopaque, event: seam.LifecycleEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (event == .load_changed and event.load_changed.state == .failed) self.failed += 1;
        }
    };
    var fake = FakeWk{};
    var ios = IosWebviewRenderer.init(fake.platform());
    const r = ios.renderer();
    var sink = Sink{};
    r.setLifecycleCallback(.{ .ctx = &sink, .onEvent = Sink.onEvent });
    ios.onLoadState(.failed, null);
    try std.testing.expectEqual(@as(usize, 1), sink.failed);
}
