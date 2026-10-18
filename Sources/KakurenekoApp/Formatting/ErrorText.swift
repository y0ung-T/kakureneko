// User-presentable error text for failed actions (`KakurenekoControlling` errors are LocalizedError,
// `SideEffectError`, `DeliveryError` or installer errors).

import KakurenekoKit
import Foundation

/// An inline error shown in the menu or a window until dismissed.
nonisolated struct ErrorBanner: Sendable, Hashable, Identifiable {
    var id = UUID()
    /// What failed: "Installing closed-lid mode".
    var title: String
    var message: String
}

nonisolated enum ErrorText {
    static func describe(_ error: any Error) -> String {
        if let delivery = error as? DeliveryError {
            switch delivery {
            case .retryable(let after):
                let retry = after.map { " Kakureneko retries in \(KakurenekoFormat.shortDuration($0))." } ?? " Kakureneko retries automatically."
                return "iCloud could not be reached." + retry
            case .permanent(let message):
                return "iCloud refused the request: \(message)"
            }
        }
        if error is CancellationError { return "Cancelled." }
        if let localized = error as? any LocalizedError, let description = localized.errorDescription, !description.isEmpty {
            return description
        }
        let ns = error as NSError
        return ns.localizedDescription.isEmpty ? String(describing: error) : ns.localizedDescription
    }
}
