---
title: wezig v0 — static HTML + CSS painted to a window
slug: browser
humanOnly: true
---

> Launch snapshot — records intent at creation, NOT maintained. Current truth: `docs/adr/` (decisions) + the code; remaining work: `work/tasks/ready/` tasks.

> **This spec was RE-SCOPED (2026-07-14).** It originally bundled the whole wezig vision (render engine + JavaScript + Ethereum + IPFS) with only a v0 slice committed. That mixed a fully-taskable subset with gated direction in one spec — the anti-pattern captured in `../dorfl`'s `tasking-has-no-partial-state...` observation. Per the "task a spec atomically or split it" principle, the beyond-v0 direction was broken out into its own logically-grouped, separately-taskable specs (see [Successor specs](#successor-specs)). What remains here is ONLY the v0 render slice, which is fully tasked and built. The decision to ship usability first via a system-webview backend behind a `Renderer` seam is recorded in `docs/adr/0005-renderer-seam-webview-backend-while-native-catches-up.md`.

## Problem Statement

Before wezig can be a browser (let alone one with native Ethereum/IPFS), it needs a real rendering core: bytes of HTML/CSS turned into pixels on screen, built behind swappable seams so each subsystem can mature independently. v0 proves that core on a deliberately small, fixed subset, with a working `zig build` / `zig build test` acceptance loop from day one, so "it renders" is testable rather than aspirational.

## Solution

A from-scratch rendering pipeline in Zig — HTML parse → DOM → CSS cascade → block/inline layout → software paint to a window — over a FIXED, documented subset of HTML/CSS, binding mature C libraries (SDL3 for the window, stb_truetype for glyphs) rather than reimplementing rasterization or shaping. The subset is small on purpose: enough structure to exercise block/inline layout and paint a real page fragment, and nothing more. Every subset boundary is reported through one structured `Diagnostics` sink, and the exact subset + limits are written down as a contract.

## User Stories (the committed v0 milestone — TASKED AND BUILT)

1. As a developer, I want wezig to parse a fixed, documented subset of HTML into a DOM tree, so that there is a real document model to lay out.
2. As a developer, I want wezig to parse a fixed subset of CSS and apply it to the DOM (cascade + inheritance for the supported properties), so that nodes have computed styles.
3. As a developer, I want wezig to lay out block and inline boxes with text, so that the document has a box tree with real positions and sizes.
4. As a developer, I want wezig to paint that box tree (backgrounds, borders, and shaped text) to an on-screen window via bound C libraries, so that a real page fragment appears as pixels.
5. As a developer, I want a `build.zig` and a `zig build` / `zig build test` flow that makes the `verify` gate green, so that the project has a working acceptance loop from day one.
6. As a developer, I want the v0 HTML/CSS subset and its limits written down, so that "it works" for v0 is unambiguous and testable.

All six landed as tasks (now in `work/tasks/done/`: build-scaffold-green-gate, diagnostics-sink, html-parse-subset, css-parse-and-cascade, layout-block-inline, fix-fontsize-unsupported-unit, paint-sdl3-stb-window, document-v0-subset-limits) and the ADRs `docs/adr/0001..0004`. The exact v0 subset + limits are `docs/v0-subset.md`.

## Successor specs

The wezig vision beyond v0 is now carried by three logically-grouped, separately-taskable specs (each atomically taskable once its own open questions are answered), sequenced behind ADR-0005's `Renderer` seam:

- **`usable-browser-webview-shell`** — ship a USABLE browser first: a `Renderer` seam + a system-webview backend (WebKitGTK) + the chrome/shell (window, tabs, URL bar, navigation), so wezig is a real, usable browser early while the native renderer catches up. `taskedAfter: [browser]`.
- **`native-renderer-conformance`** — grow wezig's OWN renderer past the v0 subset toward matching existing browsers (real HTML parsing, full CSS, floats/flex/grid/tables/positioning, real text shaping, networking), behind the same `Renderer` seam so it swaps in progressively. `taskedAfter: [browser]`.
- **`web3-native-capabilities`** — the differentiators: a native Ethereum provider (EIP-1193) and native IPFS resolution, specified against the seam's script-bridge + request-interception hooks so they work whichever backend renders the page. `taskedAfter: [usable-browser-webview-shell]`.

## Out of Scope (of THIS v0 spec)

- **v0 explicitly excludes** JavaScript execution, Canvas/WebGL/WebGPU, IPFS resolution, the Ethereum wallet, networking, navigation, and any browser chrome. Those are the successor specs above, not this slice.
- **Full web-platform conformance** is not a v0 goal; its target is an open question owned by `native-renderer-conformance`.
- **Writing our own rasterizer / font shaper / GPU driver** is out of scope by strategy — bound from C libraries.

## Further Notes

- Landscape context gathered at idea time (mid-2025): **Ladybird** (C++, independent, 4th on Web Platform Tests as of March 2025, moving toward Rust) is the reference for "browser from scratch" and a calibration on how hard this is even when funded; **Servo** (Rust) and **Vaev** (C++) are other from-scratch engines. No production browser is written in Zig, but the pillars each have Zig starting points (`zss`, `kiesel`, `zigquery`), which de-risks the "does anyone do this in Zig" question.
- The honest framing to keep front-of-mind: a full browser including all rendering plus Canvas/WebGL/WebGPU, a JS engine, IPFS, and a wallet is a decade-scale, multi-person effort. The webview-shell track (ADR-0005) is how wezig becomes usable and differentiated LONG before the native renderer reaches that bar.
