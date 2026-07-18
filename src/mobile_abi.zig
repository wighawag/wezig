//! The C-ABI surface the mobile shells (iOS/Android) link against.
//!
//! On mobile, Zig builds a STATIC LIBRARY that the OS-native shell hosts:
//!   - iOS: a Swift/Xcode app links `libwezig_mobile.a` and calls these
//!     `export fn`s through a C-ABI header, then drives a `WKWebView`.
//!   - Android: a Gradle/NDK app loads the static lib through a JNI shim and
//!     drives an `android.webkit.WebView`.
//!
//! This module is the NARROW, stable C boundary those shims call: it proves the
//! Zig core is linked and live from the native side, without dragging the shell
//! seams (which link WebKitGTK/GTK on desktop) into the mobile build. The
//! functions here are deliberately minimal — an ABI-version integer and a
//! greeting string — exactly enough for the toolchain tasks to prove Zig↔native
//! linkage end-to-end. Richer surface (the `ChromeSurface` half of the split
//! `Toolkit`, ADR-0008) is wired by the downstream mobile renderer/embedding
//! tasks; keeping this file minimal keeps the toolchain proof honest.
//!
//! These are C-callable (`export fn`, C ABI), so they are usable from Swift
//! (via a bridging header) and from C/JNI alike. The library module already
//! links libc (stb_truetype), so returning a static C string is safe.

const std = @import("std");
const branding = @import("branding.zig");
const seam = @import("renderer.zig");
const IosWebviewRenderer = @import("ios_webview_renderer.zig").IosWebviewRenderer;
const WkPlatform = @import("ios_webview_renderer.zig").WkPlatform;

/// The mobile C-ABI contract version. Bumped when the exported surface below
/// changes shape, so a native shim can assert it links the ABI it expects.
pub const abi_version: c_int = 1;

/// Return the mobile C-ABI version. The native shim calls this first to prove
/// the Zig static lib is linked and callable.
export fn wezig_abi_version() c_int {
    return abi_version;
}

/// A NUL-terminated greeting the native shim can display (e.g. in a WebView or a
/// log line) to prove the Zig core is live. Points at static storage owned by
/// the library; the caller must NOT free it.
export fn wezig_greeting() [*:0]const u8 {
    return "wezig mobile core linked";
}

// ---------------------------------------------------------------------------
// iOS `Renderer`-backend proof C-ABI (spec `explore-mobile-shell`, story 4).
//
// The iOS proof mirrors the desktop `shell-test`: navigate ONE page through the
// pinned `Renderer` seam, observe the seam deliver a `.finished` lifecycle event
// to a subscriber, and prove the view is non-blank via `WKWebView.takeSnapshot`.
// The Swift shell (`mobile/ios/Sources/RendererProof.swift`) owns the async
// simulator orchestration (create the `WKWebView`, pump the run loop, take the
// snapshot); THIS Zig side owns the SEAM: it constructs the `IosWebviewRenderer`
// backend, subscribes a proof sink, drives navigation THROUGH the seam, and maps
// the `WKNavigationDelegate` callbacks Swift forwards into the seam's
// `LifecycleEvent`s — so the proof asserts the seam carries iOS, not that Swift
// happens to load a page.
//
// One backend instance is proven at a time (the narrowest real case), so the
// proof state is a single module-level value the exported thunks operate on.
// ---------------------------------------------------------------------------

/// The seam-level proof state, driven by the exported thunks below. Holds the
/// backend under test plus the two facts the proof asserts (mirroring the
/// desktop `Smoke`): did the seam deliver `.finished`, and did Swift report the
/// snapshot non-blank.
const IosProof = struct {
    ios: IosWebviewRenderer,
    /// Set once the `Renderer` seam delivered a `.finished` event to our sink
    /// (proves seam-level navigation reached a subscriber — the `shell-test` bar).
    seam_finished: bool = false,
    /// Set from Swift once `WKWebView.takeSnapshot` was scanned non-blank.
    snapshot_non_blank: bool = false,
};

var ios_proof: IosProof = undefined;

