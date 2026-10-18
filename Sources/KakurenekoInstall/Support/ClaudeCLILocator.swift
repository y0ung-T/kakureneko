import KakurenekoKit
import Foundation
import Synchronization

/// Finds the `claude` executable for the plugin commands (brief §3.6 A: "Use the resolved absolute `claude` path
/// (`~/.local/bin/claude`, else `/bin/zsh -lc 'command -v claude'` once)"). A GUI app does not inherit the shell
/// `PATH`, so known install locations are probed first. A found path is cached for the manager's lifetime; a miss
/// is not (the user may install Claude Code later).
final class ClaudeCLILocator: Sendable {
    /// System-wide locations probed after the home-relative ones (Homebrew on Apple silicon and Intel).
    static let defaultSystemCandidates = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]

    private let systemCandidates: [String]
    private let useLoginShell: Bool
    private let cache = Mutex<String?>(nil)

    /// - Parameters:
    ///   - systemCandidates: absolute paths outside the home (tests pass `[]` so results never depend on the Mac).
    ///   - useLoginShell: fall back to `/bin/zsh -lc 'command -v claude'` (a read-only subprocess).
    init(systemCandidates: [String] = ClaudeCLILocator.defaultSystemCandidates, useLoginShell: Bool = true) {
        self.systemCandidates = systemCandidates
        self.useLoginShell = useLoginShell
    }

    /// Home-relative install locations, most common first (native installer, legacy local npm, npm/bun globals).
    static func homeCandidates(_ paths: Paths) -> [URL] {
        [
            paths.claudeCLICandidate,
            paths.homeRelative(".claude/local/claude"),
            paths.homeRelative(".npm-global/bin/claude"),
            paths.homeRelative(".bun/bin/claude"),
        ]
    }

    func locate(
        paths: Paths,
        fileSystem: any InstallFileSystem,
        runner: any SubprocessRunning,
        environment: [String: String]
    ) async -> String? {
        if let cached = cache.withLock({ $0 }), fileSystem.isExecutableFile(URL(filePath: cached)) { return cached }
        let candidates = Self.homeCandidates(paths).map { $0.path(percentEncoded: false) } + systemCandidates
        if let found = candidates.first(where: { fileSystem.isExecutableFile(URL(filePath: $0)) }) {
            cache.withLock { $0 = found }
            return found
        }
        guard useLoginShell else { return nil }
        let request = SubprocessRequest(
            executable: "/bin/zsh",
            arguments: ["-lc", "command -v claude"],
            extraEnvironment: environment,
            timeout: .seconds(10),
            maxOutputBytes: 64 << 10,
            effect: .readOnly
        )
        guard let result = try? await runner.run(request), result.succeeded else { return nil }
        let line = result.stdoutString.split(whereSeparator: \.isNewline).last.map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let line, line.hasPrefix("/"), fileSystem.isExecutableFile(URL(filePath: line)) else { return nil }
        cache.withLock { $0 = line }
        return line
    }
}
