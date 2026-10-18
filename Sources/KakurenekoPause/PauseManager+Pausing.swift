import Darwin
import KakurenekoKit
import Foundation
import Synchronization

extension PauseManager {
    /// Freeze ordering (brief §6.4): at most this many re-enumeration rounds to stop newly spawned members.
    static let newcomerRounds = 5

    /// One pause/recheck pass: its inputs and the dry-run gate value used for EVERY action of the pass (the journal
    /// records it per app as `simulated`).
    struct Run: Sendable {
        let topology: AgentTopology
        let settings: PauseSettings
        let now: Date
        let generation: UInt64
        let dry: Bool
        let table: ProcessTable
        let grouping: any ProcessGrouping
        let selfTest: GroupingSelfTest
        let bootUUID: String
        let uid: uid_t
        let began: Date
        let selfPIDs: Set<pid_t>
        /// Apps registered for `https` (category default, Freeze only; empty otherwise).
        var browserBundleIDs: Set<String> = []

        var context: ProtectionContext { ProtectionContext(topology: topology, settings: settings, selfPIDs: selfPIDs) }
        /// Freeze needs a grouping that sees XPC helpers AND a complete topology (else: Throttle only).
        var freezePermitted: Bool { selfTest.freezeAllowed && topology.isComplete }
    }

    enum GroupOutcome {
        case paused(PausedApp, main: ProcessIdentity)
        case protected([ProtectionReason])
        case failed(String)
        case nothing(String)
        case aborted
    }

    // MARK: - pause

    @concurrent
    public func pause(topology: AgentTopology, settings: PauseSettings, now: Date) async -> PauseReport {
        let generation = signalGate.withLock { $0.generation }
        return await operations.withLock {
            await self.pauseLocked(topology: topology, settings: settings, now: now, generation: generation)
        }
    }

    func pauseLocked(topology: AgentTopology, settings: PauseSettings, now: Date, generation: UInt64) async -> PauseReport {
        var report = PauseReport(at: now)
        let reconciled = journal.reconcileWithDisk()
        if reconciled > 0 { logger.warning("\(reconciled) journaled process(es) were thawed by kakureneko-guard; treated as thawed") }
        syncMetadataWithJournal()
        let (prepared, skipped) = prepareRun(topology: topology, settings: settings, now: now, generation: generation, startSession: true)
        guard let run = prepared else {
            report.skippedReason = skipped
            report.paused = currentPausedApps()
            logger.info("pause skipped: \(skipped ?? "unknown reason")")
            return report
        }
        if !run.dry {
            do { try ensureGuardRunning() } catch { logger.error("could not start kakureneko-guard: \(error)") }
        }

        // Candidates: regular, finished launching, own uid, launched before the pause began, not Kakureneko.
        let alreadyPaused = Set(journal.current?.apps.map(\.appPid) ?? [])
        let sessionProtected = state.withLock { $0.session.protected }
        var eligible: [(app: AppCandidate, main: ProcessEntry)] = []
        for app in candidates.runningApplications().filter(\.isRegular).sorted(by: { $0.pid < $1.pid }) {
            guard !alreadyPaused.contains(app.pid), let main = run.table[app.pid], !main.isZombie else { continue }
            var reasons: [ProtectionReason] = []
            if app.pid == selfPID || app.bundleID == KakurenekoID.bundleIdentifier {
                reasons = [.kakurenekoItself]
            } else if !app.isFinishedLaunching || !main.isOwned(by: run.uid) {
                reasons = [.notCandidate]
            } else if main.identity.startDate > run.began {
                reasons = [.launchedAfterPause]
            } else if let known = sessionProtected[main.identity] {
                reasons = known.reasons
            }
            if reasons.isEmpty {
                eligible.append((app, main))
            } else {
                report.protected.append(ProtectedApp(appPID: app.pid, bundleID: app.bundleID, name: app.displayName, reasons: reasons))
            }
        }

        let groups = run.grouping.groups(for: eligible.map(\.main.pid), in: run.table, uid: run.uid)
        let conflicts = GroupOverlap.conflictingMains(groups)
        let allMembers = Set(groups.values.joined())
        let audio = allMembers.isEmpty ? [] : probe.audioActivePIDs(among: allMembers)

        groupLoop: for (app, main) in eligible {
            guard isCurrent(run.generation) else {
                report.skippedReason = "interrupted by a thaw"
                break
            }
            let outcome: GroupOutcome = conflicts.contains(app.pid)
                ? .protected([.uncertain])
                : await pauseGroup(app: app, main: main, memberPIDs: groups[app.pid] ?? [], audio: audio, run: run)
            switch outcome {
            case .paused(let paused, let mainIdentity):
                state.withLock { s in
                    s.metadata[app.pid] = paused
                    s.mains[app.pid] = mainIdentity
                }
                logger.notice("\(paused.mode == .freeze ? "froze" : paused.mode == .quit ? "quit" : "throttled") \(app.displayName) (pid \(app.pid))\(paused.downgradedBecause.map { " — downgraded: \($0.rawValue)" } ?? "")")
            case .protected(let reasons):
                report.protected.append(ProtectedApp(appPID: app.pid, bundleID: app.bundleID, name: app.displayName, reasons: reasons))
                logger.info("protected \(app.displayName) (pid \(app.pid)): \(reasons.map(\.rawValue).joined(separator: ", "))")
            case .failed(let message):
                report.failures.append(PauseFailure(appPID: app.pid, name: app.displayName, message: message))
                logger.error("pause of \(app.displayName) (pid \(app.pid)) failed: \(message)")
            case .nothing(let why):
                logger.debug("\(app.displayName) (pid \(app.pid)) not paused: \(why)")
            case .aborted:
                report.skippedReason = "interrupted by a thaw"
                break groupLoop
            }
        }
        state.withLock { s in
            if s.session.lastRescan == nil { s.session.lastRescan = now }
        }
        report.paused = currentPausedApps()
        logger.notice("pause: \(report.summary) (\(report.paused.count) paused, \(report.protected.count) protected, \(report.failures.count) failed)")
        return report
    }

