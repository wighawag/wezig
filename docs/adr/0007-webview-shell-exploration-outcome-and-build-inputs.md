---
status: accepted
---

# The webview-shell exploration outcome: proceed on the two seams, and the build inputs it settled

The `explore-webview-shell` exploration (ADR-0005) is complete. Its verdict: **yes, build the usable browser on the two pinned seams** — the `Renderer` content seam and the `Toolkit` chrome-host seam (both pinned in ADR-0006) — because a minimal chrome drove a real, interactive page and the two web3-load-bearing hooks (script-message bridge, custom-scheme interception) end-to-end THROUGH those seams, with the chrome machine-proven to reach neither `webkit` nor `gtk`. The full findings, the service-worker + N-concurrent-`PageContext` content-model DESIGN, the GTK-leakage assessment, the process/sandbox observations, the Xvfb headless-testing strategy, and the de-risked build plan live in `docs/shell-exploration-findings.md`; this ADR records only the load-bearing decisions that document settles, so the follow-on usable-browser build spec inherits them as fixed points.

This ADR does not re-pin the interfaces (ADR-0006 does that) and does not decide the shell's final process model (the spec's stance was to observe, not decide). It records WHAT the exploration proved and the load-bearing choices it deliberately DEFERRED to the build spec, so those are not silently re-litigated.

## Decisions this exploration settled

- **Proceed on the two seams as pinned (ADR-0006).** The seam surface was sufficient for a one-window, URL-bar, back/forward chrome on a real page; no gap blocked the spike. The build spec builds against `Renderer` + `Toolkit`, never around them, and the conformance guard (`src/chrome_conformance.zig`) keeps the chrome binding-free in the v0 `zig build test` gate.
- **The service-worker interception model is two layers, and they are NOT interchangeable.** Custom-scheme interception (`registerScheme`) is the NATIVE/context layer we own and that survives the `WezigRenderer` swap; a page's service-worker `fetch` is the PAGE/JS layer WebKitGTK runs. A future native SW handler is a DIFFERENT seam surface from `registerScheme`, and SW-hosting on content we serve depends on the scheme's SECURITY TRAITS (secure/CORS/local), which are a context-layer decision. Ground truth: `work/notes/findings/sw-fetch-vs-custom-scheme-interception-two-layers-2026-07-15.md`.
- **The content model is N concurrent `PageContext`s decoupled from presentation.** Deferring tabs-as-UI must not bake in one-visible-page-at-a-time: navigate/lifecycle/hooks become per-context, presentation is a `Toolkit.embedView` of the selected context, and background contexts keep running (including their service workers). SW registrations and cookies are per-`WebKitNetworkSession` website-data, so contexts carry a session-partition identity. This is a DESIGN the build spec adopts and may revise, not a newly pinned interface (`docs/shell-exploration-findings.md` section 3).
- **The headless-test strategy is Xvfb + `webkit_web_view_get_snapshot`, in dedicated build steps.** WebKitGTK has no native headless mode and `GtkOffscreenWindow` is unusable with a WebView (WebKit bug #76911), so the real-backend proofs run under `xvfb-run` as `shell-test`/`shell-bridge-test`/`shell-scheme-test`, kept OUT of the display-free `zig build test` gate. CI needs a DEDICATED leg provisioning `xvfb` + `libwebkitgtk-6.0-dev`.

## Load-bearing choices deferred to the build spec (surfaced, not decided)

These are recorded so the build spec makes them deliberately rather than inheriting them by accident (full detail: `docs/shell-exploration-findings.md` section 6):

- **Input/scroll/focus forwarding on the `Renderer` seam.** Absent today because the WebKitGTK view handles input itself; a `WezigRenderer` cannot, so the method set must be added BEFORE a second backend lands (adding it after two implementations exist breaks a pinned interface).
- **Scheme security traits at the seam** (extra `registerScheme` fields vs a sibling call).
- **Session/partition identity on `PageContext`** (which contexts share a `WebKitNetworkSession`).
- **A seam-level snapshot API** (the smoke snapshot is the one place the shell reaches past the seam today).
- **Cross-toolkit view embedding** (the opaque `ViewHandle` is a GtkWidget both backends agree on; a non-GTK chrome hosting a WebKitGTK view is a foreign-embedding spike, not a drop-in).

## Consequences

- The follow-on usable-browser BUILD spec is authorable from `docs/shell-exploration-findings.md` alone, with the shell's real shape and gaps known; its atomic tasks (presentation-over-`PageContext`s, the input-forwarding seam extension, session partitioning, downloads, history/persistence, the Xvfb CI leg) each build against a seam whose surface and deferred decisions are now recorded.
- `explore-web3-capabilities` inherits a concrete wallet boundary: the page-world provider posts `request` over the script bridge (untrusted, content process), native decides + replies (trusted, UI-side), and the boundary holds identically after the `WezigRenderer` swap because it is expressed at the seam.
- The two-seams pinning (ADR-0006) stands; this ADR neither supersedes nor amends it, it records the exploration's outcome and the build inputs that reference it.
