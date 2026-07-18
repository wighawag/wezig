//! `MobileChromeSurface`: the `ChromeSurface` half of the split `Toolkit` seam
//! (toolkit.zig, ADR-0008) implemented for the mobile chrome host — the ONE
//! piece the `mobile-viewhandle-embedding-proof` task adds (spec
//! `explore-mobile-shell`, Q3/story 6; ADR-0006's flagged cross-toolkit
//! embedding spike, ADR-0007).
//!
//! ## What this proves
//!
//! ADR-0006 keeps the renderer's view OPAQUE (`ViewHandle = *anyopaque`): the
//! chrome takes it from `Renderer.view()` and hands it to `ChromeSurface.embedView`
//! WITHOUT knowing what it is. On desktop both backends agree it is a `GtkWidget`.
//! ADR-0007 flagged the cross-toolkit case — a NON-GTK chrome host embedding a
//! foreign view — as an unproven spike. Mobile is that case: the iOS host embeds
//! a `WKWebView`'s `UIView*`, the Android host embeds a JNI global-ref to an
//! `android.webkit.WebView`. This module is the mobile `ChromeSurface` that
//! `embedView`s that opaque handle, so the proof drives the SAME seam path the
//! chrome would: `surface.embedView(renderer.view())` — never a native
//! `addSubview`/`addView` reached around the seam.
//!
//! The sharp risk (spec Q3) is ANDROID: the handle is not a raw pointer but a
//! JNI global-ref, with lifetime + thread-affinity constraints. This module
//! keeps the Zig `ChromeSurface` half BACKEND-AGNOSTIC — it copies the opaque
//! `usize` bits through unchanged and hands them to a native embed op; only the
//! native side (Swift `UIView`/JNI `ViewGroup`) interprets them. So the seam
//! contract under test is exactly "does the opaque handle carry a JNI global-ref
//! across `embedView`", answered by the on-emulator embedding leg.
//!
//! ## Why an ops table (mirroring `WkPlatform` / `CJavaBridge`)
//!
//! Like the two mobile `Renderer` backends, the physical view-hierarchy call
//! (`addSubview` on iOS, `ViewGroup.addView` over JNI on Android) lives on the
//! NATIVE side of the FFI the toolchain pinned (Swift owns UIKit; the Java
//! controller owns `android.webkit.*`). So the Zig `ChromeSurface` reaches the
//! host through a small C-ABI ops table (`EmbedPlatform`) the native shell
//! installs. This keeps the "chrome-surface half is pure Zig, backend-agnostic"
//! discipline while the actual UIKit/Java call sits behind the C-ABI — the same
//! shape `ios_webview_renderer.zig` and `android_renderer.zig` already use.
//!
//! The Zig `embedView` here does NOTHING platform-specific: it forwards the
//! opaque handle to the ops table. That is the whole point — the seam carries
//! the handle; the backend interprets it. The headless tests below prove the
//! forwarding with a fake ops table (no UIKit, no JVM); the REAL proof (a page
//! shows in the embedded view) runs on the iOS simulator / Android emulator
//! embedding legs, kept OUT of `zig build test` (spec Q6 / ADR-0007 discipline).

const std = @import("std");
const seam = @import("renderer.zig");
const toolkit = @import("toolkit.zig");

