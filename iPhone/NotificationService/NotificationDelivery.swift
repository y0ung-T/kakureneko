// Hands the notification extension's result to the system exactly once, from whichever path gets there first:
// the finished alert, or `serviceExtensionTimeWillExpire` with the best content built so far.

import os
import UserNotifications

/// Sendable by construction: its only stored property is a lock, and every access to the guarded state goes through
/// it. The state itself is not Sendable — UserNotifications' content handler is an unannotated ObjC block and
/// `UNNotificationContent` is not marked Sendable — hence `OSAllocatedUnfairLock(uncheckedState:)`. That is sound
/// here because the handler may be called from any thread (Apple's own template calls it from URLSession callbacks),
/// the lock serializes every use, and contents are never mutated once stored.
final class NotificationDelivery: Sendable {
    private struct State {
        var handler: ((UNNotificationContent) -> Void)?
        var best: UNNotificationContent
    }

    private let state: OSAllocatedUnfairLock<State>

    /// `fallback`: the push's own content, delivered if nothing better is ready in time.
    init(handler: @escaping (UNNotificationContent) -> Void, fallback: UNNotificationContent) {
        state = OSAllocatedUnfairLock(uncheckedState: State(handler: handler, best: fallback))
    }

    /// The best content so far (delivered by `deliver()`, or when time runs out).
    func improve(_ content: UNNotificationContent) {
        state.withLockUnchecked { $0.best = content }
    }

    /// Delivers the best content; later calls do nothing. The handler runs outside the lock (it is system code).
    func deliver() {
        let pending = state.withLockUnchecked { state -> (handler: (UNNotificationContent) -> Void, content: UNNotificationContent)? in
            guard let handler = state.handler else { return nil }
            state.handler = nil
            return (handler, state.best)
        }
        if let pending { pending.handler(pending.content) }
    }
}
