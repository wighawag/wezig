---
status: accepted
---

# Mobile app lifecycle / state-restoration is HOST-ONLY; the `Renderer` seam is NOT grown

The mobile-shell build (spec `build-mobile-shell`, Resolved decision 1, story 9) must make page state survive a background→foreground round-trip. We decide this is a **HOST concern that lives ABOVE the `Renderer` seam**: the `UIViewController` (iOS) / `Activity` (Android) host wires background→foreground restoration by driving the EXISTING `Renderer` methods (`stop`/`navigate`/`setViewportSize`) plus the native `WKWebView` / `android.webkit.WebView` state save-restore the OS already mandates. **No `suspend`/`resume`/state-save-restore method is added to the `Renderer` seam now.**

## Why host-only (and not a new seam method)

The only two `Renderer` backends today — iOS `WKWebView` (`src/ios_webview_renderer.zig`) and Android `android.webkit.WebView` (`src/android_renderer.zig`) — **restore their own state natively**: the OS persists and re-materialises the webview's page, scroll position, and history across the lifecycle transition. A seam-level `suspend`/`resume`/state method would therefore forward a signal the host ALREADY has to a backend that ALREADY handles it — pure pass-through that buys nothing.

Adding it now is precisely the **speculative pinned-interface growth ADR-0006 forbids** ("MINIMAL on purpose"; "the interface does not grow speculative methods with no implementation"). It is the SAME discipline ADR-0006 applied when it **deferred input/scroll forwarding** on the `Renderer` seam until a second backend (`WezigRenderer`, which owns no OS-native interactive widget) forces the shape. Lifecycle is the same story: defer the seam method until a backend genuinely forces it.

Reversibility runs the safe way. Host-only NOW, then ADDITIVELY add a seam method LATER is non-breaking. Guessing the method shape now and re-pinning a 2+-implementation interface when the forcing backend lands is the expensive, breaking move. So the cheap-and-correct order is: keep the seam minimal now; grow it on the evidence of the backend that forces it.

## Breadcrumb — `WezigRenderer` on mobile IS expected to force a seam-level lifecycle API (a KNOWN deferral)

A future `WezigRenderer` on mobile (downstream of `explore-native-renderer`, satisfying this SAME `Renderer` seam) owns **no OS webview widget that auto-persists** its own state across the lifecycle. When it lands it is EXPECTED to force a seam-level `suspend`/`resume`/state-save-restore API — pinned THEN, on that backend's evidence, exactly as input/scroll is deferred to it. This is recorded here so the omission is a **known, deliberate deferral, not an oversight**: the `WezigRenderer`-on-mobile task inherits, as an explicit debt, the obligation to grow the seam with lifecycle/state methods (mirroring input/scroll) at that point.

## Cross-references

- **ADR-0006** (`0006-two-seams-renderer-and-toolkit-pinned-interfaces.md`) — the MINIMAL-seam discipline this follows, and the input/scroll deferral precedent it mirrors.
- **ADR-0009** (`0009-mobile-shell-exploration-outcome-and-build-inputs.md`) — the mobile exploration outcome that confirmed the two backends carry the seams and placed app lifecycle / state restoration in the build spec.
- **Spec `build-mobile-shell`** — Resolved decision 1 (this decision) and story 9 (the requirement to record the lifecycle→seam mapping).

## Consequences

- The `Renderer` seam (`src/renderer.zig`) is UNCHANGED by this slice; the mobile lifecycle wiring lives entirely in the platform host (`UIViewController`/`Activity`) and drives only existing seam methods + native save-restore. The desktop v0 gate stays green — this is a documentation/decision deliverable, no code change.
- A future `WezigRenderer`-on-mobile task must reproduce lifecycle/state semantics and, at that point, grow the seam with the `suspend`/`resume`/state API deferred here — the same way it is expected to grow the seam with input/scroll forwarding (ADR-0006).