/// The C-ABI ops table the native shell installs so the Zig `ChromeSurface` can
/// drive a view hierarchy it does not own. `host` is an opaque cookie (the Swift
/// coordinator / the Java controller's JNI ctx); `embedView` receives the
/// renderer's opaque `ViewHandle` and adds it to the host's content area. This
/// is the ONLY surface the mobile chrome-surface uses to touch native UI; the
/// Swift file / JNI shim behind these pointers is the sole importer of
/// UIKit / `android.webkit.*`.
pub const EmbedPlatform = extern struct {
    /// The native host cookie handed to every op (identifies the content area
    /// the view is embedded into). Opaque to Zig.
    host: *anyopaque,
    /// Embed `view` (the renderer's opaque `ViewHandle`, unchanged) into the
    /// host's content area. On iOS `view` is a `UIView*`; on Android it is a
    /// JNI global-ref to the `WebView`. The Zig side never interprets it — it
    /// hands the exact bits it got from `Renderer.view()` back to the native op.
    embedView: *const fn (host: *anyopaque, view: *anyopaque) callconv(.c) void,
    /// Set the URL bar's displayed text (the chrome-surface widget contract).
    setUrlText: *const fn (host: *anyopaque, text: [*:0]const u8) callconv(.c) void,
    /// Enable/disable the Back / Forward buttons.
    setBackEnabled: *const fn (host: *anyopaque, enabled: bool) callconv(.c) void,
    setForwardEnabled: *const fn (host: *anyopaque, enabled: bool) callconv(.c) void,
};

