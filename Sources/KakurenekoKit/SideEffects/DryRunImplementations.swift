import KakurenekoCloud
import Foundation

// Dry-run / switching implementations of every side-effect protocol.
//
// Each type takes an optional `passthrough` (the real implementation), the shared `DryRunGate` and the
// `DryRunLedger`:
//   * passthrough == nil         → logs "would …" and returns a synthetic success (pure dry-run).
//   * passthrough != nil, gate on  → logs "would …" and returns a synthetic success.
//   * passthrough != nil, gate off → forwards to the real implementation.
// Read-only operations (health checks, GET requests, `.readOnly` subprocesses, priority reads) always
// forward to the passthrough when one exists.

/// `sudo -n pmset …`
public struct DryRunPrivilegedCommandRunner: PrivilegedCommandRunning {
    public let passthrough: (any PrivilegedCommandRunning)?
    public let gate: DryRunGate
    public let ledger: DryRunLedger

    public init(passthrough: (any PrivilegedCommandRunning)? = nil, gate: DryRunGate, ledger: DryRunLedger) {
        self.passthrough = passthrough
        self.gate = gate
        self.ledger = ledger
    }

    public func run(_ command: PrivilegedCommand) async throws -> SubprocessResult {
        if let passthrough, command.effect == .readOnly || !gate.isOn {
            return try await passthrough.run(command)
        }
        switch command {
        case .setSleepDisabled(let on):
            ledger.record(.power, action: on ? "power.arm" : "power.disarm",
                          detail: "would run \(command.argv.joined(separator: " "))")
            return SubprocessResult(exitCode: 0)
        case .checkSudoRule:
            // Pure dry-run cannot know; report "not installed" (conservative).
            return SubprocessResult(exitCode: 1, stderr: Data("dry-run: sudo rule not checked".utf8))
        }
    }
}

/// `IOPMSleepSystem`
public struct DryRunSystemSleeper: SystemSleeping {
    public let passthrough: (any SystemSleeping)?
    public let gate: DryRunGate
    public let ledger: DryRunLedger

    public init(passthrough: (any SystemSleeping)? = nil, gate: DryRunGate, ledger: DryRunLedger) {
        self.passthrough = passthrough
        self.gate = gate
        self.ledger = ledger
    }

    public func sleepNow() async throws {
        if let passthrough, !gate.isOn { return try await passthrough.sleepNow() }
        ledger.record(.power, action: "power.sleep", detail: "would put the Mac to sleep now (IOPMSleepSystem)")
    }

    public func scheduleDetachedSleep(after delay: Duration) throws {
        if let passthrough, !gate.isOn { return try passthrough.scheduleDetachedSleep(after: delay) }
        ledger.record(.power, action: "power.scheduleSleep",
                      detail: "would leave a helper that sleeps the Mac in \(delay.components.seconds) s if the lid is closed")
    }
}

/// Apple Event shutdown
public struct DryRunShutdownRequester: ShutdownRequesting {
    public let passthrough: (any ShutdownRequesting)?
    public let gate: DryRunGate
    public let ledger: DryRunLedger

    public init(passthrough: (any ShutdownRequesting)? = nil, gate: DryRunGate, ledger: DryRunLedger) {
        self.passthrough = passthrough
        self.gate = gate
        self.ledger = ledger
    }

    public func requestShutdown() async throws {
        if let passthrough, !gate.isOn { return try await passthrough.requestShutdown() }
        ledger.record(.power, action: "power.shutdown", detail: "would ask loginwindow to shut down")
    }
}

/// `pmset displaysleepnow`
public struct DryRunDisplaySleeper: DisplaySleeping {
    public let passthrough: (any DisplaySleeping)?
    public let gate: DryRunGate
    public let ledger: DryRunLedger

    public init(passthrough: (any DisplaySleeping)? = nil, gate: DryRunGate, ledger: DryRunLedger) {
        self.passthrough = passthrough
        self.gate = gate
        self.ledger = ledger
    }

    public func displaySleepNow() async throws {
        if let passthrough, !gate.isOn { return try await passthrough.displaySleepNow() }
        ledger.record(.power, action: "power.displaySleep", detail: "would turn the built-in display off (pmset displaysleepnow)")
    }
}

/// SIGSTOP/SIGCONT, setpriority, terminate
public struct DryRunProcessSignaller: ProcessSignalling {
    public let passthrough: (any ProcessSignalling)?
    public let gate: DryRunGate
    public let ledger: DryRunLedger

    public init(passthrough: (any ProcessSignalling)? = nil, gate: DryRunGate, ledger: DryRunLedger) {
        self.passthrough = passthrough
        self.gate = gate
        self.ledger = ledger
    }

    /// Pausing calls refuse un-enriched identities in dry-run too (same contract as the real signaller), so a
    /// dry-run session catches a missing enrichment exactly like a real one would.
    private func requireEnriched(_ target: ProcessIdentity) throws {
        guard target.pidVersion != nil, target.uniqueID != nil else { throw SideEffectError.identityMismatch }
    }

