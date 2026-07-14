//! The v0 paint backend: `StbSoftwareBackend`, a concrete `PaintBackend`
//! (the seam pinned by `layout-block-inline` / ADR-0002) that renders a laid-out
//! box tree to an RGBA `Surface` using stb_truetype for glyphs and a small
//! software rasteriser for backgrounds/borders/text coverage. Plus `paintTree`,
//! which walks the box tree and issues the backend calls.
//!
//! ## Where this sits (ADR-0002 / ADR-0003)
//!
//! Everything here is BELOW the `PaintBackend` seam: glyph selection, shaping
//! (v0 shaping = simple left-to-right advance from stb metrics), and raster all
//! live in the backend. Callers above the seam (`paintTree` talks only to the
//! vtable) never touch SDL/stb specifics, so the future SDL+FreeType+HarfBuzz+
//! Skia backend is a drop-in replacement: it implements the SAME vtable.
//!
//! The backend renders into an offscreen `Surface`; the on-screen SDL3 window
//! (in `sdl.zig`, the app entrypoint) blits that surface. TESTS render to the
//! surface and compare against golden PNGs, so the test path is headless.
//!
//! ## Font handling (the run/font contract)
//!
//! A `TextRun` arrives with its resolved `Font` (family/size/weight) per the
//! layout contract. v0 ships ONE embedded face (Roboto Regular) and maps every
//! family/weight to it (documented v0 limit); `size_px` drives the stb pixel
//! scale. The backend never re-resolves font properties upward.

const std = @import("std");
const layout = @import("layout.zig");
const surface = @import("surface.zig");
const html = @import("html.zig");
const css = @import("css.zig");
const diagnostics = @import("diagnostics.zig");

const c = @cImport({
    @cInclude("stb_truetype.h");
});

const PaintBackend = layout.PaintBackend;
const TextRun = layout.TextRun;
const RunMetrics = layout.RunMetrics;
const Color = layout.Color;
const Rect = layout.Rect;
const Edges = layout.Edges;
const Box = layout.Box;
const Surface = surface.Surface;
const Rgba = surface.Rgba;

/// The single embedded v0 font face (Roboto Regular, Apache-2.0; see
/// `src/assets/Roboto-LICENSE.txt`). Vendored so glyph rasterisation is
/// deterministic and byte-identical across machines, which is what makes the
/// committed golden images stable (ADR-0003).
const embedded_font = @embedFile("assets/Roboto-Regular.ttf");

