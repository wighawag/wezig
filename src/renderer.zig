//! The `Renderer` seam: the chrome-to-content boundary (ADR-0005, ADR-0006).
//!
//! This is the TOP seam of the browser: the chrome, and later the Ethereum
//! provider + IPFS resolution, talk ONLY to this interface and NEVER reach past
//! it into WebKitGTK-specific APIs. `SystemWebviewRenderer` (WebKitGTK) is its
//! first and only implementation today; `WezigRenderer` (our own engine) will
//! implement the SAME interface later and be swapped in behind it. This file
//! deliberately imports NO windowing/webview binding: it is pure interface, so
//! callers above the seam stay backend-free (the same discipline ADR-0002 set
//! for `PaintBackend`, applied at the top of the stack).
//!
//! ## Shape (vtable, like `PaintBackend` / `std.mem.Allocator`)
//!
//! `Renderer` is a `{ ptr, vtable }` pair so a concrete backend is a runtime
//! VALUE, not a comptime type: the chrome holds one `Renderer` and could hold a
//! different backend tomorrow with no code change. The method set is MINIMAL on
//! purpose (spec `explore-webview-shell`, this task): just what a one-window,
//! URL-bar, back/forward chrome needs to drive one real page.
//!
//!   - navigation:   `navigate` / `reload` / `stop`, `goBack` / `goForward`,
//!                   `canGoBack` / `canGoForward`
//!   - view:         `view()` -> an OPAQUE, embeddable interactive view handle
//!                   the toolkit hosts (kept opaque so the chrome never learns
//!                   it is a GTK widget)
//!   - input/scroll/viewport: `setViewportSize` (input + scroll are handled by
//!                   the live interactive view itself for the webview backend;
//!                   see the note on that method)
//!   - load lifecycle EVENTS: `setLifecycleCallback` delivers title / URL /
//!                   progress / load-state changes the chrome subscribes to.
//!
//! ## The two web3-load-bearing hooks (this task, ADR-0005)
//!
//! The minimal navigate/interact surface above is joined by the TWO hooks
//! `explore-web3-capabilities` builds on. ADR-0005 pins BOTH to this seam so the
//! Ethereum provider (EIP-1193) and `ipfs://` are served THROUGH the interface
//! and keep working after the `WezigRenderer` swap, never as one-off webview
//! calls in the chrome:
//!
//!   - **script-message bridge:** inject a page-world script (`injectUserScript`)
//!     so a native object like `window.wezig` exists on the page, register a
//!     named page->native channel (`setScriptMessageHandler`), and evaluate JS
//!     back into the page (`evaluateScript`) to post a native result. Together
//!     these round-trip a message BOTH ways: the page posts to native, native
//!     replies into the page. (WebKitGTK: `WebKitUserContentManager` handlers +
//!     user scripts; proven with a trivial `window.wezig.ping()`.)
//!   - **request-interception / custom-scheme hook:** register a custom URI
//!     scheme (`registerScheme`) whose requests are served by a native handler
//!     returning a body + content-type. (WebKitGTK:
//!     `webkit_web_context_register_uri_scheme` + a `WebKitURISchemeRequestCallback`;
//!     proven with a trivial `wezig-test://hello`.)
//!
//! Both are on the VTable so `WezigRenderer` must satisfy them later; only the
//! WebKitGTK backend (`system_webview_renderer.zig`) knows the concrete APIs.

const std = @import("std");

/// An opaque handle to the renderer's live, embeddable interactive view (the
/// content area). The toolkit seam embeds THIS into the shell window's content
/// slot. It is `*anyopaque` on purpose: the chrome passes it from the renderer
/// to the toolkit without ever knowing it is a `GtkWidget` (or, later, a
/// `WezigRenderer` surface). Only the two backend implementations interpret it.
pub const ViewHandle = *anyopaque;

/// The phases of a page load the chrome cares about. A subset of what the
/// backend exposes, chosen to match what a URL bar + back/forward chrome needs:
/// flip a spinner on `started`, enable/disable buttons on `committed`, stop the
/// spinner on `finished`, surface an error on `failed`.
pub const LoadState = enum {
    /// A navigation has begun (a new provisional load started).
    started,
    /// The load committed (the server responded; the URL is now authoritative).
    committed,
    /// The load finished successfully.
    finished,
    /// The load failed (network error, bad URL, TLS failure, ...).
    failed,
};

