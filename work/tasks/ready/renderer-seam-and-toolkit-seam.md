---
title: Pin the Renderer seam + the chrome/toolkit seam as Zig interfaces
slug: renderer-seam-and-toolkit-seam
spec: explore-webview-shell
blockedBy: [webview-hello-window]
covers: [1, 2, 3, 5, 6]
---

## What to build

Extract the hello-window's ad-hoc WebKitGTK/GTK calls behind TWO seams (the "seam everything" theme), so both are swappable, and record the pinned interfaces in an ADR:

- **The `Renderer` seam** (content backend): a Zig interface with navigate / reload / stop, back / forward, an embeddable interactive view, input / scroll / viewport, and load-lifecycle events (title, URL, progress). `SystemWebviewRenderer` (WebKitGTK) is its first and only implementation now; `WezigRenderer` implements the same interface later.
- **The chrome/toolkit seam** (chrome host): a Zig abstraction for the window + widgets the chrome uses, so GTK is swappable later (GTK now → Qt → a Zig-native chrome layer). The GTK implementation is the first and only one now. This is ALSO where **windowing sits behind a seam** (story 6): GTK owns the shell window now, but it is reached through the toolkit abstraction (not hard-wired), so the windowing layer is a swappable component — record this and the swap path in the ADR. (SDL/native windowing from ADR-0004 stays the `WezigRenderer`-direct harness, untouched.)

Stand up a MINIMAL chrome (one window, a URL bar, back/forward buttons) that talks ONLY to these two seams — never to `webkit`/`gtk` symbols directly. Start the `Renderer` interface MINIMAL (just what this minimal chrome needs); the script-bridge + interception hooks are a separate task. Record the pinned interface shapes + the two-seam decision in `docs/adr/000N-*.md`.

## Acceptance criteria

- [ ] A `Renderer` Zig interface exists (navigate/reload/stop, back/forward, interactive view, input/scroll/viewport, load-lifecycle events), with `SystemWebviewRenderer` (WebKitGTK) implementing it.
- [ ] A chrome/toolkit seam exists (window + the widgets the chrome needs), with a GTK implementation behind it; the shell WINDOW is reached through this seam (not hard-wired to GTK), so windowing is a swappable component (story 6). The ADR records the windowing-seam decision + swap path.
- [ ] A minimal chrome (window + URL bar + back/forward) drives real navigation THROUGH the seams only; it imports neither `webkit` nor `gtk` symbols directly.
- [ ] An ADR records both pinned interfaces and the two-seam (content + toolkit) decision.
- [ ] The `shell` / `shell-test` steps still work through the seams; the v0 gate is untouched and green.
- [ ] Tests cover the new behaviour (a seam-level test driving navigation), mirroring the repo's test style, headless via `xvfb-run` where a display is needed.

## Blocked by

- `webview-hello-window` (extends the same shell module; refactors its calls behind the seams).

## Prompt

> Goal: turn the hello-window's direct WebKitGTK/GTK calls into TWO pinned, swappable seams and a minimal chrome that uses only them (spec `explore-webview-shell`, ADR-0005). Decisions already made (do not re-litigate): there are TWO seams — the `Renderer` seam (content backend: WebKitGTK now, `WezigRenderer` later) and a chrome/toolkit seam (chrome host: GTK now, Qt/Zig-native later). Both are Zig interfaces with exactly one implementation today. Start the `Renderer` interface MINIMAL (navigate/reload/stop, back/forward, interactive view, input/scroll/viewport, load-lifecycle events) — the script-message bridge and request-interception hooks are added by the NEXT task, so do not build them here.
>
> The minimal chrome (one window, URL bar, back/forward) must talk ONLY to the two seams — it must not reference `webkit_*` or `gtk_*` symbols directly (a later task adds a conformance check for exactly this). Record the pinned interface shapes and the two-seam decision in a new ADR (`docs/adr/`), since these interfaces are load-bearing for `explore-web3-capabilities` and the eventual `WezigRenderer` swap.
>
> Domain vocabulary + seam framing: `CONTEXT.md`, ADR-0002 (the `PaintBackend` seam is the precedent for "callers touch only the interface"), ADR-0005. This is exploration: pin and prove the seams on the minimal case, do not build a full browser. "Done" = a minimal chrome navigates real pages through the two seams, no direct webkit/gtk imports in the chrome, and an ADR pins the interfaces; the v0 gate stays green.