    public func send(_ signal: ProcessSignalKind, to target: ProcessIdentity) throws {
        if signal == .stop { try requireEnriched(target) }
        if let passthrough, !gate.isOn { return try passthrough.send(signal, to: target) }
        ledger.record(.pause, action: signal == .stop ? "signal.stop" : "signal.cont",
                      detail: "would \(signal == .stop ? "freeze (SIGSTOP)" : "thaw (SIGCONT)") pid \(target.pid)")
    }

    public func setDarwinBackground(_ enabled: Bool, for target: ProcessIdentity) throws {
        if enabled { try requireEnriched(target) }
        if let passthrough, !gate.isOn { return try passthrough.setDarwinBackground(enabled, for: target) }
        ledger.record(.pause, action: enabled ? "priority.background" : "priority.normal",
                      detail: enabled ? "would throttle pid \(target.pid)" : "would unthrottle pid \(target.pid)")
    }

    public func isDarwinBackground(_ target: ProcessIdentity) -> Bool? {
        passthrough?.isDarwinBackground(target)
    }

    public func terminateApplication(_ target: ProcessIdentity) async throws {
        if let passthrough, !gate.isOn { return try await passthrough.terminateApplication(target) }
        ledger.record(.pause, action: "app.terminate", detail: "would quit app pid \(target.pid)")
    }

    public func relaunchApplication(at bundleURL: URL) async throws {
        if let passthrough, !gate.isOn { return try await passthrough.relaunchApplication(at: bundleURL) }
        ledger.record(.pause, action: "app.relaunch", detail: "would relaunch \(bundleURL.deletingPathExtension().lastPathComponent) (not activated)")
    }
}

/// Admin prompt
public struct DryRunAdministratorScriptRunner: AdministratorScriptRunning {
    public let passthrough: (any AdministratorScriptRunning)?
    public let gate: DryRunGate
    public let ledger: DryRunLedger

    public init(passthrough: (any AdministratorScriptRunning)? = nil, gate: DryRunGate, ledger: DryRunLedger) {
        self.passthrough = passthrough
        self.gate = gate
        self.ledger = ledger
    }

    public func runAsAdministrator(script: String, name: String, arguments: [String]) async throws -> String {
        if let passthrough, !gate.isOn {
            return try await passthrough.runAsAdministrator(script: script, name: name, arguments: arguments)
        }
        ledger.record(.power, action: "admin.script", detail: "would run \(name) with administrator privileges")
        return ""
    }
}

/// Mac notifications: permission reads and category registration pass through; posting and the permission prompt
/// are logged instead (the title only — bodies may quote agent output). Without a real poster (tests, pure
/// dry-run) the permission reads `.unavailable` and no button taps ever arrive.
public struct DryRunLocalNotificationPoster: LocalNotificationPosting {
    public let passthrough: (any LocalNotificationPosting)?
    public let gate: DryRunGate
    public let ledger: DryRunLedger

    public init(passthrough: (any LocalNotificationPosting)? = nil, gate: DryRunGate, ledger: DryRunLedger) {
        self.passthrough = passthrough
        self.gate = gate
        self.ledger = ledger
    }

    public func authorization() async -> (MacAlertAuthorization, timeSensitive: Bool?) {
        await passthrough?.authorization() ?? (.unavailable, nil)
    }

    public func requestAuthorization() async -> MacAlertAuthorization {
        if let passthrough, !gate.isOn { return await passthrough.requestAuthorization() }
        ledger.record(.notify, action: "notify.authorize", detail: "would ask for permission to show notifications")
        return await authorization().0
    }

    public func registerCategories(keepAwakeSeconds: Int) async {
        await passthrough?.registerCategories(keepAwakeSeconds: keepAwakeSeconds)
    }

    public func post(_ alert: CloudAlert) async throws {
        if let passthrough, !gate.isOn { return try await passthrough.post(alert) }
        ledger.record(.notify, action: "notify.post", detail: "would show the notification \"\(alert.title)\"")
    }

    public func buttonTaps() -> AsyncStream<AlertPresentation.ButtonTap> {
        passthrough?.buttonTaps() ?? AsyncStream { $0.finish() }
    }

    /// Clearing other Macs' notifications from this Mac's list is harmless and passes through.
    public func removeRemoteAlerts() async {
        await passthrough?.removeRemoteAlerts()
    }
}

/// Mac notifications where `UNUserNotificationCenter` cannot work (no app bundle): permission `.unavailable`,
/// posts are dropped, no taps.
public struct UnavailableLocalNotifications: LocalNotificationPosting {
    public init() {}
    public func authorization() async -> (MacAlertAuthorization, timeSensitive: Bool?) { (.unavailable, nil) }
    public func requestAuthorization() async -> MacAlertAuthorization { .unavailable }
    public func registerCategories(keepAwakeSeconds: Int) async {}
    public func post(_ alert: CloudAlert) async throws {}
    public func buttonTaps() -> AsyncStream<AlertPresentation.ButtonTap> { AsyncStream { $0.finish() } }
    public func removeRemoteAlerts() async {}
}

