---
title: Prove the two web3 hooks on both mobile webviews (bridge + custom-scheme parity)
slug: mobile-web3-hooks-parity
spec: explore-mobile-shell
blockedBy: [android-renderer-backend-oneshot, ios-renderer-backend-oneshot]
covers: [8, 9]
needsAnswers: true
---

## What to build

Confirm the two web3-load-bearing `Renderer`-seam hooks carry on BOTH mobile webviews with the SAME seam semantics (spec stories 8,9), so `explore-web3-capabilities`'s EIP-1193 provider + `ipfs://` work is backend-agnostic across desktop AND mobile — recording any per-platform semantic gap as a finding at the seam.

- **Script-message bridge** (`injectUserScript` / `setScriptMessageHandler` / `evaluateScript`): round-trip ONE message both ways (`window.wezig.ping`), mirroring the desktop `shell-bridge-test`.
  - iOS: `WKUserContentController` add-user-script + `WKScriptMessageHandler` + `evaluateJavaScript`.
  - Android: `WebView.addJavascriptInterface` + `evaluateJavascript` — callbacks arrive on a NON-UI (binder) thread; marshal correctly and record the thread contract.
- **Custom-scheme interception** (`registerScheme`): serve ONE `wezig-test://hello` request from native returning a body + content-type that renders, mirroring the desktop `shell-scheme-test`.
  - iOS: `WKURLSchemeHandler`, registered on the `WKWebViewConfiguration` BEFORE the webview is created — surface this ordering constraint at the seam.
  - Android: `WebViewClient.shouldInterceptRequest` (non-UI thread). Record the custom-scheme SECURITY-ORIGIN/`isSecure` traits (Android treats custom schemes as opaque/insecure by default — affects secure-context/service-worker behaviour on served content, directly relevant to `ipfs://`).

## Acceptance criteria

- [ ] The script-message bridge round-trips one message both ways on iOS (`WKUserContentController` path) AND Android (`addJavascriptInterface`/`evaluateJavascript` path), mirroring `shell-bridge-test`, green in each platform's CI leg.
- [ ] A registered custom scheme serves one native body that renders on iOS (`WKURLSchemeHandler`) AND Android (`shouldInterceptRequest`), mirroring `shell-scheme-test`.
- [ ] The iOS scheme-registration ORDERING constraint (schemes set on the configuration before webview creation) is surfaced at the seam and recorded.
- [ ] The Android non-UI-thread contract (bridge + scheme callbacks) and custom-scheme security-origin/`isSecure` traits are recorded as findings, with their implication for `ipfs://` secure-context behaviour noted.
- [ ] The hooks are exercised THROUGH the pinned `Renderer` seam (same method names as desktop), keeping the capabilities backend-agnostic; findings feed `explore-web3-capabilities` and, where they change the seam, ADR-0005/0006/0007.
- [ ] Desktop v0 gate untouched; mobile proofs run in the dedicated CI legs, not `zig build test`.

## Blocked by

- `android-renderer-backend-oneshot` and `ios-renderer-backend-oneshot` (the hooks extend each mobile `Renderer` backend).

## Prompt

> Goal: prove the two web3 hooks (script-message bridge + custom-scheme interception) on BOTH mobile webviews with the SAME `Renderer`-seam semantics as desktop (spec `explore-mobile-shell`, stories 8,9), so `explore-web3-capabilities`'s provider + `ipfs://` are backend-agnostic. Mirror the desktop proofs exactly: `shell-bridge-test` (round-trip `window.wezig.ping` both ways) and `shell-scheme-test` (serve `wezig-test://hello` from native). The seam methods (`injectUserScript`/`setScriptMessageHandler`/`evaluateScript`, `registerScheme`) already exist and are proven on WebKitGTK — implement them for each mobile backend.
>
> Platform mappings + gaps to RECORD (spec Resolved decisions §Q5): iOS bridge → `WKUserContentController` + `WKScriptMessageHandler` + `evaluateJavaScript`; iOS scheme → `WKURLSchemeHandler`, which MUST be registered on the `WKWebViewConfiguration` before the webview is created (surface this ordering at the seam). Android bridge → `addJavascriptInterface`/`evaluateJavascript`, callbacks on a NON-UI binder thread (marshal, record the contract); Android scheme → `WebViewClient.shouldInterceptRequest` (non-UI thread), and record that Android custom schemes are opaque/insecure by default (affects secure-context/service-worker on served content — matters for `ipfs://`). These gaps ARE the "scheme security traits at the seam" item ADR-0007 deferred; feed them back to `explore-web3-capabilities` and the seam ADRs.
>
> Read: the `Renderer` seam file (the two hooks + their doc comments), `system_webview_renderer.zig` for the reference implementation, `shell-bridge-test`/`shell-scheme-test` for the reference assertions, the spec's Q5 decision. Verify iOS on `macos-14`, Android on the KVM emulator leg. Exploration on the narrowest case — one bridge round-trip, one scheme request per platform. "Done" = both hooks proven on both mobile webviews through the seam, with the iOS ordering + Android threading/security-trait gaps recorded as findings.
