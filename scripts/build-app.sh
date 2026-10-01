#!/usr/bin/env bash
# Builds build/Budget.app (universal, ad-hoc signed) and build/Budget.zip.
# Needs macOS with Xcode or the Xcode Command Line Tools.
#   VERSION=0.2.0 BUILD_NUMBER=7 scripts/build-app.sh
#   ARCHS=arm64 scripts/build-app.sh      # faster, Apple Silicon only
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Budget"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
ARCHS="${ARCHS:-arm64 x86_64}"

rm -rf "$APP" "$BUILD_DIR/$APP_NAME.zip"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

binaries=()
for arch in $ARCHS; do
  args=(-c release --product "$APP_NAME" --triple "$arch-apple-macosx15.0" --scratch-path ".build/app-$arch")
  swift build "${args[@]}"
  binaries+=("$(swift build "${args[@]}" --show-bin-path)/$APP_NAME")
done

if [ "${#binaries[@]}" -gt 1 ]; then
  lipo -create "${binaries[@]}" -output "$APP/Contents/MacOS/$APP_NAME"
else
  cp "${binaries[0]}" "$APP/Contents/MacOS/$APP_NAME"
fi

cp Support/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"

codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict --verbose=2 "$APP"

(cd "$BUILD_DIR" && ditto -c -k --keepParent "$APP_NAME.app" "$APP_NAME.zip")
echo "Built $APP ($VERSION build $BUILD_NUMBER) and $BUILD_DIR/$APP_NAME.zip"
