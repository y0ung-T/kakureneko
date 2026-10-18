@testable import KakurenekoPower
import KakurenekoKit
import Foundation
import Synchronization
import Testing

// MARK: - Pure detectors

@Suite("Power event detectors", .timeLimit(.minutes(1)))
struct PowerEventDetectorTests {
    static let t0 = TestClock.defaultStart

    @Test func lidEdgesIgnoreRepeatsAndUnreadableValues() {
        var lid = LidEdgeDetector()
        lid.prime(false, now: Self.t0)
        #expect(lid.observe(false, now: Self.t0 + 1) == nil, "AC plug/unplug message with the lid still open")
        #expect(lid.observe(true, now: Self.t0 + 2) == .closed)
        #expect(lid.closedSince == Self.t0 + 2)
        #expect(lid.observe(true, now: Self.t0 + 3) == nil, "poll re-reading the same state")
        #expect(lid.closedSince == Self.t0 + 2)
        #expect(lid.observe(nil, now: Self.t0 + 4) == nil, "unreadable keeps the last state")
        #expect(lid.state == .closed)
        #expect(lid.observe(false, now: Self.t0 + 5) == .open)
        #expect(lid.closedSince == nil)
    }

    @Test func firstReadingPrimesSilently() {
        var lid = LidEdgeDetector()
        #expect(lid.observe(true, now: Self.t0) == nil)
        #expect(lid.isPrimed && lid.closed == true)
        #expect(lid.closedSince == Self.t0)
    }

    @Test func unreadableAtStartThenClosedIsAnEdge() {
        var lid = LidEdgeDetector()
        lid.prime(nil, now: Self.t0)
        #expect(lid.observe(nil, now: Self.t0 + 1) == nil, "a Mac without a lid never produces edges")
        #expect(lid.observe(true, now: Self.t0 + 2) == .closed, "a close is never missed")
        #expect(lid.closedSince == Self.t0 + 2)
    }

    @Test func boolEdges() {
        var display = BoolEdgeDetector()
        #expect(display.observe(true) == nil, "first value primes")
        #expect(display.observe(true) == nil)
        #expect(display.observe(false) == false)
        #expect(display.observe(true) == true)
        var primed = BoolEdgeDetector()
        primed.prime(false)
        #expect(primed.observe(true) == true)
    }

    @Test func userActivityNeedsAClosedLidRecentInputAndRespectsTheRateLimit() {
        var detector = UserActivityDetector()
        let closed = Self.t0
        #expect(detector.observe(secondsSinceInput: 0.2, lidClosedSince: nil, now: closed + 5) == nil, "lid open")
        #expect(detector.observe(secondsSinceInput: 2.0, lidClosedSince: closed, now: closed + 5) == nil, "not below 2 s")
        #expect(detector.observe(secondsSinceInput: nil, lidClosedSince: closed, now: closed + 5) == nil)
        #expect(detector.observe(secondsSinceInput: -1, lidClosedSince: closed, now: closed + 5) == nil)
        #expect(detector.observe(secondsSinceInput: 1.5, lidClosedSince: closed, now: closed + 1) == nil,
                "input from before the lid closed")
        #expect(detector.observe(secondsSinceInput: 0.5, lidClosedSince: closed, now: closed + 5) == 0.5)
        #expect(detector.lastEmittedAt == closed + 5)
        #expect(detector.observe(secondsSinceInput: 0.4, lidClosedSince: closed, now: closed + 6) == nil)
        #expect(detector.observe(secondsSinceInput: 0.4, lidClosedSince: closed, now: closed + 14.9) == nil)
        #expect(detector.observe(secondsSinceInput: 0.3, lidClosedSince: closed, now: closed + 15) == 0.3)
    }
}

