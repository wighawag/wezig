---
title: Spike the page-facing GPU path (one canvas, one WebGPU frame) + assess WebGL first-class route
slug: spike-page-gpu-context
spec: explore-native-renderer
needsAnswers: true
blockedBy: []
covers: [3, 6]
---

<!-- open-questions -->

## Open questions

1. **What is the ACCEPTANCE bar for the WebGL "first-class, 100% conformance +
   performant" claim within an EXPLORATION spike?** The spec (decision 2, story 3)
   demands the spike "prove WebGL can hit full conformance + perf, not hand-wave
   'it falls out'" — but a narrowest-case one-canvas-one-frame spike CANNOT
   *prove* 100% WPT/khronos-conformance or performance parity; that is a
   multi-year build claim. Is the intended deliverable here (a) a one-WebGL-frame
   spike PLUS a written, evidence-grounded ASSESSMENT that the ANGLE-style
   GL→native-GPU translation route is viable for full conformance + perf (citing
   how Chrome/ANGLE does it), i.e. confidence not proof — or (b) something
   stronger? Confirm the bar so this task promises what a spike can actually
   deliver rather than an impossible "100% proven" acceptance criterion.
2. **Which GPU binding is the spike's leaf — Dawn or `wgpu-native`?** ADR-0004
   leans "Dawn/`wgpu-native`" without picking one. Does this spike pick one (and
   record why) as part of its output, or is the pick itself deferred to the
   findings task with the spike run against whichever is faster to stand up?

<!-- /open-questions -->

## What to build

Spike the PAGE-FACING GPU capability on the native path (decision 2 promoted GPU
from defer to spike). The target is a PAGE's `<canvas>` getting a working GPU
context that draws ONE frame — one canvas, one frame, one shader — via
Dawn/`wgpu-native` (the direction ADR-0004 leans toward), NOT merely internal
layer compositing. WebGPU is the primary native target; the WebGL path must be
assessed as first-class (see open question 1). This de-risks the NATIVE
`WezigRenderer` GPU path — noting the system-webview backend already ships
working WebGL/WebGPU TODAY (so page-GPU content runs in wezig now via the
webview; this spike is about the native path).

- Stand up a GPU context via Dawn or `wgpu-native` behind the windowing/paint
  seam and draw ONE frame from ONE shader into a surface a page `<canvas>` would
  present.
- Produce a written, evidence-grounded assessment of the WebGL first-class route
  (ANGLE-style GL→native translation, as Chrome does) — scope pinned by the
  answer to open question 1.
- Record the concrete Dawn-vs-`wgpu-native` pick (or defer per open question 2).

## Acceptance criteria

- [ ] A GPU context via Dawn/`wgpu-native` draws ONE frame from ONE shader into
      a page-`<canvas>`-facing surface on the native path (not just internal
      compositing), verified by a test/golden.
- [ ] The WebGL first-class route is assessed per the resolved bar (open
      question 1), grounded in how the ANGLE-style GL→native path is known to work.
- [ ] The findings note records the Dawn-vs-`wgpu-native` disposition and that the
      webview backend already runs page-GPU content today (the native path is what
      this de-risks).
- [ ] Tests cover the one-frame path per the repo's golden/test style; the v0
      build gate stays green and the display/GPU leg stays out of the display-free
      gate.

## Blocked by

- None — can start immediately (once the open questions are resolved).

## Prompt

> Goal: spike the PAGE-FACING GPU path on the native renderer — one `<canvas>`,
> one WebGPU frame, one shader — via Dawn/`wgpu-native`, plus an assessment of the
> WebGL first-class route (spec `explore-native-renderer`, story 3, decision 2).
> RESOLVE THE OPEN QUESTIONS FIRST (the WebGL acceptance bar and the
> Dawn-vs-`wgpu-native` leaf) — do not guess a "100% conformance proven"
> criterion a spike cannot deliver.
>
> WebGPU is the primary native target; WebGL is a hard requirement to be proven
> first-class via an ANGLE-style GL→native-GPU translation (as Chrome does), not
> hand-waved as "it falls out." The spike targets the PAGE-facing capability (a
> page canvas gets a working GPU context and draws one frame), NOT internal layer
> compositing. Note the two-backends reality (ADR-0005): the system-webview
> backend already ships working WebGL/WebGPU today, so page-GPU content runs in
> wezig now via the webview — this spike de-risks the NATIVE `WezigRenderer` GPU
> path only.
>
> Where to look: ADR-0004 (windowing SDL-as-v0-leaf, native/`mach`+Dawn/`wgpu-native`
> as target), ADR-0002/0003 (`PaintBackend` seam + offscreen `Surface`),
> `src/sdl.zig`/`src/paint.zig`. This is exploration on the NARROWEST case
> (story 6): one canvas, one frame, one shader; assess-and-record for WebGL; do
> NOT build a Canvas/WebGL/WebGPU implementation. "Done" = one native GPU frame
> reaches a page-canvas-facing surface, the WebGL route is assessed to the
> resolved bar, the library disposition is recorded, and the v0 gate stays green.
