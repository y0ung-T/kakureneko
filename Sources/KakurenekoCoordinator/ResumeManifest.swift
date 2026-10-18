// `resume.json` (brief §7.5): written right before an opt-in shutdown, offered as "Reopen sessions" at the
// next launch, deleted when the offer is cleared or when the Mac only slept (sessions survived). Once the shutdown
// request is out it is kept even if the user cancels (loginwindow may still complete it); a file written during the
// current boot is never offered (no shutdown happened since).

import Darwin
import KakurenekoKit
import Foundation

enum ResumeManifest {
    /// One entry per live session (ended ones excluded). Process-fallback keys carry no resumable id.
    static func entries(from sessions: [AgentSession]) -> [ResumeEntry] {
        sessions
            .filter { !$0.state.isEnded }
            .map { session in
                ResumeEntry(
                    agent: session.agent,
                    sessionId: session.key.isProcessFallback ? nil : session.key.id,
                    cwd: session.cwd,
                    title: session.title,
                    kind: session.metadata[MetadataKey.claudeKind],
                    jobId: session.metadata[MetadataKey.claudeJobID],
                    host: session.host
                )
            }
    }

    /// Atomic 0600 write (`KakurenekoJSON`).
    static func write(_ entries: [ResumeEntry], to url: URL) throws {
        try AtomicFile.write(KakurenekoJSON.encode(entries), to: url, permissions: 0o600, followSymlinks: false)
    }

    /// Entries from a previous run; empty when missing or unreadable (a corrupt file is never fatal).
    static func read(from url: URL) -> [ResumeEntry] {
        guard let data = try? AtomicFile.readIfExists(url),
              let entries = try? KakurenekoJSON.decode([ResumeEntry].self, from: data) else { return [] }
        return entries
    }

    static func delete(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// The manifest's modification time (nil when missing).
    static func writtenAt(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.modificationDate] as? Date
    }

    /// The launch offer: the manifest's entries, unless it was written during THIS boot — then no shutdown happened
    /// since (a cancelled or aborted shutdown, Kakureneko merely relaunched) and the sessions are still running: the
    /// stale file is deleted and nothing is offered. Unknown boot or write time → offered (conservative).
    static func launchOffer(at url: URL, bootTime: Date?) -> [ResumeEntry] {
        let entries = read(from: url)
        guard !entries.isEmpty, let bootTime, let written = writtenAt(url), written > bootTime else { return entries }
        delete(at: url)
        return []
    }

    /// `kern.boottime` (read-only sysctl); nil when unavailable.
    static func kernelBootTime() -> Date? {
        var time = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        let rc = mib.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, 2, &time, &size, nil, 0) }
        guard rc == 0, time.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
    }
}
