---
title: Explore — the native renderer past v0 (pick the target, pin the libraries, spike the hard parts)
slug: explore-native-renderer
taskedAfter: [browser]
---

> Launch snapshot — records intent at creation, NOT maintained. Current truth: `docs/adr/` (decisions) + the code; remaining work: `work/tasks/ready/` tasks.

> **This is an EXPLORATION-scoped spec.** Its deliverable is CONFIDENCE + a de-risked plan for growing `WezigRenderer` toward matching existing browsers — NOT the finished renderer (that is a decade-scale, Ladybird-class effort and is many follow-on build specs). It picks the conformance target, pins the C-library choices, and spikes the parts most likely to be hard or wrong (real text shaping behind `PaintBackend`; the progressive-swap routing at the `Renderer` seam; networking), each on the NARROWEST real case, so we can confidently say HOW the native renderer grows and WHERE it swaps in. The actual "implement WHATWG parsing / CSS grid / flexbox" work is scoped by follow-on build specs, informed by this exploration.

## Anchoring thesis (ADR-0011)

wezig is a **general-purpose web browser** that does not trust the origin by
default: full compatibility with the normal server-focused web is a HARD
requirement, and on top of that it is privacy-protecting, local-first, and a
place to explore web apps that do not assume a trusted server (content-addressed
/ `ipfs://`, verifiable resources). The decentralised web is a *consequence* of
that stance, not the purpose. Every decision below is anchored on **a real
general browser**, NOT a dapp/on-chain niche (this corrects the earlier
"native-Ethereum/IPFS-differentiator" framing).

## Resolved decisions (the four gating questions, answered)

The `needsAnswers` gate is CLEARED — the four gating questions are decided:
(1) the conformance target is a TIERED general-browser capability ladder (WPT %
as the secondary meter); (2) the load-bearing C libraries are HarfBuzz (shaping,
pinned), a BOUND HTTP+TLS stack (networking, never write TLS), and Dawn/`wgpu-native`
(page-facing WebGPU primary / WebGL first-class), with FreeType leant and the 2D
rasterizer pick deferred; (3) a reversible `ScriptEngine` seam, BIND first
(SpiderMonkey leant), Zig-native (`kiesel`) as the aspirational later swap-in;
(4) a USER-CONTROLLED swap policy (default webview; native only on explicit
manual per-page trigger or a per-domain allow-list) with NO automatic routing.

> Detail moved to the tasks (`spec: explore-native-renderer` in `work/tasks/`)
> and the ADRs each spike produces; the decision rationale is anchored on
> ADR-0011. The tasks own the per-decision specifics (which string to shape,
> which resource to fetch+verify, the one-canvas-one-frame GPU case, the
> swap-mechanism + per-domain-allow model, the SM/JSC/V8 criteria, the tier
> definitions) and the de-risked sliced build plan.

## Problem Statement

A browser is first a web renderer, and wezig's reason to own its stack is that its renderer is its own (so it need not inherit an incumbent engine's origin-trusting defaults — ADR-0011). v0 renders only a small fixed HTML/CSS subset (`docs/v0-subset.md`). Growing `WezigRenderer` toward a REAL GENERAL BROWSER (real WHATWG parsing, full CSS, floats/flex/grid/tables/positioning, real text shaping, networking, JS, AND page-facing WebGPU/WebGL) is the long axis of the project and cannot be scoped as one build. Before committing to that multi-year build, we need CONFIDENCE in the approach: the conformance target (decision 1), the C libraries (decision 2), the JS-engine boundary (decision 3), the user-controlled swap policy (decision 4) — and proof that the hard parts (real text shaping, networking + verify, page-facing GPU, the swap mechanism) actually work behind the seams.

## Solution

