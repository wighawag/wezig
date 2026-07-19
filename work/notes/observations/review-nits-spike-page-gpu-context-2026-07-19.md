---
title: review-gate non-blocking nits for 'spike-page-gpu-context' (Gate 2 approve)
date: 2026-07-19
status: open
reviewOf: spike-page-gpu-context
---

## Non-blocking review findings

The PR/code review gate (Gate 2) APPROVED 'spike-page-gpu-context' but raised the
following non-blocking findings (nits). They do not block integration; this
is their durable home for triage — promote-to-task / keep / delete.

- The gpu CI leg + module docs cite ADR-0007 as the source of the pattern that provisioned/live spike proofs get a DEDICATED CI leg off the display-free gate, but ADR-0007's text only names the webview/Xvfb shell leg — it never enumerates the harfbuzz/networking/gpu legs. The generalization is a living convention set by the prior harfbuzz/networking spikes (and is what unblocked harfbuzz), not literally in the ADR. Ratify the pattern and consider amending ADR-0007 (or a short ADR) to pin -provisioned-dep-or-live-proof gets its own leg- so future authors and reviewers are not citing an ADR that does not state it.
  (docs/adr/0007 only lists shell-* under Xvfb; ci.yml gpu/harfbuzz/networking legs + src/gpu_page_spike.zig header all cite ADR-0007 for the dedicated-leg rule.)
- The landing commit has no -## Decisions- block; the in-scope design choices (leaf=wgpu-native, Vulkan backend over the GL backend which panics headless, pin v25.0.2.2, ANGLE-style route for WebGL) are instead recorded in the findings note. That is adequate here since the note is thorough, but confirm the findings-and-build-plan task inherits the Vulkan-over-GL-backend caveat as a load-bearing constraint, not just the bare leaf name.
  (work/notes/findings/gpu-page-context-pick-wgpu-native-2026-07-19.md + the wgpu-native GL submit-panic observation note.)
