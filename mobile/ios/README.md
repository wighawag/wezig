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

## Layout

- `Sources/main.swift` — the app: a `UIApplicationDelegate` whose root
  `UIViewController` hosts one `WKWebView`, plus a call into the Zig C-ABI to
  prove linkage (logged + shown in the loaded HTML).
- `Sources/wezig_mobile.h` — the C-ABI header exposing the Zig `export fn`s;
  imported into Swift via `-import-objc-header` (a bridging header).
- `Info.plist` — the app bundle's Info.plist (bundle id, launch, orientations).
- `build-and-run.sh` — the CI/local driver: cross-compile the Zig static lib,
  compile Swift against the simulator SDK, assemble the `.app`, then
  boot → install → launch on an iOS 17 Simulator via `simctl`.

The `.app` is assembled by hand (swiftc + a bundle layout) rather than via a
committed `.xcodeproj`, so the proof is a single reproducible script with no
fragile project file to drift. This is the toolchain-proof shape; a real app
target can adopt an Xcode project later.
