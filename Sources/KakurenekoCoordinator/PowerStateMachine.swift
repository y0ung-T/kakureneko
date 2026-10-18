// The §7.3 power state machine (brief) as a PURE value type, plus the predicates of ARCHITECTURE §9.8 that
// replace the brief's undefined "waiting grace" (§11 item 18). No I/O, no clock, no services: the coordinator
// builds `PowerInputs` from the latest service state, calls `step`/the request functions, and executes the
// returned `PowerAction`s in order. Every transition is unit-testable with explicit dates.

import KakurenekoKit
import Foundation

// MARK: - Predicates

/// The coordinator's decision predicates (ARCHITECTURE §9.8 "Predicates"). Pure functions of their inputs.
enum PowerPredicates {
    /// Some session is `.waiting(_, since)` with `since + timers.needsInputCountdown > now`.
    static func waitingGraceActive(sessions: [AgentSession], timers: SessionTimers, now: Date) -> Bool {
        sessions.contains { session in
            guard case .waiting(_, let since) = session.state else { return false }
            return since.addingTimeInterval(timers.needsInputCountdown) > now
        }
    }

    /// A keep-awake override is in force.
    static func keepAwakeActive(_ until: Date?, now: Date) -> Bool {
        guard let until else { return false }
        return until > now
    }

    /// `anyWorking || waitingGraceActive || keepAwakeUntil > now` — drives Disarmed → Armed and blocks the
    /// 2-min Armed → Disarmed (a waiting session keeps the flag set so a closing lid does not sleep at once).
    static func shouldStayArmed(anyWorking: Bool, waitingGraceActive: Bool, keepAwakeUntil: Date?, now: Date) -> Bool {
        anyWorking || waitingGraceActive || keepAwakeActive(keepAwakeUntil, now: now)
    }

    /// `!anyWorking && !(keepAwakeUntil > now)` — drives ClosedAwake → Countdown.
    static func shouldCountDown(anyWorking: Bool, keepAwakeUntil: Date?, now: Date) -> Bool {
        !anyWorking && !keepAwakeActive(keepAwakeUntil, now: now)
    }

    /// `lid == .closed && !externalDisplayConnected` (clamshell desktop counts as OPEN).
    static func effectiveLidClosed(lid: LidState, externalDisplayConnected: Bool) -> Bool {
        lid == .closed && !externalDisplayConnected
    }

    /// Recent user input: a known reading `< awayIdleSeconds`; an UNKNOWN reading counts as present only while the
    /// lid is effectively open (Kit `Presence.hasRecentInput`, the one rule shared with notification gating). The
    /// countdown predicates only consult it with the lid closed, so a missing reading never blocks a countdown.
    static func userPresent(secondsSinceUserInput: TimeInterval?, awayIdleSeconds: Int, effectiveLidClosed: Bool) -> Bool {
        Presence.hasRecentInput(secondsSinceUserInput: secondsSinceUserInput, idleThreshold: TimeInterval(awayIdleSeconds),
                                lidClosed: effectiveLidClosed)
    }

    /// Countdown length: `anyWaiting ? needsInputCountdown : finishCountdown`.
    static func countdownLength(anyWaiting: Bool, timers: SessionTimers) -> TimeInterval {
        anyWaiting ? timers.needsInputCountdown : timers.finishCountdown
    }

    /// `.needsInput` if anything waits; `.wentQuiet` if every turn that ended since the lid closed belongs to a
    /// heuristic-only session (and at least one did); else `.finished`.
    static func countdownReason(anyWaiting: Bool, endedTurnsSinceLidClosed: [SessionEffect]) -> CountdownReason {
        if anyWaiting { return .needsInput }
        if !endedTurnsSinceLidClosed.isEmpty, endedTurnsSinceLidClosed.allSatisfy({ $0.session.isHeuristicOnly }) {
            return .wentQuiet
        }
        return .finished
    }
}

// MARK: - Inputs and actions

