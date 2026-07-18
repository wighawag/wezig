# Mobile web3-hooks parity — design decisions (for the reviewer / downstream)

_2026-07-18 — task `mobile-web3-hooks-parity` (spec `explore-mobile-shell`, stories 8,9)._

Durable record of the load-bearing choices made proving the two web3 hooks on
both mobile webviews THROUGH the pinned `Renderer` seam. Recorded here (not only
in code) because a reviewer or a downstream task (`explore-web3-capabilities`,
`mobile-verification-legs-ci`, the mobile ADR) could be surprised, and several
touch the shared `mobile_abi.zig` C-ABI + the seam ADRs. Findings (the two
per-platform semantic gaps) are separate, verified notes under
`work/notes/findings/` and linked below.

## What was built

Both hooks now carry through BOTH mobile backends via the SAME seam methods as
desktop (`injectUserScript`/`setScriptMessageHandler`/`evaluateScript`,
`registerScheme`), previously honest no-ops:

- **iOS** (`src/ios_webview_renderer.zig`): the hooks reach the Swift shell over
  the `WkPlatform` C-ABI ops table (extended with `setScriptMessageHandler` +
  `registerScheme`); Swift owns `WKUserContentController` / `WKScriptMessageHandler`
  (`BridgeProof.swift`) and `WKURLSchemeHandler` (`SchemeProof.swift`). Proof
  C-ABI added to `mobile_abi.zig` (`wezig_ios_bridge_proof_*` / `wezig_ios_scheme_proof_*`).
- **Android** (`src/android_renderer.zig`): the hooks reach Java over the
  `JavaBridge`/`CJavaBridge` (extended likewise); `WezigWebViewController` owns
  `addJavascriptInterface`/`evaluateJavascript` + `WebViewClient.shouldInterceptRequest`.
  New JNI up-calls (`wezig_android_on_script_message` / `wezig_android_serve_scheme`)
  and C observers for the instrumented `BridgeSeamTest` / `SchemeSeamTest`.

The seam-CONTRACT proofs (both hooks reach the ops table/bridge + the
page->native / scheme-serve legs re-enter the seam) run headlessly in
`zig build test` via the fake `WkPlatform`/`JavaBridge` (mirroring
`renderer.zig`'s `FakeRenderer` hook tests). The real end-to-end proofs are new
dedicated CI legs (`ios-bridge-proof` / `ios-scheme-proof` on macos-14; Android
`BridgeSeamTest`/`SchemeSeamTest` on the emulator leg), kept OUT of
`zig build test` (spec Q6 / ADR-0007) — the desktop v0 gate is untouched.

## Decisions (would surprise a reviewer / touch another artifact)

1. **The seam `registerScheme`/`setScriptMessageHandler` shapes are UNCHANGED;**
   the per-platform ordering/threading gaps are surfaced at the backend + as
   findings, NOT baked into the seam signature. Alternative considered: add a
   `scheme security traits` / `secure` flag to `registerScheme` now. Rejected as
   premature — that is `explore-web3-capabilities`'s call (ADR-0007 deferred it);
   this task's job is to PROVE parity and RECORD the gap, not decide the trait
   API. **Touches:** ADR-0005/0007, `explore-web3-capabilities`.

2. **iOS scheme handler registered on the config BEFORE webview creation** — the
   iOS ordering constraint is demonstrated in `SchemeProof.swift` (build config →
   `registerScheme` op installs the `WKURLSchemeHandler` → only then create the
   `WKWebView`). **Touches:** the mobile chrome's per-view construction; the
   N-`PageContext` content model must thread the scheme set into each webview's
   config at build time. Finding:
   `work/notes/findings/ios-wkurlschemehandler-registration-ordering-2026-07-18.md`.

3. **The two Android hooks have OPPOSITE thread contracts.** The bridge post
   (`addJavascriptInterface`) IS marshalled onto the UI thread before crossing
   the seam (async reply, like the load callbacks); `shouldInterceptRequest` is
   NOT (it must answer synchronously on the binder thread). So the scheme up-call
   is the ONE seam callback that runs off the UI thread, and the seam
   `SchemeHandler` it invokes must be thread-safe. **Touches:** the seam's
   threading contract, `explore-web3-capabilities`'s `ipfs://` handler. Finding:
   `work/notes/findings/android-custom-scheme-nonui-thread-and-opaque-origin-2026-07-18.md`.

4. **Proof C-ABI is additive scaffolding; `abi_version` NOT bumped.** The new
   `wezig_ios_bridge/scheme_proof_*` + `wezig_android_*` hook thunks are proof
   scaffolding the shells link, not the toolchain shell's `wezig_abi_version`/
   `wezig_greeting` contract — same posture as the story-4 iOS proof C-ABI. The
   story-4 `wezig_ios_proof_start` keeps its signature (the two new `WkPlatform`
   ops are wired to no-op stubs there) so it is not disturbed. **Touches:**
   `mobile_abi.zig`, `mobile/ios/Sources/wezig_mobile.h`.

5. **Android `injectUserScript` = `evaluateJavascript`, not a document-start user
   script.** Android's WebView has NO API equivalent to iOS's
   `WKUserScript(.atDocumentStart)` / WebKitGTK's user-content-manager
   document-start injection. For the narrowest-case proof the injected wrapper is
   evaluated (the bridge page defines `window.wezig` inline anyway); a real
   provider bridge must re-inject on each page start (e.g. an `onPageStarted`
   hook). Recorded so a downstream reader is not surprised the Android bridge
   injection is not document-start-guaranteed. **Touches:**
   `explore-web3-capabilities`'s provider injection on Android.

## Coherence check

No new seam concept, flag, or status was introduced — the hooks reuse the
existing pinned `Renderer` methods and the established ops-table / JavaBridge /
C-observer patterns from the story-4/5 backends. The one new named surface is the
proof C-ABI, which mirrors the existing `wezig_ios_proof_*` / `wezig_android_*`
naming. The per-platform gaps are recorded as `findings` (verified external
ground truth), the correct bucket, not re-meanings of an existing concept.
