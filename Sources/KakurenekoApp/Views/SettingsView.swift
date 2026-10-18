// The settings window: every `KakurenekoSettings` section, edited as a LOCAL draft (`AppModel.settingsDraft`) and
// sent with `updateSettings` on Apply (or when the window closes). Numeric ranges come from `SettingsCatalog`,
// i.e. the Kit `…Range` constants. Toggles that act on the system at once (Kakureneko on/off, launch at login,
// never-pause entries, notification and agent actions) are immediate and do not go through the draft.

import AppKit
import KakurenekoKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding<SettingsPane?>(
                get: { model.settingsPane },
                set: { if let pane = $0 { model.settingsPane = pane } })) { pane in
                Label(pane.title, systemImage: pane.symbolName).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 220)
        } detail: {
            VStack(spacing: 0) {
                if let banner = model.banner {
                    ErrorBannerView(banner: banner) { model.dismissBanner() }
                        .padding([.horizontal, .top], 16)
                }
                SettingsPaneView(model: model, pane: model.settingsPane)
                if model.settingsDraft.isDirty {
                    ApplyBar(model: model)
                }
            }
            .navigationTitle(model.settingsPane.title)
        }
        .toolbar(removing: .sidebarToggle)
        .tint(Palette.amber)
        .frame(minWidth: 760, idealWidth: 800, minHeight: 540, idealHeight: 620)
    }
}

private struct ApplyBar: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(spacing: 10) {
                Image(systemName: "pencil").foregroundStyle(Palette.amberInk)
                Text("Unsaved changes").font(.callout)
                Spacer()
                Button("Revert") { model.revertSettings() }
                    .buttonStyle(.largeSecondary)
                ProgressButton(title: "Apply", isRunning: model.isRunning(.settings), prominent: true, large: true) {
                    Task { await model.commitSettings() }
                }
                .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .background(Palette.card)
    }
}

private struct SettingsPaneView: View {
    let model: AppModel
    let pane: SettingsPane

    var body: some View {
        Form {
            switch pane {
            case .general: GeneralPane(model: model)
            case .closedLid: ClosedLidPane(model: model)
            case .sessions: SessionsPane(model: model)
            case .pausing: PausingPane(model: model)
            case .notifications: NotificationsPane(model: model)
            case .integrations: AgentsPane(model: model)
            case .advanced: AdvancedPane(model: model)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Palette.paper)
    }
}

/// A stepper row for one catalog entry, editing the draft.
private struct IntSettingRow: View {
    let spec: IntSettingSpec
    let draft: SettingsDraft

    var body: some View {
        let value = draft.value[keyPath: spec.keyPath]
        Stepper(value: Binding(
            get: { draft.value[keyPath: spec.keyPath] },
            set: { draft.value[keyPath: spec.keyPath] = spec.clamp($0) }),
                in: spec.range, step: spec.step) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(spec.title)
                    Spacer()
                    Text(spec.format(value)).monospacedDigit().foregroundStyle(Palette.ink2)
                }
                if let help = spec.help {
                    Text(help).font(.caption).foregroundStyle(Palette.ink2)
                }
            }
        }
        .help("Range: \(spec.rangeText)")
    }
}

/// Binding into the draft.
@MainActor
private func draftBinding<T>(_ draft: SettingsDraft, _ keyPath: WritableKeyPath<KakurenekoSettings, T>) -> Binding<T> {
    Binding(get: { draft.value[keyPath: keyPath] }, set: { draft.value[keyPath: keyPath] = $0 })
}

// MARK: - General

private struct GeneralPane: View {
    let model: AppModel

