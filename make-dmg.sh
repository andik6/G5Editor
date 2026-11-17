#!/bin/bash
# Builds a universal "G5 Editor.app" and packs it into dist/G5-Editor-<version>.dmg
# (drag-to-Applications layout). Usage: ./make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(cat VERSION)
./build-app.sh --universal
DMG="dist/G5-Editor-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "dist/G5 Editor.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/READ ME FIRST.txt" <<TXT
G5 Editor $VERSION: unofficial editor for the ZOOM G5 (macOS 14 or later, Apple Silicon or Intel)

1. Drag "G5 Editor" onto the Applications folder.
2. The app is not signed with an Apple Developer ID, so the first time macOS will say it
   "cannot be opened" or "cannot verify the developer". To allow it:
     - macOS 15 and later: try to open it once, then go to System Settings → Privacy & Security,
       scroll down and click "Open Anyway".
     - macOS 14: right-click (Control-click) the app → Open → Open.
3. Connect the G5 with USB. Allow microphone access when asked (it is used only to hear the
   G5's USB audio for the monitor and the tuner).

Before editing, use "Back Up" to save all your patches.
More: https://github.com/andik6/G5Editor
TXT
rm -f "$DMG"
hdiutil create -volname "G5 Editor $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
