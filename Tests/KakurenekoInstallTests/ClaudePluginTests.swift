@testable import KakurenekoInstall
import Darwin
import KakurenekoKit
import Foundation
import Synchronization
import Testing

/// A scripted `claude` CLI: every call succeeds, `plugin list --json` reports the plugin as `state` says.
final class FakeClaudeCLI: Sendable {
    enum PluginState: Sendable { case enabled, disabled, absent }
    private let state: Mutex<PluginState>
    /// Arguments of a call that should fail, with its stderr.
    private let failure = Mutex<(arguments: [String], stderr: String, exitCode: Int32)?>(nil)

    init(_ initial: PluginState = .absent) { state = Mutex(initial) }

    func set(_ new: PluginState) { state.withLock { $0 = new } }
    func fail(_ arguments: [String], exitCode: Int32 = 1, stderr: String) { failure.withLock { $0 = (arguments, stderr, exitCode) } }

    var handler: FakeSubprocessRunner.Handler {
        { [self] request in
            if let failure = failure.withLock({ $0 }), failure.arguments == request.arguments {
                return SubprocessResult(exitCode: failure.exitCode, stderr: Data(failure.stderr.utf8))
            }
            switch Array(request.arguments.prefix(2)) {
            case ["plugin", "list"]:
                let list: String = switch state.withLock({ $0 }) {
                case .enabled: #"[{"id":"kakureneko@kakureneko-local","scope":"user","enabled":true}]"#
                case .disabled: #"[{"id":"kakureneko@kakureneko-local","scope":"user","enabled":false}]"#
                case .absent: #"[{"id":"vercel@claude-plugins-official","scope":"user","enabled":true}]"#
                }
                return SubprocessResult(exitCode: 0, stdout: Data(("Checking plugins…\n" + list + "\n").utf8))
            case ["plugin", "install"], ["plugin", "enable"]:
                set(.enabled)
            case ["plugin", "uninstall"]:
                set(.absent)
            default:
                break
            }
            return SubprocessResult(exitCode: 0, stdout: Data(#"{"success":true}"#.utf8))
        }
    }
}

@Suite("Claude Code plugin", .timeLimit(.minutes(1)))
struct ClaudePluginTests {
    private func setUp(_ home: TestHome, cli: FakeClaudeCLI = FakeClaudeCLI()) throws -> String {
        try home.deployFakeHelper()
        try home.write(".claude/settings.json", "{\n  \"theme\": \"dark\"\n}\n")
        home.runner.setHandler(cli.handler)
        return try home.installFakeClaudeCLI()
    }

    private func pluginDirectoryArgument(_ home: TestHome) -> String {
        home.paths.claudePluginDirectory.path(percentEncoded: false).trimmingTrailingSlashForCLI
    }

    private func expectAgentEnvironment(_ request: SubprocessRequest, _ home: TestHome) {
        for (key, value) in home.paths.agentSubprocessEnvironment {
            #expect(request.extraEnvironment[key] == value, "\(key) missing on \(request.displayString)")
        }
        #expect(request.extraEnvironment["DISABLE_AUTOUPDATER"] == "1")
        #expect(request.environment == nil)
        #expect(request.stdin == nil) // /dev/null
    }

    @Test func installAndUninstallIssueExactlyTheBriefsCommands() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let cli = try setUp(home)
        let manager = home.manager()

        let result = try await manager.install(.claude)
        let installCalls = home.runner.requests
        #expect(installCalls.map(\.executable) == [cli, cli, cli])
        #expect(installCalls.map(\.arguments) == [
            ["plugin", "marketplace", "add", pluginDirectoryArgument(home), "--scope", "user", "--json"],
            ["plugin", "install", "kakureneko@kakureneko-local", "--scope", "user", "--json"],
            ["plugin", "list", "--json"],
        ])
        #expect(installCalls.map(\.effect) == [.mutating, .mutating, .readOnly])
        for request in installCalls { expectAgentEnvironment(request, home) }
        // The home is a temp home: the agent dirs are pinned inside it, never the real ~/.claude.
        #expect(installCalls.first?.extraEnvironment["CLAUDE_CONFIG_DIR"] == home.paths.claudeConfigDirectory.path(percentEncoded: false).trimmingTrailingSlashForCLI)
        #expect(!pluginDirectoryArgument(home).hasSuffix("/"))

