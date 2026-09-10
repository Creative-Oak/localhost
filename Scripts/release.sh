#!/bin/bash
# Builds, signs, notarises and staples Localhost.app.
#
# This script never sees a secret. The signing identity lives in the login
# keychain and the notarisation credentials in a notarytool keychain profile,
# both created once by hand — see docs/shipping.md.
#
#   SIGNING_IDENTITY="Developer ID Application: Name (TEAMID)" \
#   NOTARY_PROFILE=localhost-notary \
#   ./Scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${SIGNING_IDENTITY:-}"
PROFILE="${NOTARY_PROFILE:-}"

if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning \
        | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
fi
if [ -z "$IDENTITY" ]; then
    echo "No Developer ID Application identity found." >&2
    echo "See docs/shipping.md — this needs an Apple Developer Program membership." >&2
    exit 1
fi

APP="$(./Scripts/bundle.sh release | tail -1)"
echo "signing $APP as: $IDENTITY"

# --options runtime is the hardened runtime, which notarisation requires.
# No entitlements: reading and signalling our own processes needs none, and the
# App Sandbox would prevent both. See docs/design.md.
codesign --force --deep --options runtime --timestamp \
    --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

ARCHIVE="${APP%.app}.zip"
rm -f "$ARCHIVE"
ditto -c -k --keepParent "$APP" "$ARCHIVE"

if [ -z "$PROFILE" ]; then
    echo
    echo "Signed but NOT notarised: set NOTARY_PROFILE to submit."
    echo "  $ARCHIVE"
    exit 0
fi

echo "submitting for notarisation…"
xcrun notarytool submit "$ARCHIVE" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# Gatekeeper's own verdict, which is what a user's Mac will apply.
spctl --assess --type execute --verbose=4 "$APP"

rm -f "$ARCHIVE"
ditto -c -k --keepParent "$APP" "$ARCHIVE"
echo
echo "notarised and stapled: $ARCHIVE"
