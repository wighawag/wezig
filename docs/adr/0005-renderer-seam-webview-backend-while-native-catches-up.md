---
status: accepted
---

# The Renderer seam: ship a usable browser on a system-webview backend while the native renderer catches up

wezig will grow its own rendering engine to eventually "match existing browsers," but that is a multi-year effort, and a perfect renderer with no networking, navigation, or chrome is still not a usable browser. So we introduce a top-level **`Renderer` seam** at the chrome-to-content boundary with TWO backends behind it: a **`SystemWebviewRenderer`** (a real system webview: WebKitGTK first, later WebView2 / WKWebView) that makes wezig a usable, differentiated browser NOW, and a **`WezigRenderer`** (our own engine, growing from the v0 subset) that we swap in progressively behind the SAME seam. The chrome, the Ethereum provider, and IPFS resolution are built against the seam, not against either backend, so shipping usability early does not couple us to the webview.

## Context: two things a browser needs that are NOT rendering

"Use a website" needs far more than a renderer: networking (HTTP/TLS), navigation (URL bar, back/forward, history), links, scrolling, input and forms, and JavaScript. The v0 pipeline paints a static fragment; it cannot yet drive an interactive session. Meanwhile "match existing browsers" (real WHATWG parsing, full CSS, floats/flex/grid/tables/positioning, HarfBuzz/FreeType text, networking, JS) is the long axis. Sequencing usability BEHIND a from-scratch renderer would delay a usable product by years and starve the differentiators (native Ethereum provider, native IPFS) of a real browser to live in. The webview "cheat" decouples the two: usability now, native renderer in parallel.

## The seam: navigate/interact, NOT just paint

A system webview owns its own event loop, navigation, networking, JS, and input handling: you hand it a URL and it does everything. Our engine is the opposite: WE must drive networking, layout, hit-testing, scrolling, and input. Therefore the honest seam is NOT "render(document) -> surface" (a webview will not hand us a layout tree or let us drive its layout). It is a wider **content-view** interface, roughly:

- `navigate(url)` / `reload()` / `stop()` and back/forward,
- a live, embeddable interactive view (the content area) the chrome hosts,
- input forwarding, scrolling, viewport/resize,
- navigation + load lifecycle EVENTS (title, URL, progress, favicon) the chrome subscribes to,
- a **script-message bridge** the native Ethereum provider (EIP-1193) and IPFS interception hook into (inject a page-world provider, receive `request` calls, post results back),
- a request-interception / custom-scheme hook so `ipfs://` (and wallet RPC) can be served natively.

Both a system webview and (eventually) `WezigRenderer` can satisfy THIS interface. A finer "document -> frame" boundary cannot be satisfied by a webview, so it is NOT the top seam; it lives INSIDE `WezigRenderer` as its own concern.

## The layered-seam picture (this is what makes the swap cheap)

- **Coarse seam at chrome <-> content** (`Renderer`, this ADR): the only boundary the chrome, the wallet, and IPFS know. `SystemWebviewRenderer` and `WezigRenderer` are the two implementations.
- **Fine seams INSIDE `WezigRenderer`** (existing): `Tokenizer | TreeBuilder` (ADR-0001), `PaintBackend` (ADR-0002), engine-paints-into-a-`Surface` (ADR-0003), and the windowing leaf (ADR-0004). These are our engine's internals; the webview has no equivalent and does not need one.

So the coarse seam buys early usability; the fine seams let our engine mature independently. The progressive swap is per-capability or per-page-type: route what `WezigRenderer` handles well to it, fall back to the webview for the rest, until fallback is no longer needed.

## The discipline that makes or breaks it

The chrome (and the Ethereum/IPFS features) MUST talk ONLY to the `Renderer` seam and NEVER reach past it into WebKitGTK/WebView2-specific APIs. The moment chrome code calls a webview-native API directly, the swap stops being cheap. This is the same rule ADR-0002 set for `PaintBackend` (callers touch only the vtable), applied at the top of the stack. A conformance point worth enforcing later: the chrome crate/module must not import the webview binding at all; only the `SystemWebviewRenderer` implementation may.

## Considered options

- **Native renderer first, usability later (status quo ordering).** Rejected as the primary path: it delays a usable, differentiated browser by years and gives the Ethereum/IPFS work no real browser to inhabit. The renderer still gets built, just in parallel behind the seam rather than as a blocking prerequisite.
- **Wrap a whole system webview with NO seam (chrome hard-wired to WebKitGTK).** Rejected: fastest to a demo, but the renderer and the webview become mutually-exclusive whole-engines with no swap path; replacing the webview later means rewriting the entire content path. The seam is the whole point.
- **A narrow "document -> frame" top seam.** Rejected as the TOP seam: a system webview does not expose that boundary, so it could not sit behind it. That boundary is real, but it belongs INSIDE `WezigRenderer`, not at the chrome edge.
- **First webview backend: WebView2 / WKWebView.** Deferred: the dev + CI platform is Linux, so **WebKitGTK (via webkit2gtk / `WKWebView`-equivalent GObject API)** is the first `SystemWebviewRenderer`; the other platforms' webviews implement the same seam later.

## Consequences

- A new top-level `Renderer` interface is introduced; the chrome/shell (window, tabs, URL bar, navigation, and later the wallet + IPFS UI) is built against it. This supersedes ADR-0004's `main.zig`/SDL app-entrypoint role for the eventual product shell (SDL/the v0 window path remains the harness for exercising `WezigRenderer` directly and the golden tests).
- The Ethereum provider and IPFS resolution are specified in terms of the seam's script-bridge and request-interception hooks, so they work IDENTICALLY whichever backend renders the page: they ship early against the webview and keep working after the native swap.
- The roadmap splits into two parallel tracks (usability via the webview backend; the native renderer maturing behind the same seam). This reshapes the `browser` spec's story ordering; a spec update accompanies this ADR.
- New strategic questions this raises (which system webview per platform; how the script bridge injects the provider; whether/when to route page-types to `WezigRenderer`) are recorded as spec open questions, not decided here.
- Binding a system webview links yet another external library on each platform; like windowing (ADR-0004) this is an OS/library dependency confined to the `SystemWebviewRenderer` implementation, never leaking into the chrome.
