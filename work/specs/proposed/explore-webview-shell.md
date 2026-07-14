---
title: Explore — the webview shell (pin the Renderer seam, prove it end-to-end, learn the shell)
slug: explore-webview-shell
humanOnly: true
needsAnswers: true
taskedAfter: [browser]
---

> Launch snapshot — records intent at creation, NOT maintained. Current truth: `docs/adr/` (decisions) + the code; remaining work: `work/tasks/ready/` tasks.

> **This is an EXPLORATION-scoped spec.** Its deliverable is CONFIDENCE + a de-risked plan, NOT a finished browser. It pins the `Renderer` seam interface, proves it end-to-end with a thin vertical spike (one real page loads and is interactive via WebKitGTK behind the seam), and LEARNS the shell's real shape — crucially the unknowns you can only discover by building a thin version (tabs: do we want them and how do they interact with the seam; how much GTK leaks into the chrome; whether the seam is actually sufficient; the process model under a real webview). The full usable-browser BUILD is a follow-on spec, written once this exploration says "yes, this way, and here is how." (Even though WebKitGTK renders the page on day one, this is exploration because the SHELL is where the real unknowns live.)

<!-- open-questions -->

## Open questions

These gate tasking this spec (`needsAnswers: true`). Exploration exists to ANSWER them; a couple must be decided up front to start the spike, the rest are what the spike resolves.

1. **First webview binding + GTK exposure (decide up front).** ADR-0005 picks WebKitGTK. Confirm webkit2gtk 6.0 (GTK4) vs 4.1 (GTK3), and whether GTK is the acceptable chrome toolkit for the spike or the chrome should host only the webview's content widget. This is the one choice needed before the spike starts.
2. **The `Renderer` seam surface (the spike RESOLVES this).** ADR-0005 sketches it (navigate/reload/stop, back/forward, an embeddable interactive view, input/scroll/viewport, load-lifecycle events, a script-message bridge, a request-interception / custom-scheme hook). The spike's job is to prove which of these a real page actually needs and pin the concrete Zig interface — especially the script-bridge shape, since `explore-web3-capabilities` builds on it. Output: a pinned interface + an ADR.
3. **Tabs — do we want them, and how do they meet the seam? (the spike LEARNS this.)** Is the content model one-renderer-per-tab, and how does the seam expose tab lifecycle? The minimum "use a website" bar is single-tab; the exploration should surface what a multi-tab model would demand of the seam so the build plan can decide, without necessarily building tabs.
4. **Process / sandbox model (was browser Q5; the spike OBSERVES it).** WebKit is already multi-process; our native renderer is not. Learn what the webview backend imposes and note what the shell must assume vs abstract, since it is foundational and hard to retrofit. Full resolution can wait for the build spec, but the exploration must report what it saw.
5. **Windowing under the shell.** ADR-0004 kept SDL as a v0 leaf and prototyped native X11; once a GTK/webview shell exists, GTK owns the window. Confirm ADR-0005's lean: the webview toolkit owns windowing for the shell, and SDL/native is reserved for exercising `WezigRenderer` directly.

<!-- /open-questions -->

## Problem Statement

wezig's v0 paints a static fragment, but "use a website" needs networking, navigation, links, scrolling, input, and JS — almost none of it rendering. Building that natively first would delay a usable product by years. The webview "cheat" (ADR-0005) can deliver usability early, BUT we do not yet know the shape of the shell: whether the `Renderer` seam as sketched is sufficient, how tabs interact with it, how much of GTK leaks into the chrome, or what process model a real webview imposes. We need to LEARN these by building a thin, real version before committing to a full usable-browser build.

## Solution

Build the thinnest real thing that exercises the whole idea: pin the `Renderer` seam (ADR-0005) as a concrete Zig interface, implement a `SystemWebviewRenderer` on WebKitGTK behind it, and stand up a minimal chrome (one window, a URL bar, back/forward) that talks ONLY to the seam. Drive one real webpage through it end-to-end (load, click a link, scroll, type into a field) to prove the seam surface and the chrome↔content boundary. Along the way, LEARN and REPORT the shell unknowns (tabs, GTK leakage, process model, the script-bridge shape) so the follow-on build spec is de-risked. The output is a pinned seam (+ ADR), a working spike, resolved/answered questions, and a build plan — not a finished browser.

## User Stories

1. As a developer, I want the `Renderer` seam pinned as a concrete Zig interface (navigate/interact + script-bridge + interception hooks), recorded in an ADR, so that both backends and the chrome build against a stable, proven boundary.
2. As a developer, I want a `SystemWebviewRenderer` (WebKitGTK) implementing that interface for the spike, so that a real, complete renderer sits behind the seam.
3. As a developer, I want a minimal chrome (one window, URL bar, back/forward) that talks ONLY to the seam, so that the chrome↔content boundary is real and the swap-discipline is exercised from day one.
4. As a user (of the spike), I want to load one real webpage and click a link, scroll, and type into a field, so that the exploration proves the seam end-to-end on a real page.
5. As a developer, I want the exploration to LEARN and write down the shell unknowns — tabs (and how they'd meet the seam), how much GTK leaks into the chrome, the process model the webview imposes, and whether the seam surface was sufficient — so that the build plan is informed by reality, not guesses.
6. As a developer, I want a conformance check that the chrome does not import the webview binding directly (only `SystemWebviewRenderer` may), so that the swap-cheapness discipline is testable from the spike onward.
7. As a developer, I want the exploration to emit a de-risked BUILD PLAN (what the full usable-browser spec should contain, what tabs/history/process decisions it must make), so that the follow-on build is a known quantity.

## Out of Scope (this is exploration)

- A finished, feature-complete usable browser — multi-tab, history persistence, bookmarks, downloads, settings. The exploration LEARNS what these demand of the seam; BUILDING them is the follow-on build spec.
- The native rendering engine (`explore-native-renderer`) and the web3 capabilities (`explore-web3-capabilities`) — this spec only pins and proves the seam they depend on.
- Non-Linux webview backends — the spike is WebKitGTK; other platforms implement the pinned seam later.
