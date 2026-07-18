//! The Android shell C-ABI: the real-app entry points the Gradle app module's
//! `MainActivity` (an `android.app.Activity`) links against — through the JNI
//! shim (`wezig_shell_jni.c`) — to stand up a genuine (if minimal) mobile
//! browser. This is the Android half of spec `build-mobile-shell` (stories
//! 2/3/4/5/6), the twin of `src/ios_shell.zig`. Host-loop-free: the OS owns the
//! window + run loop (ADR-0008), so the `Activity` drives THIS entry point
//! instead of a `HostLoop`.
//!
//! ## What it wires (all THROUGH the two seams — no raw `android.webkit.*`)
//!
//! `wezig_android_shell_start` takes the already-constructed Android `Renderer`
//! backend (the `*AndroidWebviewRenderer` the shim built via
//! `wezig_android_renderer_init` over its `CJavaBridge`) plus the chrome-surface
//! `CEmbedPlatform` ops (the URL field / back-forward toolbar / content
//! container the Java `WezigShellController` owns), builds the mobile
//! `ChromeSurface` + the shared `MobileChrome` (`src/mobile_chrome.zig`, the
//! mobile analogue of `chrome.zig`) over those two seams, `attach`es the chrome
//! to both event streams, and `build`s (embeds the renderer's opaque view
//! through the surface, sizes the viewport, navigates the start URI).
//!
//! Reusing the shim-owned renderer handle (rather than re-taking the
//! `CJavaBridge` here) keeps the renderer's JNI global-ref lifecycle — the ONE
//! cached view ref + the `deleteView`/`teardown` bridge ops the backend fix
//! added — owned by the shim exactly as the seam-contract tests exercise it; the
//! shell only composes the two seam VALUES the chrome drives.
//!
//! From then on the shell is a thin relay (mirroring `ios_shell.zig`):
//!
//!   - **user intents → renderer:** the `Activity`'s URL field / Back / Forward /
//!     Reload controls call `wezig_android_shell_navigate` / `_go_back` /
//!     `_go_forward` / `_reload`, which fire a `ChromeIntent` INTO the surface;
//!     the chrome turns each into a `Renderer` call. The shell NEVER calls the
//!     `WebView` directly — navigation crosses the seams exactly as desktop.
//!   - **renderer lifecycle → widgets:** the `WebViewClient`/`WebChromeClient`
//!     callbacks the Java controller marshals onto the UI thread re-enter the
//!     backend (`wezig_android_on_load_state` / `_on_uri_changed` /
//!     `_on_title_changed`), which emits `LifecycleEvent`s the chrome reflects
//!     into the surface's URL text + Back/Forward sensitivity (story 5).
//!
//! ## App lifecycle / state restoration is HOST-ONLY (ADR-0010, Resolved dec. 1)
//!
//! Background→foreground page-state restoration is a HOST concern ABOVE this
//! seam: the `Activity` wires it via `onSaveInstanceState`/`onRestoreInstanceState`
//! + the native `WebView.saveState`/`restoreState` the OS already mandates. No
//! `suspend`/`resume`/state method is added to the `Renderer` seam (ADR-0010).
//! This file adds NO lifecycle entry point: there is nothing for the seam to do
//! that the native `WebView` save-restore + the existing navigate op do not
//! already cover.
//!
//! One shell instance runs at a time (the narrowest real case — one visible
//! page; N-context tabs are Slice B), so the state is a single module-level
//! value the exported thunks operate on, mirroring `mobile_abi.zig`/`ios_shell`.

const std = @import("std");
const seam = @import("renderer.zig");
const toolkit = @import("toolkit.zig");
const android = @import("android_renderer.zig");
const AndroidWebviewRenderer = android.AndroidWebviewRenderer;
const mcs = @import("mobile_chrome_surface.zig");
const MobileChromeSurface = mcs.MobileChromeSurface;
const CEmbedPlatform = mcs.CEmbedPlatform;
const MobileChrome = @import("mobile_chrome.zig").MobileChrome;

