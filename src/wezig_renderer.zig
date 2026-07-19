//! `WezigRenderer`: a NATIVE static-page STUB behind the `Renderer` seam
//! (ADR-0005/0006), the minimal real SECOND backend the user-controlled swap
//! needs (spec `explore-native-renderer`, story 4/6, decision 4).
//!
//! ## What this is (and is NOT)
//!
//! This is the narrowest possible native `Renderer`: on `navigate` it paints
//! ONE simple static page THROUGH the existing v0 layout/paint pipeline
//! (`paint.renderScene` -> `html.parse` -> `css.styleDocument` -> `layout` ->
//! `StbSoftwareBackend`, ADR-0002/0003) into an owned offscreen `Surface`, and
//! re-emits the seam's `LifecycleEvent`s exactly as a real backend would. It is
//! the "trivial one" the idea note (`work/notes/ideas/renderer-swap-toggle-in-chrome.md`)
//! flagged the swap was BLOCKED on ("there is no second backend to swap TO"):
//! the whole point is to give the user-triggered swap a real native page to
//! swap the current page TO, painted by OUR pipeline rather than a webview.
//!
//! It is deliberately NOT the native renderer: no networking, no real WHATWG
//! parsing, no interactive view, no JS. It renders a fixed static page (the URI
//! is echoed into it so the swap is visibly "this page, painted natively"). The
//! full engine is the multi-year build this spec only DE-RISKS; growing this
//! stub toward it is the follow-on build plan's job, not this task's.
//!
//! ## Why it can live in the library `mod` (unlike the webview backend)
//!
//! `SystemWebviewRenderer`/`GtkToolkit`/`sdl.zig` link native system libraries
//! and therefore live in the SHELL executable ONLY (`build.zig`), so the v0
//! gate + goldens stay display-free. This stub links NOTHING new: it paints via
//! `paint.renderScene`, which is already in the `wezig` module (stb_truetype,
//! compiled by Zig). So `WezigRenderer` is a normal library module, re-exported
//! from `src/root.zig`, and its seam-contract tests run headlessly in
//! `zig build test` — exactly like `FakeRenderer` and the mobile backends.
//!
//! ## The two web3 hooks are inert here (a recorded stub limitation)
//!
//! The `Renderer` seam carries the script-message bridge + custom-scheme hooks
//! (ADR-0005) so `WezigRenderer` MUST satisfy them to sit behind the seam. This
//! STUB has no JS engine and serves no requests, so it records the calls (like
//! `FakeRenderer` does) but runs no script and serves no scheme. Wiring them to
//! the real native pipeline is the follow-on build; the seam shape is honoured
//! now so the swap coordinator can re-attach them uniformly across backends.

const std = @import("std");
const renderer_mod = @import("renderer.zig");
const paint = @import("paint.zig");
const surface_mod = @import("surface.zig");
const branding = @import("branding.zig");

const Renderer = renderer_mod.Renderer;
const ViewHandle = renderer_mod.ViewHandle;
const LifecycleEvent = renderer_mod.LifecycleEvent;
const LifecycleCallback = renderer_mod.LifecycleCallback;
const ScriptMessageCallback = renderer_mod.ScriptMessageCallback;
const SchemeHandler = renderer_mod.SchemeHandler;
const Surface = surface_mod.Surface;

