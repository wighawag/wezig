//! The iOS shell C-ABI: the real-app entry points the Xcode/SwiftPM project's
//! `WKWebViewShellController` (a `UIViewController`) links against to stand up a
//! genuine (if minimal) mobile browser — the iOS half of spec `build-mobile-shell`
//! (stories 1/3/4/5/6). This is the iOS twin of the desktop `shell_main.zig`
//! wiring, but host-loop-free: the OS owns the window + run loop (ADR-0008), so
//! the `UIViewController` drives THIS entry point instead of a `HostLoop`.
//!
//! ## What it wires (all THROUGH the two seams — no raw WKWebView above the FFI)
//!
//! `wezig_ios_shell_start` constructs the three shared-core pieces and hands the
//! chrome the two seam values:
//!
//!   - the `IosWebviewRenderer` backend (`src/ios_webview_renderer.zig`) over the
//!     Swift-owned `WKWebView`, via the `WkPlatform` ops table the shell installs;
//!   - the `MobileChromeSurface` (`src/mobile_chrome_surface.zig`) over the
//!     Swift-owned URL field / back-forward toolbar / content container, via the
//!     `EmbedPlatform` ops table;
//!   - the shared `MobileChrome` (`src/mobile_chrome.zig`) — the mobile analogue
//!     of `chrome.zig` — composed over those two seams. `attach` subscribes it to
//!     both event streams; `build` embeds the renderer's opaque `ViewHandle`
//!     through the surface, sizes the viewport, and navigates the start URI.
//!
//! From then on the shell is a thin relay:
//!
//!   - **user intents → renderer:** the `UIViewController`'s URL field / Back /
//!     Forward / Reload controls call `wezig_ios_shell_navigate` / `_go_back` /
//!     `_go_forward` / `_reload`, which fire a `ChromeIntent` INTO the surface;
//!     the chrome turns each into a `Renderer` call. The shell NEVER calls the
//!     `WKWebView` directly — navigation crosses the seams exactly as desktop.
//!   - **renderer lifecycle → widgets:** the `WKNavigationDelegate` callbacks
//!     Swift forwards (`wezig_ios_shell_on_load_state` / `_on_title` / `_on_uri`)
//!     re-enter the backend, which emits `LifecycleEvent`s the chrome reflects
//!     into the surface's URL text + Back/Forward sensitivity (story 5).
//!
//! ## The iOS scheme-ordering constraint, threaded at config-build time (story 4)
//!
//! This shell registers only a TRIVIAL MARKER scheme (`wezig://`) to PROVE the
//! wiring — there is no real scheme content here. But it honours the iOS finding
//! (`work/notes/findings/ios-wkurlschemehandler-registration-ordering-2026-07-18.md`
//! / `ios_webview_renderer.zig`'s module doc): a `WKURLSchemeHandler` MUST be
//! installed on the `WKWebViewConfiguration` BEFORE the `WKWebView` is created.
//! So the shell takes the marker scheme name as a start-time argument and calls
//! `Renderer.registerScheme` — which reaches `WkPlatform.registerScheme` — during
//! `wezig_ios_shell_start`, BEFORE the Swift shell has created the webview. The
//! Swift side threads the scheme set into the config at build time and only then
//! constructs the `WKWebView` (the `SchemeProof.swift` ordering, now in the real
//! app). This keeps the wiring correct for the day a real scheme (`ipfs://`)
//! lands on a per-`PageContext` webview (the finding's downstream implication).
//!
//! ## App lifecycle / state restoration is HOST-ONLY (ADR-0010, Resolved dec. 1)
//!
//! Background→foreground page-state restoration is a HOST concern ABOVE this
//! seam: the `UIViewController` relies on the native `WKWebView`'s own state
//! save-restore (the OS re-materialises the page/scroll/history) and, if it must
//! re-drive the seam, calls the EXISTING `wezig_ios_shell_navigate` — no
//! `suspend`/`resume`/state method is added to the `Renderer` seam (ADR-0010).
//! This file adds NO lifecycle entry point: there is nothing for the seam to do
//! that the native webview + the existing navigate op do not already cover.
//!
//! One shell instance runs at a time (the narrowest real case — one visible
//! page; N-context tabs are Slice B), so the state is a single module-level
//! value the exported thunks operate on, mirroring `mobile_abi.zig`'s proofs.