Explore, don't build-the-whole-thing. Execute against the four resolved decisions above, SPIKING the load-bearing parts on the NARROWEST real case: real text shaping (HarfBuzz) behind the `PaintBackend` seam on one string; a networking fetch of one normal resource AND one hash-verified content-addressed resource; a page-facing GPU context (WebGPU primary, WebGL first-class) drawing one canvas frame on the native path (Dawn/`wgpu-native`); and the USER-triggered per-page renderer swap at the `Renderer` seam on one page. Add + pin the `ScriptEngine` seam (bind first; Zig-native later) and produce the SpiderMonkey/JSC/V8 recommendation. Keep the existing internal seams (`Tokenizer | TreeBuilder` ADR-0001, `PaintBackend` ADR-0002, surface ADR-0003, windowing ADR-0004 — which already leans Dawn/`wgpu-native`) as the structure the growth extends. The output is: the pinned tiered target, pinned libraries + the `ScriptEngine` seam (+ ADRs), working spikes of the risky parts, and a de-risked, sliced BUILD PLAN — not a conformant renderer.

## User Stories

1. As a developer, I want the GENERAL-BROWSER conformance target pinned as a tiered capability ladder (representative pages per tier — incl. normal server-web pages AND a content-addressed static page — with WPT-subset bars), so that "a real general browser" is a measurable goal, not a vibe, and not mis-scoped to a dapp niche (ADR-0011).
2. As a developer, I want the load-bearing C libraries pinned by spiking them (HarfBuzz shaping behind `PaintBackend` on one string; a networking fetch of one normal AND one hash-verified content-addressed resource), so that the library choices are proven, not guessed.
3. As a developer, I want a spike of the page-facing GPU path on the native renderer (a `<canvas>` gets a working WebGPU context drawing one frame; the WebGL path proven to be first-class — 100% + performant — not a fallback) via Dawn/`wgpu-native`, so that my WebGPU/WebGL content (e.g. games) has a proven native path — while noting the webview backend already runs it today.
4. As a developer, I want a spike of the USER-triggered renderer swap at the `Renderer` seam (the user forces one page to render natively; everything else stays webview by default), plus the per-domain-allow data model, so that the user-controlled swap mechanism (no automatic routing) is proven.
5. As a developer, I want the `ScriptEngine` SEAM pinned and a written SpiderMonkey/JSC/V8 bind recommendation (with independence/reuse/perf criteria) plus the Zig-native-later position, so that the JS boundary is reversible and a future build spec can commit.
6. As a developer, I want each spike to stay on the NARROWEST real case (one string, one+one resource, one canvas frame, one page), so that the exploration reaches confidence fast without turning into the full build.
7. As a developer, I want a de-risked, SLICED build plan (which follow-on specs grow the parser / CSS / layout / text / networking / GPU / JS / the user-swap chrome, in what order, to what tier), so that the real renderer work is a known quantity.

## Out of Scope (this is exploration)

- Actually implementing WHATWG parsing, full CSS, flex/grid/tables, a conformant layout engine, a JS engine, or a production GPU/canvas stack — those are follow-on BUILD specs this exploration de-risks and plans. The GPU work here is a page-facing WebGPU/WebGL SPIKE (one canvas frame), not the full Canvas/WebGL/WebGPU implementation.
- Deciding the deferred 2D-rasterizer pick (Skia vs lighter) — recorded as an open pick, not spiked (partly subsumed by the GPU path).
- BUILDING a Zig-native JS engine — the exploration only adds the `ScriptEngine` seam and recommends the first (bound) engine; the Zig-native swap-in is a later build.
- AUTOMATIC page routing / mismatch detection between backends — deliberately rejected (decision 4): the swap is user-controlled (manual per-page + per-domain allow), so no automatic-routing mechanism is built or spiked.
- The chrome/shell and webview backend (`explore-webview-shell`) and the web3 capabilities (`explore-web3-capabilities`).
- Canvas/WebGL/WebGPU page contexts — gated on the GPU-library decision; a later exploration/build, not this spec.