@Suite("Sleep acknowledgement", .timeLimit(.minutes(1)))
struct SleepAcknowledgementTests {
    @Test func autoAllowsAfterEightSeconds() async {
        let clock = TestClock()
        let allowed = Locked(0)
        let timedOut = Locked(0)
        let settled = Locked(0)
        let ack = SleepAcknowledgement.make(
            deadline: PowerMonitor.Timing().sleepAcknowledgementDeadline, clock: clock,
            allow: { allowed.update { $0 += 1 } },
            onTimeout: { timedOut.update { $0 += 1 } },
            onSettled: { settled.update { $0 += 1 } })
        #expect(PowerMonitor.Timing().sleepAcknowledgementDeadline == .seconds(8))
        #expect(await waitUntil { clock.sleeperCount == 1 })
        clock.advance(by: .milliseconds(7_990))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(allowed.value == 0)
        #expect(!ack.isAllowed)
        clock.advance(by: .milliseconds(20)) // past 8 s (sums of float seconds can land one ulp short of 8.0)
        #expect(await waitUntil { allowed.value == 1 })
        #expect(ack.isAllowed)
        #expect(timedOut.value == 1)
        #expect(settled.value == 1)
        ack.allow() // a late consumer: idempotent
        #expect(allowed.value == 1)
    }

    @Test func consumerAllowCancelsTheTimer() async {
        let clock = TestClock()
        let allowed = Locked(0)
        let timedOut = Locked(0)
        let ack = SleepAcknowledgement.make(deadline: .seconds(8), clock: clock,
                                            allow: { allowed.update { $0 += 1 } },
                                            onTimeout: { timedOut.update { $0 += 1 } })
        #expect(await waitUntil { clock.sleeperCount == 1 })
        ack.allow()
        ack.allow()
        #expect(allowed.value == 1)
        #expect(await waitUntil { clock.sleeperCount == 0 }, "the auto-allow timer is cancelled")
        clock.advance(by: .seconds(30))
        try? await Task.sleep(for: .milliseconds(10))
        #expect(allowed.value == 1)
        #expect(timedOut.value == 0)
    }

    @Test func allowBeforeTheTimerIsInstalledStillCancelsIt() async {
        let clock = TestClock()
        let allowed = Locked(0)
        let ack = SleepAcknowledgement.make(deadline: .seconds(8), clock: clock, allow: { allowed.update { $0 += 1 } })
        ack.allow() // immediately, possibly before the timer task even started
        #expect(allowed.value == 1)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(clock.sleeperCount == 0)
        clock.advance(by: .seconds(9))
        try? await Task.sleep(for: .milliseconds(10))
        #expect(allowed.value == 1)
    }
}

// MARK: - PowerMonitor

/// A monitor on a `TestClock` with manual observers, the Kit `FakePowerController` (lid + snapshots) and fake
/// display / input readers.
final class MonitorRig: Sendable {
    let clock: TestClock
    let power: FakePowerController
    let observer = ManualObserver()
    let displays = FakeDisplays(false)
    let input = FakeInput(600)
    let monitor: PowerMonitor

    init(lidClosed: Bool? = false, extraObservers: [any PowerObserving] = []) {
        clock = TestClock()
        power = FakePowerController(clock: clock)
        power.setLidClosed(lidClosed)
        monitor = PowerMonitor(power: power, clock: clock, logger: KakurenekoLogger(.power),
                               observers: [observer] + extraObservers, displays: displays, input: input)
    }

    /// Poll task + snapshot timer.
    static let baseSleepers = 2

    /// Waits until `count` tasks sleep on the clock, advances it, then waits until they sleep again (the poll ran).
    func step(by duration: Duration = .seconds(1), sleepers: Int = MonitorRig.baseSleepers) async {
        _ = await waitUntil { self.clock.sleeperCount >= sleepers }
        clock.advance(by: duration)
        _ = await waitUntil { self.clock.sleeperCount >= sleepers }
    }

    /// Delivers a `.willPowerOff` marker and waits until `recorder` saw it: every event emitted before is recorded.
    func flush(_ recorder: EventRecorder) async {
        let before = recorder.all.filter { $0 == .willPowerOff }.count
        observer.deliver(.willPowerOff)
        await recorder.wait { $0.all.filter { $0 == .willPowerOff }.count > before }
    }

    func started() async -> EventRecorder {
        let recorder = EventRecorder(monitor.events())
        await monitor.start()
        await recorder.wait { !$0.snapshots.isEmpty }
        return recorder
    }
}