/// A software `PaintBackend` backed by stb_truetype glyphs and an RGBA
/// `Surface`. Construct with `init`, obtain the seam value with `backend()`,
/// and hand that to `paintTree` / `layout`. The backend does NOT own the
/// surface (the caller does), so the same surface can be blitted to a window
/// afterwards.
pub const StbSoftwareBackend = struct {
    surface: *Surface,
    font: c.stbtt_fontinfo,

    /// Initialise the backend over `target`. Fails only if the embedded font
    /// cannot be parsed (a build-time invariant, so effectively never).
    pub fn init(target: *Surface) error{FontInit}!StbSoftwareBackend {
        var self = StbSoftwareBackend{ .surface = target, .font = undefined };
        const offset = c.stbtt_GetFontOffsetForIndex(embedded_font, 0);
        if (c.stbtt_InitFont(&self.font, embedded_font, offset) == 0) return error.FontInit;
        return self;
    }

    /// The `PaintBackend` seam value. All drawing methods are wired (unlike the
    /// layout `StubBackend`, which only measures).
    pub fn backend(self: *StbSoftwareBackend) PaintBackend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = PaintBackend.VTable{
        .measureRun = measureRun,
        .drawRun = drawRun,
        .fillRect = fillRect,
        .drawBorder = drawBorder,
        .beginFrame = beginFrame,
        .present = present,
    };

    /// The stb pixel scale for a run's font size.
    fn scaleFor(self: *StbSoftwareBackend, size_px: f32) f32 {
        return c.stbtt_ScaleForPixelHeight(&self.font, size_px);
    }

    /// The face's ascent/descent for `size_px` (descent returned positive: the
    /// distance below the baseline).
    fn vmetrics(self: *StbSoftwareBackend, size_px: f32) struct { ascent: f32, descent: f32 } {
        var ascent: c_int = 0;
        var descent: c_int = 0;
        var line_gap: c_int = 0;
        c.stbtt_GetFontVMetrics(&self.font, &ascent, &descent, &line_gap);
        const scale = self.scaleFor(size_px);
        return .{
            .ascent = @as(f32, @floatFromInt(ascent)) * scale,
            .descent = @as(f32, @floatFromInt(-descent)) * scale,
        };
    }

    // --- PaintBackend vtable implementations -----------------------------

    /// Measure a run: sum of scaled horizontal advances (with kerning) for its
    /// codepoints, and the face's scaled ascent/descent. This is the SAME code
    /// path `drawRun` advances the pen along, so measured width matches drawn
    /// width exactly.
    fn measureRun(ctx: *anyopaque, run: TextRun) RunMetrics {
        const self: *StbSoftwareBackend = @ptrCast(@alignCast(ctx));
        const scale = self.scaleFor(run.font.size_px);
        const vm = self.vmetrics(run.font.size_px);
        var width: f32 = 0;
        var it = CodepointIterator{ .bytes = run.text };
        var prev: c_int = 0;
        while (it.next()) |cp| {
            var advance: c_int = 0;
            var lsb: c_int = 0;
            c.stbtt_GetCodepointHMetrics(&self.font, cp, &advance, &lsb);
            if (prev != 0) {
                width += @as(f32, @floatFromInt(c.stbtt_GetCodepointKernAdvance(&self.font, prev, cp))) * scale;
            }
            width += @as(f32, @floatFromInt(advance)) * scale;
            prev = cp;
        }
        return .{ .width = width, .ascent = vm.ascent, .descent = vm.descent };
    }

    /// Draw a run with its baseline origin at `(x, baseline_y)`. Each glyph is
    /// rasterised by stb to an 8-bit coverage bitmap and blended as `color`
    /// scaled by coverage (anti-aliased text).
    fn drawRun(ctx: *anyopaque, run: TextRun, x: f32, baseline_y: f32, color: Color) void {
        const self: *StbSoftwareBackend = @ptrCast(@alignCast(ctx));
        const scale = self.scaleFor(run.font.size_px);
        var pen_x = x;
        var it = CodepointIterator{ .bytes = run.text };
        var prev: c_int = 0;
        while (it.next()) |cp| {
            if (prev != 0) {
                pen_x += @as(f32, @floatFromInt(c.stbtt_GetCodepointKernAdvance(&self.font, prev, cp))) * scale;
            }
            self.drawGlyph(cp, scale, pen_x, baseline_y, color);
            var advance: c_int = 0;
            var lsb: c_int = 0;
            c.stbtt_GetCodepointHMetrics(&self.font, cp, &advance, &lsb);
            pen_x += @as(f32, @floatFromInt(advance)) * scale;
            prev = cp;
        }
    }

    /// Rasterise one glyph and blend it. `pen_x` is the glyph's pen position;
    /// stb gives the coverage bitmap plus its top-left offset from the pen /
    /// baseline, which we place onto the surface.
    fn drawGlyph(self: *StbSoftwareBackend, cp: c_int, scale: f32, pen_x: f32, baseline_y: f32, color: Color) void {
        var w: c_int = 0;
        var h: c_int = 0;
        var xoff: c_int = 0;
        var yoff: c_int = 0;
        const bitmap = c.stbtt_GetCodepointBitmap(&self.font, 0, scale, cp, &w, &h, &xoff, &yoff);
        if (bitmap == null) return;
        defer c.stbtt_FreeBitmap(bitmap, null);
        if (w <= 0 or h <= 0) return;

        // The glyph's top-left on the surface: pen_x + xoff, baseline + yoff
        // (yoff is negative for the part above the baseline).
        const gx0: i64 = @as(i64, @intFromFloat(@floor(pen_x))) + xoff;
        const gy0: i64 = @as(i64, @intFromFloat(@floor(baseline_y))) + yoff;
        const uw: usize = @intCast(w);
        const uh: usize = @intCast(h);
        var row: usize = 0;
        while (row < uh) : (row += 1) {
            var col: usize = 0;
            while (col < uw) : (col += 1) {
                const cov = bitmap[row * uw + col];
                if (cov == 0) continue;
                // Modulate the fill alpha by glyph coverage.
                const a: u8 = @intCast((@as(u32, color.a) * cov + 127) / 255);
                self.surface.blendPixel(gx0 + @as(i64, @intCast(col)), gy0 + @as(i64, @intCast(row)), .{
                    .r = color.r,
                    .g = color.g,
                    .b = color.b,
                    .a = a,
                });
            }
        }
    }

    /// Fill a rectangle (a background) with a solid colour.
    fn fillRect(ctx: *anyopaque, rect: Rect, color: Color) void {
        const self: *StbSoftwareBackend = @ptrCast(@alignCast(ctx));
        self.surface.fillRect(
            @intFromFloat(@round(rect.x)),
            @intFromFloat(@round(rect.y)),
            @intFromFloat(@round(rect.w)),
            @intFromFloat(@round(rect.h)),
            toRgba(color),
        );
    }

    /// Stroke a border of per-side `widths` INSIDE `rect` (the border-box), one
    /// solid-colour rectangle per side. v0 borders are square, single-colour.
    fn drawBorder(ctx: *anyopaque, rect: Rect, widths: Edges, color: Color) void {
        const self: *StbSoftwareBackend = @ptrCast(@alignCast(ctx));
        const rgba = toRgba(color);
        const x: i64 = @intFromFloat(@round(rect.x));
        const y: i64 = @intFromFloat(@round(rect.y));
        const w: i64 = @intFromFloat(@round(rect.w));
        const h: i64 = @intFromFloat(@round(rect.h));
        const top: i64 = @intFromFloat(@round(widths.top));
        const right: i64 = @intFromFloat(@round(widths.right));
        const bottom: i64 = @intFromFloat(@round(widths.bottom));
        const left: i64 = @intFromFloat(@round(widths.left));
        if (top > 0) self.surface.fillRect(x, y, w, top, rgba);
        if (bottom > 0) self.surface.fillRect(x, y + h - bottom, w, bottom, rgba);
        if (left > 0) self.surface.fillRect(x, y, left, h, rgba);
        if (right > 0) self.surface.fillRect(x + w - right, y, right, h, rgba);
    }

    /// Begin a frame. For the offscreen backend this is a no-op (the surface is
    /// cleared at construction / by the caller); the SDL path clears the window.
    fn beginFrame(ctx: *anyopaque) void {
        _ = ctx;
    }

    /// Present the frame. No-op for the offscreen backend (the pixels are
    /// already in the surface); the SDL path swaps the window here.
    fn present(ctx: *anyopaque) void {
        _ = ctx;
    }
};

