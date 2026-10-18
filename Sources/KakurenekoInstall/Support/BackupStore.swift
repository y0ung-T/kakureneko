import KakurenekoKit
import Foundation

/// Backups of agent config files before an edit (brief §3.7.2): `~/.kakureneko/backups/<agent>/<basename>.<ISO-ts>`
/// (ISO 8601 basic format, e.g. `config.toml.20261012T220000.000Z`, so the name has no `:`), mode 0600 (configs
/// can hold credentials). A backup is skipped when one with the same content already exists, so repeated
/// operations keep the original instead of piling up copies. Backups are never deleted by Kakureneko.
struct BackupStore: Sendable {
    let paths: Paths
    let fileSystem: any InstallFileSystem

    /// Writes a backup of `data` (the current bytes of `file`) unless an identical one exists.
    /// - Returns: the new backup's path, or nil when an identical backup already existed.
    func backup(_ data: Data, of file: URL, agent: AgentID, at date: Date) throws -> URL? {
        let directory = paths.backupDirectory(for: agent)
        let basename = file.lastPathComponent
        let digest = Digest.sha256Hex(data)
        if find(agent: agent, basename: basename, sha256: digest) != nil { return nil }
        let stamp = Self.timestamp(date)
        var candidate = directory.appending(path: "\(basename).\(stamp)", directoryHint: .notDirectory)
        var suffix = 2
        while fileSystem.exists(candidate) || fileSystem.isSymbolicLink(candidate) {
            candidate = directory.appending(path: "\(basename).\(stamp)-\(suffix)", directoryHint: .notDirectory)
            suffix += 1
        }
        try fileSystem.replaceItem(data, at: candidate, permissions: 0o600)
        return candidate
    }

    /// The bytes of a backup of `basename` whose SHA-256 is `sha256`, if one exists.
    func find(agent: AgentID, basename: String, sha256: String) -> Data? {
        let prefix = basename + "."
        let candidates = fileSystem.contentsOfDirectory(paths.backupDirectory(for: agent))
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in candidates {
            guard !fileSystem.isSymbolicLink(url), let data = try? fileSystem.read(url) else { continue }
            if Digest.sha256Hex(data) == sha256 { return data }
        }
        return nil
    }

    /// `20261012T220000.123Z` (ISO 8601 basic format, UTC, milliseconds).
    static func timestamp(_ date: Date) -> String {
        KakurenekoJSON.iso8601String(from: date).filter { $0 != "-" && $0 != ":" }
    }
}

/// `~/.kakureneko/install-manifest.json` (brief §3.7.5). Kakureneko's own file: written atomically with mode 0600.
///
/// Loading never writes (statuses, previews and dry-runs stay read-only). A manifest that does not decode reads
/// as empty, and the first real save keeps a copy of it in the backups folder before replacing it (never silently
/// dropped).
struct ManifestStore: Sendable {
    let paths: Paths
    let fileSystem: any InstallFileSystem
    let logger: KakurenekoLogger

    /// The stored manifest; empty when it is missing or does not decode.
    func load() -> InstallManifest {
        guard let data = try? fileSystem.read(paths.installManifestFile) else { return InstallManifest() }
        do {
            return try KakurenekoJSON.decode(InstallManifest.self, from: data)
        } catch {
            logger.error("install manifest does not decode; treating it as empty (\(error.localizedDescription))")
            return InstallManifest()
        }
    }

    /// Writes `manifest`. An existing file that does not decode is first copied to
    /// `~/.kakureneko/backups/install-manifest.json.unreadable-<ts>`.
    func save(_ manifest: InstallManifest, now: Date) throws {
        let url = paths.installManifestFile
        if let data = try? fileSystem.read(url), (try? KakurenekoJSON.decode(InstallManifest.self, from: data)) == nil {
            let aside = paths.backupsDirectory.appending(
                path: "install-manifest.json.unreadable-\(BackupStore.timestamp(now))", directoryHint: .notDirectory)
            try fileSystem.replaceItem(data, at: aside, permissions: 0o600)
            logger.warning("kept the unreadable install manifest as \(paths.displayPath(aside))")
        }
        try fileSystem.write(try KakurenekoJSON.encode(Self.normalized(manifest)), to: url, permissions: 0o600)
    }

    /// Entries in a stable order (agent, then file), so equal manifests compare equal and diffs stay small.
    static func normalized(_ manifest: InstallManifest) -> InstallManifest {
        var sorted = manifest
        sorted.entries.sort { ($0.agent.rawValue, $0.file) < ($1.agent.rawValue, $1.file) }
        return sorted
    }
}