@Suite("PowerMonitor", .timeLimit(.minutes(1)))
struct PowerMonitorTests {
    @Test func startPrimesWithoutAnEdgeAndEmitsASnapshot() async throws {
        let rig = MonitorRig(lidClosed: true)
        let recorder = await rig.started()
        defer { recorder.cancel() }
        #expect(recorder.snapshots.first?.lid == .closed)
        #expect(recorder.snapshots.first?.takenAt == rig.clock.now())
        await rig.flush(recorder)
        #expect(recorder.lidEdges.isEmpty, "the lid state at start is not an edge")
        #expect(rig.observer.starts == 1 && rig.observer.isRegistered)
        await rig.monitor.start()
        #expect(rig.observer.starts == 1, "start is idempotent")
        await rig.monitor.stop()
    }

    @Test func clamshellMessagesAreEdgeDetected() async throws {
        let rig = MonitorRig(lidClosed: false)
        let recorder = await rig.started()
        defer { recorder.cancel() }
        rig.observer.deliver(.clamshellMessage(closed: false)) // AC change with the lid open
        rig.power.setLidClosed(true)
        rig.observer.deliver(.clamshellMessage(closed: true))
        rig.observer.deliver(.clamshellMessage(closed: true)) // AC change with the lid closed
        rig.power.setLidClosed(false)
        rig.observer.deliver(.clamshellMessage(closed: false))
        await rig.flush(recorder)
        #expect(recorder.lidEdges == [.closed, .open])
        await rig.monitor.stop()
    }

    @Test func clamshellMessageTriggersASnapshot() async throws {
        let rig = MonitorRig()
        let recorder = await rig.started()
        defer { recorder.cancel() }
        let before = recorder.snapshots.count
        rig.observer.deliver(.clamshellMessage(closed: false)) // e.g. AC plugged in: no edge, fresh snapshot
        #expect(await recorder.wait { $0.snapshots.count > before })
        await rig.monitor.stop()
    }

    @Test func pollBacksUpTheLidMessageWithoutDoubleEdges() async throws {
        let rig = MonitorRig(lidClosed: false)
        let recorder = await rig.started()
        defer { recorder.cancel() }
        rig.power.setLidClosed(true)
        await rig.step()
        await rig.flush(recorder)
        #expect(recorder.lidEdges == [.closed])
        // The interest message arriving late, and more polls, add nothing.
        rig.observer.deliver(.clamshellMessage(closed: true))
        await rig.step()
        await rig.step()
        await rig.flush(recorder)
        #expect(recorder.lidEdges == [.closed])
        // The edge is followed by a snapshot that shows the closed lid.
        #expect(await recorder.wait { $0.snapshots.last?.lid == .closed })
        rig.power.setLidClosed(false)
        await rig.step()
        await rig.flush(recorder)
        #expect(recorder.lidEdges == [.closed, .open])
        await rig.monitor.stop()
    }

    @Test func lidUnreadableAtStartThenClosedIsReported() async throws {
        let rig = MonitorRig(lidClosed: nil)
        let recorder = await rig.started()
        defer { recorder.cancel() }
        await rig.step()
        await rig.flush(recorder)
        #expect(recorder.lidEdges.isEmpty, "no lid, no edge")
        rig.power.setLidClosed(true)
        await rig.step()
        await rig.flush(recorder)
        #expect(recorder.lidEdges == [.closed])
        await rig.monitor.stop()
    }

    @Test func closedLidUserActivityIsRateLimited() async throws {
        let rig = MonitorRig(lidClosed: true) // closed since the start (t0)
        let recorder = await rig.started()
        defer { recorder.cancel() }
        await rig.step() // t0+1: idle input
        await rig.flush(recorder)
        #expect(recorder.userActivities.isEmpty)
        rig.input.set(0.5)
        await rig.step() // t0+2: input 0.5 s ago (after the lid closed)
        await rig.flush(recorder)
        #expect(recorder.userActivities == [0.5])
        for _ in 3...11 { await rig.step() } // t0+3 … t0+11: still within 10 s of the last emission
        await rig.flush(recorder)
        #expect(recorder.userActivities == [0.5])
        await rig.step() // t0+12: 10 s later
        await rig.flush(recorder)
        #expect(recorder.userActivities == [0.5, 0.5])
        // Lid open: no more closed-lid activity.
        rig.power.setLidClosed(false)
        for _ in 0..<12 { await rig.step() }
        await rig.flush(recorder)
        #expect(recorder.userActivities == [0.5, 0.5])
        #expect(recorder.lidEdges == [.open])
        await rig.monitor.stop()
    }

