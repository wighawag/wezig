---
title: Pin the general-browser conformance target as a tiered capability ladder (+ WPT bars)
slug: pin-conformance-tiers
spec: explore-native-renderer
blockedBy: []
covers: [1]
---

## What to build

Pin the CONFORMANCE TARGET for the native `WezigRenderer` as a named, tiered
capability ladder — the decision deliverable for story 1. This is a durable
decision artifact (an ADR plus a checklist doc under `docs/`), not renderer
code. It turns "grow toward a real general browser" from a vibe into a
measurable goal anchored on ADR-0011 (a real general web browser, NOT a
dapp/on-chain niche).

Deliver:
- The **named tiers** (rough ladder to refine: T0 = v0 fixed subset (done);
  T1 = real WHATWG parse + core CSS → static real pages incl. `ipfs://`;
  T2 = floats/flex/grid/tables + real shaping → most static layout;
  T3 = JS + networking + dynamic DOM → interactive sites). Pin the EXACT tiers.
- For EACH tier: (a) a concrete "renders these representative pages" checklist,
  and (b) a WPT-subset bar. Every tier's page checklist MUST include normal,
  server-served general-web pages (the compatibility floor) AND a
  content-addressed / `ipfs://` static page (where the thesis lands early).
- The role of WPT %: the OBJECTIVE secondary regression meter, explicitly NOT
  the roadmap driver.

## Acceptance criteria

- [ ] **ADR numbering (coordination — several sibling exploration tasks add ADRs in parallel):** the new ADR's number is chosen by scanning `docs/adr/` for the highest existing number and incrementing (`ADR-FORMAT.md`); if a concurrently-landed sibling task (`pin-scriptengine-seam`, `native-renderer-findings-and-build-plan`) already took the next number by the time this lands, RE-NUMBER to the next free one at land-time so no two ADRs share a number. Use an `<NNNN>` placeholder in the branch and resolve it against the current `docs/adr/` at integration — do NOT hardcode `0012` on the assumption it is free.
- [ ] An ADR pins the tiered capability ladder (the named tiers, each with a page
      checklist + a WPT-subset bar), anchored on ADR-0011 (general browser, not a
      dapp niche).
- [ ] Every tier's page checklist names both normal server-web pages AND a
      content-addressed / `ipfs://` static page.
- [ ] The doc states WPT % is the secondary regression meter, not the roadmap driver.
- [ ] The tiers are consistent with the existing seams/ADRs (0001–0011) and the
      v0 subset (`docs/v0-subset.md`) as T0.
- [ ] This is documentation only; the v0 build gate is untouched and green.

## Blocked by

- None — can start immediately.

## Prompt

> Goal: pin the native renderer's conformance target as a TIERED capability
> ladder (spec `explore-native-renderer`, story 1, decision 1). This is the
> decision deliverable — an ADR + a checklist doc under `docs/`, NOT renderer
> code. The target is explicitly "a real general web browser" (ADR-0011), not
> "good enough for on-chain apps."
>
> Produce named tiers (refine the rough T0..T3 ladder in the spec into pinned
> tiers). For each tier give (a) a concrete "renders these representative pages"
> checklist that MUST include both normal server-served general-web pages (the
> compatibility floor) AND a content-addressed / `ipfs://` static page (the
> thesis lands early on verifiable static sites), and (b) a WPT-subset bar. State
> clearly that WPT % is the OBJECTIVE secondary regression meter, not the roadmap
> driver.
>
> Domain vocabulary + framing: `CONTEXT.md`, ADR-0011 (general browser for a
> post-trusted-server web), ADR-0001 (v0 thin subset behind swappable seams),
> `docs/v0-subset.md` (this is T0, already done). NOTE: several sibling
> exploration tasks add ADRs in parallel — choose your ADR number by scanning
> `docs/adr/` for the highest + incrementing, and re-number to the next free one
> at land-time if a sibling took it (never hardcode `0012` as free). Ground T0 in the actual v0
> subset. This is exploration: pin the measurable target so follow-on BUILD specs
> can aim at named tiers; do NOT implement any tier. "Done" = a reader can, from
> the ADR + checklist alone, say exactly which pages + WPT bar define each tier.
