@testable import KakurenekoInstall
import KakurenekoKit
import Foundation
import Testing

/// Per-agent invariants of the entries we write (brief §3.3–3.6, R03/R04/R05; ARCHITECTURE §9.7).
@Suite("Snippet invariants", .timeLimit(.minutes(1)))
struct SnippetInvariantTests {
    /// What each installer writes into a fresh (missing) file, per target path.
    private func freshDocuments(_ installer: any IntegrationInstaller, _ context: InstallContext) throws -> [(path: String, text: String)] {
        try installer.managedFiles(context).filter { $0.role == .target }.map { file in
            (file.path, try file.splicer.install(into: nil, previous: nil).text)
        }
    }

    /// Event names (keys of the hooks container) in a JSON document we wrote.
    private func eventNames(_ text: String, path: String, agent: AgentID) throws -> [String] {
        let editor = try JSONEditor(text: text, dialect: .jsonc, path: path)
        let keys: [String] = switch agent {
        case .agy: [AgyInstaller.hookName]
        case .droid where path.hasSuffix("hooks.json"): []
        case .claude: path.hasSuffix("hooks/hooks.json") ? ["hooks"] : ["__none__"]
        default: ["hooks"]
        }
        return editor.node(at: keys)?.members?.map(\.key) ?? []
    }

    @Test func noBlockingOrPermissionHooksAnywhere() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let context = makeContext(home)
        let forbiddenEverywhere: Set = ["PreToolUse", "preToolUse", "BeforeTool", "beforeShellExecution", "beforeMCPExecution",
                                        "beforeReadFile", "subagentStart", "permissionRequest", "pre_run_command", "pre_write_code",
                                        "pre_read_code", "pre_mcp_tool_use"]
        for installer in IntegrationManager.defaultInstallers {
            for (path, text) in try freshDocuments(installer, context) where path.hasSuffix(".json") {
                let events = try eventNames(text, path: path, agent: installer.agent)
                #expect(Set(events).isDisjoint(with: forbiddenEverywhere), "\(installer.agent): \(events)")
                if installer.agent == .claude { #expect(!events.contains("PermissionRequest")) }
                #expect(!text.contains("\"async\""), "\(installer.agent) sets async")
                #expect(!text.contains("asyncRewake") && !text.contains("onFailure"))
            }
        }
    }

