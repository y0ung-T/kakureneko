import Foundation

/// Every fixed identifier of the product (DECISIONS D5 table applied to the brief; D13: one name everywhere).
public enum KakurenekoID {
    public static let appName = "Kakureneko"
    /// `CFBundleIdentifier` of Kakureneko.app.
    public static let bundleIdentifier = "com.kakureneko.Kakureneko"
    /// Bundle executable name (`Contents/MacOS/Kakureneko`). SwiftPM product is `KakurenekoApp`.
    public static let appExecutableName = "Kakureneko"

    /// Hook helper: `Kakureneko.app/Contents/Helpers/kakureneko-hook`, copied to `~/.kakureneko/bin/kakureneko-hook`.
    public static let hookExecutableName = "kakureneko-hook"
    public static let hookSigningIdentifier = "com.kakureneko.hook"
    /// Out-of-process pause guard: `Kakureneko.app/Contents/Helpers/kakureneko-guard`.
    public static let guardExecutableName = "kakureneko-guard"
    public static let guardSigningIdentifier = "com.kakureneko.guard"

    /// Root fail-safe LaunchDaemon label (`/Library/LaunchDaemons/com.kakureneko.failsafe.plist`).
    public static let launchDaemonLabel = "com.kakureneko.failsafe"

    /// `notify_post` name the hook posts after every inbox drop (a wake-up hint only).
    public static let inboxDarwinNotification = "com.kakureneko.inbox"

    /// Every installed hook entry contains this substring; uninstall/repair remove only entries containing it.
    public static let ownershipMarker = "/.kakureneko/bin/kakureneko-hook"

    /// Claude Code local plugin marketplace (brief §3.6 snippet A, renamed).
    public static let claudePluginName = "kakureneko"
    public static let claudeMarketplaceName = "kakureneko-local"
    public static let claudePluginReference = "kakureneko@kakureneko-local"

    /// os.Logger subsystem.
    public static let logSubsystem = "com.kakureneko.Kakureneko"

    /// Sub-path of the per-user temp dir (`confstr(_CS_DARWIN_USER_TEMP_DIR)`) used as the sandbox fallback inbox.
    public static let fallbackInboxRelativePath = "com.kakureneko/inbox"

    /// `IOPMAssertionCreateWithName` reason while armed (brief §7.2).
    public static let powerAssertionReason = "Kakureneko: agent active"
    /// `ProcessInfo.beginActivity` reason while armed.
    public static let activityReason = "Kakureneko monitoring"
    /// `NSSound(named:)` played once at lid close on battery (brief §7.4 "bag hint").
    public static let lidCloseChimeSoundName = "Submarine"

    /// App Tamer resumes processes others stopped; warn when it runs (brief §6.5 item 6).
    public static let appTamerBundleIdentifier = "com.stclairsoft.AppTamer"
}

/// Environment variables Kakureneko honours (renamed from `LIDLESS_*`).
public enum KakurenekoEnvironment {
    /// `KAKURENEKO_DRY_RUN=1`: log every side effect ("would arm", "would sleep", …) instead of acting.
    public static let dryRun = "KAKURENEKO_DRY_RUN"
    /// `KAKURENEKO_RECORD=1`: the hook also writes raw stdin/argv/allow-listed env to `~/.kakureneko/recordings/`.
    public static let record = "KAKURENEKO_RECORD"
    /// Overrides the home directory every `Paths` location derives from (safe dev runs). Honoured by the app
    /// and by every Kit-based helper (`Paths.live`). Spawned helpers in tests get BOTH `HOME` and this.
    public static let home = "KAKURENEKO_HOME"
    /// Hook side only (tests): overrides the primary inbox directory.
    public static let inbox = "KAKURENEKO_INBOX"
    /// Hook side only (tests): overrides the sandbox fallback inbox (default
    /// `confstr(_CS_DARWIN_USER_TEMP_DIR)/com.kakureneko/inbox`). Hook tests always set BOTH this and `KAKURENEKO_INBOX`
    /// so nothing is ever written to the real per-user fallback inbox.
    public static let fallbackInbox = "KAKURENEKO_FALLBACK_INBOX"
    /// Optional path of a plain-text debug log mirror (app side).
    public static let debugLog = "KAKURENEKO_DEBUG_LOG"
    /// Developer tool (app side): absolute path of a lid-simulation control file (`closed` → Kakureneko sees a closed
    /// lid, no external display, no input). Honoured ONLY together with `KAKURENEKO_DRY_RUN=1` (KakurenekoPower
    /// `LidSimulation`).
    public static let simulateLid = "KAKURENEKO_SIMULATE_LID"

    /// `1`, `true`, `yes`, `on` (case-insensitive) are truthy; anything else (or nil) is false.
    public static func isTruthy(_ value: String?) -> Bool {
        guard let value else { return false }
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "1", "true", "yes", "on": return true
        default: return false
        }
    }
}
