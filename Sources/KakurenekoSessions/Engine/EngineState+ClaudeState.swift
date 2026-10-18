import KakurenekoKit
import Foundation

/// One Claude session as T2 sees it in one snapshot: its record (if any), its `agents --json` entry (if any) and the
/// merged status (ARCHITECTURE §9.3 "T2 merge").
struct ClaudeT2View: Sendable, Hashable {
    var key: SessionKey
    var observation: ClaudeSessionObservation?
    var entry: ClaudeAgentsEntry?
    /// Merged effective status (`nil` = no status written yet).
    var status: ClaudeT2Status?
    /// The record's `statusUpdatedAt` (changes only when status/waitingFor are rewritten).
    var recordStatusAt: Date?
    /// Live process (record identity, or the scanner's identity for the pid of an agents-only entry).
    var identity: ProcessIdentity?
    /// Record alive (identity verified) or agents entry alive (has a pid).
    var alive: Bool
}

extension EngineState {
    // MARK: - Merge (pure)

    /// Builds one view per Claude session from a snapshot.
    ///
    /// * Records are grouped by `sessionId` (a record without one is keyed by its live process); when several
    ///   records claim the same session (crash leftover + resumed process) the live one wins, then the most
    ///   recently updated.
    /// * Interactive status comes from the record when `statusUpdatedAt ≥ agentsPolledAt`, else from the entry.
    ///   Background `state` comes only from `agents --json`.
    /// * Alive entries without a record (background sessions) become their own views; dead entries (no pid) are
    ///   history and are ignored.
    static func claudeViews(from snapshot: ClaudeStateSnapshot, processes: ProcessSnapshot?) -> [SessionKey: ClaudeT2View] {
        var best: [SessionKey: ClaudeSessionObservation] = [:]
        for observation in snapshot.sessions {
            let key: SessionKey
            if let id = cappedOrNil(observation.record.sessionId) {
                key = SessionKey(agent: .claude, id: id)
            } else if let identity = observation.identity {
                key = SessionKey.fallback(agent: .claude, identity: identity)
            } else {
                continue
            }
            if let current = best[key], !isBetterRecord(observation, than: current) { continue }
            best[key] = observation
        }

        let entries = snapshot.agents ?? []
        var entryBySession: [String: ClaudeAgentsEntry] = [:]
        var entryByPID: [Int32: ClaudeAgentsEntry] = [:]
        for entry in entries {
            if let sid = cappedOrNil(entry.sessionId) {
                // Prefer the alive entry when an id appears twice.
                if let existing = entryBySession[sid], existing.pid != nil, entry.pid == nil { continue }
                entryBySession[sid] = entry
            }
            if let pid = entry.pid { entryByPID[pid] = entry }
        }

        var views: [SessionKey: ClaudeT2View] = [:]
        var recordSessionIDs = Set<String>()
        var recordPIDs = Set<Int32>()
        for (key, observation) in best {
            let record = observation.record
            if let sid = record.sessionId { recordSessionIDs.insert(sid) }
            recordPIDs.insert(record.pid)
            let entry = record.sessionId.flatMap { entryBySession[$0] } ?? entryByPID[record.pid]
            let merged = mergedStatus(record: record, entry: entry, agentsPolledAt: snapshot.agentsPolledAt)
            views[key] = ClaudeT2View(key: key, observation: observation, entry: entry, status: merged,
                                      recordStatusAt: record.statusUpdatedAt.map(epochMilliseconds),
                                      identity: observation.identity, alive: observation.identity != nil)
        }

        for entry in entries {
            guard let pid = entry.pid, let sid = cappedOrNil(entry.sessionId),
                  !recordSessionIDs.contains(sid), !recordPIDs.contains(pid) else { continue }
            let key = SessionKey(agent: .claude, id: sid)
            guard views[key] == nil else { continue }
            let identity = processes?.agents.first { $0.identity.pid == pid && $0.agent == .claude }?.identity
            views[key] = ClaudeT2View(key: key, observation: nil, entry: entry,
                                      status: mergedStatus(record: nil, entry: entry, agentsPolledAt: snapshot.agentsPolledAt),
                                      recordStatusAt: nil, identity: identity, alive: true)
        }
        return views
    }

