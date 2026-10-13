#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="${1:-"$ROOT/dist"}"
APP="$DESTINATION/Windows Style Mac Explorer.app"
LOCAL_IDENTITY="Windows Style Mac Explorer Local Signing"

if [[ -z "${CODE_SIGN_IDENTITY:-}" ]]; then
    IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    for PREFIX in "Developer ID Application:" "Apple Development:" "$LOCAL_IDENTITY"; do
        CODE_SIGN_IDENTITY="$(printf '%s\n' "$IDENTITIES" | awk -F '"' -v prefix="$PREFIX" 'index($2, prefix) == 1 { print $2; exit }')"
        [[ -n "$CODE_SIGN_IDENTITY" ]] && break
    done
fi
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"

swift build --configuration release --package-path "$ROOT"
BIN_DIR="$(swift build --configuration release --show-bin-path --package-path "$ROOT")"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
install -m 755 "$BIN_DIR/FileExplorer" "$APP/Contents/MacOS/FileExplorer"
install -m 644 "$ROOT/packaging/Info.plist" "$APP/Contents/Info.plist"
install -m 644 "$ROOT/packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign "$CODE_SIGN_IDENTITY" "$APP"

echo "Signed with: $CODE_SIGN_IDENTITY"
echo "$APP"
