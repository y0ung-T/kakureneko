@testable import KakurenekoInstall
import Darwin
import KakurenekoKit
import Foundation
import Testing

@Suite("IntegrationManager rules", .timeLimit(.minutes(1)))
struct ManagerRuleTests {
    @Test func agentsWithoutAConfigDirectoryAreNotOfferedAndNothingIsCreated() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        let manager = home.manager()
        let before = home.snapshot()

        let statuses = await manager.statuses()
        #expect(statuses.map(\.agent) == AgentID.installableInV1)
        for status in statuses {
            #expect(status.supported)
            #expect(!status.configDirExists, "\(status.agent) offered without its config dir")
            #expect(!status.installed)
            #expect(!status.needsRepair)
            #expect(!status.needsTrustStep)
            #expect(status.lastEventSeen == nil)
            #expect(!status.configFiles.isEmpty)
        }
        for agent in AgentID.installableInV1 {
            await #expect(throws: SideEffectError.self) { try await manager.install(agent) }
            await #expect(throws: SideEffectError.self) { try await manager.repair(agent) }
            await #expect(throws: SideEffectError.self) { try await manager.preview(agent) }
            // Uninstalling something that was never installed is a harmless no-op.
            let removed = try await manager.uninstall(agent)
            #expect(removed.plan.isEmpty)
        }
        #expect(home.snapshot() == before)
        #expect(home.runner.requests.isEmpty)
    }

    @Test func agentsWithoutAnInstallerAreRejected() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        try home.mkdir(".config/zed")
        let manager = home.manager()
        for agent in [AgentID.zed, .vscode, .kiro, .unknown] {
            await #expect(throws: SideEffectError.self) { try await manager.install(agent) }
            await #expect(throws: SideEffectError.self) { try await manager.preview(agent, operation: .uninstall) }
        }
    }

    @Test func installWithoutADeployedHelperThrowsAndWritesNothing() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try AgentSetups.prepare(.gemini, in: home)
        let manager = home.manager()
        let before = home.snapshot()
        await #expect(throws: SideEffectError.unavailable("hook helper not deployed")) { try await manager.install(.gemini) }
        await #expect(throws: SideEffectError.unavailable("hook helper not deployed")) { try await manager.repair(.gemini) }
        #expect(home.snapshot() == before)

        // A helper that is not executable does not count either.
        try FileManager.default.createDirectory(at: home.paths.binDirectory, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: home.paths.hookBinary)
        chmod(home.paths.hookBinary.path(percentEncoded: false), 0o644)
        await #expect(throws: SideEffectError.unavailable("hook helper not deployed")) { try await manager.install(.gemini) }

        // The preview still works and warns.
        let plan = try await manager.preview(.gemini)
        #expect(!plan.changes.isEmpty)
        #expect(plan.warnings.contains { $0.contains("not deployed") })
        #expect(home.read(".gemini/settings.json") == Fixtures.geminiSettings)
    }

    @Test func installWithoutAHelperSucceedsInDryRun() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try AgentSetups.prepare(.gemini, in: home)
        let before = home.snapshot()
        let result = try await home.manager(gate: .alwaysOn()).install(.gemini)
        #expect(result.dryRun)
        #expect(result.plan.changes.count == 1)
        #expect(result.messages.first == "Dry run: nothing was written.")
        #expect(home.snapshot() == before)
    }

    @Test(arguments: AgentID.installableInV1)
    func dryRunPlansEverythingAndWritesNothing(_ agent: AgentID) async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try AgentSetups.prepare(agent, in: home)
        let before = home.snapshot()
        let manager = home.manager(gate: .alwaysOn())

        let result = try await manager.install(agent)
        #expect(result.dryRun)
        #expect(result.backups.isEmpty)
        #expect(!result.plan.changes.isEmpty)
        #expect(!result.status.installed)
        #expect(home.snapshot() == before)
        let fileLines = home.ledger.entries.filter { $0.action == "install.write" || $0.action == "install.delete" }
        #expect(fileLines.count == result.plan.changes.count)
        #expect(fileLines.allSatisfy { $0.category == .install && $0.detail.hasPrefix("would ") })
        // No mutating CLI call reached the runner; the gated runner logged them instead.
        #expect(home.runner.requests.allSatisfy { $0.effect == .readOnly })
        let commandLines = home.ledger.entries(action: "subprocess.run")
        #expect(commandLines.count == result.plan.commands.count)
        if agent == .claude {
            #expect(result.plan.commands.map(\.arguments) == [
                ["plugin", "marketplace", "add", home.paths.claudePluginDirectory.path(percentEncoded: false).trimmingTrailingSlashForCLI,
                 "--scope", "user", "--json"],
                ["plugin", "install", "kakureneko@kakureneko-local", "--scope", "user", "--json"],
            ])
        }

        // Dry-run uninstall and repair of a real install change nothing either.
        try home.deployFakeHelper()
        _ = try await home.manager().install(agent)
        let installed = home.snapshot()
        home.ledger.removeAll()
        let removal = try await manager.uninstall(agent)
        #expect(removal.dryRun)
        #expect(!removal.plan.changes.isEmpty)
        #expect(home.snapshot() == installed)
        #expect(!home.ledger.entries.filter { $0.action.hasPrefix("install.") }.isEmpty)
        let repair = try await manager.repair(agent)
        #expect(repair.dryRun)
        #expect(home.snapshot() == installed)
    }

    @Test func previewShowsDiffsForInstallUninstallAndRepairAndWritesNothing() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        try AgentSetups.prepare(.gemini, in: home)
        let manager = home.manager()
        let pristine = home.snapshot()

        let install = try await manager.preview(.gemini)
        #expect(install.operation == .install)
        let change = try #require(install.changes.first)
        #expect(install.changes.count == 1)
        #expect(change.kind == .modify)
        #expect(change.path == home.url(".gemini/settings.json").path(percentEncoded: false))
        #expect(change.before == Fixtures.geminiSettings)
        #expect(change.unifiedDiff.hasPrefix("--- ~/.gemini/settings.json\n+++ ~/.gemini/settings.json\n@@ "))
        let added = change.unifiedDiff.split(separator: "\n").filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }
        #expect(added.filter { $0.contains(KakurenekoID.ownershipMarker) }.count == 5)
        // The user's own AfterAgent hook stays (it only gains the comma before ours).
        #expect(added.contains { $0.contains("\"my-logger\"") && $0.hasSuffix(",") })
        #expect(change.after?.contains("~/bin/log-turn.sh") == true)
        #expect(try await manager.preview(.gemini, operation: .uninstall).isEmpty)
        #expect(home.snapshot() == pristine)

        _ = try await manager.install(.gemini)
        let installed = home.snapshot()
        let uninstall = try await manager.preview(.gemini, operation: .uninstall)
        #expect(uninstall.operation == .uninstall)
        #expect(uninstall.changes.first?.after == Fixtures.geminiSettings)
        let diffLines = (uninstall.changes.first?.unifiedDiff ?? "").split(separator: "\n")
        let removedLines = diffLines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }
        let addedLines = diffLines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }
        #expect(removedLines.filter { $0.contains(KakurenekoID.ownershipMarker) }.count == 5)
        #expect(!addedLines.contains { $0.contains(KakurenekoID.ownershipMarker) })
        #expect(try await manager.preview(.gemini, operation: .repair).isEmpty)
        #expect(home.snapshot() == installed)

        // Gemini rewrote its settings and dropped our hooks: the repair preview re-adds them.
        let rewritten = Fixtures.geminiSettings.replacingOccurrences(of: "\"GitHub\"", with: "\"Dracula\"")
        try home.write(".gemini/settings.json", rewritten)
        let afterRewrite = home.snapshot()
        let repair = try await manager.preview(.gemini, operation: .repair)
        #expect(repair.operation == .repair)
        #expect(repair.changes.count == 1)
        #expect(repair.changes.first?.before == rewritten)
        #expect(repair.changes.first?.after?.contains(KakurenekoID.ownershipMarker) == true)
        #expect(repair.changes.first?.after?.contains("\"Dracula\"") == true)
        #expect(home.snapshot() == afterRewrite)
    }

    @Test func statusesFlagAnAgentRewriteAndRepairFixesIt() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        try AgentSetups.prepare(.gemini, in: home)
        let manager = home.manager()
        _ = try await manager.install(.gemini)

        // The agent rewrote the file without our entries (the user's hook survived).
        try home.write(".gemini/settings.json", Fixtures.geminiSettings)
        var status = try #require(await manager.statuses().first { $0.agent == .gemini })
        #expect(status.needsRepair)
        #expect(!status.installed)

        let repaired = try await manager.repair(.gemini)
        #expect(repaired.plan.operation == .repair)
        #expect(repaired.status.installed)
        #expect(!repaired.status.needsRepair)
        status = try #require(await manager.statuses().first { $0.agent == .gemini })
        #expect(status.installed)
        #expect(!status.needsRepair)

        // One of our five entries vanished: still flagged, and repair re-adds just that one.
        let installed = try #require(home.read(".gemini/settings.json"))
        var editor = try JSONEditor(text: installed, dialect: .jsonc, path: "settings.json")
        let index = try #require(editor.node(at: ["hooks"])?.members?.firstIndex { $0.key == "BeforeAgent" })
        try editor.removeChild(at: index, ofContainerAt: ["hooks"])
        try home.write(".gemini/settings.json", editor.text)
        status = try #require(await manager.statuses().first { $0.agent == .gemini })
        #expect(status.installed)
        #expect(status.needsRepair)
        _ = try await manager.repair(.gemini)
        let commands = commandStrings(home.read(".gemini/settings.json"))
        #expect(commands.filter { $0.contains(KakurenekoID.ownershipMarker) }.count == 5)
        #expect(commands.contains("~/bin/log-turn.sh"))

        // Uninstall still gives back the user's original file.
        _ = try await manager.uninstall(.gemini)
        #expect(home.read(".gemini/settings.json") == Fixtures.geminiSettings)
    }

    @Test func anAgentReformattingItsFileIsNotARepair() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        try AgentSetups.prepare(.cursor, in: home)
        let manager = home.manager()
        _ = try await manager.install(.cursor)

        // Cursor re-serialized the file (sorted keys, other indentation, escaped slashes).
        let installed = try #require(home.read(".cursor/hooks.json"))
        let object = try JSONSerialization.jsonObject(with: Data(installed.utf8))
        let reformatted = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try reformatted.write(to: home.url(".cursor/hooks.json"))
        let status = try #require(await manager.statuses().first { $0.agent == .cursor })
        #expect(status.installed)
        #expect(!status.needsRepair)
        let again = try await manager.install(.cursor)
        #expect(again.plan.isEmpty)

        // Uninstall removes exactly our entries from the reformatted file.
        _ = try await manager.uninstall(.cursor)
        let remaining = try #require(home.read(".cursor/hooks.json"))
        #expect(!remaining.contains("kakureneko-hook"))
        let commands = commandStrings(remaining)
        #expect(Set(commands) == ["./hooks/format.sh", "say done"])
        _ = try JSONSyntax.parse(remaining, dialect: .strict)
    }

    @Test func aWriteThatDoesNotReparseRollsBackEveryFileOfTheOperation() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        try AgentSetups.prepare(.codex, in: home)
        let corrupting = CorruptingFileSystem(corruptSuffix: "/.codex/hooks.json")
        let manager = home.manager(fileSystem: corrupting)

        await #expect(throws: InstallError.self) { try await manager.install(.codex) }
        #expect(corrupting.corruptedWrites == 1)
        // config.toml was written and verified first; it is restored too.
        #expect(home.read(".codex/config.toml") == Fixtures.codexConfig)
        #expect(home.read(".codex/hooks.json") == Fixtures.codexHooks)
        #expect(try home.manifest().entries.isEmpty)
        let status = try #require(await manager.statuses().first { $0.agent == .codex })
        #expect(!status.installed)
        #expect(!status.needsRepair)

        // The next (clean) attempt succeeds.
        let result = try await home.manager().install(.codex)
        #expect(result.status.installed)
    }

    @Test func aCorruptedNewFileIsRemovedAgain() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        try home.mkdir(".codebuddy")
        let manager = home.manager(fileSystem: CorruptingFileSystem(corruptSuffix: "/.codebuddy/settings.json"))
        do {
            _ = try await manager.install(.codebuddy)
            Issue.record("the corrupted write was accepted")
        } catch let error as InstallError {
            guard case .verificationFailed = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        }
        #expect(!home.exists(".codebuddy/settings.json"))
    }

    @Test func symlinkedConfigEditsTheTargetAndKeepsTheLink() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        let target = try home.write("dotfiles/gemini/settings.json", Fixtures.geminiSettings)
        try home.mkdir(".gemini")
        let link = home.url(".gemini/settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let manager = home.manager()

        let result = try await manager.install(.gemini)
        #expect(result.status.installed)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path(percentEncoded: false)) == target.path(percentEncoded: false))
        #expect(home.read("dotfiles/gemini/settings.json")?.contains(KakurenekoID.ownershipMarker) == true)
        #expect(result.backups.count == 1)
        #expect(try Data(contentsOf: URL(filePath: result.backups[0])) == Data(Fixtures.geminiSettings.utf8))

        _ = try await manager.uninstall(.gemini)
        #expect(home.read("dotfiles/gemini/settings.json") == Fixtures.geminiSettings)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path(percentEncoded: false)) == target.path(percentEncoded: false))
    }

    @Test func fileModesAreKeptAndBackupsArePrivate() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        try AgentSetups.prepare(.gemini, in: home)
        chmod(home.url(".gemini/settings.json").path(percentEncoded: false), 0o600)
        let manager = home.manager()

        let result = try await manager.install(.gemini)
        #expect(home.mode(".gemini/settings.json") == 0o600)
        let backup = try #require(result.backups.first)
        #expect(backup == home.paths.backupDirectory(for: .gemini).appending(path: "settings.json.20261012T220000.000Z").path(percentEncoded: false))
        var st = stat()
        #expect(stat(backup, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o600)
        #expect(try Data(contentsOf: URL(filePath: backup)) == Data(Fixtures.geminiSettings.utf8))

        home.clock.advance(by: .seconds(60))
        let removed = try await manager.uninstall(.gemini)
        #expect(home.mode(".gemini/settings.json") == 0o600)
        // The pre-uninstall state is backed up too (under a new timestamp); the original backup is kept.
        #expect(removed.backups == [home.paths.backupDirectory(for: .gemini).appending(path: "settings.json.20261012T220100.000Z").path(percentEncoded: false)])
        #expect(FileManager.default.fileExists(atPath: backup))

        // Re-installing the same original does not pile up identical backups.
        let again = try await manager.install(.gemini)
        #expect(again.backups.isEmpty)
    }

    @Test func manifestRecordsEveryFileAndUnreadableManifestsAreKeptAside() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        try AgentSetups.prepare(.codex, in: home)
        try AgentSetups.prepare(.aider, in: home)
        try home.write(".kakureneko/install-manifest.json", "{ this is not json")
        let manager = home.manager()

        // Reading (statuses, previews) never touches the broken manifest.
        let before = home.snapshot()
        _ = await manager.statuses()
        _ = try await manager.preview(.codex)
        #expect(home.snapshot() == before)

        _ = try await manager.install(.codex)
        _ = try await manager.install(.aider)
        let manifest = try home.manifest()
        #expect(manifest.version == InstallManifest.currentVersion)
        let codex = manifest.entries(for: .codex)
        #expect(codex.map(\.file) == [".codex/config.toml", ".codex/hooks.json"].map { home.url($0).path(percentEncoded: false) })
        #expect(codex.allSatisfy { $0.kind == .spliced && $0.sha256Before != nil })
        let config = try #require(codex.first)
        #expect(config.sha256Before == Digest.sha256Hex(Fixtures.codexConfig))
        #expect(config.chainedOriginal == "notify = [\"terminal-notifier\", \"-title\", \"Codex\"]   # desktop ping")
        let aider = try #require(manifest.entries(for: .aider).first)
        #expect(AiderConfigSplicer.Originals.decode(aider.chainedOriginal)?.command == "notifications-command: \"say 'Aider is ready'\"")
        #expect(home.mode(".kakureneko/install-manifest.json") == 0o600)

        let aside = try FileManager.default.contentsOfDirectory(atPath: home.paths.backupsDirectory.path(percentEncoded: false))
            .filter { $0.hasPrefix("install-manifest.json.unreadable-") }
        #expect(aside.count == 1)
        let kept = home.paths.backupsDirectory.appending(path: try #require(aside.first))
        #expect(try String(contentsOf: kept, encoding: .utf8) == "{ this is not json")

        // Uninstall drops only that agent's entries.
        _ = try await manager.uninstall(.codex)
        #expect(try home.manifest().entries.map(\.agent) == [.aider])
    }

    @Test func manifestLossFallsBackToSurgicalUninstall() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        try AgentSetups.prepare(.codex, in: home)
        let manager = home.manager()
        _ = try await manager.install(.codex)
        try FileManager.default.removeItem(at: home.paths.installManifestFile)

        let status = try #require(await manager.statuses().first { $0.agent == .codex })
        #expect(status.installed)
        _ = try await manager.uninstall(.codex)
        // Without the manifest the notify chain is rebuilt from our own argv (no trailing comment, normalized quoting).
        let config = try #require(home.read(".codex/config.toml"))
        #expect(config.contains("notify = [\"terminal-notifier\", \"-title\", \"Codex\"]\n"))
        #expect(!config.contains(KakurenekoID.ownershipMarker))
        #expect(home.read(".codex/hooks.json") == Fixtures.codexHooks)
    }

    @Test func concurrentOperationsAreSerialized() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        let agents: [AgentID] = [.gemini, .cursor, .codex, .aider, .qwen, .windsurf, .opencode, .copilot]
        for agent in agents { try AgentSetups.prepare(agent, in: home) }
        let manager = home.manager()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for agent in agents {
                group.addTask {
                    let result = try await manager.install(agent)
                    #expect(result.status.installed)
                }
                group.addTask { _ = await manager.statuses() }
            }
            try await group.waitForAll()
        }
        let manifest = try home.manifest()
        #expect(Set(manifest.entries.map(\.agent)) == Set(agents))
        let statuses = await manager.statuses().filter { agents.contains($0.agent) }
        #expect(statuses.allSatisfy { $0.installed && !$0.needsRepair })
    }

    @Test func codexHomeIsHonoured() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        try home.write("work/codex-home/config.toml", Fixtures.codexConfigNoNotify)
        let paths = home.paths(environment: ["CODEX_HOME": home.url("work/codex-home").path(percentEncoded: false)])
        let manager = home.manager(paths: paths)

        let status = try #require(await manager.statuses().first { $0.agent == .codex })
        #expect(status.configDirExists)
        #expect(status.configFiles.contains("~/work/codex-home/config.toml"))
        _ = try await manager.install(.codex)
        #expect(home.read("work/codex-home/config.toml")?.contains("notify = [\"\(home.hookPath)\", \"codex\", \"notify\"]") == true)
        #expect(home.exists("work/codex-home/hooks.json"))
        #expect(!home.exists(".codex"))
        _ = try await manager.uninstall(.codex)
        #expect(home.read("work/codex-home/config.toml") == Fixtures.codexConfigNoNotify)
        #expect(!home.exists("work/codex-home/hooks.json"))
    }

    @Test func codexTrustStepIsDetectedReadOnlyAndHooksStateIsNeverTouched() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        try AgentSetups.prepare(.codex, in: home)
        let manager = home.manager()
        let result = try await manager.install(.codex)
        #expect(result.status.needsTrustStep)
        #expect(result.plan.followUpNote == CodexInstaller.trustNote)
        let hooksBefore = try #require(home.read(".codex/hooks.json"))

        // The user approves our hooks in /hooks: Codex appends [hooks.state."…"] tables to config.toml.
        let ours = CodexTrust.ourHandlers(inHooksJSON: hooksBefore)
        #expect(ours.count == 6)
        var approvals = ""
        for handler in ours {
            approvals += "\n[hooks.state.\"\(home.paths.codexHome.path(percentEncoded: false))hooks.json:\(handler.event):\(handler.group):\(handler.handler)\"]\ntrusted_hash = \"sha256:\(handler.event.count)\"\n"
        }
        let approved = try #require(home.read(".codex/config.toml")) + approvals
        try home.write(".codex/config.toml", approved)
        var status = try #require(await manager.statuses().first { $0.agent == .codex })
        #expect(status.installed)
        #expect(!status.needsTrustStep)
        #expect(!status.needsRepair)
        #expect(home.read(".codex/config.toml") == approved)

        // Re-install and repair leave the approvals alone; uninstall restores notify and keeps them too.
        _ = try await manager.repair(.codex)
        #expect(home.read(".codex/config.toml") == approved)
        _ = try await manager.uninstall(.codex)
        #expect(home.read(".codex/config.toml") == Fixtures.codexConfig + approvals)
        status = try #require(await manager.statuses().first { $0.agent == .codex })
        #expect(!status.installed)
        #expect(!status.needsTrustStep)
    }

    @Test func droidWritesTheFileItActuallyReadsAndCleansTheOther() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        // hooks.json exists → Droid ignores settings.json "hooks", where an old entry of ours lingers.
        let stale = Fixtures.droidSettings.replacingOccurrences(
            of: "\"PostToolUse\": [",
            with: "\"Stop\": [ { \"hooks\": [ { \"type\": \"command\", \"command\": \"/Users/old/.kakureneko/bin/kakureneko-hook droid Stop 2>/dev/null; exit 0\", \"timeout\": 5 } ] } ],\n    \"PostToolUse\": [")
        try home.write(".factory/settings.json", stale)
        try home.write(".factory/hooks.json", "{\n  \"PreToolUse\": [ { \"matcher\": \"Bash\", \"hooks\": [ { \"type\": \"command\", \"command\": \"~/guard.sh\" } ] } ]\n}\n")
        let manager = home.manager()

        let preview = try await manager.preview(.droid)
        #expect(Set(preview.changes.map(\.path)) == Set([".factory/hooks.json", ".factory/settings.json"].map { home.url($0).path(percentEncoded: false) }))
        let result = try await manager.install(.droid)
        #expect(result.status.installed)
        let hooks = commandStrings(home.read(".factory/hooks.json"))
        #expect(hooks.filter { $0.contains(KakurenekoID.ownershipMarker) }.count == 5)
        #expect(home.read(".factory/settings.json") == Fixtures.droidSettings)
        #expect(try home.manifest().entries(for: .droid).map(\.file) == [home.url(".factory/hooks.json").path(percentEncoded: false)])

        _ = try await manager.uninstall(.droid)
        #expect(home.read(".factory/hooks.json") == "{\n  \"PreToolUse\": [ { \"matcher\": \"Bash\", \"hooks\": [ { \"type\": \"command\", \"command\": \"~/guard.sh\" } ] } ]\n}\n")
        #expect(home.read(".factory/settings.json") == Fixtures.droidSettings)
    }

    @Test func copilotRefusesAFileItDidNotWrite() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        try AgentSetups.prepare(.copilot, in: home)
        let foreign = "{ \"version\": 1, \"hooks\": { \"agentStop\": [ { \"type\": \"command\", \"bash\": \"say hi\" } ] } }\n"
        try home.write(".copilot/hooks/kakureneko.json", foreign)
        let manager = home.manager()
        await #expect(throws: InstallError.self) { try await manager.install(.copilot) }
        #expect(home.read(".copilot/hooks/kakureneko.json") == foreign)
        // Uninstall never deletes it either (it holds nothing of ours).
        let removed = try await manager.uninstall(.copilot)
        #expect(removed.plan.isEmpty)
        #expect(home.read(".copilot/hooks/kakureneko.json") == foreign)
    }

    @Test func ownedFilesMatchTheirSnippets() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        try AgentSetups.prepare(.copilot, in: home)
        try AgentSetups.prepare(.opencode, in: home)
        let manager = home.manager()
        _ = try await manager.install(.copilot)
        _ = try await manager.install(.opencode)

        let copilot = try #require(home.read(".copilot/hooks/kakureneko.json"))
        let editor = try JSONEditor(text: copilot, dialect: .strict, path: "kakureneko.json")
        #expect(editor.root.members?.map(\.key) == ["version", "hooks"])
        #expect(editor.node(at: ["version"])?.value == .number(1))
        #expect(editor.node(at: ["hooks"])?.members?.map(\.key) == CopilotInstaller.events)
        #expect(!copilot.contains("preToolUse") && !copilot.contains("permissionRequest"))
        let notification = try #require(editor.node(at: ["hooks", "notification"])?.elements?.first)
        #expect(notification.member("matcher")?.value.stringValue == "permission_prompt|elicitation_dialog|agent_idle|agent_completed")
        #expect(notification.member("bash")?.value.stringValue == "\(home.hookPath) copilot notification 2>/dev/null; exit 0")
        #expect(notification.member("timeoutSec")?.value.value == .number(5))

        let plugin = try #require(home.read(".config/opencode/plugins/kakureneko.js"))
        #expect(plugin.contains("const HOOK = \"\(home.hookPath)\""))
        #expect(plugin.contains("spawn(HOOK, [\"opencode\", type]"))
        #expect(plugin.contains("id: \"kakureneko\""))
        #expect(plugin.contains("server: async (input)") && plugin.contains("setup: async (ctx)"))

        for agent in [AgentID.copilot, .opencode] {
            let entries = try home.manifest().entries(for: agent)
            #expect(entries.count == 1)
            #expect(entries.first?.kind == .ownedFile)
            #expect(entries.first?.sha256Before == nil)
        }
        _ = try await manager.uninstall(.copilot)
        _ = try await manager.uninstall(.opencode)
        #expect(!home.exists(".copilot/hooks/kakureneko.json"))
        #expect(!home.exists(".config/opencode/plugins/kakureneko.js"))
        #expect(home.exists(".copilot/config.json"))
    }

    @Test func notesExplainSwitchedOffHooks() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.write(".qwen/settings.json", "{\n  \"disableAllHooks\": true\n}\n")
        try home.write(".claude/settings.json", "{\n  // managed\n  \"allowManagedHooksOnly\": true\n}\n")
        try home.write(".gemini/settings.json", "{ \"hooksConfig\": { \"enabled\": false } }\n")
        try home.write(".copilot/settings.json", "{ \"disableAllHooks\": false }\n")
        try home.write(".codex/config.toml", "[features]\nhooks = false\n")
        let statuses = await home.manager().statuses()
        func notes(_ agent: AgentID) -> [String] { statuses.first { $0.agent == agent }?.notes ?? [] }
        #expect(notes(.qwen).contains { $0.contains("~/.qwen/settings.json sets disableAllHooks to true") })
        #expect(notes(.claude).contains { $0.contains("allowManagedHooksOnly") })
        #expect(notes(.gemini).contains { $0.contains("hooksConfig.enabled to false") })
        #expect(!notes(.copilot).contains { $0.contains("disableAllHooks") })
        #expect(notes(.codex).contains { $0.contains("[features] hooks = false") })
        #expect(notes(.codex).contains(CodexInstaller.trustNote))
    }

    @Test func uninstallAfterTheAgentWasRemovedCleansTheManifest() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        try AgentSetups.prepare(.windsurf, in: home)
        let manager = home.manager()
        _ = try await manager.install(.windsurf)
        try FileManager.default.removeItem(at: home.url(".codeium"))

        let status = try #require(await manager.statuses().first { $0.agent == .windsurf })
        #expect(!status.configDirExists)
        #expect(!status.needsRepair)
        #expect(!status.installed)
        #expect(status.notes.contains { $0.contains("configuration was removed") })
        await #expect(throws: SideEffectError.self) { try await manager.repair(.windsurf) }
        let removed = try await manager.uninstall(.windsurf)
        #expect(removed.plan.isEmpty)
        #expect(try home.manifest().entries.isEmpty)
        #expect(!home.exists(".codeium"))
    }

    @Test func resultsCarryMessagesAndTheFollowUpNote() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        try AgentSetups.prepare(.cursor, in: home)
        let manager = home.manager()
        let installed = try await manager.install(.cursor)
        #expect(installed.messages == ["Updated ~/.cursor/hooks.json"])
        let again = try await manager.install(.cursor)
        #expect(again.messages == ["Already up to date."])
        let removed = try await manager.uninstall(.cursor)
        #expect(removed.messages == ["Updated ~/.cursor/hooks.json"])
        let nothing = try await manager.uninstall(.cursor)
        #expect(nothing.messages == ["Nothing of Kakureneko's was installed."])
        let status = try #require(installed.status.configFiles.first)
        #expect(status == "~/.cursor/hooks.json")
    }
}