const std = @import("std");
const seam = @import("renderer.zig");
const toolkit = @import("toolkit.zig");
const IosWebviewRenderer = @import("ios_webview_renderer.zig").IosWebviewRenderer;
const WkPlatform = @import("ios_webview_renderer.zig").WkPlatform;
const MobileChromeSurface = @import("mobile_chrome_surface.zig").MobileChromeSurface;
const MobileChrome = @import("mobile_chrome.zig").MobileChrome;

/// The iOS shell's seam-level state. Holds the backend, the chrome-surface, and
/// the shared mobile chrome composed over them. `MobileChrome` stores the two
/// seam VALUES (not pointers to these fields), and `IosWebviewRenderer` /
/// `MobileChromeSurface` are pointer-identity-stable here (module-level), so the
/// chrome's `.ctx` back-pointers into `ios`/`surface` stay valid for the app's
/// lifetime.
const IosShell = struct {
    ios: IosWebviewRenderer,
    surface: MobileChromeSurface,
    chrome: MobileChrome,
    /// The trivial marker scheme the shell registered at config-build time (for
    /// the marker scheme's `onRequest` body). Borrowed from Swift's argument for
    /// the app's lifetime (Swift keeps the scheme string alive).
    marker_scheme: []const u8 = "",
};

var ios_shell: IosShell = undefined;

/// The trivial marker body the shell's scheme handler serves. There is no real
/// scheme content in this slice (spec: "registers only the trivial marker
/// scheme"); a real body (`ipfs://` content) is `explore-web3-capabilities`.
const marker_body =
    "<!doctype html><html><head><title>wezig</title></head>" ++
    "<body><h1>wezig</h1><p>mobile shell marker scheme</p></body></html>";

/// The marker scheme handler (the seam `SchemeHandler`): serves a trivial static
/// body for any request to the registered marker scheme. Proves the scheme set
/// threaded into the config at build time re-enters the seam and serves — WITHOUT
/// shipping any real scheme content (that is a downstream task).
fn onMarkerScheme(ctx: *anyopaque, uri: []const u8) seam.SchemeResponse {
    _ = ctx;
    _ = uri;
    return .{ .body = marker_body, .content_type = "text/html" };
}

/// Construct the iOS `Renderer` backend + the mobile `ChromeSurface` + the shared
/// `MobileChrome` over the Swift-owned `WKWebView` / toolbar, register the trivial
/// marker scheme THROUGH the seam at config-build time (the iOS ordering
/// constraint — Swift must have installed the `WKURLSchemeHandler` on the config
/// before creating the webview), attach the chrome to both event streams, and
/// drive the start navigation THROUGH the seams. `marker_scheme` is the trivial
/// scheme name (e.g. `wezig`); `start_uri` is the first page. Returns an opaque
/// shell context Swift hands back to the relay thunks. One shell at a time.
export fn wezig_ios_shell_start(
    // --- WKWebView ops (the Renderer backend drives these) ---
    wk: *anyopaque,
    view: *anyopaque,
    navigate: *const fn (wk: *anyopaque, uri: [*:0]const u8) callconv(.c) void,
    reload: *const fn (wk: *anyopaque) callconv(.c) void,
    stop: *const fn (wk: *anyopaque) callconv(.c) void,
    goBack: *const fn (wk: *anyopaque) callconv(.c) void,
    goForward: *const fn (wk: *anyopaque) callconv(.c) void,
    canGoBack: *const fn (wk: *anyopaque) callconv(.c) bool,
    canGoForward: *const fn (wk: *anyopaque) callconv(.c) bool,
    setViewportSize: *const fn (wk: *anyopaque, width: c_int, height: c_int) callconv(.c) void,
    injectUserScript: *const fn (wk: *anyopaque, source: [*:0]const u8) callconv(.c) void,
    evaluateScript: *const fn (wk: *anyopaque, source: [*:0]const u8) callconv(.c) void,
    setScriptMessageHandler: *const fn (wk: *anyopaque, name: [*:0]const u8) callconv(.c) void,
    registerScheme: *const fn (wk: *anyopaque, scheme: [*:0]const u8) callconv(.c) void,
    // --- chrome-surface ops (the URL field / toolbar / content container) ---
    embed_host: *anyopaque,
    embedView: *const fn (host: *anyopaque, view: *anyopaque) callconv(.c) void,
    setUrlText: *const fn (host: *anyopaque, text: [*:0]const u8) callconv(.c) void,
    setBackEnabled: *const fn (host: *anyopaque, enabled: bool) callconv(.c) void,
    setForwardEnabled: *const fn (host: *anyopaque, enabled: bool) callconv(.c) void,
    // --- shell config ---
    marker_scheme: [*:0]const u8,
    start_uri: [*:0]const u8,
) *anyopaque {
    ios_shell = .{
        .ios = IosWebviewRenderer.init(.{
            .wk = wk,
            .view = view,
            .navigate = navigate,
            .reload = reload,
            .stop = stop,
            .goBack = goBack,
            .goForward = goForward,
            .canGoBack = canGoBack,
            .canGoForward = canGoForward,
            .setViewportSize = setViewportSize,
            .injectUserScript = injectUserScript,
            .evaluateScript = evaluateScript,
            .setScriptMessageHandler = setScriptMessageHandler,
            .registerScheme = registerScheme,
        }),
        .surface = MobileChromeSurface.init(.{
            .host = embed_host,
            .embedView = embedView,
            .setUrlText = setUrlText,
            .setBackEnabled = setBackEnabled,
            .setForwardEnabled = setForwardEnabled,
        }),
        .chrome = undefined,
        .marker_scheme = std.mem.span(marker_scheme),
    };
    ios_shell.chrome = MobileChrome.init(ios_shell.ios.renderer(), ios_shell.surface.chromeSurface());
    ios_shell.chrome.attach();

    // The iOS ordering constraint (finding): register the trivial marker scheme
    // THROUGH the seam NOW — Swift's `registerScheme` op installs the
    // `WKURLSchemeHandler` on the `WKWebViewConfiguration` BEFORE it creates the
    // webview. `MobileChrome` never registers schemes (it is nav-only), so the
    // shell threads the scheme set in here, at config-build time.
    ios_shell.ios.renderer().registerScheme(marker_scheme, .{
        .ctx = &ios_shell,
        .onRequest = onMarkerScheme,
    });

    // Embed the renderer's opaque view through the surface, size the viewport,
    // and navigate the start URI — all THROUGH the two seams (MobileChrome.build).
    ios_shell.chrome.build(start_uri);
    return &ios_shell;
}

