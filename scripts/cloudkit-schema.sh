#!/usr/bin/env bash
# Apply Kakureneko's CloudKit schema (Xcode/CloudKit/schema.ckdb) with Apple's cktool (docs/NATIVE-NOTIFICATIONS.md §3).
#
# Usage: scripts/cloudkit-schema.sh [validate|import|export]      (default: validate)
#   validate  check the file against the development environment
#   import    replace the DEVELOPMENT schema with the file (record types, fields, indexes, creator-only permissions)
#   export    print the current development schema
# Production is never touched here: deploy the development schema in the CloudKit Console ("Deploy Schema
# Changes") before the first TestFlight / Developer ID build.
#
# Needs a CloudKit management token saved once with `xcrun cktool save-token --type management` (create it in the
# CloudKit Console: account menu → Manage Tokens). Env: TEAM_ID (default 7NRW73MYQZ), CONTAINER_ID.
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-validate}"
TEAM_ID="${TEAM_ID:-7NRW73MYQZ}"
CONTAINER_ID="${CONTAINER_ID:-iCloud.com.kakureneko.Kakureneko}"
FILE="Xcode/CloudKit/schema.ckdb"
ARGS=(--team-id "$TEAM_ID" --container-id "$CONTAINER_ID" --environment development)

case "$MODE" in
  validate) xcrun cktool validate-schema "${ARGS[@]}" --file "$FILE" ;;
  import)   xcrun cktool import-schema "${ARGS[@]}" --file "$FILE" && echo "Imported $FILE into the development environment." ;;
  export)   xcrun cktool export-schema "${ARGS[@]}" ;;
  *) echo "usage: $0 [validate|import|export]" >&2; exit 2 ;;
esac
