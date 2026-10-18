import KakurenekoKit
import Foundation

/// Read-only detection of user settings that silently switch every hook off (brief §3.7.6: "Installed" is not
/// "working"; R02 §1 `disableAllHooks` / `allowManagedHooksOnly`, R03 §3 Gemini `hooksConfig.enabled`, R04 §3.4
/// Qwen `disableAllHooks`). The status only gains a note; Kakureneko never flips these switches.
enum HooksSwitch {
    struct Rule: Sendable {
        /// Keys from the document root to the boolean.
        var keys: [String]
        /// The value that turns hooks off.
        var disablingValue: Bool
    }

    /// Claude Code and the Claude-compatible family, Copilot CLI.
    static let disableAllHooks = Rule(keys: ["disableAllHooks"], disablingValue: true)
    /// Claude Code: only managed (MDM) hooks run.
    static let allowManagedHooksOnly = Rule(keys: ["allowManagedHooksOnly"], disablingValue: true)
    /// Gemini CLI (`hooksConfig.enabled` defaults to true).
    static let geminiHooksEnabled = Rule(keys: ["hooksConfig", "enabled"], disablingValue: false)

    /// A user-facing note when `file` (JSON, comments allowed) sets one of `rules`; nil otherwise (also when the
    /// file is missing or unreadable).
    static func note(_ file: URL, rules: [Rule], context: InstallContext) -> String? {
        guard let text = try? context.fileSystem.readText(file),
              let editor = try? JSONEditor(text: text, dialect: .jsonc, path: context.path(file)) else { return nil }
        for rule in rules {
            guard case .bool(let value)? = editor.node(at: rule.keys)?.kind, value == rule.disablingValue else { continue }
            return "\(context.display(file)) sets \(rule.keys.joined(separator: ".")) to \(value), so no hooks run (Kakureneko's included) until it is changed."
        }
        return nil
    }
}
