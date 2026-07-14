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
- **promptGuidance** — the per-repo NUDGE namespace in `dorfl.json` whose members (currently just `testFirst`) strengthen the wording in the worker's in-band prompt. NOT a gate: the `verify` step is still the only acceptance bar. Omitted ⇒ off; absence is the default.
- **work/ contract** — the on-disk system this repo uses, defined by the reference docs in **`work/protocol/`** (copied here by `setup`): `WORK-CONTRACT.md` (the contract), `CLAIM-PROTOCOL.md`, `REVIEW-PROTOCOL.md`, `task-template.md`, `spec-template.md`, `ADR-FORMAT.md`. Three REGIME umbrellas — `notes/` (capture buckets), `tasks/` (the build board), `specs/` (the spec lifecycle) — plus top-level `questions/` and `protocol/`. One markdown file per item, status = the folder it lives in (never a field). Capture buckets: `notes/ideas/` (proposed), `notes/observations/` (spotted, unverified, append-only), `notes/findings/` (verified external/domain ground truth, each with a `source:`). ADRs (`docs/adr/`, format in `work/protocol/ADR-FORMAT.md`) record what WE decided and why.

## Naming

There are TWO distinct, swappable name identifiers with independent lifecycles; neither is baked into the `work/` identity graph. The launch spec and its tasks use the name-independent slug `browser` (`slug: browser` / `spec: browser`), so renaming EITHER identifier never touches the `work/` cross-reference graph.

- **Code name** (`wezig` today) — the internal project/codebase identity: repo, module namespace, `build.zig.zon`'s `.name`. Stable for now and safe to use as the current identity, but it CAN change later, so code that must refer to it reads a single `code_name` constant rather than hard-coding the literal.
- **Display name** (undecided, WILL change) — the user-facing product name. Defined in exactly ONE place: a single `app_name` constant. Every user-facing/UI reference reads that constant.

When the build scaffold lands (`build-scaffold-green-gate`), BOTH names are defined once (e.g. `code_name` and `app_name` in a `src/branding.zig` module, with `build.zig.zon`'s `.name` = the code name). Renaming either later is then a one-line constant edit plus prose mentions (`CONTEXT.md`, the spec `title:`/body), with no identity or cross-reference churn.

## Conventions

Standing per-change rules agents must follow in this repo.

- **Conventional-commit subjects.** Every change commits with a conventional-commit subject (`feat:`, `fix:`, `docs:`, `test:`, `chore:`, optionally scoped e.g. `fix(app): …`). This is load-bearing: releases and the changelog are generated FROM the git history by GoReleaser (`.goreleaser.yaml`), so there are NO per-change changeset files to maintain. `docs:`/`test:`/`chore:`/`task:` subjects are filtered out of the changelog; `feat:`/`fix:` are what users see.
- **Releasing.** Cut a release by pushing a version tag (`git tag vX.Y.Z && git push origin vX.Y.Z`). The `release` workflow runs the acceptance gate, then GoReleaser (native Zig builder) cross-compiles the Linux binaries, archives them with the docs, builds checksums, generates the changelog from the commits since the last tag, and publishes a GitHub Release. Bump `build.zig.zon`'s `.version` to match the tag. The macOS/Windows targets are omitted from `.goreleaser.yaml` until a snapshot build is verified green for them (SDL3 is built from source per target).

## Skills this repo uses

- Required: `setup` (onboarding/migration), `to-spec`, `to-task`.
- Recommended: `review`, `grill-me`.
