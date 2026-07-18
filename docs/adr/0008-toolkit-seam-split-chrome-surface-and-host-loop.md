---
status: accepted
---

# Split the `Toolkit` seam into a `ChromeSurface` half and a `HostLoop` half (mobile lifecycle inversion)

The mobile-shell exploration (spec `explore-mobile-shell`, Q4/story 7) hit a real mismatch: ADR-0006's single `Toolkit` seam bundled TWO concerns that swap along DIFFERENT axes, and on mobile the desktop shape cannot be honestly implemented. On desktop, wezig's code creates the window and drives the main loop (`createWindow`/`present`/`run`/`quit`). On mobile the **OS owns the window and the run loop** — the chrome lives inside a `UIViewController` (iOS) or an `Activity` (Android) that the platform instantiates and pumps — so there is nothing for a mobile toolkit to `createWindow` or `run`. Forcing a mobile backend to stub those methods would be a lie the seam invites.

We therefore SPLIT `Toolkit` (in `src/toolkit.zig`) along the axis that actually differs desktop↔mobile, into two `{ ptr, vtable }` halves:

- **`ChromeSurface`** — the widgets + intents BOTH platforms implement: `embedView`, `setUrlText`, `setBackEnabled`/`setForwardEnabled`, `setChromeCallback`.
- **`HostLoop`** — desktop-only windowing + main loop: `createWindow`, `setTitle`, `present`, `run`, `quit`.

`Toolkit` becomes a desktop COMPOSITE (`Toolkit.compose(surface, host)`) that re-exposes the flat method surface the chrome already calls, so **`src/chrome.zig` is unchanged** — it still holds one `Toolkit` value and calls `createWindow`/`embedView`/`run`/etc. on it, each delegating to the right half. `GtkToolkit` implements both halves and composes them; a mobile toolkit will implement **only `ChromeSurface`** and be driven directly (the OS supplies the host/loop). The `chrome_conformance` guard is unaffected — the chrome still reaches neither `gtk_` nor `webkit_`.

This is the same discipline ADR-0006 used when it deferred input/scroll on the `Renderer` seam until a second backend forced the shape: refine a pinned interface on the evidence of the second (here, mobile) target, not speculatively. The split is a real, if small, refinement of a pinned interface, done now on the mobile spike's evidence.

## Considered options

- **Keep one `Toolkit` and stub host/loop on mobile.** Rejected: `createWindow`/`run` on a platform that owns neither is a dishonest no-op the seam should not invite; it also hides the genuine lifecycle inversion behind a uniform-looking interface.
- **Introduce a brand-new mobile-only seam.** Rejected: the spec's resolved decision (§Q4) is explicitly a SPLIT of the existing `Toolkit`, not a parallel interface. Two seams that overlap on `embedView`/URL/buttons would duplicate the chrome-surface concern and re-fork the vocabulary.
- **Split but make `chrome.zig` hold the two halves directly.** Rejected for this task: keeping `Toolkit` as the composite means the chrome (and every wiring site in `shell.zig`) is untouched, so the desktop blast radius is zero. The chrome does not yet need to distinguish the halves; when the mobile chrome entrypoint lands it can consume `ChromeSurface` directly.

## Consequences

- `GtkToolkit` gains `chromeSurface()` + `hostLoop()` accessors; `toolkit()` now returns `Toolkit.compose(...)`. Desktop behaviour, `zig build shell`/`shell-test`/`shell-bridge-test`/`shell-scheme-test`, and the display-free `zig build test` seam-contract tests are all unchanged and green.
- The `FakeToolkit` implements both halves and exposes `chromeSurface()`/`hostLoop()`/`toolkit()`; a headless test now proves the surface half stands ALONE (the mobile shape) with no window ever created — the seam's mobile-readiness is asserted in the gate, not just asserted in prose.
- A mobile toolkit (iOS/Android tasks downstream) implements `ChromeSurface` only; the OS-owned view controller / activity is the host/loop, so no `HostLoop` implementation is needed or wanted there.
