---
title: Build the release mobile artifacts from the real apps (APK + iOS Simulator app)
slug: mobile-release-artifacts-real-app
spec: build-mobile-shell
blockedBy: [android-shell-app, ios-shell-xcode-project]
covers: [12]
---

## What to build

Repoint the release-workflow mobile artifact jobs from the spike scripts to the REAL platform apps, so the downloadable GitHub Release artifacts track the maintained shell (not the bespoke spike build).

- **`android-apk` job:** builds the REAL Android app module's (unsigned-debug) APK and uploads `wezig_<tag>_android_debug_unsigned.apk`, replacing the `build-zig-libs.sh` + bare-Gradle spike path.
- **`ios-simulator-app` job:** builds the REAL Xcode/SwiftPM app's Simulator `.app`, zips it, and uploads `wezig_<tag>_ios-simulator_app.zip`, replacing the `build-and-run.sh` `BUILD_ONLY` path.
- Both stay UNSIGNED / Simulator-only (signing + store delivery are Slice C, `deliver-mobile-signing-and-store`) and keep their clear labelling (the iOS artifact is a SIMULATOR app, not a device build).

## Acceptance criteria

- [ ] The `android-apk` release job builds the REAL app module's unsigned-debug APK (both ABIs) and uploads it to the release, replacing the spike build path.
- [ ] The `ios-simulator-app` release job builds the REAL Xcode/SwiftPM app's Simulator `.app`, zips it, and uploads it, replacing the spike build path.
- [ ] Both artifacts stay unsigned / Simulator-only and keep their explicit labels (no implication of a device/store build).
- [ ] The desktop goreleaser job is unaffected; the release workflow still cuts on a version tag and attaches all artifacts to the one release.
- [ ] Verified end-to-end by cutting a test tag (or a dry-run/`workflow_dispatch` equivalent) and confirming the real-app artifacts attach and download as valid packages, via `gh release view` / `gh run view`.

## Blocked by

- `android-shell-app` and `ios-shell-xcode-project` — the jobs build THOSE real apps, so both must exist first.

## Prompt

> Goal: repoint the release-workflow mobile artifact jobs from the spike scripts to the REAL platform apps (spec `build-mobile-shell`, story 12), so the downloadable GitHub Release artifacts track the maintained shell. The `android-apk` job builds the real app module's unsigned-debug APK; the `ios-simulator-app` job builds the real Xcode/SwiftPM app's Simulator `.app`, zips it. Both stay UNSIGNED / Simulator-only (signing + store delivery are Slice C) and keep their clear labels (the iOS artifact is a SIMULATOR app).
>
> Read: `.github/workflows/release.yml` (the current `android-apk` + `ios-simulator-app` jobs driven by `build-zig-libs.sh` / `build-and-run.sh`); the real apps from `android-shell-app` + `ios-shell-xcode-project`; `CONTEXT.md` § Releasing. Verify end-to-end by cutting a test tag (or a `workflow_dispatch` equivalent) and confirming the real-app artifacts attach + download as valid packages via `gh release view` / `gh run view`. Keep the desktop goreleaser job unaffected. "Done" = the release jobs build the mobile artifacts from the real apps, attach them to the release unsigned/Simulator-labelled, and a test-tag run confirms valid downloadable packages.
