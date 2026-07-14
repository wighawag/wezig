//! The v0 layout engine: turn the styled DOM (computed styles from the CSS
//! cascade) into a BOX TREE with real positions and sizes. This is a thin,
//! deliberately-throwaway v0 layout (block flow + inline flow with
//! line-breaking + the full box model), placed behind the `PaintBackend` seam
//! so a mature engine can replace it later without caller changes (see
//! `docs/adr/0001-...` and `docs/adr/0002-...`).
//!
//! ## What v0 does
//!
//!   - BLOCK FLOW: block-level boxes stack vertically, each filling its
//!     containing block's content width (unless `width` says otherwise).
//!   - INLINE FLOW: text and inline boxes flow into LINE BOXES and wrap at the
//!     containing block's content width. Wrapping needs text measurement, which
//!     is the reason the `PaintBackend` seam is introduced HERE.
//!   - BOX MODEL: content / padding / border / margin are all honoured, plus
//!     `width` and `height`.
//!   - UNITS: `px` and `%` (percentages resolve against the containing block;
//!     `%` is honoured for `width` only in v0). Any other unit
//!     (`em`/`rem`/`vw`/`vh`/`ch`/…) emits `unsupported_unit` and falls back:
//!     a length falls back to `auto`/`0`, and a `font-size` falls back to the
//!     16px default. The `unsupported_unit` contract is UNIFORM across both
//!     length and font-size resolution.
//!
//! ## Documented v0 limits (each surfaced via a diagnostic or the limits doc)
//!
//!   - NO margin collapsing (adjacent vertical margins simply add).
//!   - NO floats / `clear`.
//!   - `position: static` only (no relative/absolute/fixed/sticky).
//!   - NO flex / grid / table.
//!   - NO `overflow` scrolling (content is not clipped or scrolled).
//!
//! ## The `PaintBackend` seam (the load-bearing design; ADR-0002)
//!
//! `PaintBackend` is the ONE interface the paint stack lives behind. It is a
//! vtable (a `*anyopaque` context + a function-pointer table, like
//! `std.mem.Allocator`) so a headless STUB backend (this task, for tests) and
//! the real SDL3 + stb_truetype backend (the next task) BOTH satisfy it, and a
//! later Skia/HarfBuzz/FreeType backend satisfies it unchanged.
//!
//! The full method set is DECLARED now so the next task implements it without
//! reshaping the interface:
//!   - `measureRun`: how wide/tall is this text run? (EXERCISED by layout for
//!     line-breaking; the only method layout calls.)
//!   - `drawRun`, `fillRect`, `drawBorder`, `beginFrame`, `present`: the
//!     drawing side, implemented by the paint task. Declared here so both
//!     backends satisfy one interface.
//!
//! RUN / FONT CONTRACT (pinned here; the paint task and future backends depend
//! on it): a `TextRun` crossing the seam carries its RESOLVED `Font`
//! (family / size / weight) taken from the cascade's computed styles. Shaping
//! and measurement live entirely BELOW the seam: the backend owns them and
//! never re-resolves font properties upward. This is what makes "shaped text" a
//! clean backend responsibility.
//!
//! ## Testing seam
//!
//! Test at the LAYOUT seam: given HTML + CSS fixtures, assert the box tree's
//! positions/sizes and the collected diagnostic codes, driving measurement
//! through a headless stub backend. Do NOT assert on internal layout structures.

const std = @import("std");
const diagnostics = @import("diagnostics.zig");
const html = @import("html.zig");
const css = @import("css.zig");

const Diagnostics = diagnostics.Diagnostics;
const Node = html.Node;
const ComputedStyle = css.ComputedStyle;
const StyledDocument = css.StyledDocument;
const Property = css.Property;

// ---------------------------------------------------------------------------
// The PaintBackend seam (ADR-0002).
// ---------------------------------------------------------------------------

/// A resolved font for a text run, taken from the cascade's computed styles.
/// This is the whole font contract the backend needs to shape + measure a run;
/// layout never re-resolves font properties below this point.
pub const Font = struct {
    /// The `font-family` computed value (a raw family string in v0; the backend
    /// maps it to a concrete face).
    family: []const u8,
    /// The font size in CSS pixels (already resolved from `font-size`).
    size_px: f32,
    /// The `font-weight` computed value (e.g. `normal` / `bold` / a numeric
    /// string); the backend picks the matching face.
    weight: []const u8,
};

/// One shaped-text unit crossing the paint seam: the text bytes plus the
/// resolved `Font` they are set in. Both `measureRun` and (later) `drawRun`
/// receive a `TextRun`, so the backend has everything to shape/measure/draw
/// with no upward font re-resolution.
pub const TextRun = struct {
    text: []const u8,
    font: Font,
};

/// The metrics a backend returns for a measured run. Widths/heights are in CSS
/// pixels. `ascent`/`descent` position the run's glyphs around the line
/// baseline (`ascent` above, `descent` below); `width` advances the pen.
pub const RunMetrics = struct {
    width: f32,
    ascent: f32,
    descent: f32,

    /// The run's total line height contribution (ascent + descent).
    pub fn height(self: RunMetrics) f32 {
        return self.ascent + self.descent;
    }
};

/// A solid RGBA colour a backend fills with. Carried as bytes so the seam is
/// backend-agnostic (SDL, Skia, … all accept 8-bit channels).
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,
};

/// An axis-aligned rectangle in device pixels (CSS px at 1x in v0). `x`/`y` are
/// the top-left corner.
pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

