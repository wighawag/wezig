---
title: Shell exploration findings + de-risked build plan (the confidence deliverable)
slug: shell-findings-and-build-plan
spec: explore-webview-shell
blockedBy: [seam-script-bridge-and-interception, chrome-swap-discipline-conformance-check]
covers: [7, 8, 10]
---

## What to build

The exploration's actual DELIVERABLE: a written, durable report + build plan that captures what the spikes LEARNED, so the follow-on usable-browser BUILD spec is a known quantity. This is documentation (an ADR + a findings doc under `docs/`), not code. It must be grounded in what the earlier tasks actually observed — do not speculate where a spike produced a fact.

Cover:
- **The pinned `Renderer` + toolkit seams** — reference the interface ADR; note anything the spikes revealed the seam was MISSING or that a real page needed.
- **GTK leakage** — how much GTK leaked into the chrome despite the toolkit seam (from the conformance-check task): is a Qt / Zig-native chrome genuinely feasible behind this seam, and what would it cost?
- **Service workers + the content model (story 7 — DESIGN it, do not merely mention it)** — what WebKitGTK actually provides for service workers, how its SW `fetch` interception relates to the custom-scheme interception (the two-layer note), and a concrete DESIGN for a content model of N CONCURRENT page/document contexts DECOUPLED from presentation (tabs deferred) that does not assume one-visible-page-at-a-time. This is a real design artifact (the shape of a `PageContext` / how the seam exposes context lifecycle), not just an observation. State what a future NATIVE service-worker handler must satisfy at the seam.
- **Process / sandbox model** — what WebKitGTK imposes (it is already multi-process), and what the shell must assume vs abstract; a build-plan + `explore-web3-capabilities` wallet-boundary input.
- **Headless-testing strategy** — Xvfb + `webkit_web_view_get_snapshot` is the shell-test approach (WebKitGTK has no native headless mode; `GtkOffscreenWindow` is unusable with a WebView, WebKit bug #76911); note the `xvfb` CI-leg requirement.
- **The de-risked BUILD PLAN** — what the follow-on usable-browser build spec should contain and decide (the presentation model over N contexts, history/persistence, downloads, the process model), so the build is atomically taskable when written.

## Acceptance criteria

- [ ] A findings doc under `docs/` captures: the pinned seams (+ gaps found), GTK-leakage assessment, the service-worker + N-concurrent-contexts content-model design, the process/sandbox observations, and the Xvfb headless-testing strategy.
- [ ] An ADR records the load-bearing decisions the exploration settled (or a pointer to the interface ADR + this findings doc).
- [ ] A de-risked BUILD PLAN section states what the follow-on usable-browser spec should contain and the decisions it must make, so it can be authored + tasked atomically.
- [ ] Every claim is grounded in what an earlier task actually observed (no speculation dressed as a finding).
- [ ] The doc matches reality (spot-checked against the shell code + the seam interfaces that landed).

## Blocked by

- `seam-script-bridge-and-interception` and `chrome-swap-discipline-conformance-check` (this report synthesizes ALL the spike learnings, so it comes last).

## Prompt

> Goal: write the exploration's confidence deliverable — a findings doc + ADR + a de-risked build plan for the follow-on usable-browser BUILD spec (spec `explore-webview-shell`, ADR-0005). This is the whole point of an EXPLORATION spec: its "done" is CONFIDENCE + a plan, not a shipped browser. It is documentation, grounded in what the earlier tasks (`webview-hello-window`, `renderer-seam-and-toolkit-seam`, `seam-script-bridge-and-interception`, `chrome-swap-discipline-conformance-check`) actually observed — do not speculate where a spike produced a fact.
>
> Cover, from the spikes: the pinned `Renderer` + toolkit seams (and any gap a real page revealed); how much GTK leaked despite the toolkit seam (is Qt / Zig-native chrome feasible, at what cost); what WebKitGTK provides for service workers and how SW `fetch` interception relates to custom-scheme interception (the two-layer finding) plus the design for N concurrent page/document contexts decoupled from presentation (tabs deferred, must not assume one-page-at-a-time), and what a future native SW handler must satisfy at the seam; what the (already multi-process) WebKitGTK imposes on the process/sandbox model; and the Xvfb + snapshot headless-testing strategy (no native headless; `GtkOffscreenWindow` unusable per WebKit bug #76911) including the `xvfb` CI-leg requirement. End with a de-risked BUILD PLAN: what the follow-on usable-browser build spec must contain and decide, so it can be authored and tasked atomically.
>
> Domain vocabulary + framing: `CONTEXT.md`, ADR-0005, and the ADR pinned by `renderer-seam-and-toolkit-seam`. "Done" = a reader (human or agent) can, from this doc alone, author the follow-on usable-browser build spec with the shell's real shape already known; every claim traces to something a spike observed.
