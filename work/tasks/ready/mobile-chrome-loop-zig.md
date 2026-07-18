---
title: Shared mobile chrome loop over ChromeSurface (Zig, headless-tested)
slug: mobile-chrome-loop-zig
spec: build-mobile-shell
blockedBy: []
covers: [3, 5, 11]
---

## What to build

The shared, backend-agnostic mobile chrome that both platform shells drive: a Zig chrome loop over the `ChromeSurface` half of the split `Toolkit` (ADR-0008) that owns a URL field + back/forward and reflects the `Renderer`'s lifecycle events into those widgets — the mobile analogue of how `src/chrome.zig` drives `GtkToolkit`, but with NO host/loop half (the OS owns the run loop on mobile).

End-to-end (thin path through every layer it touches): a chrome value holds a `Renderer` + a `ChromeSurface`; on a user "navigate" intent it drives `Renderer.navigate`; on `Renderer` lifecycle events (`uri_changed`, `load_changed`) it calls `ChromeSurface.setUrlText` / `setBackEnabled` / `setForwardEnabled`; on back/forward intents it drives `Renderer.goBack`/`goForward`. It embeds the renderer's opaque `ViewHandle` through `ChromeSurface.embedView`. This is the ONE piece of chrome logic mobile adds; the platform shells (iOS/Android tasks) construct it and feed it the native `ChromeSurface`/`Renderer`.

EXPECTED PATH: add a small dedicated `src/mobile_chrome.zig` `MobileChrome` over a `ChromeSurface`. Reusing the existing `src/chrome.zig` `Chrome` host-loop-free is NOT a clean drop-in — `Chrome.init` takes a COMPOSED `Toolkit` and calls the `HostLoop` half directly (`createWindow`/`setTitle`/`present`/`run`/`quit` in `build`/`start`/`onChromeIntent`), so reusing it would require refactoring `Chrome` to accept a bare `ChromeSurface`, widening the blast radius into the desktop wiring + `chrome_conformance`. So default to a minimal `MobileChrome` unless you can refactor `Chrome` to split cleanly WITHOUT touching desktop behaviour; record the choice + why in a module doc-comment. Either way it must reach ONLY the seams and keep `src/chrome.zig`'s binding-free discipline intact.

NOTE on the surface it drives: the mobile `ChromeSurface` impl (`MobileChromeSurface`) currently lives INSIDE `src/mobile_chrome_surface.zig`, which is the embedding-PROOF file (it also holds `export fn wezig_ios_embed_proof_start` + single-proof-at-a-time state). The `MobileChromeSurface` struct itself is a clean `ChromeSurface` you construct against; if the shell tasks need it separated from the proof scaffolding, extracting the struct is in scope for whichever task first needs a clean reuse — this foundation task only needs to drive a `ChromeSurface` (real or `Fake`), so it can proceed against the existing struct.

## Acceptance criteria

- [ ] A shared mobile chrome value drives a `Renderer` + a `ChromeSurface`: navigate/back/forward intents call the renderer; `Renderer` lifecycle events reflect into `setUrlText`/`setBackEnabled`/`setForwardEnabled`; the renderer's `ViewHandle` is embedded via `ChromeSurface.embedView`.
- [ ] The chrome reaches ONLY the `Renderer` + `ChromeSurface` seams (no `webkit_`/`gtk_`/`android.webkit`/`WKWebView`); `src/chrome_conformance.zig` stays green.
- [ ] Headless seam-contract tests run in `zig build test` (no device, no display) using the `FakeRenderer` + a `ChromeSurface` fake (mirror `FakeToolkit`/`MobileChromeSurface`): assert a navigate intent updates the URL text, and back/forward toggle the enabled flags, exactly as the desktop `chrome.zig` tests do.
- [ ] The reuse-vs-new-`MobileChrome` decision is recorded in a module doc-comment (what was chosen + why), per the spec's Implementation Decisions.
- [ ] The full v0 gate (`zig fmt --check` + `zig build` + `zig build test`) stays green; the core gate stays device-free.
- [ ] Tests cover the new chrome shape headlessly (mirror the repo's `FakeRenderer`/`FakeToolkit` seam-contract style).

## Blocked by

- None — can start immediately. This is the shared Zig foundation both platform shells (`android-shell-app`, `ios-shell-xcode-project`) build on, so it is sequenced FIRST and blocks them.

## Prompt

> Goal: build the shared mobile chrome loop (spec `build-mobile-shell`, stories 3/5/11) — a Zig chrome over the `ChromeSurface` half of the split `Toolkit` (ADR-0008) that owns a URL field + back/forward and reflects `Renderer` lifecycle events into those widgets, exactly as `src/chrome.zig` drives `GtkToolkit` on desktop, but with NO `HostLoop` (the OS owns the run loop on mobile). This is the ONE shared chrome piece both platform shells consume; do NOT build any platform shell here.
>
> Read for context/vocabulary: `CONTEXT.md`; `src/chrome.zig` (the desktop chrome that reflects lifecycle events into toolkit widgets — the shape to mirror; note it takes a COMPOSED `Toolkit` and calls the `HostLoop` half directly, so it is NOT a clean host-loop-free reuse — default to a small new `src/mobile_chrome.zig` `MobileChrome`); `src/toolkit.zig` (`ChromeSurface`/`HostLoop`/`Toolkit`, ADR-0008); `src/mobile_chrome_surface.zig` (the mobile `ChromeSurface` impl `MobileChromeSurface` — currently co-located with the embedding-PROOF C-ABI in that file); `src/renderer.zig` (the seam + `FakeRenderer` + `LifecycleEvent`); `src/chrome_conformance.zig` (the binding-free guard). Record the `MobileChrome`-vs-refactored-`Chrome` choice + why in a module doc-comment. Test headlessly in `zig build test` with `FakeRenderer` + a `ChromeSurface` fake — a navigate intent updates the URL text; back/forward toggle the enabled flags. Keep `chrome_conformance` green and the core gate device-free. "Done" = a shared mobile chrome drives navigation + reflects lifecycle through `ChromeSurface`, headless-tested, gate green.