/// A `ChromeSurface` (toolkit.zig) driven through an `EmbedPlatform` ops table.
/// This is the MOBILE toolkit's only half — the OS owns the window + run loop
/// (`HostLoop`), so a mobile toolkit implements ONLY `ChromeSurface` (ADR-0008).
/// Construct with `init` (handing the ops table the native shell installed),
/// obtain the seam value with `chromeSurface()`, and hand THAT to the chrome;
/// the chrome calls `embedView(renderer.view())` without learning the handle is
/// a `UIView*` or a JNI ref.
pub const MobileChromeSurface = struct {
    platform: EmbedPlatform,
    cb: ?toolkit.ChromeCallback = null,

    pub fn init(platform: EmbedPlatform) MobileChromeSurface {
        return .{ .platform = platform };
    }

    pub fn chromeSurface(self: *MobileChromeSurface) toolkit.ChromeSurface {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Deliver a user intent UP to the subscribed chrome (the native shell calls
    /// this when a URL is entered / a nav button is tapped). Kept here so the
    /// mobile chrome host has a home for intents even though this task only
    /// exercises `embedView`.
    pub fn fireIntent(self: *MobileChromeSurface, intent: toolkit.ChromeIntent) void {
        if (self.cb) |cb| cb.onIntent(cb.ctx, intent);
    }

    const vtable = toolkit.ChromeSurface.VTable{
        .embedView = embedView,
        .setUrlText = setUrlText,
        .setBackEnabled = setBackEnabled,
        .setForwardEnabled = setForwardEnabled,
        .setChromeCallback = setChromeCallback,
    };

    fn embedView(ctx: *anyopaque, view: seam.ViewHandle) void {
        const self: *MobileChromeSurface = @ptrCast(@alignCast(ctx));
        // Backend-agnostic: forward the OPAQUE handle unchanged. Only the native
        // op interprets it (a `UIView*` on iOS, a JNI global-ref on Android).
        self.platform.embedView(self.platform.host, view);
    }
    fn setUrlText(ctx: *anyopaque, text: [*:0]const u8) void {
        const self: *MobileChromeSurface = @ptrCast(@alignCast(ctx));
        self.platform.setUrlText(self.platform.host, text);
    }
    fn setBackEnabled(ctx: *anyopaque, enabled: bool) void {
        const self: *MobileChromeSurface = @ptrCast(@alignCast(ctx));
        self.platform.setBackEnabled(self.platform.host, enabled);
    }
    fn setForwardEnabled(ctx: *anyopaque, enabled: bool) void {
        const self: *MobileChromeSurface = @ptrCast(@alignCast(ctx));
        self.platform.setForwardEnabled(self.platform.host, enabled);
    }
    fn setChromeCallback(ctx: *anyopaque, cb: toolkit.ChromeCallback) void {
        const self: *MobileChromeSurface = @ptrCast(@alignCast(ctx));
        self.cb = cb;
    }
};

// ---------------------------------------------------------------------------
// iOS embedding-proof C-ABI (spec `explore-mobile-shell`, Q3/story 6).
//
// The iOS proof mirrors the desktop `shell-test` embedding: the mobile
// chrome-surface `embedView`s the renderer's `WKWebView` view and the page
// shows. The Swift shell (`mobile/ios/Sources/EmbeddingProof.swift`) owns the
// `WKWebView`, the container view, and the snapshot; THIS Zig side owns the
// SEAM: it constructs both the `IosWebviewRenderer` backend AND the
// `MobileChromeSurface`, then drives `surface.embedView(renderer.view())` — so
// the proof asserts the OPAQUE handle crossed the chrome-surface↔renderer seam,
// not that Swift happened to `addSubview` a webview.
//
// One proof at a time (the narrowest real case), so the state is a single
// module-level value the exported thunks operate on.
// ---------------------------------------------------------------------------

const IosWebviewRenderer = @import("ios_webview_renderer.zig").IosWebviewRenderer;
const WkPlatform = @import("ios_webview_renderer.zig").WkPlatform;

/// The seam-level embedding-proof state. Holds BOTH seams under test (the
/// renderer backend and the mobile chrome-surface) plus the two facts the proof
/// asserts: did the seam deliver `.finished`, and did Swift report the embedded
/// view's snapshot non-blank.
const IosEmbedProof = struct {
    ios: IosWebviewRenderer,
    surface: MobileChromeSurface,
    /// Set once the `Renderer` seam delivered a `.finished` event (the page
    /// loaded through the seam — the `shell-test` bar).
    seam_finished: bool = false,
    /// Set from Swift once the EMBEDDED view's snapshot was scanned non-blank
    /// (the page is visible in the host, via the chrome-surface embed).
    embedded_non_blank: bool = false,
};

var ios_embed_proof: IosEmbedProof = undefined;

fn onIosEmbedEvent(ctx: *anyopaque, event: seam.LifecycleEvent) void {
    const p: *IosEmbedProof = @ptrCast(@alignCast(ctx));
    switch (event) {
        .load_changed => |lc| if (lc.state == .finished) {
            p.seam_finished = true;
        },
        else => {},
    }
}

/// Construct the iOS `Renderer` backend AND the mobile `ChromeSurface`, subscribe
/// the proof sink, navigate `uri` THROUGH the renderer seam, and embed the
/// renderer's opaque view THROUGH the chrome-surface seam
/// (`surface.embedView(renderer.view())`). Swift passes its `WkPlatform` ops and
/// its `EmbedPlatform` ops as raw C pointers. Returns an opaque proof context
/// Swift hands back to the nav-delegate + snapshot thunks. One proof at a time.
export fn wezig_ios_embed_proof_start(
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
    // The chrome-surface host + its embed ops (the WKWebView container).
    embed_host: *anyopaque,
    embedView: *const fn (host: *anyopaque, view: *anyopaque) callconv(.c) void,
    setUrlText: *const fn (host: *anyopaque, text: [*:0]const u8) callconv(.c) void,
    setBackEnabled: *const fn (host: *anyopaque, enabled: bool) callconv(.c) void,
    setForwardEnabled: *const fn (host: *anyopaque, enabled: bool) callconv(.c) void,
    uri: [*:0]const u8,
) *anyopaque {
    ios_embed_proof = .{
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
        }),
        .surface = MobileChromeSurface.init(.{
            .host = embed_host,
            .embedView = embedView,
            .setUrlText = setUrlText,
            .setBackEnabled = setBackEnabled,
            .setForwardEnabled = setForwardEnabled,
        }),
    };
    const r = ios_embed_proof.ios.renderer();
    r.setLifecycleCallback(.{ .ctx = &ios_embed_proof, .onEvent = onIosEmbedEvent });

    // THE PROOF: embed the renderer's opaque view THROUGH the chrome-surface
    // seam. The chrome would do exactly this; here it crosses a NON-GTK toolkit
    // host, resolving ADR-0007's flagged cross-toolkit-embedding case on iOS.
    const cs = ios_embed_proof.surface.chromeSurface();
    cs.embedView(r.view());

    r.navigate(uri);
    return &ios_embed_proof;
}

