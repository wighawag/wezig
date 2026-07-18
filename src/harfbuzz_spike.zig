//! De-risking SPIKE (spec `explore-native-renderer`, story 2, decision 2):
//! prove that REAL text shaping via HarfBuzz (PINNED, ADR-0011 / CONTEXT.md
//! "C-library binding") works BEHIND the existing `PaintBackend` seam
//! (ADR-0002) on ONE non-trivial string, painting into the same offscreen
//! `Surface` the v0 goldens target (ADR-0003).
//!
//! This is NOT the text subsystem and NOT a migration of v0 text: it is the
//! narrowest real case (spec story 6) that proves the pinned library choice and
//! that the seam can host real shaping. The v0 `stb_truetype` glyph-by-glyph
//! path stays exactly where it is (`src/paint.zig`); this module lives beside
//! it as a SECOND `PaintBackend` implementation and is exercised only by its
//! own display-free test step (`zig build harfbuzz-shape-test`, folded into
//! `zig build test`). It is deliberately NOT re-exported from `src/root.zig`,
//! so HarfBuzz never enters the desktop library `mod` or the mobile
//! cross-compiles (which rebuild `root.zig` for their targets); see the
//! "## Why a separate module + step" note below.
//!
//! ## What "real shaping" buys over the v0 stb path (the load-bearing proof)
//!
//! The v0 `StbSoftwareBackend` walks the run one Unicode CODEPOINT at a time and
//! maps each to a glyph with `stbtt_FindGlyphIndex` (`src/paint.zig`). That is
//! NOT shaping: it cannot apply the font's GSUB substitutions, so the ASCII
//! sequence "ffi" in "office" renders as three separate glyphs `f`,`f`,`i`.
//! HarfBuzz, given the SAME ASCII bytes, applies the font's `liga` feature and
//! emits the `ffi`/`fi` LIGATURE glyph — a glyph the v0 path never produces for
//! that input. So "office" shapes to 5 glyphs through this backend vs the 6 the
//! stb path draws, and the painted pixels differ. That difference IS the proof
//! the shaping path is load-bearing (spec acceptance: "a rendering v0's stb
//! path cannot produce").
//!
//! ## FreeType observation (for `native-renderer-findings-and-build-plan`)
//!
//! Decision 2 LEANs FreeType to pair with HarfBuzz. This spike finds FreeType
//! is NOT needed YET: HarfBuzz does SHAPING (bytes -> positioned glyph IDs); the
//! rasteriser only needs to turn a GLYPH ID into coverage, and stb_truetype
//! already exposes glyph-INDEX rasterisation (`stbtt_GetGlyphBitmap` /
//! `stbtt_GetGlyphHMetrics` take a glyph index, not a codepoint). So the same
//! vendored stb face rasterises HarfBuzz's shaped glyph IDs with no new
//! rasteriser. FreeType becomes load-bearing later — hinting, colour/bitmap
//! fonts, correct sub-pixel/gamma, matching HarfBuzz's font metrics exactly —
//! but this narrowest-case shaping proof does not require it. Captured durably
//! for the findings task (`native-renderer-findings-and-build-plan`) in
//! `work/notes/findings/harfbuzz-freetype-not-needed-yet-2026-07-18.md`.
//!
//! ## Why a separate module + step (not folded into `src/paint.zig`)
//!
//! `src/paint.zig` links ONLY vendored stb (compiled by Zig) and is part of the
//! `wezig` library `mod`, which is ALSO recompiled for the iOS/Android targets
//! (`build.zig` MobileLib). HarfBuzz here is a SYSTEM library resolved via
//! pkg-config; linking it into `mod` would drag it into every mobile
//! cross-compile and the desktop consumers. Keeping the spike in its own module
//! + test executable (which links harfbuzz for the HOST only) contains the
//! pinned-library proof to exactly where it is proven, matching how the webview
//! shell keeps WebKitGTK out of `mod` (build.zig `ShellBuild`). The eventual
//! REAL backend (the mature SDL+FreeType+HarfBuzz+Skia stack, ADR-0001) will
//! decide its own linking; that is a build spec, not this spike.

