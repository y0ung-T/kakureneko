@testable import KakurenekoCoordinator
import KakurenekoKit
import Foundation
import Testing

/// The pure §7.3 machine and the §9.8 predicates, with explicit dates (no actor, no services).
@Suite("Power state machine (pure)", .timeLimit(.minutes(1)))
struct PowerStateMachineTests {
    let t0 = TestClock.defaultStart
    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func inputs(_ seconds: TimeInterval, _ configure: (inout PowerInputs) -> Void = { _ in }) -> PowerInputs {
        var i = PowerInputs(now: at(seconds))
        configure(&i)
        return i
    }

    /// A machine already Armed with the lid open at t0 (one working session).
    func armed() -> PowerStateMachine {
        var m = PowerStateMachine(now: t0)
        #expect(m.step(inputs(0) { $0.anyWorking = true }) == [.arm])
        return m
    }

    /// Armed, then the lid closed at t0 + 10.
    func closedAwake() -> PowerStateMachine {
        var m = armed()
        #expect(m.step(inputs(10) { $0.anyWorking = true; $0.lid = .closed }) == [.lidClosedAwake])
        return m
    }

    /// ClosedAwake, then the work finished at t0 + 20 (5 min finish countdown until t0 + 320).
    func countingDown(endAction: EndAction = .sleep) -> PowerStateMachine {
        var m = closedAwake()
        let actions = m.step(inputs(20) { $0.lid = .closed; $0.endAction = endAction })
        #expect(actions == [.countdownStarted(endsAt: at(320), reason: .finished, stateVersion: 0)])
        return m
    }

    // MARK: Predicates

    @Test func waitingGraceLastsTheNeedsInputCountdown() {
        let timers = SessionTimers()
        let waiting = Fixture.session("w", state: .waiting(kind: .permission, since: t0))
        #expect(PowerPredicates.waitingGraceActive(sessions: [waiting], timers: timers, now: at(599)))
        #expect(!PowerPredicates.waitingGraceActive(sessions: [waiting], timers: timers, now: at(600)))
        let working = Fixture.session("x", state: .working(since: t0))
        #expect(!PowerPredicates.waitingGraceActive(sessions: [working], timers: timers, now: t0))
    }

    @Test func stayArmedAndCountDownPredicates() {
        #expect(PowerPredicates.shouldStayArmed(anyWorking: true, waitingGraceActive: false, keepAwakeUntil: nil, now: t0))
        #expect(PowerPredicates.shouldStayArmed(anyWorking: false, waitingGraceActive: true, keepAwakeUntil: nil, now: t0))
        #expect(PowerPredicates.shouldStayArmed(anyWorking: false, waitingGraceActive: false, keepAwakeUntil: at(1), now: t0))
        #expect(!PowerPredicates.shouldStayArmed(anyWorking: false, waitingGraceActive: false, keepAwakeUntil: t0, now: t0))
        #expect(PowerPredicates.shouldCountDown(anyWorking: false, keepAwakeUntil: nil, now: t0))
        #expect(PowerPredicates.shouldCountDown(anyWorking: false, keepAwakeUntil: t0, now: t0))
        #expect(!PowerPredicates.shouldCountDown(anyWorking: true, keepAwakeUntil: nil, now: t0))
        #expect(!PowerPredicates.shouldCountDown(anyWorking: false, keepAwakeUntil: at(1), now: t0))
    }

