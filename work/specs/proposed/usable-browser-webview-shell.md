---
title: A usable browser now — Renderer seam + system-webview backend + chrome shell
slug: usable-browser-webview-shell
humanOnly: true
needsAnswers: true
taskedAfter: [browser]
---

> Launch snapshot — records intent at creation, NOT maintained. Current truth: `docs/adr/` (decisions) + the code; remaining work: `work/tasks/ready/` tasks.

<!-- open-questions -->

## Open questions

These gate tasking this spec (hence `needsAnswers: true`). They are the forks the webview-first strategy raises; the ORIGINAL browser-spec questions that this track owns are folded in.

1. **First webview binding + how it is bound.** ADR-0005 picks WebKitGTK (webkit2gtk / WebKitWebView) as the first `SystemWebviewRenderer` because Linux is the dev/CI platform. Confirm: webkit2gtk 6.0 (GTK4) vs 4.1 (GTK3)? And is GTK the acceptable chrome toolkit for v1, or do we want a Zig-native chrome hosting only the webview's content widget? This decides how much GTK leaks into the shell.
2. **The `Renderer` seam surface (exact interface).** ADR-0005 sketches it (navigate/reload/stop, back/forward, an embeddable interactive view, input/scroll/viewport, load-lifecycle events, a script-message bridge, a request-interception / custom-scheme hook). Ratify the concrete Zig interface — especially the script-bridge shape (how a page-world object is injected and how request/response round-trips) since `web3-native-capabilities` builds directly on it.
3. **Process / sandbox model** (was browser-spec Q5). Single-process to start (simplest), or multi-process/sandboxed from the outset? A webview backend brings its OWN process model (WebKit already multi-process); our native renderer does not yet. Decide whether the shell assumes one model or abstracts both, since it is foundational and hard to retrofit once chrome hardens.
4. **Windowing under the shell.** ADR-0004 kept SDL as a v0 windowing leaf and prototyped native X11. Once a GTK/webview shell exists, GTK owns the window. Do we (a) let the webview toolkit own windowing for the shell and reserve SDL/native only for exercising `WezigRenderer` directly, or (b) keep a single windowing abstraction both backends present into? ADR-0005 leans (a); confirm.
5. **Tab / navigation model scope for v1.** Single window + single tab + URL bar + back/forward is the minimum "use a website" bar. Are multi-tab, history persistence, bookmarks, and downloads in the first usable milestone, or a follow-up?

<!-- /open-questions -->

## Problem Statement

wezig's v0 can paint a static HTML/CSS fragment, but that is not a browser a person can use: "use a website" needs networking (HTTP/TLS), navigation (URL bar, back/forward, history), links, scrolling, input and forms, and JavaScript — almost none of which is rendering. Building all of that natively before wezig is usable would delay a usable, differentiated product by years and starve the differentiators (native Ethereum provider, native IPFS) of a real browser to live in. wezig needs to be a usable browser EARLY, without permanently coupling itself to a shortcut.

## Solution

Introduce a top-level `Renderer` seam at the chrome↔content boundary (ADR-0005) with two backends behind it: a `SystemWebviewRenderer` (a real system webview — WebKitGTK first) that makes wezig usable NOW, and a `WezigRenderer` (our own engine, grown by the `native-renderer-conformance` spec) that swaps in progressively behind the SAME seam. Build the chrome/shell — window, tabs, URL bar, navigation, load lifecycle — against the seam ONLY, never against a webview-specific API, so shipping usability early does not couple the product to the webview. The seam is a navigate/interact interface (not merely "paint a document"), because a webview owns its own event loop, navigation, networking, and JS; the fine-grained document/paint seams (ADR-0001/0002/0003) live INSIDE `WezigRenderer`, not at this boundary.

## User Stories

1. As a user, I want to type a URL and see the page load in a window, so that wezig can actually browse the web.
2. As a user, I want back/forward, reload, and stop, so that navigation works like a real browser.
3. As a user, I want to click links and scroll, and have forms and text input work, so that I can use interactive sites.
4. As a developer, I want the chrome/shell to talk ONLY to a `Renderer` interface (never to a webview-specific API), so that the content backend is swappable.
5. As a developer, I want a `SystemWebviewRenderer` (WebKitGTK) implementing that interface, so that wezig is a usable browser now on a complete, real renderer.
6. As a developer, I want the seam to expose a script-message bridge and a request-interception / custom-scheme hook, so that native capabilities (Ethereum provider, IPFS) can attach at the seam and work whichever backend renders the page.
7. As a developer, I want a conformance rule (a test or a lint) that the chrome module does not import the webview binding directly — only the `SystemWebviewRenderer` implementation may — so that the swap stays cheap over time.
8. As a user, I want a minimal usable shell (one window, URL bar, back/forward, one tab), so that "use a website" is met at the first milestone; richer tab/history/bookmark features are a follow-up.

## Out of Scope

- The native rendering engine's growth past v0 — that is `native-renderer-conformance` (this spec CONSUMES `WezigRenderer` through the seam but does not build it).
- The Ethereum provider and IPFS behaviour themselves — that is `web3-native-capabilities` (this spec only provides the seam hooks they attach to).
- Non-Linux webview backends (WebView2 / WKWebView) — they implement the same seam later; the first backend is WebKitGTK.
