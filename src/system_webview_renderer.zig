//! `SystemWebviewRenderer`: the `Renderer` seam (renderer.zig) implemented on
//! WebKitGTK 6.0 (ADR-0005, ADR-0006). This is the ONE place WebKitGTK is
//! touched for content: it wraps a `WebKitWebView`, maps the seam's methods to
//! `webkit_web_view_*` calls, and translates WebKit's signals into the seam's
//! `LifecycleEvent`s. `WezigRenderer` will implement the SAME `renderer.zig`
//! interface later and be swapped in behind it.
//!
//! Like `sdl.zig` (SDL) and `gtk_toolkit.zig` (GTK), this file links a native
//! library and therefore lives in the SHELL executable ONLY, never the `wezig`
//! library module (see `build.zig`). The `wezig` library, the v0 SDL app, and
//! the headless golden tests never see WebKitGTK.
//!
//! The GTK4/WebKit binding comes through `webkit_c.h` (see that header for why
//! a thin translate-c shim is needed instead of a bare `@cInclude`).

const std = @import("std");
const wezig = @import("wezig");
const seam = wezig.renderer;

const c = @cImport({
    @cDefine("__GI_SCANNER__", "1");
    @cDefine("GTK_COMPILATION", "1");
    @cInclude("webkit_c.h");
});

