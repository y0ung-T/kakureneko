@testable import KakurenekoInstall
import Darwin
import KakurenekoKit
import Foundation
import Testing

@Suite("Hook helper deployment", .timeLimit(.minutes(1)))
struct HelperDeploymentTests {
    /// A stand-in for `Kakureneko.app/Contents/Helpers/kakureneko-hook` (never executed).
    private func bundledHelper(_ home: TestHome, _ body: String = "#!/bin/sh\nexit 0\n") throws -> URL {
        let url = home.root.appending(path: "Kakureneko.app/Contents/Helpers/kakureneko-hook")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(body.utf8).write(to: url)
        chmod(url.path(percentEncoded: false), 0o755)
        return url
    }

    private func isSymlink(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path(percentEncoded: false), &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    @Test func copiesOnceAndSkipsWhileTheHashMatches() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let bundled = try bundledHelper(home)
        let manager = home.manager()

        let first = try await manager.deployHelper(from: bundled)
        #expect(first.copied)
        #expect(first.path == home.hookPath)
        #expect(first.sha256 == Digest.sha256Hex("#!/bin/sh\nexit 0\n"))
        #expect(try Data(contentsOf: home.paths.hookBinary) == Data(contentsOf: bundled))
        #expect(home.mode(".kakureneko/bin/kakureneko-hook") == 0o755)
        #expect(!isSymlink(home.paths.hookBinary))
        // DirectoryLayout ran: Kakureneko's own directories exist with mode 0700.
        for directory in [home.paths.inboxDirectory, home.paths.runDirectory, home.paths.logDirectory, home.paths.backupsDirectory] {
            var st = stat()
            #expect(stat(directory.path(percentEncoded: false), &st) == 0)
            #expect(st.st_mode & 0o777 == 0o700)
        }

        let modified = try FileManager.default.attributesOfItem(atPath: home.hookPath)[.modificationDate] as? Date
        let second = try await manager.deployHelper(from: bundled)
        #expect(!second.copied)
        #expect(second.sha256 == first.sha256)
        #expect(try FileManager.default.attributesOfItem(atPath: home.hookPath)[.modificationDate] as? Date == modified)

        // A new app version ships a different helper: it is copied over atomically.
        let updated = try bundledHelper(home, "#!/bin/sh\n# v2\nexit 0\n")
        let third = try await manager.deployHelper(from: updated)
        #expect(third.copied)
        #expect(third.sha256 != first.sha256)
        #expect(try Data(contentsOf: home.paths.hookBinary) == Data("#!/bin/sh\n# v2\nexit 0\n".utf8))
    }

    @Test func repairsAWrongModeAndReplacesASymlink() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let bundled = try bundledHelper(home)
        let manager = home.manager()
        _ = try await manager.deployHelper(from: bundled)

        // Same bytes, but no longer executable: copied again with 0755.
        chmod(home.hookPath, 0o644)
        let fixed = try await manager.deployHelper(from: bundled)
        #expect(fixed.copied)
        #expect(home.mode(".kakureneko/bin/kakureneko-hook") == 0o755)

        // A symlink (e.g. into the app bundle) is replaced by a copy; the link target is left alone.
        try FileManager.default.removeItem(at: home.paths.hookBinary)
        try FileManager.default.createSymbolicLink(at: home.paths.hookBinary, withDestinationURL: bundled)
        let copied = try await manager.deployHelper(from: bundled)
        #expect(copied.copied)
        #expect(!isSymlink(home.paths.hookBinary))
        #expect(try Data(contentsOf: bundled) == Data("#!/bin/sh\nexit 0\n".utf8))
    }

    @Test func aMissingBundledHelperThrows() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let manager = home.manager()
        await #expect(throws: SideEffectError.self) {
            try await manager.deployHelper(from: home.root.appending(path: "Kakureneko.app/Contents/Helpers/kakureneko-hook"))
        }
        let empty = try bundledHelper(home, "")
        await #expect(throws: SideEffectError.self) { try await manager.deployHelper(from: empty) }
        #expect(!home.exists(".kakureneko/bin/kakureneko-hook"))
    }

    @Test func aDeployedHelperUnblocksInstalls() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        try AgentSetups.prepare(.cursor, in: home)
        let manager = home.manager()
        await #expect(throws: SideEffectError.unavailable("hook helper not deployed")) { try await manager.install(.cursor) }
        _ = try await manager.deployHelper(from: try bundledHelper(home))
        let result = try await manager.install(.cursor)
        #expect(result.status.installed)
        #expect(!result.status.notes.contains { $0.contains("not deployed") })
    }

    @Test func deploymentIsKakurenekosOwnFileAndHappensInDryRunToo() async throws {
        let home = try TestHome()
        defer { home.cleanup() }
        let result = try await home.manager(gate: .alwaysOn()).deployHelper(from: try bundledHelper(home))
        #expect(result.copied)
        #expect(home.exists(".kakureneko/bin/kakureneko-hook"))
        #expect(home.ledger.entries.isEmpty)
    }
}
