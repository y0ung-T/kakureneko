import KakurenekoCloud
import KakurenekoKit
import Foundation
import Testing

@Suite("Fakes, composition and preview controller", .timeLimit(.minutes(1)))
struct FakesAndControllerTests {
    @Test func fakeServiceSetComposes() async throws {
        let paths = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        let fakes = FakeServiceSet(paths: paths)
        let services = fakes.services
        #expect(services.paths == paths)
        try await services.power.arm()
        #expect(services.power.kernelFlags().sleepDisabled == true)
        #expect(fakes.power.count(.arm) == 1)
        _ = await services.pausing.thawAll(reason: .lidOpened)
        #expect(fakes.pausing.calls == [.thawAll(.lidOpened)])
        let now = fakes.clock.now()
        let disposition = await services.notifications.submit(.test, context: NotificationContext(now: now, presence: .away, stateVersion: 1))
        if case .queued = disposition {} else { Issue.record("expected queued") }
        #expect(fakes.notifications.submittedIntents == [.test])
    }

    @Test func fakeEventSourceDelivers() async {
        let source = FakeEventSource()
        let stream = source.events()
        let event = AgentEvent(id: "1", agent: .codex, event: .turnStarted, rawEventName: "UserPromptSubmit",
                               sessionKey: SessionKey(agent: .codex, id: "t"), occurredAt: Date(), receivedAt: Date())
        source.emit(event)
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == event)
        #expect(await source.lastEventSeen()[.codex] != nil)
    }

    @Test func previewControllerAppliesActions() async throws {
        let controller = PreviewKakurenekoController()
        let stream = controller.snapshots()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.sessions.count == 2)
        await controller.keepAwake(for: 3600)
        let next = await iterator.next()
        #expect(next?.keepAwakeUntil != nil)
        await controller.setNeverPause(bundleID: "com.spotify.client", true)
        #expect(await controller.currentSnapshot().settings.pausing.neverPauseBundleIDs == ["com.spotify.client"])
        #expect(await controller.requestNotificationPermission() == .authorized)
        #expect(await controller.currentSnapshot().notifications.macAuthorization == .authorized)
        #expect(await controller.currentSnapshot().notifications.phoneConnected)
        #expect(await controller.calls.contains("keepAwake(3600)"))
    }

    @Test func basicMatcherRecognisesMainCLIs() {
        let m = BasicAgentSignatureMatcher()
        #expect(m.match(ProcessDescriptor(executablePath: "/Users/x/.local/share/claude/versions/2.1.296", argv: ["claude"], comm: "2.1.296"))?.agent == .claude)
        #expect(m.match(ProcessDescriptor(executablePath: nil, argv: ["claude bg-spare"]))?.isInfrastructure == true)
        #expect(m.match(ProcessDescriptor(executablePath: nil, argv: ["claude", "daemon", "run"]))?.isInfrastructure == true)
        #expect(m.match(ProcessDescriptor(executablePath: nil, argv: ["ugrep", "-r"])) == nil)
        #expect(m.match(ProcessDescriptor(executablePath: "/opt/homebrew/bin/node", argv: ["node", "/usr/local/lib/node_modules/@openai/codex/bin/codex.js"]))?.agent == .codex)
        #expect(m.match(ProcessDescriptor(executablePath: "/bin/zsh", argv: ["-zsh"])) == nil)
    }

    @Test func staticProcessLookupLiveness() {
        let id = ProcessIdentity(pid: 10, startSec: 1, startUsec: 0)
        let lookup = StaticProcessLookup([id])
        #expect(lookup.isAlive(id))
        #expect(!lookup.isAlive(ProcessIdentity(pid: 10, startSec: 2, startUsec: 0))) // pid reused
        lookup.remove(pid: 10)
        #expect(!lookup.isAlive(id))
    }

    @Test func powerChangeAcknowledgerIsOneShot() {
        final class Counter: @unchecked Sendable { var n = 0 }
        let counter = Counter()
        let ack = PowerChangeAcknowledger { counter.n += 1 }
        ack.allow()
        ack.allow()
        #expect(counter.n == 1)
        #expect(ack.isAllowed)
    }
}
