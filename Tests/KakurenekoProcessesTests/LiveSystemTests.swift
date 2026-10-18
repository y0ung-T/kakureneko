@testable import KakurenekoProcesses
import Darwin
import KakurenekoKit
import Foundation
import Testing

/// Read-only probes of the real process table. Assertions only concern this test process and processes the test
/// spawns itself (never which agents happen to run). The only signals sent go to the test's own children.
enum Spawn {
    /// `posix_spawn` in a new process group (so cleanup can reach grandchildren), with the temp-home environment.
    static func start(_ argv: [String], environment: [String: String]) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in cArgs { free(pointer) }
            for pointer in cEnv { free(pointer) }
        }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &actions, &attributes, cArgs, cEnv)
        guard rc == 0 else { throw POSIXError(POSIXErrorCode(rawValue: rc) ?? .EINVAL) }
        return pid
    }

    /// Kills the process group the test created and reaps the child.
    static func stop(_ pid: pid_t) {
        kill(-pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }

    /// Polls (10 ms steps, ≤ 10 s of WALL time — the suite shares the machine) until `condition` holds.
    static func waitUntil(_ condition: () -> Bool) async -> Bool {
        let end = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

@Suite("Live system (read-only)", .timeLimit(.minutes(1)))
struct LiveSystemTests {
    let kernel = KernelProcessLookup()
    let live = LiveProcessLookup()
    let probe = LiveProcessProbe()

    @Test func liveLookupMatchesTheKernelReferenceForThisProcess() throws {
        let me = getpid()
        let reference = try #require(kernel.identity(of: me))
        let identity = try #require(live.identity(of: me))
        #expect(identity == reference)
        #expect(identity.pid == reference.pid && identity.startSec == reference.startSec && identity.startUsec == reference.startUsec)
        #expect(identity.uniqueID != nil && identity.uniqueID != 0)
        #expect(identity.pidVersion != nil)
        #expect(live.isAlive(reference))
        #expect(live.parentPID(of: me) == getppid())
    }

    @Test func liveLookupIsNilForInvalidAndDeadPIDs() async throws {
        #expect(live.identity(of: 0) == nil)
        #expect(live.identity(of: -1) == nil)
        #expect(live.identity(of: Int32.max) == nil)
        let temp = try TempHome()
        let pid = try Spawn.start(["/usr/bin/true"], environment: temp.paths.helperEnvironment)
        let identity = live.identity(of: pid) // may already be a zombie, still a process
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let after = live.identity(of: pid)
        // Gone (nil), or — astronomically unlikely — the pid was already reused by another process.
        #expect(after == nil || (identity != nil && after != identity))
        if let identity { #expect(!live.isAlive(identity)) }
    }

    @Test func scanTableIdentityEqualsTheKernelReference() throws {
        // ARCHITECTURE §8: PROC_PIDTBSDINFO start time (scanner) == kinfo_proc p_starttime (KernelProcessLookup).
        let table = try #require(probe.readTable())
        let row = try #require(table[getpid()])
        #expect(row.identity == kernel.identity(of: getpid()))
        #expect(row.ppid == getppid())
        #expect(row.uid == getuid())
        #expect(table.sameUIDRows.contains { $0.pid == getpid() })
        // Other users' processes (launchd) are listed without an identity; KERN_PROC_PID resolves it.
        if let launchd = table[1] {
            #expect(launchd.identity == nil)
            #expect(probe.identity(of: 1) == kernel.identity(of: 1))
        }
    }

    @Test func spawnedChildAppearsAsADescendantWithTheRightParent() async throws {
        let temp = try TempHome()
        let child = try Spawn.start(["/bin/sleep", "30"], environment: temp.paths.helperEnvironment)
        defer { Spawn.stop(child) }
        let table = try #require(probe.readTable())
        #expect(table.descendants(of: getpid()).contains(child))
        let row = try #require(table[child])
        #expect(row.ppid == getpid())
        #expect(row.identity == kernel.identity(of: child))
        #expect(row.identity == live.identity(of: child))
        var reader = ProcArgsReader()
        #expect(probe.arguments(of: child, reader: &reader)?.argv == ["/bin/sleep", "30"])
        // The environment allow-list: the helper environment has none of the four variables.
        #expect(probe.arguments(of: child, reader: &reader)?.environment.isEmpty == true)
        #expect(probe.executablePath(of: child) == "/bin/sleep")
    }

    @Test func scannerReportsASpawnedTreeEndToEnd() async throws {
        let temp = try TempHome()
        let marker = "kakureneko-test-\(UUID().uuidString)"
        // `bash -c 'sleep 30; :'` forks sleep (the trailing `:` prevents the exec optimisation). Not /bin/sh: on macOS it
        // is a stub that re-execs the selected shell. 30 s (killed with its process group at the end) so a loaded
        // machine can never let the tree exit before the scan.
        let shell = try Spawn.start(["/bin/bash", "-c", "/bin/sleep 30; :", marker], environment: temp.paths.helperEnvironment)
        defer { Spawn.stop(shell) }
        let table = LiveProcessProbe()
        #expect(await Spawn.waitUntil { table.readTable()?.children[shell]?.isEmpty == false })
        let sleeper = try #require(table.readTable()?.children[shell]?.first)

        let scanner = ProcessScanner(
            paths: temp.paths,
            signatureMatcher: PredicateMatcher { descriptor in
                descriptor.argv.contains(marker) ? AgentMatch(agent: .unknown) : nil
            },
            clock: SystemClock(), logger: KakurenekoLogger(.processes), probe: LiveProcessProbe(), resolver: { _ in [] },
            defaultBrowser: { nil })
        let now = Date()
        let snapshot = await scanner.sample(now: now)
        let agent = try #require(snapshot.process(pid: shell))
        #expect(snapshot.agents.count == 1)
        #expect(agent.identity == kernel.identity(of: shell))
        #expect(agent.identity.uniqueID != nil)
        #expect(agent.ppid == getpid())
        #expect(agent.executablePath == "/bin/bash")
        #expect(agent.argv0 == "/bin/bash")
        #expect(agent.arguments == ["/bin/bash", "-c", "/bin/sleep 30; :", marker])
        #expect(agent.descendants == [kernel.identity(of: sleeper)].compactMap { $0 })
        #expect(agent.ancestors.first?.identity == kernel.identity(of: getpid()))
        if getppid() > 1 { #expect(agent.ancestors.contains { $0.identity.pid == getppid() }) }
        #expect(agent.cwd.map { URL(filePath: $0).standardizedFileURL.path } != nil)
        #expect(agent.firstSeen == now)
        #expect(agent.evidence.treeCPUSeconds != nil)
        #expect(snapshot.scannedProcessCount > 1)

        let topology = await scanner.topology(for: snapshot, now: now)
        #expect(topology.agentIdentities == [agent.identity])
        #expect(topology.descendantIdentities.map(\.pid) == [sleeper])
        #expect(topology.ancestorPIDs.contains(getpid()))
        #expect(!topology.ancestorPIDs.contains(1))
    }

    /// Card §9.2: `sample()` completes in < 200 ms in debug. The bound is checked on the scan's own CPU time (user +
    /// system of the scanning thread): wall time on a shared, loaded machine includes time spent waiting for a CPU,
    /// which no code can bound. Wall time still has a loose sanity bound (best of 3 fresh scanners), which catches
    /// a scan that blocks or waits.
    @Test func sampleCompletesWithinBudget() async throws {
        let temp = try TempHome()
        var coldCPU = Double.infinity, warmCPU = Double.infinity, coldWall = Double.infinity
        for _ in 0..<3 {
            let scanner = ProcessScanner(paths: temp.paths, matcher: AgentMatcher(paths: temp.paths), clock: TestClock())
            let started = ContinuousClock.now
            let cold = await scanner.sample(now: Date())
            coldWall = min(coldWall, (ContinuousClock.now - started).timeInterval * 1000)
            coldCPU = min(coldCPU, scanner.lastSampleCPUMilliseconds)
            #expect(cold.scannedProcessCount > 0)
            _ = await scanner.sample(now: Date())
            warmCPU = min(warmCPU, scanner.lastSampleCPUMilliseconds)
            if coldCPU < 200, warmCPU < 200, coldWall < 200 { break }
        }
        #expect(coldCPU < 200, "cold scan used \(coldCPU) ms of CPU")
        #expect(warmCPU < 200, "warm scan used \(warmCPU) ms of CPU")
        #expect(coldWall < 1_000, "cold scan took \(coldWall) ms of wall time (best of 3)")
    }

    @Test func machTimebaseIsTicksOnAppleSilicon() throws {
        #if arch(arm64)
        #expect(MachTimebase.current == MachTimebase(numer: 125, denom: 3))
        #expect(abs(MachTimebase.current.seconds(fromTicks: 24_000_000) - 1.0) < 1e-9)
        #else
        print("skipped: Intel timebase is 1/1")
        #endif
    }

    @Test func cpuSecondsAgreeWithGetrusage() throws {
        // Burn a little CPU so the values are not ~0.
        var x = 0.0
        for i in 0..<2_000_000 { x += sin(Double(i)) }
        #expect(x.isFinite)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let reference = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        let measured = try #require(probe.cpuSeconds(of: getpid()))
        #expect(measured > 0)
        // Same counters; other test threads keep running between the two reads.
        #expect(abs(measured - reference) < max(0.5, reference * 0.2), "rusage \(measured) vs getrusage \(reference)")
    }

    @Test func workingDirectoryAndExecutablePathOfThisProcess() throws {
        let cwd = try #require(probe.workingDirectory(of: getpid()))
        let expected = FileManager.default.currentDirectoryPath
        #expect(URL(filePath: cwd).resolvingSymlinksInPath().path == URL(filePath: expected).resolvingSymlinksInPath().path)
        let path = try #require(probe.executablePath(of: getpid()))
        #expect(FileManager.default.isExecutableFile(atPath: path))
        var reader = ProcArgsReader()
        let arguments = try #require(probe.arguments(of: getpid(), reader: &reader))
        // The last kept element may be cut by the 4 KiB budget; everything before it is exact.
        #expect(arguments.argv.dropLast().elementsEqual(CommandLine.arguments.prefix(max(0, arguments.argv.count - 1))))
        #expect(arguments.argv.first == CommandLine.arguments.first)
    }

    @Test func uniqueIdentifierFlavorReads() throws {
        let unique = try #require(LibProc.uniqueIdentifier(getpid()))
        #expect(unique.uniqueID != 0)
        // Stable for the process lifetime.
        #expect(LibProc.uniqueIdentifier(getpid())?.uniqueID == unique.uniqueID)
        #expect(LibProc.uniqueIdentifier(Int32.max) == nil)

        // R06 §2.4: p_idversion == audit token val[7] (what KakurenekoPause signals with).
        var token = audit_token_t()
        var count = mach_msg_type_number_t(MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
        let task = mach_task_self_
        let kr = withUnsafeMutablePointer(to: &token) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(task, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        #expect(kr == KERN_SUCCESS)
        #expect(unique.pidVersion == token.val.7)
        #expect(pid_t(bitPattern: token.val.5) == getpid())
    }

    @Test func ptyMasterAndTerminalDecoding() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            Issue.record("openpty failed: \(errno)")
            return
        }
        defer {
            close(master)
            close(slave)
        }
        var info = stat()
        #expect(fstat(slave, &info) == 0)
        let slaveDevice = info.st_rdev
        let minor = deviceMinor(UInt32(bitPattern: slaveDevice))

        guard case .entries(let entries) = probe.fileDescriptors(of: getpid(), kinds: .ptyMasters) else {
            Issue.record("fd listing failed")
            return
        }
        #expect(entries.contains(.ptyMaster(minor: minor)))
        #expect(!entries.contains { if case .tcp = $0 { true } else { false } }) // kinds filter

        let terminal = try #require(probe.terminal(device: slaveDevice))
        #expect(terminal.name == "ttys" + String(format: "%03d", minor))
        #expect(terminal.modified != nil)
        #expect(LibProc.deviceName(-1) == nil)
    }

    @Test func socketAndPipeDecoding() throws {
        // Loopback TCP: listener + client + accepted socket, all inside this process (no external network).
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        #expect(listener >= 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(bound == 0)
        #expect(listen(listener, 4) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        let port = UInt16(bigEndian: address.sin_port)
        let client = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(client) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        #expect(connected == 0)
        let accepted = accept(listener, nil, nil)
        defer { close(accepted) }

        // Unix socket pair and a pipe.
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        defer { for fd in pair { close(fd) } }
        var pipeFDs: [Int32] = [-1, -1]
        #expect(pipe(&pipeFDs) == 0)
        defer { for fd in pipeFDs { close(fd) } }

        guard case .entries(let entries) = probe.fileDescriptors(of: getpid(), kinds: [.sockets, .pipes]) else {
            Issue.record("fd listing failed")
            return
        }
        let tcp = entries.compactMap { if case .tcp(let info) = $0 { info } else { nil } }
        #expect(tcp.contains { $0.isListening && $0.localPort == port && $0.local == ip("127.0.0.1") })
        let clientSide = try #require(tcp.first { $0.isEstablished && $0.remotePort == port })
        #expect(clientSide.remote?.isLoopback == true)
        #expect(tcp.contains { $0.isEstablished && $0.localPort == port && $0.remotePort == clientSide.localPort })

        let unix = entries.compactMap { if case .unixSocket(let info) = $0 { info } else { nil } }
        #expect(unix.contains { a in a.peerSocket != 0 && unix.contains { $0.socket == a.peerSocket && $0.peerSocket == a.socket } })

        let pipes = entries.compactMap { if case .pipe(let handle, let peer) = $0 { (handle, peer) } else { nil } }
        #expect(pipes.contains { a in pipes.contains { $0.0 == a.1 && $0.1 == a.0 } })

        // The pairing logic over the live decoding: treat the client fd's process as the "agent" side is not
        // possible inside one process, so check the builder's index directly with the decoded entries.
        let hints = TopologyBuilder.ipcPeers(treePIDs: [1], fileDescriptors: [1: [.tcp(clientSide)], 2: entries])
        #expect(hints.contains { $0.peerPID == 2 && $0.kind == .loopbackTCP })
    }

    @Test func powerAssertionsAreReadable() {
        // Read-only `IOPMCopyAssertionsByProcess`; contents depend on the machine.
        #expect(probe.powerAssertions() != nil)
    }
}
