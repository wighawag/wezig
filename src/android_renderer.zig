//! `AndroidWebviewRenderer`: the `Renderer` seam (renderer.zig) implemented over
//! `android.webkit.WebView` (spec `explore-mobile-shell`, story 5; ADR-0005,
//! ADR-0006). This is the ANDROID counterpart of `SystemWebviewRenderer`
//! (WebKitGTK, desktop): it satisfies the SAME pinned `Renderer` interface so
//! the chrome, the Ethereum provider, and IPFS resolution stay backend-agnostic
//! and swap onto Android with no change above the seam.
//!
//! ## Why this backend looks different from the desktop one (the JVM boundary)
//!
//! On desktop the whole backend is Zig calling WebKitGTK C directly. On Android
//! the WebView is a Java object living on the JVM side, so the backend is a
//! Zig↔Java BRIDGE:
//!
//!   - **down-calls (seam -> WebView):** `navigate`/`reload`/`stop`,
//!     `goBack`/`goForward`, `canGoBack`/`canGoForward`, `setViewportSize` call
//!     THROUGH a small table of function pointers (`JavaBridge`) that the JNI
//!     shim (`mobile/android/app/src/main/cpp/wezig_renderer_jni.c`) fills in
//!     with calls into the Java `WezigWebViewController`.
//!   - **up-calls (WebView -> seam):** the Java `WebViewClient`'s load callbacks
//!     enter Zig through the C-ABI `export fn`s at the bottom of this file
//!     (`wezig_android_on_load_state` / `_on_uri_changed` / `_on_title_changed`
//!     / `_on_progress`), which decode the raw event and re-emit it as a
//!     `LifecycleEvent` to the subscribed `LifecycleCallback`.
//!
//! Keeping the down-calls behind a `JavaBridge` pointer table (rather than a
//! hard `@extern` to the shim) is what lets `zig build test` drive the backend
//! HEADLESSLY with a fake bridge — the exact same discipline `FakeRenderer`
//! uses to prove the seam contract without a webview or a display. The real
//! JNI wiring is exercised on an x86_64 emulator by the Android instrumented
//! test (`mobile-verification-legs-ci`); this file's local floor is that the
//! bridge + seam mapping compile and the contract holds.
//!
//! ## The thread contract (spec Q5 — the KNOWN GAP, recorded as a finding)
//!
//! `WebViewClient` load callbacks (`onPageStarted`/`onPageFinished`/…) and
//! `shouldInterceptRequest` run on NON-UI (binder) threads. The seam's
//! `LifecycleCallback` is single-sink and expected to be delivered on the host
//! loop's thread (the desktop backend emits on the GTK main loop). So the Java
//! side MARSHALS every `WebViewClient` callback onto the UI thread (a
//! `Handler(Looper.getMainLooper())` post) BEFORE it crosses into the
//! `wezig_android_on_*` entry points here — the up-call already arrives on the
//! UI thread, and this Zig code performs no cross-thread work of its own. That
//! keeps this backend's contract identical to the desktop one: the chrome sees
//! lifecycle events serialized on one thread. (Finding recorded in the task
//! done-record; see `mobile/android/README.md`.)
//!
//! ## The two web3 hooks (spec `explore-mobile-shell` stories 8,9; this task)
//!
//! Both web3-load-bearing hooks now carry through this backend, mirroring the
//! desktop `SystemWebviewRenderer` (WebKitGTK) and the iOS backend:
//!
//!   - **script-message bridge:** `injectUserScript` runs a page-world script
//!     (Android has no document-start user-script API, so the Java side injects
//!     via `evaluateJavascript` / a load-time hook — see the finding below);
//!     `setScriptMessageHandler` registers an `addJavascriptInterface` object so
//!     `window.<name>.postMessage(v)` reaches native; `evaluateScript` runs JS
//!     back into the page. The page->native leg re-enters Zig at
//!     `wezig_android_on_script_message`.
//!   - **custom-scheme interception:** `registerScheme` records a native scheme
//!     handler; the Java `WebViewClient.shouldInterceptRequest` serves each
//!     request for that scheme by up-calling `wezig_android_serve_scheme`.
//!
//! ## The thread contract for the hooks (spec Q5 — the KNOWN GAP, sharper here)
//!
//! `addJavascriptInterface` callbacks arrive on a private binder thread (the
//! `JavaBridge` thread), and `shouldInterceptRequest` runs on a NON-UI (binder)
//! thread too. The seam's callbacks are single-sink and expected serialized on
//! the host thread. So the Java side MARSHALS the bridge post onto the UI thread
//! before crossing into `wezig_android_on_script_message` (same discipline as
//! the load callbacks). `shouldInterceptRequest`, however, must return its
//! response SYNCHRONOUSLY on the binder thread (the WebView blocks that thread
//! waiting for the bytes) — it CANNOT hop to the UI thread and wait. So the
//! scheme up-call (`wezig_android_serve_scheme`) is the ONE seam callback that
//! legitimately runs off the UI thread; the seam `SchemeHandler` it invokes must
//! be thread-safe / not touch UI state. This is recorded as a finding
//! (`work/notes/findings/android-custom-scheme-nonui-thread-and-opaque-origin-2026-07-18.md`)
//! because it is load-bearing for `ipfs://`.
//!
//! The ONLY Android code that imports `android.webkit.*` is the Java
//! `WezigWebViewController`; this Zig file and everything above the seam never
//! do (the same discipline the desktop chrome keeps against `webkit_`/`gtk_`).

const std = @import("std");
const seam = @import("renderer.zig");

/// The raw `WebViewClient` load-callback codes the Java side reports up through
/// `wezig_android_on_load_state`. They map 1:1 onto the seam's `LoadState`, but
/// are their OWN enum so the JNI boundary carries a stable integer the Java
/// shim writes, decoupled from the seam enum's declaration order. Kept in
/// lock-step with `WezigWebViewController`'s constants.
pub const AndroidLoadEvent = enum(c_int) {
    /// `WebViewClient.onPageStarted` — a provisional load began.
    page_started = 0,
    /// `WebViewClient.onPageCommitVisible` — first paint / content committed.
    page_committed = 1,
    /// `WebViewClient.onPageFinished` — the load finished successfully.
    page_finished = 2,
    /// `WebViewClient.onReceivedError` — the load failed.
    page_failed = 3,
};

/// Decode a raw JNI load-event integer into the seam's `LoadState`. Returns
/// null for an unrecognised code (so a future Java-side event the seam does not
/// model is dropped, not mis-mapped). Pure + unit-testable — this is the heart
/// of the `WebViewClient` -> `LifecycleEvent` mapping the acceptance criterion
/// calls out, provable with no JNI and no emulator.
pub fn mapLoadState(code: c_int) ?seam.LoadState {
    return switch (code) {
        @intFromEnum(AndroidLoadEvent.page_started) => .started,
        @intFromEnum(AndroidLoadEvent.page_committed) => .committed,
        @intFromEnum(AndroidLoadEvent.page_finished) => .finished,
        @intFromEnum(AndroidLoadEvent.page_failed) => .failed,
        // An unrecognised code is dropped, not mis-mapped.
        else => null,
    };
}

/// The table of down-call function pointers the JNI shim fills in: each drives
/// the corresponding Java `WezigWebViewController` method over JNI. Held by
/// pointer so `zig build test` can supply a FAKE bridge and drive the backend
/// headlessly (mirroring `FakeRenderer`), and so the real shim owns all `jni.h`
/// contact — this Zig file never includes it.
pub const JavaBridge = struct {
    ctx: *anyopaque,
    navigate: *const fn (ctx: *anyopaque, uri: [*:0]const u8) void,
    reload: *const fn (ctx: *anyopaque) void,
    stop: *const fn (ctx: *anyopaque) void,
    goBack: *const fn (ctx: *anyopaque) void,
    goForward: *const fn (ctx: *anyopaque) void,
    canGoBack: *const fn (ctx: *anyopaque) bool,
    canGoForward: *const fn (ctx: *anyopaque) bool,
    /// Return the opaque `ViewHandle` for the Java `WebView` — a JNI global ref
    /// (spec Q3: on Android the handle is a JNI reference, not a raw pointer).
    /// Carried opaquely across the seam exactly like the desktop `GtkWidget`.
    /// NOTE: each call MINTS a fresh JNI global-ref (the shim's `NewGlobalRef`),
    /// so the backend calls this AT MOST ONCE per view and caches the result
    /// (see `viewHandle` + `cached_view`); the leak the spike flagged (a ref per
    /// `view()` call) is fixed by that caching, not by the shim.
    view: *const fn (ctx: *anyopaque) seam.ViewHandle,
    /// Delete a JNI global-ref previously minted by `view` (the shim's
    /// `DeleteGlobalRef`). Called EXACTLY ONCE on teardown, on the one cached
    /// view ref, so the net live-ref count returns to zero (ADR-0009 hazard).
    deleteView: *const fn (ctx: *anyopaque, view: seam.ViewHandle) void,
    setViewportSize: *const fn (ctx: *anyopaque, width: c_int, height: c_int) void,

    // --- the two web3 hooks (ADR-0005; spec stories 8,9) ---
    /// Run `source` in the page world (native->page setup leg of the bridge).
    injectUserScript: *const fn (ctx: *anyopaque, source: [*:0]const u8) void,
    /// Register the page->native channel `name` via `addJavascriptInterface`
    /// (opens `window.<name>.postMessage`). The page's posts flow back to the
    /// seam at `wezig_android_on_script_message`.
    setScriptMessageHandler: *const fn (ctx: *anyopaque, name: [*:0]const u8) void,
    /// Evaluate `source` as JS in the current page (native->page reply leg).
    evaluateScript: *const fn (ctx: *anyopaque, source: [*:0]const u8) void,
    /// Register the custom URI scheme `scheme`; the Java
    /// `WebViewClient.shouldInterceptRequest` serves it from native by
    /// up-calling `wezig_android_serve_scheme`.
    registerScheme: *const fn (ctx: *anyopaque, scheme: [*:0]const u8) void,
    /// Free the bridge's own native side (the JNI shim's per-renderer context:
    /// its cached `JavaVM` + the global-ref to the Java controller — the
    /// renderer-side analogue of the embedding shim's leaked `EmbedCtx`).
    /// Called EXACTLY ONCE on teardown, after `deleteView`, so no native
    /// per-renderer state outlives the backend (ADR-0009 hazard).
    teardown: *const fn (ctx: *anyopaque) void,
};

