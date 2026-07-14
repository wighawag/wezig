---
status: accepted
---

# Windowing: SDL3 as the v0 swappable leaf, native per-OS windowing as the target

v0 uses SDL3 to open the on-screen window, take input, and present the painted `Surface`, kept behind the `PaintBackend` seam (ADR-0002) in `src/sdl.zig` + `src/main.zig` only (ADR-0003). This ADR records that SDL is a DELIBERATE v0 CONVENIENCE LEAF, not the intended long-term windowing layer: for the real browser we expect to move to NATIVE per-OS windowing (a Zig-native stack such as `mach` + Dawn/`wgpu-native`, or hand-rolled `wayland`/`X11`/`Win32`/`Cocoa` bindings), because a browser needs OS-native capabilities SDL does not cleanly provide. The point of writing this down is that the choice is revisitable and the seam must stay honest.

## Context: windowing is inherently OS-specific

Opening a window, receiving input, and getting pixels on screen is done through OS-specific APIs with no way around it: Wayland (`libwayland-client`) or X11 (`libX11`) on Linux, Cocoa/AppKit (Objective-C runtime) on macOS, Win32 (`user32`/`gdi32`) on Windows. There is no OS that lets you open a window without touching its native library. So the real question is never "can we avoid OS window code?" but "do we bind those native APIs ourselves, or use a library that already did?" A "pure Zig" windowing library does NOT remove this linking; it still links the OS's own libraries (or speaks their wire protocol) and merely moves the binding/dispatch logic into Zig. The only way to truly remove third-party linking is native bindings that link ONLY the OS libraries, which is per-OS code we would own.

## Why SDL is right for v0 (and only v0)

- It got us to "a real page fragment appears on screen" fast, with one dependency instead of four per-OS windowing paths.
- ADR-0003 already isolated it correctly: SDL sits below the app entrypoint, out of the library module, and out of the headless golden tests. It is a swappable LEAF, not a spine. The `PaintBackend` seam (ADR-0002) means the engine (parse -> cascade -> layout -> paint into a `Surface`) never sees SDL.
- Because the tests target the offscreen `Surface`, replacing the windowing layer later does not touch the engine or the goldens.

## Why SDL is the wrong long-term fit for a BROWSER

SDL is a game/media abstraction. A browser needs deep OS-native windowing that SDL does not cleanly give: multiple top-level windows, native menus, IME / input-method editors, precise HiDPI, clipboard, drag-and-drop, and (critically) native GPU-surface integration for the intended Skia / Dawn / `wgpu-native` stack. Chromium and Firefox both use native per-OS windowing (Chromium's `views`/`gfx`, not SDL). `CONTEXT.md` currently names "...SDL, Dawn or wgpu-native" in the intended stack; this ADR flags that SDL line as the part to revisit. The transparency/window-size issues already hit in v0 were Wayland-compositor details: that class of complexity is inherent to windowing and does not disappear with any choice; it only moves.

## Considered options

- **Keep SDL as the permanent windowing layer.** Rejected as the LONG-TERM answer for the reasons above (a browser outgrows a game windowing abstraction), but ACCEPTED for v0 as the fastest path that keeps the seam honest.
- **`mach` (mach-core) + Dawn / `wgpu-native`.** The strongest Zig-idiomatic candidate: cross-platform, actively developed, WebGPU-first, which aligns with the Canvas/WebGL/WebGPU goal. Still links native OS libs, but the Zig side is first-class and it cross-compiles well. Likely the target direction; deferred (not a v0 need).
- **Hand-rolled native bindings (`wayland`/`X11`/`Win32`/`Cocoa`, via `@cImport` / `zigwin32` / raw protocol).** Maximum control, no big third-party lib, links only OS libraries, and Zig's cross-compilation + `@cImport` make this genuinely pleasant. Rejected for v0 only because it is real per-OS work x3+ platforms that buys nothing for the v0 milestone; it remains a legitimate future path.
- **Speak the Wayland wire protocol over a raw socket (no `libwayland`).** The only approach that removes ALL linking, and correspondingly the most platform code to own forever. Not pursued.

## Consequences

- SDL stays confined to `src/sdl.zig` + `src/main.zig`; the library, the paint backend, and the golden tests remain SDL-free and display-free, so replacing the windowing layer is a leaf swap.
- A future windowing backend (native or `mach`-based) implements the same "present a `Surface`" contract; the goldens (which target the offscreen surface) survive the swap unchanged, per ADR-0001.
- "Remove the need for linking" is not fully achievable for windowing: the achievable version is native Zig bindings that link only the OS's own libraries. If/when that is pursued, it is a real project, not a config change, and should get its own ADR.
- A prototype (a minimal non-SDL window presenting the same `Surface`) is the natural next step to make the alternative concrete before committing; it does not replace SDL in v0.
