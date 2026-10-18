#!/usr/bin/env bash
# Build, test, install, archive or upload Kakureneko for iPhone (Xcode/project.yml → Xcode/Kakureneko.xcodeproj,
# generated here with XcodeGen). OWNER: agent "phone". See docs/IPHONE-APP.md ("Build, test, ship").
#
# Usage: scripts/build-phone.sh [build|test|install|archive|upload]      (default: build)
#   build    Debug build for the connected iPhone, signed automatically (registers the device / refreshes the
#            provisioning profiles of the existing App IDs when needed). Nothing is installed.
#   test     KakurenekoPhoneTests on the iOS Simulator (fakes only: no iCloud, no device).
#   install  build, then install onto the iPhone with devicectl (does not launch it). Run by a human.
#   archive  Release archive for TestFlight / App Store → build/KakurenekoPhone.xcarchive, with the release version
#            and build number (below). Prints the archived app's push / iCloud environments. Run by a human.
#   upload   archive, then export it straight to App Store Connect (xcodebuild -exportArchive, method
#            app-store-connect, destination upload, automatic signing, team 7NRW73MYQZ; options written to
#            build/ExportOptions.plist). Prints the uploaded build's push / iCloud environments: both must say
#            "production" / "Production". Run by a human (needs the Apple Account signed in to Xcode).
#
# Release numbers (archive and upload only): scripts/release.env, if it exists, is sourced for
#   VERSION=1.0.0          → MARKETING_VERSION (CFBundleShortVersionString); default: Xcode/project.yml's
#   BUILD_NUMBER=…         → CURRENT_PROJECT_VERSION (CFBundleVersion); default: UTC `date -u +%Y%m%d%H%M`, so every
#                            upload's build number is higher than the last
#   WEBSITE_URL=https://…  → KAKURENEKO_WEBSITE_URL (the app's privacy / support / Mac links; every mode); default:
#                            Xcode/project.yml's https://kakureneko.com
# Variables already set in the environment win over the file. Nothing else the file sets reaches this script.
#
# Env:
#   DEVICE_ID   the iPhone's identifier (default 00008150-001221493C04401C; `xcrun devicectl list devices`)
#   SIMULATOR   simulator name for `test` (default "iPhone 17")
#
# Output: build/xcode (derived data; the app is build/xcode/Build/Products/Debug-iphoneos/Kakureneko.app),
#         build/KakurenekoPhone.xcarchive, build/export (upload summary).
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-build}"
DEVICE_ID="${DEVICE_ID:-00008150-001221493C04401C}"
SIMULATOR="${SIMULATOR:-iPhone 17}"
PROJECT="Xcode/Kakureneko.xcodeproj"
SCHEME="KakurenekoPhone"
DERIVED="build/xcode"
APP="$DERIVED/Build/Products/Debug-iphoneos/Kakureneko.app"
ARCHIVE="build/KakurenekoPhone.xcarchive"
EXPORT_DIR="build/export"
EXPORT_OPTIONS="build/ExportOptions.plist"
TEAM_ID="7NRW73MYQZ"
RELEASE_ENV="scripts/release.env"

case "$MODE" in build|test|install|archive|upload) ;; *) echo "usage: $0 [build|test|install|archive|upload]" >&2; exit 2 ;; esac
command -v xcodegen >/dev/null || { echo "xcodegen is missing: brew install xcodegen" >&2; exit 1; }

# Release numbers: sourced in a subshell, so only these three values come back.
if [[ -f "$RELEASE_ENV" ]]; then
  eval "$(
    set +u
    # shellcheck disable=SC1090
    source "$RELEASE_ENV" >/dev/null
    printf 'FILE_VERSION=%q\nFILE_BUILD_NUMBER=%q\nFILE_WEBSITE_URL=%q\n' "${VERSION:-}" "${BUILD_NUMBER:-}" "${WEBSITE_URL:-}"
  )"
fi
VERSION="${VERSION:-${FILE_VERSION:-}}"
BUILD_NUMBER="${BUILD_NUMBER:-${FILE_BUILD_NUMBER:-}}"
WEBSITE_URL="${WEBSITE_URL:-${FILE_WEBSITE_URL:-}}"

# Overrides for every xcodebuild call (the website), and for release builds (version, build number).
COMMON_OVERRIDES=()
[[ -n "$WEBSITE_URL" ]] && COMMON_OVERRIDES+=("KAKURENEKO_WEBSITE_URL=$WEBSITE_URL")

echo "==> xcodegen"
xcodegen generate --spec Xcode/project.yml --quiet

# The version and a build number newer than the installed one, for device builds too: iOS refreshes an app's cached
# icon and name (home screen, notifications) only when CFBundleVersion changes, so a reinstall with the same build
# number keeps showing the old icon.
version_overrides() {
  echo "CURRENT_PROJECT_VERSION=${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
  [[ -n "$VERSION" ]] && echo "MARKETING_VERSION=$VERSION"
  return 0
}

