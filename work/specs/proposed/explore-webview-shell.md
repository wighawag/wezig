---
title: Explore — the webview shell (pin the Renderer seam, prove it end-to-end, learn the shell)
slug: explore-webview-shell
humanOnly: true
taskedAfter: [browser]
---

> Launch snapshot — records intent at creation, NOT maintained. Current truth: `docs/adr/` (decisions) + the code; remaining work: `work/tasks/ready/` tasks.

> **This is an EXPLORATION-scoped spec.** Its deliverable is CONFIDENCE + a de-risked plan, NOT a finished browser. It pins the `Renderer` seam interface, proves it end-to-end with a thin vertical spike (one real page loads and is interactive via WebKitGTK behind the seam), and LEARNS the shell's real shape — the unknowns you can only discover by building a thin version. The full usable-browser BUILD is a follow-on spec, written once this exploration says "yes, this way, and here is how." (Even though WebKitGTK renders the page on day one, this is exploration because the SHELL is where the real unknowns live.)

## Resolved decisions (answers to the launch open questions)

These were the launch open questions; they are now decided, so the spec is taskable. The running theme: **SEAM EVERYTHING so every component is swappable** (content backend, chrome toolkit, windowing), consistent with ADR-0002/0004.

1. **Binding + chrome toolkit: WebKitGTK 6.0 (GTK4), GTK chrome for the spike, BEHIND A TOOLKIT SEAM.** The spike uses WebKitGTK 6.0/GTK4 and GTK for the chrome (fastest path to a real, interactive page). But the chrome talks to a **chrome/toolkit abstraction**, not to GTK directly, so the toolkit is swappable later (GTK → Qt → a Zig-native chrome layer). So there are TWO seams: the `Renderer` seam (content backend) AND a toolkit seam (chrome host). The spike must report how much GTK leaks despite the seam.
2. **`Renderer` seam surface: start minimal, add the load-bearing hooks as explicit spike goals, pin in an ADR.** Start from a minimal interface (navigate/reload/stop, back/forward, an embeddable interactive view, input/scroll/viewport, load-lifecycle events) and ADD the **script-message bridge** and **request-interception / custom-scheme hook** as explicit spike goals even if a plain page does not need them — because `explore-web3-capabilities` (EIP-1193 provider + `ipfs://`) builds directly on them. Output: a concrete Zig interface pinned in an ADR.
3. **Content model: N concurrent page/document contexts, DECOUPLED from presentation; service-worker-AWARE by design (not implemented).** Tabs-as-a-UI are DEFERRED (we may want something other than tabs). But the architecture assumes **multiple concurrently-loaded page contexts** from the start, decoupled from however they are presented. Service workers are the architectural driver: a page context can outlive or precede its view (background execution, a document sharing a worker), so the content model must NOT assume one-visible-page-at-a-time. The spike still loads ONE real page; SW-awareness is a DESIGN-REVIEW criterion + a build-plan input, NOT something the spike implements or proves. The spike must CHECK what WebKitGTK actually provides for service workers and map how its SW `fetch` interception relates to our custom-scheme interception (see below), so that when we later swap to `WezigRenderer` we know what our own SW handler must satisfy at the seam.
4. **Process / sandbox model: OBSERVE and REPORT only.** WebKitGTK is already multi-process (see WebKitNetworkSession); our native renderer is not. The spike observes what the webview imposes and reports it (a build-plan + `explore-web3-capabilities` wallet-boundary input); it does NOT decide the whole sandbox architecture now.
5. **Windowing: GTK owns the shell window for now, behind a WINDOWING SEAM.** Confirmed ADR-0005's lean: the webview toolkit (GTK) owns the shell window, and SDL/native windowing (ADR-0004) stays the harness for exercising `WezigRenderer` directly. But windowing is seamed too, so it is a swappable component (consistent with ADR-0004's leaf philosophy) rather than hard-wired to GTK.

> **WebKitGTK reality checked (grounds the spike):** service workers ARE supported (WebCore workers/service is built in; networking/SW/cache governed by `WebKitNetworkSession`). Request interception is `webkit_web_context_register_uri_scheme()` + a `WebKitURISchemeRequestCallback` — the exact mechanism the `ipfs://` / web3 hooks use. Note the TWO interception layers the spike must map: the browser's custom-scheme handler vs. a page's service-worker `fetch` handler; how they compose is a finding for the seam (it determines what our own future SW handler must do behind the `Renderer` seam).