    @Test func effectiveLidAndPresencePredicates() {
        #expect(PowerPredicates.effectiveLidClosed(lid: .closed, externalDisplayConnected: false))
        #expect(!PowerPredicates.effectiveLidClosed(lid: .closed, externalDisplayConnected: true)) // clamshell desktop
        #expect(!PowerPredicates.effectiveLidClosed(lid: .open, externalDisplayConnected: false))
        #expect(!PowerPredicates.effectiveLidClosed(lid: .noLid, externalDisplayConnected: false))
        #expect(PowerPredicates.userPresent(secondsSinceUserInput: 299, awayIdleSeconds: 300, effectiveLidClosed: true))
        #expect(!PowerPredicates.userPresent(secondsSinceUserInput: 300, awayIdleSeconds: 300, effectiveLidClosed: true))
        // Unknown input time (ARCHITECTURE §8 "Presence"): away with the lid closed, present with it open.
        #expect(!PowerPredicates.userPresent(secondsSinceUserInput: nil, awayIdleSeconds: 300, effectiveLidClosed: true))
        #expect(PowerPredicates.userPresent(secondsSinceUserInput: nil, awayIdleSeconds: 300, effectiveLidClosed: false))
        // The same rule as notification gating.
        for lidClosed in [true, false] {
            for seconds in [nil, 10.0, 299, 300, 4_000] as [TimeInterval?] {
                let present = PowerPredicates.userPresent(secondsSinceUserInput: seconds, awayIdleSeconds: 300, effectiveLidClosed: lidClosed)
                #expect(present == Presence.hasRecentInput(secondsSinceUserInput: seconds, idleThreshold: 300, lidClosed: lidClosed))
                let presence = Presence(lidClosed: lidClosed, screenLocked: false, secondsSinceUserInput: seconds)
                if !lidClosed { #expect(presence.isAway(idleThreshold: 300) == !present) }
            }
        }
    }

    @Test func countdownLengthAndReason() {
        let timers = SessionTimers()
        #expect(PowerPredicates.countdownLength(anyWaiting: true, timers: timers) == 600)
        #expect(PowerPredicates.countdownLength(anyWaiting: false, timers: timers) == 300)
        let heuristic = Fixture.effect(.wentQuiet, Fixture.session("h", agent: .goose, state: .idle(since: t0, outcome: nil), tiers: [.heuristic]), at: t0)
        let hooked = Fixture.effect(.finished, Fixture.session("c", state: .idle(since: t0, outcome: .completed)), at: t0)
        #expect(PowerPredicates.countdownReason(anyWaiting: true, endedTurnsSinceLidClosed: [hooked]) == .needsInput)
        #expect(PowerPredicates.countdownReason(anyWaiting: false, endedTurnsSinceLidClosed: [heuristic]) == .wentQuiet)
        #expect(PowerPredicates.countdownReason(anyWaiting: false, endedTurnsSinceLidClosed: [heuristic, hooked]) == .finished)
        #expect(PowerPredicates.countdownReason(anyWaiting: false, endedTurnsSinceLidClosed: []) == .finished)
    }

    // MARK: Disarmed → Armed

    @Test func armingNeedsAReasonPolicyAndNoBlocker() {
        var m = PowerStateMachine(now: t0)
        #expect(m.step(inputs(0)).isEmpty)
        #expect(m.step(inputs(0) { $0.anyWorking = true; $0.armingAllowed = false }).isEmpty)
        #expect(m.step(inputs(0) { $0.anyWorking = true; $0.armBackoff = true }).isEmpty)
        #expect(m.step(inputs(0) { $0.anyWorking = true; $0.armingBlocker = .thermalCritical }) == [.armingBlocked(.thermalCritical)])
        #expect(m.phase == .disarmed)
        #expect(m.step(inputs(1) { $0.waitingGraceActive = true }) == [.arm])
        #expect(m.phase == .armed(since: at(1)))
    }

    @Test func armingWithTheLidAlreadyClosedGoesStraightToClosedAwake() {
        var m = PowerStateMachine(effectiveLidClosed: true, now: t0)
        #expect(m.step(inputs(5) { $0.lid = .closed; $0.keepAwakeUntil = at(100) }) == [.arm])
        #expect(m.phase == .closedAwake(since: t0))
        #expect(m.isClosedLidAwake)
    }

    /// A Kakureneko-initiated sleep is not undone by the next (dark) wake in the bag: the agent that was mid-turn when
    /// the user asked to sleep is still `.working`, but Disarmed does not re-arm while the lid stays closed. A NEW turn
    /// (the state version moves past the one recorded at the wind-down) re-arms.
    @Test func aWakeInTheBagAfterASleepRequestDoesNotRearmUntilANewTurn() {
        var m = closedAwake()
        _ = m.requestSleep(.userSleepNow, inputs(20) { $0.lid = .closed; $0.anyWorking = true; $0.stateVersion = 7 })
        m.didWake(kernelArmed: false)
        #expect(m.phase == .disarmed)
        for t in stride(from: 9000.0, through: 9600, by: 15) {
            #expect(m.step(inputs(t) { $0.lid = .closed; $0.anyWorking = true; $0.stateVersion = 7 }).isEmpty)
        }
        #expect(m.phase == .disarmed)
        #expect(m.step(inputs(9700) { $0.lid = .closed; $0.anyWorking = true; $0.stateVersion = 8 }) == [.arm])
        #expect(m.phase == .closedAwake(since: at(10)))
    }

    /// Opening the lid releases the latch (the user is here): the still-working agent re-arms.
    @Test func aWakeWithTheLidOpenAfterASleepRequestRearms() {
        var m = closedAwake()
        _ = m.requestSleep(.userSleepNow, inputs(20) { $0.lid = .closed; $0.anyWorking = true; $0.stateVersion = 7 })
        m.didWake(kernelArmed: false)
        #expect(m.step(inputs(9000) { $0.lid = .closed; $0.anyWorking = true; $0.stateVersion = 7 }).isEmpty)
        #expect(m.step(inputs(9010) { $0.lid = .open; $0.anyWorking = true; $0.stateVersion = 7 }) == [.lidOpened(.lidOpened), .arm])
        #expect(m.phase == .armed(since: at(9010)))
        // "Sleep now" with the lid open, the Mac woken with the lid still open: re-arms at once.
        var open = armed()
        _ = open.requestSleep(.userSleepNow, inputs(20) { $0.anyWorking = true; $0.stateVersion = 7 })
        open.didWake(kernelArmed: false)
        #expect(open.step(inputs(900) { $0.anyWorking = true; $0.stateVersion = 7 }) == [.arm])
    }

    /// A keep-awake override, a countdown elapse and the 12 h cap: keep-awake that survived the sleep never re-arms in
    /// the bag; a new turn does not release a safety trip's latch — only the lid opening does.
    @Test func aSafetyTripLatchHoldsUntilTheLidOpens() {
        var m = closedAwake()
        let trip = m.step(inputs(30) { $0.lid = .closed; $0.anyWorking = true; $0.stateVersion = 3; $0.safetyTrip = .maxDuration(hours: 12) })
        #expect(trip == [.safetyTripped(.maxDuration(hours: 12)), .windDown(.safetyTrip(.maxDuration(hours: 12)), shutdown: false)])
        m.didWake(kernelArmed: false)
        #expect(m.step(inputs(900) { $0.lid = .closed; $0.anyWorking = true; $0.stateVersion = 9 }).isEmpty)
        #expect(m.step(inputs(905) { $0.lid = .closed; $0.keepAwakeUntil = at(5000); $0.stateVersion = 9 }).isEmpty)
        _ = m.keepAwakeRequested(inputs(906) { $0.lid = .closed; $0.keepAwakeUntil = at(5000) })
        #expect(m.step(inputs(910) { $0.lid = .closed; $0.keepAwakeUntil = at(5000); $0.stateVersion = 9 }).isEmpty)
        #expect(m.phase == .disarmed)
        #expect(m.step(inputs(920) { $0.lid = .open; $0.anyWorking = true }) == [.lidOpened(.lidOpened), .arm])
    }

    /// An explicit keep-awake request after the wake releases a non-safety latch.
    @Test func aKeepAwakeRequestAfterTheWakeRearms() {
        var m = countingDown()
        #expect(m.step(inputs(320) { $0.lid = .closed }) == [.windDown(.countdownElapsed, shutdown: false)])
        m.didWake(kernelArmed: false)
        #expect(m.step(inputs(900) { $0.lid = .closed; $0.keepAwakeUntil = at(5000) }).isEmpty)
        #expect(m.keepAwakeRequested(inputs(901) { $0.lid = .closed; $0.keepAwakeUntil = at(5000) }).isEmpty)
        #expect(m.step(inputs(902) { $0.lid = .closed; $0.keepAwakeUntil = at(5000) }) == [.arm])
    }

    /// A wind-down cancelled before the sleep (the user is at the Mac) leaves no latch behind.
    @Test func aCancelledWindDownLeavesNoLatch() {
        var m = closedAwake()
        _ = m.requestSleep(.userSleepNow, inputs(20) { $0.lid = .closed; $0.anyWorking = true; $0.stateVersion = 7 })
        #expect(m.cancelWindDown(inputs(21) { $0.lid = .closed; $0.windDown = .running(disarmed: true) }) == [.cancelWindDown])
        #expect(m.phase == .disarmed)
        #expect(m.step(inputs(22) { $0.lid = .closed; $0.anyWorking = true; $0.stateVersion = 7 }) == [.arm])
    }

    /// A sleep that did not happen keeps the decision: Disarmed retries the sleep instead of re-arming for the same turn.
    @Test func aSleepThatDidNotHappenRetriesInsteadOfRearmingForTheSameTurn() {
        var m = closedAwake()
        _ = m.requestSleep(.userSleepNow, inputs(20) { $0.lid = .closed; $0.anyWorking = true; $0.stateVersion = 7 })
        m.sleepDidNotHappen(now: at(30))
        #expect(m.step(inputs(40) { $0.lid = .closed; $0.anyWorking = true; $0.stateVersion = 7 }).isEmpty)
        #expect(m.step(inputs(90) { $0.lid = .closed; $0.anyWorking = true; $0.stateVersion = 7 }) == [.windDown(.countdownElapsed, shutdown: false)])
    }

    /// The wind-down was decided (safety trip) but its task had not started when the lid opened (the coordinator was
    /// still submitting the trip push): the flag is still set, so the machine must not claim Disarmed without a disarm.
    @Test func aCancelBeforeTheWindDownTaskStartedKeepsTheFlagAccountedFor() {
        var m = PowerStateMachine(effectiveLidClosed: true, now: t0)
        #expect(m.step(inputs(0) { $0.lid = .closed; $0.anyWorking = true }) == [.arm])
        let trip = m.step(inputs(15) { $0.lid = .closed; $0.anyWorking = true; $0.safetyTrip = .batteryFloor(percent: 15) })
        #expect(trip.contains(.windDown(.safetyTrip(.batteryFloor(percent: 15)), shutdown: false)))
        let actions = m.step(inputs(16) { $0.windDown = .none; $0.armingBlocker = .batteryFloor(percent: 15) })
        #expect(actions.contains(.cancelWindDown))
        // Back to Armed (lid open) — and the blocker disarms it in the same step, so the flag is cleared.
        #expect(actions.contains(.disarm(.blocked(.batteryFloor(percent: 15)))))
        #expect(m.phase == .disarmed)
    }

    @Test func aWakeFindingTheFlagClearedDropsAnArmedPhase() {
        var m = armed()
        m.didWake(kernelArmed: true)
        #expect(m.phase.isArmed)
        m.didWake(kernelArmed: false) // the root fail-safe cleared it meanwhile
        #expect(m.phase == .disarmed)
    }

    // MARK: Armed

    @Test func armedDisarmsAfterTwoIdleMinutesWithTheLidOpen() {
        var m = armed()
        #expect(m.step(inputs(30)).isEmpty) // idle from here
        #expect(m.step(inputs(149)).isEmpty)
        #expect(m.step(inputs(150) { $0.anyWorking = true }).isEmpty) // busy again resets the timer
        #expect(m.step(inputs(200)).isEmpty)
        #expect(m.step(inputs(319)).isEmpty)
        #expect(m.step(inputs(320)) == [.disarm(.idle)])
        #expect(m.phase == .disarmed)
    }

    @Test func armedDisarmsAtOnceWhenBlockedOrNotAllowed() {
        var m = armed()
        #expect(m.step(inputs(5) { $0.anyWorking = true; $0.armingBlocker = .batteryFloor(percent: 18) })
                == [.disarm(.blocked(.batteryFloor(percent: 18))), .armingBlocked(.batteryFloor(percent: 18))])
        #expect(m.phase == .disarmed)
        m = armed()
        #expect(m.step(inputs(5) { $0.anyWorking = true; $0.armingAllowed = false }) == [.disarm(.notAllowed)])
    }

