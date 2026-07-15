# Webview-shell exploration: findings + de-risked build plan

This is the CONFIDENCE deliverable of the `explore-webview-shell` exploration (ADR-0005, ADR-0006): a durable, grounded report of what the four spikes LEARNED about the browser shell, plus a de-risked build plan for the follow-on usable-browser BUILD spec. An exploration's "done" is confidence + a plan, not a shipped browser (spec `explore-webview-shell`), so this document, not the spike code, is the deliverable a human or agent reads to author that build spec with the shell's real shape already known.

Every claim below traces to something a spike actually observed. The four spikes, in order, were:

- `webview-hello-window` (story 4): a GTK4 window embedding a `WebKitWebView` that loads one real, interactive page, plus the headless snapshot smoke test.
- `renderer-seam-and-toolkit-seam` (stories 1, 2, 3, 5, 6): the two pinned Zig seams (`Renderer` content backend, `Toolkit` chrome host) and a minimal chrome that talks only to them.
- `seam-script-bridge-and-interception` (story 1): the two web3-load-bearing hooks on the `Renderer` seam (script-message bridge, custom-scheme interception), each proven end-to-end.
- `chrome-swap-discipline-conformance-check` (story 9): the machine-enforced guard that the chrome imports neither `webkit` nor `gtk`.

Where a claim comes from a captured note rather than the code, the note is cited. The load-bearing external ground truth on service workers is `work/notes/findings/sw-fetch-vs-custom-scheme-interception-two-layers-2026-07-15.md`; provisioning ground truth is `work/notes/observations/shell-xvfb-provisioning-and-cimport-shim-2026-07-15.md`.

## 1. The pinned seams (what landed, and the one gap)

The exploration pinned TWO seams, both recorded in ADR-0006 and both built as the repo's idiomatic `{ ptr: *anyopaque, vtable: *const VTable }` value (the `PaintBackend`/`std.mem.Allocator` shape), so a backend is a runtime VALUE, not a comptime type.

- **`Renderer` seam** (`src/renderer.zig`), the content backend at the chrome-to-content boundary. Implemented by `SystemWebviewRenderer` on WebKitGTK (`src/system_webview_renderer.zig`). Surface: `navigate`/`reload`/`stop`, `goBack`/`goForward`, `canGoBack`/`canGoForward`; `view() -> ViewHandle` (an opaque embeddable interactive view); `setViewportSize`; `setLifecycleCallback` delivering a `LifecycleEvent` union (`load_changed{state, uri}` with `LoadState = started|committed|finished|failed`, `title_changed`, `uri_changed`, `progress_changed`). The `seam-script-bridge-and-interception` task then added the two web3-load-bearing hooks: the **script-message bridge** (`injectUserScript`, `setScriptMessageHandler`, `evaluateScript`) and the **custom-scheme interception** hook (`registerScheme` with a `SchemeHandler` returning a `SchemeResponse{ body, content_type }`).
- **`Toolkit` seam** (`src/toolkit.zig`), the chrome host AND the windowing layer (story 6). Implemented by `GtkToolkit` on GTK4 (`src/gtk_toolkit.zig`). Surface: `createWindow`, `setTitle`, `embedView(ViewHandle)`, `present`, `run`/`quit` (the chrome-host main loop, i.e. the windowing event loop); `setUrlText`, `setBackEnabled`/`setForwardEnabled`; `setChromeCallback` delivering a `ChromeIntent` union UP (`navigate(url)`, `reload`, `back`, `forward`, `closed`).

The minimal chrome (`src/chrome.zig`) is the sole module holding both seam values and wiring them together; it turns each `ChromeIntent` into a `Renderer` call and reflects each `LifecycleEvent` into a `Toolkit` widget update. Both seams also ship a fake in-memory implementation (`FakeRenderer`, `FakeToolkit`) so the chrome<->seam contract is tested headlessly inside `zig build test` with no webview and no display.

**The seam surface was sufficient for the minimal chrome.** The spikes drove one real page (`zig build shell` interactive; `example.com`) plus three headless proofs (smoke render, bridge round-trip, scheme serve) entirely through these methods, so navigate/interact/lifecycle + the two hooks covered a one-window, URL-bar, back/forward chrome with no gap that blocked the spike.

