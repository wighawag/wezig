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
//! ## The two web3 hooks (spec `explore-mobile-shell` stories 8,9; task
//! `mobile-web3-hooks-parity`)
//!
//! Both web3-load-bearing hooks now carry through this backend to the ops table,
//! mirroring the desktop `SystemWebviewRenderer` (WebKitGTK) mapping:
//!
//!   - **script-message bridge:** `injectUserScript` installs a page-world
//!     `WKUserScript` on the `WKUserContentController`; `setScriptMessageHandler`
//!     registers a named `WKScriptMessageHandler` (opening
//!     `window.webkit.messageHandlers.<name>`); `evaluateScript` runs JS back
//!     into the page. The page->native leg flows BACK up through
//!     `onScriptMessage` (the exported `wezig_ios_on_script_message` thunk in
//!     `mobile_abi.zig`), exactly like the nav-delegate callbacks. `WKScriptMessageHandler`
//!     already delivers `didReceive` on the MAIN queue, so — unlike Android —
//!     no thread marshalling is needed.
//!   - **custom-scheme interception:** `registerScheme` records a native scheme
//!     handler; the `WKURLSchemeHandler` the Swift shell installs calls back up
//!     through `onSchemeRequest` (the `wezig_ios_serve_scheme` thunk), which
//!     asks the seam handler for the body + content-type native serves.
//!
//! ## The iOS scheme-ordering constraint (surfaced at the seam — spec Q5)
//!
//! A `WKURLSchemeHandler` MUST be registered on the `WKWebViewConfiguration`
//! (`setURLSchemeHandler:forURLScheme:`) BEFORE the `WKWebView` is created —
//! `WKWebView` copies its configuration at init, so a handler set afterwards is
//! ignored and the scheme 404s. `registerScheme` on this backend therefore only
//! records the handler + reaches the ops table's `registerScheme`, which the
//! Swift shell must call while assembling the configuration (before the webview
//! exists). This is the ONE ordering constraint the iOS hook has that WebKitGTK
//! and Android do not, and it is why the ops table carries a `registerScheme`
//! that the shell wires at configuration time rather than at navigate time.
//! (Recorded as a finding in
//! `work/notes/findings/ios-wkurlschemehandler-registration-ordering-2026-07-18.md`.)

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
    // The two web3 hooks (spec stories 8,9). Mirror the desktop backend's
    // mapping onto WebKitGTK; here they cross the C-ABI to the Swift shell that
    // owns the `WKUserContentController` / `WKURLSchemeHandler`.
    injectUserScript: *const fn (wk: *anyopaque, source: [*:0]const u8) callconv(.c) void,
    evaluateScript: *const fn (wk: *anyopaque, source: [*:0]const u8) callconv(.c) void,
    /// Register the page->native channel `name` on the `WKUserContentController`
    /// (`addScriptMessageHandler:name:` -> `window.webkit.messageHandlers.<name>`).
    /// The page's posts flow BACK to `onScriptMessage` (via the exported thunk).
    setScriptMessageHandler: *const fn (wk: *anyopaque, name: [*:0]const u8) callconv(.c) void,
    /// Register the custom URI scheme `scheme` with the `WKURLSchemeHandler` the
    /// Swift shell installed on the `WKWebViewConfiguration` BEFORE the webview
    /// was created (the ordering constraint above). Each request flows back to
    /// `onSchemeRequest`, which asks the seam handler for the served bytes.
    registerScheme: *const fn (wk: *anyopaque, scheme: [*:0]const u8) callconv(.c) void,
};

