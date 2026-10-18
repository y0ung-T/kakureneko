// The demo: Kakureneko on a sample Mac, entirely on fakes (docs/IPHONE-APP.md, "Demo"). The app is no use without the
// Mac app, so App Review (and anyone curious) start it from onboarding's last step or Settings → See a demo. Debug
// builds also start it from launch arguments (`-KakurenekoDemo <scenario>`, Views/PreviewSupport.swift: Simulator
// screenshots), and every SwiftUI preview runs on it.
//
//   * `DemoFixtures`: sample Macs and alerts, worded the way the Mac app words them (PhoneStatusBuilder).
//   * `DemoEnvironment`: a `PhoneStore` on its own `InMemoryCloudStore`, a throwaway cache directory and defaults
//     suite, and `RecordingNotificationCenter`: nothing reaches iCloud or the system's notifications. Plus a
//     simulated Mac that answers the store's commands a moment later and keeps its status fresh.
//   * `DemoMode`: the app's switch. While a demo runs the root view covers the real app with it; the real
//     `PhoneStore` (and its iCloud sync) keeps running underneath, untouched, and is what shows again at the end.

import KakurenekoCloud
import Foundation
import Observation

@MainActor
enum DemoFixtures {
    static let studioID = "demo-studio"
    static let miniID = "demo-mini"

    enum Scenario: String, CaseIterable, Sendable {
        /// One MacBook with the lid closed: an agent working, one waiting for you, one finished; recent alerts.
        /// What the in-app demo shows.
        case oneMac
        /// The lid closed and two agents working.
        case working
        /// Like `oneMac`, with the agent that waits for you first (screenshots).
        case waiting
        case severalMacs
        /// All agents done, sleeping in a few minutes.
        case countdown
        /// The Mac stopped publishing 40 minutes ago.
        case stale
        /// Signed in, but no Mac has published its status yet.
        case noMac
        /// Not signed in to iCloud.
        case noICloud
        /// Onboarding not done, notification permission not asked yet.
        case firstRun
        /// Onboarding not done, but a Mac already shares its status: onboarding's "Connected to Studio".
        case firstRunWithMac
    }

    /// The in-app demo's scenario.
    static let demoScenario = Scenario.oneMac

    static func statuses(_ scenario: Scenario, now: Date) -> [MacStatus] {
        switch scenario {
        case .oneMac, .firstRunWithMac: [studio(now: now)]
        case .working:
            [studio(now: now, headline: "Lid closed · 2 agents working", keptAwake: false,
                    agents: [
                        AgentSummary(agent: "Claude Code", project: "kakureneko", host: "Terminal", activity: .working,
                                     since: now.addingTimeInterval(-25 * 60)),
                        AgentSummary(agent: "Codex", project: "website", host: "VS Code", activity: .working,
                                     since: now.addingTimeInterval(-8 * 60)),
                        AgentSummary(agent: "Claude Code", project: "api", host: "Terminal", activity: .finished,
                                     since: now.addingTimeInterval(-12 * 60)),
                    ])]
        case .waiting:
            [studio(now: now, keptAwake: false,
                    agents: [
                        AgentSummary(agent: "Codex", project: "website", host: "VS Code", activity: .waiting,
                                     since: now.addingTimeInterval(-3 * 60), note: "Needs permission to run npm install"),
                        AgentSummary(agent: "Claude Code", project: "kakureneko", host: "Terminal", activity: .working,
                                     since: now.addingTimeInterval(-25 * 60)),
                        AgentSummary(agent: "Claude Code", project: "api", host: "Terminal", activity: .finished,
                                     since: now.addingTimeInterval(-12 * 60)),
                    ])]
        case .severalMacs: [studio(now: now), mini(now: now)]
        case .countdown:
            [studio(now: now, phase: .countdown, headline: "Going to sleep soon", detail: "All agents are done.",
                    countdownEndsAt: now.addingTimeInterval(270), keptAwake: false,
                    agents: [
                        AgentSummary(agent: "Claude Code", project: "kakureneko", host: "Terminal", activity: .finished,
                                     since: now.addingTimeInterval(-30)),
                        AgentSummary(agent: "Codex", project: "website", host: "VS Code", activity: .finished,
                                     since: now.addingTimeInterval(-4 * 60)),
                    ])]
        case .stale: [studio(now: now, updatedAt: now.addingTimeInterval(-40 * 60))]
        case .noMac, .noICloud, .firstRun: []
        }
    }

