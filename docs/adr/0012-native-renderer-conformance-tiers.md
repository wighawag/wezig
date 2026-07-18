<!--
  ADR NUMBER COORDINATION: several sibling exploration tasks (spec
  `explore-native-renderer`: `pin-scriptengine-seam`,
  `native-renderer-findings-and-build-plan`) add ADRs in parallel. `0012` was
  the next free number when this branch was cut (highest existing was 0011). If a
  sibling landed 0012 first, RE-NUMBER this file (and every reference to
  "ADR-0012" in this file and in `docs/conformance-tiers.md`) to the next free
  number at integration. Do not assume 0012 is free.
-->
---
status: accepted
---

# The native renderer's conformance target is a TIERED capability ladder (page checklists + WPT bars)

`WezigRenderer`'s growth toward matching an incumbent browser is a decade-scale,
Ladybird-class effort (`explore-native-renderer`); "grow toward a real general
browser" is unmeasurable as stated, so it cannot drive follow-on build specs. We
decide the conformance target is a **named, tiered capability ladder** — T0
(fixed v0 subset, done) → T1 (real static documents) → T2 (full static layout) →
T3 (interactive sites) — where **each tier is defined by a concrete "renders
these representative pages" checklist** (its human-legible, roadmap-driving
definition) **plus a WPT-subset bar** (its objective, secondary *regression*
meter). The tiers and their contents are pinned in `docs/conformance-tiers.md`;
this ADR records the decision and its rationale. The target is anchored on
**ADR-0011: a real general web browser**, NOT "good enough for on-chain / dapp
frontends."

## Why a tiered ladder (and not a single target or a raw WPT number)

- **A single "conformant browser" target is not actionable.** Full conformance is
  many years and many build specs away; a binary done/not-done target gives no
  intermediate, shippable goals for follow-on specs to aim at. Named tiers give
  each build spec a concrete "aim at T1/T2/T3" it can commit to.
- **Pages, not percentages, must drive the roadmap.** The most natural objective
  handle is "raise the WPT pass rate," but WPT coverage is uneven and full of
  deep edge cases with little real-page impact; optimising the number optimises
  the suite, not the pages users open. The ladder therefore makes the **page
  checklist** the primary driver and the WPT bar the *secondary* meter (see the
  next section). This is the load-bearing, easy-to-get-wrong choice this ADR
  exists to pin.
- **The thesis is page-shaped, so the tiers must be.** ADR-0011 makes verifiable /
  content-addressed content a first-class goal that lands EARLY on static sites.
  A capability ladder keyed on representative pages can encode "an `ipfs://`
  static site renders at T1" as a hard requirement; a WPT percentage cannot. So
  **every tier's checklist pins BOTH a normal server-served page floor (the
  compatibility guarantee) AND a content-addressed / `ipfs://` static page** at
  the same tier — the thesis is not deferred to a final tier, it rides every rung.
- **The tiers extend the existing seams, not a new structure.** The ladder grows
  by swapping mature backends in at the seams ADR-0001 already pinned
  (`Tokenizer | TreeBuilder`, the `Selector` matcher, the cascade, `PaintBackend`)
  and routing at the `Renderer` seam (ADR-0005). T0 is exactly the v0 subset
  (`docs/v0-subset.md`); each higher tier is an additive replacement behind those
  seams, consistent with ADRs 0001–0011.

## WPT % is the objective SECONDARY regression meter — NOT the roadmap driver

This is stated here because it is the decision most likely to be misread later.
The WPT pass rate on each tier's named subset is the **objective regression
meter**: a mechanical, judgement-free number that answers "did this change move
conformance backward, and by how much?" and gives a comparable-over-time gauge of
how complete a tier is. It is **not** how we choose what to build next — the
**page checklist** is. We do not pick the next feature by "lowest-scoring WPT
directory." A tier is *reached* when its full page checklist (server-web floor
AND content-addressed floor) renders correctly; the WPT bar then *guards* it
against regression. The full reasoning and the exact per-tier subsets/thresholds
are in `docs/conformance-tiers.md` ("The role of WPT %").

## The tiers (summary — full checklists + bars in `docs/conformance-tiers.md`)

- **T0 — Fixed v0 subset (DONE).** Exactly `docs/v0-subset.md`: subset tokenizer +
  allowlist, real cascade on ten properties, block/inline flow, software text. No
  WPT bar (no real parser to run it against); guarded by goldens + the doc-drift
  test (`src/docs.zig`). Floor: an authored subset fragment, server-served AND via
  the content-addressed path.
- **T1 — Real static documents.** Real WHATWG parse + core CSS + HarfBuzz Latin
  shaping → correct static block/inline layout of REAL pages. Floor: real
  hand-authored article/blog pages (HTTP) AND a real `ipfs://` static site (CID).
  WPT: ≥ 90 % HTML tree-construction, ≥ 70 % core CSS static-layout areas.
- **T2 — Full static layout.** Floats/flex/grid/tables + positioning + full
  complex-script/bidi shaping → MOST static real pages. Floor: modern CSS-layout
  and table/float pages plus a complex-script page (HTTP) AND an `ipfs://` static
  site using modern layout. WPT: ≥ 85 % static-layout areas, ≥ 80 % text/bidi.
- **T3 — Interactive sites.** `ScriptEngine` (bound engine first) + networking +
  dynamic DOM → interactive real sites. Floor: a JS-driven app page and a
  form/interaction page (HTTP) AND an `ipfs://` interactive frontend (CID). WPT:
  ≥ 75 % DOM / HTML-scripting / fetch areas.

## Scope

This is an EXPLORATION deliverable: it pins the measurable target so follow-on
BUILD specs can aim at named tiers. It implements **no** tier and changes **no**
renderer code — the v0 build gate is untouched and stays green. "Done" means a
reader can, from this ADR plus `docs/conformance-tiers.md` alone, say exactly
which pages and which WPT bar define each tier.

## Cross-references

- **`docs/conformance-tiers.md`** — the checklist companion this ADR pins: the
  full per-tier page checklists and WPT-subset bars, and the WPT-role reasoning.
- **ADR-0011** (`0011-wezig-is-a-general-browser-for-a-post-trusted-server-web.md`)
  — the general-browser thesis the target is anchored on (a real general browser,
  not a dapp niche; the conformance target is a general-browser target).
- **ADR-0001** (`0001-v0-thin-subset-behind-swappable-seams.md`) — the swappable
  seams the ladder grows through; T0 is its output.
- **ADR-0005** (`0005-renderer-seam-webview-backend-while-native-catches-up.md`) —
  the `Renderer` seam the native path is routed at while it climbs the ladder.
- **`docs/v0-subset.md`** — the exact, code-backed definition of T0.
- **Spec `explore-native-renderer`** — story 1 / decision 1, the exploration this
  answers.
