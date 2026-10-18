# Kakureneko — design

Everything visual lives here. Start with **`DESIGN.md`** (the written language: colour, type, illustration, icons,
components, motion, voice). The two live documents:

| | Link |
|---|---|
| **Design** canvas: app icon, menu bar states, Soot sheet, six iPhone screens, five Mac screens, product page mockup | https://claude.ai/artifact/GgThvEPKMv1J2hVSCpYWSL |
| **Design Language** page: the written language with live specimens, swatches and both theme variants | https://claude.ai/artifact/RjcbAeBNfrSV3SjqwAq1TP |

Both are private until shared from their Share menu.

## What is where

```
*.jpeg                 the reference sheet (silly black-cat stickers, linocut ink, the black + yellow + pink logo)
DESIGN.md              the design language (binding)
artwork/generate.py    draws every SVG from one scene: run `python3 "design language/artwork/generate.py" "design language/artwork"`
artwork/render.swift   SVG → PNG with alpha, AppKit's built-in SVG support (used by scripts/make-icon.sh)
artwork/icon-mac.svg   the shipped macOS icon (tile with margins); icon-ios.svg the full-bleed iOS icon
artwork/icon-mac-amber.svg, icon-mac-ink.svg   explored alternatives, not shipped
artwork/menubar/       nine template-image glyphs (idle, working, keepawake, waiting, attention, countdown, asleep, shutdown, off)
artwork/mascot/        six Soot poses (sit, peek, hide, coffee, sleep, wave), each also as *-sticker.svg for dark surfaces
artwork/wordmark/      wordmark.svg ("kakureneko", Manrope Bold outlines), wordmark.swift (CoreText → SVG), the OFL font file;
                       wordmark-semibold.svg and wordmark-capitalised.svg are explored alternatives
archive-v0/            the previous moon-and-laptop placeholder icon and its scripts
```

Regenerating the wordmark (run in `artwork/wordmark/`): `swift wordmark.swift "Manrope[wght].ttf" kakureneko 700
wordmark.svg -1.2` (the semibold variant is weight 600, the capitalised one "Kakureneko"; both tracking −0.6). Copy
`wordmark.svg` to `site/assets/wordmark.svg`, and the same file with `fill="#F4F2EC"` to `site/assets/wordmark-light.svg`.

Rasters the build uses (regenerate with `scripts/make-icon.sh`, never hand-edit):

* `Resources/AppIcon.icns`: the macOS iconset.
* `iPhone/App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png`: 1024 px, opaque.
* `Resources/MenuBar/<state>.png` and `<state>@2x.png`: 18 pt template images.

## Where the code uses it

* **Colours and buttons:** `Sources/KakurenekoApp/Views/Palette.swift` (Mac) and `iPhone/App/Views/Palette.swift`
  (iPhone) hold the §2 tokens, the state colours behind `Tone` / `Tint`, the amber primary buttons and `MascotView`.
  `Tests/KakurenekoAppTests/DesignTokensTests.swift` pins the hex values and checks every state text for 4.5:1.
* **Menu bar:** `MenuBarIcon.imageName` names the template glyph per state; `MenuBarLabel` and the menu header load
  it from `Contents/Resources/MenuBar` (`Artwork.menuBarGlyph`), the SF Symbol is the fallback outside the bundle.
* **Soot:** the Mac loads `Contents/Resources/Mascot/<pose>.svg` (the `-sticker` file in dark mode); the iPhone
  uses the `Mascot/<pose>` image sets (sticker = dark appearance); the iPhone alert thumbnails are
  `iPhone/NotificationService/Artwork/alert-wave.png` and `alert-sleep.png`. `scripts/make-icon.sh` writes all of
  them; `scripts/build-app.sh` copies `Resources/MenuBar` and `Resources/Mascot` into the app.
* **Checking the iPhone screens without iCloud:** Debug builds on the Simulator accept
  `-KakurenekoDemo oneMac|severalMacs|countdown|stale|noMac|noICloud|firstRun` (plus `-KakurenekoDemoTab activity|settings`)
  and run on the preview fixtures.