const std = @import("std");
const wezig = @import("wezig");

const layout = wezig.layout;
const surface = wezig.surface;
const paint = wezig.paint;

const PaintBackend = layout.PaintBackend;
const TextRun = layout.TextRun;
const RunMetrics = layout.RunMetrics;
const Color = layout.Color;
const Surface = surface.Surface;

/// stb_truetype for GLYPH-INDEX rasterisation of HarfBuzz's shaped output (see
/// the FreeType note above: HarfBuzz shapes, stb rasterises the shaped glyph
/// IDs — no FreeType needed for this spike). Same vendored header the v0 path
/// uses.
const stb = @cImport({
    @cInclude("stb_truetype.h");
});

/// HarfBuzz (PINNED, decision 2). The shaping engine: bytes + font -> a run of
/// positioned glyph IDs with the font's GSUB/kern features applied.
const hb = @cImport({
    @cInclude("hb.h");
});

/// The same embedded v0 face the stb path uses (`src/paint.zig`), so this spike
/// and the v0 path shape/raster the SAME font bytes — the only variable is
/// HarfBuzz shaping vs stb codepoint-by-codepoint. Roboto Regular carries a
/// `liga` GSUB table, which is what makes the "office" ligature proof possible.
const embedded_font = @embedFile("assets/Roboto-Regular.ttf");

/// One shaped glyph crossing out of the shaper: a GLYPH ID (not a codepoint)
/// plus its pen advance and offset, in font design units at the shaping size.
pub const ShapedGlyph = struct {
    glyph_id: u32,
    /// Pen advance in CSS pixels for this glyph.
    x_advance: f32,
    x_offset: f32,
    y_offset: f32,
    /// The source byte cluster this glyph came from (HarfBuzz cluster value);
    /// exposed so the ligature proof can assert clusters merged.
    cluster: u32,
};

