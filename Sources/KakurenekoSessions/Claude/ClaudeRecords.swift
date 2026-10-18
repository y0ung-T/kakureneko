import KakurenekoKit
import Foundation

/// Helpers for `~/.claude/sessions/<pid>.json` records (R02 §3).
enum ClaudeRecords {
    /// Records are small (≈ 1 KB); anything larger is not a record.
    static let maxRecordBytes = 64 << 10
    /// Cap for every string taken from a record (untrusted input).
    static let maxFieldLength = 1024

    /// Liveness the way Claude itself checks it (R02 §3.6): the pid exists AND its start time matches `procStart`
    /// within ±1 s (defeats pid reuse). Without `procStart`, the process must have started before the session
    /// registered (`startedAt`, epoch ms). `nil` → dead.
    static func verifiedIdentity(of record: ClaudeSessionRecord, lookup: any ProcessLookup) -> ProcessIdentity? {
        guard record.pid > 0, let identity = lookup.identity(of: record.pid) else { return nil }
        if let procStart = record.procStartEpochSeconds {
            return abs(identity.startSec - procStart) <= 1 ? identity : nil
        }
        if let startedAt = record.startedAt {
            return Double(identity.startSec) <= startedAt / 1000 + 1 ? identity : nil
        }
        return identity
    }

    /// Every string field capped at `maxFieldLength`.
    static func capped(_ record: ClaudeSessionRecord) -> ClaudeSessionRecord {
        var r = record
        r.sessionId = cap(r.sessionId)
        r.cwd = cap(r.cwd)
        r.procStart = cap(r.procStart)
        r.version = cap(r.version)
        r.kind = cap(r.kind)
        r.entrypoint = cap(r.entrypoint)
        r.status = cap(r.status)
        r.waitingFor = cap(r.waitingFor)
        r.name = cap(r.name)
        r.nameSource = cap(r.nameSource)
        r.jobId = cap(r.jobId)
        r.parkedJobId = cap(r.parkedJobId)
        r.bridgeSessionId = cap(r.bridgeSessionId)
        return r
    }

    static func cap(_ value: String?) -> String? {
        guard let value else { return nil }
        return value.count > maxFieldLength ? String(value.prefix(maxFieldLength)) : value
    }

    /// A single path component that cannot escape its directory (`sessionId` and directory names are untrusted).
    static func isSafePathComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    /// `<projects>/<slug>` where the slug is the launch cwd with every non-alphanumeric character replaced by `-`
    /// (R02 §5.1; very long slugs are truncated + hashed by Claude, hence the directory scan fallback).
    static func projectSlug(forCwd cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }
}