## Problem Statement

wezig's v0 paints a static fragment, but "use a website" needs networking, navigation, links, scrolling, input, and JS — almost none of it rendering. Building that natively first would delay a usable product by years. The webview "cheat" (ADR-0005) can deliver usability early, BUT we do not yet know the shape of the shell: whether the `Renderer` seam as sketched is sufficient, how tabs interact with it, how much of GTK leaks into the chrome, or what process model a real webview imposes. We need to LEARN these by building a thin, real version before committing to a full usable-browser build.

## Solution

Build the thinnest real thing that exercises the whole idea: pin the `Renderer` seam (ADR-0005) as a concrete Zig interface, implement a `SystemWebviewRenderer` on WebKitGTK behind it, and stand up a minimal chrome (one window, a URL bar, back/forward) that talks ONLY to the seam. Drive one real webpage through it end-to-end (load, click a link, scroll, type into a field) to prove the seam surface and the chrome↔content boundary. Along the way, LEARN and REPORT the shell unknowns (tabs, GTK leakage, process model, the script-bridge shape) so the follow-on build spec is de-risked. The output is a pinned seam (+ ADR), a working spike, resolved/answered questions, and a build plan — not a finished browser.

## User Stories

1. As a developer, I want the `Renderer` seam pinned as a concrete Zig interface (navigate/interact + script-bridge + interception hooks), recorded in an ADR, so that both backends and the chrome build against a stable, proven boundary.
2. As a developer, I want a `SystemWebviewRenderer` (WebKitGTK) implementing that interface for the spike, so that a real, complete renderer sits behind the seam.
3. As a developer, I want a minimal chrome (one window, URL bar, back/forward) that talks ONLY to the seam, so that the chrome↔content boundary is real and the swap-discipline is exercised from day one.
4. As a user (of the spike), I want to load one real webpage and click a link, scroll, and type into a field, so that the exploration proves the seam end-to-end on a real page.
5. As a developer, I want the chrome to talk to a **toolkit/chrome-host abstraction** (not to GTK directly), so that the chrome toolkit is swappable (GTK now → Qt or a Zig-native chrome layer later); the spike reports how much GTK leaks despite the seam.
6. As a developer, I want **windowing to be a seamed, swappable component** (GTK owns the shell window now; SDL/native stays the `WezigRenderer`-direct harness), so that the windowing layer can change without touching the chrome, consistent with ADR-0004.
7. As a developer, I want the content model to assume **N concurrent page/document contexts, decoupled from presentation and service-worker-aware** (a context can outlive/precede its view), so that deferring tabs-as-UI does not bake in a one-page-at-a-time architecture. The spike documents what WebKitGTK provides for service workers and how its SW `fetch` interception relates to our custom-scheme interception, as a build-plan + native-SW input.
8. As a developer, I want the exploration to LEARN and write down the shell unknowns — the multi-context/SW implications, how much GTK leaks despite the toolkit seam, the process model the webview imposes, and whether the seam surface was sufficient — so that the build plan is informed by reality, not guesses.
9. As a developer, I want a conformance check that the chrome does not import the webview binding directly (only `SystemWebviewRenderer` may), and does not import the GTK toolkit directly (only the toolkit-seam implementation may), so that BOTH swap disciplines (content backend, chrome toolkit) are testable from the spike onward.
10. As a developer, I want the exploration to emit a de-risked BUILD PLAN (what the full usable-browser spec should contain: the presentation model over N contexts, history/process/service-worker decisions), so that the follow-on build is a known quantity.

## Out of Scope (this is exploration)

- A finished, feature-complete usable browser — the presentation model (tabs or otherwise), history persistence, bookmarks, downloads, settings. The exploration LEARNS what these demand of the seams; BUILDING them is the follow-on build spec.
- **Implementing service workers, or a second chrome toolkit (Qt / Zig-native), or a second windowing backend.** These are why the seams exist, but the spike only DESIGNS the seams to admit them and REPORTS what they will require — it builds exactly ONE implementation of each (WebKitGTK content, GTK chrome, GTK window) plus the seam.
- The native rendering engine (`explore-native-renderer`) and the web3 capabilities (`explore-web3-capabilities`) — this spec only pins and proves the seams they depend on.
- Non-Linux webview backends — the spike is WebKitGTK; other platforms implement the pinned `Renderer` seam later.
