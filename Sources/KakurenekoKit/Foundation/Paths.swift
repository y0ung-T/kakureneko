import Darwin
import Foundation

/// Every filesystem location Kakureneko reads or writes, derived from an injectable home directory.
///
/// * Production: `Paths.live()` (honours `KAKURENEKO_HOME`).
/// * Tests: `try Paths.temporary()` — a fresh temp home; nothing ever touches the real `~`.
///
/// Rule (binding): no module hard-codes `~`, `NSHomeDirectory()` or `/Users/...`. Everything goes
/// through a `Paths` value passed in at construction time.
public struct Paths: Sendable, Equatable {
    /// The (possibly fake) home directory. Agent config dirs, `~/.kakureneko` and app support derive from it.
    public let home: URL
    /// Short user name (`NSUserName()` in production). Used in the sudoers line.
    public let userName: String
    /// `~/Library/Application Support/Kakureneko`.
    public let appSupport: URL
    /// Per-user temp dir (`confstr(_CS_DARWIN_USER_TEMP_DIR)`), base of the sandbox fallback inbox.
    public let userTempDirectory: URL
    /// Environment used to resolve `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `COPILOT_HOME`, `XDG_CONFIG_HOME`.
    /// When the home is overridden, `live()` strips those four so agent dirs derive from the fake home.
    public let environment: [String: String]
    /// True when `home` is not the real user's home (`KAKURENEKO_HOME`, a test `HOME`, `temporary()`).
    /// Then agent CLIs spawned by Kakureneko get their config locations pinned inside the fake home
    /// (`agentSubprocessEnvironment`), and the privileged install refuses to run for real.
    public let isHomeOverridden: Bool