    var body: some View {
        let draft = model.settingsDraft
        Section {
            Toggle(isOn: Binding(get: { model.snapshot.settings.general.enabled },
                                 set: { on in Task { await model.setEnabled(on) } })) {
                Text("Kakureneko is on")
                Text("Off: no keeping awake, no pausing and no pushes. Sessions are still shown.")
            }
            Toggle(isOn: Binding(get: { model.snapshot.settings.general.launchAtLogin },
                                 set: { on in Task { await model.setLaunchAtLogin(on) } })) {
                Text("Open Kakureneko at login")
                Text(launchAtLoginCaption)
            }
            if model.loginItemStatus == .requiresApproval {
                Button("Open Login Items Settings…") { model.openLoginItemsSettings() }
            }
        }
        Section("When agents are working") {
            Toggle(isOn: draftBinding(draft, \.power.keepAwakeWithLidClosed)) {
                Text("Keep the Mac awake with the lid closed")
                Text("Needs closed-lid mode. The Mac sleeps a few minutes after your agents finish.")
            }
        }
        Section("When every agent is done") {
            Picker("Then", selection: draftBinding(draft, \.power.endAction)) {
                Text("Sleep (recommended)").tag(EndAction.sleep)
                Text("Shut down").tag(EndAction.shutdown)
            }
            if draft.value.power.endAction == .shutdown {
                Text("Shut down falls back to sleep when an agent waits for you or an app blocks it. Alerts also get a Shut down button.")
                    .font(.caption)
                    .foregroundStyle(Palette.ink2)
                AutomationConsentRow(model: model)
            }
        }
        Section {
            Button("Show Setup Again…") { model.openOnboarding() }
        }
        UpdatesAndAboutSection(model: model)
        UninstallSection(model: model)
    }

    private var launchAtLoginCaption: String {
        if model.isDryRun { return "Dry run: changes to the login item are only logged." }
        if !model.environment.isBundled { return "Only available when running Kakureneko.app." }
        return "macOS: \(model.loginItemStatus.text)"
    }
}

/// Version, Sparkle (Developer ID builds) and the website's links.
private struct UpdatesAndAboutSection: View {
    let model: AppModel

    var body: some View {
        let updater = model.environment.updater
        let links = AppLinks.release
        Section("About Kakureneko") {
            LabeledContent("Version", value: AppLinks.versionText)
            if updater.isAvailable {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { model.snapshot.settings.general.automaticUpdateChecks },
                    set: { on in Task { await model.setAutomaticUpdateChecks(on) } }))
                Button("Check for Updates…") { model.checkForUpdates() }
                    .disabled(!updater.canCheckNow)
            }
            if links.website != nil {
                HStack(spacing: 16) {
                    if let website = links.website { Link("Website", destination: website) }
                    if let privacy = links.privacyPolicy { Link("Privacy policy", destination: privacy) }
                    if let support = links.support { Link("Support", destination: support) }
                }
                .foregroundStyle(Palette.amberInk)
            }
        }
    }
}

/// "Uninstall Kakureneko…": everything Kakureneko added, after a confirmation that lists it (`UninstallPlan`).
private struct UninstallSection: View {
    let model: AppModel
    @State private var confirm = false

    var body: some View {
        Section {
            HStack {
                Button("Uninstall Kakureneko…", role: .destructive) { confirm = true }
                    .disabled(model.isRunning(.uninstall))
                if model.isRunning(.uninstall) {
                    ProgressView().controlSize(.small)
                    if let step = model.uninstallStep {
                        Text(step).font(.callout).foregroundStyle(Palette.ink2)
                    }
                }
            }
        } footer: {
            Text("Removes closed-lid mode, the agent hooks, the login item and Kakureneko's files, then moves the app to the Trash. Dragging the app to the Trash alone leaves those behind.")
                .foregroundStyle(Palette.ink2)
        }
        .confirmationDialog("Uninstall Kakureneko?", isPresented: $confirm) {
            Button(model.isDryRun ? "Uninstall (dry run)" : "Uninstall", role: .destructive) {
                Task { await model.uninstall() }
            }
        } message: {
            Text("This removes:\n" + model.uninstallPlan.lines.map { "• " + $0 }.joined(separator: "\n"))
        }
    }
}

// MARK: - Closed lid & safety

private struct ClosedLidPane: View {
    let model: AppModel
    @State private var confirmRemove = false

