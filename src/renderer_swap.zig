//! The USER-controlled renderer swap at the `Renderer` seam (ADR-0005/0006;
//! spec `explore-native-renderer`, story 4/6, decision 4). This is the
//! narrowest-case proof of the swap MECHANISM + its data model — NOT the
//! product chrome UX.
//!
//! ## The policy this encodes (decision 4, ADR-0011)
//!
//! The webview is the DEFAULT; the native `WezigRenderer` is used ONLY when the
//! user opts in — there is NO automatic mismatch routing anywhere. The user opts
//! in two ways, both here:
//!   - a MANUAL per-page trigger (`toggle`) — the long-press-reload gesture the
//!     shell recognises and turns into a `toggle` call; it swaps ONLY the current
//!     page, and toggling again (native -> webview) is the MANUAL fallback;
//!   - a per-domain user ALLOW-LIST (`DomainAllowList`) — domains the user has
//!     marked to ALWAYS render native, consulted on `navigate` to pick that
//!     domain's default engine. Everything not on the list defaults to webview.
//! This matches ADR-0011's "explicit, user-controlled trust boundaries" over
//! implicit browser magic, and the idea note
//! (`work/notes/ideas/renderer-swap-toggle-in-chrome.md`) that RESOLVED this as
//! the primary manual swap mechanism.
//!
//! ## Why this is a backend-VALUE swap, not a seam change (chrome_conformance)
//!
//! ADR-0005: "swapping WebKitGTK for `WezigRenderer` … is a change to which
//! backend VALUE is passed in, NOT a change to this file." `RendererSwap` holds
//! BOTH `Renderer` seam values and, on a swap, RE-POINTS which one is active,
//! RE-ATTACHES the chrome's single lifecycle callback to the newly-active
//! backend, and RE-NAVIGATES the current URL through it (the three steps ADR-0005
//! names). It talks ONLY to the `Renderer` seam — it never imports a webview/GTK
//! binding — so `chrome_conformance` is untouched: the swap is a value change at
//! the seam, not a widening of it. `src/chrome.zig` is likewise UNCHANGED: this
//! coordinator sits BESIDE the chrome for the spike, so a spike need not reshape
//! the pinned `ChromeIntent` set for one gesture (recorded as a decision below).
//!
//! ## DECISION: a coordinator BESIDE the chrome, not a new `ChromeIntent`
//!
//! CHOICE: model the manual swap as `RendererSwap.toggle()` (a coordinator the
//! shell's long-press gesture calls) rather than adding a `swap_engine` variant
//! to the pinned `ChromeIntent` union (`src/toolkit.zig`).
//! WHY: `ChromeIntent` is documented as "a closed set: a URL-bar chrome has
//! exactly these controls", and it is a PINNED seam (ADR-0006) shared by desktop
//! (`chrome.zig`, guarded by `chrome_conformance`), mobile (`mobile_chrome.zig`),
//! and every toolkit backend. Adding a variant for a NARROWEST-CASE spike would
//! widen a pinned interface and force every `ChromeIntent` switch (and the
//! conformance guard's blast radius) to grow for one gesture — exactly the
//! speculative seam growth ADR-0006 rejected ("does not grow speculative methods
//! with no implementation"). Keeping the swap in a beside-the-chrome coordinator
//! proves the mechanism without touching the pinned set.
//! TOUCHES: nothing else — `toolkit.zig`/`chrome.zig`/`mobile_chrome.zig` are
//! unchanged. ALTERNATIVE CONSIDERED: a `swap_engine` `ChromeIntent` wired
//! through the chrome; rejected as above (widens a pinned seam for a spike). When
//! the swap graduates from spike to product chrome UX, promoting the gesture to a
//! first-class intent is the deliberate follow-on that can pay that cost.

const std = @import("std");
const renderer_mod = @import("renderer.zig");

const Renderer = renderer_mod.Renderer;
const LifecycleCallback = renderer_mod.LifecycleCallback;

