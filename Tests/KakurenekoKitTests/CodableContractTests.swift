import KakurenekoCloud
import KakurenekoKit
import Foundation
import Testing

@Suite("Codable contracts", .timeLimit(.minutes(1)))
struct CodableContractTests {
    // MARK: AgentID

    @Test func agentIDTolerantDecodingAndAliases() throws {
        let decoded = try JSONDecoder().decode([AgentID].self, from: Data(#"["claude","continue","made-up-agent"]"#.utf8))
        #expect(decoded == [.claude, .continueCLI, .unknown])
        #expect(AgentID(label: "cursor-agent") == .cursor)
        #expect(AgentID(label: "KiloCode") == .kilo)
        #expect(AgentID(label: "rovodev") == .rovo)
        #expect(AgentID.claude.displayName == "Claude Code")
        #expect(AgentID.continueCLI.rawValue == "continue")
        // Dictionaries keyed by AgentID encode as JSON objects.
        let dict: [AgentID: Int] = [.codex: 1]
        let text = String(decoding: try JSONEncoder().encode(dict), as: UTF8.self)
        #expect(text == #"{"codex":1}"#)
        #expect(try JSONDecoder().decode([AgentID: Int].self, from: Data(text.utf8)) == dict)
    }

    // MARK: NormalizedEvent

    @Test func normalizedEventJSONShape() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let finished = String(decoding: try encoder.encode(NormalizedEvent.turnFinished(.rateLimited)), as: UTF8.self)
        #expect(finished == #"{"outcome":"rateLimited","type":"turnFinished"}"#)
        let waiting = String(decoding: try encoder.encode(NormalizedEvent.needsInput(.permission)), as: UTF8.self)
        #expect(waiting == #"{"kind":"permission","type":"needsInput"}"#)
        for event: NormalizedEvent in [.sessionStarted, .turnStarted, .activity, .turnFinished(.ambiguous), .needsInput(.question), .idleReminder, .sessionEnded] {
            let back = try JSONDecoder().decode(NormalizedEvent.self, from: try encoder.encode(event))
            #expect(back == event)
        }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(NormalizedEvent.self, from: Data(#"{"type":"explode"}"#.utf8)) }
    }

    // MARK: InboxHeader / InboxFile

    @Test func inboxHeaderDecodesBriefExample() throws {
        let line = #"""
        {"v":1,"agent":"claude","event":"Stop","ts":1791811783024,"pid":7940,"ppid":7938,"cwd":"/Users/x/proj","env":{"CLAUDE_PID":"96888","CLAUDE_CODE_SESSION_ID":"abc","CLAUDE_CODE_ENTRYPOINT":"cli","TERM_PROGRAM":"Apple_Terminal","__CFBundleIdentifier":"com.apple.Terminal"},"ancestry":[{"pid":96888,"startSec":1791810323,"startUsec":1234,"exe":"2.1.296","argv0":"claude"}],"someFutureField":true}
        """#
        let header = try JSONDecoder().decode(InboxHeader.self, from: Data(line.utf8))
        #expect(header.v == 1)
        #expect(header.agent == "claude")
        #expect(header.event == "Stop")
        #expect(header.ts == 1_791_811_783_024)
        #expect(header.pid == 7940 && header.ppid == 7938)
        #expect(header.cwd == "/Users/x/proj")
        #expect(header.env["CLAUDE_PID"] == "96888")
        #expect(header.ancestry.count == 1)
        #expect(header.ancestry[0].identity == ProcessIdentity(pid: 96888, startSec: 1_791_810_323, startUsec: 1234))
        #expect(header.ancestry[0].argv0 == "claude")
        #expect(header.ancestry[0].controllingTTY == nil)
        #expect(HostApp.from(environment: header.env)?.name == "Terminal")
        #expect(abs(header.date.timeIntervalSince1970 - 1_791_811_783.024) < 0.001)
    }

    @Test func inboxHeaderMinimalPrototypeFormat() throws {
        // R08's prototype header (no env/ancestry) must still decode.
        let line = #"{"v":1,"agent":"codex","event":"notify","ts":1,"pid":2,"ppid":3,"cwd":"/x"}"#
        let header = try JSONDecoder().decode(InboxHeader.self, from: Data(line.utf8))
        #expect(header.env.isEmpty && header.ancestry.isEmpty)
    }

    @Test func inboxFileRoundTripAndErrors() throws {
        let header = InboxHeader(agent: "codex", event: "notify", ts: 1_791_811_783_024, pid: 10, ppid: 9, cwd: "/w",
                                 payloadSource: "argv", env: ["CODEX_HOME": "/c"],
                                 ancestry: [InboxAncestor(pid: 9, ppid: 1, startSec: 5, startUsec: 6, exe: "codex", argv0: "codex", tdev: 268_435_460)])
        let payload = Data(#"{"type":"agent-turn-complete","thread-id":"t1","turn-id":"u1"}"#.utf8)
        let file = try InboxFile.serialize(header: header, payload: payload)
        let (parsedHeader, parsedPayload) = try InboxFile.parse(file)
        #expect(parsedHeader == header)
        #expect(parsedPayload == payload)
        // Payload is preserved byte for byte, including newlines.
        let multi = Data("{\n \"a\": 1\n}\n".utf8)
        #expect(try InboxFile.parse(try InboxFile.serialize(header: header, payload: multi)).payload == multi)
        // Empty payload.
        #expect(try InboxFile.parse(Data(#"{"agent":"a","event":"e","ts":1}"#.utf8) + Data([0x0A])).payload.isEmpty)
        #expect(throws: InboxFile.ParseError.noHeaderLine) { try InboxFile.parse(Data("no newline".utf8)) }
        #expect(throws: InboxFile.ParseError.self) { try InboxFile.parse(Data("not json\n{}".utf8)) }
    }

    @Test func inboxFileNames() {
        let name = InboxFile.fileName(epochNanoseconds: 1_791_811_783_024_000_123, pid: 7940)
        #expect(name == "1791811783024000123-7940.event")
        let padded = InboxFile.fileName(epochNanoseconds: 42, pid: 1)
        #expect(padded == "0000000000000000042-1.event")
        #expect(InboxFile.parseFileName(name)?.pid == 7940)
        #expect(InboxFile.parseFileName("garbage.tmp") == nil)
        #expect(padded < name) // lexicographic == chronological
    }

    @Test func environmentAllowListNeverContainsSecrets() {
        for name in InboxHeader.environmentAllowList {
            #expect(!InboxHeader.isForbiddenEnvironmentName(name), "\(name) looks like a secret")
        }
        #expect(InboxHeader.isForbiddenEnvironmentName("CLAUDE_CODE_MESSAGING_TOKEN"))
        #expect(InboxHeader.isForbiddenEnvironmentName("OPENAI_API_KEY"))
    }

    // MARK: AgentEvent

    @Test func agentEventRoundTrip() throws {
        let event = AgentEvent(
            id: "1791811783024000123-7940.event",
            agent: .claude,
            event: .turnFinished(.completed),
            rawEventName: "Stop",
            sessionKey: SessionKey(agent: .claude, id: "3514aa88"),
            agentProcess: ProcessIdentity(pid: 96888, startSec: 1_791_810_323, startUsec: 1234, uniqueID: 99, pidVersion: 7),
            host: HostApp(bundleID: "com.apple.Terminal", name: "Terminal", pid: 44124),
            cwd: "/Users/x/proj",
            title: "Fix the build",
            messagePreview: "Done. All tests pass.",
            waitingFor: nil,
            turnID: "turn-1",
            backgroundTasksRunning: true,
            errorDetail: nil,
            transcriptPath: "/Users/x/.claude/projects/p/3514aa88.jsonl",
            tier: .hook,
            occurredAt: Date(timeIntervalSince1970: 1_791_811_783.024),
            receivedAt: Date(timeIntervalSince1970: 1_791_811_783.030),
            metadata: ["claude.entrypoint": "cli"]
        )
        let back = try KakurenekoJSON.decode(AgentEvent.self, from: KakurenekoJSON.encode(event))
        #expect(back == event)
        #expect(back.agentProcess?.uniqueID == 99) // optional enrichments survive
        #expect(back.argvAgentLabel == "claude")
        #expect(event.dedupeIdentity == "claude|3514aa88|turnFinished|completed")
    }

    @Test func processIdentityEqualityIgnoresEnrichments() {
        let a = ProcessIdentity(pid: 1, startSec: 2, startUsec: 3)
        let b = ProcessIdentity(pid: 1, startSec: 2, startUsec: 3, uniqueID: 77, pidVersion: 5)
        let c = ProcessIdentity(pid: 1, startSec: 2, startUsec: 4)
        #expect(a == b)
        #expect(Set([a, b]).count == 1)
        #expect(a != c)
        #expect(a.fallbackSessionID == "pid:1:2.3")
        #expect(SessionKey.fallback(agent: .aider, identity: a).isProcessFallback)
    }

    // MARK: Sessions

    @Test func sessionStateAndAggregate() throws {
        let now = Date(timeIntervalSince1970: 1_791_842_400)
        func session(_ id: String, _ state: SessionState) -> AgentSession {
            AgentSession(key: SessionKey(agent: .codex, id: id), state: state)
        }
        let sessions = [
            session("a", .working(since: now)),
            session("b", .settling(until: now, outcome: .completed)),
            session("c", .waiting(kind: .permission, since: now.addingTimeInterval(-60))),
            session("d", .stalled(since: now)),
            session("e", .idle(since: now, outcome: .interrupted)),
            session("f", .ended(at: now)),
        ]
        let agg = SessionAggregate.compute(from: sessions, stateVersion: 3, lastFinishedAt: nil)
        #expect(agg.anyWorking && agg.anyWaiting)
        #expect(agg.workingCount == 2) // settling counts as working
        #expect(agg.stalledCount == 1 && agg.idleCount == 1 && agg.liveCount == 5)
        #expect(agg.oldestWaitingSince == now.addingTimeInterval(-60))
        #expect(agg.stateVersion == 3)
        let effect = SessionEffect(kind: .finished, session: sessions[0], at: now, outcome: .completed, workedFor: 2520)
        #expect(try KakurenekoJSON.decode(SessionEffect.self, from: KakurenekoJSON.encode(effect)) == effect)
        for s in sessions {
            #expect(try KakurenekoJSON.decode(SessionState.self, from: KakurenekoJSON.encode(s.state)) == s.state)
        }
    }

    // MARK: Claude records

    @Test func claudeRecordTolerantDecoding() throws {
        let json = #"""
        {"pid":96888,"sessionId":"3514aa88-efa8-4a60-97d7-2878eed849d4","cwd":"/Users/tomasnguyen/Developer",
         "startedAt":1791810326817,"procStart":"Mon Oct 12 13:05:23 2026","version":"2.1.296","peerProtocol":1,
         "peerFeatures":["notify_idle"],"kind":"interactive","entrypoint":"cli","pidDomain":"darwin",
         "messagingSocketPath":"/tmp/cc-socks/96888.sock","name":"developer-40","nameSource":"derived",
         "nameSince":1791810326817,"status":"busy","updatedAt":1791810678765,"statusUpdatedAt":1791810678765,
         "spare":"weird-type"}
        """#
        let record = try #require(ClaudeSessionRecord.decode(Data(json.utf8)))
        #expect(record.pid == 96888)
        #expect(record.statusKind == .busy)
        #expect(record.spare == nil) // wrong type → nil
        #expect(record.humanName == nil) // derived names are not titles
        #expect(!record.isIgnorable)
        #expect(record.procStartEpochSeconds == 1_791_810_323) // 2026-10-12T13:05:23Z
        #expect(ClaudeSessionRecord.parseProcStart("Fri Oct  2 01:02:03 2026") != nil) // space-padded day
        #expect(ClaudeSessionRecord.decode(Data(#"{"sessionId":"x"}"#.utf8)) == nil) // pid required
        let parked = try #require(ClaudeSessionRecord.decode(Data(#"{"pid":1,"parkedJobId":"e5b3e311","name":"N","nameSource":"user"}"#.utf8)))
        #expect(parked.isIgnorable)
        #expect(parked.humanName == "N")
        #expect(ClaudeSessionRecord.isRecordFileName("96888.json"))
        #expect(!ClaudeSessionRecord.isRecordFileName("96888.abc.key"))
        #expect(!ClaudeSessionRecord.isRecordFileName(".fleetview-heartbeat"))
    }

    @Test func claudeAgentsListDecoding() {
        let json = #"""
        [{"pid":24617,"id":"e5b3e311","cwd":"/x","kind":"background","startedAt":1791212730037,"sessionId":"s","name":"N","status":"idle","state":"done"},
         {"pid":76720,"cwd":"/y","kind":"interactive","status":"busy"},
         "garbage"]
        """#
        let entries = ClaudeAgentsEntry.decodeList(Data(json.utf8))
        #expect(entries?.count == 2)
        #expect(entries?.first?.state == "done")
        #expect(entries?.last?.pid == 76720)
    }

    // MARK: Pause journal

    @Test func pauseJournalRoundTripMatchesR06Schema() throws {
        let journal = PauseJournal(
            bootSessionUUID: "4B5EADB3-AD06-410E-83BD-8CE9B4A773A4",
            kakurenekoPid: 4242,
            startedAt: Date(timeIntervalSince1970: 1_791_847_804),
            apps: [
                PauseJournalApp(bundleID: "company.thebrowser.Browser", name: "Arc", appPid: 92564, mode: .throttle, members: [
                    PauseJournalRecord(pid: 92564, pidVersion: 2_146_524, uniqueID: 1_234_567, startSec: 1_790_774_478, startUsec: 221_234,
                                       path: "/Applications/Arc.app/Contents/MacOS/Arc", action: .darwinBackground),
                ]),
            ]
        )
        let data = try journal.encoded()
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"action\" : \"darwinbg\""))
        #expect(text.contains("\"schema\" : 1"))
        #expect(text.contains("\"startedAt\" : \"2026-10-12T23:30:04.000Z\""))
        #expect(PauseJournal.decode(data) == journal)
        #expect(journal.apps[0].members[0].identity.pidVersion == 2_146_524)

        let paths = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        try journal.write(to: paths.pauseJournalFile)
        #expect(PauseJournal.read(from: paths.pauseJournalFile) == journal)
        #expect(PauseJournal.read(from: paths.outboxFile) == nil)
    }

    // MARK: Notify / install / snapshot types

    @Test func notifyTypesRoundTrip() throws {
        let n = OutgoingNotification(kind: .countdown, title: "All agents done, sleeping in 5 min", body: "Finished: api (Claude Code, 42m)",
                                     groupKey: "countdown", replaceKey: "countdown",
                                     actions: [.keepAwake(seconds: 3600), .sleepNow, .shutDown, .keepAwake(seconds: 60)],
                                     createdAt: Date(timeIntervalSince1970: 1_791_842_400), stateVersion: 42)
        #expect(n.actions.count == 3) // at most 3 buttons
        #expect(n.priority == .default)
        #expect(n.priority.interruption == .active)
        #expect(n.expiresAt == n.createdAt.addingTimeInterval(30 * 60))
        #expect(try KakurenekoJSON.decode(OutgoingNotification.self, from: KakurenekoJSON.encode(n)) == n)
        #expect(NotificationAction.keepAwake(seconds: 3600).label == "Keep awake 1h")
        #expect(NotificationAction.keepAwake(seconds: 1800).label == "Keep awake 30m")
        #expect(NotificationKind.needsInput.defaultPriority == .high)
        #expect(NotificationKind.needsInput.actionTTL == 2 * 3600)
        #expect(NotificationPriority.high.interruption == .timeSensitive && NotificationPriority.low.interruption == .passive)
        #expect(NotificationAction.shutDown.cloudAction == .shutDown)
        #expect(NotificationAction.keepAwake(seconds: 10).cloudAction == .keepAwake(seconds: 60), "clamped to the wire range")
        let status = NotificationStatus(macAuthorization: .authorized, iCloud: .available,
                                        phones: [PhoneDevice(deviceID: "p", name: "iPhone", model: "iPhone18,3", systemVersion: "26",
                                                             appVersion: "1", alertsAuthorized: true, lastSeenAt: n.createdAt)])
        #expect(status.phoneConnected)
        #expect(try KakurenekoJSON.decode(NotificationStatus.self, from: KakurenekoJSON.encode(status)) == status)
        #expect(!NotificationStatus(iCloud: .noAccount, phones: status.phones).phoneConnected)
        let command = RemoteCommand(kind: .sleep, commandID: "c", stateVersion: 3, expiresAt: n.createdAt, receivedAt: n.createdAt,
                                    source: .phone(name: "iPhone"))
        #expect(try KakurenekoJSON.decode(RemoteCommand.self, from: KakurenekoJSON.encode(command)) == command)
        #expect(command.source.isPhone && !CommandSource.macNotification.isPhone)
    }

    @Test func installManifestRoundTrip() throws {
        let manifest = InstallManifest(entries: [
            InstallManifestEntry(agent: .codex, file: "/h/.codex/config.toml", kind: .spliced, sha256Before: "a", sha256After: "b",
                                 chainedOriginal: #"notify = ["X", "a"]"#, installedAt: Date(timeIntervalSince1970: 1_791_842_400)),
        ])
        #expect(try KakurenekoJSON.decode(InstallManifest.self, from: KakurenekoJSON.encode(manifest)) == manifest)
        #expect(manifest.entries(for: .codex).count == 1)
    }

    @Test func safetyTripReasonsAndPowerTypes() throws {
        #expect(SafetyTrip.batteryFloor(percent: 19).userReason == "battery 19 %")
        #expect(SafetyTrip.thermalCritical.userReason == "too hot")
        #expect(SafetyTrip.networkOffline(minutes: 15).userReason == "offline 15 min")
        let phase = PowerPhase.countdown(endsAt: Date(timeIntervalSince1970: 10), reason: .needsInput, closedSince: Date(timeIntervalSince1970: 1))
        #expect(try KakurenekoJSON.decode(PowerPhase.self, from: KakurenekoJSON.encode(phase)) == phase)
        #expect(phase.isArmed)
        #expect(KernelPowerFlags(sleepDisabled: true, clamshellClosed: nil).lid == .noLid)
        #expect(ThermalPressure(notifyState: 3) == .trapping)
        let resume = ResumeEntry(agent: .claude, sessionId: "abc", cwd: "/x/it's", title: nil)
        #expect(resume.resumeCommand == "cd '/x/it'\\''s' && claude --resume abc")
    }

    @Test func appSnapshotStatusLine() {
        var snapshot = PreviewKakurenekoController.sampleSnapshot()
        #expect(snapshot.statusLine == "1 working · 1 waiting")
        snapshot.mode = .disabled
        #expect(snapshot.statusLine == "Off")
        #expect(AppSnapshot.placeholder().statusLine == "Idle")
    }
}
