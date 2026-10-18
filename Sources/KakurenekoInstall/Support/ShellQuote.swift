import KakurenekoKit
import Foundation

/// POSIX `sh` quoting for the shell-run hook commands (Gemini `bash -c`, Codex `$SHELL -lc`, Cursor, Copilot
/// `bash`, Windsurf `bash -c`, Aider `shell=True`, the Claude-compatible family).
enum ShellQuote {
    /// Characters that never need quoting in a POSIX shell word.
    private static let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@%+=:,./-_")

    /// Returns `word` unchanged when it is made only of shell-safe characters (the normal
    /// `/Users/<name>/.kakureneko/bin/kakureneko-hook` case — keeps the Codex trust hash stable), else wraps it in
    /// single quotes (`'` → `'\''`).
    static func quoteIfNeeded(_ word: String) -> String {
        if !word.isEmpty, word.allSatisfy({ safe.contains($0) }) { return word }
        return quote(word)
    }

    /// Always single-quotes `word`.
    static func quote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The command strings installers write. Every one contains `KakurenekoID.ownershipMarker` (the hook path).
struct HookCommand: Sendable, Hashable {
    /// Absolute path of `~/.kakureneko/bin/kakureneko-hook` (literal, never `~`/`$HOME`: Factory, Rovo and Windsurf
    /// do not expand them — brief C2).
    let hookPath: String

    /// Suffix of every shell-run entry: a missing helper can never be read as a blocking decision.
    static let shellSuffix = " 2>/dev/null; exit 0"

    /// `<hook> <agent> <event> 2>/dev/null; exit 0`.
    func shell(_ agent: AgentID, _ event: String) -> String {
        "\(ShellQuote.quoteIfNeeded(hookPath)) \(agent.rawValue) \(event)\(Self.shellSuffix)"
    }

    /// `<hook> <agent> <event> --chain -- <chainText> 2>/dev/null; exit 0` (Aider). `chainText` is shell text.
    func shell(_ agent: AgentID, _ event: String, chaining chainText: String) -> String {
        "\(ShellQuote.quoteIfNeeded(hookPath)) \(agent.rawValue) \(event) --chain -- \(chainText)\(Self.shellSuffix)"
    }
}
