---
title: review-gate non-blocking nits for 'fix-fontsize-unsupported-unit' (Gate 2 approve)
date: 2026-07-14
status: open
reviewOf: fix-fontsize-unsupported-unit
---

## Non-blocking review findings

The PR/code review gate (Gate 2) APPROVED 'fix-fontsize-unsupported-unit' but raised the
following non-blocking findings (nits). They do not block integration; this
is their durable home for triage — promote-to-task / keep / delete.

- The emitted diagnostic message on the font-size unsupported path reads 'only px and % supported in v0', but for font-size '%' is itself unsupported (it falls back to 16px). Intentional string-parity with parseLength or slightly misleading for font-size?
  (src/layout.zig parseFontSize both emit sites reuse parseLength's verbatim message; the task asked for same shape/severity as parseLength, so this is a deliberate consistency choice, not a defect.)
- fontOf/fontOfContext signatures became error-returning (!Font) with try propagated through layoutInline and LineLayout.addNode. This in-scope signature change was not recorded in a Decisions block; ratify as a mechanical consequence of threading a fallible sink.
  (Necessary because diag.add can fail (OOM); all 4 call sites updated consistently, fully local, low risk.)
