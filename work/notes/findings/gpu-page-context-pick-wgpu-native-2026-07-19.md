---
source: The `spike-page-gpu-context` spike itself (src/gpu_page_spike.zig + build.zig `page-gpu-frame-test` + the `gpu` CI leg), verified on the dev box: a WebGPU frame via wgpu-native v25.0.2.2 over lavapipe (Mesa 25.0.7 Vulkan/llvmpipe), and a WebGL frame via EGL surfaceless + OpenGL ES 2.0 (Mesa llvmpipe), each read back and pixel-checked. WebGL-route assessment grounded in ANGLE (angleproject.org / chromium.googlesource.com/angle/angle).
---

# Page-facing GPU pick: **wgpu-native** (WebGPU) + the ANGLE-style native-GL route is first-class-viable (WebGL) — for `native-renderer-findings-and-build-plan`

Verified while running the `spike-page-gpu-context` spike (spec
`explore-native-renderer`, story 3 + story 6, decision 2). This settles the two
open questions the task carried and proves the NATIVE page-facing GPU path on the
narrowest real case: **ONE WebGPU frame** (via the chosen leaf) **plus ONE WebGL
frame**, each from ONE shader into an offscreen `Surface` a page `<canvas>` would
present (NOT internal compositing), read back and pixel-verified.

> Two-backends reality (ADR-0005): the **system-webview backend already ships
> working WebGL/WebGPU today**, so page-GPU content runs in wezig NOW via the
> webview. This spike de-risks the NATIVE `WezigRenderer` GPU path ONLY — the
> path wezig will need when a page is rendered natively rather than in the webview.

## Resolved decision 2 — the leaf is **wgpu-native** (WebGPU primary)

Run the one-frame WebGPU path against whichever of Dawn / wgpu-native stands up
FASTEST in Zig, and record the pick. **Pick: `wgpu-native`.**

- **Build ergonomics in Zig (the deciding factor).** wgpu-native ships a
  **prebuilt** `libwgpu_native.{so,a}` + the two standard C headers
  (`webgpu.h`, `wgpu.h`). That drops straight into Zig `@cImport` + a
  `linkSystemLibrary("wgpu_native")` with an added include/lib path — no C++
  toolchain, no GN/`depot_tools`, no multi-GB source build. Dawn is a
  Chromium-family C++/GN project; standing up a one-frame path from it in Zig is
  materially more setup (build Dawn, or find/trust a prebuilt, then bind the same
  `webgpu.h`). For "fastest to a one-frame WebGPU path in Zig", wgpu-native wins
  clearly — this is exactly the tie-breaker resolved-decision 2 names.
- **WebGPU API currency.** wgpu-native tracks the current `webgpu.h`
  (WGSL shader source, the future/callback-info API, `WGPUStringView`). The spike
  targets **v25.0.2.2** against that current header; a Zig binding written now
  matches upstream WebGPU, and the SAME `webgpu.h` is what Dawn exposes — so the
  seam is written against the standard header, keeping the leaf itself swappable
  (Dawn later is a link-line change, not an API rewrite).
- **Cross-compile / maintenance.** wgpu-native publishes per-target release
  archives (Linux/macOS/Windows, x86_64/aarch64), so provisioning it in CI is a
  `curl | unzip` (the `gpu` leg does exactly this) rather than a source build.
  It is actively maintained (gfx-rs), Rust-internally but a **pure C ABI**
  outward, so it fits the repo's C-library-binding strategy (CONTEXT.md) the same
  way libcurl/HarfBuzz/SDL do.
- **Backend caveat (recorded, load-bearing for the build plan).** wgpu-native's
  **OpenGL(ES) backend panics on `wgpuQueueSubmit` headless** (v22, even for a
  clear-only pass — see `work/notes/observations/wgpu-native-gl-backend-submit-panic-2026-07-19.md`);
  the **Vulkan backend is clean** (lavapipe in CI, native ICDs on real machines)
  and is what the frame proof uses. So the pick is "wgpu-native **over its Vulkan
  backend**", not the GL backend. This is a spike-informed recommendation, NOT a
  final pin: the findings task may ratify or revisit (e.g. re-benchmark Dawn once
  a trusted prebuilt exists, or reassess the GL backend upstream-fix); but the
  leaf is CHOSEN, which is part of the de-risking.

If Dawn and wgpu-native are ever judged equivalent on capability for the real
build, wgpu-native still wins the "simpler to stand up in Zig" tie-break stated
in decision 2.

## Resolved decision 1(a) — WebGL is ASSESSED first-class-viable (confidence, NOT in-spike proof)

The spike deliverable for WebGL is **(i) one working WebGL frame** on the native
path **plus (ii) an evidence-grounded assessment** that the ANGLE-style
GL→native-GPU translation route can reach full WebGL conformance + performance.
It does NOT (and must not) claim "100% conformant + performant proven" — that is a
multi-year BUILD claim, not a spike claim.

- **(i) The one frame (proven).** `WebGlContext` in `src/gpu_page_spike.zig`
  creates a **headless EGL surfaceless + OpenGL ES 2.0** context (no window, no
  display server), compiles a vertex+fragment GLSL-ES shader pair, draws one
  full-viewport triangle into an FBO, and reads it back into the offscreen
  `Surface`. The centre pixel is the shader's blue (0/102/255) within tolerance,
  not the off-white clear — the native GL substrate a WebGL context runs on drew
  a real frame. **WebGL 1.0 IS OpenGL ES 2.0; WebGL 2.0 IS OpenGL ES 3.0**, so a
  working headless GLES2 frame is a frame on the exact substrate a native WebGL
  implementation targets.