/// A `Renderer` backed by one Java `android.webkit.WebView` reached over JNI.
/// Construct with `init(bridge)`, obtain the seam value with `renderer()`, and
/// hand THAT to the chrome. The chrome never sees the `WebView`; it flows to the
/// toolkit only as an opaque `ViewHandle` (a JNI global ref to the WebView).
pub const AndroidWebviewRenderer = struct {
    /// Upper bound on a re-injectable user script (the marker/provider bridge
    /// source). Owned IN-STRUCT (no allocator on this backend, matching the
    /// module's fixed-buffer style, e.g. the scheme/title C-observer buffers) so
    /// the source survives the `injectUserScript` call to be re-issued on later
    /// `.started` events — the seam only lends `source` for the call's duration.
    pub const max_injected_source = 8192;

    bridge: JavaBridge,
    cb: ?seam.LifecycleCallback = null,
    /// The single page->native script-message handler (script bridge, ADR-0005).
    msg_cb: ?seam.ScriptMessageCallback = null,
    /// The single custom-scheme handler (request interception, ADR-0005).
    scheme_handler: ?seam.SchemeHandler = null,
    /// The last `injectUserScript` source, copied into `injected_buf` (owned)
    /// and re-issued on every `.started` (Resolved decision 2 / ADR-0009 §3:
    /// Android has no `WKUserScript(.atDocumentStart)`, so ONE caller-side
    /// `injectUserScript` gets document-start semantics on every page by the
    /// backend re-injecting on each page start). Null until the first inject.
    injected_source: ?[:0]const u8 = null,
    injected_buf: [max_injected_source:0]u8 = undefined,
    /// The ONE cached JNI global-ref for this view: minted lazily on the first
    /// `view()` (via the bridge's `view` op) and returned UNCHANGED thereafter,
    /// so exactly one global-ref lives per view instead of one per call (the
    /// ADR-0009 hazard). Deleted on teardown via `bridge.deleteView`.
    cached_view: ?seam.ViewHandle = null,

    pub fn init(bridge: JavaBridge) AndroidWebviewRenderer {
        return .{ .bridge = bridge };
    }

    /// Backend teardown: delete the one cached view global-ref (if minted) and
    /// free the bridge's native context, so no JNI global-ref outlives the
    /// backend (ADR-0009 hazard: the per-view ref leak + the leaked native ctx).
    /// Idempotent w.r.t. the view ref (it is cleared after deletion). The real
    /// JNI ops (`DeleteGlobalRef` / freeing the shim's `JavaCtx`) live behind the
    /// bridge; the headless fake bridge models them with its ref counter.
    pub fn deinit(self: *AndroidWebviewRenderer) void {
        if (self.cached_view) |v| {
            self.bridge.deleteView(self.bridge.ctx, v);
            self.cached_view = null;
        }
        self.bridge.teardown(self.bridge.ctx);
    }

    pub fn renderer(self: *AndroidWebviewRenderer) seam.Renderer {
        return .{ .ptr = self, .vtable = &vtable };
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

    // --- navigation: down-calls into the Java WebView over the bridge ---

    fn navigate(ctx: *anyopaque, uri: [*:0]const u8) void {
        const self: *AndroidWebviewRenderer = @ptrCast(@alignCast(ctx));
        self.bridge.navigate(self.bridge.ctx, uri);
    }
    fn reloadFn(ctx: *anyopaque) void {
        const self: *AndroidWebviewRenderer = @ptrCast(@alignCast(ctx));
        self.bridge.reload(self.bridge.ctx);
    }
    fn stopFn(ctx: *anyopaque) void {
        const self: *AndroidWebviewRenderer = @ptrCast(@alignCast(ctx));
        self.bridge.stop(self.bridge.ctx);
    }
    fn goBack(ctx: *anyopaque) void {
        const self: *AndroidWebviewRenderer = @ptrCast(@alignCast(ctx));
        self.bridge.goBack(self.bridge.ctx);
    }
    fn goForward(ctx: *anyopaque) void {
        const self: *AndroidWebviewRenderer = @ptrCast(@alignCast(ctx));
        self.bridge.goForward(self.bridge.ctx);
    }
    fn canGoBack(ctx: *anyopaque) bool {
        const self: *AndroidWebviewRenderer = @ptrCast(@alignCast(ctx));
        return self.bridge.canGoBack(self.bridge.ctx);
    }
    fn canGoForward(ctx: *anyopaque) bool {
        const self: *AndroidWebviewRenderer = @ptrCast(@alignCast(ctx));
        return self.bridge.canGoForward(self.bridge.ctx);
    }

    // --- view / viewport ---

    fn viewHandle(ctx: *anyopaque) seam.ViewHandle {
        const self: *AndroidWebviewRenderer = @ptrCast(@alignCast(ctx));
        // The interactive view IS the Java WebView; hand its JNI global ref
        // across opaquely (spec Q3). Only the Android toolkit/embedding code
        // downcasts it back to a WebView reference. Mint the global-ref LAZILY
        // on the first call and cache it, returning the SAME ref thereafter, so
        // exactly one global-ref lives per view (ADR-0009 hazard: the spike
        // minted a fresh ref — and leaked it — on every `view()` call).
        if (self.cached_view) |v| return v;
        const v = self.bridge.view(self.bridge.ctx);
        self.cached_view = v;
        return v;
    }
    fn setViewportSize(ctx: *anyopaque, width: c_int, height: c_int) void {
        const self: *AndroidWebviewRenderer = @ptrCast(@alignCast(ctx));
        // The embedded WebView tracks its allocated size from Android layout;
        // like the desktop backend this is effectively a no-op today, but the
        // seam method is forwarded so a `WezigRenderer` can honour it (ADR-0006).
        self.bridge.setViewportSize(self.bridge.ctx, width, height);
    }

    // --- lifecycle events ---

    fn setLifecycleCallback(ctx: *anyopaque, cb: seam.LifecycleCallback) void {
        const self: *AndroidWebviewRenderer = @ptrCast(@alignCast(ctx));
        self.cb = cb;
    }

    fn emit(self: *AndroidWebviewRenderer, event: seam.LifecycleEvent) void {
        if (self.cb) |cb| cb.onEvent(cb.ctx, event);
    }

    // --- up-call dispatch: the Java WebViewClient's callbacks arrive here ---
    // (already marshalled onto the UI thread by the Java side — see the thread
    // contract note in the module doc). These are the mapping the JNI export
    // entry points below drive.

    /// A `WebViewClient` load-state callback: map the raw code and re-emit as a
    /// `.load_changed` lifecycle event. `uri` is borrowed for the call.
    ///
    /// Document-start re-injection (Resolved decision 2 / ADR-0009 §3): on every
    /// `.started` this re-issues the last `injectUserScript` source through the
    /// bridge, so ONE caller-side `injectUserScript` yields document-start
    /// semantics on every page — keeping the injection contract seam-uniform
    /// with iOS's `WKUserScript(.atDocumentStart)` and WebKitGTK's
    /// user-content-manager document-start injection, WITHOUT growing the seam
    /// or leaking the platform quirk above it. Android's `WebView` has no
    /// document-start user-script API, so re-issuing on each page start is the
    /// mechanism. Fires BEFORE the event is emitted so the injected page-world
    /// object exists before any subscriber reacts to the load starting.
    pub fn dispatchLoadState(self: *AndroidWebviewRenderer, code: c_int, uri: ?[]const u8) void {
        const state = mapLoadState(code) orelse return;
        if (state == .started) {
            if (self.injected_source) |source| {
                self.bridge.injectUserScript(self.bridge.ctx, source.ptr);
            }
        }
        self.emit(.{ .load_changed = .{ .state = state, .uri = uri } });
    }

    /// A `WebView` URL change (redirects, history navigation) -> `.uri_changed`.
    pub fn dispatchUriChanged(self: *AndroidWebviewRenderer, uri: []const u8) void {
        self.emit(.{ .uri_changed = uri });
    }

    /// A document-title change -> `.title_changed`.
    pub fn dispatchTitleChanged(self: *AndroidWebviewRenderer, title: []const u8) void {
        self.emit(.{ .title_changed = title });
    }

    /// A load-progress change in [0,100] (Android's `WebChromeClient` reports an
    /// int percent) -> `.progress_changed` in [0.0, 1.0].
    pub fn dispatchProgress(self: *AndroidWebviewRenderer, percent: c_int) void {
        const clamped = std.math.clamp(percent, 0, 100);
        self.emit(.{ .progress_changed = @as(f64, @floatFromInt(clamped)) / 100.0 });
    }

    // --- up-call dispatch for the two web3 hooks (ADR-0005; spec stories 8,9) ---

    /// A page-world post arrived on channel `name` (the page called
    /// `window.<name>.postMessage(body)` via `addJavascriptInterface`). Already
    /// marshalled onto the UI thread by the Java side (the bridge thread contract
    /// in the module doc). Re-emits to the seam's `ScriptMessageCallback`.
    /// `name`/`body` are borrowed for the call (the seam contract).
    pub fn dispatchScriptMessage(self: *AndroidWebviewRenderer, name: []const u8, body: []const u8) void {
        const cb = self.msg_cb orelse return;
        cb.onMessage(cb.ctx, name, body);
    }

    /// A request for the registered custom scheme arrived
    /// (`WebViewClient.shouldInterceptRequest`). Ask the seam handler for the
    /// native body + content-type; returns null if no handler is registered (the
    /// Java side then returns null so the WebView falls through). NOTE: this runs
    /// on the binder thread — the ONE seam callback that is NOT UI-thread
    /// serialized (it must answer synchronously; the module doc's thread
    /// contract). The returned slices are borrowed until the handler is next
    /// called (the seam contract), so the Java side copies them immediately.
    pub fn serveSchemeRequest(self: *AndroidWebviewRenderer, uri: []const u8) ?seam.SchemeResponse {
        const h = self.scheme_handler orelse return null;
        return h.onRequest(h.ctx, uri);
    }

    // --- the two web3 hooks: down-calls into the Java WebView over the bridge ---
    // The iOS/desktop twin: `setScriptMessageHandler`/`registerScheme` record
    // the seam callback here (so the page->native + scheme-serve legs re-enter
    // Zig) and reach the Java bridge (which installs the platform primitive).

    fn injectUserScript(ctx: *anyopaque, source: [*:0]const u8) void {
        const self: *AndroidWebviewRenderer = @ptrCast(@alignCast(ctx));
        // Remember the source (owned copy) so it can be re-issued on each page
        // start (Resolved decision 2 — see `dispatchLoadState`). A source longer
        // than `max_injected_source` is still injected now but NOT remembered
        // (it cannot be re-issued); the marker/provider bridge sources this is
        // built for are far smaller. Then issue the initial injection.
        const span = std.mem.span(source);
        if (span.len <= max_injected_source) {
            @memcpy(self.injected_buf[0..span.len], span);
            self.injected_buf[span.len] = 0;
            self.injected_source = self.injected_buf[0..span.len :0];
        } else {
            self.injected_source = null;
        }
        self.bridge.injectUserScript(self.bridge.ctx, source);
    }
    fn setScriptMessageHandler(ctx: *anyopaque, name: [*:0]const u8, cb: seam.ScriptMessageCallback) void {
        const self: *AndroidWebviewRenderer = @ptrCast(@alignCast(ctx));
        self.msg_cb = cb;
        self.bridge.setScriptMessageHandler(self.bridge.ctx, name);
    }
    fn evaluateScript(ctx: *anyopaque, source: [*:0]const u8) void {
        const self: *AndroidWebviewRenderer = @ptrCast(@alignCast(ctx));
        self.bridge.evaluateScript(self.bridge.ctx, source);
    }
    fn registerScheme(ctx: *anyopaque, scheme: [*:0]const u8, handler: seam.SchemeHandler) void {
        const self: *AndroidWebviewRenderer = @ptrCast(@alignCast(ctx));
        self.scheme_handler = handler;
        self.bridge.registerScheme(self.bridge.ctx, scheme);
    }
};

// ---------------------------------------------------------------------------
// JNI up-call entry points (C-ABI). The Java WebViewClient calls THESE through
// the JNI shim after marshalling onto the UI thread. `handle` is the
// `*AndroidWebviewRenderer` the shim received at construction (as an opaque
// jlong). Strings arrive NUL-terminated (the shim converts the jstring); a null
// pointer means "absent" (e.g. no URI yet very early in a load).
//
// These are `export fn` so the shim links them; they are force-retained in the
// static archive via the `comptime` reference at the bottom of this file (the
// same technique `root.zig` uses for `mobile_abi`). They take only primitive
// C types + C strings, so this file needs NO `jni.h` — the shim owns all JNI.
// ---------------------------------------------------------------------------

fn spanOrNull(s: ?[*:0]const u8) ?[]const u8 {
    return if (s) |p| std.mem.span(p) else null;
}

// --- construction + down-call C-ABI (the JNI shim calls THESE) --------------
// The shim owns the `AndroidWebviewRenderer` storage lifetime: it allocates a
// slot, calls `wezig_android_renderer_init` with a filled `CJavaBridge`, keeps
// the returned handle as a jlong, and issues navigation down-calls through the
// `wezig_android_*` wrappers. Kept C-ABI so the shim needs no knowledge of the
// Zig struct layout (and no Zig-struct-by-value calls from C).

/// The C-ABI mirror of `JavaBridge`: a plain struct of C function pointers the
/// JNI shim fills in (each calls a Java `WezigWebViewController.do*` method).
/// Passed BY POINTER to `wezig_android_renderer_init`, which copies it into the
/// renderer. `bool` is C-ABI-compatible here (Zig lowers it to a byte the shim
/// reads as a C99 `bool`/`jboolean`).
pub const CJavaBridge = extern struct {
    ctx: ?*anyopaque,
    navigate: *const fn (ctx: ?*anyopaque, uri: [*:0]const u8) callconv(.c) void,
    reload: *const fn (ctx: ?*anyopaque) callconv(.c) void,
    stop: *const fn (ctx: ?*anyopaque) callconv(.c) void,
    goBack: *const fn (ctx: ?*anyopaque) callconv(.c) void,
    goForward: *const fn (ctx: ?*anyopaque) callconv(.c) void,
    canGoBack: *const fn (ctx: ?*anyopaque) callconv(.c) bool,
    canGoForward: *const fn (ctx: ?*anyopaque) callconv(.c) bool,
    view: *const fn (ctx: ?*anyopaque) callconv(.c) ?*anyopaque,
    /// Delete a JNI global-ref previously returned by `view` (the shim's
    /// `DeleteGlobalRef`). Mirror of `JavaBridge.deleteView`; the JNI shim's
    /// `WezigCJavaBridge` (field order MUST match) gains the same op.
    deleteView: *const fn (ctx: ?*anyopaque, view: ?*anyopaque) callconv(.c) void,
    setViewportSize: *const fn (ctx: ?*anyopaque, width: c_int, height: c_int) callconv(.c) void,
    // --- the two web3 hooks (ADR-0005; spec stories 8,9) ---
    injectUserScript: *const fn (ctx: ?*anyopaque, source: [*:0]const u8) callconv(.c) void,
    setScriptMessageHandler: *const fn (ctx: ?*anyopaque, name: [*:0]const u8) callconv(.c) void,
    evaluateScript: *const fn (ctx: ?*anyopaque, source: [*:0]const u8) callconv(.c) void,
    registerScheme: *const fn (ctx: ?*anyopaque, scheme: [*:0]const u8) callconv(.c) void,
    /// Free the shim's per-renderer native context (its `JavaCtx`: the cached
    /// `JavaVM` + the controller global-ref). Mirror of `JavaBridge.teardown`.
    teardown: *const fn (ctx: ?*anyopaque) callconv(.c) void,
};

/// Adapter state stored alongside a renderer created from the C boundary: it
/// bridges the seam's Zig-callconv `JavaBridge` fn-pointer types to the shim's
/// C-callconv `CJavaBridge`. Heap-owned; freed by `wezig_android_renderer_deinit`.
const CBackend = struct {
    backend: AndroidWebviewRenderer,
    cbridge: CJavaBridge,

    fn navigate(ctx: *anyopaque, uri: [*:0]const u8) void {
        const self: *CBackend = @fieldParentPtr("backend", @as(*AndroidWebviewRenderer, @ptrCast(@alignCast(ctx))));
        self.cbridge.navigate(self.cbridge.ctx, uri);
    }
    fn reload(ctx: *anyopaque) void {
        const self: *CBackend = @fieldParentPtr("backend", @as(*AndroidWebviewRenderer, @ptrCast(@alignCast(ctx))));
        self.cbridge.reload(self.cbridge.ctx);
    }
    fn stop(ctx: *anyopaque) void {
        const self: *CBackend = @fieldParentPtr("backend", @as(*AndroidWebviewRenderer, @ptrCast(@alignCast(ctx))));
        self.cbridge.stop(self.cbridge.ctx);
    }
    fn goBack(ctx: *anyopaque) void {
        const self: *CBackend = @fieldParentPtr("backend", @as(*AndroidWebviewRenderer, @ptrCast(@alignCast(ctx))));
        self.cbridge.goBack(self.cbridge.ctx);
    }
    fn goForward(ctx: *anyopaque) void {
        const self: *CBackend = @fieldParentPtr("backend", @as(*AndroidWebviewRenderer, @ptrCast(@alignCast(ctx))));
        self.cbridge.goForward(self.cbridge.ctx);
    }
    fn canGoBack(ctx: *anyopaque) bool {
        const self: *CBackend = @fieldParentPtr("backend", @as(*AndroidWebviewRenderer, @ptrCast(@alignCast(ctx))));
        return self.cbridge.canGoBack(self.cbridge.ctx);
    }
    fn canGoForward(ctx: *anyopaque) bool {
        const self: *CBackend = @fieldParentPtr("backend", @as(*AndroidWebviewRenderer, @ptrCast(@alignCast(ctx))));
        return self.cbridge.canGoForward(self.cbridge.ctx);
    }
    fn view(ctx: *anyopaque) seam.ViewHandle {
        const self: *CBackend = @fieldParentPtr("backend", @as(*AndroidWebviewRenderer, @ptrCast(@alignCast(ctx))));
        return self.cbridge.view(self.cbridge.ctx) orelse undefined;
    }
    fn deleteView(ctx: *anyopaque, v: seam.ViewHandle) void {
        const self: *CBackend = @fieldParentPtr("backend", @as(*AndroidWebviewRenderer, @ptrCast(@alignCast(ctx))));
        self.cbridge.deleteView(self.cbridge.ctx, v);
    }
    fn teardown(ctx: *anyopaque) void {
        const self: *CBackend = @fieldParentPtr("backend", @as(*AndroidWebviewRenderer, @ptrCast(@alignCast(ctx))));
        self.cbridge.teardown(self.cbridge.ctx);
    }
    fn setViewportSize(ctx: *anyopaque, width: c_int, height: c_int) void {
        const self: *CBackend = @fieldParentPtr("backend", @as(*AndroidWebviewRenderer, @ptrCast(@alignCast(ctx))));
        self.cbridge.setViewportSize(self.cbridge.ctx, width, height);
    }
    fn injectUserScript(ctx: *anyopaque, source: [*:0]const u8) void {
        const self: *CBackend = @fieldParentPtr("backend", @as(*AndroidWebviewRenderer, @ptrCast(@alignCast(ctx))));
        self.cbridge.injectUserScript(self.cbridge.ctx, source);
    }
    fn setScriptMessageHandler(ctx: *anyopaque, name: [*:0]const u8) void {
        const self: *CBackend = @fieldParentPtr("backend", @as(*AndroidWebviewRenderer, @ptrCast(@alignCast(ctx))));
        self.cbridge.setScriptMessageHandler(self.cbridge.ctx, name);
    }
    fn evaluateScript(ctx: *anyopaque, source: [*:0]const u8) void {
        const self: *CBackend = @fieldParentPtr("backend", @as(*AndroidWebviewRenderer, @ptrCast(@alignCast(ctx))));
        self.cbridge.evaluateScript(self.cbridge.ctx, source);
    }
    fn registerScheme(ctx: *anyopaque, scheme: [*:0]const u8) void {
        const self: *CBackend = @fieldParentPtr("backend", @as(*AndroidWebviewRenderer, @ptrCast(@alignCast(ctx))));
        self.cbridge.registerScheme(self.cbridge.ctx, scheme);
    }
};

/// C-ABI constructor: allocate a renderer whose down-calls forward to `cbridge`
/// (a C fn-pointer table the shim owns). Returns an opaque handle the shim keeps
/// as a jlong and threads into the up-call and down-call C-ABI functions. Uses
/// the C allocator so the shim owns the lifetime symmetrically with
/// `wezig_android_renderer_deinit`. Returns null on OOM.
export fn wezig_android_renderer_init(cbridge: *const CJavaBridge) ?*anyopaque {
    const cb = std.heap.c_allocator.create(CBackend) catch return null;
    cb.cbridge = cbridge.*;
    cb.backend = AndroidWebviewRenderer.init(.{
        .ctx = &cb.backend,
        .navigate = CBackend.navigate,
        .reload = CBackend.reload,
        .stop = CBackend.stop,
        .goBack = CBackend.goBack,
        .goForward = CBackend.goForward,
        .canGoBack = CBackend.canGoBack,
        .canGoForward = CBackend.canGoForward,
        .view = CBackend.view,
        .deleteView = CBackend.deleteView,
        .setViewportSize = CBackend.setViewportSize,
        .injectUserScript = CBackend.injectUserScript,
        .setScriptMessageHandler = CBackend.setScriptMessageHandler,
        .evaluateScript = CBackend.evaluateScript,
        .registerScheme = CBackend.registerScheme,
        .teardown = CBackend.teardown,
    });
    // The up-call entry points receive this same handle (the `*AndroidWebviewRenderer`).
    return &cb.backend;
}

/// C-ABI destructor: free a renderer created by `wezig_android_renderer_init`.
/// Runs the backend teardown FIRST (deletes the one cached view global-ref via
/// the bridge's `deleteView`, then frees the shim's native ctx via `teardown` —
/// the ADR-0009 leak fixes) BEFORE freeing the Zig adapter, so the bridge ops
/// still see a live `cbridge`/ctx when they run.
export fn wezig_android_renderer_deinit(handle: ?*anyopaque) void {
    const backend: *AndroidWebviewRenderer = @ptrCast(@alignCast(handle orelse return));
    backend.deinit();
    const cb: *CBackend = @fieldParentPtr("backend", backend);
    std.heap.c_allocator.destroy(cb);
}

/// C-ABI down-call: begin loading `uri`. The shim calls this on the UI thread.
export fn wezig_android_navigate(handle: ?*anyopaque, uri: [*:0]const u8) void {
    const backend: *AndroidWebviewRenderer = @ptrCast(@alignCast(handle orelse return));
    backend.renderer().navigate(uri);
}

/// C-ABI: return the renderer's opaque `ViewHandle` (a JNI global-ref to the
/// `WebView`) via the seam's `view()`. The embedding proof
/// (`mobile-viewhandle-embedding-proof`, spec Q3/story 6) obtains THIS handle and
/// hands it to `wezig_android_embed_view` (mobile_chrome_surface.zig), so the
/// JNI global-ref crosses the chrome-surface seam as an opaque `*anyopaque`.
/// Returns null if no proof is active. The caller must NOT delete the returned
/// global-ref (the JNI bridge owns it).
export fn wezig_android_renderer_view(handle: ?*anyopaque) ?*anyopaque {
    const backend: *AndroidWebviewRenderer = @ptrCast(@alignCast(handle orelse return null));
    return backend.renderer().view();
}

/// The seam `LifecycleCallback` sink used when the native side must report
/// events back UP to a C observer (the instrumented test / a future native
/// chrome). `onEvent` is a C fn pointer; the load state is passed as the raw
/// `AndroidLoadEvent` code so C need not know the seam enum, and `uri` is a
/// borrowed C string (null when absent). This is how a Java test subscribes to
/// the REAL seam `.finished` event (mirroring the desktop `shell-test` sink),
/// rather than observing the WebView directly.
pub const CLifecycleObserver = extern struct {
    ctx: ?*anyopaque,
    onLoadState: *const fn (ctx: ?*anyopaque, code: c_int, uri: ?[*:0]const u8) callconv(.c) void,
    /// The document title changed (`.title_changed`). Load-bearing for the
    /// scheme proof: the native-served body's `<title>` marker arriving here
    /// proves it BOTH served AND rendered (the desktop `shell-scheme-test`
    /// assertion). `title` is a borrowed C string.
    onTitle: *const fn (ctx: ?*anyopaque, title: ?[*:0]const u8) callconv(.c) void,
};

/// The installed C observer (the seam is single-sink, so one global suffices).
/// Stored module-level because the renderer struct is owned by C and we avoid
/// changing its layout; `onCObserverEvent` reads it. Set by
/// `wezig_android_set_lifecycle_observer`.
var c_observer: ?CLifecycleObserver = null;

/// The lifecycle callback that was subscribed BEFORE the C observer was
/// installed (e.g. the shell's `MobileChrome`, attached in
/// `wezig_android_shell_start`). The seam is single-sink, so installing the C
/// observer would otherwise SILENCE that subscriber. We capture it here and
/// FAN OUT to it from `onCObserverEvent`, so a native observer (the instrumented
/// `ShellSeamTest`) can watch the seam WITHOUT displacing the app's chrome — the
/// URL field / nav buttons keep reflecting lifecycle events while the test also
/// observes them. Null when nothing was subscribed first (the bare-controller
/// proofs `RendererSeamTest`/`EmbeddingProofTest`, which have no chrome).
var prior_lifecycle_cb: ?seam.LifecycleCallback = null;

fn onCObserverEvent(ctx: *anyopaque, event: seam.LifecycleEvent) void {
    _ = ctx;
    // Fan out to the pre-existing subscriber (the app's chrome) FIRST, so the
    // C observer is ADDITIVE, not a replacement (see `prior_lifecycle_cb`).
    if (prior_lifecycle_cb) |cb| cb.onEvent(cb.ctx, event);
    const obs = c_observer orelse return;
    switch (event) {
        .load_changed => |lc| {
            const code: c_int = switch (lc.state) {
                .started => @intFromEnum(AndroidLoadEvent.page_started),
                .committed => @intFromEnum(AndroidLoadEvent.page_committed),
                .finished => @intFromEnum(AndroidLoadEvent.page_finished),
                .failed => @intFromEnum(AndroidLoadEvent.page_failed),
            };
            var buf: [2048]u8 = undefined;
            const uri_z: ?[*:0]const u8 = if (lc.uri) |u| blk: {
                if (u.len >= buf.len) break :blk null;
                @memcpy(buf[0..u.len], u);
                buf[u.len] = 0;
                break :blk @ptrCast(&buf);
            } else null;
            obs.onLoadState(obs.ctx, code, uri_z);
        },
        .title_changed => |title| {
            var buf: [512]u8 = undefined;
            if (title.len >= buf.len) return;
            @memcpy(buf[0..title.len], title);
            buf[title.len] = 0;
            obs.onTitle(obs.ctx, @ptrCast(&buf));
        },
        else => {},
    }
}

/// C-ABI: install a C lifecycle observer as the seam's callback sink, so a
/// native caller (the instrumented test) receives the REAL seam `.load_changed`
/// events the WebViewClient drives — the Android analogue of the desktop
/// `shell-test` subscribing to the `Renderer` seam.
export fn wezig_android_set_lifecycle_observer(handle: ?*anyopaque, observer: *const CLifecycleObserver) void {
    const backend: *AndroidWebviewRenderer = @ptrCast(@alignCast(handle orelse return));
    c_observer = observer.*;
    // Capture whatever callback is already subscribed (the shell's MobileChrome)
    // so the C observer FANS OUT to it rather than silencing it (single-sink
    // seam). Do NOT capture our own multiplexing sink if the observer is being
    // re-installed (idempotent — avoids chaining onCObserverEvent to itself).
    if (backend.cb) |existing| {
        if (existing.onEvent != onCObserverEvent) prior_lifecycle_cb = existing;
    }
    backend.renderer().setLifecycleCallback(.{ .ctx = backend, .onEvent = onCObserverEvent });
}

/// Java -> Zig: a `WebViewClient` load-state callback (already on the UI thread).
export fn wezig_android_on_load_state(handle: ?*anyopaque, code: c_int, uri: ?[*:0]const u8) void {
    const self: *AndroidWebviewRenderer = @ptrCast(@alignCast(handle orelse return));
    self.dispatchLoadState(code, spanOrNull(uri));
}

/// Java -> Zig: the document URI changed.
export fn wezig_android_on_uri_changed(handle: ?*anyopaque, uri: ?[*:0]const u8) void {
    const self: *AndroidWebviewRenderer = @ptrCast(@alignCast(handle orelse return));
    const u = spanOrNull(uri) orelse return;
    self.dispatchUriChanged(u);
}

/// Java -> Zig: the document title changed.
export fn wezig_android_on_title_changed(handle: ?*anyopaque, title: ?[*:0]const u8) void {
    const self: *AndroidWebviewRenderer = @ptrCast(@alignCast(handle orelse return));
    const t = spanOrNull(title) orelse return;
    self.dispatchTitleChanged(t);
}

/// Java -> Zig: load progress changed (Android reports an int percent 0..100).
export fn wezig_android_on_progress(handle: ?*anyopaque, percent: c_int) void {
    const self: *AndroidWebviewRenderer = @ptrCast(@alignCast(handle orelse return));
    self.dispatchProgress(percent);
}

// ---------------------------------------------------------------------------
// The two web3 hooks: C-ABI down-call wrappers + up-call entry points + the C
// observers the instrumented test subscribes THROUGH the seam (spec stories
// 8,9). Mirrors the desktop `shell-bridge-test`/`shell-scheme-test` legs and the
// existing lifecycle-observer surface: the test drives the hooks via the seam
// (never the WebView directly) and observes the page->native / scheme-serve legs
// through these C callbacks.
// ---------------------------------------------------------------------------

/// C-ABI down-call: inject a page-world script (native->page setup leg). The
/// shim calls this on the UI thread.
export fn wezig_android_inject_user_script(handle: ?*anyopaque, source: [*:0]const u8) void {
    const backend: *AndroidWebviewRenderer = @ptrCast(@alignCast(handle orelse return));
    backend.renderer().injectUserScript(source);
}

/// C-ABI down-call: evaluate JS in the current page (native->page reply leg).
export fn wezig_android_evaluate_script(handle: ?*anyopaque, source: [*:0]const u8) void {
    const backend: *AndroidWebviewRenderer = @ptrCast(@alignCast(handle orelse return));
    backend.renderer().evaluateScript(source);
}

/// A C page->native message observer (the instrumented test subscribes THROUGH
/// this, mirroring the desktop bridge test's `onBridgeMessage`). `onMessage` is
/// a C fn pointer receiving the channel name + the message body as borrowed C
/// strings.
pub const CScriptMessageObserver = extern struct {
    ctx: ?*anyopaque,
    onMessage: *const fn (ctx: ?*anyopaque, name: ?[*:0]const u8, body: ?[*:0]const u8) callconv(.c) void,
};

/// The installed C bridge observer (the seam channel is single today).
var c_msg_observer: ?CScriptMessageObserver = null;

fn onCScriptMessage(ctx: *anyopaque, name: []const u8, body: []const u8) void {
    _ = ctx;
    const obs = c_msg_observer orelse return;
    var nbuf: [128]u8 = undefined;
    var bbuf: [2048]u8 = undefined;
    if (name.len >= nbuf.len or body.len >= bbuf.len) return;
    @memcpy(nbuf[0..name.len], name);
    nbuf[name.len] = 0;
    @memcpy(bbuf[0..body.len], body);
    bbuf[body.len] = 0;
    obs.onMessage(obs.ctx, @ptrCast(&nbuf), @ptrCast(&bbuf));
}

/// C-ABI: register the page->native channel `name` THROUGH the seam and install
/// a C observer as the seam's `ScriptMessageCallback` sink, so a native caller
/// (the instrumented test) receives the REAL page->native messages. Mirrors
/// `wezig_android_set_lifecycle_observer` for the bridge hook.
export fn wezig_android_set_script_message_observer(
    handle: ?*anyopaque,
    name: [*:0]const u8,
    observer: *const CScriptMessageObserver,
) void {
    const backend: *AndroidWebviewRenderer = @ptrCast(@alignCast(handle orelse return));
    c_msg_observer = observer.*;
    backend.renderer().setScriptMessageHandler(name, .{ .ctx = backend, .onMessage = onCScriptMessage });
}

/// Java -> Zig: a page-world post arrived on channel `name` with `body` (the
/// `addJavascriptInterface` object's method, already marshalled onto the UI
/// thread by the Java side). Re-enters the seam via `dispatchScriptMessage`.
export fn wezig_android_on_script_message(handle: ?*anyopaque, name: ?[*:0]const u8, body: ?[*:0]const u8) void {
    const self: *AndroidWebviewRenderer = @ptrCast(@alignCast(handle orelse return));
    const n = spanOrNull(name) orelse return;
    const b = spanOrNull(body) orelse "";
    self.dispatchScriptMessage(n, b);
}

/// A C custom-scheme observer (the instrumented test subscribes THROUGH this,
/// mirroring the desktop scheme test's `onSchemeRequest`). `onRequest` serves a
/// request URI by writing the native body + content-type into the out-params
/// and returning true, or false if it declines. Runs on the binder thread (the
/// module doc's thread contract) — must be thread-safe.
pub const CSchemeObserver = extern struct {
    ctx: ?*anyopaque,
    onRequest: *const fn (
        ctx: ?*anyopaque,
        uri: ?[*:0]const u8,
        out_body: *[*]const u8,
        out_body_len: *usize,
        out_content_type: *[*:0]const u8,
    ) callconv(.c) bool,
};

var c_scheme_observer: ?CSchemeObserver = null;
/// Storage for the last served response so its bytes outlive the seam callback
/// (the C observer's out-params borrow into the observer's own storage; we hold
/// the response the seam handler returns so the up-call can hand it to Java).
var c_scheme_last: ?seam.SchemeResponse = null;

fn onCSchemeRequest(ctx: *anyopaque, uri: []const u8) seam.SchemeResponse {
    _ = ctx;
    const obs = c_scheme_observer orelse return .{ .body = "", .content_type = "text/plain" };
    var nbuf: [2048]u8 = undefined;
    const uri_z: [*:0]const u8 = blk: {
        if (uri.len >= nbuf.len) break :blk "";
        @memcpy(nbuf[0..uri.len], uri);
        nbuf[uri.len] = 0;
        break :blk @ptrCast(&nbuf);
    };
    var body_ptr: [*]const u8 = undefined;
    var body_len: usize = 0;
    var ct: [*:0]const u8 = undefined;
    if (!obs.onRequest(obs.ctx, uri_z, &body_ptr, &body_len, &ct)) {
        return .{ .body = "", .content_type = "text/plain" };
    }
    return .{ .body = body_ptr[0..body_len], .content_type = std.mem.span(ct) };
}

/// C-ABI: register the custom scheme `scheme` THROUGH the seam and install a C
/// observer as the seam's `SchemeHandler`, so a native caller (the instrumented
/// test) serves the REAL scheme requests. Mirrors
/// `wezig_android_set_lifecycle_observer` for the scheme hook.
export fn wezig_android_register_scheme_observer(
    handle: ?*anyopaque,
    scheme: [*:0]const u8,
    observer: *const CSchemeObserver,
) void {
    const backend: *AndroidWebviewRenderer = @ptrCast(@alignCast(handle orelse return));
    c_scheme_observer = observer.*;
    backend.renderer().registerScheme(scheme, .{ .ctx = backend, .onRequest = onCSchemeRequest });
}

/// Java -> Zig: `shouldInterceptRequest` asks native to serve `uri` on the
/// registered custom scheme. Writes the served body + length + content-type into
/// the out-params (borrowed until the next serve, per the seam contract) and
/// returns true, or false if no scheme handler is registered (Java returns null
/// so the WebView falls through). NOTE: runs on the binder thread — the one seam
/// callback not UI-thread serialized (the module doc's thread contract).
export fn wezig_android_serve_scheme(
    handle: ?*anyopaque,
    uri: ?[*:0]const u8,
    out_body: *[*]const u8,
    out_body_len: *usize,
    out_content_type: *[*:0]const u8,
) bool {
    const self: *AndroidWebviewRenderer = @ptrCast(@alignCast(handle orelse return false));
    const u = spanOrNull(uri) orelse return false;
    const resp = self.serveSchemeRequest(u) orelse return false;
    c_scheme_last = resp;
    out_body.* = resp.body.ptr;
    out_body_len.* = resp.body.len;
    // Copy the content-type NUL-terminated (the seam's `content_type` is
    // `[]const u8`, not sentinel-terminated) so Java always reads a valid C
    // string. Single serve at a time; borrowed until the next serve.
    const ct = std.fmt.bufPrintZ(&scheme_ct_buf, "{s}", .{resp.content_type}) catch "text/plain";
    out_content_type.* = @ptrCast(ct.ptr);
    return true;
}

/// NUL-terminating buffer for the last served content-type (see above).
var scheme_ct_buf: [128]u8 = undefined;

// Force the JNI `export fn`s to be analysed/emitted in a non-test static-lib
// build (same GC-retention issue + fix as `mobile_abi` in `root.zig`).
comptime {
    _ = &wezig_android_on_load_state;
    _ = &wezig_android_on_uri_changed;
    _ = &wezig_android_on_title_changed;
    _ = &wezig_android_on_progress;
    _ = &wezig_android_renderer_init;
    _ = &wezig_android_renderer_deinit;
    _ = &wezig_android_navigate;
    _ = &wezig_android_renderer_view;
    _ = &wezig_android_set_lifecycle_observer;
    _ = &wezig_android_inject_user_script;
    _ = &wezig_android_evaluate_script;
    _ = &wezig_android_set_script_message_observer;
    _ = &wezig_android_on_script_message;
    _ = &wezig_android_register_scheme_observer;
    _ = &wezig_android_serve_scheme;
}

// ---------------------------------------------------------------------------
// Headless seam-contract tests (run in `zig build test`; no JNI, no emulator).
// A fake `JavaBridge` records the down-calls, and the up-call dispatch is driven
// directly, so the whole Android backend's seam wiring is proven on the host.
// The REAL end-to-end proof (a WebView renders one page on an x86_64 emulator)
// is the Android instrumented test run by `mobile-verification-legs-ci`.
// ---------------------------------------------------------------------------

/// A fake Java side for the tests: records the last down-call and hands back a
/// stable opaque view token, so the backend is drivable with no JVM.
const FakeJava = struct {
    last_navigated: ?[]const u8 = null,
    reloaded: bool = false,
    stopped: bool = false,
    went_back: bool = false,
    went_forward: bool = false,
    back_ok: bool = false,
    forward_ok: bool = false,
    last_viewport: ?[2]c_int = null,
    view_token: u8 = 0,

    // --- JNI global-ref lifecycle model (ADR-0009 hazard; the leak counter) ---
    /// How many times the `view` op minted a global-ref (the real shim's
    /// `NewGlobalRef`). The backend caches, so a correct backend calls it ONCE
    /// per view no matter how many `view()` seam calls happen.
    view_mints: usize = 0,
    /// Live global-refs = mints minus deletes. Must be exactly 1 while the view
    /// is held and 0 after teardown (the leak-count assertion).
    live_view_refs: usize = 0,
    /// Set once the bridge's `teardown` op ran (the shim's native ctx freed).
    torn_down: bool = false,

    // --- web3-hook down-call state (what the Java bridge installs) ---
    injected: ?[]const u8 = null,
    /// How many times the `injectUserScript` op fired (initial inject + each
    /// document-start re-injection on `.started`).
    inject_count: usize = 0,
    last_evaluated: ?[]const u8 = null,
    msg_channel: ?[]const u8 = null,
    registered_scheme: ?[]const u8 = null,

    fn bridge(self: *FakeJava) JavaBridge {
        return .{
            .ctx = self,
            .navigate = navigate,
            .reload = reload,
            .stop = stop,
            .goBack = goBack,
            .goForward = goForward,
            .canGoBack = canGoBack,
            .canGoForward = canGoForward,
            .view = view,
            .deleteView = deleteView,
            .setViewportSize = setViewportSize,
            .injectUserScript = injectUserScript,
            .setScriptMessageHandler = setScriptMessageHandler,
            .evaluateScript = evaluateScript,
            .registerScheme = registerScheme,
            .teardown = teardown,
        };
    }
    fn injectUserScript(ctx: *anyopaque, source: [*:0]const u8) void {
        const self: *FakeJava = @ptrCast(@alignCast(ctx));
        self.injected = std.mem.span(source);
        self.inject_count += 1;
    }
    fn setScriptMessageHandler(ctx: *anyopaque, name: [*:0]const u8) void {
        const self: *FakeJava = @ptrCast(@alignCast(ctx));
        self.msg_channel = std.mem.span(name);
    }
    fn evaluateScript(ctx: *anyopaque, source: [*:0]const u8) void {
        const self: *FakeJava = @ptrCast(@alignCast(ctx));
        self.last_evaluated = std.mem.span(source);
    }
    fn registerScheme(ctx: *anyopaque, scheme: [*:0]const u8) void {
        const self: *FakeJava = @ptrCast(@alignCast(ctx));
        self.registered_scheme = std.mem.span(scheme);
    }
    fn navigate(ctx: *anyopaque, uri: [*:0]const u8) void {
        const self: *FakeJava = @ptrCast(@alignCast(ctx));
        self.last_navigated = std.mem.span(uri);
    }
    fn reload(ctx: *anyopaque) void {
        const self: *FakeJava = @ptrCast(@alignCast(ctx));
        self.reloaded = true;
    }
    fn stop(ctx: *anyopaque) void {
        const self: *FakeJava = @ptrCast(@alignCast(ctx));
        self.stopped = true;
    }
    fn goBack(ctx: *anyopaque) void {
        const self: *FakeJava = @ptrCast(@alignCast(ctx));
        self.went_back = true;
    }
    fn goForward(ctx: *anyopaque) void {
        const self: *FakeJava = @ptrCast(@alignCast(ctx));
        self.went_forward = true;
    }
    fn canGoBack(ctx: *anyopaque) bool {
        const self: *FakeJava = @ptrCast(@alignCast(ctx));
        return self.back_ok;
    }
    fn canGoForward(ctx: *anyopaque) bool {
        const self: *FakeJava = @ptrCast(@alignCast(ctx));
        return self.forward_ok;
    }
    fn view(ctx: *anyopaque) seam.ViewHandle {
        const self: *FakeJava = @ptrCast(@alignCast(ctx));
        // Model the shim's `NewGlobalRef`: each call mints a fresh live ref.
        self.view_mints += 1;
        self.live_view_refs += 1;
        return &self.view_token;
    }
    fn deleteView(ctx: *anyopaque, v: seam.ViewHandle) void {
        const self: *FakeJava = @ptrCast(@alignCast(ctx));
        // Model the shim's `DeleteGlobalRef`: the deleted ref is the one minted
        // for this view (the backend hands back exactly the cached handle).
        std.debug.assert(v == @as(seam.ViewHandle, &self.view_token));
        self.live_view_refs -= 1;
    }
    fn setViewportSize(ctx: *anyopaque, width: c_int, height: c_int) void {
        const self: *FakeJava = @ptrCast(@alignCast(ctx));
        self.last_viewport = .{ width, height };
    }
    fn teardown(ctx: *anyopaque) void {
        const self: *FakeJava = @ptrCast(@alignCast(ctx));
        self.torn_down = true;
    }
};

test "mapLoadState maps every WebViewClient code onto the seam LoadState" {
    try std.testing.expectEqual(seam.LoadState.started, mapLoadState(0).?);
    try std.testing.expectEqual(seam.LoadState.committed, mapLoadState(1).?);
    try std.testing.expectEqual(seam.LoadState.finished, mapLoadState(2).?);
    try std.testing.expectEqual(seam.LoadState.failed, mapLoadState(3).?);
    // An unrecognised code is dropped, not mis-mapped.
    try std.testing.expectEqual(@as(?seam.LoadState, null), mapLoadState(99));
}

test "AndroidWebviewRenderer: navigation down-calls reach the Java bridge" {
    var java = FakeJava{ .back_ok = true };
    var backend = AndroidWebviewRenderer.init(java.bridge());
    const r = backend.renderer();

    r.navigate("https://page.example/");
    try std.testing.expectEqualStrings("https://page.example/", java.last_navigated.?);

    r.reload();
    try std.testing.expect(java.reloaded);
    r.stop();
    try std.testing.expect(java.stopped);
    r.goBack();
    try std.testing.expect(java.went_back);
    r.goForward();
    try std.testing.expect(java.went_forward);

    // can-go queries forward through the bridge to the WebView's history.
    try std.testing.expect(r.canGoBack());
    try std.testing.expect(!r.canGoForward());

    // The opaque view handle is the Java WebView's ref, passed through unchanged.
    try std.testing.expectEqual(@as(seam.ViewHandle, @ptrCast(&java.view_token)), r.view());

    r.setViewportSize(360, 640);
    try std.testing.expectEqual([2]c_int{ 360, 640 }, java.last_viewport.?);
}

test "AndroidWebviewRenderer: a navigation drives a .finished event to a subscriber" {
    // The acceptance heart, mirrored on the desktop `shell-test` assertion:
    // driving one navigation must deliver a `.finished` LifecycleEvent to the
    // subscribed callback, with the WebViewClient's (UI-thread-marshalled)
    // up-call correctly mapped to the seam.
    const Sink = struct {
        started: usize = 0,
        finished: usize = 0,
        last_uri: [64]u8 = undefined,
        last_uri_len: usize = 0,
        fn onEvent(ctx: *anyopaque, event: seam.LifecycleEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (event) {
                .load_changed => |lc| switch (lc.state) {
                    .started => self.started += 1,
                    .finished => {
                        self.finished += 1;
                        if (lc.uri) |u| {
                            @memcpy(self.last_uri[0..u.len], u);
                            self.last_uri_len = u.len;
                        }
                    },
                    else => {},
                },
                else => {},
            }
        }
    };

    var java = FakeJava{};
    var backend = AndroidWebviewRenderer.init(java.bridge());
    const r = backend.renderer();

    var sink = Sink{};
    r.setLifecycleCallback(.{ .ctx = &sink, .onEvent = Sink.onEvent });

    // Navigate down into the (fake) WebView, then simulate the Java
    // WebViewClient's callbacks arriving back up through the JNI entry points.
    r.navigate("https://page.example/");
    const uri: [*:0]const u8 = "https://page.example/";
    wezig_android_on_load_state(&backend, @intFromEnum(AndroidLoadEvent.page_started), uri);
    wezig_android_on_load_state(&backend, @intFromEnum(AndroidLoadEvent.page_committed), uri);
    wezig_android_on_load_state(&backend, @intFromEnum(AndroidLoadEvent.page_finished), uri);

    try std.testing.expectEqual(@as(usize, 1), sink.started);
    try std.testing.expectEqual(@as(usize, 1), sink.finished);
    try std.testing.expectEqualStrings("https://page.example/", sink.last_uri[0..sink.last_uri_len]);
}

test "AndroidWebviewRenderer: title/uri/progress up-calls reach the seam" {
    const Sink = struct {
        title: [32]u8 = undefined,
        title_len: usize = 0,
        uri: [64]u8 = undefined,
        uri_len: usize = 0,
        progress: f64 = -1,
        fn onEvent(ctx: *anyopaque, event: seam.LifecycleEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (event) {
                .title_changed => |t| {
                    @memcpy(self.title[0..t.len], t);
                    self.title_len = t.len;
                },
                .uri_changed => |u| {
                    @memcpy(self.uri[0..u.len], u);
                    self.uri_len = u.len;
                },
                .progress_changed => |p| self.progress = p,
                else => {},
            }
        }
    };

    var java = FakeJava{};
    var backend = AndroidWebviewRenderer.init(java.bridge());
    const r = backend.renderer();
    var sink = Sink{};
    r.setLifecycleCallback(.{ .ctx = &sink, .onEvent = Sink.onEvent });

    wezig_android_on_title_changed(&backend, "wezig android shell");
    wezig_android_on_uri_changed(&backend, "https://redirected.example/");
    wezig_android_on_progress(&backend, 100);

    try std.testing.expectEqualStrings("wezig android shell", sink.title[0..sink.title_len]);
    try std.testing.expectEqualStrings("https://redirected.example/", sink.uri[0..sink.uri_len]);
    try std.testing.expectEqual(@as(f64, 1.0), sink.progress);
}

test "AndroidWebviewRenderer: the script-message bridge round-trips a message both ways" {
    // The Android twin of the desktop `shell-bridge-test`, proven headlessly at
    // the seam-contract level (no JNI, no emulator): the native->page setup leg
    // injects `window.wezig` (reaches the Java bridge); `setScriptMessageHandler`
    // installs the `addJavascriptInterface` channel; the page->native leg posts a
    // value that reaches native via `dispatchScriptMessage` (what the marshalled
    // JS-interface up-call does); the native->page reply leg evaluates JS back.
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

    var java = FakeJava{};
    var backend = AndroidWebviewRenderer.init(java.bridge());
    const r = backend.renderer();

    r.injectUserScript("window.wezig = { ping: function(v){ wezigNative.postMessage(v); } };");
    try std.testing.expect(java.injected != null);

    var native = Native{};
    r.setScriptMessageHandler("wezig", .{ .ctx = &native, .onMessage = Native.onMessage });
    try std.testing.expectEqualStrings("wezig", java.msg_channel.?);

    // page->native: the (UI-thread-marshalled) JS-interface up-call delivers.
    backend.dispatchScriptMessage("wezig", "ping-from-page");
    try std.testing.expectEqualStrings("wezig", native.got_name[0..native.got_name_len]);
    try std.testing.expectEqualStrings("ping-from-page", native.got_body[0..native.got_body_len]);

    // native->page reply leg reaches the Java bridge's evaluateJavascript.
    r.evaluateScript("window.wezig.ping('pong-from-native');");
    try std.testing.expectEqualStrings("window.wezig.ping('pong-from-native');", java.last_evaluated.?);
}

test "AndroidWebviewRenderer: a registered custom scheme is served from native" {
    // The Android twin of the desktop `shell-scheme-test`: `registerScheme`
    // records the seam handler AND reaches the Java bridge (which wires
    // `shouldInterceptRequest`); a request re-enters via `serveSchemeRequest`
    // (the binder-thread up-call) and is served the native body + content-type.
    const Native = struct {
        fn onRequest(ctx: *anyopaque, uri: []const u8) seam.SchemeResponse {
            _ = ctx;
            _ = uri;
            return .{ .body = "<h1>hello from native</h1>", .content_type = "text/html" };
        }
    };

    var java = FakeJava{};
    var backend = AndroidWebviewRenderer.init(java.bridge());
    const r = backend.renderer();

    var native: u8 = 0;
    r.registerScheme("wezig-test", .{ .ctx = &native, .onRequest = Native.onRequest });
    try std.testing.expectEqualStrings("wezig-test", java.registered_scheme.?);

    const resp = backend.serveSchemeRequest("wezig-test://hello").?;
    try std.testing.expectEqualStrings("<h1>hello from native</h1>", resp.body);
    try std.testing.expectEqualStrings("text/html", resp.content_type);

    // Before registration a scheme request has no handler (Java returns null).
    var bare_java = FakeJava{};
    var bare = AndroidWebviewRenderer.init(bare_java.bridge());
    try std.testing.expectEqual(@as(?seam.SchemeResponse, null), bare.serveSchemeRequest("wezig-test://x"));
}

test "AndroidWebviewRenderer: one injectUserScript re-injects on every .started (document-start seam-uniform)" {
    // Resolved decision 2 / ADR-0009 §3: Android's WebView has no
    // `WKUserScript(.atDocumentStart)` equivalent, so ONE caller-side
    // `injectUserScript` must give document-start semantics on EVERY page. Prove
    // it at the seam-contract level: inject once, then drive N page starts and
    // assert the injection op fired on EACH — so the caller (and a future
    // `WezigRenderer`) sees the SAME document-start contract as iOS/WebKitGTK.
    var java = FakeJava{};
    var backend = AndroidWebviewRenderer.init(java.bridge());
    const r = backend.renderer();

    const marker = "window.wezig = { marker: true };";
    r.injectUserScript(marker);
    // The initial injection fired exactly once and reached the bridge.
    try std.testing.expectEqual(@as(usize, 1), java.inject_count);
    try std.testing.expectEqualStrings(marker, java.injected.?);

    // Drive N document starts (the WebViewClient's onPageStarted -> `.started`,
    // marshalled up through the JNI load-state entry point). Each must re-issue
    // the remembered source through the bridge's injectUserScript op.
    const N: usize = 5;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        wezig_android_on_load_state(&backend, @intFromEnum(AndroidLoadEvent.page_started), "https://page.example/");
        // A committed/finished in the SAME page must NOT re-inject (only starts do).
        wezig_android_on_load_state(&backend, @intFromEnum(AndroidLoadEvent.page_committed), "https://page.example/");
        wezig_android_on_load_state(&backend, @intFromEnum(AndroidLoadEvent.page_finished), "https://page.example/");
    }

    // Initial inject (1) + one re-injection per `.started` (N).
    try std.testing.expectEqual(@as(usize, 1 + N), java.inject_count);
    // The last re-issued source is still the remembered one (unchanged).
    try std.testing.expectEqualStrings(marker, java.injected.?);

    // A backend with NO prior injectUserScript re-injects nothing on `.started`.
    var bare_java = FakeJava{};
    var bare = AndroidWebviewRenderer.init(bare_java.bridge());
    wezig_android_on_load_state(&bare, @intFromEnum(AndroidLoadEvent.page_started), "https://x.example/");
    try std.testing.expectEqual(@as(usize, 0), bare_java.inject_count);
}