@Suite("Protected locations", .timeLimit(.minutes(1)))
struct ProtectedLocationTests {
    /// An installer that (wrongly) targets `relative` with a Gemini-style splice.
    struct RogueInstaller: IntegrationInstaller {
        let agent = AgentID.gemini
        let relative: String

        func configDirectories(_ context: InstallContext) -> [URL] { [context.paths.claudeConfigDirectory] }

        func managedFiles(_ context: InstallContext) -> [ManagedFile] {
            let url = context.paths.homeRelative(relative)
            let entry = HookEntries.claudeStyleGroup(command: context.hook.shell(.gemini, "Stop"), timeout: 5)
            return [ManagedFile(url: url, kind: .spliced, splicer: JSONHookSplicer(
                path: context.path(url), dialect: .jsonc, containerKeys: ["hooks"],
                events: [HookEventEntries(event: "Stop", entries: [entry])]))]
        }
    }

    @Test(arguments: [".claude/settings.local.json", ".claude/sessions/4242.json", ".claude/jobs/abc/state.json",
                      ".claude/daemon/hooks.json", ".claude/.fleetview-heartbeat", ".claude/api.key"])
    func everyPlannedChangeOfAProtectedLocationIsRefused(_ relative: String) async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        try home.mkdir(".claude")
        let manager = home.manager(installers: [RogueInstaller(relative: relative)])
        let before = home.snapshot()
        await #expect(throws: InstallError.self) { try await manager.install(.gemini) }
        await #expect(throws: InstallError.self) { try await manager.preview(.gemini) }
        #expect(home.snapshot() == before)
    }

    @Test func symlinksIntoProtectedLocationsAreRefusedToo() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.mkdir(".claude/sessions")
        try home.mkdir(".gemini")
        let link = home.url(".gemini/settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.url(".claude/sessions/1.json"))
        #expect(ProtectedLocations.violation(link, paths: home.paths) != nil)
        #expect(ProtectedLocations.violation(home.url(".gemini/other.json"), paths: home.paths) == nil)
        #expect(ProtectedLocations.violation(home.url(".claude/settings.json"), paths: home.paths) == nil)
        #expect(ProtectedLocations.violation(home.paths.claudePluginDirectory, paths: home.paths) == nil)
        #expect(ProtectedLocations.violation(home.url(".claude/sessions"), paths: home.paths) != nil)
        #expect(ProtectedLocations.violation(home.url(".claudex/sessions/1.json"), paths: home.paths) == nil)
    }

    @Test func noV1InstallerTouchesAProtectedLocation() throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let context = makeContext(home)
        for installer in IntegrationManager.defaultInstallers {
            for file in installer.managedFiles(context) {
                #expect(ProtectedLocations.violation(file.url, paths: home.paths) == nil, "\(installer.agent) → \(file.path)")
            }
            for directory in installer.ownedDirectories(context) {
                #expect(ProtectedLocations.violation(directory, paths: home.paths) == nil)
            }
        }
    }
}

