---
source: WKWebViewConfiguration / WKURLSchemeHandler docs (Apple) + the mobile-web3-hooks-parity spike (mobile/ios)
---

# iOS `WKURLSchemeHandler` MUST be registered on the configuration BEFORE the `WKWebView` is created — surfaced at the `Renderer` seam

Verified while implementing the iOS custom-scheme hook (task
`mobile-web3-hooks-parity`, spec `explore-mobile-shell` Q5/story 9).

**Ground truth.** A custom URI scheme is served on iOS by installing a
`WKURLSchemeHandler` via `WKWebViewConfiguration.setURLSchemeHandler(_:forURLScheme:)`.
`WKWebView` **copies its configuration at `init`**, so a handler set on the
configuration (or via `webView.configuration`) AFTER the webview is created is
ignored: requests to the scheme 404 / fail. The handler must be on the config
object BEFORE `WKWebView(frame:configuration:)` is called. (Additionally, iOS
forbids registering a handler for a scheme WebKit already handles — `http`,
`https`, `file`, `about`, `data`, … — so custom schemes like `wezig-test://` /
`ipfs://` must be genuinely custom names.)

**Why it matters at the seam.** The desktop WebKitGTK backend registers a scheme
on the *web context* at any time (`registerScheme` -> `webkit_web_context_register_uri_scheme`),
and Android's `shouldInterceptRequest` is a per-`WebViewClient` hook set on an
existing WebView — neither has this ordering constraint. iOS is the ONE backend
where `registerScheme` is **lifecycle-ordered relative to view creation**. This
is exactly the "scheme security/registration traits at the seam" item ADR-0007
deferred; proving the hook on iOS forces it.

**Resolution taken (how the seam surfaces it).** The `Renderer` seam's
`registerScheme` shape is unchanged (`scheme` + `SchemeHandler`), but its iOS
backend (`src/ios_webview_renderer.zig`) documents that the platform op it drives
(`WkPlatform.registerScheme`) MUST be invoked by the native shell while
assembling the `WKWebViewConfiguration`, before the webview exists. The proof's
Swift shell (`mobile/ios/Sources/SchemeProof.swift`) demonstrates the ordering
explicitly: it builds the config, calls `wezig_ios_scheme_proof_start` (which
reaches `registerScheme`, installing the `WKURLSchemeHandler` on that config) and
ONLY THEN creates the `WKWebView` from it. The backend's module doc records the
constraint so a future `WezigRenderer`/mobile-chrome build honours it.

**Downstream implication.** For `explore-web3-capabilities`'s `ipfs://`: the iOS
chrome host must register the `ipfs` scheme handler at webview-construction time
(it cannot lazily add it after the view exists, as it might on desktop/Android).
Any per-context/per-view creation of webviews (the N-`PageContext` content model,
ADR-0007) must thread the scheme set into EACH webview's configuration at build
time. Recorded durably here + in the `ios_webview_renderer.zig` module doc + the
task done-record; fed to ADR-0005/0007 (the seam's scheme-registration lifecycle)
and `explore-web3-capabilities`.