    /// Live beats dead, then the most recent `statusUpdatedAt`/`updatedAt`, then the newest file, then the pid.
    static func isBetterRecord(_ a: ClaudeSessionObservation, than b: ClaudeSessionObservation) -> Bool {
        if (a.identity != nil) != (b.identity != nil) { return a.identity != nil }
        let ta = max(a.record.statusUpdatedAt ?? 0, a.record.updatedAt ?? 0)
        let tb = max(b.record.statusUpdatedAt ?? 0, b.record.updatedAt ?? 0)
        if ta != tb { return ta > tb }
        let fa = a.fileModifiedAt ?? .distantPast
        let fb = b.fileModifiedAt ?? .distantPast
        if fa != fb { return fa > fb }
        return a.record.pid > b.record.pid
    }

    /// The merged effective status of one session.
    static func mergedStatus(record: ClaudeSessionRecord?, entry: ClaudeAgentsEntry?, agentsPolledAt: Date?) -> ClaudeT2Status? {
        let recordStatus = record.flatMap(status(of:))
        let recordAt = record?.statusUpdatedAt.map(epochMilliseconds)
        // The record is at least as new as the poll (or there is no polled entry to compare with).
        let recordFresh: Bool
        if recordStatus == nil {
            recordFresh = false
        } else if let polled = agentsPolledAt, entry != nil {
            recordFresh = recordAt.map { $0 >= polled } ?? false
        } else {
            recordFresh = true
        }

        if let entry, let bgState = entry.state?.lowercased(), !bgState.isEmpty {
            // Background session: its `state` is authoritative, except that a fresher record proves a start or a wait.
            if recordFresh, let recordStatus, recordStatus == .busy || recordStatus.isWaiting { return recordStatus }
            switch bgState {
            case "working": return .busy
            case "blocked": return .waiting(cappedOrNil(entry.waitingFor) ?? cappedOrNil(record?.waitingFor))
            case "done", "failed", "stopped":
                if recordFresh, let recordStatus, recordStatus.isIdleLike { return recordStatus }
                return .idle
            default: break
            }
        }
        if let recordStatus, recordFresh || entry.flatMap(status(of:)) == nil { return recordStatus }
        return entry.flatMap(status(of:)) ?? recordStatus
    }

    static func status(of record: ClaudeSessionRecord) -> ClaudeT2Status? {
        switch record.statusKind {
        case .busy: .busy
        case .waiting: .waiting(cappedOrNil(record.waitingFor))
        case .idle: .idle
        case .shell: .shell
        case nil: nil
        }
    }

    /// Interactive `status` of an entry (`busy` | `waiting` | `idle`; `shell` tolerated).
    static func status(of entry: ClaudeAgentsEntry) -> ClaudeT2Status? {
        switch entry.status?.lowercased() {
        case "busy": .busy
        case "waiting": .waiting(cappedOrNil(entry.waitingFor))
        case "idle": .idle
        case "shell": .shell
        default: nil
        }
    }

    static func epochMilliseconds(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }

    // MARK: - Ingest

    mutating func ingest(claudeState snapshot: ClaudeStateSnapshot, now: Date) {
        ignoredIdentities = Set(snapshot.ignoredIdentities)
        let views = Self.claudeViews(from: snapshot, processes: latestProcesses)
        for key in views.keys.sorted() {
            if let view = views[key] { applyClaude(view, snapshot: snapshot, now: now) }
        }
        for key in sortedKeys where views[key] == nil {
            claudeSessionAbsent(key, snapshot: snapshot, now: now)
        }
    }