    @Test func willSleepAutoAllowsAfterEightSeconds() async throws {
        let rig = MonitorRig()
        let recorder = await rig.started()
        defer { recorder.cancel() }
        let allowed = Locked(0)
        rig.observer.deliver(.systemWillSleep(allow: { allowed.update { $0 += 1 } }))
        #expect(await recorder.wait { $0.acknowledgers.count == 1 })
        let ack = try #require(recorder.acknowledgers.first)
        #expect(!ack.isAllowed && allowed.value == 0)
        // poll + snapshot timer + the auto-allow timer
        #expect(await waitUntil { rig.clock.sleeperCount == MonitorRig.baseSleepers + 1 })
        rig.clock.advance(by: .milliseconds(7_900))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(allowed.value == 0)
        rig.clock.advance(by: .milliseconds(200))
        #expect(await waitUntil { allowed.value == 1 })
        #expect(ack.isAllowed)
        ack.allow()
        #expect(allowed.value == 1)
        await rig.monitor.stop()
        #expect(allowed.value == 1)
    }

    @Test func consumerAcknowledgementAllowsOnce() async throws {
        let rig = MonitorRig()
        let recorder = await rig.started()
        defer { recorder.cancel() }
        let allowed = Locked(0)
        rig.observer.deliver(.systemWillSleep(allow: { allowed.update { $0 += 1 } }))
        #expect(await recorder.wait { $0.acknowledgers.count == 1 })
        recorder.acknowledgers[0].allow()
        #expect(allowed.value == 1)
        #expect(await waitUntil { rig.clock.sleeperCount == MonitorRig.baseSleepers }, "timer cancelled")
        rig.clock.advance(by: .seconds(10))
        try? await Task.sleep(for: .milliseconds(20))
        await rig.monitor.stop()
        #expect(allowed.value == 1)
    }

    @Test func willSleepWithoutSubscribersIsAllowedAtOnce() async throws {
        let rig = MonitorRig()
        await rig.monitor.start()
        let allowed = Locked(0)
        rig.observer.deliver(.systemWillSleep(allow: { allowed.update { $0 += 1 } }))
        await rig.monitor.drain()
        #expect(allowed.value == 1)
        await rig.monitor.stop()
    }

    @Test func wakeSettlesPendingAcknowledgements() async throws {
        let rig = MonitorRig()
        let recorder = await rig.started()
        defer { recorder.cancel() }
        let allowed = Locked(0)
        rig.observer.deliver(.systemWillSleep(allow: { allowed.update { $0 += 1 } }))
        #expect(await recorder.wait { $0.acknowledgers.count == 1 })
        let snapshots = recorder.snapshots.count
        rig.observer.deliver(.systemDidWake)
        await rig.monitor.drain()
        #expect(allowed.value == 1)
        #expect(await recorder.wait { $0.all.contains(.didWake) })
        #expect(await recorder.wait { $0.snapshots.count > snapshots }, "a fresh snapshot after wake")
        await rig.monitor.stop()
    }

    @Test func stopAllowsPendingAndFinishesEveryStream() async throws {
        let rig = MonitorRig()
        let recorder = await rig.started()
        let allowed = Locked(0)
        rig.observer.deliver(.systemWillSleep(allow: { allowed.update { $0 += 1 } }))
        #expect(await recorder.wait { $0.acknowledgers.count == 1 })
        await rig.monitor.stop()
        #expect(allowed.value == 1)
        #expect(await recorder.wait { $0.isFinished })
        #expect(rig.observer.stops >= 1 && !rig.observer.isRegistered)
        #expect(await waitUntil { rig.clock.sleeperCount == 0 }, "poll and timers cancelled")
        // A late subscription ends at once; a stray willSleep is still acknowledged.
        let late = EventRecorder(rig.monitor.events())
        #expect(await late.wait { $0.isFinished })
        rig.monitor.handle(.systemWillSleep(allow: { allowed.update { $0 += 1 } }))
        #expect(allowed.value == 2)
        // Stopped is final.
        await rig.monitor.start()
        #expect(rig.observer.starts == 1)
        await rig.monitor.stop()
    }

    @Test func workspaceObservationsMapToEvents() async throws {
        let rig = MonitorRig()
        let recorder = await rig.started()
        defer { recorder.cancel() }
        rig.observer.deliver(.sessionResignedActive)
        rig.observer.deliver(.sessionBecameActive)
        rig.observer.deliver(.willPowerOff)
        #expect(await recorder.wait { $0.all.contains(.willPowerOff) })
        #expect(recorder.edges == [.sessionResignedActive, .sessionBecameActive, .willPowerOff])
        await rig.monitor.stop()
    }