/// A `WKNavigationDelegate` load-state callback forwarded from Swift (same codes
/// as the proofs: 0=started,1=committed,2=finished,3=failed; `uri` may be null).
/// Re-enters the backend, which emits a `LifecycleEvent` the chrome reflects into
/// the surface's URL text + Back/Forward sensitivity (story 5).
export fn wezig_ios_shell_on_load_state(ctx: *anyopaque, state: c_int, uri: ?[*:0]const u8) void {
    const p: *IosShell = @ptrCast(@alignCast(ctx));
    const load_state: seam.LoadState = switch (state) {
        0 => .started,
        1 => .committed,
        2 => .finished,
        else => .failed,
    };
    const uri_slice: ?[]const u8 = if (uri) |u| std.mem.span(u) else null;
    p.ios.onLoadState(load_state, uri_slice);
}

/// The document title changed (KVO on `WKWebView.title`), forwarded from Swift.
/// Re-enters the backend as a `.title_changed` event (the mobile chrome keeps no
/// window title, so this is inert at the surface today — but the seam path is
/// complete for a future title-bearing chrome).
export fn wezig_ios_shell_on_title(ctx: *anyopaque, title: [*:0]const u8) void {
    const p: *IosShell = @ptrCast(@alignCast(ctx));
    p.ios.onTitle(std.mem.span(title));
}

/// The document URL changed (KVO on `WKWebView.URL`), forwarded from Swift.
/// Re-enters the backend as a `.uri_changed` event the chrome reflects into the
/// URL field — so the field mirrors the current page on redirects / history nav.
export fn wezig_ios_shell_on_uri(ctx: *anyopaque, uri: [*:0]const u8) void {
    const p: *IosShell = @ptrCast(@alignCast(ctx));
    p.ios.onUri(std.mem.span(uri));
}

/// The user submitted a URL in the URL field. Fire a `.navigate` intent INTO the
/// surface; the chrome turns it into a `Renderer.navigate` — the shell never
/// calls the `WKWebView` directly. `uri` is borrowed for this call.
export fn wezig_ios_shell_navigate(ctx: *anyopaque, uri: [*:0]const u8) void {
    const p: *IosShell = @ptrCast(@alignCast(ctx));
    p.surface.fireIntent(.{ .navigate = std.mem.span(uri) });
}