        #expect(result.plan.commands.map(\.arguments) == Array(installCalls.prefix(2).map(\.arguments)))
        #expect(result.plan.commands.allSatisfy { $0.executable == cli && !$0.purpose.isEmpty })
        #expect(result.plan.followUpNote == ClaudePluginInstaller.followUp)
        #expect(result.messages.contains(ClaudePluginInstaller.followUp))
        #expect(result.status.installed)
        #expect(!result.status.needsRepair)
        #expect(result.backups.isEmpty) // Kakureneko's own files are not backed up
        #expect(home.read(".claude/settings.json") == "{\n  \"theme\": \"dark\"\n}\n")
        let entries = try home.manifest().entries(for: .claude)
        #expect(entries.count == 3)
        #expect(entries.allSatisfy { $0.kind == .cliPlugin && $0.sha256Before == nil })

        let before = home.runner.requests.count
        let removed = try await manager.uninstall(.claude)
        let uninstallCalls = Array(home.runner.requests.dropFirst(before))
        #expect(uninstallCalls.map(\.arguments) == [
            ["plugin", "uninstall", "kakureneko@kakureneko-local", "--scope", "user", "--json"],
            ["plugin", "marketplace", "remove", "kakureneko-local", "--json"],
        ])
        #expect(uninstallCalls.allSatisfy { $0.effect == .mutating && $0.executable == cli })
        for request in uninstallCalls { expectAgentEnvironment(request, home) }
        #expect(!removed.status.installed)
        #expect(Set(removed.plan.changes.map(\.kind)) == [.delete])
        #expect(!home.exists(".kakureneko/claude-plugin"))
        #expect(try home.manifest().entries(for: .claude).isEmpty)
        #expect(home.read(".claude/settings.json") == "{\n  \"theme\": \"dark\"\n}\n")
    }

    @Test func pluginFilesMatchSnippetA() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        _ = try setUp(home)
        _ = try await home.manager().install(.claude)

        let marketplace = try JSONEditor(text: try #require(home.read(".kakureneko/claude-plugin/.claude-plugin/marketplace.json")), dialect: .strict, path: "m")
        #expect(marketplace.root.members?.map(\.key) == ["name", "owner", "description", "plugins"])
        #expect(marketplace.node(at: ["name"])?.stringValue == "kakureneko-local")
        #expect(marketplace.node(at: ["owner", "name"])?.stringValue == "Kakureneko")
        let listed = try #require(marketplace.node(at: ["plugins"])?.elements?.first)
        #expect(listed.member("name")?.value.stringValue == "kakureneko")
        #expect(listed.member("source")?.value.stringValue == "./plugins/kakureneko")

        let plugin = try JSONEditor(text: try #require(home.read(".kakureneko/claude-plugin/plugins/kakureneko/.claude-plugin/plugin.json")), dialect: .strict, path: "p")
        #expect(plugin.node(at: ["name"])?.stringValue == "kakureneko")
        #expect(plugin.node(at: ["version"])?.stringValue == "1.0.0")
        #expect(plugin.node(at: ["author", "name"])?.stringValue == "Kakureneko")

        let hooksText = try #require(home.read(".kakureneko/claude-plugin/plugins/kakureneko/hooks/hooks.json"))
        let hooks = try JSONEditor(text: hooksText, dialect: .strict, path: "h")
        #expect(hooks.root.members?.map(\.key) == ["description", "hooks"])
        let events = try #require(hooks.node(at: ["hooks"])?.members)
        #expect(events.map(\.key) == ["SessionStart", "UserPromptSubmit", "Stop", "StopFailure", "Notification", "SessionEnd"])
        for event in events {
            let groups = try #require(event.value.elements)
            #expect(groups.count == 1)
            let handlers = try #require(groups[0].member("hooks")?.value.elements)
            #expect(handlers.count == 1)
            let handler = handlers[0]
            #expect(handler.members?.map(\.key) == ["type", "command", "args", "timeout"])
            #expect(handler.member("type")?.value.stringValue == "command")
            #expect(handler.member("command")?.value.stringValue == home.hookPath)
            #expect(handler.member("args")?.value.value == .array([.string("claude"), .string(event.key)]))
            #expect(handler.member("timeout")?.value.value == .number(event.key == "SessionEnd" ? 1 : 5))
            #expect(groups[0].member("matcher")?.value.stringValue == (event.key == "Notification"
                ? "permission_prompt|idle_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input|agent_completed|quota_auto_resume_fired|quota_auto_resume_stale|quota_auto_resume_disabled"
                : nil))
        }
        for forbidden in ["async", "asyncRewake", "onFailure", "PermissionRequest"] {
            #expect(!hooksText.contains("\"\(forbidden)\""))
        }
    }

    @Test func reinstallingAnEnabledPluginOnlyQueriesTheCLI() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        _ = try setUp(home)
        let manager = home.manager()
        _ = try await manager.install(.claude)
        let before = home.runner.requests.count

        let again = try await manager.install(.claude)
        #expect(again.plan.isEmpty)
        #expect(again.messages.first == "Already up to date.")
        let calls = Array(home.runner.requests.dropFirst(before))
        #expect(!calls.isEmpty)
        #expect(calls.allSatisfy { $0.arguments == ["plugin", "list", "--json"] && $0.effect == .readOnly })
    }

    @Test func aCLIFailureRollsTheFilesBackAndReportsIt() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let cli = FakeClaudeCLI()
        _ = try setUp(home, cli: cli)
        cli.fail(["plugin", "install", "kakureneko@kakureneko-local", "--scope", "user", "--json"], stderr: "Error: plugin source could not be read")
        let manager = home.manager()

        do {
            _ = try await manager.install(.claude)
            Issue.record("install succeeded although the CLI failed")
        } catch let error as InstallError {
            guard case .cliFailed(_, let detail) = error else {
                Issue.record("unexpected \(error)")
                return
            }
            #expect(detail.contains("exit 1"))
            #expect(detail.contains("could not be read"))
        }
        #expect(!home.exists(".kakureneko/claude-plugin/plugins/kakureneko/hooks/hooks.json"))
        #expect(!home.exists(".kakureneko/claude-plugin/.claude-plugin/marketplace.json"))
        #expect(try home.manifest().entries.isEmpty)
    }

    @Test func alreadyDoneFailuresAreBenign() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let cli = FakeClaudeCLI()
        _ = try setUp(home, cli: cli)
        cli.fail(["plugin", "marketplace", "add", pluginDirectoryArgument(home), "--scope", "user", "--json"],
                 stderr: "Marketplace 'kakureneko-local' is already installed")
        let result = try await home.manager().install(.claude)
        #expect(result.status.installed)
        #expect(!result.status.needsRepair)
    }

    @Test func aDisabledPluginIsFlaggedAndRepairReEnablesIt() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let cli = FakeClaudeCLI()
        _ = try setUp(home, cli: cli)
        let manager = home.manager()
        _ = try await manager.install(.claude)

        cli.set(.disabled) // the user disabled it in /plugin
        let status = try #require(await manager.statuses().first { $0.agent == .claude })
        #expect(status.installed)
        #expect(status.needsRepair)
        #expect(status.notes.contains("The plugin is disabled in Claude Code."))

        let preview = try await manager.preview(.claude, operation: .repair)
        #expect(preview.changes.isEmpty)
        #expect(preview.commands.map(\.arguments) == [["plugin", "enable", "kakureneko@kakureneko-local", "--scope", "user"]])
        let before = home.runner.requests.count
        let repaired = try await manager.repair(.claude)
        #expect(repaired.status.installed)
        #expect(!repaired.status.needsRepair)
        let mutating = home.runner.requests.dropFirst(before).filter { $0.effect == .mutating }
        #expect(mutating.map(\.arguments) == [["plugin", "enable", "kakureneko@kakureneko-local", "--scope", "user"]])
    }

    @Test func aPluginRemovedBehindKakurenekosBackIsReinstalledByRepair() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let cli = FakeClaudeCLI()
        _ = try setUp(home, cli: cli)
        let manager = home.manager()
        _ = try await manager.install(.claude)

        cli.set(.absent) // `claude plugin uninstall` run by the user
        var status = try #require(await manager.statuses().first { $0.agent == .claude })
        #expect(!status.installed)
        #expect(status.needsRepair)
        let repaired = try await manager.repair(.claude)
        #expect(repaired.plan.commands.map { Array($0.arguments.prefix(3)) } == [["plugin", "marketplace", "add"], ["plugin", "install", "kakureneko@kakureneko-local"]])
        #expect(repaired.status.installed)

        // A deleted hooks.json (Kakureneko's own file) is rewritten too.
        try FileManager.default.removeItem(at: home.url(".kakureneko/claude-plugin/plugins/kakureneko/hooks/hooks.json"))
        status = try #require(await manager.statuses().first { $0.agent == .claude })
        #expect(status.needsRepair)
        let rewritten = try await manager.repair(.claude)
        #expect(rewritten.plan.changes.map(\.kind) == [.create])
        #expect(home.exists(".kakureneko/claude-plugin/plugins/kakureneko/hooks/hooks.json"))
    }

    @Test func aMissingCLIBlocksInstallButNotPreviewOrDryRun() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        try home.mkdir(".claude")
        let manager = home.manager()
        let before = home.snapshot()

        await #expect(throws: SideEffectError.self) { try await manager.install(.claude) }
        #expect(home.snapshot() == before)
        let preview = try await manager.preview(.claude)
        #expect(preview.warnings.contains { $0.contains("claude command was not found") })
        #expect(preview.commands.allSatisfy { $0.executable == "claude" })
        #expect(preview.changes.count == 3)

        let dry = try await home.manager(gate: .alwaysOn()).install(.claude)
        #expect(dry.dryRun)
        #expect(home.ledger.entries(action: "subprocess.run").count == 2)
        #expect(home.snapshot() == before)
        #expect(home.runner.requests.isEmpty)
    }

    @Test func theLoginShellLocatesTheCLIReadOnly() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        try home.mkdir(".claude")
        let tool = try home.write("tools/bin/claude", "#!/bin/sh\nexit 0\n")
        chmod(tool.path(percentEncoded: false), 0o755)
        let cli = FakeClaudeCLI()
        let toolPath = tool.path(percentEncoded: false)
        home.runner.setHandler { request in
            if request.executable == "/bin/zsh" {
                return SubprocessResult(exitCode: 0, stdout: Data("Welcome!\n\(toolPath)\n".utf8))
            }
            return try cli.handler(request)
        }
        let result = try await home.manager(loginShellLookup: true).install(.claude)
        #expect(result.status.installed)
        let requests = home.runner.requests
        let lookup = try #require(requests.first)
        #expect(lookup.executable == "/bin/zsh")
        #expect(lookup.arguments == ["-lc", "command -v claude"])
        #expect(lookup.effect == .readOnly)
        expectAgentEnvironment(lookup, home)
        #expect(requests.dropFirst().allSatisfy { $0.executable == toolPath })
    }

    @Test func uninstallWithoutTheCLIStillRemovesTheFiles() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let cli = try setUp(home)
        let manager = home.manager()
        _ = try await manager.install(.claude)
        try FileManager.default.removeItem(atPath: cli)

        let removed = try await manager.uninstall(.claude)
        #expect(removed.messages.contains { $0.contains("claude plugin uninstall kakureneko@kakureneko-local") })
        #expect(!home.exists(".kakureneko/claude-plugin"))
        #expect(try home.manifest().entries(for: .claude).isEmpty)
    }

    @Test func aNormalHomeDoesNotPinClaudeConfigDir() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        try home.mkdir("alt-claude")
        home.runner.setHandler(FakeClaudeCLI().handler)
        let cli = try home.installFakeClaudeCLI()
        let paths = home.paths(environment: ["CLAUDE_CONFIG_DIR": home.url("alt-claude").path(percentEncoded: false)])
        let manager = home.manager(paths: paths)

        let status = try #require(await manager.statuses().first { $0.agent == .claude })
        #expect(status.configDirExists) // ~/.claude does not exist; $CLAUDE_CONFIG_DIR does
        _ = try await manager.install(.claude)
        let requests = home.runner.requests
        #expect(!requests.isEmpty)
        for request in requests {
            #expect(request.executable == cli)
            var environment = request.extraEnvironment
            #expect(environment.removeValue(forKey: "PATH")?.hasPrefix(URL(filePath: cli).deletingLastPathComponent().path(percentEncoded: false).trimmingTrailingSlashForCLI) == true)
            #expect(environment == ["HOME": home.paths.home.path(percentEncoded: false).trimmingTrailingSlashForCLI, "DISABLE_AUTOUPDATER": "1"])
        }
    }
}