/// iCloud: reads (account status, change fetches, record fetches) pass through; every write (zone, records,
/// deletions, subscriptions) is logged instead. Without a real store (this build has no iCloud entitlement, or
/// tests) reads report `.unavailableInThisBuild` and return nothing.
public struct DryRunCloudStore: CloudStore {
    public let passthrough: (any CloudStore)?
    public let gate: DryRunGate
    public let ledger: DryRunLedger

    public init(passthrough: (any CloudStore)? = nil, gate: DryRunGate, ledger: DryRunLedger) {
        self.passthrough = passthrough
        self.gate = gate
        self.ledger = ledger
    }

    public func accountStatus() async -> CloudAccountStatus {
        await passthrough?.accountStatus() ?? .unavailableInThisBuild
    }

    public func prepare() async throws(CloudError) {
        if let passthrough, !gate.isOn { return try await passthrough.prepare() }
        ledger.record(.notify, action: "cloud.prepare", detail: "would prepare Kakureneko's iCloud records")
    }

    public func save(_ items: [CloudItem]) async throws(CloudError) {
        if let passthrough, !gate.isOn { return try await passthrough.save(items) }
        let types = items.map(\.id.recordType).joined(separator: ", ")
        ledger.record(.notify, action: "cloud.save", detail: "would save \(items.count) iCloud record(s) (\(types))")
    }

    public func delete(_ ids: [CloudItemID]) async throws(CloudError) {
        if let passthrough, !gate.isOn { return try await passthrough.delete(ids) }
        ledger.record(.notify, action: "cloud.delete", detail: "would delete \(ids.count) iCloud record(s)")
    }

    public func fetchAll(_ recordType: String) async throws(CloudError) -> [CloudItem] {
        guard let passthrough else { return [] }
        do {
            return try await passthrough.fetchAll(recordType)
        } catch .zoneMissing where gate.isOn {
            return [] // as `fetchChanges`: what dry-run only pretended to prepare holds nothing yet
        }
    }

    public func deleteOwned(_ recordType: String, modifiedBefore cutoff: Date) async throws(CloudError) -> Int {
        if let passthrough, !gate.isOn { return try await passthrough.deleteOwned(recordType, modifiedBefore: cutoff) }
        ledger.record(.notify, action: "cloud.prune", detail: "would delete old \(recordType) records from iCloud")
        return 0
    }

    public func resetIdentity() async {
        await passthrough?.resetIdentity()
    }

    public func accountTag() async throws(CloudError) -> String {
        guard let passthrough else { throw .notSignedIn }
        return try await passthrough.accountTag()
    }

    public func fetchChanges(since token: CloudChangeToken?, types: [String]) async throws(CloudError) -> CloudChangeBatch {
        guard let passthrough else { return CloudChangeBatch(token: token) }
        do {
            return try await passthrough.fetchChanges(since: token, types: types)
        } catch .zoneMissing where gate.isOn {
            // `prepare` was only logged: what dry-run pretends to have prepared has no changes yet (reporting it
            // missing would send the caller back to set it up again, over and over).
            return CloudChangeBatch(token: token)
        }
    }

    public func fetch(_ id: CloudItemID) async throws(CloudError) -> CloudItem? {
        try await passthrough?.fetch(id)
    }

    public func saveSubscription(_ subscription: CloudSubscription) async throws(CloudError) {
        if let passthrough, !gate.isOn { return try await passthrough.saveSubscription(subscription) }
        ledger.record(.notify, action: "cloud.subscribe", detail: "would create the iCloud subscription(s) \(subscription.subscriptionIDs.joined(separator: ", "))")
    }
}

/// Subprocess: `.readOnly` requests pass through; `.mutating` ones are logged and answered with exit 0.
public struct DryRunSubprocessRunner: SubprocessRunning {
    public let passthrough: (any SubprocessRunning)?
    public let gate: DryRunGate
    public let ledger: DryRunLedger

    public init(passthrough: (any SubprocessRunning)? = nil, gate: DryRunGate, ledger: DryRunLedger) {
        self.passthrough = passthrough
        self.gate = gate
        self.ledger = ledger
    }

    public func run(_ request: SubprocessRequest) async throws -> SubprocessResult {
        if let passthrough, request.effect == .readOnly || !gate.isOn {
            return try await passthrough.run(request)
        }
        if request.effect == .readOnly {
            // Pure dry-run without a real runner: nothing to read.
            return SubprocessResult(exitCode: 127, stderr: Data("dry-run: no subprocess runner".utf8))
        }
        ledger.record(.app, action: "subprocess.run", detail: "would run \(request.displayString)")
        return SubprocessResult(exitCode: 0)
    }
}