test "AndroidWebviewRenderer: exactly one JNI global-ref per view, zero after teardown (ADR-0009 leak fix)" {
    // Story 8 / ADR-0009 §Consequences: `view()` must mint the JNI global-ref
    // LAZILY and cache it (one live ref per view, returned unchanged across
    // calls) instead of leaking a fresh ref per call; teardown deletes it and
    // frees the bridge's native ctx, so ZERO refs remain. Proven headlessly via
    // the fake bridge's ref counter.
    var java = FakeJava{};
    var backend = AndroidWebviewRenderer.init(java.bridge());
    const r = backend.renderer();

    // No ref is minted until the first `view()` (lazy).
    try std.testing.expectEqual(@as(usize, 0), java.view_mints);
    try std.testing.expectEqual(@as(usize, 0), java.live_view_refs);

    // Repeated `view()` calls mint the ref ONCE and hand back the SAME handle.
    const h1 = r.view();
    const h2 = r.view();
    const h3 = r.view();
    try std.testing.expectEqual(h1, h2);
    try std.testing.expectEqual(h2, h3);
    try std.testing.expectEqual(@as(usize, 1), java.view_mints);
    try std.testing.expectEqual(@as(usize, 1), java.live_view_refs);

    // Teardown deletes the one cached ref (net zero) and frees the native ctx.
    backend.deinit();
    try std.testing.expectEqual(@as(usize, 0), java.live_view_refs);
    try std.testing.expect(java.torn_down);

    // Teardown WITHOUT ever taking the view mints/deletes nothing but still
    // tears the native ctx down (no dangling native per-renderer state).
    var java2 = FakeJava{};
    var backend2 = AndroidWebviewRenderer.init(java2.bridge());
    backend2.deinit();
    try std.testing.expectEqual(@as(usize, 0), java2.view_mints);
    try std.testing.expectEqual(@as(usize, 0), java2.live_view_refs);
    try std.testing.expect(java2.torn_down);
}

