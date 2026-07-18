# wezig iOS shell

The iOS side of the mobile shell (spec `build-mobile-shell`, stories 1/3/4/5/6/7;
tasks `ios-shell-xcode-project` + `mobile-verify-legs-real-app`): a REAL,
maintainable **Xcode project** (`App/WezigShell.xcodeproj`) whose root
`UIViewController` hosts the mobile `Renderer` (`WKWebView`) + `ChromeSurface`
driven by the shared mobile chrome (`MobileChrome`), with a URL field +
back/forward toolbar and background→foreground page-state restoration — the
mobile equivalent of the desktop `zig build shell` app. The Zig static lib is
built as a **normal Xcode build phase** (not a bespoke `swiftc` script);
Simulator-only + unsigned (signing is Slice C).

> **The seam proofs run against the REAL app now.** The narrowest-case
> exploration SPIKES (the standalone `swiftc`-assembled `*-proof.sh` +
> `Sources/*Proof.swift` binaries) have been REMOVED (task
> `mobile-verify-legs-real-app`). Every seam proof now runs against the
> maintained app: the renderer RUN proof + the story-4 state-restoration
> assertion are the app's `--wezig-verify` self-check (`ShellVerify.swift`,
> driven by the `mobile-verify` → `ios-shell` leg); the embedding + bridge +
> scheme seam proofs are folded into the app's **XCTest target**
> (`App/Tests/*.swift`, driven by `mobile-verify` → `ios-seam-proofs` via
> `xcodebuild test`). This mirrors the Android side, where the seam proofs are
> instrumented tests in the real app module's test target.

## The real app (`App/`)

- `App/WezigShell.xcodeproj` — the Xcode project. A pre-build **"Build Zig static
  lib" phase** (`App/build-zig-lib.sh`) cross-compiles `libwezig_mobile.a` for
  the SDK/arch Xcode is building (via `zig build ios-lib`, ReleaseSafe+strip) and
  the Swift target `-force_load`s it. No signing. The project has two targets: the
  `WezigShell` app and the `WezigShellTests` XCTest bundle (the folded seam proofs).
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

## The seam proofs, folded into the app's XCTest target (`App/Tests/`)

The embedding + script-message-bridge + custom-scheme seam proofs (ADR-0009's
Q3/story-6 + story-8 + story-9 seam-parity proofs) run as XCTest cases in the
`WezigShellTests` bundle, hosted by the real `WezigShell` app and compiled +
linked by the real Xcode project (its "Build Zig static lib" phase). They drive
the SAME already-exported proof C-ABI (`wezig_ios_embed_proof_*`,
`wezig_ios_bridge_proof_*`, `wezig_ios_scheme_proof_*`, retained in
`libwezig_mobile.a` via `root.zig`'s comptime keep) the removed spikes drove —
so no assertion is lost, just repointed at the maintained build.

- `App/Tests/EmbeddingProofTests.swift` — a mobile chrome-surface `embedView`s
  the renderer's `WKWebView` view (carried across the seam as the OPAQUE
  `ViewHandle`) into a container; asserts the webview's superview is the seam
  container (hosted THROUGH the seam) AND a non-blank `WKWebView.takeSnapshot`.
  The sole WKWebView/UIKit toucher for the embedding proof.
- `App/Tests/BridgeProofTests.swift` — round-trips ONE message BOTH ways through
  the seam over a `WKWebView` (`window.wezig.ping` page→native, native→page
  reply). The sole `WKUserContentController`/`WKScriptMessageHandler` toucher.
- `App/Tests/SchemeProofTests.swift` — serves ONE `wezig-test://hello` request
  from native through the seam, demonstrating the iOS ORDERING CONSTRAINT (the
  `WKURLSchemeHandler` is installed on the config BEFORE the webview is created).
  The sole `WKURLSchemeHandler` toucher.
- `App/Tests/ProofTestSupport.swift` — shared helpers (a key window the
  WKWebView-hosting proofs attach to so the webview renders; the non-blank pixel
  scan).