/// A `PaintBackend` (ADR-0002) whose glyph selection is REAL HarfBuzz shaping,
/// rasterised into an offscreen `Surface` via stb glyph-index bitmaps. Same
/// seam as `StbSoftwareBackend`; the only method that behaves differently is the
/// text path (`measureRun`/`drawRun`), which shapes instead of walking
/// codepoints. Backgrounds/borders reuse the v0 software fills conceptually but
/// this spike only needs the text path, so `fillRect`/`drawBorder` are left
/// unwired (this backend paints text only).
pub const HarfBuzzShapedBackend = struct {
    surface: *Surface,
    stb_font: stb.stbtt_fontinfo,
    hb_blob: *hb.hb_blob_t,
    hb_face: *hb.hb_face_t,
    hb_font: *hb.hb_font_t,
    /// HarfBuzz font units per em (from the face); scales HB design-unit
    /// advances to CSS pixels alongside the run's `size_px`.
    units_per_em: f32,

    pub fn init(target: *Surface) error{ FontInit, ShaperInit }!HarfBuzzShapedBackend {
        var self: HarfBuzzShapedBackend = undefined;
        self.surface = target;

        // stb face (for glyph-index rasterisation of HB's shaped glyph IDs).
        const offset = stb.stbtt_GetFontOffsetForIndex(embedded_font, 0);
        if (stb.stbtt_InitFont(&self.stb_font, embedded_font, offset) == 0) return error.FontInit;

        // HarfBuzz face/font over the SAME bytes.
        const blob = hb.hb_blob_create(
            embedded_font.ptr,
            @intCast(embedded_font.len),
            hb.HB_MEMORY_MODE_READONLY,
            null,
            null,
        ) orelse return error.ShaperInit;
        const face = hb.hb_face_create(blob, 0) orelse {
            hb.hb_blob_destroy(blob);
            return error.ShaperInit;
        };
        const font = hb.hb_font_create(face) orelse {
            hb.hb_face_destroy(face);
            hb.hb_blob_destroy(blob);
            return error.ShaperInit;
        };
        self.hb_blob = blob;
        self.hb_face = face;
        self.hb_font = font;
        self.units_per_em = @floatFromInt(hb.hb_face_get_upem(face));
        return self;
    }

    pub fn deinit(self: *HarfBuzzShapedBackend) void {
        hb.hb_font_destroy(self.hb_font);
        hb.hb_face_destroy(self.hb_face);
        hb.hb_blob_destroy(self.hb_blob);
    }

    /// The `PaintBackend` seam value. Text methods are shaped; the rect methods
    /// are unwired (this spike paints text only).
    pub fn backend(self: *HarfBuzzShapedBackend) PaintBackend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = PaintBackend.VTable{
        .measureRun = measureRun,
        .drawRun = drawRun,
    };

    /// Shape `run` with HarfBuzz and return the positioned glyph IDs (caller
    /// owns the returned slice). This is the REAL shaping step: GSUB ligatures,
    /// kerning, and contextual substitutions the font declares are applied here,
    /// which the v0 codepoint path cannot do.
    pub fn shape(self: *HarfBuzzShapedBackend, gpa: std.mem.Allocator, run: TextRun) ![]ShapedGlyph {
        const buf = hb.hb_buffer_create() orelse return error.OutOfMemory;
        defer hb.hb_buffer_destroy(buf);
        hb.hb_buffer_add_utf8(buf, run.text.ptr, @intCast(run.text.len), 0, @intCast(run.text.len));
        // Let HarfBuzz infer script/direction/language from the text (fine for
        // this narrowest-case spike; a real subsystem would carry these from the
        // cascade / bidi).
        hb.hb_buffer_guess_segment_properties(buf);
        // Default features (includes `liga`): shape with the font's own tables.
        hb.hb_shape(self.hb_font, buf, null, 0);

        var n: c_uint = 0;
        const infos = hb.hb_buffer_get_glyph_infos(buf, &n);
        const positions = hb.hb_buffer_get_glyph_positions(buf, &n);

        // HarfBuzz reports advances in font design units; scale to CSS px.
        const px_per_unit = run.font.size_px / self.units_per_em;
        var out = try gpa.alloc(ShapedGlyph, n);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            out[i] = .{
                .glyph_id = infos[i].codepoint, // post-shaping this is a GLYPH ID
                .x_advance = @as(f32, @floatFromInt(positions[i].x_advance)) * px_per_unit,
                .x_offset = @as(f32, @floatFromInt(positions[i].x_offset)) * px_per_unit,
                .y_offset = @as(f32, @floatFromInt(positions[i].y_offset)) * px_per_unit,
                .cluster = infos[i].cluster,
            };
        }
        return out;
    }

    // --- PaintBackend vtable ------------------------------------------------

    /// Measure a run: sum of HarfBuzz shaped advances + the face's scaled
    /// vertical metrics. Because the advances come from the SHAPED run, a
    /// ligature's single advance replaces its component advances — the measured
    /// width reflects real shaping, not a per-codepoint sum.
    fn measureRun(ctx: *anyopaque, run: TextRun) RunMetrics {
        const self: *HarfBuzzShapedBackend = @ptrCast(@alignCast(ctx));
        // A short-lived arena so measureRun stays allocation-clean for callers.
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const glyphs = self.shape(arena.allocator(), run) catch return .{ .width = 0, .ascent = 0, .descent = 0 };
        var width: f32 = 0;
        for (glyphs) |g| width += g.x_advance;

        const scale = stb.stbtt_ScaleForPixelHeight(&self.stb_font, run.font.size_px);
        var ascent: c_int = 0;
        var descent: c_int = 0;
        var line_gap: c_int = 0;
        stb.stbtt_GetFontVMetrics(&self.stb_font, &ascent, &descent, &line_gap);
        return .{
            .width = width,
            .ascent = @as(f32, @floatFromInt(ascent)) * scale,
            .descent = @as(f32, @floatFromInt(-descent)) * scale,
        };
    }

    /// Draw a shaped run with its baseline origin at `(x, baseline_y)`. Each
    /// SHAPED glyph ID is rasterised by stb via `stbtt_GetGlyphBitmap` (the
    /// glyph-INDEX raster path — no FreeType needed, see the module note) and
    /// blended as `color` scaled by coverage.
    fn drawRun(ctx: *anyopaque, run: TextRun, x: f32, baseline_y: f32, color: Color) void {
        const self: *HarfBuzzShapedBackend = @ptrCast(@alignCast(ctx));
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const glyphs = self.shape(arena.allocator(), run) catch return;
        const scale = stb.stbtt_ScaleForPixelHeight(&self.stb_font, run.font.size_px);
        var pen_x = x;
        for (glyphs) |g| {
            self.drawGlyphIndex(@intCast(g.glyph_id), scale, pen_x + g.x_offset, baseline_y - g.y_offset, color);
            pen_x += g.x_advance;
        }
    }

    /// Rasterise ONE glyph BY GLYPH INDEX (HarfBuzz's shaped output) and blend
    /// it. This is the crux of the FreeType observation: stb rasterises a shaped
    /// glyph ID directly, so no second rasteriser is needed for this spike.
    fn drawGlyphIndex(self: *HarfBuzzShapedBackend, gid: c_int, scale: f32, pen_x: f32, baseline_y: f32, color: Color) void {
        var w: c_int = 0;
        var h: c_int = 0;
        var xoff: c_int = 0;
        var yoff: c_int = 0;
        const bitmap = stb.stbtt_GetGlyphBitmap(&self.stb_font, scale, scale, gid, &w, &h, &xoff, &yoff);
        if (bitmap == null) return;
        defer stb.stbtt_FreeBitmap(bitmap, null);
        if (w <= 0 or h <= 0) return;

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
};

