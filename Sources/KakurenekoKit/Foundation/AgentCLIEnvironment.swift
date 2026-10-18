import Darwin
import Foundation

/// (fix) The `PATH` for agent-CLI subprocesses (`claude plugin …`, `claude agents --json`).
///
/// A GUI app started by launchd inherits `PATH=/usr/bin:/bin:/usr/sbin:/sbin`. Claude Code installed with npm, bun,
/// Homebrew's node, nvm or the legacy `~/.claude/local` wrapper is a `#!/usr/bin/env node` script: with that `PATH`
/// it exits 127 ("env: node: No such file or directory"), so the install rolls back and the poller sees nothing.
/// Search order: the CLI's own directory (npm/nvm/Homebrew keep `node` next to it), its symlink target's directory,
/// the user's login-shell `PATH` (when captured), the common install directories, then the inherited `PATH`.
public enum AgentCLIEnvironment {
    /// The launchd default, always last.
    public static let systemPATH = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// Home-relative directories where node/bun/agent CLIs are commonly installed.
    public static let homeRelativeDirectories = [".local/bin", ".bun/bin", ".volta/bin", ".npm-global/bin", ".claude/local"]
    /// System-wide ones (Homebrew on Apple silicon and Intel).
    public static let systemDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// - Parameters:
    ///   - executable: the resolved CLI (absolute path).
    ///   - home: the user's home (the fake home in a `KAKURENEKO_HOME` run).
    ///   - loginShellPATH: the login shell's `PATH`, if captured.
    ///   - inherited: this process's `PATH`.
    public static func searchPath(executable: String, home: URL, loginShellPATH: String?, inherited: String?) -> String {
        var entries: [String] = []
        func add(_ directory: String) {
            let trimmed = directory.count > 1 && directory.hasSuffix("/") ? String(directory.dropLast()) : directory
            guard trimmed.hasPrefix("/"), !trimmed.contains(":"), !entries.contains(trimmed) else { return }
            entries.append(trimmed)
        }
        if executable.hasPrefix("/") {
            add(URL(filePath: executable).deletingLastPathComponent().path(percentEncoded: false))
            if let resolved = realPath(executable) {
                add(URL(filePath: resolved).deletingLastPathComponent().path(percentEncoded: false))
            }
        }
        for part in (loginShellPATH ?? "").split(separator: ":") { add(String(part)) }
        for relative in homeRelativeDirectories {
            add(home.appending(path: relative, directoryHint: .isDirectory).path(percentEncoded: false))
        }
        for directory in systemDirectories { add(directory) }
        for part in (inherited ?? "").split(separator: ":") { add(String(part)) }
        for part in systemPATH.split(separator: ":") { add(String(part)) }
        return entries.joined(separator: ":")
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