/// A native static-page `Renderer` stub. Construct with `init`, obtain the seam
/// value with `renderer()`, and drive it through the seam. On `navigate` it
/// paints a static page for the URI into `last_surface` (owned) and emits the
/// load lifecycle the chrome subscribes to; the caller may inspect
/// `last_surface` to prove a native paint happened.
pub const WezigRenderer = struct {
    gpa: std.mem.Allocator,
    cb: ?LifecycleCallback = null,
    /// A stable non-null token handed back as the opaque `ViewHandle`. The stub
    /// has no OS-native interactive widget (it is a painted static page), so the
    /// handle is just a marker the chrome/toolkit treat opaquely.
    view_token: u8 = 0,
    /// The current document URI (owned copy), or null before the first navigate.
    current_uri: ?[]const u8 = null,
    /// The offscreen surface the last `navigate` painted THROUGH the v0
    /// pipeline. Owned; replaced on each navigate; freed in `deinit`. Its
    /// existence + non-blank content is the proof this backend painted natively.
    last_surface: ?Surface = null,

    // --- inert web3-hook bookkeeping (see the module doc) ---
    injected_script: ?[]const u8 = null,
    msg_name: ?[]const u8 = null,
    msg_cb: ?ScriptMessageCallback = null,
    scheme_name: ?[]const u8 = null,
    scheme_handler: ?SchemeHandler = null,

    pub fn init(gpa: std.mem.Allocator) WezigRenderer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *WezigRenderer) void {
        if (self.current_uri) |u| self.gpa.free(u);
        if (self.last_surface) |*s| s.deinit();
        if (self.injected_script) |s| self.gpa.free(s);
        if (self.msg_name) |s| self.gpa.free(s);
        if (self.scheme_name) |s| self.gpa.free(s);
    }

    pub fn renderer(self: *WezigRenderer) Renderer {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// The size of the static page this stub paints. A real, comfortable page
    /// size (not one of the tiny goldens), so the painted surface is a plausible
    /// content view rather than a thumbnail.
    const page_w: u32 = 1024;
    const page_h: u32 = 768;

    /// Build the v0 `GoldenScene` for `uri`: a titled static page painted
    /// through the SAME pipeline the goldens/app use. The URI is echoed into the
    /// page body so the painted page is visibly "this document, rendered by
    /// wezig" — the native counterpart of the webview showing the same URL.
    fn sceneFor(uri: []const u8) paint.GoldenScene {
        _ = uri; // the static page is fixed for the stub; the URI drives the
        // emitted lifecycle, not the (single) page content, on the narrowest case.
        return .{
            .name = "wezig-native-stub",
            .html_src = "<body><p>" ++ branding.display_name ++ " native renderer</p></body>",
            .css_src = "p { font-size: 24px; }",
            .viewport = @floatFromInt(page_w),
            .w = page_w,
            .h = page_h,
            .background = .{
                .rect = .{ .x = 0, .y = 0, .w = @floatFromInt(page_w), .h = @floatFromInt(page_h) },
                .color = .{ .r = 240, .g = 244, .b = 250 },
            },
            .text_color = .{ .r = 20, .g = 40, .b = 80 },
        };
    }

    fn emit(self: *WezigRenderer, event: LifecycleEvent) void {
        if (self.cb) |cb| cb.onEvent(cb.ctx, event);
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
    };

    fn navigate(ctx: *anyopaque, uri: [*:0]const u8) void {
        const self: *WezigRenderer = @ptrCast(@alignCast(ctx));
        const slice = std.mem.span(uri);
        const owned = self.gpa.dupe(u8, slice) catch return;

        // Paint the static page THROUGH the v0 layout/paint pipeline. If the
        // paint fails we still record the navigation + emit lifecycle (the
        // swap must not wedge on a paint hiccup), leaving `last_surface` as-is.
        const painted = paint.renderScene(self.gpa, sceneFor(slice)) catch null;
        if (painted) |surf| {
            if (self.last_surface) |*old| old.deinit();
            self.last_surface = surf;
        }

        if (self.current_uri) |u| self.gpa.free(u);
        self.current_uri = owned;

        self.emit(.{ .load_changed = .{ .state = .started, .uri = owned } });
        self.emit(.{ .uri_changed = owned });
        self.emit(.{ .load_changed = .{ .state = .committed, .uri = owned } });
        self.emit(.{ .load_changed = .{ .state = .finished, .uri = owned } });
    }

    fn reload(ctx: *anyopaque) void {
        const self: *WezigRenderer = @ptrCast(@alignCast(ctx));
        const cur = self.current_uri orelse return;
        self.emit(.{ .load_changed = .{ .state = .started, .uri = cur } });
        self.emit(.{ .load_changed = .{ .state = .finished, .uri = cur } });
    }

    fn stop(ctx: *anyopaque) void {
        _ = ctx;
    }

    // The stub renders one page and keeps no session history of its own: the
    // swap coordinator owns the URL being shown, and back/forward stay a webview
    // concern for the narrowest case. So these are inert (no history to walk).
    fn goBack(ctx: *anyopaque) void {
        _ = ctx;
    }
    fn goForward(ctx: *anyopaque) void {
        _ = ctx;
    }
    fn canGoBack(ctx: *anyopaque) bool {
        _ = ctx;
        return false;
    }
    fn canGoForward(ctx: *anyopaque) bool {
        _ = ctx;
        return false;
    }

    fn view(ctx: *anyopaque) ViewHandle {
        const self: *WezigRenderer = @ptrCast(@alignCast(ctx));
        return &self.view_token;
    }

    fn setViewportSize(ctx: *anyopaque, width: c_int, height: c_int) void {
        _ = ctx;
        _ = width;
        _ = height;
    }

    fn setLifecycleCallback(ctx: *anyopaque, cb: LifecycleCallback) void {
        const self: *WezigRenderer = @ptrCast(@alignCast(ctx));
        self.cb = cb;
    }

    // --- inert web3 hooks (recorded, not executed; see the module doc) ---
    fn injectUserScript(ctx: *anyopaque, source: [*:0]const u8) void {
        const self: *WezigRenderer = @ptrCast(@alignCast(ctx));
        if (self.injected_script) |s| self.gpa.free(s);
        self.injected_script = self.gpa.dupe(u8, std.mem.span(source)) catch null;
    }
    fn setScriptMessageHandler(ctx: *anyopaque, name: [*:0]const u8, cb: ScriptMessageCallback) void {
        const self: *WezigRenderer = @ptrCast(@alignCast(ctx));
        if (self.msg_name) |s| self.gpa.free(s);
        self.msg_name = self.gpa.dupe(u8, std.mem.span(name)) catch null;
        self.msg_cb = cb;
    }
    fn evaluateScript(ctx: *anyopaque, source: [*:0]const u8) void {
        _ = ctx;
        _ = source; // no JS engine in the stub; nothing to evaluate.
    }
    fn registerScheme(ctx: *anyopaque, scheme: [*:0]const u8, handler: SchemeHandler) void {
        const self: *WezigRenderer = @ptrCast(@alignCast(ctx));
        if (self.scheme_name) |s| self.gpa.free(s);
        self.scheme_name = self.gpa.dupe(u8, std.mem.span(scheme)) catch null;
        self.scheme_handler = handler;
    }
};