    /// Common preconditions of `pause`/`recheck`; nil + a reason when nothing may be done.
    func prepareRun(topology: AgentTopology, settings: PauseSettings, now: Date, generation: UInt64,
                    startSession: Bool) -> (Run?, String?) {
        guard settings.enabled else { return (nil, "pausing disabled") }
        guard isCurrent(generation) else { return (nil, "interrupted by a thaw") }
        if startSession, let latch = state.withLock({ $0.session.latch }) { return (nil, latch) }
        let selection = currentSelection()
        guard let grouping = selection.grouping else { return (nil, "grouping self-test failed") }
        guard let table = probe.processTable() else { return (nil, "process table unavailable") }
        guard let boot = probe.bootSessionUUID() else { return (nil, "boot session unavailable") }
        let began = state.withLock { s -> Date in
            if startSession, s.session.began == nil { s.session.began = now }
            return s.session.began ?? now
        }
        var selfPIDs: Set<pid_t> = [selfPID]
        if let guardPID = guardProcess?.pid { selfPIDs.insert(guardPID) }
        var run = Run(topology: topology, settings: settings, now: now, generation: generation, dry: dryRun.isOn,
                      table: table, grouping: grouping, selfTest: selection.selfTest, bootUUID: boot,
                      uid: probe.userID, began: began, selfPIDs: selfPIDs)
        if settings.mode == .freeze, startSession { run.browserBundleIDs = candidates.webBrowserBundleIdentifiers() }
        return (run, nil)
    }

