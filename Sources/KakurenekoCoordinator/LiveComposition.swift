// The composition root: the ONLY place that names concrete module types. Written by the architect against
// the binding signatures in docs/ARCHITECTURE.md. Owner: agent "coordinator" (keep the wiring rules below).
//
// Wiring rules (binding):
//   1. Real side effects are built once and wrapped with `SideEffects.gated` (dry-run switch on every call).
//   2. Services receive the GATED side effects. Real side-effect implementations receive the REAL (ungated)
//      `FoundationSubprocessRunner`, so a gated call is logged exactly once.
//   3. Every logger shares one optional `FileLogSink` (`~/.kakureneko/log/kakureneko.log`).
//   4. Nothing here performs I/O beyond reading settings.json; services start in `KakurenekoCoordinator.start()`.
//   5. `SessionEngine` gets `initialStateVersion` = launch epoch ms (signed `sv` never repeats across relaunches);
//      `handlesTerminationSignals: true` (only the live app installs SIGTERM/INT/HUP/QUIT sources).
//   6. Every defaulted dry-run/ledger/gate parameter a module appended to its binding init is passed EXPLICITLY
//      (never left to a default or to a "find it inside the gated side effect" fallback): `PowerController(ledger:)`,
//      `PrivilegedInstaller(dryRun:)`, `IntegrationManager(dryRun:ledger:)`, `PauseManager(dryRun:ledger:)`. The event
//      inbox and the scanner get the production `AgentMatcher`; the Claude watcher and the pause engine get
//      `LiveProcessLookup` (identity tuples equal `KernelProcessLookup`'s, ARCHITECTURE §8).
//   7. The gate starts with ONLY the environment policy (`KAKURENEKO_DRY_RUN`). `settings.general.dryRun` is applied by
//      `start()` step 6, AFTER journal recovery and the kernel-flag reconcile: real effects a crashed REAL run left
//      behind (journaled non-simulated pauses, a real `SleepDisabled`) are undone for real, as §6 requires ("undo
//      runs under the gate that acted"). Until then a `.starting` snapshot reports `isDryRun` = env-forced only.
//   8. `KAKURENEKO_SIMULATE_LID` (developer lid simulation) reaches `PowerController` and `PowerMonitor` as ONE
//      `LidSimulation`, and only when the environment forces dry-run (`LidSimulation.fromEnvironment`).

import KakurenekoCloud
import KakurenekoEvents
import KakurenekoInstall
import KakurenekoKit
import KakurenekoNotify
import KakurenekoPause
import KakurenekoPower
import KakurenekoProcesses
import KakurenekoSessions
import Foundation

