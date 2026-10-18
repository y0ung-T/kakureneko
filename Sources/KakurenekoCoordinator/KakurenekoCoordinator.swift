// KakurenekoCoordinator — the brain: wires sources → SessionEngine → aggregation → power state machine (§7.3)
// → pause/notify actions; remote command execution; settings persistence; implements KakurenekoControlling and
// publishes AppSnapshot; dry-run wiring.
// OWNER: agent "coordinator". Spec card: docs/ARCHITECTURE.md §9.8. Brief §5.6, §6.1, §6.5, §7.3–7.5, §8.3,
// §8.5, §9.4.
//
// Files:
//   KakurenekoCoordinator.swift       the actor: state, init, the KakurenekoControlling surface
//   Coordinator+Lifecycle.swift     start() order, launch reconcile, subscriptions, prepareForTermination()
//   Coordinator+Evaluation.swift    main loop, process() (route → step → act), pausing, heartbeat, publishing
//   Coordinator+Power.swift         action execution, the wind-down task, power events, remote commands, settings
//   PowerStateMachine.swift         the pure §7.3 machine + predicates
//   PauseScheduling.swift           pause gate, topology augmentation, CPU watchdog, E3 hints (pure)
//   NotificationRouting.swift       SessionEffect → NotificationIntent (pure)
//   SnapshotBuilder.swift           warnings (pure) + snapshot comparison
//   ResumeManifest.swift            resume.json
//   TerminationSignals.swift        SIGTERM/INT/HUP/QUIT dispatch sources (live only)
//   RunningApplications.swift       read-only App Tamer probe
//   LiveComposition.swift           the composition root (only place naming concrete module types)

import KakurenekoCloud
import KakurenekoKit
import Foundation

/// Test and diagnostics knobs. Not part of the public surface: the public initializer uses the defaults.
struct CoordinatorOptions: Sendable {
    /// Run the 1 s main loop after `start()`. Tests switch it off and call `tick()` themselves.
    var runsMainLoop: Bool
    /// Main-loop period.
    var tickInterval: Duration
    /// Whether an app with this bundle id is running (App Tamer warning). Injected so tests never look at real apps.
    var isApplicationRunning: @Sendable (String) -> Bool
    /// When this boot began (`kern.boottime`, read-only); nil = unknown. A `resume.json` written after it describes
    /// sessions that survived (no shutdown happened), so it is not offered.
    var bootTime: @Sendable () -> Date?

    init(
        runsMainLoop: Bool = true,
        tickInterval: Duration = .seconds(1),
        isApplicationRunning: @escaping @Sendable (String) -> Bool = { RunningApplications.isRunning($0) },
        bootTime: @escaping @Sendable () -> Date? = { ResumeManifest.kernelBootTime() }
    ) {
        self.runsMainLoop = runsMainLoop
        self.tickInterval = tickInterval
        self.isApplicationRunning = isApplicationRunning
        self.bootTime = bootTime
    }
}

