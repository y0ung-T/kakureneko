import Darwin
import KakurenekoKit
import Foundation
import notify
import Testing

/// `kakureneko-hook` end to end (ARCHITECTURE §9.1 acceptance 1–6): the built binary is spawned with a temp HOME +
/// KAKURENEKO_HOME (`paths.helperEnvironment`) and BOTH inbox overrides pointing into the temp root.
@Suite("kakureneko-hook contract", .timeLimit(.minutes(1)))
struct HookContractTests {
    static let claudeStop = #"{"session_id":"e5b3e311-1111-2222-3333-444455556666","transcript_path":"/Users/x/.claude/projects/p/e5b3e311.jsonl","cwd":"/Users/x/proj","hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"Done é\n\"quoted\" \\ back"}"#

    private func requireHook() throws {
        try #require(FileManager.default.isExecutableFile(atPath: Products.hookPath), "kakureneko-hook must be built next to the test bundle")
    }

    private func singleEvent(in inbox: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> (name: String, header: InboxHeader, payload: Data) {
        let files = InboxFiles.eventFiles(in: inbox)
        try #require(files.count == 1, "expected exactly one .event file, found \(files.map(\.lastPathComponent))", sourceLocation: sourceLocation)
        let parsed = try InboxFile.parse(try Data(contentsOf: files[0]))
        return (files[0].lastPathComponent, parsed.header, parsed.payload)
    }

    // MARK: 1. exit/output contract, header, payload, env allow-list, ancestry

    @Test func stdinPayloadProducesOneParseableEventFile() async throws {
        try requireHook()
        let home = try TempHome()
        let workdir = try home.scratch("work dir")
        let env = home.hookEnvironment(extra: [
            "MY_SECRET_TOKEN": "tok-should-never-appear",
            "OPENAI_API_KEY": "sk-should-never-appear-0123456789",
            "CLAUDE_CODE_MESSAGING_TOKEN": "messaging-secret",
            "TERM_PROGRAM": "Apple_Terminal",
            "CLAUDE_PID": "96888",
            "UNRELATED_VARIABLE": "nope",
        ])
        let result = await HookRunner.run(["claude", "Stop"], environment: env, stdin: .data(Data(Self.claudeStop.utf8)),
                                          workingDirectory: workdir.path(percentEncoded: false))
        #expect(result.exitCode == 0)
        #expect(!result.timedOut)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.isEmpty)

        let event = try singleEvent(in: home.paths.inboxDirectory)
        let parsedName = try #require(InboxFile.parseFileName(event.name))
        #expect(parsedName.pid == result.pid)
        #expect(event.name == InboxFile.fileName(epochNanoseconds: parsedName.epochNanoseconds, pid: result.pid))
        let expectedLength: Int = 19 + 1 + String(result.pid).count + ".event".count
        #expect(event.name.count == expectedLength)
        #expect(event.header.v == 1)
        #expect(event.header.agent == "claude")
        #expect(event.header.event == "Stop")
        #expect(event.header.pid == result.pid)
        #expect(event.header.ppid == getpid())
        #expect(event.header.cwd == workdir.realPath)
        #expect(event.header.payloadSource == "stdin")
        #expect(abs(event.header.date.timeIntervalSinceNow) < 30)
        #expect(event.payload == Data(Self.claudeStop.utf8), "payload must be byte-identical to stdin")

        // Env allow-list: never anything matching TOKEN|KEY|SECRET|PASSWORD, never unlisted names.
        #expect(event.header.env["TERM_PROGRAM"] == "Apple_Terminal")
        #expect(event.header.env["CLAUDE_PID"] == "96888")
        #expect(event.header.env["MY_SECRET_TOKEN"] == nil)
        #expect(event.header.env["OPENAI_API_KEY"] == nil)
        #expect(event.header.env["CLAUDE_CODE_MESSAGING_TOKEN"] == nil)
        #expect(event.header.env["UNRELATED_VARIABLE"] == nil)
        let raw = String(decoding: try Data(contentsOf: try #require(InboxFiles.eventFiles(in: home.paths.inboxDirectory).first)), as: UTF8.self)
        #expect(!raw.contains("tok-should-never-appear"))
        #expect(!raw.contains("sk-should-never-appear"))
        #expect(!raw.contains("messaging-secret"))
        for name in event.header.env.keys {
            #expect(InboxHeader.environmentAllowList.contains(name))
            #expect(!InboxHeader.isForbiddenEnvironmentName(name))
        }

        // Ancestry: nearest first = this test process, identical identity tuple to the Kit reference lookup.
        let first = try #require(event.header.ancestry.first)
        #expect(first.pid == getpid())
        #expect(first.identity == KernelProcessLookup().identity(of: getpid()))
        #expect(first.ppid == getppid())
        let ownPath = try #require(Self.processPath(getpid()))
        #expect(first.path == ownPath)
        #expect(event.header.ancestry.count <= 8)
        for ancestor in event.header.ancestry {
            if let argv1 = ancestor.argv1 { #expect(InboxAncestor.isRecordableArgv1(argv1)) }
        }
        // Nothing left behind in .tmp/.
        #expect(InboxFiles.entries(in: home.paths.inboxTempDirectory).isEmpty)
    }

    @Test func argv1IsRecordedOnlyWhenPathLike() async throws {
        try requireHook()
        let home = try TempHome()
        let plain = try home.scratch("scripts")
        let spaced = try home.scratch("scripts with space")
        let body = "\"\(Products.hookPath)\" claude Stop\ntrue\n"
        let plainScript = plain.appending(path: "run.sh")
        let spacedScript = spaced.appending(path: "run.sh")
        try body.write(to: plainScript, atomically: true, encoding: .utf8)
        try body.write(to: spacedScript, atomically: true, encoding: .utf8)

        // `/bin/sh <path>`: argv[1] is a path without whitespace → recorded.
        let inboxA = try home.scratch("inbox-a")
        let a = await HookRunner.run(executable: "/bin/sh", [plainScript.path(percentEncoded: false)],
                                     environment: home.hookEnvironment(inbox: inboxA), stdin: .data(Data("{}".utf8)))
        #expect(a.exitCode == 0)
        let eventA = try singleEvent(in: inboxA)
        let shellA = try #require(eventA.header.ancestry.first)
        #expect(shellA.pid == a.pid)
        #expect(shellA.argv0 == "/bin/sh")
        #expect(shellA.argv1 == plainScript.path(percentEncoded: false))
        #expect(shellA.path != nil)
        #expect(eventA.header.ancestry.dropFirst().first?.pid == getpid())

        // A path WITH whitespace (could be prompt text) → never recorded.
        let inboxB = try home.scratch("inbox-b")
        let b = await HookRunner.run(executable: "/bin/sh", [spacedScript.path(percentEncoded: false)],
                                     environment: home.hookEnvironment(inbox: inboxB), stdin: .data(Data("{}".utf8)))
        #expect(b.exitCode == 0)
        let shellB = try #require(try singleEvent(in: inboxB).header.ancestry.first)
        #expect(shellB.argv0 == "/bin/sh")
        #expect(shellB.argv1 == nil)

        // `sh -c '<prompt-like text>'`: argv[1] = "-c" (no slash) → not recorded; the command text never appears.
        let inboxC = try home.scratch("inbox-c")
        let c = await HookRunner.run(executable: "/bin/sh", ["-c", "\"\(Products.hookPath)\" claude Stop; echo please refactor /etc/passwd >/dev/null"],
                                     environment: home.hookEnvironment(inbox: inboxC), stdin: .data(Data("{}".utf8)))
        #expect(c.exitCode == 0)
        let fileC = try singleEvent(in: inboxC)
        #expect(fileC.header.ancestry.first?.argv1 == nil)
        let rawC = String(decoding: try Data(contentsOf: try #require(InboxFiles.eventFiles(in: inboxC).first)), as: UTF8.self)
        #expect(!rawC.contains("please refactor"))
    }

    // MARK: 2. argv payload and --chain

    @Test func codexTrailingJSONArgvIsThePayload() async throws {
        try requireHook()
        let home = try TempHome()
        let notify = #"{"type":"agent-turn-complete","thread-id":"b5f6c1c2-aaaa","turn-id":"12345","cwd":"/Users/x/p","client":"codex-tui","input-messages":["Rename `foo`"],"last-assistant-message":"Rename complete"}"#
        // Even with data on stdin, a trailing JSON argv wins.
        let result = await HookRunner.run(["codex", "notify", notify], environment: home.hookEnvironment(),
                                          stdin: .data(Data(#"{"ignored":true}"#.utf8)))
        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.isEmpty)
        let event = try singleEvent(in: home.paths.inboxDirectory)
        #expect(event.header.agent == "codex")
        #expect(event.header.event == "notify")
        #expect(event.header.payloadSource == "argv")
        #expect(event.payload == Data(notify.utf8))
    }

    @Test func chainRunsDetachedWithArgvPayloadAppended() async throws {
        try requireHook()
        let home = try TempHome()
        let marker = try home.scratch("chain").appending(path: "marker.txt")
        let notify = #"{"type":"agent-turn-complete","thread-id":"t-1","turn-id":"7"}"#
        // The chained command records its $0 (= the appended payload) and then keeps running for 2 s.
        let script = "printf '%s' \"$0\" > '\(marker.path(percentEncoded: false))'; /bin/sleep 2"
        let result = await HookRunner.run(["codex", "notify", "--chain", "--", "/bin/sh", "-c", script, notify],
                                          environment: home.hookEnvironment())
        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.isEmpty)
        #expect(result.milliseconds < 1_000, "the hook must not wait for the chained command (took \(result.milliseconds) ms)")
        #expect(await eventually { FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)) })
        let recorded = await eventuallyContents(marker)
        #expect(recorded == notify, "chained argv gets the argv payload as its last argument")
        let event = try singleEvent(in: home.paths.inboxDirectory)
        #expect(event.header.payloadSource == "argv")
        #expect(event.payload == Data(notify.utf8))
    }

    @Test func chainWithStdinPayloadIsSpawnedUnchanged() async throws {
        try requireHook()
        let home = try TempHome()
        let marker = try home.scratch("chain").appending(path: "marker.txt")
        let script = "printf '%s:%s' \"$#\" \"$0\" > '\(marker.path(percentEncoded: false))'"
        let result = await HookRunner.run(["codex", "waiting", "--chain", "--", "/bin/sh", "-c", script, "zero"],
                                          environment: home.hookEnvironment(),
                                          stdin: .data(Data(#"{"from":"stdin"}"#.utf8)))
        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)
        #expect(await eventuallyContents(marker) == "0:zero", "a stdin payload must never be appended to the chained argv")
        let event = try singleEvent(in: home.paths.inboxDirectory)
        #expect(event.header.payloadSource == "stdin")
        #expect(event.payload == Data(#"{"from":"stdin"}"#.utf8))
    }

    @Test func aidersPipedStdinIsNeverRead() async throws {
        try requireHook()
        let home = try TempHome()
        // Aider passes its own stdin through to the hook: input piped into Aider is Aider's, not a payload.
        let result = await HookRunner.run(["aider", "waiting"], environment: home.hookEnvironment(),
                                          stdin: .data(Data("input meant for aider\n".utf8)))
        #expect(result.exitCode == 0)
        let event = try singleEvent(in: home.paths.inboxDirectory)
        #expect(event.header.payloadSource == "none")
        #expect(event.payload.isEmpty)
    }

    @Test func chainFromATerminalIsSpawnedUnchangedWithoutReadingStdin() async throws {
        try requireHook()
        let home = try TempHome()
        let marker = try home.scratch("chain").appending(path: "marker.txt")
        let script = "printf '%s' \"$#\" > '\(marker.path(percentEncoded: false))'"
        let result = await HookRunner.run(["aider", "waiting", "--chain", "--", "/bin/sh", "-c", script], environment: home.hookEnvironment(), stdin: .pty)
        #expect(result.exitCode == 0)
        #expect(await eventuallyContents(marker) == "0")
        let event = try singleEvent(in: home.paths.inboxDirectory)
        #expect(event.header.payloadSource == "none")
        #expect(event.payload.isEmpty)
    }

    /// Codex `notify` values usually start with a bare program name (`["notify-send", …]`, `["terminal-notifier", …]`):
    /// the chained argv is resolved through the hook's inherited PATH (posix_spawnp / execvp semantics), exactly as
    /// Codex resolved it before the install.
    @Test func chainResolvesABareProgramNameThroughPath() async throws {
        try requireHook()
        let home = try TempHome()
        let bin = try home.scratch("user bin")
        let marker = try home.scratch("chain").appending(path: "marker.txt")
        let program = "kakureneko-test-notify-\(UUID().uuidString.prefix(8))"
        let script = bin.appending(path: program)
        try "#!/bin/sh\nprintf '%s|%s' \"$1\" \"$2\" > '\(marker.path(percentEncoded: false))'\n".write(to: script, atomically: true, encoding: .utf8)
        #expect(chmod(script.path(percentEncoded: false), 0o755) == 0)
        let notify = #"{"type":"agent-turn-complete","thread-id":"t-9","turn-id":"1"}"#
        let path = "/usr/bin:/bin:" + bin.path(percentEncoded: false)
        let result = await HookRunner.run(["codex", "notify", "--chain", "--", program, "--title", notify],
                                          environment: home.hookEnvironment(extra: ["PATH": path]))
        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.isEmpty)
        #expect(await eventuallyContents(marker) == "--title|\(notify)", "bare name found via PATH, payload appended")
        _ = try singleEvent(in: home.paths.inboxDirectory)
        let log = (try? String(contentsOf: home.paths.hookLogFile, encoding: .utf8)) ?? ""
        #expect(!log.contains("chain spawn failed"))

        // Not on PATH → logged, still exit 0, still delivered.
        let other = try TempHome()
        let missing = await HookRunner.run(["codex", "notify", "--chain", "--", program, notify],
                                           environment: other.hookEnvironment(extra: ["PATH": "/usr/bin:/bin"]))
        #expect(missing.exitCode == 0)
        #expect(missing.stdout.isEmpty && missing.stderr.isEmpty)
        _ = try singleEvent(in: other.paths.inboxDirectory)
        #expect(try String(contentsOf: other.paths.hookLogFile, encoding: .utf8).contains("chain spawn failed"))
    }

    /// `python -m aider`: the hook records the module of a Python ancestor so the matcher can attribute it. The
    /// "Python" here is `/bin/sh` started with argv `[python3, -m, aider]` (never a real interpreter).
    @Test func pythonModuleAncestorIsRecorded() async throws {
        try requireHook()
        let home = try TempHome()
        let work = try home.scratch("python-module")
        // `sh -m aider` runs the file ./aider (job-control flag + script name), which calls the hook.
        try "\"\(Products.hookPath)\" aider waiting\n".write(to: work.appending(path: "aider"), atomically: true, encoding: .utf8)
        let result = await HookRunner.run(executable: "/bin/sh", argv0: "python3", ["-m", "aider"],
                                          environment: home.hookEnvironment(), workingDirectory: work.path(percentEncoded: false))
        #expect(result.exitCode == 0)
        let event = try singleEvent(in: home.paths.inboxDirectory)
        let parent = try #require(event.header.ancestry.first)
        #expect(parent.pid == result.pid)
        #expect(parent.argv0 == "python3")
        #expect(parent.argv1 == nil)
        #expect(parent.module == "aider")
        #expect(parent.descriptor.argv == ["python3", "-m", "aider"])
        // The test process itself is no Python interpreter: no module.
        #expect(event.header.ancestry.dropFirst().first?.module == nil)
    }

    @Test func missingChainProgramStillExitsZeroAndDelivers() async throws {
        try requireHook()
        let home = try TempHome()
        let result = await HookRunner.run(["aider", "waiting", "--chain", "--", "/nonexistent/program-\(UUID().uuidString)"],
                                          environment: home.hookEnvironment(), stdin: .devNull)
        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.isEmpty)
        _ = try singleEvent(in: home.paths.inboxDirectory)
        let log = try String(contentsOf: home.paths.hookLogFile, encoding: .utf8)
        #expect(log.contains("chain spawn failed"))
    }

    // MARK: 3. The two documented stdout answers

    @Test func cursorBeforeSubmitPromptAnswersContinue() async throws {
        try requireHook()
        let home = try TempHome()
        let result = await HookRunner.run(["cursor", "beforeSubmitPrompt"], environment: home.hookEnvironment(),
                                          stdin: .data(Data(#"{"conversation_id":"c1","generation_id":"g1","prompt":"hi"}"#.utf8)))
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == #"{"continue":true}"#)
        #expect(result.stderr.isEmpty)
        #expect(InboxFiles.eventFiles(in: home.paths.inboxDirectory).count == 1)
    }

    @Test(arguments: ["TaskComplete", "TaskStart", "UserPromptSubmit", "SessionShutdown"])
    func clineAnswersCancelFalse(event: String) async throws {
        try requireHook()
        let home = try TempHome()
        let result = await HookRunner.run(["cline", event], environment: home.hookEnvironment(),
                                          stdin: .data(Data(#"{"taskId":"k1","hookName":"agent_end"}"#.utf8)))
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == #"{"cancel":false}"#)
        #expect(result.stderr.isEmpty)
        #expect(InboxFiles.eventFiles(in: home.paths.inboxDirectory).count == 1)
    }

    @Test(arguments: [["cursor", "stop"], ["cursor", "sessionStart"], ["claude", "UserPromptSubmit"], ["gemini", "AfterAgent"], ["copilot", "agentStop"]])
    func everyOtherEventKeepsStdoutEmpty(arguments: [String]) async throws {
        try requireHook()
        let home = try TempHome()
        let result = await HookRunner.run(arguments, environment: home.hookEnvironment(), stdin: .data(Data("{}".utf8)))
        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.isEmpty)
    }

    // MARK: 4. Fallback inbox, bad arguments, back-pressure

    @Test func unwritablePrimaryInboxFallsBack() async throws {
        try requireHook()
        let home = try TempHome()
        let readOnly = try home.scratch("ro")
        #expect(chmod(readOnly.path(percentEncoded: false), 0o500) == 0)
        let env = home.hookEnvironment(inbox: readOnly, fallback: home.paths.fallbackInboxDirectory)
        let result = await HookRunner.run(["claude", "Stop"], environment: env, stdin: .data(Data(Self.claudeStop.utf8)))
        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.isEmpty)
        #expect(InboxFiles.entries(in: readOnly).isEmpty)
        let event = try singleEvent(in: home.paths.fallbackInboxDirectory)
        #expect(event.payload == Data(Self.claudeStop.utf8))
        let log = try String(contentsOf: home.paths.hookLogFile, encoding: .utf8)
        #expect(log.contains("used fallback"))
        #expect(!log.contains("e5b3e311"), "the hook log never contains payloads")
    }

    @Test func bothInboxesUnwritableStillExitsZero() async throws {
        try requireHook()
        let home = try TempHome()
        let readOnlyA = try home.scratch("ro-a")
        let readOnlyB = try home.scratch("ro-b")
        #expect(chmod(readOnlyA.path(percentEncoded: false), 0o500) == 0)
        #expect(chmod(readOnlyB.path(percentEncoded: false), 0o500) == 0)
        let result = await HookRunner.run(["claude", "Stop"], environment: home.hookEnvironment(inbox: readOnlyA, fallback: readOnlyB),
                                          stdin: .data(Data("{}".utf8)))
        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.isEmpty)
        #expect(InboxFiles.entries(in: readOnlyA).isEmpty)
        #expect(InboxFiles.entries(in: readOnlyB).isEmpty)
        #expect(try String(contentsOf: home.paths.hookLogFile, encoding: .utf8).contains("event not delivered"))
    }

    @Test(arguments: [[String](), ["claude"], ["bad/agent", "Stop"], ["claude", "Stop; rm -rf ~"], ["", "Stop"], ["claude", String(repeating: "x", count: 65)]])
    func badArgumentsExitZeroWithoutOutputOrFile(arguments: [String]) async throws {
        try requireHook()
        let home = try TempHome()
        let result = await HookRunner.run(arguments, environment: home.hookEnvironment(), stdin: .data(Data("{}".utf8)))
        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.isEmpty)
        #expect(InboxFiles.entries(in: home.paths.inboxDirectory).filter { $0 != ".tmp" }.isEmpty)
        #expect(InboxFiles.eventFiles(in: home.paths.fallbackInboxDirectory).isEmpty)
    }

    @Test func fullInboxDropsTheEvent() async throws {
        try requireHook()
        let home = try TempHome()
        let inbox = home.paths.inboxDirectory
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        for index in 0...InboxFile.maxQueuedFiles {
            let path = inbox.appending(path: InboxFile.fileName(epochNanoseconds: UInt64(index), pid: 1)).path(percentEncoded: false)
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            close(fd)
        }
        let result = await HookRunner.run(["claude", "Stop"], environment: home.hookEnvironment(), stdin: .data(Data("{}".utf8)))
        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)
        #expect(InboxFiles.eventFiles(in: inbox).count == InboxFile.maxQueuedFiles + 1, "the event is dropped, not queued")
        #expect(InboxFiles.eventFiles(in: home.paths.fallbackInboxDirectory).isEmpty, "back-pressure is not a reason to fall back")
        #expect(try String(contentsOf: home.paths.hookLogFile, encoding: .utf8).contains("dropped"))
    }

    // MARK: 5. Never block the agent

    /// Wall-time bounds of a spawned child are inflated by machine load (the whole suite runs in parallel). The
    /// intrinsic latency is the BEST of a few independent rounds: a hook that really waited (for the 2 s alarm, or
    /// polling a tty for 300 ms) fails every round, while a round that merely lost the CPU is retried.
    private func bestOf(rounds: Int = 3, under bound: Double, _ measure: (Int) async throws -> Double) async rethrows -> Double {
        var best = Double.infinity
        for round in 0..<rounds {
            best = min(best, try await measure(round))
            if best < bound { break }
        }
        return best
    }

    @Test func stdinHeldOpenByTheParentIsBounded() async throws {
        try requireHook()
        let home = try TempHome()
        let quiet = try await bestOf(under: 750) { round in
            let inbox = try home.scratch("inbox-quiet-\(round)")
            let result = await HookRunner.run(["claude", "Stop"], environment: home.hookEnvironment(inbox: inbox), stdin: .heldOpen(prefix: Data()))
            #expect(result.exitCode == 0)
            #expect(!result.timedOut)
            // The idle limit (not the 2 s alarm, which exits WITHOUT writing) ended the read: the event exists.
            let event = try singleEvent(in: inbox)
            #expect(event.header.payloadSource == "none")
            #expect(event.payload.isEmpty)
            return result.milliseconds
        }
        #expect(quiet < 750, "an open-but-silent stdin must not stall the hook (best \(quiet) ms)")

        // Data followed by silence: the payload is kept, the idle limit still ends the read.
        let partial = try await bestOf(under: 750) { round in
            let inbox = try home.scratch("inbox-partial-\(round)")
            let result = await HookRunner.run(["claude", "Stop"], environment: home.hookEnvironment(inbox: inbox),
                                              stdin: .heldOpen(prefix: Data(Self.claudeStop.utf8)))
            #expect(result.exitCode == 0)
            let event = try singleEvent(in: inbox)
            #expect(event.header.payloadSource == "stdin")
            #expect(event.payload == Data(Self.claudeStop.utf8))
            return result.milliseconds
        }
        #expect(partial < 750, "best \(partial) ms")
    }

    @Test func medianWallTimeIsWellUnderFiftyMilliseconds() async throws {
        try requireHook()
        let home = try TempHome()
        var rounds: [[Int]] = []
        let median = try await bestOf(under: 50) { round in
            let inbox = try home.scratch("inbox-median-\(round)")
            var times: [Double] = []
            for _ in 0..<20 {
                let result = await HookRunner.run(["claude", "Stop"], environment: home.hookEnvironment(inbox: inbox),
                                                  stdin: .data(Data(Self.claudeStop.utf8)))
                #expect(result.exitCode == 0)
                times.append(result.milliseconds)
            }
            #expect(InboxFiles.eventFiles(in: inbox).count == 20)
            rounds.append(times.map { Int($0) })
            return times.sorted()[times.count / 2]
        }
        #expect(median < 50, "best median \(median) ms over 20 runs per round: \(rounds)")
    }

    @Test func terminalStdinIsNeverRead() async throws {
        try requireHook()
        let home = try TempHome()
        var rounds: [[Int]] = []
        let median = try await bestOf(under: 50) { round in
            let inbox = try home.scratch("inbox-tty-\(round)")
            var times: [Double] = []
            for _ in 0..<5 {
                let result = await HookRunner.run(["aider", "waiting"], environment: home.hookEnvironment(inbox: inbox), stdin: .pty)
                #expect(result.exitCode == 0)
                #expect(result.stdout.isEmpty)
                #expect(result.stderr.isEmpty)
                times.append(result.milliseconds)
            }
            let files = InboxFiles.eventFiles(in: inbox)
            #expect(files.count == 5)
            for file in files {
                let parsed = try InboxFile.parse(try Data(contentsOf: file))
                #expect(parsed.header.payloadSource == "none")
                #expect(parsed.payload.isEmpty)
            }
            rounds.append(times.map { Int($0) })
            return times.sorted()[times.count / 2]
        }
        #expect(median < 50, "a tty stdin must not be polled (best median \(median) ms: \(rounds))")
    }

    @Test func deliveryPostsTheInboxDarwinNotification() async throws {
        try requireHook()
        let home = try TempHome()
        var token: Int32 = 0
        try #require(notify_register_check(KakurenekoID.inboxDarwinNotification, &token) == UInt32(NOTIFY_STATUS_OK))
        defer { notify_cancel(token) }
        var check: Int32 = 0
        _ = notify_check(token, &check) // the first check always reports "changed"
        let result = await HookRunner.run(["claude", "Stop"], environment: home.hookEnvironment(), stdin: .data(Data("{}".utf8)))
        #expect(result.exitCode == 0)
        #expect(InboxFiles.eventFiles(in: home.paths.inboxDirectory).count == 1)
        #expect(notify_check(token, &check) == UInt32(NOTIFY_STATUS_OK))
        #expect(check == 1, "notify_post(\"com.kakureneko.inbox\") after the rename")
    }

    @Test func devNullStdinIsAnEmptyPayload() async throws {
        try requireHook()
        let home = try TempHome()
        let result = await HookRunner.run(["claude", "SessionEnd"], environment: home.hookEnvironment(), stdin: .devNull)
        #expect(result.exitCode == 0)
        let event = try singleEvent(in: home.paths.inboxDirectory)
        #expect(event.header.payloadSource == "none")
        #expect(event.payload.isEmpty)
    }

    // MARK: 6. Recorder mode and root resolution

    @Test func recordModeWritesARecordingIntoTheFakeHome() async throws {
        try requireHook()
        let home = try TempHome()
        let env = home.hookEnvironment(extra: [KakurenekoEnvironment.record: "1", "TERM_PROGRAM": "iTerm.app",
                                               "GITHUB_TOKEN": "ghp_shouldneverbeseen0123456789"])
        let result = await HookRunner.run(["claude", "Stop"], environment: env, stdin: .data(Data(Self.claudeStop.utf8)))
        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)
        let directory = home.paths.recordingsDirectory.appending(path: "claude", directoryHint: .isDirectory)
        let recordings = InboxFiles.entries(in: directory)
        try #require(recordings.count == 1, "recordings: \(recordings)")
        #expect(recordings[0].hasPrefix("Stop-") && recordings[0].hasSuffix(".json"))
        let data = try Data(contentsOf: directory.appending(path: recordings[0]))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["agent"] as? String == "claude")
        #expect(object["event"] as? String == "Stop")
        #expect(object["stdin"] as? String == Self.claudeStop)
        #expect((object["argv"] as? [String])?.suffix(2) == ["claude", "Stop"])
        let recordedEnv = try #require(object["env"] as? [String: String])
        #expect(recordedEnv["TERM_PROGRAM"] == "iTerm.app")
        #expect(recordedEnv["GITHUB_TOKEN"] == nil)
        #expect(!String(decoding: data, as: UTF8.self).contains("ghp_shouldneverbeseen"))
        // The event itself is still delivered.
        #expect(InboxFiles.eventFiles(in: home.paths.inboxDirectory).count == 1)
    }

    @Test func rootIsTheFakeHomeAndDirectoriesArePrivate() async throws {
        try requireHook()
        let home = try TempHome()
        // Both inbox overrides stay set (hook tests never rely on root resolution for the inbox); the root shows in
        // where the recording and the log go. The overridden inbox does not exist yet: the hook creates it 0700.
        let inbox = home.paths.home.deletingLastPathComponent().appending(path: "fresh/inbox", directoryHint: .isDirectory)
        let env = home.hookEnvironment(inbox: inbox, extra: [KakurenekoEnvironment.record: "1"])
        let result = await HookRunner.run(["gemini", "AfterAgent"], environment: env, stdin: .data(Data(#"{"session_id":"g"}"#.utf8)))
        #expect(result.exitCode == 0)
        let event = try singleEvent(in: inbox)
        #expect(event.header.agent == "gemini")
        #expect(InboxFiles.entries(in: home.paths.recordingsDirectory.appending(path: "gemini")).count == 1,
                "<root> = $HOME/.kakureneko when the binary is not an installed copy")
        var info = stat()
        #expect(stat(inbox.path(percentEncoded: false), &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700, "inbox directories are created 0700")
        #expect(stat(inbox.appending(path: ".tmp").path(percentEncoded: false), &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
        #expect(stat(InboxFiles.eventFiles(in: inbox)[0].path(percentEncoded: false), &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600, "inbox files are 0600")
    }

    @Test func installedCopyUsesTheKakurenekoDirectoryItLivesIn() async throws {
        try requireHook()
        let home = try TempHome()
        // A dev install under a DIFFERENT fake home than $HOME: <root> must follow the binary's own location.
        let otherHome = try home.scratch("installed-home")
        let bin = otherHome.appending(path: ".kakureneko/bin", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let installed = bin.appending(path: "kakureneko-hook")
        try FileManager.default.copyItem(atPath: Products.hookPath, toPath: installed.path(percentEncoded: false))
        let readOnly = try home.scratch("ro")
        #expect(chmod(readOnly.path(percentEncoded: false), 0o500) == 0)
        // Primary inbox unwritable → the fallback is used and the hook logs that into <root>/log/hook.log.
        let env = home.hookEnvironment(inbox: readOnly, extra: [KakurenekoEnvironment.record: "1"])
        let result = await HookRunner.run(executable: installed.path(percentEncoded: false), ["claude", "Stop"], environment: env,
                                          stdin: .data(Data("{}".utf8)))
        #expect(result.exitCode == 0)
        #expect(InboxFiles.eventFiles(in: home.paths.fallbackInboxDirectory).count == 1)
        let installedRoot = otherHome.appending(path: ".kakureneko", directoryHint: .isDirectory)
        #expect(!InboxFiles.entries(in: installedRoot.appending(path: "recordings/claude")).isEmpty)
        #expect(FileManager.default.fileExists(atPath: installedRoot.appending(path: "log/hook.log").path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: home.paths.recordingsDirectory.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: home.paths.hookLogFile.path(percentEncoded: false)))
    }

    // MARK: - Helpers

    private static func processPath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * 1024)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private func eventuallyContents(_ url: URL) async -> String? {
        var contents: String?
        _ = await eventually(timeout: .seconds(5)) {
            contents = try? String(contentsOf: url, encoding: .utf8)
            return contents.map { !$0.isEmpty } ?? false
        }
        return contents
    }
}
