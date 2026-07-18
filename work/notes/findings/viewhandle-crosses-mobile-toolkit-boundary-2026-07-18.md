---
source: the mobile-viewhandle-embedding-proof spike (src/mobile_chrome_surface.zig; mobile/ios/Sources/EmbeddingProof.swift; mobile/android WezigEmbeddingController.java + wezig_embedding_jni.c) + JNI global-ref semantics (Android NDK docs) + WKWebView/UIView embedding (UIKit docs)
---

# The opaque `ViewHandle` carries a mobile native view across the chrome-surface↔renderer boundary on BOTH platforms — CONFIRMED sufficient

Verified building the ViewHandle-embedding proof (task
`mobile-viewhandle-embedding-proof`, spec `explore-mobile-shell` Q3/story 6).
This resolves ADR-0007's explicitly-flagged **cross-toolkit view embedding**
spike ("the opaque `ViewHandle` is a GtkWidget both backends agree on; a non-GTK
chrome hosting a foreign view is a foreign-embedding spike, not a drop-in") on
the narrowest real case, on both iOS and Android.

## What was proven

A mobile **chrome-surface** (`MobileChromeSurface`, the `ChromeSurface` half of
the split `Toolkit`, ADR-0008) `embedView`s the mobile renderer's view — obtained
via `Renderer.view()` as the OPAQUE `*anyopaque` `ViewHandle` — and the page
shows, driven THROUGH the seam exactly as the chrome would call it
(`surface.embedView(renderer.view())`), on a NON-GTK toolkit host:

- **iOS (EXECUTED):** the handle is the `WKWebView`'s `UIView*`. The Swift embed
  op downcasts it and `addSubview`s it into a container. The proof asserts BOTH
  (a) the webview's `superview === container` (it was hosted THROUGH the seam,
  not a stray `addSubview`) AND (b) `WKWebView.takeSnapshot` is non-blank (the
  page rendered). We snapshot the WEBVIEW, not the container, because WKWebView
  content is composited out-of-process (rendering the container's layer would be
  blank — the same reason the renderer proof uses `takeSnapshot`); the
  superview-identity check is what proves the embed crossed the seam. Runs on the
  `ios-embedding-proof` CI leg (macos-14, iOS 17 simulator) via
  `mobile/ios/embedding-proof.sh` — wired + executable in this change.
- **Android (the sharp Q3 risk):** the handle is a JNI **global-ref** to the
  `android.webkit.WebView`, not a raw pointer. The JNI shim downcasts it back to
  the `WebView` jobject and `ViewGroup.addView`s it; the instrumented
  `EmbeddingProofTest` gets the renderer's opaque handle from the seam, embeds it
  THROUGH `ChromeSurface.embedView`, and asserts the WebView became a child of the
  container (`assertSame`) AND the container draws non-blank (`view.draw` recurses
  into the embedded child). **Execution status:** the on-emulator RUN of this
  instrumented test is delegated to the KVM x86_64-emulator leg that
  `mobile-verification-legs-ci` stands up (that task runs `connectedAndroidTest`,
  which picks this up automatically) — it is NOT executed by this change's CI
  (`mobile-android.yml` only builds the APK). So in THIS change the Android path
  is proven by: construction (the full native link resolves), the headless Zig
  seam-contract tests (bit-transparent handle carry, in `zig build test`), and the
  ready-to-run instrumented test; the live-emulator confirmation lands when that
  leg runs. See "Confidence status" below.

## The Q3 answer: the opaque contract is SUFFICIENT (no refinement needed)

The task explicitly allowed EITHER outcome (confirmed-sufficient OR
pinned-insufficient-with-a-typed-handle/handle-with-vtable proposal). The outcome
is **confirmed-sufficient**:

- **Lifetime.** On Android the handle is a JNI GLOBAL ref (`NewGlobalRef` in
  `bridge_view`), so it survives past the JNI call that produced it and stays
  valid while the chrome holds the view — the same durability a raw-pointer
  handle gives on desktop. The opaque `*anyopaque` contract does not need to know
  it is a ref: the Zig `ChromeSurface.embedView` copies the bits through
  UNCHANGED and only the native side (which owns the ref's lifetime) interprets
  them. So a JNI ref is carried by the SAME opaque contract as a `GtkWidget*` or a
  `UIView*`.
- **Thread-affinity.** The interpretation step (`ViewGroup.addView` /
  `addSubview`) must run on the UI thread — but that is an Android/UIKit
  view-hierarchy constraint on the NATIVE side, NOT a gap in the seam contract.
  The seam carries the opaque handle regardless of thread; the caller performs
  the embed on the thread the platform requires (the proofs embed on the UI
  thread), exactly as the desktop backend embeds on the GTK main loop. There is
  nothing for `ChromeSurface.embedView`'s signature to add: a typed handle would
  not change WHERE the embed must run.

**Therefore ADR-0006's opaque `ViewHandle` stands.** No typed-handle /
handle-with-vtable refinement is required; the chrome-surface half stays
backend-agnostic (it embeds an opaque handle; only the backends interpret it),
preserving the seam discipline across a non-GTK toolkit↔backend boundary.

## Confidence status (what is EXECUTED vs. pending an emulator run)

Be precise about the evidence, since Android is the sharp risk:

- **iOS:** confirmed by an EXECUTABLE end-to-end leg in this change
  (`ios-embedding-proof`, macos-14 simulator).
- **Android:** confirmed by construction + headless Zig seam-contract tests +
  a ready-to-run instrumented test; the LIVE-emulator run is delegated to
  `mobile-verification-legs-ci`'s KVM leg (`connectedAndroidTest`). The Q3
  *contract* question — "does the opaque `*anyopaque` carry a JNI global-ref
  across `embedView` (lifetime + thread-affinity)" — is answered YES by the
  reasoning + the headless tests + the resolving native link; the remaining
  emulator run is a REGRESSION check that a real WebView paints once embedded,
  not an open contract question. If that leg ever shows the embedded WebView
  blank/detached, THAT would reopen the finding — but nothing in the JNI
  global-ref semantics predicts it will.

## Carry-forward hazard for the real chrome (recorded, not a spike blocker)

`bridge_view` (`wezig_renderer_jni.c`) creates a NEW JNI global-ref on every
`Renderer.view()` call and never deletes it, and the embedding shim's `EmbedCtx`
global-ref is intentionally leaked at teardown — both fine for a one-shot spike,
but a per-embed global-ref LEAK that the mobile BUILD spec must fix (cache one
global-ref per view, delete on teardown). Flagged here so it is not inherited
silently.

## What it means downstream

- ADR-0006 (opaque `ViewHandle`) and ADR-0008 (split `Toolkit` / `ChromeSurface`)
  are confirmed carriable to mobile with no interface change. The mobile ADR
  (`mobile-adr-and-build-plan`) records this as a settled Q3 result rather than a
  re-opened question.
- The mobile BUILD spec can host the renderer's view through `ChromeSurface`
  without a per-platform view-type leak into the chrome; the only platform code
  is the native embed op (Swift `addSubview` / JNI `addView`), symmetric with the
  desktop `GtkToolkit.embedView`.
- The one native-side rule to carry forward (documented, not a seam change):
  perform the embed on the UI thread. This composes with the Q5 thread-marshalling
  finding (`android-webviewclient-nonui-thread-marshalling-2026-07-18.md`).

Recorded durably here + in `mobile/android/README.md` (Android finding),
`mobile/ios/README.md` (iOS proof), and the `src/mobile_chrome_surface.zig` module
doc; linked from the task done-record.
