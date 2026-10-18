// One Mac: phase, headline, live countdown, "not responding" state, battery / lid / keep-awake / last update, its
// agent sessions, and the Keep awake / Sleep now / Shut down buttons with their feedback. Redraws every few
// seconds (TimelineView) so staleness and "updated … ago" stay true without new data.

import KakurenekoCloud
import SwiftUI

struct MacDetailView: View {
    let macID: String
    @Environment(PhoneStore.self) private var store

    var body: some View {
        Group {
            if let status = store.status(for: macID) {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    MacDetailList(presentation: MacStatusPresentation(status: status, now: context.date))
                }
                .navigationTitle(status.macName)
            } else {
                EmptyStateView(pose: .hide, title: "Mac not found",
                               message: "This Mac no longer shares its status. It may have been reset or signed out of iCloud.") {
                    EmptyView()
                }
            }
        }
        .refreshable { await store.refresh() }
    }
}

private struct MacDetailList: View {
    let presentation: MacStatusPresentation

    var body: some View {
        List {
            ConnectionBanner(now: presentation.now)
            Section { StatusHeader(presentation: presentation) }
                .cardRows()
            // During a countdown the buttons come first (DESIGN canvas "iPhone · Sleep countdown").
            if presentation.controlsFirst {
                MacControlsSection(presentation: presentation)
                AgentsSection(presentation: presentation)
                DetailsSection(presentation: presentation)
            } else {
                DetailsSection(presentation: presentation)
                AgentsSection(presentation: presentation)
                MacControlsSection(presentation: presentation)
            }
        }
        .paperList()
    }
}

/// Phase pill, headline, detail, the countdown and the pose of the moment.
private struct StatusHeader: View {
    let presentation: MacStatusPresentation
    @ScaledMetric(relativeTo: .largeTitle) private var countdownSize = 48

    var body: some View {
        let status = presentation.status
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                PhasePill(style: presentation.phaseStyle)
                if presentation.isStale {
                    Text("Not responding since \(TimeText.clock(status.updatedAt, now: presentation.now))")
                        .font(.headline)
                        .foregroundStyle(Tint.critical.color)
                    Text("\(status.macName) hasn't sent an update for a while. It may be offline or out of power, or Kakureneko may have quit.")
                        .font(.subheadline)
                        .foregroundStyle(Palette.ink2)
                }
                Text(status.headline)
                    .font(.title3.weight(.semibold))
                if let detail = status.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(Palette.ink2)
                }
                if let end = presentation.countdownEnd {
                    // The countdown: SF Pro Bold, tabular, drowsy violet (red for a shutdown); "Sleeps in" in ink-2.
                    let tint = presentation.phaseStyle.tint
                    AdaptiveStack(spacing: 10) {
                        Text(timerInterval: presentation.now...end, countsDown: true)
                            .font(.system(size: countdownSize, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(tint.color)
                        Text(presentation.countdownLabel)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Palette.ink2)
                    }
                    .padding(.top, 2)
                    .accessibilityElement(children: .combine)
                }
                if let model = status.model {
                    Text(model)
                        .font(.footnote)
                        .foregroundStyle(Palette.ink3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let pose = presentation.poseName.flatMap(MascotPose.init(rawValue:)) {
                MascotView(pose: pose, height: 92)
            }
        }
        .padding(.vertical, 6)
    }
}

/// Battery, lid, keep-awake end and last update.
private struct DetailsSection: View {
    let presentation: MacStatusPresentation

    var body: some View {
        let status = presentation.status
        let battery = presentation.battery
        Section {
            LabeledContent {
                Text(battery.text)
            } label: {
                DetailLabel("Battery", symbol: battery.symbol)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(battery.accessibilityLabel)

            LabeledContent {
                Text(presentation.lidText)
            } label: {
                DetailLabel("Lid", symbol: "laptopcomputer")
            }

            if let until = presentation.keepAwakeUntil {
                LabeledContent {
                    Text(until, style: .time)
                } label: {
                    DetailLabel("Kept awake until", symbol: "cup.and.heat.waves")
                }
            }

            LabeledContent {
                Text(TimeText.ago(status.updatedAt, now: presentation.now))
                    .foregroundStyle(presentation.isStale ? Tint.critical.color : Palette.ink2)
            } label: {
                DetailLabel("Updated", symbol: "clock")
            }
        } header: {
            SectionTitle("Details")
        }
        .cardRows()
    }
}

/// A details row's title with its symbol in secondary ink.
private struct DetailLabel: View {
    let title: String
    let symbol: String

    init(_ title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Palette.ink2)
        }
    }
}

/// The agent sessions the Mac reported.
private struct AgentsSection: View {
    let presentation: MacStatusPresentation

    var body: some View {
        let agents = presentation.status.agents
        Section {
            if agents.isEmpty {
                Text("No agent sessions")
                    .foregroundStyle(Palette.ink2)
            } else {
                ForEach(Array(agents.enumerated()), id: \.offset) { _, agent in
                    AgentRow(agent: agent, now: presentation.now)
                }
            }
        } header: {
            SectionTitle("Agents")
        }
        .cardRows()
    }
}

private struct AgentRow: View {
    let agent: AgentSummary
    let now: Date
    @ScaledMetric(relativeTo: .body) private var dotSize = 10

