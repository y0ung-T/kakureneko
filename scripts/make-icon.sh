#!/usr/bin/env bash
# Regenerates every raster brand asset from the SVG sources in "design language/artwork" (see design language/DESIGN.md):
#   Resources/AppIcon.icns                                   macOS app icon (Soot on a closed MacBook, bone tile)
#   iPhone/App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png   iOS icon, 1024 px, full bleed, opaque
#   Resources/MenuBar/<state>.png + <state>@2x.png           menu bar template images (18 pt grid, black + alpha)
#   Resources/Mascot/<pose>.svg, <pose>-sticker.svg          the Soot poses for the Mac app (vector, as drawn)
#   iPhone/App/Resources/Assets.xcassets/Mascot/<pose>.imageset   the same poses for iOS (sticker = dark appearance)
#   iPhone/NotificationService/Artwork/alert-<pose>.png      sticker poses on a paper tile: iPhone alert thumbnails
# Rendering uses AppKit's built-in SVG support (render.swift): nothing to install. build-app.sh copies the outputs
# into the bundle. OWNER: agent "app". Only writes the files above and a temporary directory.
set -euo pipefail
cd "$(dirname "$0")/.."

ART="design language/artwork"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kakureneko-icon.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

xcrun swiftc -O -swift-version 6 "$ART/render.swift" -o "$WORK/render"
xcrun swiftc -O -swift-version 6 scripts/flatten-png.swift -o "$WORK/flatten"

# macOS: the standard iconset (16 … 512 pt at 1x and 2x) from the tile-with-margins artwork.
mkdir -p "$WORK/AppIcon.iconset"
for base in 16 32 128 256 512; do
  "$WORK/render" "$ART/icon-mac.svg" "$base" "$WORK/AppIcon.iconset/icon_${base}x${base}.png"
  "$WORK/render" "$ART/icon-mac.svg" "$((base * 2))" "$WORK/AppIcon.iconset/icon_${base}x${base}@2x.png"
done
iconutil --convert icns --output Resources/AppIcon.icns "$WORK/AppIcon.iconset"
echo "Wrote Resources/AppIcon.icns"

# iOS: one 1024 px full-bleed PNG; iOS masks the corners itself and App Store Connect rejects alpha.
IOS_ICON="iPhone/App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
"$WORK/render" "$ART/icon-ios.svg" 1024 "$WORK/ios.png"
"$WORK/flatten" "$WORK/ios.png" "$IOS_ICON"
echo "Wrote $IOS_ICON"

# Menu bar: one template image per MenuBarIcon state (DESIGN.md §6 maps them to the states).
mkdir -p Resources/MenuBar
for svg in "$ART"/menubar/*.svg; do
  name="$(basename "$svg" .svg)"
  "$WORK/render" "$svg" 18 "Resources/MenuBar/$name.png"
  "$WORK/render" "$svg" 36 "Resources/MenuBar/$name@2x.png"
done
echo "Wrote Resources/MenuBar/*.png ($(ls "$ART"/menubar/*.svg | wc -l | tr -d ' ') states)"

# Soot: the poses stay vector. The Mac app loads the SVGs (NSImage, CoreSVG); the iOS asset catalog gets one image
# set per pose with the die-cut sticker variant as the dark appearance (DESIGN.md §5: dark surfaces use the sticker).
POSES=(sit peek hide coffee sleep wave)
rm -rf Resources/Mascot
mkdir -p Resources/Mascot
CATALOG="iPhone/App/Resources/Assets.xcassets/Mascot"
rm -rf "$CATALOG"
mkdir -p "$CATALOG"
printf '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n' > "$CATALOG/Contents.json"
for pose in "${POSES[@]}"; do
  cp "$ART/mascot/$pose.svg" "$ART/mascot/$pose-sticker.svg" Resources/Mascot/
  set_dir="$CATALOG/$pose.imageset"
  mkdir -p "$set_dir"
  cp "$ART/mascot/$pose.svg" "$set_dir/$pose.svg"
  cp "$ART/mascot/$pose-sticker.svg" "$set_dir/$pose-sticker.svg"
  cat > "$set_dir/Contents.json" <<JSON
{
  "images" : [
    {
      "filename" : "$pose.svg",
      "idiom" : "universal"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "filename" : "$pose-sticker.svg",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "preserves-vector-representation" : true
  }
}
JSON
done
echo "Wrote Resources/Mascot and $CATALOG (${#POSES[@]} poses)"

# iPhone alert thumbnails (DESIGN.md §7: a sticker pose on paper): wave for "needs input", sleep for the countdown.
mkdir -p iPhone/NotificationService/Artwork
for pose in wave sleep; do
  "$WORK/render" "$ART/mascot/$pose-sticker.svg" 600 "$WORK/$pose-sticker.png"
  "$WORK/flatten" "$WORK/$pose-sticker.png" "iPhone/NotificationService/Artwork/alert-$pose.png" 300
done
echo "Wrote iPhone/NotificationService/Artwork/alert-*.png"
