import KakurenekoKit

/// Rule P-J: bundle ids that are never paused, whatever the dynamic rules say (R06 §3.4 + every known agent host +
/// Kakureneko itself). Matching is exact, except entries ending in "." which match as prefixes (`com.jetbrains.`).
enum NeverPauseList {
    static let bundleIDs: Set<String> = {
        var ids: Set<String> = [
            // Kakureneko itself
            KakurenekoID.bundleIdentifier,
            // Terminals (agent hosts)
            "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.github.wez.wezterm",
            "org.alacritty", "net.kovidgoyal.kitty", "dev.warp.Warp-Stable", "co.zeit.hyper", "org.tabby",
            // IDEs / editors (agent hosts)
            "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium", "com.todesktop.230313mzl4w4u92",
            "com.exafunction.windsurf", "dev.zed.Zed", "dev.zed.Zed-Preview", "com.google.android.studio",
            "com.apple.dt.Xcode", "com.sublimetext.4", "com.panic.Nova",
            // AI desktop apps (agent hosts)
            "com.anthropic.claudefordesktop", "com.openai.chat", "com.openai.codex",
            // Dev infrastructure / VMs
            "com.apple.iphonesimulator", "com.docker.docker", "dev.kdrag0n.MacVirt", "io.podman_desktop.PodmanDesktop",
            "com.utmapp.UTM", "com.parallels.desktop.console", "com.vmware.fusion", "com.postgresapp.Postgres2",
            "com.tinyapp.DBngin", "de.appsolute.MAMP", "de.beyondco.herd",
            // Local LLM servers
            "com.electron.ollama", "ai.elementlabs.lmstudio",
            // Network / VPN
            "io.tailscale.ipn.macos", "io.tailscale.ipn.macsys", "com.cloudflare.1dot1dot1dot1.macos",
            "com.wireguard.macos", "net.mullvad.vpn", "ch.protonvpn.mac", "at.obdev.littlesnitch",
            // Password managers / SSH agents (a frozen SSH agent makes `git push` hang)
            "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
            "com.maxgoedjen.Secretive.Host", "org.keepassxc.keepassxc",
            // Security / MDM
            "com.microsoft.wdav", "com.microsoft.wdav.shim",
            // Remote access
            "com.apple.ScreenSharing", "com.teamviewer.TeamViewer", "com.philandro.anydesk", "com.p5sys.jump.mac.viewer",
            // macOS system UI and tools
            "com.apple.finder", "com.apple.systempreferences", "com.apple.ActivityMonitor", "com.apple.Console",
            "com.apple.ScriptEditor2", "com.apple.shortcuts", "com.apple.Automator", "com.apple.DiskUtility",
            "com.apple.installer", "com.apple.MigrateAssistant", "com.apple.keychainaccess",
            // Input / accessibility / window and display utilities
            "pro.betterdisplay.BetterDisplay", "com.MrKai77.Loop", "com.logitech.Logi-Options", "com.logi.optionsplus",
            "org.pqrs.Karabiner-Elements.Settings", "com.hegenberg.BetterTouchTool", "com.raycast.macos",
            "com.runningwithcrayons.Alfred", "org.hammerspoon.Hammerspoon", "com.stairways.keyboardmaestro.engine",
            "com.knollsoft.Rectangle", "com.if.Amphetamine",
        ]
        for entry in HostApp.knownBundleNames where !entry.bundleIDOrPrefix.hasSuffix(".") {
            ids.insert(entry.bundleIDOrPrefix)
        }
        return ids
    }()

    static let prefixes: [String] = {
        var prefixes = ["com.jetbrains."]
        for entry in HostApp.knownBundleNames where entry.bundleIDOrPrefix.hasSuffix(".") {
            if !prefixes.contains(entry.bundleIDOrPrefix) { prefixes.append(entry.bundleIDOrPrefix) }
        }
        return prefixes
    }()

    static func contains(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        return bundleIDs.contains(bundleID) || prefixes.contains { bundleID.hasPrefix($0) }
    }
}
