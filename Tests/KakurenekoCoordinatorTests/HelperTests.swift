@testable import KakurenekoCoordinator
import KakurenekoCloud
import KakurenekoKit
import Foundation
import Testing

/// Pure helpers: notification routing, the pause gate and topology augmentation, the CPU watchdog, E3 hints,
/// the resume manifest and the warning list.
@Suite("Coordinator helpers (pure)", .timeLimit(.minutes(1)))
struct HelperTests {
    let t0 = TestClock.defaultStart

    // MARK: NotificationRouting

    @Test func effectKindsMapToIntents() {
        let session = Fixture.session("s", state: .idle(since: t0, outcome: .completed))
        let finished = Fixture.effect(.finished, session, at: t0, outcome: .completed)
        let needs = Fixture.effect(.needsInput, session, at: t0)
        let stalled = Fixture.effect(.stalled, session, at: t0)
        let quiet = Fixture.effect(.wentQuiet, session, at: t0)
        let ended = Fixture.effect(.ended, session, at: t0)
        let sleepsAt = t0.addingTimeInterval(300)
        #expect(NotificationRouting.intent(for: finished, workingCount: 2, awakeUntil: nil, sleepsAt: nil) == .finished(finished, stillRunning: 2))
        #expect(NotificationRouting.intent(for: needs, workingCount: 0, awakeUntil: sleepsAt, sleepsAt: nil) == .needsInput(needs, awakeUntil: sleepsAt))
        #expect(NotificationRouting.intent(for: stalled, workingCount: 0, awakeUntil: nil, sleepsAt: nil) == .stalled(stalled))
        #expect(NotificationRouting.intent(for: quiet, workingCount: 0, awakeUntil: nil, sleepsAt: sleepsAt) == .wentQuiet(quiet, sleepsAt: sleepsAt))
        #expect(NotificationRouting.intent(for: ended, workingCount: 0, awakeUntil: nil, sleepsAt: nil) == nil)
    }

    @Test func resolvedKeysAreThoseThatLeftWaiting() {
        let a = SessionKey(agent: .claude, id: "a")
        let b = SessionKey(agent: .codex, id: "b")
        let c = SessionKey(agent: .gemini, id: "c")
        #expect(NotificationRouting.resolvedKeys(previouslyWaiting: [a, b], nowWaiting: [b, c]) == [a])
        #expect(NotificationRouting.resolvedKeys(previouslyWaiting: [], nowWaiting: [a]).isEmpty)
    }

    @Test func awakeUntilIsTheNeedsInputWindowOrALongerKeepAwake() {
        let timers = SessionTimers()
        #expect(NotificationRouting.awakeUntil(waitingSince: t0, timers: timers, keepAwakeUntil: nil, canKeepAwake: true) == t0.addingTimeInterval(600))
        #expect(NotificationRouting.awakeUntil(waitingSince: t0, timers: timers, keepAwakeUntil: t0.addingTimeInterval(60), canKeepAwake: true) == t0.addingTimeInterval(600))
        #expect(NotificationRouting.awakeUntil(waitingSince: t0, timers: timers, keepAwakeUntil: t0.addingTimeInterval(3600), canKeepAwake: true) == t0.addingTimeInterval(3600))
        #expect(NotificationRouting.awakeUntil(waitingSince: t0, timers: timers, keepAwakeUntil: nil, canKeepAwake: false) == nil)
    }

    @Test func waitingSinceAndResubmission() {
        let since = t0.addingTimeInterval(-42)
        let waiting = Fixture.session("w", state: .waiting(kind: .dialog, since: since))
        let effect = Fixture.effect(.needsInput, waiting, at: t0)
        #expect(NotificationRouting.waitingSince(effect) == since)
        #expect(NotificationRouting.waitingSince(Fixture.effect(.finished, Fixture.session("x", state: .working(since: t0)), at: t0)) == t0)
        let resubmitted = NotificationRouting.resubmittedNeedsInput(for: waiting)
        #expect(resubmitted?.kind == .needsInput && resubmitted?.at == since && resubmitted?.needsInputKind == .dialog)
        #expect(NotificationRouting.resubmittedNeedsInput(for: Fixture.session("x", state: .working(since: t0))) == nil)
    }

