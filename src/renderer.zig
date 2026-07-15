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
//! ## Deliberately NOT here yet (next task)
//!
//! The script-message bridge (inject a page-world provider, receive `request`
//! calls) and the request-interception / custom-scheme hook (`ipfs://`, wallet
//! RPC) are what `explore-web3-capabilities` depends on. ADR-0005 pins them to
//! the seam, but they are a SEPARATE task; this task starts the interface
//! MINIMAL and proves it, so they are intentionally absent here.

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

    pub fn init(gpa: std.mem.Allocator) FakeRenderer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *FakeRenderer) void {
        for (self.history.items) |u| self.gpa.free(u);
        self.history.deinit(self.gpa);
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