/// Which engine painted the current page — the vocabulary the visible engine
/// INDICATOR shows ("webview" vs "wezig"). `webview` is the default backend
/// (`SystemWebviewRenderer`); `wezig` is the native `WezigRenderer`.
pub const EngineKind = enum {
    webview,
    wezig,

    /// The short human label the engine indicator displays. Stable, lowercase,
    /// matching the idea note's "webview" vs "wezig" wording.
    pub fn label(self: EngineKind) []const u8 {
        return switch (self) {
            .webview => "webview",
            .wezig => "wezig",
        };
    }

    /// The other engine — what a manual `toggle` flips TO.
    pub fn other(self: EngineKind) EngineKind {
        return switch (self) {
            .webview => .wezig,
            .wezig => .webview,
        };
    }
};

/// Extract the DOMAIN (host) the allow-list keys on from a URL, WITHOUT a URL
/// parser dependency (v0 has none): take the authority between `://` and the
/// next `/`, `?`, or `#`, and drop any `user@` and `:port`. Returns null when
/// there is no `://` authority (e.g. a bare path), so such URLs simply never
/// match the allow-list. Lowercased-compare is the caller's job (`contains`).
pub fn domainOf(url: []const u8) ?[]const u8 {
    const scheme_sep = std.mem.indexOf(u8, url, "://") orelse return null;
    var authority = url[scheme_sep + 3 ..];
    // Cut at the first path/query/fragment delimiter.
    const end = std.mem.indexOfAny(u8, authority, "/?#") orelse authority.len;
    authority = authority[0..end];
    // Drop userinfo (`user:pass@host`).
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| {
        authority = authority[at + 1 ..];
    }
    // Drop the port (`host:port`). IPv6 literals are out of scope for the spike.
    if (std.mem.indexOfScalar(u8, authority, ':')) |colon| {
        authority = authority[0..colon];
    }
    if (authority.len == 0) return null;
    return authority;
}

