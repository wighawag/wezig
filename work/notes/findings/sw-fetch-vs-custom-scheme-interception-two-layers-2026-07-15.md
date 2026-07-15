---
title: WebKitGTK SW `fetch` interception vs custom-scheme interception are TWO layers (native vs page)
date: 2026-07-15
status: open
kind: finding
reviewOf: seam-script-bridge-and-interception
forTask: shell-findings-and-build-plan
source: WebKitGTK 6.0 headers (2.52.3, this dev box) + ADR-0005; observed while proving the seam's `registerScheme` hook (`zig build shell-scheme-test`)
---

Captured for `shell-findings-and-build-plan` (its story-7 / two-layer input). While proving the `Renderer` seam's request-interception hook (`registerScheme` -> `webkit_web_context_register_uri_scheme`, `wezig-test://hello` served from native, `zig build shell-scheme-test` green), I looked at how WebKitGTK's service-worker `fetch` interception relates to the custom-scheme interception the seam now exposes. They are TWO DIFFERENT LAYERS, and conflating them is the trap a future native service-worker handler must avoid.

## The two layers

- **Custom-scheme interception (native / context layer, what this task added).** `webkit_web_context_register_uri_scheme(context, scheme, cb, ...)` installs a `WebKitURISchemeRequestCallback` in OUR native process. It fires for EVERY request to that scheme (top-level navigations, subresources, `fetch()`), BEFORE any page JS sees it, and answers with bytes we generate (`webkit_uri_scheme_request_finish` over a `GInputStream`, or the newer `..._finish_with_response` with a `WebKitURISchemeResponse` carrying status + headers). This is where `ipfs://` and wallet-RPC endpoints get served. It is OURS: it survives the eventual `WezigRenderer` swap because it lives at the seam, not in page script.

- **Service-worker `fetch` interception (page / JS layer, what WebKitGTK provides).** A service worker's `fetch` handler runs INSIDE the web-content process as page-controlled JavaScript. WebKitGTK ships SW support (SW registrations are a first-class website-data category: `WEBKIT_WEBSITE_DATA_SERVICE_WORKER_REGISTRATIONS`, persisted/cleared via the `WebKitNetworkSession`'s `WebKitWebsiteDataManager`). The browser does not register or drive these handlers; the PAGE does, and WebKit runs them. We do not write a `WebKitURISchemeRequestCallback` for them.

## How they relate (the ordering / precedence that matters)

For a request to a normal (http/https) origin, the SW `fetch` handler (page layer) gets first refusal; only requests that leave the SW (or origins with no SW) reach the network/context layer. For a request to OUR custom scheme, our native callback answers it directly. The load-bearing consequence for a future native SW handler at the seam: a service worker can only be registered from, and control, a **secure origin**, and by default a custom scheme is NOT treated as secure/CORS-enabled. WebKitGTK exposes exactly the knobs to fix this at the SAME context/security layer as the scheme itself: `WebKitSecurityManager`'s `register_uri_scheme_as_secure` / `..._as_cors_enabled` / `..._as_local` / `..._as_display_isolated` (queryable via `..._uri_scheme_is_secure`). So the two layers are not independent: whether content served by our native scheme interception can host a service worker is decided by how we register the scheme's security traits, which is a native/context-layer decision.

## What this means for the seam (input to the findings design)

- The seam's custom-scheme hook (`registerScheme`) is the NATIVE-layer interception; it is complete and proven. It is NOT the place a page's own service worker plugs in.
- A future native service-worker handler at the seam is a DIFFERENT surface from `registerScheme`. To satisfy it, the seam must let the backend also declare a scheme's SECURITY TRAITS (secure / CORS / local) at registration time, because SW registration on content we serve depends on the origin being secure. Today `registerScheme` takes only a body + content-type; the findings/design should decide whether scheme security traits belong on that same seam call (extra fields) or a sibling call, and record that a `WezigRenderer` must reproduce both the fetch-serving AND the origin-security semantics for SW-hosting content to behave identically after the swap.
- Design note for the N-concurrent-contexts model (story 7): SW registrations are shared per-`WebKitNetworkSession` website-data, NOT per view. A content model of N page/document contexts decoupled from presentation must decide which contexts share a `WebKitNetworkSession` (hence share SW registrations + cookies) versus get an isolated one; that partitioning is orthogonal to, but interacts with, both interception layers above.