    /// Facts → protections → enrichment → mode → action for one candidate group.
    func pauseGroup(app: AppCandidate, main: ProcessEntry, memberPIDs: [pid_t], audio: Set<pid_t>, run: Run) async -> GroupOutcome {
        let facts = gatherFacts(app: app, main: main, memberPIDs: memberPIDs, audio: audio, table: run.table)
        let reasons = ProtectionRules.protections(for: facts, in: run.context)
        guard reasons.isEmpty else { return .protected(reasons) }

        // Enrichment first: nothing is journaled or signalled without pidVersion + uniqueID.
        guard let mainIdentity = probe.enrich(main.identity) else { return .protected([.uncertain]) }
        var members = [mainIdentity]
        for entry in facts.members where entry.pid != main.pid {
            if let enriched = probe.enrich(entry.identity) {
                members.append(enriched)
            } else {
                logger.debug("member pid \(entry.pid) of \(app.displayName) could not be enriched; left alone")
            }
        }

        // Quit loses the app's service until it is relaunched: never on an incomplete topology (be conservative).
        let quitEligible = run.settings.quitWhenMemoryLow
            && run.topology.isComplete
            && probe.memoryPressure() >= .warning
            && Kernel.isCleanForQuit(dirtyFlags: probe.dirtyFlags(of: main.pid))
            && app.bundlePath != nil
        var downgrades: [ProtectionReason] = []
        if run.settings.mode == .freeze || quitEligible {
            let busy = cpuHistory.withLock { $0.busyFraction(for: main.identity, now: run.now) }
            let downloading = memberPIDs.contains { probe.hasDownloadInProgress($0) }
            downgrades = ProtectionRules.downgrades(downloadInProgress: downloading, busyFraction: busy)
            if let category = ProtectionRules.categoryDowngrade(bundleID: app.bundleID, browserBundleIDs: run.browserBundleIDs) {
                downgrades.append(category)
            }
        }
        let choice = ProtectionRules.mode(requested: run.settings.mode, freezePermitted: run.freezePermitted,
                                          downgrades: downgrades, quitEligible: quitEligible)
        let journalApp = JournalAppInfo(appPid: app.pid, bundleID: app.bundleID, name: app.displayName)
        let outcome: GroupOutcome
        switch choice.mode {
        case .throttle:
            outcome = throttle(journalApp, main: mainIdentity, members: members, run: run)
        case .freeze:
            outcome = freeze(journalApp, main: mainIdentity, members: members, run: run)
        case .quit:
            outcome = await quit(journalApp, main: mainIdentity, bundlePath: app.bundlePath, run: run)
        }
        guard case .paused(var paused, let identity) = outcome else { return outcome }
        paused.downgradedBecause = choice.downgradedBecause
        return .paused(paused, main: identity)
    }

    func gatherFacts(app: AppCandidate, main: ProcessEntry, memberPIDs: [pid_t], audio: Set<pid_t>, table: ProcessTable) -> GroupFacts {
        GroupFacts(
            app: app,
            main: main,
            members: memberPIDs.compactMap { table[$0] },
            mainAncestors: table.ancestors(of: main.pid),
            audioActive: !audio.isDisjoint(with: memberPIDs),
            traced: memberPIDs.contains { probe.isTraced($0) } || probe.isTraced(main.pid)
        )
    }

    // MARK: - Modes

    /// What the journal records about an app.
    struct JournalAppInfo: Sendable {
        var appPid: Int32
        var bundleID: String?
        var name: String
    }

    /// Throttle: skip members already in darwinbg (so restoring to 0 is always correct), journal, `PRIO_DARWIN_BG`,
    /// verify (not in dry-run). The main failing → undo the whole group.
    func throttle(_ app: JournalAppInfo, main: ProcessIdentity, members: [ProcessIdentity], run: Run) -> GroupOutcome {
        let targets = members.filter { signaller.isDarwinBackground($0) != true }
        guard !targets.isEmpty else { return .nothing("already in the background") }
        guard isCurrent(run.generation) else { return .aborted }
        do {
            try journalAppend(app, mode: .throttle, records: records(for: targets, action: .darwinBackground), run: run)
        } catch {
            return .failed("journal write failed: \(error)")
        }
        let applied: [ProcessIdentity]
        switch applyThrottle(app, main: main, targets: targets, run: run) {
        case .success(let list): applied = list
        case .failure(let outcome): return outcome
        }
        guard !applied.isEmpty else {
            dropJournalApp(app.appPid)
            return .nothing("no member could be throttled")
        }
        return .paused(PausedApp(appPID: app.appPid, bundleID: app.bundleID, name: app.name, mode: .throttle,
                                 memberCount: applied.count, pausedAt: run.now), main: main)
    }

    enum ApplyResult {
        case success([ProcessIdentity])
        case failure(GroupOutcome)
    }

