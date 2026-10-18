// Small shared building blocks for the menu, onboarding and settings views.

import AppKit
import KakurenekoKit
import SwiftUI

/// Uppercase small section title with an optional trailing accessory.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Palette.ink2)
                .tracking(0.6)
            Spacer(minLength: 8)
            trailing
        }
    }
}

/// A rounded container: a state card takes the state's tint, a neutral one a faint ink wash (flat, no border).
struct Card<Content: View>: View {
    var tone: Tone = .neutral
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tone.fill, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }
}

/// A capsule label ("simulated", "Dry run", "New file").
struct Badge: View {
    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(tone.color)
            .background(tone.fill, in: Capsule())
    }
}

/// A status dot in the state's solid fill.
struct StatusDot: View {
    let tone: Tone
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(tone.solid)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Icon + title + message banner with optional actions.
struct Banner<Actions: View>: View {
    let symbolName: String
    let tone: Tone
    let title: String
    var message: String?
    @ViewBuilder var actions: Actions

    init(symbolName: String, tone: Tone, title: String, message: String? = nil,
         @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.symbolName = symbolName
        self.tone = tone
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbolName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tone.color)
                .font(.body)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.fill, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }
}

/// The inline error banner (dismissible).
struct ErrorBannerView: View {
    let banner: ErrorBanner
    let dismiss: () -> Void

    var body: some View {
        Banner(symbolName: "xmark.octagon.fill", tone: .critical, title: "\(banner.title) failed", message: banner.message) {
            Button("Dismiss", action: dismiss)
                .buttonStyle(.accentLink)
                .font(.caption)
        }
    }
}

/// A QR code image with a caption (pairing).
struct QRCodeView: View {
    let text: String
    let caption: String
    var size: CGFloat = 120

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let image = QRCode.image(for: text) {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "qrcode")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(Palette.ink2)
                }
            }
            .frame(width: size, height: size)
            .padding(6)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityLabel("QR code: \(caption)")
            Text(caption)
                .font(.caption)
                .foregroundStyle(Palette.ink2)
                .multilineTextAlignment(.center)
                .frame(width: size + 12)
        }
    }
}

/// A button that shows a spinner while its action runs (primary: amber with ink text; else the secondary style).
struct ProgressButton: View {
    let title: String
    let isRunning: Bool
    var prominent = false
    var large = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isRunning {
                    ProgressView().controlSize(.mini)
                }
                Text(title)
            }
        }
        .disabled(isRunning)
        .buttonStyle(KakurenekoButtonStyle(kind: prominent ? .primary : .secondary, large: large))
    }
}