### The one gap a real backend revealed: input/scroll forwarding is deliberately absent

`setViewportSize` is the ONLY input/viewport method on the `Renderer` seam, and on the WebKitGTK backend it is a NO-OP: the embedded `WebKitWebView` is itself a live, focusable GTK widget, so it handles scroll, click, and keyboard input directly once embedded (the interactive spike verified scroll/click/type work). This is recorded in `renderer.zig` and ADR-0006 as a deliberate MINIMAL-start omission, NOT an oversight: a `WezigRenderer` owns no OS-native interactive widget, so it CANNOT rely on the widget-handles-input path and WILL need the seam extended with explicit input/scroll forwarding (pointer events, key events, wheel/scroll deltas, focus). This is the single most important known-incomplete part of the `Renderer` interface, and the build plan (section 6) calls it out as a decision the build spec must make BEFORE a second backend lands, because adding input methods after `WezigRenderer` exists is a breaking change to a seam with two implementations.

A second, smaller sharp edge the bridge spike surfaced: `setScriptMessageHandler` today supports exactly ONE page->native channel, because the WebKitGTK `JSCValue` handed to the handler does not carry the channel name, so the backend hardcodes the channel name `"wezig"` when it re-emits (`system_webview_renderer.zig` `onScriptMessage`; nit captured in `work/notes/observations/review-nits-seam-script-bridge-and-interception-2026-07-15.md`). One channel is enough for the exploration and for a single EIP-1193 provider, but `explore-web3-capabilities` should decide whether it needs more than one named channel; if so, the backend must connect the per-detail signal so the channel name is recoverable.

## 2. GTK leakage: how much leaked despite the toolkit seam

The conformance check (`src/chrome_conformance.zig`) MACHINE-PROVES the core claim: `src/chrome.zig` contains zero `webkit`/`gtk` code tokens (comment-stripped, case-insensitive scan, run inside the v0 `zig build test` gate). It is demonstrated in both directions (a synthetic chrome that imports the webkit binding fails; one that imports gtk fails). So the chrome itself is genuinely toolkit-free and content-backend-free. That is the leakage assessment's headline: **the chrome does not leak GTK at all.**

The leakage that DOES exist is confined to three well-understood places, none of them the chrome:

1. **The two backend files.** `system_webview_renderer.zig` touches `webkit_*`; `gtk_toolkit.zig` touches `gtk_*`. This is by design: they ARE the seam implementations. Both link the native libraries and live in the shell executable ONLY, never the `wezig` library module (`build.zig`), so the v0 SDL render path and the headless golden tests stay WebKitGTK/GTK-free.
2. **The shell's smoke snapshot (`src/shell.zig`).** The headless `shell-test` calls `webkit_web_view_get_snapshot` / `gdk_texture_download` directly, because **there is no seam-level snapshot API yet**. This is the one place the shell reaches past the seam for a non-chrome reason (test verification), and it is the clearest candidate for a future seam method (`snapshot() -> pixels`) if headless snapshot testing needs to survive the `WezigRenderer` swap. It re-casts the opaque `ViewHandle` back to a `*c.WebKitWebView` through its own `@cImport`, which only works because the handle IS a GtkWidget today.
3. **The `ViewHandle` is a raw `*anyopaque` GtkWidget** that crosses BOTH seams (`Renderer.view()` -> chrome -> `Toolkit.embedView`). The chrome never learns it is a GtkWidget (that is the point), but the fact that the toolkit can host the renderer's view AT ALL depends on both backends today agreeing it is a GtkWidget. A Qt toolkit embedding a WebKitGTK view, or a GTK toolkit embedding a `WezigRenderer` surface, would need a real cross-toolkit embedding contract, not just an opaque pointer. This is the deepest latent coupling the exploration found: the opaque handle hides the type from the chrome but does NOT make the two backends independent of each other's widget system.

A fourth, minor leak: `GtkToolkit.init()` returns `error.GtkInit`, and the shell entrypoint's error set names it (`shell.zig` `ShellError.GtkInit`), so the toolkit's failure mode is named after GTK in the shell exe (not the chrome). Cosmetic; a swapped toolkit would want a toolkit-neutral init-failed error.