/// A load-lifecycle event delivered to the chrome's callback. The chrome reads
/// only these fields; it never touches a backend-native event object. `title`
/// and `uri` are borrowed for the duration of the callback (the backend owns
/// the storage), so a chrome that keeps them must copy.
pub const LifecycleEvent = union(enum) {
    /// The load state changed. `uri` is the document URI at this phase (may be
    /// null very early). On `.failed`, the load did not complete.
    load_changed: struct { state: LoadState, uri: ?[]const u8 },
    /// The document title changed (may fire several times per load).
    title_changed: []const u8,
    /// The document URI changed (redirects, history navigation).
    uri_changed: []const u8,
    /// Load progress in [0.0, 1.0]; the chrome can drive a progress bar.
    progress_changed: f64,
};

/// The chrome's subscription to lifecycle events: a context pointer plus a
/// callback the backend invokes on the main loop. Kept a plain pair (not a
/// vtable) because there is exactly one event sink shape.
pub const LifecycleCallback = struct {
    ctx: *anyopaque,
    onEvent: *const fn (ctx: *anyopaque, event: LifecycleEvent) void,
};

/// A message posted from the page world to native over a named script-message
/// channel (the script-message bridge, ADR-0005). `name` is the channel the
/// handler was registered under; `body` is the message's string payload,
/// borrowed for the callback's duration (the backend owns the storage, so a
/// handler that keeps it must copy). This is the page->native leg of the bridge
/// the EIP-1193 provider uses to deliver `request` calls; native replies into
/// the page with `evaluateScript`.
pub const ScriptMessageCallback = struct {
    ctx: *anyopaque,
    onMessage: *const fn (ctx: *anyopaque, name: []const u8, body: []const u8) void,
};

/// A native-served response to a custom-scheme request (the request-interception
/// hook, ADR-0005). The scheme handler returns this for each request URI: the
/// `body` bytes native generates and the `content_type` to serve them as (e.g.
/// `text/html`). Both slices must stay valid until the handler is next called
/// (the backend copies them immediately into its own request response). This is
/// how `ipfs://` (and wallet RPC endpoints) are served from native code.
pub const SchemeResponse = struct {
    body: []const u8,
    content_type: []const u8,
};

/// A native handler for a registered custom URI scheme. `onRequest` is invoked
/// with the full request `uri` and returns the `SchemeResponse` native serves
/// for it. Kept a plain pair (like `LifecycleCallback`): one handler per scheme.
pub const SchemeHandler = struct {
    ctx: *anyopaque,
    onRequest: *const fn (ctx: *anyopaque, uri: []const u8) SchemeResponse,
};

/// A custom scheme's SECURITY TRAITS: how the origin a scheme serves is treated
/// by the engine's security model, declared AT the seam so it is reproduced
/// after the `WezigRenderer` swap (ADR-0015 decision 7; the two-layer finding
/// `work/notes/findings/sw-fetch-vs-custom-scheme-interception-two-layers-2026-07-15.md`).
/// These are a CONTEXT/security-layer concern distinct from serving a body
/// (`SchemeHandler`, above): on WebKitGTK they map to `WebKitSecurityManager`'s
/// `register_uri_scheme_as_secure` / `_as_cors_enabled` / `_as_local`, a
/// DIFFERENT API from `webkit_web_context_register_uri_scheme`. Registering
/// `ipfs://` as `.{ .secure = true }` makes it a first-class secure origin (its
/// bytes are hash-verified — the STRONGEST origin, ADR-0011). All-false is the
/// default (an ordinary, non-secure custom scheme).
///
/// Scope note (ADR-0016): being a secure origin is NECESSARY but NOT SUFFICIENT
/// for service-worker HOSTING on stock WebKitGTK — that needs a SEPARATE
/// backend-level protocol allowlist with no public knob, delivered by a carried
/// fork patch (`spike-webkitgtk-sw-scheme-patch`), NOT by these traits. These
/// traits are the clean, self-contained secure-origin declaration; they work on
/// stock WebKitGTK (the origin IS treated as secure).
pub const SchemeSecurityTraits = struct {
    /// Treat the scheme's origin as a SECURE context (like `https://`): powerful
    /// web platform features gated on secure context become available, and — on
    /// a backend that also allowlists the protocol — service workers can be
    /// hosted. WebKitGTK: `webkit_security_manager_register_uri_scheme_as_secure`.
    secure: bool = false,
    /// Allow cross-origin resource sharing to the scheme's origin. WebKitGTK:
    /// `webkit_security_manager_register_uri_scheme_as_cors_enabled`.
    cors: bool = false,
    /// Treat the scheme as LOCAL (like `file://`): restricted access rules apply.
    /// WebKitGTK: `webkit_security_manager_register_uri_scheme_as_local`.
    local: bool = false,
};

