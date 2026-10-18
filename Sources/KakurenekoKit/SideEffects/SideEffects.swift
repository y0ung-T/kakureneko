import KakurenekoCloud
import Foundation

/// The complete set of system-mutating capabilities. Services receive the members they need in their
/// initializers; nothing else in the codebase may mutate the system.
///
/// Production wiring (KakurenekoCoordinator): build the real set from KakurenekoPower/KakurenekoPause/KakurenekoNotify types
/// + `CloudKitStore` + `FoundationSubprocessRunner`, then wrap it with `SideEffects.gated(…)` so every call consults
/// the `DryRunGate` (env `KAKURENEKO_DRY_RUN=1` or the settings toggle).
public struct SideEffects: Sendable {
    public var privileged: any PrivilegedCommandRunning
    public var systemSleep: any SystemSleeping
    public var shutdown: any ShutdownRequesting
    public var displaySleep: any DisplaySleeping
    public var signaller: any ProcessSignalling
    /// macOS notifications (Kakureneko's own).
    public var localNotifications: any LocalNotificationPosting
    /// The app's CloudKit public database (records readable only by their creator, D12); nil when this build is
    /// not signed for iCloud.
    public var cloud: (any CloudStore)?
    public var subprocess: any SubprocessRunning
    public var administrator: any AdministratorScriptRunning

    public init(
        privileged: any PrivilegedCommandRunning,
        systemSleep: any SystemSleeping,
        shutdown: any ShutdownRequesting,
        displaySleep: any DisplaySleeping,
        signaller: any ProcessSignalling,
        localNotifications: any LocalNotificationPosting,
        cloud: (any CloudStore)?,
        subprocess: any SubprocessRunning,
        administrator: any AdministratorScriptRunning
    ) {
        self.privileged = privileged
        self.systemSleep = systemSleep
        self.shutdown = shutdown
        self.displaySleep = displaySleep
        self.signaller = signaller
        self.localNotifications = localNotifications
        self.cloud = cloud
        self.subprocess = subprocess
        self.administrator = administrator
    }

    /// Wraps every member of `real` in its dry-run switch (forward when the gate is off; log when on).
    public static func gated(_ real: SideEffects, gate: DryRunGate, ledger: DryRunLedger) -> SideEffects {
        SideEffects(
            privileged: DryRunPrivilegedCommandRunner(passthrough: real.privileged, gate: gate, ledger: ledger),
            systemSleep: DryRunSystemSleeper(passthrough: real.systemSleep, gate: gate, ledger: ledger),
            shutdown: DryRunShutdownRequester(passthrough: real.shutdown, gate: gate, ledger: ledger),
            displaySleep: DryRunDisplaySleeper(passthrough: real.displaySleep, gate: gate, ledger: ledger),
            signaller: DryRunProcessSignaller(passthrough: real.signaller, gate: gate, ledger: ledger),
            localNotifications: DryRunLocalNotificationPoster(passthrough: real.localNotifications, gate: gate, ledger: ledger),
            cloud: real.cloud.map { DryRunCloudStore(passthrough: $0, gate: gate, ledger: ledger) },
            subprocess: DryRunSubprocessRunner(passthrough: real.subprocess, gate: gate, ledger: ledger),
            administrator: DryRunAdministratorScriptRunner(passthrough: real.administrator, gate: gate, ledger: ledger)
        )
    }

    /// Pure dry-run: every mutation is only logged. Read-only subprocess / iCloud calls go to `subprocess` / `cloud`
    /// when provided (tests pass `FakeSubprocessRunner` / `InMemoryCloudStore`), otherwise they fail softly.
    public static func dryRun(
        ledger: DryRunLedger,
        subprocess: (any SubprocessRunning)? = nil,
        cloud: (any CloudStore)? = nil
    ) -> SideEffects {
        let gate = DryRunGate.alwaysOn()
        return SideEffects(
            privileged: DryRunPrivilegedCommandRunner(gate: gate, ledger: ledger),
            systemSleep: DryRunSystemSleeper(gate: gate, ledger: ledger),
            shutdown: DryRunShutdownRequester(gate: gate, ledger: ledger),
            displaySleep: DryRunDisplaySleeper(gate: gate, ledger: ledger),
            signaller: DryRunProcessSignaller(gate: gate, ledger: ledger),
            localNotifications: DryRunLocalNotificationPoster(gate: gate, ledger: ledger),
            cloud: cloud.map { DryRunCloudStore(passthrough: $0, gate: gate, ledger: ledger) },
            subprocess: DryRunSubprocessRunner(passthrough: subprocess, gate: gate, ledger: ledger),
            administrator: DryRunAdministratorScriptRunner(gate: gate, ledger: ledger)
        )
    }
}