/// The single interface the paint stack lives behind (ADR-0002). A vtable: a
/// `*anyopaque` context plus a function-pointer table, so a stub backend (this
/// task) and the real SDL3/stb backend (next task) both satisfy it, and a later
/// Skia/HarfBuzz/FreeType backend satisfies it unchanged.
///
/// Layout only calls `measureRun`. The drawing methods are declared so the
/// paint task implements the SAME interface without reshaping it; a backend
/// that does not draw (the measurement stub) may leave them `null`.
pub const PaintBackend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Measure a run (width + vertical metrics). REQUIRED: layout drives
        /// line-breaking through this. Shaping/measurement live in the backend.
        measureRun: *const fn (ctx: *anyopaque, run: TextRun) RunMetrics,

        /// Draw a shaped run at a baseline origin. Implemented by the paint
        /// task; the measurement stub leaves it `null`.
        drawRun: ?*const fn (ctx: *anyopaque, run: TextRun, x: f32, baseline_y: f32, color: Color) void = null,
        /// Fill a rectangle with a solid colour (backgrounds).
        fillRect: ?*const fn (ctx: *anyopaque, rect: Rect, color: Color) void = null,
        /// Stroke a border rectangle of the given per-side widths and colour.
        drawBorder: ?*const fn (ctx: *anyopaque, rect: Rect, widths: Edges, color: Color) void = null,
        /// Begin a frame (clear/prepare the target surface).
        beginFrame: ?*const fn (ctx: *anyopaque) void = null,
        /// Present the frame (swap/flush to the window or offscreen surface).
        present: ?*const fn (ctx: *anyopaque) void = null,
    };

    /// Measure a text run. The one method layout uses.
    pub fn measureRun(self: PaintBackend, run: TextRun) RunMetrics {
        return self.vtable.measureRun(self.ptr, run);
    }
};

/// A stub `PaintBackend` for tests (and any headless measurement path): it
/// measures text with a fixed per-character advance and a fixed ascent/descent
/// proportion of the font size, so line-breaking is DETERMINISTIC without a real
/// font. No drawing methods are wired (they are the paint task's job).
///
/// The advance model is intentionally simple and documented so fixtures can
/// predict wrap points: every byte advances `advance_ratio * size_px`, ascent
/// is `ascent_ratio * size_px`, descent is `descent_ratio * size_px`.
pub const StubBackend = struct {
    advance_ratio: f32 = 0.5,
    ascent_ratio: f32 = 0.8,
    descent_ratio: f32 = 0.2,

    pub fn backend(self: *StubBackend) PaintBackend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = PaintBackend.VTable{ .measureRun = measureRun };

    fn measureRun(ctx: *anyopaque, run: TextRun) RunMetrics {
        const self: *StubBackend = @ptrCast(@alignCast(ctx));
        const n: f32 = @floatFromInt(run.text.len);
        return .{
            .width = n * self.advance_ratio * run.font.size_px,
            .ascent = self.ascent_ratio * run.font.size_px,
            .descent = self.descent_ratio * run.font.size_px,
        };
    }
};

// ---------------------------------------------------------------------------
// The box tree (the OUTPUT seam consumers test against).
// ---------------------------------------------------------------------------

/// Per-side lengths (the box model's four edges). Used for padding, border, and
/// margin widths.
pub const Edges = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,

    pub fn horizontal(self: Edges) f32 {
        return self.left + self.right;
    }
    pub fn vertical(self: Edges) f32 {
        return self.top + self.bottom;
    }
};

/// A box's geometry after layout, in the CSS box model. `(x, y)` is the
/// top-left of the CONTENT area (the border-box origin is `(x - padding.left -
/// border.left, …)`); `width`/`height` are the CONTENT box size. `padding`,
/// `border`, and `margin` are the resolved edge widths.
pub const Dimensions = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    padding: Edges = .{},
    border: Edges = .{},
    margin: Edges = .{},

    /// The content-box rectangle.
    pub fn contentRect(self: Dimensions) Rect {
        return .{ .x = self.x, .y = self.y, .w = self.width, .h = self.height };
    }

    /// The border-box rectangle (content + padding + border), the rect a
    /// background/border paints.
    pub fn borderRect(self: Dimensions) Rect {
        return .{
            .x = self.x - self.padding.left - self.border.left,
            .y = self.y - self.padding.top - self.border.top,
            .w = self.width + self.padding.horizontal() + self.border.horizontal(),
            .h = self.height + self.padding.vertical() + self.border.vertical(),
        };
    }

    /// The margin-box outer height (border box + vertical margins): the
    /// vertical space this box consumes in its block container's flow.
    pub fn marginBoxHeight(self: Dimensions) f32 {
        return self.height + self.padding.vertical() + self.border.vertical() + self.margin.vertical();
    }

    /// The margin-box outer width.
    pub fn marginBoxWidth(self: Dimensions) f32 {
        return self.width + self.padding.horizontal() + self.border.horizontal() + self.margin.horizontal();
    }
};

/// What kind of box this is. `anonymous` block boxes wrap runs of inline
/// content inside a block container (the CSS anonymous-block rule).
pub const BoxKind = enum {
    block,
    inline_box,
    /// An anonymous block box generated to hold inline-level children of a
    /// block container that also has block children (or, in v0, any block
    /// container's inline content).
    anonymous,
    /// A leaf holding one measured text run on a line.
    text,
};