fn onProofEvent(ctx: *anyopaque, event: seam.LifecycleEvent) void {
    const p: *IosProof = @ptrCast(@alignCast(ctx));
    switch (event) {
        .load_changed => |lc| if (lc.state == .finished) {
            p.seam_finished = true;
        },
        else => {},
    }
}

/// Construct the iOS `Renderer` backend over the `WKWebView` the Swift shell
/// owns, subscribe the proof sink to the seam's lifecycle events, and navigate
/// `uri` THROUGH the seam. Swift passes its ops-table fields as raw C pointers
/// (assembled into a `WkPlatform` here). Returns an opaque proof context Swift
/// hands back to the nav-delegate + snapshot thunks. One proof at a time.
export fn wezig_ios_proof_start(
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
    uri: [*:0]const u8,
) *anyopaque {
    ios_proof = .{
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
            // The story-4 renderer proof does not exercise the web3 hooks; the two
            // hook ops are wired to no-op stubs so the WkPlatform stays total
            // without widening this proof's C-ABI signature (the hooks have their
            // own proof entry points below).
            .setScriptMessageHandler = noopSetMsgHandler,
            .registerScheme = noopRegisterScheme,
        }),
    };
    const r = ios_proof.ios.renderer();
    r.setLifecycleCallback(.{ .ctx = &ios_proof, .onEvent = onProofEvent });
    r.navigate(uri);
    return &ios_proof;
}

fn noopSetMsgHandler(wk: *anyopaque, name: [*:0]const u8) callconv(.c) void {
    _ = wk;
    _ = name;
}
fn noopRegisterScheme(wk: *anyopaque, scheme: [*:0]const u8) callconv(.c) void {
    _ = wk;
    _ = scheme;
}

/// The `WKWebView`'s `UIView*` the backend hands back across the seam as the
/// opaque `ViewHandle` (the Q3 decision). Swift adds THIS view to its window, so
/// the view the chrome would embed is the one that renders — proving the opaque
/// handle carries the mobile native view. Returns null if no proof is active.
export fn wezig_ios_proof_view(ctx: *anyopaque) ?*anyopaque {
    const p: *IosProof = @ptrCast(@alignCast(ctx));
    const r = p.ios.renderer();
    return r.view();
}

/// A `WKNavigationDelegate` load-state callback forwarded from Swift. `state`
/// is the seam's `LoadState` as an int (0=started,1=committed,2=finished,
/// 3=failed); `uri` may be null. The backend maps it to a `LifecycleEvent` and
/// re-emits to the subscribed proof sink — so `.finished` flowing here is the
/// same seam path the chrome uses.
export fn wezig_ios_on_load_state(ctx: *anyopaque, state: c_int, uri: ?[*:0]const u8) void {
    const p: *IosProof = @ptrCast(@alignCast(ctx));
    const load_state: seam.LoadState = switch (state) {
        0 => .started,
        1 => .committed,
        2 => .finished,
        else => .failed,
    };
    const uri_slice: ?[]const u8 = if (uri) |u| std.mem.span(u) else null;
    p.ios.onLoadState(load_state, uri_slice);
}

/// Swift reports the result of scanning `WKWebView.takeSnapshot`: true if the
/// captured image had at least one non-blank pixel (a rendered page), false if
/// it was uniform/blank. Recorded for the final verdict.
export fn wezig_ios_proof_set_snapshot_non_blank(ctx: *anyopaque, non_blank: bool) void {
    const p: *IosProof = @ptrCast(@alignCast(ctx));
    p.snapshot_non_blank = non_blank;
}

/// The proof verdict: true iff the seam delivered `.finished` AND the snapshot
/// was non-blank — the two facts spec story 4 requires. Swift asserts this and
/// prints PASS/FAIL for the CI leg to grep.
export fn wezig_ios_proof_passed(ctx: *anyopaque) bool {
    const p: *IosProof = @ptrCast(@alignCast(ctx));
    return p.seam_finished and p.snapshot_non_blank;
}