/// The `Renderer` seam value: a context pointer plus a function-pointer table,
/// exactly like `PaintBackend` (ADR-0002). Construct a backend, obtain this
/// value from it, and hand it to the chrome; the chrome talks only to these
/// methods.
pub const Renderer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        // --- navigation ---
        /// Begin loading `uri` in the view (a full navigation).
        navigate: *const fn (ctx: *anyopaque, uri: [*:0]const u8) void,
        /// Reload the current document.
        reload: *const fn (ctx: *anyopaque) void,
        /// Stop the in-flight load.
        stop: *const fn (ctx: *anyopaque) void,
        /// Navigate back / forward in session history.
        goBack: *const fn (ctx: *anyopaque) void,
        goForward: *const fn (ctx: *anyopaque) void,
        /// Whether a back / forward navigation is currently possible (the chrome
        /// enables/disables its buttons from these).
        canGoBack: *const fn (ctx: *anyopaque) bool,
        canGoForward: *const fn (ctx: *anyopaque) bool,

        // --- view / viewport ---
        /// The live, embeddable interactive view handle the toolkit hosts.
        view: *const fn (ctx: *anyopaque) ViewHandle,
        /// Tell the renderer its viewport size changed (resize). Input and
        /// scroll for the webview backend are handled by the live view widget
        /// itself once embedded and focused, so no per-event forwarding method
        /// is needed at this seam yet; a `WezigRenderer` (which does NOT own an
        /// OS-native interactive widget) will extend the seam with explicit
        /// input/scroll forwarding when it lands (recorded in ADR-0006).
        setViewportSize: *const fn (ctx: *anyopaque, width: c_int, height: c_int) void,

        // --- lifecycle events ---
        /// Subscribe the chrome to load-lifecycle events. At most one sink; a
        /// later call replaces the previous one.
        setLifecycleCallback: *const fn (ctx: *anyopaque, cb: LifecycleCallback) void,

        // --- script-message bridge (ADR-0005) ---
        /// Inject `source` into every page's world at document start, so a
        /// native page-world object (e.g. `window.wezig`) exists before page
        /// scripts run. This is the native->page setup leg of the bridge.
        injectUserScript: *const fn (ctx: *anyopaque, source: [*:0]const u8) void,
        /// Register the page->native channel `name`: the page posts to it and
        /// `cb` is invoked with the message body. At most one handler per name;
        /// a later call with the same name replaces it.
        setScriptMessageHandler: *const fn (ctx: *anyopaque, name: [*:0]const u8, cb: ScriptMessageCallback) void,
        /// Evaluate `source` as JS in the current page, e.g. to post a native
        /// result back into the page (the native->page reply leg).
        evaluateScript: *const fn (ctx: *anyopaque, source: [*:0]const u8) void,

        // --- request-interception / custom-scheme hook (ADR-0005) ---
        /// Register the custom URI scheme `scheme` (e.g. `ipfs`): every request
        /// for it is served by `handler` from native code. At most one handler
        /// per scheme.
        registerScheme: *const fn (ctx: *anyopaque, scheme: [*:0]const u8, handler: SchemeHandler) void,
        /// Declare the SECURITY TRAITS of the custom URI scheme `scheme`
        /// (secure / CORS / local) at the SEAM, so `ipfs://` can be registered
        /// as a secure origin and a `WezigRenderer` reproduces it (ADR-0015
        /// decision 7). This is a SIBLING to `registerScheme`, not extra fields
        /// on it: security traits are a distinct CONTEXT-layer concern (a
        /// different backend API from the request callback — `WebKitSecurityManager`
        /// vs the URI-scheme registration), and not every scheme declares them.
        ///
        /// OPTIONAL on the vtable (`?...`): a backend that cannot honour scheme
        /// security traits leaves it null (ADR-0016 decision 5 — the seam
        /// expresses the declaration UNIFORMLY, but whether a given backend can
        /// honour it varies). The `declareSchemeSecurity` forwarder no-ops when
        /// the backend does not implement it, so callers stay backend-agnostic.
        declareSchemeSecurity: ?*const fn (ctx: *anyopaque, scheme: [*:0]const u8, traits: SchemeSecurityTraits) void = null,
    };

    // Thin forwarders so callers write `renderer.navigate(...)` not
    // `renderer.vtable.navigate(renderer.ptr, ...)`.
    pub fn navigate(self: Renderer, uri: [*:0]const u8) void {
        self.vtable.navigate(self.ptr, uri);
    }
    pub fn reload(self: Renderer) void {
        self.vtable.reload(self.ptr);
    }
    pub fn stop(self: Renderer) void {
        self.vtable.stop(self.ptr);
    }
    pub fn goBack(self: Renderer) void {
        self.vtable.goBack(self.ptr);
    }
    pub fn goForward(self: Renderer) void {
        self.vtable.goForward(self.ptr);
    }
    pub fn canGoBack(self: Renderer) bool {
        return self.vtable.canGoBack(self.ptr);
    }
    pub fn canGoForward(self: Renderer) bool {
        return self.vtable.canGoForward(self.ptr);
    }
    pub fn view(self: Renderer) ViewHandle {
        return self.vtable.view(self.ptr);
    }
    pub fn setViewportSize(self: Renderer, width: c_int, height: c_int) void {
        self.vtable.setViewportSize(self.ptr, width, height);
    }
    pub fn setLifecycleCallback(self: Renderer, cb: LifecycleCallback) void {
        self.vtable.setLifecycleCallback(self.ptr, cb);
    }
    pub fn injectUserScript(self: Renderer, source: [*:0]const u8) void {
        self.vtable.injectUserScript(self.ptr, source);
    }
    pub fn setScriptMessageHandler(self: Renderer, name: [*:0]const u8, cb: ScriptMessageCallback) void {
        self.vtable.setScriptMessageHandler(self.ptr, name, cb);
    }
    pub fn evaluateScript(self: Renderer, source: [*:0]const u8) void {
        self.vtable.evaluateScript(self.ptr, source);
    }
    pub fn registerScheme(self: Renderer, scheme: [*:0]const u8, handler: SchemeHandler) void {
        self.vtable.registerScheme(self.ptr, scheme, handler);
    }
    /// Declare `scheme`'s security traits at the seam (secure/CORS/local). A
    /// no-op on a backend that does not implement the optional vtable method
    /// (see `declareSchemeSecurity` on the VTable).
    pub fn declareSchemeSecurity(self: Renderer, scheme: [*:0]const u8, traits: SchemeSecurityTraits) void {
        if (self.vtable.declareSchemeSecurity) |f| f(self.ptr, scheme, traits);
    }
};

