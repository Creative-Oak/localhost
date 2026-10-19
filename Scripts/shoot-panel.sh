#!/bin/bash
# Screenshots the panel as AppKit really draws it.
#
# Captures this app's window by id, so nothing else on the screen is included.
#   ./Scripts/shoot-panel.sh out.png [dark|light] [sample] [all] [grow]
#
# `sample` uses made-up listeners instead of this machine's; `grow` expands
# every tier after the panel opens, to check the window follows.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:?usage: shoot-panel.sh <out.png> [dark]}"
MODE="${2:-light}"
shift; shift || true

swift build >/dev/null
BIN="$(swift build --show-bin-path)/Localhost"

"$BIN" --window "$MODE" "$@" > /tmp/localhost-panel-window.txt 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT

for _ in $(seq 1 60); do
    WINDOW=$(sed -n 's/^window: //p' /tmp/localhost-panel-window.txt 2>/dev/null | head -1)
    [ -n "${WINDOW:-}" ] && break
    sleep 0.1
done
[ -n "${WINDOW:-}" ] || { echo "panel window never appeared" >&2; exit 1; }

sleep "${SETTLE:-1.2}"   # let the material and text settle
screencapture -o -x -l "$WINDOW" "$OUT"
echo "$OUT"
