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

## Outcome (pinned toolchain — proven green in CI)

Proven on the `mobile-android` CI leg (`.github/workflows/mobile-android.yml`, `ubuntu-latest`): the `wezig` Zig static lib — including its `stb_truetype` C dep — cross-links for both ABIs against the NDK sysroot, packages into a debug APK that carries `libwezigshell.so` for both ABIs (JNI shim statically linking the Zig core), and the APK is uploaded as an artifact.

Pinned facts (also in `mobile/android/README.md`):

- **NDK:** r26d (`26.3.11579264`); LLVM sysroot. Provisioned via `android-actions/setup-android` + `sdkmanager` in CI; user-local (no root) locally.
- **Zig target triples:** `aarch64-linux-android.26`, `x86_64-linux-android.26` (`.26` = API-level floor).
- **The C-libc gap + fix:** `stb_truetype` needs bionic's `<math.h>` (`<sysroot>/usr/include`) AND arch headers `<asm/*>` (`<sysroot>/usr/include/<triple>`). Wired via `zig build android-lib -Dmobile-sysroot=<sysroot> -Dmobile-sysroot-arch-include=<triple>` (added to `build.zig`).
- **UBSan:** the vendored stb C source is compiled `-fno-sanitize=undefined` for mobile (the mobile SDKs don't ship the `__ubsan_handle_*` runtime for static linking).
- **Export retention:** the mobile C-ABI (`src/mobile_abi.zig`) `export fn`s are force-kept via a `comptime { _ = mobile_abi; }` in `root.zig`, else a non-test lib build GCs them.
- **Division of labour:** Zig owns the portable core (static `.a`); NDK/CMake links it into `libwezigshell.so` behind a JNI shim; Gradle owns packaging. AGP 8.5.2 / Gradle 8.7 / minSdk 26 / compileSdk 34; ABIs arm64-v8a + x86_64.
- **Emulator RUN** is delegated to `mobile-verification-legs-ci` (KVM Linux runner); this task's floor — an installable APK — is met.

## Blocked by

- None — can start immediately. (Independent of the Toolkit split; touches new mobile/ files, not the desktop shell.)

## Prompt

> Goal: pin the Zig→Android toolchain (spec `explore-mobile-shell`, Q2/stories 1,3). DECIDED approach (spec Resolved decisions §Q2): Zig builds a STATIC LIBRARY; a thin Gradle/NDK shell project hosts it and drives an `android.webkit.WebView` via a small JNI shim. Zig owns the portable core; the Android toolchain owns packaging.
>
> Known ground truth to build on (proven before tasking): the pure-Zig `wezig` library already cross-compiles to `aarch64-linux-android` and `x86_64-linux-android` with `zig build-obj`/`build-lib` and NO NDK. The single gap is that the `stb_truetype` C dependency needs Android's bionic libc headers (`math.h` etc.) from the NDK sysroot — install the NDK and wire its sysroot into the C compile to close it. Floor: Android API 26; ABIs arm64-v8a (device) + x86_64 (emulator).
>
> Keep everything additive and out of the desktop path: new mobile/shell files, no change to the desktop `build.zig` shell steps or the `zig build test` gate. Record the pinned toolchain (NDK version, target triples, Gradle↔Zig↔JNI wiring) durably. Vocabulary/context: `CONTEXT.md` (C-library-binding strategy), `build.zig.zon` (the SDL-from-source precedent for a pinned external dep), the spec. This is exploration on the narrowest real case — one WebView launching from a Zig-hosted APK — not a full Android app. "Done" = the wezig lib + C dep link for both ABIs against the NDK, a minimal APK loads the lib and shows one WebView, and the toolchain is written down.