### Is a Qt or Zig-native chrome feasible behind this seam, and at what cost?

**Feasible: yes, for the widget/window/event-loop surface.** The `Toolkit` interface is small and toolkit-neutral (window, title, URL text, two button-enabled flags, embed-a-view, main loop, and one intent callback UP). A Qt or Zig-native implementation of exactly those methods drops into `Chrome.init` with no chrome change, which is the swap the two-seams design bought. The conformance guard keeps it that way.

**The real cost is NOT the widgets; it is view embedding (the `ViewHandle` coupling above).** `embedView` today does `gtk_box_append` of a GtkWidget. A Qt toolkit cannot `gtk_box_append`, and a WebKitGTK view is a GtkWidget, so hosting a GTK WebView inside a Qt window means cross-toolkit embedding (foreign-window reparenting / an X11 or Wayland subsurface), which is real, platform-specific work outside the current seam. So: swapping the CHROME toolkit while keeping the WebKitGTK CONTENT backend is the expensive combination, precisely because both are GTK-family today and the seam hides but does not sever their shared widget substrate. The cheap swaps are the ones where the two backends do NOT have to co-embed across toolkits (e.g. GTK chrome + `WezigRenderer` content, where `WezigRenderer` can render into whatever surface the toolkit provides). The build spec should treat "Qt chrome hosting a WebKitGTK view" as a research spike in its own right, not a drop-in.

## 3. Service workers + the N-concurrent-contexts content model (story 7 design)

This section DESIGNS the content model story 7 requires; it does not merely observe. The external ground truth it rests on is the finding `work/notes/findings/sw-fetch-vs-custom-scheme-interception-two-layers-2026-07-15.md` (WebKitGTK 6.0 headers, this dev box, observed while proving `registerScheme`).

### What WebKitGTK provides for service workers, and the two interception layers

WebKitGTK ships service-worker support. SW registrations are a first-class website-data category (`WEBKIT_WEBSITE_DATA_SERVICE_WORKER_REGISTRATIONS`), persisted and cleared through a `WebKitNetworkSession`'s `WebKitWebsiteDataManager`. The browser does not register or drive SW handlers; the PAGE does, and WebKit runs them inside the web-content process.

The load-bearing finding is that **SW `fetch` interception and our custom-scheme interception are TWO DIFFERENT LAYERS**, and conflating them is the trap a future native SW handler must avoid:

- **Custom-scheme interception is the NATIVE / context layer** (what `registerScheme` added). `webkit_web_context_register_uri_scheme` installs a `WebKitURISchemeRequestCallback` in OUR process. It fires for EVERY request to that scheme, before any page JS sees it, and answers with bytes we generate. This is where `ipfs://` and wallet-RPC endpoints get served. It is OURS and it survives the `WezigRenderer` swap because it lives at the seam.
- **Service-worker `fetch` interception is the PAGE / JS layer** (what WebKitGTK provides). The SW's `fetch` handler is page-controlled JavaScript; WebKit runs it. We do not write a scheme callback for it.

**How they relate (the precedence that matters):** for a normal http/https origin, the page's SW `fetch` handler gets first refusal; only requests that leave the SW (or origins with no SW) reach the network/context layer. For OUR custom scheme, our native callback answers directly. The consequence for a future native SW handler: a service worker can only be registered from, and control, a **secure origin**, and a custom scheme is NOT secure/CORS-enabled by default. WebKitGTK exposes the knobs at the SAME context/security layer as the scheme: `WebKitSecurityManager`'s `register_uri_scheme_as_secure` / `..._as_cors_enabled` / `..._as_local` / `..._as_display_isolated`. So whether content served by our native scheme interception can host a service worker is a native/context-layer decision about the scheme's SECURITY TRAITS.

