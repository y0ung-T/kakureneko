import Darwin
import KakurenekoKit
import Foundation
import Synchronization

extension PauseManager {
    /// XNU copies an EXTERNAL darwinbg to every child forked afterwards (verified on macOS 26 with own processes:
    /// the child reports `PROC_FLAG_EXT_DARWINBG` and keeps it after the parent is restored). A renderer, a native
    /// messaging host or an agent CLI forked by a member Kakureneko throttled therefore starts throttled — R06 §1.2:
    /// "helpers spawned while throttled start throttled, and Lidless must clear them too" — but every undo path
    /// (thaw, guard, crash buffer, launch recovery) restores only JOURNALED records.
    ///
    /// Journals such processes as Kakureneko's own `.darwinBackground` records: a live, same-user process started
    /// after the pause began, whose PARENT is a member Kakureneko throttled (journaled, identity verified) or one
    /// adopted the same way, and that carries darwinbg now. A process that was already darwinbg before the pause
    /// (App Tamer, `taskpolicy -b`, the user) — or forked by such a one — is never adopted, so restoring to 0 stays
    /// correct. Real (non-simulated) throttled apps only, never in dry-run (nothing was really throttled).
    /// - Parameter appPids: limit to these journaled apps (nil = all).
    /// - Returns: the number of processes adopted.
    @discardableResult
    func adoptInheritedThrottles(only appPids: Set<Int32>? = nil) -> Int {
        guard !dryRun.isOn, let snapshot = journal.current, let table = probe.processTable() else { return 0 }
        let uid = probe.userID
        let began = state.withLock { $0.session.began } ?? snapshot.startedAt
        let journaledPIDs = Set(snapshot.apps.flatMap(\.members).map(\.pid))
        var adopted = 0
        for app in snapshot.apps where app.mode == .throttle && !app.simulated {
            if let appPids, !appPids.contains(app.appPid) { continue }
            // Members Kakureneko really throttled that are still the same process.
            var ours = Set(app.members.filter { record in
                record.action == .darwinBackground && table[record.pid]?.identity == record.identity
            }.map(\.pid))
            guard !ours.isEmpty else { continue }
            // Parents fork before their children: walk candidates oldest first so a chain is adopted in one pass.
            let candidates = Set(ours.flatMap { table.descendants(of: $0) })
                .subtracting(journaledPIDs)
                .compactMap { table[$0] }
                .filter { !$0.isZombie && $0.isOwned(by: uid) && $0.identity.startDate >= began }
                .sorted { ($0.startSec, $0.startUsec, $0.pid) < ($1.startSec, $1.startUsec, $1.pid) }
            var records: [PauseJournalRecord] = []
            for entry in candidates where ours.contains(entry.ppid) {
                guard let identity = probe.enrich(entry.identity), signaller.isDarwinBackground(identity) == true,
                      let record = PauseJournalRecord(identity: identity, path: probe.executablePath(of: entry.pid),
                                                      action: .darwinBackground) else { continue }
                records.append(record)
                ours.insert(entry.pid)
            }
            guard !records.isEmpty else { continue }
            do {
                try journal.update(header: { snapshot }) { j in
                    guard let index = j.apps.firstIndex(where: { $0.appPid == app.appPid }) else { return }
                    let existing = Set(j.apps[index].members)
                    j.apps[index].members.append(contentsOf: records.filter { !existing.contains($0) })
                }
                adopted += records.count
                logger.notice("\(records.count) process(es) forked by throttled \(app.name ?? "pid \(app.appPid)") inherited the throttle; journaled to be restored")
            } catch {
                logger.error("could not journal inherited throttles of \(app.name ?? "pid \(app.appPid)"): \(error)")
            }
        }
        if adopted > 0 { publishCrashBuffer() }
        return adopted
    }
}