/// One node in the box tree. A `block`/`anonymous` box lays its children out in
/// block flow; an `anonymous` box lays inline children into line boxes.
pub const Box = struct {
    kind: BoxKind,
    dims: Dimensions,
    /// The styled element this box came from (null for anonymous/text boxes).
    node: ?*const Node = null,
    /// The text run this box paints (only for `.text` boxes).
    run: ?TextRun = null,
    /// The run's ascent above the baseline (only meaningful for `.text` boxes;
    /// used to baseline-align runs within a line box).
    ascent: f32 = 0,
    children: std.ArrayList(*Box),

    /// The computed style of the originating element, if any.
    pub fn style(self: *const Box, styled: *const StyledDocument) ?*const ComputedStyle {
        const n = self.node orelse return null;
        return styled.styleFor(n);
    }
};

/// The laid-out document: the root box plus the arena that owns every box.
pub const LayoutTree = struct {
    arena: std.heap.ArenaAllocator,
    root: *Box,

    pub fn deinit(self: *LayoutTree) void {
        self.arena.deinit();
    }
};

// ---------------------------------------------------------------------------
// Length resolution (px + %-width; everything else -> unsupported_unit).
// ---------------------------------------------------------------------------

/// A resolved length outcome. `%` is only meaningful where a percentage basis
/// exists (width against the containing block).
const Length = union(enum) {
    /// A concrete pixel length.
    px: f32,
    /// A percentage of the containing block (0..1 as a fraction is NOT used; we
    /// keep the raw percent so width resolution multiplies by the basis).
    percent: f32,
    /// `auto` (or an unresolved/unsupported value that falls back to auto).
    auto,
};

/// Parse a computed length string into a `Length`. `px` and `%` are supported;
/// any other unit emits `unsupported_unit` (via `diag`) and resolves to `auto`.
/// A bare number with no unit is treated as `px` (v0 convenience; real CSS
/// requires a unit for non-zero lengths, but the cascade carries raw strings).
fn parseLength(
    value: []const u8,
    diag: *Diagnostics,
    gpa: std.mem.Allocator,
) !Length {
    const v = std.mem.trim(u8, value, " \t\r\n");
    if (v.len == 0 or std.ascii.eqlIgnoreCase(v, "auto")) return .auto;

    // Percentage.
    if (std.mem.endsWith(u8, v, "%")) {
        const num = std.mem.trim(u8, v[0 .. v.len - 1], " \t");
        const f = std.fmt.parseFloat(f32, num) catch return .auto;
        return .{ .percent = f };
    }

    // Split trailing alphabetic unit from the numeric part.
    var split: usize = v.len;
    while (split > 0 and (std.ascii.isAlphabetic(v[split - 1]))) : (split -= 1) {}
    const num = v[0..split];
    const unit = v[split..];

    const f = std.fmt.parseFloat(f32, std.mem.trim(u8, num, " \t")) catch return .auto;

    if (unit.len == 0) return .{ .px = f }; // bare number: treat as px in v0.
    if (std.ascii.eqlIgnoreCase(unit, "px")) return .{ .px = f };

    // Any other unit (em/rem/vw/vh/ch/pt/…) is unsupported in v0.
    try diag.add(gpa, .warning, .unsupported_unit, null, "unsupported CSS unit (only px and % supported in v0)");
    return .auto;
}

/// Resolve a length that has NO percentage basis (padding/border/margin, and
/// `height`): `px` -> its value, `%`/`auto` -> `default`. A `%` here is not
/// supported in v0 (percentages are width-only) and resolves to `default`.
fn resolveAbsolute(len: Length, default: f32) f32 {
    return switch (len) {
        .px => |p| p,
        .percent, .auto => default,
    };
}

/// Resolve a length against a percentage `basis` (used for `width`). `px` ->
/// value, `%` -> fraction of basis, `auto` -> `null` (caller fills auto).
fn resolveAgainst(len: Length, basis: f32) ?f32 {
    return switch (len) {
        .px => |p| p,
        .percent => |pc| basis * pc / 100.0,
        .auto => null,
    };
}

// ---------------------------------------------------------------------------
// The layout engine.
// ---------------------------------------------------------------------------

/// The error set the mutually-recursive layout functions share. Named
/// explicitly to break the inferred-error-set dependency loop between
/// `layoutBlock` and `layoutBlockChildren`.
const LayoutError = std.mem.Allocator.Error;

/// The layout context threaded through the recursion.
const Engine = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    styled: *const StyledDocument,
    backend: PaintBackend,
    diag: *Diagnostics,

    fn newBox(self: *Engine, kind: BoxKind) !*Box {
        const b = try self.arena.create(Box);
        b.* = .{ .kind = kind, .dims = .{}, .children = .empty };
        return b;
    }

    /// The resolved `Font` for an element from its computed styles.
    fn fontOf(self: *Engine, node: *const Node) !Font {
        const s = self.styled.styleFor(node);
        if (s) |st| {
            const size = try parseFontSize(st.get(.font_size), self.diag, self.gpa);
            return .{
                .family = st.get(.font_family),
                .size_px = size,
                .weight = st.get(.font_weight),
            };
        }
        return default_font;
    }

    /// The font a top-level inline node starts in: its own element font, or its
    /// parent element's font for a bare text node.
    fn fontOfContext(self: *Engine, node: *const Node) !Font {
        switch (node.data) {
            .element => return try self.fontOf(node),
            .text => {
                if (node.parent) |p| {
                    if (p.data == .element and !std.mem.eql(u8, p.data.element.tag, "#document")) {
                        return try self.fontOf(p);
                    }
                }
                return default_font;
            },
        }
    }
};

/// The fallback font when no computed style is available (e.g. a text node with
/// no styled parent element).
const default_font = Font{ .family = "serif", .size_px = 16, .weight = "normal" };

/// The computed `display` string of an element node ("block" / "inline" / …).
fn displayOf(styled: *const StyledDocument, node: *const Node) []const u8 {
    const s = styled.styleFor(node) orelse return "inline";
    return s.get(.display);
}