// ---------------------------------------------------------------------------
// A fake `Renderer` for headless seam tests (no webview, no display).
// ---------------------------------------------------------------------------

/// A minimal in-memory `Renderer` used by the library's `zig build test` block
/// to prove the seam is drivable WITHOUT a webview or a display: it records the
/// last navigated URI, tracks a toy back/forward stack, and re-emits lifecycle
/// events to whatever callback the chrome registered. It lets us assert the
/// chrome<->renderer contract (navigate flips state, events reach the chrome)
/// headlessly; the REAL end-to-end proof (WebKitGTK renders a page) stays in
/// the `shell-test` build step under Xvfb.
pub const FakeRenderer = struct {
    history: std.ArrayListUnmanaged([]const u8) = .empty,
    index: isize = -1,
    gpa: std.mem.Allocator,
    cb: ?LifecycleCallback = null,
    /// A stable non-null token to hand back as the opaque view handle.
    view_token: u8 = 0,

    // --- script-message bridge state (for the seam-contract tests) ---
    /// The last user script injected via `injectUserScript` (owned copy).
    injected_script: ?[]const u8 = null,
    /// The single registered page->native channel, if any.
    msg_name: ?[]const u8 = null,
    msg_cb: ?ScriptMessageCallback = null,
    /// The last script `evaluateScript` was asked to run (owned copy). Stands in
    /// for "native posted a reply back into the page".
    last_evaluated: ?[]const u8 = null,

    // --- custom-scheme interception state ---
    /// The single registered custom scheme, if any.
    scheme_name: ?[]const u8 = null,
    scheme_handler: ?SchemeHandler = null,
    /// The security traits last declared for a scheme via
    /// `declareSchemeSecurity`, plus the scheme they were declared for (owned
    /// copy). Null until a declaration is made — so a test can assert the
    /// default (undeclared) state is distinguishable from an explicit all-false.
    declared_scheme: ?[]const u8 = null,
    declared_traits: ?SchemeSecurityTraits = null,

    pub fn init(gpa: std.mem.Allocator) FakeRenderer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *FakeRenderer) void {
        for (self.history.items) |u| self.gpa.free(u);
        self.history.deinit(self.gpa);
        if (self.injected_script) |s| self.gpa.free(s);
        if (self.msg_name) |s| self.gpa.free(s);
        if (self.last_evaluated) |s| self.gpa.free(s);
        if (self.scheme_name) |s| self.gpa.free(s);
        if (self.declared_scheme) |s| self.gpa.free(s);
    }

    // --- test-only simulation of the page side of the two hooks ---

    /// Simulate the page posting `body` on channel `name` (the page->native leg
    /// of the bridge). Delivers to the registered handler if the channel matches.
    pub fn firePageMessage(self: *FakeRenderer, name: []const u8, body: []const u8) void {
        if (self.msg_name) |registered| {
            if (std.mem.eql(u8, registered, name)) {
                if (self.msg_cb) |cb| cb.onMessage(cb.ctx, name, body);
            }
        }
    }

    /// Simulate a request for `uri` on the registered custom scheme, returning
    /// what native would serve (or null if no matching handler is registered).
    pub fn serveSchemeRequest(self: *FakeRenderer, uri: []const u8) ?SchemeResponse {
        if (self.scheme_handler) |h| return h.onRequest(h.ctx, uri);
        return null;
    }

    pub fn renderer(self: *FakeRenderer) Renderer {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = Renderer.VTable{
        .navigate = navigate,
        .reload = reload,
        .stop = stop,
        .goBack = goBack,
        .goForward = goForward,
        .canGoBack = canGoBack,
        .canGoForward = canGoForward,
        .view = view,
        .setViewportSize = setViewportSize,
        .setLifecycleCallback = setLifecycleCallback,
        .injectUserScript = injectUserScript,
        .setScriptMessageHandler = setScriptMessageHandler,
        .evaluateScript = evaluateScript,
        .registerScheme = registerScheme,
        .declareSchemeSecurity = declareSchemeSecurity,
    };

    fn emit(self: *FakeRenderer, event: LifecycleEvent) void {
        if (self.cb) |cb| cb.onEvent(cb.ctx, event);
    }

    fn navigate(ctx: *anyopaque, uri: [*:0]const u8) void {
        const self: *FakeRenderer = @ptrCast(@alignCast(ctx));
        const slice = std.mem.span(uri);
        const owned = self.gpa.dupe(u8, slice) catch return;
        // Truncate any forward entries, then push (browser history semantics).
        while (self.history.items.len > @as(usize, @intCast(self.index + 1))) {
            const dropped = self.history.pop().?;
            self.gpa.free(dropped);
        }
        self.history.append(self.gpa, owned) catch {
            self.gpa.free(owned);
            return;
        };
        self.index = @intCast(self.history.items.len - 1);
        self.emit(.{ .load_changed = .{ .state = .started, .uri = owned } });
        self.emit(.{ .uri_changed = owned });
        self.emit(.{ .load_changed = .{ .state = .committed, .uri = owned } });
        self.emit(.{ .load_changed = .{ .state = .finished, .uri = owned } });
    }

    fn reload(ctx: *anyopaque) void {
        const self: *FakeRenderer = @ptrCast(@alignCast(ctx));
        if (self.index < 0) return;
        const cur = self.history.items[@intCast(self.index)];
        self.emit(.{ .load_changed = .{ .state = .started, .uri = cur } });
        self.emit(.{ .load_changed = .{ .state = .finished, .uri = cur } });
    }

    fn stop(ctx: *anyopaque) void {
        _ = ctx;
    }

    fn goBack(ctx: *anyopaque) void {
        const self: *FakeRenderer = @ptrCast(@alignCast(ctx));
        if (self.index <= 0) return;
        self.index -= 1;
        const cur = self.history.items[@intCast(self.index)];
        self.emit(.{ .uri_changed = cur });
        self.emit(.{ .load_changed = .{ .state = .finished, .uri = cur } });
    }

    fn goForward(ctx: *anyopaque) void {
        const self: *FakeRenderer = @ptrCast(@alignCast(ctx));
        if (self.index + 1 >= @as(isize, @intCast(self.history.items.len))) return;
        self.index += 1;
        const cur = self.history.items[@intCast(self.index)];
        self.emit(.{ .uri_changed = cur });
        self.emit(.{ .load_changed = .{ .state = .finished, .uri = cur } });
    }

    fn canGoBack(ctx: *anyopaque) bool {
        const self: *FakeRenderer = @ptrCast(@alignCast(ctx));
        return self.index > 0;
    }

    fn canGoForward(ctx: *anyopaque) bool {
        const self: *FakeRenderer = @ptrCast(@alignCast(ctx));
        return self.index + 1 < @as(isize, @intCast(self.history.items.len));
    }

    fn view(ctx: *anyopaque) ViewHandle {
        const self: *FakeRenderer = @ptrCast(@alignCast(ctx));
        return &self.view_token;
    }

    fn setViewportSize(ctx: *anyopaque, width: c_int, height: c_int) void {
        _ = ctx;
        _ = width;
        _ = height;
    }

    fn setLifecycleCallback(ctx: *anyopaque, cb: LifecycleCallback) void {
        const self: *FakeRenderer = @ptrCast(@alignCast(ctx));
        self.cb = cb;
    }

    fn injectUserScript(ctx: *anyopaque, source: [*:0]const u8) void {
        const self: *FakeRenderer = @ptrCast(@alignCast(ctx));
        if (self.injected_script) |s| self.gpa.free(s);
        self.injected_script = self.gpa.dupe(u8, std.mem.span(source)) catch null;
    }

    fn setScriptMessageHandler(ctx: *anyopaque, name: [*:0]const u8, cb: ScriptMessageCallback) void {
        const self: *FakeRenderer = @ptrCast(@alignCast(ctx));
        if (self.msg_name) |s| self.gpa.free(s);
        self.msg_name = self.gpa.dupe(u8, std.mem.span(name)) catch null;
        self.msg_cb = cb;
    }

    fn evaluateScript(ctx: *anyopaque, source: [*:0]const u8) void {
        const self: *FakeRenderer = @ptrCast(@alignCast(ctx));
        if (self.last_evaluated) |s| self.gpa.free(s);
        self.last_evaluated = self.gpa.dupe(u8, std.mem.span(source)) catch null;
    }

    fn registerScheme(ctx: *anyopaque, scheme: [*:0]const u8, handler: SchemeHandler) void {
        const self: *FakeRenderer = @ptrCast(@alignCast(ctx));
        if (self.scheme_name) |s| self.gpa.free(s);
        self.scheme_name = self.gpa.dupe(u8, std.mem.span(scheme)) catch null;
        self.scheme_handler = handler;
    }

    fn declareSchemeSecurity(ctx: *anyopaque, scheme: [*:0]const u8, traits: SchemeSecurityTraits) void {
        const self: *FakeRenderer = @ptrCast(@alignCast(ctx));
        if (self.declared_scheme) |s| self.gpa.free(s);
        self.declared_scheme = self.gpa.dupe(u8, std.mem.span(scheme)) catch null;
        self.declared_traits = traits;
    }
};