    /// Throttles already-journaled `targets`; drops members that failed or did not verify. Shared with the helper
    /// re-scan in `recheck`.
    func applyThrottle(_ app: JournalAppInfo, main: ProcessIdentity, targets: [ProcessIdentity], run: Run) -> ApplyResult {
        var applied: [ProcessIdentity] = []
        var dropped: [ProcessIdentity] = []
        for target in targets {
            switch perform(run.generation, { try signaller.setDarwinBackground(true, for: target) }) {
            case .done:
                applied.append(target)
            case .aborted:
                return .failure(.aborted) // the pending thaw undoes everything journaled
            case .failed(let error):
                if target == main {
                    undoThrottle(applied)
                    dropJournalApp(app.appPid)
                    return .failure(.failed("could not throttle \(app.name): \(error)"))
                }
                dropped.append(target)
            }
        }
        if !run.dry {
            // The dry-run passthrough would read REAL state, so verification is skipped there.
            let unverified = applied.filter { signaller.isDarwinBackground($0) != true }
            if unverified.contains(main) {
                undoThrottle(applied)
                dropJournalApp(app.appPid)
                return .failure(.failed("throttling \(app.name) did not take effect"))
            }
            if !unverified.isEmpty {
                undoThrottle(unverified)
                dropped.append(contentsOf: unverified)
                applied.removeAll { unverified.contains($0) }
            }
        }
        if !dropped.isEmpty { dropJournalRecords(app.appPid, identities: dropped) }
        return .success(applied)
    }

    func undoThrottle(_ identities: [ProcessIdentity]) {
        for identity in identities.reversed() { try? signaller.setDarwinBackground(false, for: identity) }
    }

    /// Freeze (brief §6.4): journal → main → members → ≤ 5 newcomer rounds → verify `SSTOP` (not in dry-run);
    /// any partial failure thaws the whole group. Members someone else already stopped (App Tamer, `kill -STOP`)
    /// are neither journaled nor signalled — a thaw must only resume what Kakureneko stopped (brief §6.5.4), the
    /// Freeze counterpart of Throttle's "already darwinbg" rule.
    func freeze(_ app: JournalAppInfo, main: ProcessIdentity, members allMembers: [ProcessIdentity], run: Run) -> GroupOutcome {
        var journaled: Set<pid_t> = []
        var unenriched: Set<pid_t> = []
        var stopped: [ProcessIdentity] = []
        if probe.isStopped(main.pid) { return .nothing("already stopped by someone else") }
        let foreignStops = Set(allMembers.filter { probe.isStopped($0.pid) }.map(\.pid))
        let members = allMembers.filter { !foreignStops.contains($0.pid) }
        unenriched.formUnion(foreignStops) // never reconsidered as newcomers

        func journalMembers(_ identities: [ProcessIdentity]) throws {
            try journalAppend(app, mode: .freeze, records: records(for: identities, action: .sigstop), run: run)
            journaled.formUnion(identities.map(\.pid))
        }
        func stop(_ identities: [ProcessIdentity]) -> GroupOutcome? {
            for target in identities {
                switch perform(run.generation, { try signaller.send(.stop, to: target) }) {
                case .done:
                    stopped.append(target)
                case .aborted:
                    return .aborted
                case .failed(let error):
                    let vanished = (error as? SideEffectError).map { $0 == .processGone || $0 == .identityMismatch } ?? false
                    guard vanished, target != main else {
                        thawJournaledApp(app.appPid, dry: run.dry)
                        return .failed("could not freeze \(app.name): \(error)")
                    }
                    dropJournalRecords(app.appPid, identities: [target])
                }
            }
            return nil
        }

        guard isCurrent(run.generation) else { return .aborted }
        do { try journalMembers(members) } catch { return .failed("journal write failed: \(error)") }
        if let early = stop(members) { return early }

        for _ in 0..<Self.newcomerRounds {
            guard let table = probe.processTable() else { break }
            let fresh = run.grouping.groups(for: [app.appPid], in: table, uid: run.uid)[app.appPid] ?? []
            let newcomers = fresh.filter { !journaled.contains($0) && !unenriched.contains($0) }.compactMap { table[$0] }
            if newcomers.isEmpty { break }
            if newcomers.contains(where: \.hasControllingTTY) {
                thawJournaledApp(app.appPid, dry: run.dry)
                return .protected([.notCandidate])
            }
            var enriched: [ProcessIdentity] = []
            for entry in newcomers {
                if entry.isStopped {
                    unenriched.insert(entry.pid) // stopped by someone else: never ours to resume
                } else if let identity = probe.enrich(entry.identity) {
                    enriched.append(identity)
                } else {
                    unenriched.insert(entry.pid)
                }
            }
            guard !enriched.isEmpty else { continue }
            guard isCurrent(run.generation) else { return .aborted }
            do {
                try journalMembers(enriched)
            } catch {
                thawJournaledApp(app.appPid, dry: run.dry)
                return .failed("journal write failed: \(error)")
            }
            if let early = stop(enriched) { return early }
        }

        if !run.dry {
            let notStopped = stopped.filter { !probe.isStopped($0.pid) && processes.isAlive($0) }
            if !notStopped.isEmpty {
                thawJournaledApp(app.appPid, dry: run.dry)
                return .failed("\(notStopped.count) process(es) of \(app.name) did not stop")
            }
        }
        guard !stopped.isEmpty else {
            dropJournalApp(app.appPid)
            return .nothing("no member could be frozen")
        }
        return .paused(PausedApp(appPID: app.appPid, bundleID: app.bundleID, name: app.name, mode: .freeze,
                                 memberCount: stopped.count, pausedAt: run.now), main: main)
    }

