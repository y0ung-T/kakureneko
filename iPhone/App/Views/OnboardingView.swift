// First run: what Kakureneko does → allow notifications (the system prompt comes only after the explanation) →
// iCloud check (same Apple Account as the Mac) → "Your Mac" (Model/MacSetup.swift): asks whether the Mac app is
// installed, guides to it or through its setup, and shows "Connected to <Mac>" once that Mac shares its status
// (Done finishes onboarding). Every waiting screen can be skipped and offers the demo (Model/Demo.swift).

import KakurenekoCloud
import SwiftUI

enum OnboardingStep: Int, Hashable, CaseIterable {
    case welcome, notifications, iCloud, waitingForMac

    var name: String {
        switch self {
        case .welcome: "Welcome"
        case .notifications: "Notifications"
        case .iCloud: "iCloud"
        case .waitingForMac: "Your Mac"
        }
    }

    /// Where onboarding starts: the welcome (Debug builds: `-KakurenekoDemoStep waitingForMac` and the like, for
    /// Simulator screenshots).
    static var first: OnboardingStep {
        #if DEBUG
        if let name = UserDefaults.standard.string(forKey: "KakurenekoDemoStep"),
           let step = allCases.first(where: { "\($0)" == name }) { return step }
        #endif
        return .welcome
    }

    /// "Step 1 of 4 · Notifications · iCloud · Your Mac": where you are, then what comes next (text, not dots).
    var progressText: String {
        let all = Self.allCases
        let next = all.filter { $0.rawValue > rawValue }.map(\.name)
        return (["Step \(rawValue + 1) of \(all.count)"] + next).joined(separator: " · ")
    }
}

struct OnboardingView: View {
    @Environment(PhoneStore.self) private var store
    @State private var step: OnboardingStep

    init(step: OnboardingStep = .first) {
        _step = State(initialValue: step)
    }

    var body: some View {
        Group {
            switch step {
            // Each step only moves on from itself: a late callback (the permission prompt's save finishing after
            // the user already tapped Continue) must never send them back.
            case .welcome: WelcomeStep { advance(from: .welcome, to: .notifications) }
            case .notifications: NotificationsStep { advance(from: .notifications, to: .iCloud) }
            case .iCloud: ICloudStep { advance(from: .iCloud, to: .waitingForMac) }
            case .waitingForMac: YourMacStep()
            }
        }
        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)).combined(with: .opacity))
        .animation(.default, value: step)
    }

    private func advance(from current: OnboardingStep, to target: OnboardingStep) {
        if step == current { step = target }
    }
}

/// The layout every step shares (DESIGN.md §7, onboarding): the pose at the top, title, one short paragraph, the
/// content, and the buttons pinned to the bottom over the step text.
private struct OnboardingPage<Content: View, Actions: View>: View {
    let step: OnboardingStep
    let pose: MascotPose
    let title: String
    let message: String
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions
    @ScaledMetric(relativeTo: .largeTitle) private var poseHeight = 170

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                MascotView(pose: pose, height: min(poseHeight, 210))
                    .padding(.top, 32)
                Text(title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(.body)
                    .foregroundStyle(Palette.ink2)
                    .multilineTextAlignment(.center)
                content
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Palette.paper)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                actions
                Text(step.progressText)
                    .font(.footnote)
                    .foregroundStyle(Palette.ink3)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .background {
                Palette.paper.opacity(0.94)
                    .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
                    .ignoresSafeArea()
            }
        }
    }
}

/// The amber capsule with ink text.
private struct PrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.primaryCapsule)
    }
}

private struct FeatureRow: View {
    let symbol: String
    let text: String
    @ScaledMetric(relativeTo: .title2) private var iconWidth = 36

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Palette.amberInk)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct WelcomeStep: View {
    let next: () -> Void

    var body: some View {
        OnboardingPage(step: .welcome, pose: .sit, title: "Welcome to Kakureneko",
                       message: "Kakureneko keeps your Mac awake while your AI agents work, even with the lid closed, and lets it sleep when they're done. This app keeps you in the loop.") {
            VStack(alignment: .leading, spacing: 18) {
                FeatureRow(symbol: "bell.badge", text: "Know when an agent finishes or needs your input.")
                FeatureRow(symbol: "timer", text: "Get a heads-up before your Mac goes to sleep.")
                FeatureRow(symbol: "cup.and.heat.waves", text: "Keep it awake or put it to sleep from your iPhone.")
                FeatureRow(symbol: "icloud", text: "Works through Apple's iCloud: no account to create, no analytics.")
            }
            .padding(.top, 12)
        } actions: {
            PrimaryButton(title: "Continue", action: next)
        }
    }
}

private struct NotificationsStep: View {
    let next: () -> Void
    @Environment(PhoneStore.self) private var store

