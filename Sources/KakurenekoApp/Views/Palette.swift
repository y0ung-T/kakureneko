// The design language's colours, shapes and artwork for the Mac app ("design language/DESIGN.md" §2–§7): warm
// neutrals, one amber accent, the state set, the menu bar cat glyphs and the Soot poses.
//
// Light and dark are two palettes, not an inversion: every token resolves for the appearance of the view that
// draws it. Amber is a fill, never a text colour; accent text uses `amberInk`.

import AppKit
import SwiftUI

enum Palette {
    static let ink = dynamic(light: 0x121212, dark: 0xF4F2EC)
    static let paper = dynamic(light: 0xF4F2EC, dark: 0x1A1915)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x24231E)
    static let line = dynamic(light: 0xE2DFD6, dark: 0x35332C)
    /// Secondary text (4.6:1 on `paper`).
    static let ink2 = dynamic(light: 0x6E6B63, dark: 0xA6A299)
    /// Tertiary text, placeholders.
    static let ink3 = dynamic(light: 0x9A978F, dark: 0x6E6B63)
    /// The accent: switches, primary buttons, progress, the selected sidebar row.
    static let amber = fixed(0xFFB300)
    /// Accent text and symbols (amber itself fails as text on paper).
    static let amberInk = dynamic(light: 0x7A5200, dark: 0xFFC63D)
    static let pink = fixed(0xFF4D8D)
    /// Text and symbols on an amber fill: ink in both modes.
    static let onAmber = fixed(0x121212)

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark]).map {
                $0 == .darkAqua || $0 == .vibrantDark
            } ?? false
            return rgb(isDark ? dark : light)
        })
    }

    static func fixed(_ hex: UInt32) -> Color { Color(nsColor: rgb(hex)) }

    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// DESIGN.md §4: radii and the menu's spacing.
enum Metrics {
    static let chipRadius: CGFloat = 6
    static let cardRadius: CGFloat = 10
}

/// A 1 pt `line` hairline (dividers in the menu, the onboarding and settings bars).
struct Hairline: View {
    var color: Color = Palette.line

    var body: some View {
        Rectangle().fill(color).frame(height: 1).accessibilityHidden(true)
    }
}

// MARK: - State colours (§2.1)

extension Tone {
    /// Text and symbols in this state's colour (readable on `card` and `paper`).
    var color: Color {
        switch self {
        case .neutral: Palette.ink2
        case .muted: Palette.ink3
        case .working: Palette.amberInk
        case .waiting: Palette.dynamic(light: 0xB3134F, dark: 0xFF7AAA)
        case .drowsy: Palette.dynamic(light: 0x4A3FD0, dark: 0xB1A8FF)
        case .asleep: Palette.dynamic(light: 0x3A35A0, dark: 0xA09AFF)
        case .attention: Palette.dynamic(light: 0x9A3E00, dark: 0xFF9F66)
        case .critical: Palette.dynamic(light: 0xB3261E, dark: 0xFF7B7B)
        case .success: Palette.dynamic(light: 0x1B7A43, dark: 0x6FDC9A)
        }
    }

    /// The state's solid fill: status dots, chips.
    var solid: Color {
        switch self {
        case .neutral, .muted: Palette.fixed(0x8E8B84)
        case .working: Palette.amber
        case .waiting: Palette.pink
        case .drowsy: Palette.fixed(0x7B6CF6)
        case .asleep: Palette.fixed(0x4A44B5)
        case .attention: Palette.fixed(0xF26B1D)
        case .critical: Palette.fixed(0xE5484D)
        case .success: Palette.fixed(0x34B36B)
        }
    }

    /// Background tint for banners, badges and state cards (the fill at about 15 %; no border, no shadow).
    var fill: Color {
        switch self {
        case .neutral, .muted: Palette.ink.opacity(0.05)
        case .working: Palette.amber.opacity(0.16)
        default: solid.opacity(0.14)
        }
    }
}

// MARK: - Buttons (§7: primary amber with ink text, secondary on card with a hairline, destructive red)

/// The design's small rectangular buttons (menu, banners, onboarding, the settings apply bar).
struct KakurenekoButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    var kind: Kind = .secondary
    var large = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(large ? .body.weight(.semibold) : .callout.weight(kind == .secondary ? .medium : .semibold))
            .lineLimit(1)
            .padding(.horizontal, large ? 14 : 9)
            .padding(.vertical, large ? 5 : 3)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: large ? 7 : Metrics.chipRadius, style: .continuous))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: large ? 7 : Metrics.chipRadius, style: .continuous)
                        .strokeBorder(Palette.line)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: Metrics.chipRadius))
    }

    private var foreground: Color {
        switch kind {
        case .primary: Palette.onAmber
        case .secondary: Palette.ink
        case .destructive: .white
        }
    }

    private var background: Color {
        switch kind {
        case .primary: Palette.amber
        case .secondary: Palette.card
        case .destructive: Tone.critical.solid
        }
    }
}