/// Convert a seam `Color` to a surface `Rgba`.
fn toRgba(color: Color) Rgba {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
}

/// Iterate UTF-8 codepoints, falling back to the replacement char on malformed
/// bytes so a bad byte never aborts a run.
const CodepointIterator = struct {
    bytes: []const u8,
    i: usize = 0,

    fn next(self: *CodepointIterator) ?c_int {
        if (self.i >= self.bytes.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(self.bytes[self.i]) catch {
            self.i += 1;
            return 0xFFFD;
        };
        if (self.i + len > self.bytes.len) {
            self.i = self.bytes.len;
            return 0xFFFD;
        }
        const cp = std.unicode.utf8Decode(self.bytes[self.i .. self.i + len]) catch {
            self.i += len;
            return 0xFFFD;
        };
        self.i += len;
        return @intCast(cp);
    }
};

// ---------------------------------------------------------------------------
// Painting the box tree through the seam.
// ---------------------------------------------------------------------------

/// How a box's background / border / text colours are resolved for painting.
/// v0 has no `background-color`/`border`/`color` in the computed-style set yet,
/// so `paintTree` takes an explicit `PaintStyle` per call (the app supplies
/// defaults). This keeps colour resolution ABOVE the raster but still a caller
/// concern, not baked into the backend.
pub const PaintStyle = struct {
    /// Text colour.
    text: Color = .{ .r = 0, .g = 0, .b = 0 },
};

/// Walk the laid-out box tree and paint it through `backend` (the seam). Order:
/// backgrounds/borders first (block boxes), then text runs, in tree order
/// (painter's algorithm, sufficient for v0's non-overlapping block/inline flow).
/// Talks ONLY to the `PaintBackend` vtable, so it is backend-agnostic.
pub fn paintTree(be: PaintBackend, root: *const Box, style: PaintStyle) void {
    if (be.vtable.beginFrame) |f| f(be.ptr);
    paintBox(be, root, style);
    if (be.vtable.present) |f| f(be.ptr);
}

fn paintBox(be: PaintBackend, box: *const Box, style: PaintStyle) void {
    switch (box.kind) {
        .text => {
            if (box.run) |run| {
                if (be.vtable.drawRun) |draw| {
                    // The run's baseline sits `ascent` below the box top.
                    draw(be.ptr, run, box.dims.x, box.dims.y + box.ascent, style.text);
                }
            }
        },
        .block, .inline_box, .anonymous => {
            // (Backgrounds/borders paint here once the cascade carries the
            // colours; the box model rects are already available via
            // `dims.borderRect()`. v0 leaves block boxes transparent, so we only
            // recurse. The seam calls are wired and exercised via the app path
            // and the fillRect/drawBorder tests.)
        },
    }
    for (box.children.items) |child| paintBox(be, child, style);
}

// ---------------------------------------------------------------------------
// Golden-image fixtures (ADR-0003).
//
// Each `GoldenScene` renders a small v0 fixture to an OFFSCREEN surface. The
// SAME function renders both the committed reference PNG (`writeGoldens`) and
// the surface a test compares against it, so a golden is a genuine regression
// guard for the raster. The set is kept SMALL and each scene fits in a few tens
// of pixels so the reference PNGs stay maintainable (the spec calls this out).
// ---------------------------------------------------------------------------

/// A named v0 golden fixture: an HTML+CSS document laid out at `viewport` px and
/// painted onto a `w`x`h` surface, plus the explicit background/border colours
/// v0's computed-style set does not yet carry (so the "page fragment" scenes are
/// still visually meaningful). Colours are supplied here, ABOVE the raster.
pub const GoldenScene = struct {
    name: []const u8,
    html_src: []const u8,
    css_src: []const u8,
    viewport: f32,
    w: u32,
    h: u32,
    /// Optional background fill rect (border-box), painted first.
    background: ?struct { rect: Rect, color: Color } = null,
    /// Optional border, painted over the background.
    border: ?struct { rect: Rect, widths: Edges, color: Color } = null,
    text_color: Color = .{ .r = 0, .g = 0, .b = 0 },
};

/// The v0 golden set. Deliberately small: a background+border box, a single
/// text line, and a wrapping "page fragment" that combines all three (the
/// milestone image).
pub const golden_scenes = [_]GoldenScene{
    .{
        .name = "bg-border",
        .html_src = "<body></body>",
        .css_src = "",
        .viewport = 40,
        .w = 40,
        .h = 30,
        .background = .{ .rect = .{ .x = 4, .y = 4, .w = 32, .h = 22 }, .color = .{ .r = 220, .g = 230, .b = 245 } },
        .border = .{ .rect = .{ .x = 4, .y = 4, .w = 32, .h = 22 }, .widths = .{ .top = 2, .right = 2, .bottom = 2, .left = 2 }, .color = .{ .r = 40, .g = 90, .b = 160 } },
    },
    .{
        .name = "text-line",
        .html_src = "<body><p>Hello</p></body>",
        .css_src = "p { font-size: 20px; }",
        .viewport = 120,
        .w = 120,
        .h = 32,
        .text_color = .{ .r = 20, .g = 20, .b = 20 },
    },
    .{
        .name = "page-fragment",
        .html_src = "<body><p>wezig paints text</p></body>",
        .css_src = "p { font-size: 16px; }",
        .viewport = 120,
        .w = 120,
        .h = 64,
        .background = .{ .rect = .{ .x = 2, .y = 2, .w = 116, .h = 60 }, .color = .{ .r = 250, .g = 248, .b = 240 } },
        .border = .{ .rect = .{ .x = 2, .y = 2, .w = 116, .h = 60 }, .widths = .{ .top = 2, .right = 2, .bottom = 2, .left = 2 }, .color = .{ .r = 150, .g = 120, .b = 60 } },
        .text_color = .{ .r = 30, .g = 30, .b = 40 },
    },
};

/// Render one golden `scene` to a fresh `Surface` (white background). The caller
/// owns and must `deinit` the returned surface. This is the ONE render path both
/// the golden generator and the golden tests use.
pub fn renderScene(gpa: std.mem.Allocator, scene: GoldenScene) !Surface {
    var surf = try Surface.init(gpa, scene.w, scene.h, .{ .r = 255, .g = 255, .b = 255 });
    errdefer surf.deinit();
    var be_impl = try StbSoftwareBackend.init(&surf);
    const be = be_impl.backend();

    if (be.vtable.beginFrame) |f| f(be.ptr);

    // Backgrounds/borders first (painter's algorithm), supplied above the seam.
    if (scene.background) |bg| StbSoftwareBackend.fillRect(&be_impl, bg.rect, bg.color);
    if (scene.border) |bd| StbSoftwareBackend.drawBorder(&be_impl, bd.rect, bd.widths, bd.color);

    // Lay the fixture out and paint its text runs through the seam.
    var diag = diagnostics.Diagnostics.init(gpa);
    defer diag.deinit(gpa);
    var doc = try html.parse(gpa, scene.html_src, &diag);
    defer doc.deinit();
    var styled = try css.styleDocument(gpa, &doc, scene.css_src, &diag);
    defer styled.deinit();
    var tree = try layout.layout(gpa, &styled, &doc, scene.viewport, be, &diag);
    defer tree.deinit();

    paintBox(be, tree.root, .{ .text = scene.text_color });

    if (be.vtable.present) |f| f(be.ptr);
    return surf;
}

/// Regenerate every committed golden PNG into `dir` (used by the golden
/// generator; NOT the test path). Overwrites existing references.
pub fn writeGoldens(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) !void {
    for (golden_scenes) |scene| {
        var surf = try renderScene(gpa, scene);
        defer surf.deinit();
        var buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ dir, scene.name });
        try surf.writePng(gpa, io, path);
    }
}