- `App/Tests/Info.plist` — the test bundle Info.plist.
- `mobile/ios/seam-proofs.sh` — the CI/local driver: `xcodebuild test` the real
  project on an iOS 17 Simulator and assert the XCTest suite passes.

The seam-CONTRACT portion of every hook (the bridge round-trip, the scheme serve,
the embed forward — reaching the ops table + re-entering the seam) still runs
HEADLESSLY in `zig build test` via the `Fake*` platforms; these XCTest cases are
the REAL end-to-end proofs, kept OUT of `zig build test` (ADR-0007).

### FINDING — the iOS scheme-registration ordering constraint

A `WKURLSchemeHandler` MUST be set on the `WKWebViewConfiguration` BEFORE the
`WKWebView` is created (the view copies its config at init; a handler added
afterwards is ignored). This is the ONE ordering constraint the iOS scheme hook
has that WebKitGTK and Android do not, surfaced at the seam in
`src/ios_webview_renderer.zig`'s module doc and demonstrated explicitly in
`App/Tests/SchemeProofTests.swift` (and honoured by the real app's
`WKWebViewBackend`). Recorded in
`work/notes/findings/ios-wkurlschemehandler-registration-ordering-2026-07-18.md`
and fed to `explore-web3-capabilities` + ADR-0005/0007 (relevant to `ipfs://`).

## What this proves (and what it does NOT)

- **Proves:** Zig cross-compiles the `wezig` core (including its `stb_truetype`
  C dep) to `aarch64-ios-simulator` and links into a real app; Swift calls a Zig
  `export fn` through the C-ABI header; the app launches on an iOS 17 Simulator
  on a `macos-14` runner; the renderer + embedding + bridge + scheme seams and
  background→foreground state restoration all work against the maintained app.
- **Does NOT:** ship a device/App-Store build. The **Simulator needs NO code
  signing and NO Apple Developer account** — this shell adds none. Device/store
  signing is out of scope (a follow-on build spec).

## Toolchain facts (pinned)

- **CI is the Mac.** Verified on GitHub `macos-14` (Apple Silicon). No physical
  Mac is needed; iterate via `gh run view`.
- **Runner ceiling: Xcode 15.4 ⇒ iOS SDK caps at 17.** So we build+run against an
  **iOS 17 Simulator** (the newest runtime guaranteed present on the runner with
  no extra download). The **deployment-target floor is iOS 16.0**.
- **Zig target triples:** `aarch64-ios-simulator` (exercised) and `aarch64-ios`
  (device build proven to compile; not run).
- **The C-libc gap:** `stb_truetype` needs the iOS SDK's `math.h`, which Zig does
  not bundle. The build points Zig's C compile at the SDK sysroot via
  `zig build ios-lib -Dmobile-target=aarch64-ios-simulator -Dmobile-sysroot="$(xcrun --sdk iphonesimulator --show-sdk-path)"`.

## Verification legs (which workflow runs what, and when)

Two distinct triggers, mirroring how the desktop keeps its fast gate separate
from the expensive Xvfb `shell-*` proofs (ADR-0007):

- **`mobile-ios` (`.github/workflows/mobile-ios.yml`) — the fast BUILD leg, on
  the hot path.** `workflow_dispatch` + a path-filtered `push`. Builds the REAL
  Xcode project and proves the Zig→iOS cross-link + that the WKWebView shell app
  LAUNCHES (`build-and-run.sh`). Cheap enough to run whenever the mobile iOS
  surface changes.
- **`mobile-verify` (`.github/workflows/mobile-verify.yml`) — the dedicated RUN
  legs, OFF the hot path.** `workflow_dispatch` + a nightly `schedule` (NOT
  per-push). `ios-shell` runs `shell-verify.sh` (renderer navigate + `.finished`
  + non-blank + background→foreground state restoration, against the real app);
  `ios-seam-proofs` runs `seam-proofs.sh` (the embedding + bridge + scheme XCTest
  cases against the real app). Read a run with
  `gh run list --workflow mobile-verify.yml` → `gh run view <id> --log`.

The core `zig build test` gate stays device-free — no simulator dependency leaks
into it; only the `Fake*`/seam-contract tests run there.
