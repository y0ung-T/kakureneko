import KakurenekoCloud
@testable import KakurenekoNotify
import KakurenekoKit
import Foundation
import Testing

@Suite("Outbox, backoff and persistence", .timeLimit(.minutes(1)))
struct OutboxAndStoreTests {
    func note(_ kind: NotificationKind, group: String, title: String = "t", expires: Date? = nil) -> OutgoingNotification {
        OutgoingNotification(kind: kind, title: title, body: "b", groupKey: group, createdAt: Fixtures.start, expiresAt: expires)
    }

    @Test func newestItemWithTheSameGroupKeyReplacesTheQueuedOne() {
        var outbox = Outbox()
        outbox.enqueue(note(.needsInput, group: "input:codex/x-1", title: "first"), now: Fixtures.start)
        outbox.enqueue(note(.stalled, group: "stalled:a"), now: Fixtures.start)
        let replaced = outbox.enqueue(note(.needsInput, group: "input:codex/x-1", title: "second"), now: Fixtures.start)
        #expect(replaced.map(\.notification.title) == ["first"])
        #expect(outbox.items.map(\.notification.title) == ["t", "second"]) // FIFO: the replacement goes last
    }

    @Test func countdownSupersedesQueuedFinishes() {
        var outbox = Outbox()
        outbox.enqueue(note(.finished, group: "finished:a"), now: Fixtures.start)
        outbox.enqueue(note(.wentQuiet, group: "quiet:b"), now: Fixtures.start)
        outbox.enqueue(note(.needsInput, group: "input:c"), now: Fixtures.start)
        outbox.enqueue(note(.countdown, group: "countdown"), now: Fixtures.start)
        #expect(outbox.items.map(\.notification.kind) == [.needsInput, .countdown])
    }

    @Test func expiredItemsAreDropped() {
        var outbox = Outbox()
        outbox.enqueue(note(.warning, group: "w", expires: Fixtures.start.addingTimeInterval(10)), now: Fixtures.start)
        outbox.enqueue(note(.asleep, group: "asleep"), now: Fixtures.start)
        #expect(outbox.removeExpired(now: Fixtures.start.addingTimeInterval(9)).isEmpty)
        #expect(outbox.removeExpired(now: Fixtures.start.addingTimeInterval(10)).map(\.notification.groupKey) == ["w"])
        #expect(outbox.count == 1)
    }

    @Test func sizeIsBounded() {
        var outbox = Outbox()
        for i in 0..<(Outbox.maximumItems + 5) { outbox.enqueue(note(.warning, group: "w\(i)"), now: Fixtures.start) }
        #expect(outbox.count == Outbox.maximumItems)
        #expect(outbox.items.first?.notification.groupKey == "w5")
    }

    @Test func retryBookkeeping() {
        var outbox = Outbox()
        let n = note(.warning, group: "w")
        outbox.enqueue(n, now: Fixtures.start)
        outbox.recordRetryableFailure(id: n.id, retryAt: Fixtures.start.addingTimeInterval(4), error: "retryable")
        #expect(outbox.item(id: n.id)?.attempts == 1)
        #expect(outbox.earliestAttempt() == Fixtures.start.addingTimeInterval(4))
        #expect(outbox.earliestAttempt(excluding: [n.id]) == nil)
        #expect(outbox.remove(id: n.id)?.id == n.id)
        #expect(outbox.isEmpty)
    }

    @Test func backoffIsExponentialWithFullJitterInsideItsBounds() {
        let upper: (ClosedRange<Double>) -> Double = { $0.upperBound }
        let lower: (ClosedRange<Double>) -> Double = { $0.lowerBound }
        #expect((1...10).map { BackoffPolicy.outbox.delay(afterFailures: $0, random: upper) } == [2, 4, 8, 16, 32, 64, 128, 256, 300, 300])
        #expect(BackoffPolicy.outbox.delay(afterFailures: 7, random: lower) == 2)
        #expect((1...8).map { BackoffPolicy.cloudPoll.delay(afterFailures: $0, random: upper) } == [15, 30, 60, 120, 240, 480, 600, 600])
        #expect(BackoffPolicy.cloudPoll.delay(afterFailures: 1_000, random: upper) == 600)
        for failures in 1...12 {
            let d = BackoffPolicy.cloudPoll.delay(afterFailures: failures) { Double.random(in: $0) }
            #expect(d >= 15 && d <= 600)
        }
    }

