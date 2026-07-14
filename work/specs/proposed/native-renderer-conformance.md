---
title: The native renderer — grow WezigRenderer past v0 toward matching existing browsers
slug: native-renderer-conformance
humanOnly: true
needsAnswers: true
taskedAfter: [browser]
---

> Launch snapshot — records intent at creation, NOT maintained. Current truth: `docs/adr/` (decisions) + the code; remaining work: `work/tasks/ready/` tasks.

<!-- open-questions -->

## Open questions

These gate tasking this spec (`needsAnswers: true`). They set how far and how the native renderer goes, and which libraries it binds.

1. **Rendering conformance target** (was browser-spec Q4). What is the ambition — a Web Platform Tests percentage, a concrete "renders these N real sites correctly" bar, or "good enough for the on-chain apps we care about first"? This sets how far layout/CSS/paint/text must go and how progress is measured against the webview backend.
2. **Which C libraries, pinned** (was browser-spec Q6). Ratify the concrete picks as their milestones arrive: rasterizer (Skia vs a lighter stb-based path — v0 uses stb_truetype + software raster), font shaping (HarfBuzz), glyph raster (FreeType vs stb_truetype), GPU/compositing (Dawn vs wgpu-native), and networking (bind an HTTP/TLS stack vs write one). v0 needs only window + 2D raster + text; the rest are per-milestone.
3. **Networking stack.** "Use a website" needs HTTP/1.1+2 and TLS. Bind an existing stack (curl / a TLS lib) or grow one? This is a prerequisite for the native renderer to load anything real, and interacts with the process/sandbox model (owned by `usable-browser-webview-shell` Q3).
4. **Progressive-swap policy.** ADR-0005 says the swap is per-capability or per-page-type: route what `WezigRenderer` handles well to it, fall back to the webview otherwise. What is the routing decision (a capability allowlist? a per-site opt-in? a "native for simple pages" heuristic?), and how is a native-vs-webview mismatch surfaced/tested?
5. **JavaScript engine — write or bind** (was browser-spec Q1). Eventually the native renderer needs a JS runtime: write one in Zig (e.g. build on `kiesel`) for a fully from-scratch stack, or bind V8 / JavaScriptCore for immediate compatibility. The single largest scope decision after core layout. (Note: the webview backend ALREADY runs JS, so this gates the NATIVE renderer's dynamic-page support, not usability — usability comes from the webview track.)

<!-- /open-questions -->

## Problem Statement

A browser is first a web renderer, and wezig's reason to own its stack is that its renderer is its own. v0 renders only a small fixed HTML/CSS subset (documented in `docs/v0-subset.md`). To eventually stand on its own — and to progressively replace the system-webview backend — `WezigRenderer` must grow toward matching existing browsers: real WHATWG HTML parsing, full CSS, real layout (floats, flex, grid, tables, positioning, stacking), real text shaping, networking, and eventually JavaScript. This is the long axis of the project.

## Solution

Grow `WezigRenderer` behind the same `Renderer` seam the webview backend sits behind (ADR-0005), so it can be swapped in progressively — per capability or per page-type — as it matures, without touching the chrome. Keep the existing internal seams (`Tokenizer | TreeBuilder` per ADR-0001, `PaintBackend` per ADR-0002, engine-paints-into-a-`Surface` per ADR-0003, windowing leaf per ADR-0004) as the engine's internal structure, and extend each subsystem past its v0 subset toward standards conformance, binding mature C libraries for rasterization/shaping/GPU/networking rather than reimplementing them. Progress is measured against a ratified conformance target and against the webview backend rendering the same pages.

## User Stories

1. As a developer, I want the HTML parser to grow from the fixed v0 allowlist toward the WHATWG parsing algorithm (real tokenizer states, insertion modes, error recovery), so that arbitrary real HTML parses.
2. As a developer, I want CSS support to grow past the v0 property/selector subset (more properties, more selectors, at-rules, the real cascade edge cases), so that real stylesheets apply.
3. As a developer, I want layout to grow past block+inline into floats, positioning, flexbox, grid, and tables, so that real page layouts render correctly.
4. As a developer, I want real text shaping (HarfBuzz/FreeType) behind the `PaintBackend` seam, replacing the v0 single embedded stb_truetype face, so that fonts, scripts, and shaping match the web.
5. As a developer, I want a networking stack (HTTP/TLS) so the native renderer can load real resources, not just in-memory fixtures.
6. As a developer, I want a progressive-swap mechanism at the `Renderer` seam (route pages the native engine handles to `WezigRenderer`, fall back to the webview otherwise), so the native renderer earns real traffic incrementally.
7. As a developer, I want a JavaScript runtime for the native renderer (write-or-bind per the open question), so that native-rendered pages can be script-driven.
8. As a developer, I want conformance measured against a ratified target (WPT % or a real-site set), so that "matching existing browsers" is testable, not a vibe.

## Out of Scope

- The chrome/shell and the system-webview backend — that is `usable-browser-webview-shell` (this spec produces the OTHER backend behind the same seam).
- The Ethereum/IPFS capabilities — that is `web3-native-capabilities` (they attach at the seam and are backend-agnostic).
- Canvas/WebGL/WebGPU page contexts may be a later story here or their own spec, depending on the GPU-library decision (open question 2); not committed in this spec's first tasking.