extension ButtonStyle where Self == KakurenekoButtonStyle {
    static var primary: KakurenekoButtonStyle { KakurenekoButtonStyle(kind: .primary) }
    static var secondary: KakurenekoButtonStyle { KakurenekoButtonStyle(kind: .secondary) }
    static var destructive: KakurenekoButtonStyle { KakurenekoButtonStyle(kind: .destructive) }
    static var largePrimary: KakurenekoButtonStyle { KakurenekoButtonStyle(kind: .primary, large: true) }
    static var largeSecondary: KakurenekoButtonStyle { KakurenekoButtonStyle(kind: .secondary, large: true) }
}

/// The menu header's on/off switch: amber when on (DESIGN.md §7), flat, VoiceOver sees a normal switch.
struct AmberSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule()
                .fill(configuration.isOn ? Palette.amber : Palette.ink.opacity(0.18))
                .frame(width: 30, height: 18)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle().fill(Color.white).frame(width: 14, height: 14).padding(2)
                }
                .animation(.easeOut(duration: 0.18), value: configuration.isOn)
                .opacity(isEnabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

/// An inline text link in the accent text colour ("Resume all", "Install…").
struct AccentLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Palette.amberInk)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == AccentLinkStyle {
    static var accentLink: AccentLinkStyle { AccentLinkStyle() }
}

// MARK: - Artwork

/// Where the bundled artwork lives: `Contents/Resources/MenuBar` (template PNGs) and `Contents/Resources/Mascot`
/// (SVG poses), copied by scripts/build-app.sh. Tests and render probes point it at the repository instead.
enum Artwork {
    static var resources: URL? = Bundle.main.resourceURL {
        didSet { glyphs = [:] }
    }

    private static var glyphs: [String: NSImage] = [:]

    /// A menu bar glyph as an 18 pt template image (1x + 2x), or nil outside the app bundle. Cached: the menu bar
    /// label asks for it on every redraw.
    static func menuBarGlyph(_ name: String) -> NSImage? {
        if let cached = glyphs[name] { return cached }
        guard let image = loadGlyph(name) else { return nil }
        glyphs[name] = image
        return image
    }

    private static func loadGlyph(_ name: String) -> NSImage? {
        guard let directory = resources?.appending(path: "MenuBar", directoryHint: .isDirectory) else { return nil }
        let image = NSImage(size: NSSize(width: 18, height: 18))
        for file in ["\(name).png", "\(name)@2x.png"] {
            guard let rep = NSImageRep(contentsOf: directory.appending(path: file)) else { continue }
            rep.size = image.size
            image.addRepresentation(rep)
        }
        guard !image.representations.isEmpty else { return nil }
        image.isTemplate = true
        image.accessibilityDescription = nil
        return image
    }

    /// A Soot pose (`sit`, `peek`, `hide`, `coffee`, `sleep`, `wave`); the die-cut sticker variant on dark surfaces.
    static func mascot(_ pose: MascotPose, dark: Bool) -> NSImage? {
        guard let directory = resources?.appending(path: "Mascot", directoryHint: .isDirectory) else { return nil }
        return NSImage(contentsOf: directory.appending(path: dark ? "\(pose.rawValue)-sticker.svg" : "\(pose.rawValue).svg"))
    }
}

/// The six poses (DESIGN.md §5) and where each one goes.
enum MascotPose: String, CaseIterable {
    /// Brand mark, About, the menu's "no sessions" state.
    case sit
    /// A closed MacBook with eyes in the gap: the onboarding closed-lid step.
    case peek
    /// Behind a panel: lid closed, staying awake.
    case hide
    /// Wide awake with a mug: keep awake.
    case coffee
    /// Eyes closed, zZ: asleep, normal sleep.
    case sleep
    /// A paw up and a question bubble: needs input.
    case wave
}

/// One Soot pose at a fixed height (never cropped, never recoloured); nothing when the artwork is missing.
struct MascotView: View {
    let pose: MascotPose
    var height: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let image = Artwork.mascot(pose, dark: colorScheme == .dark) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(height: height)
                .accessibilityHidden(true)
        }
    }
}
