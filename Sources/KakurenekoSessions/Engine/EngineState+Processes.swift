import KakurenekoKit
import Foundation

/// T3/T4: process snapshots — liveness of bound processes, progress evidence (stall guard, waiting exit), the
/// heuristic turn tracker for sessions without a start edge, and heuristic sessions for hook-less agents
/// (brief §5.3–5.5, ARCHITECTURE §9.3).
extension EngineState {
    mutating func ingest(processes snapshot: ProcessSnapshot, now: Date) {
        latestProcesses = snapshot
        var byIdentity: [ProcessIdentity: AgentProcess] = [:]
        for p in snapshot.agents where byIdentity[p.identity] == nil { byIdentity[p.identity] = p }

        // 1. Sessions without a process bind to the unique same-agent, same-cwd process (may merge a fallback).
        for key in sortedKeys {
            guard var t = tracked[key], t.session.agentProcess == nil, !t.state.isEnded else { continue }
            bindByCwdIfPossible(&t, now: now)
            tracked[key] = t
        }

        // 2. Liveness and evidence of bound processes.
        let drivers = heuristicDrivers
        for key in sortedKeys {
            guard var t = tracked[key], !t.state.isEnded, let identity = t.session.agentProcess else { continue }
            if let p = byIdentity[identity] {
                t.t3.seen = true
                t.t3.misses = 0
                applyEvidence(&t, process: p, drivesTurns: drivers[identity] == key, now: now)
            } else if t.t3.seen {
                t.t3.misses += 1
                if t.t3.misses >= 2 { end(&t, reason: .processGone, now: now) }
            } else if let liveness {
                // Never in a snapshot (an agent that exited within one scan of its hook, a process the scanner does
                // not classify): the point lookup decides — dead (gone or start time differs) for two snapshots in a
                // row ends it like a T3 miss; alive but unclassified keeps it.
                if liveness.isAlive(identity) {
                    t.t3.misses = 0
                } else {
                    t.t3.misses += 1
                    if t.t3.misses >= 2 { end(&t, reason: .processGone, now: now) }
                }
            }
            tracked[key] = t
        }

        // 3. Heuristic sessions for unbound processes.
        updateHeuristicCandidates(snapshot, now: now)
    }

    /// The one session per process whose turns T3 evidence may drive: among the non-ended sessions without a start
    /// edge bound to that process (same agent), the most recently active one. One process's evidence never starts
    /// several turns at once (Codex sub-threads are separate sessions on one process).
    var heuristicDrivers: [ProcessIdentity: SessionKey] {
        var best: [ProcessIdentity: TrackedSession] = [:]
        for t in tracked.values where !t.state.isEnded && t.usesHeuristicTurns {
            guard let identity = t.session.agentProcess else { continue }
            if let current = best[identity],
               current.lastActivityAt > t.lastActivityAt
                || (current.lastActivityAt == t.lastActivityAt && current.key < t.key) {
                continue
            }
            best[identity] = t
        }
        return best.mapValues(\.key)
    }

    /// Evidence for the process a session is bound to.
    /// - Parameter drivesTurns: this session is its process's heuristic driver (`heuristicDrivers`).
    private mutating func applyEvidence(_ t: inout TrackedSession, process p: AgentProcess, drivesTurns: Bool,
                                        now: Date) {
        let evidence = p.evidence
        if t.session.isHeuristicOnly {
            if let cwd = Self.cappedOrNil(p.cwd) { t.session.cwd = cwd }
            if let host = p.hostApp { t.session.host = host }
        }

        if Self.evidenceShowsProgress(evidence, process: p, usesHeuristicTurns: t.usesHeuristicTurns) {
            switch t.state {
            case .working, .settling:
                t.session.lastProgressAt = now
            case .stalled:
                enterWorking(&t, now: now, entry: .resume, cause: "progress evidence \(Self.kinds(evidence))")
            default:
                break
            }
        }

        if t.usesHeuristicTurns, drivesTurns || t.state.isWorking {
            // After a finish, the sampler's window still shows the finished turn: it cannot start the next one.
            let heldOff = t.heuristicHoldoffUntil.map { evidence.sampledAt < $0 } ?? false
            t.heuristic.record(meets: evidence.meetsHeuristicThreshold && !(heldOff && t.state.isIdle), at: now)
            switch t.state {
            case .idle:
                if t.heuristic.sustained(for: timers.heuristicSustain, at: now) {
                    t.session.tiers.insert(.heuristic)
                    enterWorking(&t, now: now, entry: .newTurn, cause: "T3 \(Self.kinds(evidence)) sustained",
                                 turnStart: t.heuristic.aboveSince)
                }
            case .working:
                heuristicExitIfQuiet(&t, now: now)
            default:
                break
            }
        } else if t.usesHeuristicTurns {
            // Not the process's driver: a sustain run started while it was must not count if it becomes one again.
            t.heuristic.reset()
        }

        // Waiting exit for agents with no resume edge — only without a T2 record (the record reports the resume).
        // Only samples taken at least one evidence window after the wait began count: E1/E2/E4 describe the
        // sampler's trailing 60 s, so earlier samples still show the work that led up to the prompt (a false exit
        // there would replace the needs-input countdown with "working" until the stall guard). An IDE host's tree
        // (every extension) qualifies only with a model-API socket, as for heuristic-session creation.
        if case .waiting(_, let since) = t.state, !t.t2.present {
            let qualifies = evidence.active.count >= 2 && !evidence.active.isDisjoint(with: EngineAgentTraits.workKinds)
                && evidence.sampledAt >= since.addingTimeInterval(Self.evidenceWindow)
                && (!p.isIDEHost || evidence.active.contains(.modelAPISocket))
            t.waitingExit.record(meets: qualifies, at: now)
            if t.waitingExit.sustained(for: timers.heuristicSustain, at: now) {
                t.session.tiers.insert(.heuristic)
                enterWorking(&t, now: now, entry: .resume, cause: "T3 \(Self.kinds(evidence)) after needs-input")
            }
        }
    }

