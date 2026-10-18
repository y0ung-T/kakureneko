import KakurenekoKit
import Foundation
import Synchronization

/// The T3 scanner + evidence sampler + topology builder (brief §5.3–5.4, §6.3; ARCHITECTURE §9.2).
///
/// Isolation: a `Sendable` final class. The scan state (identity → descriptor cache, per-tree evidence history) lives
/// in a `Mutex<ScanEngine>`, which also serialises scans. `sample` and `topology` are `@concurrent`: they are
/// syscall-heavy and must never run on the coordinator's (or the main) actor.
///
/// Strictly read-only: never signals, never renices, never writes anything.
public final class ProcessScanner: ProcessSampling {
    private let paths: Paths
    private let matcher: any AgentSignatureMatching
    private let clock: any KakurenekoClock
    private let logger: KakurenekoLogger
    private let probe: any ProcessProbing
    private let engine = Mutex(ScanEngine())
    private let lastScanCPU = Mutex(0.0)
    private let bundles: BundleIdentifierCache
    private let endpoints: ModelEndpointRegistry
    private let storeWatcher: SessionStoreWatcher
    private let collector: TopologyCollector
    private let builder: TopologyBuilder

    /// Binding signature.
    public convenience init(
        paths: Paths,
        matcher: AgentMatcher,
        clock: any KakurenekoClock = SystemClock(),
        logger: KakurenekoLogger = KakurenekoLogger(.processes)
    ) {
        self.init(
            paths: paths,
            signatureMatcher: matcher,
            clock: clock,
            logger: logger,
            probe: LiveProcessProbe(),
            resolver: ModelEndpointRegistry.systemResolver
        )
    }

    /// Full initializer (tests inject a synthetic probe, a fake DNS resolver and a fixed default browser).
    init(
        paths: Paths,
        signatureMatcher: any AgentSignatureMatching,
        clock: any KakurenekoClock,
        logger: KakurenekoLogger,
        probe: any ProcessProbing,
        resolver: @escaping HostResolver,
        bundles: BundleIdentifierCache = BundleIdentifierCache(),
        defaultBrowser: DefaultBrowserResolver.Lookup? = nil,
        topologyDeadline: Duration = .seconds(1),
        storeEventLatency: CFTimeInterval = 0.2
    ) {
        self.paths = paths
        self.matcher = signatureMatcher
        self.clock = clock
        self.logger = logger
        self.probe = probe
        self.bundles = bundles
        self.endpoints = ModelEndpointRegistry(resolver: resolver, clock: clock, logger: logger)
        self.storeWatcher = SessionStoreWatcher(
            log: SessionStoreWriteLog(), clock: clock, home: paths.home.path(percentEncoded: false), logger: logger,
            latency: storeEventLatency)
        self.collector = TopologyCollector(deadline: topologyDeadline)
        let browser = DefaultBrowserResolver(lookup: defaultBrowser ?? DefaultBrowserResolver.systemLookup(bundles: bundles))
        self.builder = TopologyBuilder(
            bundleIdentifier: { [bundles] path in bundles.bundleIdentifier(ofBundle: path) },
            defaultBrowserBundleID: { [browser] in browser.bundleID() }
        )
    }

    deinit {
        endpoints.stop()
        storeWatcher.stop()
    }

    // MARK: ProcessSampling

    /// Starts the E3 FSEvents stream over the hinted session stores and the 10-minute model-API resolution (E4).
    /// Idempotent.
    public func start() async {
        storeWatcher.start()
        endpoints.start()
        logger.info("process scanner started")
    }

    public func stop() async {
        endpoints.stop()
        storeWatcher.stop()
        logger.info("process scanner stopped")
    }

    @concurrent
    public func sample(now: Date) async -> ProcessSnapshot {
        let context = ScanContext(
            matcher: matcher, endpoints: endpoints.current, storeWrites: storeWatcher.log, bundles: bundles)
        let (snapshot, reads, cpu) = engine.withLock { engine in
            let snapshot = engine.scan(probe: probe, context: context, now: now)
            return (snapshot, engine.lastScanReads, engine.lastScanCPUMilliseconds)
        }
        lastScanCPU.withLock { $0 = cpu }
        logger.debug(
            "scan: \(snapshot.scannedProcessCount) processes, \(reads) new, \(snapshot.agents.count) agent(s), "
                + String(format: "%.1f ms", snapshot.scanMilliseconds))
        return snapshot
    }

    @concurrent
    public func topology(for snapshot: ProcessSnapshot, now: Date) async -> AgentTopology {
        let started = ContinuousClock.now
        guard let input = collector.collect(
            snapshot: snapshot, now: now, probe: probe,
            cachedDescriptors: { identities in engine.withLock { $0.descriptors(for: identities) } })
        else {
            logger.warning("topology: process table unavailable; reporting the snapshot's view as incomplete")
            return TopologyBuilder.fallback(snapshot: snapshot, now: now)
        }
        let topology = builder.build(input)
        let elapsed = (ContinuousClock.now - started).timeInterval * 1000
        logger.debug(
            "topology: \(topology.agentIdentities.count) agent(s), \(topology.descendantIdentities.count) descendant(s), "
                + "\(topology.ptyMasterHolderPIDs.count) pty holder(s), \(topology.ipcPeers.count) peer(s), "
                + "\(topology.automationHelpers.count) helper(s), complete=\(topology.isComplete), "
                + String(format: "%.1f ms", elapsed))
        return topology
    }

    @concurrent
    public func updateSessionStoreHints(_ hints: [SessionStoreHint]) async {
        storeWatcher.setHints(hints)
    }

    // MARK: Diagnostics (tests)

    /// The E3 write log (tests record writes directly).
    var storeWriteLog: SessionStoreWriteLog { storeWatcher.log }
    var isStoreWatcherRunning: Bool { storeWatcher.isRunning }
    var watchedStoreRoots: [String] { storeWatcher.watchedRoots }
    var endpointRefreshCount: Int { endpoints.refreshCount }
    var currentEndpoints: ModelEndpointSet { endpoints.current }
    var cachedIdentityCount: Int { engine.withLock { $0.cache.count } }
    /// CPU time of the last `sample()` in ms (see `ScanEngine.lastScanCPUMilliseconds`).
    var lastSampleCPUMilliseconds: Double { lastScanCPU.withLock { $0 } }
}
