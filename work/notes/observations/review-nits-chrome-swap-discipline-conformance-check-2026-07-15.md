---
title: review-gate non-blocking nits for 'chrome-swap-discipline-conformance-check' (Gate 2 approve)
date: 2026-07-15
status: open
reviewOf: chrome-swap-discipline-conformance-check
---

## Non-blocking review findings

The PR/code review gate (Gate 2) APPROVED 'chrome-swap-discipline-conformance-check' but raised the
following non-blocking findings (nits). They do not block integration; this
is their durable home for triage — promote-to-task / keep / delete.

- Ratify: the agent chose to STRIP Zig line comments before scanning, so the real chrome (whose doc-comments name webkit/gtk in prose) passes while code mentions fail. Sound and well-documented in the module header, but not specified by the task. Confirm this is the intended discipline (prose may discuss the boundary; only code is forbidden).
  (src/chrome_conformance.zig stripLineComments + the header 'Why we strip comments before scanning'. Without it the guard would fail the current seam-respecting chrome, since chrome.zig lines 5-7,21,129 mention the tokens in comments.)
- Ratify: the guard is a case-insensitive whole-token substring scan (webkit/gtk) over a single hardcoded path src/chrome.zig, not an AST/import parse, and only that one file. If chrome ever splits into multiple files the guard will not follow them, and a literal string 'gtk' in chrome code would trip it. Documented as a deliberate tradeoff mirroring docs.zig; confirm the single-file scope is acceptable.
  (chrome_path = 'src/chrome.zig'; forbidden_tokens = {webkit, gtk}; module header notes chrome is 'the ONE file the discipline governs' and accepts the false-positive-over-false-negative tradeoff.)
- The PR/commit carried no '## Decisions' block; the two in-scope design choices above were recorded only in the module doc-comment. Prefer a Decisions block in future so ratification is explicit.
  (git show -s e4a3d3c body is a single title line, no Decisions section.)
