#!/usr/bin/env bash
# Build Kakureneko.app from the SwiftPM package (R08 §4, adapted). OWNER: agent "app".
#
# Usage: scripts/build-app.sh [release|debug]          (default: release)
# Env (defaults from scripts/release.env when present):
#   VERSION       CFBundleShortVersionString (default: release.env, else 0.1.0)
#   BUILD_NUMBER  CFBundleVersion (default: release.env, else a UTC timestamp YYYYMMDDHHMM, always increasing)
#   SIGN_ID       codesign identity. Default: the first "Apple Development:" identity from
#                 `security find-identity -v -p codesigning` (stable designated requirement → TCC grants
#                 and the login item survive rebuilds), else "-" (ad-hoc). DISTRIBUTION=1: the first
#                 "Developer ID Application:" identity (required).
#   PROFILE       Mac provisioning profile to embed (iCloud + push + Time Sensitive). Default: the one Xcode's
#                 automatic signing minted for the KakurenekoMacSigning stub (Xcode/project.yml), refreshed with
#                 `xcodebuild -allowProvisioningUpdates` when missing or about to expire. DISTRIBUTION=1:
#                 build/release/DeveloperID.provisionprofile (scripts/release-mac.sh profile; required).
#   NO_CLOUD=1    Build without iCloud: Mac notifications only, no iPhone alerts (also the automatic fallback
#                 when no profile is available, e.g. ad-hoc signing or no Xcode account).
#   DISTRIBUTION=1  The build people download (scripts/release-mac.sh runs it; docs/RELEASE.md): Developer ID,
#                 Apple silicon + Intel, secure timestamps, CloudKit and APNs Production, Sparkle's feed and key,
#                 the copyright from release.env. Notarizing is release-mac.sh's job.
#
# Output: build/Kakureneko.app
#   Contents/MacOS/Kakureneko             (SwiftPM product KakurenekoApp, renamed)
#   Contents/Helpers/kakureneko-hook        (identifier com.kakureneko.hook)
#   Contents/Helpers/kakureneko-guard       (identifier com.kakureneko.guard)
#   Contents/Frameworks/Sparkle.framework (the updater; idle in builds without a feed)
#   Contents/Info.plist, Contents/PkgInfo
#   Contents/embedded.provisionprofile    (with iCloud; see PROFILE)
# Signing is inside-out with the hardened runtime; the app gets Resources/Kakureneko.entitlements, merged with
# Resources/KakurenekoCloud.entitlements when a profile is embedded (docs/NATIVE-NOTIFICATIONS.md §6).
# This script only builds and signs. It never launches or installs anything; the only thing it may register is
# the Mac development profile, through Xcode's own account (skip with NO_CLOUD=1 or PROFILE=…).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
case "$CONFIG" in release|debug) ;; *) echo "usage: $0 [release|debug]" >&2; exit 2 ;; esac
# Release settings (version, website, Sparkle key, copyright); the environment wins over the file.
ENV_VERSION="${VERSION:-}" ENV_BUILD_NUMBER="${BUILD_NUMBER:-}"
if [[ -f scripts/release.env ]]; then
  # shellcheck disable=SC1091
  source scripts/release.env
fi
VERSION="${ENV_VERSION:-${VERSION:-0.1.0}}"
BUILD_NUMBER="${ENV_BUILD_NUMBER:-${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}}"
DISTRIBUTION="${DISTRIBUTION:-0}"
if [[ "$DISTRIBUTION" == "1" ]]; then
  [[ "$CONFIG" == "release" ]] || { echo "DISTRIBUTION=1 builds release only" >&2; exit 2; }
  [[ "${NO_CLOUD:-}" != "1" ]] || { echo "DISTRIBUTION=1 needs iCloud (unset NO_CLOUD)" >&2; exit 2; }
  if [[ -z "${SIGN_ID:-}" ]]; then
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/^.*"\(Developer ID Application: [^"]*\)".*$/\1/p' | head -n 1 || true)"
  fi
  [[ "${SIGN_ID:-}" == "Developer ID Application:"* ]] || {
    echo "DISTRIBUTION=1 needs a 'Developer ID Application' identity in the keychain (scripts/release-mac.sh check)" >&2; exit 1; }
  PROFILE="${PROFILE:-build/release/DeveloperID.provisionprofile}"
  [[ -f "$PROFILE" ]] || { echo "missing $PROFILE: run scripts/release-mac.sh profile" >&2; exit 1; }
  ARCHS=(arm64 x86_64)
