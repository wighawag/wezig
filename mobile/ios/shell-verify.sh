#!/usr/bin/env bash
# The iOS SHELL verification leg (spec build-mobile-shell, stories 4/7): drive the
# REAL Xcode app (mobile/ios/App/WezigShell.xcodeproj) on an iOS 17 Simulator and
# assert the mobile-verify facts AGAINST THE MAINTAINED APP, not the spike harness:
#   1. navigate one page THROUGH the seams,
#   2. a `.finished` lifecycle event reaches the chrome (URL reflected),
#   3. the embedded WKWebView renders non-blank,
#   4. a background→foreground round-trip PRESERVES the page (story 4).
#
# The app self-checks under the `--wezig-verify` launch arg (ShellVerify.swift),
# driving the SAME seams a user does, and prints one PASS/FAIL line we grep.
# macos-14 runner; Simulator only, no signing. Same build path as build-and-run.sh
# (the Zig lib is a normal Xcode build phase).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IOS_DIR="$REPO_ROOT/mobile/ios"
APP_DIR="$IOS_DIR/App"
PROJECT="$APP_DIR/WezigShell.xcodeproj"
SCHEME="WezigShell"
BUILD_DIR="${BUILD_DIR:-$IOS_DIR/build}"
DERIVED="$BUILD_DIR/DerivedData"
BUNDLE_ID="dev.wighawag.wezig.shell"

echo "== iOS shell verify (real Xcode project) =="
xcodebuild -version || true

rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"

# Pin a SINGLE architecture (the runner's native arch) for BOTH the link and the
# per-arch "Build Zig static lib" phase. Without ONLY_ACTIVE_ARCH + an explicit
# ARCHS, `xcodebuild build` resolves ARCHS to every simulator arch (arm64+x86_64)
# and links x86_64 while the script phase builds arm64 (CURRENT_ARCH=undefined_arch)
# — an arch mismatch that fails the link with undefined _wezig_ios_shell_* symbols.
HOST_ARCH="$(uname -m)"   # arm64 on the Apple-Silicon macos-14 runner
echo "== 1/4 xcodebuild (Zig-lib build phase + Swift); arch: $HOST_ARCH =="
xcodebuild \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
  -sdk iphonesimulator -derivedDataPath "$DERIVED" \
  ONLY_ACTIVE_ARCH=YES ARCHS="$HOST_ARCH" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build

APP="$(find "$DERIVED/Build/Products" -maxdepth 2 -name 'WezigShell.app' -type d | head -1)"
[ -z "$APP" ] && { echo "FAIL: WezigShell.app not produced." >&2; exit 1; }
echo "built: $APP"

echo "== 2/4 boot simulator =="
RUNTIME="$(xcrun simctl list runtimes | grep -m1 'iOS 17' | grep -oE 'com.apple.CoreSimulator.SimRuntime.iOS-17[^ ]*' || true)"
[ -z "$RUNTIME" ] && { echo "no iOS 17 runtime"; xcrun simctl list runtimes; exit 1; }
DEVTYPE="$(xcrun simctl list devicetypes | grep -m1 'iPhone 15 ' | grep -oE 'com\.apple\.CoreSimulator\.SimDeviceType\.[A-Za-z0-9-]+' | head -1)"
[ -z "$DEVTYPE" ] && DEVTYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation"
UDID="$(xcrun simctl create wezig-ios17-verify "$DEVTYPE" "$RUNTIME")"
xcrun simctl boot "$UDID"; xcrun simctl bootstatus "$UDID" -b

echo "== 3/4 install + launch (--wezig-verify) =="
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch --console-pty "$UDID" "$BUNDLE_ID" --wezig-verify > "$BUILD_DIR/verify.log" 2>&1 &
LAUNCH_PID=$!
sleep 20
xcrun simctl spawn "$UDID" log show --last 60s --predicate 'eventMessage CONTAINS "wezig verify" OR eventMessage CONTAINS "wezig shell verify" OR eventMessage BEGINSWITH "PASS" OR eventMessage BEGINSWITH "FAIL"' --style compact > "$BUILD_DIR/verify-syslog.log" 2>&1 || true
kill "$LAUNCH_PID" 2>/dev/null || true

echo "---- verify.log ----"; cat "$BUILD_DIR/verify.log" || true
echo "---- verify-syslog.log ----"; cat "$BUILD_DIR/verify-syslog.log" || true

echo "== 4/4 verdict =="
if grep -q "PASS: iOS shell browsed one page through the seams and preserved it" "$BUILD_DIR/verify.log" "$BUILD_DIR/verify-syslog.log" 2>/dev/null; then
  echo "PASS: iOS shell verify GREEN (navigate + finished + non-blank + background/foreground preserved)."
  xcrun simctl shutdown "$UDID" || true
else
  echo "FAIL: iOS shell verify did not observe the PASS line."
  xcrun simctl shutdown "$UDID" || true
  exit 1
fi