    @Test func outboxRoundTripsAndDecodesLossily() throws {
        let paths = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        let store = NotifyStore(paths: paths)
        let items = [OutboxItem(notification: note(.needsInput, group: "input:a"), enqueuedAt: Fixtures.start, attempts: 2,
                                nextAttemptAt: Fixtures.start.addingTimeInterval(8), lastError: "retryable"),
                     OutboxItem(notification: note(.countdown, group: "countdown"), enqueuedAt: Fixtures.start)]
        try store.saveOutbox(items)
        #expect(store.loadOutbox() == items)
        #expect(try posixPermissions(paths.outboxFile) == 0o600)

        // One corrupt item never loses the others.
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: paths.outboxFile)) as? [String: Any])
        var raw = try #require(json["items"] as? [[String: Any]])
        raw.insert(["notification": ["kind": "finished"]], at: 1)
        json["items"] = raw
        try JSONSerialization.data(withJSONObject: json).write(to: paths.outboxFile)
        #expect(store.loadOutbox() == items)

        try Data("not json".utf8).write(to: paths.outboxFile)
        #expect(store.loadOutbox().isEmpty)
    }

    @Test func stateRoundTripsAndIsTolerant() throws {
        let paths = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        let store = NotifyStore(paths: paths)
        let fresh = store.loadState()
        #expect(UUID(uuidString: fresh.macID) != nil, "a Mac id is created on first load")

        var state = NotifyPersistentState()
        state.changeToken = CloudChangeToken(data: Data("seq:9".utf8))
        state.seenCommands = ["c1": Fixtures.start.addingTimeInterval(60)]
        state.phones = ["p1": PhoneDevice(deviceID: "p1", name: "iPhone", model: "iPhone18,3", systemVersion: "26.6",
                                          appVersion: "1", alertsAuthorized: true, lastSeenAt: Fixtures.start)]
        state.noteSavedAlert("a1", createdAt: Fixtures.start)
        state.lastDeliveredAt = Fixtures.start
        state.lastCommandAt = Fixtures.start
        try store.saveState(state)
        #expect(store.loadState() == state)
        #expect(try posixPermissions(paths.notifyStateFile) == 0o600)

        // A v1 (ntfy) file, a bad Mac id and wrong types never fail a load.
        try Data(#"{"version":1,"lastMessageID":"msg1","seenNonces":{"n":1},"macID":"not-a-uuid","phones":"nope"}"#.utf8)
            .write(to: paths.notifyStateFile)
        let tolerant = store.loadState()
        #expect(UUID(uuidString: tolerant.macID) != nil)
        #expect(tolerant.phones.isEmpty && tolerant.changeToken == nil && tolerant.seenCommands.isEmpty)
        try Data("{".utf8).write(to: paths.notifyStateFile)
        #expect(store.loadState().phones.isEmpty)
    }

    @Test func replayCacheAndSavedAlertsArePruned() {
        var state = NotifyPersistentState()
        state.seenCommands = ["old": Fixtures.start, "live": Fixtures.start.addingTimeInterval(1)]
        state.pruneSeenCommands(now: Fixtures.start)
        #expect(Array(state.seenCommands.keys) == ["live"])
        for i in 0..<(NotifyPersistentState.maximumSavedAlerts + 5) { state.noteSavedAlert("a\(i)", createdAt: Fixtures.start) }
        #expect(state.savedAlerts.count == NotifyPersistentState.maximumSavedAlerts)
        #expect(state.savedAlerts.first?.id == "a5", "the oldest are forgotten first")
    }

    @Test func legacyNtfySecretsAreDeleted() throws {
        let paths = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        let store = NotifyStore(paths: paths)
        #expect(!store.removeLegacySecrets())
        try FileManager.default.createDirectory(at: paths.legacySecretsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version":1,"pairing":{"notifyTopic":"kakureneko_x"}}"#.utf8).write(to: paths.legacySecretsFile)
        #expect(store.removeLegacySecrets())
        #expect(!FileManager.default.fileExists(atPath: paths.legacySecretsFile.path(percentEncoded: false)))
    }
}

func posixPermissions(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
}