// ===========================================================================
// Tests: render fixtures to an OFFSCREEN surface and compare to golden PNGs.
// The test path is HEADLESS (no SDL/window). Goldens live in `src/testdata/`.
// ===========================================================================

const testing = std.testing;

test "measureRun sums real stb advances and returns face metrics" {
    const gpa = testing.allocator;
    var surf = try Surface.init(gpa, 4, 4, .{ .r = 255, .g = 255, .b = 255 });
    defer surf.deinit();
    var be = try StbSoftwareBackend.init(&surf);

    const m = be.backend().measureRun(.{
        .text = "Hi",
        .font = .{ .family = "sans-serif", .size_px = 32, .weight = "normal" },
    });
    // Real font metrics: positive width, ascent above + descent below baseline.
    try testing.expect(m.width > 0);
    try testing.expect(m.ascent > 0);
    try testing.expect(m.descent > 0);
    // Roboto is taller above the baseline than below.
    try testing.expect(m.ascent > m.descent);
}

test "wider text measures wider (advance accumulates)" {
    const gpa = testing.allocator;
    var surf = try Surface.init(gpa, 4, 4, .{ .r = 255, .g = 255, .b = 255 });
    defer surf.deinit();
    var be = try StbSoftwareBackend.init(&surf);
    const font = layout.Font{ .family = "serif", .size_px = 24, .weight = "normal" };
    const short = be.backend().measureRun(.{ .text = "i", .font = font });
    const long = be.backend().measureRun(.{ .text = "iiiii", .font = font });
    try testing.expect(long.width > short.width);
}