/// Where the wind-down task is (the machine never runs it; the coordinator reports its progress).
enum WindDownProgress: Sendable, Hashable {
    /// No wind-down task exists.
    case none
    /// Draining / thawing / waiting / disarming — still cancellable. `disarmed` is set just BEFORE
    /// `power.disarm()` is awaited (a cancel during the call must assume the flag is clear).
    case running(disarmed: Bool)
    /// `requestShutdown()` was sent (flag already clear); waiting up to 3 min for the Mac to go down before
    /// falling back to `sleepNow()`. Lid open, keep-awake and Cancel abandon the fallback (the user is here).
    case awaitingShutdown
    /// `sleepNow()` was called: no longer cancellable, wait for the wake (or the sleep-confirmation timeout).
    case committed
}

/// Everything one step looks at, computed by the coordinator at `now`.
struct PowerInputs: Sendable, Hashable {
    var now: Date
    var lid: LidState
    var externalDisplayConnected: Bool
    var anyWorking: Bool
    var anyWaiting: Bool
    var waitingGraceActive: Bool
    var keepAwakeUntil: Date?
    var userPresent: Bool
    /// Policy: mode `.full` ∧ `general.enabled` ∧ `power.keepAwakeWithLidClosed` (never in notifications-only/disabled).
    var armingAllowed: Bool
    /// A recent `arm()` failure: do not retry yet (Disarmed only).
    var armBackoff: Bool
    /// `safety.armingBlocker(snapshot, settings.safety)` (stateless; nil = allowed or unknown).
    var armingBlocker: SafetyTrip?
    /// `safety.evaluate(…)` result when it was due this step (closed-lid phases only), else nil.
    var safetyTrip: SafetyTrip?
    var timers: SessionTimers
    var countdownReason: CountdownReason
    var endAction: EndAction
    var stateVersion: Int
    var windDown: WindDownProgress

    init(
        now: Date,
        lid: LidState = .open,
        externalDisplayConnected: Bool = false,
        anyWorking: Bool = false,
        anyWaiting: Bool = false,
        waitingGraceActive: Bool = false,
        keepAwakeUntil: Date? = nil,
        userPresent: Bool = false,
        armingAllowed: Bool = true,
        armBackoff: Bool = false,
        armingBlocker: SafetyTrip? = nil,
        safetyTrip: SafetyTrip? = nil,
        timers: SessionTimers = SessionTimers(),
        countdownReason: CountdownReason = .finished,
        endAction: EndAction = .sleep,
        stateVersion: Int = 0,
        windDown: WindDownProgress = .none
    ) {
        self.now = now
        self.lid = lid
        self.externalDisplayConnected = externalDisplayConnected
        self.anyWorking = anyWorking
        self.anyWaiting = anyWaiting
        self.waitingGraceActive = waitingGraceActive
        self.keepAwakeUntil = keepAwakeUntil
        self.userPresent = userPresent
        self.armingAllowed = armingAllowed
        self.armBackoff = armBackoff
        self.armingBlocker = armingBlocker
        self.safetyTrip = safetyTrip
        self.timers = timers
        self.countdownReason = countdownReason
        self.endAction = endAction
        self.stateVersion = stateVersion
        self.windDown = windDown
    }

    var effectiveLidClosed: Bool {
        PowerPredicates.effectiveLidClosed(lid: lid, externalDisplayConnected: externalDisplayConnected)
    }
    var keepAwakeActive: Bool { PowerPredicates.keepAwakeActive(keepAwakeUntil, now: now) }
    var shouldStayArmed: Bool {
        PowerPredicates.shouldStayArmed(anyWorking: anyWorking, waitingGraceActive: waitingGraceActive,
                                        keepAwakeUntil: keepAwakeUntil, now: now)
    }
    var shouldCountDown: Bool { PowerPredicates.shouldCountDown(anyWorking: anyWorking, keepAwakeUntil: keepAwakeUntil, now: now) }
    var countdownLength: TimeInterval { PowerPredicates.countdownLength(anyWaiting: anyWaiting, timers: timers) }
}