    var body: some View {
        let draft = model.settingsDraft
        let status = model.snapshot.privileged
        let summary = PrivilegedSummary.make(status)
        Section {
            HStack(spacing: 8) {
                StatusDot(tone: summary.tone)
                Text(summary.text)
                if summary.isSimulated { Badge(text: "simulated", tone: .attention) }
                Spacer()
                if model.isRunning(.privileged) { ProgressView().controlSize(.small) }
            }
            if let detail = status.detail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(Palette.ink2)
            }
            Text("One administrator prompt installs a sudoers rule that only allows `pmset -a disablesleep 1|0`, and a fail-safe that turns sleep back on if Kakureneko stops for about 3 minutes or the battery reaches \(SafetySettings.hardFloorPercentFixed) %.")
                .font(.caption)
                .foregroundStyle(Palette.ink2)
            HStack {
                Button(status.isOperational && !status.simulated ? "Reinstall…" : "Install…") {
                    Task { await model.installPrivilegedHelper() }
                }
                .disabled(model.isRunning(.privileged))
                Button("Check Again") { Task { await model.refreshPrivilegedStatus() } }
                Spacer()
                if status.sudoRuleInstalled || status.failsafeLoaded {
                    Button("Remove…", role: .destructive) { confirmRemove = true }
                        .disabled(model.isRunning(.privileged))
                }
            }
        } header: {
            Text("Closed-lid mode")
        }
        .confirmationDialog("Remove closed-lid mode?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { Task { await model.uninstallPrivilegedHelper() } }
        } message: {
            Text("Closing the lid will sleep the Mac again. Kakureneko keeps sending alerts.")
        }
        Section("With the lid closed") {
            Toggle(isOn: draftBinding(draft, \.safety.allowOnBattery)) {
                Text("Allow on battery")
                Text("Off: the Mac sleeps whenever it is on battery with the lid closed.")
            }
            Toggle("Turn the display off when the lid closes", isOn: draftBinding(draft, \.power.displaySleepOnLidClose))
            Picker(selection: draftBinding(draft, \.power.lidCloseSound)) {
                Text("Never").tag(LidCloseSound.off)
                Text("On battery").tag(LidCloseSound.onBattery)
                Text("Always").tag(LidCloseSound.always)
            } label: {
                Text("Play a sound when the lid closes")
                Text("While an agent keeps the Mac awake. A reminder not to put a running Mac in a bag.")
            }
        }
        Section("Safety") {
            ForEach(SettingsCatalog.safety) { spec in
                IntSettingRow(spec: spec, draft: draft)
            }
            LabeledContent("Fail-safe battery floor", value: "\(SafetySettings.hardFloorPercentFixed) % (fixed)")
            Toggle("Warn about Low Power Mode on battery", isOn: draftBinding(draft, \.safety.warnLowPowerMode))
        }
    }
}

// MARK: - Sessions

private struct SessionsPane: View {
    let model: AppModel

    var body: some View {
        let draft = model.settingsDraft
        Section {
            ForEach(SettingsCatalog.timers) { spec in
                IntSettingRow(spec: spec, draft: draft)
            }
        } header: {
            Text("Timers")
        } footer: {
            Text("A countdown only starts with the lid closed and nobody at the Mac.")
        }
        Section("Fixed") {
            ForEach(SettingsCatalog.fixedTimers(draft.value.timers), id: \.title) { item in
                LabeledContent(item.title, value: item.value)
            }
        }
    }
}

// MARK: - Pausing

private struct PausingPane: View {
    let model: AppModel
    @State private var newBundleID = ""
    @State private var bundleIDError: String?

