# wezig iOS shell (toolchain proof)

The narrowest-real-case iOS shell for the `explore-mobile-shell` exploration
(task `ios-toolchain-crosslink`, spec Q2/stories 1,2): a minimal app that links
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

## Layout

- `Sources/main.swift` — the toolchain shell app: a `UIApplicationDelegate` whose
  root `UIViewController` hosts one `WKWebView`, plus a call into the Zig C-ABI to
  prove linkage (logged + shown in the loaded HTML).
- `Sources/RendererProof.swift` — the Renderer-backend proof app (story 4): owns
  the `WKWebView` + `WKNavigationDelegate`, drives one page through the pinned
  seam via the Zig backend, and asserts finished + non-blank snapshot. The sole
  WKWebView toucher for the backend.
- `Sources/wezig_mobile.h` — the C-ABI header exposing the Zig `export fn`s (the
  mobile ABI + the Renderer-proof thunks); imported into Swift via
  `-import-objc-header` (a bridging header).
- `Info.plist` — the app bundle's Info.plist (bundle id, launch, orientations);
  the proof reuses it with the executable/bundle-id rewritten.
- `build-and-run.sh` — the toolchain-shell CI/local driver: cross-compile the Zig
  static lib, compile Swift against the simulator SDK, assemble the `.app`, then
  boot → install → launch on an iOS 17 Simulator via `simctl`.
- `renderer-proof.sh` — the Renderer-backend proof driver: same build shape, but
  launches `RendererProof.swift` and asserts the seam PASS line (navigate +
  finished + non-blank snapshot).

The `.app` is assembled by hand (swiftc + a bundle layout) rather than via a
committed `.xcodeproj`, so the proof is a single reproducible script with no
fragile project file to drift. This is the toolchain-proof shape; a real app
target can adopt an Xcode project later.

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
