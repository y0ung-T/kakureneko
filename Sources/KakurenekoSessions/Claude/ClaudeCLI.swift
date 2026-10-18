import KakurenekoKit
import Foundation

/// `claude agents --json --all` (R02 §3.5): request construction and tolerant parsing. The CLI is only ever run
/// through the injected `SubprocessRunning` (tests: `FakeSubprocessRunner`), read-only, stdin `/dev/null`.
enum ClaudeCLI {
    static let agentsArguments = ["agents", "--json", "--all"]
    static let timeout: Duration = .seconds(10)
    static let maxOutputBytes = 4 << 20
    /// `/bin/zsh -lc 'command -v claude'` when `~/.local/bin/claude` is missing (GUI apps lack the shell PATH).
    static let shell = "/bin/zsh"
    static let lookupArguments = ["-lc", "command -v claude"]
    /// A failed lookup is retried at most this often.
    static let lookupRetryInterval: TimeInterval = 30 * 60
    /// Cap for every string taken from the CLI output (untrusted input).
    static let maxFieldLength = 1024

    /// `paths.agentSubprocessEnvironment` (fake-home pinning) + no auto-update + no nonessential traffic.
    static func environment(_ paths: Paths) -> [String: String] {
        var env = paths.agentSubprocessEnvironment
        env["DISABLE_AUTOUPDATER"] = "1"
        env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        return env
    }

    /// `PATH` = `AgentCLIEnvironment.searchPath`: an npm/bun/nvm `claude` is a `#!/usr/bin/env node` script, which
    /// launchd's bare `PATH` cannot run (exit 127).
    static func agentsRequest(executable: String, paths: Paths,
                              inheritedPATH: String? = ProcessInfo.processInfo.environment["PATH"]) -> SubprocessRequest {
        var environment = environment(paths)
        environment["PATH"] = AgentCLIEnvironment.searchPath(executable: executable, home: paths.home,
                                                             loginShellPATH: nil, inherited: inheritedPATH)
        return SubprocessRequest(executable: executable, arguments: agentsArguments, extraEnvironment: environment,
                                 stdin: nil, timeout: timeout, maxOutputBytes: maxOutputBytes, effect: .readOnly)
    }

    static func lookupRequest(paths: Paths) -> SubprocessRequest {
        SubprocessRequest(executable: shell, arguments: lookupArguments, extraEnvironment: environment(paths),
                          stdin: nil, timeout: timeout, maxOutputBytes: 64 << 10, effect: .readOnly)
    }

    /// The absolute path printed by `command -v claude` (login shells may print other lines first).
    static func parseLookup(_ result: SubprocessResult) -> String? {
        guard result.succeeded else { return nil }
        return result.stdoutString
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
    }

    /// Entries of a successful run; `nil` on failure or unparseable output. Tolerates text around the JSON array.
    static func parseAgents(_ result: SubprocessResult) -> [ClaudeAgentsEntry]? {
        guard result.succeeded else { return nil }
        var entries = ClaudeAgentsEntry.decodeList(result.stdout)
        if entries == nil, let start = result.stdout.firstIndex(of: UInt8(ascii: "[")),
           let end = result.stdout.lastIndex(of: UInt8(ascii: "]")), start < end {
            entries = ClaudeAgentsEntry.decodeList(result.stdout[start...end])
        }
        return entries?.map(capped)
    }

    static func capped(_ entry: ClaudeAgentsEntry) -> ClaudeAgentsEntry {
        var e = entry
        e.id = cap(e.id)
        e.cwd = cap(e.cwd)
        e.kind = cap(e.kind)
        e.sessionId = cap(e.sessionId)
        e.name = cap(e.name)
        e.status = cap(e.status)
        e.state = cap(e.state)
        e.waitingFor = cap(e.waitingFor)
        return e
    }

    static func cap(_ value: String?) -> String? {
        guard let value else { return nil }
        return value.count > maxFieldLength ? String(value.prefix(maxFieldLength)) : value
    }
}
