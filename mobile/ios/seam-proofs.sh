#!/usr/bin/env bash
# The iOS seam-proof leg (spec build-mobile-shell, stories 7/11): run the
# embedding + script-message-bridge + custom-scheme seam proofs FOLDED INTO the
# REAL app's XCTest target (`WezigShellTests` in mobile/ios/App/WezigShell.xcodeproj)
# on an iOS 17 Simulator, via `xcodebuild test`. This REPLACES the old
# hand-assembled `embedding-proof.sh` / `bridge-proof.sh` / `scheme-proof.sh`
# spike scripts (+ their `Sources/*Proof.swift` swiftc binaries): the SAME
# assertions, now compiled + linked by the REAL Xcode project (its "Build Zig
# static lib" phase builds the Zig core as a normal step) and hosted by the real
# WezigShell app — the Android precedent (the seam proofs are instrumented tests
# in the real app module's test target).
#
# The three XCTest cases (EmbeddingProofTests / BridgeProofTests / SchemeProofTests)
# drive the SAME already-exported proof C-ABI (`wezig_ios_embed_proof_*`,
# `wezig_ios_bridge_proof_*`, `wezig_ios_scheme_proof_*`) the spikes drove, over
# the real backend, and assert: embedding = view hosted THROUGH the seam +
# non-blank snapshot; bridge = one message round-trips both ways; scheme = a
# native body served + rendered (handler installed on the config before the
# webview — the ordering constraint).
#
# macos-14 runner; Simulator only, no signing. Kept OUT of `zig build test`
# (ADR-0007). Runs NIGHTLY + on-demand via mobile-verify.yml.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IOS_DIR="$REPO_ROOT/mobile/ios"
APP_DIR="$IOS_DIR/App"
PROJECT="$APP_DIR/WezigShell.xcodeproj"
SCHEME="WezigShell"
BUILD_DIR="${BUILD_DIR:-$IOS_DIR/build-seam-proofs}"
DERIVED="$BUILD_DIR/DerivedData"

echo "== iOS seam proofs (embedding + bridge + scheme, real app XCTest target) =="
xcodebuild -version || true

rm -rf "$BUILD_DIR"; mkdir -p "$BUILD_DIR"

echo "== boot an iOS 17 simulator =="
RUNTIME="$(xcrun simctl list runtimes | grep -m1 'iOS 17' | grep -oE 'com.apple.CoreSimulator.SimRuntime.iOS-17[^ ]*' || true)"
[ -z "$RUNTIME" ] && { echo "no iOS 17 runtime"; xcrun simctl list runtimes; exit 1; }
DEVTYPE="$(xcrun simctl list devicetypes | grep -m1 'iPhone 15 ' | grep -oE 'com\.apple\.CoreSimulator\.SimDeviceType\.[A-Za-z0-9-]+' | head -1)"
[ -z "$DEVTYPE" ] && DEVTYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation"
UDID="$(xcrun simctl create wezig-ios17-seam-proofs "$DEVTYPE" "$RUNTIME")"
xcrun simctl boot "$UDID"; xcrun simctl bootstatus "$UDID" -b

echo "== xcodebuild test (Zig-lib build phase + Swift app + XCTest bundle) =="
# ONLY_ACTIVE_ARCH + explicit ARCHS forces one arch end-to-end so the per-arch
# "Build Zig static lib" phase agrees with the link (same constraint as
# build-and-run.sh / shell-verify.sh).
HOST_ARCH="$(uname -m)"
set +e
xcodebuild test \
  -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
  -sdk iphonesimulator -derivedDataPath "$DERIVED" \
  -destination "id=$UDID" \
  ONLY_ACTIVE_ARCH=YES ARCHS="$HOST_ARCH" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  2>&1 | tee "$BUILD_DIR/xctest.log"
STATUS=${PIPESTATUS[0]}
set -e

xcrun simctl shutdown "$UDID" || true

echo "== verdict =="
if [ "$STATUS" -eq 0 ] && grep -q "Test Suite 'All tests' passed" "$BUILD_DIR/xctest.log"; then
  echo "PASS: iOS seam proofs GREEN (embedding + bridge + scheme, against the real app)."
else
  echo "FAIL: iOS seam-proof XCTest run did not pass (status=$STATUS)."
  exit 1
fi
