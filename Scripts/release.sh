#!/bin/bash
# Builds, signs, notarises and staples Localhost-<version>.dmg, writes the
# Sparkle appcast for it, and optionally publishes both as a GitHub release.
#
# This script never sees a secret. The signing identity lives in the login
# keychain, the notarisation credentials in a notarytool keychain profile, and
# the Sparkle EdDSA private key in the keychain under the account "localhost" —
# all created once by hand, see docs/shipping.md.
#
#   VERSION=0.2.0 BUILD=2 \
#   NOTARY_PROFILE=localhost-notary \
#   PUBLISH=1 \
#   ./Scripts/release.sh
#
# BUILD must be higher than the last release's, or Sparkle will not offer it.
# Without NOTARY_PROFILE the DMG is signed but not notarised, and is not
# published: Gatekeeper would refuse it on every other Mac.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${VERSION:?set VERSION, e.g. VERSION=0.2.0}"
: "${BUILD:?set BUILD, higher than the last release}"
IDENTITY="${SIGNING_IDENTITY:-}"
PROFILE="${NOTARY_PROFILE:-}"
REPO=Creative-Oak/localhost
TAG="v$VERSION"
SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin

if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning \
        | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
fi
if [ -z "$IDENTITY" ]; then
    echo "No Developer ID Application identity found." >&2
    echo "See docs/shipping.md — this needs an Apple Developer Program membership." >&2
    exit 1
fi

APP="$(VERSION="$VERSION" BUILD="$BUILD" ./Scripts/bundle.sh release | tail -1)"
echo "signing $APP as: $IDENTITY"

# Inside out, and without --deep: Sparkle's helpers each need their own
# hardened-runtime signature, and Downloader.xpc keeps its entitlements.
# --options runtime is the hardened runtime, which notarisation requires.
sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
# No entitlements: reading and signalling our own processes needs none, and the
# App Sandbox would prevent both. See docs/design.md.
sign "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# The DMG is both the download and the Sparkle update archive.
OUT=build/release/$VERSION
rm -rf "$OUT"
mkdir -p "$OUT"
DMG="$OUT/Localhost-$VERSION.dmg"
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/Localhost.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname Localhost -srcfolder "$STAGE" -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [ -z "$PROFILE" ]; then
    echo
    echo "Signed but NOT notarised: set NOTARY_PROFILE to submit."
    echo "  $DMG"
    exit 0
fi

# One submission covers the DMG and the app inside it.
echo "submitting for notarisation…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
# Gatekeeper's own verdict, which is what a user's Mac will apply.
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"

# Signed after stapling, since stapling changes the file. The appcast holds
# only this release: it is served from the latest release, so that is all an
# installed copy ever needs to see.
"$SPARKLE_BIN/generate_appcast" --account localhost \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    "$OUT"

echo
echo "notarised and stapled: $DMG"
echo "appcast:               $OUT/appcast.xml"

if [ "${PUBLISH:-}" != 1 ]; then
    echo
    echo "Not published. To publish:"
    echo "  gh release create $TAG --repo $REPO --title \"Localhost $VERSION\" $DMG $OUT/appcast.xml"
    exit 0
fi

# Installed copies follow releases/latest, so this goes live the moment it is created.
gh release create "$TAG" --repo "$REPO" --title "Localhost $VERSION" \
    --generate-notes "$DMG" "$OUT/appcast.xml"
echo "published: https://github.com/$REPO/releases/tag/$TAG"
