# wgpu-native's OpenGL/GLES backend panics on `queueSubmit` headless (v22); Vulkan/lavapipe is clean

2026-07-19 — noticed while running the `spike-page-gpu-context` spike.

wgpu-native **v22.1.0.5**'s OpenGL(ES) backend gets a valid adapter/device/pipeline
headlessly (EGL surfaceless + Mesa llvmpipe) but **panics inside `wgpuQueueSubmit`**
(`wgpu-core/src/command/mod.rs:522`, "CommandBuffer cannot be destroyed because is
still in use", a non-unwinding Rust panic that aborts the process) even for a
clear-only render pass — so the GL backend cannot complete a frame there. The
**Vulkan backend on lavapipe (`mesa-vulkan-drivers`) is clean** and completes a
full render→copy→map→readback with **wgpu-native v25.0.2.2**. This drove the spike's
leaf/version/backend pick (see `work/notes/findings/gpu-page-context-pick-wgpu-native-2026-07-19.md`):
target v25's current webgpu.h API over the Vulkan backend, not GL.

Out of scope for this spike (just capturing the signal): the real GPU build should
not lean on wgpu-native's GL backend for headless/CI readback; prefer Vulkan
(lavapipe in CI, native ICDs on dev machines) or re-evaluate once the GL backend
submit path is fixed upstream.
