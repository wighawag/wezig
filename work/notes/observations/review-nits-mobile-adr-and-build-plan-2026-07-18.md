---
title: review-gate non-blocking nits for 'mobile-adr-and-build-plan' (Gate 2 approve)
date: 2026-07-18
status: open
reviewOf: mobile-adr-and-build-plan
---

## Non-blocking review findings

The PR/code review gate (Gate 2) APPROVED 'mobile-adr-and-build-plan' but raised the
following non-blocking findings (nits). They do not block integration; this
is their durable home for triage — promote-to-task / keep / delete.

- The findings doc header claims every citation is a verified finding under work/notes/findings/, but four inline (Decisions: ...) citations resolve to files under work/notes/observations/ instead (mobile-web3-hooks-parity-decisions, ios-renderer-backend-c-abi-ops-table-decision, mobile-chrome-surface-embed-ops-table-decision, mobile-verify-legs-decisions). The files exist and their content is sound, so this is a traceability/path inaccuracy not a dead reference: a reader following the promised findings/ path will not find them. Fix the header claim or the citation paths.
  (docs/mobile-exploration-findings.md line ~5 (a verified finding under work/notes/findings/; cited inline) vs cited files actually in work/notes/observations/. Confirmed via find: all four present under observations/.)
- Ratify the deliverable's two recorded Decisions (in the findings-doc Decisions block): (1) the findings doc lives at docs/mobile-exploration-findings.md alongside shell-exploration-findings.md rather than folded into ADR-0009, keeping ADRs short; (2) the mobile build is sliced into three follow-on specs (build-mobile-shell then build-mobile-chrome then deliver-mobile-signing-and-store) as a re-cuttable proposal, not a pinned interface. Both are self-recorded, touch no code/other task, and match the desktop precedent (ADR-0007 + shell-exploration-findings.md). No missed in-scope decision of consequence found.
  (docs/mobile-exploration-findings.md, ## Decisions recorded by this deliverable. Both flagged for ratification by the author; low-risk and reversible.)
