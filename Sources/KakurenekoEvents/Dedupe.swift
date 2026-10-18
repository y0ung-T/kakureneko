import KakurenekoKit
import Foundation

/// Duplicate suppression (ARCHITECTURE §9.1 "Dedupe", §11.15):
///
/// * drop an event only when the previous ACCEPTED event for the same `sessionKey` has the same
///   `dedupeIdentity` and `|Δ occurredAt| ≤ AgentEvent.dedupeWindow` — consecutive duplicates only (a second
///   `turnStarted` after a sub-2-s turn is legitimate);
/// * Codex `notify` and Codex `Stop` for the same turn id collapse into one regardless of time.
///
/// Both tables are bounded; old entries are pruned.
struct DedupeState {
    struct Accepted: Equatable {
        var identity: String
        var at: Date
        var turnID: String?
    }

    static let maxSessions = 4_096
    static let maxCodexTurns = 4_096
    /// Entries untouched for this long are pruned when a table is full.
    static let retention: TimeInterval = 15 * 60

    private(set) var lastAccepted: [SessionKey: Accepted] = [:]
    /// `<session id>|<turn id>` of Codex turns already reported finished → when.
    private(set) var codexFinishedTurns: [String: Date] = [:]

    /// True when `event` should be emitted (and records it as accepted).
    mutating func accept(_ event: AgentEvent) -> Bool {
        if let key = Self.codexTurnKey(event) {
            if codexFinishedTurns[key] != nil { return false }
        }
        if let last = lastAccepted[event.sessionKey], last.identity == event.dedupeIdentity,
           abs(event.occurredAt.timeIntervalSince(last.at)) <= AgentEvent.dedupeWindow {
            return false
        }
        if let key = Self.codexTurnKey(event) {
            codexFinishedTurns[key] = event.occurredAt
            if codexFinishedTurns.count > Self.maxCodexTurns { Self.prune(&codexFinishedTurns, now: event.occurredAt) }
        }
        lastAccepted[event.sessionKey] = Accepted(identity: event.dedupeIdentity, at: event.occurredAt, turnID: event.turnID)
        if lastAccepted.count > Self.maxSessions { pruneSessions(now: event.occurredAt) }
        return true
    }

    /// Codex finish events (`notify`, `Stop`, `Interrupt`) carry the turn id they finish.
    static func codexTurnKey(_ event: AgentEvent) -> String? {
        guard event.agent == .codex || AgentID(label: event.argvAgentLabel) == .codex,
              case .turnFinished = event.event, let turn = event.turnID
        else { return nil }
        return "\(event.sessionKey.id)|\(turn)"
    }

    private mutating func pruneSessions(now: Date) {
        lastAccepted = lastAccepted.filter { now.timeIntervalSince($0.value.at) < Self.retention }
        if lastAccepted.count > Self.maxSessions {
            // Keep the newest half (one sort instead of repeated minimum searches).
            let newest = lastAccepted.sorted { $0.value.at > $1.value.at }.prefix(Self.maxSessions / 2)
            lastAccepted = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
    }

    private static func prune(_ table: inout [String: Date], now: Date) {
        table = table.filter { now.timeIntervalSince($0.value) < retention }
        if table.count > maxCodexTurns {
            let newest = table.sorted { $0.value > $1.value }.prefix(maxCodexTurns / 2)
            table = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
    }
}