    @Test func busyAgainNamesTheMostRecentlyBusySession() {
        let older = Fixture.session("a", agent: .codex, state: .working(since: t0), cwd: "/Users/tester/code/web", turnStartedAt: t0)
        let newer = Fixture.session("b", agent: .claude, state: .working(since: t0), cwd: "/Users/tester/code/api", turnStartedAt: t0.addingTimeInterval(5))
        let idle = Fixture.session("c", agent: .gemini, state: .idle(since: t0, outcome: nil), turnStartedAt: t0.addingTimeInterval(9))
        #expect(NotificationRouting.busyAgainReason(sessions: [older, newer, idle]) == "Claude Code in api is busy again")
        #expect(NotificationRouting.busyAgainReason(sessions: [older]) == "Codex in web is busy again")
        let noProject = Fixture.session("d", agent: .codex, state: .working(since: t0), cwd: nil)
        #expect(NotificationRouting.busyAgainReason(sessions: [noProject]) == "Codex is busy again")
        #expect(NotificationRouting.busyAgainReason(sessions: []) == "An agent became busy again")
        #expect(NotificationRouting.busyAgainReason(sessions: [Fixture.session("e", state: .ended(at: t0))]) == "An agent became busy again")
    }

    @Test func presenceTreatsClamshellAsOpen() {
        let present = NotificationRouting.presence(effectiveLidClosed: false, screenLocked: nil, secondsSinceUserInput: 10)
        #expect(!present.isAway(idleThreshold: 300))
        #expect(NotificationRouting.presence(effectiveLidClosed: true, screenLocked: nil, secondsSinceUserInput: 0).isAway())
        #expect(NotificationRouting.presence(effectiveLidClosed: false, screenLocked: true, secondsSinceUserInput: 0).isAway())
    }

    // MARK: PausePolicy

    func gate(_ configure: (inout PausePolicy.Inputs) -> Void = { _ in }) -> PausePolicy.Inputs {
        var i = PausePolicy.Inputs(now: t0.addingTimeInterval(90), effectiveLidClosed: true, closedSince: t0,
                                   secondsSinceUserInput: 60, shouldStayArmed: true, heldAwakeWithLidClosed: true,
                                   mode: .full, kakurenekoEnabled: true, settings: PauseSettings())
        configure(&i)
        return i
    }

    @Test func pauseGateNeedsEveryCondition() {
        #expect(PausePolicy.shouldPause(gate()))
        #expect(PausePolicy.shouldPause(gate { $0.secondsSinceUserInput = nil })) // unknown input = none
        #expect(!PausePolicy.shouldPause(gate { $0.now = self.t0.addingTimeInterval(89) }))
        #expect(!PausePolicy.shouldPause(gate { $0.secondsSinceUserInput = 59 }))
        #expect(!PausePolicy.shouldPause(gate { $0.effectiveLidClosed = false }))
        #expect(!PausePolicy.shouldPause(gate { $0.closedSince = nil }))
        #expect(!PausePolicy.shouldPause(gate { $0.shouldStayArmed = false }))
        #expect(!PausePolicy.shouldPause(gate { $0.heldAwakeWithLidClosed = false }))
        #expect(!PausePolicy.shouldPause(gate { $0.mode = .notificationsOnly }))
        #expect(!PausePolicy.shouldPause(gate { $0.kakurenekoEnabled = false }))
        #expect(!PausePolicy.shouldPause(gate { $0.settings.enabled = false }))
        #expect(PausePolicy.shouldPause(gate { $0.settings.lidCloseSettleSeconds = 30; $0.now = self.t0.addingTimeInterval(30) }))
    }

    @Test func hardCap() {
        var settings = PauseSettings()
        settings.maxPausedHours = 2
        #expect(!PausePolicy.hardCapReached(pausedSince: nil, now: t0, settings: settings))
        #expect(!PausePolicy.hardCapReached(pausedSince: t0, now: t0.addingTimeInterval(7199), settings: settings))
        #expect(PausePolicy.hardCapReached(pausedSince: t0, now: t0.addingTimeInterval(7200), settings: settings))
    }