    /// Stall-guard progress from the bound process's evidence: a kind that proves work (E1/E2/E3,
    /// `EvidenceSample.showsProgress`; E4/E5 blips of an idle TUI do not). An IDE host's tree holds every extension
    /// (language servers, indexers, other agents): for a session with a start edge its evidence never counts — the
    /// hooks report tool activity —, and for a session driven by heuristic turns (Codex `app-server` notify-only) only
    /// together with a model-API socket (E4), the rule that creates heuristic sessions for IDE hosts.
    static func evidenceShowsProgress(_ evidence: EvidenceSample, process p: AgentProcess,
                                      usesHeuristicTurns: Bool) -> Bool {
        guard evidence.showsProgress else { return false }
        guard p.isIDEHost else { return true }
        return usesHeuristicTurns && evidence.active.contains(.modelAPISocket)
    }

    /// Heuristic exit: fewer than two kinds for the exit window → `.idle(nil)` + `wentQuiet`. When a T1 finish already
    /// settled this turn (its background work kept it working), the finish stands instead (no `wentQuiet`).
    mutating func heuristicExitIfQuiet(_ t: inout TrackedSession, now: Date) {
        guard t.state.isWorking, t.usesHeuristicTurns, t.heuristic.quiet(for: timers.heuristicExit, at: now) else { return }
        if t.turn.stopSeen {
            finish(&t, outcome: t.turn.pendingOutcome ?? .completed, now: now, cause: "T3 quiet after a finish")
            return
        }
        let workedFor = t.turn.startedAt.map { start in
            max(0, (t.heuristic.belowSince ?? now).timeIntervalSince(start))
        }
        t.session.tiers.insert(.heuristic)
        becomeIdle(&t, outcome: nil, now: now, cause: "T3 quiet for \(Int(timers.heuristicExit))s")
        if let workedFor { t.session.lastTurnDuration = workedFor }
        emit(.wentQuiet, t, at: now, workedFor: workedFor)
    }

    // MARK: - Heuristic sessions

    private mutating func updateHeuristicCandidates(_ snapshot: ProcessSnapshot, now: Date) {
        let bound = boundAgents
        let dismissed = tombstonedIdentities
        var present = Set<ProcessIdentity>()
        for p in snapshot.agents {
            guard isHeuristicCandidate(p, in: snapshot, bound: bound, dismissed: dismissed),
                  p.evidence.meetsHeuristicThreshold else {
                heuristicCandidates[p.identity] = nil
                continue
            }
            present.insert(p.identity)
            let first = heuristicCandidates[p.identity] ?? now
            heuristicCandidates[p.identity] = first
            guard now.timeIntervalSince(first) >= timers.heuristicSustain else { continue }
            heuristicCandidates[p.identity] = nil
            createHeuristicSession(for: p, since: first, now: now)
        }
        heuristicCandidates = heuristicCandidates.filter { present.contains($0.key) }
    }

    /// ARCHITECTURE §9.3 "T3 heuristic sessions": non-infrastructure; an IDE host only with a model-API socket; not a
    /// parked/spare/daemon Claude process; not dismissed; not bound; not owned by a same-agent relative (the
    /// outermost same-agent process owns the tree; a bound same-agent ancestor or descendant owns it too).
    func isHeuristicCandidate(_ p: AgentProcess, in snapshot: ProcessSnapshot, bound: [ProcessIdentity: Set<AgentID>],
                              dismissed: Set<ProcessIdentity>) -> Bool {
        guard !p.isInfrastructure,
              !p.isIDEHost || p.evidence.active.contains(.modelAPISocket),
              !ignoredIdentities.contains(p.identity),
              !dismissed.contains(p.identity),
              bound[p.identity] == nil else { return false }
        if !Self.isOutermost(p, in: snapshot) { return false }
        let relatives = Set(p.ancestors.map(\.identity)).union(p.descendants)
        return !relatives.contains { bound[$0]?.contains(p.agent) == true }
    }

    private mutating func createHeuristicSession(for p: AgentProcess, since: Date, now: Date) {
        let key = SessionKey.fallback(agent: p.agent, identity: p.identity)
        var t: TrackedSession
        if let existing = tracked[key] {
            guard existing.state.isEnded else { return }
            t = existing
            revive(&t, now: now, cause: "T3 evidence")
        } else {
            t = TrackedSession(key: key, now: now)
        }
        t.session.agentProcess = p.identity
        if let host = p.hostApp { t.session.host = host }
        if let cwd = Self.cappedOrNil(p.cwd) { t.session.cwd = cwd }
        t.session.tiers.insert(.heuristic)
        t.t3.seen = true
        t.heuristic.aboveSince = since
        enterWorking(&t, now: now, entry: .newTurn, cause: "T3 heuristic \(Self.kinds(p.evidence))", turnStart: since)
        tracked[key] = t
    }

    static func kinds(_ evidence: EvidenceSample) -> String {
        evidence.active.isEmpty ? "[]" : "[" + evidence.active.sorted().map(\.rawValue).joined(separator: ",") + "]"
    }
}
