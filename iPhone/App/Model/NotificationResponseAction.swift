// What a tap on a notification asks the app to do, decoded right where UserNotifications delivers the response
// (any thread) into a Sendable value the app delegate hands to the main actor. Buttons decode through
// `AlertPresentation.buttonTap`, exactly like on the Mac.

import KakurenekoCloud
import Foundation
import UserNotifications

enum NotificationResponseAction: Sendable, Equatable {
    /// The notification itself was tapped: open the app on this Mac (nil when the notification names none).
    case open(macID: String?)
    /// A button: send its command to the Mac. `macName` names the Mac in a "couldn't reach" notice.
    case button(AlertPresentation.ButtonTap, macName: String?)
    /// Dismissed, or not a Kakureneko notification.
    case ignore

    init(actionIdentifier: String, userInfo: [AnyHashable: Any]) {
        let macID = userInfo[NotificationIDs.UserInfo.macID] as? String
        if actionIdentifier == UNNotificationDefaultActionIdentifier {
            self = .open(macID: macID)
        } else if let tap = AlertPresentation.buttonTap(actionIdentifier: actionIdentifier, userInfo: userInfo) {
            self = .button(tap, macName: userInfo[NotificationIDs.UserInfo.macName] as? String)
        } else {
            self = .ignore
        }
    }
}
