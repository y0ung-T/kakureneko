@testable import KakurenekoInstall
import Darwin
import KakurenekoKit
import Foundation
import Testing

/// Regression tests for the installers review (each failed before its fix). Temp homes and fakes only; the one real
/// execution runs a script the test wrote itself whose "interpreter" is `/usr/bin/true`.
@Suite("Installer fixes", .timeLimit(.minutes(1)))
struct InstallerFixTests {
    // MARK: Agent-CLI PATH (GUI app: launchd's bare PATH)

    /// An npm/bun-style `claude` (`#!/usr/bin/env node`) at `~/.npm-global/bin/claude`: every plugin command carries a
    /// PATH that starts with the CLI's own directory and contains the Homebrew directories (node lives there).
    @Test func claudePluginCommandsCarryASearchPathForNodeShims() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        try home.write(".claude/settings.json", "{}\n")
        let shim = try home.write(".npm-global/bin/claude", "#!/usr/bin/env node\n")
        chmod(shim.path(percentEncoded: false), 0o755)
        home.runner.setHandler { _ in SubprocessResult(exitCode: 0, stdout: Data("[]".utf8)) }
        _ = try? await home.manager().install(.claude)
        let requests = home.runner.requests.filter { $0.executable == shim.path(percentEncoded: false) }
        #expect(!requests.isEmpty)
        for request in requests {
            let path = try #require(request.extraEnvironment["PATH"], "\(request.displayString)")
            let entries = path.split(separator: ":").map(String.init)
            #expect(entries.first == home.url(".npm-global/bin").path(percentEncoded: false).trimmingTrailingSlashForCLI)
            #expect(entries.contains("/opt/homebrew/bin") && entries.contains("/usr/local/bin"))
            #expect(entries.contains("/usr/bin"))
        }
    }

    /// With the login-shell probe on, the user's shell PATH (nvm, asdf …) is part of the search path.
    @Test func theLoginShellPATHIsPartOfTheSearchPath() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        try home.write(".claude/settings.json", "{}\n")
        let cli = try home.installFakeClaudeCLI()
        home.runner.setHandler { request in
            if request.executable == LoginShellProbe.shell, request.arguments.first == "-ilc" {
                let out = "motd\n" + LoginShellProbe.marker + "/Users/me/.nvm/versions/node/v22/bin:/usr/bin\0\0\0\0\0"
                return SubprocessResult(exitCode: 0, stdout: Data(out.utf8))
            }
            return SubprocessResult(exitCode: 0, stdout: Data("[]".utf8))
        }
        let manager = IntegrationManager(
            paths: home.paths, subprocess: home.runner, dryRun: .off(), ledger: home.ledger, clock: home.clock,
            logger: KakurenekoLogger(.install), fileSystem: LiveInstallFileSystem(),
            claudeLocator: ClaudeCLILocator(systemCandidates: [], useLoginShell: false),
            loginShell: LoginShellProbe(enabled: true))
        _ = try? await manager.install(.claude)
        let request = try #require(home.runner.requests.first { $0.executable == cli })
        #expect(request.extraEnvironment["PATH"]?.contains("/Users/me/.nvm/versions/node/v22/bin") == true)
        // One shell run per manager lifetime.
        #expect(home.runner.requests.filter { $0.executable == LoginShellProbe.shell }.count == 1)
    }

    /// The mechanism, for real: a `#!/usr/bin/env <interpreter>` shim whose interpreter sits next to it (the npm/nvm
    /// layout) exits 127 with launchd's PATH and runs with the composed one. Both are the test's own files.
    @Test func anEnvShimRunsWithTheComposedPATHButNotWithLaunchdsPATH() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let bin = home.url("nvm/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: bin.appending(path: "kakurenekofakenode").path(percentEncoded: false),
                                                   withDestinationPath: "/usr/bin/true")
        let shim = bin.appending(path: "claude")
        try Data("#!/usr/bin/env kakurenekofakenode\n".utf8).write(to: shim)
        chmod(shim.path(percentEncoded: false), 0o755)
        let runner = FoundationSubprocessRunner()
        func run(_ path: String) async throws -> Int32 {
            try await runner.run(SubprocessRequest(executable: shim.path(percentEncoded: false), arguments: ["--version"],
                                                   environment: ["PATH": path, "HOME": home.paths.home.path(percentEncoded: false)],
                                                   timeout: .seconds(10), effect: .readOnly)).exitCode
        }
        #expect(try await run(AgentCLIEnvironment.systemPATH) == 127)
        let composed = AgentCLIEnvironment.searchPath(executable: shim.path(percentEncoded: false), home: home.paths.home,
                                                      loginShellPATH: nil, inherited: AgentCLIEnvironment.systemPATH)
        #expect(try await run(composed) == 0)
    }

    // MARK: Agent-directory variables only the login shell knows

    @Test func aShellOnlyCodexHomeIsReportedOnTheCodexStatus() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        try home.mkdir(".codex")
        home.runner.setHandler { request in
            guard request.executable == LoginShellProbe.shell else { return SubprocessResult(exitCode: 1) }
            let out = LoginShellProbe.marker + "/usr/bin\0\0/Users/me/work/codex\0\0\0"
            return SubprocessResult(exitCode: 0, stdout: Data(out.utf8))
        }
        let manager = IntegrationManager(
            paths: home.paths(environment: [:]), subprocess: home.runner, dryRun: .off(), ledger: home.ledger,
            clock: home.clock, logger: KakurenekoLogger(.install), fileSystem: LiveInstallFileSystem(),
            claudeLocator: ClaudeCLILocator(systemCandidates: [], useLoginShell: false),
            loginShell: LoginShellProbe(enabled: true))
        let statuses = await manager.statuses()
        let codex = try #require(statuses.first { $0.agent == .codex })
        #expect(codex.notes.contains { $0.contains("CODEX_HOME=/Users/me/work/codex") && $0.contains("launchctl setenv") })
        #expect(!(statuses.first { $0.agent == .gemini }?.notes.contains { $0.contains("launchctl setenv") } ?? true))
    }

    // MARK: Aider

    /// `notifications: false` + a command: Aider never ran it. Install must not start running it on every bell; the
    /// original lines come back on uninstall.
    @Test func aDormantAiderCommandIsNotChained() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        let original = "notifications: false\nnotifications-command: afplay /System/Library/Sounds/Sosumi.aiff\n"
        try home.write(".aider.conf.yml", original)
        let manager = home.manager()
        _ = try await manager.install(.aider)
        let installed = try #require(home.read(".aider.conf.yml"))
        #expect(!installed.contains("afplay"))
        #expect(!installed.contains("--chain"))
        #expect(installed.contains("notifications: true"))
        #expect(installed.contains(home.hookPath))
        // Changed since install (text-only removal): the dormant original lines are restored, not lost.
        try home.write(".aider.conf.yml", "model: sonnet\n" + installed)
        _ = try await manager.uninstall(.aider)
        #expect(home.read(".aider.conf.yml") == "model: sonnet\n" + original)
    }

    /// The manifest is lost, Kakureneko is set up again (the "ours already" path): uninstall used to delete the user's
    /// chained command and `notifications: true`.
    @Test func aiderUninstallAfterManifestLossKeepsTheUsersCommand() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        let original = "model: sonnet\nnotifications: true\nnotifications-command: \"say 'Aider is ready'\"\n"
        try home.write(".aider.conf.yml", original)
        _ = try await home.manager().install(.aider)
        try FileManager.default.removeItem(at: home.paths.installManifestFile)
        let fresh = home.manager()
        _ = try await fresh.install(.aider)
        _ = try await fresh.uninstall(.aider)
        let after = try #require(home.read(".aider.conf.yml"))
        #expect(after.contains("say 'Aider is ready'"))
        #expect(after.contains("notifications: true"))
        #expect(!after.contains(KakurenekoID.ownershipMarker))
    }

    /// The UI-reachable variant: manifest lost and notifications switched off → Repair → Uninstall.
    @Test func aiderRepairAfterManifestLossThenUninstallKeepsTheUsersCommand() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        try home.write(".aider.conf.yml", "model: sonnet\nnotifications: true\nnotifications-command: \"say 'Aider is ready'\"\n")
        _ = try await home.manager().install(.aider)
        try FileManager.default.removeItem(at: home.paths.installManifestFile)
        let installed = try #require(home.read(".aider.conf.yml"))
        try home.write(".aider.conf.yml", installed.replacingOccurrences(of: "notifications: true", with: "notifications: false"))
        let manager = home.manager()
        #expect(try #require(await manager.statuses().first { $0.agent == .aider }).needsRepair)
        _ = try await manager.repair(.aider)
        #expect(try home.manifest().entries(for: .aider).allSatisfy { $0.chainedOriginal != "{}" })
        _ = try await manager.uninstall(.aider)
        #expect(home.read(".aider.conf.yml")?.contains("say 'Aider is ready'") == true)
    }

    /// An entry of ours pointing at an old hook path (home moved, KAKURENEKO_HOME changed): needs repair, and install
    /// rewrites it with the current hook — keeping what it chains.
    @Test func aStaleAiderHookPathIsRepaired() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        let stale = "notifications: true\nnotifications-command: \"/Volumes/Old/me/.kakureneko/bin/kakureneko-hook aider waiting --chain -- /bin/sh -c 'say hi' 2>/dev/null; exit 0\"\n"
        try home.write(".aider.conf.yml", stale)
        let manager = home.manager()
        let status = try #require(await manager.statuses().first { $0.agent == .aider })
        #expect(status.installed && status.needsRepair)
        _ = try await manager.install(.aider)
        let after = try #require(home.read(".aider.conf.yml"))
        #expect(after.contains(home.hookPath))
        #expect(!after.contains("/Volumes/Old"))
        #expect(after.contains("--chain -- /bin/sh -c 'say hi'"))
        #expect(try #require(await manager.statuses().first { $0.agent == .aider }).needsRepair == false)
    }

    // MARK: JSONC comments

    @Test func uninstallKeepsCommentsOfTheContainerItEmpties() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        let original = "{\n  // \"theme\": \"Dracula\",\n  /* \"mcpServers\": { \"gh\": { \"command\": \"npx\" } } */\n}\n"
        try home.write(".gemini/settings.json", original)
        let manager = home.manager()
        _ = try await manager.install(.gemini)
        var text = try #require(home.read(".gemini/settings.json"))
        text = text.replacingOccurrences(of: "Dracula", with: "Nord") // changed since install: text-only removal
        try home.write(".gemini/settings.json", text)
        _ = try await manager.uninstall(.gemini)
        let after = try #require(home.read(".gemini/settings.json"))
        #expect(after == "{\n  // \"theme\": \"Nord\",\n  /* \"mcpServers\": { \"gh\": { \"command\": \"npx\" } } */\n}\n")
    }

    @Test func installKeepsACommentInsideAnEmptySingleLineContainer() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        try home.write(".gemini/settings.json", "{\n  \"theme\": \"GitHub\",\n  \"hooks\": { /* TODO: add my lint hook here */ }\n}\n")
        _ = try await home.manager().install(.gemini)
        let after = try #require(home.read(".gemini/settings.json"))
        #expect(after.contains("/* TODO: add my lint hook here */"))
        #expect(after.contains(home.hookPath))
    }

    @Test func removingTheOnlyChildKeepsCommentsAndOtherwiseLeavesAnEmptyContainer() throws {
        var editor = try JSONEditor(text: "{\n  // keep me\n  \"a\": 1\n}\n", dialect: .jsonc, path: "x")
        try editor.removeChild(at: 0, ofContainerAt: [])
        #expect(editor.text == "{\n  // keep me\n}\n")
        var plain = try JSONEditor(text: "{ \"a\": 1 }\n", dialect: .jsonc, path: "x")
        try plain.removeChild(at: 0, ofContainerAt: [])
        #expect(plain.text == "{}\n")
        var nested = try JSONEditor(text: "{\n  \"hooks\": {\n    \"Stop\": []\n  }\n}\n", dialect: .jsonc, path: "x")
        try nested.removeChild(at: 0, ofContainerAt: ["hooks"])
        #expect(nested.text == "{\n  \"hooks\": {}\n}\n")
    }

    // MARK: opencode version gate

    @Test(arguments: [("opencode 1.10.2", true), ("1.18.29", false), ("v2.0.0", false), ("garbage", false)])
    func opencodeOlderThanTheObjectFormGetsTheLegacyPlugin(_ output: String, _ legacy: Bool) async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try home.deployFakeHelper()
        try home.mkdir(".config/opencode")
        let binary = try home.write(".opencode/bin/opencode", "#!/bin/sh\nexit 0\n")
        chmod(binary.path(percentEncoded: false), 0o755)
        home.runner.setHandler { request in
            request.arguments == ["--version"] ? SubprocessResult(exitCode: 0, stdout: Data((output + "\n").utf8))
                : SubprocessResult(exitCode: 1)
        }
        _ = try await home.manager().install(.opencode)
        let plugin = try #require(home.read(".config/opencode/plugins/kakureneko.js"))
        #expect(plugin.contains("export const KakurenekoPlugin = async (input)") == legacy)
        #expect(plugin.contains("export default {") == !legacy)
        #expect(home.runner.requests.contains { $0.executable == binary.path(percentEncoded: false) && $0.effect == .readOnly })
    }

    @Test func openCodeVersionParsing() {
        #expect(OpenCodeVersion.parse("opencode 1.18.29\n") == OpenCodeVersion(major: 1, minor: 18, patch: 29))
        #expect(OpenCodeVersion.parse("v0.15.3-beta") == OpenCodeVersion(major: 0, minor: 15, patch: 3))
        #expect(OpenCodeVersion.parse("none") == nil)
        #expect(OpenCodeVersion(major: 1, minor: 18, patch: 28) < OpenCodeInstaller.objectFormMinimum)
        #expect(!(OpenCodeVersion(major: 1, minor: 18, patch: 29) < OpenCodeInstaller.objectFormMinimum))
    }
}
