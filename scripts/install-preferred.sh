#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="/Applications/Windows Style Mac Explorer.app"

"$ROOT/scripts/build-app.sh" /Applications

if ! osascript -e 'tell application "System Events" to exists login item "Windows Style Mac Explorer"' | grep -q true; then
    osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/Windows Style Mac Explorer.app", hidden:false}'
fi

if ! defaults read com.apple.dock persistent-apps 2>/dev/null | grep -Eq 'Windows Style Mac Explorer|Windows%20Style%20Mac%20Explorer'; then
    defaults write com.apple.dock persistent-apps -array-add \
        '{"tile-data"={"file-data"={"_CFURLString"="file:///Applications/Windows%20Style%20Mac%20Explorer.app/";"_CFURLStringType"=15;};"file-label"="Windows Style Mac Explorer";};"tile-type"="file-tile";}'
    killall Dock
fi

open "$APP"
