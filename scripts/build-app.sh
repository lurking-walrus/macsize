#!/usr/bin/env bash
# Build MacSize.app from the Swift package.
#
# All values are configurable through environment variables:
#   APP_NAME       Display/bundle name               (default: "MacSize Dev")
#   BUNDLE_ID      CFBundleIdentifier                (default: com.example.macsize.dev)
#   VERSION        CFBundleShortVersionString        (default: BuildInfo.version, else `git describe`)
#   BUILD_NUMBER   CFBundleVersion                   (default: BuildInfo.build, else git commit count)
#   CONFIGURATION  swift build configuration         (default: release)
#   OUTPUT_DIR     Where to place the .app           (default: ./build)
#   SIGN_IDENTITY  codesign identity; "-" = ad-hoc   (default: -)
#   ARCHS          Space-separated architectures, e.g. "arm64 x86_64" for a universal
#                  build                             (default: host architecture only)
#
# Auto-updates (official releases only). Both must be set, or the app never updates:
#   SPARKLE_FEED_URL       appcast URL, written to SUFeedURL
#   SPARKLE_PUBLIC_ED_KEY  base64 EdDSA public key, written to SUPublicEDKey
#
# With a real identity the app is signed with the hardened runtime and a secure
# timestamp, ready for notarization. Ad-hoc builds skip the hardened runtime:
# library validation would otherwise refuse to load the ad-hoc-signed Sparkle.framework.
#
# Example:
#   BUNDLE_ID=io.github.yourname.macsize SIGN_IDENTITY="Developer ID Application: …" \
#     ARCHS="arm64 x86_64" scripts/build-app.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_INFO="$ROOT_DIR/Sources/MacSizeCore/BuildInfo.swift"

# Read `public static let <name> = "<value>"` from BuildInfo.swift.
build_info_value() {
    sed -n "s/^[[:space:]]*public static let $1 = \"\(.*\)\"$/\1/p" "$BUILD_INFO" | head -n 1
}

# Local builds default to a distinct "MacSize Dev" identity so they never collide with an
# installed official release (Full Disk Access, preferences, Sparkle state). The release
# workflow sets APP_NAME=MacSize and BUNDLE_ID from the repository variable.
APP_NAME="${APP_NAME:-MacSize Dev}"
BUNDLE_ID="${BUNDLE_ID:-com.example.macsize.dev}"
if [[ -z "${VERSION:-}" ]]; then
    VERSION="$(build_info_value version)"
    if [[ -z "$VERSION" || "$VERSION" == "0.0.0-dev" ]]; then
        GIT_VERSION="$(git -C "$ROOT_DIR" describe --tags --dirty 2>/dev/null || true)"
        VERSION="${GIT_VERSION#v}"
        VERSION="${VERSION:-0.0.0-dev}"
    fi
fi
if [[ -z "${BUILD_NUMBER:-}" ]]; then
    BUILD_NUMBER="$(build_info_value build)"
    if [[ -z "$BUILD_NUMBER" || "$BUILD_NUMBER" == "0" ]]; then
        BUILD_NUMBER="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"
    fi
fi
CONFIGURATION="${CONFIGURATION:-release}"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/build}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
ARCHS="${ARCHS:-}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
MIN_MACOS="14.0"

SWIFT_ARGS=(-c "$CONFIGURATION")
for arch in $ARCHS; do
    SWIFT_ARGS+=(--arch "$arch")
done

cd "$ROOT_DIR"
echo "==> Building MacSizeApp ($CONFIGURATION${ARCHS:+, $ARCHS})"
swift build "${SWIFT_ARGS[@]}" --product MacSizeApp
echo "==> Building bundled macsize CLI ($CONFIGURATION${ARCHS:+, $ARCHS})"
swift build "${SWIFT_ARGS[@]}" --product macsize
# Multi-arch builds land in .build/apple/Products/<Config>; ask SwiftPM rather than guess.
BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"

# Locate Sparkle.framework: SwiftPM copies it next to the products; fall back to the
# (universal) xcframework slice that `swift package resolve` downloaded.
SPARKLE_SRC=""
for candidate in "$BIN_DIR/Sparkle.framework" "$BIN_DIR/PackageFrameworks/Sparkle.framework"; do
    if [[ -d "$candidate" ]]; then SPARKLE_SRC="$candidate"; break; fi
