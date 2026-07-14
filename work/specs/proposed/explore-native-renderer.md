---
title: Explore — the native renderer past v0 (pick the target, pin the libraries, spike the hard parts)
slug: explore-native-renderer
humanOnly: true
needsAnswers: true
taskedAfter: [browser]
---

> Launch snapshot — records intent at creation, NOT maintained. Current truth: `docs/adr/` (decisions) + the code; remaining work: `work/tasks/ready/` tasks.

> **This is an EXPLORATION-scoped spec.** Its deliverable is CONFIDENCE + a de-risked plan for growing `WezigRenderer` toward matching existing browsers — NOT the finished renderer (that is a decade-scale, Ladybird-class effort and is many follow-on build specs). It picks the conformance target, pins the C-library choices, and spikes the parts most likely to be hard or wrong (real text shaping behind `PaintBackend`; the progressive-swap routing at the `Renderer` seam; networking), each on the NARROWEST real case, so we can confidently say HOW the native renderer grows and WHERE it swaps in. The actual "implement WHATWG parsing / CSS grid / flexbox" work is scoped by follow-on build specs, informed by this exploration.

<!-- open-questions -->

## Open questions

These gate tasking this spec (`needsAnswers: true`). Exploration exists to answer them.

1. **Rendering conformance target** (was browser Q4). Pick the ambition and the yardstick: a Web Platform Tests percentage, a concrete "renders these N real sites" set, or "good enough for the on-chain apps we care about first." This sets how far to grow and how progress is measured against the webview backend. Deciding this IS a primary output of the exploration.
2. **Which C libraries, pinned** (was browser Q6). Ratify the picks as spikes prove them: rasterizer (Skia vs a lighter stb path — v0 uses stb_truetype + software raster), font shaping (HarfBuzz), glyph raster (FreeType vs stb_truetype), GPU/compositing (Dawn vs wgpu-native), networking (bind curl/a TLS lib vs write one). The exploration spikes the load-bearing ones (at least shaping + networking) rather than deciding on paper.
3. **JavaScript engine — write or bind** (was browser Q1). The single largest scope decision after core layout: write one in Zig (e.g. `kiesel`) or bind V8 / JavaScriptCore. The exploration does NOT build a JS engine; it evaluates and RECOMMENDS, so the build specs can commit. (Usability's JS comes from the webview backend, so this gates only the native renderer's dynamic-page support.)
4. **Progressive-swap policy.** ADR-0005 says the swap is per-capability or per-page-type: route what `WezigRenderer` handles to it, fall back to the webview otherwise. Spike the routing mechanism on one trivial case (a simple static page rendered natively, everything else via the webview) and decide how the routing + mismatch-detection works.

<!-- /open-questions -->

## Problem Statement

A browser is first a web renderer, and wezig's reason to own its stack is that its renderer is its own. v0 renders only a small fixed HTML/CSS subset (`docs/v0-subset.md`). Growing `WezigRenderer` toward matching existing browsers (real WHATWG parsing, full CSS, floats/flex/grid/tables/positioning, real text shaping, networking, JS) is the long axis of the project and cannot be scoped as one build. Before committing to that multi-year build, we need CONFIDENCE in the approach: the right conformance target, the right C libraries, and proof that the hard parts (real text shaping, the progressive swap, networking) actually work behind the existing seams.

## Solution

Explore, don't build-the-whole-thing. Pick and record the conformance target; pin the C-library choices by SPIKING the load-bearing ones (real text shaping behind the `PaintBackend` seam on one string; a networking spike that fetches one real resource; the progressive-swap routing on one trivial page). Keep the existing internal seams (`Tokenizer | TreeBuilder` ADR-0001, `PaintBackend` ADR-0002, surface ADR-0003, windowing ADR-0004) as the structure the growth extends. Evaluate and recommend on the JS-engine fork without building one. The output is: a ratified target, pinned libraries (+ ADRs), working spikes of the risky parts, and a de-risked, sliced BUILD PLAN — not a conformant renderer.

## User Stories

1. As a developer, I want the conformance target picked and written down (WPT %, a real-site set, or a first-apps bar), so that "matching existing browsers" is a measurable goal, not a vibe.
2. As a developer, I want the load-bearing C libraries pinned by spiking them (real text shaping via HarfBuzz/FreeType behind `PaintBackend` on one string; a networking fetch of one real resource), so that the library choices are proven, not guessed.
3. As a developer, I want a spike of the progressive-swap routing at the `Renderer` seam (render one simple static page with `WezigRenderer`, everything else via the webview), so that we know the swap mechanism works.
4. As a developer, I want a written evaluation + recommendation on the JavaScript-engine fork (write vs bind), so that a future build spec can commit with the trade-offs already reasoned.
5. As a developer, I want each spike to stay on the NARROWEST real case (one string, one resource, one page), so that the exploration reaches confidence fast without turning into the full build.
6. As a developer, I want a de-risked, SLICED build plan (which follow-on specs grow the parser / CSS / layout / text / networking / JS, in what order, to what bar), so that the real renderer work is a known quantity.

## Out of Scope (this is exploration)

- Actually implementing WHATWG parsing, full CSS, flex/grid/tables, a conformant layout engine, or a JS engine — those are follow-on BUILD specs this exploration de-risks and plans.
- The chrome/shell and webview backend (`explore-webview-shell`) and the web3 capabilities (`explore-web3-capabilities`).
- Canvas/WebGL/WebGPU page contexts — gated on the GPU-library decision; a later exploration/build, not this spec.