    var body: some View {
        let authorization = store.notificationAuthorization
        OnboardingPage(step: .notifications, pose: .wave, title: "Stay in the loop",
                       message: "Allow notifications so Kakureneko can tell you when an agent finishes or needs you, and before your Mac goes to sleep. Time Sensitive alerts can break through Focus.") {
            if let authorization, authorization.status != .notDetermined {
                Label(authorization.alertsAllowed ? "Notifications are on." : "Notifications are off. You can turn them on later in Settings.",
                      systemImage: authorization.alertsAllowed ? "checkmark.circle.fill" : "bell.slash")
                    .foregroundStyle(authorization.alertsAllowed ? Tint.finished.color : Palette.ink2)
                    .padding(.top, 8)
            }
        } actions: {
            if authorization?.status == .notDetermined {
                PrimaryButton(title: "Allow notifications") {
                    Task {
                        await store.requestNotificationAuthorization()
                        next()
                    }
                }
                Button("Not now", action: next)
            } else {
                PrimaryButton(title: "Continue", action: next)
            }
        }
        .task { await store.refreshNotificationAuthorization() }
    }
}

private struct ICloudStep: View {
    let next: () -> Void
    @Environment(PhoneStore.self) private var store
    @State private var checking = false

    var body: some View {
        let account = store.account
        let ready = account?.isAvailable == true
        OnboardingPage(step: .iCloud, pose: .peek, title: "Connect through iCloud",
                       message: "Kakureneko reaches your Mac through Apple's iCloud: no account to create, no server of ours in between. Use the same Apple Account on this iPhone and on your Mac.") {
            Group {
                if checking || account == nil {
                    ProgressView("Checking iCloud…")
                } else if let account, !ready {
                    VStack(spacing: 8) {
                        Label(account.shortTitle, systemImage: "exclamationmark.icloud")
                            .font(.headline)
                            .foregroundStyle(Tint.attention.color)
                        Text(account.phoneExplanation)
                            .multilineTextAlignment(.center)
                        Text("Settings → your name → iCloud")
                            .font(.footnote)
                            .foregroundStyle(Palette.ink2)
                    }
                } else {
                    Label("iCloud is ready.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Tint.finished.color)
                }
            }
            .padding(.top, 8)
        } actions: {
            if ready || account == nil {
                PrimaryButton(title: "Continue", action: next)
                    .disabled(account == nil)
            } else {
                PrimaryButton(title: "Check again") { Task { await check() } }
                Button("Continue anyway", action: next)
            }
        }
        .task { await check() }
    }

    private func check() async {
        checking = true
        await store.refreshAccount()
        checking = false
    }
}

/// Step 4 (Model/MacSetup.swift): asks whether the Mac app is installed, then guides either way; a Mac that shares
/// its status turns any of its screens into "Connected", and Done finishes onboarding.
private struct YourMacStep: View {
    @Environment(PhoneStore.self) private var store
    @State private var answer: MacSetupAnswer? = Self.initialAnswer

    /// nil: not asked yet (Debug builds: `-KakurenekoDemoMacAnswer onMac|notYet`, for Simulator screenshots).
    private static var initialAnswer: MacSetupAnswer? {
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "KakurenekoDemoMacAnswer") {
        case "onMac": return .onMac
        case "notYet": return .notYet
        default: return nil
        }
        #else
        return nil
        #endif
    }

    var body: some View {
        Group {
            switch MacSetupScreen.of(answer: answer, macs: store.macs) {
            case .question:
                MacQuestionScreen(answer: $answer)
            case .getMacApp:
                GetMacAppScreen(answer: $answer)
            case .waiting:
                WaitingForMacScreen(answer: $answer)
            case .connected(let macName, let macID):
                ConnectedScreen(macName: macName, macID: macID)
            }
        }
        .animation(.default, value: MacSetupScreen.of(answer: answer, macs: store.macs))
    }
}

/// "See a demo" and "Skip for now", under each screen that waits for a Mac.
private struct DemoAndSkip: View {
    @Environment(PhoneStore.self) private var store
    /// Optional so previews without the app's root still render (the button is hidden then).
    @Environment(DemoMode.self) private var demo: DemoMode?

    var body: some View {
        HStack(spacing: 24) {
            if let demo {
                Button("See a demo") { demo.start() }
            }
            Button("Skip for now") { store.completeOnboarding() }
        }
        .font(.body.weight(.medium))
        .foregroundStyle(Palette.ink)
    }
}

private struct MacQuestionScreen: View {
    @Binding var answer: MacSetupAnswer?

    var body: some View {
        OnboardingPage(step: .waitingForMac, pose: .sit, title: "Is Kakureneko on your Mac?",
                       message: "This app works with Kakureneko for Mac. The Mac app keeps your Mac awake while your agents work and sends the alerts you get here.") {
            EmptyView()
        } actions: {
            PrimaryButton(title: "Yes, it's on my Mac") { answer = .onMac }
            Button("Not yet") { answer = .notYet }
                .buttonStyle(.secondaryCapsule)
            DemoAndSkip()
        }
    }
}

private struct GetMacAppScreen: View {
    @Binding var answer: MacSetupAnswer?
    @State private var copied = false