fn isBlockDisplay(display: []const u8) bool {
    return std.ascii.eqlIgnoreCase(display, "block");
}

/// Font-size resolution for a run's font. Only `px` (and a bare number) is
/// meaningful for a run's pixel size; any other unit (`%`/`em`/`rem`/… or a
/// keyword like `larger`) is unsupported in v0: it emits `unsupported_unit`
/// (via `diag`, same severity/shape as `parseLength`) and falls back to the
/// 16px default. This mirrors the emit-then-fallback contract `parseLength`
/// uses, so the `unsupported_unit` diagnostic is uniform across length paths.
fn parseFontSize(value: []const u8, diag: *Diagnostics, gpa: std.mem.Allocator) !f32 {
    const v = std.mem.trim(u8, value, " \t");
    var split: usize = v.len;
    while (split > 0 and std.ascii.isAlphabetic(v[split - 1])) : (split -= 1) {}
    const unit = v[split..];
    const f = std.fmt.parseFloat(f32, std.mem.trim(u8, v[0..split], " \t")) catch {
        // A non-numeric font-size (e.g. a keyword like `larger`) is unsupported.
        try diag.add(gpa, .warning, .unsupported_unit, null, "unsupported CSS unit (only px and % supported in v0)");
        return 16;
    };
    if (unit.len == 0 or std.ascii.eqlIgnoreCase(unit, "px")) return f;

    // Any other font-size unit (em/rem/vw/vh/ch/pt/% or keyword) is unsupported
    // in v0: emit the diagnostic, then fall back to the 16px default.
    try diag.add(gpa, .warning, .unsupported_unit, null, "unsupported CSS unit (only px and % supported in v0)");
    return 16;
}

/// Lay out `styled` into a box tree sized to a viewport of `viewport_width`
/// CSS pixels. The viewport width is the initial containing block's content
/// width (the basis for top-level `%` widths). Measurement/line-breaking runs
/// through `backend`.
///
/// This is the LAYOUT seam: callers give a styled document + a viewport width +
/// a `PaintBackend`, and read back the box tree's `Dimensions`.
pub fn layout(
    gpa: std.mem.Allocator,
    styled: *const StyledDocument,
    doc: *const html.Document,
    viewport_width: f32,
    backend: PaintBackend,
    diag: *Diagnostics,
) !LayoutTree {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    var engine = Engine{
        .arena = arena.allocator(),
        .gpa = gpa,
        .styled = styled,
        .backend = backend,
        .diag = diag,
    };

    // The root box is an anonymous block establishing the initial containing
    // block; the document's top-level nodes are its block-flow children.
    const root = try engine.newBox(.anonymous);
    root.dims.width = viewport_width;
    root.dims.x = 0;
    root.dims.y = 0;

    try layoutBlockChildren(&engine, root, doc.children(), viewport_width);

    return .{ .arena = arena, .root = root };
}

/// Lay out a sequence of child nodes as the block-flow content of `container`
/// (whose content box is already positioned/sized). Consecutive INLINE-level
/// children are grouped into an anonymous block box that runs inline layout;
/// BLOCK-level children each become a block box stacked vertically. Returns the
/// bottom `y` after all children (so the container can size to content).
fn layoutBlockChildren(
    engine: *Engine,
    container: *Box,
    nodes: []const *const Node,
    content_width: f32,
) !void {
    var cursor_y = container.dims.y;
    var inline_group: std.ArrayList(*const Node) = .empty;

    const flush = struct {
        fn run(
            e: *Engine,
            cont: *Box,
            group: *std.ArrayList(*const Node),
            width: f32,
            y: *f32,
        ) !void {
            if (group.items.len == 0) return;
            const anon = try e.newBox(.anonymous);
            anon.dims.x = cont.dims.x;
            anon.dims.y = y.*;
            anon.dims.width = width;
            try layoutInline(e, anon, group.items, width);
            try cont.children.append(e.arena, anon);
            y.* += anon.dims.height;
            group.clearRetainingCapacity();
        }
    }.run;

    for (nodes) |node| {
        switch (node.data) {
            .text => {
                // Whitespace-only text between block boxes is collapsed away in
                // v0 (it generates no box); non-blank text joins the inline run.
                if (isBlank(node.data.text)) continue;
                try inline_group.append(engine.arena, node);
            },
            .element => {
                const display = displayOf(engine.styled, node);
                if (isBlockDisplay(display)) {
                    try flush(engine, container, &inline_group, content_width, &cursor_y);
                    const child = try layoutBlock(engine, node, container.dims.x, cursor_y, content_width);
                    cursor_y += child.dims.marginBoxHeight();
                    try container.children.append(engine.arena, child);
                } else {
                    try inline_group.append(engine.arena, node);
                }
            },
        }
    }
    try flush(engine, container, &inline_group, content_width, &cursor_y);

    container.dims.height = cursor_y - container.dims.y;
}

