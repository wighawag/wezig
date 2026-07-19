---
title: Rust + Zig renderers behind the seam — differential bake-off (Ethereum multi-client analogy); under LLM authorship, permanent-both is genuinely live, gated on the oracle problem + whether verifiable rendering is a product
slug: rust-zig-renderer-differential-bakeoff-ethereum-multiclient-analogy
---

A pre-spec design idea for de-risking the `WezigRenderer` language question by
building it in BOTH Rust and Zig behind the `Renderer` seam — and the honest cost
analysis of the Ethereum-multi-client analogy that motivates it. Discussed
2026-07-19 as a follow-on to ADR-0017 (the Zig language decision). This is an IDEA
(pre-spec): it changes no code; it records what transfers from the multi-client
model and what does not, so the option is neither "obviously do it" nor "obviously
don't" when `WezigRenderer` is specced.

## The idea

Ethereum runs MULTIPLE independent client implementations (Geth/Nethermind/Besu/
Erigon/Reth) and treats that diversity as a strength. Could wezig write
`WezigRenderer` in BOTH Rust and Zig (both behind the pinned `Renderer` seam,
ADR-0005/0006) and get the same benefit — cross-implementation bug-finding + a
real language bake-off?

## What TRANSFERS from the Ethereum model (the genuinely good part)

- **wezig already has the shared conformance spec.** Ethereum's multi-client model
  works because every client is judged byte-for-byte against the SAME test vectors
  (execution-spec tests, hive, state tests). wezig's equivalent already exists:
  ADR-0012's tiered conformance ladder (page checklists) + the WPT subset bar. Two
  renderers judged against the SAME WPT subset + the SAME fixtures is exactly the
  precondition that makes multi-client coherent rather than chaotic. This is why
  the analogy is not silly.
- **Differential testing is real, powerful bug-finding.** Two renderers rendering
  the same page and DIFFING the output surfaces bugs: any divergence is a bug in at
  least one. This is a proven browser technique. A Rust renderer and a Zig renderer
  cross-checking each other would genuinely harden both, AND yield honest bake-off
  data (memory-safety bugs found in each, C-binding friction, LLM-authorship
  velocity, WPT pass rate) — settling the Zig-vs-Rust-for-the-engine question by
  MEASUREMENT instead of argument (the project's prove-and-record ethos, and the
  independent-checker discipline ADR-0017 requires under LLM authorship).

## What does NOT transfer (the gaps — and which ones LLM-authorship ERASES)

> **UPDATE (2026-07-19): the LLM-authorship premise weakens TWO of the three
> objections below.** The original "why not permanent multi-client" case leaned on
> HUMAN labor economics (one author, climbing the ladder twice forever). If LLMs
> write and maintain most of the code, the COST of a second implementation drops
> toward the cost of the compute + the review discipline, not a second human team
> — so "two implementations against the same test suite" is no longer far-fetched.
> Below, each objection is marked for whether it SURVIVES that premise.

- **[SURVIVES — the real objection] Ethereum clients must agree byte-for-byte;
  browsers must not.** The EVM is deterministic — one correct answer, so a client
  diff is conclusive ("this client is wrong"). Rendering is a huge, fuzzy,
  quirk-laden target where even the incumbents disagree constantly and "correct" is
  often "what the web expects", not a clean spec. Two renderers WILL diverge on
  thousands of edge cases with NO oracle to say which is right — so a diff says
  "these differ", not "which is the bug". This objection is INDEPENDENT of who
  writes the code: even with infinite cheap LLM labor, a divergence still needs a
  human/oracle to adjudicate, and the web has no canonical oracle the way the EVM
  does. This is the gap that genuinely limits the value of the differential — NOT
  the cost. (Mitigation: anchor the diff to the shared WPT vectors + incumbent
  behaviour as the partial oracle, so a diff on a WPT-covered case IS conclusive;
  only the uncovered long tail stays ambiguous.)
- **[WEAKENED by LLM-authorship] "one author, forever" cost.** The original
  objection — maintaining two full renderers means climbing the decade-scale
  conformance ladder TWICE with one author's labor — assumed HUMAN maintenance. If
  LLMs author + maintain both against the SAME test suite, the marginal cost of the
  second engine is compute + the independent-review discipline (ADR-0017), not a
  second team. Ethereum needs a $B ecosystem to fund N human teams; wezig may need
  a bigger CI budget. So this objection largely DISSOLVES under the LLM premise —
  which is precisely why the idea resurfaced and is worth taking seriously.
- **[PARTLY SURVIVES] the resilience payoff still does not accrue to a browser
  — UNLESS verifiable rendering is the product.** On a blockchain, client diversity
  protects the NETWORK from any one client's consensus bug (the redundancy IS the
  product). In a browser, two renderers protect nothing EXTERNAL by default — a
  renderer bug mis-renders a page, it does not fork a chain. So absent a product
  framing, "two renderers" is DIFFERENTIAL TESTING (a QA technique), whose value is
  real but does not by itself REQUIRE permanence. BUT this is the objection the
  "verifiable rendering" framing (below) directly converts into a YES — and cheap
  LLM authorship is what makes that framing affordable enough to consider. So under
  the LLM premise this stops being a hard "no" and becomes "only if the product
  wants it".

