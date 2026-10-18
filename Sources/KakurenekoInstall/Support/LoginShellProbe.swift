import KakurenekoKit
import Foundation
import Synchronization

/// One read-only run of the user's interactive login shell (`/bin/zsh -ilc`, stdin `/dev/null`, 10 s), cached for the
/// manager's lifetime: the `PATH` and the agent-directory variables the user's shell exports. A GUI app started by
/// launchd sees neither — `#!/usr/bin/env node` CLIs fail with 127, and `CODEX_HOME`/`CLAUDE_CONFIG_DIR`/… set in
/// `~/.zshrc` are invisible. Output is delimited by a marker (shell start-up files may print anything first).
final class LoginShellProbe: Sendable {
    struct Values: Sendable, Equatable {
        var path: String?
        /// Non-empty values of `variables`.
        var agentDirectories: [String: String]
    }

    /// The agent-directory variables `Paths` honours (ARCHITECTURE §4.1).
    static let variables = ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "COPILOT_HOME", "XDG_CONFIG_HOME"]
    static let marker = "__KAKURENEKO_LOGIN_ENV__"
    static let shell = "/bin/zsh"

    private let enabled: Bool
    private let cache = Mutex<Values?>(nil)
    private let attempted = Mutex(false)

    /// - Parameter enabled: false (tests) → never runs a shell; `values` is nil.
    init(enabled: Bool = true) { self.enabled = enabled }

    static func request(environment: [String: String]) -> SubprocessRequest {
        let fields = (["$PATH"] + variables.map { "${\($0)-}" }).map { "\"\($0)\"" }.joined(separator: " ")
        return SubprocessRequest(
            executable: shell,
            arguments: ["-ilc", "printf '%s' '\(marker)'; printf '%s\\0' \(fields)"],
            extraEnvironment: environment,
            stdin: nil,
            timeout: .seconds(10),
            maxOutputBytes: 256 << 10,
            effect: .readOnly
        )
    }

    static func parse(_ result: SubprocessResult) -> Values? {
        let text = result.stdoutString
        guard let range = text.range(of: marker, options: .backwards) else { return nil }
        let fields = text[range.upperBound...].split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 1 + variables.count else { return nil }
        var directories: [String: String] = [:]
        for (index, name) in variables.enumerated() {
            let value = fields[1 + index].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("/") { directories[name] = value }
        }
        let path = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
        return Values(path: path.isEmpty ? nil : path, agentDirectories: directories)
    }

    /// The probed values (one shell run per lifetime; a failure is not retried).
    func values(runner: any SubprocessRunning, environment: [String: String]) async -> Values? {
        guard enabled else { return nil }
        if let cached = cache.withLock({ $0 }) { return cached }
        let first = attempted.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
        guard first else { return cache.withLock { $0 } }
        guard let result = try? await runner.run(Self.request(environment: environment)),
              let values = Self.parse(result) else { return nil }
        cache.withLock { $0 = values }
        return values
    }
}