/// Lay out one BLOCK-level element at block-flow position `(origin_x, origin_y)`
/// within a containing block of `cb_width` content pixels. Resolves the box
/// model, sizes the content width, lays out children, and sizes the content
/// height (to `height` if set, else to content). Returns the positioned box;
/// `origin_y` is the box's MARGIN-box top.
fn layoutBlock(
    engine: *Engine,
    node: *const Node,
    origin_x: f32,
    origin_y: f32,
    cb_width: f32,
) LayoutError!*Box {
    const box = try engine.newBox(.block);
    box.node = node;
    const st = engine.styled.styleFor(node);

    var dims = &box.dims;
    dims.margin = try edgesFromShorthand(engine, if (st) |s| s.get(.margin) else "0");
    dims.padding = try edgesFromShorthand(engine, if (st) |s| s.get(.padding) else "0");
    // v0 has no `border-width` property in the supported set, so borders are 0
    // for now; the field exists so the paint task and later border support slot
    // in without reshaping the box model.
    dims.border = .{};

    // Content width: `width` resolves against the containing block; `auto`
    // fills the remaining space (cb_width minus this box's own horizontal
    // margin/border/padding), the block-flow default.
    const width_len = try parseLength(if (st) |s| s.get(.width) else "auto", engine.diag, engine.gpa);
    const non_content_h = dims.margin.horizontal() + dims.border.horizontal() + dims.padding.horizontal();
    dims.width = resolveAgainst(width_len, cb_width) orelse (cb_width - non_content_h);
    if (dims.width < 0) dims.width = 0;

    // Content-box origin: margin + border + padding in from the margin-box top-left.
    dims.x = origin_x + dims.margin.left + dims.border.left + dims.padding.left;
    dims.y = origin_y + dims.margin.top + dims.border.top + dims.padding.top;

    // Lay out children in block flow within this box's content box.
    switch (node.data) {
        .element => |el| try layoutBlockChildren(engine, box, el.children.items, dims.width),
        .text => {},
    }

    // Content height: `height` if set (px only; % height unsupported in v0),
    // else the height the children produced (set by layoutBlockChildren).
    const height_len = try parseLength(if (st) |s| s.get(.height) else "auto", engine.diag, engine.gpa);
    switch (height_len) {
        .px => |p| dims.height = p,
        .percent, .auto => {}, // keep the content height set by children.
    }

    return box;
}

/// Lay out inline-level `nodes` into LINE BOXES inside `container` (an anonymous
/// block whose content box is positioned/sized). Text wraps at the container's
/// content width. Sets `container.dims.height` to the total line-box height.
fn layoutInline(
    engine: *Engine,
    container: *Box,
    nodes: []const *const Node,
    content_width: f32,
) !void {
    var liner = LineLayout{
        .engine = engine,
        .container = container,
        .max_width = content_width,
        .origin_x = container.dims.x,
        .cursor_y = container.dims.y,
        .cursor_x = container.dims.x,
        .line_ascent = 0,
        .line_descent = 0,
        .line_boxes = .empty,
    };
    for (nodes) |node| try liner.addNode(node, try engine.fontOfContext(node));
    try liner.finishLine();
    container.dims.height = liner.cursor_y - container.dims.y;
}

/// The running state of inline layout: a pen (`cursor_x`, `cursor_y`) walking
/// left-to-right and wrapping to a new line at `max_width`. Line boxes are
/// baseline-aligned: a line's height is `max(ascent) + max(descent)` over its
/// runs, and each run sits on the shared baseline.
const LineLayout = struct {
    engine: *Engine,
    container: *Box,
    max_width: f32,
    origin_x: f32,
    cursor_y: f32,
    cursor_x: f32,
    line_ascent: f32,
    line_descent: f32,
    /// Boxes placed on the CURRENT line (finalised on `finishLine`, which sets
    /// their baseline `y`).
    line_boxes: std.ArrayList(*Box),

    /// Add one inline-level node's content to the flow. For text nodes each
    /// whitespace-separated WORD is a wrap opportunity; inline elements
    /// contribute their text children (v0 flattens inline element text into the
    /// same flow, honouring the element's own font).
    fn addNode(self: *LineLayout, node: *const Node, font: Font) !void {
        switch (node.data) {
            .text => try self.addText(node.data.text, font),
            .element => |el| {
                if (el.children.items.len == 0) {
                    // Empty inline element (e.g. <br>): a br forces a line break.
                    if (std.ascii.eqlIgnoreCase(el.tag, "br")) try self.forceBreak();
                    return;
                }
                const child_font = try self.engine.fontOf(node);
                for (el.children.items) |child| try self.addNode(child, child_font);
            },
        }
    }

    /// Flow a text string word-by-word, wrapping at `max_width`.
    fn addText(self: *LineLayout, text: []const u8, font: Font) !void {
        var it = std.mem.tokenizeAny(u8, text, " \t\r\n\x0c");
        while (it.next()) |word| {
            const run = TextRun{ .text = word, .font = font };
            const metrics = self.engine.backend.measureRun(run);

            // Advance for a leading space between words already on this line.
            const space_w = self.spaceWidth(font);
            const need_space = self.cursor_x > self.origin_x;
            const advance = metrics.width + (if (need_space) space_w else 0);

            // Wrap if this word would overflow the line (but never wrap a word
            // that is alone at the line start: it just overflows).
            if (need_space and self.cursor_x + advance > self.origin_x + self.max_width) {
                try self.finishLine();
            }

            const space_before = if (self.cursor_x > self.origin_x) space_w else 0;
            const x = self.cursor_x + space_before;
            try self.placeRun(run, metrics, x);
            self.cursor_x = x + metrics.width;
        }
    }

    /// Width of an inter-word space in `font` (measured through the backend so
    /// it matches the run advance model).
    fn spaceWidth(self: *LineLayout, font: Font) f32 {
        return self.engine.backend.measureRun(.{ .text = " ", .font = font }).width;
    }

    /// Place one measured run at pen `x` on the current line, recording it as a
    /// text box and growing the line's ascent/descent.
    fn placeRun(self: *LineLayout, run: TextRun, metrics: RunMetrics, x: f32) !void {
        const box = try self.engine.newBox(.text);
        box.run = run;
        box.ascent = metrics.ascent;
        box.dims.x = x;
        box.dims.width = metrics.width;
        box.dims.height = metrics.height();
        try self.line_boxes.append(self.engine.arena, box);
        self.line_ascent = @max(self.line_ascent, metrics.ascent);
        self.line_descent = @max(self.line_descent, metrics.descent);
    }

    /// Force a break to the next line (a `<br>` or an overflow wrap).
    fn forceBreak(self: *LineLayout) !void {
        try self.finishLine();
    }

    /// Finalise the current line: baseline-align every run on it, add the line
    /// box's height to the pen, and reset for the next line.
    fn finishLine(self: *LineLayout) !void {
        if (self.line_boxes.items.len == 0) {
            // An empty forced break still advances by one blank line only if a
            // <br> at line start. v0 keeps this simple: no advance for a fully
            // empty line with no prior content.
            self.cursor_x = self.origin_x;
            return;
        }
        const baseline = self.cursor_y + self.line_ascent;
        for (self.line_boxes.items) |box| {
            // Place each run's content top so the shared baseline aligns across
            // the line (a taller run sits higher; all share one baseline).
            box.dims.y = baseline - box.ascent;
            try self.container.children.append(self.engine.arena, box);
        }
        self.cursor_y += self.line_ascent + self.line_descent;
        self.cursor_x = self.origin_x;
        self.line_ascent = 0;
        self.line_descent = 0;
        self.line_boxes.clearRetainingCapacity();
    }
};