test "C-ABI renderer teardown deletes the one cached view ref + frees the ctx (as the JNI shim would)" {
    // Exercise the EXACT C-ABI teardown surface the JNI shim uses: construct via
    // `wezig_android_renderer_init`, take the view a few times (one mint), then
    // `wezig_android_renderer_deinit` must delete that one ref and free the ctx.
    const CJava = struct {
        var token: u8 = 0;
        var mints: usize = 0;
        var live: usize = 0;
        var torn_down: bool = false;
        fn noop(_: ?*anyopaque) callconv(.c) void {}
        fn no(_: ?*anyopaque) callconv(.c) bool {
            return false;
        }
        fn nav(_: ?*anyopaque, _: [*:0]const u8) callconv(.c) void {}
        fn view(_: ?*anyopaque) callconv(.c) ?*anyopaque {
            mints += 1;
            live += 1;
            return &token;
        }
        fn deleteView(_: ?*anyopaque, v: ?*anyopaque) callconv(.c) void {
            std.debug.assert(v == @as(?*anyopaque, &token));
            live -= 1;
        }
        fn viewport(_: ?*anyopaque, _: c_int, _: c_int) callconv(.c) void {}
        fn source(_: ?*anyopaque, _: [*:0]const u8) callconv(.c) void {}
        fn teardown(_: ?*anyopaque) callconv(.c) void {
            torn_down = true;
        }
    };
    CJava.mints = 0;
    CJava.live = 0;
    CJava.torn_down = false;

    const cbridge = CJavaBridge{
        .ctx = null,
        .navigate = CJava.nav,
        .reload = CJava.noop,
        .stop = CJava.noop,
        .goBack = CJava.noop,
        .goForward = CJava.noop,
        .canGoBack = CJava.no,
        .canGoForward = CJava.no,
        .view = CJava.view,
        .deleteView = CJava.deleteView,
        .setViewportSize = CJava.viewport,
        .injectUserScript = CJava.source,
        .setScriptMessageHandler = CJava.source,
        .evaluateScript = CJava.source,
        .registerScheme = CJava.source,
        .teardown = CJava.teardown,
    };
    const handle = wezig_android_renderer_init(&cbridge).?;
    const backend: *AndroidWebviewRenderer = @ptrCast(@alignCast(handle));

    // Take the view via BOTH the seam and the embedding C accessor; still ONE mint.
    _ = backend.renderer().view();
    _ = wezig_android_renderer_view(handle);
    try std.testing.expectEqual(@as(usize, 1), CJava.mints);
    try std.testing.expectEqual(@as(usize, 1), CJava.live);

    wezig_android_renderer_deinit(handle);
    try std.testing.expectEqual(@as(usize, 0), CJava.live);
    try std.testing.expect(CJava.torn_down);
}

