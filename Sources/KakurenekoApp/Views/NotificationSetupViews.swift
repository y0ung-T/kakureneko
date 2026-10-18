// Notification setup shared by onboarding step 2 and the Notifications settings pane (docs/NATIVE-NOTIFICATIONS.md):
// allow macOS notifications → get the Kakureneko iPhone app (same Apple Account = connected through iCloud, no
// pairing) → "iPhone connected" appears by itself once its `PhoneDevice` record arrives → send a test to both.

import KakurenekoCloud
import KakurenekoKit
import SwiftUI

struct NotificationSetupView: View {
    let model: AppModel
    /// Settings pane layout: plain rows instead of numbered steps.
    var compact = false

    var body: some View {
        let status = model.snapshot.notifications
        let ready = AlertsSummary.make(status, settings: model.snapshot.settings.notifications).isReady
        VStack(alignment: .leading, spacing: compact ? 12 : 18) {
            step(1, "Notifications on this Mac") { MacPermissionRows(model: model, status: status) }
            step(2, "Kakureneko for iPhone") { PhoneLinkRows(model: model, status: status) }
            step(3, "Try it") { SendTestRow(model: model, ready: ready) }
        }
    }

    @ViewBuilder
    private func step<Content: View>(_ number: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        if compact {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                content()
            }
        } else {
            StepBlock(number: number, title: title, content: content)
        }
    }
}

/// Permission state of Kakureneko's macOS notifications and the one action that fixes it.
struct MacPermissionRows: View {
    let model: AppModel
    let status: NotificationStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch status.macAuthorization {
            case .authorized, .provisional:
                Label(AlertsSummary.macPermissionText(status.macAuthorization), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Tone.success.color)
                if status.macTimeSensitive == false {
                    hint("Turn on Time Sensitive Notifications for Kakureneko so alerts that need you break through Focus.")
                    Button("Open System Settings") { model.openNotificationSettings() }
                        .buttonStyle(.accentLink)
                }
            case .notDetermined:
                hint("Alerts appear with buttons to keep the Mac awake or put it to sleep.")
                ProgressButton(title: "Allow Notifications", isRunning: model.isRunning(.notificationPermission), prominent: true) {
                    Task { await model.requestNotificationPermission() }
                }
            case .denied:
                Label("Notifications are off for Kakureneko", systemImage: "bell.slash.fill")
                    .foregroundStyle(Tone.attention.color)
                Button("Open System Settings") { model.openNotificationSettings() }
            case .unavailable:
                Label("Not available here: run Kakureneko.app", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Tone.muted.color)
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
    }
}

/// iCloud state and the iPhones running the Kakureneko app (live: rows appear as their records arrive).
struct PhoneLinkRows: View {
    let model: AppModel
    let status: NotificationStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !status.iCloud.isAvailable && status.iCloud != .couldNotDetermine {
                Label(status.iCloud.explanation, systemImage: "icloud.slash")
                    .foregroundStyle(Tone.attention.color)
                    .fixedSize(horizontal: false, vertical: true)
            } else if status.phones.isEmpty {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Install Kakureneko on your iPhone and use the same Apple Account as this Mac. It connects through iCloud: no pairing, no other app.")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        if AppLinks.iPhoneApp == nil {
                            Text("Kakureneko for iPhone is coming to the App Store.")
                                .font(.caption)
                                .foregroundStyle(Palette.ink2)
                        }
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Waiting for your iPhone…").font(.caption).foregroundStyle(Palette.ink2)
                        }
                        .task { await model.lookForPhonesWhileWaiting() }
                    }
                    if let link = AppLinks.iPhoneApp {
                        Spacer(minLength: 0)
                        QRCodeView(text: link.absoluteString, caption: "Scan with your iPhone", size: 96)
                    }
                }
            } else {
                ForEach(status.phones) { phone in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Label(AlertsSummary.phoneLine(phone, now: model.snapshot.generatedAt), systemImage: "iphone.gen3")
                                .foregroundStyle(phone.alertsAuthorized ? Tone.success.color : Tone.attention.color)
                            Spacer(minLength: 0)
                            // An old install or a phone that is gone; a phone in use adds itself back when the app opens.
                            Button("Remove") { Task { await model.forgetPhone(phone.deviceID) } }
                                .buttonStyle(.accentLink)
                                .font(.caption)
                                .help("Remove this iPhone from the list. If it still has Kakureneko, it comes back the next time the app opens.")
                        }
                        if !phone.alertsAuthorized {
                            Text("Notifications are off on this iPhone: allow them in its Settings → Notifications → Kakureneko.")
                                .font(.caption)
                                .foregroundStyle(Palette.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}

/// "Try it": a test alert on this Mac and every connected iPhone.
struct SendTestRow: View {
    let model: AppModel
    let ready: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("Sends a test alert to this Mac and every connected iPhone.")
                .font(.callout)
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            ProgressButton(title: "Send Test", isRunning: model.isRunning(.sendTest)) {
                Task { await model.sendTestNotification() }
            }
            .disabled(!ready)
        }
    }
}

/// A numbered step with content.
struct StepBlock<Content: View>: View {
    let number: Int
    let title: String
    @ViewBuilder var content: Content

    init(number: Int, title: String, @ViewBuilder content: () -> Content) {
        self.number = number
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.callout.weight(.bold))
                .foregroundStyle(Palette.onAmber)
                .frame(width: 22, height: 22)
                .background(Palette.amber, in: Circle())
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                content
            }
        }
    }
}