/// The Android shell's seam-level state. Holds the chrome-surface + the shared
/// mobile chrome composed over the (shim-owned) renderer backend + the surface.
/// `MobileChrome` stores the two seam VALUES (not pointers to these fields), and
/// the surface / the C embed adapter are pointer-identity-stable here
/// (module-level for the surface adapter, and the renderer handle is owned by
/// the shim), so the chrome's `.ctx` back-pointers stay valid for the app's
/// lifetime.
const AndroidShell = struct {
    /// The Android `Renderer` backend — NOT owned here; it is the shim's
    /// `*AndroidWebviewRenderer` (constructed via `wezig_android_renderer_init`,
    /// freed via `wezig_android_renderer_deinit`). The shell only reads its seam.
    renderer_backend: *AndroidWebviewRenderer,
    /// The mobile chrome-surface over the Java `CEmbedPlatform` ops. Bridges the
    /// C-callconv ops the shim installs to the seam's Zig-callconv `EmbedPlatform`.
    surface: MobileChromeSurface,
    /// The C ops table the surface's embed/widget ops forward to (copied in from
    /// the shim's `CEmbedPlatform`).
    cplatform: CEmbedPlatform,
    /// The shared mobile chrome composed over the two seams.
    chrome: MobileChrome,

    // --- C-callconv → Zig-callconv embed-op adapters (mirroring the C-ABI path
    //     in `mobile_chrome_surface.zig`'s `CAndroidSurface`). The surface's
    //     `EmbedPlatform.host` is this `AndroidShell`, so each op recovers it
    //     directly and forwards to the shim's `CEmbedPlatform` op. ---
    fn embedView(host: *anyopaque, view: *anyopaque) callconv(.c) void {
        const self: *AndroidShell = @ptrCast(@alignCast(host));
        self.cplatform.embedView(self.cplatform.host, view);
    }
    fn setUrlText(host: *anyopaque, text: [*:0]const u8) callconv(.c) void {
        const self: *AndroidShell = @ptrCast(@alignCast(host));
        self.cplatform.setUrlText(self.cplatform.host, text);
    }
    fn setBackEnabled(host: *anyopaque, enabled: bool) callconv(.c) void {
        const self: *AndroidShell = @ptrCast(@alignCast(host));
        self.cplatform.setBackEnabled(self.cplatform.host, enabled);
    }
    fn setForwardEnabled(host: *anyopaque, enabled: bool) callconv(.c) void {
        const self: *AndroidShell = @ptrCast(@alignCast(host));
        self.cplatform.setForwardEnabled(self.cplatform.host, enabled);
    }
};

var android_shell: AndroidShell = undefined;

/// Construct the mobile `ChromeSurface` (over the Java `CEmbedPlatform` ops) +
/// the shared `MobileChrome` over the already-built Android `Renderer` backend,
/// attach the chrome to both event streams, and drive the start navigation
/// THROUGH the seams (`MobileChrome.build`: embed the renderer's opaque view via
/// the surface, size the viewport, navigate `start_uri`).
///
/// `renderer_handle` is the `*AndroidWebviewRenderer` the shim created via
/// `wezig_android_renderer_init` (so its JNI global-ref lifecycle stays
/// shim-owned); `cplatform` is the C embed ops table the shim fills in (each op
/// calls the Java `WezigShellController`). Returns an opaque shell context Swift…
/// er, the Java side hands back to the relay thunks. One shell at a time.
export fn wezig_android_shell_start(
    renderer_handle: ?*anyopaque,
    cplatform: *const CEmbedPlatform,
    start_uri: [*:0]const u8,
) ?*anyopaque {
    const backend: *AndroidWebviewRenderer = @ptrCast(@alignCast(renderer_handle orelse return null));
    android_shell = .{
        .renderer_backend = backend,
        .surface = undefined,
        .cplatform = cplatform.*,
        .chrome = undefined,
    };
    android_shell.surface = MobileChromeSurface.init(.{
        .host = &android_shell,
        .embedView = AndroidShell.embedView,
        .setUrlText = AndroidShell.setUrlText,
        .setBackEnabled = AndroidShell.setBackEnabled,
        .setForwardEnabled = AndroidShell.setForwardEnabled,
    });
    android_shell.chrome = MobileChrome.init(
        android_shell.renderer_backend.renderer(),
        android_shell.surface.chromeSurface(),
    );
    android_shell.chrome.attach();

    // Embed the renderer's opaque view through the surface, size the viewport,
    // and navigate the start URI — all THROUGH the two seams (MobileChrome.build).
    android_shell.chrome.build(start_uri);
    return &android_shell;
}