/// Why the machine asks for a disarm.
enum DisarmCause: Sendable, Hashable {
    /// Armed with the lid open and nothing to hold awake for `disarmLidOpen`.
    case idle
    /// `armingBlocker` tripped while Armed with the lid open.
    case blocked(SafetyTrip)
    /// The policy no longer allows arming (mode, master switch, setting).
    case notAllowed
}

/// What the coordinator must do, in order.
enum PowerAction: Sendable, Hashable {
    /// `power.arm()` (+ heartbeat). On failure the coordinator calls `armFailed`.
    case arm
    case disarm(DisarmCause)
    /// Entered ClosedAwake on the effective lid-close edge: display sleep, the chime (`lidCloseSound`), safety reset,
    /// start the 15 s safety cadence, start the pause settle clock.
    case lidClosedAwake
    /// Effective lid-open edge (lid opened, or an external display connected while closed): thaw with this reason.
    case lidOpened(ThawReason)
    /// Submit the countdown intent (once per entry). `stateVersion` = the `sv` the decision was made at: the
    /// push's Sleep-now/Shut-down buttons are signed with it, never with a newer one (the push is sent after
    /// awaits, by which time another agent may have started a turn and cancelled this countdown).
    case countdownStarted(endsAt: Date, reason: CountdownReason, stateVersion: Int)
    case countdownCancelled
    /// Submit `.shuttingDown`.
    case shutdownPending(at: Date, requestedFromPhone: Bool)
    /// The grace ended without shutting down. `stale` = the state version moved (submit `.commandIgnored`).
    case shutdownCancelled(stale: Bool)
    /// Push the trip BEFORE winding down.
    case safetyTripped(SafetyTrip)
    /// Start the ONE wind-down task.
    case windDown(WindDownReason, shutdown: Bool)
    /// Cancel the running wind-down task (it has not reached `sleepNow`/`requestShutdown`).
    case cancelWindDown
    /// Arming refused / armed state dropped because of a stateless blocker (`AppWarning(id: "arming-blocked")`).
    case armingBlocked(SafetyTrip)
}

// MARK: - The machine

/// Brief §7.3 with the ARCHITECTURE §9.8 refinements. Owned by the coordinator actor; a plain value type.
struct PowerStateMachine: Sendable, Hashable {
    /// The phone "Shut down" grace (brief §8.3: "Shutting down in 60 s").
    static let shutdownGrace: TimeInterval = 60
    /// After a sleep attempt that did not take, try again this much later while the lid stays closed.
    static let sleepRetryDelay: TimeInterval = 60

    struct PendingShutdown: Sendable, Hashable {
        /// `sv` at request time; re-checked at the deadline.
        var stateVersion: Int
        var requestedFromPhone: Bool
        /// Whether the flag was (expected to be) set when the grace began — decides where a cancel returns to.
        var wasArmed: Bool
    }

    private(set) var phase: PowerPhase = .disarmed
    /// Last effective lid state seen by `step` (edges are detected against it).
    private(set) var effectiveLidClosed: Bool
    /// Start of the current effective closed-lid period.
    private(set) var closedSince: Date?
    /// Armed with the lid open and `!shouldStayArmed` since.
    private(set) var idleSince: Date?
    private(set) var pendingShutdown: PendingShutdown?
    /// Disarmed with the lid closed after a sleep that did not happen: wind down again at this time.
    private(set) var sleepRetryAt: Date?
    /// Whether the flag was (expected to be) set when the current wind-down began: a wind-down cancelled
    /// before its `disarm()` returns there, one started from Disarmed (menu "Sleep now") returns to Disarmed.
    private(set) var windDownFromArmed = false

