// Pure formatting for agent integrations (onboarding step 3 and the Integrations settings pane) and for the
// install/uninstall/repair diff preview sheet.

import KakurenekoKit
import Foundation

/// One agent integration row.
nonisolated struct IntegrationRowModel: Sendable, Hashable, Identifiable {
    enum Operation: String, Sendable, Hashable, CaseIterable {
        case install, uninstall, repair

        var planOperation: InstallPlan.Operation {
            switch self {
            case .install: .install
            case .uninstall: .uninstall
            case .repair: .repair
            }
        }

        var title: String {
            switch self {
            case .install: "Install…"
            case .uninstall: "Remove…"
            case .repair: "Repair…"
            }
        }
    }

    var id: AgentID
    var name: String
    var statusText: String
    var tone: Tone
    /// Codex trust walkthrough, notes from the installer.
    var guidance: [String]
    /// Offered operations; each one opens the diff preview first.
    var operations: [Operation]
    var configFiles: [String]

    /// The one-time Codex `/hooks` trust step (R03: hooks are inert until approved; never forge `trusted_hash`).
    static let codexTrustGuidance =
        "Open Codex once, type /hooks and approve the Kakureneko hooks. Until then Kakureneko only hears when a turn finishes."

    static func make(_ status: IntegrationStatus, now: Date) -> IntegrationRowModel {
        let statusText: String
        let tone: Tone
        var operations: [Operation]
        if status.needsRepair {
            statusText = "Needs repair · the agent rewrote its config"
            tone = .critical
            operations = [.repair, .uninstall]
        } else if status.installed {
            if let seen = status.lastEventSeen {
                statusText = "Working · last event \(DurationText.elapsed(since: seen, now: now)) ago"
                tone = .success
            } else {
                statusText = "Installed · waiting for the first event"
                tone = .attention
            }
            operations = [.uninstall]
        } else {
            statusText = "Not installed"
            tone = .muted
            operations = [.install]
        }
        if !status.supported { operations = [] }
        var guidance: [String] = []
        if status.needsTrustStep && status.installed { guidance.append(codexTrustGuidance) }
        guidance.append(contentsOf: status.notes)
        return IntegrationRowModel(id: status.agent, name: status.agent.displayName, statusText: statusText, tone: tone,
                                   guidance: guidance, operations: operations, configFiles: status.configFiles)
    }

    /// Integrations offered at all: supported by this build and the agent's config dir exists (phantom-install rule),
    /// ordered like `AgentID.installableInV1`. `dismissed` agents are left out (onboarding "Not now").
    static func offered(_ statuses: [IntegrationStatus], dismissed: Set<AgentID> = []) -> [IntegrationStatus] {
        let order = Dictionary(uniqueKeysWithValues: AgentID.installableInV1.enumerated().map { ($1, $0) })
        return statuses
            .filter { $0.supported && $0.configDirExists && !dismissed.contains($0.agent) }
            .sorted { (order[$0.agent] ?? Int.max, $0.agent.rawValue) < (order[$1.agent] ?? Int.max, $1.agent.rawValue) }
    }

    /// Supported agents not found on this Mac (shown greyed in settings).
    static func notDetected(_ statuses: [IntegrationStatus]) -> [IntegrationStatus] {
        statuses.filter { $0.supported && !$0.configDirExists }.sorted { $0.agent < $1.agent }
    }
}

/// One line of a unified diff, classified for coloring.
nonisolated struct DiffLine: Sendable, Hashable, Identifiable {
    enum Kind: String, Sendable, Hashable {
        case fileHeader, hunk, added, removed, context
    }

    var id: Int
    var kind: Kind
    var text: String

    static func parse(_ unifiedDiff: String) -> [DiffLine] {
        var lines = unifiedDiff.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.enumerated().map { index, line in
            DiffLine(id: index, kind: kind(of: line), text: line)
        }
    }

    static func kind(of line: String) -> Kind {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .fileHeader }
        if line.hasPrefix("@@") { return .hunk }
        if line.hasPrefix("+") { return .added }
        if line.hasPrefix("-") { return .removed }
        return .context
    }
}

/// Text for the preview sheet.
nonisolated enum InstallPlanText {
    static func title(_ plan: InstallPlan) -> String {
        let name = plan.agent.displayName
        switch plan.operation {
        case .install: return "Install the Kakureneko hook for \(name)"
        case .uninstall: return "Remove the Kakureneko hook from \(name)"
        case .repair: return "Repair the Kakureneko hook for \(name)"
        }
    }

    static func confirmTitle(_ operation: InstallPlan.Operation) -> String {
        switch operation {
        case .install: "Install"
        case .uninstall: "Remove"
        case .repair: "Repair"
        }
    }

    static func changeKind(_ kind: FileChange.Kind) -> String {
        switch kind {
        case .create: "New file"
        case .modify: "Modified"
        case .delete: "Deleted"
        }
    }

    /// Summary shown after applying.
    static func resultSummary(_ result: InstallResult) -> String {
        var parts: [String] = []
        if result.dryRun {
            parts.append("Dry run · nothing was written.")
        } else {
            switch result.plan.operation {
            case .install: parts.append("Installed for \(result.plan.agent.displayName).")
            case .uninstall: parts.append("Removed from \(result.plan.agent.displayName).")
            case .repair: parts.append("Repaired for \(result.plan.agent.displayName).")
            }
        }
        if !result.backups.isEmpty {
            parts.append(result.backups.count == 1 ? "1 backup saved." : "\(result.backups.count) backups saved.")
        }
        parts.append(contentsOf: result.messages)
        if let note = result.plan.followUpNote { parts.append(note) }
        return parts.joined(separator: " ")
    }
}