test "C bridge + scheme observers receive the real seam legs (as the JNI shim would)" {
    // Exercise the EXACT C-ABI surface the JNI shim/instrumented test uses for
    // the two hooks: a C bridge observer receives the page->native post; a C
    // scheme observer serves the request through the seam.
    const CBridge = struct {
        var name_buf: [32]u8 = undefined;
        var name_len: usize = 0;
        var body_buf: [32]u8 = undefined;
        var body_len: usize = 0;
        fn onMessage(_: ?*anyopaque, name: ?[*:0]const u8, body: ?[*:0]const u8) callconv(.c) void {
            const n = std.mem.span(name.?);
            const b = std.mem.span(body.?);
            @memcpy(name_buf[0..n.len], n);
            name_len = n.len;
            @memcpy(body_buf[0..b.len], b);
            body_len = b.len;
        }
    };
    const CScheme = struct {
        fn onRequest(
            _: ?*anyopaque,
            _: ?[*:0]const u8,
            out_body: *[*]const u8,
            out_body_len: *usize,
            out_ct: *[*:0]const u8,
        ) callconv(.c) bool {
            const body = "<title>WEZIG-SCHEME-OK</title>";
            out_body.* = body.ptr;
            out_body_len.* = body.len;
            out_ct.* = "text/html";
            return true;
        }
    };
    CBridge.name_len = 0;
    CBridge.body_len = 0;

    var java = FakeJava{};
    var backend = AndroidWebviewRenderer.init(java.bridge());
    const handle: *anyopaque = &backend;

    // Bridge: register the channel + a C observer, then simulate the page post.
    const msg_obs = CScriptMessageObserver{ .ctx = null, .onMessage = CBridge.onMessage };
    wezig_android_set_script_message_observer(handle, "wezig", &msg_obs);
    defer c_msg_observer = null;
    try std.testing.expectEqualStrings("wezig", java.msg_channel.?);
    wezig_android_on_script_message(handle, "wezig", "ping-from-page");
    try std.testing.expectEqualStrings("wezig", CBridge.name_buf[0..CBridge.name_len]);
    try std.testing.expectEqualStrings("ping-from-page", CBridge.body_buf[0..CBridge.body_len]);

    // Scheme: register the scheme + a C observer, then simulate the intercept.
    const scheme_obs = CSchemeObserver{ .ctx = null, .onRequest = CScheme.onRequest };
    wezig_android_register_scheme_observer(handle, "wezig-test", &scheme_obs);
    defer c_scheme_observer = null;
    try std.testing.expectEqualStrings("wezig-test", java.registered_scheme.?);

    var body_ptr: [*]const u8 = undefined;
    var body_len: usize = 0;
    var ct: [*:0]const u8 = undefined;
    try std.testing.expect(wezig_android_serve_scheme(handle, "wezig-test://hello", &body_ptr, &body_len, &ct));
    try std.testing.expectEqualStrings("<title>WEZIG-SCHEME-OK</title>", body_ptr[0..body_len]);
    try std.testing.expectEqualStrings("text/html", std.mem.span(ct));

    // An unregistered handle serving a scheme returns false (WebView falls through).
    var bare_java = FakeJava{};
    var bare = AndroidWebviewRenderer.init(bare_java.bridge());
    try std.testing.expect(!wezig_android_serve_scheme(&bare, "wezig-test://x", &body_ptr, &body_len, &ct));
}