    /// Set by every Kakureneko-initiated wind-down (countdown, menu/phone sleep, safety trip, shutdown and its sleep
    /// fallback). While it holds and the effective lid is closed, Disarmed never re-arms: macOS dark-wakes the Mac
    /// in the bag (Power Nap, maintenance — `kIOMessageSystemHasPoweredOn` every ~15 min on battery), and the
    /// agent that was mid-turn when the user asked to sleep is usually still `.working` then. Released by the
    /// effective lid opening (edge, or Disarmed with the lid open), an explicit keep-awake request, or — except
    /// after a safety trip — a NEW turn (`stateVersion` beyond the one recorded here). A wind-down that is
    /// cancelled before the sleep (the user is at the Mac) drops it.
    struct RearmLatch: Sendable, Hashable {
        var stateVersion: Int
        /// A safety trip: only the lid opening releases it (never a new turn or a keep-awake).
        var safetyTrip: Bool
    }
    private(set) var rearmLatch: RearmLatch?

    /// Starts Disarmed with the given effective lid state (no edge is generated for the initial state).
    init(effectiveLidClosed: Bool = false, now: Date) {
        self.effectiveLidClosed = effectiveLidClosed
        self.closedSince = effectiveLidClosed ? now : nil
    }

    /// True in the phases where the lid is closed and the Mac is held awake (safety evaluation, pausing).
    var isClosedLidAwake: Bool {
        switch phase {
        case .closedAwake, .countdown, .shutdownPending: effectiveLidClosed
        case .disarmed, .armed, .windingDown: false
        }
    }

    var isWindingDown: Bool { if case .windingDown = phase { true } else { false } }

    // MARK: Periodic step

    /// Edge handling (effective lid) first, then the level-triggered rules of the current phase.
    mutating func step(_ inputs: PowerInputs) -> [PowerAction] {
        var actions: [PowerAction] = []
        handleLidEdge(inputs, &actions)
        handleLevel(inputs, &actions)
        return actions
    }

    private mutating func handleLidEdge(_ i: PowerInputs, _ actions: inout [PowerAction]) {
        let closed = i.effectiveLidClosed
        guard closed != effectiveLidClosed else { return }
        effectiveLidClosed = closed
        idleSince = nil
        sleepRetryAt = nil
        if closed {
            closedSince = i.now
            if case .armed = phase {
                phase = .closedAwake(since: i.now)
                actions.append(.lidClosedAwake)
            }
            return
        }
        closedSince = nil
        rearmLatch = nil
        actions.append(.lidOpened(i.lid == .closed ? .externalDisplay : .lidOpened))
        switch phase {
        case .closedAwake:
            phase = .armed(since: i.now)
        case .countdown:
            phase = .armed(since: i.now)
            actions.append(.countdownCancelled)
        case .shutdownPending:
            let wasArmed = pendingShutdown?.wasArmed ?? true
            pendingShutdown = nil
            phase = wasArmed ? .armed(since: i.now) : .disarmed
            actions.append(.shutdownCancelled(stale: false))
        case .windingDown:
            actions.append(contentsOf: cancelRunningWindDown(i))
        case .disarmed, .armed:
            break
        }
    }

