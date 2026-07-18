---
title: ADR — mobile app lifecycle is host-only (seam not grown; WezigRenderer forces it later)
slug: mobile-shell-lifecycle-adr
spec: build-mobile-shell
blockedBy: []
covers: [9]
---

## What to build

Record the load-bearing decision this slice makes (spec Resolved decision 1, story 9) in a new `docs/adr/` entry: **mobile app lifecycle / state-restoration is a HOST concern above the `Renderer` seam — the seam is NOT grown with `suspend`/`resume`/state-save-restore now.** Capture the why (both current backends restore their own state natively; adding a seam method now is the speculative growth ADR-0006 forbids, the same discipline that deferred input/scroll) and the breadcrumb (a future `WezigRenderer` on mobile IS expected to force a seam-level lifecycle API, to be pinned THEN — a KNOWN deferral, not an oversight).

This is a documentation/decision deliverable — no code gate change. It exists so a future `WezigRenderer`-on-mobile task knows exactly what it owes, and so the deferral is discoverable rather than implicit.

## Acceptance criteria

- [ ] A new `docs/adr/<NNNN>-<slug>.md` (next sequential number, `ADR-FORMAT.md` shape) records: the decision (lifecycle host-only, seam unchanged), the rationale (backends restore natively; avoid speculative pinned-interface growth; the input/scroll precedent), and the breadcrumb (`WezigRenderer` on mobile is expected to force a seam-level `suspend`/`resume`/state API, pinned then).
- [ ] The ADR cross-references ADR-0006 (the MINIMAL-seam discipline it follows), ADR-0009 (the mobile exploration outcome), and the `build-mobile-shell` spec.
- [ ] No code change; the desktop v0 gate stays green (documentation only).

## Blocked by

- None — can start immediately. The decision is already made (spec Resolved decision 1); this task records it durably. It is independent of the code tasks (touches only `docs/adr/`).

## Prompt

> Goal: record the mobile app-lifecycle decision (spec `build-mobile-shell`, Resolved decision 1, story 9) in a new `docs/adr/` entry: mobile lifecycle / state-restoration is HOST-ONLY — the `Renderer` seam is NOT grown with `suspend`/`resume`/state methods now. Capture the why (both current backends — `WKWebView`, `android.webkit.WebView` — restore their own state natively, so a seam method would forward a signal the host already has; adding it now is the speculative pinned-interface growth ADR-0006 forbids, the same discipline that deferred input/scroll until a second backend forced the shape) and the breadcrumb (a future `WezigRenderer` on mobile owns no OS widget that auto-persists and IS expected to force a seam-level lifecycle API, pinned THEN — a KNOWN deferral).
>
> Read: `work/protocol/ADR-FORMAT.md` (format + numbering — scan `docs/adr/` for the highest number and increment); ADR-0006 (the MINIMAL-seam discipline + the input/scroll deferral precedent); ADR-0009 (mobile exploration outcome); the `build-mobile-shell` spec's Resolved decision 1. This is documentation only — no code change, desktop gate stays green. "Done" = a new ADR pins lifecycle-host-only with the rationale + the `WezigRenderer`-forces-it-later breadcrumb, cross-referenced to ADR-0006/0009 and the spec.
