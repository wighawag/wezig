---
title: Explore — the webview shell (pin the Renderer seam, prove it end-to-end, learn the shell)
slug: explore-webview-shell
humanOnly: true
taskedAfter: [browser]
---

> Launch snapshot — records intent at creation, NOT maintained. Current truth: `docs/adr/` (decisions) + the code; remaining work: `work/tasks/ready/` tasks.

> **This is an EXPLORATION-scoped spec.** Its deliverable is CONFIDENCE + a de-risked plan, NOT a finished browser. It pins the `Renderer` seam interface, proves it end-to-end with a thin vertical spike (one real page loads and is interactive via WebKitGTK behind the seam), and LEARNS the shell's real shape — the unknowns you can only discover by building a thin version. The full usable-browser BUILD is a follow-on spec, written once this exploration says "yes, this way, and here is how." (Even though WebKitGTK renders the page on day one, this is exploration because the SHELL is where the real unknowns live.)

## Resolved decisions (summary — detail now lives in the tasks + ADRs)

The launch open questions are decided, so the spec is tasked. The running theme: **SEAM EVERYTHING so every component is swappable** (content backend, chrome toolkit, windowing), consistent with ADR-0002/0004. In brief: (1) WebKitGTK **6.0/GTK4** with a GTK chrome for the spike, but behind a **toolkit seam** so the chrome host is swappable (GTK → Qt → Zig-native) — TWO seams, `Renderer` (content) + toolkit (chrome); (2) the `Renderer` seam starts minimal and gains the **script-message bridge + custom-scheme interception** hooks (which `explore-web3-capabilities` depends on), pinned in an ADR; (3) content model = **N concurrent page/document contexts decoupled from presentation, service-worker-aware by design** (tabs-as-UI deferred; SW not implemented, only designed-for); (4) process/sandbox model is **observed and reported**, not decided; (5) windowing = GTK owns the shell window behind a **windowing seam** (SDL/native stays the `WezigRenderer`-direct harness). Grounded on real WebKitGTK APIs (`WebKitNetworkSession`; SW support; `webkit_web_context_register_uri_scheme` for interception). The full detail lives in the tasks (`work/tasks/`) and the interface ADR they produce.

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
