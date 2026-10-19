import KakurenekoCloud
@testable import KakurenekoNotify
import KakurenekoKit
import Foundation
import Synchronization
import Testing

// Shared fixtures for the KakurenekoNotify tests. iCloud: InMemoryCloudStore only (never CloudKit); Mac notifications:
// RecordingLocalNotifications (never UNUserNotificationCenter). Time: TestClock (default start 2026-10-12T22:00:00Z)
// and a UTC template time zone.

enum Fixtures {
    static let utc = TimeZone(identifier: "UTC")!
    static let start = TestClock.defaultStart
    static let identity = MacIdentity(name: "Studio", model: "MacBook Pro (16-inch, 2021)", appVersion: "1.0 (7)")
    /// The iPhone only while the user is away from the Mac, and no Mac notifications: the iPhone is the only
    /// channel, so presence decides whether a message goes at all.
    static var phoneWhenAway: NotificationSettings {
        var settings = NotificationSettings()
        settings.phoneTiming = .away
        settings.macAlerts = false
        return settings
    }
    static let preview = "Refactored the parser; all 42 tests pass."
    /// The iPhone the harness connects by default (`Harness(phone:)`).
    static let phone = PhoneDevice(deviceID: "phone-default", name: "iPhone", model: "iPhone18,3", systemVersion: "26.6",
                                   appVersion: "1.0", alertsAuthorized: true, timeSensitiveAllowed: true, lastSeenAt: start)

    static func at(_ hour: Int, _ minute: Int, dayOffset: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let base = calendar.startOfDay(for: start)
        return base.addingTimeInterval(TimeInterval(dayOffset * 86_400 + hour * 3600 + minute * 60))
    }

    static func claude(state: SessionState? = nil, preview: String? = Fixtures.preview, remoteControl: Bool = false,
                       id: String = "c-1", cwd: String = "/Users/me/src/api") -> AgentSession {
        AgentSession(
            key: SessionKey(agent: .claude, id: id), host: HostApp(bundleID: "com.googlecode.iterm2", name: "iTerm2"),
            cwd: cwd, state: state ?? .idle(since: start, outcome: .completed), turnStartedAt: start.addingTimeInterval(-2520),
            lastProgressAt: at(21, 40), tiers: [.hook], lastMessagePreview: preview, remoteControlConnected: remoteControl)
    }

    static func codex(waiting since: Date = at(21, 50), waitingFor: String? = "Codex needs your permission to run npm install",
                      id: String = "x-1") -> AgentSession {
        AgentSession(
            key: SessionKey(agent: .codex, id: id), host: HostApp(bundleID: "com.apple.Terminal", name: "Terminal"),
            cwd: "/Users/me/src/web", state: .waiting(kind: .permission, since: since), tiers: [.hook],
            waitingFor: waitingFor)
    }

    static func aider() -> AgentSession {
        AgentSession(key: SessionKey(agent: .aider, id: "pid:4242:1791840000.000001"), cwd: "/Users/me/src/proj",
                     state: .idle(since: start, outcome: nil), tiers: [.heuristic])
    }

    static func finished(_ session: AgentSession = claude(), workedFor: TimeInterval? = 2520, at: Date = start,
                         outcome: TurnOutcome = .completed) -> SessionEffect {
        SessionEffect(kind: .finished, session: session, at: at, outcome: outcome, workedFor: workedFor)
    }

    static func needsInput(_ session: AgentSession = codex(), at: Date = at(21, 50)) -> SessionEffect {
        SessionEffect(kind: .needsInput, session: session, at: at, needsInputKind: .permission)
    }

    static func context(_ now: Date = start, presence: Presence = .away, sv: Int = 42, keepAwake: Int = 3600) -> NotificationContext {
        NotificationContext(now: now, presence: presence, stateVersion: sv, keepAwakeSeconds: keepAwake)
    }

    static func templateContext(_ detail: DetailLevel = .basic, now: Date = start, sv: Int = 42) -> TemplateContext {
        TemplateContext(detail: detail, now: now, timeZone: utc, stateVersion: sv, keepAwakeSeconds: 3600)
    }

    static func environment(path: ManualPathMonitor) -> NotifyEnvironment {
        var e = NotifyEnvironment()
        e.timeZone = utc
        e.random = { $0.lowerBound }
        e.makePathMonitor = { path }
        e.identity = { identity }
        return e
    }
}