// ===========================================================================
// Spike tests (display-free; run via `zig build harfbuzz-shape-test`, folded
// into `zig build test`). These are the acceptance proof for the task: real
// shaping behind the seam, painting into the offscreen Surface, DIFFERING from
// the stb v0 path.
// ===========================================================================

const testing = std.testing;

/// The one non-trivial string: "office" contains the ASCII sequence "ffi",
/// which Roboto's `liga` GSUB collapses into a ligature glyph under real
/// shaping. The v0 stb path (codepoint-by-codepoint) cannot do this.
const shaping_proof_text = "office";
const shaping_font = layout.Font{ .family = "sans-serif", .size_px = 32, .weight = "normal" };

test "HarfBuzz shapes 'office' to fewer glyphs than codepoints (ligature applied)" {
    const gpa = testing.allocator;
    var surf = try Surface.init(gpa, 4, 4, .{ .r = 255, .g = 255, .b = 255 });
    defer surf.deinit();
    var be = try HarfBuzzShapedBackend.init(&surf);
    defer be.deinit();

    const glyphs = try be.shape(gpa, .{ .text = shaping_proof_text, .font = shaping_font });
    defer gpa.free(glyphs);

    // "office" is 6 codepoints; real shaping merges "ffi" -> a ligature, so the
    // shaped run has FEWER glyphs than the byte/codepoint count. The v0 stb path
    // always draws one glyph per codepoint, so this count alone is a rendering
    // it cannot produce.
    try testing.expectEqual(@as(usize, 6), shaping_proof_text.len);
    try testing.expect(glyphs.len < shaping_proof_text.len);

    // The ligature glyph spans a MERGED cluster: at least two input bytes share
    // one output glyph (the defining property of a ligature substitution).
    var merged = false;
    for (glyphs, 0..) |g, i| {
        const next_cluster = if (i + 1 < glyphs.len) glyphs[i + 1].cluster else @as(u32, shaping_proof_text.len);
        if (next_cluster - g.cluster > 1) merged = true;
    }
    try testing.expect(merged);
}

