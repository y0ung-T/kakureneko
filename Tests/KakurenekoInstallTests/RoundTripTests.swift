@testable import KakurenekoInstall
import KakurenekoKit
import Foundation
import Testing

/// Pre-existing user setups for every v1 agent (the agent's directory exists, usually with a config of its own).
enum AgentSetups {
    /// Creates the agent's realistic config in `home`. Returns the user files that must survive untouched.
    @discardableResult
    static func prepare(_ agent: AgentID, in home: TestHome) throws -> [String] {
        switch agent {
        case .claude:
            try home.write(".claude/settings.json", "{\n  \"theme\": \"dark\",\n  \"enabledPlugins\": { \"vercel@claude-plugins-official\": true }\n}\n")
            try home.installFakeClaudeCLI()
            home.runner.setHandler(ClaudeCLIResponder.enabledAfterInstall())
            return [".claude/settings.json"]
        case .codex:
            try home.write(".codex/config.toml", Fixtures.codexConfig)
            try home.write(".codex/hooks.json", Fixtures.codexHooks)
            return [".codex/config.toml", ".codex/hooks.json"]
        case .gemini:
            try home.write(".gemini/settings.json", Fixtures.geminiSettings)
            return [".gemini/settings.json"]
        case .agy:
            try home.write(".gemini/config/hooks.json", Fixtures.agyHooks)
            return [".gemini/config/hooks.json"]
        case .copilot:
            try home.write(".copilot/config.json", "{\n  // managed automatically\n  \"firstLaunchAt\": \"2026-08-09\"\n}\n")
            return [".copilot/config.json"]
        case .cursor:
            try home.write(".cursor/hooks.json", Fixtures.cursorHooks)
            return [".cursor/hooks.json"]
        case .opencode:
            try home.write(".config/opencode/opencode.json", "{ \"$schema\": \"https://opencode.ai/config.json\", \"theme\": \"opencode\" }\n")
            return [".config/opencode/opencode.json"]
        case .aider:
            try home.write(".aider.conf.yml", Fixtures.aiderConfig)
            return [".aider.conf.yml"]
        case .droid:
            try home.write(".factory/settings.json", Fixtures.droidSettings)
            return [".factory/settings.json"]
        case .qwen:
            try home.write(".qwen/settings.json", Fixtures.qwenSettings)
            return [".qwen/settings.json"]
        case .auggie:
            try home.write(".augment/settings.json", Fixtures.auggieSettings)
            return [".augment/settings.json"]
        case .qoder:
            try home.write(".qoder/settings.json", "{\n  \"permissions\": { \"allow\": [\"Bash(git status)\"] }\n}\n")
            return [".qoder/settings.json"]
        case .codebuddy:
            try home.mkdir(".codebuddy") // no settings file yet: we create it and delete it again
            return []
        case .iflow:
            try home.write(".iflow/settings.json", "{\n  // iflow\n  \"theme\": \"Default\"\n}\n")
            return [".iflow/settings.json"]
        case .devin:
            try home.write(".config/devin/config.json", Fixtures.devinConfig)
            return [".config/devin/config.json"]
        case .windsurf:
            try home.write(".codeium/windsurf/hooks.json", Fixtures.windsurfHooks)
            return [".codeium/windsurf/hooks.json"]
        default:
            Issue.record("no setup for \(agent)")
            return []
        }
    }
}

/// Scripted answers of the fake `claude` CLI.
enum ClaudeCLIResponder {
    static let enabledList = #"{"plugins":[{"id":"kakureneko@kakureneko-local","name":"kakureneko","marketplace":"kakureneko-local","enabled":true}]}"#