/// The per-domain-allow DATA MODEL: a persistent, user-controlled set of domains
/// that ALWAYS render natively (decision 4). This is the SCHEMA (how the list is
/// stored) plus HOW the swap consults it (`engineFor`); there is deliberately NO
/// automatic routing — the list only ever holds domains the USER added, and a
/// domain that is not on it defaults to the webview.
///
/// ## Schema (on-disk format)
///
/// A plain UTF-8 text file, ONE domain per line, `\n`-separated. Blank lines and
/// lines beginning with `#` (comments) are ignored on load. Domains are stored
/// and compared LOWERCASE (hosts are case-insensitive). This trivially-diffable,
/// human-editable format is deliberate for a spike: the persistence mechanism is
/// what is being proven, not a binary/DB schema.
pub const DomainAllowList = struct {
    gpa: std.mem.Allocator,
    /// The set of allowed domains (owned, lowercased keys).
    domains: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(gpa: std.mem.Allocator) DomainAllowList {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *DomainAllowList) void {
        var it = self.domains.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.domains.deinit(self.gpa);
    }

    /// Lowercase `domain` into a fresh owned buffer (hosts compare case-insensitively).
    fn lowerDup(gpa: std.mem.Allocator, domain: []const u8) ![]u8 {
        const out = try gpa.alloc(u8, domain.len);
        for (domain, 0..) |ch, i| out[i] = std.ascii.toLower(ch);
        return out;
    }

    /// Mark `domain` to always render native. Idempotent (adding an existing
    /// domain is a no-op). The user gesture behind this is out of scope for the
    /// spike; the model + persistence are what is proven.
    pub fn add(self: *DomainAllowList, domain: []const u8) !void {
        const key = try lowerDup(self.gpa, domain);
        const gop = try self.domains.getOrPut(self.gpa, key);
        if (gop.found_existing) {
            self.gpa.free(key); // already present; drop the dup.
        }
    }

    /// Remove `domain` from the allow-list (so it reverts to the webview
    /// default). A no-op if it was not present.
    pub fn remove(self: *DomainAllowList, domain: []const u8) void {
        var buf: [253]u8 = undefined; // max DNS name length; longer never matches.
        if (domain.len > buf.len) return;
        for (domain, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
        const key = buf[0..domain.len];
        if (self.domains.fetchRemove(key)) |kv| self.gpa.free(kv.key);
    }

    /// Whether `domain` is on the allow-list (case-insensitive).
    pub fn contains(self: *const DomainAllowList, domain: []const u8) bool {
        var buf: [253]u8 = undefined;
        if (domain.len > buf.len) return false;
        for (domain, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
        return self.domains.contains(buf[0..domain.len]);
    }

    /// The engine `url` should DEFAULT to: `wezig` iff its domain is on the
    /// allow-list, else `webview`. This is HOW the swap consults the model on a
    /// fresh navigation. A URL with no parseable domain defaults to `webview`
    /// (never native) — there is no automatic routing.
    pub fn engineFor(self: *const DomainAllowList, url: []const u8) EngineKind {
        const domain = domainOf(url) orelse return .webview;
        return if (self.contains(domain)) .wezig else .webview;
    }

    /// Serialise the allow-list to `writer` in the on-disk schema (one lowercase
    /// domain per line). Order is unspecified (a set), which is fine for the
    /// format. The caller owns flushing/closing the sink.
    pub fn writeTo(self: *const DomainAllowList, writer: *std.Io.Writer) !void {
        var it = self.domains.keyIterator();
        while (it.next()) |k| {
            try writer.writeAll(k.*);
            try writer.writeByte('\n');
        }
    }

    /// Persist the allow-list to `path` (relative to cwd) in the schema above.
    /// TESTS point this at a temp dir so the real user list is never touched.
    pub fn saveToFile(self: *const DomainAllowList, io: std.Io, path: []const u8) !void {
        var buf: std.Io.Writer.Allocating = .init(self.gpa);
        defer buf.deinit();
        try self.writeTo(&buf.writer);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = buf.written() });
    }

    /// Populate the allow-list from `text` in the schema (one domain per line;
    /// blanks + `#` comments ignored). Additive: existing entries are kept.
    pub fn loadFromText(self: *DomainAllowList, text: []const u8) !void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            try self.add(line);
        }
    }

    /// Load the allow-list from `path` (relative to cwd). A MISSING file is NOT
    /// an error — an empty list (everything defaults to webview) is the correct
    /// first-run state, so a fresh user has no persisted preferences yet.
    pub fn loadFromFile(self: *DomainAllowList, io: std.Io, path: []const u8) !void {
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, self.gpa, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.gpa.free(text);
        try self.loadFromText(text);
    }
};