/// The user submitted a URL in the URL field. Fire a `.navigate` intent INTO the
/// surface; the chrome turns it into a `Renderer.navigate` — the shell never
/// calls the `WebView` directly. `uri` is borrowed for this call.
export fn wezig_android_shell_navigate(ctx: ?*anyopaque, uri: [*:0]const u8) void {
    const p: *AndroidShell = @ptrCast(@alignCast(ctx orelse return));
    p.surface.fireIntent(.{ .navigate = std.mem.span(uri) });
}

/// The user tapped Back. Fire a `.back` intent INTO the surface (→ chrome →
/// `Renderer.goBack`), NOT a raw `WebView.goBack`.
export fn wezig_android_shell_go_back(ctx: ?*anyopaque) void {
    const p: *AndroidShell = @ptrCast(@alignCast(ctx orelse return));
    p.surface.fireIntent(.back);
}

/// The user tapped Forward. Fire a `.forward` intent INTO the surface.
export fn wezig_android_shell_go_forward(ctx: ?*anyopaque) void {
    const p: *AndroidShell = @ptrCast(@alignCast(ctx orelse return));
    p.surface.fireIntent(.forward);
}

/// The user tapped Reload. Fire a `.reload` intent INTO the surface.
export fn wezig_android_shell_reload(ctx: ?*anyopaque) void {
    const p: *AndroidShell = @ptrCast(@alignCast(ctx orelse return));
    p.surface.fireIntent(.reload);
}

// Force the shell C-ABI `export fn`s to be analysed/emitted in a non-test
// static-lib build (same GC-retention issue + fix as `mobile_abi`/`ios_shell`).
comptime {
    _ = &wezig_android_shell_start;
    _ = &wezig_android_shell_navigate;
    _ = &wezig_android_shell_go_back;
    _ = &wezig_android_shell_go_forward;
    _ = &wezig_android_shell_reload;
}

// ---------------------------------------------------------------------------
// Headless seam-contract tests (run in `zig build test`; no JNI, no JVM, no
// emulator). A fake `CJavaBridge` (constructing a real backend via
// `wezig_android_renderer_init`) + a fake `CEmbedPlatform` record what the shell
// drives, so the whole Android-shell wiring — build the surface + chrome over
// the shim-owned renderer, embed + navigate on build, relay intents THROUGH the
// seams, reflect lifecycle events into the widgets — is proven on the host. The
// REAL end-to-end proof (a live WebView browses one page in the APK, survives a
// background/foreground round-trip) is the x86_64-emulator leg, kept OUT of
// `zig build test` (spec Q6 / ADR-0007 discipline).
// ---------------------------------------------------------------------------

const CJavaBridge = android.CJavaBridge;

