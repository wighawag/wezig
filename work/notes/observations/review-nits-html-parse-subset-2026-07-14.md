---
title: review-gate non-blocking nits for 'html-parse-subset' (Gate 2 approve)
date: 2026-07-14
status: open
reviewOf: html-parse-subset
---

## Non-blocking review findings

The PR/code review gate (Gate 2) APPROVED 'html-parse-subset' but raised the
following non-blocking findings (nits). They do not block integration; this
is their durable home for triage — promote-to-task / keep / delete.

- Ratify: a non-allowlisted element is skipped but its ALLOWLISTED descendants survive and re-parent to the skipped element's parent (e.g. span inside marquee attaches to body). Non-obvious re-parenting choice; is this the intended v0 behaviour vs dropping the whole subtree?
  (src/html.zig handleStartTag skip-marker + test 'non-allowlisted element ... its allowed children survive')
- Ratify: non-allowlisted ATTRIBUTES are silently dropped with NO diagnostic code, while non-allowlisted ELEMENTS emit non_allowlisted_element. Asymmetric user-visible policy (header notes a later task may add a code).
  (src/html.zig filterAttrs + module header allowlist section)
- Ratify: non_allowlisted_element is emitted at severity .warning (skip-and-continue). Task did not specify severity; diagnostics module leaves severity per-call.
  (src/html.zig handleStartTag diag.add(.warning, .non_allowlisted_element, ...))
- Decisions were recorded in the html.zig module doc-comment header, not in a PR '## Decisions' block or the done record body. Recorded durably and discoverable, but note the convention gap for future auditing.
  (work/tasks/done/html-parse-subset.md has no Decisions block; decisions live in src/html.zig header)