// ---------------------------------------------------------------------------
// iOS web3-hook proof C-ABI (spec `explore-mobile-shell` stories 8,9; task
// `mobile-web3-hooks-parity`).
//
// Two proofs, the iOS twins of the desktop `shell-bridge-test` /
// `shell-scheme-test`, each driving ONE hook THROUGH the pinned `Renderer` seam
// over the Swift-owned `WKWebView`:
//
//   - bridge: inject `window.wezig.ping`, register the `wezig` page->native
//     channel, load a page that posts `ping-from-page`; native receives it
//     (page->native leg) and evaluates a reply that re-posts `pong-from-native`
//     (native->page leg). BOTH legs seen == pass. Mirrors `onBridgeMessage` in
//     the desktop `shell.zig`.
//   - scheme: register `wezig-test://` (the Swift shell installs the
//     WKURLSchemeHandler on the config BEFORE creating the webview — the iOS
//     ordering constraint), navigate to `wezig-test://hello`, and serve a
//     native body whose `<title>` marker reaching `.title_changed` proves it
//     both served AND rendered. Mirrors `onSchemeRequest`/`onSchemeEvent`.
//
// One proof at a time (the narrowest real case), so each keeps a single
// module-level state the exported thunks operate on. `WkPlatform` fields the
// hooks do not exercise (navigate/back/forward query ops) are wired to the same
// no-op stubs the story-4 proof uses; the hook proofs only drive the hook ops +
// the callbacks that re-enter the seam.
// ---------------------------------------------------------------------------

const bridge_ping = "ping-from-page";
const bridge_pong = "pong-from-native";

/// The bridge proof state: the backend under test + the two facts the proof
/// asserts (mirroring the desktop `Bridge`): did native receive the page's
/// `ping` (page->native), and did native observe its OWN reply come back through
/// the page (native->page).
const IosBridgeProof = struct {
    ios: IosWebviewRenderer,
    got_ping: bool = false,
    got_pong: bool = false,
};

var ios_bridge_proof: IosBridgeProof = undefined;

/// The page->native handler for the bridge proof (the seam `ScriptMessageCallback`).
/// First message is the page's `ping`; native then evaluates a reply re-posting
/// `pong` over the same channel, so the SECOND message proves the native->page
/// leg. Both seen == success. Identical logic to the desktop `onBridgeMessage`.
fn onBridgeMessage(ctx: *anyopaque, name: []const u8, body: []const u8) void {
    _ = name;
    const p: *IosBridgeProof = @ptrCast(@alignCast(ctx));
    if (!p.got_ping) {
        if (std.mem.eql(u8, body, bridge_ping)) {
            p.got_ping = true;
            // native->page reply: evaluate a call that re-posts `pong` back
            // through the SAME injected channel.
            p.ios.renderer().evaluateScript("window.wezig.ping('" ++ bridge_pong ++ "');");
        }
        return;
    }
    if (std.mem.eql(u8, body, bridge_pong)) p.got_pong = true;
}

/// Construct the iOS backend over the Swift-owned `WKWebView`, wire the bridge
/// hook THROUGH the seam (`injectUserScript` + `setScriptMessageHandler`), and
/// return the proof context Swift hands back to the message + navigate thunks.
/// Swift installs the `WKUserScript` + `WKScriptMessageHandler` behind the two
/// hook ops; the page's posts flow back via `wezig_ios_on_script_message`.
export fn wezig_ios_bridge_proof_start(
    wk: *anyopaque,
    view: *anyopaque,
    injectUserScript: *const fn (wk: *anyopaque, source: [*:0]const u8) callconv(.c) void,
    evaluateScript: *const fn (wk: *anyopaque, source: [*:0]const u8) callconv(.c) void,
    setScriptMessageHandler: *const fn (wk: *anyopaque, name: [*:0]const u8) callconv(.c) void,
) *anyopaque {
    ios_bridge_proof = .{ .ios = IosWebviewRenderer.init(.{
        .wk = wk,
        .view = view,
        .navigate = iosNoopNavigate,
        .reload = iosNoopAction,
        .stop = iosNoopAction,
        .goBack = iosNoopAction,
        .goForward = iosNoopAction,
        .canGoBack = iosNoopQuery,
        .canGoForward = iosNoopQuery,
        .setViewportSize = iosNoopViewport,
        .injectUserScript = injectUserScript,
        .evaluateScript = evaluateScript,
        .setScriptMessageHandler = setScriptMessageHandler,
        .registerScheme = noopRegisterScheme,
    }) };
    const r = ios_bridge_proof.ios.renderer();
    // native->page setup: inject the page-world `window.wezig` object BEFORE the
    // page loads (Swift installs it at document start). Same source as desktop.
    r.injectUserScript(
        \\window.wezig = { ping: function(v) {
        \\  window.webkit.messageHandlers.wezig.postMessage(v);
        \\} };
    );
    // page->native: register the `wezig` channel; the handler drives both legs.
    r.setScriptMessageHandler("wezig", .{ .ctx = &ios_bridge_proof, .onMessage = onBridgeMessage });
    return &ios_bridge_proof;
}

