import Foundation

/// The composition root's input: every service the coordinator composes, as Kit protocols.
///
/// * Production: built by `KakurenekoCoordinator.makeLiveServices(…)` from the concrete module types.
/// * Coordinator tests: `KakurenekoServices.fakes(…)` (Kit/Testing) or hand-built with fakes.
///
/// The coordinator never instantiates a module type except inside its `live` factory, so swapping any
/// service for a fake requires no code change.
public struct KakurenekoServices: Sendable {
    public var paths: Paths
    public var clock: any KakurenekoClock
    public var dryRun: DryRunGate
    public var ledger: DryRunLedger
    /// Optional file sink shared by every service logger.
    public var logSink: FileLogSink?

    public var events: any AgentEventSource
    public var processes: any ProcessSampling
    public var processLookup: any ProcessLookup
    public var claudeState: any ClaudeStateSource
    public var sessions: any SessionTracking
    public var power: any PowerControlling
    public var powerEvents: any PowerEventSource
    public var safety: any SafetyEvaluating
    public var privileged: any PrivilegedInstalling
    public var pausing: any AppPausing
    public var notifications: any NotificationDispatching
    public var integrations: any AgentIntegrating

    /// The side effects the services were built with (already dry-run gated). Exposed for diagnostics/tests.
    public var sideEffects: SideEffects

    /// Location of the bundled hook helper to deploy (`Kakureneko.app/Contents/Helpers/kakureneko-hook`);
    /// nil when not running from a bundle (e.g. `swift run`), in which case deployment is skipped.
    public var bundledHookHelper: URL?
    /// Location of the bundled guard (`Kakureneko.app/Contents/Helpers/kakureneko-guard`); nil outside a bundle.
    public var bundledGuardHelper: URL?
    /// Whether `KakurenekoCoordinator.start()` installs the SIGTERM/INT/HUP/QUIT dispatch sources (sync thaw →
    /// sync disarm → exit). `LiveComposition` sets true; tests keep false (never hijack the test runner's signals).
    public var handlesTerminationSignals: Bool

    public init(
        paths: Paths,
        clock: any KakurenekoClock,
        dryRun: DryRunGate,
        ledger: DryRunLedger,
        logSink: FileLogSink? = nil,
        events: any AgentEventSource,
        processes: any ProcessSampling,
        processLookup: any ProcessLookup,
        claudeState: any ClaudeStateSource,
        sessions: any SessionTracking,
        power: any PowerControlling,
        powerEvents: any PowerEventSource,
        safety: any SafetyEvaluating,
        privileged: any PrivilegedInstalling,
        pausing: any AppPausing,
        notifications: any NotificationDispatching,
        integrations: any AgentIntegrating,
        sideEffects: SideEffects,
        bundledHookHelper: URL? = nil,
        bundledGuardHelper: URL? = nil,
        handlesTerminationSignals: Bool = false
    ) {
        self.paths = paths
        self.clock = clock
        self.dryRun = dryRun
        self.ledger = ledger
        self.logSink = logSink
        self.events = events
        self.processes = processes
        self.processLookup = processLookup
        self.claudeState = claudeState
        self.sessions = sessions
        self.power = power
        self.powerEvents = powerEvents
        self.safety = safety
        self.privileged = privileged
        self.pausing = pausing
        self.notifications = notifications
        self.integrations = integrations
        self.sideEffects = sideEffects
        self.bundledHookHelper = bundledHookHelper
        self.bundledGuardHelper = bundledGuardHelper
        self.handlesTerminationSignals = handlesTerminationSignals
    }

    /// A logger for `category` sharing this composition's file sink.
    public func logger(_ category: LogCategory) -> KakurenekoLogger { KakurenekoLogger(category, sink: logSink) }
}
