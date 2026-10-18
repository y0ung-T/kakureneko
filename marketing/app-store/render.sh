#!/usr/bin/env bash
# Renders the App Store screenshots (docs/APP-STORE.md §7) from source/screens.html with headless Chrome:
# marketing/app-store/screenshots/0N-*.png, 1320 × 2868 (6.9-inch display), opaque.
# The phone screens inside them are the Simulator captures in marketing/screenshots/iphone; retake those first
# if the app's screens changed.
#
# Usage: marketing/app-store/render.sh
set -euo pipefail
cd "$(dirname "$0")"

CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
OUT="screenshots"
NAMES=(01-lid-closed 02-needs-you 03-countdown 04-activity 05-several-macs 06-no-account)
mkdir -p "$OUT"

# App Store Connect rejects screenshots with an alpha channel: scripts/flatten-png.swift rewrites them opaque.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
xcrun swiftc -O -swift-version 6 ../../scripts/flatten-png.swift -o "$TMP/flatten"

for i in "${!NAMES[@]}"; do
  n=$((i + 1))
  file="$OUT/${NAMES[$i]}.png"
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --allow-file-access-from-files --window-size=1320,2868 --virtual-time-budget=3000 \
    --screenshot="$PWD/$file" "file://$PWD/source/screens.html?n=$n" >/dev/null 2>&1
  "$TMP/flatten" "$file" "$file"
  echo "$file $(sips -g pixelWidth -g pixelHeight "$file" | awk '/pixel/ {printf "%s ", $2}')"
done
