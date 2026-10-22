// Small views shared by the screens: the phase pill, the "offline" banner, the demo banner, the feedback line under
// the buttons, section titles, the empty state with Soot, links the app opens, and a stack that turns vertical at
// accessibility text sizes. Colours come from Palette.swift (the design language).

import KakurenekoCloud
import SwiftUI
import UIKit

/// Links the app opens. The GitHub repository comes from the Info.plist (`KakurenekoWebsiteURL`, set from the
/// `KAKURENEKO_WEBSITE_URL` build setting in Xcode/project.yml, or `WEBSITE_URL` in scripts/release.env); TestFlight's
/// test information uses the same privacy policy URL.
enum AppLinks {
    static let website = WebsiteLinks(infoValue: Bundle.main.object(forInfoDictionaryKey: WebsiteLinks.infoKey))

    /// <repository>/blob/main/PRIVACY.md
    static var privacyPolicy: URL { website.privacyPolicy }
    /// <repository>/issues
    static var support: URL { website.support }
    /// <repository>/: its README links the Mac app's download.
    static var macDownload: URL { website.home }

    /// This app's notification settings.
    @MainActor static var notificationSettings: URL { URL(string: UIApplication.openNotificationSettingsURLString)! }
}

/// The strip across the top of the demo: an ink "Demo" pill, one sentence and End demo, on every screen of it.
struct DemoBanner: View {
    let end: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content(withSentence: true)
            content(withSentence: false)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background {
            Palette.card
                .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
                .ignoresSafeArea(edges: .top)
        }
    }

    private func content(withSentence: Bool) -> some View {
        HStack(spacing: 10) {
            Text("Demo")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.paper)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(Palette.ink, in: .capsule)
                .fixedSize()
            if withSentence {
                Text("A sample Mac. Nothing is sent.")
                    .font(.footnote)
                    .foregroundStyle(Palette.ink2)
                    .fixedSize()
            }
            Spacer(minLength: 8)
            Button("End demo", action: end)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.ink)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(Palette.ink)
                .fixedSize()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Demo with a sample Mac")
    }
}

/// The capsule naming a Mac's phase: the state's tint behind its text colour (DESIGN.md §7, status pill).
struct PhasePill: View {
    let style: PhaseStyle

    var body: some View {
        Label(style.title, systemImage: style.symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(style.tint.color)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(style.tint.tint, in: .capsule)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: style)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Status: \(style.title)")
    }
}

/// A list section's title: uppercase, medium, lightly tracked, secondary ink.
struct SectionTitle: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.footnote.weight(.medium))
            .tracking(0.5)
            .textCase(.uppercase)
            .foregroundStyle(Palette.ink2)
    }
}

/// An empty screen: one Soot pose, a title, one sentence, one button (DESIGN.md §7, never a grey symbol alone).
struct EmptyStateView<Actions: View>: View {
    let pose: MascotPose
    let title: String
    let message: String
    @ViewBuilder var actions: Actions
    @ScaledMetric(relativeTo: .largeTitle) private var poseHeight = 120

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                MascotView(pose: pose, height: min(poseHeight, 140))
                    .padding(.bottom, 4)
                Text(title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .foregroundStyle(Palette.ink2)
                    .multilineTextAlignment(.center)
                actions
                    .padding(.top, 6)
            }
            .padding(32)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical, alignment: .center) { length, _ in length * 0.9 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Palette.paper)
    }
}

/// A section that explains why the screen may be out of date (offline, iCloud refused, signed out).
struct ConnectionBanner: View {
    @Environment(PhoneStore.self) private var store
    let now: Date

    var body: some View {
        if let account = store.account, !account.isAvailable {
            banner(symbol: "icloud.slash", title: "iCloud Unavailable", detail: account.phoneExplanation)
        } else {
            switch store.connection {
            case .offline:
                banner(symbol: "wifi.slash", title: "Offline", detail: lastUpdate)
            case .failed(let message, _):
                banner(symbol: "exclamationmark.icloud", title: "Can't Reach iCloud", detail: message)
            case .unknown, .online:
                EmptyView()
            }
        }
    }

    private var lastUpdate: String {
        guard let last = store.lastSyncedAt else { return "Showing the last known state." }
        return "Showing the state from \(TimeText.ago(last, now: now).lowercased())."
    }

    private func banner(symbol: String, title: String, detail: String) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(Palette.ink2)
                }
            } icon: {
                Image(systemName: symbol).foregroundStyle(Tint.attention.color)
            }
            .accessibilityElement(children: .combine)
        }
        .listRowBackground(Tint.attention.tint)
    }
}

/// "Sent. Waiting for Studio…" under a button, announced to VoiceOver as it changes.
struct FeedbackLine: View {
    let feedback: CommandFeedback
    let macName: String

    var body: some View {
        Label(feedback.message(macName: macName), systemImage: feedback.symbol)
            .font(.footnote)
            .foregroundStyle(feedback.tint.color)
            .contentTransition(.opacity)
            .onChange(of: feedback.phase, initial: true) { _, _ in
                AccessibilityNotification.Announcement(feedback.message(macName: macName)).post()
            }
    }
}

/// Horizontal, or vertical at accessibility text sizes (so long names and pills never truncate).
struct AdaptiveStack<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: spacing))
        layout { content }
    }
}