    var body: some View {
        let draft = model.settingsDraft
        let freezeAllowed = model.snapshot.groupingSelfTest?.freezeAllowed ?? false
        Section {
            Text(SettingsCatalog.pausingMemorySentence)
                .font(.callout)
            Toggle(isOn: draftBinding(draft, \.pausing.enabled)) {
                Text("Pause other apps while the lid is closed")
                Text("Never touches apps that run or talk to an agent, play audio or download.")
            }
            Picker("Mode", selection: draftBinding(draft, \.pausing.mode)) {
                Text("Throttle (default)").tag(PauseMode.throttle)
                Text("Freeze (experimental)").tag(PauseMode.freeze)
                    .disabled(!freezeAllowed)
            }
            if draft.value.pausing.mode == .freeze && !freezeAllowed {
                Label("Freeze is unavailable on this Mac (\(model.snapshot.groupingSelfTest?.detail ?? "self-test not passed")). Throttle is used.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Tone.attention.color)
            }
            // "Let frozen apps breathe" (R06 §5.7) is not implemented in v1: no toggle that promises it
            // (`PauseSettings.breathing` stays in the schema for v2).
            Toggle(isOn: draftBinding(draft, \.pausing.quitWhenMemoryLow)) {
                Text("Quit idle apps when memory is low")
                Text("Only apps with nothing unsaved. They reopen when you open the lid.")
            }
        } header: {
            Text("Pausing")
        }
        Section("Timing") {
            ForEach(SettingsCatalog.pausing) { spec in
                IntSettingRow(spec: spec, draft: draft)
            }
        }
        Section {
            let list = model.snapshot.settings.pausing.neverPauseBundleIDs
            if list.isEmpty {
                Text("No apps yet.").foregroundStyle(Palette.ink2)
            }
            ForEach(list, id: \.self) { bundleID in
                HStack {
                    AppNameLabel(bundleID: bundleID)
                    Spacer()
                    Button {
                        Task { await model.setNeverPause(bundleID: bundleID, false) }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove from the list")
                }
            }
            HStack {
                TextField("Bundle identifier, e.g. com.spotify.client", text: $newBundleID)
                    .onSubmit(addTyped)
                Button("Add", action: addTyped).disabled(newBundleID.isEmpty)
                Button("Choose App…", action: chooseApp)
            }
            if let bundleIDError {
                Text(bundleIDError).font(.caption).foregroundStyle(Tone.critical.color)
            }
        } header: {
            Text("Never pause")
        } footer: {
            Text("Changes to this list apply at once.")
        }
    }

    private func addTyped() {
        guard let id = BundleIDInput.normalize(newBundleID) else {
            bundleIDError = "That does not look like a bundle identifier."
            return
        }
        bundleIDError = nil
        newBundleID = ""
        Task { await model.setNeverPause(bundleID: id, true) }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.allowsMultipleSelection = false
        panel.prompt = "Never Pause"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let id = Bundle(url: url)?.bundleIdentifier else {
            bundleIDError = "\(url.deletingPathExtension().lastPathComponent) has no bundle identifier."
            return
        }
        bundleIDError = nil
        Task { await model.setNeverPause(bundleID: id, true) }
    }
}

/// Shows an app's name (read-only LaunchServices lookup) next to its bundle id.
private struct AppNameLabel: View {
    let bundleID: String

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack(spacing: 8) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                    .resizable()
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "app.dashed").frame(width: 18, height: 18)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(url.map { $0.deletingPathExtension().lastPathComponent } ?? bundleID)
                if url != nil {
                    Text(bundleID).font(.caption).foregroundStyle(Palette.ink2)
                }
            }
        }
    }
}

// MARK: - Notifications

private struct NotificationsPane: View {
    let model: AppModel

