#!/bin/bash
# Builds dist/WaterBreak.app from the SwiftPM executable.
set -euo pipefail

cd "$(dirname "$0")"

APP="dist/WaterBreak.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/WaterBreak "$APP/Contents/MacOS/WaterBreak"

# The icon is generated from `tools/make_icon.py` rather than committed, matching
# how the break scene itself is drawn procedurally: no binary assets in the repo.
# `iconutil` needs a directory literally named *.iconset, and it is built under
# dist/ so it lands in the gitignored output.
ICONSET="dist/WaterBreak.iconset"
rm -rf "$ICONSET"
python3 tools/make_icon.py "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/WaterBreak.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>WaterBreak</string>
    <key>CFBundleDisplayName</key>
    <string>WaterBreak</string>
    <key>CFBundleIdentifier</key>
    <string>local.waterbreak</string>
    <key>CFBundleExecutable</key>
    <string>WaterBreak</string>
    <!-- Without this the app shows the generic placeholder in Finder, Spotlight
         and Raycast. Extension omitted, as CFBundleIconFile expects. -->
    <key>CFBundleIconFile</key>
    <string>WaterBreak</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <!-- Menu-bar only: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS will launch it locally without Gatekeeper fuss.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
echo
echo "Now running ./build-saver.sh to generate the pixel art screensaver"

./build-saver.sh

echo "Installing screen-saver, by calling ./install-saver.sh"

./install-saver.sh

echo "Done"
