import KakurenekoKit
import Foundation
import Synchronization

/// Pure path analysis for `.app` bundles (host-app detection, P-B agent-launched apps, `open -a`).
enum AppBundlePaths {
    /// The outermost `.app` bundle containing `path`: `/A/Visual Studio Code.app/Contents/Frameworks/Code Helper
    /// (Plugin).app/Contents/MacOS/Code Helper (Plugin)` → `/A/Visual Studio Code.app`.
    static func outermostBundle(containing path: String) -> String? {
        guard path.hasPrefix("/"), let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    /// The bundle whose main executable is `path` (`<bundle>.app/Contents/MacOS/<name>`), nested bundles included.
    static func bundle(ofMainExecutable path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        let n = components.count
        guard n >= 4, components[n - 2] == "MacOS", components[n - 3] == "Contents", components[n - 4].hasSuffix(".app")
        else { return nil }
        return "/" + components[0...(n - 4)].joined(separator: "/")
    }

    /// True when `path` is the main executable of a top-level `.app` (a GUI app's main process, not a helper).
    static func isAppMainExecutable(_ path: String) -> Bool {
        guard let bundle = bundle(ofMainExecutable: path) else { return false }
        return outermostBundle(containing: path) == bundle
    }

    /// True when `path` lies anywhere inside an `.app` bundle.
    static func isInsideAppBundle(_ path: String) -> Bool {
        outermostBundle(containing: path) != nil
    }
}

/// Bundle identifier lookups (`<bundle>/Contents/Info.plist` → `CFBundleIdentifier`), cached per bundle path.
/// Thread-safe; the reader is injectable for tests.
final class BundleIdentifierCache: Sendable {
    typealias Reader = @Sendable (String) -> String?

    private let reader: Reader
    private let cache = Mutex<[String: String?]>([:])
    private static let capacity = 1024

    init(reader: @escaping Reader = BundleIdentifierCache.readInfoPlist) {
        self.reader = reader
    }

    func bundleIdentifier(ofBundle bundlePath: String) -> String? {
        if let cached = cache.withLock({ $0[bundlePath] }) { return cached }
        let value = reader(bundlePath)
        cache.withLock { entries in
            if entries.count >= Self.capacity { entries.removeAll(keepingCapacity: true) }
            entries[bundlePath] = .some(value)
        }
        return value
    }

    /// Reads `CFBundleIdentifier` from the bundle's Info.plist (read-only file access).
    @Sendable static func readInfoPlist(_ bundlePath: String) -> String? {
        let url = URL(filePath: bundlePath, directoryHint: .isDirectory).appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String, !identifier.isEmpty
        else { return nil }
        return String(identifier.prefix(255))
    }
}

/// Host-app derivation for an agent (ARCHITECTURE §9.2): `HostApp.from(environment:)` first, else the first ancestor
/// whose executable lies inside an `.app` bundle → `HostApp.from(bundleID:)`. The pid is the host app's MAIN process
/// when it is in the ancestry.
enum HostAppResolver {
    static func host(environment: [String: String], ancestors: [AncestorInfo], bundles: BundleIdentifierCache) -> HostApp? {
        if var host = HostApp.from(environment: environment) {
            if let bundleID = host.bundleID {
                host.pid = ancestors.first { $0.isApp && $0.bundleID == bundleID }?.identity.pid
            }
            return host
        }
        for (index, ancestor) in ancestors.enumerated() {
            guard let path = ancestor.executablePath, let outer = AppBundlePaths.outermostBundle(containing: path) else {
                continue
            }
            guard let bundleID = bundles.bundleIdentifier(ofBundle: outer) else { continue }
            // Prefer the app's main process further up the chain (helpers → main).
            let main = ancestors[index...].first { candidate in
                guard let candidatePath = candidate.executablePath else { return false }
                return AppBundlePaths.isAppMainExecutable(candidatePath)
                    && AppBundlePaths.outermostBundle(containing: candidatePath) == outer
            }
            return HostApp.from(bundleID: bundleID, pid: (main ?? ancestor).identity.pid)
        }
        return nil
    }
}