/// A `WKNavigationDelegate` load-state callback forwarded from Swift (same shape
/// as the renderer-proof thunk): map `state` (0=started,1=committed,2=finished,
/// 3=failed) to a `LifecycleEvent` and re-emit to the proof sink.
export fn wezig_ios_embed_on_load_state(ctx: *anyopaque, state: c_int, uri: ?[*:0]const u8) void {
    const p: *IosEmbedProof = @ptrCast(@alignCast(ctx));
    const load_state: seam.LoadState = switch (state) {
        0 => .started,
        1 => .committed,
        2 => .finished,
        else => .failed,
    };
    const uri_slice: ?[]const u8 = if (uri) |u| std.mem.span(u) else null;
    p.ios.onLoadState(load_state, uri_slice);
}

/// Swift reports whether scanning the EMBEDDED container's snapshot found a
/// non-blank pixel (the page is visible through the chrome-surface embed).
export fn wezig_ios_embed_set_non_blank(ctx: *anyopaque, non_blank: bool) void {
    const p: *IosEmbedProof = @ptrCast(@alignCast(ctx));
    p.embedded_non_blank = non_blank;
}

/// The embedding-proof verdict: true iff the seam delivered `.finished` AND the
/// EMBEDDED view rendered non-blank — i.e. the opaque handle carried the mobile
/// view across the chrome-surface seam and the page showed. Swift asserts this.
export fn wezig_ios_embed_proof_passed(ctx: *anyopaque) bool {
    const p: *IosEmbedProof = @ptrCast(@alignCast(ctx));
    return p.seam_finished and p.embedded_non_blank;
}

// ---------------------------------------------------------------------------
// Android embedding-proof C-ABI (spec `explore-mobile-shell`, Q3/story 6) — the
// SHARP risk. The opaque `ViewHandle` here is a JNI global-ref to the
// `android.webkit.WebView`. The JNI shim
// (`mobile/android/app/src/main/cpp/wezig_embedding_jni.c`) fills the
// `CEmbedPlatform` whose `embedView` calls the Java controller's
// `doEmbedView(WebView)` (a `ViewGroup.addView`), and the instrumented test
// (`EmbeddingProofTest`) asserts the WebView became a child of the container AND
// rendered non-blank — with the embed driven THROUGH `surface.embedView`, not a
// direct `addView`.
//
// This is the Android analogue of the iOS C-ABI above; it exists so the JNI
// shim can construct the mobile chrome-surface and drive one embed over the
// seam using ONLY C types (no Zig-struct-by-value from C).
// ---------------------------------------------------------------------------

/// The C-ABI mirror of `EmbedPlatform` the Android JNI shim fills in (field
/// order MUST match the shim's struct). Passed BY POINTER to
/// `wezig_android_chrome_surface_init`, which copies it into the surface.
pub const CEmbedPlatform = extern struct {
    host: ?*anyopaque,
    embedView: *const fn (host: ?*anyopaque, view: ?*anyopaque) callconv(.c) void,
    setUrlText: *const fn (host: ?*anyopaque, text: [*:0]const u8) callconv(.c) void,
    setBackEnabled: *const fn (host: ?*anyopaque, enabled: bool) callconv(.c) void,
    setForwardEnabled: *const fn (host: ?*anyopaque, enabled: bool) callconv(.c) void,
};

