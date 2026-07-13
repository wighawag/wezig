---
title: Paint — SDL3 + stb software backend to a window
slug: paint-sdl3-stb-window
spec: wezig-browser
blockedBy: [layout-block-inline]
covers: [4]
---

## What to build

Realize the full `PaintBackend` seam with a concrete `StbSoftwareBackend` (stb_truetype for glyphs + software rasterization) plus SDL3 for the window and present, and paint the box tree — backgrounds, borders, and text — to an on-screen window. This is the first task with a real C dependency (SDL3 linked through Zig's build system; stb_truetype as a single-header binding). The backend implements the interface introduced by the layout task: `measureRun`, `drawRun`, `fillRect`, `drawBorder`, `beginFrame`/`present`. A text run reaching `drawRun`/`measureRun` carries its resolved font (family/size/weight) from the computed styles (the contract pinned by `layout-block-inline`), so this backend does glyph selection + shaping + raster from the run alone. Shaping and raster live entirely BELOW the seam, so the later SDL+FreeType+HarfBuzz+Skia backend can replace `StbSoftwareBackend` with zero caller changes. Tests are golden-image comparisons against the backend's rendered SURFACE (headless — render to an offscreen buffer and compare to a reference image; no on-screen window needed for the test). The on-screen SDL3 window is the app entrypoint path.

## Acceptance criteria

- [ ] `StbSoftwareBackend` implements the full `PaintBackend` interface (`measureRun`, `drawRun`, `fillRect`, `drawBorder`, `beginFrame`/`present`).
- [ ] SDL3 is linked via `build.zig` and opens a window; stb_truetype supplies glyph rasterization.
- [ ] The box tree paints to a surface: backgrounds, borders, and text render correctly for the v0 fixtures.
- [ ] Golden-image tests compare the backend's OFFSCREEN rendered surface to reference images (headless; no on-screen window in the test path).
- [ ] The paint stack is a clean backend swap: no caller above the seam depends on SDL3/stb specifics (a future Skia backend could replace it).
- [ ] Tests cover the new behaviour, mirroring the repo's test style.

## Blocked by

- `layout-block-inline` (needs the box tree and the `PaintBackend` interface it introduced).

## Prompt

> Goal: paint the box tree to pixels — the v0 "a real page fragment appears on screen" milestone. Decisions already made (do not re-litigate): (1) v0 paint stack = SDL3 (window/input/present) + stb_truetype (glyphs) + software rasterization, deliberately the LIGHT path — NOT FreeType/HarfBuzz/Skia yet. (2) It sits behind the `PaintBackend`/`Canvas` seam introduced by `layout-block-inline`; you implement `StbSoftwareBackend` satisfying that interface, with shaping + raster entirely BELOW the seam, so the future SDL+FreeType+HarfBuzz+Skia backend is a drop-in replacement with zero caller changes. (3) SDL version is SDL3.
>
> This is the first real C binding — expect the risk to be in linking/toolchain (SDL3 via `build.zig`, stb_truetype single-header), so isolate and diagnose that here. SDL3 is linked and stb_truetype registered in the SAME `build.zig` the scaffold task created — add them as additive edits. A text run you receive already carries its resolved font (per the `layout-block-inline` run/font contract); do NOT re-resolve font properties above the seam. TEST via golden images against an OFFSCREEN surface (render to a buffer, compare to a reference PNG) so the test path is HEADLESS and CI-safe — do NOT require an on-screen window to run tests; the on-screen SDL3 window is the app entrypoint, not the test path. Keep the v0 fixture set small so reference images stay maintainable (the spec calls this out).
>
> Domain vocabulary (paint/compositor, C-library binding): `CONTEXT.md`. The `PaintBackend` interface is from `layout-block-inline` — implement it, do not redesign it. "Done" = v0 fixtures paint to a window on screen AND golden-image tests pass headlessly against the offscreen surface.
>
> RECORD non-obvious in-scope decisions durably: the SDL3 linking approach for this Zig version, the stb_truetype binding shape, and the golden-image tolerance/format — an ADR is warranted for the C-linking approach since it is hard to reverse and future backends build on it.