    @Test func displayReconfigurationIsEdgeDetected() async throws {
        let rig = MonitorRig()
        let recorder = await rig.started()
        defer { recorder.cancel() }
        // Each reconfiguration re-reads the displays when it is processed.
        rig.observer.deliver(.displaysReconfigured) // nothing changed (e.g. resolution)
        await rig.monitor.drain()
        rig.displays.set(true)
        rig.observer.deliver(.displaysReconfigured)
        rig.observer.deliver(.displaysReconfigured)
        await rig.monitor.drain()
        rig.displays.set(false)
        rig.observer.deliver(.displaysReconfigured)
        await rig.flush(recorder)
        #expect(recorder.displayEdges == [true, false])
        await rig.monitor.stop()
    }

    @Test func displayChangeWhileTheLidIsClosedIsCaughtByThePoll() async throws {
        let rig = MonitorRig(lidClosed: true)
        let recorder = await rig.started()
        defer { recorder.cancel() }
        rig.displays.set(true) // no reconfiguration callback (missed)
        await rig.step()
        await rig.flush(recorder)
        #expect(recorder.displayEdges == [true])
        await rig.monitor.stop()
    }

    @Test func lateSubscriberGetsOnlyTheLatestSnapshot() async throws {
        let rig = MonitorRig()
        let early = await rig.started()
        defer { early.cancel() }
        rig.power.setLidClosed(true)
        rig.observer.deliver(.clamshellMessage(closed: true))
        rig.observer.deliver(.sessionResignedActive)
        #expect(await early.wait { $0.lidEdges == [.closed] && $0.snapshots.last?.lid == .closed })
        let late = EventRecorder(rig.monitor.events())
        defer { late.cancel() }
        #expect(await late.wait { !$0.all.isEmpty })
        #expect(late.all.first?.isSnapshot == true)
        rig.observer.deliver(.willPowerOff)
        #expect(await late.wait { $0.all.contains(.willPowerOff) })
        #expect(late.edges == [.willPowerOff], "no stale lid/session edge is replayed")
        await rig.monitor.stop()
    }

    @Test func snapshotsArePeriodic() async throws {
        let rig = MonitorRig()
        let recorder = await rig.started()
        defer { recorder.cancel() }
        let first = recorder.snapshots.count
        let start = rig.clock.now()
        await rig.step(by: .seconds(15))
        #expect(await recorder.wait { $0.snapshots.count > first })
        #expect(recorder.snapshots.last?.takenAt == start.addingTimeInterval(15))
        await rig.monitor.stop()
    }

    @Test func powerConditionChangesTriggerASnapshot() async throws {
        let rig = MonitorRig()
        let recorder = await rig.started()
        defer { recorder.cancel() }
        var snapshot = PowerSnapshot(takenAt: .distantPast, batteryPercent: 55, onAC: false)
        snapshot.thermalState = .serious
        rig.power.setSnapshot(snapshot)
        rig.observer.deliver(.powerConditionsChanged)
        #expect(await recorder.wait { $0.snapshots.last?.batteryPercent == 55 })
        #expect(recorder.snapshots.last?.thermalState == .serious)
        await rig.monitor.stop()
    }

    @Test func unavailableObserversAreTolerated() async throws {
        let refusing = ManualObserver(name: "refusing", accepts: false)
        let rig = MonitorRig(extraObservers: [refusing])
        let recorder = await rig.started()
        defer { recorder.cancel() }
        #expect(refusing.starts == 1)
        rig.observer.deliver(.willPowerOff)
        #expect(await recorder.wait { $0.all.contains(.willPowerOff) })
        await rig.monitor.stop()
    }

