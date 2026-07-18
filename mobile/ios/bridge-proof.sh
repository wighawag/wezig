#!/usr/bin/env bash
# Build + run the wezig iOS script-message BRIDGE proof on an iOS 17 Simulator
# (task mobile-web3-hooks-parity, spec explore-mobile-shell story 8). The iOS
# twin of the desktop `zig build shell-bridge-test`: round-trip ONE message BOTH
# ways THROUGH the pinned `Renderer` seam (WKUserContentController /
# WKScriptMessageHandler), mirroring `window.wezig.ping`.
#
# Designed to run on a GitHub macos-14 runner (CI is the Mac) OR locally on a Mac
# with Xcode. NO code signing / no Apple Developer account — Simulator only.
#
# Steps: cross-compile the Zig static lib (which now carries the IosWebviewRenderer
# backend + its bridge-proof C-ABI) against the iOS-simulator SDK sysroot; compile
# the Swift proof app against the simulator SDK, linking the lib; assemble a
# minimal .app; boot an iOS 17 simulator; install; launch; assert the seam PASS
# line reached the device log.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IOS_DIR="$REPO_ROOT/mobile/ios"
BUILD_DIR="${BUILD_DIR:-$IOS_DIR/build-bridge-proof}"
APP="$BUILD_DIR/WezigBridgeProof.app"
BUNDLE_ID="dev.wighawag.wezig.bridgeproof"

SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
DEPLOY_TARGET="16.0"           # deployment-target FLOOR
ARCH="$(uname -m)"             # arm64 on the Apple-Silicon runner
[ "$ARCH" = "arm64" ] && ZIG_TARGET="aarch64-ios-simulator" || ZIG_TARGET="x86_64-ios-simulator"

echo "== iOS bridge-proof build =="
echo "SDK:            $SDK_PATH"
echo "arch:           $ARCH  (zig target: $ZIG_TARGET)"
echo "deploy target:  iOS $DEPLOY_TARGET (floor); runtime: iOS 17 simulator (SDK ceiling)"

rm -rf "$BUILD_DIR"
mkdir -p "$APP"

# 1. Cross-compile the wezig mobile static lib for the iOS simulator.
echo "== 1/5 zig ios-lib =="
( cd "$REPO_ROOT" && zig build ios-lib \
    -Dmobile-target="$ZIG_TARGET" \
    -Dmobile-sysroot="$SDK_PATH" )
ZIG_LIB="$REPO_ROOT/zig-out/lib/libwezig_mobile.a"
file "$ZIG_LIB"

# 2. Compile the Swift proof app against the simulator SDK, importing the C-ABI
#    bridging header and linking the Zig static lib. WebKit + UIKit are SDK libs.
echo "== 2/5 swiftc =="
xcrun --sdk iphonesimulator swiftc \
    -sdk "$SDK_PATH" \
    -target "${ARCH}-apple-ios${DEPLOY_TARGET}-simulator" \
    -parse-as-library \
    -import-objc-header "$IOS_DIR/Sources/wezig_mobile.h" \
    -framework UIKit -framework WebKit \
    -Xlinker -force_load -Xlinker "$ZIG_LIB" \
    -o "$APP/WezigBridgeProof" \
    "$IOS_DIR/Sources/BridgeProof.swift"

# 3. Assemble the .app bundle (executable + Info.plist).
echo "== 3/5 assemble .app =="
sed 's/WezigShell/WezigBridgeProof/g; s/dev\.wighawag\.wezig\.shell/dev.wighawag.wezig.bridgeproof/g' \
    "$IOS_DIR/Info.plist" > "$APP/Info.plist"
plutil -lint "$APP/Info.plist"
ls -la "$APP"

# 4. Boot an iOS 17 simulator (newest runtime present on the runner).
echo "== 4/5 boot simulator =="
RUNTIME="$(xcrun simctl list runtimes | grep -m1 'iOS 17' | grep -oE 'com.apple.CoreSimulator.SimRuntime.iOS-17[^ ]*' || true)"
if [ -z "$RUNTIME" ]; then
  echo "no iOS 17 runtime found; available runtimes:"; xcrun simctl list runtimes
  exit 1
fi
echo "runtime: $RUNTIME"
DEVTYPE="$(xcrun simctl list devicetypes | grep -m1 'iPhone 15 ' | grep -oE 'com\.apple\.CoreSimulator\.SimDeviceType\.[A-Za-z0-9-]+' | head -1)"
[ -z "$DEVTYPE" ] && DEVTYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation"
UDID="$(xcrun simctl create wezig-ios17-bridge "$DEVTYPE" "$RUNTIME")"
echo "device: $UDID"
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b

# 5. Install + launch; assert the seam PASS line reached the device log.
echo "== 5/5 install + launch =="
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" > "$BUILD_DIR/launch.log" 2>&1 &
LAUNCH_PID=$!
# Give the app time to load the page + snapshot (navigate + finished + takeSnapshot).
sleep 12
xcrun simctl spawn "$UDID" log show --last 40s --predicate 'eventMessage CONTAINS "iOS script-message bridge"' --style compact > "$BUILD_DIR/wezig.log" 2>&1 || true
kill "$LAUNCH_PID" 2>/dev/null || true

echo "---- launch.log ----"; cat "$BUILD_DIR/launch.log" || true
echo "---- wezig.log ----"; cat "$BUILD_DIR/wezig.log" || true

if grep -q "PASS: iOS script-message bridge round-tripped" "$BUILD_DIR/launch.log" "$BUILD_DIR/wezig.log" 2>/dev/null; then
  echo "PASS: iOS script-message bridge round-tripped a message both ways through the pinned seam."
else
  echo "FAIL: did not observe the iOS bridge PASS line from the launched app."
  xcrun simctl shutdown "$UDID" || true
  exit 1
fi

xcrun simctl shutdown "$UDID" || true
echo "iOS bridge-hook proof GREEN."
