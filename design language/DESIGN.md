# Kakureneko — design language (binding for every screen, icon and page)

Written 2026-10-17 from the reference sheet in this folder (silly black-cat stickers, linocut ink, one bold logo in
black + yellow + pink). It covers the Mac menu bar app, the iPhone app, the notifications and the product page.
Visual version: the "Design" canvas (app icon, menu bar states, mascot sheet, iPhone and Mac screens, product page
mockup) and the "Design Language" page, both linked from `README.md` beside this file.
Where this document and the code disagree on a colour, a word or a symbol, this document wins; where it is
silent, Apple's Human Interface Guidelines win.

---

## 1. The idea

**Kakureneko is a black cat that keeps watch while you are away.** You close the lid and leave; the cat stays on the
laptop, alert, eyes open, until your agents are done, then it lets the Mac sleep and lets you know. It hides (in a box,
in a bag, under a lid), which is what the name says: kakureneko (隠れ猫) is Japanese for "hiding cat". It stares, it
never says much. The mascot is called **Soot** (a working name; rename it in
one place, here).

Three rules follow from the metaphor:

1. **The eyes are the status light.** Open and amber = awake and working. Half-closed = sleeping soon. Closed =
   nothing to do. Crossed out = shutting down. Nothing else about Soot changes between states.
2. **Ink on paper.** Everything is a black silhouette with a faint print grain on a bone-white ground with one
   amber accent. No gradients, no soft shadows, no gloss. Depth comes from overlap, not from blur.
3. **The product is quiet, the cat is silly.** Copy is plain and dry. The jokes are visual and live in the
   illustrations, never in button labels or alerts.

## 2. Colour

Hex values are sRGB. Light and dark are two palettes, not an inversion: the cat stays ink in both.

| Token | Light | Dark | Use |
|---|---|---|---|
| `ink` | `#121212` | `#F4F2EC` | Text, silhouettes (illustrations stay `#121212` in both modes) |
| `paper` | `#F4F2EC` | `#1A1915` | Window and page background |
| `card` | `#FFFFFF` | `#24231E` | Cards, the menu popover, list rows |
| `line` | `#E2DFD6` | `#35332C` | Hairlines, dividers, outlines of inactive controls |
| `ink-2` | `#6E6B63` | `#A6A299` | Secondary text (4.6:1 on `paper`) |
| `ink-3` | `#9A978F` | `#6E6B63` | Tertiary text, placeholders |
| `amber` | `#FFB300` | `#FFB300` | The accent: eyes, switches, primary buttons, focus rings, progress |
| `amber-ink` | `#7A5200` | `#FFC63D` | Accent *text* (amber itself fails as text on paper) |
| `pink` | `#FF4D8D` | `#FF4D8D` | Second brand colour: stickers, one highlight per page, "waiting for you" |

**Neutrals are warm** (a hint of amber in every grey). Never use a pure `#808080`-style grey.

**Accent rule.** Amber is a fill, not a text colour. A primary button is amber with ink text. A link is ink,
underlined. The focus ring is amber at 2 pt. Native fills use `amber` by name (switches, primary buttons); text
that needs the accent uses `amber-ink`. On iOS the asset-catalog `AccentColor` is therefore `amber-ink`, because
iOS draws the accent as text (list buttons, links, the selected tab).

### 2.1 State colours (the semantic set)

Each state has a **fill** (pills, dots, icons), a **text** colour for light and for dark surfaces, and a tint
(fill at 15 % over the surface) for pill and banner backgrounds. The code's `Tone` (Mac) and `Tint` (iPhone) map
onto these; the system colours they use today are replaced by these values.

