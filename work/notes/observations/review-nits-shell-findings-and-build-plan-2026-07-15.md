---
title: review-gate non-blocking nits for 'shell-findings-and-build-plan' (Gate 2 approve)
date: 2026-07-15
status: open
reviewOf: shell-findings-and-build-plan
---

## Non-blocking review findings

The PR/code review gate (Gate 2) APPROVED 'shell-findings-and-build-plan' but raised the
following non-blocking findings (nits). They do not block integration; this
is their durable home for triage — promote-to-task / keep / delete.

- Ratify decision: findings doc placed at docs/shell-exploration-findings.md (a reference report) rather than under docs/adr/, with only the settled decisions pointed to from ADR-0007. Reasonable per ADR-FORMAT (ADRs stay short); confirm the split is what you want.
  (Recorded in the doc's ## Decisions block and mirrored by ADR-0007; ADR-FORMAT norm that an ADR can be one paragraph.)
- Ratify decision: the N-concurrent-PageContext content model is delivered as a DESIGN (PageContext shape + per-context seam methods), not built, and is labelled a proposal the build spec may revise, not a pinned interface. This is an in-scope choice about how far story 7 goes; confirm design-only is acceptable (the spec Out-of-Scope forbids building presentation here).
  (Doc section 3 + ## Decisions; ADR-0007 records it as a design, not a re-pin of ADR-0006.)
- PageContext is a new load-bearing term the build spec will inherit. Consider pinning it in CONTEXT.md glossary so a later author cannot re-fork or re-mean it. Non-blocking since the doc scopes it clearly as a proposal.
  (Lens 4 coherence: term is introduced consistently and at the right layer, but only lives in the findings doc/ADR-0007 today.)
