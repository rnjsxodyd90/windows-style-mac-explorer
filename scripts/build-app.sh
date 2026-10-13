#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="${1:-"$ROOT/dist"}"
APP="$DESTINATION/Windows Style Mac Explorer.app"

swift build --configuration release --package-path "$ROOT"
BIN_DIR="$(swift build --configuration release --show-bin-path --package-path "$ROOT")"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
install -m 755 "$BIN_DIR/FileExplorer" "$APP/Contents/MacOS/FileExplorer"
install -m 644 "$ROOT/packaging/Info.plist" "$APP/Contents/Info.plist"
install -m 644 "$ROOT/packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"

echo "$APP"