    @Test func everyShellRunEntryCarriesTheMarkerAndTheSafeSuffix() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let context = makeContext(home)
        for installer in IntegrationManager.defaultInstallers where installer.agent != .claude {
            for (path, text) in try freshDocuments(installer, context) where path.hasSuffix(".json") {
                let commands = commandStrings(text)
                #expect(!commands.isEmpty, "\(installer.agent) wrote no commands")
                for command in commands {
                    #expect(command.hasPrefix(home.hookPath + " " + installer.agent.rawValue + " "), "\(command)")
                    #expect(command.hasSuffix(" 2>/dev/null; exit 0"), "\(command)")
                    #expect(command.contains(KakurenekoID.ownershipMarker))
                }
            }
        }
    }

    @Test func timeoutsUseEachAgentsUnit() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let context = makeContext(home)
        func timeouts(_ agent: AgentID) throws -> Set<Double> {
            let installer = try #require(IntegrationManager.defaultInstallers.first { $0.agent == agent })
            var result: Set<Double> = []
            for (_, text) in try freshDocuments(installer, context) where text.hasPrefix("{") {
                func walk(_ node: JSONNode) {
                    switch node.kind {
                    case .object(let members):
                        for member in members {
                            if member.key == "timeout" || member.key == "timeoutSec", case .number(let n) = member.value.kind {
                                result.insert(Double(n) ?? -1)
                            }
                            walk(member.value)
                        }
                    case .array(let elements): elements.forEach(walk)
                    default: break
                    }
                }
                walk(try JSONSyntax.parse(text, dialect: .jsonc))
            }
            return result
        }
        #expect(try timeouts(.auggie) == [5000])
        #expect(try timeouts(.gemini) == [5000])
        #expect(try timeouts(.claude) == [5, 1])
        #expect(try timeouts(.codex) == [5, 1])
        for agent in [AgentID.droid, .qwen, .qoder, .codebuddy, .iflow, .devin, .agy, .copilot, .cursor] {
            #expect(try timeouts(agent) == [5], "\(agent)")
        }
        #expect(try timeouts(.windsurf).isEmpty) // Windsurf documents no timeout
    }

    @Test func theClaudeFamilyEventsFollowR04() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let context = makeContext(home)
        let expected: [AgentID: [String]] = [
            .droid: ["SessionStart", "UserPromptSubmit", "Notification", "Stop", "SessionEnd"],
            .qwen: ["SessionStart", "UserPromptSubmit", "Stop", "StopFailure", "Notification", "PermissionRequest", "SessionEnd"],
            .auggie: ["SessionStart", "Stop", "Notification", "SessionEnd"],
            .qoder: ["SessionStart", "UserPromptSubmit", "Stop", "Notification", "PermissionRequest", "SessionEnd"],
            .codebuddy: ["SessionStart", "UserPromptSubmit", "Stop", "Notification", "SessionEnd"],
            .iflow: ["SessionStart", "Stop", "Notification", "SessionEnd"],
            .devin: ["SessionStart", "Stop", "PermissionRequest", "SessionEnd"],
        ]
        #expect(Set(expected.keys) == AgentID.claudeCompatibleFamily)
        for installer in ClaudeFamilyInstaller.all {
            let documents = try freshDocuments(installer, context)
            #expect(documents.count == 1)
            let (path, text) = try #require(documents.first)
            #expect(try eventNames(text, path: path, agent: installer.agent) == expected[installer.agent], "\(installer.agent)")
            // Claude-shaped groups: { matcher?, hooks: [ { type: command, command, timeout, name? } ] }.
            let commands = try handlerCommands(text, containerKeys: installer.agent == .droid ? [] : ["hooks"])
            #expect(commands.count == expected[installer.agent]?.count)
        }
        let qwen = try #require(try freshDocuments(ClaudeFamilyInstaller(spec: ClaudeFamilyInstaller.qwen), context).first).text
        #expect(qwen.contains("\"matcher\": \"*\"") && qwen.contains("\"name\": \"kakureneko\""))
    }

    @Test func installersDescribeTheirFilesAndDirectories() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let context = makeContext(home)
        let installers = IntegrationManager.defaultInstallers
        #expect(installers.map(\.agent) == AgentID.installableInV1)
        let expected: [AgentID: [String]] = [
            .claude: ["~/.kakureneko/claude-plugin/.claude-plugin/marketplace.json",
                      "~/.kakureneko/claude-plugin/plugins/kakureneko/.claude-plugin/plugin.json",
                      "~/.kakureneko/claude-plugin/plugins/kakureneko/hooks/hooks.json"],
            .codex: ["~/.codex/config.toml", "~/.codex/hooks.json"],
            .gemini: ["~/.gemini/settings.json"],
            .agy: ["~/.gemini/config/hooks.json"],
            .copilot: ["~/.copilot/hooks/kakureneko.json"],
            .cursor: ["~/.cursor/hooks.json"],
            .opencode: ["~/.config/opencode/plugins/kakureneko.js"],
            .aider: ["~/.aider.conf.yml"],
            .droid: ["~/.factory/hooks.json"],
            .qwen: ["~/.qwen/settings.json"],
            .auggie: ["~/.augment/settings.json"],
            .qoder: ["~/.qoder/settings.json"],
            .codebuddy: ["~/.codebuddy/settings.json"],
            .iflow: ["~/.iflow/settings.json"],
            .devin: ["~/.config/devin/config.json"],
            .windsurf: ["~/.codeium/windsurf/hooks.json"],
        ]
        for installer in installers {
            #expect(installer.displayFiles(context) == expected[installer.agent], "\(installer.agent)")
            #expect(!installer.configDirectories(context).isEmpty)
        }
    }
}