    /// Quit (opt-in, memory pressure, clean app): journal a `.terminate` record with the BUNDLE path, then ask the app
    /// to quit. Relaunched (not activated) by a later lid-open/user thaw.
    func quit(_ app: JournalAppInfo, main: ProcessIdentity, bundlePath: String?, run: Run) async -> GroupOutcome {
        guard let bundlePath, let record = PauseJournalRecord(identity: main, path: bundlePath, action: .terminate) else {
            return .nothing("no bundle path")
        }
        guard isCurrent(run.generation) else { return .aborted }
        do {
            try journalAppend(app, mode: .quit, records: [record], run: run)
        } catch {
            return .failed("journal write failed: \(error)")
        }
        guard isCurrent(run.generation) else { return .aborted }
        do {
            try await signaller.terminateApplication(main)
        } catch {
            dropJournalApp(app.appPid)
            return .failed("could not quit \(app.name): \(error)")
        }
        return .paused(PausedApp(appPID: app.appPid, bundleID: app.bundleID, name: app.name, mode: .quit,
                                 memberCount: 1, pausedAt: run.now), main: main)
    }

    // MARK: - recheck

    @concurrent
    public func recheck(topology: AgentTopology, settings: PauseSettings, now: Date) async -> PauseReport {
        let generation = signalGate.withLock { $0.generation }
        return await operations.withLock {
            self.recheckLocked(topology: topology, settings: settings, now: now, generation: generation)
        }
    }

