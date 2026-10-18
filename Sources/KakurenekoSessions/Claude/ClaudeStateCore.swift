import KakurenekoKit
import Foundation

/// The Claude T2 reader: records + liveness + transcript tails + the last `claude agents --json --all` result, and
/// the broadcaster every snapshot goes out on. An actor, so all file and subprocess I/O runs here and never on the
/// caller's executor; building and yielding a snapshot happen in one actor turn, so snapshots go out in order.
/// Read-only: nothing under the Claude config dir is ever written, and `*.key` files are never opened.
actor ClaudeStateCore {
    /// Fan-out of full snapshots (replays the latest to new subscribers).
    nonisolated let broadcaster = AsyncBroadcaster<ClaudeStateSnapshot>(replayLatest: true)

    /// What a refresh found beyond the snapshot itself.
    struct RefreshOutcome: Sendable {
        var emitted: Bool
        /// A record went busy/waiting → idle/shell: re-read transcript tails shortly (turn_duration lags the record).
        var tailRereadWanted: Bool
        /// A record could not be decoded (caught mid-rewrite): read again soon.
        var retryWanted: Bool
    }

    private struct CachedRecord {
        var stamp: FileStamp
        var record: ClaudeSessionRecord
    }

    private struct CachedTranscript {
        var stamp: FileStamp
        var summary: TranscriptSummary
    }

    private enum CLIResolution {
        case unknown
        case found(String)
        case missing(retryAt: Date)
    }

    private let paths: Paths
    private let subprocess: any SubprocessRunning
    private let processes: any ProcessLookup
    private let files: any ClaudeFileAccess
    private let clock: any KakurenekoClock
    private let logger: KakurenekoLogger

    private var records: [String: CachedRecord] = [:]
    private var transcripts: [String: CachedTranscript] = [:]
    private var transcriptPaths: [String: String] = [:]
    private var transcriptMisses: [String: Date] = [:]
    private var agents: [ClaudeAgentsEntry]?
    private var agentsPolledAt: Date?
    private(set) var lastPollAt: Date?
    private var cli: CLIResolution = .unknown
    private var lastEmitted: ClaudeStateSnapshot?
    /// Record file name → status at the previous build (busy → idle detection).
    private var previousStatuses: [String: String] = [:]
    /// Record file name → stamp at the previous build (`nil` = directory unreadable).
    private var previousSignature: [String: FileStamp]?
    private var directoryWasReadable: Bool?
    /// Record file name → stamp of content that failed to decode (one retry per distinct stamp, never a loop).
    private var undecodableStamps: [String: FileStamp] = [:]

    /// A transcript that does not exist yet (new session) is looked up again after this long.
    static let transcriptMissRetry: TimeInterval = 30

    init(paths: Paths, subprocess: any SubprocessRunning, processes: any ProcessLookup, files: any ClaudeFileAccess,
         clock: any KakurenekoClock, logger: KakurenekoLogger) {
        self.paths = paths
        self.subprocess = subprocess
        self.processes = processes
        self.files = files
        self.clock = clock
        self.logger = logger
    }

    // MARK: - Snapshots

    /// Reads everything now (records + liveness + titles) without polling the CLI and without emitting. Leaves the
    /// change-detection baselines alone, so a change it happens to see is still detected (and emitted) by the next
    /// sweep or debounced refresh.
    func snapshot() -> ClaudeStateSnapshot {
        build(now: clock.now(), commit: false).snapshot
    }

    /// Reads everything and emits the snapshot when it differs from the last one emitted (or when `force`).
    func refresh(reason: String, force: Bool) -> RefreshOutcome {
        let built = build(now: clock.now(), commit: true)
        var emitted = false
        if force || !Self.sameContent(built.snapshot, lastEmitted) {
            lastEmitted = built.snapshot
            broadcaster.yield(built.snapshot)
            emitted = true
            logger.debug("claude snapshot (\(reason)): \(built.snapshot.sessions.count) records, "
                + "\(built.snapshot.agents.map { "\($0.count) agents" } ?? "no agents"), "
                + "\(built.snapshot.ignoredIdentities.count) ignored")
        }
        return RefreshOutcome(emitted: emitted, tailRereadWanted: built.statusDropped, retryWanted: built.undecodable)
    }

    /// Polls `claude agents --json --all`, then emits a full snapshot (always).
    func pollAndRefresh() async -> RefreshOutcome {
        await poll()
        return refresh(reason: "poll", force: true)
    }

    /// True when the set of record files or any record's size/mtime changed since the last build (mtime sweep).
    func recordFilesChanged() -> Bool {
        signature() != previousSignature
    }

    /// Snapshot equality ignoring `takenAt`.
    static func sameContent(_ a: ClaudeStateSnapshot, _ b: ClaudeStateSnapshot?) -> Bool {
        guard var b else { return false }
        b.takenAt = a.takenAt
        return a == b
    }

    // MARK: - Reading

    private func signature() -> [String: FileStamp]? {
        let directory = paths.claudeSessionsDirectory
        guard let names = files.listDirectory(directory) else { return nil }
        var result: [String: FileStamp] = [:]
        for name in names where ClaudeSessionRecord.isRecordFileName(name) {
            if let stamp = files.stamp(directory.appending(path: name, directoryHint: .notDirectory)) { result[name] = stamp }
        }
        return result
    }

    /// Reads `sessions/` (+ liveness, transcripts) into a snapshot.
    /// - Parameter commit: update the change-detection baselines (previous signature and statuses, retried
    ///   undecodable stamps). Only refreshes commit; `snapshot()` must not consume an edge it does not emit.
    private func build(now: Date, commit: Bool) -> (snapshot: ClaudeStateSnapshot, statusDropped: Bool, undecodable: Bool) {
        let directory = paths.claudeSessionsDirectory
        guard let names = files.listDirectory(directory) else {
            if commit {
                if directoryWasReadable != false { logger.info("claude sessions directory not readable (no T2)") }
                directoryWasReadable = false
                previousSignature = nil
                previousStatuses = [:]
                records = [:]
            }
            return (ClaudeStateSnapshot(takenAt: now, sessions: [], agents: agents, agentsPolledAt: agentsPolledAt,
                                        sessionsDirectoryReadable: false, ignoredIdentities: []), false, false)
        }
        if commit {
            if directoryWasReadable != true { logger.info("claude sessions directory readable") }
            directoryWasReadable = true
        }

        var observations: [ClaudeSessionObservation] = []
        var ignored = Set<ProcessIdentity>()
        var signature: [String: FileStamp] = [:]
        var statuses: [String: String] = [:]
        var statusDropped = false
        var undecodable = false

        for name in names.sorted() where ClaudeSessionRecord.isRecordFileName(name) {
            let url = directory.appending(path: name, directoryHint: .notDirectory)
            guard let stamp = files.stamp(url), stamp.isRegularFile else { continue }
            signature[name] = stamp
            let record: ClaudeSessionRecord
            // When the reported content was written (a torn read reports the previous content and its time).
            var contentModified = stamp.modified
            if let cached = records[name], cached.stamp == stamp {
                record = cached.record
            } else if let data = files.readFile(url, maxBytes: ClaudeRecords.maxRecordBytes),
                      let decoded = ClaudeSessionRecord.decode(data) {
                record = ClaudeRecords.capped(decoded)
                records[name] = CachedRecord(stamp: stamp, record: record)
            } else {
                // Caught between truncate and write of an in-place rewrite (or garbage): keep the last good content
                // and ask for one more read of this exact file state.
                if undecodableStamps[name] != stamp {
                    if commit { undecodableStamps[name] = stamp }
                    undecodable = true
                }
                guard let cached = records[name] else { continue }
                record = cached.record
                contentModified = cached.stamp.modified
            }

            let identity = ClaudeRecords.verifiedIdentity(of: record, lookup: processes)
            if record.isIgnorable {
                if let identity { ignored.insert(identity) }
                continue
            }
            if let status = record.status {
                statuses[name] = status
                let before = previousStatuses[name]
                if (before == "busy" || before == "waiting"), status == "idle" || status == "shell" { statusDropped = true }
            }
            observations.append(observation(for: record, identity: identity, fileModifiedAt: contentModified, now: now))
        }
        records = records.filter { signature[$0.key] != nil }
        if commit {
            undecodableStamps = undecodableStamps.filter { signature[$0.key] != nil }
            previousSignature = signature
            previousStatuses = statuses
        }

        let snapshot = ClaudeStateSnapshot(
            takenAt: now,
            sessions: observations.sorted { $0.record.pid < $1.record.pid },
            agents: agents,
            agentsPolledAt: agentsPolledAt,
            sessionsDirectoryReadable: true,
            ignoredIdentities: ignored.sorted { ($0.pid, $0.startSec, $0.startUsec) < ($1.pid, $1.startSec, $1.startUsec) })
        return (snapshot, statusDropped, undecodable)
    }

    private func observation(for record: ClaudeSessionRecord, identity: ProcessIdentity?, fileModifiedAt: Date,
                             now: Date) -> ClaudeSessionObservation {
        var observation = ClaudeSessionObservation(record: record, identity: identity, fileModifiedAt: fileModifiedAt)
        let humanName = record.humanName.map { TextSanitizer.sanitize($0) }
        observation.title = humanName.flatMap { $0.isEmpty ? nil : $0 }
        // Transcripts only matter for live sessions (a dead record just ends its session).
        guard identity != nil, let sessionId = record.sessionId, !sessionId.isEmpty,
              let found = transcript(sessionId: sessionId, launchCwd: record.cwd, now: now) else {
            return observation
        }
        let (path, summary) = found
        observation.transcriptPath = path
        if let title = summary.title.map({ TextSanitizer.sanitize($0) }), !title.isEmpty { observation.title = title }
        observation.currentCwd = summary.currentCwd
        observation.lastAssistantPreview = summary.lastAssistantPreview
        observation.lastTurnCompletedAt = summary.turnCompletedAt
        observation.lastTurnDurationMs = summary.turnDurationMs
        observation.lastTurnPendingBackground = summary.turnPendingBackground
        return observation
    }

    /// `projects/*/<sessionId>.jsonl`, summarized from its tail (cached by size + mtime).
    private func transcript(sessionId: String, launchCwd: String?, now: Date) -> (String, TranscriptSummary)? {
        guard let path = transcriptPath(sessionId: sessionId, launchCwd: launchCwd, now: now) else { return nil }
        let url = URL(filePath: path, directoryHint: .notDirectory)
        guard let stamp = files.stamp(url), stamp.isRegularFile else {
            transcriptPaths[sessionId] = nil
            transcripts[path] = nil
            return nil
        }
        if let cached = transcripts[path], cached.stamp == stamp { return (path, cached.summary) }
        guard let tail = files.readTail(url, maxBytes: TranscriptTail.maxBytes) else { return nil }
        var summary = TranscriptTail.summarize(tail.data, startsAtFileStart: tail.offset == 0)
        if let older = transcripts[path], stamp.size >= older.stamp.size {
            summary = summary.carryingTitles(from: older.summary)
        }
        transcripts[path] = CachedTranscript(stamp: stamp, summary: summary)
        return (path, summary)
    }

    private func transcriptPath(sessionId: String, launchCwd: String?, now: Date) -> String? {
        let fileName = sessionId + ".jsonl"
        guard ClaudeRecords.isSafePathComponent(fileName) else { return nil }
        if let known = transcriptPaths[sessionId], files.stamp(URL(filePath: known))?.isRegularFile == true {
            return known
        }
        if let miss = transcriptMisses[sessionId], now.timeIntervalSince(miss) < Self.transcriptMissRetry { return nil }
        let projects = paths.claudeProjectsDirectory
        var candidates: [String] = []
        if let cwd = launchCwd, !cwd.isEmpty { candidates.append(ClaudeRecords.projectSlug(forCwd: cwd)) }
        candidates.append(contentsOf: (files.listDirectory(projects) ?? []).sorted())
        for directory in candidates where ClaudeRecords.isSafePathComponent(directory) {
            let url = projects.appending(path: directory, directoryHint: .isDirectory)
                .appending(path: fileName, directoryHint: .notDirectory)
            if files.stamp(url)?.isRegularFile == true {
                let path = url.path(percentEncoded: false)
                transcriptPaths[sessionId] = path
                transcriptMisses[sessionId] = nil
                return path
            }
        }
        transcriptMisses[sessionId] = now
        if transcriptMisses.count > 512 { transcriptMisses = transcriptMisses.filter { now.timeIntervalSince($0.value) < Self.transcriptMissRetry } }
        return nil
    }

    // MARK: - Polling

    private func poll() async {
        let now = clock.now()
        lastPollAt = now
        guard let executable = await resolveCLI(now: now) else {
            agents = nil
            agentsPolledAt = nil
            return
        }
        let request = ClaudeCLI.agentsRequest(executable: executable, paths: paths)
        // Stamped BEFORE the CLI runs: the CLI reads the records at some point during its run, so only a record
        // written before the run started is certainly reflected in its output. Stamping on return made a record
        // rewritten while the CLI ran look older than the poll, and the stale entry won the T2 merge.
        let started = clock.now()
        do {
            let result = try await subprocess.run(request)
            if let parsed = ClaudeCLI.parseAgents(result) {
                agents = parsed
                agentsPolledAt = started
            } else {
                logger.warning("claude agents --json failed (exit \(result.exitCode)\(result.timedOut ? ", timed out" : ""))")
                agents = nil
                agentsPolledAt = nil
            }
        } catch {
            logger.warning("claude agents --json could not run: \(error)")
            agents = nil
            agentsPolledAt = nil
            cli = .unknown
        }
    }

    /// `paths.claudeCLICandidate` when executable, else one `/bin/zsh -lc 'command -v claude'` (retried at most every
    /// `ClaudeCLI.lookupRetryInterval`).
    private func resolveCLI(now: Date) async -> String? {
        switch cli {
        case .found(let path):
            if files.isExecutableFile(URL(filePath: path)) { return path }
            cli = .unknown
        case .missing(let retryAt):
            if now < retryAt { return nil }
        case .unknown:
            break
        }
        let candidate = paths.claudeCLICandidate
        if files.isExecutableFile(candidate) {
            let path = candidate.path(percentEncoded: false)
            cli = .found(path)
            return path
        }
        if let result = try? await subprocess.run(ClaudeCLI.lookupRequest(paths: paths)),
           let path = ClaudeCLI.parseLookup(result), files.isExecutableFile(URL(filePath: path)) {
            logger.info("claude CLI resolved via login shell")
            cli = .found(path)
            return path
        }
        logger.info("claude CLI not found; agents --json polling paused")
        cli = .missing(retryAt: now.addingTimeInterval(ClaudeCLI.lookupRetryInterval))
        return nil
    }
}
