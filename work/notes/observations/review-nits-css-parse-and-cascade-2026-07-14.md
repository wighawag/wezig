---
title: review-gate non-blocking nits for 'css-parse-and-cascade' (Gate 2 approve)
date: 2026-07-14
status: open
reviewOf: css-parse-and-cascade
---

## Non-blocking review findings

The PR/code review gate (Gate 2) APPROVED 'css-parse-and-cascade' but raised the
following non-blocking findings (nits). They do not block integration; this
is their durable home for triage — promote-to-task / keep / delete.

- Ratify: a malformed declaration with no colon is SILENTLY skipped with no diagnostic, while unknown-property and !important emit codes. Intended v0 policy, or should malformed decls emit a code too?
  (src/css.zig parseOneDeclaration: `const colon = indexOfScalar(text, ':') orelse return;` (silent). Unspecified by the task.)
- Ratify: within a grouped selector list (a, b), an unsupported member is dropped individually and the rule KEEPS its supported members; the task said unsupported selector skips the rule. Per-member survival is a refinement worth confirming.
  (src/css.zig parseSelectorList drops only bad group members; only an all-unsupported rule is skipped. Test covers full-rule skip, not partial-group.)
- Ratify the exact initial values chosen (color=black, background-color=transparent, font-family=serif, font-size=16px, font-weight=normal, width/height=auto, margin/padding=0). User-visible defaults the limits doc will publish; not pinned by the task.
  (src/css.zig Property.initialValue; recorded in the module header + css-cascade-decisions note.)
- Ratify the cross-task boundary: values are carried as RAW trimmed strings and unit/% interpretation plus the unsupported_unit diagnostic are DEFERRED to layout-block-inline. This shapes what layout and document-v0-subset-limits consume.
  (Recorded in work/notes/observations/css-cascade-decisions-2026-07-14.md and the css.zig header; unsupported_unit code exists but is emitted nowhere yet.)
- Convention gap (same nit as html-parse-subset): in-scope decisions live in the src/css.zig doc-comment header and an observations note (reviewOf: css-parse-and-cascade), not a PR ## Decisions block nor appended to the done-record body. Discoverable but note for future auditing.
  (work/tasks/done/css-parse-and-cascade.md body is the original template; link is via the note frontmatter, not the done record itself.)