**What a future native SW handler must satisfy at the seam:** it is a DIFFERENT surface from `registerScheme` (which serves bytes; it is not where a page's SW plugs in). To admit it, the seam must let the backend also declare a scheme's SECURITY TRAITS (secure / CORS / local) at registration time, because SW-hosting on content we serve depends on the origin being secure. Today `registerScheme` takes only `{ body, content_type }`. The build spec must DECIDE whether scheme security traits go on that same seam call (extra fields) or a sibling call, and record that a `WezigRenderer` must reproduce BOTH the fetch-serving AND the origin-security semantics for SW-hosting to behave identically after the swap.

### The content model: N concurrent `PageContext`s decoupled from presentation

Story 7 requires that deferring tabs-as-UI must NOT bake in a one-visible-page-at-a-time architecture. The design below is the shape the build spec should adopt. It is deliberately expressed in the same seam idiom already in the repo.

The unit is a **`PageContext`**: one page/document context with its own `Renderer`-seam view, its own session history, and its own lifecycle-event stream. A context can exist WITHOUT being the presented one (background load, prerender, a SW-driven update to a non-visible context), and a context can outlive or precede its on-screen view. Presentation (which context, if any, is embedded in the window right now) is a SEPARATE concern from context existence. Concretely:

- The `Renderer` seam gains a context-lifecycle surface: `createContext() -> PageContext`, `destroyContext(PageContext)`, and the existing navigate/lifecycle/hook methods become PER-context (they operate on a `PageContext`, not on a single implicit view). Today's single-view `Renderer` is the N=1 special case of this; the minimal chrome drove exactly one context, which is why the spike did not need this yet.
- Presentation is a toolkit concern: `Toolkit.embedView(ViewHandle)` already takes a specific view, so switching the presented context is `embedView(otherContext.view())`. Tabs-as-UI, when built, is just a chrome that owns N `PageContext`s and calls `embedView` on the selected one; NO context assumes it is the visible one.
- **Backgrounded contexts still run.** Because a `PageContext` owns a real view whether or not it is embedded, a background context keeps loading, keeps running its service worker, and keeps delivering lifecycle events to its own subscriber. The chrome multiplexes N event streams (one sink per context) instead of one.

**Where service workers touch this (the partitioning decision):** SW registrations (and cookies) are shared per-`WebKitNetworkSession` website-data, NOT per view. So an N-context model must decide which contexts SHARE a `WebKitNetworkSession` (hence share SW registrations, cookies, cache) versus get an ISOLATED one. That partitioning is the browser's privacy/identity boundary (normal tabs share a session; a private/incognito context gets its own; the wallet's origin may want isolation). It is orthogonal to, but interacts with, both interception layers above, and it is a decision the build spec must make explicitly rather than inherit by accident from "one default session." A `PageContext` should therefore carry a session-partition identity, and the seam should expose session creation/selection so the chrome can place a context in the right partition.

**What a native SW handler must satisfy at the seam (restated for the N-context world):** the SW surface is per-`WebKitNetworkSession`, so a native SW handler is registered against a SESSION/partition, not against a single view; a `WezigRenderer` must reproduce the same per-session registration + secure-origin semantics so SW behaviour is identical across the swap and across contexts sharing a partition.

## 4. Process / sandbox model: what WebKitGTK imposes

WebKitGTK is ALREADY multi-process, and the exploration's stance (per the spec) is to OBSERVE and REPORT this, not to decide the shell's final process model.

What is imposed and observed:

- **WebKitGTK runs the web content in a separate content process** (a UI process + one or more web-content/network processes), with its own sandbox. Our `SystemWebviewRenderer` lives in the UI process; the page's JavaScript, DOM, and its service worker run in the content process. This is why the two interception layers land where they do: our `WebKitURISchemeRequestCallback` runs in OUR process (UI-side), while the page's SW `fetch` runs in the content process. The multi-process split is not something we opt into; it is how the webview works.
- **The script-message bridge crosses the process boundary for us.** `WebKitUserContentManager` handlers and `evaluateScript` marshal across the UI<->content boundary; the spike's bridge round-trip (page posts, native receives, native evaluates a reply, page observes it) proves that cross-process round-trip works through the seam without us managing IPC. A future native `WezigRenderer` that is single-process would satisfy the SAME seam with in-process calls, so the seam abstracts over "is there a process boundary here?" already.
- **The sandbox is the webview's, not ours (yet).** WebKitGTK provides its own content sandbox. The wallet's key custody must therefore NOT live in the content process or behind the page-world bridge alone: the bridge delivers page requests to native, but the signing/custody boundary is a NATIVE-side concern (UI process or a dedicated broker), and the page never gets the key material, only the ability to REQUEST via the bridge. This is a direct input to `explore-web3-capabilities`: the wallet boundary is "page-world provider (untrusted, content process) posts a `request` over the script bridge; native (trusted, UI-side) decides and replies," and that boundary holds identically after the `WezigRenderer` swap because it is expressed at the seam.

