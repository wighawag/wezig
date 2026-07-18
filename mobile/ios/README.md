# wezig iOS shell

The iOS side of the mobile shell (spec `build-mobile-shell`, stories 1/3/4/5/6;
task `ios-shell-xcode-project`): a REAL, maintainable **Xcode project**
(`App/WezigShell.xcodeproj`) whose root `UIViewController` hosts the mobile
`Renderer` (`WKWebView`) + `ChromeSurface` driven by the shared mobile chrome
(`MobileChrome`), with a URL field + back/forward toolbar and
background→foreground page-state restoration — the mobile equivalent of the
desktop `zig build shell` app. The Zig static lib is built as a **normal Xcode
build phase** (not a bespoke `swiftc` script); Simulator-only + unsigned
(signing is Slice C).

> **The real app vs the proof harnesses.** `App/` is the real app the CI BUILD
> leg (`mobile-ios`) and the SHELL verify leg (`mobile-verify` → `ios-shell`)
> drive, and the release `ios-simulator-app` job packages. The `Sources/*Proof.swift`
> files remain the narrowest-case exploration SPIKES (renderer / embedding /
> bridge / scheme), each still built by its own dedicated `*-proof.sh` script +
> `mobile-verify` leg — they are single-fact proofs, not the app.

## The real app (`App/`)

- `App/WezigShell.xcodeproj` — the Xcode project. A pre-build **"Build Zig static
  lib" phase** (`App/build-zig-lib.sh`) cross-compiles `libwezig_mobile.a` for
  the SDK/arch Xcode is building (via `zig build ios-lib`, ReleaseSafe+strip) and
  the Swift target `-force_load`s it. No signing.
- `App/Sources/AppDelegate.swift` — the app entry; retains the window +
  controller for the app's lifetime (host-only lifecycle).
- `App/Sources/WKWebViewShellController.swift` — the root `UIViewController`: URL
  field + back/forward toolbar + content container. Constructs the shared mobile
  chrome over the two seams via `wezig_ios_shell_start` and drives navigation
  ONLY through the shell C-ABI (the chrome/seams) — never a raw `WKWebView` call.
  Background→foreground restoration is HOST-ONLY (ADR-0010): the native
  `WKWebView` state save-restore + the existing navigate op; no seam method added.
- `App/Sources/WKWebViewBackend.swift` — **the sole `WKWebView`/WebKit toucher**
  for the app: owns the `WKWebView`, its `WKNavigationDelegate`, the marker-scheme
  `WKURLSchemeHandler`, and the C-ABI ops tables. Installs the marker scheme
  handler on the `WKWebViewConfiguration` **BEFORE** the `WKWebView` is created
  (the iOS ordering constraint — the finding), so the scheme set is threaded into
  the config at build time even though the shell registers only the trivial
  `wezig://` marker.
- `App/Sources/ShellVerify.swift` — the REAL-app self-check the `mobile-verify`
  `ios-shell` leg drives under `--wezig-verify`: navigate THROUGH the seams + a
  `.finished` event reaching the chrome + a non-blank snapshot + a
  background→foreground round-trip that preserves the page (story 4).
- `App/Info.plist` — the app bundle Info.plist.
- `mobile/ios/build-and-run.sh` — builds the real project via `xcodebuild`
  (running the Zig-lib build phase), then boots → installs → launches on an iOS
  17 Simulator; `BUILD_ONLY=1` stops after the `.app` (the release packaging
  path). `mobile/ios/shell-verify.sh` builds the same app and runs the
  `--wezig-verify` self-check.

## The exploration spike proofs (`Sources/`, historical)

The narrowest-real-case exploration proofs for `explore-mobile-shell`
(`ios-toolchain-crosslink` / story 4 / Q3 / stories 8,9): a minimal app that links
the wezig Zig **static library** over a C-ABI header and shows one `WKWebView`,
launched on the iOS **Simulator** via `xcrun simctl`.

## What this proves (and what it does NOT)

- **Proves:** Zig cross-compiles the `wezig` core (including its `stb_truetype`
  C dep) to `aarch64-ios-simulator` and links into a real app; Swift calls a Zig
  `export fn` (`wezig_abi_version()` / `wezig_greeting()`) through the C-ABI
  header; the app launches on an iOS 17 Simulator on a `macos-14` runner.
- **Does NOT:** ship a device/App-Store build. The **Simulator needs NO code
  signing and NO Apple Developer account** — this shell adds none. Device/store
  signing is out of scope (a follow-on build spec).

## Toolchain facts (pinned)

- **CI is the Mac.** Verified on GitHub `macos-14` (Apple Silicon). No physical
  Mac is needed; iterate via `gh run view`.
- **Runner ceiling: Xcode 15.4 ⇒ iOS SDK caps at 17.** So we build+run against an
  **iOS 17 Simulator** (the newest runtime guaranteed present on the runner with
  no extra download). The **deployment-target floor is iOS 16.0**.
- **Zig target triples:** `aarch64-ios-simulator` (exercised here) and
  `aarch64-ios` (device build proven to compile; not run).
