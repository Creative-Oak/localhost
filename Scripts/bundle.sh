#!/bin/bash
# Assembles Localhost.app around the SwiftPM binary.
#
# SwiftPM builds an executable, but a menu bar app needs a bundle: LSUIElement
# is what keeps it out of the Dock and the app switcher. Signing and notarising
# are release.sh's job.
#
#   VERSION=0.2.0 BUILD=2 ./Scripts/bundle.sh release
#
# BUILD is what Sparkle compares to decide whether an update is newer, so it
# must go up with every release.
set -euo pipefail

CONFIGURATION="${1:-debug}"
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"
cd "$(dirname "$0")/.."

swift build -c "$CONFIGURATION"
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"
APP="$BIN_PATH/Localhost.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_PATH/Localhost" "$APP/Contents/MacOS/Localhost"
# ditto, not cp: the framework is versioned and its symlinks must survive.
ditto "$BIN_PATH/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
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
	<string>dk.creativeoak.Localhost</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright © 2026 Creative Oak.</string>
</dict>
</plist>
PLIST

# Only a release build knows where updates live. A debug build checking the
# real feed would offer to replace itself with the last release.
if [ "$CONFIGURATION" = release ]; then
    PLIST="$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy \
        -c "Add :SUFeedURL string https://github.com/Creative-Oak/localhost/releases/latest/download/appcast.xml" \
        -c "Add :SUPublicEDKey string 5NjL3DbRPaCClKEMHXfIbLmAEgz6fpocGHPS2PJIstI=" \
        -c "Add :SUEnableAutomaticChecks bool false" \
        "$PLIST"
fi

echo "$APP"
