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
    view: *const fn (ctx: *anyopaque) seam.ViewHandle,
    setViewportSize: *const fn (ctx: *anyopaque, width: c_int, height: c_int) void,
};

/// A `Renderer` backed by one Java `android.webkit.WebView` reached over JNI.
/// Construct with `init(bridge)`, obtain the seam value with `renderer()`, and
/// hand THAT to the chrome. The chrome never sees the `WebView`; it flows to the
/// toolkit only as an opaque `ViewHandle` (a JNI global ref to the WebView).
pub const AndroidWebviewRenderer = struct {
    bridge: JavaBridge,
    cb: ?seam.LifecycleCallback = null,

    pub fn init(bridge: JavaBridge) AndroidWebviewRenderer {
        return .{ .bridge = bridge };
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
        // downcasts it back to a WebView reference.
        return self.bridge.view(self.bridge.ctx);
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
    pub fn dispatchLoadState(self: *AndroidWebviewRenderer, code: c_int, uri: ?[]const u8) void {
        const state = mapLoadState(code) orelse return;
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

    // --- the two web3 hooks (ADR-0005) ---
    // Deferred to `mobile-web3-hooks-parity` (spec stories 8,9): this task is
    // the CONTENT-seam proof (navigate + finished + non-blank), so these are
    // wired as honest no-ops that satisfy the pinned VTable without pretending
    // to implement the bridge/scheme hooks. The web3-hooks task attaches
    // `addJavascriptInterface`/`evaluateJavascript` (bridge) and
    // `shouldInterceptRequest` (scheme) through the same JavaBridge.

    fn injectUserScript(ctx: *anyopaque, source: [*:0]const u8) void {
        _ = ctx;
        _ = source;
    }
    fn setScriptMessageHandler(ctx: *anyopaque, name: [*:0]const u8, cb: seam.ScriptMessageCallback) void {
        _ = ctx;
        _ = name;
        _ = cb;
    }
    fn evaluateScript(ctx: *anyopaque, source: [*:0]const u8) void {
        _ = ctx;
        _ = source;
    }
    fn registerScheme(ctx: *anyopaque, scheme: [*:0]const u8, handler: seam.SchemeHandler) void {
        _ = ctx;
        _ = scheme;
        _ = handler;
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
    setViewportSize: *const fn (ctx: ?*anyopaque, width: c_int, height: c_int) callconv(.c) void,
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
    fn setViewportSize(ctx: *anyopaque, width: c_int, height: c_int) void {
        const self: *CBackend = @fieldParentPtr("backend", @as(*AndroidWebviewRenderer, @ptrCast(@alignCast(ctx))));
        self.cbridge.setViewportSize(self.cbridge.ctx, width, height);
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
        .setViewportSize = CBackend.setViewportSize,
    });
    // The up-call entry points receive this same handle (the `*AndroidWebviewRenderer`).
    return &cb.backend;
}

/// C-ABI destructor: free a renderer created by `wezig_android_renderer_init`.
export fn wezig_android_renderer_deinit(handle: ?*anyopaque) void {
    const backend: *AndroidWebviewRenderer = @ptrCast(@alignCast(handle orelse return));
    const cb: *CBackend = @fieldParentPtr("backend", backend);
    std.heap.c_allocator.destroy(cb);
}

/// C-ABI down-call: begin loading `uri`. The shim calls this on the UI thread.
export fn wezig_android_navigate(handle: ?*anyopaque, uri: [*:0]const u8) void {
    const backend: *AndroidWebviewRenderer = @ptrCast(@alignCast(handle orelse return));
    backend.renderer().navigate(uri);
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
};

/// The installed C observer (the seam is single-sink, so one global suffices).
/// Stored module-level because the renderer struct is owned by C and we avoid
/// changing its layout; `onCObserverEvent` reads it. Set by
/// `wezig_android_set_lifecycle_observer`.
var c_observer: ?CLifecycleObserver = null;

fn onCObserverEvent(ctx: *anyopaque, event: seam.LifecycleEvent) void {
    _ = ctx;
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
    _ = &wezig_android_set_lifecycle_observer;
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
            .setViewportSize = setViewportSize,
        };
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
        return &self.view_token;
    }
    fn setViewportSize(ctx: *anyopaque, width: c_int, height: c_int) void {
        const self: *FakeJava = @ptrCast(@alignCast(ctx));
        self.last_viewport = .{ width, height };
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
        fn viewport(_: ?*anyopaque, _: c_int, _: c_int) callconv(.c) void {}
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
        .setViewportSize = CJava.viewport,
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
    };
    CObs.finished_code = -1;
    CObs.finished_uri_len = 0;

    var java = FakeJava{};
    var backend = AndroidWebviewRenderer.init(java.bridge());
    const observer = CLifecycleObserver{ .ctx = null, .onLoadState = CObs.onLoadState };
    wezig_android_set_lifecycle_observer(&backend, &observer);
    defer c_observer = null;

    wezig_android_on_load_state(&backend, @intFromEnum(AndroidLoadEvent.page_started), "https://obs.example/");
    wezig_android_on_load_state(&backend, @intFromEnum(AndroidLoadEvent.page_finished), "https://obs.example/");

    try std.testing.expectEqual(@intFromEnum(AndroidLoadEvent.page_finished), CObs.finished_code);
    try std.testing.expectEqualStrings("https://obs.example/", CObs.finished_uri[0..CObs.finished_uri_len]);
}

test "wezig_android_on_* entry points are null-safe (defensive JNI boundary)" {
    // A null handle or absent string must not crash the up-call — the JNI
    // boundary can legitimately pass null (no URI yet early in a load).
    wezig_android_on_load_state(null, 2, null);
    wezig_android_on_uri_changed(null, null);
    wezig_android_on_title_changed(null, null);
    wezig_android_on_progress(null, 50);

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