- **The C-libc gap:** `stb_truetype` needs the iOS SDK's `math.h`, which Zig does
  not bundle. The build points Zig's C compile at the SDK sysroot via
  `zig build ios-lib -Dmobile-target=aarch64-ios-simulator -Dmobile-sysroot="$(xcrun --sdk iphonesimulator --show-sdk-path)"`.

## The Renderer-backend proof (task `ios-renderer-backend-oneshot`, story 4)

On top of the toolchain shell, a second proof drives ONE real page THROUGH the
pinned `Renderer` seam over a `WKWebView` — the iOS twin of the desktop
`zig build shell-test`. It asserts the three story-4 facts: navigate + a
`.finished` lifecycle event reaching a seam subscriber + a non-blank
`WKWebView.takeSnapshot`.

- **The backend is Zig** (`src/ios_webview_renderer.zig`, `IosWebviewRenderer`):
  it satisfies the SAME pinned `Renderer` VTable the desktop `SystemWebviewRenderer`
  does. Because the pinned iOS toolchain has Swift own the `WKWebView` and Zig own
  the core over a C-ABI, this backend reaches the webview through a **C-ABI
  ops-table** (`WkPlatform`) the Swift shell installs, and the `WKNavigationDelegate`
  callbacks flow back into it (mapped to the seam's `LifecycleEvent`s). `view()`
  returns the `WKWebView`'s `UIView*` as the opaque `ViewHandle` (the Q3 decision).
- **`Sources/RendererProof.swift` is the ONLY WKWebView/UIKit toucher** for the
  backend: it owns the `WKWebView` + delegate, builds the ops table, relays the
  nav-delegate callbacks into the seam, and does the platform-only snapshot scan.
  Everything above the seam stays backend-agnostic.
- The seam-CONTRACT tests (the backend maps a nav-delegate sequence to a
  `.finished` seam event, headless, no WKWebView) run in `zig build test`; the
  REAL end-to-end proof runs on the dedicated `mobile-verify` workflow's
  `ios-simulator` leg on a macos-14 iOS 17 Simulator (kept OUT of `zig build
  test`, per spec Q6 / ADR-0007), which runs `renderer-proof.sh` NIGHTLY +
  on-demand (NOT per-push — see "Verification legs" below).

## The two web3-hook proofs (task `mobile-web3-hooks-parity`, stories 8,9)

Two further proofs drive the two web3-load-bearing `Renderer` hooks THROUGH the
pinned seam over a `WKWebView`, the iOS twins of the desktop
`shell-bridge-test` / `shell-scheme-test`:

- **script-message bridge (story 8)** — `Sources/BridgeProof.swift`: injects
  `window.wezig.ping` via a `WKUserScript` on the `WKUserContentController`,
  registers the `wezig` channel via a `WKScriptMessageHandler`, loads a page that
  posts `ping-from-page` (page->native leg), and native evaluates a reply that
  re-posts `pong-from-native` (native->page leg). Both legs seen == PASS.
  `WKScriptMessageHandler.didReceive` fires on the main queue, so — unlike
  Android — no thread marshalling is needed. Driven by `bridge-proof.sh`
  (`ios-bridge-proof` CI leg).
- **custom-scheme interception (story 9)** — `Sources/SchemeProof.swift`:
  registers `wezig-test://` via a `WKURLSchemeHandler` on the
  `WKWebViewConfiguration` **BEFORE the `WKWebView` is created** (the iOS
  ordering constraint — see the finding below), navigates `wezig-test://hello`,
  and serves a native body whose marker `<title>` reaching the seam proves it
  served AND rendered. Driven by `scheme-proof.sh` (`ios-scheme-proof` CI leg).

The seam-CONTRACT portion of both hooks (the bridge round-trip + the scheme
serve, reaching the ops table + re-entering the seam) runs headlessly in
`zig build test` via the fake `WkPlatform`; the real end-to-end proofs are the
two new `macos-14` CI legs, kept OUT of `zig build test` (spec Q6 / ADR-0007).

### FINDING — the iOS scheme-registration ordering constraint

A `WKURLSchemeHandler` MUST be set on the `WKWebViewConfiguration` BEFORE the
`WKWebView` is created (the view copies its config at init; a handler added
afterwards is ignored). This is the ONE ordering constraint the iOS scheme hook
has that WebKitGTK and Android do not, surfaced at the seam in
`src/ios_webview_renderer.zig`'s module doc and demonstrated explicitly in
`SchemeProof.swift`. Recorded in
`work/notes/findings/ios-wkurlschemehandler-registration-ordering-2026-07-18.md`
and fed to `explore-web3-capabilities` + ADR-0005/0007 (relevant to `ipfs://`).

## Layout (the spike proofs)

- `Sources/RendererProof.swift` — the Renderer-backend proof app (story 4): owns
  the `WKWebView` + `WKNavigationDelegate`, drives one page through the pinned
  seam via the Zig backend, and asserts finished + non-blank snapshot. The sole
  WKWebView toucher for the backend.
- `Sources/wezig_mobile.h` — the C-ABI header exposing the Zig `export fn`s (the
  mobile ABI + the Renderer-proof thunks); imported into Swift via
  `-import-objc-header` (a bridging header).
- `Info.plist` — the shared spike-proof Info.plist (the proof scripts reuse it
  with the executable/bundle-id rewritten). The real app uses `App/Info.plist`.
- `build-and-run.sh` — the REAL-app CI/local driver: `xcodebuild` builds
  `App/WezigShell.xcodeproj` (running the Zig-lib build phase), then boots →
  installs → launches on an iOS 17 Simulator via `simctl`.
- `renderer-proof.sh` — the Renderer-backend proof driver: same build shape, but
  launches `RendererProof.swift` and asserts the seam PASS line (navigate +
  finished + non-blank snapshot).
- `Sources/BridgeProof.swift` + `bridge-proof.sh` — the script-message bridge
  proof (story 8): the sole WKUserContentController/WKScriptMessageHandler
  toucher, round-tripping `window.wezig.ping` both ways through the seam.
- `Sources/SchemeProof.swift` + `scheme-proof.sh` — the custom-scheme proof
  (story 9): the sole WKURLSchemeHandler toucher, serving `wezig-test://hello`
  from native (handler registered on the config before the webview — the
  ordering constraint).

Each PROOF `.app` is assembled by hand (swiftc + a bundle layout) rather than via
the committed `.xcodeproj`, so each proof stays a single reproducible script with
no project file to drift — the toolchain-proof shape. The REAL app now DOES use a
committed Xcode project (`App/WezigShell.xcodeproj`, above), which builds the Zig
lib as a normal build phase; the proofs keep their standalone scripts.

## Verification legs (which workflow runs what, and when)

Two distinct triggers, mirroring how the desktop keeps its fast gate separate
from the expensive Xvfb `shell-*` proofs (spec Q6 / ADR-0007):

- **`mobile-ios` (`.github/workflows/mobile-ios.yml`) — the fast BUILD leg, on
  the hot path.** `workflow_dispatch` + a path-filtered `push`. Proves the
  Zig→iOS cross-link and that the WKWebView shell app LAUNCHES
  (`build-and-run.sh`). Cheap enough to run whenever the mobile iOS surface
  changes.
- **`mobile-verify` (`.github/workflows/mobile-verify.yml`) — the dedicated RUN
  leg, OFF the hot path.** `workflow_dispatch` + a nightly `schedule` (NOT
  per-push). Its `ios-simulator` job runs `renderer-proof.sh`: boot an iOS 17
  Simulator, install + launch the proof app, and assert the seam PASS line
  (navigate + `.finished` + non-blank `takeSnapshot`). This is the iOS analogue
  of the desktop Xvfb `shell-test` leg. Read a run with
  `gh run list --workflow mobile-verify.yml` → `gh run view <id> --log`.

The core `zig build test` gate stays device-free — no simulator dependency
leaks into it; only the `Fake*`/seam-contract tests run there.
## The ViewHandle-embedding proof (task `mobile-viewhandle-embedding-proof`, Q3/story 6)

A third proof resolves ADR-0007's flagged cross-toolkit-embedding spike on iOS: a
mobile chrome-surface `embedView`s the renderer's `WKWebView` view (carried
across the seam as the OPAQUE `ViewHandle`) and the page shows.

