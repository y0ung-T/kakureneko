import CoreServices
import KakurenekoKit
import Foundation
import Synchronization

/// Gathers `TopologyInput` from the live system for `ProcessSampling.topology(for:now:)` (R06 §3.2–3.3; ~60 ms for
/// ~400 same-uid processes). Strictly read-only.
///
/// * A fresh process table (agents that exited since the snapshot are dropped; new descendants are included).
/// * Executable paths and helper argv of agent-tree members, from the scan cache where possible.
/// * File descriptors of every same-uid process (pty masters, sockets, pipes) — the pty-master holders and IPC peers
///   are by definition outside the agent trees — plus other users' tree members (failures there make the result
///   incomplete).
/// * A hard deadline: when it passes, collection stops and the topology is marked incomplete.
struct TopologyCollector: Sendable {
    /// Hard cap on descriptor collection (the expected cost is ~60 ms).
    var deadline: Duration = .seconds(1)

    /// nil when the process table cannot be read (the caller then falls back to `TopologyBuilder.fallback`).
    func collect(
        snapshot: ProcessSnapshot,
        now: Date,
        probe: any ProcessProbing,
        cachedDescriptors: ([ProcessIdentity]) -> [ProcessIdentity: ProcessDescriptor]
    ) -> TopologyInput? {
        let started = ContinuousClock.now
        guard let table = probe.readTable() else { return nil }

        var complete = true
        let liveAgents = snapshot.agents.map(\.identity).filter { table[$0.pid]?.identity == $0 }
        var treePIDs = Set(liveAgents.map(\.pid))
        for agent in liveAgents { treePIDs.formUnion(table.descendants(of: agent.pid)) }

        // Identities of other users' tree members (`sudo` children, …).
        var extraIdentities: [Int32: ProcessIdentity] = [:]
        for pid in treePIDs where table[pid]?.identity == nil {
            if let identity = probe.identity(of: pid) { extraIdentities[pid] = identity }
        }

        // Paths and helper argv of tree members.
        let treeIdentities = treePIDs.compactMap { table[$0]?.identity }
        let cached = cachedDescriptors(treeIdentities)
        var executablePaths: [Int32: String] = [:]
        var arguments: [Int32: [String]] = [:]
        var reader: ProcArgsReader?
        for pid in treePIDs.sorted() {
            let descriptor = table[pid]?.identity.flatMap { cached[$0] }
            if let path = descriptor?.executablePath ?? probe.executablePath(of: pid) { executablePaths[pid] = path }
            let comm = table[pid]?.comm ?? ""
            var argv = descriptor?.argv ?? []
            let names = [executablePaths[pid].map(AgentSignatureRules.basename), argv.first.map(AgentSignatureRules.basename), comm]
                .compactMap { $0 }
            let isCandidate = names.contains { AutomationHelperTargets.tools.contains($0) || $0 == "xcrun" }
            guard isCandidate else { continue }
            if argv.isEmpty {
                if reader == nil { reader = ProcArgsReader() }
                argv = probe.arguments(of: pid, reader: &reader!)?.argv ?? []
            }
            arguments[pid] = argv
        }

        // Descriptors: every same-uid process + other users' tree members.
        var fileDescriptors: [Int32: [FDEntry]] = [:]
        var targets = table.sameUIDRows.map(\.pid)
        targets.append(contentsOf: treePIDs.filter { table[$0]?.uid != table.currentUID })
        for pid in targets.sorted() {
            if ContinuousClock.now - started > deadline {
                complete = false
                break
            }
            switch probe.fileDescriptors(of: pid, kinds: .all) {
            case .entries(let entries):
                if !entries.isEmpty { fileDescriptors[pid] = entries }
            case .gone:
                continue
            case .failed:
                complete = false
            }
        }

        return TopologyInput(
            builtAt: now,
            table: table,
            agents: liveAgents,
            extraIdentities: extraIdentities,
            executablePaths: executablePaths,
            arguments: arguments,
            fileDescriptors: fileDescriptors,
            probesComplete: complete
        )
    }
}

/// The default `https` handler (`open <url>` → likely the default browser), cached for 10 minutes.
final class DefaultBrowserResolver: Sendable {
    typealias Lookup = @Sendable () -> String?

    private struct Entry {
        var value: String?
        var resolvedAt: ContinuousClock.Instant
    }

    static let lifetime: Duration = .seconds(600)

    private let lookup: Lookup
    private let cache = Mutex<Entry?>(nil)

    init(lookup: @escaping Lookup) {
        self.lookup = lookup
    }

    func bundleID() -> String? {
        let now = ContinuousClock.now
        if let entry = cache.withLock({ $0 }), now - entry.resolvedAt < Self.lifetime { return entry.value }
        let value = lookup()
        cache.withLock { $0 = Entry(value: value, resolvedAt: now) }
        return value
    }

    /// LaunchServices: the application that opens `https://` URLs, then its bundle identifier (read-only).
    static func systemLookup(bundles: BundleIdentifierCache) -> Lookup {
        { @Sendable in
            guard let probe = URL(string: "https://example.com"),
                  let unmanaged = LSCopyDefaultApplicationURLForURL(probe as CFURL, .all, nil)
            else { return nil }
            let appURL = unmanaged.takeRetainedValue() as URL
            let path = appURL.path(percentEncoded: false)
            return bundles.bundleIdentifier(ofBundle: path.hasSuffix("/") ? String(path.dropLast()) : path)
        }
    }
}
