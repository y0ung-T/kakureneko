// The MenuBarExtra(.window) content: status, dry-run banner, warnings, power phase + countdown with Keep awake /
// Sleep now / Cancel, sessions, paused apps + Resume all, where alerts show, Settings…, Quit.
// All strings come from the pure formatters in Formatting/; this file only lays them out.

import AppKit
import KakurenekoKit
import SwiftUI

/// The menu bar label: the cat-head template glyph of the state (macOS colours it for the menu bar), or its SF Symbol
/// outside the app bundle. The accessibility label carries the state.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let icon = MenuBarIcon.make(snapshot: model.snapshot, now: Date())
        Group {
            if let glyph = Artwork.menuBarGlyph(icon.imageName) {
                Image(nsImage: glyph)
            } else {
                Image(systemName: icon.symbolName)
            }
        }
        .accessibilityLabel(icon.accessibilityLabel)
    }
}

struct MenuContentView: View {
    let model: AppModel

    static let width: CGFloat = 340

    var body: some View {
        // Re-evaluated every second while the window is open (countdowns, "42m" durations).
        TimelineView(.periodic(from: .now, by: 1)) { context in
            MenuBody(model: model, now: context.date)
        }
        .frame(width: Self.width)
    }
}

private struct MenuBody: View {
    let model: AppModel
    let now: Date

    private var snapshot: AppSnapshot { model.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MenuHeader(model: model)
            if model.isDryRun {
                DryRunBanner(model: model)
            }
            if let banner = model.banner {
                ErrorBannerView(banner: banner) { model.dismissBanner() }
            }
            if !snapshot.resumeOffer.isEmpty {
                ResumeOfferCard(model: model)
            }
            let warnings = WarningList.forMenu(snapshot.warnings, dryRunBannerShown: model.isDryRun)
            if !warnings.isEmpty {
                WarningsList(model: model, warnings: warnings)
            }
            PowerCard(model: model, now: now)
            // Sessions are what the menu is for: when the screen is short, the paused apps give way first.
            SessionsSection(model: model, now: now)
                .layoutPriority(1)
            if !snapshot.pausedApps.isEmpty {
                PausedAppsSection(model: model, now: now)
            }
            AlertsRow(model: model)
            if let version = model.environment.updater.pendingUpdateVersion {
                UpdateRow(version: version) { model.checkForUpdates() }
            }
            Hairline()
            MenuFooter(model: model)
        }
        .padding(12)
        .foregroundStyle(Palette.ink)
        .tint(Palette.amber)
        .background(Palette.card)
    }
}

// MARK: - Header

private struct MenuHeader: View {
    let model: AppModel

    var body: some View {
        let icon = MenuBarIcon.make(snapshot: model.snapshot, now: Date())
        let off = model.snapshot.mode == .disabled
        HStack(spacing: 10) {
            Group {
                if let glyph = Artwork.menuBarGlyph(icon.imageName) {
                    Image(nsImage: glyph)
                        .renderingMode(.template)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 28, height: 28)
                } else {
                    Image(systemName: icon.symbolName).font(.title2)
                }
            }
            .foregroundStyle(off ? Palette.ink3 : Palette.ink)
            .frame(width: 30)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(KakurenekoID.appName).font(.title3.weight(.semibold))
                Text(HeaderText.subtitle(for: model.snapshot))
                    .font(.callout)
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("Kakureneko is on", isOn: Binding(
                get: { model.snapshot.settings.general.enabled },
                set: { on in Task { await model.setEnabled(on) } }))
                .toggleStyle(AmberSwitchStyle())
                .labelsHidden()
                .disabled(!model.hasReceivedSnapshot)
                .help(model.snapshot.settings.general.enabled ? "Turn Kakureneko off" : "Turn Kakureneko on")
        }
    }
}

// MARK: - Dry run

private struct DryRunBanner: View {
    let model: AppModel
    @State private var expanded = false

    var body: some View {
        let lines = DryRunLine.feed(ledger: model.snapshot.dryRunLog, local: model.localDryRunLog, limit: expanded ? 50 : 3)
        Card(tone: .attention) {
            HStack(spacing: 6) {
                Image(systemName: "testtube.2").foregroundStyle(Tone.attention.color)
                Text(DryRunLine.title(forced: model.snapshot.isDryRunForced))
                    .font(.callout.weight(.semibold))
                Spacer()
            }
            if lines.isEmpty {
                Text("Decisions appear here as \"would …\" lines.")
                    .font(.caption)
                    .foregroundStyle(Palette.ink2)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(lines) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(line.time).monospacedDigit().foregroundStyle(Palette.ink2)
                                Text(line.text).lineLimit(expanded ? 3 : 1)
                            }
                            .font(.caption)
                            .help(line.action)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: expanded ? 160 : 54)
                Button(expanded ? "Show less" : "Show all") { expanded.toggle() }
                    .buttonStyle(.accentLink)
                    .font(.caption)
            }
        }
    }
}

// MARK: - Resume offer

private struct ResumeOfferCard: View {
    let model: AppModel

