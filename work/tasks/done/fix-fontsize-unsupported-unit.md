---
title: font-size must emit unsupported_unit for non-px units
slug: fix-fontsize-unsupported-unit
spec: browser
blockedBy: [layout-block-inline]
covers: [3]
---

## What to build

Close a diagnostic-consistency gap left by `layout-block-inline`. In `src/layout.zig`, `parseLength` (used for `width`/`height`/`margin`/`padding`) correctly emits an `unsupported_unit` diagnostic when it sees a non-`px`/`%` unit like `em`/`rem`/`vw`/`vh`/`ch`/`pt`, then falls back. But `parseFontSize` (used for a run's resolved `font-size`) **silently** falls back to 16px for a non-`px` unit and emits **no diagnostic**. This contradicts the acceptance criterion "unsupported units emit `unsupported_unit`" and the `src/layout.zig` module header (which claims any non-`px`/`%` unit emits the diagnostic).

Make `parseFontSize` emit `unsupported_unit` (via the `Diagnostics` sink, same severity/shape as `parseLength`) when the `font-size` value carries a unit that is neither `px` nor a bare number, THEN fall back to its 16px default. Bare-number and `px` values keep their current behaviour (no diagnostic). Do NOT change any other layout behaviour, the `PaintBackend` seam, or the box-tree output; this is a narrow diagnostic-parity fix.

The mechanical catch: `parseFontSize` currently has no access to the `Diagnostics` sink (it takes only the value string and returns `f32`). Thread the sink (and the gpa the sink needs) into `parseFontSize` and its call site the same way `parseLength` receives them, keeping the change local. `%` and other non-length `font-size` values (e.g. `larger`, `2em`) are all "unsupported unit" for v0 font-size resolution and should emit the code.

## Acceptance criteria

- [ ] `font-size` with a non-`px` unit (e.g. `font-size: 2em`, `1.5rem`, `120%`) emits `unsupported_unit` through the `Diagnostics` sink and falls back to the 16px default.
- [ ] `font-size` in `px` (e.g. `font-size: 20px`) and a bare number resolve as before and emit NO diagnostic.
- [ ] The `src/layout.zig` module header's claim that all non-`px`/`%` units emit `unsupported_unit` is now true for `font-size` too (update the comment if it singled font-size out).
- [ ] A test asserts `font-size: 2em` (or similar) yields `unsupported_unit` in the collected diagnostics AND the run still measures at the 16px fallback; a `px` font-size test asserts NO such diagnostic.
- [ ] No change to box-tree positions/sizes, the `PaintBackend` interface, or any other diagnostic; the existing layout tests still pass.
- [ ] Tests cover the new behaviour, mirroring the repo's test style.

## Blocked by

- `layout-block-inline` (this amends `parseFontSize` in the `src/layout.zig` it created).

## Prompt

> Goal: make the `unsupported_unit` diagnostic contract UNIFORM. Right now `parseLength` emits it for non-px/% units but `parseFontSize` silently swallows them (returns 16px, no code). This was flagged in the `layout-block-inline` Gate-2 review nits and RATIFIED by the human as a bug to fix (Q1, option A). Decisions already made (do not re-litigate): a non-`px` `font-size` unit (`em`/`rem`/`vw`/`vh`/`ch`/`pt`/`%`/keywords) is UNSUPPORTED in v0 and MUST emit `unsupported_unit`, then fall back to the 16px default — exactly the emit-then-fallback shape `parseLength` already uses. Keep the change surgical: thread the `Diagnostics` sink (+ gpa) into `parseFontSize`, emit the code on the unsupported branch, update the header comment that singled font-size out, and add a focused test. Do NOT touch the box model, the `PaintBackend` seam, or any other behaviour.
>
> Push the diagnostic through the existing `Diagnostics` sink with the same `.warning` severity `parseLength` uses. Test at the same seam the layout tests use: given an HTML+CSS fixture with a `font-size: 2em` (or similar), assert `unsupported_unit` is collected AND the run measures at the 16px fallback; assert a `px` font-size emits nothing. Domain vocabulary: `CONTEXT.md`. "Done" = the font-size path emits `unsupported_unit` for unsupported units, the header comment is accurate, the new test passes, and every existing layout test still passes unchanged.
