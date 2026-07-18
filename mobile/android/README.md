# wezig Android shell (toolchain proof)

The narrowest-real-case Android shell for the `explore-mobile-shell` exploration
(task `android-toolchain-ndk-crosslink`, spec Q2/stories 1,3): a minimal Gradle
project that cross-links the wezig Zig **static library** (including its
`stb_truetype` C dep) against the **NDK sysroot** for both ABIs, packages it into
an APK via a JNI shim, and shows one `android.webkit.WebView`.

## What this proves (and what it does NOT)

- **Proves:** the pure-Zig `wezig` core cross-compiles to `aarch64-linux-android`
  and `x86_64-linux-android`, and its `stb_truetype` C dep links once the NDK
  sysroot supplies bionic's libc headers (`math.h`, `<asm/*>`); a JNI shim loads
  the Zig core and calls a Zig `export fn`; the APK builds to an installable
  artifact and shows one WebView.
- **Floor:** Android **API 26**; ABIs **arm64-v8a** (device) + **x86_64**
  (emulator). This task's floor is: it BUILDS to an installable APK. The
  on-emulator RUN proof is delegated to the CI verification-legs task
  (`mobile-verification-legs-ci`) on a KVM Linux runner.

## The C-libc gap and how it is closed (pinned)

The pure-Zig library cross-compiles to Android with **no NDK**. The single gap is
that the `stb_truetype` C dependency needs Android/bionic libc headers from the
NDK sysroot:

- `<math.h>`, `<stdlib.h>`, … live under `<sysroot>/usr/include`.
- **arch-specific** headers (`<asm/types.h>`, reached via `<linux/types.h>`) live
  under `<sysroot>/usr/include/<triple>` (e.g. `usr/include/aarch64-linux-android`).

The Zig static lib is built with BOTH include roots wired in:

```
zig build android-lib \
  -Dmobile-target=aarch64-linux-android.26 \
  -Dmobile-sysroot="$NDK/toolchains/llvm/prebuilt/<host>/sysroot" \
  -Dmobile-sysroot-arch-include=aarch64-linux-android
```

(`.26` = the API-level floor; the arch-include is the `usr/include/<triple>`
subdir.) Both ABIs produce a `current ar archive` static lib.

## Pinned toolchain

- **NDK:** r26d (LLVM sysroot). Provisioned user-local (no root); recorded in CI
  via `android-actions/setup-android`.
- **Zig target triples:** `aarch64-linux-android.26`, `x86_64-linux-android.26`.
- **Division of labour:** Zig owns the portable core (static `.a`); the NDK/CMake
  links it into `libwezigshell.so` behind a small JNI shim; Gradle owns
  packaging (APK, `WebView` Activity).
- **compileSdk 34 / minSdk 26 / targetSdk 34**; AGP 8.5, Gradle 8.7.

## Layout

- `app/src/main/cpp/wezig_jni.c` — the JNI shim: `System.loadLibrary` entry that
  calls the Zig C-ABI (`wezig_abi_version`/`wezig_greeting`) and returns the
  greeting to Java.
- `app/src/main/cpp/CMakeLists.txt` — links the prebuilt Zig static lib (per ABI)
  into `libwezigshell.so`.
- `app/src/main/java/dev/wighawag/wezig/MainActivity.java` — loads the lib and
  shows one `WebView` with HTML embedding the Zig greeting.
- `build-zig-libs.sh` — cross-compiles the Zig static lib for both ABIs into the
  per-ABI `jniLibs`-adjacent staging dir the CMake build reads.
- `build.gradle` / `settings.gradle` / `app/build.gradle` — the minimal Gradle
  project (NDK + CMake externalNativeBuild).