    private mutating func handleLevel(_ i: PowerInputs, _ actions: inout [PowerAction]) {
        switch phase {
        case .disarmed:
            releaseRearmLatchIfDue(i)
            guard i.shouldStayArmed, rearmLatch == nil else {
                if effectiveLidClosed, let retry = sleepRetryAt, i.now >= retry {
                    sleepRetryAt = nil
                    beginWindDown(.countdownElapsed, shutdown: false, i, &actions)
                }
                return
            }
            sleepRetryAt = nil
            guard i.armingAllowed, !i.armBackoff else { return }
            if let blocker = i.armingBlocker {
                actions.append(.armingBlocked(blocker))
                return
            }
            idleSince = nil
            actions.append(.arm)
            if effectiveLidClosed {
                // Armed while the lid is already (effectively) closed: no lid-close edge to replay.
                closedSince = closedSince ?? i.now
                phase = .closedAwake(since: closedSince ?? i.now)
            } else {
                phase = .armed(since: i.now)
            }

        case .armed:
            if let trip = i.safetyTrip, i.lid == .closed, i.externalDisplayConnected, !i.userPresent {
                // Lid physically closed, a display keeps it "open" — which may be a virtual/AirPlay/Sidecar display
                // in a bag, not a desk: with nobody using the Mac the closed-lid guards still end in sleep.
                tripWindDown(trip, i, &actions)
            } else if !i.armingAllowed {
                phase = .disarmed
                idleSince = nil
                actions.append(.disarm(.notAllowed))
            } else if let blocker = i.armingBlocker {
                phase = .disarmed
                idleSince = nil
                actions.append(.disarm(.blocked(blocker)))
                actions.append(.armingBlocked(blocker))
            } else if i.shouldStayArmed {
                idleSince = nil
            } else {
                let since = idleSince ?? i.now
                idleSince = since
                if i.now.timeIntervalSince(since) >= i.timers.disarmLidOpen {
                    phase = .disarmed
                    idleSince = nil
                    actions.append(.disarm(.idle))
                }
            }

        case .closedAwake(let since):
            if let trip = i.safetyTrip {
                tripWindDown(trip, i, &actions)
            } else if !i.armingAllowed {
                // Closed lid without Kakureneko's protection: sleep rather than stay awake unmonitored.
                beginWindDown(.countdownElapsed, shutdown: false, i, &actions)
            } else if i.shouldCountDown && !i.userPresent {
                let endsAt = i.now.addingTimeInterval(i.countdownLength)
                phase = .countdown(endsAt: endsAt, reason: i.countdownReason, closedSince: since)
                actions.append(.countdownStarted(endsAt: endsAt, reason: i.countdownReason, stateVersion: i.stateVersion))
            }

        case .countdown(let endsAt, let reason, let closedSince):
            if let trip = i.safetyTrip {
                tripWindDown(trip, i, &actions)
            } else if !i.armingAllowed {
                beginWindDown(.countdownElapsed, shutdown: false, i, &actions)
            } else if i.anyWorking || i.keepAwakeActive {
                phase = .closedAwake(since: closedSince)
                actions.append(.countdownCancelled)
            } else if i.anyWaiting, reason != .needsInput {
                // A session started waiting during a finish countdown (no working edge seen in between): the
                // countdown becomes the needs-input one (brief §7.3: T = anyWaiting ? 10 min : 5 min), never shorter.
                let upgraded = max(endsAt, i.now.addingTimeInterval(i.timers.needsInputCountdown))
                phase = .countdown(endsAt: upgraded, reason: .needsInput, closedSince: closedSince)
                actions.append(.countdownStarted(endsAt: upgraded, reason: .needsInput, stateVersion: i.stateVersion))
            } else if i.now >= endsAt {
                if i.userPresent {
                    // Someone is using the Mac (e.g. Screen Sharing): start over once they leave.
                    phase = .closedAwake(since: closedSince)
                    actions.append(.countdownCancelled)
                } else if i.endAction == .shutdown, !i.anyWaiting {
                    actions.append(contentsOf: enterShutdownPending(fromPhone: false, i))
                } else {
                    // Sleep (default), or shutdown opted in but a session waits for input (brief §7.5 fallback).
                    beginWindDown(.countdownElapsed, shutdown: false, i, &actions)
                }
            }

        case .shutdownPending(let at, let fromPhone):
            if let trip = i.safetyTrip, effectiveLidClosed {
                tripWindDown(trip, i, &actions)
            } else if i.now >= at {
                if let pending = pendingShutdown, pending.stateVersion == i.stateVersion {
                    beginWindDown(fromPhone ? .remoteShutdown : .countdownElapsed, shutdown: true, i, &actions)
                } else {
                    // An agent became busy again during the grace (brief §8.3: `sv` re-checked at the deadline).
                    phase = (pendingShutdown?.wasArmed ?? true) ? lidImpliedArmedPhase(i) : .disarmed
                    pendingShutdown = nil
                    actions.append(.shutdownCancelled(stale: true))
                }
            }

        case .windingDown:
            break
        }
    }