@Suite("Symlink edge cases", .timeLimit(.minutes(1)))
struct SymlinkEdgeCaseTests {
    private func linkTarget(_ url: URL) throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: url.path(percentEncoded: false))
    }

    @Test func aDanglingLinkGetsItsTargetCreatedAndRemovedWhileTheLinkStays() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        try home.mkdir(".cursor")
        try home.mkdir("dotfiles")
        let link = home.url(".cursor/hooks.json")
        // A relative link into a dotfiles repo whose file does not exist yet.
        try FileManager.default.createSymbolicLink(atPath: link.path(percentEncoded: false), withDestinationPath: "../dotfiles/cursor-hooks.json")
        let manager = home.manager()

        let result = try await manager.install(.cursor)
        #expect(result.plan.changes.map(\.kind) == [.create])
        #expect(try linkTarget(link) == "../dotfiles/cursor-hooks.json")
        #expect(home.read("dotfiles/cursor-hooks.json")?.contains(KakurenekoID.ownershipMarker) == true)
        #expect(try #require(await manager.statuses().first { $0.agent == .cursor }).installed)

        _ = try await manager.uninstall(.cursor)
        #expect(try linkTarget(link) == "../dotfiles/cursor-hooks.json")
        #expect(!home.exists("dotfiles/cursor-hooks.json"))
    }

    @Test func aRollbackOfACreatedFileKeepsTheLink() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        try home.mkdir(".codebuddy")
        try home.mkdir("dotfiles")
        let link = home.url(".codebuddy/settings.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.url("dotfiles/codebuddy.json"))
        let manager = home.manager(fileSystem: CorruptingFileSystem(corruptSuffix: "/.codebuddy/settings.json"))
        await #expect(throws: InstallError.self) { try await manager.install(.codebuddy) }
        #expect(try linkTarget(link) == home.url("dotfiles/codebuddy.json").path(percentEncoded: false))
        #expect(!home.exists("dotfiles/codebuddy.json"))
    }

    @Test func aSymlinkedPluginFolderIsUnlinkedNotFollowed() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        try home.mkdir(".claude")
        home.runner.setHandler(FakeClaudeCLI().handler)
        try home.installFakeClaudeCLI()
        try home.write("elsewhere/keep.txt", "user data\n")
        let manager = home.manager()
        _ = try await manager.install(.claude)
        // Someone replaced the plugin folder with a link to their own folder.
        try FileManager.default.removeItem(at: home.paths.claudePluginDirectory)
        try FileManager.default.createSymbolicLink(at: home.paths.claudePluginDirectory, withDestinationURL: home.url("elsewhere"))

        _ = try await manager.uninstall(.claude)
        #expect(!home.exists(".kakureneko/claude-plugin"))
        #expect(home.read("elsewhere/keep.txt") == "user data\n")
    }
}
