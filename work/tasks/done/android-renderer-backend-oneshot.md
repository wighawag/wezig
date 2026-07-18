---
title: Android Renderer backend — one real page through the pinned seam (android.webkit.WebView)
slug: android-renderer-backend-oneshot
spec: explore-mobile-shell
blockedBy: [mobile-toolkit-seam-split, android-toolchain-ndk-crosslink]
covers: [5]
---

## What to build

Implement a mobile `Renderer` backend on Android (`android.webkit.WebView`) that satisfies the SAME pinned `Renderer` interface the desktop `SystemWebviewRenderer` does, and drive ONE real page through it (spec story 5): navigate → observe a `finished` lifecycle event reaching a subscriber → the view is non-blank. This proves the CONTENT seam carries Android.

The backend is the only Android code touching `android.webkit.*` — the seam contract is identical to desktop. Because the WebView lives on the JVM side behind JNI, the backend bridges Zig↔Java (via the JNI shim from the toolchain task): `navigate`/`reload`/back-forward call into the WebView; `WebViewClient` load callbacks (which arrive on a non-UI thread — marshal to the seam callback appropriately) drive the `LifecycleEvent` union.

Scope (narrowest real case): one page, one lifecycle assertion, one non-blank snapshot. The real emulator RUN is asserted in the CI verification leg (`mobile-verification-legs-ci`); this task's local floor is the backend compiling + a headless/unit proof of the seam wiring.

## Acceptance criteria

- [ ] An Android `Renderer` backend implements the pinned `Renderer` VTable (navigate/reload/stop, back/forward, view, setViewportSize, lifecycle callback) over `android.webkit.WebView`.
- [ ] Driving one navigation produces a `.finished` `LifecycleEvent` delivered to a subscribed callback (mirroring the desktop `shell-test` assertion), with WebViewClient's non-UI-thread callbacks correctly marshalled to the seam.
- [ ] The view renders a non-blank page (a snapshot/bitmap check), proven on an x86_64 emulator (the emulator run may be delegated to `mobile-verification-legs-ci`; this task's floor: the backend + wiring compile and the seam contract holds).
- [ ] The Android backend is the ONLY code importing `android.webkit.*`; the chrome/seam callers stay backend-agnostic.
- [ ] Any semantic gap found (threading, lifecycle-event mapping) is recorded as a finding (done-record / mobile ADR).
- [ ] Desktop v0 gate untouched and green; the seam-contract portion runs headlessly where possible.

## Blocked by

- `mobile-toolkit-seam-split` (implements against the settled seam shape).
- `android-toolchain-ndk-crosslink` (needs the NDK build + JNI shim + WebView shell to attach the backend to).

## Prompt

> Goal: implement an Android `Renderer` backend over `android.webkit.WebView` satisfying the pinned `Renderer` seam, and drive ONE real page through it (spec `explore-mobile-shell`, story 5) — navigate + a `.finished` lifecycle event observed + a non-blank view. Mirror the desktop proof: `SystemWebviewRenderer` (WebKitGTK) is the reference implementation and `shell-test` is the reference assertion (load-finished + non-blank snapshot).
>
> The backend is the ONLY Android code allowed to touch `android.webkit.*`; everything above the seam stays backend-agnostic (same discipline as the desktop chrome). The WebView is on the JVM side behind JNI (use the shim from `android-toolchain-ndk-crosslink`): call navigate/back/forward into the WebView; map `WebViewClient` load callbacks to the `LifecycleEvent` union. KNOWN GAP to handle and record (spec Q5): `WebViewClient` callbacks and `shouldInterceptRequest` run on NON-UI (binder) threads — marshal to the seam callback correctly; note the thread contract as a finding.
>
> Read: the `Renderer` seam file + its ADRs (ADR-0005/0006), `SystemWebviewRenderer` for the reference shape, the desktop `shell-test` mode for the reference assertion, the spec's Q5 decision. The real emulator RUN can be delegated to `mobile-verification-legs-ci` (KVM-accelerated Linux runner); this task's floor is the backend + seam wiring compiling and the contract holding. Exploration, narrowest case — one page. "Done" = the Android WebView drives one page through the pinned seam with a finished-event + non-blank proof, the backend is the sole `android.webkit` toucher, and thread/lifecycle findings are recorded.