    @Test func topologyIsAugmentedWithLiveSessionProcessesAndHosts() {
        let base = AgentTopology(builtAt: t0, agentIdentities: [Fixture.identity(1)], sessionHostPIDs: [999])
        let sessions = [
            Fixture.session("a", state: .working(since: t0), agentPID: 10, hostPID: 4242),
            Fixture.session("b", state: .waiting(kind: .permission, since: t0), hostPID: 5151),
            Fixture.session("c", state: .ended(at: t0), agentPID: 30, hostPID: 6161),
        ]
        let augmented = PausePolicy.augment(base, with: sessions)
        #expect(augmented.agentIdentities == [Fixture.identity(1), Fixture.identity(10)])
        #expect(augmented.sessionHostPIDs == [4242, 5151]) // replaced, ended sessions excluded
        #expect(augmented.builtAt == t0)
    }

    // MARK: CPUWatchdog

    @Test func watchdogTripsOnlyForAStalledWorkingAgentSinceTheFreeze() {
        var dog = CPUWatchdog()
        let working = Fixture.session("w", state: .working(since: t0), agentPID: 7)
        func scan(_ cpu: Double?, at seconds: TimeInterval) {
            let at = t0.addingTimeInterval(seconds)
            dog.observe(ProcessSnapshot(takenAt: at, agents: [Fixture.agentProcess(7, cpuSeconds: cpu, at: at)]), now: at)
        }
        scan(10, at: 0)
        scan(10.005, at: 100) // below epsilon: not an advance
        let frozenSince = t0.addingTimeInterval(200)
        #expect(!dog.tripped(workingSessions: [working], frozenSince: frozenSince, now: t0.addingTimeInterval(499), limit: 300))
        #expect(dog.tripped(workingSessions: [working], frozenSince: frozenSince, now: t0.addingTimeInterval(500), limit: 300))
        scan(11, at: 450) // advanced
        #expect(!dog.tripped(workingSessions: [working], frozenSince: frozenSince, now: t0.addingTimeInterval(700), limit: 300))
        #expect(dog.tripped(workingSessions: [working], frozenSince: frozenSince, now: t0.addingTimeInterval(750), limit: 300))
        // Not working, or no counter, or the process vanished: never trips.
        let idle = Fixture.session("w", state: .idle(since: t0, outcome: nil), agentPID: 7)
        #expect(!dog.tripped(workingSessions: [idle], frozenSince: frozenSince, now: t0.addingTimeInterval(9999), limit: 300))
        scan(nil, at: 800)
        #expect(dog.progress.isEmpty)
        #expect(!dog.tripped(workingSessions: [working], frozenSince: frozenSince, now: t0.addingTimeInterval(9999), limit: 300))
    }

    // MARK: SessionStoreHints

