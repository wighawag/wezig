---
title: review-gate non-blocking nits for 'layout-block-inline' (Gate 2 approve)
date: 2026-07-14
status: open
reviewOf: layout-block-inline
---

## Non-blocking review findings

The PR/code review gate (Gate 2) APPROVED 'layout-block-inline' but raised the
following non-blocking findings (nits). They do not block integration; this
is their durable home for triage — promote-to-task / keep / delete.

- parseFontSize silently falls back to 16px for non-px font-size units (e.g. font-size:2em) WITHOUT emitting unsupported_unit, while parseLength emits it for width/height/margin/padding. This contradicts the acceptance criterion (unsupported units emit unsupported_unit) and layout.zig header line 19 which claims all non-px/% units emit the diagnostic. Should an em/rem/vw font-size also emit unsupported_unit for consistency?
  (src/layout.zig:448 parseFontSize returns 16 with no diag.add; contrast parseLength at :347)
- Ratify in-scope decision: measureRun is REQUIRED (non-optional fn ptr) while all drawing methods are optional (nullable, null on stub). This is a load-bearing interface shape the next paint task and future Skia/HarfBuzz backend inherit. Recorded in ADR-0002; ratify the required-vs-optional split.
  (src/layout.zig PaintBackend.VTable; ADR-0002. Matches ADR-0001 pinned method set.)
- Ratify in-scope decision: a bare unitless number (e.g. width:100) is treated as px rather than emitting unsupported_unit or being rejected. Documented in parseLength but not named in the task.
  (src/layout.zig:344 'bare number: treat as px in v0')
- No PR Decisions block was recorded (commit body is empty). The interface-shape, %-width-against-containing-block, and baseline handling decisions the task asked to record durably were captured in ADR-0002 instead, which satisfies the intent; noting the missing PR-description block for completeness.
  (git show c9c88b3 body empty; docs/adr/0002 present)
