---
title: review-gate non-blocking nits for 'evaluate-custody-and-extension-compat' (Gate 2 approve)
date: 2026-07-19
status: open
reviewOf: evaluate-custody-and-extension-compat
---

## Non-blocking review findings

The PR/code review gate (Gate 2) APPROVED 'evaluate-custody-and-extension-compat' but raised the
following non-blocking findings (nits). They do not block integration; this
is their durable home for triage — promote-to-task / keep / delete.

- Ratify: the doc recommends a concrete custody PROBE ORDER (hardware then keychain then encrypted-at-rest) and pins keychain as the software default, which ADR-0015 d.3 lists as tiers but does not order. Reasonable (follows from the threat analysis: least owned-crypto is default), recorded in Decisions #3, and left EXACT primitive/UX to the build spec. Confirm this ordering is acceptable as a recommendation.
  (finding doc section 1 + Decisions #3; ADR-0015 d.3 fixes tiers + least-crypto-we-own but not selection order.)
- Ratify: the doc coins the descriptive label non-interactive predicate (section 3.4) for the broker's automate-vs-prompt decision. Flagged by the agent as a DESCRIPTION not a new gate/flag/status, built only from ADR-0015 d.4 (signing split, origin-bound) + thesis classes, so it does not enter the glossary. Confirm the label is fine or should be dropped.
  (finding doc section 3.4 + Decisions #2.)
- Minor convention: this finding adds status: open and kind: finding frontmatter that sibling work/notes/findings/*.md files do not carry. Harmless/additive, not load-bearing; noting for consistency only.
  (frontmatter of the new doc vs other findings in work/notes/findings/.)