    private mutating func applyClaude(_ v: ClaudeT2View, snapshot: ClaudeStateSnapshot, now: Date) {
        let key = v.key
        var created = false
        var t: TrackedSession
        if let existing = tracked[key] {
            t = existing
        } else {
            // Crash leftovers (dead records) never create sessions; a dismissed session needs new activity.
            guard v.alive else { return }
            if let tomb = tombstones[key], tomb.identity == nil || tomb.identity == v.identity,
               !(v.recordStatusAt.map { $0 > tomb.at } ?? false) {
                return
            }
            t = TrackedSession(key: key, now: now)
            created = true
        }

        // A record that vanished cannot be kept alive by a poll older than the last sighting of that record.
        if !created, v.observation == nil, t.t2.hasRecord, snapshot.sessionsDirectoryReadable,
           (snapshot.agentsPolledAt ?? .distantPast) <= (t.t2.recordLastSeenAt ?? .distantPast) {
            if !t.state.isEnded {
                t.t2.present = false
                end(&t, reason: .recordDeleted, now: now)
                tracked[key] = t
            }
            return
        }

        // Liveness first: a dead record ends the session it describes — but not a session that hooks already bound
        // to a different (resumed) process while the crash leftover is still on disk.
        if !v.alive {
            guard !t.state.isEnded else { return }
            let recordPID = v.observation?.record.pid
            guard t.session.agentProcess == nil || t.session.agentProcess?.pid == recordPID else { return }
            t.t2.present = false
            end(&t, reason: .recordDead, now: now)
            tracked[key] = t
            return
        }

        if t.state.isEnded {
            let differentProcess = v.identity != nil && t.session.agentProcess != nil && v.identity != t.session.agentProcess
            let newActivity = v.recordStatusAt.map { $0 > (t.endedAt ?? .distantPast) } ?? false
            guard (t.endReason?.isLivenessVerdict ?? true) || differentProcess || newActivity else { return }
            revive(&t, now: now, cause: "T2 record alive")
        }

        t.t2.present = true
        t.session.tiers.insert(.stateFile)
        if v.observation != nil {
            t.t2.hasRecord = true
            t.t2.recordLastSeenAt = snapshot.takenAt
        }
        if let identity = v.identity { bind(&t, to: identity, adoptState: created, now: now) }
        applyClaudeFields(&t, v)

        guard let status = v.status else {
            tracked[key] = t
            return
        }
        let previous = t.t2.status
        // A record rewrite is an edge only when the merged status reflects that record. When a stale
        // `agents --json` entry outvoted it (the CLI read the records just before the rewrite and returned after it),
        // the rewrite is applied later, once the entry agrees or the record is fresher than the poll; acting on it
        // now would apply the entry's OLD status as a new edge (a working turn finished as interrupted, or a
        // settling one continued and its finish lost).
        let recordReflected = v.observation.flatMap { Self.status(of: $0.record) }.map { status.sameKind(as: $0) } ?? false
        let rewritten = recordReflected && v.recordStatusAt != nil && t.t2.recordStatusAt != nil
            && v.recordStatusAt != t.t2.recordStatusAt
        let edge = !status.sameKind(as: previous) || rewritten
        t.t2.status = status
        if recordReflected, let at = v.recordStatusAt { t.t2.recordStatusAt = at }

        switch status {
        case .busy:
            t.hasStartEdge = true
            if edge {
                t.t2.busyStatusAt = v.recordStatusAt ?? now
                t.lastActivityAt = now
                switch t.state {
                case .working:
                    t.session.lastProgressAt = now
                case .settling:
                    enterWorking(&t, now: now, entry: .continuation, cause: "record busy")
                case .waiting, .stalled:
                    enterWorking(&t, now: now, entry: .resume, cause: "record busy")
                case .idle:
                    enterWorking(&t, now: now, entry: .newTurn, cause: "record busy")
                case .ended:
                    break
                }
            }
        case .waiting(let text):
            if edge {
                enterWaiting(&t, kind: EngineAgentTraits.needsInputKind(forWaitingFor: text), text: text, now: now,
                             cause: "record waiting")
            } else if t.state.isWaiting, let text {
                t.session.waitingFor = Self.capped(text)
            }
        case .idle, .shell:
            if edge { applyClaudeIdle(&t, v, now: now) }
            upgradeLateTurnDuration(&t, v, now: now)
        }
        tracked[key] = t
    }

    /// Record busy → idle/shell (ARCHITECTURE §9.3).
    private mutating func applyClaudeIdle(_ t: inout TrackedSession, _ v: ClaudeT2View, now: Date) {
        let cause = "record \(v.status?.label ?? "idle")"
        switch t.state {
        case .waiting:
            becomeIdle(&t, outcome: nil, now: now, cause: cause)
        case .working, .stalled:
            if t.turn.stopSeen {
                finish(&t, outcome: t.turn.pendingOutcome ?? .completed, now: now, cause: "\(cause) after Stop")
            } else if t.hooksLive {
                finish(&t, outcome: .interrupted, now: now, cause: "\(cause) without Stop")
            } else if let observation = v.observation, Self.turnDurationMatches(observation, t) {
                finish(&t, outcome: .completed, now: now, workedFor: observation.lastTurnDurationMs.map { $0 / 1000 },
                       cause: "\(cause) + turn_duration")
            } else {
                finish(&t, outcome: .interrupted, now: now, cause: "\(cause), no turn_duration yet")
                // T2-only: the transcript's turn_duration is written just after the turn; wait for it briefly.
                t.turn.awaitingTurnDuration = v.observation != nil
            }
        case .settling, .idle, .ended:
            break
        }
    }