    /// Agent-directory variables that `live()` ignores when the home is overridden.
    public static let agentDirectoryVariables = ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "COPILOT_HOME", "XDG_CONFIG_HOME"]

    public init(
        home: URL,
        userName: String? = nil,
        appSupport: URL? = nil,
        userTempDirectory: URL? = nil,
        environment: [String: String] = [:],
        isHomeOverridden: Bool = false
    ) {
        let home = home.standardizedFileURL
        self.home = home
        self.userName = userName ?? home.lastPathComponent
        self.appSupport = appSupport
            ?? home.appending(path: "Library/Application Support/Kakureneko", directoryHint: .isDirectory)
        self.userTempDirectory = userTempDirectory
            ?? home.appending(path: "tmp", directoryHint: .isDirectory)
        self.environment = environment
        self.isHomeOverridden = isHomeOverridden
    }

    /// Production paths (the app AND every Kit-based helper such as `kakureneko-guard`).
    ///
    /// Home resolution: `KAKURENEKO_HOME` (absolute) → `HOME` (absolute) → `FileManager` (getpwuid). Note that
    /// `FileManager.homeDirectoryForCurrentUser` / `NSHomeDirectory()` IGNORE `$HOME` on macOS, so a helper spawned
    /// by a test with `HOME=<temp>` would otherwise touch the real `~/.kakureneko`. launchd sets `HOME` to the real
    /// home for GUI apps, so production is unaffected. When the resolved home is not the real one, the agent
    /// directory variables are dropped from `environment` (agent dirs then derive from the fake home).
    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> Paths {
        let realHome = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let home: URL
        if let override = environment[KakurenekoEnvironment.home], override.hasPrefix("/") {
            home = URL(filePath: override, directoryHint: .isDirectory).standardizedFileURL
        } else if let value = environment["HOME"], value.hasPrefix("/") {
            home = URL(filePath: value, directoryHint: .isDirectory).standardizedFileURL
        } else {
            home = realHome
        }
        let overridden = home.path(percentEncoded: false).trimmingTrailingSlash
            != realHome.path(percentEncoded: false).trimmingTrailingSlash
        var env = environment
        if overridden {
            for key in agentDirectoryVariables { env.removeValue(forKey: key) }
        }
        return Paths(
            home: home,
            userName: NSUserName(),
            userTempDirectory: Self.darwinUserTempDirectory(),
            environment: env,
            isHomeOverridden: overridden
        )
    }

    /// A unique, freshly created temporary home for tests (`<tmp>/<prefix>-<uuid>/home`).
    /// The per-user temp dir is a sibling inside the same scratch folder, so the fallback inbox is isolated too.
    public static func temporary(prefix: String = "kakureneko-test") throws -> Paths {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "\(prefix)-\(UUID().uuidString)", directoryHint: .isDirectory)
        let home = root.appending(path: "home", directoryHint: .isDirectory)
        let temp = root.appending(path: "usertmp", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        return Paths(home: home, userName: "tester", userTempDirectory: temp, environment: [:], isHomeOverridden: true)
    }

    /// Environment for spawned helpers that must stay inside this (possibly fake) home: `HOME` +
    /// `KAKURENEKO_HOME` (Kit-based helpers such as `kakureneko-guard`, and the hook in tests).
    public var helperEnvironment: [String: String] {
        let h = home.path(percentEncoded: false).trimmingTrailingSlash
        return ["HOME": h, KakurenekoEnvironment.home: h]
    }

    /// `extraEnvironment` for every agent-CLI subprocess (`claude plugin …`, `claude agents --json --all`):
    /// `HOME` = this home, and — only when the home is overridden — `CLAUDE_CONFIG_DIR`, `CODEX_HOME`,
    /// `COPILOT_HOME`, `XDG_CONFIG_HOME` pinned to the fake-home locations, so a `KAKURENEKO_HOME` run can never
    /// read or modify the real `~/.claude` etc. In a normal run the agent variables are NOT added: setting
    /// `CLAUDE_CONFIG_DIR` explicitly (even to the default) moves Claude's global `.claude.json` into the config
    /// dir, which would change the CLI's behaviour. Callers add `DISABLE_AUTOUPDATER=1` etc. on top.
    public var agentSubprocessEnvironment: [String: String] {
        var env = ["HOME": home.path(percentEncoded: false).trimmingTrailingSlash]
        if isHomeOverridden {
            env["CLAUDE_CONFIG_DIR"] = claudeConfigDirectory.path(percentEncoded: false).trimmingTrailingSlash
            env["CODEX_HOME"] = codexHome.path(percentEncoded: false).trimmingTrailingSlash
            env["COPILOT_HOME"] = copilotHome.path(percentEncoded: false).trimmingTrailingSlash
            env["XDG_CONFIG_HOME"] = xdgConfigDirectory.path(percentEncoded: false).trimmingTrailingSlash
        }
        return env
    }

    /// `confstr(_CS_DARWIN_USER_TEMP_DIR)`, falling back to `NSTemporaryDirectory()`.
    public static func darwinUserTempDirectory() -> URL {
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, size) > 0 {
                let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                return URL(filePath: path, directoryHint: .isDirectory)
            }
        }
        return URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
    }

    // MARK: - ~/.kakureneko

    /// `~/.kakureneko`
    public var kakurenekoDirectory: URL { home.appending(path: ".kakureneko", directoryHint: .isDirectory) }
    /// `~/.kakureneko/bin`
    public var binDirectory: URL { kakurenekoDirectory.appending(path: "bin", directoryHint: .isDirectory) }
    /// `~/.kakureneko/bin/kakureneko-hook` — the literal absolute path installers write into agent configs.
    public var hookBinary: URL { binDirectory.appending(path: KakurenekoID.hookExecutableName, directoryHint: .notDirectory) }
    /// `~/.kakureneko/inbox`
    public var inboxDirectory: URL { kakurenekoDirectory.appending(path: "inbox", directoryHint: .isDirectory) }
    /// `~/.kakureneko/inbox/.tmp` (hook writes here first, then `rename(2)`s into the inbox)
    public var inboxTempDirectory: URL { inboxDirectory.appending(path: ".tmp", directoryHint: .isDirectory) }
    /// `~/.kakureneko/inbox/bad` (files that failed to parse)
    public var inboxBadDirectory: URL { inboxDirectory.appending(path: "bad", directoryHint: .isDirectory) }
    /// Sandbox fallback inbox: `<user temp dir>/com.kakureneko/inbox` (the app watches both inboxes).
    public var fallbackInboxDirectory: URL {
        userTempDirectory.appending(path: KakurenekoID.fallbackInboxRelativePath, directoryHint: .isDirectory)
    }
    public var fallbackInboxTempDirectory: URL { fallbackInboxDirectory.appending(path: ".tmp", directoryHint: .isDirectory) }
    public var fallbackInboxBadDirectory: URL { fallbackInboxDirectory.appending(path: "bad", directoryHint: .isDirectory) }
    /// Both inboxes, primary first.
    public var allInboxDirectories: [URL] { [inboxDirectory, fallbackInboxDirectory] }
    /// `~/.kakureneko/run`
    public var runDirectory: URL { kakurenekoDirectory.appending(path: "run", directoryHint: .isDirectory) }
    /// `~/.kakureneko/run/heartbeat` — mtime touched every SafetyMonitor tick while REALLY armed; read by the root fail-safe.
    public var heartbeatFile: URL { runDirectory.appending(path: "heartbeat", directoryHint: .notDirectory) }
    /// `~/.kakureneko/run/last-events.json` — persisted proof of life (`[AgentID: Date]`, keyed by the delivering
    /// integration), written by KakurenekoEvents at most once per minute and loaded in `start()`.
    public var lastEventsFile: URL { runDirectory.appending(path: "last-events.json", directoryHint: .notDirectory) }
    /// `~/.kakureneko/log`
    public var logDirectory: URL { kakurenekoDirectory.appending(path: "log", directoryHint: .isDirectory) }
    /// `~/.kakureneko/log/hook.log` (hook diagnostics, rotated at 1 MB by the hook)
    public var hookLogFile: URL { logDirectory.appending(path: "hook.log", directoryHint: .notDirectory) }
    /// `~/.kakureneko/log/kakureneko.log` (optional app file log, rotated at 1 MB)
    public var appLogFile: URL { logDirectory.appending(path: "kakureneko.log", directoryHint: .notDirectory) }
    /// `~/.kakureneko/log/guard.log`
    public var guardLogFile: URL { logDirectory.appending(path: "guard.log", directoryHint: .notDirectory) }
    /// `~/.kakureneko/backups`
    public var backupsDirectory: URL { kakurenekoDirectory.appending(path: "backups", directoryHint: .isDirectory) }
    /// `~/.kakureneko/backups/<agent>`
    public func backupDirectory(for agent: AgentID) -> URL {
        backupsDirectory.appending(path: agent.rawValue, directoryHint: .isDirectory)
    }
    /// `~/.kakureneko/recordings` (`KAKURENEKO_RECORD=1`)
    public var recordingsDirectory: URL { kakurenekoDirectory.appending(path: "recordings", directoryHint: .isDirectory) }
    /// `~/.kakureneko/claude-plugin` (local plugin marketplace root)
    public var claudePluginDirectory: URL { kakurenekoDirectory.appending(path: "claude-plugin", directoryHint: .isDirectory) }
    /// `~/.kakureneko/install-manifest.json`
    public var installManifestFile: URL { kakurenekoDirectory.appending(path: "install-manifest.json", directoryHint: .notDirectory) }

    // MARK: - ~/Library/Application Support/Kakureneko

    /// `paused.json` — the pause write-ahead journal (also read by kakureneko-guard).
    public var pauseJournalFile: URL { appSupport.appending(path: "paused.json", directoryHint: .notDirectory) }
    /// `outbox.json` — persistent notification outbox.
    public var outboxFile: URL { appSupport.appending(path: "outbox.json", directoryHint: .notDirectory) }
    /// `secrets.json` — ntfy topics and HMAC key of versions before native notifications. Notify deletes it at start.
    public var legacySecretsFile: URL { appSupport.appending(path: "secrets.json", directoryHint: .notDirectory) }
    /// `notify-state.json` — this Mac's id, the iCloud change token, seen command ids, known phones.
    public var notifyStateFile: URL { appSupport.appending(path: "notify-state.json", directoryHint: .notDirectory) }
    /// `settings.json` — `KakurenekoSettings`.
    public var settingsFile: URL { appSupport.appending(path: "settings.json", directoryHint: .notDirectory) }
    /// `resume.json` — resume manifest written before an opt-in shutdown.
    public var resumeManifestFile: URL { appSupport.appending(path: "resume.json", directoryHint: .notDirectory) }
    /// `install/` — generated privileged install scripts.
    public var installScriptsDirectory: URL { appSupport.appending(path: "install", directoryHint: .isDirectory) }
    /// `install/install-privileged.sh`
    public var privilegedInstallScript: URL { installScriptsDirectory.appending(path: "install-privileged.sh", directoryHint: .notDirectory) }
    /// `install/uninstall-privileged.sh`
    public var privilegedUninstallScript: URL { installScriptsDirectory.appending(path: "uninstall-privileged.sh", directoryHint: .notDirectory) }
    /// `install/kakureneko-failsafe.sh` (template; the install script copies it to the root location with the heartbeat path substituted)
    public var failsafeScriptTemplate: URL { installScriptsDirectory.appending(path: "kakureneko-failsafe.sh", directoryHint: .notDirectory) }

    // MARK: - Root-owned locations (written only by the admin-prompt install script)

    public var sudoersDropIn: URL { RootPaths.sudoersDropIn }
    public var launchDaemonPlist: URL { RootPaths.launchDaemonPlist }
    public var rootSupportDirectory: URL { RootPaths.supportDirectory }
    public var failsafeScript: URL { RootPaths.failsafeScript }

    // MARK: - Agent locations (read-only for everyone except KakurenekoInstall)

    /// `$CLAUDE_CONFIG_DIR` (absolute) or `~/.claude`.
    public var claudeConfigDirectory: URL {
        if let value = environment["CLAUDE_CONFIG_DIR"], value.hasPrefix("/") {
            return URL(filePath: value, directoryHint: .isDirectory)
        }
        return home.appending(path: ".claude", directoryHint: .isDirectory)
    }
    /// `<claude config>/sessions` (read-only; never write).
    public var claudeSessionsDirectory: URL { claudeConfigDirectory.appending(path: "sessions", directoryHint: .isDirectory) }
    /// `<claude config>/projects` (read-only).
    public var claudeProjectsDirectory: URL { claudeConfigDirectory.appending(path: "projects", directoryHint: .isDirectory) }
    /// `$CODEX_HOME` (absolute) or `~/.codex`.
    public var codexHome: URL {
        if let value = environment["CODEX_HOME"], value.hasPrefix("/") {
            return URL(filePath: value, directoryHint: .isDirectory)
        }
        return home.appending(path: ".codex", directoryHint: .isDirectory)
    }
    /// `~/.gemini`
    public var geminiDirectory: URL { home.appending(path: ".gemini", directoryHint: .isDirectory) }
    /// `$COPILOT_HOME` (absolute) or `~/.copilot`.
    public var copilotHome: URL {
        if let value = environment["COPILOT_HOME"], value.hasPrefix("/") {
            return URL(filePath: value, directoryHint: .isDirectory)
        }
        return home.appending(path: ".copilot", directoryHint: .isDirectory)
    }
    /// `~/.cursor`
    public var cursorDirectory: URL { home.appending(path: ".cursor", directoryHint: .isDirectory) }
    /// `$XDG_CONFIG_HOME` (absolute) or `~/.config`.
    public var xdgConfigDirectory: URL {
        if let value = environment["XDG_CONFIG_HOME"], value.hasPrefix("/") {
            return URL(filePath: value, directoryHint: .isDirectory)
        }
        return home.appending(path: ".config", directoryHint: .isDirectory)
    }
    /// `<xdg config>/opencode`
    public var opencodeConfigDirectory: URL { xdgConfigDirectory.appending(path: "opencode", directoryHint: .isDirectory) }
    /// `~/.aider.conf.yml`
    public var aiderConfigFile: URL { home.appending(path: ".aider.conf.yml", directoryHint: .notDirectory) }
    /// `~/.codeium/windsurf`
    public var windsurfDirectory: URL { home.appending(path: ".codeium/windsurf", directoryHint: .isDirectory) }
    /// `~/.local/bin/claude` (first candidate for the Claude CLI; see brief §3.6 A).
    public var claudeCLICandidate: URL { home.appending(path: ".local/bin/claude", directoryHint: .notDirectory) }

    /// `home/<relative>` for any other agent dotfile (e.g. `.factory/hooks.json`).
    public func homeRelative(_ relativePath: String) -> URL {
        home.appending(path: relativePath, directoryHint: .inferFromPath)
    }

    /// Replaces the home prefix with `~` for display only (never for writing into configs).
    public func displayPath(_ url: URL) -> String {
        let path = url.path(percentEncoded: false)
        let homePath = home.path(percentEncoded: false)
        let trimmedHome = homePath.hasSuffix("/") ? String(homePath.dropLast()) : homePath
        if path == trimmedHome { return "~" }
        if path.hasPrefix(trimmedHome + "/") { return "~" + path.dropFirst(trimmedHome.count) }
        return path
    }
}