/// A fake native host recording BOTH the `CJavaBridge` down-calls the renderer
/// drives AND the `CEmbedPlatform` widget ops the chrome drives, so the Android
/// shell is drivable with no JNI/JVM. Backed by module-level statics (the ops
/// are C-callconv fn pointers with no closure), reset by each test.
const FakeShellHost = struct {
    // renderer/WebView side (CJavaBridge)
    var navigated: bool = false;
    var last_uri: [256]u8 = undefined;
    var last_uri_len: usize = 0;
    var reloaded: bool = false;
    var went_back: bool = false;
    var went_forward: bool = false;
    var viewport_w: c_int = 0;
    var viewport_h: c_int = 0;
    var can_back: bool = false;
    var can_forward: bool = false;
    var view_token: u8 = 0;

    // surface side (CEmbedPlatform)
    var embedded: ?*anyopaque = null;
    var url_text: [256]u8 = undefined;
    var url_len: usize = 0;
    var back_enabled: bool = false;
    var forward_enabled: bool = false;

    fn reset() void {
        navigated = false;
        last_uri_len = 0;
        reloaded = false;
        went_back = false;
        went_forward = false;
        viewport_w = 0;
        viewport_h = 0;
        can_back = false;
        can_forward = false;
        embedded = null;
        url_len = 0;
        back_enabled = false;
        forward_enabled = false;
    }

    // --- CJavaBridge down-calls ---
    fn navigate(_: ?*anyopaque, uri: [*:0]const u8) callconv(.c) void {
        const s = std.mem.span(uri);
        const n = @min(s.len, last_uri.len);
        @memcpy(last_uri[0..n], s[0..n]);
        last_uri_len = n;
        navigated = true;
    }
    fn reload(_: ?*anyopaque) callconv(.c) void {
        reloaded = true;
    }
    fn stop(_: ?*anyopaque) callconv(.c) void {}
    fn goBack(_: ?*anyopaque) callconv(.c) void {
        went_back = true;
    }
    fn goForward(_: ?*anyopaque) callconv(.c) void {
        went_forward = true;
    }
    fn canGoBack(_: ?*anyopaque) callconv(.c) bool {
        return can_back;
    }
    fn canGoForward(_: ?*anyopaque) callconv(.c) bool {
        return can_forward;
    }
    fn view(_: ?*anyopaque) callconv(.c) ?*anyopaque {
        return &view_token;
    }
    fn deleteView(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {}
    fn setViewportSize(_: ?*anyopaque, width: c_int, height: c_int) callconv(.c) void {
        viewport_w = width;
        viewport_h = height;
    }
    fn source(_: ?*anyopaque, _: [*:0]const u8) callconv(.c) void {}
    fn teardown(_: ?*anyopaque) callconv(.c) void {}

    // --- CEmbedPlatform ops ---
    fn embedView(_: ?*anyopaque, v: ?*anyopaque) callconv(.c) void {
        embedded = v;
    }
    fn setUrlText(_: ?*anyopaque, text: [*:0]const u8) callconv(.c) void {
        const s = std.mem.span(text);
        const n = @min(s.len, url_text.len);
        @memcpy(url_text[0..n], s[0..n]);
        url_len = n;
    }
    fn setBackEnabled(_: ?*anyopaque, enabled: bool) callconv(.c) void {
        back_enabled = enabled;
    }
    fn setForwardEnabled(_: ?*anyopaque, enabled: bool) callconv(.c) void {
        forward_enabled = enabled;
    }

    fn bridge() CJavaBridge {
        return .{
            .ctx = null,
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
            .injectUserScript = source,
            .setScriptMessageHandler = source,
            .evaluateScript = source,
            .registerScheme = source,
            .teardown = teardown,
        };
    }
    fn platform() CEmbedPlatform {
        return .{
            .host = null,
            .embedView = embedView,
            .setUrlText = setUrlText,
            .setBackEnabled = setBackEnabled,
            .setForwardEnabled = setForwardEnabled,
        };
    }
    fn urlText() []const u8 {
        return url_text[0..url_len];
    }
    fn lastUri() []const u8 {
        return last_uri[0..last_uri_len];
    }
};

// Force a `WebViewClient` load-state up-call into the shim-owned renderer (the
// Java side marshals these onto the UI thread before crossing the seam). Codes
// mirror `AndroidLoadEvent` (0=started,1=committed,2=finished,3=failed).
extern fn wezig_android_on_load_state(handle: ?*anyopaque, code: c_int, uri: ?[*:0]const u8) void;
extern fn wezig_android_on_uri_changed(handle: ?*anyopaque, uri: ?[*:0]const u8) void;
extern fn wezig_android_renderer_init(cbridge: *const CJavaBridge) ?*anyopaque;
extern fn wezig_android_renderer_deinit(handle: ?*anyopaque) void;

test "Android shell: start embeds the view, sizes the viewport, and navigates through the seams" {
    FakeShellHost.reset();
    const bridge = FakeShellHost.bridge();
    const renderer_handle = wezig_android_renderer_init(&bridge).?;
    defer wezig_android_renderer_deinit(renderer_handle);

    const cplatform = FakeShellHost.platform();
    _ = wezig_android_shell_start(renderer_handle, &cplatform, "https://start.example/").?;

    // build() embedded the renderer's opaque view THROUGH the chrome-surface seam.
    try std.testing.expect(FakeShellHost.embedded != null);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&FakeShellHost.view_token)), FakeShellHost.embedded.?);

    // The viewport was sized through the seam (MobileChrome.build).
    try std.testing.expect(FakeShellHost.viewport_w > 0 and FakeShellHost.viewport_h > 0);

    // The start navigation crossed the seam to the WebView op (not a raw call).
    try std.testing.expect(FakeShellHost.navigated);
    try std.testing.expectEqualStrings("https://start.example/", FakeShellHost.lastUri());
}