/// Swift forwards a page-world post from the `WKScriptMessageHandler` here
/// (`didReceive`, already on the main queue). `name` is the channel, `body` the
/// message string. Re-enters the seam via the backend's `onScriptMessage`.
export fn wezig_ios_on_script_message(ctx: *anyopaque, name: [*:0]const u8, body: [*:0]const u8) void {
    const p: *IosBridgeProof = @ptrCast(@alignCast(ctx));
    p.ios.onScriptMessage(std.mem.span(name), std.mem.span(body));
}

/// The bridge verdict: true iff BOTH legs landed (native got the page's ping AND
/// native's evaluated reply came back through the page). Swift asserts + prints.
export fn wezig_ios_bridge_proof_passed(ctx: *anyopaque) bool {
    const p: *IosBridgeProof = @ptrCast(@alignCast(ctx));
    return p.got_ping and p.got_pong;
}

/// The scheme proof state: the backend + the two facts (mirroring the desktop
/// `Scheme`): was the native handler invoked (served), and did the served body's
/// `<title>` marker reach `.title_changed` (rendered)?
const IosSchemeProof = struct {
    ios: IosWebviewRenderer,
    served: bool = false,
    rendered: bool = false,
};

var ios_scheme_proof: IosSchemeProof = undefined;

const scheme_marker = "WEZIG-SCHEME-OK";

/// The native scheme handler (the seam `SchemeHandler`): serves an HTML body
/// whose `<title>` is the marker; records that it ran. Identical to the desktop
/// `onSchemeRequest`.
fn onSchemeRequest(ctx: *anyopaque, uri: []const u8) seam.SchemeResponse {
    _ = uri;
    const p: *IosSchemeProof = @ptrCast(@alignCast(ctx));
    p.served = true;
    return .{
        .body = "<html><head><title>" ++ scheme_marker ++ "</title></head>" ++
            "<body><h1>" ++ scheme_marker ++ "</h1></body></html>",
        .content_type = "text/html",
    };
}

/// Lifecycle sink for the scheme proof: the marker `<title>` arriving proves the
/// native-served body was parsed + rendered by WebKit.
fn onSchemeProofEvent(ctx: *anyopaque, event: seam.LifecycleEvent) void {
    const p: *IosSchemeProof = @ptrCast(@alignCast(ctx));
    switch (event) {
        .title_changed => |title| {
            if (std.mem.eql(u8, title, scheme_marker)) p.rendered = true;
        },
        else => {},
    }
}

/// Construct the iOS backend, register `wezig-test://` THROUGH the seam, and
/// subscribe the marker-title sink. Swift MUST have installed the
/// `WKURLSchemeHandler` on the `WKWebViewConfiguration` before creating the
/// webview (the iOS ordering constraint), then navigate `wezig-test://hello`.
/// Returns the proof context Swift hands to the scheme-serve + title thunks.
export fn wezig_ios_scheme_proof_start(
    wk: *anyopaque,
    view: *anyopaque,
    registerScheme: *const fn (wk: *anyopaque, scheme: [*:0]const u8) callconv(.c) void,
) *anyopaque {
    ios_scheme_proof = .{ .ios = IosWebviewRenderer.init(.{
        .wk = wk,
        .view = view,
        .navigate = iosNoopNavigate,
        .reload = iosNoopAction,
        .stop = iosNoopAction,
        .goBack = iosNoopAction,
        .goForward = iosNoopAction,
        .canGoBack = iosNoopQuery,
        .canGoForward = iosNoopQuery,
        .setViewportSize = iosNoopViewport,
        .injectUserScript = iosNoopSource,
        .evaluateScript = iosNoopSource,
        .setScriptMessageHandler = noopSetMsgHandler,
        .registerScheme = registerScheme,
    }) };
    const r = ios_scheme_proof.ios.renderer();
    r.registerScheme("wezig-test", .{ .ctx = &ios_scheme_proof, .onRequest = onSchemeRequest });
    r.setLifecycleCallback(.{ .ctx = &ios_scheme_proof, .onEvent = onSchemeProofEvent });
    return &ios_scheme_proof;
}