    func recheckLocked(topology: AgentTopology, settings: PauseSettings, now: Date, generation: UInt64) -> PauseReport {
        var report = PauseReport(at: now)
        // The guard may have thawed records during a hang: missing records count as already thawed.
        let reconciled = journal.reconcileWithDisk()
        if reconciled > 0 { logger.warning("\(reconciled) journaled process(es) were thawed by kakureneko-guard; treated as thawed") }
        syncMetadataWithJournal()
        let before = currentPausedApps()
        guard !before.isEmpty else { return report }

        let began = state.withLock { $0.session.began }
        if let began, now.timeIntervalSince(began) >= TimeInterval(settings.maxPausedHours) * 3600 {
            _ = thawJournal(allowRelaunch: false)
            finishThaw(reason: .hardCap)
            report.thawed = before
            report.skippedReason = "hard cap of \(settings.maxPausedHours) h reached"
            report.paused = currentPausedApps()
            logger.notice("recheck: hard cap reached; thawed everything")
            return report
        }
        guard settings.enabled else {
            _ = thawJournal(allowRelaunch: false)
            finishThaw(reason: .pausingDisabled)
            report.thawed = before
            report.skippedReason = "pausing disabled"
            report.paused = currentPausedApps()
            return report
        }
        let (prepared, skipped) = prepareRun(topology: topology, settings: settings, now: now, generation: generation, startSession: false)
        guard let run = prepared else {
            report.skippedReason = skipped
            // Blind (no process table, boot session or grouping): no protection can be evaluated, and Freeze is
            // never kept on facts that cannot be checked — thaw the frozen apps (throttled ones stay).
            if isCurrent(generation) {
                report.thawed = thawFrozenApps(before, dry: dryRun.isOn, why: skipped ?? "recheck impossible")
            }
            report.paused = currentPausedApps()
            return report
        }
        // `isComplete == false` (a probe failed, the 1 s deadline skipped the newest processes): P-C/P-D cannot see
        // what an agent talks to. Never freeze on an incomplete topology (§9.5) — and never stay frozen on one.
        if !run.topology.isComplete {
            report.thawed = thawFrozenApps(before, dry: run.dry, why: "agent topology incomplete")
        }

        let apps = (journal.current?.apps ?? []).filter { $0.mode != .quit }
        let running = Dictionary(candidates.runningApplications().map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let mains = state.withLock { $0.mains }
        let groups = run.grouping.groups(for: apps.map(\.appPid), in: run.table, uid: run.uid)
        let audio = probe.audioActivePIDs(among: Set(groups.values.joined()))
        let pausedByPID = Dictionary(before.map { ($0.appPID, $0) }, uniquingKeysWith: { first, _ in first })

        for app in apps {
            guard isCurrent(run.generation) else {
                report.skippedReason = "interrupted by a thaw"
                break
            }
            let candidate = running[app.appPid] ?? AppCandidate(pid: app.appPid, bundleID: app.bundleID, localizedName: app.name)
            let knownMain = mains[app.appPid] ?? app.members.first { $0.pid == app.appPid }?.identity
            guard let main = run.table[app.appPid], knownMain.map({ $0 == main.identity }) ?? true else {
                // The app quit (or its pid was reused): thaw whatever helpers are left.
                thawJournaledApp(app.appPid, dry: run.dry)
                if let paused = pausedByPID[app.appPid] { report.thawed.append(paused) }
                logger.info("recheck: \(candidate.displayName) quit while paused; released its helpers")
                continue
            }
            let facts = gatherFacts(app: candidate, main: main, memberPIDs: groups[app.appPid] ?? [], audio: audio, table: run.table)
            let reasons = ProtectionRules.protections(for: facts, in: run.context)
            guard !reasons.isEmpty else { continue }
            thawJournaledApp(app.appPid, dry: run.dry)
            let protected = ProtectedApp(appPID: app.appPid, bundleID: candidate.bundleID, name: candidate.displayName, reasons: reasons)
            state.withLock { $0.session.protected[main.identity] = protected }
            report.protected.append(protected)
            if let paused = pausedByPID[app.appPid] { report.thawed.append(paused) }
            logger.notice("recheck: thawed \(candidate.displayName) and protected it for this session (\(reasons.map(\.rawValue).joined(separator: ", ")))")
        }

        let rescanDue = state.withLock { s -> Bool in
            guard let last = s.session.lastRescan,
                  now.timeIntervalSince(last) < TimeInterval(settings.throttleRescanSeconds) else {
                s.session.lastRescan = now
                return true
            }
            return false
        }
        if rescanDue, isCurrent(run.generation) {
            let protectedByRescan = rescanThrottledHelpers(run: run, running: running)
            for item in protectedByRescan {
                report.protected.append(item)
                if let paused = pausedByPID[item.appPID] { report.thawed.append(paused) }
            }
        }
        report.paused = currentPausedApps()
        return report
    }

    /// Throttles helpers spawned since the pause by throttled apps (launchd-spawned XPC services do not inherit
    /// darwinbg). A newcomer with a controlling tty thaws and protects the app instead. Returns apps protected.
    func rescanThrottledHelpers(run: Run, running: [pid_t: AppCandidate]) -> [ProtectedApp] {
        // Children forked by throttled members inherited the throttle: journal them first (they are then "known" and
        // restored by every thaw), the remaining darwinbg newcomers are someone else's and stay untouched.
        adoptInheritedThrottles()
        guard let snapshot = journal.current else { return [] }
        let throttled = snapshot.apps.filter { $0.mode == .throttle && $0.simulated == run.dry }
        guard !throttled.isEmpty else { return [] }
        let groups = run.grouping.groups(for: throttled.map(\.appPid), in: run.table, uid: run.uid)
        let mains = state.withLock { $0.mains }
        var protectedApps: [ProtectedApp] = []
        for app in throttled {
            guard isCurrent(run.generation) else { break }
            guard let mainEntry = run.table[app.appPid], mains[app.appPid].map({ $0 == mainEntry.identity }) ?? true else { continue }
            let known = Set(app.members.map(\.pid))
            let newcomers = (groups[app.appPid] ?? []).filter { !known.contains($0) }.compactMap { run.table[$0] }
            guard !newcomers.isEmpty else { continue }
            let name = running[app.appPid]?.displayName ?? app.name ?? "pid \(app.appPid)"
            if newcomers.contains(where: \.hasControllingTTY) {
                thawJournaledApp(app.appPid, dry: run.dry)
                let protected = ProtectedApp(appPID: app.appPid, bundleID: app.bundleID, name: name, reasons: [.notCandidate])
                state.withLock { $0.session.protected[mainEntry.identity] = protected }
                protectedApps.append(protected)
                continue
            }
            let fresh = newcomers.compactMap { probe.enrich($0.identity) }.filter { signaller.isDarwinBackground($0) != true }
            guard !fresh.isEmpty else { continue }
            let info = JournalAppInfo(appPid: app.appPid, bundleID: app.bundleID, name: name)
            do {
                try journalAppend(info, mode: .throttle, records: records(for: fresh, action: .darwinBackground), run: run)
            } catch {
                logger.error("journal write failed while re-scanning \(name): \(error)")
                continue
            }
            let mainIdentity = mains[app.appPid] ?? mainEntry.identity
            if case .success(let applied) = applyThrottle(info, main: mainIdentity, targets: fresh, run: run), !applied.isEmpty {
                logger.info("throttled \(applied.count) new helper(s) of \(name)")
            }
        }
        return protectedApps
    }

    /// Thaws every journaled `.freeze` app (LIFO per app); returns the apps thawed.
    func thawFrozenApps(_ paused: [PausedApp], dry: Bool, why: String) -> [PausedApp] {
        let frozen = (journal.current?.apps ?? []).filter { $0.mode == .freeze }.map(\.appPid)
        guard !frozen.isEmpty else { return [] }
        for appPid in frozen { thawJournaledApp(appPid, dry: dry) }
        logger.notice("recheck: \(why): thawed \(frozen.count) frozen app(s)")
        let set = Set(frozen)
        return paused.filter { set.contains($0.appPID) }
    }

    // MARK: - Journal helpers

    func records(for identities: [ProcessIdentity], action: PauseAction) -> [PauseJournalRecord] {
        identities.compactMap { PauseJournalRecord(identity: $0, path: probe.executablePath(of: $0.pid), action: action) }
    }

    /// Journal FIRST: appends `records` to the app's entry (creating it with `simulated = run.dry`) and persists with
    /// F_FULLFSYNC before returning, then refreshes the crash-handler pid list (before the caller signals).
    func journalAppend(_ app: JournalAppInfo, mode: PauseMode, records: [PauseJournalRecord], run: Run) throws {
        try journal.update(header: { PauseJournal(bootSessionUUID: run.bootUUID, kakurenekoPid: selfPID, startedAt: run.began) }) { j in
            if j.bootSessionUUID != run.bootUUID {
                // Records of another boot can never be verified again.
                j.apps.removeAll()
                j.bootSessionUUID = run.bootUUID
                j.startedAt = run.began
            }
            j.kakurenekoPid = selfPID
            if let index = j.apps.firstIndex(where: { $0.appPid == app.appPid }) {
                let existing = Set(j.apps[index].members)
                j.apps[index].members.append(contentsOf: records.filter { !existing.contains($0) })
            } else {
                j.apps.append(PauseJournalApp(bundleID: app.bundleID, name: app.name, appPid: app.appPid, mode: mode,
                                              members: records, simulated: run.dry))
            }
        }
        publishCrashBuffer()
    }

    func dropJournalApp(_ appPid: Int32) {
        let members = journal.current?.apps.first { $0.appPid == appPid }?.members ?? []
        removeFromJournal([appPid: members])
    }

    func dropJournalRecords(_ appPid: Int32, identities: [ProcessIdentity]) {
        let set = Set(identities)
        let members = journal.current?.apps.first { $0.appPid == appPid }?.members.filter { set.contains($0.identity) } ?? []
        removeFromJournal([appPid: members])
    }

    /// Thaws one journaled app (LIFO) and removes what was undone — including the processes its throttled members
    /// forked meanwhile (they inherited the throttle; `adoptInheritedThrottles`).
    func thawJournaledApp(_ appPid: Int32, dry: Bool) {
        adoptInheritedThrottles(only: [appPid])
        guard let snapshot = journal.current, let app = snapshot.apps.first(where: { $0.appPid == appPid }) else { return }
        let boot = probe.bootSessionUUID()
        let thaw = thawApp(app, dry: dry, bootMatches: boot != nil && boot == snapshot.bootSessionUUID, allowRelaunch: false)
        removeFromJournal([appPid: thaw.remove])
    }
}