## The synthesis (updated for LLM-authorship: converge is a CHOICE, not a forced default)

The original synthesis was "differential PHASE, then converge to one" — on the
reasoning that permanent-both costs a single author too much. **Under the
LLM-authorship premise that cost objection largely dissolves, so BOTH endgames are
now live** and the decision turns on the two objections that SURVIVE (the oracle
problem + whether resilience is a product goal), not on labor cost:

**Phase 1 (do this regardless of endgame): the differential bake-off.**
1. Build the Rust and Zig renderers in parallel up to a SHARED TIER (ADR-0012
   T1/T2), both behind the seam, both judged by the SAME WPT subset + page
   checklists.
2. Run them DIFFERENTIALLY (same page → diff output), anchored to the WPT vectors +
   incumbent behaviour as the PARTIAL ORACLE so a diff on a covered case is
   conclusive. Harvest: bugs found in each, memory-safety defects (the key
   Zig-vs-Rust datum), C-binding friction, LLM-authorship velocity, WPT pass rate.
3. Guard fairness: same LLM/harness, same tests, same tier; account for Zig's
   pre-1.0 training-data disadvantage (ADR-0017) so the bake-off measures LANGUAGES.

**Phase 2 (the fork — now a genuine choice, decided from Phase-1 data):**
- **Converge to one** if the differential's marginal bug-finding drops off past the
   shared tier AND verifiable-rendering is not a product goal (the loser's harness
   can stay as a cheap oracle). This was the old default; it is still valid, just no
   longer FORCED by cost.
- **Keep both permanently** if EITHER (a) the differential keeps finding real,
   distinct bugs cheaply under LLM maintenance (the QA value compounds and the cost
   is compute, not a second team), OR (b) verifiable rendering is adopted as a
   product promise (below) — in which case two engines are the DESIGN, not a QA
   phase.

**What decides it is NOT cost anymore — it is the two surviving objections:** the
ORACLE problem (a diff on the uncovered long tail is ambiguous; how much of the tail
does WPT + incumbent-diffing actually cover?) and whether wezig wants
renderer-diversity as a TRUST FEATURE (product) vs just a bug-finder (QA). Decide
Phase 2 from Phase-1 evidence on exactly those two axes.

**The load-bearing caveat under LLM authorship (from ADR-0017):** cheap LLM labor
makes two implementations affordable, but it does NOT supply the independent SAFETY
oracle — if the SAME model authors both engines, their memory-safety blind spots may
CORRELATE, so the differential catches BEHAVIOURAL divergence but not necessarily a
shared latent memory bug. So even two-engine diversity still needs the ADR-0017
discipline (independent adversarial review + fuzzing + isolation); it does not
replace it. (Using DIFFERENT models, or Rust's compiler as one engine's independent
checker, partially de-correlates the blind spots — a point in favour of making one
of the two engines the Rust one.)

## The framing under which PERMANENT multi-client is the DESIGN (on-thesis)

If wezig elevates **"verifiable rendering"** to a PRODUCT PROMISE — "two
independent engines must agree, or the page is flagged as untrusted" — then the
differential BECOMES the product (as it is for Ethereum), and permanence is
DESIGN, not QA. Under HUMAN authorship this was a stretch (who maintains two
engines forever?); under LLM authorship the maintenance cost objection largely
dissolves, so this framing moves from "far-fetched" to "a real product option". It
is strongly on-thesis for a don't-trust-by-default browser (ADR-0011): renderer
diversity as a TRUST feature — the rendering analogue of content-addressing (you
don't trust ONE engine's interpretation any more than you trust ONE server). The
remaining hard question is the ORACLE problem: "they disagree" flags a page, but on
the fuzzy web two CORRECT engines also disagree on the long tail, so a naive
"must agree" would false-positive constantly — the promise likely has to be scoped
(agree on a SECURITY-relevant projection: layout of trust-indicators, origin of
subresources, not pixel-exact rendering). That scoping is the open design work if
this framing is pursued.

## Scope / status

- IDEA, pre-spec. It adds an OPTION + its (LLM-updated) cost analysis to the
  `WezigRenderer` language decision (deferred + seam-gated per ADR-0017); it
  changes no code and commits to nothing. When `WezigRenderer` is specced, run the
  Phase-1 differential bake-off, then decide Phase 2 from the DATA on the two axes
  cost no longer dominates: the ORACLE coverage (does WPT + incumbent-diffing make
  enough of the tail conclusive?) and whether verifiable rendering is a product
  goal. Under LLM authorship all three endgames are live — single-engine,
  converge-after-bake-off, or permanent-both-by-design — and the choice is
  evidence-driven, not forced by maintenance cost.
- Related: ADR-0017 (Zig decision + escape hatch + LLM-authorship safety posture),
  ADR-0012 (the conformance ladder = the shared test vectors), ADR-0005/0006 (the
  seam that makes N backends first-class),
  `work/notes/ideas/memory-safety-posture-sandbox-and-fuzz-attacker-facing-components.md`.
