import Darwin
import KakurenekoKit
import Foundation

/// What the expensive per-process reads produced for one identity. Memory only: argv can contain prompt text and is
/// never logged or persisted; the environment holds only the four allow-listed variables.
struct CachedProcess: Sendable {
    /// `p_comm` at read time. A change means the process exec'd a new image (pid and start time survive `exec`),
    /// so the entry is re-read.
    var comm: String
    var descriptor: ProcessDescriptor
    var match: AgentMatch?
    /// Scan time at which this identity was first seen.
    var firstSeen: Date
    /// Read while the process was younger than `ScanEngine.youngProcessAge` (possibly between `fork` and `exec`):
    /// read once more on the next scan.
    var rereadPending: Bool
    /// `caffeinate` by executable basename or argv[0] (E2 exclusion, E6 attribution).
    var isCaffeinate: Bool
    /// Flavor-17 enrichment, attempted once per matched agent.
    var uniqueID: UInt64?
    var pidVersion: UInt32?
    var enrichmentAttempted = false
}

/// Per-agent-tree evidence history (brief §5.4), keyed by the agent's identity.
struct TreeEvidenceState: Sendable {
    var cpu = TreeCPUAccumulator()
    var churn = DescendantChurnTracker()
    var sockets = ModelSocketTracker()
}

/// Inputs of one scan that do not come from the process probe.
struct ScanContext: Sendable {
    var matcher: any AgentSignatureMatching
    /// E4 destination set at scan time.
    var endpoints: ModelEndpointSet
    /// E3 write times per agent identity.
    var storeWrites: SessionStoreWriteLog
    var bundles: BundleIdentifierCache
}

/// One T3 scan (ARCHITECTURE §9.2 `sample(now:)`): a cheap pass over every pid, argv/path only for identities not
/// seen before, signature matching, then — for matched agents only — ancestry, host app, descendants, cwd, tty and
/// evidence E1–E6.
///
/// A value type so the whole pipeline can be exercised over synthetic process tables; `ProcessScanner` keeps it in
/// a `Mutex` (which also serialises scans).
struct ScanEngine: Sendable {
    /// Processes younger than this at their first read may still be between `fork` and `exec`.
    static let youngProcessAge: TimeInterval = 1

    private(set) var cache: [ProcessIdentity: CachedProcess] = [:]
    private(set) var trees: [ProcessIdentity: TreeEvidenceState] = [:]
    /// `proc_pidpath` of other users' ancestors (root `login`, `sshd`), by identity.
    private var foreignPaths: [ProcessIdentity: String?] = [:]
    /// Diagnostics: argv/path reads performed by the last scan.
    private(set) var lastScanReads = 0
    /// Diagnostics: CPU time (user + system) the last scan's thread spent, in ms — its intrinsic cost, which unlike
    /// `scanMilliseconds` (wall time) does not grow while the machine is busy with other work.
    private(set) var lastScanCPUMilliseconds = 0.0

    // MARK: Scan