    @Test func lidEdgesMoveBetweenArmedAndClosedAwake() {
        var m = closedAwake()
        #expect(m.phase == .closedAwake(since: at(10)))
        #expect(m.closedSince == at(10))
        #expect(m.step(inputs(20) { $0.anyWorking = true }) == [.lidOpened(.lidOpened)])
        #expect(m.phase == .armed(since: at(20)))
        #expect(m.closedSince == nil)
        // An external display while closed counts as open (thaw reason: external display) …
        #expect(m.step(inputs(30) { $0.anyWorking = true; $0.lid = .closed; $0.externalDisplayConnected = true }).isEmpty)
        #expect(m.phase == .armed(since: at(20)))
        // … and its disconnect with the lid closed is the close edge.
        #expect(m.step(inputs(40) { $0.anyWorking = true; $0.lid = .closed }) == [.lidClosedAwake])
        #expect(m.step(inputs(50) { $0.anyWorking = true; $0.lid = .closed; $0.externalDisplayConnected = true }) == [.lidOpened(.externalDisplay)])
    }

    @Test func aLidCloseWhileDisarmedChangesNothing() {
        var m = PowerStateMachine(now: t0)
        #expect(m.step(inputs(1) { $0.lid = .closed }).isEmpty)
        #expect(m.phase == .disarmed)
        #expect(m.closedSince == at(1))
    }