    static func studio(now: Date, phase: MacPhase = .lidClosedAwake, headline: String = "Lid closed · 1 agent working · 1 waiting",
                       detail: String = "Keeping your Mac awake for the agents. 4 apps slowed down.", countdownEndsAt: Date? = nil,
                       keptAwake: Bool = true, agents: [AgentSummary]? = nil, updatedAt: Date? = nil) -> MacStatus {
        MacStatus(macID: studioID, macName: "Studio", model: "MacBook Pro", phase: phase, headline: headline, detail: detail,
                  countdownEndsAt: countdownEndsAt, keepAwakeUntil: keptAwake ? now.addingTimeInterval(40 * 60) : nil,
                  agents: agents ?? [
                      AgentSummary(agent: "Claude Code", project: "kakureneko", host: "Terminal", activity: .working,
                                   since: now.addingTimeInterval(-25 * 60)),
                      AgentSummary(agent: "Codex", project: "website", host: "VS Code", activity: .waiting,
                                   since: now.addingTimeInterval(-3 * 60), note: "Needs permission to run npm install"),
                      AgentSummary(agent: "Claude Code", project: "api", host: "Terminal", activity: .finished,
                                   since: now.addingTimeInterval(-12 * 60)),
                  ],
                  batteryPercent: 76, onBattery: true, lidClosed: true, stateVersion: 12, keepAwakeSeconds: 3600,
                  shutdownEnabled: true, canSleep: true, updatedAt: updatedAt ?? now.addingTimeInterval(-20), appVersion: "1.0.0")
    }

    static func mini(now: Date) -> MacStatus {
        MacStatus(macID: miniID, macName: "Mini", model: "Mac mini", phase: .idle, headline: "No agents working",
                  batteryPercent: nil, onBattery: false, lidClosed: false, stateVersion: 3, keepAwakeSeconds: 1800,
                  canSleep: true, updatedAt: now.addingTimeInterval(-90), appVersion: "1.0.0")
    }

    static func alerts(now: Date) -> [CloudAlert] {
        func alert(_ kind: String, _ title: String, _ body: String, ago: TimeInterval,
                   interruption: AlertInterruption = .active) -> CloudAlert {
            let created = now.addingTimeInterval(-ago)
            return CloudAlert(macID: studioID, macName: "Studio", kind: kind, title: title, body: body, threadID: kind,
                              interruption: interruption, createdAt: created, expiresAt: created.addingTimeInterval(600))
        }
        let day: TimeInterval = 86400
        // Yesterday: a countdown, then a night's sleep reported when the Mac woke (times in this iPhone's format).
        let countdownAgo = day + 3 * 3600
        let slept = now.addingTimeInterval(-countdownAgo + 5 * 60)
        let woke = slept.addingTimeInterval(7 * 3600)
        func clock(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
        return [
            alert(AlertKind.needsInput, "Codex needs your input", "website · Needs permission to run npm install", ago: 3 * 60,
                  interruption: .timeSensitive),
            alert(AlertKind.finished, "Claude Code finished", "api · 41 min", ago: 12 * 60),
            alert(AlertKind.warning, "Low Power Mode is on", "Agents may run slower on battery.", ago: 50 * 60),
            alert(AlertKind.countdown, "Studio sleeps in 5 min", "All agents finished.", ago: countdownAgo, interruption: .timeSensitive),
            alert(AlertKind.asleep, "Studio slept \(clock(slept))–\(clock(woke))", "After all agents finished.",
                  ago: now.timeIntervalSince(woke), interruption: .passive),
            alert(AlertKind.commandIgnored, "Sleep ignored", "Codex in website is busy again.", ago: day + 1800),
            alert(AlertKind.test, "Test alert", "Kakureneko on Studio can reach this iPhone.", ago: 2 * day),
            alert(AlertKind.safetyTrip, "Safety sleep", "The battery reached 8%.", ago: 2 * day + 600, interruption: .timeSensitive),
            alert(AlertKind.stalled, "Codex looks stuck", "No output for 20 minutes.", ago: 2 * day + 7200),
        ]
    }
}

/// A demo's store, its in-memory iCloud and notification center, and the simulated Mac.
@MainActor
final class DemoEnvironment: Identifiable {
    /// How often the simulated Mac looks for commands, and how often it republishes its status.
    enum Timing {
        static let answerEvery: Duration = .seconds(2)
        static let heartbeat: TimeInterval = 30
    }

