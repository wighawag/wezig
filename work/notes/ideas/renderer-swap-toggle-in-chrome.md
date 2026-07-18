---
title: A chrome control to swap the active Renderer backend (long-press reload → webview ⇄ native)
slug: renderer-swap-toggle-in-chrome
---

## The idea

Add a chrome affordance that swaps which `Renderer` backend is driving the
current page — e.g. a **long-press on the Reload button** toggles between the
system-webview backend and the native `WezigRenderer` (with a normal tap still
reloading). A small visible indicator shows which engine painted the current
page ("webview" vs "wezig"). This makes wezig's headline architectural bet —
the swappable `Renderer` seam (ADR-0005/0006) — a thing the user can actually
see and exercise, and gives developers a one-gesture manual override for
comparing backends on a real page.

## Why the seam already supports this (the cheap part)

The chrome holds ONE `Renderer` value (`renderer: Renderer`, a `{ptr, vtable}`
in `src/chrome.zig` / `src/mobile_chrome.zig`) and talks ONLY to the seam.
ADR-0005: "swapping WebKitGTK for `WezigRenderer` … is a change to which backend
VALUE is passed in, NOT a change to this file." So swapping the active backend
is, at the chrome layer, re-pointing that value + re-attaching lifecycle
callbacks + re-navigating the current URL through the new backend. No seam
change; `chrome_conformance` stays green.

## Why it is NOT actionable yet (the blocking part — be honest)

There is **no second backend to swap to**. Today's only real `Renderer`
implementations are the webview ones (`system_webview_renderer.zig` desktop,
`ios_webview_renderer.zig`, `android_renderer.zig`) plus `FakeRenderer`.
**`WezigRenderer` does not exist** — it is referenced only in the ADRs/docs as
the future native engine. A toggle wired today would swap webview⇄webview (or
webview⇄fake), which proves the mechanism but has no user-visible payoff. So
this idea is **downstream of a native backend existing** (even a trivial
static-page stub).

## Where it belongs / how it relates to the planned work

- **RESOLVED (2026-07-18): this idea IS the swap policy.** `explore-native-renderer`
  decision #4 settled the progressive-swap question as **USER-CONTROLLED, with NO
  automatic routing**: the webview is the default; the native renderer is used
  only when the USER opts in — (a) a manual per-page trigger (THIS toggle) or
  (b) a per-domain user allow-list. So this idea is no longer a secondary
  "override" alongside automatic routing — it is the PRIMARY manual mechanism of
  the swap policy, plus a visible engine indicator. (This matches ADR-0011's
  "explicit, user-controlled trust boundaries" over implicit browser magic.)
- Still gated on a second backend (`WezigRenderer` / a static-page stub)
  existing; `explore-native-renderer` spikes the seam-level swap mechanism
  (re-point the `Renderer` value + re-navigate) on the narrowest case.

## Smallest first step that would make it real (optional spike)

`explore-native-renderer` story #3 already is "render one simple static page
with `WezigRenderer`, everything else via the webview." A minimal version of
THIS idea rides on that: wire a trivial second `Renderer` (a native stub that
paints one static page through the existing v0 layout/paint pipeline) behind the
seam in ONE shell, plus a long-press-reload toggle + an engine indicator — a
narrowest-case proof of the swap routing + the UX affordance together. That is a
de-risking spike for question #4, not a product feature.

## Open sub-questions (for whoever picks this up)

- Manual toggle only, automatic routing only, or automatic with a manual
  override? (Ties directly to `explore-native-renderer` Q4.)
- Per-page or persistent preference? Does a swap re-load the page or repaint the
  existing document?
- The gesture: long-press reload is one option; a dedicated button, a menu item,
  or a settings toggle are others. Long-press keeps the minimal chrome minimal.
- The indicator: text badge, icon, colour of the URL bar? Enough to tell the
  engines apart at a glance.

## Provenance

Proposed 2026-07-18 by the human (wighawag) while testing the v0.1.0 mobile
shell, wanting to exercise the renderer swap the whole architecture is built
around. Depends on: a native `WezigRenderer` (or a static-page stub) existing —
tracked by `explore-native-renderer`.