/// A dispatcher on a temp home with an in-memory iCloud, recording Mac notifications, a test clock and a manual
/// path monitor.
final class Harness: Sendable {
    let paths: Paths
    let clock: TestClock
    /// The iCloud the dispatcher talks to (nil = this build has no iCloud).
    let cloud: InMemoryCloudStore?
    let local: RecordingLocalNotifications
    let pathMonitor: ManualPathMonitor
    let dispatcher: NotificationDispatcher
    let logURL: URL
    let settings: NotificationSettings
    let environment: NotifyEnvironment

    /// `store` replaces `cloud` as the dispatcher's iCloud (e.g. a dry-run gate or a `SuspendingCloudStore` in front
    /// of it); `noCloud` builds without iCloud. `phone`: an iPhone already checked in (its record in a fresh home
    /// and the default iCloud), as alerts only go to iCloud once one did.
    init(settings: NotificationSettings = NotificationSettings(), paths: Paths? = nil, clock: TestClock? = nil,
         cloud: InMemoryCloudStore? = nil, store: (any CloudStore)? = nil, noCloud: Bool = false,
         local: RecordingLocalNotifications? = nil, online: Bool = true, phone: Bool = true,
         configure: (inout NotifyEnvironment) -> Void = { _ in }) throws {
        let freshHome = paths == nil
        let paths = try paths ?? Paths.temporary()
        self.paths = paths
        let testClock = clock ?? TestClock()
        self.clock = testClock
        let seed: [CloudItem] = phone ? [.device(Fixtures.phone)] : []
        self.cloud = noCloud ? nil : (cloud ?? InMemoryCloudStore(seed: seed, now: { testClock.now() }))
        if phone && freshHome && !noCloud {
            let store = NotifyStore(paths: paths)
            var state = store.loadState()
            state.phones = [Fixtures.phone.deviceID: Fixtures.phone]
            try store.saveState(state)
        }
        self.local = local ?? RecordingLocalNotifications()
        self.pathMonitor = ManualPathMonitor(initial: online)
        self.settings = settings
        self.logURL = paths.home.deletingLastPathComponent().appending(path: "notify-test.log")
        let logger = KakurenekoLogger(.notify, sink: FileLogSink(url: logURL, minimumLevel: .debug))
        var environment = Fixtures.environment(path: pathMonitor)
        configure(&environment)
        self.environment = environment
        self.dispatcher = NotificationDispatcher(
            paths: paths, settings: settings, localNotifications: self.local, cloud: noCloud ? nil : (store ?? self.cloud),
            clock: self.clock, logger: logger, environment: environment)
    }

    /// A second dispatcher on the same home and iCloud (a relaunch).
    func relaunch(settings: NotificationSettings? = nil) -> NotificationDispatcher {
        NotificationDispatcher(
            paths: paths, settings: settings ?? self.settings, localNotifications: local, cloud: cloud, clock: clock,
            logger: KakurenekoLogger(.notify, sink: FileLogSink(url: logURL, minimumLevel: .debug)),
            environment: Fixtures.environment(path: ManualPathMonitor(initial: true)))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent())
    }

    /// `start`, then waits until iCloud is set up (zone + subscription).
    func startReady() async throws {
        await dispatcher.start()
        let ready = await eventually { await self.dispatcher.cloudReadyForTesting }
        try #require(ready)
    }

    /// Alerts saved to iCloud, oldest first (placeholders excluded).
    var saved: [CloudAlert] {
        get async {
            guard let cloud else { return [] }
            return await cloud.items(ofType: CloudSchema.RecordType.alert).compactMap {
                if case .alert(let alert) = $0, !CloudSchemaBootstrap.isPlaceholder($0) { return alert }
                return nil
            }
        }
    }

    var savedTitles: [String] { get async { await saved.map(\.title) } }

    /// Mac notifications shown, oldest first.
    var posted: [CloudAlert] { local.posted }

    /// The Mac status records in iCloud (one per Mac).
    var statuses: [MacStatus] {
        get async {
            guard let cloud else { return [] }
            return await cloud.items(ofType: CloudSchema.RecordType.macStatus).compactMap {
                if case .status(let status) = $0 { return status }
                return nil
            }
        }
    }

    /// Saves a command as the iPhone app would (for this Mac unless `macID` says otherwise).
    @discardableResult
    func phoneCommand(_ request: CloudRequest, sv: Int? = 42, issuedAt: Date? = nil, lifetime: TimeInterval = 600,
                      macID: String? = nil, id: String = UUID().uuidString) async throws -> CloudCommand {
        let mac: String
        if let macID { mac = macID } else { mac = await dispatcher.macIDForTesting }
        let issued = issuedAt ?? clock.now()
        let command = CloudCommand(id: id, macID: mac, request: request, stateVersion: sv, issuedAt: issued,
                                   expiresAt: issued.addingTimeInterval(lifetime), deviceID: "phone-1", deviceName: "iPhone")
        try await #require(cloud).save([.command(command)])
        return command
    }

    var logText: String { (try? String(contentsOf: logURL, encoding: .utf8)) ?? "" }
}