    @Test func droppingAStartedMonitorTearsItDown() async throws {
        let clock = TestClock()
        let observer = ManualObserver()
        let power = FakePowerController(clock: clock)
        let allowed = Locked(0)
        let weakMonitor = Locked(WeakMonitor())
        var recorder: EventRecorder?
        do {
            let monitor = PowerMonitor(power: power, clock: clock, logger: KakurenekoLogger(.power), observers: [observer],
                                       displays: FakeDisplays(), input: FakeInput())
            weakMonitor.set(WeakMonitor(monitor: monitor))
            let r = EventRecorder(monitor.events())
            recorder = r
            await monitor.start()
            #expect(await r.wait { !$0.snapshots.isEmpty })
            observer.deliver(.systemWillSleep(allow: { allowed.update { $0 += 1 } }))
            #expect(await r.wait { $0.acknowledgers.count == 1 })
        }
        // The emitted acknowledger is still referenced by the recorder; the monitor itself must go away.
        #expect(await waitUntil { weakMonitor.value.monitor == nil }, "no retain cycle through tasks or observers")
        #expect(allowed.value == 1, "deinit settles pending acknowledgements")
        #expect(await recorder?.wait { $0.isFinished } == true)
        #expect(observer.stops >= 1)
    }

    @Test func staleSnapshotsAreAlignedWithTheEdges() async throws {
        // The snapshot's own lid/display readings are stale (taken before the lid closed and the display left).
        let clock = TestClock()
        let power = StaleSnapshotPower(clock: clock, stale: PowerSnapshot(takenAt: .distantPast, lid: .open,
                                                                          externalDisplayConnected: true))
        let displays = FakeDisplays(true)
        let monitor = PowerMonitor(power: power, clock: clock, logger: KakurenekoLogger(.power), observers: [],
                                   displays: displays, input: FakeInput())
        let recorder = EventRecorder(monitor.events())
        defer { recorder.cancel() }
        await monitor.start()
        #expect(await recorder.wait { !$0.snapshots.isEmpty })
        power.lidClosed.set(true)
        displays.set(false)
        monitor.requestSnapshot()
        #expect(await recorder.wait { $0.snapshots.count >= 2 })
        let events = recorder.all
        let closedEdge = try #require(events.firstIndex(of: .lidChanged(.closed)))
        let displayEdge = try #require(events.firstIndex(of: .externalDisplayChanged(connected: false)))
        let lastSnapshot = try #require(events.lastIndex { $0.isSnapshot })
        #expect(closedEdge < lastSnapshot && displayEdge < lastSnapshot, "edges come before the snapshot that shows them")
        #expect(recorder.snapshots.last?.lid == .closed, "never an open-lid snapshot after a close edge")
        #expect(recorder.snapshots.last?.externalDisplayConnected == false)
        #expect(recorder.lidEdges == [.closed], "a stale reading never produces a reverse edge")
        await monitor.stop()
    }

    @Test func liveObserversStartAndStop() async throws {
        // Real registrations (IOKit interest + IORegisterForSystemPower, NSWorkspace, CoreGraphics, notify): read-only.
        let clock = TestClock()
        let power = FakePowerController(clock: clock)
        let monitor = PowerMonitor(power: power, clock: clock)
        let recorder = EventRecorder(monitor.events())
        await monitor.start()
        #expect(await recorder.wait { !$0.snapshots.isEmpty })
        await monitor.stop()
        #expect(await recorder.wait { $0.isFinished })
    }
}

/// A weak reference that can live in a `Locked` (read from `@Sendable` closures).
struct WeakMonitor: Sendable {
    weak var monitor: PowerMonitor?
}

/// A `PowerControlling` whose `snapshot()` always returns the same (stale) readings while `kernelFlags()` is live.
final class StaleSnapshotPower: PowerControlling {
    let lidClosed = Locked<Bool?>(false)
    private let clock: TestClock
    private let stale: PowerSnapshot

    init(clock: TestClock, stale: PowerSnapshot) {
        self.clock = clock
        self.stale = stale
    }

    func start() async {}
    func kernelFlags() -> KernelPowerFlags { KernelPowerFlags(sleepDisabled: false, clamshellClosed: lidClosed.value) }
    func arm() async throws {}
    func disarm() async throws {}
    func disarmSynchronously(timeout: Duration) -> Bool { true }
    func touchHeartbeat() throws {}
    func sleepNow() async throws {}
    func requestShutdown() async throws {}
    func scheduleDetachedSleep(after delay: Duration) throws {}
    func displaySleepNow() async throws {}
    func playLidCloseChime() {}
    func snapshot() async -> PowerSnapshot {
        var snapshot = stale
        snapshot.takenAt = clock.now()
        return snapshot
    }
}