test "FakeRenderer: navigate pushes history and drives back/forward" {
    var fr = FakeRenderer.init(std.testing.allocator);
    defer fr.deinit();
    const r = fr.renderer();

    try std.testing.expect(!r.canGoBack());
    try std.testing.expect(!r.canGoForward());

    r.navigate("https://a.example/");
    r.navigate("https://b.example/");
    try std.testing.expect(r.canGoBack());
    try std.testing.expect(!r.canGoForward());

    r.goBack();
    try std.testing.expect(!r.canGoBack());
    try std.testing.expect(r.canGoForward());

    // Navigating from a back position truncates the forward entry.
    r.navigate("https://c.example/");
    try std.testing.expect(!r.canGoForward());
    try std.testing.expectEqual(@as(usize, 2), fr.history.items.len);
}

test "FakeRenderer: lifecycle events reach a subscribed callback" {
    const Sink = struct {
        finished: usize = 0,
        last_uri: [64]u8 = undefined,
        last_uri_len: usize = 0,
        fn onEvent(ctx: *anyopaque, event: LifecycleEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            switch (event) {
                .load_changed => |lc| if (lc.state == .finished) {
                    self.finished += 1;
                },
                .uri_changed => |u| {
                    @memcpy(self.last_uri[0..u.len], u);
                    self.last_uri_len = u.len;
                },
                else => {},
            }
        }
    };

    var fr = FakeRenderer.init(std.testing.allocator);
    defer fr.deinit();
    const r = fr.renderer();

    var sink = Sink{};
    r.setLifecycleCallback(.{ .ctx = &sink, .onEvent = Sink.onEvent });

    r.navigate("https://page.example/");
    try std.testing.expect(sink.finished >= 1);
    try std.testing.expectEqualStrings("https://page.example/", sink.last_uri[0..sink.last_uri_len]);
}