| State | Means | Fill | Text (light / dark) | Mac `Tone` | iPhone `Tint` |
|---|---|---|---|---|---|
| Working | an agent is working, the Mac stays awake | `#FFB300` amber | `#7A5200` / `#FFC63D` | `.working` | `.blue` → working |
| Waiting | an agent needs you | `#FF4D8D` pink | `#B3134F` / `#FF7AAA` | `.waiting` | `.orange` → waiting |
| Drowsy | sleep or shutdown countdown | `#7B6CF6` violet | `#4A3FD0` / `#B1A8FF` | (countdown rows) | `.orange` → drowsy |
| Asleep | the Mac is asleep | `#4A44B5` indigo | `#3A35A0` / `#A09AFF` | — | `.purple`, `.indigo` |
| Attention | a warning | `#F26B1D` orange | `#9A3E00` / `#FF9F66` | `.attention` | `.yellow` |
| Critical | safety stop, error, shutting down | `#E5484D` red | `#B3261E` / `#FF7B7B` | `.critical` | `.red` |
| Finished | done, success | `#34B36B` green | `#1B7A43` / `#6FDC9A` | `.success` | `.green` |
| Idle / Off | nothing happening, Kakureneko off | `#8E8B84` grey | `#6E6B63` / `#A6A299` | `.neutral`, `.muted` | `.gray` |

Working is amber on purpose: the accent *is* "awake". Waiting is pink, not orange, so it never reads as a
warning: an agent asking a question is normal. Drowsy and Asleep share a hue family (evening) and are told apart by
lightness. Attention is a red-orange, 20° and two lightness steps from amber, so the two never sit next to each
other at the same lightness. Every state also differs in shape or icon (see §6), never by colour alone.

## 3. Typography

| Role | Native (Mac + iPhone) | Web (product page, documents) | Notes |
|---|---|---|---|
| Wordmark | the outlined `artwork/wordmark/wordmark.svg` | the same SVG | Manrope Bold, lowercase "kakureneko", tracking −1.2 |
| Display, large titles | SF Pro Bold / Semibold | Manrope 700, tracking −0.02 em | Onboarding titles, the countdown, hero copy |
| Body | SF Pro (system text styles) | Manrope 400 / 500 | All UI text; Dynamic Type everywhere |
| Numbers | SF Pro Bold with `monospacedDigit()` | Manrope 700 with `tabular-nums` | Countdowns, durations, percentages |
| Code, paths | SF Mono | JetBrains Mono | File paths and commands only |

Scale on the web: 13 / 15 / 17 / 20 / 24 / 32 / 44 / 64 px, line height 1.45 for body and 1.1 for display.
Native code uses the system text styles (`.caption`, `.callout`, `.body`, `.headline`, `.title3`, `.largeTitle`)
and never `.fontDesign(.rounded)`: one plain sans, weight and size carry the hierarchy. Uppercase section labels get +0.6 pt tracking
(the Mac `SectionHeader` already does this). Headlines wrap balanced; nothing truncates a Mac name or a pill.

## 4. Shape, space, depth

* **Radii:** 6 pt chips and badges, 10 pt Mac cards and banners, 14 pt iPhone cards, 22 pt sheets and the
  onboarding window content, capsule for pills and primary buttons. The app icon tile keeps Apple's grid.
* **Spacing:** a 4 pt base. 8 between related items, 12 inside cards, 16 between cards, 24 to a window edge, 28
  inside the onboarding window. The menu popover is 340 pt wide with 12 pt padding (unchanged).
* **Depth:** flat. Cards are `card` on `paper` with no shadow; banners are a state tint with no border. The only
  shadows are the system's (menus, windows, notifications). Illustrations cast a flat ink ellipse, never a blur.
* **Strokes:** 1 pt `line` hairlines in UI; illustration outlines are ink, 10–12 units on a 400 grid.

## 5. Illustration system (Soot)

Sources: `artwork/mascot/*.svg`; `artwork/generate.py` draws them all from one cat, the embroidery reference's head
(tall ears set wide apart, ring eyes, hand-cut edges) on a small sitting body with a simple tapering tail, so they stay consistent. Every pose exists twice: plain, and `-sticker` (a 14-unit bone die-cut border) for dark surfaces,
photos and the product page's dark band. **On any dark surface use the sticker variant**: the plain ink cat
disappears.

