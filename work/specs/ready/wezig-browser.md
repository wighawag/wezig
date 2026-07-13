---
title: wezig — a browser done right, in Zig
slug: wezig-browser
humanOnly: true
needsAnswers: true
---

> Launch snapshot — records intent at creation, NOT maintained. Current truth: `docs/adr/` (decisions) + the code; remaining work: `work/tasks/ready/` tasks. (The technical-detail sections below are trimmed by `to-task` once the work is tasked — they move into tasks/ADRs and this spec settles to its durable framing: Problem / Solution / User Stories / Out of Scope.)

<!-- open-questions -->
<!--
  TRANSIENT BLOCK — stripped by the apply rung on full resolution.
  While the spec has unresolved questions blocking autonomous tasking:
    1. Set `needsAnswers: true` in the frontmatter above.
    2. List the questions under the `## Open questions` heading below.
    3. Clear the flag (and let apply strip this block) once they are answered.
  Delete the whole fenced block — markers and all — if the spec launches fully resolved.
-->

## Open questions

These are genuine design forks that were deliberately DEFERRED at idea-interview time rather than force-resolved. The scope is a serious browser, but only the v0 slice below is committed; everything past it depends on answers here. The auto-tasker must not proceed until these are resolved (hence `needsAnswers: true` and `humanOnly: true`).

1. **JavaScript engine — write or bind?** wezig will eventually need a JS runtime. Do we write one in Zig (e.g. build on / adopt the `kiesel` project) for a fully from-scratch stack, or bind an existing engine (V8 / JavaScriptCore) for immediate real-world compatibility? This is the single largest scope decision after core layout.
2. **IPFS integration depth.** What does "native IPFS support" mean concretely: embed a full IPFS node (a Zig/Rust implementation) in-process, bind an existing node (e.g. kubo) over its API, or resolve via a trusted gateway with content-hash verification? And is `ipns://` in scope alongside `ipfs://`?
3. **Ethereum wallet security model.** Where and how are private keys stored (OS keychain, encrypted-at-rest, hardware-wallet support)? What is the signing/approval UX? Which chains beyond Ethereum mainnet? What exactly does the page-facing provider surface expose (EIP-1193 `request`, which RPC methods, permission model)? This area is security-critical and human-judgement-heavy.
4. **Rendering conformance target.** What is the ambition for standards conformance (a Web Platform Tests percentage, a "renders these N real sites" bar, or "good enough for the on-chain apps we care about")? This sets how far layout/CSS/paint must go past v0.
5. **Process / sandbox model.** Single-process (simplest, fastest to build) or a multi-process, sandboxed architecture (the security posture real browsers need, especially one holding wallet keys)? This is foundational and hard to retrofit, so it should be decided before layout hardens.
6. **Which C libraries, pinned.** The strategy is to bind C libraries, but the concrete picks need ratifying: rasterizer (Skia vs a lighter stb-based path), font shaping (HarfBuzz), glyph raster (FreeType vs stb_truetype), windowing/GL (SDL vs GLFW), and WebGPU backend (Dawn vs wgpu-native). v0 needs only window + 2D raster + text; the rest can be decided as their milestones arrive.

<!-- /open-questions -->

## Problem Statement

A browser should be able to talk to Ethereum and resolve content-addressed resources natively. Mainstream browsers don't: connecting to on-chain apps means a third-party extension grafted onto a browser that has no native notion of accounts or signing (supporting the EIP-1193 provider natively, as Brave does, is the exception, not the norm), and IPFS content is reached through HTTP gateways (a trust and UX compromise, not real content-addressing). None of this makes a browser a different genre; it is just a browser that isn't artificially missing obvious capabilities. There is no browser whose core treats an Ethereum provider (EIP-1193 RPC) and content-addressed retrieval (IPFS) as first-class, built-in capabilities. wezig exists to be that browser, built from scratch in Zig so the whole stack is owned and these capabilities are native rather than add-ons.

## Solution

A from-scratch browser, written in Zig, that renders the standard web AND treats a native Ethereum provider and native content-addressing as capabilities a complete browser should have:

- A **rendering engine** built from the ground up (HTML parse → DOM → CSS cascade → layout → paint/composite), binding mature C libraries (Skia/FreeType/HarfBuzz/SDL, and later Dawn or wgpu-native) for rasterization, font shaping, and the GPU stack rather than reimplementing them.
- **Native IPFS resolution**, so `ipfs://` content is fetched and verified as content-addressed data, not proxied through a gateway.
- A **built-in Ethereum provider (EIP-1193 RPC)**, so pages can request accounts and signatures natively without a third-party extension.
- Later, the dynamic-web capabilities real pages need: a **JavaScript engine**, and GPU-backed **Canvas 2D / WebGL / WebGPU** contexts composited into the page.

The v0 slice deliberately proves the rendering core before any Ethereum, IPFS, or scripting lands.

## User Stories

### v0 — the committed milestone (static HTML + CSS paint to a window)

