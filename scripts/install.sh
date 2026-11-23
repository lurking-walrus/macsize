#!/usr/bin/env bash
# Install the `treesize` CLI and (optionally) TreeSize.app.
#
# Environment variables:
#   PREFIX        CLI install prefix; binary goes to $PREFIX/bin   (default: /usr/local)
#   APP_DEST      Where to copy the .app; empty = skip             (default: empty)
#   Any variable understood by scripts/build-app.sh is passed through.
#
# Examples:
#   PREFIX="$HOME/.local" scripts/install.sh
#   APP_DEST="$HOME/Applications" scripts/install.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${PREFIX:-/usr/local}"
APP_DEST="${APP_DEST:-}"

cd "$ROOT_DIR"
echo "==> Building treesize CLI (release)"
swift build -c release --product treesize
BIN_DIR="$(swift build -c release --show-bin-path)"

mkdir -p "$PREFIX/bin"
install -m 0755 "$BIN_DIR/treesize" "$PREFIX/bin/treesize"
echo "==> Installed $PREFIX/bin/treesize"

if [[ -n "$APP_DEST" ]]; then
    OUTPUT_DIR="$ROOT_DIR/build" "$ROOT_DIR/scripts/build-app.sh"
    APP_NAME="${APP_NAME:-TreeSize}"
    mkdir -p "$APP_DEST"
    rm -rf "$APP_DEST/$APP_NAME.app"
    cp -R "$ROOT_DIR/build/$APP_NAME.app" "$APP_DEST/"
    echo "==> Installed $APP_DEST/$APP_NAME.app"
fi