else
  if [[ -z "${SIGN_ID:-}" ]]; then
    SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/^.*"\(Apple Development: [^"]*\)".*$/\1/p' | head -n 1 || true)"
    SIGN_ID="${SIGN_ID:--}"
  fi
  ARCHS=(arm64)
fi
# Secure timestamps are what notarization requires; development builds skip the round trip to Apple.
if [[ "$DISTRIBUTION" == "1" ]]; then TIMESTAMP=(--timestamp); else TIMESTAMP=(--timestamp=none); fi
APP="build/Kakureneko.app"

echo "==> swift build ($CONFIG, ${ARCHS[*]})"
BINS=()
for arch in "${ARCHS[@]}"; do
  ARCH_FLAGS=(-c "$CONFIG" --arch "$arch")
  swift build "${ARCH_FLAGS[@]}" --product KakurenekoApp
  swift build "${ARCH_FLAGS[@]}" --product kakureneko-hook
  swift build "${ARCH_FLAGS[@]}" --product kakureneko-guard
  BINS+=("$(swift build "${ARCH_FLAGS[@]}" --show-bin-path)")
done
BIN="${BINS[0]}"
# One executable per product with every architecture (lipo with a single input just copies it).
fat() { local product="$1" out="$2" inputs=() b; for b in "${BINS[@]}"; do inputs+=("$b/$product"); done
  lipo -create "${inputs[@]}" -output "$out"; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
fat KakurenekoApp "$APP/Contents/MacOS/Kakureneko"                     # CFBundleExecutable
fat kakureneko-hook "$APP/Contents/Helpers/kakureneko-hook"               # separate dir: no case clash
fat kakureneko-guard "$APP/Contents/Helpers/kakureneko-guard"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
# Links (AppLinks.swift): every build that knows the repository shows them; only Developer ID builds update themselves.
if [[ -n "${WEBSITE_URL:-}" ]]; then
  plutil -replace KakurenekoWebsiteURL -string "$WEBSITE_URL" "$APP/Contents/Info.plist"
fi
if [[ -n "${IPHONE_APP_URL:-}" ]]; then
  plutil -replace KakurenekoIPhoneAppURL -string "$IPHONE_APP_URL" "$APP/Contents/Info.plist"
fi
if [[ "$DISTRIBUTION" == "1" ]]; then
  [[ -n "${WEBSITE_URL:-}" ]] || { echo "DISTRIBUTION=1 needs WEBSITE_URL in scripts/release.env" >&2; exit 1; }
  [[ -n "${APPCAST_URL:-}" ]] || { echo "DISTRIBUTION=1 needs APPCAST_URL in scripts/release.env" >&2; exit 1; }
  [[ -n "${SPARKLE_PUBLIC_KEY:-}" ]] || { echo "DISTRIBUTION=1 needs SPARKLE_PUBLIC_KEY: run scripts/release-mac.sh keys" >&2; exit 1; }
  plutil -replace SUFeedURL -string "$APPCAST_URL" "$APP/Contents/Info.plist"
  plutil -replace SUPublicEDKey -string "$SPARKLE_PUBLIC_KEY" "$APP/Contents/Info.plist"
  # The app applies GeneralSettings.automaticUpdateChecks itself; this only keeps Sparkle from asking first.
  plutil -replace SUEnableAutomaticChecks -bool YES "$APP/Contents/Info.plist"
  if [[ -n "${COPYRIGHT:-}" ]]; then
    plutil -replace NSHumanReadableCopyright -string "$COPYRIGHT" "$APP/Contents/Info.plist"
  else
    echo "==> warning: COPYRIGHT is empty in scripts/release.env" >&2
    plutil -remove NSHumanReadableCopyright "$APP/Contents/Info.plist"
  fi
fi
plutil -lint "$APP/Contents/Info.plist" >/dev/null
# Sparkle: the binary links @rpath/Sparkle.framework; non-sandboxed apps don't need its XPC services.
SPARKLE="$(find .build/artifacts -path '*Sparkle.xcframework/macos-*/Sparkle.framework' -maxdepth 6 -type d | head -n 1)"
[[ -n "$SPARKLE" ]] || { echo "Sparkle.framework not found: run swift package resolve" >&2; exit 1; }
cp -R "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
FW="$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$FW/XPCServices" "$FW/Versions/B/XPCServices" "$FW/Headers" "$FW/Versions/B/Headers" \
  "$FW/PrivateHeaders" "$FW/Versions/B/PrivateHeaders" "$FW/Modules" "$FW/Versions/B/Modules"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Kakureneko"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# SwiftPM resource bundles, if any target ever declares resources.
for b in "$BIN"/*.bundle; do [[ -e "$b" ]] && cp -R "$b" "$APP/Contents/Resources/"; done
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  plutil -replace CFBundleIconFile -string AppIcon "$APP/Contents/Info.plist"
fi
# The design language's artwork (scripts/make-icon.sh): menu bar template glyphs and the Soot poses.
for dir in MenuBar Mascot; do
  if [[ -d "Resources/$dir" ]]; then cp -R "Resources/$dir" "$APP/Contents/Resources/$dir"; fi
done

# The Mac provisioning profile for iCloud (nothing to do for ad-hoc signing: a profile needs a real identity).
STUB_PROFILE="build/xcode/Build/Products/Debug/KakurenekoMacSigning.app/Contents/embedded.provisionprofile"
profile_valid_for_a_day() {
  local expires
  expires="$(security cms -D -i "$1" 2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null || true)"
  [[ -n "$expires" ]] || return 1
  local expiry_epoch
  expiry_epoch="$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$expires" +%s 2>/dev/null || echo 0)"
  (( expiry_epoch > $(date +%s) + 86400 ))
}
if [[ "$DISTRIBUTION" != "1" && "${NO_CLOUD:-}" != "1" && "$SIGN_ID" != "-" && -z "${PROFILE:-}" ]]; then
  if ! { [[ -f "$STUB_PROFILE" ]] && profile_valid_for_a_day "$STUB_PROFILE"; }; then
    if command -v xcodegen >/dev/null && command -v xcodebuild >/dev/null; then
      echo "==> refreshing the Mac provisioning profile (Xcode automatic signing)"
      xcodegen generate --quiet --spec Xcode/project.yml >/dev/null 2>&1 || true
      xcodebuild -quiet -project Xcode/Kakureneko.xcodeproj -scheme KakurenekoMacSigning -configuration Debug \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath build/xcode \
        -allowProvisioningUpdates -allowProvisioningDeviceRegistration build >/dev/null 2>&1 || true
    fi
  fi
  [[ -f "$STUB_PROFILE" ]] && profile_valid_for_a_day "$STUB_PROFILE" && PROFILE="$STUB_PROFILE"
  if [[ -z "${PROFILE:-}" ]]; then
    echo "==> iCloud: Xcode could not make the Mac profile, so iPhone alerts won't work in this build." >&2
    if [[ -z "$(defaults read com.apple.dt.Xcode DVTDeveloperAccountManagerAppleIDLists 2>/dev/null | grep -E '@|identifier')" ]]; then
      echo "    Xcode has no Apple account: sign in under Xcode → Settings → Accounts, then run this again." >&2
    else
      echo "    See why: xcodebuild -project Xcode/Kakureneko.xcodeproj -scheme KakurenekoMacSigning -allowProvisioningUpdates build" >&2
    fi
  fi
fi
# The signing identity must be one of the profile's certificates, or macOS kills the app at launch (codesign
# --verify would still pass). SHA-1 of the identity vs. SHA-1 of every DeveloperCertificates entry.
profile_lists_identity() {
  local identity_sha i cert_sha
  identity_sha="$(security find-identity -v -p codesigning 2>/dev/null | grep -F "\"$SIGN_ID\"" | awk '{print $2}' | head -n 1)"
  [[ -n "$identity_sha" ]] || return 1
  local decoded
  decoded="$(mktemp -t kakureneko-profile)"
  security cms -D -i "$1" -o "$decoded" 2>/dev/null || { rm -f "$decoded"; return 1; }
  for i in 0 1 2 3 4 5 6 7 8 9; do
    cert_sha="$(plutil -extract "DeveloperCertificates.$i" raw -o - "$decoded" 2>/dev/null | base64 -D 2>/dev/null \
      | shasum -a 1 | awk '{print toupper($1)}')" || break
    [[ "$cert_sha" == "DA39A3EE5E6B4B0D3255BFEF95601890AFD80709" ]] && break # empty input: no more certificates
    if [[ "$cert_sha" == "$identity_sha" ]]; then rm -f "$decoded"; return 0; fi
  done
  rm -f "$decoded"
  return 1
}
if [[ "${NO_CLOUD:-}" != "1" && -n "${PROFILE:-}" ]] && ! profile_lists_identity "$PROFILE"; then
  if [[ "$DISTRIBUTION" == "1" ]]; then
    echo "the profile $PROFILE does not list '$SIGN_ID': run scripts/release-mac.sh profile again" >&2
    exit 1
  fi
  echo "==> iCloud: the profile does not list '$SIGN_ID'; building without iCloud" >&2
  PROFILE=""
fi
ENTITLEMENTS="Resources/Kakureneko.entitlements"
if [[ "${NO_CLOUD:-}" != "1" && -n "${PROFILE:-}" ]]; then
  cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
  ENTITLEMENTS="build/Kakureneko.entitlements"
  cp Resources/Kakureneko.entitlements "$ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Merge Resources/KakurenekoCloud.entitlements" "$ENTITLEMENTS" >/dev/null
  if [[ "$DISTRIBUTION" == "1" ]]; then
    # The download talks to CloudKit Production and the production APNs, like the App Store iPhone app.
    # (PlistBuddy, not plutil: entitlement keys contain dots, which plutil reads as a key path.)
    /usr/libexec/PlistBuddy -c "Set :com.apple.developer.aps-environment production" "$ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Delete :com.apple.developer.icloud-container-environment" "$ENTITLEMENTS" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :com.apple.developer.icloud-container-environment string Production" "$ENTITLEMENTS"
    # Only keys the Developer ID profile grants (Time Sensitive may not be among them): an ungranted key kills
    # the app at launch.
    granted="$(mktemp -t kakureneko-granted)"
    security cms -D -i "$PROFILE" -o "$granted"
    for key in com.apple.developer.usernotifications.time-sensitive; do
      if ! /usr/libexec/PlistBuddy -c "Print :Entitlements:$key" "$granted" >/dev/null 2>&1; then
        echo "==> warning: the profile does not grant $key; signing without it" >&2
        /usr/libexec/PlistBuddy -c "Delete :$key" "$ENTITLEMENTS"
      fi
    done
    rm -f "$granted"
  fi
  echo "==> iCloud: embedded $(security cms -D -i "$PROFILE" | plutil -extract Name raw -o - -)"
else
  echo "==> iCloud: off for this build (Mac notifications only)"
fi

echo "==> signing inside-out with '$SIGN_ID'"
codesign --force --sign "$SIGN_ID" "${TIMESTAMP[@]}" --options runtime "$FW/Versions/B/Autoupdate"
codesign --force --sign "$SIGN_ID" "${TIMESTAMP[@]}" --options runtime "$FW/Versions/B/Updater.app"
codesign --force --sign "$SIGN_ID" "${TIMESTAMP[@]}" --options runtime "$FW"
codesign --force --sign "$SIGN_ID" "${TIMESTAMP[@]}" --options runtime \
  --identifier com.kakureneko.hook "$APP/Contents/Helpers/kakureneko-hook"
codesign --force --sign "$SIGN_ID" "${TIMESTAMP[@]}" --options runtime \
  --identifier com.kakureneko.guard "$APP/Contents/Helpers/kakureneko-guard"
codesign --force --sign "$SIGN_ID" "${TIMESTAMP[@]}" --options runtime \
  --entitlements "$ENTITLEMENTS" "$APP"

echo "==> verifying"
codesign --verify --deep --strict --verbose=2 "$APP"
if [[ "$DISTRIBUTION" == "1" ]]; then
  for exe in "$APP/Contents/MacOS/Kakureneko" "$APP/Contents/Helpers/kakureneko-hook" "$APP/Contents/Helpers/kakureneko-guard"; do
    lipo "$exe" -verify_arch arm64 x86_64 || { echo "$exe is not universal" >&2; exit 1; }
  done
fi
echo "Built $APP ($VERSION/$BUILD_NUMBER, $CONFIG, ${ARCHS[*]}, signed with '$SIGN_ID')"