| File | Pose | Where it goes |
|---|---|---|
| `sit` | sitting, tail up, staring | brand mark next to the wordmark, About, the Mac "no sessions" empty state |
| `peek` | a closed MacBook, eyes in the gap, tail out the side | product page hero, the Mac onboarding "closed lid" step |
| `hide` | behind a flat panel, head and toes over the edge | "Lid closed, staying awake" states, iPhone "waiting for your Mac" |
| `coffee` | wide awake, both paws on a mug with a bolt | Keep awake (alerts, menu row, iPhone button feedback) |
| `sleep` | sitting, eyes closed, zZ | Asleep / "Normal sleep", the iPhone empty Activity list at night |
| `wave` | one paw up, a question bubble | Needs input (notification artwork, Activity empty state) |

Drawing rules: the ink carries a sparse diagonal grain of bone flecks at 5–12 % (`generate.py grain`), never
the eyes and never the menu bar glyphs; ears are tall and set wide apart with a lighter `#34332F` inner ear; the tail is one simple tapering shape; every paw shows three toes; every edge is lightly roughened (`generate.py roughen`);
Soot is always `#121212` with `#FFB300` eyes, never recoloured, never given a mouth beyond the small "o" in
`wave`, never rotated, never cropped through the eyes. Minimum size 24 pt. Clear space around a pose equals one ear
height. At most one pose per screen; none in Settings panes. The eyes may animate (a blink, pupils glancing at a
button) but the silhouette never squashes or stretches.

## 6. Icons

### 6.1 App icon

Soot sitting on a closed MacBook, tail up, on a bone tile (`artwork/icon-mac.svg`; `icon-ios.svg` is the same scene
full-bleed and opaque). The eyes are the only colour. `scripts/make-icon.sh` renders both from the SVGs.
`icon-mac-amber.svg` and `icon-mac-ink.svg` are explored alternatives and are not shipped.

### 6.2 Menu bar

Template images (black + alpha, 18 pt grid, `Resources/MenuBar/<state>.png` and `@2x`): the cat's own head
outline, generated from the same drawing, with the eyes punched out. The head sits in the same place in every state so the item never jumps;
badges live top-right. Load them with `NSImage(named:)`/`Bundle.main.image(forResource:)` and `isTemplate = true`
(or `Image(nsImage:).renderingMode(.template)`); macOS then colours them for light, dark and tinted menu bars.

| File | `MenuBarIcon` symbol today | State | Drawing |
|---|---|---|---|
| `idle` | `laptopcomputer` | Kakureneko on, nothing working | eyes closed, content |
| `working` | `cup.and.heat.waves.fill` | agents working (lid open or closed) | eyes wide |
| `keepawake` | `cup.and.saucer.fill` | kept awake by you | eyes wide + mug |
| `waiting` | `hand.raised.fill` | an agent is waiting for you | eyes up + "?" |
| `attention` | `laptopcomputer.trianglebadge.exclamationmark` | a critical warning | ears flat + "!" |
| `countdown` | `hourglass` | sleep countdown | half-lidded + "z" |
| `asleep` | `moon.zzz.fill` | going to sleep | eyes closed + "zZ" |
| `shutdown` | `power` | shutting down soon | × eyes + power |
| `off` | `laptopcomputer.slash` | Kakureneko off | outline only |

### 6.3 Inside the UI

SF Symbols stay for actions and rows (they match the platform): `cup.and.heat.waves` keep awake, `moon.zzz`
sleep, `power` shut down, `hand.raised` waiting, `checkmark.circle` finished, `timer` countdown, `bell.badge`
alerts, `laptopcomputer` a Mac, `iphone` the phone. Use `.hierarchical` rendering, state colour from §2.1.

## 7. Components