/// Whether a text string is entirely ASCII whitespace (collapsed away between
/// block boxes in v0).
fn isBlank(text: []const u8) bool {
    for (text) |c| {
        if (!std.ascii.isWhitespace(c)) return false;
    }
    return true;
}

/// Parse a box-model shorthand (`margin`/`padding`) into `Edges`. v0 supports
/// the 1-value form (all four sides equal); 2/3/4-value forms are parsed
/// top/right/bottom/left. Percentages and unsupported units resolve to 0 (a `%`
/// margin/padding basis is not supported in v0).
fn edgesFromShorthand(engine: *Engine, value: []const u8) !Edges {
    var parts: [4]f32 = .{ 0, 0, 0, 0 };
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, value, " \t\r\n");
    while (it.next()) |tok| {
        if (n == 4) break;
        const len = try parseLength(tok, engine.diag, engine.gpa);
        parts[n] = resolveAbsolute(len, 0);
        n += 1;
    }
    return switch (n) {
        0 => .{},
        1 => .{ .top = parts[0], .right = parts[0], .bottom = parts[0], .left = parts[0] },
        2 => .{ .top = parts[0], .right = parts[1], .bottom = parts[0], .left = parts[1] },
        3 => .{ .top = parts[0], .right = parts[1], .bottom = parts[2], .left = parts[1] },
        else => .{ .top = parts[0], .right = parts[1], .bottom = parts[2], .left = parts[3] },
    };
}

// ===========================================================================
// Tests: at the LAYOUT seam (HTML + CSS fixtures in; assert the box tree's
// positions/sizes and the collected diagnostic codes, driving measurement
// through the headless `StubBackend`).
// ===========================================================================

const testing = std.testing;

/// Build a laid-out tree from HTML + CSS fixtures against a stub backend at a
/// given viewport width. The caller owns everything and must `deinit` all three
/// returned pieces (doc, styled, tree) plus the diagnostics.
const Fixture = struct {
    doc: html.Document,
    styled: StyledDocument,
    tree: LayoutTree,
    stub: *StubBackend,
    gpa: std.mem.Allocator,

    fn deinit(self: *Fixture) void {
        self.tree.deinit();
        self.styled.deinit();
        self.doc.deinit();
        self.gpa.destroy(self.stub);
    }
};

fn layoutFixture(
    gpa: std.mem.Allocator,
    html_src: []const u8,
    css_src: []const u8,
    viewport_width: f32,
    diag: *Diagnostics,
) !Fixture {
    var doc = try html.parse(gpa, html_src, diag);
    errdefer doc.deinit();
    var styled = try css.styleDocument(gpa, &doc, css_src, diag);
    errdefer styled.deinit();
    const stub = try gpa.create(StubBackend);
    stub.* = .{};
    const tree = try layout(gpa, &styled, &doc, viewport_width, stub.backend(), diag);
    return .{ .doc = doc, .styled = styled, .tree = tree, .stub = stub, .gpa = gpa };
}

/// Find the first box whose originating element has `tag`, pre-order.
fn firstBoxByTag(box: *const Box, tag: []const u8) ?*const Box {
    if (box.node) |n| {
        if (n.isElement(tag)) return box;
    }
    for (box.children.items) |child| {
        if (firstBoxByTag(child, tag)) |found| return found;
    }
    return null;
}

/// Collect all `.text` boxes in the tree, pre-order.
fn collectTextBoxes(box: *const Box, out: *std.ArrayList(*const Box), gpa: std.mem.Allocator) !void {
    if (box.kind == .text) try out.append(gpa, box);
    for (box.children.items) |child| try collectTextBoxes(child, out, gpa);
}

test "block boxes stack vertically, each filling the containing block width" {
    const gpa = testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    // Two block <p>s inside a <body>; they stack, and (no width set) each fills
    // the viewport content width.
    var fx = try layoutFixture(gpa, "<body><p>a</p><p>b</p></body>", "", 800, &diag);
    defer fx.deinit();

    const body = firstBoxByTag(fx.tree.root, "body").?;
    try testing.expectEqual(@as(f32, 800), body.dims.width);

    // The two paragraphs stack: the second's top is below the first's bottom.
    var ps: [2]*const Box = undefined;
    var n: usize = 0;
    for (body.children.items) |c| {
        if (c.node) |node| if (node.isElement("p")) {
            ps[n] = c;
            n += 1;
        };
    }
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(f32, 800), ps[0].dims.width);
    try testing.expectEqual(@as(f32, 800), ps[1].dims.width);
    // p[1] starts at p[0]'s content-box bottom (no margins/padding here).
    try testing.expect(ps[1].dims.y >= ps[0].dims.y + ps[0].dims.height);
    try testing.expectEqual(@as(usize, 0), diag.entries().len);
}

