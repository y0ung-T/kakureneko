@testable import KakurenekoEvents
import KakurenekoKit
import Foundation
import Testing

/// A matcher that classifies by pid (to test attribution rules independently of any signature table).
struct StubMatcher: AgentSignatureMatching {
    var byArgv0: [String: AgentMatch]
    func match(_ process: ProcessDescriptor) -> AgentMatch? {
        process.argv.first.flatMap { byArgv0[$0] }
    }
}

/// ARCHITECTURE §9.1 attribution: nearest matched ancestor → argv label → env markers (§11.13).
@Suite("Attribution", .timeLimit(.minutes(1)))
struct AttributionTests {
    @Test func nearestMatchedAncestorBeatsTheArgvLabel() throws {
        var harness = PipelineHarness()
        // A Claude-format hook in ~/.claude/settings.json run by Droid (R04 §2.1).
        let event = try harness.accept("claude", "Stop", #"{"session_id":"d-1"}"#,
                                       ancestry: [Ancestor.sh(30), Ancestor.droid(20), Ancestor.zsh(10)])
        #expect(event.agent == .droid)
        #expect(event.argvAgentLabel == "claude")
        #expect(event.agentProcess == Ancestor.droid(20).identity)
        #expect(event.sessionKey == SessionKey(agent: .droid, id: "d-1"))
        #expect(event.metadata[MetadataKey.relabelledFrom] == "claude")
    }

    @Test func argvLabelWhenNoAncestorMatches() throws {
        var harness = PipelineHarness()
        let event = try harness.accept("codex", "Stop", #"{"session_id":"t1"}"#,
                                       ancestry: [Ancestor.sh(30), Ancestor.other(20), Ancestor.login(5)])
        #expect(event.agent == .codex)
        #expect(event.agentProcess == nil)
        #expect(event.metadata[MetadataKey.relabelledFrom] == nil)
    }