- **(ii) The assessment (confidence, grounded in ANGLE).** Chrome/Chromium do
  NOT ship a bespoke "WebGL renderer": they implement WebGL by **translating the
  WebGL (≈ GLES) command stream through ANGLE onto the platform's native GPU
  API** — ANGLE ("Almost Native Graphics Layer Engine", Google) translates OpenGL
  ES 2.0/3.0/3.1 to **Vulkan, desktop GL, Direct3D 9/11, and Metal**
  (angleproject.org; chromium.googlesource.com/angle/angle). Safari and Firefox
  use ANGLE too. This is the industry's PROVEN route to first-class, conformant,
  performant WebGL: you do not hand-write a GL stack per OS; you translate GLES to
  the native API ANGLE already supports, and you inherit ANGLE's conformance work
  (ANGLE passes the Khronos GLES conformance suite and is what backs Chrome's
  WebGL conformance). For wezig the concrete route is: **bind ANGLE (or, longer
  term, target `wgpu`/Dawn's GL-on-native path) as the WebGL backend**, exposing
  a GLES surface to the WebGL implementation and letting ANGLE map it to Vulkan on
  Linux/Android, D3D11 on Windows, Metal on macOS/iOS — mirroring Chrome exactly.
  The spike's direct EGL/GLES frame is the substrate END of that route; the ANGLE
  layer is the translation END the build adopts rather than reinvents.

  **Known risks / costs (named, per the bar):**
  - **ANGLE is a large C++/GN dependency** (Chromium-family build), the same
    class of integration cost as Dawn — binding + provisioning + updating it is
    real work, not "it falls out". A prebuilt/vendored ANGLE eases this.
  - **Conformance is inherited but not free:** WebGL conformance = the WebGL CTS
    on top of ANGLE's GLES conformance; wezig must run the WebGL CTS against its
    integration and fix the wezig-side glue (context creation, canvas sizing,
    extension exposure, security/robustness like `robustBufferAccess`).
  - **Performance depends on the native-API path** ANGLE picks (Vulkan/D3D/Metal)
    and on avoiding readback stalls; the spike used software rasterisers
    (llvmpipe/lavapipe), so it proves CORRECTNESS of the route, NOT performance —
    performance is a build-time measurement on real GPUs.
  - **Security/sandbox:** a real page-facing GPU context needs the GPU-process /
    command-buffer isolation Chrome uses (untrusted page → GPU); out of scope for
    the spike but a first-class build concern (ADR-0011 trust posture).

  **Judgment (confidence):** the ANGLE-style GL→native route is the same route
  every shipping browser uses for first-class WebGL, it is open-source and
  liberally licensed, and the spike proved the GLES substrate frame works on the
  native path headlessly. So reaching **full WebGL conformance + performance via
  this route is credible/viable** — the build cost is ANGLE integration + running
  the WebGL CTS + the GPU-process security model, NOT inventing a GL stack. This
  is the confidence decision 1(a) asks for; the findings-and-build-plan task
  inherits it to SCOPE the real WebGL build (it is NOT a claim WebGL is done).

## Where the spike sits + what it is NOT

- **The target is the offscreen `Surface` (ADR-0003)** — the same page-`<canvas>`-
  facing paint target the v0 goldens use. Both legs render on the GPU and read
  back into it, so the frame reaches a surface a canvas would present, NOT
  internal layer compositing.
- **Own module + step + CI leg (ADR-0007), NOT the core gate.** `wgpu-native` +
  EGL/GLES are linked ONLY into the spike's test exe; it is NOT re-exported from
  `src/root.zig`, so they never enter the `wezig` library `mod`, the desktop
  consumers, or the mobile cross-compiles. The live render legs are `-Dgpu-live`
  (the `gpu` job); a bare `zig test` compiles+links and skips them, so the
  display/GPU leg stays OUT of the display-free `zig build test` gate, which stays
  green.
- **NOT the Canvas/WebGL/WebGPU subsystem.** No canvas element, no WebGL/WebGPU
  JS API, no swapchain/windowing, no compute, no bind groups/textures/uniforms
  beyond the one triangle. Those are the follow-on BUILD spec this spike de-risks.

## Recommendation for the build plan

1. **Pin `wgpu-native` (over its Vulkan backend) as the native WebGPU leaf**,
   bound through the standard `webgpu.h`/`wgpu.h` so Dawn stays a link-line-level
   alternative behind the same API. Sequence the WebGPU build to grow this
   one-frame path into a real canvas-backed context (swapchain/surface, bind
   groups, the WebGPU JS API) behind the paint/renderer seams.
2. **Pin the ANGLE-style GL→native route for WebGL** (translate GLES to the
   platform native API as Chrome does), budgeting ANGLE integration + the WebGL
   CTS + the GPU-process security model. Do NOT scope WebGL as "hand-write a GL
   backend"; scope it as "integrate ANGLE + prove conformance/perf".
3. Both are NATIVE-path work; the webview backend continues to serve page-GPU
   content until the native path reaches the target tier (ADR-0005).