/// The swap coordinator: holds BOTH `Renderer` seam values and the current
/// engine, and performs the three-step swap (re-point + re-attach + re-navigate)
/// ADR-0005 names. The chrome (or the spike's shell) drives it: subscribe once
/// with `attach`, `navigate` to load a URL through the domain's default engine,
/// and `toggle` on the long-press gesture to force the current page to the other
/// engine (and back).
///
/// It owns NEITHER backend (the caller constructs `WezigRenderer` +
/// `SystemWebviewRenderer`/`FakeRenderer` and hands their seam VALUES in), and it
/// keeps the chrome's single lifecycle callback so it can RE-ATTACH it to the
/// newly-active backend on every swap.
pub const RendererSwap = struct {
    webview: Renderer,
    wezig: Renderer,
    allow: *const DomainAllowList,
    /// Which backend is active NOW (the engine indicator reads this).
    current: EngineKind = .webview,
    /// The chrome's single lifecycle sink, re-attached to the active backend on
    /// each swap. Null until `attach`.
    cb: ?LifecycleCallback = null,
    /// The current document URL (owned, NUL-terminated copy), so `toggle` can
    /// re-navigate it through the other backend. Null before the first `navigate`.
    current_url: ?[:0]const u8 = null,
    gpa: std.mem.Allocator,

    pub fn init(
        gpa: std.mem.Allocator,
        webview: Renderer,
        wezig: Renderer,
        allow: *const DomainAllowList,
    ) RendererSwap {
        return .{ .gpa = gpa, .webview = webview, .wezig = wezig, .allow = allow };
    }

    pub fn deinit(self: *RendererSwap) void {
        if (self.current_url) |u| self.gpa.free(u);
    }

    /// The currently-active `Renderer` seam value (the one the chrome's calls go
    /// to). This is what "re-pointing the single `Renderer` value" resolves to.
    pub fn active(self: *const RendererSwap) Renderer {
        return switch (self.current) {
            .webview => self.webview,
            .wezig => self.wezig,
        };
    }

    /// The label the visible engine INDICATOR shows for the active engine.
    pub fn engineLabel(self: *const RendererSwap) []const u8 {
        return self.current.label();
    }

    /// Subscribe the chrome's single lifecycle callback. Stored so it can be
    /// RE-ATTACHED to whichever backend becomes active after a swap; wired to the
    /// currently-active backend immediately.
    pub fn attach(self: *RendererSwap, cb: LifecycleCallback) void {
        self.cb = cb;
        self.active().setLifecycleCallback(cb);
    }

    /// Navigate to `url`, choosing the engine the per-domain-allow model says
    /// this domain DEFAULTS to (native iff allow-listed, else webview). This is
    /// the ONLY place the allow-list drives an automatic-looking choice — and it
    /// is not automatic ROUTING: it reflects a preference the USER set. If the
    /// chosen engine differs from the active one, the backend is re-pointed +
    /// the callback re-attached first, then the URL is navigated.
    pub fn navigate(self: *RendererSwap, url: [:0]const u8) void {
        const want = self.allow.engineFor(url);
        if (want != self.current) self.repoint(want);
        self.setCurrentUrl(url);
        self.active().navigate(url);
    }

    /// The MANUAL per-page trigger (the long-press-reload gesture): flip the
    /// current page to the OTHER engine and re-render it there. Re-points the
    /// active backend, re-attaches the lifecycle callback, and re-navigates the
    /// current URL — the three ADR-0005 steps. A no-op if nothing is loaded yet
    /// (there is no current page to swap). Toggling native -> webview is the
    /// MANUAL fallback; there is no automatic fallback.
    pub fn toggle(self: *RendererSwap) void {
        const url = self.current_url orelse return;
        self.repoint(self.current.other());
        // `current_url` is an owned NUL-terminated copy; re-navigate it through
        // the now-active backend.
        self.active().navigate(url);
    }

    /// Re-point the active backend to `kind` and RE-ATTACH the chrome's single
    /// lifecycle callback to it (so events keep reaching the chrome after the
    /// swap). Does NOT navigate — callers pair this with a navigate.
    fn repoint(self: *RendererSwap, kind: EngineKind) void {
        self.current = kind;
        if (self.cb) |cb| self.active().setLifecycleCallback(cb);
    }

    /// Replace the owned current-URL copy with a NUL-terminated dup of `url`.
    fn setCurrentUrl(self: *RendererSwap, url: []const u8) void {
        const owned = self.gpa.dupeZ(u8, url) catch return;
        if (self.current_url) |old| self.gpa.free(old);
        self.current_url = owned;
    }
};

// ---------------------------------------------------------------------------
// Tests: the swap mechanism + the allow-list model, headlessly (no webview, no
// display), in `zig build test`. The two backends are `FakeRenderer`s so we can
// assert which one received a navigate; a real end-to-end swap onto the native
// `WezigRenderer` is covered by `wezig_renderer.zig`'s paint test.
// ---------------------------------------------------------------------------

const testing = std.testing;
const FakeRenderer = renderer_mod.FakeRenderer;

test "domainOf extracts the host from assorted URLs (no automatic anything)" {
    try testing.expectEqualStrings("example.com", domainOf("https://example.com/path?q=1#h").?);
    try testing.expectEqualStrings("example.com", domainOf("https://example.com").?);
    try testing.expectEqualStrings("host.example", domainOf("https://user:pass@host.example:8443/x").?);
    try testing.expectEqualStrings("app.local", domainOf("http://app.local").?);
    // No authority -> no domain (defaults to webview downstream).
    try testing.expect(domainOf("about:blank") == null);
    try testing.expect(domainOf("/just/a/path") == null);
}

