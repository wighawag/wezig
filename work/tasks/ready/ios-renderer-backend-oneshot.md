---
title: iOS Renderer backend — one real page through the pinned seam (WKWebView)
slug: ios-renderer-backend-oneshot
spec: explore-mobile-shell
blockedBy: [mobile-toolkit-seam-split, ios-toolchain-crosslink]
covers: [4]
needsAnswers: true
---

## What to build

Implement a mobile `Renderer` backend on iOS (`WKWebView`) that satisfies the SAME pinned `Renderer` interface, and drive ONE real page through it (spec story 4): navigate → observe a `finished` lifecycle event → a non-blank snapshot (`WKWebView.takeSnapshot`). This proves the CONTENT seam carries iOS.

The backend is the only iOS code touching `WKWebView`/`WKNavigationDelegate` — the seam contract is identical to desktop and Android. `WKNavigationDelegate` callbacks map to the `LifecycleEvent` union; `loadRequest`/`reload`/`goBack`/`goForward` implement navigation; `view()` returns the `WKWebView`'s `UIView*` as the opaque `ViewHandle`.

Scope (narrowest real case): one page, one lifecycle assertion, one non-blank snapshot, on an iOS 17 Simulator via `simctl`, asserted in a CI job on `macos-14`.

## Acceptance criteria

- [ ] An iOS `Renderer` backend implements the pinned `Renderer` VTable over `WKWebView`, with `WKNavigationDelegate` callbacks mapped to the `LifecycleEvent` union.
- [ ] Driving one navigation produces a `.finished` `LifecycleEvent` to a subscribed callback, mirroring the desktop `shell-test` assertion.
- [ ] `WKWebView.takeSnapshot` proves the view is non-blank after load.
- [ ] The backend returns the `WKWebView`'s `UIView*` as the opaque `ViewHandle` (kept opaque across the seam, per the Q3 decision).
- [ ] The whole proof runs GREEN on an iOS 17 Simulator on a `macos-14` CI job (dedicated leg, not in `zig build test`).
- [ ] The iOS backend is the ONLY code importing `WKWebView`/UIKit webview symbols; callers stay backend-agnostic.

## Blocked by

- `mobile-toolkit-seam-split` (implements against the settled seam shape).
- `ios-toolchain-crosslink` (needs the Zig-hosted WKWebView app + the macos-14 CI job to attach the backend to).

## Prompt

> Goal: implement an iOS `Renderer` backend over `WKWebView` satisfying the pinned `Renderer` seam, and drive ONE real page (spec `explore-mobile-shell`, story 4) — navigate + a `.finished` lifecycle event + a non-blank `takeSnapshot`. Mirror the desktop proof (`SystemWebviewRenderer` + `shell-test`).
>
> The backend is the ONLY iOS code touching `WKWebView`/`WKNavigationDelegate`; everything above the seam stays backend-agnostic. Map `WKNavigationDelegate` methods to the `LifecycleEvent` union; return the `WKWebView`'s `UIView*` as the opaque `ViewHandle` (keep it opaque — the Q3 decision). Verify on a `macos-14` runner via `xcrun simctl` on an iOS 17 simulator, iterating through `gh run view` (no physical Mac needed). Simulator only: no signing, no Apple Developer account.
>
> Read: the `Renderer` seam file + ADR-0005/0006, `SystemWebviewRenderer` for the reference shape, the desktop `shell-test` assertion, the spec's Q3/Q4 decisions, and `ios-toolchain-crosslink` (the app + CI job you extend). Build on the settled split-`Toolkit` shape. Exploration, narrowest case — one page. "Done" = the WKWebView drives one page through the pinned seam with a finished-event + non-blank snapshot, green on an iOS 17 simulator in CI, the backend the sole WKWebView toucher.
