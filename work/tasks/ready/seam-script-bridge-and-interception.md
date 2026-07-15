---
title: Add the script-message bridge + request-interception hooks to the Renderer seam
slug: seam-script-bridge-and-interception
spec: explore-webview-shell
blockedBy: [renderer-seam-and-toolkit-seam]
covers: [1]
---

## What to build

Add the two LOAD-BEARING hooks to the `Renderer` seam that `explore-web3-capabilities` (the EIP-1193 provider + `ipfs://`) depends on, and prove each on a trivial case:

- **Script-message bridge:** inject a page-world object into the loaded page and round-trip a message both ways (page calls into native, native posts a result back). On the WebKitGTK backend this is `WebKitUserContentManager` script-message handlers + injected user scripts. Prove it by injecting a trivial `window.wezig.ping()` that round-trips a value.
- **Request-interception / custom-scheme hook:** register a custom URI scheme and serve a response from native code. On WebKitGTK this is `webkit_web_context_register_uri_scheme()` + a `WebKitURISchemeRequestCallback`. Prove it by serving a trivial `wezig-test://hello` that returns a native-generated body the page displays.

Both hooks are added to the `Renderer` interface (so `WezigRenderer` must satisfy them later), with the WebKitGTK implementation behind the seam. As part of proving the interception hook, OBSERVE and note (for the findings task) how WebKitGTK's service-worker `fetch` interception relates to this custom-scheme interception — the two-layer question that determines what a future native service-worker handler must satisfy at the seam.

## Acceptance criteria

- [ ] The `Renderer` seam exposes a script-message bridge; a trivial page-world call round-trips through native and back, proven by a test.
- [ ] The `Renderer` seam exposes a request-interception / custom-scheme hook; a trivial custom scheme is served from native code and rendered, proven by a test.
- [ ] Both hooks are part of the seam INTERFACE (not webview-specific call sites in the chrome), so `WezigRenderer` can implement them later.
- [ ] A note is captured (for `shell-findings-and-build-plan`) on how WebKitGTK service-worker `fetch` interception relates to the custom-scheme interception.
- [ ] Tests cover the new behaviour headless via `xvfb-run`; the v0 gate is untouched and green.
- [ ] Tests mirror the repo's test style.

## Blocked by

- `renderer-seam-and-toolkit-seam` (extends the pinned `Renderer` interface).

## Prompt

> Goal: add the script-message bridge and the request-interception / custom-scheme hook to the `Renderer` seam, and prove each on a trivial case (spec `explore-webview-shell`, ADR-0005). These two hooks are the load-bearing surface `explore-web3-capabilities` builds on (the EIP-1193 provider injects via the script bridge; `ipfs://` is served via interception), so they must be part of the seam INTERFACE, with the WebKitGTK implementation behind it — not one-off webview calls in the chrome.
>
> WebKitGTK specifics: the script bridge is `WebKitUserContentManager` script-message handlers + injected user scripts (prove a `window.wezig.ping()` round-trip); interception is `webkit_web_context_register_uri_scheme()` + a `WebKitURISchemeRequestCallback` (prove a `wezig-test://hello` served from native). While here, OBSERVE how WebKitGTK's service-worker `fetch` interception relates to this custom-scheme interception (two layers), and capture a note for the findings task — this determines what a future native service-worker handler must satisfy at the seam.
>
> Domain vocabulary + framing: `CONTEXT.md`, ADR-0005, and the ADR pinned by `renderer-seam-and-toolkit-seam`. This is exploration: prove the hooks on trivial cases, do NOT build the wallet or IPFS (that is `explore-web3-capabilities`). Test headless under `xvfb-run`; keep it out of the display-free `zig build test` gate. "Done" = both hooks are on the seam interface and proven by tests, with the SW-vs-scheme interception note captured; the v0 gate stays green.