- **The chrome-surface is Zig** (`src/mobile_chrome_surface.zig`,
  `MobileChromeSurface`): the `ChromeSurface` half of the split `Toolkit`
  (ADR-0008) for the mobile host. Its `embedView` forwards the opaque handle
  UNCHANGED to a Swift-installed C-ABI `EmbedPlatform` op; only Swift interprets
  it as a `UIView*` (`addSubview`). So the view reaches the screen THROUGH the
  backend-agnostic seam, not a raw `addSubview` reached around it.
- **`Sources/EmbeddingProof.swift` is the sole WKWebView/UIKit toucher** for this
  proof: it owns the `WKWebView` + delegate + a container `UIView`, implements the
  embed op, and snapshots the CONTAINER (not the webview directly) to assert the
  page is visible through the embedded view.
- The seam-CONTRACT tests (the chrome-surface forwards the opaque handle to the
  embed op, headless) run in `zig build test`; the REAL end-to-end proof runs on
  the `ios-embedding-proof` CI leg (macos-14, iOS 17 simulator) via
  `mobile/ios/embedding-proof.sh`.
- **Finding:** the opaque `ViewHandle` is CONFIRMED sufficient across the mobile
  toolkit↔renderer boundary on both platforms — no typed-handle refinement needed
  (`work/notes/findings/viewhandle-crosses-mobile-toolkit-boundary-2026-07-18.md`).

- `Sources/EmbeddingProof.swift` — the embedding-proof app: owns the `WKWebView`
  + delegate + container, embeds the renderer's view via the chrome-surface seam,
  asserts finished + a non-blank container snapshot. The sole WKWebView toucher.
- `embedding-proof.sh` — the embedding-proof driver: same build shape as
  `renderer-proof.sh`, launches `EmbeddingProof.swift`, asserts the embed PASS line.
