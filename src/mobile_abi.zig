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
    ios_proof = .{ .ios = IosWebviewRenderer.init(.{
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
    }) };
    const r = ios_proof.ios.renderer();
    r.setLifecycleCallback(.{ .ctx = &ios_proof, .onEvent = onProofEvent });
    r.navigate(uri);
    return &ios_proof;
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

test "abi_version is the pinned contract version" {
    try std.testing.expectEqual(@as(c_int, 1), wezig_abi_version());
}

test "greeting is a stable non-empty C string" {
    const g = std.mem.span(wezig_greeting());
    try std.testing.expect(g.len > 0);
    try std.testing.expectEqualStrings("wezig mobile core linked", g);
}
