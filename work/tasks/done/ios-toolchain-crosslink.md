---
title: Pin the Zig→iOS toolchain — static lib into a minimal Xcode/WKWebView app on the Simulator
slug: ios-toolchain-crosslink
spec: explore-mobile-shell
blockedBy: [mobile-toolkit-seam-split]
covers: [1, 2]
---

## What to build

Prove and pin the Zig→iOS build path (spec Q2/stories 1,2): the `wezig` Zig library cross-compiles to the iOS simulator target and links into a minimal Xcode/SwiftPM app that shows one `WKWebView`, launched on the iOS Simulator via `xcrun simctl` — all on a GitHub `macos-14` runner (no physical Mac needed; CI is the Mac).

Already de-risked (see the `mobile-smoke` workflow run): the `macos-14` runner ships Xcode 15.4 + iOS 17 simulator runtimes, `simctl` boots a simulator headlessly, and Zig cross-compiles a C-ABI static lib to `aarch64-ios-simulator` (`current ar archive`). This task turns that PoC into a real minimal app.

Scope (narrowest real case): a minimal Xcode/SwiftPM target that links the Zig static lib (Zig `export fn` over a C-ABI header, imported into Swift), owns Info.plist + a `WKWebView`, and shows one webview. Floor: iOS 16.0 deployment target; run on an iOS 17 simulator (newest runtime guaranteed present on the runner without an extra download — record this so no one trips on the SDK/runtime ceiling). NO code signing / Apple Developer account: the Simulator needs none (device/store signing is out of scope — a follow-on build spec).

## Acceptance criteria

- [ ] The `wezig` library cross-compiles to `aarch64-ios-simulator` (and `aarch64-ios` for device builds, even if only the simulator is exercised here).
- [ ] A minimal Xcode/SwiftPM app links the Zig static lib via a C-ABI header (Swift calls at least one Zig `export fn`) and hosts one `WKWebView`.
- [ ] The app builds and launches on an iOS 17 Simulator on a `macos-14` runner, driven by `xcrun simctl` (boot → install → launch), asserted GREEN in a CI job authored for this task.
- [ ] The iOS deployment-target floor (16.0) and the simulator-runtime used (17.x) + the reason (Xcode 15.4 SDK ceiling on the runner) are written down (done-record / mobile ADR).
- [ ] No signing / no Apple Developer account is required (Simulator only); this is stated explicitly.
- [ ] The desktop v0 gate is untouched; the new iOS CI job is a DEDICATED leg (not folded into `zig build test`), mirroring how the webview proofs are kept separate.

## Blocked by

- `mobile-toolkit-seam-split` (the iOS shell hosts the chrome-surface half of the split `Toolkit`; build on the settled seam shape, not the pre-split one).

## Prompt

> Goal: pin the Zig→iOS toolchain (spec `explore-mobile-shell`, Q2/stories 1,2). DECIDED approach (spec Resolved decisions §Q2): Zig builds a STATIC LIBRARY; a thin Xcode/SwiftPM app hosts it and drives a `WKWebView`; Zig↔Swift over a C-ABI header (Zig `export fn`). The OS toolchain owns Info.plist/entitlements/signing; Zig owns the portable core.
>
> You do NOT need a physical Mac: author a CI job on `runs-on: macos-14` and iterate via `gh run view` (this is how the whole iOS line is verified). Proven ground truth (the `mobile-smoke` workflow): macos-14 ships Xcode 15.4 + iOS 17 simulator runtimes; `xcrun simctl bootstatus` boots a simulator headlessly; `zig build-lib -target aarch64-ios-simulator` produces a real static archive. IMPORTANT runner ceiling: Xcode 15.4 ⇒ iOS SDK caps at 17, so target an iOS 17 SIMULATOR (deployment-target floor stays 16.0). Simulator builds need NO code signing and NO Apple Developer account — do not add any; device/store signing is out of scope (a follow-on build spec).
>
> Keep it additive: new iOS shell files + a dedicated iOS CI job; do not touch the desktop `build.zig` shell steps or the `zig build test` gate. Build on the settled split-`Toolkit` shape from `mobile-toolkit-seam-split` (the iOS shell hosts the chrome-surface half; the OS is the host/loop). Record the deployment floor, the simulator runtime used, and the no-signing fact. Context: `CONTEXT.md`, the spec, the two-seams ADR (ADR-0006), the `mobile-smoke` workflow as the PoC. Exploration on the narrowest case — one WKWebView launching from a Zig-hosted app on the Simulator — not a full iOS app. "Done" = the wezig lib links into a minimal WKWebView app that launches green on an iOS 17 simulator in CI, with the toolchain + floor written down.
