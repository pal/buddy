#!/usr/bin/env bash
# Builds build/Buddy.app as a universal binary (Apple silicon + Intel).
#
#   scripts/build-app.sh                 # ad-hoc signed, for your own Mac
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" scripts/build-app.sh
#
# Environment: VERSION (default 0.1.0), BUILD_NUMBER (default 1), SIGN_IDENTITY (default "-" = ad-hoc).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP="build/Buddy.app"

echo "==> Building Buddy $VERSION ($BUILD_NUMBER)"
for arch in arm64 x86_64; do
  swift build -c release --arch "$arch" --product Buddy
done
ARM_BIN="$(swift build -c release --arch arm64 --show-bin-path)/Buddy"
X86_BIN="$(swift build -c release --arch x86_64 --show-bin-path)/Buddy"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/Buddy" "$ARM_BIN" "$X86_BIN"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

if [ -f Resources/AppIcon.png ]; then
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi

echo "==> Signing ($SIGN_IDENTITY)"
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - --entitlements Resources/Buddy.entitlements "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" \
    --entitlements Resources/Buddy.entitlements "$APP"
fi
codesign --verify --strict "$APP"

echo "==> Done: $APP"