    // MARK: Requests (menu / phone)

    /// User "Sleep now" (`.userSleepNow`) or a verified phone `sleep` (`.remoteSleep`, sv already checked).
    /// Ignored while already winding down; replaces a pending shutdown grace.
    mutating func requestSleep(_ reason: WindDownReason, _ i: PowerInputs) -> [PowerAction] {
        if isWindingDown { return [] }
        var actions: [PowerAction] = []
        if case .shutdownPending = phase { actions.append(.shutdownCancelled(stale: false)) }
        beginWindDown(reason, shutdown: false, i, &actions)
        return actions
    }

    /// Verified phone `shutdown` (sv + opt-in already checked) → the 60 s grace.
    mutating func requestShutdown(fromPhone: Bool, _ i: PowerInputs) -> [PowerAction] {
        switch phase {
        case .windingDown, .shutdownPending:
            return []
        case .disarmed, .armed, .closedAwake, .countdown:
            return enterShutdownPending(fromPhone: fromPhone, i)
        }
    }

    /// A keep-awake override (menu or phone) was just set: cancel a countdown, a shutdown grace and a wind-down
    /// not yet at `sleepNow`. (The override itself keeps Countdown from re-entering.)
    mutating func keepAwakeRequested(_ i: PowerInputs) -> [PowerAction] {
        if rearmLatch?.safetyTrip == false { rearmLatch = nil }
        switch phase {
        case .countdown(_, _, let closedSince):
            phase = .closedAwake(since: closedSince)
            return [.countdownCancelled]
        case .shutdownPending:
            return cancelShutdownPending(i)
        case .windingDown:
            return cancelRunningWindDown(i)
        case .disarmed, .armed, .closedAwake:
            return []
        }
    }

    /// Menu "Cancel": a shutdown grace or a cancellable wind-down returns to the phase the lid state implies.
    mutating func cancelWindDown(_ i: PowerInputs) -> [PowerAction] {
        switch phase {
        case .shutdownPending:
            return cancelShutdownPending(i)
        case .windingDown:
            return cancelRunningWindDown(i)
        case .disarmed, .armed, .closedAwake, .countdown:
            return []
        }
    }

    // MARK: Reports from the coordinator

    /// `power.arm()` threw: the flag is not set.
    mutating func armFailed() {
        switch phase {
        case .armed, .closedAwake, .countdown:
            phase = .disarmed
            idleSince = nil
        case .disarmed, .shutdownPending, .windingDown:
            break
        }
    }

    /// The wind-down could not put the Mac to sleep (or the sleep never happened): Disarmed, retry later while
    /// the lid stays closed.
    mutating func sleepDidNotHappen(now: Date) {
        phase = .disarmed
        idleSince = nil
        pendingShutdown = nil
        sleepRetryAt = effectiveLidClosed ? now.addingTimeInterval(Self.sleepRetryDelay) : nil
    }

    /// `.didWake`: a Kakureneko-initiated sleep ends in Disarmed (brief §7.3 "on wake: Disarmed"). `kernelArmed`
    /// is the effective flag read after the wake; an armed phase whose flag was cleared meanwhile (root
    /// fail-safe) also drops to Disarmed.
    mutating func didWake(kernelArmed: Bool?) {
        sleepRetryAt = nil
        idleSince = nil
        switch phase {
        case .windingDown:
            phase = .disarmed
            pendingShutdown = nil
        case .armed, .closedAwake, .countdown, .shutdownPending:
            if kernelArmed == false {
                phase = .disarmed
                pendingShutdown = nil
            }
        case .disarmed:
            break
        }
    }

    /// Master switch off, dry-run toggle, termination, privileged uninstall: the coordinator disarmed directly.
    mutating func forceDisarmed() {
        phase = .disarmed
        idleSince = nil
        pendingShutdown = nil
        sleepRetryAt = nil
        rearmLatch = nil
    }