    var body: some View {
        let entries = model.snapshot.resumeOffer
        Banner(symbolName: "arrow.uturn.backward.circle", tone: .working,
               title: ResumeOfferText.title(count: entries.count), message: ResumeOfferText.detail(entries)) {
            HStack {
                ProgressButton(title: "Reopen", isRunning: model.isRunning(.resume), prominent: true) {
                    Task { await model.reopenResumeOffer() }
                }
                Button("Not now") { Task { await model.dismissResumeOffer() } }
                    .buttonStyle(.secondary)
            }
            .padding(.top, 2)
        }
    }
}

// MARK: - Warnings

private struct WarningsList: View {
    let model: AppModel
    let warnings: [AppWarning]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(warnings) { warning in
                let fix = WarningList.fix(for: warning)
                if WarningList.isCompact(warning) {
                    CompactBanner(symbolName: WarningList.symbol(warning.severity), tone: WarningList.tone(warning.severity),
                                  title: warning.title, fixTitle: fix?.title) { open(fix) }
                        .help(warning.message)
                } else {
                    Banner(symbolName: WarningList.symbol(warning.severity), tone: WarningList.tone(warning.severity),
                           title: warning.title, message: warning.message) {
                        if let fix {
                            Button(fix.title) { open(fix) }
                                .buttonStyle(.accentLink)
                                .font(.caption.weight(.semibold))
                                .padding(.top, 2)
                        }
                    }
                }
            }
        }
    }

    /// Opens where the warning gets fixed ("Repair…" → Settings → Agents).
    private func open(_ fix: WarningFix?) {
        switch fix {
        case .settings(let pane): model.openSettings(pane)
        case .systemNotificationSettings: model.openNotificationSettings()
        case nil: break
        }
    }
}

/// One line for an informational notice (its explanation is the tooltip), so it never crowds out the sessions.
private struct CompactBanner: View {
    let symbolName: String
    let tone: Tone
    let title: String
    var fixTitle: String?
    var fix: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbolName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tone.color)
                .frame(width: 18)
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if let fixTitle {
                Button(fixTitle, action: fix)
                    .buttonStyle(.accentLink)
                    .font(.caption.weight(.semibold))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.fill, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }
}

// MARK: - Power

private struct PowerCard: View {
    let model: AppModel
    let now: Date