    mutating func scan(probe: any ProcessProbing, context: ScanContext, now: Date) -> ProcessSnapshot {
        let started = ContinuousClock.now
        let cpuStarted = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        defer { lastScanCPUMilliseconds = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) &- cpuStarted) / 1e6 }
        guard let table = probe.readTable() else {
            return ProcessSnapshot(takenAt: now, agents: [], scannedProcessCount: 0, scanMilliseconds: Self.milliseconds(since: started))
        }
        let rows = table.sameUIDRows
        refreshCache(rows: rows, probe: probe, matcher: context.matcher, now: now)

        let agentRows = rows.filter { row in row.identity.flatMap { cache[$0]?.match } != nil }.sorted { $0.pid < $1.pid }
        var agents: [AgentProcess] = []
        var liveForeign: Set<ProcessIdentity> = []
        if !agentRows.isEmpty {
            let assertions = probe.powerAssertions() ?? [:]
            let caffeinateParents = caffeinateParents(rows: rows)
            for row in agentRows {
                guard let identity = row.identity, let process = agentProcess(
                    row: row, identity: identity, table: table, probe: probe, context: context,
                    assertions: assertions, caffeinateParents: caffeinateParents, liveForeign: &liveForeign, now: now)
                else { continue }
                agents.append(process)
            }
        }
        let liveAgents = Set(agents.map(\.identity))
        trees = trees.filter { liveAgents.contains($0.key) }
        foreignPaths = foreignPaths.filter { liveForeign.contains($0.key) }
        return ProcessSnapshot(
            takenAt: now, agents: agents, scannedProcessCount: rows.count, scanMilliseconds: Self.milliseconds(since: started))
    }

    /// Reads path + argv for identities not cached yet (or exec'd / young at their first read), matches them, and
    /// forgets identities that are gone.
    private mutating func refreshCache(rows: [ProcessRow], probe: any ProcessProbing, matcher: any AgentSignatureMatching, now: Date) {
        var reader: ProcArgsReader?
        var live: Set<ProcessIdentity> = []
        live.reserveCapacity(rows.count)
        var reads = 0
        let wallNow = probe.wallClockNow()
        for row in rows {
            guard let identity = row.identity else { continue }
            live.insert(identity)
            let existing = cache[identity]
            if let existing, existing.comm == row.comm, !existing.rereadPending { continue }
            reads += 1
            if reader == nil { reader = ProcArgsReader() }
            let arguments = probe.arguments(of: row.pid, reader: &reader!)
            // `proc_pidpath` is nil after an auto-update replaced the binary: fall back to the exec path.
            let path = probe.executablePath(of: row.pid) ?? arguments?.executablePath
            let descriptor = ProcessDescriptor(
                executablePath: path,
                argv: arguments?.argv ?? [],
                comm: row.comm.isEmpty ? nil : row.comm,
                environment: arguments?.environment ?? [:]
            )
            let young = wallNow.timeIntervalSince(identity.startDate) < Self.youngProcessAge
            cache[identity] = CachedProcess(
                comm: row.comm,
                descriptor: descriptor,
                match: matcher.match(descriptor),
                firstSeen: existing?.firstSeen ?? now,
                rereadPending: young && existing == nil,
                isCaffeinate: Self.isCaffeinate(descriptor, comm: row.comm),
                uniqueID: existing?.uniqueID,
                pidVersion: existing?.pidVersion,
                enrichmentAttempted: existing?.enrichmentAttempted ?? false
            )
        }
        if cache.count != live.count { cache = cache.filter { live.contains($0.key) } }
        lastScanReads = reads
    }

    /// `caffeinate` pid → its parent pid (E6: a caffeinate whose parent is the agent counts as the agent's).
    private func caffeinateParents(rows: [ProcessRow]) -> [Int32: Int32] {
        var result: [Int32: Int32] = [:]
        for row in rows {
            guard let identity = row.identity, cache[identity]?.isCaffeinate == true else { continue }
            result[row.pid] = row.ppid
        }
        return result
    }

    // MARK: One agent

    private mutating func agentProcess(
        row: ProcessRow,
        identity: ProcessIdentity,
        table: ProcessTable,
        probe: any ProcessProbing,
        context: ScanContext,
        assertions: [Int32: [PowerAssertionInfo]],
        caffeinateParents: [Int32: Int32],
        liveForeign: inout Set<ProcessIdentity>,
        now: Date
    ) -> AgentProcess? {
        guard var entry = cache[identity], let match = entry.match else { return nil }
        if !entry.enrichmentAttempted {
            entry.enrichmentAttempted = true
            // Re-read the identity afterwards: the flavor-17 values must belong to this very process.
            if let unique = probe.uniqueIdentifier(of: row.pid), probe.identity(of: row.pid) == identity {
                entry.uniqueID = unique.uniqueID
                entry.pidVersion = unique.pidVersion
            }
            cache[identity] = entry
        }
        var enriched = identity
        enriched.uniqueID = entry.uniqueID
        enriched.pidVersion = entry.pidVersion

        let descendants = table.descendants(of: row.pid).compactMap { table[$0]?.identity }
        let ancestors = ancestorInfos(of: row.pid, table: table, probe: probe, bundles: context.bundles, liveForeign: &liveForeign)
        let host = HostAppResolver.host(environment: entry.descriptor.environment, ancestors: ancestors, bundles: context.bundles)
        let terminal = row.tdev.flatMap { probe.terminal(device: $0) }
        let evidence = treeEvidence(
            agent: identity, row: row, descendants: descendants, table: table, probe: probe, context: context,
            assertions: assertions, caffeinateParents: caffeinateParents, ttyModified: terminal?.modified, now: now)
        let descriptor = entry.descriptor
        return AgentProcess(
            identity: enriched,
            agent: match.agent,
            executablePath: descriptor.executablePath,
            argv0: descriptor.argv.first ?? row.comm,
            arguments: descriptor.argv,
            cwd: probe.workingDirectory(of: row.pid),
            ttyDevice: row.tdev,
            ttyName: terminal?.name,
            ppid: row.ppid,
            ancestors: ancestors,
            hostApp: host,
            descendants: descendants,
            isInfrastructure: match.isInfrastructure,
            isIDEHost: match.isIDEHost,
            evidence: evidence,
            firstSeen: entry.firstSeen
        )
    }

    /// Ancestors nearest first, up to launchd (excluded). Other users' rows (root `login`) get their identity from
    /// `KERN_PROC_PID`; an ancestor that vanished mid-walk is skipped.
    private mutating func ancestorInfos(
        of pid: Int32,
        table: ProcessTable,
        probe: any ProcessProbing,
        bundles: BundleIdentifierCache,
        liveForeign: inout Set<ProcessIdentity>
    ) -> [AncestorInfo] {
        var result: [AncestorInfo] = []
        for ancestorPID in table.ancestors(of: pid) {
            guard let row = table[ancestorPID] else { break }
            let identity: ProcessIdentity
            let path: String?
            if let own = row.identity {
                identity = own
                path = cache[own]?.descriptor.executablePath
            } else {
                guard let foreign = probe.identity(of: ancestorPID) else { continue }
                identity = foreign
                if let known = foreignPaths[foreign] {
                    path = known
                } else {
                    path = probe.executablePath(of: ancestorPID)
                    foreignPaths[foreign] = .some(path)
                }
                liveForeign.insert(foreign)
            }
            let bundle = path.flatMap(AppBundlePaths.bundle(ofMainExecutable:))
            result.append(AncestorInfo(
                identity: identity,
                comm: row.comm.isEmpty ? nil : row.comm,
                executablePath: path,
                bundleID: bundle.flatMap(bundles.bundleIdentifier(ofBundle:)),
                isApp: path.map(AppBundlePaths.isAppMainExecutable) ?? false
            ))
        }
        return result
    }

    // MARK: Evidence

    private mutating func treeEvidence(
        agent: ProcessIdentity,
        row: ProcessRow,
        descendants: [ProcessIdentity],
        table: ProcessTable,
        probe: any ProcessProbing,
        context: ScanContext,
        assertions: [Int32: [PowerAssertionInfo]],
        caffeinateParents: [Int32: Int32],
        ttyModified: Date?,
        now: Date
    ) -> EvidenceSample {
        var state = trees[agent] ?? TreeEvidenceState()
        let members = [agent] + descendants

        // E1: cumulative tree CPU (rusage ticks × timebase) and its trailing-window average.
        var cpu: [(identity: ProcessIdentity, cpuSeconds: Double)] = []
        cpu.reserveCapacity(members.count)
        for member in members {
            if let seconds = probe.cpuSeconds(of: member.pid) { cpu.append((member, seconds)) }
        }
        state.cpu.record(members: cpu, now: now)

        // E2: new descendants, minus caffeinate, infrastructure and keep-alive respawns.
        let infos = descendants.map { descendant -> DescendantInfo in
            let cached = cache[descendant]
            let comm = table[descendant.pid]?.comm ?? ""
            return DescendantInfo(
                identity: descendant,
                argvKey: DescendantInfo.argvKey(
                    executablePath: cached?.descriptor.executablePath, argv: cached?.descriptor.argv ?? [], comm: comm),
                isCaffeinate: cached?.isCaffeinate ?? (comm == "caffeinate"),
                isInfrastructure: cached?.match?.isInfrastructure == true
            )
        }
        state.churn.update(current: infos, now: now)

        // E4: ESTABLISHED TCP connections of the tree to the model-API set.
        var connections: Set<String> = []
        for member in members {
            guard case .entries(let entries) = probe.fileDescriptors(of: member.pid, kinds: .sockets) else { continue }
            for case .tcp(let tcp) in entries where tcp.isEstablished {
                guard let remote = tcp.remote, context.endpoints.contains(remote) else { continue }
                connections.insert("\(member.pid)|" + tcp.connectionKey)
            }
        }
        state.sockets.update(connections: connections, now: now)
        trees[agent] = state

        // E6: assertions of the agent or of a caffeinate whose parent is the agent.
        let assertionNames = AssertionAttribution.names(
            forAgent: row.pid, assertionsByPID: assertions, caffeinateParents: caffeinateParents)

        return EvidenceInputs(
            cpu: state.cpu,
            churn: state.churn,
            sockets: state.sockets,
            lastStoreWrite: context.storeWrites.lastWrite(for: agent),
            ttyModified: ttyModified,
            assertionNames: assertionNames
        ).sample(at: now)
    }

    // MARK: Topology support

    /// Cached descriptors of `identities` (topology: executable paths and helper argv without re-reading).
    func descriptors(for identities: some Sequence<ProcessIdentity>) -> [ProcessIdentity: ProcessDescriptor] {
        var result: [ProcessIdentity: ProcessDescriptor] = [:]
        for identity in identities { if let entry = cache[identity] { result[identity] = entry.descriptor } }
        return result
    }

    // MARK: Helpers

    static func isCaffeinate(_ descriptor: ProcessDescriptor, comm: String) -> Bool {
        if descriptor.executableBasename == "caffeinate" || descriptor.argv0Basename == "caffeinate" { return true }
        return descriptor.argv.isEmpty && descriptor.executablePath == nil && comm == "caffeinate"
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return elapsed.timeInterval * 1000
    }
}
