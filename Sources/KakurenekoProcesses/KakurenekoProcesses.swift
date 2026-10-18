// KakurenekoProcesses — libproc process registry (T3), agent signature table, evidence sampler E1–E6,
// pty map, process tree/ancestry, AgentTopology for pausing.
// OWNER: agent "processes". Spec card: docs/ARCHITECTURE.md §9.2. Brief §5.3, §5.4, §6.3 (P-A…P-E
// inputs); R08 §7 (verified libproc patterns), R06 §3.2 (pty map), R04 §7.5 (long-tail signatures).
//
// Public surface (binding): `AgentMatcher`, `LiveProcessLookup`, `ProcessScanner`. Everything else is internal.
//
// Files:
//   AgentMatcher.swift        signature table (brief §5.3 + R04 §7.5)
//   LibProc.swift             read-only libproc/sysctl wrappers, Mach timebase
//   ProcArgs.swift            KERN_PROCARGS2 parser (argv + env allow-list only) and reused-buffer reader
//   ProcessTable.swift        point-in-time process table (parent/child links, ancestry, descendants)
//   ProcessProbe.swift        the system-read seam (`ProcessProbing`) and its live implementation
//   AppBundles.swift          .app path analysis, bundle-id cache, host-app derivation
//   Evidence.swift            E1–E6 as pure functions/trackers over synthetic or live histories
//   ModelEndpoints.swift      model-API destination set for E4 (CIDRs + periodic resolution)
//   SessionStoreWatcher.swift E3 write log + FSEvents stream over the hinted session stores
//   ScanEngine.swift          one scan: cache by identity, match, ancestry, host app, evidence
//   TopologyBuilder.swift     AgentTopology (pty masters, ancestors, launched apps, IPC peers, helpers)
//   TopologyCollector.swift   gathers the topology inputs from the live system
//   ProcessScanner.swift      `ProcessSampling` implementation tying it together
//
// Strictly read-only: nothing in this module signals, renices or otherwise mutates any process.

import Darwin
import KakurenekoKit
import Foundation

/// Live pid → identity lookups via `sysctl(KERN_PROC_PID)`.
///
/// The `(pid, startSec, startUsec)` tuple is exactly `KernelProcessLookup`'s (ARCHITECTURE §8 invariant: the hook,
/// the scanner, this lookup and the pause journal all produce the same tuple). As an optional enrichment it fills
/// `uniqueID`/`pidVersion` from the `PROC_PIDUNIQIDENTIFIERINFO` flavor when that read succeeds and the process
/// provably did not change in between (the identity is re-read afterwards); these never participate in equality.
public struct LiveProcessLookup: ProcessLookup {
    private let kernel = KernelProcessLookup()

    /// Binding signature.
    public init() {}

    public func identity(of pid: Int32) -> ProcessIdentity? {
        guard var identity = kernel.identity(of: pid) else { return nil }
        if let unique = LibProc.uniqueIdentifier(pid), kernel.identity(of: pid) == identity {
            identity.uniqueID = unique.uniqueID
            identity.pidVersion = unique.pidVersion
        }
        return identity
    }

    /// Parent pid (`kp_eproc.e_ppid`), nil when gone.
    func parentPID(of pid: Int32) -> Int32? { kernel.parentPID(of: pid) }
}
