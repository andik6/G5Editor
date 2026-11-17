#!/bin/bash
# Builds "G5 Editor.app" into ./dist (ad-hoc signed).
#   ./build-app.sh              Apple Silicon only (quick, for this Mac)
#   ./build-app.sh --universal  Apple Silicon + Intel (for releases)
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(cat VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
ARCHS=()
[[ "${1:-}" == "--universal" ]] && ARCHS=(--arch arm64 --arch x86_64)
swift build -c release --product G5Editor ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/G5Editor"
APP="dist/G5 Editor.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/G5Editor"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>G5 Editor</string>
  <key>CFBundleDisplayName</key><string>G5 Editor</string>
  <key>CFBundleIdentifier</key><string>local.andi.g5editor</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>G5Editor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>G5 Editor listens to the G5's USB audio for the monitor and the tuner. Nothing is recorded or sent anywhere.</string>
  <key>NSHumanReadableCopyright</key><string>Unofficial editor for the ZOOM G5. Not affiliated with ZOOM Corporation.</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP $VERSION ($BUILD) [$(lipo -archs "$APP/Contents/MacOS/G5Editor")]"
