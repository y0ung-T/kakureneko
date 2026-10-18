// The design language's colours, shapes and artwork for the iPhone app ("design language/DESIGN.md" §2–§7): warm
// neutrals, one amber accent, the state set and the Soot poses (asset catalog `Mascot/`, the sticker variant is the
// dark appearance). Light and dark are two palettes, not an inversion.
//
// iOS uses the accent for text (list buttons, links, the tab bar), so the asset catalog's AccentColor is `amberInk`;
// amber itself is a fill (primary buttons, the countdown's Keep awake) and is used by name.

import SwiftUI
import UIKit

enum Palette {
    static let ink = dynamic(light: 0x121212, dark: 0xF4F2EC)
    static let paper = dynamic(light: 0xF4F2EC, dark: 0x1A1915)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x24231E)
    static let line = dynamic(light: 0xE2DFD6, dark: 0x35332C)
    /// Secondary text (4.6:1 on `paper`).
    static let ink2 = dynamic(light: 0x6E6B63, dark: 0xA6A299)
    /// Tertiary text, placeholders.
    static let ink3 = dynamic(light: 0x9A978F, dark: 0x6E6B63)
    static let amber = fixed(0xFFB300)
    static let amberInk = dynamic(light: 0x7A5200, dark: 0xFFC63D)
    static let pink = fixed(0xFF4D8D)
    /// Text on an amber fill: ink in both modes.
    static let onAmber = fixed(0x121212)

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in rgb(traits.userInterfaceStyle == .dark ? dark : light) })
    }

    static func fixed(_ hex: UInt32) -> Color { Color(uiColor: rgb(hex)) }

    static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - State colours (§2.1)

extension Tint {
    /// Text and symbols in this state's colour (readable on `card` and `paper`).
    var color: Color {
        switch self {
        case .accent, .working: Palette.amberInk
        case .waiting: Palette.dynamic(light: 0xB3134F, dark: 0xFF7AAA)
        case .drowsy: Palette.dynamic(light: 0x4A3FD0, dark: 0xB1A8FF)
        case .asleep: Palette.dynamic(light: 0x3A35A0, dark: 0xA09AFF)
        case .attention: Palette.dynamic(light: 0x9A3E00, dark: 0xFF9F66)
        case .critical: Palette.dynamic(light: 0xB3261E, dark: 0xFF7B7B)
        case .finished: Palette.dynamic(light: 0x1B7A43, dark: 0x6FDC9A)
        case .idle: Palette.ink2
        }
    }

    /// The state's solid fill: status dots.
    var solid: Color {
        switch self {
        case .accent, .working: Palette.amber
        case .waiting: Palette.pink
        case .drowsy: Palette.fixed(0x7B6CF6)
        case .asleep: Palette.fixed(0x4A44B5)
        case .attention: Palette.fixed(0xF26B1D)
        case .critical: Palette.fixed(0xE5484D)
        case .finished: Palette.fixed(0x34B36B)
        case .idle: Palette.fixed(0x8E8B84)
        }
    }

    /// Pill and banner background: the fill at about 15 % over the surface.
    var tint: Color { self == .idle ? Palette.ink.opacity(0.06) : solid.opacity(0.16) }
}

// MARK: - Lists on paper

extension View {
    /// A screen's list or form in the design's colours: `paper` behind (sections add `cardRows()`).
    func paperList() -> some View {
        scrollContentBackground(.hidden).background(Palette.paper)
    }

    /// The rows of a section on `card`, with `line` separators.
    func cardRows() -> some View {
        listRowBackground(Palette.card).listRowSeparatorTint(Palette.line)
    }
}

/// The amber capsule button with ink text (onboarding Continue, the countdown's Keep awake).
struct PrimaryCapsuleStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Palette.onAmber)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 16)
            .background(Palette.amber, in: .capsule)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(.capsule)
    }
}

extension ButtonStyle where Self == PrimaryCapsuleStyle {
    static var primaryCapsule: PrimaryCapsuleStyle { PrimaryCapsuleStyle() }
}

/// The quiet capsule beside or under a primary one (onboarding's See a demo): ink text on `card`, a `line` outline.
struct SecondaryCapsuleStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Palette.ink)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 16)
            .background(Palette.card, in: .capsule)
            .overlay { Capsule().strokeBorder(Palette.line, lineWidth: 1) }
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .contentShape(.capsule)
    }
}

extension ButtonStyle where Self == SecondaryCapsuleStyle {
    static var secondaryCapsule: SecondaryCapsuleStyle { SecondaryCapsuleStyle() }
}

// MARK: - Soot

/// The six poses (DESIGN.md §5).
enum MascotPose: String, CaseIterable {
    case sit, peek, hide, coffee, sleep, wave
}

/// One Soot pose at a fixed height: never cropped, never recoloured. The asset's dark appearance is the sticker.
struct MascotView: View {
    let pose: MascotPose
    var height: CGFloat

    var body: some View {
        Image(pose.rawValue)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .accessibilityHidden(true)
    }
}
