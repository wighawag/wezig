---
title: review-gate non-blocking nits for 'paint-sdl3-stb-window' (Gate 2 approve)
date: 2026-07-14
status: open
reviewOf: paint-sdl3-stb-window
---

## Non-blocking review findings

The PR/code review gate (Gate 2) APPROVED 'paint-sdl3-stb-window' but raised the
following non-blocking findings (nits). They do not block integration; this
is their durable home for triage — promote-to-task / keep / delete.

- Ratify: block-box backgrounds/borders are painted ABOVE the seam via PaintStyle/GoldenScene, not resolved from the cascade. paintBox leaves block/inline/anonymous boxes transparent and only draws text; bg/border colours are supplied by the caller. Is caller-supplied colour the intended v0 shape until the cascade carries color/background-color/border?
  (src/paint.zig paintBox .block/.inline_box/.anonymous branch only recurses; GoldenScene + PaintStyle carry colours. Forced by v0 computed-style set lacking those properties; documented in ADR-0003 and code comments.)
- Ratify: in a headless environment main() logs and RETURNS the SDL error, so 'zig build run' exits non-zero when no display is present even though paint succeeded offscreen. Is a non-zero exit on a missing display the intended app behaviour vs exiting 0 with a warning?
  (src/main.zig showSurface catch logs then 'return err'.)
- PR description carried no ## Decisions block. The in-scope choices (from-source castholm/SDL port, vendored stb v1.26 + Roboto, PNG stored-block codec, tolerance=2, above-seam colour) are all captured in ADR-0003, but nothing was surfaced in the commit body for the human to ratify.
  (git log HEAD body is a single title line; decisions live only in docs/adr/0003.)