1. As a developer, I want wezig to parse a fixed, documented subset of HTML into a DOM tree, so that there is a real document model to lay out.
2. As a developer, I want wezig to parse a fixed subset of CSS and apply it to the DOM (cascade + inheritance for the supported properties), so that nodes have computed styles.
3. As a developer, I want wezig to lay out block and inline boxes with text, so that the document has a box tree with real positions and sizes.
4. As a developer, I want wezig to paint that box tree (backgrounds, borders, and shaped text) to an on-screen window via bound C libraries, so that a real page fragment appears as pixels.
5. As a developer, I want a `build.zig` and a `zig build` / `zig build test` flow that makes the `verify` gate green, so that the project has a working acceptance loop from day one.
6. As a developer, I want the v0 HTML/CSS subset and its limits written down, so that "it works" for v0 is unambiguous and testable.

### Beyond v0 (direction, gated on the open questions above)

7. As a user, I want to open an `ipfs://` address and have wezig resolve and verify the content natively, so that content-addressed sites load without a gateway.
8. As a page, I want to request accounts and signatures from wezig's built-in Ethereum provider (EIP-1193) natively, so that users transact without a third-party extension.
9. As a user, I want my wallet keys stored and signing approved through a trustworthy, well-defined security model, so that a browser holding keys is safe to use.
10. As a developer, I want dynamic pages to run JavaScript, so that real script-driven pages actually function.
11. As a developer, I want Canvas 2D, WebGL, and WebGPU contexts exposed to page script and composited into the page, so that graphics-heavy pages and content render.
12. As a user, I want wezig to render enough real HTML/CSS to load the sites I care about, so that it is a usable browser and not only a demo.

### Autonomy notes (the two gate axes)

- **`humanOnly: true`** — a human must drive the TASKING of this spec. It is a serious-browser vision with security-critical (wallet key custody, signing) and architecture-foundational (process/sandbox model, JS-engine choice) forks; an agent must not auto-fan this into tasks. This flag governs tasking only and does not pre-set the gate of individual tasks (the tasker decides each task's gate from its own build-nature — e.g. a v0 `build.zig` chore can be fully agent-buildable).
- **`needsAnswers: true`** — the six open questions above block auto-tasking until resolved. The v0 stories (1–6) are well-defined and could be tasked once a human clears tasking, but the beyond-v0 stories depend on the answers, so the spec as a whole is flagged incomplete rather than falsely complete.

## Implementation Decisions

Decisions fixed at launch (seed for tasking; trimmed by `to-task` later):

- **Language: Zig** (fixed by the originating idea). C interop is a first-class reason for the choice.
- **Bind C libraries; do not reimplement the hard graphics primitives.** Rasterization, font shaping, glyph rendering, windowing, and the GPU stack come from mature C/C++ libraries exposed through Zig. Concrete picks are open question 6; the strategy itself is decided.
- **Reuse of existing Zig prototypes is on the table** rather than hand-writing every pillar: `zss` (CSS parser / layout / renderer), `zigquery` (HTML parser + CSS selectors), `kiesel` (JS engine). Whether/how much to adopt each is a per-milestone decision; the openness to reuse is decided.
- **v0 excludes** JavaScript, Canvas/WebGL/WebGPU, IPFS, and the wallet. v0 is HTML+CSS layout and paint to a window, plus the `build.zig`/gate scaffolding.
- **WebGPU, when it arrives, is expected to be the cleanest GPU target** (standard `webgpu.h` C API; existing Zig bindings via `zgpu`/wgpu-native), likely sequenced before WebGL and ahead of full Canvas 2D conformance. Recorded as direction, not a v0 commitment.

## Testing Decisions

- Test at the **highest stable seams**: for v0, prefer "given this HTML+CSS input, the produced box tree has these positions/sizes" (layout seam) and "the painted output matches a reference" (paint seam) over asserting internal parser structures.
- The **`verify` gate** (`zig fmt --check . && zig build && zig build test`) is the acceptance backbone; the first task must land a `build.zig` that makes `zig build` / `zig build test` real (the gate is red until then, by design).
- Golden/reference-image tests are the natural fit for the paint milestone; keep the v0 HTML/CSS subset small enough that references are maintainable.
- Prior art to lean on for test shape: `zss` (its demo/tests exercise CSS layout + render in Zig).

## Out of Scope

- **v0 explicitly excludes** JavaScript execution, Canvas/WebGL/WebGPU, IPFS resolution, and the Ethereum wallet. These are direction (stories 7–12), not the committed first slice.
- **Full web-platform conformance** is not a v0 goal and its target is an open question (4).
- **Writing our own rasterizer / font shaper / GPU driver** is out of scope by strategy — these are bound from C libraries.
- **Migration of any existing code** — none exists; this is a clean-slate project.

## Further Notes

- Landscape context gathered at idea time (mid-2025): **Ladybird** (C++, independent, 4th on Web Platform Tests as of March 2025, moving toward Rust) is the reference for "browser from scratch" and a calibration on how hard this is even when funded; **Servo** (Rust) and **Vaev** (C++) are other from-scratch engines. No production browser is written in Zig, but the pillars each have Zig starting points (`zss`, `kiesel`, `zigquery`), which de-risks the "does anyone do this in Zig" question.
- The honest framing to keep front-of-mind: a full browser "including all rendering" plus Canvas/WebGL/WebGPU, a JS engine, IPFS, and a wallet is a decade-scale, multi-person effort. This spec commits only to the v0 rendering slice and captures the rest as gated direction so the work stays truthful about scope.
