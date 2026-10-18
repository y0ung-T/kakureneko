// Quitting (spec card §9.9): `applicationShouldTerminate` answers `.terminateLater`, awaits
// `prepareForTermination()` (cancel wind-down, thaw every paused app, disarm, flush the outbox, stop services) and
// only then replies `true`. A watchdog replies after `timeout` so a wedged service can never keep the app from
// quitting — but first it runs the controller's SYNCHRONOUS thaw + disarm (`terminateSynchronously`): a normal
// `NSApp` exit runs no signal handler, so nothing else would undo the pauses or clear the flag (the root fail-safe
// and `kakureneko-guard` remain the backstops).

import AppKit
import KakurenekoKit
import Foundation

final class TerminationFlow {
    /// Upper bound for `prepareForTermination` (it drains the outbox for ≤ 2 s).
    let timeout: Duration
    /// The watchdog's clock (tests inject a `TestClock`; production sleeps for real).
    private let clock: any KakurenekoClock
    private(set) var isTerminating = false
    private(set) var hasReplied = false
    private var prepareTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var reply: ((Bool) -> Void)?
    private var emergency: (() -> Void)?

    init(timeout: Duration = .seconds(6), clock: any KakurenekoClock = SystemClock()) {
        self.timeout = timeout
        self.clock = clock
    }

    /// Starts the shutdown sequence; `reply` is called exactly once (with `true`) on the main actor.
    /// - Parameter emergency: run (synchronously) before replying when the watchdog fired, i.e. `prepare` never finished.
    func begin(prepare: @escaping @Sendable () async -> Void, emergency: @escaping () -> Void = {},
               reply: @escaping (Bool) -> Void) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateLater }
        isTerminating = true
        self.reply = reply
        self.emergency = emergency
        prepareTask = Task { [weak self] in
            await prepare()
            self?.finish()
        }
        let timeout = timeout
        let clock = clock
        watchdogTask = Task { [weak self] in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            self?.finish(timedOut: true)
        }
        return .terminateLater
    }

    private func finish(timedOut: Bool = false) {
        guard !hasReplied else { return }
        hasReplied = true
        prepareTask?.cancel()
        watchdogTask?.cancel()
        let emergency = self.emergency
        self.emergency = nil
        if timedOut { emergency?() }
        let reply = self.reply
        self.reply = nil
        reply?(true)
    }
}
