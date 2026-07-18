---
title: Prove the opaque ViewHandle crosses the mobile Toolkit↔Renderer boundary (both platforms)
slug: mobile-viewhandle-embedding-proof
spec: explore-mobile-shell
blockedBy: [android-renderer-backend-oneshot, ios-renderer-backend-oneshot]
covers: [6]
needsAnswers: true
---

## What to build

Resolve ADR-0007's flagged cross-toolkit-embedding risk on the narrowest real case (spec Q3/story 6): prove the opaque `ViewHandle` carries a mobile native view across the mobile `Toolkit` (chrome-surface) ↔ mobile `Renderer` boundary on BOTH platforms — a mobile chrome-host embeds the mobile renderer's view (`embedView`) and shows a page — OR pin exactly where the seam is insufficient and feed that back to ADR-0006/0007.

- **iOS:** the renderer's `view()` returns the `WKWebView`'s `UIView*`; the iOS chrome-surface `embedView` adds it as a subview and shows the page.
- **Android:** the renderer's `view()` returns a JNI reference to the `WebView`; the Android chrome-surface `embedView` adds it to the view hierarchy. THIS is the sharp risk (Q3): confirm the opaque `*anyopaque`/`usize` contract cleanly carries a JNI global-ref (lifetime + thread-affinity). If it cannot, that is the highest-value FINDING — pin the exact contract the seam is missing and propose the refinement (typed handle / handle-with-vtable) back to ADR-0006/0007.

## Acceptance criteria

- [ ] On iOS: the chrome-surface `embedView` hosts the renderer's `WKWebView` view and a page is shown (green in the iOS simulator CI job).
- [ ] On Android: the chrome-surface `embedView` hosts the renderer's `WebView` and a page is shown — OR a precise finding documents why the opaque handle cannot carry the JNI ref, with a proposed seam refinement.
- [ ] The opaque `ViewHandle` contract is either CONFIRMED sufficient across a non-GTK toolkit↔backend boundary, or its insufficiency is pinned and fed back to ADR-0006/0007 as a seam finding (this is an explicit deliverable — either outcome is a valid result).
- [ ] The chrome-surface half stays backend-agnostic (it embeds an opaque handle; only the backends interpret it), preserving the seam discipline.
- [ ] The outcome (confirmation or the refinement proposal) is recorded durably (mobile ADR / findings note).
- [ ] Desktop v0 gate untouched.

## Blocked by

- `android-renderer-backend-oneshot` and `ios-renderer-backend-oneshot` (needs both mobile `Renderer` backends' `view()` to embed).

## Prompt

> Goal: resolve the single sharpest mobile risk (spec `explore-mobile-shell`, Q3/story 6, and ADR-0007's explicitly-flagged cross-toolkit-embedding spike): prove the opaque `ViewHandle` carries a mobile native view across the mobile chrome-surface↔renderer boundary on BOTH platforms — a mobile chrome-host `embedView`s the renderer's view and shows a page — or pin exactly where the pinned interface is insufficient.
>
> iOS is expected to be straightforward (`UIView*` subview). ANDROID is the real test: the view is a JNI reference to the `android.webkit.WebView`, not a raw pointer, so confirm the opaque `*anyopaque`/`usize` handle contract cleanly carries a JNI global-ref (lifetime + thread-affinity). If it CANNOT, do not force it — that finding is the most valuable output of the whole exploration: pin the exact missing contract and propose the refinement (a typed handle, or a handle-with-vtable) back to ADR-0006/0007. EITHER outcome (confirmed-sufficient OR pinned-insufficient-with-a-proposal) is a valid, complete result.
>
> Keep the chrome-surface half backend-agnostic: it embeds an opaque handle; only the backends interpret it. Read: ADR-0006 (the opaque `ViewHandle` decision) and ADR-0007 (the flagged cross-toolkit-embedding risk), the spec's Q3 decision, the two mobile backends this builds on. Verify iOS on `macos-14`, Android on the KVM Linux emulator leg (via `mobile-verification-legs-ci`). Exploration — the answer is the deliverable. "Done" = ViewHandle sufficiency across the mobile boundary is CONFIRMED (page shown on both) or its insufficiency is pinned with a concrete seam-refinement proposal, recorded durably.