test "Renderer seam: the script-message bridge round-trips a message both ways" {
    // The page->native leg: a page-world call posts a message; native receives
    // it. The native->page leg: native evaluates a reply script into the page.
    // This mirrors what `window.wezig.ping()` does over the real bridge, proven
    // here headlessly through the seam (no webview, no display).
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

    var fr = FakeRenderer.init(std.testing.allocator);
    defer fr.deinit();
    const r = fr.renderer();

    // native->page setup: inject the page-world object.
    r.injectUserScript(
        \\window.wezig = { ping: function(v) {
        \\  window.webkit.messageHandlers.wezig.postMessage(v);
        \\} };
    );
    try std.testing.expect(fr.injected_script != null);

    // page->native: register the channel and simulate the page posting to it.
    var native = Native{};
    r.setScriptMessageHandler("wezig", .{ .ctx = &native, .onMessage = Native.onMessage });
    fr.firePageMessage("wezig", "hello-from-page");
    try std.testing.expectEqualStrings("wezig", native.got_name[0..native.got_name_len]);
    try std.testing.expectEqualStrings("hello-from-page", native.got_body[0..native.got_body_len]);

    // native->page reply: native evaluates JS back into the page.
    r.evaluateScript("window.__wezig_reply = 'pong';");
    try std.testing.expect(fr.last_evaluated != null);
    try std.testing.expectEqualStrings("window.__wezig_reply = 'pong';", fr.last_evaluated.?);
}

