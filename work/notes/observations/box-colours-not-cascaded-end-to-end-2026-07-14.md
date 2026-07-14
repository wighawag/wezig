---
title: block-box background/border colours are not cascaded end-to-end in v0
date: 2026-07-14
status: open
kind: follow-up
relatesTo: [css-parse-and-cascade, layout-block-inline, paint-sdl3-stb-window]
---

## What was noticed

The v0 render pipeline paints TEXT from real computed styles (the run carries its resolved font family/size/weight across the `PaintBackend` seam), but block-box **background and border colours are NOT resolved from the cascade**. In `src/paint.zig`, `paintBox` leaves `.block` / `.inline_box` / `.anonymous` boxes transparent and only draws text; the background/border colours used by the golden fixtures are **caller-supplied** via `PaintStyle` / `GoldenScene`, not read from computed styles.

This is forced by the current v0 computed-style set: `css-parse-and-cascade` carries `display`, `color`, `background-color`, `font-*`, `width`, `height`, `margin`, `padding` as computed values, but `border` is absent and `background-color` / `color` are not threaded THROUGH layout into the box tree the painter consumes. So each task is correct in isolation (all four passed their acceptance criteria), but end-to-end a real `<div style="background-color: red; border: 1px solid black">` would not paint red-with-a-black-border from the cascade alone; the colour has to be supplied above the seam.

Documented in ADR-0003 and in the `paint-sdl3-stb-window` review nits (`review-nits-paint-sdl3-stb-window-2026-07-14.md`, first bullet).

## Decision (ratified by the human)

ACCEPT for v0. This is within the documented v0 slice, not a regression. Box background/border colours being caller-supplied rather than cascaded end-to-end is a known v0 limit. The `document-v0-subset-limits` doc MUST state this explicitly so "v0 works" is honest about it.

## Suggested follow-up (v0.1, NOT this milestone)

A future task should thread `color` / `background-color` (already computed) and a `border-*` property set through layout into the box tree so `paintBox` resolves box colours from computed styles, removing the above-seam `PaintStyle` shim. That would make the fixtures cascade-driven end-to-end. Scoped as v0.1; deliberately NOT expanded into the current v0 chain.
