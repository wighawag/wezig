---
title: review-gate non-blocking nits for 'android-renderer-backend-oneshot' (Gate 2 approve)
date: 2026-07-18
status: open
reviewOf: android-renderer-backend-oneshot
---

## Non-blocking review findings

The PR/code review gate (Gate 2) APPROVED 'android-renderer-backend-oneshot' but raised the
following non-blocking findings (nits). They do not block integration; this
is their durable home for triage — promote-to-task / keep / delete.

- bridge_view creates a fresh NewGlobalRef on EVERY seam view() call and never deletes it — each call leaks one JNI global ref. Not hit by this content-seam proof (view() is unused here), but the embedding task will call it; should cache the ref once or have the embedder own its lifetime.
  (mobile/android/app/src/main/cpp/wezig_renderer_jni.c bridge_view; owned by mobile-viewhandle-embedding-proof)
- postUriChanged / wezig_android_on_uri_changed has no Java producer: no WebViewClient callback (e.g. doUpdateVisitedHistory) ever calls postUriChanged, so .uri_changed never fires from the real backend. The Zig path is unit-tested but dead on-device. Fine for the navigate+finished proof; flag so a later task wires it if uri_changed is needed.
  (WezigWebViewController.java postUriChanged is defined but unreferenced)
- Ratify recorded decision: opaque ViewHandle = JNI global ref to the WebView (spec Q3). Matches the spec decision; the JNI-ref lifetime/thread-affinity risk is explicitly deferred to the embedding-proof task.
  (README DECISIONS block + spec Q3; recorded, looks correct)
- Ratify recorded decision: the two web3 hooks (injectUserScript/setScriptMessageHandler/evaluateScript/registerScheme) are honest no-ops satisfying the VTable, deferred to mobile-web3-hooks-parity (stories 8,9). Correct scoping for a content-seam-only proof; that task exists in tasks/ready.
  (android_renderer.zig no-op hooks + README DECISIONS; mobile-web3-hooks-parity present)
- Ratify recorded decision: load-event codes are a stable JNI integer enum (AndroidLoadEvent 0..3) kept in lock-step between Java PAGE_* constants and Zig, decoupled from seam enum order. Sound; the risk is silent drift between the two files — the mapLoadState unit test pins the Zig half but nothing cross-checks the Java constants.
  (android_renderer.zig AndroidLoadEvent vs WezigWebViewController PAGE_* constants)
