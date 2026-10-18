import KakurenekoCloud
import Foundation
import Synchronization

/// Recording `LocalNotificationPosting` for tests (never touches `UNUserNotificationCenter`).
///
/// * `post`: records the alert (or throws `postError` once set); `posted` lists them oldest first.
/// * `requestAuthorization`: answers `requestResult` and makes it the current permission.
/// * `tap(_:)`: simulates a button tap on a Mac notification (emitted on `buttonTaps()`; taps before the first
///   subscription are held for it, like the live poster's).
public final class RecordingLocalNotifications: LocalNotificationPosting {
    private struct State {
        var posted: [CloudAlert] = []
        var authorization: MacAlertAuthorization
        var timeSensitive: Bool?
        var requestResult: MacAlertAuthorization = .authorized
        var requests = 0
        var categoryRegistrations: [Int] = []
        var postError: (any Error & Sendable)?
        var remoteAlertRemovals = 0
        var subscribed = false
        var earlyTaps: [AlertPresentation.ButtonTap] = []
    }
    private let state: Mutex<State>
    private let taps = AsyncBroadcaster<AlertPresentation.ButtonTap>()

    public init(authorization: MacAlertAuthorization = .authorized, timeSensitive: Bool? = true) {
        state = Mutex(State(authorization: authorization, timeSensitive: timeSensitive))
    }

    public var posted: [CloudAlert] { state.withLock { $0.posted } }
    public var authorizationRequests: Int { state.withLock { $0.requests } }
    /// `keepAwakeSeconds` of every `registerCategories` call.
    public var categoryRegistrations: [Int] { state.withLock { $0.categoryRegistrations } }
    /// `removeRemoteAlerts` calls.
    public var remoteAlertRemovals: Int { state.withLock { $0.remoteAlertRemovals } }
    public func setAuthorization(_ value: MacAlertAuthorization) { state.withLock { $0.authorization = value } }
    public func setRequestResult(_ value: MacAlertAuthorization) { state.withLock { $0.requestResult = value } }
    public func setPostError(_ error: (any Error & Sendable)?) { state.withLock { $0.postError = error } }
    public func tap(_ tap: AlertPresentation.ButtonTap) {
        let now = state.withLock { s -> Bool in
            if !s.subscribed { s.earlyTaps.append(tap) }
            return s.subscribed
        }
        if now { taps.yield(tap) }
    }

    public func authorization() async -> (MacAlertAuthorization, timeSensitive: Bool?) {
        state.withLock { ($0.authorization, $0.timeSensitive) }
    }

    public func requestAuthorization() async -> MacAlertAuthorization {
        state.withLock { s in
            s.requests += 1
            if s.authorization == .notDetermined { s.authorization = s.requestResult }
            return s.authorization
        }
    }

    public func registerCategories(keepAwakeSeconds: Int) async {
        state.withLock { $0.categoryRegistrations.append(keepAwakeSeconds) }
    }

    public func post(_ alert: CloudAlert) async throws {
        let error = state.withLock { s -> (any Error & Sendable)? in
            if s.postError == nil { s.posted.append(alert) }
            return s.postError
        }
        if let error { throw error }
    }

    public func buttonTaps() -> AsyncStream<AlertPresentation.ButtonTap> {
        let stream = taps.stream()
        let early = state.withLock { s -> [AlertPresentation.ButtonTap] in
            s.subscribed = true
            defer { s.earlyTaps = [] }
            return s.earlyTaps
        }
        for tap in early { taps.yield(tap) }
        return stream
    }

    public func removeRemoteAlerts() async { state.withLock { $0.remoteAlertRemovals += 1 } }
}

/// Scriptable `SubprocessRunning` for tests. Records every request; answers with `handler(request)`
/// (default: exit 0, empty output). Never spawns anything.
public final class FakeSubprocessRunner: SubprocessRunning {
    public typealias Handler = @Sendable (SubprocessRequest) throws -> SubprocessResult
    private struct State { var requests: [SubprocessRequest] = []; var handler: Handler }
    private let state: Mutex<State>

    public init(handler: Handler? = nil) {
        state = Mutex(State(handler: handler ?? { _ in SubprocessResult(exitCode: 0) }))
    }

    public func setHandler(_ handler: @escaping Handler) { state.withLock { $0.handler = handler } }
    public var requests: [SubprocessRequest] { state.withLock { $0.requests } }

    public func run(_ request: SubprocessRequest) async throws -> SubprocessResult {
        let handler = state.withLock { s -> Handler in
            s.requests.append(request)
            return s.handler
        }
        return try handler(request)
    }
}

/// `ProcessLookup` backed by a dictionary (tests).
public final class StaticProcessLookup: ProcessLookup {
    private let table: Mutex<[Int32: ProcessIdentity]>

    public init(_ identities: [ProcessIdentity] = []) {
        table = Mutex(Dictionary(identities.map { ($0.pid, $0) }, uniquingKeysWith: { _, b in b }))
    }

    public func identity(of pid: Int32) -> ProcessIdentity? { table.withLock { $0[pid] } }
    public func set(_ identity: ProcessIdentity) { table.withLock { $0[identity.pid] = identity } }
    public func remove(pid: Int32) { _ = table.withLock { $0.removeValue(forKey: pid) } }
}

extension SideEffects {
    /// Fully inert side effects for tests: every mutation goes to `ledger`; read-only subprocess / iCloud calls
    /// go to the given fakes (no iCloud unless `cloud` is passed).
    public static func inert(
        ledger: DryRunLedger = DryRunLedger(),
        subprocess: FakeSubprocessRunner = FakeSubprocessRunner(),
        cloud: (any CloudStore)? = nil
    ) -> SideEffects {
        .dryRun(ledger: ledger, subprocess: subprocess, cloud: cloud)
    }
}