test "box model: margin, padding, width in px are honoured" {
    const gpa = testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    // A block with explicit margin/padding/width. Content box origin is inset
    // by margin+padding; width is the declared px value.
    const css_src = "div { margin: 10px; padding: 5px; width: 100px; }";
    var fx = try layoutFixture(gpa, "<body><div>x</div></body>", css_src, 800, &diag);
    defer fx.deinit();

    const div = firstBoxByTag(fx.tree.root, "div").?;
    // width honoured exactly (px, not filled to container).
    try testing.expectEqual(@as(f32, 100), div.dims.width);
    try testing.expectEqual(@as(f32, 10), div.dims.margin.left);
    try testing.expectEqual(@as(f32, 5), div.dims.padding.left);
    // Content-box x = body content x (0) + margin.left(10) + padding.left(5).
    try testing.expectEqual(@as(f32, 15), div.dims.x);
    try testing.expectEqual(@as(usize, 0), diag.entries().len);
}

test "%-width resolves against the containing block content width" {
    const gpa = testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    // A 50% div in an 800px viewport -> 400px content width.
    var fx = try layoutFixture(gpa, "<body><div>x</div></body>", "div { width: 50%; }", 800, &diag);
    defer fx.deinit();

    const div = firstBoxByTag(fx.tree.root, "div").?;
    try testing.expectEqual(@as(f32, 400), div.dims.width);
    try testing.expectEqual(@as(usize, 0), diag.entries().len);
}

test "explicit px height overrides content height" {
    const gpa = testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    var fx = try layoutFixture(gpa, "<body><div>x</div></body>", "div { height: 250px; }", 800, &diag);
    defer fx.deinit();

    const div = firstBoxByTag(fx.tree.root, "div").?;
    try testing.expectEqual(@as(f32, 250), div.dims.height);
    try testing.expectEqual(@as(usize, 0), diag.entries().len);
}

test "inline text wraps into line boxes at the container width" {
    const gpa = testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    // font-size 20px, stub advance 0.5*size = 10px/char. "aaaa" = 40px per word,
    // + a 10px space between words. Viewport 100px content:
    //   word1 at x=0 (40px, ends at 40), space+word2 would end at 90 (fits),
    //   space+word3 would need 90+10+40=140 > 100 -> wraps to a new line.
    const css_src = "p { font-size: 20px; }";
    var fx = try layoutFixture(gpa, "<body><p>aaaa aaaa aaaa</p></body>", css_src, 100, &diag);
    defer fx.deinit();

    var texts: std.ArrayList(*const Box) = .empty;
    defer texts.deinit(gpa);
    try collectTextBoxes(fx.tree.root, &texts, gpa);
    try testing.expectEqual(@as(usize, 3), texts.items.len);

    // First two words share the first line (same y); the third wraps below.
    try testing.expectEqual(texts.items[0].dims.y, texts.items[1].dims.y);
    try testing.expect(texts.items[2].dims.y > texts.items[0].dims.y);
    // Word 1 starts at the content origin (x=0); word 2 after word1 + a space.
    try testing.expectEqual(@as(f32, 0), texts.items[0].dims.x);
    try testing.expectEqual(@as(f32, 50), texts.items[1].dims.x); // 40 + 10 space
    // Wrapped word restarts at the line origin.
    try testing.expectEqual(@as(f32, 0), texts.items[2].dims.x);
    try testing.expectEqual(@as(usize, 0), diag.entries().len);
}

test "a run carries its resolved font from computed styles across the seam" {
    const gpa = testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    // The run reaching the backend carries family/size/weight resolved from the
    // cascade (font-family sans-serif, font-size 24px, bold on the <b>).
    const css_src = "p { font-family: sans-serif; font-size: 24px; } b { font-weight: bold; }";
    var fx = try layoutFixture(gpa, "<body><p><b>hi</b></p></body>", css_src, 800, &diag);
    defer fx.deinit();

    var texts: std.ArrayList(*const Box) = .empty;
    defer texts.deinit(gpa);
    try collectTextBoxes(fx.tree.root, &texts, gpa);
    try testing.expectEqual(@as(usize, 1), texts.items.len);

    const run = texts.items[0].run.?;
    try testing.expectEqualStrings("hi", run.text);
    try testing.expectEqualStrings("sans-serif", run.font.family);
    try testing.expectEqual(@as(f32, 24), run.font.size_px);
    try testing.expectEqualStrings("bold", run.font.weight);
    // width = 2 chars * 0.5 * 24 = 24px (proves measureRun was exercised).
    try testing.expectEqual(@as(f32, 24), texts.items[0].dims.width);
    try testing.expectEqual(@as(usize, 0), diag.entries().len);
}

test "the stub PaintBackend is exercised for measurement" {
    // A direct check that the seam's measurement contract holds: a run carries
    // its font, and the stub returns width = len * advance_ratio * size.
    var stub = StubBackend{};
    const be = stub.backend();
    const m = be.measureRun(.{ .text = "abcd", .font = .{ .family = "serif", .size_px = 16, .weight = "normal" } });
    try testing.expectEqual(@as(f32, 4 * 0.5 * 16), m.width);
    try testing.expectEqual(@as(f32, 0.8 * 16), m.ascent);
    try testing.expectEqual(@as(f32, 0.2 * 16), m.descent);
}