/// Fixed timings (brief §6.4, §7.3, §7.5, §8.5, R07 §14; ARCHITECTURE §9.8).
enum CoordinatorTiming {
    /// Leading-edge snapshot coalescing: at most one immediate publish per 250 ms; the 1 s tick flushes the rest.
    static let minimumPublishInterval: TimeInterval = 0.25
    /// `touchHeartbeat()` cadence while armed (the root fail-safe clears the flag after 150 s without one).
    static let heartbeatInterval: TimeInterval = 15
    /// SafetyMonitor cadence while the lid is closed and the Mac held awake.
    static let safetyInterval: TimeInterval = 15
    /// A power snapshot older than this is refreshed by the tick before a safety evaluation.
    static let staleSnapshotAge: TimeInterval = 30
    /// `notifications.drain(deadline: now + 10 s)` before every Kakureneko-initiated sleep or shutdown.
    static let windDownDrainSeconds: TimeInterval = 10
    /// Wait after thawing before a power action (frozen apps delay sleep and block shutdown).
    static let thawSettle: Duration = .seconds(3)
    /// Still running this long after a polite shutdown request → fall back to sleep.
    static let shutdownFallback: Duration = .seconds(180)
    /// Shortest delay handed to the detached sleep fallback when the app quits late in the 3 min window.
    static let detachedSleepMinimumDelay: TimeInterval = 10
    /// No `willSleep` this long after `sleepNow()` → the sleep did not happen (Disarmed, retry later).
    static let sleepConfirmation: Duration = .seconds(60)
    /// Outbox flush inside the `willSleep` window (the acknowledger auto-allows after 8 s).
    static let willSleepFlushSeconds: TimeInterval = 5
    /// Outbox kick after a wake.
    static let wakeDrainSeconds: TimeInterval = 10
    /// Outbox flush in `prepareForTermination()`.
    static let terminationDrainSeconds: TimeInterval = 2
    /// After a failed `arm()`, do not retry for this long.
    static let armRetryBackoff: TimeInterval = 60
    /// User input newer than this in a snapshot thaws paused apps (`.userInput`).
    static let userInputThawSeconds: TimeInterval = 5
    /// App Tamer probe cadence.
    static let conflictingAppCheckInterval: TimeInterval = 300
    /// Integration statuses (hooks an agent update removed → "needs repair") are re-read this often.
    static let integrationRefreshInterval: TimeInterval = 600
    /// Dry-run ledger lines in the snapshot.
    static let dryRunLogLimit = 50
}

/// `start()` / `prepareForTermination()` lifecycle.
enum CoordinatorLifecycle {
    case idle
    case starting(Task<Void, Never>)
    case running
    case terminated
}

/// The ONE wind-down task and what it reported (ARCHITECTURE §9.8 "WindingDown").
struct WindDownState {
    /// Bumped by every start/cancel; the task re-checks it (and the phase) after every await.
    var generation: UInt64 = 0
    var task: Task<Void, Never>?
    var progress: WindDownProgress = .none
    /// `willSleep` arrived after `sleepNow()`.
    var sleepConfirmed = false
    /// The sleep Kakureneko initiated, reported as `.asleep` after the wake.
    var pendingSleepRecord: SleepRecord?
    /// `resume.json` was written by this wind-down (deleted after a wake: the sessions survived).
    var resumeManifestWritten = false
    /// When `requestShutdown()` went out (the 3 min sleep fallback counts from here).
    var shutdownRequestedAt: Date?
}

/// Pausing bookkeeping for the current effective closed-lid period.
struct PauseState {
    /// `pause` ran this period (recheck / level thaw triggers apply).
    var active = false
    var startedAt: Date?
    var nextRecheckAt: Date?
    /// Hard cap, watchdog or "Resume all": no new `pause` until the next effective lid edge.
    var suppressedUntilLidEdge = false
    /// Bumped by every thaw: a `pause`/`recheck` that raced with a thaw is undone / ignored.
    var epoch: UInt64 = 0
    var inFlight = false
    var lastThawReason: ThawReason?
    var pausedApps: [PausedApp] = []
    var lastReport: PauseReport?
}

/// Snapshot publishing state (leading-edge coalescing).
struct PublishState {
    var lastPublished: AppSnapshot
    /// nil until the first publish after `init` (the initial snapshot does not open a coalescing window).
    var lastPublishAt: Date?
    var dirty = false
    var count = 0
}

/// The coordinator's FIFO async locks (actor re-entrancy: every `await` lets other inputs run).
enum CoordinatorLock: Sendable, Hashable {
    /// Every flag/power mutation (arm, disarm, sleep, shutdown): execution order = decision order, and an `arm`
    /// decided after a cancelled wind-down never interleaves with that wind-down's in-flight `disarm`.
    case power
    /// `pausing.pause` / `recheck` / `thawAll`: a thaw requested while `pause` runs waits for it and then thaws
    /// what it just paused, under the same dry-run gate.
    case pause
    /// `applySettings`: concurrent updates apply in order (the dry-run toggle's undo must finish first).
    case settings
}

