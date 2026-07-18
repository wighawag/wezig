---
source: android.webkit.WebViewClient.shouldInterceptRequest / WebResourceResponse docs + Chromium custom-scheme origin behaviour + the mobile-web3-hooks-parity spike (mobile/android)
---

# Android custom-scheme interception: `shouldInterceptRequest` runs (and must answer) on a NON-UI thread, and custom schemes are OPAQUE/insecure origins by default

Verified while implementing the Android custom-scheme hook (task
`mobile-web3-hooks-parity`, spec `explore-mobile-shell` Q5/story 9). This is the
sharper Android half of the two gaps the spec's §Q5 flagged, and the
"scheme security traits at the seam" item ADR-0007 deferred.

## Gap 1 — the thread contract for `shouldInterceptRequest` is DIFFERENT from the load callbacks

`WebViewClient.shouldInterceptRequest(WebView, WebResourceRequest)` is invoked on
a **non-UI (binder) thread**, like the load callbacks. BUT unlike the load
callbacks (which we marshal onto the UI thread with a `Handler` post before
crossing the seam — see `android-webviewclient-nonui-thread-marshalling-2026-07-18.md`),
`shouldInterceptRequest` **must return its `WebResourceResponse` synchronously on
that binder thread** — the WebView blocks the thread waiting for the bytes. It
therefore CANNOT hop to the UI thread and wait for a reply.

**Consequence for the seam.** The custom-scheme up-call
(`wezig_android_serve_scheme` -> the seam `SchemeHandler`) is the **one seam
callback that legitimately runs off the host/UI thread**. The seam's
`SchemeHandler.onRequest` must be thread-safe and must not touch UI state; it
returns a `SchemeResponse` (body + content-type) which the Java side wraps in a
`WebResourceResponse(new ByteArrayInputStream(...))` synchronously. The bridge
hook (`addJavascriptInterface.postMessage`) is the opposite: it fires on a
private binder thread too, but IS marshalled onto the UI thread before crossing
the seam (its reply is asynchronous, so it can). So the two web3 hooks have
OPPOSITE thread contracts on Android, and the seam records both.

## Gap 2 — a custom scheme is an OPAQUE / insecure origin by default (matters for `ipfs://`)

Android's WebView (Chromium) treats a request served via `shouldInterceptRequest`
for a **custom scheme** as an **opaque origin** that is NOT a secure context by
default: `window.isSecureContext` is false, `crypto.subtle` is unavailable,
service workers cannot be registered, and cross-origin / CORS semantics differ
from an `https://` origin. There is no public `WebView` API equivalent to
WebKitGTK's `WebKitSecurityManager.register_uri_scheme_as_secure` /
`_as_cors_enabled` to promote a custom scheme to a secure/CORS-enabled origin —
the closest levers are `WebSettingsCompat`/`WebViewAssetLoader` (which serve
under an `https://appassets.androidplatform.net` origin precisely to GET a secure
context) or `setAllowUniversalAccessFromFileURLs` (file scheme only, discouraged).

**Consequence for `explore-web3-capabilities`'s `ipfs://`.** Content served from
native via a bare `ipfs://` custom scheme on Android will NOT be a secure context
and CANNOT host a service worker, whereas the same content on desktop WebKitGTK
CAN be made secure by registering the scheme's security traits at the context
layer (the two-layers finding,
`sw-fetch-vs-custom-scheme-interception-two-layers-2026-07-15.md`). So
`ipfs://` behaviour is NOT backend-identical for secure-context/SW-dependent
pages: the seam must let a backend declare (or the mobile chrome choose) either
(a) serve `ipfs://` content under a synthetic secure `https://` origin
(app-assets style) so it gets a secure context, or (b) accept that `ipfs://`
content is a non-secure origin on Android. This is a real per-platform semantic
gap, not a bug — it is exactly the "scheme security traits at the seam" decision
ADR-0007 deferred, now forced by proving the hook on mobile.

## What this task did / recorded

The story-9 proof serves a plain HTML body (no SW, no secure-context dependency),
so it renders identically on both webviews — the narrowest real case. The
security-trait gap above does not block THAT proof; it is recorded as the
load-bearing finding the follow-on work must resolve. Fed to
`explore-web3-capabilities` and ADR-0005/0007 (the seam's scheme-security-traits
decision), and recorded in `src/android_renderer.zig`'s module doc + the task
done-record + `mobile/android/README.md`.
