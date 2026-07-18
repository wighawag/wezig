---
title: Dedicated mobile verification CI legs (iOS Simulator on macOS, Android emulator on KVM Linux)
slug: mobile-verification-legs-ci
spec: explore-mobile-shell
blockedBy: [android-renderer-backend-oneshot, ios-renderer-backend-oneshot]
covers: [10]
---

## What to build

Stand up the scriptable, device-free mobile verification legs (spec Q6/story 10) that prove the mobile seam end-to-end WITHOUT a physical device, kept OUT of the display-free `zig build test` gate — mirroring how the desktop webview proofs live only in the Xvfb `shell-*` steps.

- **iOS leg** (`runs-on: macos-14`): boot an iOS 17 Simulator via `xcrun simctl`, build + install the iOS spike app, drive it, and assert navigate + a `finished` lifecycle event + a non-blank `takeSnapshot`.
- **Android leg** (`runs-on: ubuntu-latest`, KVM-accelerated): boot a headless x86_64 emulator (`-no-window`) via `avdmanager`/`emulator` (or a maintained emulator action), install the APK via `adb`, run an instrumented test asserting the same three things.

Both are DEDICATED legs, run on-demand / nightly (NOT on every PR) to control cost (iOS uses macOS runner minutes; free+unlimited on this public repo, but slower). The core `zig build test` gate stays device-free — only the `Fake*` seam contracts run there.

## Acceptance criteria

- [ ] An iOS CI job on `macos-14` boots an iOS 17 simulator, installs + launches the iOS spike, and asserts navigate + finished-event + non-blank snapshot; green.
- [ ] An Android CI job on `ubuntu-latest` boots a headless KVM-accelerated x86_64 emulator, installs the APK, and asserts navigate + finished-event + non-blank via an instrumented test; green.
- [ ] Both legs are triggered on-demand / nightly (e.g. `workflow_dispatch` + `schedule`), NOT on every push, and are documented as the mobile analogue of the desktop Xvfb `shell-*` steps.
- [ ] The core `zig build test` gate stays device-free and green (no simulator/emulator dependency leaks into it).
- [ ] The leg definitions + how to run/read them are written down (workflow comments + done-record).

## Blocked by

- `android-renderer-backend-oneshot` and `ios-renderer-backend-oneshot` (the legs RUN those backends' one-page proofs; they need something real to drive).

## Prompt

> Goal: build the dedicated mobile verification CI legs (spec `explore-mobile-shell`, Q6/story 10) — the mobile analogue of the desktop Xvfb `shell-test`/`shell-bridge-test`/`shell-scheme-test` steps — proving the mobile seam end-to-end with no physical device, kept OUT of `zig build test`. DECIDED shape (spec Resolved decisions §Q6): iOS on `macos-14` via `xcrun simctl` (iOS 17 simulator); Android on `ubuntu-latest` via a KVM-accelerated headless x86_64 emulator + `adb` + an instrumented test. Each asserts the same three things as the desktop smoke: navigate + a `.finished` lifecycle event + a non-blank snapshot.
>
> Run these on-demand / nightly (`workflow_dispatch` + `schedule`), NOT per-PR — iOS uses macOS runner minutes (free+unlimited on this public repo, but slower), so keep them off the hot path. The core `zig build test` gate MUST stay device-free (only `Fake*` seam contracts there). You author + iterate the workflows via `gh run view` (the `mobile-smoke` workflow is your reference PoC for both the macOS simctl path and the Linux Android path). Ground truth: GitHub Linux runners provide KVM (this is why the Android emulator runs in CI though it can't on the Hetzner box); macos-14 provides Xcode 15.4 + iOS 17 simulators.
>
> Read: `.github/workflows/ci.yml` (the Xvfb webview leg is the pattern to mirror), the `mobile-smoke` workflow (the proven macOS + Android CI paths), the iOS/Android backend tasks (what the legs drive), the spec's Q6 decision. "Done" = both mobile legs are green (iOS simulator + Android emulator, each asserting navigate/finished/non-blank), triggered nightly/on-demand, documented, with the core gate still device-free."
