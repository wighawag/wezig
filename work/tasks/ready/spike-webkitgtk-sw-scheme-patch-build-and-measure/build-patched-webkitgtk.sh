#!/usr/bin/env bash
# Build a PATCHED WebKitGTK 2.52.3 (carried ipfs:// service-worker-capable fork
# patch, ADR-0016 d.6) from source into a self-contained prefix, then hand its
# path to the repo's `-Dsw-patch -Dsw-webkit-prefix=...` build so the live SW leg
# (`zig build ipfs-sw-hosting-test`) can run. This is the HARDWARE-GATED half of
# spike-webkitgtk-sw-scheme-patch-build-and-measure.
#
# It is a SPIKE build: it installs into its OWN prefix and NEVER overwrites the
# system libwebkitgtk, and it is never wired into release/distribution.
#
# WHY THIS IS A SEPARATE, PRIVILEGED STEP (the provisioning gate). The build
# needs a large set of `-dev` system packages this host lacks; installing them
# needs root. The agent that landed the Zig side + rebased the patch has NO
# passwordless sudo, so it could not run `apt-get install`. A human runs THIS
# script (the `apt-get` line needs sudo); everything after is unprivileged.
#
# Records the two remaining acceptance data points: build TIME (printed at the
# end + written to build-time.txt) and the live-SW proof (the `zig build
# ipfs-sw-hosting-test` PASS line). Host spec is in host-spec.txt next to this.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The repo root is 4 levels up: work/tasks/ready/<slug>/ -> repo.
REPO="$(cd "$HERE/../../../.." && pwd)"
WORK="${WEBKIT_SPIKE_WORK:-$HOME/.dorfl/webkit-spike-build}"
SRC="$WORK/webkitgtk-2.52.3"
BUILD="$WORK/build-2.52.3"
PREFIX="$WORK/install-2.52.3"
TARBALL_URL="https://webkitgtk.org/releases/webkitgtk-2.52.3.tar.xz"
# Verified 2026-07-20 against the official release archive.
TARBALL_SHA256="5b3e0d174e63dcc28848b1194e0e7448d5948c3c2427ecd931c2c5be5261aebb"

echo "== 1/6  Install build dependencies (needs sudo) =="
# The set of -dev packages missing on the reference host (Debian 13). Adjust for
# another distro. These are BUILD deps only; the spike lib installs to $PREFIX.
sudo apt-get update
sudo apt-get install -y \
  build-essential cmake ninja-build ruby gperf \
  libgcrypt20-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
  libseccomp-dev libwpe-1.0-dev libwpebackend-fdo-1.0-dev libmanette-0.2-dev \
  libgbm-dev libwoff-dev libavif-dev libjxl-dev liblcms2-dev libxkbcommon-dev \
  libenchant-2-dev libnotify-dev libhyphen-dev libopenjp2-7-dev libsecret-1-dev \
  libsystemd-dev libepoxy-dev libtasn1-6-dev libxslt1-dev libwebp-dev \
  libjpeg-dev libpng-dev libgtk-4-dev libsoup-3.0-dev libicu-dev

echo "== 2/6  Fetch + verify + extract WebKitGTK 2.52.3 source =="
mkdir -p "$WORK"
if [ ! -d "$SRC" ]; then
  cd "$WORK"
  [ -f webkitgtk-2.52.3.tar.xz ] || curl -fSL -o webkitgtk-2.52.3.tar.xz "$TARBALL_URL"
  echo "$TARBALL_SHA256  webkitgtk-2.52.3.tar.xz" | sha256sum -c -
  tar xf webkitgtk-2.52.3.tar.xz
fi

echo "== 3/6  Apply the rebased fork patch =="
# The patch is already rebased onto 2.52.3 (webkitgtk-2.52.3-sw-scheme-capable.patch
# in this sidecar). `patch -p1 --forward` is idempotent-ish: skip if applied.
cd "$SRC"
if ! grep -q shouldTreatURLSchemeAsServiceWorkerCapable \
     Source/WebCore/workers/service/ServiceWorkerContainer.cpp; then
  patch -p1 < "$HERE/webkitgtk-2.52.3-sw-scheme-capable.patch"
fi

echo "== 4/6  Configure (spike config: heavy optional features off) =="
cmake -S "$SRC" -B "$BUILD" -GNinja -DPORT=GTK -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DENABLE_MINIBROWSER=OFF -DENABLE_DOCUMENTATION=OFF -DENABLE_INTROSPECTION=OFF \
  -DENABLE_GAMEPAD=OFF -DENABLE_JOURNALD_LOG=OFF -DUSE_GTK4=ON

echo "== 5/6  Build + install (this is the multi-hour compile) =="
START=$(date +%s)
ninja -C "$BUILD"
ninja -C "$BUILD" install
END=$(date +%s)
BUILD_SECONDS=$((END - START))
printf 'build_seconds: %d\nbuild_hms: %02d:%02d:%02d\nhost: %s\ncores: %s\n' \
  "$BUILD_SECONDS" $((BUILD_SECONDS/3600)) $(((BUILD_SECONDS%3600)/60)) $((BUILD_SECONDS%60)) \
  "$(uname -sr)" "$(nproc)" | tee "$HERE/build-time.txt"

echo "== 6/6  Run the live SW-hosting proof against the patched lib =="
cd "$REPO"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="$PREFIX/lib:${LD_LIBRARY_PATH:-}"
zig build ipfs-sw-hosting-test -Dsw-patch -Dsw-webkit-prefix="$PREFIX"
echo
echo "DONE. Build time recorded in build-time.txt; the PASS line above is the"
echo "live service-worker-on-ipfs:// proof (the leg stock WebKitGTK rejects)."