    var body: some View {
        let style = AgentActivityStyle(agent.activity)
        let place = [agent.project, agent.host].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            // DESIGN.md §7, session row: a dot in the state's fill, the status in its text colour.
            Circle()
                .fill(style.tint.solid)
                .frame(width: dotSize, height: dotSize)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.agent)
                    .font(.headline)
                if !place.isEmpty {
                    Text(place)
                        .font(.subheadline)
                        .foregroundStyle(Palette.ink2)
                }
                if let note = agent.note, !note.isEmpty {
                    Text(note)
                        .font(.subheadline)
                        .foregroundStyle(Tint.waiting.color)
                }
                Text(agent.since.map { "\(style.title) \(agent.activity == .finished ? "at" : "since") \(TimeText.clock($0, now: now))" }
                     ?? style.title)
                    .font(.caption)
                    .foregroundStyle(style.tint.color)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// A control button's title and icon in one color: its tint while it works, grey while it doesn't.
private struct ControlLabel: View {
    let title: String
    let symbol: String
    let tint: Color
    let enabled: Bool

    var body: some View {
        Label(title, systemImage: symbol)
            .foregroundStyle(enabled ? tint : Palette.ink3)
    }
}

/// Keep awake (no confirmation), Sleep now and Shut down (confirmed), and what became of the last tap.
struct MacControlsSection: View {
    let presentation: MacStatusPresentation
    @Environment(PhoneStore.self) private var store
    @State private var confirming: Confirmation?

    enum Confirmation: Hashable {
        case sleep, shutDown
    }

    var body: some View {
        let status = presentation.status
        let feedback = store.visibleFeedback(for: status.macID, channel: .controls, at: presentation.now)
        let busy = feedback?.phase == .sending
        let canKeepAwake = presentation.canKeepAwake && !busy
        let canSleep = presentation.canSleep && !busy
        let critical = Tint.critical.color
        Section {
            if presentation.controlsFirst {
                // The countdown: one amber Keep awake button, Sleep now in red under it.
                VStack(spacing: 6) {
                    Button {
                        Task { await store.keepAwake(macID: status.macID) }
                    } label: {
                        Label(presentation.keepAwakeTitle, systemImage: "cup.and.heat.waves")
                    }
                    .buttonStyle(.primaryCapsule)
                    .disabled(!canKeepAwake)

                    Button(role: .destructive) {
                        confirming = .sleep
                    } label: {
                        ControlLabel(title: CloudAction.sleepNow.title, symbol: "moon.zzz", tint: critical, enabled: canSleep)
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSleep)
                }
                .padding(.vertical, 6)
                // The separator spans the row, not just from the Sleep now label's text.
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            } else {
                Button {
                    Task { await store.keepAwake(macID: status.macID) }
                } label: {
                    ControlLabel(title: presentation.keepAwakeTitle, symbol: "cup.and.heat.waves", tint: Palette.amberInk,
                                 enabled: canKeepAwake)
                }
                .disabled(!canKeepAwake)

                Button(role: .destructive) {
                    confirming = .sleep
                } label: {
                    ControlLabel(title: CloudAction.sleepNow.title, symbol: "moon.zzz", tint: critical, enabled: canSleep)
                }
                .disabled(!canSleep)
            }

            if presentation.showsShutDown {
                let canShutDown = presentation.canShutDown && !busy
                Button(role: .destructive) {
                    confirming = .shutDown
                } label: {
                    ControlLabel(title: CloudAction.shutDown.title, symbol: "power", tint: critical, enabled: canShutDown)
                }
                .disabled(!canShutDown)
            }
        } header: {
            SectionTitle("Control")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let feedback {
                    FeedbackLine(feedback: feedback, macName: status.macName)
                }
                if let reason = unavailableReason {
                    Text(reason)
                }
            }
            .foregroundStyle(Palette.ink2)
        }
        .cardRows()
        .sensoryFeedback(trigger: feedback?.phase) { _, phase in
            switch phase {
            case .done?, .received?: .success
            case .noResponse?, .failed?, .ignored?: .warning
            default: nil
            }
        }
        .confirmationDialog(confirmationTitle, isPresented: isConfirming, titleVisibility: .visible, presenting: confirming) { action in
            Button(action == .sleep ? CloudAction.sleepNow.title : CloudAction.shutDown.title, role: .destructive) {
                Task {
                    switch action {
                    case .sleep: await store.sleepNow(macID: status.macID)
                    case .shutDown: await store.shutDown(macID: status.macID)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action == .sleep
                 ? "Agents still working on \(status.macName) will pause until it wakes."
                 : "Agents still working on \(status.macName) will stop, and it stays off until someone turns it on.")
        }
    }

    private var isConfirming: Binding<Bool> {
        Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
    }

    private var confirmationTitle: String {
        let name = presentation.status.macName
        return confirming == .shutDown ? "Shut down \(name)?" : "Put \(name) to sleep?"
    }

    /// Why Sleep now / Shut down are greyed out.
    private var unavailableReason: String? {
        let name = presentation.status.macName
        switch presentation.status.phase {
        case .asleep: return "\(name) is asleep. The buttons work again when it wakes."
        case .shutDown: return "\(name) is shut down."
        case .off: return "Kakureneko is switched off on \(name)."
        default: break
        }
        if presentation.isStale { return "Sleep and shut down are off while \(name) isn't responding." }
        if !presentation.canSleep { return "\(name) isn't accepting Sleep now at the moment." }
        return nil
    }
}

#if DEBUG
#Preview("Working, lid closed") {
    PreviewHost(.oneMac) { NavigationStack { MacDetailView(macID: DemoFixtures.studioID) } }
}

#Preview("Countdown") {
    PreviewHost(.countdown) { NavigationStack { MacDetailView(macID: DemoFixtures.studioID) } }
}

#Preview("Not responding") {
    PreviewHost(.stale) { NavigationStack { MacDetailView(macID: DemoFixtures.studioID) } }
}
#endif