extension KakurenekoCoordinator {
    /// Production services. Honours `KAKURENEKO_DRY_RUN` and `KAKURENEKO_HOME`.
    /// - Parameter bundleURL: the running app bundle (`Bundle.main.bundleURL`); helpers are located in
    ///   `Contents/Helpers/` only when it is a `.app`.
    public static func makeLiveServices(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL
    ) -> KakurenekoServices {
        let paths = Paths.live(environment: environment)
        let clock = SystemClock()
        let settings = KakurenekoSettings.load(from: paths.settingsFile)
        // Rule 7: settings-requested dry-run is applied by `start()` step 6, not here.
        let gate = DryRunGate(policy: .fromEnvironment(environment), requested: false)

        var sink: FileLogSink?
        if let debugPath = environment[KakurenekoEnvironment.debugLog], debugPath.hasPrefix("/") {
            sink = FileLogSink(url: URL(filePath: debugPath), minimumLevel: .debug)
        } else if settings.general.fileLogEnabled {
            sink = FileLogSink(url: paths.appLogFile)
        }
        func logger(_ category: LogCategory) -> KakurenekoLogger { KakurenekoLogger(category, sink: sink) }

        let ledger = DryRunLedger(logger: logger(.dryRun), clock: clock)

        // Real side effects (ungated) …
        let realSubprocess = FoundationSubprocessRunner()
        let real = SideEffects(
            privileged: SudoPrivilegedCommandRunner(subprocess: realSubprocess),
            systemSleep: IOPMSystemSleeper(subprocess: realSubprocess),
            shutdown: LoginWindowShutdownRequester(),
            displaySleep: PmsetDisplaySleeper(subprocess: realSubprocess),
            signaller: AuditTokenSignaller(),
            // Only inside the app bundle (UserNotifications needs a bundle id); the bare executable has none.
            localNotifications: UserNotificationCenterPoster.makeIfAvailable(bundle: Bundle(url: bundleURL) ?? .main, logger: logger(.notify))
                ?? UnavailableLocalNotifications(),
            // Only when the bundle is signed for iCloud (an ad-hoc or unprovisioned build is not).
            cloud: CloudKitStore.makeIfEntitled(),
            subprocess: realSubprocess,
            administrator: AppleScriptAdministratorRunner()
        )
        // … gated once.
        let effects = SideEffects.gated(real, gate: gate, ledger: ledger)

        let helpersDirectory: URL? = bundleURL.pathExtension == "app"
            ? bundleURL.appending(path: "Contents/Helpers", directoryHint: .isDirectory)
            : nil
        let hookHelper = helpersDirectory?.appending(path: KakurenekoID.hookExecutableName, directoryHint: .notDirectory)
        let guardHelper = helpersDirectory?.appending(path: KakurenekoID.guardExecutableName, directoryHint: .notDirectory)

        let matcher = AgentMatcher(paths: paths)
        let lookup = LiveProcessLookup()
        // Rule 8: developer lid simulation, nil unless the ENVIRONMENT forces dry-run.
        let lidSimulation = LidSimulation.fromEnvironment(environment)
        let power = PowerController(
            paths: paths,
            privileged: effects.privileged,
            systemSleep: effects.systemSleep,
            shutdown: effects.shutdown,
            displaySleep: effects.displaySleep,
            dryRun: gate,
            clock: clock,
            logger: logger(.power),
            ledger: ledger,
            lidSimulation: lidSimulation
        )

        return KakurenekoServices(
            paths: paths,
            clock: clock,
            dryRun: gate,
            ledger: ledger,
            logSink: sink,
            events: EventInbox(paths: paths, matcher: matcher, clock: clock, logger: logger(.events)),
            processes: ProcessScanner(paths: paths, matcher: matcher, clock: clock, logger: logger(.processes)),
            processLookup: lookup,
            claudeState: ClaudeStateWatcher(paths: paths, subprocess: effects.subprocess, processes: lookup, clock: clock, logger: logger(.sessions)),
            sessions: SessionEngine(timers: settings.timers, logger: logger(.sessions),
                                    initialStateVersion: Int(clock.now().timeIntervalSince1970 * 1000),
                                    processes: lookup),
            power: power,
            powerEvents: PowerMonitor(power: power, clock: clock, logger: logger(.power), lidSimulation: lidSimulation),
            safety: SafetyMonitor(logger: logger(.power)),
            privileged: PrivilegedInstaller(
                paths: paths,
                privileged: effects.privileged,
                subprocess: effects.subprocess,
                administrator: effects.administrator,
                clock: clock,
                logger: logger(.power),
                dryRun: gate
            ),
            pausing: PauseManager(
                paths: paths,
                signaller: effects.signaller,
                processes: lookup,
                dryRun: gate,
                guardExecutable: guardHelper,
                clock: clock,
                logger: logger(.pause),
                ledger: ledger
            ),
            notifications: NotificationDispatcher(paths: paths, settings: settings.notifications, localNotifications: effects.localNotifications,
                                                  cloud: effects.cloud, clock: clock, logger: logger(.notify)),
            integrations: IntegrationManager(paths: paths, subprocess: effects.subprocess, dryRun: gate, ledger: ledger, clock: clock, logger: logger(.install)),
            sideEffects: effects,
            bundledHookHelper: hookHelper,
            bundledGuardHelper: guardHelper,
            handlesTerminationSignals: true
        )
    }

    /// The production coordinator.
    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL
    ) -> KakurenekoCoordinator {
        let services = makeLiveServices(environment: environment, bundleURL: bundleURL)
        return KakurenekoCoordinator(services: services)
    }
}
