#!/usr/bin/env bash
# Rewrite Sources/MacSizeCore/BuildInfo.swift from environment variables.
#
#   VERSION                Marketing version, e.g. 1.2.3
#                          (default: `git describe --tags --dirty` minus a leading "v",
#                          or 0.0.0-dev when there is no tag)
#   BUILD_NUMBER           Monotonic build number (default: `git rev-list --count HEAD`, or 0)
#   RELEASE_BASE_URL       Base URL for release assets, e.g.
#                          https://github.com/OWNER/REPO/releases/latest/download   (default: nil)
#   SPARKLE_PUBLIC_ED_KEY  Base64 Ed25519 public key (default: nil)
#   BUNDLE_ID              Official app bundle identifier (default: nil)
#
# CI runs this before building and never commits the result. To undo locally:
#   git checkout -- Sources/MacSizeCore/BuildInfo.swift
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT_DIR/Sources/MacSizeCore/BuildInfo.swift"

if [[ -z "${VERSION:-}" ]]; then
    VERSION="$(git -C "$ROOT_DIR" describe --tags --dirty 2>/dev/null || true)"
    VERSION="${VERSION#v}"
    VERSION="${VERSION:-0.0.0-dev}"
fi
if [[ -z "${BUILD_NUMBER:-}" ]]; then
    BUILD_NUMBER="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 0)"
fi

# Emit a Swift string literal. Escapes backslash, quote, and control characters;
# rejects newlines, which never belong in these values.
swift_string() {
    local s="$1"
    if [[ "$s" == *$'\n'* || "$s" == *$'\r'* ]]; then
        echo "stamp-version: value contains a newline" >&2
        exit 1
    fi
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    printf '"%s"' "$s"
}

# Emit a String? literal: nil when unset or empty.
swift_optional() {
    if [[ -n "${1:-}" ]]; then swift_string "$1"; else printf 'nil'; fi
}

cat > "$OUT" <<SWIFT
// Build-time values. This committed file holds development defaults.
// Release CI overwrites it via scripts/stamp-version.sh (never committed back),
// so nothing environment- or owner-specific lives in the repository.
public enum BuildInfo {
    /// Marketing version, e.g. "1.2.3". "0.0.0-dev" for source builds.
    public static let version = $(swift_string "$VERSION")
    /// Monotonic build number (git commit count in CI).
    public static let build = $(swift_string "$BUILD_NUMBER")
    /// Base URL for release assets, e.g. "https://github.com/OWNER/REPO/releases/latest/download".
    /// \`nil\` disables update checks (source builds).
    public static let releaseBaseURL: String? = $(swift_optional "${RELEASE_BASE_URL:-}")
    /// Base64 Ed25519 public key used to verify release signatures (Sparkle's SUPublicEDKey).
    /// \`nil\` disables self-update.
    public static let updatePublicEDKey: String? = $(swift_optional "${SPARKLE_PUBLIC_ED_KEY:-}")
    /// App bundle identifier for official builds, used by the CLI to open the app.
    public static let bundleIdentifier: String? = $(swift_optional "${BUNDLE_ID:-}")
}
SWIFT

echo "Stamped $OUT (version $VERSION, build $BUILD_NUMBER)"
