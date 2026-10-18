// The Activity tab: every alert of the last three days, grouped by day, newest first — the same alerts the
// notifications showed, with an icon per kind, the Mac's name and the time.

import KakurenekoCloud
import SwiftUI

struct ActivityView: View {
    @Environment(PhoneStore.self) private var store

    var body: some View {
        NavigationStack {
            Group {
                if store.alerts.isEmpty {
                    // DESIGN.md §5: Soot waving by day, asleep at night.
                    EmptyStateView(pose: Self.emptyPose(at: Date()), title: "No recent alerts",
                                   message: "Alerts from your Macs in the last three days appear here.") {
                        EmptyView()
                    }
                } else {
                    let days = ActivityDay.group(store.alerts, calendar: .current)
                    List {
                        ForEach(days) { day in
                            Section {
                                ForEach(day.alerts) { alert in
                                    AlertRow(alert: alert)
                                }
                            } header: {
                                SectionTitle(Self.title(of: day.day))
                            } footer: {
                                if day.id == days.last?.id {
                                    Text("Alerts from your Macs in the last three days.")
                                        .foregroundStyle(Palette.ink3)
                                        .frame(maxWidth: .infinity)
                                        .padding(.top, 8)
                                }
                            }
                            .cardRows()
                        }
                    }
                    .paperList()
                }
            }
            .navigationTitle("Activity")
            .refreshable { await store.refresh() }
        }
    }

    /// The empty list's pose: asleep between 22:00 and 07:00, waving otherwise.
    static func emptyPose(at date: Date, calendar: Calendar = .current) -> MascotPose {
        let hour = calendar.component(.hour, from: date)
        return hour >= 22 || hour < 7 ? .sleep : .wave
    }

    /// "Today", "Yesterday", "Monday 12 October".
    static func title(of day: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

private struct AlertRow: View {
    let alert: CloudAlert
    @ScaledMetric(relativeTo: .title3) private var iconWidth = 28

    var body: some View {
        let style = AlertKindStyle(kind: alert.kind)
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: style.symbol)
                .font(.title3)
                .foregroundStyle(style.tint.color)
                .frame(width: iconWidth)
                .accessibilityLabel(style.name)
            VStack(alignment: .leading, spacing: 3) {
                Text(alert.title)
                    .font(.headline)
                if !alert.body.isEmpty {
                    Text(alert.body)
                        .font(.subheadline)
                        .foregroundStyle(Palette.ink2)
                        .lineLimit(4)
                }
                Text("\(alert.macName) · \(alert.createdAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(Palette.ink2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Activity") {
    PreviewHost(.oneMac) { ActivityView() }
}

#Preview("No alerts") {
    PreviewHost(.noMac) { ActivityView() }
}
#endif
