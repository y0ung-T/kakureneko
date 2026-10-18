import Darwin
import KakurenekoKit
import Foundation
import Testing

@Suite("Paths", .timeLimit(.minutes(1)))
struct PathsTests {
    @Test func temporaryHomeIsIsolated() throws {
        let paths = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        #expect(!paths.home.path(percentEncoded: false).hasPrefix(realHome + ".kakureneko"))
        #expect(FileManager.default.fileExists(atPath: paths.home.path(percentEncoded: false)))
        #expect(paths.userName == "tester")
    }

    @Test func kakurenekoLayoutDerivesFromHome() {
        let paths = Paths(home: URL(filePath: "/tmp/h", directoryHint: .isDirectory), userName: "u",
                          userTempDirectory: URL(filePath: "/tmp/t", directoryHint: .isDirectory))
        #expect(paths.kakurenekoDirectory.path(percentEncoded: false) == "/tmp/h/.kakureneko/")
        #expect(paths.hookBinary.path(percentEncoded: false) == "/tmp/h/.kakureneko/bin/kakureneko-hook")
        #expect(paths.inboxDirectory.path(percentEncoded: false) == "/tmp/h/.kakureneko/inbox/")
        #expect(paths.inboxTempDirectory.path(percentEncoded: false) == "/tmp/h/.kakureneko/inbox/.tmp/")
        #expect(paths.inboxBadDirectory.path(percentEncoded: false) == "/tmp/h/.kakureneko/inbox/bad/")
        #expect(paths.heartbeatFile.path(percentEncoded: false) == "/tmp/h/.kakureneko/run/heartbeat")
        #expect(paths.logDirectory.path(percentEncoded: false) == "/tmp/h/.kakureneko/log/")
        #expect(paths.hookLogFile.path(percentEncoded: false) == "/tmp/h/.kakureneko/log/hook.log")
        #expect(paths.backupsDirectory.path(percentEncoded: false) == "/tmp/h/.kakureneko/backups/")
        #expect(paths.backupDirectory(for: .codex).path(percentEncoded: false) == "/tmp/h/.kakureneko/backups/codex/")
        #expect(paths.recordingsDirectory.path(percentEncoded: false) == "/tmp/h/.kakureneko/recordings/")
        #expect(paths.claudePluginDirectory.path(percentEncoded: false) == "/tmp/h/.kakureneko/claude-plugin/")
        #expect(paths.installManifestFile.path(percentEncoded: false) == "/tmp/h/.kakureneko/install-manifest.json")
        #expect(paths.fallbackInboxDirectory.path(percentEncoded: false) == "/tmp/t/com.kakureneko/inbox/")
        #expect(paths.allInboxDirectories.count == 2)
    }

    @Test func applicationSupportLayout() {
        let paths = Paths(home: URL(filePath: "/tmp/h", directoryHint: .isDirectory))
        let base = "/tmp/h/Library/Application Support/Kakureneko/"
        #expect(paths.appSupport.path(percentEncoded: false) == base)
        #expect(paths.pauseJournalFile.path(percentEncoded: false) == base + "paused.json")
        #expect(paths.outboxFile.path(percentEncoded: false) == base + "outbox.json")
        #expect(paths.legacySecretsFile.path(percentEncoded: false) == base + "secrets.json")
        #expect(paths.settingsFile.path(percentEncoded: false) == base + "settings.json")
        #expect(paths.resumeManifestFile.path(percentEncoded: false) == base + "resume.json")
        #expect(paths.notifyStateFile.path(percentEncoded: false) == base + "notify-state.json")
        #expect(paths.installScriptsDirectory.path(percentEncoded: false) == base + "install/")
        #expect(paths.privilegedInstallScript.path(percentEncoded: false) == base + "install/install-privileged.sh")
        #expect(paths.failsafeScriptTemplate.path(percentEncoded: false) == base + "install/kakureneko-failsafe.sh")
    }

