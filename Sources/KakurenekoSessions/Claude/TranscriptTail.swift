import KakurenekoKit
import Foundation

/// What the end of a Claude transcript says about its session (R02 §5.2–5.3).
struct TranscriptSummary: Sendable, Hashable {
    /// Latest `custom-title.customTitle` (user `/rename`).
    var customTitle: String?
    /// Latest `agent-name.agentName` (background sessions).
    var agentName: String?
    /// Latest `ai-title.aiTitle`.
    var aiTitle: String?
    /// `cwd` of the last entry that has one (the session's CURRENT cwd).
    var currentCwd: String?
    /// Sanitized text of the last non-sidechain assistant entry.
    var lastAssistantPreview: String?
    /// Last `system`/`turn_duration` entry: its timestamp, `durationMs`, and pending background work.
    var turnCompletedAt: Date?
    var turnDurationMs: Double?
    var turnPendingBackground: Int?

    /// Brief §8.4 order: custom-title → agent-name → ai-title (the record-name rule is applied by the caller).
    var title: String? { customTitle ?? agentName ?? aiTitle }

    /// Title-type values found by an earlier read of the same, since-grown file survive when they scrolled out of
    /// the tail window.
    func carryingTitles(from older: TranscriptSummary) -> TranscriptSummary {
        var merged = self
        if merged.customTitle == nil { merged.customTitle = older.customTitle }
        if merged.agentName == nil { merged.agentName = older.agentName }
        if merged.aiTitle == nil { merged.aiTitle = older.aiTitle }
        if merged.currentCwd == nil { merged.currentCwd = older.currentCwd }
        return merged
    }
}

/// Parses the last ≤ 256 KiB of a transcript JSONL backwards. Transcripts can be tens of MB; only the tail is read.
/// Content (prompts, assistant text) is never logged; the preview is sanitized with `TextSanitizer`.
enum TranscriptTail {
    static let maxBytes = 256 * 1024
    /// Assistant text is cut to this many characters before sanitizing (the preview keeps 140).
    static let previewInputLimit = 2048
    /// Cap for every other string taken from a transcript (untrusted input).
    static let maxFieldLength = 1024

    /// - Parameter startsAtFileStart: false when `data` is a tail window (its first line is partial and dropped).
    static func summarize(_ data: Data, startsAtFileStart: Bool) -> TranscriptSummary {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if !startsAtFileStart, !lines.isEmpty { lines.removeFirst() }
        var summary = TranscriptSummary()
        for line in lines.reversed() {
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if summary.currentCwd == nil, let cwd = string(object["cwd"]) { summary.currentCwd = cwd }
            switch object["type"] as? String {
            case "custom-title":
                if summary.customTitle == nil { summary.customTitle = string(object["customTitle"]) }
            case "agent-name":
                if summary.agentName == nil { summary.agentName = string(object["agentName"]) }
            case "ai-title":
                if summary.aiTitle == nil { summary.aiTitle = string(object["aiTitle"]) }
            case "assistant":
                if summary.lastAssistantPreview == nil, (object["isSidechain"] as? Bool) != true,
                   let text = assistantText(object) {
                    let sanitized = TextSanitizer.sanitize(String(text.prefix(previewInputLimit)))
                    if !sanitized.isEmpty { summary.lastAssistantPreview = sanitized }
                }
            case "system":
                if summary.turnCompletedAt == nil, summary.turnDurationMs == nil,
                   object["subtype"] as? String == "turn_duration" {
                    summary.turnCompletedAt = string(object["timestamp"]).flatMap(KakurenekoJSON.date(fromISO8601:))
                    summary.turnDurationMs = number(object["durationMs"])
                    let workflows = number(object["pendingWorkflowCount"])
                    let agents = number(object["pendingBackgroundAgentCount"])
                    if workflows != nil || agents != nil {
                        summary.turnPendingBackground = Int(max(0, workflows ?? 0)) + Int(max(0, agents ?? 0))
                    }
                }
            default:
                break
            }
        }
        return summary
    }

    /// Joined `text` blocks of an assistant entry (`message.content` may also be a plain string).
    static func assistantText(_ object: [String: Any]) -> String? {
        guard let message = object["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return text.isEmpty ? nil : text }
        guard let blocks = message["content"] as? [Any] else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard let block = block as? [String: Any], block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }
        let joined = texts.joined(separator: " ")
        return joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : joined
    }

    private static func string(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s.count > maxFieldLength ? String(s.prefix(maxFieldLength)) : s
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}
