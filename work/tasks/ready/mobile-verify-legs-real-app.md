---
title: Point the mobile-verify CI legs at the real apps + assert state restoration
slug: mobile-verify-legs-real-app
spec: build-mobile-shell
blockedBy: [android-shell-app, ios-shell-xcode-project]
covers: [7, 11]
---

## What to build

Repoint the mobile verification CI legs from the spike scripts to the REAL platform apps, and add the new background→foreground state-restoration assertion, so a regression in the maintained shell is caught (not just in the spike harness).

- **`mobile-verify.yml` (the nightly/on-demand RUN legs):** the iOS Simulator leg builds + runs the REAL Xcode/SwiftPM app (not `renderer-proof.sh`'s hand-assembled binary); the Android emulator leg builds + installs the REAL app module's APK and runs its instrumented test. Each keeps the existing assertions (navigate + a `.finished` lifecycle event reaching a seam subscriber + a non-blank snapshot) AND adds the state-restoration assertion: after a background→foreground round-trip, the current page/URL is unchanged (story 4's bar).
- **The fast per-PR build legs (`mobile-ios.yml`/`mobile-android.yml`):** build the real projects (cross-link + launch/APK), replacing the spike-script build steps.
- Keep the core `zig build test` gate device-free; the mobile RUN proofs stay OUT of it (ADR-0007 discipline).

## Acceptance criteria

- [ ] `mobile-verify.yml`'s iOS leg builds + runs the REAL iOS app (Xcode/SwiftPM) and asserts navigate + `.finished` + non-blank snapshot + page-state survives a background→foreground round-trip, green on `macos-14`.
- [ ] `mobile-verify.yml`'s Android leg builds + installs the REAL app module APK and runs the instrumented test asserting the same four things, green on a KVM x86_64 emulator.
- [ ] The fast per-PR legs (`mobile-ios.yml`/`mobile-android.yml`) build the real projects (not the spike scripts) for their cross-link/launch/APK proofs.
- [ ] The core `zig build test` gate stays device-free; the mobile RUN proofs remain OUT of it.
- [ ] The spike proof scripts/harnesses that the real app + these legs supersede are removed or clearly reduced to what still has a purpose (no dead duplicate proof path left to rot).
- [ ] CI legs are driven/verified via `gh workflow run` + `gh run view` (no physical device); the runs are green.

## Blocked by

- `android-shell-app` and `ios-shell-xcode-project` — the legs verify THOSE real apps, so both must exist first.

## Prompt

> Goal: repoint the mobile verification CI legs from the spike scripts to the REAL platform apps and add the state-restoration assertion (spec `build-mobile-shell`, stories 7/11). `mobile-verify.yml`'s iOS leg builds + runs the real Xcode/SwiftPM app; its Android leg builds + installs the real app module APK and runs its instrumented test — each asserting navigate + a `.finished` lifecycle event + a non-blank snapshot AND that a background→foreground round-trip preserves the page (story 4). The fast per-PR legs (`mobile-ios.yml`/`mobile-android.yml`) build the real projects for their cross-link/launch/APK proofs. Keep the core `zig build test` gate device-free (mobile RUN proofs stay OUT of it, ADR-0007).
>
> Read: `.github/workflows/mobile-verify.yml`, `mobile-ios.yml`, `mobile-android.yml` (the current spike-script legs); the real apps from `android-shell-app` + `ios-shell-xcode-project`; `docs/mobile-exploration-findings.md` §5 (verification strategy) + ADR-0007/0009. Remove or reduce the superseded spike proof scripts so no dead duplicate proof path is left. You do NOT need a physical device: drive `macos-14` (iOS Simulator via `simctl`) and the KVM Linux emulator (Android `connectedAndroidTest`) via `gh workflow run` + `gh run view`, iterating until green. "Done" = both `mobile-verify` legs run the REAL apps and assert navigate + finished + non-blank + state-restoration green, the fast legs build the real projects, the core gate stays device-free, and dead spike proof paths are cleaned up.
