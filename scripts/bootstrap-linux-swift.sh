#!/usr/bin/env bash
# Installs a Swift toolchain in an Ubuntu 24.04 (noble) container where swift.org
# downloads are unavailable, using Ubuntu's own `swiftlang` package from a newer
# release. Only needed to run the BudgetCore/UpAPI tests on Linux; on a Mac use Xcode.
# Idempotent: does nothing if `swift` is already on PATH.
set -euo pipefail

if command -v swift >/dev/null 2>&1; then
  swift --version
  exit 0
fi

MIRROR="${UBUNTU_MIRROR:-http://archive.ubuntu.com/ubuntu}"
DEBS=(
  pool/main/libx/libxml2/libxml2-16_2.14.5+dfsg-0.2_amd64.deb
  pool/universe/s/swiftlang/libswiftlang_6.0.3-2build1_amd64.deb
  pool/universe/s/swiftlang/swiftlang_6.0.3-2build1_amd64.deb
)
WORK="${SWIFT_DEB_CACHE:-${TMPDIR:-/tmp}/swift-debs}"
mkdir -p "$WORK"

for deb in "${DEBS[@]}"; do
  file="$WORK/$(basename "$deb")"
  if [ ! -s "$file" ]; then
    echo "Downloading $(basename "$deb")"
    curl -fsSL --retry 3 -o "$file.part" "$MIRROR/$deb"
    mv "$file.part" "$file"
  fi
done

SUDO=""
if [ "$(id -u)" -ne 0 ]; then SUDO="sudo"; fi
DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y --no-install-recommends "$WORK"/*.deb
swift --version