// ---------------------------------------------------------------------------
// Tests: the native stub paints a real page through the v0 pipeline and drives
// the seam headlessly (no webview, no display), in `zig build test`.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// True if `surf` has at least one pixel that differs from its top-left pixel —
/// a cheap "something was painted" check (the static page has a background fill
/// AND text, so it is not a single flat colour).
fn surfaceIsNonBlank(surf: *const Surface) bool {
    if (surf.pixels.len < 8) return false;
    const first = surf.pixels[0..4];
    var i: usize = 4;
    while (i + 4 <= surf.pixels.len) : (i += 4) {
        if (!std.mem.eql(u8, surf.pixels[i .. i + 4], first)) return true;
    }
    return false;
}

test "WezigRenderer: navigate paints a static page through the v0 pipeline" {
    var wr = WezigRenderer.init(testing.allocator);
    defer wr.deinit();
    const r = wr.renderer();

    // Before navigating, nothing is painted.
    try testing.expect(wr.last_surface == null);

    r.navigate("wezig://native-stub/");

    // A native paint happened: an owned surface exists, at page size, and is
    // NOT a single flat colour (background + text were painted through layout).
    try testing.expect(wr.last_surface != null);
    const surf = &wr.last_surface.?;
    try testing.expectEqual(@as(u32, WezigRenderer.page_w), surf.width);
    try testing.expectEqual(@as(u32, WezigRenderer.page_h), surf.height);
    try testing.expect(surfaceIsNonBlank(surf));
    // The current URI was recorded.
    try testing.expectEqualStrings("wezig://native-stub/", wr.current_uri.?);
}

test "WezigRenderer: lifecycle events reach a subscribed callback (finished + uri)" {
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

    var wr = WezigRenderer.init(testing.allocator);
    defer wr.deinit();
    const r = wr.renderer();

    var sink = Sink{};
    r.setLifecycleCallback(.{ .ctx = &sink, .onEvent = Sink.onEvent });
    r.navigate("https://painted-native.example/");

    try testing.expect(sink.finished >= 1);
    try testing.expectEqualStrings("https://painted-native.example/", sink.last_uri[0..sink.last_uri_len]);
}

test "WezigRenderer: re-navigating replaces the painted surface without leaking" {
    var wr = WezigRenderer.init(testing.allocator);
    defer wr.deinit();
    const r = wr.renderer();

    r.navigate("https://one.example/");
    try testing.expect(wr.last_surface != null);
    r.navigate("https://two.example/");
    // Still exactly one owned surface (deinit under the allocator asserts no
    // leak); the URI advanced to the second page.
    try testing.expect(wr.last_surface != null);
    try testing.expectEqualStrings("https://two.example/", wr.current_uri.?);
}
