---
title: review-gate non-blocking nits for 'document-v0-subset-limits' (Gate 2 approve)
date: 2026-07-14
status: open
reviewOf: document-v0-subset-limits
---

## Non-blocking review findings

The PR/code review gate (Gate 2) APPROVED 'document-v0-subset-limits' but raised the
following non-blocking findings (nits). They do not block integration; this
is their durable home for triage — promote-to-task / keep / delete.

- In-scope decision to ratify: the agent added a NEW doc-drift test guard (src/docs.zig, wired into root.zig and the root test block) that asserts docs/v0-subset.md names every allowlisted element, supported CSS property, diagnostic code, and default-block element. The task asked only for the doc; this test-guard is an unrequested (but sound) addition that couples future allowlist/property/code growth to a doc update. Ratify keeping it.
  (src/docs.zig is new; it is a NAME-PRESENCE guard only (not a prose validator). It reduces future drift risk. No commit carried a ## Decisions block, so this was surfaced by the reviewer.)
- The box-colours limit prose says threading colours through is scoped as a v0.1 follow-up. Confirm a follow-up task/note actually exists so this is a named non-delivery, not a silent gap.
  (work/notes/observations/box-colours-not-cascaded-end-to-end-2026-07-14.md records the ratified ACCEPT and a Suggested follow-up (v0.1); the deferral is flagged, not silently missing.)
