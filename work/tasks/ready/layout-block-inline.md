---
title: Layout — block + inline boxes with text
slug: layout-block-inline
spec: wezig-browser
blockedBy: [css-parse-and-cascade]
covers: [3]
---

## What to build

Turn the styled DOM into a box tree with real positions and sizes: block flow (boxes stack vertically) and inline flow (text + inline boxes flow into line boxes and wrap at the container width), with the full box model (content / padding / border / margin) and `width`/`height`. Line-breaking needs text measurement, so this task introduces the `PaintBackend` interface's `measureRun` method and drives wrapping decisions through it; tests use a headless/stub backend for measurement (no window yet — the real SDL3/stb backend is the next task). A **text run carries its resolved font** (family / size / weight, from the cascade's computed styles): `measureRun` (and later `drawRun`) receive the run WITH its font, so shaping/measurement below the seam has everything it needs and layout never re-resolves font properties. Supported units: `px` and `%`-width (against the containing block). Documented v0 limits, each surfaced via a diagnostic or the limits doc: NO margin collapsing, NO floats/`clear`, `position: static` only, NO flex/grid/table, NO `overflow` scrolling. Unsupported units (`em`/`rem`/`vw`/…) emit `unsupported_unit`.

## Acceptance criteria

- [ ] A box tree is produced from the styled DOM: block boxes stack vertically; inline content flows into line boxes and wraps at the container width.
- [ ] The full box model (content/padding/border/margin) and `width`/`height` are honoured; units `px` and `%`-width are supported.
- [ ] The `PaintBackend` interface is introduced with (at least) `measureRun`; a text run passed to it carries its resolved font (family/size/weight) from the computed styles; layout drives line-breaking through it; a headless/stub backend supplies measurements in tests.
- [ ] v0 limits hold and are visible: no margin-collapse, no floats, static-only positioning, no flex/grid/table, no overflow-scroll; unsupported units emit `unsupported_unit`.
- [ ] Tests at the layout seam: given HTML+CSS fixtures, assert the box tree's positions/sizes (and diagnostic codes) — the spec's named stable seam.
- [ ] Tests cover the new behaviour, mirroring the repo's test style.

## Blocked by

- `css-parse-and-cascade` (needs computed styles, including resolved `display` and box-model properties).

## Prompt

> Goal: lay out the styled DOM into a box tree with real positions and sizes. Decisions already made (do not re-litigate): (1) v0 does block flow + inline flow WITH line-breaking + the full box model + `width`/`height`. (2) Line-breaking requires text measurement, so introduce the `PaintBackend` interface HERE with `measureRun` (shaping lives BELOW this seam — layout only asks "how wide is this run"); use a headless/stub backend for measurement in tests. The next task (`paint-sdl3-stb-window`) supplies the real SDL3 + stb_truetype backend behind the SAME interface. (3) Units: `px` + `%`-width only; `em`/`rem`/`vw`/`vh`/`ch` → `unsupported_unit`. (4) Documented v0 limits: NO margin collapsing, NO floats/`clear`, `position: static` only, NO flex/grid/table, NO overflow scrolling.
>
> The `PaintBackend` seam is the load-bearing design here: define it so `measureRun` (this task) and the drawing methods (`drawRun`, `fillRect`, `drawBorder`, `beginFrame`/`present` — next task) form one interface a stub backend and a real SDL3/stb backend both satisfy, and later a Skia/HarfBuzz/FreeType backend satisfies unchanged. Pin the RUN/FONT contract now: a text run passed across the seam carries its resolved font (family/size/weight) taken from the cascade's computed styles, so the backend owns shaping+measurement with no upward font re-resolution. This is what makes 'shaped text' (story 4) a clean backend responsibility. Push boundary diagnostics through the `Diagnostics` sink. Test at the LAYOUT seam (spec's stable seam): given HTML+CSS, assert box-tree positions/sizes — the spec's testing decisions prefer this over internal structures.
>
> Domain vocabulary (layout, box tree, block/inline flow, paint/compositor): `CONTEXT.md`. Reusing `zss` for layout is a DEFERRED evaluation, not this task — build the thin v0 layout in-house. "Done" = fixtures produce a box tree with the expected positions/sizes and diagnostics, and `PaintBackend.measureRun` is exercised via the stub backend.
>
> RECORD non-obvious in-scope decisions (the exact `PaintBackend` interface shape, how `%`-width resolves against the containing block, line-box baseline handling) durably — the interface shape especially, since the next task and future Skia backend depend on it (an ADR is warranted if the interface is hard to change later).