/// Adapter state stored alongside an Android chrome-surface created from the C
/// boundary: bridges the `EmbedPlatform`'s Zig-callconv fn-pointer types to the
/// shim's C-callconv `CEmbedPlatform`. Heap-owned; freed by
/// `wezig_android_chrome_surface_deinit`. The `CAndroidSurface` pointer itself
/// is the `EmbedPlatform.host` cookie the ops receive, so each op recovers this
/// adapter directly (no `@fieldParentPtr` juggling).
const CAndroidSurface = struct {
    surface: MobileChromeSurface,
    cplatform: CEmbedPlatform,

    fn embedView(host: *anyopaque, view: *anyopaque) callconv(.c) void {
        const self: *CAndroidSurface = @ptrCast(@alignCast(host));
        self.cplatform.embedView(self.cplatform.host, view);
    }
    fn setUrlText(host: *anyopaque, text: [*:0]const u8) callconv(.c) void {
        const self: *CAndroidSurface = @ptrCast(@alignCast(host));
        self.cplatform.setUrlText(self.cplatform.host, text);
    }
    fn setBackEnabled(host: *anyopaque, enabled: bool) callconv(.c) void {
        const self: *CAndroidSurface = @ptrCast(@alignCast(host));
        self.cplatform.setBackEnabled(self.cplatform.host, enabled);
    }
    fn setForwardEnabled(host: *anyopaque, enabled: bool) callconv(.c) void {
        const self: *CAndroidSurface = @ptrCast(@alignCast(host));
        self.cplatform.setForwardEnabled(self.cplatform.host, enabled);
    }
};

/// C-ABI constructor: allocate an Android chrome-surface whose `embedView`
/// forwards to `cplatform` (C fn pointers the JNI shim owns, each calling the
/// Java controller). Returns an opaque handle the shim keeps as a jlong and
/// threads into the embed down-call. Uses the C allocator so the shim owns the
/// lifetime symmetrically with `wezig_android_chrome_surface_deinit`. Null on OOM.
export fn wezig_android_chrome_surface_init(cplatform: *const CEmbedPlatform) ?*anyopaque {
    const s = std.heap.c_allocator.create(CAndroidSurface) catch return null;
    s.cplatform = cplatform.*;
    s.surface = MobileChromeSurface.init(.{
        .host = s,
        .embedView = CAndroidSurface.embedView,
        .setUrlText = CAndroidSurface.setUrlText,
        .setBackEnabled = CAndroidSurface.setBackEnabled,
        .setForwardEnabled = CAndroidSurface.setForwardEnabled,
    });
    return &s.surface;
}

/// C-ABI destructor: free an Android chrome-surface created by
/// `wezig_android_chrome_surface_init`.
export fn wezig_android_chrome_surface_deinit(handle: ?*anyopaque) void {
    const surface: *MobileChromeSurface = @ptrCast(@alignCast(handle orelse return));
    const s: *CAndroidSurface = @fieldParentPtr("surface", surface);
    std.heap.c_allocator.destroy(s);
}

/// C-ABI: embed `view` (a JNI global-ref to the `WebView`, as an opaque pointer)
/// THROUGH the chrome-surface seam. The shim gets `view` from the renderer's
/// `view()` op (already a JNI global-ref) and passes it here; this drives
/// `surface.embedView(view)`, whose Zig side forwards the OPAQUE bits back to
/// the shim's `embedView` op (which does the `ViewGroup.addView`). So the JNI
/// global-ref crosses the seam as an opaque handle — the Q3 proof.
export fn wezig_android_embed_view(handle: ?*anyopaque, view: ?*anyopaque) void {
    const surface: *MobileChromeSurface = @ptrCast(@alignCast(handle orelse return));
    const v = view orelse return;
    surface.chromeSurface().embedView(v);
}

// Force the embedding C-ABI `export fn`s to be analysed/emitted in a non-test
// static-lib build (same GC-retention issue + fix as `mobile_abi`/
// `android_renderer`).
comptime {
    _ = &wezig_ios_embed_proof_start;
    _ = &wezig_ios_embed_on_load_state;
    _ = &wezig_ios_embed_set_non_blank;
    _ = &wezig_ios_embed_proof_passed;
    _ = &wezig_android_chrome_surface_init;
    _ = &wezig_android_chrome_surface_deinit;
    _ = &wezig_android_embed_view;
}