    @Test func envMarkersNeverOutrankAncestryOrArgv() throws {
        var harness = PipelineHarness()
        let env = ["CLAUDE_PID": "10", "CLAUDE_CODE_SESSION_ID": "claude-session", "CURSOR_VERSION": "2.6", "GEMINI_SESSION_ID": "g"]
        let viaArgv = try harness.accept("codex", "notify", #"{"type":"agent-turn-complete","thread-id":"th","turn-id":"1"}"#, env: env)
        #expect(viaArgv.agent == .codex)
        #expect(viaArgv.sessionKey == SessionKey(agent: .codex, id: "th"))
        let viaAncestry = try harness.accept("gemini", "AfterAgent", #"{}"#, env: env,
                                             ancestry: [Ancestor.bash(40), Ancestor.geminiNode(30), Ancestor.zsh(20), Ancestor.claude(10)], at: 5)
        #expect(viaAncestry.agent == .gemini)
        #expect(viaAncestry.agentProcess == Ancestor.geminiNode(30).identity)
    }

    /// Acceptance 8: codex notify whose ancestry is hook → sh → codex → zsh → claude with CLAUDE_PID set.
    @Test func codexRunFromClaudesBashToolIsCodex() throws {
        var harness = PipelineHarness()
        let claude = Ancestor.claude(10)
        let codex = Ancestor.codex(30)
        let env = ["CLAUDE_PID": "10", "CLAUDE_CODE_SESSION_ID": "claude-session-uuid", "CLAUDE_CODE_ENTRYPOINT": "cli"]
        let event = try harness.accept("codex", "notify", #"{"type":"agent-turn-complete","thread-id":"codex-thread","turn-id":"4"}"#,
                                       env: env, ancestry: [Ancestor.sh(40), codex, Ancestor.zsh(20), claude])
        #expect(event.agent == .codex)
        #expect(event.agentProcess == codex.identity)
        #expect(event.sessionKey == SessionKey(agent: .codex, id: "codex-thread"))
        #expect(event.metadata[MetadataKey.claudeEntrypoint] == nil, "Claude's env never decorates another agent's event")

        // Even with the argv label claude (a nested Claude-format hook), the inner agent wins.
        let nested = try harness.accept("claude", "Stop", #"{}"#, env: env,
                                        ancestry: [Ancestor.sh(40), codex, Ancestor.zsh(20), claude], at: 5)
        #expect(nested.agent == .codex)
        #expect(nested.sessionKey != SessionKey(agent: .claude, id: "claude-session-uuid"))
    }

    @Test func nodeWrapperIsRecognisedByItsScriptPath() throws {
        var harness = PipelineHarness()
        let node = Ancestor.codexNode(30)
        let event = try harness.accept("codex", "Stop", #"{"session_id":"t"}"#, ancestry: [Ancestor.sh(40), node, Ancestor.zsh(20), Ancestor.claude(10)],
                                       at: 0)
        #expect(event.agent == .codex)
        #expect(event.agentProcess == node.identity)
        // Without the argv label hint the node script path alone still attributes it.
        let unlabelled = try harness.accept("unknown-tool", "Stop", #"{"session_id":"t2"}"#,
                                            ancestry: [Ancestor.sh(40), node, Ancestor.zsh(20), Ancestor.claude(10)], at: 5)
        #expect(unlabelled.agent == .codex)
    }

    @Test func unknownInnerProgramKeepsTheArgvLabelInsteadOfAnOuterAgent() throws {
        var harness = PipelineHarness()
        // Cursor CLI (node, unknown to the basic matcher) run from Claude's Bash tool.
        let ancestry = [Ancestor.sh(50), Ancestor.cursorCLI(40), Ancestor.zsh(20), Ancestor.claude(10)]
        let env = ["CLAUDE_PID": "10", "CLAUDE_CODE_SESSION_ID": "claude-session"]
        let cursor = try harness.accept("cursor", "stop", #"{"conversation_id":"cur-1","status":"completed"}"#, env: env, ancestry: ancestry)
        #expect(cursor.agent == .cursor)
        #expect(cursor.agentProcess == nil)
        #expect(cursor.sessionKey == SessionKey(agent: .cursor, id: "cur-1"))
        // Its Claude-format route (argv claude + CURSOR_VERSION) is Cursor too, never the outer Claude session.
        let viaClaudeHooks = try harness.accept("claude", "Stop", #"{"conversation_id":"cur-1","cursor_version":"2.6"}"#,
                                                env: env.merging(["CURSOR_VERSION": "2.6.11"]) { $1 }, ancestry: ancestry, at: 5)
        #expect(viaClaudeHooks.agent == .cursor)
        #expect(viaClaudeHooks.sessionKey == SessionKey(agent: .cursor, id: "cur-1"))
        // Fallback identity for payload-less events is the unknown program, not the shell.
        let bare = try harness.accept("cursor", "stop", "", ancestry: ancestry, at: 10)
        #expect(bare.sessionKey == SessionKey.fallback(agent: .cursor, identity: Ancestor.cursorCLI(40).identity))
    }

    @Test func infrastructureAncestorsAreSkipped() throws {
        var harness = PipelineHarness()
        let ptyHost = Ancestor.make(25, argv0: "claude bg-pty-host", path: "/Users/x/.local/share/claude/versions/2.1.296", exe: "2.1.296")
        let event = try harness.accept("codex", "Stop", #"{"session_id":"t"}"#, ancestry: [Ancestor.sh(30), ptyHost, Ancestor.claude(10)])
        #expect(event.agent == .codex, "argv label: the only non-infrastructure match is an outer Claude behind an unknown program")
        let direct = try harness.accept("claude", "Stop", #"{"session_id":"c"}"#, ancestry: [ptyHost, Ancestor.claude(10)], at: 5)
        #expect(direct.agent == .claude)
        #expect(direct.agentProcess == Ancestor.claude(10).identity, "sessions bind to the non-infrastructure process")
    }

    @Test func infrastructureMatchesFromAStubMatcher() throws {
        let matcher = StubMatcher(byArgv0: [
            "daemon": AgentMatch(agent: .claude, isInfrastructure: true),
            "goose": AgentMatch(agent: .goose),
        ])
        var harness = PipelineHarness(matcher: matcher)
        let event = try harness.accept("goose", "Stop", #"{"session_id":"g"}"#,
                                       ancestry: [Ancestor.make(30, argv0: "daemon"), Ancestor.make(20, argv0: "goose")])
        #expect(event.agent == .goose)
        #expect(event.agentProcess == Ancestor.make(20, argv0: "goose").identity)
    }

    // MARK: Copilot → VS Code relabel

    @Test func copilotFileRunByVSCodeLocalIsRelabelled() throws {
        var harness = PipelineHarness(bundles: ["/Applications/Visual Studio Code.app": "com.microsoft.VSCode"])
        let event = try harness.accept("copilot", "agentStop",
                                       #"{"timestamp":"2026-10-12T22:00:00Z","cwd":"/w","session_id":"v-1","hook_event_name":"Stop","stop_hook_active":false}"#,
                                       ancestry: [Ancestor.bash(30), Ancestor.vscodePluginHost(20), Ancestor.vscodeMain(10)])
        #expect(event.agent == .vscode)
        #expect(event.argvAgentLabel == "copilot")
        #expect(event.metadata[MetadataKey.relabelledFrom] == "copilot")
        #expect(event.event == .turnFinished(.completed))
        #expect(event.sessionKey == SessionKey(agent: .vscode, id: "v-1"))
        #expect(event.host?.bundleID == "com.microsoft.VSCode")
        #expect(event.host?.name == "VS Code")
        #expect(event.host?.pid == 10, "the outermost bundle's main process")
    }

    @Test func copilotCLIUnderVSCodeIsNotRelabelled() throws {
        var harness = PipelineHarness()
        let event = try harness.accept("copilot", "agentStop", #"{"sessionId":"cp","stopReason":"end_turn"}"#,
                                       ancestry: [Ancestor.bash(40), Ancestor.copilot(30), Ancestor.vscodePluginHost(20)])
        #expect(event.agent == .copilot)
        #expect(event.agentProcess == Ancestor.copilot(30).identity)
        #expect(event.metadata[MetadataKey.relabelledFrom] == nil)
    }

    @Test func payloadCasingDecidesWithoutAncestry() throws {
        var harness = PipelineHarness()
        let local = try harness.accept("copilot", "sessionStart", #"{"session_id":"v","hook_event_name":"SessionStart","source":"new"}"#)
        #expect(local.agent == .vscode)
        let cli = try harness.accept("copilot", "notification",
                                     #"{"sessionId":"cp","hook_event_name":"Notification","notification_type":"permission_prompt","message":"m"}"#, at: 5)
        #expect(cli.agent == .copilot)
        let camel = try harness.accept("copilot", "agentStop", #"{"sessionId":"cp","stopReason":"end_turn"}"#, at: 10)
        #expect(camel.agent == .copilot)
    }

    // MARK: CLAUDE_PID binding

    @Test func claudePIDBindsOnlyWithoutAnotherAgentInBetween() throws {
        var harness = PipelineHarness()
        // Claude's binary was replaced by an auto-update: no path, p_comm = version → the matcher cannot see it.
        let updatedClaude = Ancestor.make(10, argv0: nil, path: nil, exe: "2.1.290")
        let bound = try harness.accept("claude", "Stop", #"{}"#, env: ["CLAUDE_PID": "10", "CLAUDE_CODE_SESSION_ID": "from-env"],
                                       ancestry: [Ancestor.sh(30), updatedClaude])
        #expect(bound.agent == .claude)
        #expect(bound.agentProcess == updatedClaude.identity)
        #expect(bound.sessionKey == SessionKey(agent: .claude, id: "from-env"), "env session id only with a bound CLAUDE_PID")

        // CLAUDE_PID points outside the ancestry → not bound, env id ignored.
        let unbound = try harness.accept("claude", "Stop", #"{}"#, env: ["CLAUDE_PID": "999", "CLAUDE_CODE_SESSION_ID": "from-env"],
                                         ancestry: [Ancestor.sh(30), updatedClaude], at: 5)
        #expect(unbound.agentProcess == nil)
        #expect(unbound.sessionKey != SessionKey(agent: .claude, id: "from-env"))
        #expect(unbound.sessionKey == SessionKey.fallback(agent: .claude, identity: updatedClaude.identity))

        // The payload id always wins over the inherited env id.
        let payload = try harness.accept("claude", "Stop", #"{"session_id":"from-payload"}"#,
                                         env: ["CLAUDE_PID": "10", "CLAUDE_CODE_SESSION_ID": "from-env"],
                                         ancestry: [Ancestor.sh(30), updatedClaude], at: 10)
        #expect(payload.sessionKey == SessionKey(agent: .claude, id: "from-payload"))
    }

    @Test func claudePIDDoesNotBindAcrossAnotherMatchedAgent() throws {
        let matcher = StubMatcher(byArgv0: ["codex": AgentMatch(agent: .codex), "wrapper": AgentMatch(agent: .codex, isInfrastructure: true)])
        var harness = PipelineHarness(matcher: matcher)
        // argv claude, nearest non-infra match none; an (infrastructure) codex sits between hook and CLAUDE_PID.
        let event = try harness.accept("claude", "Stop", #"{}"#, env: ["CLAUDE_PID": "10", "CLAUDE_CODE_SESSION_ID": "s"],
                                       ancestry: [Ancestor.make(30, argv0: "wrapper"), Ancestor.make(10, argv0: "2.1.296")])
        #expect(event.agent == .claude)
        #expect(event.agentProcess == nil)
        #expect(event.sessionKey != SessionKey(agent: .claude, id: "s"))
    }

    // MARK: Host app

    @Test func hostFromEnvironmentThenAncestry() throws {
        var harness = PipelineHarness(bundles: ["/System/Applications/Utilities/Terminal.app": "com.apple.Terminal"])
        let fromBundleEnv = try harness.accept("claude", "Stop", #"{"session_id":"a"}"#,
                                               env: ["__CFBundleIdentifier": "com.apple.Terminal", "TERM_PROGRAM": "iTerm.app"],
                                               ancestry: [Ancestor.claude(30), Ancestor.zsh(20), Ancestor.terminal(5)])
        #expect(fromBundleEnv.host?.name == "Terminal")
        #expect(fromBundleEnv.host?.bundleID == "com.apple.Terminal")
        #expect(fromBundleEnv.host?.pid == 5, "pid filled from the matching ancestor")

        let fromTerm = try harness.accept("claude", "Stop", #"{"session_id":"b"}"#, env: ["TERM_PROGRAM": "iTerm.app"], at: 5)
        #expect(fromTerm.host?.name == "iTerm2")

        let fromAncestry = try harness.accept("claude", "Stop", #"{"session_id":"c"}"#,
                                              ancestry: [Ancestor.claude(30), Ancestor.zsh(20), Ancestor.login(6), Ancestor.terminal(5)], at: 10)
        #expect(fromAncestry.host?.bundleID == "com.apple.Terminal")
        #expect(fromAncestry.host?.pid == 5)

        let none = try harness.accept("claude", "Stop", #"{"session_id":"d"}"#, ancestry: [Ancestor.claude(30)], at: 15)
        #expect(none.host == nil)
    }

    @Test func appBundleLocation() {
        let helper = AttributionResolver.appBundleLocation(
            "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)")
        #expect(helper?.bundlePath == "/Applications/Cursor.app")
        #expect(helper?.isMainExecutable == false)
        let main = AttributionResolver.appBundleLocation("/Applications/Cursor.app/Contents/MacOS/Cursor")
        #expect(main?.bundlePath == "/Applications/Cursor.app")
        #expect(main?.isMainExecutable == true)
        #expect(AttributionResolver.appBundleLocation("/usr/bin/zsh") == nil)
        #expect(AttributionResolver.appBundleLocation("relative.app/Contents/MacOS/x") == nil)
    }

    @Test func aiderSessionIsItsPythonProcess() throws {
        var harness = PipelineHarness()
        let python = Ancestor.python(30)
        let event = try harness.accept("aider", "waiting", "", ancestry: [Ancestor.sh(40), python, Ancestor.zsh(20)])
        #expect(event.agent == .aider)
        #expect(event.event == .turnFinished(.ambiguous))
        #expect(event.sessionKey == SessionKey.fallback(agent: .aider, identity: python.identity))
        #expect(event.sessionKey.isProcessFallback)
    }

    /// `python -m aider` run from Claude's Bash tool: the hook records the module (`InboxAncestor.module`), the
    /// descriptor becomes `[python3, -m, aider]`, and a matcher with the interpreter rule (production's
    /// `AgentMatcher`, stubbed here) binds the Python process — never the outer Claude session.
    @Test func pythonModuleAiderIsAttributedThroughItsModule() throws {
        struct ModuleAwareMatcher: AgentSignatureMatching {
            let basic = BasicAgentSignatureMatcher()
            func match(_ process: ProcessDescriptor) -> AgentMatch? {
                if process.argv.count >= 3, process.argv[1] == "-m", process.argv[2] == "aider" { return AgentMatch(agent: .aider) }
                return basic.match(process)
            }
        }
        var harness = PipelineHarness(matcher: ModuleAwareMatcher())
        let python = InboxAncestor(pid: 30, ppid: 20, startSec: 1_791_800_030, startUsec: 30, exe: "Python",
                                   argv0: "python3", path: "/opt/homebrew/bin/python3.12", module: "aider")
        let claude = Ancestor.claude(10)
        let env = ["CLAUDE_PID": "10", "CLAUDE_CODE_SESSION_ID": "claude-session"]
        let event = try harness.accept("aider", "waiting", "", env: env, ancestry: [Ancestor.sh(40), python, Ancestor.zsh(20), claude])
        #expect(event.agent == .aider)
        #expect(event.agentProcess == python.identity)
        #expect(event.sessionKey == SessionKey.fallback(agent: .aider, identity: python.identity))

        // Without the module the same ancestry has no matched Aider process (only the argv label survives).
        var basic = PipelineHarness(matcher: ModuleAwareMatcher())
        var bare = python
        bare.module = nil
        let unbound = try basic.accept("aider", "waiting", "", env: env, ancestry: [Ancestor.sh(40), bare, Ancestor.zsh(20), claude])
        #expect(unbound.agent == .aider)
        #expect(unbound.agentProcess == nil)
    }

    @Test func environmentAgentMarkers() {
        #expect(AttributionResolver.environmentAgent(["CURSOR_VERSION": "1"]) == .cursor)
        #expect(AttributionResolver.environmentAgent(["GEMINI_SESSION_ID": "1"]) == .gemini)
        #expect(AttributionResolver.environmentAgent(["AI_AGENT": "crush"]) == .crush)
        #expect(AttributionResolver.environmentAgent(["AI_AGENT": "claude-code_2-1-288_harness"]) == .claude)
        #expect(AttributionResolver.environmentAgent(["AI_AGENT": "mystery"]) == nil)
        #expect(AttributionResolver.environmentAgent(["QWEN_PROJECT_DIR": "/p"]) == .qwen)
        #expect(AttributionResolver.environmentAgent(["CLAUDE_PID": "1"]) == .claude)
        #expect(AttributionResolver.environmentAgent(["CLAUDE_PID": "1", "CURSOR_VERSION": "2"]) == .cursor)
        #expect(AttributionResolver.environmentAgent([:]) == nil)
    }
}