/// Polls `condition` (real time, ≤ `timeout`) — background work hops through actors and tasks.
@discardableResult
/// Positive waits only (returns as soon as `condition` holds); the generous default absorbs a busy machine.
func eventually(timeout: Duration = .seconds(10), _ condition: () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}

/// Lets queued tasks run (used before asserting that something did NOT happen).
func settle() async {
    for _ in 0..<50 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(40))
    for _ in 0..<50 { await Task.yield() }
}

/// Advances `clock` in `step`s (at most `limit` in total) until `condition` holds; after the last step it waits up to
/// 10 s of wall time. Returns the virtual time elapsed when it was observed, or nil. Use it only for "eventually
/// happens" checks: under load a step's short observation window can pass before the work it triggered ran, so the
/// returned time may be LATER than the instant it happened — exact-instant checks use `happensAt`.
func advance(_ clock: TestClock, step: Duration = .seconds(1), limit: Duration,
             until condition: () async -> Bool) async -> TimeInterval? {
    let start = clock.now()
    var elapsed: Duration = .zero
    while elapsed < limit {
        clock.advance(by: step)
        elapsed += step
        if await eventually(timeout: .milliseconds(25), condition) {
            return clock.now().timeIntervalSince(start)
        }
    }
    if await eventually(timeout: .seconds(10), condition) { return clock.now().timeIntervalSince(start) }
    return nil
}

/// Deterministic "happens exactly `expected` after now" check that does not depend on how quickly the dispatcher's
/// tasks get the CPU: advances in `step`s to `expected − step` (letting each step's due timers run), verifies that
/// `condition` does NOT hold yet, then advances the final step and waits up to `timeout` of WALL time for it. The
/// virtual clock never runs past `expected`, so a slow machine can delay the observation but never change the
/// instant it is attributed to. Returns true when it held at `expected` and not before.
func happensAt(_ clock: TestClock, after expected: Duration, step: Duration = .seconds(1), timeout: Duration = .seconds(10),
               sourceLocation: SourceLocation = #_sourceLocation, _ condition: () async -> Bool) async -> Bool {
    var elapsed: Duration = .zero
    while elapsed + step < expected {
        clock.advance(by: step)
        elapsed += step
        await settle()
    }
    if await condition() {
        Issue.record("happened before \(expected) (at most \(elapsed) after the start)", sourceLocation: sourceLocation)
        return false
    }
    clock.advance(by: expected - elapsed)
    return await eventually(timeout: timeout, condition)
}

/// "Happens no later than `bound` after now": advances in `step`s to `bound` (letting due timers run at each step),
/// then waits up to `timeout` of wall time for `condition`.
func happensBy(_ clock: TestClock, within bound: Duration, step: Duration = .seconds(1), timeout: Duration = .seconds(10),
               _ condition: () async -> Bool) async -> Bool {
    var elapsed: Duration = .zero
    while elapsed < bound {
        if await condition() { return true }
        let next = min(step, bound - elapsed)
        clock.advance(by: next)
        elapsed += next
        await settle()
    }
    return await eventually(timeout: timeout, condition)
}

/// Collects a `remoteCommands()` subscription in the background.
final class CommandCollector: Sendable {
    private final class Store: Sendable {
        let received = Mutex<[RemoteCommand]>([])
        let finished = Mutex(false)
    }
    private let store: Store
    private let task: Task<Void, Never>

