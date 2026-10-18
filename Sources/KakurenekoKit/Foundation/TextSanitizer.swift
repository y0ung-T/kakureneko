import Foundation

/// Sanitizer for agent-provided text that may reach a phone (brief §8.4 "Detailed" level) or the UI.
///
/// Steps, in order: strip ANSI/OSC escapes → redact secrets (`sk-…`, `ghp_…`/`gho_…`/…,
/// `xox?-…`, `AKIA…`, `-----BEGIN … -----END …`, long hex ≥ 32, long base64 ≥ 40) → reduce absolute
/// and `~` paths to their basename → collapse control characters and whitespace → cap the length
/// (default 140 characters, ending in "…" when truncated).
///
/// Producers (KakurenekoEvents normalizers, KakurenekoSessions transcript helpers) store already
/// sanitized previews in `AgentEvent.messagePreview` / `AgentSession.lastMessagePreview`.
/// KakurenekoNotify only shows them at `DetailLevel.detailed`.
public enum TextSanitizer {
    public static let defaultLimit = 140
    public static let redactionMarker = "[redacted]"

    public static func sanitize(_ input: String, limit: Int = defaultLimit) -> String {
        var text = stripANSI(input)
        text = redactSecrets(text)
        text = basenamePaths(text)
        text = collapseWhitespace(text)
        return truncate(text, limit: limit)
    }

    /// Removes CSI (`ESC [ … final`) and OSC (`ESC ] … BEL|ST`) sequences and stray ESC characters.
    public static func stripANSI(_ text: String) -> String {
        var out = replace(text, pattern: "\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)", with: "")
        out = replace(out, pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "")
        out = replace(out, pattern: "\u{1B}[@-Z\\\\-_]?", with: "")
        return out
    }

    /// Replaces token-like strings with `[redacted]`.
    public static func redactSecrets(_ text: String) -> String {
        let patterns = [
            "-----BEGIN[^-]*-----[\\s\\S]*?(?:-----END[^-]*-----|$)",
            "\\bsk-[A-Za-z0-9_\\-]{8,}",
            "\\bgh[pousr]_[A-Za-z0-9]{16,}",
            "\\bgithub_pat_[A-Za-z0-9_]{20,}",
            "\\bxox[abposr]-[A-Za-z0-9\\-]{8,}",
            "\\b(?:AKIA|ASIA)[0-9A-Z]{12,}",
            "\\btk_[A-Za-z0-9]{16,}",
            "\\b[0-9a-fA-F]{32,}\\b",
            "[A-Za-z0-9+/_\\-]{40,}={0,2}",
        ]
        var out = text
        for pattern in patterns {
            out = replace(out, pattern: pattern, with: redactionMarker)
        }
        return out
    }

    /// `/Users/me/proj/src/main.swift` → `main.swift`; `~/x/y.txt` → `y.txt`.
    public static func basenamePaths(_ text: String) -> String {
        replace(text, pattern: "(?:~|\\B)/(?:[^\\s/:\"'`()\\[\\]]+/)+([^\\s/:\"'`()\\[\\]]+)", with: "$1")
    }

    /// Control characters → space; runs of whitespace → one space; trimmed.
    public static func collapseWhitespace(_ text: String) -> String {
        let scalars = text.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar)
                ? " " : Character(scalar)
        }
        var out = ""
        out.reserveCapacity(scalars.count)
        var previousSpace = false
        for c in scalars {
            if c == " " {
                if !previousSpace { out.append(c) }
                previousSpace = true
            } else {
                out.append(c)
                previousSpace = false
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Caps at `limit` characters including the trailing "…".
    public static func truncate(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        return String(text.prefix(max(0, limit - 1))).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func replace(_ text: String, pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