    var body: some View {
        let summary = PhaseSummary.make(snapshot: model.snapshot, now: now)
        let privileged = PrivilegedSummary.make(model.snapshot.privileged)
        Card(tone: summary.tone) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: summary.symbolName)
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(summary.tone.color)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    if summary.deadline != nil {
                        // The countdown: SF Pro Bold, tabular, in the state's colour (drowsy violet, shutdown red).
                        Text(summary.title)
                            .font(.system(size: 20, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(summary.tone.color)
                    } else {
                        Text(summary.title)
                            .font(.body.weight(.semibold))
                            .monospacedDigit()
                    }
                    Text(summary.detail)
                        .font(.caption)
                        .foregroundStyle(Palette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if let keepAwake = KeepAwakeText.make(until: model.snapshot.keepAwakeUntil, now: now) {
                HStack(spacing: 6) {
                    Image(systemName: "cup.and.heat.waves.fill").foregroundStyle(Tone.working.color)
                    Text(keepAwake).font(.caption).monospacedDigit()
                    Spacer()
                    Button("Cancel") { Task { await model.cancelKeepAwake() } }
                        .buttonStyle(.accentLink)
                        .font(.caption)
                }
            }
            HStack(spacing: 6) {
                if summary.actions.contains(.cancelWindDown) {
                    Button {
                        Task { await model.cancelWindDown() }
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle.fill")
                    }
                    .buttonStyle(.destructive)
                }
                if summary.actions.contains(.keepAwake) {
                    Menu {
                        ForEach(PhaseSummary.keepAwakeOptions, id: \.seconds) { option in
                            Button(option.title) { Task { await model.keepAwake(for: option.seconds) } }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text("Keep awake")
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.primary)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                if summary.actions.contains(.sleepNow) {
                    Button {
                        Task { await model.sleepNow() }
                    } label: {
                        Label("Sleep now", systemImage: "moon.zzz.fill")
                    }
                    .buttonStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .labelStyle(.titleOnly)
            .disabled(model.snapshot.mode == .starting)
            Hairline(color: Palette.ink.opacity(0.08))
            HStack(spacing: 6) {
                StatusDot(tone: privileged.tone)
                Text(privileged.text)
                    .font(.caption)
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(2)
                if privileged.isSimulated {
                    Badge(text: "simulated", tone: .attention)
                }
                Spacer(minLength: 0)
                if privileged.offersInstall {
                    Button("Install…") { model.openSettings(.closedLid) }
                        .buttonStyle(.accentLink)
                        .font(.caption)
                }
            }
        }
    }
}

// MARK: - Sessions

private struct SessionsSection: View {
    let model: AppModel
    let now: Date
    /// Height of all rows: the list is never taller than its rows (it has layout priority, so it would otherwise take
    /// space the paused apps need).
    @State private var rowsHeight: CGFloat = 0

    var body: some View {
        let rows = SessionRowModel.rows(for: model.snapshot, now: now)
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader("Sessions") {
                if !rows.isEmpty {
                    Text("\(rows.count)").font(.caption2.weight(.medium)).foregroundStyle(Palette.ink2)
                }
            }
            if rows.isEmpty {
                // The empty state: Soot sitting, one line, nothing to press.
                HStack(spacing: 12) {
                    MascotView(pose: .sit, height: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.snapshot.mode == .starting ? "Looking for agent sessions…" : "No agent sessions right now")
                            .font(.callout.weight(.medium))
                        Text("Start an agent and it shows up here.")
                            .font(.caption)
                            .foregroundStyle(Palette.ink2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(rows) { row in
                            SessionRow(row: row) { Task { await model.dismissSession(row.id) } }
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(minHeight: SessionRowModel.minimumListHeight(rowCount: rows.count),
                       maxHeight: SessionRowModel.listMaximumHeight(rowsHeight: rowsHeight))
            }
        }
    }
}

private struct SessionRow: View {
    let row: SessionRowModel
    let dismiss: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(tone: row.tone)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    Text(row.statusText)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(row.tone.color)
                        .lineLimit(1)
                }
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundStyle(Palette.ink2)
                    .lineLimit(1)
                if let detail = row.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(row.tone == .waiting ? Tone.waiting.color : Palette.ink2)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if row.canDismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Palette.ink3)
                .help("Dismiss this stuck session")
                .accessibilityLabel("Dismiss this stuck session")
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(hovering ? Palette.ink.opacity(0.05) : Color.clear, in: RoundedRectangle(cornerRadius: Metrics.chipRadius))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Dismiss Session", action: dismiss)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Paused apps

private struct PausedAppsSection: View {
    let model: AppModel
    let now: Date

    var body: some View {
        let rows = model.snapshot.pausedApps.map { PausedAppRowModel.make($0, now: now) }
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(PausedAppRowModel.sectionTitle(count: rows.count)) {
                Button("Resume all") { Task { await model.resumeAllApps() } }
                    .buttonStyle(.accentLink)
                    .font(.caption.weight(.medium))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows) { row in
                        PausedAppRow(model: model, row: row)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(minHeight: PausedAppRowModel.rowHeight, maxHeight: PausedAppRowModel.listMaximumHeight)
            if let note = PausedAppRowModel.footnote(for: model.snapshot.powerPhase) {
                Text(note).font(.caption2).foregroundStyle(Palette.ink3).padding(.horizontal, 6)
            } else if let summary = model.snapshot.lastPauseReport?.summary, !summary.isEmpty {
                Text(summary).font(.caption2).foregroundStyle(Palette.ink3).lineLimit(2).padding(.horizontal, 6)
            }
        }
    }
}

private struct PausedAppRow: View {
    let model: AppModel
    let row: PausedAppRowModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle").foregroundStyle(Palette.ink3)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.name).font(.callout)
                Text(row.detail).font(.caption).foregroundStyle(Palette.ink2).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .contextMenu {
            if let bundleID = row.bundleID {
                Button("Never Pause \(row.name)") {
                    Task { await model.setNeverPause(bundleID: bundleID, true) }
                }
            }
        }
    }
}

// MARK: - Alerts

private struct AlertsRow: View {
    let model: AppModel

    var body: some View {
        let summary = AlertsSummary.make(model.snapshot.notifications, settings: model.snapshot.settings.notifications)
        HStack(spacing: 8) {
            Image(systemName: model.snapshot.notifications.phoneConnected ? "iphone" : "bell.badge")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(summary.tone.color).frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(summary.text).font(.callout)
                if let detail = summary.detail {
                    Text(detail).font(.caption).foregroundStyle(Palette.ink2).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if summary.isReady {
                ProgressButton(title: "Send test", isRunning: model.isRunning(.sendTest)) {
                    Task { await model.sendTestNotification() }
                }
            } else {
                Button("Set up…") { model.openSettings(.notifications) }
                    .buttonStyle(.accentLink)
                    .font(.caption)
            }
        }
    }
}

// MARK: - Update

/// A newer Kakureneko found by the daily check (Sparkle's gentle reminder): one row, the window opens on "Install…".
private struct UpdateRow: View {
    let version: String
    let install: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(Palette.onAmber, Palette.amber)
            Text("Kakureneko \(version) is available")
            Spacer()
            Button("Install…", action: install)
                .buttonStyle(.accentLink)
        }
        .font(.callout)
    }
}

// MARK: - Footer

private struct MenuFooter: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Button("Settings…") { model.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
            if model.hasReceivedSnapshot && !model.snapshot.settings.general.onboardingCompleted {
                Button("Finish setup…") { model.openOnboarding() }
            }
            Spacer()
            Button("Quit \(KakurenekoID.appName)") { model.quit() }
                .keyboardShortcut("q", modifiers: .command)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Palette.ink)
        .font(.body)
    }
}
