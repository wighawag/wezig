---
title: review-gate non-blocking nits for 'spike-native-stub-and-user-swap' (Gate 2 approve)
date: 2026-07-19
status: open
reviewOf: spike-native-stub-and-user-swap
---

## Non-blocking review findings

The PR/code review gate (Gate 2) APPROVED 'spike-native-stub-and-user-swap' but raised the
following non-blocking findings (nits). They do not block integration; this
is their durable home for triage — promote-to-task / keep / delete.

- RATIFY: the manual swap is modelled as a RendererSwap coordinator BESIDE the chrome, NOT wired into any shell. The task's AC#2 and Prompt ask for the trigger wired in ONE shell (chrome.zig/mobile_chrome.zig hold the single Renderer value; long-press-reload gesture; visible indicator). The diff touches NO chrome/shell file — RendererSwap+WezigRenderer are proven only against FakeRenderer headlessly, engineLabel() exists but is never displayed, and no long-press gesture is wired. The agent recorded this as a deliberate decision (avoid widening the pinned ChromeIntent seam for a spike, per ADR-0006). Non-blocking: the swap MECHANISM (re-point/re-attach/re-navigate + allow model + indicator vocabulary) is genuinely proven at the seam and the decision is well-reasoned and reversible; but a human should ratify that a beside-the-chrome coordinator (no actual shell wiring, indicator only as an unshown label) satisfies the task's in-one-shell + visible-indicator intent for this narrowest-case spike.
  (chrome.zig/mobile_chrome.zig never reference RendererSwap/WezigRenderer; renderer_swap.zig module doc DECISION block; task AC#2 + Prompt say 'in ONE shell' with long-press gesture + visible indicator.)
- RATIFY (process): the PR/commit description is a bare one-liner with NO '## Decisions' block. The one load-bearing in-scope decision (coordinator beside the chrome vs a new swap_engine ChromeIntent variant) is recorded ONLY in the renderer_swap.zig module doc-comment. It is well-argued (ADR-0006: do not grow a pinned seam speculatively for a spike), so this is a surfacing nit, not a defect — but the decision belongs in the PR description so a human ratifies it without reading source.
  (git log body for e5a53cf is a single feat(...) line; DECISION lives in src/renderer_swap.zig module doc.)
