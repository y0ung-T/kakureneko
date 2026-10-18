import KakurenekoKit
import Foundation

/// User-presentable installer failures (shown by the onboarding/settings UI via `localizedDescription`).
/// Contract-level failures (`hook helper not deployed`, phantom installs, missing CLI) use Kit's
/// `SideEffectError` instead, as `AgentIntegrating` documents.
enum InstallError: Error, LocalizedError, Sendable, Equatable {
    /// The agent's config file could not be parsed; nothing was written.
    case unparseable(path: String, reason: String)
    /// The config parses but has a shape we refuse to edit (e.g. `"hooks"` is not an object).
    case unexpectedStructure(path: String, reason: String)
    /// The file is not UTF-8 text.
    case notUTF8(path: String)
    /// After writing, the file did not re-parse to the expected content; it was restored from the backup.
    case verificationFailed(path: String, reason: String)
    /// A key we would write already exists and is not ours.
    case conflict(path: String, reason: String)
    /// The agent CLI reported a failure.
    case cliFailed(command: String, detail: String)
    /// An installer planned a write to a location Kakureneko must never touch (brief §3.7.8).
    case protectedLocation(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .unparseable(let path, let reason): "Could not read \(path): \(reason). Nothing was changed."
        case .unexpectedStructure(let path, let reason): "Unexpected content in \(path): \(reason). Nothing was changed."
        case .notUTF8(let path): "\(path) is not UTF-8 text. Nothing was changed."
        case .verificationFailed(let path, let reason): "The edit of \(path) did not verify (\(reason)); the original was restored."
        case .conflict(let path, let reason): "\(path): \(reason). Nothing was changed."
        case .cliFailed(let command, let detail): "\(command) failed: \(detail)"
        case .protectedLocation(let path, let reason): "Refusing to change \(path): \(reason). Nothing was changed."
        }
    }
}
