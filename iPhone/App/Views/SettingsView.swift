// The Settings tab: notification permission (and Time Sensitive) with a way to fix it, iCloud status and sync,
// "Send test alert", this iPhone, privacy and support, the demo (See a demo / End demo) and the version.

import KakurenekoCloud
import SwiftUI

struct SettingsView: View {
    @Environment(PhoneStore.self) private var store
    /// Optional so previews without the app's root still render (the row is hidden then).
    @Environment(DemoMode.self) private var demo: DemoMode?
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                Form {
                    Group {
                        notificationsSection
                        macChoicesSection
                        iCloudSection(now: context.date)
                        testSection(now: context.date)
                        deviceSection
                        privacySection
                        demoSection
                        Section {
                            LabeledContent("Version", value: store.device.appVersion)
                        }
                    }
                    .cardRows()
                }
                .paperList()
            }
            .navigationTitle("Settings")
            .refreshable { await store.refresh() }
        }
    }

    // MARK: Notifications

    @ViewBuilder private var notificationsSection: some View {
        let authorization = store.notificationAuthorization
        Section {
            LabeledContent("Alerts", value: authorization?.statusTitle ?? "Checking…")
            if let authorization, authorization.alertsAllowed {
                LabeledContent("Time Sensitive", value: authorization.timeSensitiveTitle)
            }
            switch authorization?.status {
            case .notDetermined?:
                Button("Allow notifications") { Task { await store.requestNotificationAuthorization() } }
            case .denied?:
                Button("Open Settings") { openURL(AppLinks.notificationSettings) }
            case .authorized?, .provisional?:
                if authorization?.timeSensitive == false {
                    Button("Turn on Time Sensitive") { openURL(AppLinks.notificationSettings) }
                }
            case nil:
                EmptyView()
            }
        } header: {
            SectionTitle("Notifications")
        } footer: {
            Text(authorization?.status == .denied
                 ? "Notifications are off, so Kakureneko can't tell you when an agent finishes or needs you."
                 : "Time Sensitive alerts break through Focus when an agent needs you or your Mac is about to sleep.")
        }
    }

    /// Which alerts reach the iPhone, and when, is chosen on the Mac (it decides what it sends).
    private var macChoicesSection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose alerts on your Mac")
                    Text("Kakureneko → Settings → Notifications")
                        .font(.footnote)
                        .foregroundStyle(Palette.ink2)
                }
            } icon: {
                Image(systemName: "laptopcomputer").foregroundStyle(Palette.ink2)
            }
        } footer: {
            Text("Which alerts reach this iPhone, and when. By default: while the Mac's lid is closed.")
        }
    }

    // MARK: iCloud

    private func iCloudSection(now: Date) -> some View {
        Section {
            LabeledContent("iCloud", value: store.account?.shortTitle ?? "Checking…")
            LabeledContent("Last updated", value: store.lastSyncedAt.map { TimeText.ago($0, now: now) } ?? "Not yet")
            if case .offline = store.connection {
                LabeledContent("Status", value: "Offline")
            } else if case .failed(let message, _) = store.connection {
                Text(message).foregroundStyle(Palette.ink2)
            }
            if !store.pendingCommands.isEmpty {
                LabeledContent("Waiting to send", value: "\(store.pendingCommands.count)")
                Button("Retry now") { Task { await store.refresh() } }
            }
        } header: {
            SectionTitle("iCloud")
        } footer: {
            if let account = store.account, !account.isAvailable {
                Text(account.phoneExplanation)
            } else {
                Text("Kakureneko reaches your Mac through iCloud. Use the same Apple Account on this iPhone and your Mac.")
            }
        }
    }

    // MARK: Test

    private func testSection(now: Date) -> some View {
        let macs = store.macs
        return Section {
            Button {
                Task { await store.sendTestAlert() }
            } label: {
                Label("Send test alert", systemImage: "bell.badge")
            }
            .disabled(macs.isEmpty || store.account != .available)
            ForEach(macs) { status in
                if let feedback = store.visibleFeedback(for: status.macID, channel: .test, at: now) {
                    FeedbackLine(feedback: feedback, macName: status.macName)
                }
            }
        } header: {
            SectionTitle("Test")
        } footer: {
            Text(macs.isEmpty
                 ? "Once your Mac shows up, it can send a test notification to this iPhone."
                 : "Each Mac sends a test notification to this iPhone (and shows it on the Mac too).")
        }
    }

    // MARK: This iPhone

    private var deviceSection: some View {
        Section {
            LabeledContent("Name", value: store.device.name)
            LabeledContent("Model", value: store.device.model)
            LabeledContent("iOS", value: store.device.systemVersion)
        } header: {
            SectionTitle("This iPhone")
        }
    }

    // MARK: Privacy

    private var privacySection: some View {
        Section {
            Text("Alerts travel between your Mac and iPhone through Apple's iCloud, readable only with your Apple Account. Kakureneko runs no server of its own and has no analytics.")
            Link(destination: AppLinks.privacyPolicy) {
                Label("Privacy policy", systemImage: "hand.raised")
            }
            Link(destination: AppLinks.support) {
                Label("Support", systemImage: "questionmark.circle")
            }
        } header: {
            SectionTitle("Privacy and support")
        }
    }

    // MARK: Demo

    @ViewBuilder private var demoSection: some View {
        if let demo {
            Section {
                if demo.isActive {
                    Button {
                        demo.end()
                    } label: {
                        Label("End demo", systemImage: "xmark.circle")
                    }
                } else {
                    Button {
                        demo.start()
                    } label: {
                        Label("See a demo", systemImage: "play.circle")
                    }
                }
            } footer: {
                Text(demo.isActive
                     ? "This is a sample Mac. Nothing you tap here is sent."
                     : "Try the app with a sample Mac. Nothing is sent to your Macs or iCloud.")
            }
        }
    }
}

#if DEBUG
#Preview("Settings") {
    PreviewHost(.oneMac) { SettingsView() }
}

#Preview("Settings, no iCloud") {
    PreviewHost(.noICloud) { SettingsView() }
}
#endif