// ---------------------------------------------------------------------------
// Headless seam-contract tests (run in `zig build test`; no UIKit, no JVM, no
// simulator/emulator). A fake `EmbedPlatform` records the embed, so the whole
// mobile chrome-surface's seam wiring is proven on the host. The REAL end-to-end
// proof (a page shows in the embedded view on a simulator/emulator) is the
// embedding CI legs (`mobile-verification-legs-ci` extension).
// ---------------------------------------------------------------------------

/// A fake native host for the tests: records the last embedded handle + widget
/// state, so the mobile chrome-surface is drivable with no UIKit/JVM.
const FakeHost = struct {
    embedded: ?*anyopaque = null,
    url_text: [256]u8 = undefined,
    url_len: usize = 0,
    back_enabled: bool = false,
    forward_enabled: bool = false,

    fn platform(self: *FakeHost) EmbedPlatform {
        return .{
            .host = self,
            .embedView = embedView,
            .setUrlText = setUrlText,
            .setBackEnabled = setBackEnabled,
            .setForwardEnabled = setForwardEnabled,
        };
    }
    fn embedView(host: *anyopaque, view: *anyopaque) callconv(.c) void {
        const self: *FakeHost = @ptrCast(@alignCast(host));
        self.embedded = view;
    }
    fn setUrlText(host: *anyopaque, text: [*:0]const u8) callconv(.c) void {
        const self: *FakeHost = @ptrCast(@alignCast(host));
        const slice = std.mem.span(text);
        const n = @min(slice.len, self.url_text.len);
        @memcpy(self.url_text[0..n], slice[0..n]);
        self.url_len = n;
    }
    fn setBackEnabled(host: *anyopaque, enabled: bool) callconv(.c) void {
        const self: *FakeHost = @ptrCast(@alignCast(host));
        self.back_enabled = enabled;
    }
    fn setForwardEnabled(host: *anyopaque, enabled: bool) callconv(.c) void {
        const self: *FakeHost = @ptrCast(@alignCast(host));
        self.forward_enabled = enabled;
    }
};

test "MobileChromeSurface: embedView forwards the OPAQUE handle unchanged to the native op" {
    // The heart of the Q3 proof at the seam-contract level: the chrome-surface
    // half must carry the renderer's opaque `ViewHandle` through `embedView`
    // WITHOUT interpreting it — the exact bits `Renderer.view()` produced must
    // reach the native embed op. (On the real Android leg those bits are a JNI
    // global-ref; here a stand-in token proves the seam is bit-transparent.)
    var host = FakeHost{};
    var surface = MobileChromeSurface.init(host.platform());
    const cs = surface.chromeSurface();

    // A stand-in for the renderer's opaque handle (a JNI global-ref on Android).
    var fake_view_token: u8 = 0xAB;
    const handle: seam.ViewHandle = &fake_view_token;

    cs.embedView(handle);

    // The native op received the SAME opaque bits — nothing above the seam
    // reinterpreted the handle.
    try std.testing.expect(host.embedded != null);
    try std.testing.expectEqual(@as(*anyopaque, handle), host.embedded.?);
}

test "MobileChromeSurface: the widget half stands alone (mobile shape, no HostLoop)" {
    // A mobile toolkit provides ONLY the chrome-surface half (ADR-0008). Prove
    // the widgets + intents work through `ChromeSurface` with no window/loop.
    var host = FakeHost{};
    var surface = MobileChromeSurface.init(host.platform());
    const cs = surface.chromeSurface();

    cs.setUrlText("https://mobile.example/");
    try std.testing.expectEqualStrings("https://mobile.example/", host.url_text[0..host.url_len]);

    cs.setBackEnabled(true);
    cs.setForwardEnabled(false);
    try std.testing.expect(host.back_enabled);
    try std.testing.expect(!host.forward_enabled);

    const Sink = struct {
        got_navigate: bool = false,
        fn onIntent(ctx: *anyopaque, intent: toolkit.ChromeIntent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (intent == .navigate) self.got_navigate = true;
        }
    };
    var sink = Sink{};
    cs.setChromeCallback(.{ .ctx = &sink, .onIntent = Sink.onIntent });
    surface.fireIntent(.{ .navigate = "https://x.example/" });
    try std.testing.expect(sink.got_navigate);
}