    // MARK: ClosedAwake and Countdown

    @Test func closedAwakeCountsDownOnlyWhenNothingWorksAndNobodyIsThere() {
        var m = closedAwake()
        #expect(m.step(inputs(20) { $0.lid = .closed; $0.userPresent = true }).isEmpty)
        #expect(m.step(inputs(20) { $0.lid = .closed; $0.keepAwakeUntil = at(60) }).isEmpty)
        #expect(m.step(inputs(25) { $0.lid = .closed; $0.anyWaiting = true; $0.waitingGraceActive = true; $0.countdownReason = .needsInput })
                == [.countdownStarted(endsAt: at(625), reason: .needsInput, stateVersion: 0)])
        #expect(m.phase == .countdown(endsAt: at(625), reason: .needsInput, closedSince: at(10)))
    }

    @Test func countdownElapsesIntoTheWindDown() {
        var m = countingDown()
        #expect(m.step(inputs(319) { $0.lid = .closed }).isEmpty)
        #expect(m.step(inputs(320) { $0.lid = .closed }) == [.windDown(.countdownElapsed, shutdown: false)])
        #expect(m.phase == .windingDown(reason: .countdownElapsed, since: at(320)))
        #expect(m.windDownFromArmed)
        #expect(!m.isClosedLidAwake)
    }

    @Test func countdownReturnsToClosedAwakeWhenWorkResumesOrSomeoneIsThere() {
        var m = countingDown()
        #expect(m.step(inputs(100) { $0.lid = .closed; $0.anyWorking = true }) == [.countdownCancelled])
        #expect(m.phase == .closedAwake(since: at(10)))
        m = countingDown()
        #expect(m.step(inputs(320) { $0.lid = .closed; $0.userPresent = true }) == [.countdownCancelled])
        #expect(m.phase == .closedAwake(since: at(10)))
    }

    @Test func aSessionStartingToWaitUpgradesAFinishCountdown() {
        var m = countingDown()
        #expect(m.step(inputs(100) { $0.lid = .closed; $0.anyWaiting = true; $0.waitingGraceActive = true })
                == [.countdownStarted(endsAt: at(700), reason: .needsInput, stateVersion: 0)])
        #expect(m.phase == .countdown(endsAt: at(700), reason: .needsInput, closedSince: at(10)))
        #expect(m.step(inputs(200) { $0.lid = .closed; $0.anyWaiting = true; $0.waitingGraceActive = true }).isEmpty)
    }

    @Test func shutdownEndActionGoesThroughTheGraceUnlessASessionWaits() {
        var m = countingDown(endAction: .shutdown)
        #expect(m.step(inputs(320) { $0.lid = .closed; $0.endAction = .shutdown; $0.stateVersion = 3 })
                == [.shutdownPending(at: at(380), requestedFromPhone: false)])
        #expect(m.phase == .shutdownPending(at: at(380), requestedFromPhone: false))
        #expect(m.step(inputs(380) { $0.lid = .closed; $0.endAction = .shutdown; $0.stateVersion = 3 })
                == [.windDown(.countdownElapsed, shutdown: true)])

        // Opt-in shutdown but a session waits for input: sleep instead, without a "Shutting down" grace (§7.5).
        var waiting = closedAwake()
        let waitingInputs: (inout PowerInputs) -> Void = {
            $0.lid = .closed
            $0.anyWaiting = true
            $0.countdownReason = .needsInput
            $0.endAction = .shutdown
        }
        #expect(waiting.step(inputs(20, waitingInputs)) == [.countdownStarted(endsAt: at(620), reason: .needsInput, stateVersion: 0)])
        #expect(waiting.step(inputs(620, waitingInputs)) == [.windDown(.countdownElapsed, shutdown: false)])
    }

    @Test func safetyTripsPushFirstThenWindDownFromEveryClosedLidPhase() {
        let trip = SafetyTrip.thermalCritical
        var m = closedAwake()
        #expect(m.step(inputs(30) { $0.lid = .closed; $0.anyWorking = true; $0.safetyTrip = trip })
                == [.safetyTripped(trip), .windDown(.safetyTrip(trip), shutdown: false)])
        m = countingDown()
        #expect(m.step(inputs(30) { $0.lid = .closed; $0.safetyTrip = trip })
                == [.safetyTripped(trip), .windDown(.safetyTrip(trip), shutdown: false)])
        m = closedAwake()
        _ = m.requestShutdown(fromPhone: true, inputs(20) { $0.lid = .closed })
        #expect(m.step(inputs(30) { $0.lid = .closed; $0.safetyTrip = trip })
                == [.safetyTripped(trip), .windDown(.safetyTrip(trip), shutdown: false)])
        #expect(m.pendingShutdown == nil)
    }

    @Test func closedAwakeWithoutProtectionSleepsRatherThanStayingAwakeUnmonitored() {
        var m = closedAwake()
        #expect(m.step(inputs(30) { $0.lid = .closed; $0.anyWorking = true; $0.armingAllowed = false })
                == [.windDown(.countdownElapsed, shutdown: false)])
    }

    // MARK: Shutdown grace

    @Test func shutdownGraceExecutesOnlyWithAnUnchangedStateVersion() {
        var m = closedAwake()
        #expect(m.requestShutdown(fromPhone: true, inputs(20) { $0.lid = .closed; $0.stateVersion = 9 })
                == [.shutdownPending(at: at(80), requestedFromPhone: true)])
        #expect(m.requestShutdown(fromPhone: true, inputs(21) { $0.lid = .closed; $0.stateVersion = 9 }).isEmpty)
        #expect(m.step(inputs(79) { $0.lid = .closed; $0.stateVersion = 9 }).isEmpty)
        #expect(m.step(inputs(80) { $0.lid = .closed; $0.stateVersion = 9 }) == [.windDown(.remoteShutdown, shutdown: true)])
        #expect(m.windDownFromArmed)

        m = closedAwake()
        _ = m.requestShutdown(fromPhone: true, inputs(20) { $0.lid = .closed; $0.stateVersion = 9 })
        #expect(m.step(inputs(80) { $0.lid = .closed; $0.stateVersion = 10; $0.anyWorking = true }) == [.shutdownCancelled(stale: true)])
        #expect(m.phase == .closedAwake(since: at(10)))
    }

    @Test func shutdownGraceIsCancelledByMenuKeepAwakeAndLidOpen() {
        var m = closedAwake()
        _ = m.requestShutdown(fromPhone: true, inputs(20) { $0.lid = .closed })
        #expect(m.cancelWindDown(inputs(30) { $0.lid = .closed }) == [.shutdownCancelled(stale: false)])
        #expect(m.phase == .closedAwake(since: at(10)))

        _ = m.requestShutdown(fromPhone: true, inputs(40) { $0.lid = .closed })
        #expect(m.keepAwakeRequested(inputs(41) { $0.lid = .closed; $0.keepAwakeUntil = at(3641) }) == [.shutdownCancelled(stale: false)])

        _ = m.requestShutdown(fromPhone: true, inputs(50) { $0.lid = .closed })
        #expect(m.step(inputs(55) { $0.anyWorking = true }) == [.lidOpened(.lidOpened), .shutdownCancelled(stale: false)])
        #expect(m.phase == .armed(since: at(55)))
    }

    @Test func aShutdownGraceRequestedWhileDisarmedCancelsBackToDisarmed() {
        var m = PowerStateMachine(now: t0)
        _ = m.requestShutdown(fromPhone: true, inputs(1))
        #expect(m.cancelWindDown(inputs(2)) == [.shutdownCancelled(stale: false)])
        #expect(m.phase == .disarmed)
    }

    @Test func sleepRequestReplacesAShutdownGrace() {
        var m = closedAwake()
        _ = m.requestShutdown(fromPhone: true, inputs(20) { $0.lid = .closed })
        #expect(m.requestSleep(.remoteSleep, inputs(25) { $0.lid = .closed })
                == [.shutdownCancelled(stale: false), .windDown(.remoteSleep, shutdown: false)])
        #expect(m.requestSleep(.userSleepNow, inputs(26) { $0.lid = .closed }).isEmpty) // already winding down
    }

    // MARK: Wind-down cancellation

    @Test func keepAwakeCancelsCountdownsAndUncommittedWindDowns() {
        var m = countingDown()
        #expect(m.keepAwakeRequested(inputs(100) { $0.lid = .closed }) == [.countdownCancelled])
        #expect(m.phase == .closedAwake(since: at(10)))

        m = countingDown()
        _ = m.step(inputs(320) { $0.lid = .closed })
        #expect(m.keepAwakeRequested(inputs(321) { $0.lid = .closed; $0.windDown = .running(disarmed: false) }) == [.cancelWindDown])
        #expect(m.phase == .closedAwake(since: at(10)))

        m = countingDown()
        _ = m.step(inputs(320) { $0.lid = .closed })
        #expect(m.keepAwakeRequested(inputs(325) { $0.lid = .closed; $0.windDown = .running(disarmed: true) }) == [.cancelWindDown])
        #expect(m.phase == .disarmed) // the flag is already clear; the next step re-arms

        m = countingDown()
        _ = m.step(inputs(320) { $0.lid = .closed })
        #expect(m.keepAwakeRequested(inputs(330) { $0.lid = .closed; $0.windDown = .committed }).isEmpty)
        #expect(m.isWindingDown)
    }

    @Test func lidOpenCancelsAnUncommittedWindDown() {
        var m = countingDown()
        _ = m.step(inputs(320) { $0.lid = .closed })
        #expect(m.step(inputs(322) { $0.windDown = .running(disarmed: false) }) == [.lidOpened(.lidOpened), .cancelWindDown])
        #expect(m.phase == .armed(since: at(322)))
        // … then idles out normally.
        #expect(m.step(inputs(322)).isEmpty)
        #expect(m.step(inputs(442)) == [.disarm(.idle)])
    }

    @Test func aCommittedWindDownCannotBeCancelled() {
        var m = countingDown()
        _ = m.step(inputs(320) { $0.lid = .closed })
        #expect(m.step(inputs(330) { $0.windDown = .committed }) == [.lidOpened(.lidOpened)])
        #expect(m.isWindingDown)
        #expect(m.cancelWindDown(inputs(331) { $0.windDown = .committed }).isEmpty)
    }

    @Test func awaitingShutdownAbandonsOnlyTheSleepFallback() {
        var m = closedAwake()
        _ = m.requestShutdown(fromPhone: true, inputs(20) { $0.lid = .closed })
        _ = m.step(inputs(80) { $0.lid = .closed })
        #expect(m.cancelWindDown(inputs(90) { $0.lid = .closed; $0.windDown = .awaitingShutdown }) == [.cancelWindDown])
        #expect(m.phase == .disarmed)
    }

    @Test func cancellingAWindDownThatBeganDisarmedReturnsToDisarmed() {
        var m = PowerStateMachine(now: t0)
        #expect(m.requestSleep(.userSleepNow, inputs(1)) == [.windDown(.userSleepNow, shutdown: false)])
        #expect(!m.windDownFromArmed)
        #expect(m.cancelWindDown(inputs(2) { $0.windDown = .running(disarmed: false) }) == [.cancelWindDown])
        #expect(m.phase == .disarmed)
    }

    // MARK: Reports

    @Test func armFailureDropsBackToDisarmed() {
        var m = armed()
        m.armFailed()
        #expect(m.phase == .disarmed)
    }

    @Test func aSleepThatDidNotHappenRetriesAMinuteLaterWhileTheLidStaysClosed() {
        var m = countingDown()
        _ = m.step(inputs(320) { $0.lid = .closed })
        m.sleepDidNotHappen(now: at(400))
        #expect(m.phase == .disarmed)
        #expect(m.sleepRetryAt == at(460))
        #expect(m.step(inputs(459) { $0.lid = .closed }).isEmpty)
        #expect(m.step(inputs(460) { $0.lid = .closed }) == [.windDown(.countdownElapsed, shutdown: false)])

        m.sleepDidNotHappen(now: at(500))
        #expect(m.step(inputs(510)) == [.lidOpened(.lidOpened)]) // the lid opened: no retry
        #expect(m.sleepRetryAt == nil)
        #expect(m.step(inputs(600)).isEmpty)
    }

    @Test func forceDisarmedClearsEverything() {
        var m = closedAwake()
        _ = m.requestShutdown(fromPhone: false, inputs(20) { $0.lid = .closed })
        m.forceDisarmed()
        #expect(m.phase == .disarmed)
        #expect(m.pendingShutdown == nil)
        #expect(m.sleepRetryAt == nil)
    }
}
