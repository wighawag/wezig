---
source: The `spike-harfbuzz-shaping` spike itself (src/harfbuzz_spike.zig + build.zig `harfbuzz-shape-test`), verified against HarfBuzz 10.2.0 (pkg-config) + the vendored stb_truetype v1.26 and Roboto-Regular.ttf on the dev box.
---

# HarfBuzz shaping behind `PaintBackend` does NOT need FreeType YET (for `native-renderer-findings-and-build-plan`)

Verified while running the `spike-harfbuzz-shaping` spike (spec
`explore-native-renderer`, story 2, decision 2). Decision 2 LEANs FreeType to
pair with HarfBuzz; this spike finds FreeType is **not required for the shaping
proof itself**, and records why — and where it *does* become load-bearing later.

## What the spike actually needed

HarfBuzz does **shaping**: bytes + font → a run of positioned **glyph IDs**
(GSUB ligatures / kerning / contextual substitution applied). The rasteriser's
only remaining job is "glyph ID → coverage bitmap". stb_truetype already exposes
that BY GLYPH INDEX:

- `stbtt_GetGlyphBitmap(info, sx, sy, glyph_index, …)` rasterises a shaped
  glyph ID directly (the v0 path only ever used the *codepoint* wrappers
  `stbtt_GetCodepointBitmap` / `stbtt_FindGlyphIndex`).
- `stbtt_GetGlyphHMetrics(info, glyph_index, …)` and `stbtt_GetFontVMetrics`
  cover the metrics.

So the SAME vendored stb face rasterises HarfBuzz's shaped output with **no new
rasteriser and no FreeType**. The spike paints the "office" `ffi`/`fi` ligature
glyph (gid 1834, a glyph the v0 codepoint path never selects for that ASCII
input) into the offscreen `Surface` using stb glyph-index bitmaps, and it
differs pixel-for-pixel from the v0 stb render — proof the shaping path is
load-bearing, achieved without FreeType.

## Where FreeType DOES become load-bearing (do not skip it in the build plan)

FreeType is still the leant rasteriser for the REAL text subsystem; this spike
just does not force it. It becomes necessary when the build plan needs:

- **Hinting / grid-fitting** at small sizes — stb's rasteriser has no hinting;
  FreeType (autohinter / bytecode) is what makes body text crisp.
- **Colour / bitmap / `CBDT`/`sbix`/`COLR`-`CPAL` fonts and emoji** — stb does
  not rasterise these; FreeType does.
- **Exact metric agreement with HarfBuzz.** This spike scales HB's design-unit
  advances by the face `units_per_em` and rasterises with a *separately* derived
  stb pixel scale. That is fine for one string, but the production path wants ONE
  source of truth for glyph outlines + metrics; the canonical pairing is
  HarfBuzz shaping over a FreeType `FT_Face` (`hb_ft_font_create`), so shaper and
  rasteriser share identical metrics/hinting. Two independent rasterisers
  (stb for raster, HB for metrics) is a spike shortcut, not a subsystem design.
- **Sub-pixel positioning / gamma-correct AA** consistent with the rest of the
  mature stack (FreeType + Skia).

## Recommendation for the build plan

Pin FreeType as leant (unchanged), but sequence it AFTER the shaping-integration
slice: the first shaping milestone can stand on stb glyph-index raster to keep
the slice small; introduce FreeType at the milestone that needs hinting/colour
fonts/exact HB↔raster metric sharing (`hb_ft_font_create`). The spike proves the
`PaintBackend` seam (ADR-0002) already hosts real shaping with the glyph-ID
raster it has today, so FreeType is an additive raster upgrade behind the same
seam, not a prerequisite for proving shaping.
