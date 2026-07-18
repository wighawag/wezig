---
title: Split the Toolkit seam into chrome-surface + host/loop halves (mobile lifecycle inversion)
slug: mobile-toolkit-seam-split
spec: explore-mobile-shell
blockedBy: []
covers: [7]
---

## What to build

Resolve the mobile chrome-host/lifecycle mismatch (spec Q4/story 7) by splitting the pinned `Toolkit` seam along the axis that actually differs desktop↔mobile — WITHOUT changing `chrome.zig`. Today `Toolkit` bundles two concerns; on mobile the OS owns the window + run loop, so the desktop shape (`createWindow`/`present`/`run`/`quit`) cannot be honestly implemented.

Split `Toolkit` into two halves:
- **chrome-surface** — the widgets + intents BOTH platforms implement: `embedView`, `setUrlText`, `setBackEnabled`/`setForwardEnabled`, `setChromeCallback`.
- **host/loop** — desktop-only windowing + main loop: `createWindow`, `present`, `run`, `quit`. On mobile the OS IS the host (chrome lives in a `UIViewController`/`Activity`), so a mobile toolkit implements only the chrome-surface half.

`GtkToolkit` composes BOTH halves (unchanged behaviour); the `FakeToolkit` and the chrome↔toolkit contract tests keep passing. The chrome keeps talking only to the seam(s); the conformance guard (no `gtk_`/`webkit_` in the chrome) stays green. Record the split + its rationale in an ADR (this is a real, if small, refinement of a pinned interface — do it now on the mobile spike's evidence, the same discipline ADR-0006 used for deferring input/scroll until a second backend forces the shape).

## Acceptance criteria

- [ ] `Toolkit` is split into a chrome-surface concern (embedView + URL/button widgets + chrome callback) and a host/loop concern (createWindow/present/run/quit); the split is expressed so a backend can implement chrome-surface WITHOUT host/loop.
- [ ] `GtkToolkit` composes both halves; its desktop behaviour is unchanged and `zig build shell` / `shell-test` still work through the seam(s).
- [ ] `FakeToolkit` and the existing chrome↔toolkit contract tests still pass in the display-free `zig build test` gate (adapt them to the split shape).
- [ ] `src/chrome.zig` is UNCHANGED in what it depends on (it still reaches neither `gtk_` nor `webkit_`); the `chrome_conformance` check stays green.
- [ ] An ADR records the two-halves split, why (the OS-owned-run-loop inversion on mobile), and that a mobile toolkit implements only the chrome-surface half.
- [ ] The full v0 gate (`zig fmt --check` + `zig build` + `zig build test`) stays green.
- [ ] Tests cover the new seam shape (mirror the repo's `FakeToolkit`/`FakeRenderer` seam-contract style), headless in `zig build test`.

## Blocked by

- None — can start immediately. This is a pure-Zig seam refactor with desktop-only blast radius; it is the shared structure the per-platform mobile tasks build on, so it is sequenced FIRST and most other mobile tasks are `blockedBy` it.

## Prompt

> Goal: split the pinned `Toolkit` seam (spec `explore-mobile-shell`, Q4/story 7) into a **chrome-surface** half (embedView + URL-bar/back-forward widgets + chrome-intent callback) and a **host/loop** half (createWindow/present/run/quit), so a mobile toolkit can implement the surface without the desktop windowing/run-loop it cannot own. This is a DECIDED direction (see the spec's Resolved decisions §Q4): a SPLIT of `Toolkit`, NOT a brand-new seam.
>
> Do NOT change what `src/chrome.zig` depends on. The chrome must keep talking only to the seam(s) and reach neither `gtk_` nor `webkit_` (the `chrome_conformance` check enforces this and must stay green). `GtkToolkit` composes both halves with unchanged desktop behaviour; the desktop `zig build shell` / `shell-test` paths and the display-free `zig build test` seam-contract tests (`FakeToolkit`, `FakeRenderer`) must all still pass — adapt the fakes/tests to the split shape.
>
> Read for context/vocabulary: `CONTEXT.md`; the `Toolkit` seam and its ADR (the two-seams pinning, ADR-0006); the `Renderer` seam file for the sibling shape; `chrome.zig` + the conformance guard. Record the split and its rationale (the mobile OS-owned-window/run-loop inversion) in a new `docs/adr/` entry — this refines a pinned interface, so the WHY must be durable. This is exploration: make the seam able to carry mobile, do not build any mobile backend here. "Done" = `Toolkit` splits cleanly into the two halves, GtkToolkit + chrome + conformance + the v0 gate stay green, and an ADR pins the split.
