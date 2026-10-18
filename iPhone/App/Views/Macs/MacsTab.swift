// The Mac tab: one Mac → its detail screen directly; several → a list; none → why (no iCloud, offline, or no Mac
// has published its status yet). Follows `PhoneStore.requestedMacID` when a notification tap asks for a Mac.

import KakurenekoCloud
import SwiftUI

struct MacsTab: View {
    @Environment(PhoneStore.self) private var store
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationDestination(for: String.self) { macID in
                    MacDetailView(macID: macID)
                }
        }
        .onChange(of: store.requestedMacID, initial: true) { _, macID in
            guard let macID else { return }
            store.requestedMacID = nil
            path = store.macs.count > 1 ? [macID] : []
        }
    }

    @ViewBuilder private var content: some View {
        let macs = store.macs
        let former = store.formerMacs
        if macs.count == 1, former.isEmpty, let only = macs.first {
            MacDetailView(macID: only.macID)
        } else if macs.isEmpty, former.isEmpty {
            NoMacView()
        } else {
            MacListView()
        }
    }
}

/// Several Macs: name, phase and headline of each.
struct MacListView: View {
    @Environment(PhoneStore.self) private var store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            List {
                ConnectionBanner(now: context.date)
                if !store.macs.isEmpty {
                    Section {
                        ForEach(store.macs) { status in
                            NavigationLink(value: status.macID) {
                                MacRow(presentation: MacStatusPresentation(status: status, now: context.date))
                            }
                        }
                    }
                    .cardRows()
                }
                if !store.formerMacs.isEmpty {
                    Section {
                        ForEach(store.formerMacs) { status in
                            FormerMacRow(status: status, now: context.date)
                        }
                    } header: {
                        SectionTitle("Not seen recently")
                    } footer: {
                        Text("These Macs haven't checked in for over a week. Remove one you no longer use; a Mac that runs Kakureneko again comes back by itself.")
                    }
                    .cardRows()
                }
            }
            .paperList()
        }
        .navigationTitle("Macs")
        .refreshable { await store.refresh() }
    }
}

/// A Mac silent for over a week: its name, when it was last seen, and Remove.
struct FormerMacRow: View {
    let status: MacStatus
    let now: Date
    @Environment(PhoneStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(status.macName).font(.headline)
                Text("Last seen \(TimeText.ago(status.updatedAt, now: now).lowercased())")
                    .font(.caption)
                    .foregroundStyle(Palette.ink2)
            }
            Spacer(minLength: 0)
            Button("Remove", role: .destructive) { Task { await store.removeMac(status.macID) } }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove \(status.macName)")
        }
        .padding(.vertical, 4)
    }
}

struct MacRow: View {
    let presentation: MacStatusPresentation

    var body: some View {
        let status = presentation.status
        VStack(alignment: .leading, spacing: 6) {
            AdaptiveStack {
                Text(status.macName).font(.headline)
                Spacer(minLength: 0)
                PhasePill(style: presentation.phaseStyle)
            }
            Text(status.headline)
                .font(.subheadline)
                .foregroundStyle(Palette.ink2)
            Text(presentation.isStale
                 ? "Not responding since \(TimeText.clock(status.updatedAt, now: presentation.now))"
                 : "Updated \(TimeText.ago(status.updatedAt, now: presentation.now).lowercased())")
                .font(.caption)
                .foregroundStyle(presentation.isStale ? Tint.critical.color : Palette.ink2)
        }
        .padding(.vertical, 4)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 } // not under the pill's title
        .accessibilityElement(children: .combine)
    }
}

/// No Mac to show yet, and why: Soot, one sentence and one button.
struct NoMacView: View {
    @Environment(PhoneStore.self) private var store

    var body: some View {
        Group {
            if let account = store.account, !account.isAvailable {
                EmptyStateView(pose: .hide, title: "iCloud unavailable", message: account.phoneExplanation) {
                    checkButton("Check again")
                }
            } else if case .offline = store.connection {
                EmptyStateView(pose: .sleep, title: "You're offline",
                               message: "Your Mac shows up here as soon as this iPhone is back online.") {
                    checkButton("Try again")
                }
            } else if case .failed(let message, _) = store.connection {
                EmptyStateView(pose: .wave, title: "Can't reach iCloud", message: message) {
                    checkButton("Try again")
                }
            } else {
                EmptyStateView(pose: .hide, title: "No Mac yet",
                               message: "Open Kakureneko on your Mac and turn on iPhone alerts. Your Mac and this iPhone need to use the same Apple Account.") {
                    if store.isSyncing {
                        ProgressView()
                    } else {
                        checkButton("Check again")
                    }
                }
            }
        }
        .navigationTitle("Kakureneko")
    }

    private func checkButton(_ title: String) -> some View {
        Button(title) { Task { await store.refresh() } }
            .buttonStyle(.primaryCapsule)
            .frame(maxWidth: 280)
    }
}

#if DEBUG
#Preview("Several Macs") {
    PreviewHost(.severalMacs) { MacsTab() }
}

#Preview("No Mac yet") {
    PreviewHost(.noMac) { MacsTab() }
}

#Preview("No iCloud") {
    PreviewHost(.noICloud) { MacsTab() }
}
#endif
