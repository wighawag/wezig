#!/usr/bin/env bash
# Cross-compile the wezig Zig static lib for the Android ABIs into the per-ABI
# staging dir the Gradle/CMake build reads (mobile/android/app/.cxx-zig/<abi>/).
# Also copies the shared C-ABI header next to the JNI shim so the NDK build is
# self-contained.
#
# NOTE (spec build-mobile-shell, criterion 4): the Gradle build now cross-compiles
# the Zig static lib itself, as a NORMAL build step — the `buildZigLibs` task in
# app/build.gradle, which the native (CMake) build depends on. So a plain
# `gradle assembleDebug` builds everything; this script is NO LONGER required
# before it. It is kept only as a standalone convenience for building the staged
# libs by hand (its logic is mirrored by the Gradle task). The CI legs run the
# Gradle build directly.
#
# Requires: Zig on PATH, and ANDROID_NDK_HOME (or ANDROID_NDK_ROOT) pointing at
# an installed NDK. Closes the stb_truetype libc-header gap via the NDK sysroot.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ANDROID_DIR="$REPO_ROOT/mobile/android"
STAGE="$ANDROID_DIR/app/.cxx-zig"

NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
if [ -z "$NDK" ] || [ ! -d "$NDK" ]; then
  echo "ERROR: set ANDROID_NDK_HOME (or ANDROID_NDK_ROOT) to an installed NDK." >&2
  exit 1
fi

# The NDK's LLVM sysroot (host-tagged). Find the single prebuilt host dir.
HOST_TAG="$(ls "$NDK/toolchains/llvm/prebuilt" | head -1)"
SYSROOT="$NDK/toolchains/llvm/prebuilt/$HOST_TAG/sysroot"
[ -f "$SYSROOT/usr/include/math.h" ] || { echo "ERROR: no math.h under $SYSROOT" >&2; exit 1; }

API=26   # Android API floor (spec)

# Map Android ABI -> Zig target triple + the arch include subdir under the sysroot.
declare -A ABI_TRIPLE=(
  [arm64-v8a]=aarch64-linux-android
  [x86_64]=x86_64-linux-android
)

# The shared C-ABI header lives with the iOS shell; make it visible to the NDK build.
cp "$REPO_ROOT/mobile/ios/Sources/wezig_mobile.h" "$ANDROID_DIR/app/src/main/cpp/wezig_mobile.h"

echo "== building wezig Zig static libs for Android (NDK: $NDK) =="
for abi in "${!ABI_TRIPLE[@]}"; do
  triple="${ABI_TRIPLE[$abi]}"
  out="$STAGE/$abi"
  mkdir -p "$out"
  echo "-- $abi ($triple.$API) --"
  ( cd "$REPO_ROOT" && zig build android-lib \
      -Dmobile-target="${triple}.${API}" \
      -Dmobile-sysroot="$SYSROOT" \
      -Dmobile-sysroot-arch-include="$triple" )
  cp "$REPO_ROOT/zig-out/lib/libwezig_mobile.a" "$out/libwezig_mobile.a"
  file "$out/libwezig_mobile.a"
done

echo "wezig Zig static libs staged under $STAGE/<abi>/."