/// The user tapped Back. Fire a `.back` intent INTO the surface (→ chrome →
/// `Renderer.goBack`), NOT a raw `WKWebView.goBack`.
export fn wezig_ios_shell_go_back(ctx: *anyopaque) void {
    const p: *IosShell = @ptrCast(@alignCast(ctx));
    p.surface.fireIntent(.back);
}

/// The user tapped Forward. Fire a `.forward` intent INTO the surface.
export fn wezig_ios_shell_go_forward(ctx: *anyopaque) void {
    const p: *IosShell = @ptrCast(@alignCast(ctx));
    p.surface.fireIntent(.forward);
}

/// The user tapped Reload. Fire a `.reload` intent INTO the surface.
export fn wezig_ios_shell_reload(ctx: *anyopaque) void {
    const p: *IosShell = @ptrCast(@alignCast(ctx));
    p.surface.fireIntent(.reload);
}

/// A NUL-terminating buffer for the last served content-type, so Swift always
/// gets a valid C string (the seam `content_type` is `[]const u8`, not
/// sentinel-terminated). Borrowed until the next serve — one shell at a time.
var ios_shell_ct_buf: [128]u8 = undefined;

/// Swift forwards a `WKURLSchemeHandler` request for the marker scheme here
/// (`startURLSchemeTask`). Ask the seam for the native body + content-type; write
/// the served bytes + length into the out-params (borrowed until the next call,
/// per the seam contract) and return true, or false if no handler is registered
/// (Swift then fails the task). Mirrors `wezig_ios_serve_scheme`.
export fn wezig_ios_shell_serve_scheme(
    ctx: *anyopaque,
    uri: [*:0]const u8,
    out_body: *[*]const u8,
    out_body_len: *usize,
    out_content_type: *[*:0]const u8,
) bool {
    const p: *IosShell = @ptrCast(@alignCast(ctx));
    const resp = p.ios.onSchemeRequest(std.mem.span(uri)) orelse return false;
    out_body.* = resp.body.ptr;
    out_body_len.* = resp.body.len;
    const ct = std.fmt.bufPrintZ(&ios_shell_ct_buf, "{s}", .{resp.content_type}) catch "text/plain";
    out_content_type.* = @ptrCast(ct.ptr);
    return true;
}

// Force the shell C-ABI `export fn`s to be analysed/emitted in a non-test
// static-lib build (same GC-retention issue + fix as `mobile_abi`/
// `mobile_chrome_surface`).
comptime {
    _ = &wezig_ios_shell_start;
    _ = &wezig_ios_shell_on_load_state;
    _ = &wezig_ios_shell_on_title;
    _ = &wezig_ios_shell_on_uri;
    _ = &wezig_ios_shell_navigate;
    _ = &wezig_ios_shell_go_back;
    _ = &wezig_ios_shell_go_forward;
    _ = &wezig_ios_shell_reload;
    _ = &wezig_ios_shell_serve_scheme;
}

// ---------------------------------------------------------------------------
// Headless seam-contract tests (run in `zig build test`; no WKWebView, no UIKit,
// no simulator). A fake `WkPlatform` + `EmbedPlatform` record what the shell
// drives, so the whole iOS-shell wiring — construct the three pieces, register
// the marker scheme at config-build time, embed + navigate on build, relay
// intents THROUGH the seams, reflect lifecycle events into the widgets — is
// proven on the host. The REAL end-to-end proof (a live WKWebView browses one
// page in the Xcode app, survives background/foreground) is the iOS Simulator
// leg, kept OUT of `zig build test` (spec Q6 / ADR-0007 discipline).
// ---------------------------------------------------------------------------