    /// Every mutating call succeeds; `plugin list --json` reports the plugin enabled.
    static func enabledAfterInstall() -> FakeSubprocessRunner.Handler {
        { request in
            if request.arguments == ["plugin", "list", "--json"] {
                return SubprocessResult(exitCode: 0, stdout: Data((enabledList + "\n").utf8))
            }
            return SubprocessResult(exitCode: 0, stdout: Data(#"{"success":true}"#.utf8))
        }
    }
}

/// Command strings (`command` / `bash` values) anywhere in a JSON document.
func commandStrings(_ text: String?) -> [String] {
    guard let text, let root = try? JSONSyntax.parse(text, dialect: .jsonc) else { return [] }
    var result: [String] = []
    func walk(_ node: JSONNode) {
        switch node.kind {
        case .object(let members):
            for member in members {
                if member.key == "command" || member.key == "bash", let value = member.value.stringValue { result.append(value) }
                walk(member.value)
            }
        case .array(let elements): elements.forEach(walk)
        default: break
        }
    }
    walk(root)
    return result
}

/// Every entry we wrote carries the ownership marker.
func expectEveryEntryOwned(_ change: FileChange, hookPath: String) throws {
    guard let after = change.after else { return }
    switch (change.path as NSString).pathExtension {
    case "json":
        var before = commandStrings(change.before)
        var added: [String] = []
        for command in commandStrings(after) {
            if let index = before.firstIndex(of: command) { before.remove(at: index) } else { added.append(command) }
        }
        if change.path.hasSuffix("/marketplace.json") || change.path.hasSuffix("/plugin.json") { return }
        #expect(!added.isEmpty, "no entries added to \(change.path)")
        for command in added { #expect(command.contains(KakurenekoID.ownershipMarker), "\(command) lacks the marker") }
    case "toml":
        let document = try TOMLDocument(after)
        guard case .keyValue(_, let value)? = document.rootKeyValue("notify")?.kind else {
            Issue.record("no notify in \(change.path)")
            return
        }
        #expect(value.stringArray?.first == hookPath)
    case "yml":
        let document = try YAMLDocument(after)
        let entry = try #require(document.entries(named: AiderConfigSplicer.commandKey).first)
        guard case .string(let command) = try document.scalar(of: entry) else {
            Issue.record("no command in \(change.path)")
            return
        }
        #expect(command.contains(KakurenekoID.ownershipMarker))
    case "js":
        #expect(after.contains("const HOOK = \"\(hookPath)\""))
    default:
        Issue.record("unexpected file \(change.path)")
    }
}

@Suite("Install/uninstall round trips for every v1 agent", .timeLimit(.minutes(1)))
struct RoundTripTests {
    /// Files outside `~/.kakureneko` (Kakureneko's own backups, manifest and plugin live there).
    private func userFiles(_ home: TestHome) -> [String: TestHome.Item] {
        home.snapshot().filter { key, value in
            if case .directory = value { return false }
            return !key.contains("/.kakureneko/")
        }
    }

    @Test(arguments: AgentID.installableInV1)
    func installThenUninstallRestoresEveryFileByteForByte(_ agent: AgentID) async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        try AgentSetups.prepare(agent, in: home)
        let manager = home.manager()
        let original = userFiles(home)

        let before = await manager.statuses().first { $0.agent == agent }
        #expect(before?.configDirExists == true)
        #expect(before?.installed == false)
        #expect(before?.needsRepair == false)

        let result = try await manager.install(agent)
        #expect(!result.dryRun)
        #expect(!result.plan.changes.isEmpty)
        #expect(result.status.installed)
        #expect(!result.status.needsRepair)
        for change in result.plan.changes {
            try expectEveryEntryOwned(change, hookPath: home.hookPath)
            #expect(!change.unifiedDiff.isEmpty)
        }
        // Backups exist for every pre-existing file we modified, holding the original bytes.
        for change in result.plan.changes where change.kind == .modify {
            let basename = (change.path as NSString).lastPathComponent
            let backups = try FileManager.default.contentsOfDirectory(atPath: home.paths.backupDirectory(for: agent).path(percentEncoded: false))
                .filter { $0.hasPrefix(basename + ".") }
            #expect(backups.count == 1)
        }
        #expect(result.backups.count == result.plan.changes.filter { $0.kind == .modify && $0.path.contains("/.kakureneko/") == false }.count)

        // The manifest records every file with the hash of what is on disk now.
        let manifest = try KakurenekoJSON.decode(InstallManifest.self, from: Data(contentsOf: home.paths.installManifestFile))
        let entries = manifest.entries(for: agent)
        #expect(!entries.isEmpty)
        for entry in entries {
            let data = try Data(contentsOf: URL(filePath: entry.file))
            #expect(entry.sha256After == Digest.sha256Hex(data))
            #expect(entry.installedAt == home.clock.now())
            #expect(entry.helperVersion == KakurenekoKit.marketingVersion)
        }

        let listed = await manager.statuses().first { $0.agent == agent }
        #expect(listed?.installed == true)
        #expect(listed?.needsRepair == false)

        // Re-install is a no-op.
        let installedState = home.snapshot()
        let again = try await manager.install(agent)
        #expect(again.plan.isEmpty)
        #expect(again.backups.isEmpty)
        #expect(home.snapshot() == installedState)

        let removed = try await manager.uninstall(agent)
        #expect(!removed.status.installed)
        #expect(!removed.status.needsRepair)
        #expect(userFiles(home) == original)
        let after = try KakurenekoJSON.decode(InstallManifest.self, from: Data(contentsOf: home.paths.installManifestFile))
        #expect(after.entries(for: agent).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: home.paths.claudePluginDirectory.path(percentEncoded: false)))

        // Uninstalling again finds nothing.
        let nothing = try await manager.uninstall(agent)
        #expect(nothing.plan.isEmpty)
    }

    /// Edits made after the install (by the user or the agent) survive the surgical uninstall.
    @Test(arguments: [
        (AgentID.codex, ".codex/config.toml", "model = \"gpt-5.5\"", "model = \"o3\""),
        (.gemini, ".gemini/settings.json", "\"theme\": \"GitHub\"", "\"theme\": \"Dracula\""),
        (.cursor, ".cursor/hooks.json", "say done", "say finished"),
        (.aider, ".aider.conf.yml", "model: sonnet", "model: opus"),
        (.droid, ".factory/settings.json", "npm run lint", "npm run lint:fix"),
        (.qwen, ".qwen/settings.json", "qwen3-coder", "qwen3-max"),
        (.agy, ".gemini/config/hooks.json", "~/bin/guard.sh", "~/bin/guard2.sh"),
        (.devin, ".config/devin/config.json", "\"dark\"", "\"light\""),
        (.windsurf, ".codeium/windsurf/hooks.json", "prettier --write", "prettier --check"),
    ])
    func uninstallKeepsLaterEdits(_ agent: AgentID, _ file: String, _ from: String, _ to: String) async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        try AgentSetups.prepare(agent, in: home)
        let original = try #require(home.read(file))
        let manager = home.manager()
        _ = try await manager.install(agent)
        let installed = try #require(home.read(file))
        #expect(installed.contains(from))
        try home.write(file, installed.replacingOccurrences(of: from, with: to))

        let status = await manager.statuses().first { $0.agent == agent }
        #expect(status?.installed == true)
        #expect(status?.needsRepair == false)

        _ = try await manager.uninstall(agent)
        #expect(home.read(file) == original.replacingOccurrences(of: from, with: to))
    }
}