    @Test func hintsComeFromLiveSessionsWithAProcessAndAPath() {
        let sessions = [
            Fixture.session("b", agent: .codex, state: .working(since: t0), agentPID: 20,
                            metadata: [MetadataKey.transcriptPath: "/t/b.jsonl", MetadataKey.sessionStoreDirectory: "/t/store"]),
            Fixture.session("a", agent: .gemini, state: .working(since: t0), agentPID: 10,
                            metadata: [MetadataKey.transcriptPath: "/t/a.jsonl"]),
            Fixture.session("c", state: .working(since: t0), metadata: [MetadataKey.transcriptPath: "/t/c.jsonl"]),
            Fixture.session("d", state: .ended(at: t0), agentPID: 30, metadata: [MetadataKey.transcriptPath: "/t/d.jsonl"]),
            Fixture.session("e", state: .working(since: t0), agentPID: 40, metadata: [MetadataKey.transcriptPath: ""]),
        ]
        #expect(SessionStoreHints.build(from: sessions) == [
            SessionStoreHint(identity: Fixture.identity(10), paths: ["/t/a.jsonl"]),
            SessionStoreHint(identity: Fixture.identity(20), paths: ["/t/b.jsonl", "/t/store"]),
        ])
    }

    /// Brief §5.4: the main Claude transcript alone is not E3 (idle sessions append `away_summary` and wake metadata,
    /// which revived stalled sessions); only the `<sessionId>/` store subtree (subagents, workflows) is hinted.
    @Test func claudeHintsCoverOnlyTheSessionStoreSubtreeNeverTheMainTranscript() {
        let sessions = [
            Fixture.session("s1", state: .working(since: t0), agentPID: 10,
                            metadata: [MetadataKey.transcriptPath: "/p/s1.jsonl", MetadataKey.sessionStoreDirectory: "/p/s1"]),
            Fixture.session("s2", state: .stalled(since: t0), agentPID: 20, metadata: [MetadataKey.transcriptPath: "/p/s2.jsonl"]),
        ]
        #expect(SessionStoreHints.build(from: sessions) == [SessionStoreHint(identity: Fixture.identity(10), paths: ["/p/s1"])])
    }

    // MARK: ResumeManifest

    @Test func resumeManifestEntriesRoundTripAt0600() throws {
        let paths = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        let host = HostApp(bundleID: "com.apple.Terminal", name: "Terminal", pid: 77)
        var titled = Fixture.session("abc", state: .idle(since: t0, outcome: .completed),
                                     metadata: [MetadataKey.claudeKind: "bg", MetadataKey.claudeJobID: "job-1"])
        titled.title = "Fix tests"
        titled.host = host
        let sessions = [
            titled,
            Fixture.session("pid:9:1.2", agent: .aider, state: .working(since: t0), cwd: "/x/y"),
            Fixture.session("gone", state: .ended(at: t0)),
        ]
        let entries = ResumeManifest.entries(from: sessions)
        #expect(entries == [
            ResumeEntry(agent: .claude, sessionId: "abc", cwd: Fixture.project, title: "Fix tests", kind: "bg", jobId: "job-1", host: host),
            ResumeEntry(agent: .aider, sessionId: nil, cwd: "/x/y", title: nil),
        ])
        try ResumeManifest.write(entries, to: paths.resumeManifestFile)
        #expect(ResumeManifest.read(from: paths.resumeManifestFile) == entries)
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.resumeManifestFile.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        try Data("{not json".utf8).write(to: paths.resumeManifestFile)
        #expect(ResumeManifest.read(from: paths.resumeManifestFile).isEmpty)
        ResumeManifest.delete(at: paths.resumeManifestFile)
        #expect(ResumeManifest.read(from: paths.resumeManifestFile).isEmpty)
        ResumeManifest.delete(at: paths.resumeManifestFile) // missing: no throw
    }

    // MARK: Warnings

    func warningInputs(_ configure: (inout WarningInputs) -> Void = { _ in }) -> WarningInputs {
        var i = WarningInputs(
            mode: .full,
            privileged: PrivilegedStatus(sudoRuleInstalled: true, failsafeLoaded: true),
            rawPrivileged: PrivilegedStatus(sudoRuleInstalled: true, failsafeLoaded: true),
            privilegedChecked: true,
            settings: .default,
            power: nil,
            effectiveLidClosed: false,
            isDryRun: false,
            appTamerRunning: false,
            groupingSelfTest: GroupingSelfTest(method: .responsibility, freezeAllowed: true),
            notifications: NotificationStatus(),
            kernelSleepDisabledInDryRun: false,
            disarmFailed: false,
            armingBlocked: nil,
            hotspotAtLidClose: false,
            integrations: []
        )
        configure(&i)
        return i
    }

    func ids(_ configure: (inout WarningInputs) -> Void) -> [String] {
        WarningsBuilder.warnings(warningInputs(configure)).map(\.id)
    }

    @Test func aHealthyFullModeHasNoWarnings() {
        #expect(WarningsBuilder.warnings(warningInputs()).isEmpty)
    }

    @Test func eachConditionHasItsWarning() {
        #expect(ids { $0.rawPrivileged = notInstalled; $0.privileged = notInstalled; $0.mode = .notificationsOnly } == ["privileged-missing"])
        #expect(ids { $0.rawPrivileged = notInstalled; $0.privileged = notInstalled; $0.privilegedChecked = false }.isEmpty)
        let mismatch = PrivilegedStatus(sudoRuleInstalled: true, failsafeLoaded: true, failsafeHeartbeatPath: "/Users/other/.kakureneko/run/heartbeat", heartbeatPathMismatch: true)
        #expect(ids { $0.rawPrivileged = mismatch; $0.privileged = mismatch } == ["heartbeat-path-mismatch"])
        let damaged = PrivilegedStatus(sudoRuleInstalled: true, failsafeLoaded: true, failsafeScriptMismatch: true)
        #expect(!damaged.isOperational)
        #expect(ids { $0.rawPrivileged = damaged; $0.privileged = damaged } == ["failsafe-damaged"])
        #expect(ids { $0.appTamerRunning = true } == ["app-tamer"])
        #expect(ids { $0.settings.pausing.mode = .freeze; $0.groupingSelfTest = GroupingSelfTest(method: .parentTree, freezeAllowed: false) } == ["freeze-unavailable"])
        #expect(ids { $0.settings.pausing.mode = .freeze }.isEmpty)
        #expect(ids { $0.settings.notifications.detailLevel = .detailed }.isEmpty)
        #expect(ids { $0.hotspotAtLidClose = true; $0.effectiveLidClosed = true } == ["hotspot"])
        #expect(ids { $0.hotspotAtLidClose = true; $0.effectiveLidClosed = false }.isEmpty)
        #expect(ids { $0.power = PowerSnapshot(takenAt: self.t0, onAC: false, lowPowerMode: true) } == ["low-power-mode"])
        #expect(ids { $0.power = PowerSnapshot(takenAt: self.t0, onAC: true, lowPowerMode: true) }.isEmpty)
        #expect(ids { $0.notifications = NotificationStatus(lastError: "boom") } == ["phone-alerts-error"], "shown unless iCloud is known to be missing")
        #expect(ids { $0.notifications = NotificationStatus(lastError: "boom"); $0.settings.notifications.phoneAlerts = false }.isEmpty)
        #expect(ids { $0.notifications = NotificationStatus(iCloud: .available, lastError: "Your iCloud storage is full.") }
                == ["phone-alerts-error"])
        #expect(ids { $0.notifications = NotificationStatus(macAuthorization: .denied) } == ["mac-notifications-off"])
        #expect(ids { $0.notifications = NotificationStatus(macAuthorization: .denied); $0.settings.notifications.macAlerts = false }.isEmpty)
        #expect(ids { $0.notifications = NotificationStatus(iCloud: .noAccount) } == ["icloud-unavailable"])
        #expect(ids { $0.notifications = NotificationStatus(iCloud: .unavailableInThisBuild) } == ["icloud-unavailable"])
        #expect(ids { $0.notifications = NotificationStatus(iCloud: .noAccount); $0.settings.notifications.phoneAlerts = false }.isEmpty)
        #expect(ids { $0.notifications = NotificationStatus(macAuthorization: .denied, iCloud: .noAccount); $0.settings.notifications.enabled = false }
                .isEmpty)
        #expect(ids { $0.isDryRun = true } == ["dry-run"])
        let simulated = PrivilegedStatus.simulatedForDryRun(at: t0)
        #expect(ids { $0.isDryRun = true; $0.privileged = simulated; $0.rawPrivileged = notInstalled } == ["dry-run", "dry-run-privileged-simulated"])
        #expect(ids { $0.kernelSleepDisabledInDryRun = true } == ["kernel-sleep-disabled"])
        #expect(ids { $0.disarmFailed = true } == ["disarm-failed"])
        #expect(ids { $0.armingBlocked = .thermalPressure(.heavy) } == ["arming-blocked"])
        #expect(ids { $0.integrations = [IntegrationStatus(agent: .cursor, supported: true, configDirExists: true, installed: true, needsRepair: true)] }
                == ["integration-repair:cursor"])
    }

    @Test func warningsAreOrderedMostSevereFirst() {
        let list = WarningsBuilder.warnings(warningInputs {
            $0.isDryRun = true
            $0.appTamerRunning = true
            $0.disarmFailed = true
            $0.kernelSleepDisabledInDryRun = true
        })
        #expect(list.map(\.id) == ["kernel-sleep-disabled", "disarm-failed", "app-tamer", "dry-run"])
        #expect(list.map(\.severity) == [.critical, .critical, .warning, .info])
    }

    @Test func snapshotEquivalenceIgnoresOnlyTheTimestamp() {
        let a = AppSnapshot(generatedAt: t0, mode: .full, isDryRun: false, isDryRunForced: false, settings: .default)
        var b = a
        b.generatedAt = t0.addingTimeInterval(10)
        #expect(a.isEquivalent(to: b))
        b.mode = .disabled
        #expect(!a.isEquivalent(to: b))
    }
}