test "fillRect paints a solid background block onto the surface" {
    const gpa = testing.allocator;
    var surf = try Surface.init(gpa, 20, 20, .{ .r = 255, .g = 255, .b = 255 });
    defer surf.deinit();
    var be = try StbSoftwareBackend.init(&surf);

    StbSoftwareBackend.fillRect(&be, .{ .x = 5, .y = 5, .w = 10, .h = 10 }, .{ .r = 0, .g = 0, .b = 255 });
    // Centre pixel is blue, a corner outside the rect is still white.
    const centre = (10 * 20 + 10) * 4;
    try testing.expectEqual(@as(u8, 255), surf.pixels[centre + 2]);
    try testing.expectEqual(@as(u8, 0), surf.pixels[centre + 0]);
    try testing.expectEqual(@as(u8, 255), surf.pixels[0]); // top-left still white
}

test "drawBorder strokes only the four edges, leaving the interior clear" {
    const gpa = testing.allocator;
    var surf = try Surface.init(gpa, 20, 20, .{ .r = 255, .g = 255, .b = 255 });
    defer surf.deinit();
    var be = try StbSoftwareBackend.init(&surf);

    StbSoftwareBackend.drawBorder(&be, .{ .x = 2, .y = 2, .w = 16, .h = 16 }, .{ .top = 2, .right = 2, .bottom = 2, .left = 2 }, .{ .r = 255, .g = 0, .b = 0 });
    // A pixel on the top edge is red; the centre is untouched (white).
    const top_edge = (2 * 20 + 9) * 4;
    try testing.expectEqual(@as(u8, 255), surf.pixels[top_edge + 0]);
    try testing.expectEqual(@as(u8, 0), surf.pixels[top_edge + 1]);
    const centre = (9 * 20 + 9) * 4;
    try testing.expectEqual(@as(u8, 255), surf.pixels[centre + 1]); // green channel still 255 -> white
}

