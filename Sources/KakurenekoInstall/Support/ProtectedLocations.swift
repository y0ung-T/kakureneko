import KakurenekoKit
import Foundation

/// Locations no installer may ever write or delete (brief §3.7.8): Claude's session records, `jobs/**` and
/// `daemon/**`, the Fleetview heartbeat, any `settings.local.json` and any `.key` file. Codex `[hooks.state]` is a
/// table inside `config.toml`; the `notify` splice is line-oriented and only ever touches the root `notify`
/// statement, so it is protected by construction (and covered by tests).
///
/// None of the v1 installers targets these paths; the check is a last line of defence that `IntegrationManager`
/// runs on every planned write, so a future installer bug fails loudly instead of corrupting an agent's state.
enum ProtectedLocations {
    /// Why writing (or deleting) `url` is forbidden, or nil when it is allowed. Every hop of a symlink chain is
    /// checked (also a dangling link whose target does not exist yet), so a link into a protected location is
    /// refused too.
    static func violation(_ url: URL, paths: Paths) -> String? {
        let roots = [paths.claudeConfigDirectory, paths.homeRelative(".claude")].flatMap { root in
            [root.standardizedFileURL, root.resolvingSymlinksInPath().standardizedFileURL]
        }
        for candidate in linkChain(url) {
            if let reason = check(candidate, claudeRoots: roots) { return reason }
        }
        return nil
    }

    private static func check(_ url: URL, claudeRoots: [URL]) -> String? {
        let name = url.lastPathComponent
        if name == "settings.local.json" { return "local settings files belong to the user" }
        if url.pathExtension == "key" { return "key files are never touched" }
        if name == ".fleetview-heartbeat" { return "the Fleetview heartbeat belongs to Claude Code" }
        for root in claudeRoots {
            guard let first = relativeComponents(of: url, under: root)?.first else { continue }
            switch first {
            case "sessions": return "Claude's session records are read-only for Kakureneko"
            case "jobs", "daemon": return "Claude's \(first) state is read-only for Kakureneko"
            default: continue
            }
        }
        return nil
    }

    /// `url`, every target along its symlink chain (at most `AtomicFile.maxSymlinkHops` hops), the final target with
    /// its parent directories resolved (e.g. `/var` → `/private/var`), and the exact file `AtomicFile.write` would
    /// replace (`AtomicFile.finalTarget(of:)`, which does not fold `..` lexically).
    static func linkChain(_ url: URL) -> [URL] {
        var chain = [url.standardizedFileURL]
        var current = url.standardizedFileURL
        for _ in 0..<AtomicFile.maxSymlinkHops {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: current.linkSafePath) else {
                break
            }
            let next = destination.hasPrefix("/")
                ? URL(filePath: destination, directoryHint: .notDirectory)
                : current.deletingLastPathComponent().appending(path: destination, directoryHint: .notDirectory)
            current = next.standardizedFileURL
            chain.append(current)
        }
        let parent = current.deletingLastPathComponent().resolvingSymlinksInPath()
        chain.append(parent.appending(path: current.lastPathComponent, directoryHint: .notDirectory).standardizedFileURL)
        if let written = try? AtomicFile.finalTarget(of: url) {
            let writtenParent = written.deletingLastPathComponent().resolvingSymlinksInPath()
            chain.append(writtenParent.appending(path: written.lastPathComponent, directoryHint: .notDirectory).standardizedFileURL)
        }
        return chain
    }

    /// Path components of `url` below `root`, or nil when `url` is not inside `root`.
    static func relativeComponents(of url: URL, under root: URL) -> [String]? {
        let base = root.standardizedFileURL.pathComponents
        let full = url.standardizedFileURL.pathComponents
        guard full.count > base.count, Array(full.prefix(base.count)) == base else { return nil }
        return Array(full.dropFirst(base.count))
    }
}