/// A `Renderer` backed by one `WebKitWebView`. Construct with `init`, obtain the
/// seam value with `renderer()`, and hand THAT to the chrome. The chrome never
/// sees the `WebKitWebView`; it flows to the toolkit only as an opaque
/// `ViewHandle` (the underlying `GtkWidget`).
pub const SystemWebviewRenderer = struct {
    view: *c.WebKitWebView,
    cb: ?seam.LifecycleCallback = null,
    /// The single page->native script-message handler (script bridge, ADR-0005).
    /// One channel today (the provider's `request` channel); a set can replace
    /// this if more channels are ever needed.
    msg_cb: ?seam.ScriptMessageCallback = null,
    /// The single custom-scheme handler (request interception, ADR-0005).
    scheme_handler: ?seam.SchemeHandler = null,

    /// Create the underlying `WebKitWebView`. GTK must already be initialised
    /// (the toolkit's `createWindow` does that); a `WebKitWebView` is a GTK
    /// widget, so it needs GTK up.
    pub fn init() SystemWebviewRenderer {
        const view: *c.WebKitWebView = @ptrCast(c.webkit_web_view_new());
        return .{ .view = view };
    }

    pub fn renderer(self: *SystemWebviewRenderer) seam.Renderer {
        // Wire WebKit's signals to our re-emitters now that `self` has a stable
        // address (the caller holds it by pointer).
        signalConnect(@ptrCast(self.view), "load-changed", @ptrCast(&onLoadChanged), self);
        signalConnect(@ptrCast(self.view), "notify::title", @ptrCast(&onNotifyTitle), self);
        signalConnect(@ptrCast(self.view), "notify::uri", @ptrCast(&onNotifyUri), self);
        signalConnect(@ptrCast(self.view), "notify::estimated-load-progress", @ptrCast(&onNotifyProgress), self);
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
        .declareSchemeSecurity = declareSchemeSecurity,
    };

    fn navigate(ctx: *anyopaque, uri: [*:0]const u8) void {
        const self: *SystemWebviewRenderer = @ptrCast(@alignCast(ctx));
        c.webkit_web_view_load_uri(self.view, uri);
    }
    fn reloadFn(ctx: *anyopaque) void {
        const self: *SystemWebviewRenderer = @ptrCast(@alignCast(ctx));
        c.webkit_web_view_reload(self.view);
    }
    fn stopFn(ctx: *anyopaque) void {
        const self: *SystemWebviewRenderer = @ptrCast(@alignCast(ctx));
        c.webkit_web_view_stop_loading(self.view);
    }
    fn goBack(ctx: *anyopaque) void {
        const self: *SystemWebviewRenderer = @ptrCast(@alignCast(ctx));
        c.webkit_web_view_go_back(self.view);
    }
    fn goForward(ctx: *anyopaque) void {
        const self: *SystemWebviewRenderer = @ptrCast(@alignCast(ctx));
        c.webkit_web_view_go_forward(self.view);
    }
    fn canGoBack(ctx: *anyopaque) bool {
        const self: *SystemWebviewRenderer = @ptrCast(@alignCast(ctx));
        return c.webkit_web_view_can_go_back(self.view) != 0;
    }
    fn canGoForward(ctx: *anyopaque) bool {
        const self: *SystemWebviewRenderer = @ptrCast(@alignCast(ctx));
        return c.webkit_web_view_can_go_forward(self.view) != 0;
    }
    fn viewHandle(ctx: *anyopaque) seam.ViewHandle {
        const self: *SystemWebviewRenderer = @ptrCast(@alignCast(ctx));
        // The interactive view IS the GtkWidget; hand it across opaquely.
        return @ptrCast(self.view);
    }
    fn setViewportSize(ctx: *anyopaque, width: c_int, height: c_int) void {
        // The embedded WebView tracks its allocated size from GTK layout; there
        // is no separate viewport call to make for the webview backend. Kept as
        // a no-op so the seam method exists for `WezigRenderer` (ADR-0006).
        _ = ctx;
        _ = width;
        _ = height;
    }
    fn setLifecycleCallback(ctx: *anyopaque, cb: seam.LifecycleCallback) void {
        const self: *SystemWebviewRenderer = @ptrCast(@alignCast(ctx));
        self.cb = cb;
    }

    fn emit(self: *SystemWebviewRenderer, event: seam.LifecycleEvent) void {
        if (self.cb) |cb| cb.onEvent(cb.ctx, event);
    }

    // --- script-message bridge (ADR-0005) ---
    // WebKitGTK maps this onto the view's `WebKitUserContentManager`: injected
    // user scripts set up the page-world object, `register_script_message_handler`
    // opens the `window.webkit.messageHandlers.<name>` channel, and the
    // `script-message-received::<name>` signal delivers the page's messages.

    fn injectUserScript(ctx: *anyopaque, source: [*:0]const u8) void {
        const self: *SystemWebviewRenderer = @ptrCast(@alignCast(ctx));
        const ucm = c.webkit_web_view_get_user_content_manager(self.view);
        const script = c.webkit_user_script_new(
            source,
            c.WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
            c.WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,
            null,
            null,
        );
        c.webkit_user_content_manager_add_script(ucm, script);
        c.webkit_user_script_unref(script);
    }

    fn setScriptMessageHandler(ctx: *anyopaque, name: [*:0]const u8, cb: seam.ScriptMessageCallback) void {
        const self: *SystemWebviewRenderer = @ptrCast(@alignCast(ctx));
        self.msg_cb = cb;
        const ucm = c.webkit_web_view_get_user_content_manager(self.view);
        // Connect BEFORE registering (the docs' race-avoidance ordering). The
        // signal detail is the channel name, so `::<name>` targets this channel.
        var buf: [128]u8 = undefined;
        const nm = std.mem.span(name);
        const detailed = std.fmt.bufPrintZ(&buf, "script-message-received::{s}", .{nm}) catch return;
        signalConnect(@ptrCast(ucm), detailed, @ptrCast(&onScriptMessage), self);
        _ = c.webkit_user_content_manager_register_script_message_handler(ucm, name, null);
    }

    fn evaluateScript(ctx: *anyopaque, source: [*:0]const u8) void {
        const self: *SystemWebviewRenderer = @ptrCast(@alignCast(ctx));
        c.webkit_web_view_evaluate_javascript(self.view, source, -1, null, null, null, null, null);
    }

    /// `script-message-received::<name>` handler: WebKitGTK passes the posted
    /// value as a `JSCValue`. We forward its string form to the seam callback.
    fn onScriptMessage(ucm: *c.WebKitUserContentManager, value: *c.JSCValue, data: c.gpointer) callconv(.c) void {
        _ = ucm;
        const self: *SystemWebviewRenderer = @ptrCast(@alignCast(data));
        const cb = self.msg_cb orelse return;
        const str_c = c.jsc_value_to_string(value) orelse return;
        defer c.g_free(str_c);
        // The channel name is not carried on the value; we have exactly one
        // channel today, so report it under the provider's convention.
        cb.onMessage(cb.ctx, "wezig", std.mem.span(str_c));
    }

    // --- request-interception / custom-scheme hook (ADR-0005) ---
    // WebKitGTK maps this onto the view's `WebKitWebContext`:
    // `register_uri_scheme` installs a native callback that serves each request
    // by finishing it with a `GInputStream` over the native-generated body.

    fn registerScheme(ctx: *anyopaque, scheme: [*:0]const u8, handler: seam.SchemeHandler) void {
        const self: *SystemWebviewRenderer = @ptrCast(@alignCast(ctx));
        self.scheme_handler = handler;
        const context = c.webkit_web_view_get_context(self.view);
        c.webkit_web_context_register_uri_scheme(context, scheme, @ptrCast(&onSchemeRequest), self, null);
    }

    /// Declare a scheme's SECURITY TRAITS (secure/CORS/local) on the view's
    /// `WebKitSecurityManager` (ADR-0015 decision 7). This is the CONTEXT/security
    /// layer — a DIFFERENT WebKitGTK API from `register_uri_scheme` (the request
    /// callback): `webkit_web_context_get_security_manager` +
    /// `..._register_uri_scheme_as_secure` / `_as_cors_enabled` / `_as_local`.
    /// Registering `ipfs://` as secure makes it a first-class secure origin (its
    /// bytes are hash-verified). NOTE (ADR-0016): this WORKS on stock WebKitGTK
    /// (the origin IS treated as secure); it is NECESSARY but NOT SUFFICIENT for
    /// service-worker hosting, which needs a separate backend patch and is OUT of
    /// scope here.
    fn declareSchemeSecurity(ctx: *anyopaque, scheme: [*:0]const u8, traits: seam.SchemeSecurityTraits) void {
        const self: *SystemWebviewRenderer = @ptrCast(@alignCast(ctx));
        const context = c.webkit_web_view_get_context(self.view);
        const mgr = c.webkit_web_context_get_security_manager(context);
        if (traits.secure) c.webkit_security_manager_register_uri_scheme_as_secure(mgr, scheme);
        if (traits.cors) c.webkit_security_manager_register_uri_scheme_as_cors_enabled(mgr, scheme);
        if (traits.local) c.webkit_security_manager_register_uri_scheme_as_local(mgr, scheme);
    }

    /// Whether WebKitGTK's `WebKitSecurityManager` currently treats `scheme` as a
    /// SECURE origin. Used by the off-core-gate `ipfs-secure-origin-test` leg to
    /// prove the seam's `declareSchemeSecurity` declaration reached the real
    /// backend. The WebKit query lives HERE (the backend owns the WebKit `c`
    /// translation unit); the shell proof asks through this method rather than
    /// reaching into the view, keeping WebKitGTK confined to this file.
    pub fn isSchemeSecure(self: *SystemWebviewRenderer, scheme: [*:0]const u8) bool {
        const context = c.webkit_web_view_get_context(self.view);
        const mgr = c.webkit_web_context_get_security_manager(context);
        return c.webkit_security_manager_uri_scheme_is_secure(mgr, scheme) != 0;
    }

    /// `WebKitURISchemeRequestCallback`: ask the seam handler for the native body
    /// + content-type for this URI and finish the request with an input stream
    /// over a copy of those bytes (WebKit reads the stream asynchronously, so the
    /// buffer must outlive this call; `g_memory_input_stream_new_from_data` with
    /// `g_free` as the destructor owns the copy).
    fn onSchemeRequest(request: *c.WebKitURISchemeRequest, data: c.gpointer) callconv(.c) void {
        const self: *SystemWebviewRenderer = @ptrCast(@alignCast(data));
        const handler = self.scheme_handler orelse return;
        const uri = c.webkit_uri_scheme_request_get_uri(request);
        const resp = handler.onRequest(handler.ctx, std.mem.span(uri));

        // Copy the body into a GLib-owned buffer the stream frees when done.
        const copy = c.g_malloc(resp.body.len);
        const dst: [*]u8 = @ptrCast(copy);
        @memcpy(dst[0..resp.body.len], resp.body);
        const stream = c.g_memory_input_stream_new_from_data(copy, @intCast(resp.body.len), c.g_free);

        var ct_buf: [128]u8 = undefined;
        const content_type = std.fmt.bufPrintZ(&ct_buf, "{s}", .{resp.content_type}) catch "text/plain";
        c.webkit_uri_scheme_request_finish(request, stream, @intCast(resp.body.len), content_type);
        c.g_object_unref(stream);
    }

    // --- WebKit signals -> seam lifecycle events ---

    fn onLoadChanged(_: *c.WebKitWebView, load_event: c.WebKitLoadEvent, data: c.gpointer) callconv(.c) void {
        const self: *SystemWebviewRenderer = @ptrCast(@alignCast(data));
        const uri_c = c.webkit_web_view_get_uri(self.view);
        const uri: ?[]const u8 = if (uri_c) |u| std.mem.span(u) else null;
        const state: seam.LoadState = switch (load_event) {
            c.WEBKIT_LOAD_STARTED => .started,
            c.WEBKIT_LOAD_COMMITTED => .committed,
            c.WEBKIT_LOAD_FINISHED => .finished,
            else => return,
        };
        self.emit(.{ .load_changed = .{ .state = state, .uri = uri } });
    }

    fn onNotifyTitle(_: *c.GObject, _: *c.GParamSpec, data: c.gpointer) callconv(.c) void {
        const self: *SystemWebviewRenderer = @ptrCast(@alignCast(data));
        if (c.webkit_web_view_get_title(self.view)) |t| {
            self.emit(.{ .title_changed = std.mem.span(t) });
        }
    }

    fn onNotifyUri(_: *c.GObject, _: *c.GParamSpec, data: c.gpointer) callconv(.c) void {
        const self: *SystemWebviewRenderer = @ptrCast(@alignCast(data));
        if (c.webkit_web_view_get_uri(self.view)) |u| {
            self.emit(.{ .uri_changed = std.mem.span(u) });
        }
    }

    fn onNotifyProgress(_: *c.GObject, _: *c.GParamSpec, data: c.gpointer) callconv(.c) void {
        const self: *SystemWebviewRenderer = @ptrCast(@alignCast(data));
        self.emit(.{ .progress_changed = c.webkit_web_view_get_estimated_load_progress(self.view) });
    }
};

/// `g_signal_connect` is a macro over `g_signal_connect_data`; replicate it.
/// (Same helper `shell.zig` uses; each webview/gtk file owns its own copy so
/// the seam files stay independent.)
fn signalConnect(instance: c.gpointer, detailed_signal: [*:0]const u8, handler: c.GCallback, data: c.gpointer) void {
    _ = c.g_signal_connect_data(instance, detailed_signal, handler, data, null, 0);
}
