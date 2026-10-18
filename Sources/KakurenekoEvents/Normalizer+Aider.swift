import KakurenekoKit
import Foundation

/// Aider (brief §3.3 row 8, snippet H, R03 §8): one `notifications-command` that fires on the bell — the same
/// signal for "turn done" and "needs confirmation", with no payload (and the user's tty as stdin, never read).
///
/// | Raw | Normalized |
/// |---|---|
/// | any event (installer uses `waiting`) | turnFinished(ambiguous) |
///
/// No session id: the session is the Aider process (`SessionKey.fallback`), start/end come from its lifetime.
struct AiderNormalizer: EventNormalizer {
    func normalize(_ input: NormalizationInput) -> NormalizedFields? {
        NormalizedFields(.turnFinished(.ambiguous))
    }
}
