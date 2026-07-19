---
title: Rust + Zig renderers as a differential-testing bake-off (Ethereum multi-client analogy) — converge to one, unless "verifiable rendering" becomes a product promise
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

## What does NOT transfer (the decisive gaps — why NOT permanent multi-client)

- **Ethereum clients must agree byte-for-byte; browsers must not.** The EVM is
  deterministic — one correct answer, so a client diff is conclusive ("this client
  is wrong"). Rendering is a huge, fuzzy, quirk-laden target where even the
  incumbents disagree constantly and "correct" is often "what the web expects", not
  a clean spec. Two renderers WILL diverge on thousands of edge cases with NO
  oracle to say which is right — so a diff says "these differ", not "which is the
  bug". The differential is noisier and far less conclusive than Ethereum's.
- **Ethereum's multi-client is funded by a $B ecosystem; wezig is one author.**
  Each Ethereum client has a TEAM. Maintaining two full renderers means the single
  author (+ LLMs) climbing the decade-scale conformance ladder TWICE, forever.
- **The resilience payoff does not accrue to a browser.** On a blockchain, client
  diversity protects the NETWORK from any one client's consensus bug (a bug is
  contained because the others disagree and the majority is right — the redundancy
  IS the product). In a browser, two renderers protect nothing external — a
  renderer bug mis-renders a page, it does not fork a chain. So for wezig, "two
  renderers" is NOT client diversity (a resilience property) — it is DIFFERENTIAL
  TESTING (a QA technique). And a QA technique does not need two PRODUCTION engines
  maintained forever; it needs two engines DURING the cross-checking period.

## The synthesis (keep the good part, drop the trap)

Use the two implementations as a **differential-testing + language-bake-off PHASE,
not a permanent multi-client commitment**:

1. Build the Rust and Zig renderers in parallel UP TO A SHARED TIER (e.g. ADR-0012
   T1/T2), both behind the seam, both judged by the SAME WPT subset + page
   checklists.
2. Run them DIFFERENTIALLY against each other during that phase (same page → diff
   output) — Ethereum-style bug-finding + the honest bake-off data at once.
3. **CONVERGE TO ONE for the long-haul conformance climb** (T3→T4 twice has no
   payoff for a single author). Optionally keep the loser's harness as a cheap test
   ORACLE, but do not grow both to full browsers.

Pre-commit the decision criteria + the convergence point BEFORE starting (which
metrics decide, at which tier), so "keep both to be safe" cannot silently become
permanent 2× maintenance. Guard fairness: same author/LLM, same test suite, same
tier, and account for Zig's pre-1.0 training-data disadvantage (ADR-0017) so the
bake-off measures LANGUAGES, not stale training data.

## The one framing under which PERMANENT multi-client WOULD be right (on-thesis)

If wezig ever elevates **"verifiable rendering"** to a PRODUCT PROMISE — "two
independent engines must agree, or the page is flagged as untrusted" — then the
differential BECOMES the product (as it is for Ethereum), and permanence is
justified. That is a stretch today, but it is interestingly on-thesis for a
don't-trust-by-default browser (ADR-0011): renderer diversity as a TRUST feature,
the rendering analogue of content-addressing. Recorded as the sole condition that
would flip "converge to one" into "maintain both by design".

## Scope / status

- IDEA, pre-spec. It adds an OPTION + its cost analysis to the `WezigRenderer`
  language decision (deferred + seam-gated per ADR-0017); it changes no code and
  commits to nothing. When `WezigRenderer` is specced, decide: single-language, or
  a pre-scoped Rust-vs-Zig differential bake-off that converges to one — unless the
  "verifiable rendering" product promise is adopted, in which case permanent
  two-engine diversity is the design.
- Related: ADR-0017 (Zig decision + escape hatch + LLM-authorship safety posture),
  ADR-0012 (the conformance ladder = the shared test vectors), ADR-0005/0006 (the
  seam that makes N backends first-class),
  `work/notes/ideas/memory-safety-posture-sandbox-and-fuzz-attacker-facing-components.md`.
