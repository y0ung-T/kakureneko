import Darwin
import KakurenekoKit
import Foundation

/// The one thaw-a-journal-record routine, shared by `PauseManager` (launch recovery, thaw) and `kakureneko-guard`
/// (app died / hung).
///
/// A record is undone only when ALL of these hold (R06 §4.1): the journal's boot session UUID is the current one,
/// the live process at `pid` has the journaled start time, flavor 17 reports the journaled `p_uniqueid`, and a fresh
/// audit token has `val[7] == pidVersion`. Everything else is dropped — never a blanket SIGCONT.
struct PauseRecovery: Sendable {
    let signaller: any ProcessSignalling
    let processes: any ProcessLookup
    let probe: any SystemProbing

    enum RecordOutcome: Sendable, Equatable {
        /// SIGCONT / `setpriority(…, 0)` succeeded.
        case thawed
        /// Not thawable and never will be (other boot, gone, pid reused, identity changed): forget it.
        case dropped(String)
        /// The undo failed for another reason (e.g. EPERM): keep the record and retry later.
        case failed(String)
        /// `.terminate` records are not thawed here (relaunch is the caller's decision).
        case skipped
    }

    /// Verifies `record` against the live system (read-only).
    func verify(_ record: PauseJournalRecord, bootMatches: Bool) -> String? {
        guard bootMatches else { return "journal from another boot" }
        guard processes.identity(of: record.pid) == record.identity else { return "process gone or pid reused" }
        guard let fresh = probe.enrich(record.identity),
              fresh.uniqueID == record.uniqueID, fresh.pidVersion == record.pidVersion else {
            return "uniqueID / audit token pidversion changed"
        }
        return nil
    }

    /// Verifies and undoes one record.
    func thaw(_ record: PauseJournalRecord, bootMatches: Bool) -> RecordOutcome {
        guard record.action != .terminate else { return .skipped }
        if let problem = verify(record, bootMatches: bootMatches) { return .dropped(problem) }
        do {
            switch record.action {
            case .sigstop: try signaller.send(.cont, to: record.identity)
            case .darwinBackground: try signaller.setDarwinBackground(false, for: record.identity)
            case .terminate: return .skipped
            }
            return .thawed
        } catch SideEffectError.processGone {
            return .dropped("process gone")
        } catch SideEffectError.identityMismatch {
            return .dropped("identity changed")
        } catch {
            return .failed(String(describing: error))
        }
    }

    struct Summary: Sendable, Equatable {
        var thawed = 0
        var dropped = 0
        var failed = 0
        /// Records to keep (failed undo, plus `.terminate` / simulated ones when the caller asked to keep them).
        var remaining: [PauseJournalApp] = []
    }

    /// Thaws every real record of `journal`, apps in reverse journal order and members LIFO (helpers first, main
    /// last). Simulated apps and `.terminate` records are never signalled: they are dropped, or kept untouched when
    /// `keepUnsignalled` (hang recovery keeps them for the app to handle).
    func thawAll(_ journal: PauseJournal, keepUnsignalled: Bool, log: (String) -> Void) -> Summary {
        let currentBoot = probe.bootSessionUUID()
        let bootMatches = currentBoot != nil && currentBoot == journal.bootSessionUUID
        if !bootMatches, !journal.apps.isEmpty { log("journal boot session differs from the current one: dropping its records") }
        var summary = Summary()
        var remaining: [PauseJournalApp] = []
        for app in journal.apps.reversed() {
            if app.simulated {
                log("skipping simulated (dry-run) app \(app.name ?? app.bundleID ?? "pid \(app.appPid)")")
                if keepUnsignalled { remaining.append(app) } else { summary.dropped += app.members.count }
                continue
            }
            var kept: [PauseJournalRecord] = []
            for record in app.members.reversed() {
                switch thaw(record, bootMatches: bootMatches) {
                case .thawed:
                    summary.thawed += 1
                    log("thawed pid \(record.pid) (\(record.action.rawValue))")
                case .dropped(let why):
                    summary.dropped += 1
                    log("dropped pid \(record.pid): \(why)")
                case .failed(let why):
                    summary.failed += 1
                    kept.append(record)
                    log("could not thaw pid \(record.pid): \(why)")
                case .skipped:
                    if keepUnsignalled { kept.append(record) } else { summary.dropped += 1 }
                }
            }
            if !kept.isEmpty {
                var copy = app
                copy.members = app.members.filter(kept.contains)
                remaining.append(copy)
            }
        }
        summary.remaining = remaining.reversed()
        return summary
    }

    /// True when `journal` holds a record that a thaw would signal (real, non-`.terminate`).
    static func hasThawableRecords(_ journal: PauseJournal?) -> Bool {
        guard let journal else { return false }
        return journal.realApps.contains { app in app.members.contains { $0.action != .terminate } }
    }
}