build_for_device() {
  local versions=()
  while IFS= read -r line; do versions+=("$line"); done < <(version_overrides)
  echo "==> xcodebuild build (Debug, device $DEVICE_ID: ${versions[*]})"
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
    -destination "platform=iOS,id=$DEVICE_ID" -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    "${versions[@]}" ${COMMON_OVERRIDES[@]+"${COMMON_OVERRIDES[@]}"} build
}

# One entitlement of a signed bundle ("(none)" when absent).
entitlement() { # <entitlements plist on stdin> <key>
  plutil -extract "$1" raw -o - - 2>/dev/null || echo "(none)"
}

# The push and iCloud environments a signed .app carries.
print_app_environments() { # <app>
  local app="$1" entitlements
  entitlements="$(codesign -d --entitlements :- "$app" 2>/dev/null)" || { echo "  (could not read the entitlements of $app)"; return; }
  echo "  aps-environment:                                  $(entitlement aps-environment <<<"$entitlements")"
  echo "  com.apple.developer.icloud-container-environment: $(entitlement com.apple.developer.icloud-container-environment <<<"$entitlements")"
}

archive() {
  local version_overrides=()
  while IFS= read -r line; do version_overrides+=("$line"); done < <(version_overrides)
  echo "==> xcodebuild archive (Release: ${version_overrides[*]}${WEBSITE_URL:+, website $WEBSITE_URL})"
  rm -rf "$ARCHIVE"
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination "generic/platform=iOS" -derivedDataPath "$DERIVED" \
    -archivePath "$ARCHIVE" -allowProvisioningUpdates \
    "${version_overrides[@]}" ${COMMON_OVERRIDES[@]+"${COMMON_OVERRIDES[@]}"} archive
  local app="$ARCHIVE/Products/Applications/Kakureneko.app"
  echo "Archived $ARCHIVE: version $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Info.plist")" \
       "($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Info.plist"))"
  echo "The archived app's entitlements (the archive is development-signed; the App Store export re-signs it for production):"
  print_app_environments "$app"
}

write_export_options() {
  mkdir -p build
  cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>upload</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
PLIST
  plutil -lint -s "$EXPORT_OPTIONS"
}

# What the export actually signed: DistributionSummary.plist lists each bundle's entitlements (an upload leaves no
# .ipa behind); an exported .ipa, if any, is checked with codesign too.
print_export_environments() {
  local summary="$EXPORT_DIR/DistributionSummary.plist" ipa
  if [[ -f "$summary" ]]; then
    echo "The uploaded build's entitlements ($summary):"
    /usr/bin/python3 - "$summary" <<'PY'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    summary = plistlib.load(f)
def show(bundle):
    entitlements = bundle.get("entitlements", {})
    print(f"  {bundle.get('name', '?')}:")
    for key in ("aps-environment", "com.apple.developer.icloud-container-environment"):
        print(f"    {key}: {entitlements.get(key, '(none)')}")
    for inner in bundle.get("embeddedBinaries", []):
        show(inner)
for bundles in summary.values():
    for bundle in bundles:
        show(bundle)
PY
  fi
  ipa="$(find "$EXPORT_DIR" -maxdepth 1 -name '*.ipa' -print -quit 2>/dev/null || true)"
  if [[ -n "$ipa" ]]; then
    local unpacked; unpacked="$(mktemp -d)"
    unzip -q "$ipa" -d "$unpacked"
    echo "The exported app's entitlements ($ipa):"
    print_app_environments "$unpacked/Payload/Kakureneko.app"
    rm -rf "$unpacked"
  fi
  [[ -f "$summary" || -n "$ipa" ]] || echo "  (no DistributionSummary.plist or .ipa in $EXPORT_DIR to check)"
}

case "$MODE" in
  build)
    build_for_device
    echo "Built $APP"
    ;;
  test)
    echo "==> xcodebuild test (simulator '$SIMULATOR')"
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
      -destination "platform=iOS Simulator,name=$SIMULATOR" -derivedDataPath "$DERIVED" \
      ${COMMON_OVERRIDES[@]+"${COMMON_OVERRIDES[@]}"} test
    ;;
  install)
    build_for_device
    echo "==> installing onto $DEVICE_ID"
    xcrun devicectl device install app --device "$DEVICE_ID" "$APP"
    echo "Installed Kakureneko on $DEVICE_ID (open it from the Home Screen)"
    ;;
  archive)
    archive
    echo "Upload with: scripts/build-phone.sh upload (or Xcode's Organizer)"
    ;;
  upload)
    archive
    write_export_options
    echo "==> xcodebuild -exportArchive (App Store Connect upload)"
    rm -rf "$EXPORT_DIR"
    xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$EXPORT_OPTIONS" \
      -exportPath "$EXPORT_DIR" -allowProvisioningUpdates
    print_export_environments
    echo "Uploaded. It shows in App Store Connect → TestFlight once processed. Both values above must be production."
    ;;
esac