extension String {
    /// `"/a/b/"` → `"/a/b"` (keeps `"/"`).
    var trimmingTrailingSlash: String {
        guard count > 1, hasSuffix("/") else { return self }
        return String(dropLast())
    }
}

/// Root-owned locations (constants; independent of the injectable home).
public enum RootPaths {
    /// sudoers drop-in. The file name must not contain a dot (sudo skips such files).
    public static let sudoersDropIn = URL(filePath: "/private/etc/sudoers.d/kakureneko", directoryHint: .notDirectory)
    /// Fail-safe LaunchDaemon plist.
    public static let launchDaemonPlist = URL(filePath: "/Library/LaunchDaemons/com.kakureneko.failsafe.plist", directoryHint: .notDirectory)
    /// Root support directory.
    public static let supportDirectory = URL(filePath: "/Library/Application Support/Kakureneko", directoryHint: .isDirectory)
    /// Fail-safe script run by the LaunchDaemon (root:wheel 0755).
    public static let failsafeScript = URL(filePath: "/Library/Application Support/Kakureneko/kakureneko-failsafe.sh", directoryHint: .notDirectory)
    /// `pmset` binary; the sudoers rule matches argv byte for byte.
    public static let pmset = "/usr/bin/pmset"
    public static let sudo = "/usr/bin/sudo"
    public static let launchctl = "/bin/launchctl"
}