test "C-ABI construction path drives navigate + finished event (as the JNI shim would)" {
    // Exercise the EXACT surface the JNI shim uses: build a C fn-pointer bridge,
    // construct the renderer via `wezig_android_renderer_init`, drive a navigate
    // down-call, and simulate the WebViewClient up-call — all through the C ABI.
    const CJava = struct {
        var navigated: [64]u8 = undefined;
        var navigated_len: usize = 0;
        var token: u8 = 0;
        fn navigate(_: ?*anyopaque, uri: [*:0]const u8) callconv(.c) void {
            const s = std.mem.span(uri);
            @memcpy(navigated[0..s.len], s);
            navigated_len = s.len;
        }
        fn noop(_: ?*anyopaque) callconv(.c) void {}
        fn no(_: ?*anyopaque) callconv(.c) bool {
            return false;
        }
        fn view(_: ?*anyopaque) callconv(.c) ?*anyopaque {
            return &token;
        }
        fn deleteView(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {}
        fn viewport(_: ?*anyopaque, _: c_int, _: c_int) callconv(.c) void {}
        fn source(_: ?*anyopaque, _: [*:0]const u8) callconv(.c) void {}
    };
    CJava.navigated_len = 0;

    const cbridge = CJavaBridge{
        .ctx = null,
        .navigate = CJava.navigate,
        .reload = CJava.noop,
        .stop = CJava.noop,
        .goBack = CJava.noop,
        .goForward = CJava.noop,
        .canGoBack = CJava.no,
        .canGoForward = CJava.no,
        .view = CJava.view,
        .deleteView = CJava.deleteView,
        .setViewportSize = CJava.viewport,
        .injectUserScript = CJava.source,
        .setScriptMessageHandler = CJava.source,
        .evaluateScript = CJava.source,
        .registerScheme = CJava.source,
        .teardown = CJava.noop,
    };
    const handle = wezig_android_renderer_init(&cbridge).?;
    defer wezig_android_renderer_deinit(handle);

    // Subscribe a sink through the seam value the backend exposes.
    const backend: *AndroidWebviewRenderer = @ptrCast(@alignCast(handle));
    const Sink = struct {
        finished: bool = false,
        fn onEvent(ctx: *anyopaque, event: seam.LifecycleEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (event == .load_changed and event.load_changed.state == .finished) self.finished = true;
        }
    };
    var sink = Sink{};
    backend.renderer().setLifecycleCallback(.{ .ctx = &sink, .onEvent = Sink.onEvent });

    // Down-call through the C ABI reaches the Java (fake) navigate.
    wezig_android_navigate(handle, "https://c-abi.example/");
    try std.testing.expectEqualStrings("https://c-abi.example/", CJava.navigated[0..CJava.navigated_len]);

    // The view handle is the fake WebView token, carried opaquely.
    try std.testing.expectEqual(@as(seam.ViewHandle, @ptrCast(&CJava.token)), backend.renderer().view());

    // The embedding proof obtains the SAME opaque handle via the C-ABI accessor
    // (a JNI global-ref on the real emulator) — the bits it hands to
    // `wezig_android_embed_view` across the chrome-surface seam.
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&CJava.token)), wezig_android_renderer_view(handle));

    // Up-call: the WebViewClient's finished callback reaches the seam.
    wezig_android_on_load_state(handle, @intFromEnum(AndroidLoadEvent.page_finished), "https://c-abi.example/");
    try std.testing.expect(sink.finished);
}