test "embedView carries the renderer's view() output across the seam (renderer -> surface)" {
    // End-to-end at the seam level (no webview, no host): a `Renderer` produces
    // an opaque `view()`; the chrome-surface `embedView`s exactly that handle;
    // the native op receives the renderer's bits. This is the whole
    // chrome-surface↔renderer boundary the task proves, headlessly.
    const FakeRenderer = seam.FakeRenderer;
    var fr = FakeRenderer.init(std.testing.allocator);
    defer fr.deinit();
    const r = fr.renderer();

    var host = FakeHost{};
    var surface = MobileChromeSurface.init(host.platform());
    const cs = surface.chromeSurface();

    // The chrome does: surface.embedView(renderer.view()). It never learns what
    // the handle is.
    cs.embedView(r.view());

    try std.testing.expectEqual(r.view(), host.embedded.?);
}

test "C-ABI Android chrome-surface: embed drives through the seam to the shim op (as JNI would)" {
    // Exercise the EXACT surface the Android JNI shim uses: build a C embed
    // ops-table, construct the surface via `wezig_android_chrome_surface_init`,
    // and drive `wezig_android_embed_view` with an opaque JNI-global-ref
    // stand-in — all through the C ABI. Proves the JNI global-ref carries across
    // `embedView` as an opaque handle (the Q3 contract) at the C boundary.
    const CHost = struct {
        var embedded: ?*anyopaque = null;
        fn embedView(_: ?*anyopaque, view: ?*anyopaque) callconv(.c) void {
            embedded = view;
        }
        fn setUrlText(_: ?*anyopaque, _: [*:0]const u8) callconv(.c) void {}
        fn setBackEnabled(_: ?*anyopaque, _: bool) callconv(.c) void {}
        fn setForwardEnabled(_: ?*anyopaque, _: bool) callconv(.c) void {}
    };
    CHost.embedded = null;

    const cplatform = CEmbedPlatform{
        .host = null,
        .embedView = CHost.embedView,
        .setUrlText = CHost.setUrlText,
        .setBackEnabled = CHost.setBackEnabled,
        .setForwardEnabled = CHost.setForwardEnabled,
    };
    const handle = wezig_android_chrome_surface_init(&cplatform).?;
    defer wezig_android_chrome_surface_deinit(handle);

    // A stand-in JNI global-ref (an opaque pointer, as the shim passes it).
    var fake_global_ref: u8 = 0xCD;
    wezig_android_embed_view(handle, &fake_global_ref);

    // The shim's embed op received the SAME opaque bits — the JNI ref crossed
    // the seam untouched.
    try std.testing.expect(CHost.embedded != null);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&fake_global_ref)), CHost.embedded.?);
}

test "C-ABI Android embed is null-safe (defensive JNI boundary)" {
    // A null handle or null view must not crash — the JNI boundary can pass null.
    wezig_android_embed_view(null, null);

    const CHost = struct {
        var called: bool = false;
        fn embedView(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
            called = true;
        }
        fn setUrlText(_: ?*anyopaque, _: [*:0]const u8) callconv(.c) void {}
        fn setBackEnabled(_: ?*anyopaque, _: bool) callconv(.c) void {}
        fn setForwardEnabled(_: ?*anyopaque, _: bool) callconv(.c) void {}
    };
    CHost.called = false;
    const cplatform = CEmbedPlatform{
        .host = null,
        .embedView = CHost.embedView,
        .setUrlText = CHost.setUrlText,
        .setBackEnabled = CHost.setBackEnabled,
        .setForwardEnabled = CHost.setForwardEnabled,
    };
    const handle = wezig_android_chrome_surface_init(&cplatform).?;
    defer wezig_android_chrome_surface_deinit(handle);
    // A null view is dropped, not forwarded (no crash, op not called).
    wezig_android_embed_view(handle, null);
    try std.testing.expect(!CHost.called);
}