/// A fake native host recording BOTH the WKWebView ops the renderer drives and
/// the surface ops the chrome drives, so the iOS shell is drivable with no
/// UIKit/WebKit. Ordering-aware: records whether `registerScheme` happened BEFORE
/// the first `navigate` (the iOS config-ordering constraint the shell must honour).
const FakeShellHost = struct {
    // renderer/WKWebView side
    last_uri: [256]u8 = undefined,
    last_uri_len: usize = 0,
    navigated: bool = false,
    reloaded: bool = false,
    went_back: bool = false,
    went_forward: bool = false,
    viewport_w: c_int = 0,
    viewport_h: c_int = 0,
    can_back: bool = false,
    can_forward: bool = false,
    view_token: u8 = 0,
    // history model so canGoBack/canGoForward mirror a real webview for the test
    registered_scheme: [64]u8 = undefined,
    registered_scheme_len: usize = 0,
    scheme_registered_before_navigate: bool = false,
    scheme_seen: bool = false,

    // surface side
    embedded: ?*anyopaque = null,
    url_text: [256]u8 = undefined,
    url_len: usize = 0,
    back_enabled: bool = false,
    forward_enabled: bool = false,

    fn wk(self: *FakeShellHost) *anyopaque {
        return self;
    }

    // --- WKWebView ops ---
    fn navigate(w: *anyopaque, uri: [*:0]const u8) callconv(.c) void {
        const self: *FakeShellHost = @ptrCast(@alignCast(w));
        if (!self.navigated and self.scheme_seen) self.scheme_registered_before_navigate = true;
        const slice = std.mem.span(uri);
        const n = @min(slice.len, self.last_uri.len);
        @memcpy(self.last_uri[0..n], slice[0..n]);
        self.last_uri_len = n;
        self.navigated = true;
    }
    fn reload(w: *anyopaque) callconv(.c) void {
        const self: *FakeShellHost = @ptrCast(@alignCast(w));
        self.reloaded = true;
    }
    fn stop(w: *anyopaque) callconv(.c) void {
        _ = w;
    }
    fn goBack(w: *anyopaque) callconv(.c) void {
        const self: *FakeShellHost = @ptrCast(@alignCast(w));
        self.went_back = true;
    }
    fn goForward(w: *anyopaque) callconv(.c) void {
        const self: *FakeShellHost = @ptrCast(@alignCast(w));
        self.went_forward = true;
    }
    fn canGoBack(w: *anyopaque) callconv(.c) bool {
        const self: *FakeShellHost = @ptrCast(@alignCast(w));
        return self.can_back;
    }
    fn canGoForward(w: *anyopaque) callconv(.c) bool {
        const self: *FakeShellHost = @ptrCast(@alignCast(w));
        return self.can_forward;
    }
    fn setViewportSize(w: *anyopaque, width: c_int, height: c_int) callconv(.c) void {
        const self: *FakeShellHost = @ptrCast(@alignCast(w));
        self.viewport_w = width;
        self.viewport_h = height;
    }
    fn injectUserScript(w: *anyopaque, source: [*:0]const u8) callconv(.c) void {
        _ = w;
        _ = source;
    }
    fn evaluateScript(w: *anyopaque, source: [*:0]const u8) callconv(.c) void {
        _ = w;
        _ = source;
    }
    fn setScriptMessageHandler(w: *anyopaque, name: [*:0]const u8) callconv(.c) void {
        _ = w;
        _ = name;
    }
    fn registerScheme(w: *anyopaque, scheme: [*:0]const u8) callconv(.c) void {
        const self: *FakeShellHost = @ptrCast(@alignCast(w));
        const slice = std.mem.span(scheme);
        const n = @min(slice.len, self.registered_scheme.len);
        @memcpy(self.registered_scheme[0..n], slice[0..n]);
        self.registered_scheme_len = n;
        self.scheme_seen = true;
    }

    // --- surface ops ---
    fn embedView(host: *anyopaque, view: *anyopaque) callconv(.c) void {
        const self: *FakeShellHost = @ptrCast(@alignCast(host));
        self.embedded = view;
    }
    fn setUrlText(host: *anyopaque, text: [*:0]const u8) callconv(.c) void {
        const self: *FakeShellHost = @ptrCast(@alignCast(host));
        const slice = std.mem.span(text);
        const n = @min(slice.len, self.url_text.len);
        @memcpy(self.url_text[0..n], slice[0..n]);
        self.url_len = n;
    }
    fn setBackEnabled(host: *anyopaque, enabled: bool) callconv(.c) void {
        const self: *FakeShellHost = @ptrCast(@alignCast(host));
        self.back_enabled = enabled;
    }
    fn setForwardEnabled(host: *anyopaque, enabled: bool) callconv(.c) void {
        const self: *FakeShellHost = @ptrCast(@alignCast(host));
        self.forward_enabled = enabled;
    }

    fn urlText(self: *FakeShellHost) []const u8 {
        return self.url_text[0..self.url_len];
    }
    fn lastUri(self: *FakeShellHost) []const u8 {
        return self.last_uri[0..self.last_uri_len];
    }
    fn registeredScheme(self: *FakeShellHost) []const u8 {
        return self.registered_scheme[0..self.registered_scheme_len];
    }

    /// Start the shell over this fake host (assembling the two ops tables).
    fn start(self: *FakeShellHost, marker_scheme: [*:0]const u8, start_uri: [*:0]const u8) *anyopaque {
        return wezig_ios_shell_start(
            self.wk(),
            &self.view_token,
            navigate,
            reload,
            stop,
            goBack,
            goForward,
            canGoBack,
            canGoForward,
            setViewportSize,
            injectUserScript,
            evaluateScript,
            setScriptMessageHandler,
            registerScheme,
            self.wk(), // embed_host is the same fake cookie
            embedView,
            setUrlText,
            setBackEnabled,
            setForwardEnabled,
            marker_scheme,
            start_uri,
        );
    }
};