test "the HarfBuzz shaped glyph ID is not reachable by the v0 codepoint path for this input" {
    const gpa = testing.allocator;
    var surf = try Surface.init(gpa, 4, 4, .{ .r = 255, .g = 255, .b = 255 });
    defer surf.deinit();
    var be = try HarfBuzzShapedBackend.init(&surf);
    defer be.deinit();

    const glyphs = try be.shape(gpa, .{ .text = shaping_proof_text, .font = shaping_font });
    defer gpa.free(glyphs);

    // Find the ligature glyph (the one whose cluster spans >1 input byte).
    var lig_gid: ?u32 = null;
    for (glyphs, 0..) |g, i| {
        const next_cluster = if (i + 1 < glyphs.len) glyphs[i + 1].cluster else @as(u32, shaping_proof_text.len);
        if (next_cluster - g.cluster > 1) lig_gid = g.glyph_id;
    }
    try testing.expect(lig_gid != null);

    // The v0 stb path selects glyphs with stbtt_FindGlyphIndex on each ASCII
    // codepoint of "office". None of those direct mappings yields the ligature
    // glyph — proving real shaping (GSUB), not codepoint lookup, produced it.
    for (shaping_proof_text) |ch| {
        const direct = stb.stbtt_FindGlyphIndex(&be.stb_font, ch);
        try testing.expect(@as(u32, @intCast(direct)) != lig_gid.?);
    }
}

test "shaped run paints into the offscreen Surface and DIFFERS from the v0 stb path" {
    const gpa = testing.allocator;
    const w: u32 = 140;
    const h: u32 = 48;

    // HarfBuzz-shaped render (this spike, behind the seam).
    var hb_surf_target = try Surface.init(gpa, w, h, .{ .r = 255, .g = 255, .b = 255 });
    defer hb_surf_target.deinit();
    var hb_be = try HarfBuzzShapedBackend.init(&hb_surf_target);
    defer hb_be.deinit();
    hb_be.backend().vtable.drawRun.?(hb_be.backend().ptr, .{ .text = shaping_proof_text, .font = shaping_font }, 4, 34, .{ .r = 0, .g = 0, .b = 0 });

    // v0 stb render (the fallback path, UNCHANGED, still present).
    var stb_surf = try Surface.init(gpa, w, h, .{ .r = 255, .g = 255, .b = 255 });
    defer stb_surf.deinit();
    var stb_be = try paint.StbSoftwareBackend.init(&stb_surf);
    stb_be.backend().vtable.drawRun.?(stb_be.backend().ptr, .{ .text = shaping_proof_text, .font = shaping_font }, 4, 34, .{ .r = 0, .g = 0, .b = 0 });

    // Both actually drew text (some dark pixels).
    try testing.expect(darkPixelCount(&hb_surf_target) > 0);
    try testing.expect(darkPixelCount(&stb_surf) > 0);

    // The two renders DIFFER: the ligature reshapes the run, so pixels move.
    // This is the load-bearing proof — the shaped output is a rendering the v0
    // stb path does not produce.
    var differing: usize = 0;
    var i: usize = 0;
    while (i < hb_surf_target.pixels.len) : (i += 4) {
        if (hb_surf_target.pixels[i] != stb_surf.pixels[i]) differing += 1;
    }
    try testing.expect(differing > 0);
}

/// Count pixels darker than mid-grey in the red channel (a proxy for "text was
/// drawn here").
fn darkPixelCount(surf: *const Surface) usize {
    var dark: usize = 0;
    var i: usize = 0;
    while (i < surf.pixels.len) : (i += 4) {
        if (surf.pixels[i] < 128) dark += 1;
    }
    return dark;
}