    let store: PhoneStore
    /// The demo's iCloud: every command the demo's buttons send lands here, and only here.
    let cloud: InMemoryCloudStore
    /// The demo's notification center: categories and notices are recorded, never shown.
    let notifications: RecordingNotificationCenter
    private let items: [CloudItem]
    private let clock: PhoneClock
    private let directory: URL
    private let defaultsSuite: String
    private var lastHeartbeat: Date

    /// `defaultsSuite` names the throwaway defaults (wiped first, so a demo always starts fresh).
    init(_ scenario: DemoFixtures.Scenario, device: DeviceInfo = .demo, clock: PhoneClock = .system,
         defaultsSuite: String = "KakurenekoDemo-\(UUID().uuidString)") {
        let now = clock.now()
        let statuses = DemoFixtures.statuses(scenario, now: now)
        let alerts = statuses.isEmpty ? [] : DemoFixtures.alerts(now: now)
        items = statuses.map(CloudItem.status) + alerts.map(CloudItem.alert)
        self.clock = clock
        self.defaultsSuite = defaultsSuite
        lastHeartbeat = now
        directory = FileManager.default.temporaryDirectory
            .appending(path: "KakurenekoDemo-\(UUID().uuidString)", directoryHint: .isDirectory)
        // The cache already shows the scenario, so the first frame is never empty.
        let cacheFile = PhoneCacheFile(directory: directory)
        try? cacheFile.save(PhoneCache(statuses: statuses, alerts: alerts))
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
        // Never the app's own defaults: `init(suiteName:)` is nil only for the bundle id or the global domain.
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        PhonePreferences(defaults: defaults).onboardingComplete = scenario != .firstRun && scenario != .firstRunWithMac
        let authorization = scenario == .firstRun ? NotificationAuthorization(status: .notDetermined, timeSensitive: nil)
                                                  : NotificationAuthorization(status: .authorized, timeSensitive: true)
        cloud = InMemoryCloudStore(account: scenario == .noICloud ? .noAccount : .available, zoneExists: true)
        notifications = RecordingNotificationCenter(current: authorization)
        store = PhoneStore(cloud: cloud, clock: clock, cacheFile: cacheFile, defaults: defaults, device: device,
                           notifications: notifications)
    }

    /// Fills the in-memory iCloud and syncs, then plays the Mac until cancelled.
    func run() async {
        await prepare()
        while !Task.isCancelled {
            try? await Task.sleep(for: Timing.answerEvery)
            guard !Task.isCancelled else { return }
            await tick()
        }
    }

    /// The sample Mac's records in the in-memory iCloud, and the store synced with them.
    func prepare() async {
        if await cloud.account.isAvailable { try? await cloud.save(items) }
        await store.refreshNotificationAuthorization()
        await store.refreshAccount()
        await store.sync(force: true)
    }

    /// One turn of the simulated Mac: answers commands, republishes its status now and then, and syncs the store.
    func tick() async {
        let now = clock.now()
        let heartbeat = now.timeIntervalSince(lastHeartbeat) >= Timing.heartbeat
        if heartbeat { lastHeartbeat = now }
        if await answerCommands(heartbeat: heartbeat) { await store.sync(force: true) }
    }

