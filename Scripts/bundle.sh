#!/bin/bash
# Assembles Localhost.app around the SwiftPM binary.
#
# SwiftPM builds an executable, but a menu bar app needs a bundle: LSUIElement
# is what keeps it out of the Dock and the app switcher. Signing and notarising
# come later, at step 7.
set -euo pipefail

CONFIGURATION="${1:-debug}"
cd "$(dirname "$0")/.."

swift build -c "$CONFIGURATION"
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"
APP="$BIN_PATH/Localhost.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/Localhost" "$APP/Contents/MacOS/Localhost"

if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>Localhost</string>
	<key>CFBundleDisplayName</key>
	<string>Localhost</string>
	<key>CFBundleExecutable</key>
	<string>Localhost</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.magnisoft.Localhost</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright © 2026 Magnisoft.</string>
</dict>
</plist>
PLIST

echo "$APP"
