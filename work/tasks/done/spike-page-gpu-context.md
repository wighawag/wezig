---
title: Spike the page-facing GPU path (one canvas, one WebGPU frame) + assess WebGL first-class route
slug: spike-page-gpu-context
spec: explore-native-renderer
blockedBy: []
covers: [3, 6]
---

## Resolved decisions (the two open questions, answered by the human)

1. **The WebGL bar is ASSESSMENT (confidence), NOT in-spike proof — option (a).**
   The spike CANNOT and MUST NOT claim to "prove WebGL 100% conformant +
   performant" (that is a multi-year build claim). The deliverable is: **(i) one
   working WebGL frame** on the native path (alongside the WebGPU frame), **plus
   (ii) a written, evidence-grounded ASSESSMENT** that the ANGLE-style
   GL→native-GPU translation route is viable for reaching full WebGL conformance
   + performance — grounded in how Chrome/ANGLE actually does it (cite the
   approach), naming the known risks/costs. "First-class, 100% + performant" is
   the BUILD-time TARGET the assessment argues is reachable via this route; the
   spike delivers a proven one-frame path + a credible confidence judgment, not
   an impossible proof. The findings-and-build-plan task inherits this assessment
   to scope the real WebGL build.
2. **The spike PICKS one GPU leaf and records why; the pick is not deferred.**
   Run the spike against whichever of **Dawn** or **`wgpu-native`** is faster to
   stand up in Zig for a one-frame WebGPU path, and RECORD the concrete pick +
   the reasoning (build ergonomics in Zig, cross-compile story, WebGPU API
   currency, maintenance) as part of the output. This is a spike-informed
   recommendation, not a final pin — the findings task may ratify or revisit it,
   but the spike must not leave the leaf unchosen (choosing it IS part of
   de-risking). If the two are genuinely equivalent for the one-frame case, pick
   the one with the simpler Zig binding and say so.

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

- [ ] A GPU context via the CHOSEN leaf (Dawn or `wgpu-native`, per resolved
      decision 2) draws ONE **WebGPU** frame from one shader into a
      page-`<canvas>`-facing surface on the native path (not just internal
      compositing), verified by a test/golden. A ONE **WebGL** frame is also
      drawn on the native path (the WebGL leg of resolved decision 1(a)).
- [ ] The WebGL first-class route is ASSESSED per resolved decision 1(a) — an
      evidence-grounded written judgment (confidence, NOT in-spike proof) that
      the ANGLE-style GL→native path can reach full conformance + perf, grounded
      in how Chrome/ANGLE does it, naming risks/costs. No "100% proven"
      criterion.
- [ ] The findings note records the CHOSEN Dawn-vs-`wgpu-native` leaf + why
      (resolved decision 2) and that the webview backend already runs page-GPU
      content today (the native path is what this de-risks).
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