    /// T2-only: a `turn_duration` that shows up after the record went idle turns the interrupted idle into a finish.
    private mutating func upgradeLateTurnDuration(_ t: inout TrackedSession, _ v: ClaudeT2View, now: Date) {
        guard t.turn.awaitingTurnDuration, case .idle(_, let outcome) = t.state, outcome == .interrupted,
              let observation = v.observation else { return }
        if let idleSince = t.idleSince, now.timeIntervalSince(idleSince) > Self.lateFinishWindow {
            t.turn.awaitingTurnDuration = false
            return
        }
        guard !t.hooksLive, Self.turnDurationMatches(observation, t) else { return }
        finish(&t, outcome: .completed, now: now, workedFor: observation.lastTurnDurationMs.map { $0 / 1000 },
               cause: "late turn_duration")
    }

    /// The transcript's last `system/turn_duration` belongs to the current turn and left no background work behind.
    static func turnDurationMatches(_ observation: ClaudeSessionObservation, _ t: TrackedSession) -> Bool {
        guard let completed = observation.lastTurnCompletedAt else { return false }
        guard let reference = [t.turn.startedAt, t.t2.busyStatusAt].compactMap({ $0 }).min() else { return false }
        return completed >= reference && (observation.lastTurnPendingBackground ?? 0) == 0
    }

    /// Fields other modules read (ARCHITECTURE §9.3 "Fields other modules read"). Observation values are applied
    /// only when they changed, so an unchanged transcript tail never overwrites a fresher hook value.
    private mutating func applyClaudeFields(_ t: inout TrackedSession, _ v: ClaudeT2View) {
        if let observation = v.observation {
            let record = observation.record
            if let title = Self.cappedOrNil(observation.title ?? record.humanName), title != t.observed.title {
                t.session.title = title
                t.observed.title = title
            }
            // The transcript's current cwd beats the record's LAUNCH cwd, which only fills a gap.
            if let cwd = Self.cappedOrNil(observation.currentCwd) {
                if cwd != t.observed.cwd {
                    t.session.cwd = cwd
                    t.observed.cwd = cwd
                }
            } else if t.session.cwd == nil, let cwd = Self.cappedOrNil(record.cwd) {
                t.session.cwd = cwd
            }
            if let preview = Self.cappedOrNil(observation.lastAssistantPreview), preview != t.observed.preview {
                t.session.lastMessagePreview = TextSanitizer.truncate(preview, limit: TextSanitizer.defaultLimit)
                t.observed.preview = preview
            }
            if let path = Self.cappedOrNil(observation.transcriptPath), path != t.observed.transcriptPath {
                Self.setTranscriptPath(&t, path)
                t.observed.transcriptPath = path
            }
            t.session.remoteControlConnected = record.bridgeSessionId != nil
            Self.setMetadata(&t, MetadataKey.claudeKind, record.kind)
            Self.setMetadata(&t, MetadataKey.claudeJobID, record.jobId)
            Self.setMetadata(&t, MetadataKey.claudeEntrypoint, record.entrypoint)
        } else if let entry = v.entry {
            let background = entry.kind?.lowercased() == "background"
            if t.session.cwd == nil, let cwd = Self.cappedOrNil(entry.cwd) { t.session.cwd = cwd }
            // Background names are human (agent-name/peer); interactive ones are often derived (`developer-40`).
            if background, let name = Self.cappedOrNil(entry.name), name != t.observed.title {
                t.session.title = name
                t.observed.title = name
            }
            Self.setMetadata(&t, MetadataKey.claudeKind, background ? "bg" : entry.kind)
            Self.setMetadata(&t, MetadataKey.claudeJobID, entry.id)
        }
    }

    /// A Claude session T2 has seen is missing from this snapshot: its record was deleted (only while `sessions/`
    /// is readable) or its alive `agents --json` entry vanished (only when the poll succeeded).
    private mutating func claudeSessionAbsent(_ key: SessionKey, snapshot: ClaudeStateSnapshot, now: Date) {
        guard var t = tracked[key], !t.state.isEnded, t.t2.present else { return }
        let recordDeleted = t.t2.hasRecord && snapshot.sessionsDirectoryReadable
        let entryVanished = !t.t2.hasRecord && snapshot.agents != nil
        guard recordDeleted || entryVanished else { return }
        t.t2.present = false
        end(&t, reason: .recordDeleted, now: now)
        tracked[key] = t
    }
}