test "C lifecycle observer receives the real seam .finished event" {
    // Mirrors the desktop shell-test's sink: a C observer (stand-in for the Java
    // instrumented test) subscribes THROUGH the seam and must see `.finished`
    // when the WebViewClient's finished callback drives the up-call.
    const CObs = struct {
        var finished_code: c_int = -1;
        var finished_uri: [128]u8 = undefined;
        var finished_uri_len: usize = 0;
        var last_title: [64]u8 = undefined;
        var last_title_len: usize = 0;
        fn onLoadState(_: ?*anyopaque, code: c_int, uri: ?[*:0]const u8) callconv(.c) void {
            if (code == @intFromEnum(AndroidLoadEvent.page_finished)) {
                finished_code = code;
                if (uri) |u| {
                    const s = std.mem.span(u);
                    @memcpy(finished_uri[0..s.len], s);
                    finished_uri_len = s.len;
                }
            }
        }
        fn onTitle(_: ?*anyopaque, title: ?[*:0]const u8) callconv(.c) void {
            if (title) |t| {
                const s = std.mem.span(t);
                @memcpy(last_title[0..s.len], s);
                last_title_len = s.len;
            }
        }
    };
    CObs.finished_code = -1;
    CObs.finished_uri_len = 0;
    CObs.last_title_len = 0;

    var java = FakeJava{};
    var backend = AndroidWebviewRenderer.init(java.bridge());
    const observer = CLifecycleObserver{ .ctx = null, .onLoadState = CObs.onLoadState, .onTitle = CObs.onTitle };
    wezig_android_set_lifecycle_observer(&backend, &observer);
    defer {
        c_observer = null;
        prior_lifecycle_cb = null;
    }

    wezig_android_on_load_state(&backend, @intFromEnum(AndroidLoadEvent.page_started), "https://obs.example/");
    wezig_android_on_load_state(&backend, @intFromEnum(AndroidLoadEvent.page_finished), "https://obs.example/");

    // The title also reaches the C observer (the scheme proof's render check).
    wezig_android_on_title_changed(&backend, "WEZIG-SCHEME-OK");
    try std.testing.expectEqual(@intFromEnum(AndroidLoadEvent.page_finished), CObs.finished_code);
    try std.testing.expectEqualStrings("https://obs.example/", CObs.finished_uri[0..CObs.finished_uri_len]);
    try std.testing.expectEqualStrings("WEZIG-SCHEME-OK", CObs.last_title[0..CObs.last_title_len]);
}