/// One FIFO async lock.
struct AsyncLockState {
    var held = false
    var waiters: [CheckedContinuation<Void, Never>] = []
}

/// The three locks of `CoordinatorLock`.
struct CoordinatorLocks {
    var power = AsyncLockState()
    var pause = AsyncLockState()
    var settings = AsyncLockState()

    subscript(_ lock: CoordinatorLock) -> AsyncLockState {
        get {
            switch lock {
            case .power: power
            case .pause: pause
            case .settings: settings
            }
        }
        set {
            switch lock {
            case .power: power = newValue
            case .pause: pause = newValue
            case .settings: settings = newValue
            }
        }
    }
}

/// How many inputs each consumer has fully handled (tests wait on these; diagnostics).
struct HandledCounts: Sendable, Hashable {
    var agentEvents = 0
    var claudeSnapshots = 0
    var powerEvents = 0
    var remoteCommands = 0
    var ticks = 0
}

/// The coordinator actor. Owns all mutable app state; services are reached only through Kit protocols.
public actor KakurenekoCoordinator: KakurenekoControlling {
    /// The composed services (fakes in tests).
    public nonisolated let services: KakurenekoServices

    let options: CoordinatorOptions
    let logger: KakurenekoLogger
    nonisolated let broadcaster = AsyncBroadcaster<AppSnapshot>(replayLatest: true)

    // MARK: Settings, mode, privileged
    var settings: KakurenekoSettings
    var lifecycle: CoordinatorLifecycle = .idle
    var mode: OperatingMode = .starting
    /// As shown and used for decisions (possibly `simulatedForDryRun`).
    var privileged: PrivilegedStatus = .unknown
    /// The real health-check result.
    var rawPrivileged: PrivilegedStatus = .unknown
    var privilegedChecked = false

    // MARK: Power
    var machine: PowerStateMachine
    var windDown = WindDownState()
    var locks = CoordinatorLocks()
    /// > 0 while a dry-run toggle, the master switch or a privileged uninstall undoes what was done under the
    /// old state: `process()` still routes notifications but neither steps the machine nor schedules pausing.
    var decisionSuspensions = 0
    var decisionsSuspended: Bool { decisionSuspensions > 0 }
    var keepAwakeUntil: Date?
    var lid: LidState = .unknown
    var externalDisplayConnected = false
    var latestPower: PowerSnapshot?
    var lastUserInputAt: Date?
    /// Last effective lid state seen by `process()` (edges drive bookkeeping; the machine has its own copy).
    var effectiveLidClosed = false
    /// Start of the current PHYSICAL closed-lid period (the 12 h cap while a display keeps the lid effectively open).
    var physicalLidClosedSince: Date?
    var armBackoffUntil: Date?
    /// Set after a failed disarm: the fail-safe must see a stale heartbeat and clear the flag.
    var heartbeatSuppressed = false
    var nextHeartbeatAt: Date?
    var lastSafetyEvaluationAt: Date?
    var safetyEvaluationDue = false
    var lastSleep: SleepRecord?

    // MARK: Sessions and notifications
    /// `finished` / `wentQuiet` effects since the effective lid closed (countdown reason and list).
    var turnEndsSinceLidClosed: [SessionEffect] = []
    var waitingKeys: Set<SessionKey> = []
    var wasAway: Bool?
    var wasLidClosed: Bool?
    var notificationStatus = NotificationStatus.initial
    /// Last status report handed to Notify for the iPhone app, and the chain that keeps those hand-offs in order.
    var lastStatusReport: MacStatusReport?
    var statusReportTail: Task<Void, Never>?
    /// The final status (asleep / shut down / quit) once reported: every later report keeps it, until the Mac wakes
    /// (`untilWake`) or — for a wind-down that has not reached the sleep yet — until the wind-down is cancelled.
    var finalStatus: (final: PhoneStatusBuilder.Final, untilWake: Bool)?

    // MARK: Pausing and processes
    var pause = PauseState()
    var watchdog = CPUWatchdog()
    var latestProcessSnapshot: ProcessSnapshot?
    var nextScanAt: Date?
    var appliedCadence: SamplingCadence?
    var appliedHints: [SessionStoreHint]?
    var groupingSelfTest: GroupingSelfTest?

    // MARK: Integrations, resume, warnings
    var integrationStatuses: [IntegrationStatus] = []
    var lastEventSeen: [AgentID: Date] = [:]
    var resumeOffer: [ResumeEntry] = []
    /// A `resume.json` kept after its shutdown was cancelled while the request was already out (loginwindow may still
    /// complete it): deleted at this time if Kakureneko is still running then (the shutdown did not happen).
    var resumeManifestDiscardAt: Date?
    var kernelSleepDisabledInDryRun = false
    var disarmFailed = false
    var armingBlocked: SafetyTrip?
    var hotspotAtLidClose = false
    var appTamerRunning = false
    var lastConflictingAppCheckAt: Date?
    var lastIntegrationRefreshAt: Date?

    // MARK: Tasks and publishing
    var consumerTasks: [Task<Void, Never>] = []
    var mainLoopTask: Task<Void, Never>?
    var signalSources: TerminationSignalSources?
    var publisher: PublishState
    var handled = HandledCounts()

    /// Binding signature. `settings == nil` → load from `services.paths.settingsFile` (defaults if missing).
    public init(services: KakurenekoServices, settings: KakurenekoSettings? = nil) {
        self.init(services: services, settings: settings, options: CoordinatorOptions())
    }

    /// Designated initializer (tests pass options). Performs no I/O beyond reading settings.json.
    init(services: KakurenekoServices, settings: KakurenekoSettings?, options: CoordinatorOptions) {
        self.services = services
        self.options = options
        self.logger = services.logger(.coordinator)
        let loaded = (settings ?? KakurenekoSettings.load(from: services.paths.settingsFile)).normalized()
        self.settings = loaded
        let now = services.clock.now()
        self.machine = PowerStateMachine(effectiveLidClosed: false, now: now)
        let initial = AppSnapshot(
            generatedAt: now,
            mode: .starting,
            isDryRun: services.dryRun.isOn,
            isDryRunForced: services.dryRun.isForcedByEnvironment,
            settings: loaded
        )
        self.publisher = PublishState(lastPublished: initial)
        broadcaster.yield(initial)
    }

    // MARK: Observation

    public nonisolated func snapshots() -> AsyncStream<AppSnapshot> { broadcaster.stream() }

    public func currentSnapshot() async -> AppSnapshot { buildSnapshot(now: services.clock.now()) }

    // MARK: Master switch & power

    public func setEnabled(_ enabled: Bool) async {
        var next = settings
        next.general.enabled = enabled
        await applySettings(next)
    }

    public func keepAwake(for seconds: TimeInterval) async {
        let until = services.clock.now().addingTimeInterval(max(0, seconds))
        logger.notice("keep awake until \(KakurenekoJSON.iso8601String(from: until)) (menu)")
        await requestKeepAwake(until: until)
    }

    public func cancelKeepAwake() async {
        guard keepAwakeUntil != nil else { return }
        keepAwakeUntil = nil
        logger.notice("keep awake cancelled (menu)")
        await process([])
    }

    public func sleepNow() async {
        logger.notice("sleep now (menu)")
        await requestSleep(.userSleepNow)
    }

    public func cancelWindDown() async {
        let actions = machine.cancelWindDown(currentInputs())
        logger.notice("cancel wind-down (menu): \(actions.isEmpty ? "nothing to cancel" : "\(actions)")")
        await execute(actions)
        publishIfChanged()
    }

    // MARK: Sessions

    public func dismissSession(_ key: SessionKey) async {
        logger.notice("dismiss session \(key)")
        let effects = services.sessions.dismiss(key, now: services.clock.now())
        await process(effects)
    }

    // MARK: Pausing

    public func resumeAllApps() async {
        logger.notice("resume all apps (menu)")
        await thaw(.userRequest)
        publishIfChanged()
    }

    public func setNeverPause(bundleID: String, _ neverPause: Bool) async {
        var next = settings
        var list = Set(next.pausing.neverPauseBundleIDs)
        if neverPause { list.insert(bundleID) } else { list.remove(bundleID) }
        next.pausing.neverPauseBundleIDs = list.sorted()
        await applySettings(next)
    }

    // MARK: Settings

    public func updateSettings(_ settings: KakurenekoSettings) async {
        await applySettings(settings)
    }

    public func completeOnboarding() async {
        var next = settings
        next.general.onboardingCompleted = true
        await applySettings(next)
    }

    // MARK: Privileged

    public func installPrivilegedHelper() async throws {
        logger.notice("installing closed-lid mode (one admin prompt)")
        do {
            try await services.privileged.install()
        } catch {
            logger.error("privileged install failed: \(error)")
            await refreshPrivilegedStatus()
            throw error
        }
        await refreshPrivilegedStatus()
    }

    public func uninstallPrivilegedHelper() async throws {
        logger.notice("uninstalling closed-lid mode")
        // Nothing may stay paused or armed once closed-lid mode is gone; nothing re-arms until the new health
        // check decided the mode.
        decisionSuspensions += 1
        abandonWindDown()
        machine.forceDisarmed()
        await thaw(.pausingDisabled)
        _ = await disarmFlag(context: "privileged uninstall")
        abandonWindDown()
        machine.forceDisarmed()
        var failure: (any Error)?
        do {
            try await services.privileged.uninstall()
        } catch {
            logger.error("privileged uninstall failed: \(error)")
            failure = error
        }
        decisionSuspensions -= 1
        await refreshPrivilegedStatus()
        if let failure { throw failure }
    }

    public func refreshPrivilegedStatus() async {
        let status = await services.privileged.healthCheck()
        applyPrivilegedStatus(status)
        await process([])
    }

    // MARK: Notifications

    public func requestNotificationPermission() async -> MacAlertAuthorization {
        let result = await services.notifications.requestMacAuthorization()
        await refreshNotificationStatus()
        return result
    }

    public func sendTestNotification() async throws {
        try await services.notifications.sendTest()
        await refreshNotificationStatus()
    }

    public func handleCloudPush() async {
        await services.notifications.cloudDidNotify()
    }

    public func forgetPhone(deviceID: String) async {
        await services.notifications.forgetPhone(deviceID: deviceID)
        await refreshNotificationStatus()
    }

    public func lookForPhones() async {
        await services.notifications.lookForPhones()
    }

    // MARK: Integrations

    public func refreshIntegrations() async {
        lastIntegrationRefreshAt = services.clock.now()
        integrationStatuses = await services.integrations.statuses()
        let seen = await services.events.lastEventSeen()
        lastEventSeen.merge(seen) { max($0, $1) }
        publishIfChanged()
    }

    public func previewIntegration(_ agent: AgentID, operation: InstallPlan.Operation) async throws -> InstallPlan {
        try await services.integrations.preview(agent, operation: operation)
    }

    public func installIntegration(_ agent: AgentID) async throws -> InstallResult {
        logger.notice("install integration \(agent.rawValue)")
        let result = try await services.integrations.install(agent)
        await refreshIntegrations()
        return result
    }

    public func uninstallIntegration(_ agent: AgentID) async throws -> InstallResult {
        logger.notice("uninstall integration \(agent.rawValue)")
        let result = try await services.integrations.uninstall(agent)
        await refreshIntegrations()
        return result
    }

    public func repairIntegration(_ agent: AgentID) async throws -> InstallResult {
        logger.notice("repair integration \(agent.rawValue)")
        let result = try await services.integrations.repair(agent)
        await refreshIntegrations()
        return result
    }

    // MARK: Resume

    public func clearResumeOffer() async {
        ResumeManifest.delete(at: services.paths.resumeManifestFile)
        resumeOffer = []
        publishIfChanged()
    }
}
