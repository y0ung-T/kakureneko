// "Reopen sessions" after an opt-in shutdown (brief §7.5): each `ResumeEntry.resumeCommand` runs in a new window
// of the session's host terminal. The command is written to a `.command` file that the terminal opens, so no
// Automation (Apple Events) permission is needed.
//
// `resume.json` is written from agent-provided data, so ids are validated before they reach a shell.

import KakurenekoKit
import Foundation

nonisolated enum ResumeScript {
    /// Terminals known to run `.command` files in a new window. Every other host (IDEs, Claude.app, …) → Terminal.
    static let commandFileTerminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2"]
    static let defaultTerminalBundleID = "com.apple.Terminal"

    /// Session ids / job ids may only contain these characters (they are interpolated into a shell command).
    static func isSafeIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "-_.:".unicodeScalars.contains(scalar))
        }
    }

    /// The shell command to run, or nil when the entry cannot be reopened safely. `ResumeEntry.resumeCommand` is
    /// already injection-safe and runs `cd "$HOME"` without a cwd; the identifier/newline checks here are defence in
    /// depth (and keep the `.command` file one line per command).
    static func command(for entry: ResumeEntry) -> String? {
        if let job = entry.jobId, entry.kind == "bg", !isSafeIdentifier(job) { return nil }
        if let session = entry.sessionId, !isSafeIdentifier(session) { return nil }
        if let cwd = entry.cwd, cwd.contains("\n") || cwd.contains("\0") { return nil }
        return entry.resumeCommand
    }

    /// Bundle id of the app that should open the `.command` file.
    static func terminalBundleID(for entry: ResumeEntry) -> String {
        if let id = entry.host?.bundleID, commandFileTerminals.contains(id) { return id }
        return defaultTerminalBundleID
    }

    /// Contents of the `.command` file: run the resume command, then stay in an interactive shell.
    static func fileContents(command: String) -> String {
        """
        #!/bin/zsh -l
        # Written by Kakureneko to reopen an agent session after a shutdown. Safe to delete.
        \(command)
        exec "${SHELL:-/bin/zsh}" -l

        """
    }

    /// A short label for logs and the banner.
    static func label(for entry: ResumeEntry) -> String {
        let name = entry.title ?? KakurenekoFormat.projectName(fromCwd: entry.cwd) ?? entry.sessionId ?? "session"
        return "\(entry.agent.displayName) · \(name)"
    }
}
