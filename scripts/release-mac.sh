#!/usr/bin/env bash
# Release the Mac app: Developer ID build → notarized, stapled Kakureneko.app and Kakureneko-<version>.dmg → GitHub
# Release v<version> with the disk image → Sparkle appcast entry in appcast.xml (docs/RELEASE.md). OWNER: agent "app".
#
# HUMAN-RUN: `notarize` and `all` upload to Apple's notary service and `publish` to GitHub; `keys` and `profile` use
# your keychain and your Xcode account. Automated agents only run `check`.
#
# Usage: scripts/release-mac.sh <command>
#   check     what's ready and what's missing (Developer ID identity, profile, notary profile, Sparkle key, settings)
#   keys      create (or show) Sparkle's EdDSA signing key in your login keychain; writes the public key into
#             scripts/release.env. Back the private key up: `generate_keys -x <file>` (losing it means users can't
#             update to builds signed with a new key).
#   profile   the Developer ID provisioning profile (iCloud + push) through Xcode's automatic signing: archives the
#             KakurenekoMacSigning stub and exports it with method developer-id → build/release/DeveloperID.provisionprofile
#   build     DISTRIBUTION=1 scripts/build-app.sh (universal, Developer ID, production iCloud)
#   notarize  notarize + staple the app, make the disk image, sign it, notarize + staple it, verify with Gatekeeper
#   publish   attach the disk image to the GitHub Release v<version> (gh; created if missing) as
#             Kakureneko-<version>.dmg and Kakureneko.dmg, and add the signed update to appcast.xml. Commit and push
#             appcast.xml afterwards: installed copies read it from the main branch (APPCAST_URL).
#   all       check, build, notarize, publish
# Settings: scripts/release.env (VERSION, WEBSITE_URL, APPCAST_URL, SPARKLE_PUBLIC_KEY, NOTARY_PROFILE, TEAM_ID,
# COPYRIGHT). Release notes: docs/release-notes/<VERSION>.md when it exists (the GitHub Release's text).
set -euo pipefail
cd "$(dirname "$0")/.."

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//' >&2; }
COMMAND="${1:-}"
case "$COMMAND" in check|keys|profile|build|notarize|publish|all) ;; *) usage; exit 2 ;; esac

# shellcheck disable=SC1091
source scripts/release.env
TEAM_ID="${TEAM_ID:-7NRW73MYQZ}"
NOTARY_PROFILE="${NOTARY_PROFILE:-kakureneko-notary}"
OUT="build/release"
APP="build/Kakureneko.app"
PROFILE_OUT="$OUT/DeveloperID.provisionprofile"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
mkdir -p "$OUT"

developer_id() {
  security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/^.*"\(Developer ID Application: [^"]*\)".*$/\1/p' | head -n 1 || true
}

