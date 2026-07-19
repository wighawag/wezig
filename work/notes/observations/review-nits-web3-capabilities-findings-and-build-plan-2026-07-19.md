---
title: review-gate non-blocking nits for 'web3-capabilities-findings-and-build-plan' (Gate 2 approve)
date: 2026-07-19
status: open
reviewOf: web3-capabilities-findings-and-build-plan
---

## Non-blocking review findings

The PR/code review gate (Gate 2) APPROVED 'web3-capabilities-findings-and-build-plan' but raised the
following non-blocking findings (nits). They do not block integration; this
is their durable home for triage — promote-to-task / keep / delete.

- Ratify: the findings doc lives at docs/web3-capabilities-exploration-findings.md (not docs/adr/). Sound — mirrors the sibling native-renderer/shell findings docs; docs.zig guards only v0-subset.md so the v0 gate stays green.
  (Decisions block entry 1; verified src/docs.zig doc_path = docs/v0-subset.md only.)
- Ratify: NO new companion ADR is authored (unlike native-renderer which added ADR-0014). Sound — ADR-0015 + ADR-0016 already pin the outcome, so an ADR-0017 pointing here would duplicate ADR-0015. Leaves 0017 free.
  (Decisions block entry 2; ADR-0015 Consequences already record build inputs.)
- Ratify: the web3 build is sliced into W0-W3 + I0-I2 + two separate explorations rather than one spec. A proposal the follow-on author may re-cut; touches plan shape only.
  (Decisions block entry 3; §6.)
- Minor: the task Prompt names the old spike slug spike-ipfs-secure-origin-service-worker while frontmatter/doc use spike-ipfs-fetch-verify-and-secure-origin-seam. The doc handles the re-scope correctly (§3 + ADR-0016), so this is not doc-introduced drift — noted for the human's awareness only.
  (task Prompt vs blockedBy; git history shows the ipfs spike was re-scoped.)