**What the shell must ASSUME vs ABSTRACT:** it must ASSUME the content backend may be multi-process (so nothing above the seam may assume synchronous, same-process access to page state; all page interaction is async over the bridge/lifecycle events). It must ABSTRACT the process count behind the seam (the seam methods are the same whether the backend is WebKitGTK-multiprocess or a single-process `WezigRenderer`). The final sandbox posture (do we add our own sandboxing around the wallet broker, tighten the webview sandbox, etc.) is a build-plan decision, not settled here.

## 5. Headless-testing strategy: Xvfb + snapshot

WebKitGTK has **NO native headless mode**, and `GtkOffscreenWindow` does NOT work with a WebView (WebKit bug #76911). So the supported headless approach is a **virtual X display (Xvfb)** plus `webkit_web_view_get_snapshot`, and this is the strategy the spikes actually use.

Concretely (all grounded in the landed `build.zig` + `shell.zig`):

- The headless proofs run their real-backend logic under `xvfb-run -a <binary>` (the `-a` auto-picks a free display). They are SEPARATE build steps, kept OUT of the display-free `zig build test` gate on purpose: `shell-test` (navigate through the `Renderer` seam, assert the seam's `.finished` lifecycle event reached a subscriber, snapshot the view non-blank), `shell-bridge-test` (script-message bridge round-trip both ways), and `shell-scheme-test` (custom-scheme served and rendered).
- The non-blank check downloads the snapshot texture's pixels (`gdk_texture_download`) and asserts not every pixel is identical, so a blank/failed render is caught; a page with an opaque background + text passes decisively.
- The seam-CONTRACT tests (both hooks exist and round-trip through the FAKE backend) live in `renderer.zig`'s `zig build test` block and need NO display, so the core gate stays display-free and fast. The `xvfb`-needing steps prove the REAL WebKitGTK backend.

**The `xvfb` CI-leg requirement:** the three headless steps need `xvfb` (`xvfb-run`) provisioned. It IS installed on the dev box now (`/usr/bin/xvfb-run`), but any CI that runs `shell-test`/`shell-bridge-test`/`shell-scheme-test` MUST `apt-get install xvfb` first; the interactive `zig build shell` does NOT need it, and the core `zig build test` gate does NOT need it. This means the build spec's CI plan needs a DEDICATED leg (a job/leg with `xvfb` + `libwebkitgtk-6.0-dev`) distinct from the fast display-free gate. See `work/notes/observations/shell-xvfb-provisioning-and-cimport-shim-2026-07-15.md` for the provisioning history and for the `webkit_c.h` translate-c shim (a bare `@cImport(@cInclude("webkit/webkit.h"))` does not lower on Zig 0.16; the shim `src/webkit_c.h` neutralises exactly two GObject/GTK constructs and is the reusable binding entry).

## 6. The de-risked BUILD PLAN

This section states what the follow-on usable-browser BUILD spec must contain and DECIDE, so it can be authored and tasked atomically. Each item is grounded in a spike finding above; the "decide" points are the load-bearing choices the exploration surfaced but (correctly) did not settle.

### What the build spec already knows (de-risked by the exploration)

- The two seams (`Renderer`, `Toolkit`) and the swap discipline are proven and machine-guarded; the build builds AGAINST them, never around them.
- One real page loads and is interactive; the two web3 hooks (script bridge, custom-scheme interception) work end-to-end and are on the seam interface, so `explore-web3-capabilities` can build on them.
- The headless test strategy (Xvfb + snapshot, separate steps, `xvfb` CI leg) is established and can be reused per new shell feature.
- The service-worker two-layer model and the N-context content-model shape (section 3) are designed, so tabs/history/downloads can be specified over `PageContext`s without re-deriving the architecture.

### What the build spec must CONTAIN

1. **The presentation model over N `PageContext`s.** Adopt the `PageContext` design (section 3): make the `Renderer` seam's navigate/lifecycle/hook methods per-context, add `createContext`/`destroyContext`, and build the presentation (tabs, or a single switchable view) as a chrome that owns N contexts and `embedView`s the selected one. This is the story-10 "presentation model over N contexts" requirement.
2. **History + persistence.** Session history per context is a `PageContext` concern; cross-session persistence (history, bookmarks) is a data-store concern the seam does not yet touch. Specify where persisted state lives and how it maps to `WebKitNetworkSession` website-data vs our own store.
3. **Downloads.** Not exercised by the spike at all; WebKitGTK provides a download API on the network session. Specify whether downloads are a new `Renderer`-seam surface (so `WezigRenderer` must satisfy it) or a webview-only feature for now.
4. **The process/sandbox model** (section 4): decide the final posture, especially the wallet-broker boundary (native-side custody, page-world request-only), and whether the shell adds its own sandboxing.
5. **The CI plan**: a dedicated leg with `xvfb` + `libwebkitgtk-6.0-dev` running the `shell-*` steps, separate from the fast display-free gate.

### What the build spec must DECIDE (the load-bearing choices the exploration surfaced)

- **Input/scroll forwarding on the `Renderer` seam (highest priority, section 1).** WebKitGTK's view handles input itself, so the seam has none. `WezigRenderer` cannot. DECIDE the input/scroll/focus method set and add it to the seam BEFORE a second backend lands, because adding it after two implementations exist is a breaking change to a pinned interface.
- **Scheme security traits on the seam (section 3).** Decide whether `registerScheme` grows `{ secure, cors, local }` fields or gains a sibling call, since SW-hosting on served content depends on it and a `WezigRenderer` must reproduce the origin-security semantics.
- **Session/partition identity on `PageContext` (section 3).** Decide the sharing model: which contexts share a `WebKitNetworkSession` (SW registrations + cookies + cache) vs get an isolated one, and expose session creation/selection at the seam.
- **A seam-level snapshot API (section 2).** The one place the shell reaches past the seam today is the smoke snapshot. Decide whether headless snapshot testing needs a `snapshot()` seam method to survive the `WezigRenderer` swap, or stays a webview-only test affordance.
- **Cross-toolkit view embedding (section 2).** The `ViewHandle` is an opaque GtkWidget both backends agree on. DECIDE whether the build actually needs a non-GTK chrome hosting a WebKitGTK view (the expensive combination) or whether the realistic swap axes keep the two backends from co-embedding across toolkits; if the former, scope a dedicated foreign-embedding spike.
- **Multi-channel script bridge (section 1).** Decide whether more than one named page->native channel is needed (today's backend hardcodes one); if so, the backend must recover the channel name from the per-detail signal.

Authored this way, each build item (presentation-over-contexts, input-forwarding seam extension, session partitioning, downloads, history/persistence, CI leg) is independently taskable against a seam whose real shape and gaps are now known, which is exactly the "atomically taskable" outcome the exploration exists to produce.

## Decisions recorded by this deliverable

This is a documentation task, but it makes two judgement calls worth ratifying (recorded here and cross-linked from ADR-0007):

- **This findings doc lives at `docs/shell-exploration-findings.md`, alongside `docs/v0-subset.md`,** rather than under `docs/adr/`. Rationale: it is a report + design + plan (a reference document), not a single decision; ADRs stay short per `work/protocol/ADR-FORMAT.md`, and the durable DECISIONS the exploration settled are pointed to from a companion ADR (ADR-0007). Alternative considered: fold everything into one long ADR; rejected because it violates the "an ADR can be a single paragraph" norm and buries the design/plan.
- **The N-context content model is expressed as a DESIGN (the `PageContext` shape + per-context seam methods), not built.** Rationale: the spec's Out-of-Scope forbids building the presentation model here; story 7 asks the exploration to DESIGN it so tabs are not baked out. This design is a proposal the build spec adopts and may revise; it is not a pinned interface. It touches the `Renderer` seam (would make its methods per-context) and the `Toolkit` seam (`embedView` selects the presented context), which is why it is flagged for the build spec to ratify rather than silently assumed.