test "Renderer seam: a registered custom scheme is served from native" {
    // Register `wezig-test://` and prove a request is served a native body +
    // content-type through the seam. Mirrors what `ipfs://` will do; proven here
    // headlessly (the real WebKitGTK scheme is proven under Xvfb).
    const Native = struct {
        fn onRequest(ctx: *anyopaque, uri: []const u8) SchemeResponse {
            _ = ctx;
            _ = uri;
            return .{ .body = "<h1>hello from native</h1>", .content_type = "text/html" };
        }
    };

    var fr = FakeRenderer.init(std.testing.allocator);
    defer fr.deinit();
    const r = fr.renderer();

    var native: u8 = 0;
    r.registerScheme("wezig-test", .{ .ctx = &native, .onRequest = Native.onRequest });
    try std.testing.expectEqualStrings("wezig-test", fr.scheme_name.?);

    const resp = fr.serveSchemeRequest("wezig-test://hello").?;
    try std.testing.expectEqualStrings("<h1>hello from native</h1>", resp.body);
    try std.testing.expectEqualStrings("text/html", resp.content_type);
}

test "Renderer seam: a scheme's security traits are DECLARED at the seam (ipfs:// as a secure origin)" {
    // The secure-origin seam extension (ADR-0015 decision 7): the backend
    // declares `ipfs://`'s security traits THROUGH the seam, so a `WezigRenderer`
    // reproduces them (not a one-off webview call). Proven headlessly here
    // against the fake backend; the real WebKitGTK `WebKitSecurityManager` wiring
    // is proven off the core gate under Xvfb.
    var fr = FakeRenderer.init(std.testing.allocator);
    defer fr.deinit();
    const r = fr.renderer();

    // Before any declaration, the fake has recorded no traits (an undeclared
    // scheme is an ordinary, non-secure origin — the default).
    try std.testing.expect(fr.declared_traits == null);

    r.declareSchemeSecurity("ipfs", .{ .secure = true, .cors = true });

    try std.testing.expectEqualStrings("ipfs", fr.declared_scheme.?);
    const traits = fr.declared_traits.?;
    try std.testing.expect(traits.secure);
    try std.testing.expect(traits.cors);
    try std.testing.expect(!traits.local);
}