done
if [[ -z "$SPARKLE_SRC" ]]; then
    SPARKLE_SRC="$(find "$ROOT_DIR/.build/artifacts" -type d -path '*Sparkle.xcframework/macos-*/Sparkle.framework' -print -quit 2>/dev/null || true)"
fi
if [[ -z "$SPARKLE_SRC" ]]; then
    echo "error: Sparkle.framework not found (run 'swift package resolve')" >&2
    exit 1
fi

APP_DIR="$OUTPUT_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Helpers" "$CONTENTS/Frameworks"
cp "$BIN_DIR/MacSizeApp" "$CONTENTS/MacOS/$APP_NAME"
# The CLI ships inside the app so the app can offer to install it (as a symlink).
# It lives in Helpers/ because MacOS/ is case-insensitive and would clash with the app binary.
cp "$BIN_DIR/macsize" "$CONTENTS/Helpers/macsize"
if [[ -f "$ROOT_DIR/Resources/AppIcon/AppIcon.icns" ]]; then
    cp "$ROOT_DIR/Resources/AppIcon/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
fi

echo "==> Embedding Sparkle.framework"
SPARKLE="$CONTENTS/Frameworks/Sparkle.framework"
ditto "$SPARKLE_SRC" "$SPARKLE"
# The app isn't sandboxed, so Sparkle's XPC services aren't needed.
rm -rf "$SPARKLE/Versions/B/XPCServices" "$SPARKLE/XPCServices"

APP_BIN="$CONTENTS/MacOS/$APP_NAME"
if otool -L "$APP_BIN" | grep -q '@rpath/Sparkle.framework'; then
    if ! otool -l "$APP_BIN" | grep -A2 LC_RPATH | grep -q '@executable_path/../Frameworks'; then
        install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BIN"
    fi
fi

xml_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    printf '%s' "$s"
}

SPARKLE_KEYS=""
if [[ -n "$SPARKLE_FEED_URL" && -n "$SPARKLE_PUBLIC_ED_KEY" ]]; then
    echo "==> Enabling Sparkle updates (feed: $SPARKLE_FEED_URL)"
    SPARKLE_KEYS="
    <key>SUFeedURL</key><string>$(xml_escape "$SPARKLE_FEED_URL")</string>
    <key>SUPublicEDKey</key><string>$(xml_escape "$SPARKLE_PUBLIC_ED_KEY")</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUAutomaticallyUpdate</key><true/>
    <key>SUAllowsAutomaticUpdates</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
    <key>SUVerifyUpdateBeforeExtraction</key><true/>"
elif [[ -n "$SPARKLE_FEED_URL" || -n "$SPARKLE_PUBLIC_ED_KEY" ]]; then
    echo "warning: set both SPARKLE_FEED_URL and SPARKLE_PUBLIC_ED_KEY to enable updates; building without them" >&2
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>$(xml_escape "$APP_NAME")</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$(xml_escape "$BUNDLE_ID")</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>$(xml_escape "$APP_NAME")</string>
    <key>CFBundleDisplayName</key><string>$(xml_escape "$APP_NAME")</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$(xml_escape "$VERSION")</string>
    <key>CFBundleVersion</key><string>$(xml_escape "$BUILD_NUMBER")</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key><false/>$SPARKLE_KEYS
</dict>
</plist>
PLIST
plutil -lint "$CONTENTS/Info.plist" >/dev/null

echo "==> Signing (identity: $SIGN_IDENTITY)"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    SIGN_ARGS=(--force --sign - --timestamp=none)
else
    SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --options runtime --timestamp)
fi
# Inside-out, without --deep: each nested code item gets its own signature.
codesign "${SIGN_ARGS[@]}" "$CONTENTS/Helpers/macsize"
codesign "${SIGN_ARGS[@]}" "$SPARKLE/Versions/B/Autoupdate"
codesign "${SIGN_ARGS[@]}" "$SPARKLE/Versions/B/Updater.app"
codesign "${SIGN_ARGS[@]}" "$SPARKLE"
codesign "${SIGN_ARGS[@]}" "$APP_DIR"

echo "==> Done: $APP_DIR (version $VERSION, build $BUILD_NUMBER)"
echo "    Launch with: open \"$APP_DIR\""
