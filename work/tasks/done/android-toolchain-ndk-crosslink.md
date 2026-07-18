---
title: Pin the Zig→Android toolchain — NDK cross-link of the wezig library (both ABIs)
slug: android-toolchain-ndk-crosslink
spec: explore-mobile-shell
blockedBy: []
covers: [1, 3]
---

## What to build

Prove and pin the Zig→Android build path (spec Q2/stories 1,3): the `wezig` Zig library — INCLUDING its `stb_truetype` C dependency — cross-compiles and links for the Android ABIs against the NDK sysroot, packaged into a minimal Android shell that launches an `android.webkit.WebView` on a device/emulator.

Already de-risked (see `work/notes/findings/` if captured, and the spec's Q2 decision): the PURE-Zig library cross-compiles to `aarch64-linux-android` / `x86_64-linux-android` with no NDK; the ONLY thing needing the NDK is the C dep's Android/bionic libc headers (e.g. `math.h`). So this task installs the NDK, wires its sysroot into the C compile, and stands up the thin Gradle/NDK shell.

Scope (narrowest real case): a minimal Gradle project + JNI shim that loads the Zig static lib and shows ONE `WebView`. Floor: Android API 26, ABIs arm64-v8a + x86_64 (x86_64 for the emulator). The Zig static-lib + a small C-ABI/JNI surface is the division of labour (Zig owns the portable core; Gradle/NDK owns packaging).

## Acceptance criteria

- [ ] The NDK is provisioned (user-local; no root) and its path recorded so the build is reproducible in CI and locally.
- [ ] The `wezig` library + its `stb_truetype` C dep cross-compile and link for BOTH `aarch64-linux-android` and `x86_64-linux-android` (the C `math.h`/bionic-header gap is resolved via the NDK sysroot).
- [ ] A minimal Gradle/NDK shell project builds an APK that loads the Zig static lib via a small JNI shim and displays one `android.webkit.WebView`.
- [ ] The APK launches and shows the WebView on an x86_64 emulator OR is proven building in CI (the emulator RUN proof may be delegated to the CI verification-legs task; this task's floor is: it BUILDS to an installable APK).
- [ ] The pinned toolchain path (NDK version, ABIs, Zig target triples, the Gradle↔Zig↔JNI wiring) is written down (task done-record and/or the mobile ADR).
- [ ] Tests/checks mirror the repo style where applicable; the desktop v0 gate (`zig build test`) is untouched and green.

## Blocked by

- None — can start immediately. (Independent of the Toolkit split; touches new mobile/ files, not the desktop shell.)

## Prompt

> Goal: pin the Zig→Android toolchain (spec `explore-mobile-shell`, Q2/stories 1,3). DECIDED approach (spec Resolved decisions §Q2): Zig builds a STATIC LIBRARY; a thin Gradle/NDK shell project hosts it and drives an `android.webkit.WebView` via a small JNI shim. Zig owns the portable core; the Android toolchain owns packaging.
>
> Known ground truth to build on (proven before tasking): the pure-Zig `wezig` library already cross-compiles to `aarch64-linux-android` and `x86_64-linux-android` with `zig build-obj`/`build-lib` and NO NDK. The single gap is that the `stb_truetype` C dependency needs Android's bionic libc headers (`math.h` etc.) from the NDK sysroot — install the NDK and wire its sysroot into the C compile to close it. Floor: Android API 26; ABIs arm64-v8a (device) + x86_64 (emulator).
>
> Keep everything additive and out of the desktop path: new mobile/shell files, no change to the desktop `build.zig` shell steps or the `zig build test` gate. Record the pinned toolchain (NDK version, target triples, Gradle↔Zig↔JNI wiring) durably. Vocabulary/context: `CONTEXT.md` (C-library-binding strategy), `build.zig.zon` (the SDL-from-source precedent for a pinned external dep), the spec. This is exploration on the narrowest real case — one WebView launching from a Zig-hosted APK — not a full Android app. "Done" = the wezig lib + C dep link for both ABIs against the NDK, a minimal APK loads the lib and shows one WebView, and the toolchain is written down.