test "DomainAllowList: add/contains/remove are case-insensitive and idempotent" {
    var list = DomainAllowList.init(testing.allocator);
    defer list.deinit();

    try testing.expect(!list.contains("Example.com"));
    try list.add("Example.COM");
    try testing.expect(list.contains("example.com"));
    try testing.expect(list.contains("EXAMPLE.COM"));
    // Idempotent: adding again does not leak or duplicate.
    try list.add("example.com");
    try testing.expectEqual(@as(u32, 1), list.domains.count());

    list.remove("EXAMPLE.com");
    try testing.expect(!list.contains("example.com"));
    // Removing a missing domain is a no-op.
    list.remove("never-there.example");
}

test "DomainAllowList.engineFor: allow-listed domains default native, else webview" {
    var list = DomainAllowList.init(testing.allocator);
    defer list.deinit();
    try list.add("native.example");

    try testing.expectEqual(EngineKind.wezig, list.engineFor("https://native.example/page"));
    try testing.expectEqual(EngineKind.wezig, list.engineFor("https://NATIVE.example/other"));
    try testing.expectEqual(EngineKind.webview, list.engineFor("https://other.example/"));
    // No parseable domain -> webview (never routed native automatically).
    try testing.expectEqual(EngineKind.webview, list.engineFor("about:blank"));
}

test "DomainAllowList persists to a TEMP dir and round-trips, real list untouched" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // A path INSIDE the temp dir, cwd-relative (`.zig-cache/tmp/<sub>/allow.txt`),
    // isolated from any real user allow-list — the real one is never touched.
    var full_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_path = try std.fmt.bufPrint(&full_buf, ".zig-cache/tmp/{s}/allow.txt", .{tmp.sub_path});

    const io = testing.io;

    // Save a list with two domains + prove a comment/blank line round-trips.
    {
        var list = DomainAllowList.init(testing.allocator);
        defer list.deinit();
        try list.add("a.example");
        try list.add("b.example");
        try list.saveToFile(io, file_path);
    }

    // Load it back into a fresh list: both domains present, nothing else.
    {
        var loaded = DomainAllowList.init(testing.allocator);
        defer loaded.deinit();
        try loaded.loadFromFile(io, file_path);
        try testing.expect(loaded.contains("a.example"));
        try testing.expect(loaded.contains("b.example"));
        try testing.expect(!loaded.contains("c.example"));
        try testing.expectEqual(@as(u32, 2), loaded.domains.count());
    }

    // Loading a MISSING file is not an error (fresh-user empty state).
    {
        var fresh = DomainAllowList.init(testing.allocator);
        defer fresh.deinit();
        try fresh.loadFromFile(io, "definitely-not-a-real-file-xyz.txt");
        try testing.expectEqual(@as(u32, 0), fresh.domains.count());
    }
}

test "loadFromText ignores blank lines and # comments" {
    var list = DomainAllowList.init(testing.allocator);
    defer list.deinit();
    try list.loadFromText(
        \\# my native sites
        \\a.example
        \\
        \\   b.example
        \\# trailing comment
    );
    try testing.expect(list.contains("a.example"));
    try testing.expect(list.contains("b.example"));
    try testing.expectEqual(@as(u32, 2), list.domains.count());
}

