# Mobile ChromeSurface embeds through a C-ABI `EmbedPlatform` ops table (design decision)

_2026-07-18 — task `mobile-viewhandle-embedding-proof` (spec `explore-mobile-shell`, Q3/story 6)._

Durable record of the load-bearing choices made building the mobile
`ChromeSurface` embedding proof, to be linked from the done record. Recorded here
(not only in code) because a reviewer / the mobile-build spec / `mobile-adr-and-build-plan`
could be surprised by the shape, and it touches the shared mobile C-ABI and the
split-`Toolkit` seam (ADR-0008).

## Decision 1: a Zig `MobileChromeSurface` drives the native view hierarchy via a C-ABI `EmbedPlatform` ops table

**What I chose.** `src/mobile_chrome_surface.zig` (`MobileChromeSurface`)
implements the pinned `ChromeSurface` half (toolkit.zig, ADR-0008) in **Zig**.
Its `embedView` forwards the OPAQUE `ViewHandle` UNCHANGED to a small C-ABI ops
table (`EmbedPlatform`: `embedView`/`setUrlText`/`setBackEnabled`/`setForwardEnabled`)
that the native shell installs; only the native op interprets the handle (Swift
`addSubview` / JNI `ViewGroup.addView`).

**Why.** This is the SAME shape the two mobile `Renderer` backends already use
(`WkPlatform` in `ios_webview_renderer.zig`, `CJavaBridge` in `android_renderer.zig`),
for the same reason: the pinned mobile toolchain has the native side own UIKit /
`android.webkit.*`, so the physical view-hierarchy call sits behind the C-ABI the
toolchain pinned. Keeping the `ChromeSurface` half pure Zig (no UIKit / `jni.h`)
lets its seam-contract tests run headlessly in `zig build test`, mirroring
`FakeToolkit`/`FakeRenderer`.

**Alternatives considered.**
- _Implement the mobile toolkit entirely in Swift/Java_ (no Zig `ChromeSurface`).
  Rejected: the acceptance criterion is that the chrome-surface half stays
  backend-agnostic and the SEAM carries the opaque handle; keeping the impl in
  Zig is what keeps the chrome above the seam swappable and the proof about the
  seam, not about native glue.
- _Give `embedView` a typed handle (a `UIView*`/`jobject` union)_. Rejected: that
  is exactly the ADR-0006 refinement the spike was allowed to propose IF the
  opaque contract failed — and it did not fail (see the finding). Adding a typed
  handle speculatively would re-mean the pinned `ViewHandle` for no evidence.

## Decision 2: `EmbedPlatform` re-declares the widget ops (setUrlText/setBack/Forward) even though the proof only exercises `embedView`

**What I chose.** The ops table + the `ChromeSurface` impl carry the full
chrome-surface widget set, but the proof drives only `embedView` (the URL bar /
nav buttons are inert no-ops in this narrowest case).

**Why.** `ChromeSurface`'s VTable (ADR-0008) already pins those methods; a mobile
toolkit must satisfy the WHOLE half, so declaring them now (inert) keeps the
mobile chrome-surface a real `ChromeSurface` rather than an embed-only fork. The
headless test `"the widget half stands alone"` proves they work; wiring them to
real mobile widgets is the mobile BUILD spec's job, not this spike's.

**What it touches.**
- `src/mobile_chrome_surface.zig` — new module; adds `wezig_ios_embed_*` and
  `wezig_android_chrome_surface_*`/`wezig_android_embed_view` export thunks. The
  mobile `abi_version` was NOT bumped: these are additive story-6 scaffolding, not
  a contract the toolchain shell links (same posture as the story-4 iOS proof
  thunks).
- `src/android_renderer.zig` — adds one accessor `wezig_android_renderer_view`
  (returns the renderer's opaque `ViewHandle` via the seam) so the embedding shim
  can obtain the JNI global-ref to embed. Additive; no seam-shape change.
- `mobile-adr-and-build-plan` (downstream) — inherits the confirmed Q3 result
  (opaque `ViewHandle` sufficient; see the finding) and the per-embed JNI
  global-ref LEAK carry-forward hazard the finding flags.

## Coherence check (CONTEXT.md glossary + ADRs)

- `ChromeSurface`, `Toolkit`, `HostLoop`, `ViewHandle`, `Renderer` are reused with
  their pinned meanings (ADR-0006/0008); no term re-meant. `MobileChromeSurface`
  is the mobile IMPLEMENTATION of the existing `ChromeSurface` half, not a new
  seam.
- `EmbedPlatform` is a new NAME but at the right layer and by direct analogy to
  the already-accepted `WkPlatform`/`CJavaBridge` ops-table concept (the C-ABI
  boundary between a Zig seam impl and its native driver). It does not duplicate
  `ChromeSurface`; it is the transport under one impl of it.
