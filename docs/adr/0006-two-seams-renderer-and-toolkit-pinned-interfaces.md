---
status: accepted
---

# Two seams: the `Renderer` (content) and `Toolkit` (chrome host) interfaces, pinned

The webview-shell exploration (spec `explore-webview-shell`) turns the hello-window's ad-hoc WebKitGTK/GTK calls into TWO pinned, swappable Zig interfaces and a minimal chrome that talks ONLY to them: the **`Renderer` seam** (content backend, `src/renderer.zig`) and the **chrome/toolkit seam** (chrome host + windowing, `src/toolkit.zig`). This ADR pins both interface shapes and records why there are two seams, because these interfaces are load-bearing for `explore-web3-capabilities` and the eventual `WezigRenderer` swap, and are hard to change once a second implementation exists (the same reason ADR-0002 pinned `PaintBackend`).

## Why TWO seams (content vs chrome host)

A browser shell has two independent swap axes. The CONTENT backend (what turns a URL into a live, interactive view) swaps WebKitGTK -> `WezigRenderer` (ADR-0005). The CHROME HOST (the window + toolbar widgets, and the windowing/event loop underneath) swaps GTK -> Qt -> a Zig-native chrome layer. These change for different reasons and at different times, so folding them into one interface would couple two unrelated decisions. Keeping them separate means the minimal chrome (`src/chrome.zig`) is the ONLY module that holds both and wires them together; it imports neither `webkit` nor `gtk` (a later task adds a conformance check that greps for `webkit_`/`gtk_` in the chrome and expects zero hits).

Both interfaces use the repo's idiomatic seam shape: a `{ ptr: *anyopaque, vtable: *const VTable }` value (exactly like `PaintBackend`/`std.mem.Allocator`), so a backend is a runtime VALUE, not a comptime type. Each has exactly ONE implementation today; a fake in-memory implementation of each (`FakeRenderer`, `FakeToolkit`) lets the chrome<->seam contract be tested headlessly in `zig build test` with no webview and no display.

## The `Renderer` seam (pinned, MINIMAL)

`src/renderer.zig`, implemented by `SystemWebviewRenderer` (WebKitGTK, `src/system_webview_renderer.zig`). Started MINIMAL on purpose (just what a one-window, URL-bar, back/forward chrome needs); the script-message bridge and request-interception/custom-scheme hooks that ADR-0005 pins to this seam are a SEPARATE task and are intentionally ABSENT here.

- **navigation:** `navigate(uri)` / `reload()` / `stop()`, `goBack()` / `goForward()`, `canGoBack()` / `canGoForward()`.
- **view:** `view() -> ViewHandle` (an OPAQUE `*anyopaque` embeddable interactive view; the chrome passes it to the toolkit without knowing it is a `GtkWidget`).
- **input/scroll/viewport:** `setViewportSize(w, h)`. For the webview backend, input and scroll are handled by the live interactive view widget itself once embedded and focused, so no per-event forwarding method exists at this seam yet. A `WezigRenderer` (which owns no OS-native interactive widget) will extend the seam with explicit input/scroll forwarding when it lands; recording that here so the omission is a known, deliberate MINIMAL-start choice, not an oversight.
- **load lifecycle EVENTS:** `setLifecycleCallback(cb)` delivers a `LifecycleEvent` union (`load_changed{ state, uri }` with `LoadState = started|committed|finished|failed`, `title_changed`, `uri_changed`, `progress_changed`). The chrome subscribes and reflects these into its widgets. At most one sink (a later call replaces it).

## The `Toolkit` seam (pinned) — windowing behind the seam (story 6)

`src/toolkit.zig`, implemented by `GtkToolkit` (GTK4, `src/gtk_toolkit.zig`). This is ALSO where **windowing sits behind a seam**: GTK owns the shell WINDOW now, but the chrome reaches it through `Toolkit.createWindow` and never calls `gtk_window_new`, so the windowing layer is a swappable component. (This is a DIFFERENT seam from ADR-0004's SDL/native windowing leaf: that leaf stays the `WezigRenderer`-direct render/present harness for the v0 engine + golden tests; the toolkit windowing here is the chrome-host window for the webview shell. The two do not share code and swap independently.)

- **window / windowing:** `createWindow(w, h)`, `setTitle(t)`, `embedView(ViewHandle)` (host the renderer's opaque view below the toolbar), `present()`, `run()` / `quit()` (the chrome-host main loop — the windowing event loop, owned by the toolkit).
- **widgets:** `setUrlText(t)` (the URL bar), `setBackEnabled(b)` / `setForwardEnabled(b)` (button sensitivity).
- **events:** `setChromeCallback(cb)` delivers a `ChromeIntent` union UP to the chrome (`navigate(url)`, `reload`, `back`, `forward`, `closed`), which the chrome turns into `Renderer` calls (or a quit).

**Swap path (windowing + toolkit):** a Qt or Zig-native toolkit implements this SAME `Toolkit` interface (its own `createWindow`/`run`/widgets over its native windowing) and is passed to `Chrome.init` in place of `GtkToolkit`; nothing in `chrome.zig` changes. That is the whole point of putting windowing behind the seam.

## The discipline (what makes the swap cheap)

The chrome talks ONLY to `Renderer` + `Toolkit`. The renderer's view crosses BOTH seams as an opaque `ViewHandle`, so the chrome never learns it is a GTK widget; only the two backend files (`system_webview_renderer.zig`, `gtk_toolkit.zig`) and the shell's smoke snapshot touch `webkit_*`/`gtk_*`. All three link the native libraries and live in the shell executable ONLY, never the `wezig` library module, so the v0 SDL render path and the headless golden tests stay WebKitGTK/GTK-free (`build.zig`). ADR-0005 called for a conformance check that the chrome imports neither binding; that check is a later task, but the boundary is built to pass it now.

## Considered options

- **One combined seam (content + chrome in a single interface).** Rejected: it couples two independent swap axes (webview->native content vs GTK->Qt chrome). Two seams keep each swap isolated and keep the chrome the sole integrator.
- **Pass the renderer's view as a concrete GTK widget type across the seam.** Rejected: it would leak GTK into the chrome and the `Renderer` interface. The opaque `ViewHandle` keeps both the chrome and the interfaces backend-free; only the two backends interpret it.
- **Add input/scroll/script-bridge/interception to the `Renderer` seam now.** Rejected for THIS task: the exploration pins the MINIMAL surface and proves it; the bridge + interception are `explore-web3-capabilities`'s dependency and get added deliberately by the next task so the interface does not grow speculative methods with no implementation.

## Consequences

- `SystemWebviewRenderer` and `GtkToolkit` are the first and only implementations; `WezigRenderer` (content) and Qt/Zig-native (chrome host) implement the SAME two interfaces later, swapped in at `Chrome.init` with no chrome change.
- The `explore-web3-capabilities` provider/IPFS work extends the `Renderer` seam (script-bridge + custom-scheme interception) rather than reaching into WebKitGTK, so it keeps working after the native swap.
- The `zig build shell` / `shell-test` steps now drive real navigation THROUGH the two seams; `shell-test` (headless, under Xvfb) navigates via the `Renderer` seam, asserts the seam's `.finished` lifecycle event reached a subscriber, and snapshots the view non-blank. The v0 gate (`zig fmt --check`, `zig build`, `zig build test`) is untouched and green; the seam-contract tests (`FakeRenderer`/`FakeToolkit`/chrome) run inside `zig build test` headlessly.