    init(_ stream: AsyncStream<RemoteCommand>) {
        let store = Store()
        self.store = store
        task = Task {
            for await command in stream { store.received.withLock { $0.append(command) } }
            store.finished.withLock { $0 = true }
        }
    }

    deinit { task.cancel() }

    var commands: [RemoteCommand] { store.received.withLock { $0 } }
    var kinds: [RemoteCommandKind] { commands.map(\.kind) }
    var isFinished: Bool { store.finished.withLock { $0 } }
}

/// `save` suspends until the test calls `release()` or the saving task is cancelled (a hanging network); every
/// other call goes straight to the wrapped store.
final class SuspendingCloudStore: CloudStore {
    private struct State {
        var nextID: UInt64 = 0
        var waiting: [UInt64: CheckedContinuation<Void, Never>] = [:]
        var cancelledBeforeRegistration: Set<UInt64> = []
        var saveCount = 0
        var cancelledCount = 0
        var suspending = true
    }
    private let state = Mutex(State())
    let wrapped: InMemoryCloudStore
    /// The suspended save keeps hanging when its task is cancelled (only `release()` ends it).
    let ignoresCancellation: Bool

    init(wrapping wrapped: InMemoryCloudStore, ignoresCancellation: Bool = false) {
        self.wrapped = wrapped
        self.ignoresCancellation = ignoresCancellation
    }

    var pendingCount: Int { state.withLock { $0.waiting.count } }
    var saveCount: Int { state.withLock { $0.saveCount } }
    var cancelledCount: Int { state.withLock { $0.cancelledCount } }

    /// Lets every suspended save (and every later one) through to the wrapped store.
    func release() {
        let waiting = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.suspending = false
            defer { s.waiting.removeAll() }
            return Array(s.waiting.values)
        }
        for continuation in waiting { continuation.resume() }
    }

    func save(_ items: [CloudItem]) async throws(CloudError) {
        // Status records are not what these tests hang: they pass straight through.
        guard items.contains(where: { if case .alert = $0 { true } else { false } }) else { return try await wrapped.save(items) }
        let id: UInt64? = state.withLock { s in
            s.saveCount += 1
            guard s.suspending else { return nil }
            s.nextID += 1
            return s.nextID
        }
        if let id {
            var cancelled = false
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let resumeNow: Bool = state.withLock { s in
                        if s.cancelledBeforeRegistration.remove(id) != nil || !s.suspending {
                            return true
                        }
                        s.waiting[id] = continuation
                        return false
                    }
                    if resumeNow { continuation.resume() }
                }
            } onCancel: {
                let continuation: CheckedContinuation<Void, Never>? = state.withLock { s in
                    s.cancelledCount += 1
                    if ignoresCancellation { return nil }
                    if let c = s.waiting.removeValue(forKey: id) { return c }
                    s.cancelledBeforeRegistration.insert(id)
                    return nil
                }
                continuation?.resume()
            }
            cancelled = Task.isCancelled && !ignoresCancellation
            if cancelled { throw .network(retryAfter: nil) }
        }
        try await wrapped.save(items)
    }

    func accountStatus() async -> CloudAccountStatus { await wrapped.accountStatus() }
    func prepare() async throws(CloudError) { try await wrapped.prepare() }
    func delete(_ ids: [CloudItemID]) async throws(CloudError) { try await wrapped.delete(ids) }
    func fetchChanges(since token: CloudChangeToken?, types: [String]) async throws(CloudError) -> CloudChangeBatch {
        try await wrapped.fetchChanges(since: token, types: types)
    }
    func fetchAll(_ recordType: String) async throws(CloudError) -> [CloudItem] { try await wrapped.fetchAll(recordType) }
    func deleteOwned(_ recordType: String, modifiedBefore cutoff: Date) async throws(CloudError) -> Int {
        try await wrapped.deleteOwned(recordType, modifiedBefore: cutoff)
    }
    func resetIdentity() async { await wrapped.resetIdentity() }
    func accountTag() async throws(CloudError) -> String { try await wrapped.accountTag() }
    func fetch(_ id: CloudItemID) async throws(CloudError) -> CloudItem? { try await wrapped.fetch(id) }
    func saveSubscription(_ subscription: CloudSubscription) async throws(CloudError) { try await wrapped.saveSubscription(subscription) }
}