app_version() { plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist"; }
app_build() { plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist"; }

# MARK: check

check() {
  local missing=0
  ok() { echo "  ✓ $*"; }
  todo() { echo "  ✗ $*"; missing=1; }
  echo "==> release check (version ${VERSION:-?})"
  local id; id="$(developer_id)"
  if [[ -n "$id" ]]; then ok "signing identity: $id"; else
    todo "no 'Developer ID Application' identity in the keychain. Xcode → Settings → Accounts → your team →"
    echo "      Manage Certificates… → + → Developer ID Application (the Account Holder can create it)."
  fi
  if [[ -f "$PROFILE_OUT" ]]; then
    local name expires
    name="$(security cms -D -i "$PROFILE_OUT" 2>/dev/null | plutil -extract Name raw -o - - 2>/dev/null || echo '?')"
    expires="$(security cms -D -i "$PROFILE_OUT" 2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null || echo '?')"
    ok "provisioning profile: $name (expires $expires)"
  else
    todo "no Developer ID provisioning profile: scripts/release-mac.sh profile"
  fi
  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    ok "notary profile '$NOTARY_PROFILE'"
  else
    todo "no notary credentials '$NOTARY_PROFILE'. Make an app-specific password at account.apple.com → Sign-In and"
    echo "      Security → App-Specific Passwords, then run (it asks for the password):"
    echo "      xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <your Apple Account> --team-id $TEAM_ID"
  fi
  if [[ -n "${SPARKLE_PUBLIC_KEY:-}" ]]; then ok "Sparkle public key"; else todo "no Sparkle key: scripts/release-mac.sh keys"; fi
  if [[ -n "${WEBSITE_URL:-}" ]]; then ok "repository: $WEBSITE_URL"; else todo "WEBSITE_URL is empty in scripts/release.env"; fi
  if [[ -n "${APPCAST_URL:-}" ]]; then ok "update feed: $APPCAST_URL"; else todo "APPCAST_URL is empty in scripts/release.env"; fi
  if gh auth status >/dev/null 2>&1; then ok "GitHub CLI signed in"; else todo "gh isn't signed in: gh auth login"; fi
  if [[ -n "${COPYRIGHT:-}" ]]; then ok "copyright: $COPYRIGHT"; else todo "COPYRIGHT is empty in scripts/release.env"; fi
  if [[ -n "${IPHONE_APP_URL:-}" ]]; then ok "iPhone app: $IPHONE_APP_URL"; else
    echo "  · IPHONE_APP_URL is empty: the Mac app links to the README's iPhone section (fine without a TestFlight link)"
  fi
  if [[ -f "docs/release-notes/${VERSION:-}.md" ]]; then ok "release notes docs/release-notes/$VERSION.md"; else
    echo "  · no docs/release-notes/${VERSION:-<version>}.md: the GitHub Release gets a one-line description"
  fi
  return "$missing"
}

# MARK: keys

keys() {
  [[ -x "$SPARKLE_BIN/generate_keys" ]] || swift package resolve
  echo "==> Sparkle signing key (login keychain)"
  "$SPARKLE_BIN/generate_keys" >/dev/null
  local key; key="$("$SPARKLE_BIN/generate_keys" -p)"
  [[ -n "$key" ]] || { echo "generate_keys printed no public key" >&2; exit 1; }
  /usr/bin/sed -i '' "s|^SPARKLE_PUBLIC_KEY=.*$|SPARKLE_PUBLIC_KEY=$key|" scripts/release.env
  echo "SPARKLE_PUBLIC_KEY=$key (written to scripts/release.env)"
  echo "Back up the private key somewhere safe: $SPARKLE_BIN/generate_keys -x <file>"
}

# MARK: profile

profile() {
  command -v xcodegen >/dev/null || { echo "xcodegen is missing: brew install xcodegen" >&2; exit 1; }
  [[ -n "$(developer_id)" ]] || { echo "no Developer ID Application identity (see: scripts/release-mac.sh check)" >&2; exit 1; }
  xcodegen generate --quiet --spec Xcode/project.yml
  local archive="$OUT/KakurenekoMacSigning.xcarchive" export_dir="$OUT/KakurenekoMacSigning-export"
  rm -rf "$archive" "$export_dir"
  echo "==> archiving the signing stub"
  xcodebuild -quiet -project Xcode/Kakureneko.xcodeproj -scheme KakurenekoMacSigning -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$archive" -derivedDataPath build/xcode-release \
    -allowProvisioningUpdates archive
  cat > "$OUT/ExportOptions-developer-id.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM_ID</string>
</dict>
</plist>
PLIST
  echo "==> exporting with Developer ID (Xcode makes the profile)"
  xcodebuild -quiet -exportArchive -archivePath "$archive" -exportPath "$export_dir" \
    -exportOptionsPlist "$OUT/ExportOptions-developer-id.plist" -allowProvisioningUpdates
  local embedded="$export_dir/KakurenekoMacSigning.app/Contents/embedded.provisionprofile"
  [[ -f "$embedded" ]] || { echo "the export has no embedded profile ($embedded)" >&2; exit 1; }
  cp "$embedded" "$PROFILE_OUT"
  local decoded; decoded="$(mktemp -t kakureneko-profile)"
  security cms -D -i "$PROFILE_OUT" -o "$decoded"
  echo "==> $(plutil -extract Name raw -o - "$decoded") → $PROFILE_OUT"
  for key in com.apple.developer.icloud-container-identifiers com.apple.developer.aps-environment \
             com.apple.developer.icloud-container-environment com.apple.developer.usernotifications.time-sensitive; do
    if /usr/libexec/PlistBuddy -c "Print :Entitlements:$key" "$decoded" >/dev/null 2>&1; then
      echo "  grants $key"
    else
      echo "  does NOT grant $key"
    fi
  done
  rm -f "$decoded"
}

# MARK: build

build() {
  DISTRIBUTION=1 scripts/build-app.sh release
  echo "==> entitlements of the build"
  codesign -d --entitlements - --xml "$APP" 2>/dev/null | plutil -p - | grep -E "aps-environment|container-environment|time-sensitive" || true
}

# MARK: notarize

notarize_file() {
  echo "==> notarizing $(basename "$1") (this takes a few minutes)"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
}

notarize() {
  [[ -d "$APP" ]] || { echo "no $APP: run scripts/release-mac.sh build" >&2; exit 1; }
  # The Authority lines only appear at -vv; read the output whole (grep -q would cut the pipe short under pipefail).
  local signature; signature="$(codesign -dvv "$APP" 2>&1)"
  [[ "$signature" == *"Authority=Developer ID Application"* ]] \
    || { echo "$APP is not a Developer ID build: run scripts/release-mac.sh build" >&2; exit 1; }
  local version id zip dmg stage
  version="$(app_version)"
  id="$(developer_id)"
  zip="$OUT/Kakureneko-$version.zip"
  dmg="$OUT/Kakureneko-$version.dmg"
  stage="$OUT/dmg"
  rm -f "$zip" "$dmg"
  ditto -c -k --keepParent "$APP" "$zip"
  notarize_file "$zip"
  xcrun stapler staple "$APP"
  rm -f "$zip"
  echo "==> disk image"
  rm -rf "$stage"
  mkdir -p "$stage"
  ditto "$APP" "$stage/Kakureneko.app"
  ln -s /Applications "$stage/Applications"
  hdiutil create -quiet -volname "Kakureneko" -srcfolder "$stage" -ov -format UDZO "$dmg"
  rm -rf "$stage"
  codesign --force --sign "$id" --timestamp "$dmg"
  notarize_file "$dmg"
  xcrun stapler staple "$dmg"
  echo "==> Gatekeeper"
  spctl --assess --type execute --verbose=2 "$APP"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
  echo "Notarized $dmg"
}

# MARK: publish

publish() {
  [[ -n "${WEBSITE_URL:-}" ]] || { echo "WEBSITE_URL is empty in scripts/release.env" >&2; exit 1; }
  local version build tag dmg stable signature notes
  version="$(app_version)"
  build="$(app_build)"
  tag="v$version"
  notes="docs/release-notes/$version.md"
  dmg="$OUT/Kakureneko-$version.dmg"
  [[ -f "$dmg" ]] || { echo "no $dmg: run scripts/release-mac.sh notarize" >&2; exit 1; }
  xcrun stapler validate "$dmg" >/dev/null || { echo "$dmg is not notarized and stapled" >&2; exit 1; }
  # `sparkle:edSignature="…" length="…"`, signed with the private key in the login keychain.
  signature="$("$SPARKLE_BIN/sign_update" "$dmg")"
  [[ "$signature" == *edSignature* ]] || { echo "sign_update failed: $signature" >&2; exit 1; }
  # The README's download button: <repository>/releases/latest/download/Kakureneko.dmg.
  stable="$OUT/latest/Kakureneko.dmg"
  mkdir -p "$OUT/latest"
  cp "$dmg" "$stable"
  if gh release view "$tag" >/dev/null 2>&1; then
    gh release upload "$tag" "$dmg" "$stable" --clobber
  elif [[ -f "$notes" ]]; then
    gh release create "$tag" "$dmg" "$stable" --title "Kakureneko $version" --notes-file "$notes"
  else
    gh release create "$tag" "$dmg" "$stable" --title "Kakureneko $version" \
      --notes "Kakureneko for Mac $version. Download Kakureneko.dmg, open it and drag Kakureneko to Applications."
  fi
  python3 - "$version" "$build" "${WEBSITE_URL%/}/releases/download/$tag/Kakureneko-$version.dmg" "$signature" \
    "${WEBSITE_URL%/}/releases/tag/$tag" <<'PY'
import email.utils, pathlib, re, sys
version, build, url, signature, notes = sys.argv[1:6]
path = pathlib.Path("appcast.xml")
head = ('<?xml version="1.0" encoding="utf-8"?>\n'
        '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
        '  <channel>\n    <title>Kakureneko</title>\n')
text = path.read_text() if path.exists() else head + "  </channel>\n</rss>\n"
# One entry per build: publishing the same build again replaces it.
text = re.sub(r"\s*<item>(?:(?!</item>).)*<sparkle:version>%s</sparkle:version>.*?</item>" % re.escape(build), "", text, flags=re.S)
item = f"""
    <item>
      <title>Kakureneko {version}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>{notes}</sparkle:fullReleaseNotesLink>
      <enclosure url="{url}" type="application/octet-stream" {signature} />
    </item>"""
marker = "    <title>Kakureneko</title>\n"
text = text.replace(marker, marker + item.lstrip("\n") + "\n", 1) if marker in text else text.replace("<channel>", "<channel>" + item, 1)
path.write_text(text)
PY
  xmllint --noout appcast.xml
  echo "Published $version ($build): GitHub Release $tag, appcast.xml"
  echo "Commit and push appcast.xml to make the update live."
}

case "$COMMAND" in
  check) check ;;
  keys) keys ;;
  profile) profile ;;
  build) build ;;
  notarize) notarize ;;
  publish) publish ;;
  all) check && build && notarize && publish ;;
esac
