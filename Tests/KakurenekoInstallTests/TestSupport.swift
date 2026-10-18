@testable import KakurenekoInstall
import Darwin
import KakurenekoKit
import Foundation
import Synchronization
import Testing

/// A throwaway home (`Paths.temporary()`): every test reads and writes only below it. Nothing here ever touches
/// the real `~/.claude`, `~/.codex`, … or runs an agent CLI (subprocesses go to `FakeSubprocessRunner`).
final class TestHome: Sendable {
    let paths: Paths
    let clock = TestClock()
    let ledger: DryRunLedger
    let runner = FakeSubprocessRunner()

    init() throws {
        paths = try Paths.temporary(prefix: "kakureneko-install-test")
        ledger = DryRunLedger(clock: clock)
    }

    /// The scratch root that contains `home` (and the per-user temp dir).
    var root: URL { paths.home.deletingLastPathComponent() }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func url(_ relative: String) -> URL { paths.homeRelative(relative) }

    var hookPath: String { paths.hookBinary.path(percentEncoded: false) }

    /// Writes `text` to `~/<relative>`, creating parent directories.
    @discardableResult
    func write(_ relative: String, _ text: String) throws -> URL {
        let url = url(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func mkdir(_ relative: String) throws {
        try FileManager.default.createDirectory(at: url(relative), withIntermediateDirectories: true)
    }

    func read(_ relative: String) -> String? {
        (try? Data(contentsOf: url(relative))).map { String(decoding: $0, as: UTF8.self) }
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: url(relative).path(percentEncoded: false))
    }

    /// A stand-in for the deployed helper (never executed).
    func deployFakeHelper() throws {
        try FileManager.default.createDirectory(at: paths.binDirectory, withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: paths.hookBinary)
        chmod(paths.hookBinary.path(percentEncoded: false), 0o755)
    }

    /// A stand-in `claude` at `~/.local/bin/claude` (never executed: the fake runner answers every request).
    @discardableResult
    func installFakeClaudeCLI() throws -> String {
        let url = paths.claudeCLICandidate
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        chmod(url.path(percentEncoded: false), 0o755)
        return url.path(percentEncoded: false)
    }

    func manager(
        gate: DryRunGate = .off(),
        fileSystem: any InstallFileSystem = LiveInstallFileSystem(),
        loginShellLookup: Bool = false,
        paths customPaths: Paths? = nil,
        installers: [any IntegrationInstaller] = IntegrationManager.defaultInstallers
    ) -> IntegrationManager {
        IntegrationManager(
            paths: customPaths ?? paths,
            subprocess: runner,
            dryRun: gate,
            ledger: ledger,
            clock: clock,
            logger: KakurenekoLogger(.install),
            fileSystem: fileSystem,
            claudeLocator: ClaudeCLILocator(systemCandidates: [], useLoginShell: loginShellLookup),
            installers: installers
        )
    }

    /// This home with a different agent-directory environment (e.g. `CODEX_HOME`), as `Paths.live()` would build
    /// it for the real home.
    func paths(environment: [String: String]) -> Paths {
        Paths(
            home: paths.home,
            userName: paths.userName,
            appSupport: paths.appSupport,
            userTempDirectory: paths.userTempDirectory,
            environment: environment,
            isHomeOverridden: false
        )
    }

    /// The install manifest on disk (empty when missing).
    func manifest() throws -> InstallManifest {
        guard let data = try AtomicFile.readIfExists(paths.installManifestFile) else { return InstallManifest() }
        return try KakurenekoJSON.decode(InstallManifest.self, from: data)
    }

    /// POSIX mode bits of `~/<relative>` (symlinks followed).
    func mode(_ relative: String) -> UInt16? {
        var st = stat()
        guard stat(url(relative).path(percentEncoded: false), &st) == 0 else { return nil }
        return UInt16(st.st_mode & 0o7777)
    }

    // MARK: Snapshots

    enum Item: Equatable, CustomStringConvertible {
        case file(Data, mode: UInt16)
        case directory(mode: UInt16)
        case symlink(String)

        var description: String {
            switch self {
            case .file(let data, let mode): "file(\(data.count) bytes, \(String(mode, radix: 8)))"
            case .directory(let mode): "dir(\(String(mode, radix: 8)))"
            case .symlink(let target): "symlink(\(target))"
            }
        }
    }

    /// Every item below the scratch root (paths relative to it), symlinks not followed.
    func snapshot() -> [String: Item] {
        var result: [String: Item] = [:]
        let base = root.path(percentEncoded: false)
        func walk(_ path: String) {
            guard let children = try? FileManager.default.contentsOfDirectory(atPath: path) else { return }
            for name in children {
                let full = (path as NSString).appendingPathComponent(name)
                let relative = String(full.dropFirst(base.count))
                var st = stat()
                guard lstat(full, &st) == 0 else { continue }
                let mode = UInt16(st.st_mode & 0o7777)
                switch st.st_mode & S_IFMT {
                case S_IFLNK:
                    result[relative] = .symlink((try? FileManager.default.destinationOfSymbolicLink(atPath: full)) ?? "?")
                case S_IFDIR:
                    result[relative] = .directory(mode: mode)
                    walk(full)
                default:
                    result[relative] = .file((try? Data(contentsOf: URL(filePath: full))) ?? Data(), mode: mode)
                }
            }
        }
        walk(base)
        return result
    }
}

/// A file system that corrupts the first write to one path (simulates a write that lands damaged, so the re-parse
/// check must roll back; the rollback's own write then goes through intact). Everything else goes to the real
/// file system inside the temp home.
final class CorruptingFileSystem: InstallFileSystem {
    let base = LiveInstallFileSystem()
    /// The first write to a path with this suffix lands truncated.
    let corruptSuffix: String
    /// Writes to the matching path so far.
    private let matchingWrites = Mutex(0)

