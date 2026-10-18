#!/usr/bin/env bash
# Serves the website (site/) locally, laid out as it will be at https://kakureneko.com: http://localhost:4321/
# Plain static files, no build step. Ctrl-C stops it.
#
# Usage: scripts/serve-site.sh [port]      (default 4321)
set -euo pipefail
cd "$(dirname "$0")/.."
PORT="${1:-4321}"
echo "Kakureneko website: http://localhost:$PORT/"
exec python3 -m http.server "$PORT" --bind 127.0.0.1 --directory site
