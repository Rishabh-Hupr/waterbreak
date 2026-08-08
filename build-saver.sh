#!/bin/bash
# Builds dist/WaterBreak.saver — the screensaver that shows the pixel scene on
# the lock screen and when idle.
#
# Built with swiftc directly rather than SwiftPM, because a .saver is a loadable
# bundle rather than an executable and SwiftPM has no product type for it.
set -euo pipefail

cd "$(dirname "$0")"

SAVER="dist/WaterBreak.saver"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

# The scene sources are shared with the app target, not copied, so the art can
# never drift between the two.
SHARED_SOURCES=(
    Sources/WaterBreak/BreakScene.swift
    Sources/WaterBreak/PixelCanvas.swift
    Sources/WaterBreak/PixelFont.swift
)

rm -rf "$SAVER"
mkdir -p "$SAVER/Contents/MacOS" "$SAVER/Contents/Resources"

swiftc \
    -O \
    -target arm64-apple-macos13.0 \
    -emit-library \
    -module-name WaterBreakSaver \
    -framework ScreenSaver \
    -framework AppKit \
    -o "$SAVER/Contents/MacOS/WaterBreakSaver" \
    "${SHARED_SOURCES[@]}" \
    Saver/WaterBreakSaverView.swift

cat > "$SAVER/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>WaterBreak</string>
    <key>CFBundleDisplayName</key>
    <string>WaterBreak</string>
    <key>CFBundleIdentifier</key>
    <string>local.waterbreak.saver</string>
    <key>CFBundleExecutable</key>
    <string>WaterBreakSaver</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <!-- Entry point: legacyScreenSaver instantiates this class. -->
    <key>NSPrincipalClass</key>
    <string>WaterBreakSaverView</string>
</dict>
PLIST
echo '</plist>' >> "$SAVER/Contents/Info.plist"

codesign --force --deep --sign - "$SAVER" >/dev/null 2>&1 || true

echo "Built $SAVER"
echo
echo "Install with:  ./install-saver.sh"
