#!/usr/bin/env bash
# Build MacSize.app from the Swift package.
#
# All values are configurable through environment variables:
#   APP_NAME       Display/bundle name               (default: MacSize)
#   BUNDLE_ID      CFBundleIdentifier                (default: com.example.macsize)
#   VERSION        CFBundleShortVersionString        (default: 0.1.0)
#   BUILD_NUMBER   CFBundleVersion                   (default: 1)
#   CONFIGURATION  swift build configuration         (default: release)
#   OUTPUT_DIR     Where to place the .app           (default: ./build)
#   SIGN_IDENTITY  codesign identity; "-" = ad-hoc   (default: -)
#
# Example:
#   BUNDLE_ID=io.github.yourname.macsize SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${APP_NAME:-MacSize}"
BUNDLE_ID="${BUNDLE_ID:-com.example.macsize}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
CONFIGURATION="${CONFIGURATION:-release}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/build}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
MIN_MACOS="14.0"

cd "$ROOT_DIR"
echo "==> Building MacSizeApp ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product MacSizeApp
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

APP_DIR="$OUTPUT_DIR/$APP_NAME.app"
echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/MacSizeApp" "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST

echo "==> Signing (identity: $SIGN_IDENTITY)"
codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp=none "$APP_DIR" >/dev/null

echo "==> Done: $APP_DIR"
echo "    Launch with: open \"$APP_DIR\""