test "<br> forces a line break within inline flow" {
    const gpa = testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    var fx = try layoutFixture(gpa, "<body><p>a<br>b</p></body>", "", 800, &diag);
    defer fx.deinit();

    var texts: std.ArrayList(*const Box) = .empty;
    defer texts.deinit(gpa);
    try collectTextBoxes(fx.tree.root, &texts, gpa);
    try testing.expectEqual(@as(usize, 2), texts.items.len);
    // 'a' and 'b' land on different lines (the <br> broke between them).
    try testing.expect(texts.items[1].dims.y > texts.items[0].dims.y);
    try testing.expectEqual(@as(usize, 0), diag.entries().len);
}

test "unsupported unit emits unsupported_unit and the length falls back" {
    const gpa = testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    // `2em` width is unsupported: emits unsupported_unit; width falls back to
    // auto (fills the container).
    var fx = try layoutFixture(gpa, "<body><div>x</div></body>", "div { width: 2em; }", 800, &diag);
    defer fx.deinit();

    const div = firstBoxByTag(fx.tree.root, "div").?;
    try testing.expectEqual(@as(f32, 800), div.dims.width); // auto fallback fills

    var found = false;
    for (diag.entries()) |e| {
        if (e.code == .unsupported_unit) found = true;
    }
    try testing.expect(found);
}

test "font-size with an unsupported unit emits unsupported_unit and falls back to 16px" {
    const gpa = testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    // `2em` font-size is unsupported in v0: it emits unsupported_unit and the
    // run's font falls back to the 16px default. Stub advance 0.5*size, so the
    // one-char word "x" measures at 0.5*16 = 8px, proving the 16px fallback.
    const css_src = "p { font-size: 2em; }";
    var fx = try layoutFixture(gpa, "<body><p>x</p></body>", css_src, 800, &diag);
    defer fx.deinit();

    var texts: std.ArrayList(*const Box) = .empty;
    defer texts.deinit(gpa);
    try collectTextBoxes(fx.tree.root, &texts, gpa);
    try testing.expectEqual(@as(usize, 1), texts.items.len);
    // Font fell back to 16px (not resolved from `2em`): width = 1 * 0.5 * 16 = 8.
    try testing.expectEqual(@as(f32, 16), texts.items[0].run.?.font.size_px);
    try testing.expectEqual(@as(f32, 8), texts.items[0].dims.width);

    // The unsupported unit was reported through the Diagnostics sink.
    var found = false;
    for (diag.entries()) |e| {
        if (e.code == .unsupported_unit) found = true;
    }
    try testing.expect(found);
}

test "font-size in px (and a bare number) emits no diagnostic" {
    const gpa = testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    // A `px` font-size resolves as before and emits nothing.
    var fx = try layoutFixture(gpa, "<body><p>x</p></body>", "p { font-size: 20px; }", 800, &diag);
    defer fx.deinit();

    var texts: std.ArrayList(*const Box) = .empty;
    defer texts.deinit(gpa);
    try collectTextBoxes(fx.tree.root, &texts, gpa);
    try testing.expectEqual(@as(usize, 1), texts.items.len);
    try testing.expectEqual(@as(f32, 20), texts.items[0].run.?.font.size_px);
    try testing.expectEqual(@as(usize, 0), diag.entries().len);
}

test "baseline alignment: runs of different sizes share a line baseline" {
    const gpa = testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    // A big word then a small word on one line: they share a baseline, so the
    // taller run's content-top is higher (smaller y) than the shorter run's.
    const css_src = "p { font-size: 40px; } span { font-size: 10px; }";
    var fx = try layoutFixture(gpa, "<body><p>Big <span>x</span></p></body>", css_src, 800, &diag);
    defer fx.deinit();

    var texts: std.ArrayList(*const Box) = .empty;
    defer texts.deinit(gpa);
    try collectTextBoxes(fx.tree.root, &texts, gpa);
    try testing.expectEqual(@as(usize, 2), texts.items.len);

    const big = texts.items[0];
    const small = texts.items[1];
    // Shared baseline: big.y + big.ascent == small.y + small.ascent.
    try testing.expectApproxEqAbs(big.dims.y + big.ascent, small.dims.y + small.ascent, 0.001);
    // Bigger run sits higher (smaller top y) than the small one.
    try testing.expect(big.dims.y < small.dims.y);
    try testing.expectEqual(@as(usize, 0), diag.entries().len);
}

test "nested block content height flows up to the parent (no margin collapse)" {
    const gpa = testing.allocator;
    var diag = Diagnostics.init(gpa);
    defer diag.deinit(gpa);

    // Two inner divs with 20px height and 10px vertical margins each. v0 does
    // NOT collapse margins, so the outer content height = 20+10+10 (first:
    // margin-box) + 20+10+10 (second) = 80.
    const css_src = "div.inner { height: 20px; margin: 10px; }";
    const html_src = "<body><div class=\"outer\"><div class=\"inner\">a</div><div class=\"inner\">b</div></div></body>";
    var fx = try layoutFixture(gpa, html_src, css_src, 800, &diag);
    defer fx.deinit();

    const outer = firstBoxByTag(fx.tree.root, "div").?;
    // outer content height = sum of the two inner margin-boxes (40 + 40) = 80,
    // NOT collapsed to 20+10+20+10=... . Adjacent margins simply add.
    try testing.expectEqual(@as(f32, 80), outer.dims.height);
    try testing.expectEqual(@as(usize, 0), diag.entries().len);
}