    /// What a Mac does with the phone's commands: Keep awake extends the awake time (and ends a countdown), sleep
    /// and shut down end the session, a test posts a test alert, refresh republishes. Then it deletes the commands,
    /// like the real Mac. With `heartbeat`, every running Mac also republishes (so it never looks unresponsive),
    /// and one whose countdown ran out goes to sleep. Returns whether anything changed.
    @discardableResult
    func answerCommands(heartbeat: Bool = false) async -> Bool {
        let all = await cloud.allItems
        let commands = all.compactMap { item -> CloudCommand? in if case .command(let command) = item { command } else { nil } }
        var statuses = Dictionary(all.compactMap { item -> (String, MacStatus)? in
            if case .status(let status) = item { (status.macID, status) } else { nil }
        }, uniquingKeysWith: { _, last in last })
        let now = clock.now()
        var changed = Set<String>()
        if heartbeat {
            for (macID, var status) in statuses where !MacStatusPresentation(status: status, now: now).isDormant {
                if status.phase == .countdown, let end = status.countdownEndsAt, end <= now {
                    status.fallAsleep()
                }
                status.updatedAt = now
                statuses[macID] = status
                changed.insert(macID)
            }
        }
        guard !commands.isEmpty || !changed.isEmpty else { return false }
        var replies: [CloudItem] = []
        for command in commands {
            guard var status = statuses[command.macID] else { continue }
            status.updatedAt = now
            switch command.request {
            case .keepAwake(let seconds):
                status.keepAwakeUntil = now.addingTimeInterval(TimeInterval(seconds))
                if status.phase == .countdown || status.phase == .shutdownPending {
                    status.phase = status.lidClosed ? .lidClosedAwake : .idle
                    status.headline = status.lidClosed ? "Lid closed · keeping awake" : "Keeping awake"
                    status.detail = status.lidClosed ? "Keeping your Mac awake for the agents." : nil
                    status.countdownEndsAt = nil
                }
                status.stateVersion += 1
            case .sleepNow:
                status.fallAsleep()
            case .shutDown:
                status.phase = .shutDown
                status.headline = "Shut down"
                status.detail = nil
                status.countdownEndsAt = nil
                status.keepAwakeUntil = nil
                status.agents = []
                status.stateVersion += 1
            case .sendTest:
                replies.append(.alert(CloudAlert(macID: status.macID, macName: status.macName, kind: AlertKind.test, title: "Test alert",
                                                 body: "Kakureneko on \(status.macName) can reach this iPhone.", threadID: AlertKind.test,
                                                 createdAt: now, expiresAt: now.addingTimeInterval(600))))
            case .refreshStatus:
                break
            }
            statuses[command.macID] = status
            changed.insert(command.macID)
        }
        replies += changed.compactMap { statuses[$0] }.map(CloudItem.status)
        if !commands.isEmpty { try? await cloud.delete(commands.map { CloudItemID.command($0.id) }) }
        try? await cloud.save(replies)
        return true
    }

    /// Removes the demo's cache directory and defaults suite.
    func discard() {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
    }

    /// Where the demo keeps its cache (tests check it goes away).
    var cacheDirectory: URL { directory }
}

private extension MacStatus {
    /// The final status a Mac reports before it sleeps.
    mutating func fallAsleep() {
        phase = .asleep
        headline = "Asleep"
        detail = nil
        countdownEndsAt = nil
        keepAwakeUntil = nil
        agents = []
        stateVersion += 1
    }
}

extension DeviceInfo {
    /// The iPhone in previews and tests (the app's demo uses this iPhone's own description).
    static let demo = DeviceInfo(name: "iPhone", model: "iPhone18,2", systemVersion: "26.0", appVersion: "1.0.0 (1)")
}

/// The app's demo switch: `start()` covers the real app with a demo, `end()` brings the real app back. The real
/// `PhoneStore` is never touched: the demo has its own store, iCloud and notification center.
@MainActor
@Observable
final class DemoMode {
    /// Defaults suite of the app's demo: one fixed name, wiped at every start and end, so nothing piles up.
    static let defaultsSuite = "com.kakureneko.Kakureneko.demo"

    /// The running demo, if any.
    private(set) var session: DemoEnvironment?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let device: DeviceInfo
    @ObservationIgnored private let clock: PhoneClock

    init(device: DeviceInfo, clock: PhoneClock = .system) {
        self.device = device
        self.clock = clock
    }

    var isActive: Bool { session != nil }

    /// Starts the demo (does nothing while one runs).
    func start(_ scenario: DemoFixtures.Scenario = DemoFixtures.demoScenario) {
        guard session == nil else { return }
        let environment = DemoEnvironment(scenario, device: device, clock: clock, defaultsSuite: Self.defaultsSuite)
        session = environment
        task = Task { await environment.run() }
    }

    /// Ends the demo at once; the simulated Mac stops and the demo's files go once it has (the returned task).
    @discardableResult
    func end() -> Task<Void, Never> {
        let environment = session
        let running = task
        session = nil
        task = nil
        running?.cancel()
        return Task {
            await running?.value
            environment?.discard()
        }
    }
}
