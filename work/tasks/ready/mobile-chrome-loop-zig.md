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

DECIDE (self-contained, resolvable from the code — record the choice in a module doc-comment): whether to REUSE the existing `src/chrome.zig` `Chrome` driven host-loop-free (it already talks only to the seams; the host-loop half is absent on mobile), or to add a small dedicated `src/mobile_chrome.zig` `MobileChrome`. Prefer reuse if `Chrome` composes cleanly against a `ChromeSurface`-only toolkit without a `HostLoop`; otherwise add the minimal mobile chrome. Either way it must reach ONLY the seams and keep `src/chrome.zig`'s binding-free discipline intact.

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
> Read for context/vocabulary: `CONTEXT.md`; `src/chrome.zig` (the desktop chrome that reflects lifecycle events into toolkit widgets — the shape to mirror); `src/toolkit.zig` (`ChromeSurface`/`HostLoop`/`Toolkit`, ADR-0008); `src/mobile_chrome_surface.zig` (`MobileChromeSurface`, the mobile `ChromeSurface` impl); `src/renderer.zig` (the seam + `FakeRenderer` + `LifecycleEvent`); `src/chrome_conformance.zig` (the binding-free guard). DECIDE reuse-`chrome.zig`-host-loop-free vs a small new `src/mobile_chrome.zig`; record the choice in a module doc-comment. Test headlessly in `zig build test` with `FakeRenderer` + a `ChromeSurface` fake — a navigate intent updates the URL text; back/forward toggle the enabled flags. Keep `chrome_conformance` green and the core gate device-free. "Done" = a shared mobile chrome drives navigation + reflects lifecycle through `ChromeSurface`, headless-tested, gate green.