test "RendererSwap: default is webview; the manual toggle swaps the current page and back" {
    var wv = FakeRenderer.init(testing.allocator);
    defer wv.deinit();
    var wz = FakeRenderer.init(testing.allocator);
    defer wz.deinit();
    var allow = DomainAllowList.init(testing.allocator);
    defer allow.deinit();

    var swap = RendererSwap.init(testing.allocator, wv.renderer(), wz.renderer(), &allow);
    defer swap.deinit();

    // Default engine is the webview; the indicator says so.
    try testing.expectEqual(EngineKind.webview, swap.current);
    try testing.expectEqualStrings("webview", swap.engineLabel());

    swap.navigate("https://plain.example/");
    // The webview backend got the page; the native one did NOT.
    try testing.expectEqual(@as(usize, 1), wv.history.items.len);
    try testing.expectEqual(@as(usize, 0), wz.history.items.len);

    // MANUAL trigger: swap the current page to native.
    swap.toggle();
    try testing.expectEqual(EngineKind.wezig, swap.current);
    try testing.expectEqualStrings("wezig", swap.engineLabel());
    // The SAME url was re-navigated through the native backend.
    try testing.expectEqual(@as(usize, 1), wz.history.items.len);
    try testing.expectEqualStrings("https://plain.example/", wz.history.items[0]);

    // MANUAL fallback: toggling again returns to the webview (no auto-fallback).
    swap.toggle();
    try testing.expectEqual(EngineKind.webview, swap.current);
    try testing.expectEqual(@as(usize, 2), wv.history.items.len);
}

test "RendererSwap: an allow-listed domain navigates native by default; others webview" {
    var wv = FakeRenderer.init(testing.allocator);
    defer wv.deinit();
    var wz = FakeRenderer.init(testing.allocator);
    defer wz.deinit();
    var allow = DomainAllowList.init(testing.allocator);
    defer allow.deinit();
    try allow.add("native.example");

    var swap = RendererSwap.init(testing.allocator, wv.renderer(), wz.renderer(), &allow);
    defer swap.deinit();

    // A non-listed domain: webview (the default).
    swap.navigate("https://plain.example/");
    try testing.expectEqual(EngineKind.webview, swap.current);
    try testing.expectEqual(@as(usize, 1), wv.history.items.len);

    // An allow-listed domain: native, BY the user's persisted preference.
    swap.navigate("https://native.example/app");
    try testing.expectEqual(EngineKind.wezig, swap.current);
    try testing.expectEqual(@as(usize, 1), wz.history.items.len);
    try testing.expectEqualStrings("https://native.example/app", wz.history.items[0]);
}

test "RendererSwap: lifecycle callback is re-attached to the active backend after a swap" {
    const Sink = struct {
        finished: usize = 0,
        fn onEvent(ctx: *anyopaque, event: renderer_mod.LifecycleEvent) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (event == .load_changed and event.load_changed.state == .finished) self.finished += 1;
        }
    };

    var wv = FakeRenderer.init(testing.allocator);
    defer wv.deinit();
    var wz = FakeRenderer.init(testing.allocator);
    defer wz.deinit();
    var allow = DomainAllowList.init(testing.allocator);
    defer allow.deinit();

    var swap = RendererSwap.init(testing.allocator, wv.renderer(), wz.renderer(), &allow);
    defer swap.deinit();

    var sink = Sink{};
    swap.attach(.{ .ctx = &sink, .onEvent = Sink.onEvent });

    swap.navigate("https://page.example/");
    const after_first = sink.finished;
    try testing.expect(after_first >= 1);

    // After the swap the callback must STILL receive finished events — proving
    // it was re-attached to the now-active (native) backend, not left on the old.
    swap.toggle();
    try testing.expect(sink.finished > after_first);
}

test "RendererSwap: toggle before any navigate is a no-op (no current page)" {
    var wv = FakeRenderer.init(testing.allocator);
    defer wv.deinit();
    var wz = FakeRenderer.init(testing.allocator);
    defer wz.deinit();
    var allow = DomainAllowList.init(testing.allocator);
    defer allow.deinit();

    var swap = RendererSwap.init(testing.allocator, wv.renderer(), wz.renderer(), &allow);
    defer swap.deinit();

    swap.toggle();
    // Nothing loaded, nothing swapped: still the default webview, no navigations.
    try testing.expectEqual(EngineKind.webview, swap.current);
    try testing.expectEqual(@as(usize, 0), wv.history.items.len);
    try testing.expectEqual(@as(usize, 0), wz.history.items.len);
}