    var body: some View {
        let link = AppLinks.macDownload
        OnboardingPage(step: .waitingForMac, pose: .peek, title: "Get Kakureneko for Mac",
                       message: "It's a free download. Open this address on your Mac, install the app and go through its setup.") {
            VStack(spacing: 14) {
                Text(MacSetupText.display(link))
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
                    .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.line) }
                HStack(spacing: 12) {
                    ShareLink(item: link, subject: Text("Kakureneko for Mac"),
                              message: Text("Kakureneko for Mac: \(link.absoluteString)")) {
                        Label("Send link", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.secondaryCapsule)
                    Button {
                        UIPasteboard.general.url = link
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.secondaryCapsule)
                }
                Text("Send it to your Mac with AirDrop or Messages, or copy it and paste it on your Mac.")
                    .font(.footnote)
                    .foregroundStyle(Palette.ink2)
                    .multilineTextAlignment(.center)
                WaitingLine(text: "Waiting for your Mac…")
            }
            .padding(.top, 8)
        } actions: {
            PrimaryButton(title: "I've installed it") { answer = .onMac }
            DemoAndSkip()
        }
    }
}

private struct WaitingForMacScreen: View {
    @Binding var answer: MacSetupAnswer?
    /// After `helpDelay`: "Still waiting? What to check" in the bottom bar, which is always on screen.
    @State private var offerHelp = false
    @State private var showHelp = false

    var body: some View {
        OnboardingPage(step: .waitingForMac, pose: .hide, title: "Open Kakureneko on your Mac",
                       message: "Your Mac appears here by itself as soon as Kakureneko on it shares its status.") {
            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(symbol: "1.circle.fill", text: "Click the cat in your Mac's menu bar.")
                FeatureRow(symbol: "2.circle.fill", text: "In its setup, choose \u{201C}\(MacSetupText.macButton)\u{201D}. Already set up? Check \(MacSetupText.macSetting).")
                FeatureRow(symbol: "3.circle.fill", text: "Use the same Apple Account on this iPhone and on the Mac.")
                WaitingLine(text: "Waiting for your Mac…")
            }
            .padding(.top, 8)
        } actions: {
            if offerHelp {
                Button("Still waiting? What to check") { showHelp = true }
                    .buttonStyle(.secondaryCapsule)
                    .transition(.opacity)
            }
            Button("I don't have it yet") { answer = .notYet }
                .buttonStyle(.secondaryCapsule)
            DemoAndSkip()
        }
        .task {
            try? await Task.sleep(for: MacSetupScreen.helpDelay)
            withAnimation { offerHelp = true }
        }
        .sheet(isPresented: $showHelp) {
            NavigationStack {
                ScrollView {
                    StillWaitingHelp()
                        .padding(20)
                }
                .background(Palette.paper)
                .navigationTitle("What to check")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { showHelp = false } }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

/// What to check when the Mac doesn't show up.
private struct StillWaitingHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your Mac shows up here once all of these are true:").font(.headline)
            Group {
                Text("• Kakureneko is running on the Mac: the cat is in its menu bar.")
                Text("• \(MacSetupText.macSetting) is on.")
                Text("• Both use the same Apple Account: Settings → your name on this iPhone, System Settings → your name on the Mac.")
                Text("• Both are online.")
            }
            .font(.callout)
            .foregroundStyle(Palette.ink2)
            .fixedSize(horizontal: false, vertical: true)
            Link(destination: AppLinks.support) {
                Text("More help").underline()
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(Palette.ink)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// A small spinner with a line of text.
private struct WaitingLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text).font(.callout).foregroundStyle(Palette.ink2)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct ConnectedScreen: View {
    let macName: String
    let macID: String
    @Environment(PhoneStore.self) private var store

    var body: some View {
        OnboardingPage(step: .waitingForMac, pose: .coffee, title: "Connected to \(macName)",
                       message: "Alerts from this Mac arrive here: when an agent finishes or needs you, and before the Mac goes to sleep. Their buttons keep it awake or put it to sleep.") {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let feedback = store.visibleFeedback(for: macID, channel: .test, at: context.date) {
                    FeedbackLine(feedback: feedback, macName: macName)
                }
            }
            .padding(.top, 8)
        } actions: {
            PrimaryButton(title: "Done") { store.completeOnboarding() }
            Button {
                Task { await store.sendTestAlert() }
            } label: {
                Label("Send a test alert", systemImage: "bell.badge")
            }
            .buttonStyle(.secondaryCapsule)
            .disabled(store.account != .available)
        }
    }
}

#if DEBUG
#Preview("Welcome") {
    PreviewHost(.firstRun) { OnboardingView() }
}

#Preview("Notifications") {
    PreviewHost(.firstRun) { OnboardingView(step: .notifications) }
}

#Preview("iCloud missing") {
    PreviewHost(.noICloud) { OnboardingView(step: .iCloud) }
}

#Preview("Waiting for Mac") {
    PreviewHost(.firstRun) { OnboardingView(step: .waitingForMac) }
}
#endif
