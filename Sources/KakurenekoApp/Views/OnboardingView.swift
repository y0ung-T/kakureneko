// The onboarding window (see OnboardingFlow for the steps and their rules).

import KakurenekoCloud
import KakurenekoKit
import SwiftUI

struct OnboardingView: View {
    let flow: OnboardingFlow

    private var model: AppModel { flow.model }

    var body: some View {
        VStack(spacing: 0) {
            StepIndicator(current: flow.step)
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(Palette.card)
            Hairline()
            ScrollView {
                HStack(alignment: .top, spacing: 28) {
                    // DESIGN.md §7: the pose at the top (here, the left column), one per step.
                    StepArt(step: flow.step)
                        .frame(width: 180)
                    VStack(alignment: .leading, spacing: 16) {
                        if model.isDryRun {
                            Banner(symbolName: "testtube.2", tone: .attention, title: "Dry run",
                                   message: "Kakureneko only logs what it would do: no admin prompt, no file changes, no login item, no permission prompts.")
                        }
                        if let banner = model.banner {
                            ErrorBannerView(banner: banner) { model.dismissBanner() }
                        }
                        switch flow.step {
                        case .closedLid: ClosedLidStep(flow: flow)
                        case .notifications: NotificationsStep(flow: flow)
                        case .integrations: IntegrationsStep(flow: flow)
                        case .finish: FinishStep(flow: flow)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(28)
            }
            .background(Palette.paper)
            Hairline()
            HStack {
                if !flow.isFirstStep {
                    Button("Back") { flow.back() }
                        .buttonStyle(.largeSecondary)
                }
                Spacer()
                Button(flow.continueTitle) { Task { await flow.next() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.largePrimary)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .background(Palette.card)
        }
        .foregroundStyle(Palette.ink)
        .tint(Palette.amber)
        .frame(minWidth: 720, idealWidth: 760, minHeight: 600, idealHeight: 660)
    }
}

/// The step's Soot pose, and for the closed-lid step the one-line reason under it.
private struct StepArt: View {
    let step: OnboardingFlow.Step

    var body: some View {
        VStack(spacing: 14) {
            switch step {
            case .closedLid: MascotView(pose: .peek, height: 112)
            case .notifications: MascotView(pose: .wave, height: 150)
            case .integrations: MascotView(pose: .sit, height: 150)
            case .finish: MascotView(pose: .sleep, height: 150)
            }
            if step == .closedLid {
                Text("On battery, macOS sleeps the moment the lid closes. Kakureneko keeps it awake only while an agent works.")
                    .font(.caption)
                    .foregroundStyle(Palette.ink3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity)
    }
}

private struct StepIndicator: View {
    let current: OnboardingFlow.Step

    var body: some View {
        HStack(spacing: 0) {
            ForEach(OnboardingFlow.Step.allCases) { step in
                // Numbered text steps (DESIGN.md §7: step indicators are text, not dots): done and current in amber.
                HStack(spacing: 6) {
                    ZStack {
                        if step.rawValue <= current.rawValue {
                            Circle().fill(Palette.amber)
                        } else {
                            Circle().strokeBorder(Palette.ink3)
                        }
                        if step.rawValue < current.rawValue {
                            Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(Palette.onAmber)
                        } else {
                            Text("\(step.rawValue + 1)")
                                .font(.caption.weight(step == current ? .bold : .regular))
                                .foregroundStyle(step == current ? Palette.onAmber : Palette.ink2)
                        }
                    }
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                    Text(step.title)
                        .font(.callout.weight(step == current ? .semibold : .regular))
                        .foregroundStyle(step == current ? Palette.ink : Palette.ink2)
                        .lineLimit(1)
                }
                .fixedSize() // labels never truncate; the connectors absorb the width
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Step \(step.rawValue + 1) of \(OnboardingFlow.Step.allCases.count): \(step.title)")
                .accessibilityAddTraits(step == current ? .isSelected : [])
                if step != OnboardingFlow.Step.allCases.last {
                    Hairline()
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 10)
                }
            }
        }
    }
}

private struct StepTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.title.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Step 1

private struct ClosedLidStep: View {
    let flow: OnboardingFlow

    var body: some View {
        let model = flow.model
        let summary = flow.privilegedSummary
        VStack(alignment: .leading, spacing: 16) {
            StepTitle(title: "Keep agents running with the lid closed",
                      subtitle: "Kakureneko stops the lid from sleeping your Mac, but only while an agent is working, and puts the Mac to sleep a few minutes after your agents finish.")
            VStack(alignment: .leading, spacing: 10) {
                FeatureLine(symbol: "key.fill",
                            text: "One administrator prompt installs a rule that lets Kakureneko switch sleep off and on, and nothing else.")
                FeatureLine(symbol: "lock.shield.fill",
                            text: "A fail-safe turns sleep back on if Kakureneko stops responding for about 3 minutes or the battery reaches \(SafetySettings.hardFloorPercentFixed) %.")
                FeatureLine(symbol: "battery.75percent",
                            text: "Kakureneko also sleeps on low battery, heat, a lost network or after \(SettingUnit.hours.format(model.snapshot.settings.safety.maxClosedLidHours)) with the lid closed.")
                FeatureLine(symbol: "bell.badge.fill",
                            text: "Without it, Kakureneko still sends alerts, but closing the lid sleeps the Mac.")
            }
            Card(tone: summary.tone == .muted ? .neutral : summary.tone) {
                HStack(spacing: 8) {
                    StatusDot(tone: summary.tone)
                    Text(summary.text).font(.callout)
                    if summary.isSimulated { Badge(text: "simulated", tone: .attention) }
                    Spacer()
                }
            }
            HStack(spacing: 10) {
                if model.snapshot.privileged.isOperational && !model.snapshot.privileged.simulated {
                    Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(Tone.success.color)
                } else {
                    ProgressButton(title: "Install…", isRunning: model.isRunning(.privileged), prominent: true, large: true) {
                        Task { await flow.installPrivileged() }
                    }
                    Button("Skip · notifications only") { Task { await flow.skipPrivileged() } }
                        .buttonStyle(.largeSecondary)
                }
            }
            Text("You can install or remove it later in Settings › Closed Lid & Safety.")
                .font(.caption)
                .foregroundStyle(Palette.ink3)
        }
    }
}

private struct FeatureLine: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Palette.amberInk)
                .frame(width: 20)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Step 2

private struct NotificationsStep: View {
    let flow: OnboardingFlow

    var body: some View {
        let model = flow.model
        let status = model.snapshot.notifications
        VStack(alignment: .leading, spacing: 18) {
            StepTitle(title: "Know when an agent finishes or needs you",
                      subtitle: "Alerts show on this Mac, and on your iPhone if you like. Their buttons keep the Mac awake or put it to sleep.")
            StepBlock(number: 1, title: "Notifications on this Mac") { MacPermissionRows(model: model, status: status) }
            StepBlock(number: 2, title: "Your iPhone") { OnboardingPhoneRows(flow: flow) }
            StepBlock(number: 3, title: "Try it") {
                SendTestRow(model: model, ready: AlertsSummary.make(status, settings: model.snapshot.settings.notifications).isReady)
            }
        }
    }
}

/// Step 2's iPhone part (`OnboardingFlow.PhoneSetup`). The iPhone app asks "Is Kakureneko on your Mac?" and quotes
/// "Set up my iPhone", so the two sides say the same thing.
private struct OnboardingPhoneRows: View {
    let flow: OnboardingFlow
    @State private var showHelp = false

    var body: some View {
        let model = flow.model
        let status = model.snapshot.notifications
        VStack(alignment: .leading, spacing: 10) {
            switch flow.phoneSetup {
            case .ask:
                Text("Get alerts on your iPhone too? You hear when an agent finishes or needs you, even away from the Mac, and can keep it awake from there.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Set up my iPhone") { Task { await flow.chooseIPhone() } }
                        .buttonStyle(.primary)
                    Button("Just this Mac") { Task { await flow.chooseMacOnly() } }
                        .buttonStyle(.secondary)
                }
            case .waitingForIPhone:
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        numbered(1, AppLinks.iPhoneApp == nil
                                 ? "Install Kakureneko on your iPhone."
                                 : "Scan the code with your iPhone's camera to get Kakureneko for iPhone (free).")
                        numbered(2, "Open it and follow its setup. When it asks whether Kakureneko is on your Mac, tap \u{201C}Yes, it's on my Mac\u{201D}.")
                        numbered(3, "Use the same Apple Account on both. This Mac finds the iPhone by itself.")
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Waiting for your iPhone…").font(.caption).foregroundStyle(Palette.ink2)
                        }
                        .padding(.top, 2)
                    }
                    if let link = AppLinks.iPhoneApp {
                        Spacer(minLength: 0)
                        QRCodeView(text: link.absoluteString, caption: "Scan with your iPhone", size: 96)
                    }
                }
                if showHelp {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Not showing up?").font(.callout.weight(.semibold))
                        Group {
                            Text("• On the iPhone, Kakureneko got past its iCloud step.")
                            Text("• Both use the same Apple Account: System Settings → your name on this Mac, Settings → your name on the iPhone.")
                            Text("• Both are online.")
                        }
                        .font(.callout)
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .transition(.opacity)
                }
                Button("Only this Mac instead") { Task { await flow.chooseMacOnly() } }
                    .buttonStyle(.accentLink)
                    .font(.callout)
            case .connected:
                ForEach(status.phones) { phone in
                    Label(AlertsSummary.phoneLine(phone, now: model.snapshot.generatedAt), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(phone.alertsAuthorized ? Tone.success.color : Tone.attention.color)
                    if !phone.alertsAuthorized {
                        Text("Notifications are off on this iPhone: allow them in its Settings → Notifications → Kakureneko.")
                            .font(.caption)
                            .foregroundStyle(Palette.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Connected through iCloud. Alerts reach it \(PhoneTimingText.phrase(model.snapshot.settings.notifications.phoneTiming, hasLid: model.snapshot.power?.lid != .noLid)); change that in Settings → Notifications.")
                    .font(.callout)
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            case .macOnly:
                Label("Alerts show only on this Mac.", systemImage: "laptopcomputer")
                Text("Nothing about this Mac goes to iCloud. Add an iPhone any time in Settings → Notifications.")
                    .font(.callout)
                    .foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Set up my iPhone") { Task { await flow.chooseIPhone() } }
                    .buttonStyle(.accentLink)
                    .font(.callout)
            case .iCloudUnavailable:
                Label(status.iCloud.explanation, systemImage: "icloud.slash")
                    .foregroundStyle(Tone.attention.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.easeOut(duration: 0.2), value: flow.phoneSetup)
        .task(id: flow.phoneSetup) {
            showHelp = false
            guard flow.phoneSetup == .waitingForIPhone else { return }
            try? await Task.sleep(for: OnboardingFlow.phoneHelpDelay)
            showHelp = true
        }
        .task(id: flow.phoneSetup == .waitingForIPhone) {
            guard flow.phoneSetup == .waitingForIPhone else { return }
            await flow.model.lookForPhonesWhileWaiting()
        }
    }

    private func numbered(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(number).").font(.callout.weight(.semibold)).monospacedDigit()
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Step 3

private struct IntegrationsStep: View {
    let flow: OnboardingFlow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepTitle(title: "Connect your agents",
                      subtitle: "A tiny hook tells Kakureneko exactly when an agent starts, finishes or waits for you. You see every change before it is made, and a backup is kept.")
            IntegrationListView(model: flow.model, context: .onboarding)
        }
    }
}

// MARK: - Step 4

private struct FinishStep: View {
    let flow: OnboardingFlow

    var body: some View {
        let model = flow.model
        let timers = model.snapshot.settings.timers
        VStack(alignment: .leading, spacing: 16) {
            StepTitle(title: "When every agent is done",
                      subtitle: "With the lid closed, Kakureneko counts down (\(SettingUnit.minutes.format(timers.finishCountdownMinutes)) after agents finish, \(SettingUnit.minutes.format(timers.needsInputCountdownMinutes)) if one waits for you) and then ends the session.")
            Picker("End action", selection: Binding(
                get: { flow.endAction },
                set: { action in Task { await flow.setEndAction(action) } })) {
                Text("Sleep (recommended)").tag(EndAction.sleep)
                Text("Shut down").tag(EndAction.shutdown)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text(flow.endAction == .sleep
                 ? "Sleep keeps every session; they continue when you open the lid."
                 : "Shut down ends terminal sessions. If an agent is waiting for you, or another app blocks the shutdown, Kakureneko sleeps instead. Next time you get a \"Reopen sessions\" offer.")
                .font(.callout)
                .foregroundStyle(Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if flow.endAction == .shutdown {
                AutomationConsentRow(model: model)
            }
            Hairline().padding(.vertical, 4)
            ChoiceRow(title: "Open Kakureneko at login", detail: "So it's there after a restart.",
                      isOn: Binding(get: { flow.openAtLogin }, set: { flow.openAtLogin = $0 }))
            if flow.offersUpdates {
                ChoiceRow(title: "Check for updates automatically", detail: "Once a day. You choose when to install.",
                          isOn: Binding(get: { flow.checkForUpdates }, set: { flow.checkForUpdates = $0 }))
            }
        }
    }
}

/// A title, a detail line and a switch at the trailing edge.
private struct ChoiceRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(Palette.ink2)
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .accessibilityElement(children: .combine)
    }
}

/// Automation consent status for the opt-in shutdown, with "Ask again".
struct AutomationConsentRow: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            if model.isRunning(.automation) {
                ProgressView().controlSize(.small)
                Text("Waiting for your answer to the macOS prompt…").font(.caption)
            } else if let consent = model.automationConsent {
                Image(systemName: consent.isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(consent.isGranted ? Tone.success.color : Tone.attention.color)
                Text(consent.text).font(.caption).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("macOS asks once whether Kakureneko may shut the Mac down.").font(.caption).foregroundStyle(Palette.ink2)
            }
            Spacer()
            if !(model.automationConsent?.isGranted ?? false) && !model.isRunning(.automation) {
                Button(model.isDryRun ? "Ask (dry run)" : "Ask for permission") {
                    Task { await model.requestAutomationConsent() }
                }
                .buttonStyle(.secondary)
            }
        }
    }
}