    init(corruptSuffix: String) { self.corruptSuffix = corruptSuffix }

    /// How many writes were corrupted (0 or 1).
    var corruptedWrites: Int { min(1, matchingWrites.withLock { $0 }) }

    func read(_ url: URL) throws -> Data? { try base.read(url) }

    func write(_ data: Data, to url: URL, permissions: mode_t?) throws {
        let corrupt = url.path(percentEncoded: false).hasSuffix(corruptSuffix) && matchingWrites.withLock { count in
            defer { count += 1 }
            return count == 0
        }
        if corrupt {
            try base.write(data.prefix(max(0, data.count - 7)), to: url, permissions: permissions)
        } else {
            try base.write(data, to: url, permissions: permissions)
        }
    }

    func replaceItem(_ data: Data, at url: URL, permissions: mode_t) throws { try base.replaceItem(data, at: url, permissions: permissions) }
    func remove(_ url: URL) throws { try base.remove(url) }
    func removeTree(_ url: URL) throws { try base.removeTree(url) }
    func exists(_ url: URL) -> Bool { base.exists(url) }
    func directoryExists(_ url: URL) -> Bool { base.directoryExists(url) }
    func isExecutableFile(_ url: URL) -> Bool { base.isExecutableFile(url) }
    func isSymbolicLink(_ url: URL) -> Bool { base.isSymbolicLink(url) }
    func contentsOfDirectory(_ url: URL) -> [URL] { base.contentsOfDirectory(url) }
}

/// Splice-level context for unit tests (no manager).
func makeContext(_ home: TestHome) -> InstallContext {
    InstallContext(paths: home.paths, fileSystem: LiveInstallFileSystem())
}

/// Every string anywhere inside a parsed JSON node.
func allStrings(_ node: JSONNode) -> [String] {
    switch node.kind {
    case .object(let members): members.flatMap { [$0.key] + allStrings($0.value) }
    case .array(let elements): elements.flatMap(allStrings)
    case .string(let s): [s]
    case .number, .bool, .null: []
    }
}

/// The `"command"`/`"bash"` strings of every handler under `containerKeys` that mentions `needle`.
func handlerCommands(_ text: String, containerKeys: [String], dialect: JSONSyntax.Dialect = .jsonc) throws -> [String] {
    let editor = try JSONEditor(text: text, dialect: dialect, path: "test")
    guard let container = editor.node(at: containerKeys)?.members else { return [] }
    var result: [String] = []
    for event in container {
        for element in event.value.elements ?? [] {
            let handlers = element.member("hooks")?.value.elements ?? [element]
            for handler in handlers {
                for key in ["command", "bash"] {
                    if let value = handler.member(key)?.value.stringValue { result.append(value) }
                }
            }
        }
    }
    return result
}

extension DryRunLedger {
    func actions() -> [String] { entries.map(\.action) }
}