test "iOS shell: start embeds the view, registers the marker scheme at config time, and navigates through the seams" {
    var host = FakeShellHost{};
    const ctx = host.start("wezig", "https://start.example/");

    // build() embedded the renderer's opaque view THROUGH the chrome-surface seam.
    try std.testing.expect(host.embedded != null);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&host.view_token)), host.embedded.?);

    // The viewport was sized through the seam (MobileChrome.build).
    try std.testing.expect(host.viewport_w > 0 and host.viewport_h > 0);

    // The trivial marker scheme was registered THROUGH the seam...
    try std.testing.expectEqualStrings("wezig", host.registeredScheme());
    // ...and BEFORE the first navigate (the iOS config-ordering constraint).
    try std.testing.expect(host.scheme_registered_before_navigate);

    // The start navigation crossed the seam to the WKWebView op (not a raw call).
    try std.testing.expect(host.navigated);
    try std.testing.expectEqualStrings("https://start.example/", host.lastUri());

    // The marker scheme serves a trivial native body through the seam.
    var body: [*]const u8 = undefined;
    var body_len: usize = 0;
    var ct: [*:0]const u8 = undefined;
    const served = wezig_ios_shell_serve_scheme(ctx, "wezig://x", &body, &body_len, &ct);
    try std.testing.expect(served);
    try std.testing.expect(body_len > 0);
    try std.testing.expectEqualStrings("text/html", std.mem.span(ct));
}

test "iOS shell: a URL-field submit navigates THROUGH the chrome/seams and reflects the URL" {
    var host = FakeShellHost{};
    const ctx = host.start("wezig", "https://one.example/");

    // A user-entered URL fires a navigate intent → chrome → Renderer.navigate.
    wezig_ios_shell_navigate(ctx, "https://typed.example/");
    try std.testing.expectEqualStrings("https://typed.example/", host.lastUri());

    // The WKNavigationDelegate reports the load; the chrome reflects the URI into
    // the URL field (story 5 — the field mirrors the current page).
    wezig_ios_shell_on_load_state(ctx, 0, "https://typed.example/"); // started
    wezig_ios_shell_on_uri(ctx, "https://typed.example/");
    wezig_ios_shell_on_load_state(ctx, 2, "https://typed.example/"); // finished
    try std.testing.expectEqualStrings("https://typed.example/", host.urlText());
}

test "iOS shell: back/forward intents drive the renderer and button sensitivity reflects history" {
    var host = FakeShellHost{};
    const ctx = host.start("wezig", "https://start.example/");

    // Simulate a real webview's history: after navigating away, Back is available.
    host.can_back = true;
    host.can_forward = false;
    // A lifecycle transition re-queries canGoBack/canGoForward via the chrome and
    // reflects them into the toolbar (story 5).
    wezig_ios_shell_on_load_state(ctx, 2, "https://second.example/"); // finished
    try std.testing.expect(host.back_enabled);
    try std.testing.expect(!host.forward_enabled);

    // A Back tap fires a .back intent → chrome → Renderer.goBack (not a raw call).
    wezig_ios_shell_go_back(ctx);
    try std.testing.expect(host.went_back);

    // A Forward tap fires a .forward intent → chrome → Renderer.goForward.
    host.can_forward = true;
    wezig_ios_shell_go_forward(ctx);
    try std.testing.expect(host.went_forward);

    // A Reload tap fires a .reload intent → chrome → Renderer.reload.
    wezig_ios_shell_reload(ctx);
    try std.testing.expect(host.reloaded);
}
