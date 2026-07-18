#!/usr/bin/env bash
# Build + launch the wezig iOS shell on an iOS 17 Simulator (toolchain proof for
# task ios-toolchain-crosslink). Designed to run on a GitHub macos-14 runner (CI
# is the Mac) OR locally on a Mac with Xcode. NO code signing / no Apple
# Developer account — Simulator only.
#
# Steps: cross-compile the Zig static lib against the iOS-simulator SDK sysroot;
# compile the Swift shell against the simulator SDK, linking the lib; assemble a
# minimal .app; boot an iOS 17 simulator; install; launch; assert the Zig-linked
# greeting reached the device log.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IOS_DIR="$REPO_ROOT/mobile/ios"
BUILD_DIR="${BUILD_DIR:-$IOS_DIR/build}"
APP="$BUILD_DIR/WezigShell.app"
BUNDLE_ID="dev.wighawag.wezig.shell"

# The simulator SDK + a matching arch. macos-14 / Xcode 15.4 caps at iOS 17.
SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
DEPLOY_TARGET="16.0"           # deployment-target FLOOR
ARCH="$(uname -m)"             # arm64 on the Apple-Silicon runner
[ "$ARCH" = "arm64" ] && ZIG_TARGET="aarch64-ios-simulator" || ZIG_TARGET="x86_64-ios-simulator"

echo "== iOS shell build =="
echo "SDK:            $SDK_PATH"
echo "arch:           $ARCH  (zig target: $ZIG_TARGET)"
echo "deploy target:  iOS $DEPLOY_TARGET (floor); runtime: iOS 17 simulator (SDK ceiling)"

rm -rf "$BUILD_DIR"
mkdir -p "$APP"

# 1. Cross-compile the wezig mobile static lib for the iOS simulator, pointing
#    the C compile (stb_truetype) at the SDK sysroot for its libc headers.
echo "== 1/5 zig ios-lib =="
( cd "$REPO_ROOT" && zig build ios-lib \
    -Dmobile-target="$ZIG_TARGET" \
    -Dmobile-sysroot="$SDK_PATH" )
ZIG_LIB="$REPO_ROOT/zig-out/lib/libwezig_mobile.a"
file "$ZIG_LIB"

# 2. Compile the Swift shell against the simulator SDK, importing the C-ABI
#    bridging header and linking the Zig static lib. WebKit + UIKit are SDK libs.
echo "== 2/5 swiftc =="
xcrun --sdk iphonesimulator swiftc \
    -sdk "$SDK_PATH" \
    -target "${ARCH}-apple-ios${DEPLOY_TARGET}-simulator" \
    -parse-as-library \
    -import-objc-header "$IOS_DIR/Sources/wezig_mobile.h" \
    -framework UIKit -framework WebKit \
    -Xlinker -force_load -Xlinker "$ZIG_LIB" \
    -o "$APP/WezigShell" \
    "$IOS_DIR/Sources/main.swift"

# 3. Assemble the .app bundle (executable + Info.plist).
echo "== 3/5 assemble .app =="
cp "$IOS_DIR/Info.plist" "$APP/Info.plist"
plutil -lint "$APP/Info.plist"
ls -la "$APP"

# BUILD_ONLY: stop here with the assembled .app (used by the release workflow to
# package the Simulator app without booting/launching a simulator).
if [ "${BUILD_ONLY:-0}" = "1" ]; then
  echo "BUILD_ONLY set: .app assembled at $APP; skipping simulator boot/launch."
  exit 0
fi

# 4. Boot an iOS 17 simulator (newest runtime present on the runner).
echo "== 4/5 boot simulator =="
RUNTIME="$(xcrun simctl list runtimes | grep -m1 'iOS 17' | grep -oE 'com.apple.CoreSimulator.SimRuntime.iOS-17[^ ]*' || true)"
if [ -z "$RUNTIME" ]; then
  echo "no iOS 17 runtime found; available runtimes:"; xcrun simctl list runtimes
  exit 1
fi
echo "runtime: $RUNTIME"
# Extract a concrete iPhone device type id, stripping any trailing punctuation
# (`simctl list` prints it as `Name (com.apple...id)`).
DEVTYPE="$(xcrun simctl list devicetypes | grep -m1 'iPhone 15 ' | grep -oE 'com\.apple\.CoreSimulator\.SimDeviceType\.[A-Za-z0-9-]+' | head -1)"
[ -z "$DEVTYPE" ] && DEVTYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation"
UDID="$(xcrun simctl create wezig-ios17 "$DEVTYPE" "$RUNTIME")"
echo "device: $UDID"
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b

# 5. Install + launch; assert the Zig-linked greeting reached the device log.
echo "== 5/5 install + launch =="
xcrun simctl install "$UDID" "$APP"
# Capture the device log for our NSLog line while launching.
xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" > "$BUILD_DIR/launch.log" 2>&1 &
LAUNCH_PID=$!
# Give the app a moment to run viewDidLoad and emit the NSLog line.
sleep 8
# Pull the greeting from the unified log (NSLog goes to the system log).
xcrun simctl spawn "$UDID" log show --last 30s --predicate 'eventMessage CONTAINS "wezig: linked Zig core"' --style compact > "$BUILD_DIR/wezig.log" 2>&1 || true
kill "$LAUNCH_PID" 2>/dev/null || true

echo "---- launch.log ----"; cat "$BUILD_DIR/launch.log" || true
echo "---- wezig.log ----"; cat "$BUILD_DIR/wezig.log" || true

if grep -q "wezig: linked Zig core" "$BUILD_DIR/launch.log" "$BUILD_DIR/wezig.log" 2>/dev/null; then
  echo "PASS: iOS shell launched and the Zig core is linked + callable."
else
  echo "FAIL: did not observe the Zig-core greeting from the launched app."
  xcrun simctl shutdown "$UDID" || true
  exit 1
fi

xcrun simctl shutdown "$UDID" || true
echo "iOS toolchain proof GREEN."