test "Android shell: a URL-field submit navigates THROUGH the chrome/seams and reflects the URL" {
    FakeShellHost.reset();
    const bridge = FakeShellHost.bridge();
    const renderer_handle = wezig_android_renderer_init(&bridge).?;
    defer wezig_android_renderer_deinit(renderer_handle);

    const cplatform = FakeShellHost.platform();
    const ctx = wezig_android_shell_start(renderer_handle, &cplatform, "https://one.example/").?;

    // A user-entered URL fires a navigate intent → chrome → Renderer.navigate.
    wezig_android_shell_navigate(ctx, "https://typed.example/");
    try std.testing.expectEqualStrings("https://typed.example/", FakeShellHost.lastUri());

    // The WebViewClient reports the load; the chrome reflects the URI into the URL
    // field (story 5 — the field mirrors the current page). The load callbacks are
    // marshalled onto the UI thread by the Java side before crossing the seam.
    wezig_android_on_load_state(renderer_handle, 0, "https://typed.example/"); // started
    wezig_android_on_uri_changed(renderer_handle, "https://typed.example/");
    wezig_android_on_load_state(renderer_handle, 2, "https://typed.example/"); // finished
    try std.testing.expectEqualStrings("https://typed.example/", FakeShellHost.urlText());
}

test "Android shell: back/forward intents drive the renderer and button sensitivity reflects history" {
    FakeShellHost.reset();
    const bridge = FakeShellHost.bridge();
    const renderer_handle = wezig_android_renderer_init(&bridge).?;
    defer wezig_android_renderer_deinit(renderer_handle);

    const cplatform = FakeShellHost.platform();
    const ctx = wezig_android_shell_start(renderer_handle, &cplatform, "https://start.example/").?;

    // Simulate a real webview's history: after navigating away, Back is available.
    FakeShellHost.can_back = true;
    FakeShellHost.can_forward = false;
    // A lifecycle transition re-queries canGoBack/canGoForward via the chrome and
    // reflects them into the toolbar (story 5).
    wezig_android_on_load_state(renderer_handle, 2, "https://second.example/"); // finished
    try std.testing.expect(FakeShellHost.back_enabled);
    try std.testing.expect(!FakeShellHost.forward_enabled);

    // A Back tap fires a .back intent → chrome → Renderer.goBack (not a raw call).
    wezig_android_shell_go_back(ctx);
    try std.testing.expect(FakeShellHost.went_back);

    // A Forward tap fires a .forward intent → chrome → Renderer.goForward.
    wezig_android_shell_go_forward(ctx);
    try std.testing.expect(FakeShellHost.went_forward);

    // A Reload tap fires a .reload intent → chrome → Renderer.reload.
    wezig_android_shell_reload(ctx);
    try std.testing.expect(FakeShellHost.reloaded);
}