test "C lifecycle observer is ADDITIVE: it does not silence a pre-existing seam subscriber" {
    // The `ShellSeamTest` scenario at the seam level: the shell's chrome
    // subscribes to the seam FIRST (the app wiring), then the instrumented test
    // installs a C observer to watch `.finished`. Installing the C observer must
    // NOT displace the chrome's subscription (the single-sink seam would
    // otherwise silence it, leaving the URL field empty). Prove BOTH the prior
    // subscriber AND the C observer receive the `.finished` event.
    const Prior = struct {
        var finished: usize = 0;
        var last_uri: [128]u8 = undefined;
        var last_uri_len: usize = 0;
        fn onEvent(_: *anyopaque, event: seam.LifecycleEvent) void {
            switch (event) {
                .load_changed => |lc| if (lc.state == .finished) {
                    finished += 1;
                    if (lc.uri) |u| {
                        @memcpy(last_uri[0..u.len], u);
                        last_uri_len = u.len;
                    }
                },
                else => {},
            }
        }
    };
    Prior.finished = 0;
    Prior.last_uri_len = 0;
    const CObs = struct {
        var finished: usize = 0;
        fn onLoadState(_: ?*anyopaque, code: c_int, _: ?[*:0]const u8) callconv(.c) void {
            if (code == @intFromEnum(AndroidLoadEvent.page_finished)) finished += 1;
        }
        fn onTitle(_: ?*anyopaque, _: ?[*:0]const u8) callconv(.c) void {}
    };
    CObs.finished = 0;

    var java = FakeJava{};
    var backend = AndroidWebviewRenderer.init(java.bridge());

    // 1. The app's chrome subscribes FIRST (as `MobileChrome.attach` does).
    var prior_ctx: u8 = 0;
    backend.renderer().setLifecycleCallback(.{ .ctx = &prior_ctx, .onEvent = Prior.onEvent });

    // 2. The instrumented test installs a C observer to watch the seam.
    const observer = CLifecycleObserver{ .ctx = null, .onLoadState = CObs.onLoadState, .onTitle = CObs.onTitle };
    wezig_android_set_lifecycle_observer(&backend, &observer);
    defer {
        c_observer = null;
        prior_lifecycle_cb = null;
    }

    // 3. A load finishes: BOTH the chrome AND the C observer must see it.
    wezig_android_on_load_state(&backend, @intFromEnum(AndroidLoadEvent.page_finished), "https://shell.example/");

    try std.testing.expectEqual(@as(usize, 1), CObs.finished); // the test observer saw it
    try std.testing.expectEqual(@as(usize, 1), Prior.finished); // the chrome was NOT silenced
    try std.testing.expectEqualStrings("https://shell.example/", Prior.last_uri[0..Prior.last_uri_len]);
}

test "wezig_android_on_* entry points are null-safe (defensive JNI boundary)" {
    // A null handle or absent string must not crash the up-call — the JNI
    // boundary can legitimately pass null (no URI yet early in a load).
    wezig_android_on_load_state(null, 2, null);
    wezig_android_on_uri_changed(null, null);
    wezig_android_on_title_changed(null, null);
    wezig_android_on_progress(null, 50);
    wezig_android_on_script_message(null, null, null);
    var b: [*]const u8 = undefined;
    var bl: usize = 0;
    var ct: [*:0]const u8 = undefined;
    try std.testing.expect(!wezig_android_serve_scheme(null, null, &b, &bl, &ct));

    // A real handle with a null URI on `.finished` still emits (uri = null).
    var java = FakeJava{};
    var backend = AndroidWebviewRenderer.init(java.bridge());
    const Sink = struct {
        finished_with_null_uri: bool = false,
        fn onEvent(ctx: *anyopaque, event: seam.LifecycleEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (event == .load_changed and event.load_changed.state == .finished and event.load_changed.uri == null) {
                self.finished_with_null_uri = true;
            }
        }
    };
    var sink = Sink{};
    backend.renderer().setLifecycleCallback(.{ .ctx = &sink, .onEvent = Sink.onEvent });
    wezig_android_on_load_state(&backend, @intFromEnum(AndroidLoadEvent.page_finished), null);
    try std.testing.expect(sink.finished_with_null_uri);
}