/// The per-channel tolerance golden comparisons allow (ADR-0003). Goldens are
/// produced by THIS rasteriser on the pinned toolchain, so the surface is
/// byte-identical in practice; a tiny tolerance absorbs only theoretical
/// rounding noise without hiding a real regression (a moved glyph or a wrong
/// colour shifts many pixels far past this).
const golden_tolerance: u8 = 2;

/// Embedded golden references (compared in memory, so the test path never
/// touches the disk and stays headless/CI-safe). Regenerate with
/// `zig build gen-goldens` after an intentional raster change.
const golden_bg_border = @embedFile("testdata/golden/bg-border.png");
const golden_text_line = @embedFile("testdata/golden/text-line.png");
const golden_page_fragment = @embedFile("testdata/golden/page-fragment.png");

/// Render `scene` and assert it matches the embedded `golden` PNG within
/// tolerance. This is the headless golden-image acceptance path.
fn expectGolden(gpa: std.mem.Allocator, scene: GoldenScene, golden: []const u8) !void {
    var surf = try renderScene(gpa, scene);
    defer surf.deinit();
    var ref = try surface.decodePng(gpa, golden);
    defer ref.deinit();
    const diff = surface.compare(&surf, &ref, golden_tolerance);
    if (!diff.equal) {
        std.debug.print(
            "golden '{s}' mismatch: {d} pixels differ, max channel delta {d}\n",
            .{ scene.name, diff.mismatched, diff.max_channel_delta },
        );
    }
    try testing.expect(diff.equal);
}

test "golden: background + border box paints to the reference surface" {
    try expectGolden(testing.allocator, golden_scenes[0], golden_bg_border);
}

test "golden: a laid-out text line paints to the reference surface" {
    try expectGolden(testing.allocator, golden_scenes[1], golden_text_line);
}

test "golden: the v0 page fragment (bg + border + wrapped text) matches" {
    try expectGolden(testing.allocator, golden_scenes[2], golden_page_fragment);
}

test "drawRun renders anti-aliased glyph coverage (not blank)" {
    const gpa = testing.allocator;
    var surf = try Surface.init(gpa, 60, 40, .{ .r = 255, .g = 255, .b = 255 });
    defer surf.deinit();
    var be = try StbSoftwareBackend.init(&surf);

    StbSoftwareBackend.drawRun(&be, .{
        .text = "Ag",
        .font = .{ .family = "sans-serif", .size_px = 28, .weight = "normal" },
    }, 4, 30, .{ .r = 0, .g = 0, .b = 0 });

    // Some pixels turned non-white (glyphs drew), and at least one is a partial
    // (anti-aliased) grey rather than pure black or pure white.
    var dark: usize = 0;
    var partial = false;
    var i: usize = 0;
    while (i < surf.pixels.len) : (i += 4) {
        const r = surf.pixels[i];
        if (r < 128) dark += 1;
        if (r > 0 and r < 255) partial = true;
    }
    try testing.expect(dark > 0);
    try testing.expect(partial);
}