* **Menu popover (Mac):** header = Soot glyph (state), "Kakureneko" in SF Pro Semibold, one-line status, the
  on/off switch (amber). Then banners, the power card, Sessions, Paused apps, the alerts row, footer. Cards are
  `card` on `paper`; a state card takes the state tint. Buttons: primary `.borderedProminent` tinted amber with ink
  text; Sleep now `.bordered`; destructive (cancel wind-down, shut down) red.
* **Status pill (iPhone `PhasePill`, Mac badge):** capsule, state tint background, state text colour, SF Symbol
  leading, `.subheadline.semibold`. One pill per Mac, always top of the card.
* **Session row:** state dot (8 pt, state fill), title `.callout.medium`, subtitle `ink-2`, status text in the
  state text colour, tabular digits.
* **Countdown:** the number in SF Pro Bold, tabular, drowsy violet; the label "Sleeps in" in `ink-2`.
* **Empty states:** one Soot pose at 96–140 pt, a title in SF Pro Semibold, one sentence, one button. Never a grey
  SF Symbol alone.
* **Onboarding (both platforms):** the pose at the top, title, one short paragraph, a list of three or four
  `FeatureRow`s with amber-ink symbols, buttons pinned to the bottom. Step indicators are text, not dots.
* **Notifications:** system-rendered. Title ≤ 40 characters, body one sentence, the Mac's name in the subtitle on
  the iPhone. Buttons: Keep awake 1h · Sleep now · (Shut down). The attachment image, when one is used, is a sticker
  pose on `paper`.
* **Settings:** plain system forms. No illustrations, no amber except switches.

## 8. Motion

Fast and few. 180 ms ease-out for state changes (menu bar glyph cross-fades through alpha), 240 ms for cards
appearing, spring (response 0.35, damping 0.8) for the iPhone pill changing colour. Soot blinks once every 6–10 s
when idle on a screen (not in the menu bar), and the pupils glance toward a button the user hovers. Honour Reduce
Motion: no blinks, no glances, cross-fades only.

## 9. Voice

Plain, specific, a little dry. Sentences, not labels. Say what happens, in the user's words:
"No agent is working. Your Mac sleeps as usual." · "Stays awake with the lid closed." · "Sleeps in 4:12."
Name people's things (agents, the lid, the battery), not ours (coordinator, zone, record). Errors say what went
wrong and the one thing to do about it. No exclamation marks, no "oops", no cat puns in the UI; the product page may
have exactly one.

## 10. Product page

Paper ground, ink type, amber accent, a dark band for the "while you're away" section (sticker poses there).
The hero is `peek` beside the wordmark and one sentence. The page explains the name once, in the footer
("Kakureneko (隠れ猫) is Japanese for "hiding cat", …"); the App Store description ends with the same line. **Screenshots are the content**: the page carries empty,
labelled frames (Mac menu open · iPhone Mac screen · iPhone notification · Mac onboarding) sized to the real
devices, to be filled with official screenshots from the shipping builds. No invented numbers, no fake reviews.

## 11. Files and regeneration

```
design language/
  DESIGN.md                     this document            README.md   index + links to the canvas and the page
  artwork/generate.py           one scene → icon variants, 9 menu bar glyphs, 6 poses (+ sticker variants)
  artwork/render.swift          SVG → PNG with alpha (AppKit CoreSVG; nothing to install)
  artwork/icon-*.svg            app icon sources         artwork/menubar/*.svg   artwork/mascot/*.svg
  artwork/wordmark/             wordmark.swift (CoreText outlines) + Manrope (OFL) + the wordmark SVGs
  archive-v0/                   the previous moon-and-laptop placeholder icon and its scripts
scripts/make-icon.sh            renders Resources/AppIcon.icns, the iOS AppIcon.png (opaque) and Resources/MenuBar/
```

Change the drawing in `generate.py`, run it, then run `scripts/make-icon.sh`. Never hand-edit the PNGs.
