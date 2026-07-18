#!/usr/bin/env bash
# The Xcode "Build Zig static lib" build phase (spec build-mobile-shell, story 1
# / criterion 1): cross-compile the wezig Zig core into `libwezig_mobile.a` for
# the iOS SDK + arch Xcode is currently building, as a NORMAL build step — not a
# bespoke out-of-band script. Xcode runs this phase BEFORE Compile Sources, so
# the Swift target links the freshly-built archive (wired via OTHER_LDFLAGS
# `-force_load .../libwezig_mobile.a`).
#
# It reuses the `zig build ios-lib` step (which already forces ReleaseSafe +
# strip + no-stack-check and points the stb C compile at the SDK sysroot — the
# mobile-link constraints, ADR-0009). This phase only derives the right Zig
# target triple + sysroot from Xcode's environment (PLATFORM_NAME + the active
# arch) and invokes it, so there is ONE source of truth for HOW the lib is built.
#
# Simulator + device both work; signing stays out of scope (Slice C).
set -euo pipefail

# Locate the repo root: this script lives at mobile/ios/App/, so ../../.. is root.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# The arch Xcode is building for. Prefer the single active arch (ONLY_ACTIVE_ARCH
# in Debug); fall back to the first of ARCHS. Simulator on Apple Silicon is arm64.
ARCH="${CURRENT_ARCH:-}"
if [ -z "$ARCH" ] || [ "$ARCH" = "undefined_arch" ]; then
  ARCH="$(echo "${ARCHS:-arm64}" | awk '{print $1}')"
fi

# Map (PLATFORM_NAME, arch) -> Zig target triple + the SDK sysroot for the stb C
# dep's libc headers. PLATFORM_NAME is `iphonesimulator` or `iphoneos`.
PLATFORM_NAME="${PLATFORM_NAME:-iphonesimulator}"
case "$PLATFORM_NAME" in
  iphonesimulator)
    SDK=iphonesimulator
    [ "$ARCH" = "arm64" ] && ZIG_TARGET="aarch64-ios-simulator" || ZIG_TARGET="x86_64-ios-simulator"
    ;;
  iphoneos)
    SDK=iphoneos
    ZIG_TARGET="aarch64-ios"
    ;;
  *)
    echo "build-zig-lib.sh: unsupported PLATFORM_NAME='$PLATFORM_NAME'" >&2
    exit 1
    ;;
esac

SDK_PATH="${SDKROOT:-$(xcrun --sdk "$SDK" --show-sdk-path)}"

echo "== wezig: build Zig static lib =="
echo "platform: $PLATFORM_NAME  arch: $ARCH  zig-target: $ZIG_TARGET"
echo "sdk:      $SDK_PATH"

# Locate zig. Xcode's build phase PATH is minimal; try PATH, then common installs.
ZIG_BIN="$(command -v zig || true)"
for cand in /opt/homebrew/bin/zig /usr/local/bin/zig "$HOME/.local/bin/zig"; do
  [ -n "$ZIG_BIN" ] && break
  [ -x "$cand" ] && ZIG_BIN="$cand"
done
if [ -z "$ZIG_BIN" ]; then
  echo "build-zig-lib.sh: 'zig' not found on PATH; install the pinned Zig (build.zig.zon .minimum_zig_version)." >&2
  exit 1
fi

( cd "$REPO_ROOT" && "$ZIG_BIN" build ios-lib \
    -Dmobile-target="$ZIG_TARGET" \
    -Dmobile-sysroot="$SDK_PATH" )

LIB="$REPO_ROOT/zig-out/lib/libwezig_mobile.a"
file "$LIB"
echo "== wezig: Zig static lib ready at $LIB =="