/// A `Renderer` backed by ONE `WKWebView` (driven through `WkPlatform`). Construct
/// with `init` (handing the ops table the Swift shell installed), obtain the seam
/// value with `renderer()`, and hand THAT to the chrome. The chrome never sees
/// the `WKWebView`; it flows to the toolkit only as an opaque `ViewHandle`.
pub const IosWebviewRenderer = struct {
    platform: WkPlatform,
    cb: ?seam.LifecycleCallback = null,
    /// The single page->native script-message handler (script bridge, ADR-0005).
    /// One channel today (the provider's `request` channel), matching the desktop
    /// backend; a set can replace this if more channels are ever needed.
    msg_cb: ?seam.ScriptMessageCallback = null,
    /// The single custom-scheme handler (request interception, ADR-0005).
    scheme_handler: ?seam.SchemeHandler = null,

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

    // --- native <- page: the WKScriptMessageHandler / WKURLSchemeHandler
    //     callbacks map to the seam's bridge/scheme callbacks (script bridge +
    //     custom-scheme hook, ADR-0005). The Swift shell calls THESE through the
    //     exported C-ABI thunks in `mobile_abi.zig`, so the page->native leg and
    //     the scheme-serve leg live on the Zig side of the seam — exactly like
    //     the GTK backend's `onScriptMessage` / `onSchemeRequest`.

    /// A page-world message arrived on channel `name` (the page called
    /// `window.webkit.messageHandlers.<name>.postMessage(body)`). `WKScriptMessageHandler`
    /// delivers on the main queue, so no marshalling is needed. `name`/`body`
    /// are borrowed for this call (the seam contract).
    pub fn onScriptMessage(self: *IosWebviewRenderer, name: []const u8, body: []const u8) void {
        const cb = self.msg_cb orelse return;
        cb.onMessage(cb.ctx, name, body);
    }

    /// A request for the registered custom scheme arrived (`WKURLSchemeHandler`
    /// `startURLSchemeTask`). Ask the seam handler for the native body +
    /// content-type; returns null if no scheme handler is registered (the Swift
    /// shell then fails the task). The returned slices are borrowed from the
    /// handler until it is next called (the seam contract), so Swift copies them
    /// into the `WKURLSchemeTask` response immediately.
    pub fn onSchemeRequest(self: *IosWebviewRenderer, uri: []const u8) ?seam.SchemeResponse {
        const h = self.scheme_handler orelse return null;
        return h.onRequest(h.ctx, uri);
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
    // The two web3 hooks (spec stories 8,9), the iOS twin of the desktop
    // WebKitGTK mapping. `setScriptMessageHandler`/`registerScheme` record the
    // seam callback here (so the page->native + scheme-serve legs re-enter Zig)
    // and reach the ops table so the Swift shell installs the platform handler.

    fn injectUserScript(ctx: *anyopaque, source: [*:0]const u8) void {
        const self: *IosWebviewRenderer = @ptrCast(@alignCast(ctx));
        self.platform.injectUserScript(self.platform.wk, source);
    }
    fn setScriptMessageHandler(ctx: *anyopaque, name: [*:0]const u8, cb: seam.ScriptMessageCallback) void {
        const self: *IosWebviewRenderer = @ptrCast(@alignCast(ctx));
        self.msg_cb = cb;
        // Open `window.webkit.messageHandlers.<name>` on the WKUserContentController;
        // the page's posts flow back to `onScriptMessage` via the exported thunk.
        self.platform.setScriptMessageHandler(self.platform.wk, name);
    }
    fn evaluateScript(ctx: *anyopaque, source: [*:0]const u8) void {
        const self: *IosWebviewRenderer = @ptrCast(@alignCast(ctx));
        self.platform.evaluateScript(self.platform.wk, source);
    }
    fn registerScheme(ctx: *anyopaque, scheme: [*:0]const u8, handler: seam.SchemeHandler) void {
        const self: *IosWebviewRenderer = @ptrCast(@alignCast(ctx));
        self.scheme_handler = handler;
        // The Swift shell must have installed the WKURLSchemeHandler on the
        // WKWebViewConfiguration BEFORE the webview was created (the ordering
        // constraint in the module doc); this records the seam handler + tells
        // the shell which scheme name to serve back through `onSchemeRequest`.
        self.platform.registerScheme(self.platform.wk, scheme);
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

    // --- web3-hook state (the bridge + scheme ops the Swift shell installs) ---
    /// The last user script injected via `injectUserScript` (borrowed span).
    injected: ?[]const u8 = null,
    /// The last script `evaluateScript` ran (borrowed span) — stands in for
    /// "native posted a reply back into the page".
    last_evaluated: ?[]const u8 = null,
    /// The channel name the WKUserContentController handler was registered under.
    msg_channel: ?[]const u8 = null,
    /// The custom scheme registered on the WKWebViewConfiguration.
    registered_scheme: ?[]const u8 = null,

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
    fn inject(wk: *anyopaque, source: [*:0]const u8) callconv(.c) void {
        const self: *FakeWk = @ptrCast(@alignCast(wk));
        self.injected = std.mem.span(source);
    }
    fn evaluate(wk: *anyopaque, source: [*:0]const u8) callconv(.c) void {
        const self: *FakeWk = @ptrCast(@alignCast(wk));
        self.last_evaluated = std.mem.span(source);
    }
    fn setMsgHandler(wk: *anyopaque, name: [*:0]const u8) callconv(.c) void {
        const self: *FakeWk = @ptrCast(@alignCast(wk));
        self.msg_channel = std.mem.span(name);
    }
    fn regScheme(wk: *anyopaque, scheme: [*:0]const u8) callconv(.c) void {
        const self: *FakeWk = @ptrCast(@alignCast(wk));
        self.registered_scheme = std.mem.span(scheme);
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
            .injectUserScript = inject,
            .evaluateScript = evaluate,
            .setScriptMessageHandler = setMsgHandler,
            .registerScheme = regScheme,
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

test "IosWebviewRenderer: the script-message bridge round-trips a message both ways" {
    // The iOS twin of the desktop `shell-bridge-test`, proven headlessly at the
    // seam-contract level (no WKWebView, no simulator): the native->page setup
    // leg injects `window.wezig`; `setScriptMessageHandler` opens the channel on
    // the (fake) WKUserContentController; the page->native leg posts a value that
    // reaches native via `onScriptMessage` (what the WKScriptMessageHandler does);
    // the native->page reply leg evaluates JS back into the page.
    const Native = struct {
        got_name: [32]u8 = undefined,
        got_name_len: usize = 0,
        got_body: [32]u8 = undefined,
        got_body_len: usize = 0,
        fn onMessage(ctx: *anyopaque, name: []const u8, body: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            @memcpy(self.got_name[0..name.len], name);
            self.got_name_len = name.len;
            @memcpy(self.got_body[0..body.len], body);
            self.got_body_len = body.len;
        }
    };

    var fake = FakeWk{};
    var ios = IosWebviewRenderer.init(fake.platform());
    const r = ios.renderer();

    // native->page setup: inject the page-world object (reaches the ops table).
    r.injectUserScript(
        \\window.wezig = { ping: function(v) {
        \\  window.webkit.messageHandlers.wezig.postMessage(v);
        \\} };
    );
    try std.testing.expect(fake.injected != null);

    // page->native: register the channel (opens window.webkit.messageHandlers.wezig)
    // and simulate the WKScriptMessageHandler delivering the page's post.
    var native = Native{};
    r.setScriptMessageHandler("wezig", .{ .ctx = &native, .onMessage = Native.onMessage });
    try std.testing.expectEqualStrings("wezig", fake.msg_channel.?);
    ios.onScriptMessage("wezig", "ping-from-page");
    try std.testing.expectEqualStrings("wezig", native.got_name[0..native.got_name_len]);
    try std.testing.expectEqualStrings("ping-from-page", native.got_body[0..native.got_body_len]);

    // native->page reply: native evaluates JS back into the page (ops table).
    r.evaluateScript("window.wezig.ping('pong-from-native');");
    try std.testing.expectEqualStrings("window.wezig.ping('pong-from-native');", fake.last_evaluated.?);
}

test "IosWebviewRenderer: a registered custom scheme is served from native" {
    // The iOS twin of the desktop `shell-scheme-test`, at the seam-contract
    // level: `registerScheme` records the seam handler AND reaches the ops table
    // (the Swift shell installs the WKURLSchemeHandler on the config BEFORE the
    // webview is created — the ordering constraint); a request re-enters via
    // `onSchemeRequest` and is served the native body + content-type.
    const Native = struct {
        fn onRequest(ctx: *anyopaque, uri: []const u8) seam.SchemeResponse {
            _ = ctx;
            _ = uri;
            return .{ .body = "<h1>hello from native</h1>", .content_type = "text/html" };
        }
    };

    var fake = FakeWk{};
    var ios = IosWebviewRenderer.init(fake.platform());
    const r = ios.renderer();

    var native: u8 = 0;
    r.registerScheme("wezig-test", .{ .ctx = &native, .onRequest = Native.onRequest });
    try std.testing.expectEqualStrings("wezig-test", fake.registered_scheme.?);

    const resp = ios.onSchemeRequest("wezig-test://hello").?;
    try std.testing.expectEqualStrings("<h1>hello from native</h1>", resp.body);
    try std.testing.expectEqualStrings("text/html", resp.content_type);

    // Before registration a scheme request has no handler (Swift fails the task).
    var bare = FakeWk{};
    var bare_ios = IosWebviewRenderer.init(bare.platform());
    try std.testing.expectEqual(@as(?seam.SchemeResponse, null), bare_ios.onSchemeRequest("wezig-test://x"));
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