test "Renderer seam: declareSchemeSecurity is a no-op on a backend that does not implement it" {
    // ADR-0016 decision 5: the seam expresses the declaration uniformly, but a
    // backend that cannot honour scheme security traits leaves the optional
    // vtable method null. The forwarder must then no-op (not crash), so callers
    // stay backend-agnostic. Build a minimal renderer whose vtable omits the
    // method and prove the forwarder is safe.
    const Inert = struct {
        fn navigate(_: *anyopaque, _: [*:0]const u8) void {}
        fn reload(_: *anyopaque) void {}
        fn stop(_: *anyopaque) void {}
        fn goBack(_: *anyopaque) void {}
        fn goForward(_: *anyopaque) void {}
        fn canGoBack(_: *anyopaque) bool {
            return false;
        }
        fn canGoForward(_: *anyopaque) bool {
            return false;
        }
        var token: u8 = 0;
        fn view(_: *anyopaque) ViewHandle {
            return &token;
        }
        fn setViewportSize(_: *anyopaque, _: c_int, _: c_int) void {}
        fn setLifecycleCallback(_: *anyopaque, _: LifecycleCallback) void {}
        fn injectUserScript(_: *anyopaque, _: [*:0]const u8) void {}
        fn setScriptMessageHandler(_: *anyopaque, _: [*:0]const u8, _: ScriptMessageCallback) void {}
        fn evaluateScript(_: *anyopaque, _: [*:0]const u8) void {}
        fn registerScheme(_: *anyopaque, _: [*:0]const u8, _: SchemeHandler) void {}
        const vtable = Renderer.VTable{
            .navigate = navigate,
            .reload = reload,
            .stop = stop,
            .goBack = goBack,
            .goForward = goForward,
            .canGoBack = canGoBack,
            .canGoForward = canGoForward,
            .view = view,
            .setViewportSize = setViewportSize,
            .setLifecycleCallback = setLifecycleCallback,
            .injectUserScript = injectUserScript,
            .setScriptMessageHandler = setScriptMessageHandler,
            .evaluateScript = evaluateScript,
            .registerScheme = registerScheme,
            // declareSchemeSecurity intentionally left at its null default.
        };
    };
    var ctx: u8 = 0;
    const r = Renderer{ .ptr = &ctx, .vtable = &Inert.vtable };
    // Must not crash: the forwarder skips the null method.
    r.declareSchemeSecurity("ipfs", .{ .secure = true });
}