    var body: some View {
        let draft = model.settingsDraft
        let notifications = draft.value.notifications
        let status = model.snapshot.notifications
        let summary = AlertsSummary.make(status, settings: model.snapshot.settings.notifications)
        Section {
            Toggle(isOn: draftBinding(draft, \.notifications.enabled)) {
                Text("Send alerts")
                Text("When an agent finishes or needs you, and before the Mac goes to sleep.")
            }
            HStack(spacing: 8) {
                StatusDot(tone: summary.tone)
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.text)
                    if let detail = summary.detail { Text(detail).font(.caption).foregroundStyle(Palette.ink2) }
                }
                Spacer(minLength: 8)
                ProgressButton(title: "Send Test", isRunning: model.isRunning(.sendTest)) {
                    Task { await model.sendTestNotification() }
                }
                .disabled(!summary.isReady)
                .help("Sends a test alert to this Mac and every connected iPhone.")
            }
        }

        Section {
            Toggle(isOn: draftBinding(draft, \.notifications.macAlerts)) {
                Text("Show alerts on this Mac")
                Text("macOS notifications with Keep awake and Sleep buttons, whenever they happen.")
            }
            if notifications.macAlerts {
                MacPermissionRows(model: model, status: status)
            }
        } header: {
            ScopeHeader(title: "This Mac", scope: .mac)
        }

        Section {
            // Acts at once (not on Apply): the iPhone rows below wait for an iPhone, which needs this Mac in iCloud.
            Toggle(isOn: Binding(get: { draft.value.notifications.phoneAlerts },
                                 set: { on in
                                     draft.value.notifications.phoneAlerts = on
                                     Task { await model.updateSettingsNow { $0.notifications.phoneAlerts = on } }
                                 })) {
                Text("Send alerts to your iPhone")
                Text("Through iCloud to the Kakureneko app on iPhones signed in to your Apple Account.")
            }
            if notifications.phoneAlerts {
                Picker(selection: draftBinding(draft, \.notifications.phoneTiming)) {
                    ForEach(PhoneAlertTiming.allCases, id: \.self) { timing in
                        Text(PhoneTimingText.title(timing)).tag(timing)
                    }
                } label: {
                    Text("Send them")
                    Text(PhoneTimingText.explanation(notifications.phoneTiming))
                }
                if notifications.phoneTiming == .away {
                    IntSettingRow(spec: SettingsCatalog.awayIdle, draft: draft)
                }
                PhoneLinkRows(model: model, status: status)
                Text(PhoneTimingText.footnote)
                    .font(.caption)
                    .foregroundStyle(Palette.ink2)
            }
        } header: {
            ScopeHeader(title: "iPhone", scope: .phone)
        }

        Section {
            ForEach(NotificationKindText.mutable, id: \.self) { kind in
                Toggle(NotificationKindText.name(kind), isOn: Binding(
                    get: { !draft.value.notifications.mutedKinds.contains(kind) },
                    set: { on in
                        if on { draft.value.notifications.mutedKinds.remove(kind) } else { draft.value.notifications.mutedKinds.insert(kind) }
                    }))
                if kind == .finished && !notifications.isMuted(.finished) {
                    Picker(selection: draftBinding(draft, \.notifications.minimumWorkSeconds)) {
                        ForEach(SettingsCatalog.minimumWorkChoices(current: notifications.minimumWorkSeconds), id: \.seconds) { choice in
                            Text(choice.label).tag(choice.seconds)
                        }
                    } label: {
                        Text("Only after working at least")
                        Text("Quicker turns finish silently.")
                    }
                    .padding(.leading, 16)
                }
            }
            Toggle(isOn: draftBinding(draft, \.notifications.skipClaudeRemoteControlSessions)) {
                Text("Skip Claude sessions with Remote Control connected")
                Text("Claude Code already notifies you about those.")
            }
        } header: {
            ScopeHeader(title: "What to alert about", scope: .both)
        }

        Section {
            Picker("Detail", selection: draftBinding(draft, \.notifications.detailLevel)) {
                ForEach(DetailLevel.allCases, id: \.self) { level in
                    Text(NotificationKindText.detailLevel(level)).tag(level)
                }
            }
            IntSettingRow(spec: SettingsCatalog.keepAwakeButton, draft: draft)
            ForEach(SettingsCatalog.notifications) { spec in
                IntSettingRow(spec: spec, draft: draft)
            }
        } header: {
            ScopeHeader(title: "How alerts behave", scope: .both)
        }

        Section {
            Toggle(isOn: draftBinding(draft, \.notifications.quietHours.enabled)) {
                Text("Quiet hours")
                Text("Alerts still arrive, silently (\(QuietHoursText.range(notifications.quietHours))).")
            }
            if notifications.quietHours.enabled {
                DatePicker("From", selection: minuteBinding(draft, \.notifications.quietHours.startMinute),
                           displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: minuteBinding(draft, \.notifications.quietHours.endMinute),
                           displayedComponents: .hourAndMinute)
            }
        } header: {
            ScopeHeader(title: "Quiet hours", scope: .both)
        }
    }

    private func minuteBinding(_ draft: SettingsDraft, _ keyPath: WritableKeyPath<KakurenekoSettings, Int>) -> Binding<Date> {
        Binding(
            get: { QuietHoursText.date(fromMinute: draft.value[keyPath: keyPath], reference: Date()) },
            set: { draft.value[keyPath: keyPath] = QuietHoursText.minute(from: $0) })
    }
}

