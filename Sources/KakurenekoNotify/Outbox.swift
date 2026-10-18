import KakurenekoKit
import Foundation

/// One queued message plus its delivery bookkeeping (persisted in `outbox.json`).
struct OutboxItem: Sendable, Hashable, Codable, Identifiable {
    var notification: OutgoingNotification
    var enqueuedAt: Date
    /// Failed delivery attempts so far.
    var attempts: Int
    /// Not attempted by background drains before this time (backoff / `Retry-After`).
    var nextAttemptAt: Date
    /// Last retryable failure (diagnostics only; never contains secrets).
    var lastError: String?

    var id: UUID { notification.id }

    init(notification: OutgoingNotification, enqueuedAt: Date, attempts: Int = 0, nextAttemptAt: Date? = nil, lastError: String? = nil) {
        self.notification = notification
        self.enqueuedAt = enqueuedAt
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt ?? enqueuedAt
        self.lastError = lastError
    }
}

/// On-disk form of the outbox. Decoding is lossy per item: one corrupt entry never loses the others.
struct OutboxFile: Sendable, Codable {
    static let currentVersion = 1

    var version: Int = OutboxFile.currentVersion
    var items: [OutboxItem]

    init(items: [OutboxItem]) { self.items = items }

    private enum CodingKeys: String, CodingKey { case version, items }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = c.tolerantDecode(Int.self, forKey: .version, default: OutboxFile.currentVersion)
        let lossy = c.tolerantDecode([LossyItem].self, forKey: .items, default: [])
        items = lossy.compactMap(\.item)
    }

    private struct LossyItem: Decodable {
        let item: OutboxItem?
        init(from decoder: any Decoder) throws {
            item = try? OutboxItem(from: decoder)
        }
    }
}

/// Exponential backoff with full jitter and a floor: `random(base … min(cap, base·2^(n−1)))`.
struct BackoffPolicy: Sendable, Hashable {
    var base: TimeInterval
    var cap: TimeInterval

    /// Outbox items: 2 s → 5 min (brief §8.5).
    static let outbox = BackoffPolicy(base: 2, cap: 300)
    /// iCloud polls after a failure: 15 s → 10 min.
    static let cloudPoll = BackoffPolicy(base: 15, cap: 600)

    func delay(afterFailures failures: Int, random: (ClosedRange<Double>) -> Double) -> TimeInterval {
        let exponent = Double(min(max(0, failures - 1), 30))
        let upper = min(cap, base * pow(2, exponent))
        return random(base...max(base, upper))
    }
}

/// The persistent queue (R07 §14 "Outbox design"): FIFO, newest item with the same `groupKey` replaces the
/// queued one, a countdown also supersedes queued `finished`/`wentQuiet` items (it lists them), TTL drop at
/// `expiresAt`, bounded size. Pure state; the dispatcher persists it and performs delivery.
struct Outbox: Sendable {
    /// Hard bound on queued items (oldest dropped first).
    static let maximumItems = 100

    private(set) var items: [OutboxItem]

    init(items: [OutboxItem] = []) {
        self.items = items
    }

    var count: Int { items.count }
    var isEmpty: Bool { items.isEmpty }

    func item(id: UUID) -> OutboxItem? { items.first { $0.id == id } }

    /// Adds `notification` and returns the items it replaced or pushed out.
    @discardableResult
    mutating func enqueue(_ notification: OutgoingNotification, now: Date) -> [OutboxItem] {
        var removed: [OutboxItem] = []
        let superseded: (OutboxItem) -> Bool = { item in
            if item.notification.groupKey == notification.groupKey { return true }
            if notification.kind == .countdown {
                return item.notification.kind == .finished || item.notification.kind == .wentQuiet
            }
            return false
        }
        removed += items.filter(superseded)
        items.removeAll(where: superseded)
        items.append(OutboxItem(notification: notification, enqueuedAt: now))
        if items.count > Self.maximumItems {
            let overflow = items.count - Self.maximumItems
            removed += items.prefix(overflow)
            items.removeFirst(overflow)
        }
        return removed
    }

    /// Drops items whose `expiresAt` has passed and returns them.
    @discardableResult
    mutating func removeExpired(now: Date) -> [OutboxItem] {
        let expired = items.filter { $0.notification.expiresAt <= now }
        items.removeAll { $0.notification.expiresAt <= now }
        return expired
    }

    @discardableResult
    mutating func remove(id: UUID) -> OutboxItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    @discardableResult
    mutating func removeAll(where predicate: (OutboxItem) -> Bool) -> [OutboxItem] {
        let removed = items.filter(predicate)
        items.removeAll(where: predicate)
        return removed
    }

    /// Records a retryable failure: one more attempt, next attempt at `retryAt`.
    mutating func recordRetryableFailure(id: UUID, retryAt: Date, error: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].attempts += 1
        items[index].nextAttemptAt = retryAt
        items[index].lastError = error
    }

    /// Earliest `nextAttemptAt` among items not in `excluding`.
    func earliestAttempt(excluding: Set<UUID> = []) -> Date? {
        items.filter { !excluding.contains($0.id) }.map(\.nextAttemptAt).min()
    }
}
