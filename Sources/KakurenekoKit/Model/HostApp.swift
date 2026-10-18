import Foundation

/// The GUI application hosting an agent session (Terminal, iTerm2, VS Code, Cursor, Claude.app, …).
/// Derived from `__CFBundleIdentifier` / `TERM_PROGRAM` (hook env) or the process ancestry.
public struct HostApp: Sendable, Hashable, Codable {
    /// Bundle identifier when known (`com.apple.Terminal`).
    public var bundleID: String?
    /// Display name (`Terminal`).
    public var name: String
    /// Main pid of the host app when known (from ancestry / responsibility).
    public var pid: Int32?

    public init(bundleID: String?, name: String, pid: Int32? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.pid = pid
    }

    /// Known host apps by bundle identifier. Prefix matches end with ".".
    public static let knownBundleNames: [(bundleIDOrPrefix: String, name: String)] = [
        ("com.apple.Terminal", "Terminal"),
        ("com.googlecode.iterm2", "iTerm2"),
        ("com.mitchellh.ghostty", "Ghostty"),
        ("com.github.wez.wezterm", "WezTerm"),
        ("org.alacritty", "Alacritty"),
        ("net.kovidgoyal.kitty", "kitty"),
        ("dev.warp.Warp-Stable", "Warp"),
        ("co.zeit.hyper", "Hyper"),
        ("com.microsoft.VSCode", "VS Code"),
        ("com.microsoft.VSCodeInsiders", "VS Code Insiders"),
        ("com.vscodium", "VSCodium"),
        ("com.todesktop.230313mzl4w4u92", "Cursor"),
        ("com.exafunction.windsurf", "Windsurf"),
        ("dev.zed.Zed", "Zed"),
        ("dev.zed.Zed-Preview", "Zed Preview"),
        ("com.jetbrains.", "JetBrains IDE"),
        ("com.google.android.studio", "Android Studio"),
        ("com.apple.dt.Xcode", "Xcode"),
        ("com.anthropic.claudefordesktop", "Claude"),
        ("com.openai.chat", "ChatGPT"),
    ]

    /// Known `TERM_PROGRAM` values.
    public static let knownTermPrograms: [String: (bundleID: String?, name: String)] = [
        "Apple_Terminal": ("com.apple.Terminal", "Terminal"),
        "iTerm.app": ("com.googlecode.iterm2", "iTerm2"),
        "vscode": ("com.microsoft.VSCode", "VS Code"),
        "WarpTerminal": ("dev.warp.Warp-Stable", "Warp"),
        "ghostty": ("com.mitchellh.ghostty", "Ghostty"),
        "WezTerm": ("com.github.wez.wezterm", "WezTerm"),
        "Hyper": ("co.zeit.hyper", "Hyper"),
        "tmux": (nil, "tmux"),
    ]

    /// Host from a bundle identifier (`nil` when empty).
    public static func from(bundleID: String?, pid: Int32? = nil) -> HostApp? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        for entry in knownBundleNames {
            let matches = entry.bundleIDOrPrefix.hasSuffix(".")
                ? bundleID.hasPrefix(entry.bundleIDOrPrefix)
                : bundleID == entry.bundleIDOrPrefix
            if matches { return HostApp(bundleID: bundleID, name: entry.name, pid: pid) }
        }
        let fallbackName = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return HostApp(bundleID: bundleID, name: fallbackName, pid: pid)
    }

    /// Host from an (allow-listed) hook environment: `__CFBundleIdentifier` first, then `TERM_PROGRAM`.
    public static func from(environment: [String: String]) -> HostApp? {
        if let host = from(bundleID: environment["__CFBundleIdentifier"]) { return host }
        if let term = environment["TERM_PROGRAM"], let known = knownTermPrograms[term] {
            return HostApp(bundleID: known.bundleID, name: known.name)
        }
        return nil
    }
}
