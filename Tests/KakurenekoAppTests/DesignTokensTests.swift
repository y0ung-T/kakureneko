@testable import KakurenekoApp
import AppKit
import SwiftUI
import Testing

/// The design language's colours ("design language/DESIGN.md" §2) resolve per appearance and stay readable.
@MainActor
@Suite("Design tokens", .timeLimit(.minutes(1)))
struct DesignTokensTests {
    private func resolved(_ color: Color, dark: Bool) -> (r: Double, g: Double, b: Double) {
        var result = (r: 0.0, g: 0.0, b: 0.0)
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let rgb = NSColor(color).usingColorSpace(.sRGB)!
            result = (Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent))
        }
        return result
    }

    private func hex(_ color: Color, dark: Bool) -> String {
        let c = resolved(color, dark: dark)
        return String(format: "%02X%02X%02X", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
    }

    private func contrast(_ a: Color, _ b: Color, dark: Bool) -> Double {
        func luminance(_ c: (r: Double, g: Double, b: Double)) -> Double {
            func channel(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
        }
        let (la, lb) = (luminance(resolved(a, dark: dark)), luminance(resolved(b, dark: dark)))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    @Test func paletteMatchesTheDesignDocument() {
        #expect(hex(Palette.ink, dark: false) == "121212")
        #expect(hex(Palette.ink, dark: true) == "F4F2EC")
        #expect(hex(Palette.paper, dark: false) == "F4F2EC")
        #expect(hex(Palette.paper, dark: true) == "1A1915")
        #expect(hex(Palette.card, dark: false) == "FFFFFF")
        #expect(hex(Palette.card, dark: true) == "24231E")
        #expect(hex(Palette.amber, dark: false) == "FFB300")
        #expect(hex(Palette.amber, dark: true) == "FFB300")
        #expect(hex(Palette.amberInk, dark: false) == "7A5200")
        #expect(hex(Palette.amberInk, dark: true) == "FFC63D")
        #expect(hex(Tone.waiting.solid, dark: false) == "FF4D8D")
        #expect(hex(Tone.drowsy.color, dark: false) == "4A3FD0")
        #expect(hex(Tone.drowsy.color, dark: true) == "B1A8FF")
    }

    /// State text and secondary text pass 4.5:1 on the menu's card and the windows' paper, in both modes.
    @Test(arguments: [false, true]) func stateTextIsReadable(dark: Bool) {
        let tones: [Tone] = [.neutral, .working, .waiting, .drowsy, .asleep, .attention, .critical, .success]
        for tone in tones {
            for surface in [Palette.card, Palette.paper] {
                #expect(contrast(tone.color, surface, dark: dark) >= 4.5, "\(tone) dark=\(dark)")
            }
        }
        #expect(contrast(Palette.ink2, Palette.paper, dark: dark) >= 4.5)
        #expect(contrast(Palette.onAmber, Palette.amber, dark: dark) >= 4.5) // primary button text
    }
}