    // MARK: Helpers

    private func lidImpliedArmedPhase(_ i: PowerInputs) -> PowerPhase {
        effectiveLidClosed ? .closedAwake(since: closedSince ?? i.now) : .armed(since: i.now)
    }

    private mutating func enterShutdownPending(fromPhone: Bool, _ i: PowerInputs) -> [PowerAction] {
        let at = i.now.addingTimeInterval(Self.shutdownGrace)
        pendingShutdown = PendingShutdown(stateVersion: i.stateVersion, requestedFromPhone: fromPhone, wasArmed: phase.isArmed)
        phase = .shutdownPending(at: at, requestedFromPhone: fromPhone)
        idleSince = nil
        return [.shutdownPending(at: at, requestedFromPhone: fromPhone)]
    }

    private mutating func cancelShutdownPending(_ i: PowerInputs) -> [PowerAction] {
        let wasArmed = pendingShutdown?.wasArmed ?? true
        pendingShutdown = nil
        phase = wasArmed ? lidImpliedArmedPhase(i) : .disarmed
        return [.shutdownCancelled(stale: false)]
    }

    private mutating func cancelRunningWindDown(_ i: PowerInputs) -> [PowerAction] {
        switch i.windDown {
        case .committed:
            return []
        case .running(let disarmed):
            // After `disarm()` (or when the wind-down began Disarmed) the flag is clear: Disarmed — the next step
            // re-arms if anything still needs it.
            rearmLatch = nil
            phase = (disarmed || !windDownFromArmed) ? .disarmed : lidImpliedArmedPhase(i)
            return [.cancelWindDown]
        case .awaitingShutdown:
            // The shutdown request is out (it cannot be recalled); only the sleep fallback is abandoned.
            rearmLatch = nil
            phase = .disarmed
            return [.cancelWindDown]
        case .none:
            // The wind-down was decided but its task has not started yet (the coordinator is still submitting the
            // trip push): nothing has disarmed, so the flag is as it was when the wind-down began. Cancel the
            // (late) task and return to where that flag state belongs — never to Disarmed with the flag set.
            rearmLatch = nil
            phase = windDownFromArmed ? lidImpliedArmedPhase(i) : .disarmed
            return [.cancelWindDown]
        }
    }

    /// Releases `rearmLatch` when the effective lid is open, or — not after a safety trip — when a new turn began.
    private mutating func releaseRearmLatchIfDue(_ i: PowerInputs) {
        guard let latch = rearmLatch else { return }
        if !effectiveLidClosed || (!latch.safetyTrip && i.stateVersion > latch.stateVersion) {
            rearmLatch = nil
        }
    }

    private mutating func tripWindDown(_ trip: SafetyTrip, _ i: PowerInputs, _ actions: inout [PowerAction]) {
        actions.append(.safetyTripped(trip))
        beginWindDown(.safetyTrip(trip), shutdown: false, i, &actions)
    }

    /// Whether the flag is expected set in the current phase (a shutdown grace remembers where it came from).
    private var flagExpectedSet: Bool {
        if case .shutdownPending = phase { return pendingShutdown?.wasArmed ?? true }
        return phase.isArmed
    }

    private mutating func beginWindDown(_ reason: WindDownReason, shutdown: Bool, _ i: PowerInputs, _ actions: inout [PowerAction]) {
        windDownFromArmed = flagExpectedSet
        var isSafetyTrip = false
        if case .safetyTrip = reason { isSafetyTrip = true }
        rearmLatch = RearmLatch(stateVersion: i.stateVersion, safetyTrip: isSafetyTrip || rearmLatch?.safetyTrip == true)
        pendingShutdown = nil
        phase = .windingDown(reason: reason, since: i.now)
        idleSince = nil
        actions.append(.windDown(reason, shutdown: shutdown))
    }
}
