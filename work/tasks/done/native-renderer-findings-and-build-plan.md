---
title: Native-renderer exploration findings + de-risked, sliced build plan (the confidence deliverable)
slug: native-renderer-findings-and-build-plan
spec: explore-native-renderer
blockedBy: [pin-conformance-tiers, spike-harfbuzz-shaping, spike-networking-fetch-verify, spike-page-gpu-context, spike-native-stub-and-user-swap, pin-scriptengine-seam]
covers: [6, 7]
---

## What to build

The exploration's actual DELIVERABLE (story 7): a written, durable report + a
de-risked, SLICED build plan that captures what the spikes LEARNED, so the
follow-on native-renderer BUILD specs are known quantities. This is
documentation (a findings doc under `docs/` + an ADR), grounded in what the
earlier tasks actually observed — do NOT speculate where a spike produced a fact.

Synthesize from the six tasks:
- **The pinned tiered conformance target** (`pin-conformance-tiers`) — the ladder
  the build plan aims each slice at.
- **The pinned libraries, proven** — HarfBuzz shaping behind `PaintBackend`
  (`spike-harfbuzz-shaping`, incl. the FreeType-needed-yet note); the bound HTTP +
  TLS pick with hash-verified content-addressed fetch (`spike-networking-fetch-verify`);
  the page-facing GPU pick (Dawn vs `wgpu-native`) with the WebGL first-class
  assessment (`spike-page-gpu-context`).
- **The user-controlled swap mechanism, proven** (`spike-native-stub-and-user-swap`)
  — the seam-level routing + per-domain-allow model, and what the native stub
  revealed the `Renderer` seam was missing (if anything).
- **The `ScriptEngine` seam + engine recommendation** (`pin-scriptengine-seam`) —
  the reversible boundary, the SM/JSC/V8 lean, the kiesel-later position, and the
  wide-DOM-coupled caveat's build implications.
- **The de-risked, SLICED BUILD PLAN** — which follow-on specs grow the parser /
  CSS / layout / text / networking / GPU / JS / the user-swap chrome, IN WHAT
  ORDER, TO WHICH TIER (from `pin-conformance-tiers`). Each slice must be
  atomically taskable when authored: name what it contains and the decisions it
  must make.

## Acceptance criteria

- [ ] A findings doc under `docs/` captures each spike's outcome (shaping,
      networking+verify, page-GPU + WebGL assessment, user-swap + allow-model,
      ScriptEngine seam + engine recommendation) and any seam gaps the spikes
      revealed.
- [ ] An ADR records the load-bearing decisions the exploration settled (or points
      to the per-decision ADRs the spike tasks produced). **ADR numbering:** choose
      the number by scanning `docs/adr/` for the highest + incrementing
      (`ADR-FORMAT.md`); this task is `blockedBy` the ADR-producing pin tasks so it
      normally lands after them, but still resolve an `<NNNN>` placeholder against
      the current `docs/adr/` at land-time rather than hardcoding a number.
- [ ] A de-risked, SLICED BUILD PLAN names the follow-on specs, their order, and
      the target tier for each, so each can be authored + tasked atomically.
- [ ] Every claim traces to something an earlier task actually observed (no
      speculation dressed as a finding); the plan is consistent with the pinned
      tiers.
- [ ] The doc matches reality (spot-checked against the seams/code the spikes
      touched); this is documentation only and the v0 build gate stays green.

## Blocked by

- `pin-conformance-tiers`, `spike-harfbuzz-shaping`, `spike-networking-fetch-verify`,
  `spike-page-gpu-context`, `spike-native-stub-and-user-swap`, `pin-scriptengine-seam`
  — this report synthesizes ALL the spike learnings, so it comes last.

## Prompt

> Goal: write the native-renderer exploration's confidence deliverable — a
> findings doc + ADR + a de-risked, SLICED build plan for the follow-on
> native-renderer BUILD specs (spec `explore-native-renderer`, stories 6–7). This
> is the whole point of an EXPLORATION spec: its "done" is CONFIDENCE + a plan,
> not a shipped renderer (that is a decade-scale, Ladybird-class effort). It is
> documentation, grounded in what the earlier tasks actually observed — do not
> speculate where a spike produced a fact.
>
> Synthesize from: `pin-conformance-tiers` (the tiered target), `spike-harfbuzz-shaping`
> (real shaping behind `PaintBackend` + the FreeType note), `spike-networking-fetch-verify`
> (bound HTTP+TLS pick + hash-verified content-addressed fetch),
> `spike-page-gpu-context` (Dawn/`wgpu-native` pick + the WebGL first-class
> assessment), `spike-native-stub-and-user-swap` (the user-controlled swap
> mechanism + per-domain-allow model + any `Renderer`-seam gap), and
> `pin-scriptengine-seam` (the reversible ScriptEngine seam + SM/JSC/V8 lean +
> kiesel-later + the wide-DOM-coupled caveat). End with a de-risked, SLICED BUILD
> PLAN: which follow-on specs grow the parser / CSS / layout / text / networking /
> GPU / JS / the user-swap chrome, in what ORDER, to which TIER, each atomically
> taskable when authored.
>
> Domain vocabulary + framing: `CONTEXT.md`, ADR-0011, ADR-0005/0006 (seams), and
> every ADR the spike tasks produced. "Done" = a reader can, from this doc alone,
> author the follow-on native-renderer build specs with the risky parts already
> de-risked and the target tiers already named; every claim traces to something a
> spike observed; the v0 gate stays green.
