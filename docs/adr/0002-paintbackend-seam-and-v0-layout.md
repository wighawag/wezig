# The `PaintBackend` seam and the v0 layout box model

The v0 layout engine (`src/layout.zig`) lays the styled DOM out into a box tree with real positions and sizes (block flow + inline flow with line-breaking + the full box model + `width`/`height`), and introduces the `PaintBackend` interface that the paint stack lives behind. This ADR pins the interface shape and the load-bearing layout resolution rules, because the next task (`paint-sdl3-stb-window`) and any future backend (Skia/HarfBuzz/FreeType) depend on the interface being stable, and it is hard to change once a second backend implements it.

## The `PaintBackend` interface (vtable)

`PaintBackend` is a vtable: a `*anyopaque` context plus a function-pointer table, exactly like `std.mem.Allocator`. This is the idiomatic Zig shape for a swappable backend and lets a headless stub (this task, for measurement in tests) and the real SDL3 + stb_truetype backend (next task) both satisfy one interface with no shared base type. The full method set is declared NOW so the paint task implements it without reshaping:

- `measureRun(run) -> RunMetrics`: REQUIRED. Layout drives line-breaking through this; it is the only method layout calls. Shaping and measurement live entirely below the seam.
- `drawRun`, `fillRect`, `drawBorder`, `beginFrame`, `present`: the drawing side, optional (`null` on the measurement stub), implemented by the paint task. Declared here so both backends satisfy the same interface.

### The run/font contract (pinned here)

A `TextRun` crossing the seam is `{ text: []const u8, font: Font }` where `Font = { family, size_px, weight }` is taken from the cascade's computed styles. Both `measureRun` and (later) `drawRun` receive the run WITH its font, so the backend owns glyph selection + shaping + measurement/raster with NO upward font re-resolution. This is what makes "shaped text" (story 4) a clean backend responsibility: a future HarfBuzz backend shapes from the run alone.

`RunMetrics = { width, ascent, descent }` in CSS pixels: `width` advances the pen; `ascent`/`descent` position glyphs around the line baseline. The stub backend (`StubBackend`) measures deterministically (each byte advances `advance_ratio * size_px`; ascent/descent are fixed ratios of `size_px`) so fixtures can predict wrap points without a real font.

## v0 layout resolution rules

- **`%`-width** resolves against the CONTAINING BLOCK's content width. The top-level containing block is the `viewport_width` passed into `layout`; a nested block's basis is its parent block's resolved content width. `%` is width-only in v0; `%` height / `%` padding / `%` margin are not supported (they resolve to their absolute default).
- **`auto` width** fills the containing block's content width minus this box's own horizontal margin/border/padding (the block-flow default). `width` in `px` is honoured exactly.
- **Line-box baseline**: a line box's height is `max(ascent) + max(descent)` over the runs on it; every run shares one baseline (`line_top + max_ascent`), so a taller run sits higher (smaller content-top `y`). Runs of different font sizes on one line therefore align on their baseline, not their tops.
- **Anonymous blocks** wrap consecutive inline-level children of a block container, matching the CSS anonymous-block rule; that anonymous box runs inline (line-box) layout.
- **Units**: `px` and `%` only. A bare number is treated as `px` (the cascade carries raw strings). Any other unit (`em`/`rem`/`vw`/`vh`/`ch`/`pt`/…) emits `unsupported_unit` through the `Diagnostics` sink and the length falls back to `auto`/`0`.

## Documented v0 limits (each visible)

No margin collapsing (adjacent vertical margins add), no floats/`clear`, `position: static` only, no flex/grid/table, no `overflow` scrolling. These are the v0 slice per ADR-0001 and the spec; the `document-v0-subset-limits` task writes them up.

## Considered options

- **A Zig `interface` via comptime duck-typing** (generic over a backend type): rejected because layout would become generic over the backend, and the paint task + tests want a single runtime-swappable value (stub vs SDL). The vtable keeps layout non-generic and the swap a value, matching `std.mem.Allocator`.
- **Fold measurement into layout with a font table**: rejected, since it would re-resolve fonts above the seam and duplicate the shaping the backend must own, breaking the clean "shaped text below the seam" split ADR-0001 committed to.

## Consequences

- The next task implements `drawRun`/`fillRect`/`drawBorder`/`beginFrame`/`present` on the SAME vtable and reads the run's font directly; no caller above the seam re-resolves fonts.
- The box tree (`Box`/`Dimensions`/`Edges`) is the stable layout-seam output tests assert on; `Dimensions.borderRect` already exposes the border-box rect the paint task fills.
- The stub advance model is deliberately linear and documented so fixture wrap points are predictable; it is not real text measurement, which is expected (the real metrics come from stb_truetype below the seam).
