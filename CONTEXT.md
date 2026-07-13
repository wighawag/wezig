# CONTEXT — wezig domain language

The domain glossary for `wezig`. Agents and skills use THIS vocabulary when naming modules, tests, and discussing the system. Architectural rationale lives in `docs/adr/` (decisions); product framing lives in `work/specs/`.

## What wezig is

`wezig` is a from-scratch web browser written in Zig, built as a browser should be. Beyond rendering the standard web (HTML/CSS layout and painting, later Canvas/WebGL/WebGPU and JavaScript), its reason to exist is treating capabilities a complete browser ought to have as first-class rather than leaving them to third-party extensions: a native Ethereum provider (EIP-1193 RPC) for connecting to and signing for on-chain apps, and native IPFS content resolution. Mainstream browsers omit these (Brave is a notable exception that ships a native Ethereum provider); wezig does not. It binds mature C libraries (Skia/FreeType/HarfBuzz/SDL, Dawn or wgpu-native) rather than reimplementing rasterization, font shaping, or the GPU stack from scratch.

## Core domain terms

- **browser engine** — the subsystem stack that turns bytes on the wire into pixels on screen: networking, HTML parsing, CSS, layout, paint, compositing, and (later) a JavaScript engine.
- **HTML parser** — the component that turns an HTML byte stream into a DOM tree (targeting the WHATWG parsing algorithm over time; a fixed subset for v0).
- **DOM** — the in-memory document tree the parser builds and the rest of the engine reads and mutates.
- **CSS cascade** — tokenizing/parsing stylesheets, matching selectors, and resolving computed/inherited values onto DOM nodes.
- **layout** — turning styled DOM nodes into a box tree with positions and sizes (block/inline flow for v0; flex/grid/tables later).
- **paint / compositor** — rasterizing the laid-out boxes (text, backgrounds, borders) into surfaces and composing them, including later GPU-backed contexts (Canvas/WebGL/WebGPU) into the page.
- **ipfs:// resolution** — native, content-addressed retrieval of resources over IPFS (as opposed to an HTTP-gateway shim); the depth of integration is an open question on the launch spec.
- **Ethereum wallet** — the built-in key custody + signing surface and the page-facing provider (EIP-1193 RPC) that lets pages request accounts and signatures; its security model is an open question on the launch spec.
- **JS engine** — the JavaScript runtime the browser will need for dynamic pages; whether wezig writes one (e.g. via the Zig `kiesel` project) or binds an existing engine (V8/JSC) is an open question.
- **C-library binding** — the deliberate strategy of exposing mature C/C++ libraries (Skia, FreeType, HarfBuzz, SDL, Dawn/wgpu-native) through Zig rather than reimplementing rasterization, font shaping, or the GPU stack.
- **promptGuidance** — the per-repo NUDGE namespace in `.dorfl.json` whose members (currently just `testFirst`) strengthen the wording in the worker's in-band prompt. NOT a gate: the `verify` step is still the only acceptance bar. Omitted ⇒ off; absence is the default.
- **work/ contract** — the on-disk system this repo uses, defined by the reference docs in **`work/protocol/`** (copied here by `setup`): `WORK-CONTRACT.md` (the contract), `CLAIM-PROTOCOL.md`, `REVIEW-PROTOCOL.md`, `task-template.md`, `spec-template.md`, `ADR-FORMAT.md`. Three REGIME umbrellas — `notes/` (capture buckets), `tasks/` (the build board), `specs/` (the spec lifecycle) — plus top-level `questions/` and `protocol/`. One markdown file per item, status = the folder it lives in (never a field). Capture buckets: `notes/ideas/` (proposed), `notes/observations/` (spotted, unverified, append-only), `notes/findings/` (verified external/domain ground truth, each with a `source:`). ADRs (`docs/adr/`, format in `work/protocol/ADR-FORMAT.md`) record what WE decided and why.

## Conventions

Standing per-change rules agents must follow in this repo.

<!-- e.g. "Every change requires a changeset (`pnpm changeset`)" / a CHANGELOG fragment / a news entry. Add yours here, or delete this section. For enforcement, wire your own check into the `.dorfl.json` `verify` gate. -->

## Skills this repo uses

- Required: `setup` (onboarding/migration), `to-spec`, `to-task`.
- Recommended: `review`, `grill-me`.