    @Test func rootPathsAndIdentifiers() {
        #expect(RootPaths.sudoersDropIn.path(percentEncoded: false) == "/private/etc/sudoers.d/kakureneko")
        #expect(!RootPaths.sudoersDropIn.lastPathComponent.contains(".")) // sudo skips names with a dot
        #expect(RootPaths.launchDaemonPlist.path(percentEncoded: false) == "/Library/LaunchDaemons/com.kakureneko.failsafe.plist")
        #expect(RootPaths.failsafeScript.path(percentEncoded: false) == "/Library/Application Support/Kakureneko/kakureneko-failsafe.sh")
        #expect(KakurenekoID.ownershipMarker == "/.kakureneko/bin/kakureneko-hook")
        #expect(KakurenekoID.inboxDarwinNotification == "com.kakureneko.inbox")
        #expect(KakurenekoID.bundleIdentifier == "com.kakureneko.Kakureneko")
        #expect(KakurenekoID.claudePluginReference == "kakureneko@kakureneko-local")
        let paths = Paths(home: URL(filePath: "/Users/someone", directoryHint: .isDirectory))
        #expect(paths.hookBinary.path(percentEncoded: false).hasSuffix(KakurenekoID.ownershipMarker))
    }

    @Test func agentLocationsHonourEnvironment() {
        let home = URL(filePath: "/tmp/h", directoryHint: .isDirectory)
        let plain = Paths(home: home)
        #expect(plain.claudeConfigDirectory.path(percentEncoded: false) == "/tmp/h/.claude/")
        #expect(plain.claudeSessionsDirectory.path(percentEncoded: false) == "/tmp/h/.claude/sessions/")
        #expect(plain.codexHome.path(percentEncoded: false) == "/tmp/h/.codex/")
        #expect(plain.opencodeConfigDirectory.path(percentEncoded: false) == "/tmp/h/.config/opencode/")
        #expect(plain.aiderConfigFile.path(percentEncoded: false) == "/tmp/h/.aider.conf.yml")
        let custom = Paths(home: home, environment: [
            "CLAUDE_CONFIG_DIR": "/tmp/cc", "CODEX_HOME": "/tmp/cx", "COPILOT_HOME": "/tmp/cp", "XDG_CONFIG_HOME": "/tmp/xdg",
        ])
        #expect(custom.claudeSessionsDirectory.path(percentEncoded: false) == "/tmp/cc/sessions/")
        #expect(custom.codexHome.path(percentEncoded: false) == "/tmp/cx/")
        #expect(custom.copilotHome.path(percentEncoded: false) == "/tmp/cp/")
        #expect(custom.opencodeConfigDirectory.path(percentEncoded: false) == "/tmp/xdg/opencode/")
        // Relative values are ignored.
        let relative = Paths(home: home, environment: ["CODEX_HOME": "relative/dir"])
        #expect(relative.codexHome.path(percentEncoded: false) == "/tmp/h/.codex/")
    }

    @Test func liveHonoursKakurenekoHome() {
        let paths = Paths.live(environment: ["KAKURENEKO_HOME": "/tmp/fake-home"])
        #expect(paths.home.path(percentEncoded: false) == "/tmp/fake-home/")
        #expect(paths.inboxDirectory.path(percentEncoded: false) == "/tmp/fake-home/.kakureneko/inbox/")
        let real = Paths.live(environment: [:])
        #expect(real.home == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL)
    }

    @Test func displayPathUsesTilde() {
        let paths = Paths(home: URL(filePath: "/Users/me", directoryHint: .isDirectory))
        #expect(paths.displayPath(paths.codexHome.appending(path: "config.toml")) == "~/.codex/config.toml")
        #expect(paths.displayPath(URL(filePath: "/etc/hosts")) == "/etc/hosts")
    }

    @Test func directoryLayoutCreatesPrivateDirectories() throws {
        let paths = try Paths.temporary()
        defer { try? FileManager.default.removeItem(at: paths.home.deletingLastPathComponent()) }
        try DirectoryLayout.ensureUserDirectories(paths)
        for dir in [paths.inboxTempDirectory, paths.inboxBadDirectory, paths.runDirectory, paths.fallbackInboxTempDirectory, paths.installScriptsDirectory] {
            var st = stat()
            #expect(stat(dir.path(percentEncoded: false), &st) == 0)
            #expect(st.st_mode & 0o777 == 0o700)
        }
        // Idempotent.
        try DirectoryLayout.ensureUserDirectories(paths)
    }
}
