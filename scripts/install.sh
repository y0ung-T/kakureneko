#!/usr/bin/env bash
# Build Kakureneko.app and install it into ~/Applications (brief §9.2). OWNER: agent "app".
#
# USER ONLY: run this yourself. Automated agents and tests never run it (it replaces an installed app and
# launches it).
#
# Usage: scripts/install.sh [release|debug] [--no-open]
# Env:
#   DEST     install directory (default: ~/Applications)
#   SIGN_ID  passed through to scripts/build-app.sh (default: your Apple Development identity, else ad-hoc)
#
# Steps:
#   1. scripts/build-app.sh                  → build/Kakureneko.app (signed, verified)
#   2. quit a running copy from DEST         → SIGTERM, which the app handles itself: resume paused apps,
#                                              turn sleep back on, exit (waits up to 15 s)
#   3. ditto into DEST/Kakureneko.app        (via a temporary copy, then an atomic swap); build/Kakureneko.app is
#                                              removed so only the installed app is registered
#   4. open it                               (unless --no-open)
#
# On first launch the app copies its hook helper to ~/.kakureneko/bin and shows the setup window.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() { echo "usage: $0 [release|debug] [--no-open]" >&2; }

CONFIG="release"
OPEN=1
for arg in "$@"; do
  case "$arg" in
    release|debug) CONFIG="$arg" ;;
    --no-open) OPEN=0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

DEST="${DEST:-$HOME/Applications}"
SRC="build/Kakureneko.app"
APP="$DEST/Kakureneko.app"

scripts/build-app.sh "$CONFIG"

# Quit every running copy of this user's app, wherever it was opened from (Applications, a build folder, a disk
# image): two copies would fight over sleep. Only processes whose executable is a Kakureneko.app main executable
# match, so nothing else is touched.
running_pids() {
  local pid comm
  for pid in $(pgrep -U "$(id -u)" -x Kakureneko 2>/dev/null || true); do
    comm="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
    case "$comm" in
      */Kakureneko.app/Contents/MacOS/Kakureneko) echo "$pid" ;;
    esac
  done
  return 0   # no match is not an error (set -e would end the script at PIDS="$(running_pids)")
}

PIDS="$(running_pids)"
if [[ -n "$PIDS" ]]; then
  echo "==> quitting the running app ($PIDS)"
  # shellcheck disable=SC2086
  kill -TERM $PIDS 2>/dev/null || true
  for _ in $(seq 1 30); do
    [[ -z "$(running_pids)" ]] && break
    sleep 0.5
  done
  if [[ -n "$(running_pids)" ]]; then
    echo "Kakureneko is still running; quit it from its menu and run this script again." >&2
    exit 1
  fi
fi

echo "==> installing to $APP"
mkdir -p "$DEST"
STAGE="$DEST/.Kakureneko.app.installing"
rm -rf "$STAGE"
ditto "$SRC" "$STAGE"
rm -rf "$APP"
mv "$STAGE" "$APP"
codesign --verify --deep --strict "$APP"
# The build copy has the same bundle id: left in build/, Spotlight lists it next to the installed app and macOS may
# open it instead (a notification click, the login item). Only the installed copy stays registered.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$SRC" >/dev/null 2>&1 || true
rm -rf "$SRC"
"$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true

if [[ "$OPEN" == 1 ]]; then
  echo "==> opening $APP"
  open "$APP"
fi
echo "Installed $APP"
