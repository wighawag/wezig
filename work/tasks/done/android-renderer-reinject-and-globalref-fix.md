---
title: Android backend — document-start re-injection + JNI global-ref lifecycle fix
slug: android-renderer-reinject-and-globalref-fix
spec: build-mobile-shell
blockedBy: []
covers: [8, 10]
---

## What to build

Two Zig-side fixes to the Android `Renderer` backend (`src/android_renderer.zig`), both inside the ONE file allowed to know `android.webkit.*`, so no platform quirk leaks above the seam:

1. **Document-start re-injection (Resolved decision 2).** Android's WebView has no `WKUserScript(.atDocumentStart)` equivalent, so a user script must be re-issued on EACH page start. The backend re-injects the last `injectUserScript` source on every `load_changed{ state: .started }` it emits (it already receives `WebViewClient.onPageStarted` and maps it to `.started`), so the CALLER calls `injectUserScript` once and gets document-start semantics on every page — the injection contract stays seam-uniform with iOS/WebKitGTK. The backend remembers the last injected source and re-issues it through the ops table on each `.started`.

2. **JNI global-ref lifecycle (story 8, ADR-0009 §Consequences hazard).** Today `view()` returns a FRESH JNI global-ref on every call (`return self.cbridge.view(...) orelse undefined;`) and the embedding shim leaks its `EmbedCtx` global-ref at teardown. Fix: cache ONE global-ref per view (created lazily on first `view()`, returned unchanged thereafter) and DELETE it on backend teardown; free the `EmbedCtx` global-ref on teardown. Net: exactly one live global-ref per view, zero after teardown.

## Acceptance criteria

- [ ] The Android backend re-issues the last `injectUserScript` source on every `.started` lifecycle event, so one caller `injectUserScript` yields document-start injection on every subsequent page (verified by a seam-contract test: inject once, drive N `.started` events, assert the injection op fired on each).
- [ ] `view()` returns the SAME cached global-ref across repeated calls (one ref per view, created lazily); the backend deletes it on teardown and frees the `EmbedCtx` global-ref on teardown.
- [ ] A leak-count assertion proves exactly one live global-ref per view during the view's life and zero after teardown (via the fake JNI bridge's ref counter — mirror the existing `android_renderer.zig` fake-bridge test style).
- [ ] The re-injection + ref-lifecycle changes stay INSIDE `src/android_renderer.zig`; nothing above the seam changes, and `src/chrome_conformance.zig` stays green.
- [ ] The full v0 gate (`zig fmt --check` + `zig build` + `zig build test`) stays green; the new tests run headlessly in `zig build test`.

## Blocked by

- None — can start immediately. It is Zig-only in `src/android_renderer.zig`. It is file-orthogonal to the shared chrome loop and the platform-shell FILES; the `android-shell-app` task depends on it LOGICALLY (the shell must build on this corrected backend), not because of a shared-file conflict.

## Prompt

> Goal: two Zig-side fixes to the Android `Renderer` backend (spec `build-mobile-shell`, stories 8/10), both INSIDE `src/android_renderer.zig`. (1) Document-start re-injection (Resolved decision 2): re-issue the last `injectUserScript` source on every `load_changed{ state: .started }` the backend emits, so one caller-side `injectUserScript` gives document-start semantics on every page — keeping the injection contract seam-uniform with iOS's `WKUserScript(.atDocumentStart)` and WebKitGTK. (2) JNI global-ref lifecycle (the hazard ADR-0009 flagged): `view()` currently mints a fresh global-ref per call and the embedding shim leaks its `EmbedCtx` ref at teardown — cache ONE global-ref per view (lazy, returned unchanged), delete it on teardown, and free the `EmbedCtx` ref on teardown.
>
> Read: `src/android_renderer.zig` (the backend, its fake JNI bridge + ref counter used by the existing tests, the `WebViewClient` load-callback mapping to `.started`, and the `view()`/`orelse undefined` leak site); `src/renderer.zig` (`LifecycleEvent`/`injectUserScript`); `work/notes/findings/android-webviewclient-nonui-thread-marshalling-2026-07-18.md` and `mobile-web3-hooks-parity-decisions-2026-07-18.md` (the re-injection finding); `viewhandle-crosses-mobile-toolkit-boundary-2026-07-18.md` (the ref-leak hazard). Test headlessly in `zig build test`: inject once + drive N `.started` and assert re-injection each time; assert one cached ref per view via the fake bridge's counter and zero after teardown. Keep everything inside the backend file; `chrome_conformance` stays green. "Done" = document-start re-injection is seam-uniform and the per-view global-ref leak is fixed, both headless-tested, gate green.