/// A NUL-terminating buffer for the last served content-type, so Swift always
/// gets a valid C string even if a handler returns a non-terminated slice (the
/// seam `content_type` is `[]const u8`, not sentinel-terminated). Single proof
/// at a time, and borrowed until the next serve — matching the seam contract.
var ios_scheme_ct_buf: [128]u8 = undefined;

/// Swift forwards a `WKURLSchemeHandler` request here (`startURLSchemeTask`).
/// Ask the seam for the native body + content-type; writes the served bytes +
/// their length into the out-params (borrowed until the next call, per the seam
/// contract) and returns true, or false if no handler is registered (Swift then
/// fails the task). The body bytes are read as `body_len` bytes (not assumed
/// NUL-terminated); the content-type is copied NUL-terminated for Swift.
export fn wezig_ios_serve_scheme(
    ctx: *anyopaque,
    uri: [*:0]const u8,
    out_body: *[*]const u8,
    out_body_len: *usize,
    out_content_type: *[*:0]const u8,
) bool {
    const p: *IosSchemeProof = @ptrCast(@alignCast(ctx));
    const resp = p.ios.onSchemeRequest(std.mem.span(uri)) orelse return false;
    out_body.* = resp.body.ptr;
    out_body_len.* = resp.body.len;
    const ct = std.fmt.bufPrintZ(&ios_scheme_ct_buf, "{s}", .{resp.content_type}) catch "text/plain";
    out_content_type.* = @ptrCast(ct.ptr);
    return true;
}

/// Swift forwards a `.title_changed` (the served body's `<title>`) here so the
/// seam's lifecycle sink can confirm the native body rendered. The marker title
/// arriving sets `rendered`.
export fn wezig_ios_scheme_on_title(ctx: *anyopaque, title: [*:0]const u8) void {
    const p: *IosSchemeProof = @ptrCast(@alignCast(ctx));
    p.ios.onTitle(std.mem.span(title));
}

/// The scheme verdict: true iff the native handler served the body AND the
/// marker `<title>` reached the seam (served + rendered). Swift asserts + prints.
export fn wezig_ios_scheme_proof_passed(ctx: *anyopaque) bool {
    const p: *IosSchemeProof = @ptrCast(@alignCast(ctx));
    return p.served and p.rendered;
}

// No-op WkPlatform ops the hook proofs do not exercise (navigation + query).
fn iosNoopNavigate(wk: *anyopaque, uri: [*:0]const u8) callconv(.c) void {
    _ = wk;
    _ = uri;
}
fn iosNoopAction(wk: *anyopaque) callconv(.c) void {
    _ = wk;
}
fn iosNoopQuery(wk: *anyopaque) callconv(.c) bool {
    _ = wk;
    return false;
}
fn iosNoopViewport(wk: *anyopaque, width: c_int, height: c_int) callconv(.c) void {
    _ = wk;
    _ = width;
    _ = height;
}
fn iosNoopSource(wk: *anyopaque, source: [*:0]const u8) callconv(.c) void {
    _ = wk;
    _ = source;
}

test "abi_version is the pinned contract version" {
    try std.testing.expectEqual(@as(c_int, 1), wezig_abi_version());
}

test "greeting is a stable non-empty C string" {
    const g = std.mem.span(wezig_greeting());
    try std.testing.expect(g.len > 0);
    try std.testing.expectEqualStrings("wezig mobile core linked", g);
}
