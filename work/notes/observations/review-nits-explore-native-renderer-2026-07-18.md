---
title: review-gate non-blocking nits for 'explore-native-renderer' (Gate 2 approve)
date: 2026-07-18
status: open
reviewOf: explore-native-renderer
---

## Non-blocking review findings

The PR/code review gate (Gate 2) APPROVED 'explore-native-renderer' but raised the
following non-blocking findings (nits). They do not block integration; this
is their durable home for triage — promote-to-task / keep / delete.

- spike-page-gpu-context carries needsAnswers:true over the story-3 phrase 'WebGL proven first-class — 100% + performant'. The task honestly flags that a one-frame spike cannot PROVE 100% conformance and asks whether the deliverable is a frame-spike + evidence-grounded assessment (confidence) vs impossible proof. This is the correct disposition (surface, do not guess), so it is not a set-level block; the caller should route that one task to needs-answers before it is claimed.
  (spec line 53 says '100% + performant' but the spec is exploration-scoped and story 6 pins the narrowest case; the task's open-question 1 reconciles this correctly.)
- Both spike-harfbuzz-shaping and spike-networking-fetch-verify carry covers:[2] (decision 2 has two legs) and both also carry covers:[6]. This overlap is intentional and non-conflicting — they touch disjoint code (paint/text vs a networking module) with no shared seam — so no serialising blockedBy is needed.
  (lens 3 composition: no two tasks fight the same file/command.)
