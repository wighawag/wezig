---
title: Pin the ScriptEngine seam + write the SpiderMonkey/JSC/V8 bind recommendation
slug: pin-scriptengine-seam
spec: explore-native-renderer
blockedBy: []
covers: [5, 6]
---

## What to build

Make the JS-engine boundary REVERSIBLE and pin the first-engine recommendation
(decision 3, story 5). Two coupled deliverables — a seam and a written
recommendation — so a future build spec can commit to a bound engine while
keeping a Zig-native swap-in possible.

- **Add a `ScriptEngine` SEAM** — the same reversibility pattern as the
  `Renderer` seam (ADR-0005): an interface a bound engine satisfies now and a
  Zig-native (`kiesel`) one can satisfy LATER. CAVEAT the seam must surface
  explicitly: unlike `Renderer`/`PaintBackend`, a JS-engine seam is a WIDE,
  DOM-COUPLED boundary (the engine calls back into DOM/GC/event-loop constantly)
  — pin it knowing it is intimate, not a thin vtable. Prove the seam compiles/
  holds with a trivial no-op or stub implementation (do NOT bind a real engine —
  that is a follow-on build).
- **Write the bind recommendation (ADR):** SpiderMonkey vs JavaScriptCore vs V8,
  with EXPLICIT criteria — independence / ethos-alignment (favours SpiderMonkey:
  the one major engine not owned by a browser-platform vendor, Servo's choice);
  reuse (we already link WebKit on the webview backend → favours JSC); raw perf +
  embedding ergonomics (favours V8). LEAN SpiderMonkey pending an embedding-cost
  eval. Record the Zig-native (`kiesel`) position: aspirational swap-in AFTER a
  bound engine ships compatibility, possibly FIRST for a narrow controlled-trust
  surface, never the general-web compatibility engine at the start.

## Acceptance criteria

- [ ] A `ScriptEngine` seam/interface exists (mirroring the `Renderer`-seam
      reversibility pattern), satisfied by a trivial stub, and the caveat that it
      is a WIDE DOM-coupled boundary is documented at the seam.
- [ ] An ADR records the SpiderMonkey/JSC/V8 recommendation with the
      independence / reuse / perf criteria and the SpiderMonkey lean (pending
      embedding-cost eval).
- [ ] The ADR records the Zig-native (`kiesel`) later-swap-in position (after a
      bound engine ships; possibly first for a narrow controlled-trust surface).
- [ ] No real JS engine is bound (that is a follow-on build); the seam holds with
      a stub and the v0 build gate stays green.
- [ ] Tests cover the seam/stub per the repo's test style.

## Blocked by

- None — can start immediately.

## Prompt

> Goal: add a `ScriptEngine` SEAM and write the SpiderMonkey/JSC/V8 bind
> recommendation (spec `explore-native-renderer`, story 5, decision 3). This makes
> the JS boundary reversible (bind first, Zig-native later) and produces the
> engine recommendation a future build spec commits against. Do NOT bind a real
> engine — prove the seam with a stub and write the decision.
>
> Model the seam on the `Renderer` seam's reversibility (ADR-0005): an interface a
> bound engine satisfies now, a Zig-native (`kiesel`) one later. SURFACE the
> caveat explicitly — unlike `Renderer`/`PaintBackend`, a JS-engine seam is a
> WIDE, DOM-COUPLED boundary (constant callbacks into DOM/GC/event-loop), so it is
> intimate, not a thin vtable; document that at the seam. Then write the ADR:
> SpiderMonkey vs JSC vs V8 with explicit criteria — independence/ethos (favours
> SpiderMonkey, Servo's choice, not owned by a browser-platform vendor), reuse (we
> already link WebKit on the webview backend → favours JSC), perf + embedding
> ergonomics (favours V8). LEAN SpiderMonkey pending an embedding-cost eval.
> Record the `kiesel` position: aspirational later swap-in, possibly first for a
> narrow controlled-trust (verifiable/local-first) surface, never the general-web
> compatibility engine at the start.
>
> Domain vocabulary + framing: `CONTEXT.md`, ADR-0005 (Renderer seam pattern),
> ADR-0006 (pinned seams), ADR-0011 (controlled-trust surfaces). This is
> exploration on the narrowest case (story 6): seam + stub + written
> recommendation; do NOT bind SpiderMonkey/JSC/V8. "Done" = the seam holds with a
> stub (caveat documented), the ADR states the recommendation + criteria + the
> kiesel-later position, and the v0 gate stays green.