@Suite("claude plugin list parsing", .timeLimit(.minutes(1)))
struct ClaudePluginStateTests {
    private func parse(_ stdout: String, exitCode: Int32 = 0) -> ClaudePluginState {
        ClaudePluginState.parse(SubprocessResult(exitCode: exitCode, stdout: Data(stdout.utf8)))
    }

    @Test func understandsTheLikelyShapes() {
        #expect(parse(#"[{"id":"kakureneko@kakureneko-local","enabled":true}]"#) == .enabled)
        #expect(parse(#"[{"id":"kakureneko@kakureneko-local","enabled":false}]"#) == .disabled)
        #expect(parse(#"{"plugins":[{"name":"kakureneko","marketplace":"kakureneko-local"}]}"#) == .enabled)
        #expect(parse(#"{"plugins":[{"name":"kakureneko","marketplaceName":"kakureneko-local","isEnabled":false}]}"#) == .disabled)
        #expect(parse(#"{"enabledPlugins":{"kakureneko@kakureneko-local":false}}"#) == .disabled)
        #expect(parse(#"{"installed":{"kakureneko@kakureneko-local":{"version":"1.0.0"}}}"#) == .enabled)
        #expect(parse("Loading…\nwarning: something\n" + #"[{"id":"kakureneko@kakureneko-local","enabled":true}]"# + "\n") == .enabled)
    }

    @Test func otherPluginsAndFailures() {
        #expect(parse(#"[{"id":"kakureneko@someone-else","enabled":true}]"#) == .absent)
        #expect(parse(#"{"plugins":[{"name":"kakureneko","marketplace":"elsewhere"}]}"#) == .absent)
        #expect(parse("[]") == .absent)
        #expect(parse(#"[{"id":"kakureneko@kakureneko-local","enabled":true}]"#, exitCode: 1) == .unknown)
        #expect(parse("Unknown command: plugin") == .unknown)
        #expect(parse("kakureneko@kakureneko-local (enabled)") == .enabled)
        #expect(ClaudePluginState.parse(SubprocessResult(exitCode: 0, timedOut: true)) == .unknown)
    }
}
