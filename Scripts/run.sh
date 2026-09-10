#!/bin/bash
# Rebuild, re-bundle and relaunch, replacing any running copy.
#
# `swift build` alone updates the binary but not Localhost.app, so the running
# menu bar app silently stays on old code. Always come through here.
set -euo pipefail
cd "$(dirname "$0")/.."

pkill -x Localhost 2>/dev/null || true
APP="$(./Scripts/bundle.sh "${1:-debug}" | tail -1)"
codesign --force --sign - "$APP" >/dev/null 2>&1
open "$APP"
sleep 1
if pgrep -x Localhost >/dev/null; then
    echo "running: $APP (pid $(pgrep -x Localhost))"
else
    echo "failed to launch $APP" >&2
    exit 1
fi