/// A Notifications section header that says where its settings apply: this Mac, the iPhone, or both.
private struct ScopeHeader: View {
    let title: String
    let scope: SettingScope

    var body: some View {
        HStack(spacing: 6) {
            switch scope {
            case .mac: Label(title, systemImage: "laptopcomputer")
            case .phone: Label(title, systemImage: "iphone")
            case .both:
                Text(title)
                Spacer()
                HStack(spacing: 3) {
                    Image(systemName: "laptopcomputer")
                    Image(systemName: "iphone")
                    Text(SettingScope.both.title)
                }
                .font(.caption)
                .foregroundStyle(Palette.ink2)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
                .help("Applies to alerts on this Mac and on your iPhone.")
            }
        }
    }
}

// MARK: - Agents

private struct AgentsPane: View {
    let model: AppModel

    var body: some View {
        let draft = model.settingsDraft
        Section {
            IntegrationListView(model: model, context: .settings)
        } header: {
            HStack {
                Text("Agent hooks")
                Spacer()
                Button("Refresh") { Task { await model.refreshIntegrations() } }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
        }
        Section {
            Toggle(isOn: draftBinding(draft, \.integrations.autoRepair)) {
                Text("Repair hooks automatically")
                Text("When an agent rewrites its settings and drops the Kakureneko hook. Off: you get a Repair button.")
            }
            let hidden = model.snapshot.settings.integrations.dismissedAgents.sorted()
            if !hidden.isEmpty {
                ForEach(hidden, id: \.self) { agent in
                    HStack {
                        Text("\(agent.displayName) is hidden from setup")
                        Spacer()
                        Button("Show") { Task { await model.restoreIntegration(agent) } }
                            .buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}

// MARK: - Advanced

private struct AdvancedPane: View {
    let model: AppModel

    var body: some View {
        let draft = model.settingsDraft
        Section {
            Toggle(isOn: draftBinding(draft, \.general.dryRun)) {
                Text("Dry run")
                Text(model.snapshot.isDryRunForced
                     ? "Forced on by KAKURENEKO_DRY_RUN for this launch."
                     : "Log every decision (\"would sleep\", \"would throttle…\") instead of acting. Safe for testing.")
            }
            .disabled(model.snapshot.isDryRunForced)
            Toggle(isOn: draftBinding(draft, \.general.fileLogEnabled)) {
                Text("Write a log file")
                Text("~/.kakureneko/log/kakureneko.log (no prompts, messages or secrets). Applies at the next launch.")
            }
        } header: {
            Text("Developer")
        }
        if model.isDryRun {
            Section("Dry-run decisions") {
                let lines = DryRunLine.feed(ledger: model.snapshot.dryRunLog, local: model.localDryRunLog, limit: 50)
                if lines.isEmpty {
                    Text("Nothing yet.").foregroundStyle(Palette.ink2)
                }
                ForEach(lines.reversed()) { line in
                    HStack(alignment: .firstTextBaseline) {
                        Text(line.time).monospacedDigit().foregroundStyle(Palette.ink2)
                        Text(line.text)
                        Spacer()
                        Text(line.action).font(.caption).foregroundStyle(Palette.ink3)
                    }
                    .font(.callout)
                }
            }
        }
        Section("About") {
            LabeledContent("Version", value: AppLinks.versionText)
            LabeledContent("Mode", value: modeText)
        }
    }

    private var modeText: String {
        switch model.snapshot.mode {
        case .starting: "Starting"
        case .full: "Full (closed-lid mode)"
        case .notificationsOnly: "Notifications only"
        case .disabled: "Off"
        }
    }
}
