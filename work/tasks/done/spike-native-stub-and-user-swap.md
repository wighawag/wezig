---
title: Spike the user-triggered renderer swap at the Renderer seam (native stub + per-domain-allow model)
slug: spike-native-stub-and-user-swap
spec: explore-native-renderer
blockedBy: []
covers: [4, 6]
---

## What to build

Prove decision 4's swap policy — **USER-CONTROLLED, NO automatic routing** — at
the `Renderer` seam (ADR-0005/0006) on the NARROWEST real case. This is a
de-risking spike of the swap MECHANISM + its data model, not the product feature.

The blocker the idea note (`work/notes/ideas/renderer-swap-toggle-in-chrome.md`)
flags is "there is no second backend to swap TO," so this spike supplies a
trivial one:

- **A native `WezigRenderer` static-page stub** behind the `Renderer` seam that
  paints ONE simple static page through the existing v0 layout/paint pipeline —
  the minimal real second backend the swap needs.
- **The user-triggered per-page swap** in ONE shell: the chrome re-points its
  single `Renderer` value + re-attaches lifecycle callbacks + re-navigates the
  current URL through the stub — driven by a MANUAL trigger (the long-press-reload
  toggle) with a visible engine indicator (webview vs wezig). The webview stays
  the DEFAULT; only the current page, only on explicit user action, renders
  native. `chrome_conformance` stays green (no seam change — a backend VALUE swap).
- **The per-domain-allow data model:** the schema for a persistent, user-controlled
  allow-list of domains that always render natively (data model + how the swap
  consults it). No automatic mismatch-based routing anywhere; fallback
  (native→webview) is MANUAL.

## Acceptance criteria

- [ ] A native `WezigRenderer` static-page stub paints one simple static page
      through the v0 layout/paint pipeline behind the `Renderer` seam.
- [ ] A MANUAL user trigger in one shell swaps the current page from the default
      webview backend to the native stub (re-point value + re-navigate), with a
      visible engine indicator; everything else stays webview.
- [ ] A per-domain-allow data model exists (schema + how the swap consults it) for
      domains that always render natively; there is NO automatic routing and
      fallback is manual.
- [ ] `chrome_conformance` stays green (the swap is a backend-value change, not a
      seam change).
- [ ] Tests cover the swap mechanism + the allow-list model per the repo's test
      style; the v0 build gate stays green. If the allow-list persists to a
      shared/global location, tests isolate it to a temp dir and assert the real
      one is untouched.

## Blocked by

- None — can start immediately.

## Prompt

> Goal: spike the USER-triggered renderer swap at the `Renderer` seam on the
> narrowest case (spec `explore-native-renderer`, story 4, decision 4). The policy
> is USER-CONTROLLED with NO automatic routing: the webview is the default; the
> native renderer is used only when the user opts in. This is a de-risking spike
> of the mechanism + data model, NOT the product feature.
>
> First read `work/notes/ideas/renderer-swap-toggle-in-chrome.md` — it already
> RESOLVES this as the primary manual swap mechanism and identifies the blocker:
> there is no second backend to swap to. So this task supplies a trivial native
> `WezigRenderer` static-page STUB that paints one simple static page through the
> existing v0 layout/paint pipeline, then wires the manual swap in ONE shell:
> the chrome holds ONE `Renderer` value (`src/chrome.zig`/`src/mobile_chrome.zig`)
> and talks only to the seam, so swapping is re-pointing that value + re-attaching
> lifecycle callbacks + re-navigating the current URL (ADR-0005). Add a manual
> trigger (long-press-reload toggle) + a visible engine indicator, and a
> per-domain-allow data model (a persistent user allow-list of domains that always
> render native). NO automatic mismatch routing; manual fallback only.
>
> Domain vocabulary + framing: `CONTEXT.md`, ADR-0005 (Renderer seam), ADR-0006
> (two seams pinned), ADR-0011 (explicit user-controlled trust boundaries),
> `chrome_conformance` (`src/chrome_conformance.zig`) which must stay green.
> This is exploration on the NARROWEST case (story 6): one page, one shell,
> prove-the-mechanism; do NOT build the full native renderer or the full chrome
> UX. "Done" = a user gesture swaps one page to a native stub and back, an engine
> indicator shows which painted, the per-domain-allow model is defined, tests
> pass, `chrome_conformance` + v0 gate green.
