import Darwin
import KakurenekoKit
import Foundation

// MARK: - File-descriptor model

/// A TCP endpoint (`PROC_PIDFDSOCKETINFO`, `soi_kind == SOCKINFO_TCP`).
struct TCPSocketInfo: Sendable, Hashable {
    var local: IPAddress?
    var localPort: UInt16
    var remote: IPAddress?
    var remotePort: UInt16
    /// `TSI_S_*`.
    var state: Int32

    var isListening: Bool { state == TSI_S_LISTEN }
    var isEstablished: Bool { state == TSI_S_ESTABLISHED }
    /// SYN_SENT … CLOSE_WAIT: an open connection (the kernel completes `connect()` into a frozen listener's backlog).
    var isConnected: Bool { (TSI_S_SYN_SENT...TSI_S__CLOSE_WAIT).contains(state) }
    /// Identity of the connection for E4 "new connection" detection (memory only).
    var connectionKey: String {
        "\(local.map(String.init(describing:)) ?? "*"):\(localPort)>\(remote.map(String.init(describing:)) ?? "*"):\(remotePort)"
    }
}

/// A Unix-domain endpoint (`SOCKINFO_UN`): kernel socket address, its peer's, bound and peer paths.
struct UnixSocketInfo: Sendable, Hashable {
    /// `soi_so` (kernel address, permuted per boot; stable for pairing).
    var socket: UInt64
    /// `unsi_conn_so` (0 when unconnected).
    var peerSocket: UInt64
    /// `unsi_addr` (bound path).
    var path: String?
    /// `unsi_caddr` (the path this socket connected to).
    var peerPath: String?
    /// `SO_ACCEPTCONN`.
    var isListening: Bool
}

/// The descriptors the topology and E4 care about.
enum FDEntry: Sendable, Hashable {
    /// A `/dev/ptmx` vnode: this process holds the master of pty `minor`.
    case ptyMaster(minor: UInt32)
    case unixSocket(UnixSocketInfo)
    case tcp(TCPSocketInfo)
    /// `PROC_PIDFDPIPEINFO` handle / peer handle.
    case pipe(handle: UInt64, peer: UInt64)
}

/// Which descriptor kinds to decode (vnode path lookups are the expensive part).
struct FDKinds: OptionSet, Sendable, Hashable {
    let rawValue: Int
    static let ptyMasters = FDKinds(rawValue: 1 << 0)
    static let sockets = FDKinds(rawValue: 1 << 1)
    static let pipes = FDKinds(rawValue: 1 << 2)
    static let all: FDKinds = [.ptyMasters, .sockets, .pipes]
}

enum FDReadResult: Sendable, Hashable {
    case entries([FDEntry])
    /// The process exited meanwhile (not a probe failure).
    case gone
    /// EPERM or another error: the topology is then incomplete.
    case failed(Int32)
}

/// `minor(dev)` for the pty map (R06 §3.2: master `/dev/ptmx` rdev `0x0f0000NN`, slave `ttysNNN` `0x100000NN`).
func deviceMinor(_ device: UInt32) -> UInt32 { device & 0x00FF_FFFF }

// MARK: - Builder

/// Everything the builder needs, gathered by `TopologyCollector` (or synthesised by tests).
struct TopologyInput: Sendable {
    var builtAt: Date
    var table: ProcessTable
    /// Agent identities from the latest `ProcessSnapshot` (only live ones are used).
    var agents: [ProcessIdentity]
    /// Identities of other users' rows inside agent trees (resolved via `KERN_PROC_PID`).
    var extraIdentities: [Int32: ProcessIdentity] = [:]
    /// `proc_pidpath` of agent-tree members.
    var executablePaths: [Int32: String] = [:]
    /// argv of automation-helper candidates in agent trees (memory only).
    var arguments: [Int32: [String]] = [:]
    /// Decoded descriptors per pid (agent-tree members and same-uid peers).
    var fileDescriptors: [Int32: [FDEntry]] = [:]
    /// False when a probe failed (EPERM, deadline): KakurenekoPause must then be conservative.
    var probesComplete: Bool = true
}

/// Pure construction of `AgentTopology` (brief §6.3 P-A…P-E inputs; R06 §3.2–3.3).
struct TopologyBuilder: Sendable {
    /// Bundle path → bundle identifier (`open -a /Applications/X.app`).
    var bundleIdentifier: @Sendable (String) -> String?
    /// The default `https` handler's bundle identifier (`open <url>`), resolved lazily.
    var defaultBrowserBundleID: @Sendable () -> String?

    func build(_ input: TopologyInput) -> AgentTopology {
        let table = input.table
        func identity(of pid: Int32) -> ProcessIdentity? { table[pid]?.identity ?? input.extraIdentities[pid] }

        let agents = input.agents.filter { identity(of: $0.pid) == $0 }
        let agentPIDs = Set(agents.map(\.pid))
        var treePIDs = agentPIDs
        var descendants: Set<ProcessIdentity> = []
        for agent in agents {
            for pid in table.descendants(of: agent.pid) {
                treePIDs.insert(pid)
                if let id = identity(of: pid) { descendants.insert(id) }
            }
        }

        var ttys: Set<Int32> = []
        for pid in treePIDs { if let tdev = table[pid]?.tdev { ttys.insert(tdev) } }
        let minors = Set(ttys.map { deviceMinor(UInt32(bitPattern: $0)) })

        var ptyHolders: Set<Int32> = []
        if !minors.isEmpty {
            for (pid, entries) in input.fileDescriptors {
                for entry in entries {
                    if case .ptyMaster(let minor) = entry, minors.contains(minor) {
                        ptyHolders.insert(pid)
                        break
                    }
                }
            }
        }

        var ancestors: Set<Int32> = []
        for agent in agents { ancestors.formUnion(table.ancestors(of: agent.pid)) }

        // P-B: app executables (`…/X.app/Contents/MacOS/X`, nested helper apps included) running inside an agent tree,
        // e.g. a Playwright/CDP Chrome. Toolchain CLIs that merely live inside a bundle (`Xcode.app/…/usr/bin/git`) are
        // not apps (they are protected as tree members anyway).
        var launchedApps: Set<Int32> = []
        for pid in treePIDs where !agentPIDs.contains(pid) {
            if let path = input.executablePaths[pid], AppBundlePaths.bundle(ofMainExecutable: path) != nil {
                launchedApps.insert(pid)
            }
        }

        var helpers: [AutomationHelperHint] = []
        for pid in treePIDs.sorted() {
            guard let id = identity(of: pid) else { continue }
            let argv = input.arguments[pid] ?? []
            guard let found = AutomationHelperTargets.tool(
                executablePath: input.executablePaths[pid], argv: argv, comm: table[pid]?.comm ?? "")
            else { continue }
            let targets = AutomationHelperTargets.targets(
                tool: found.tool, arguments: found.arguments,
                bundleIdentifier: bundleIdentifier, defaultBrowser: defaultBrowserBundleID)
            helpers.append(AutomationHelperHint(helper: id, tool: found.tool, likelyTargetBundleIDs: targets))
        }

        return AgentTopology(
            builtAt: input.builtAt,
            agentIdentities: Set(agents),
            descendantIdentities: descendants,
            ttyDevices: ttys,
            ptyMasterHolderPIDs: ptyHolders,
            ancestorPIDs: ancestors,
            agentLaunchedAppPIDs: launchedApps,
            ipcPeers: Self.ipcPeers(treePIDs: treePIDs, fileDescriptors: input.fileDescriptors),
            automationHelpers: helpers,
            isComplete: input.probesComplete
        )
    }

    /// Conservative topology when the process table cannot be read: everything the snapshot knew (agents, their
    /// descendants, ttys and ancestors), marked incomplete so KakurenekoPause protects anything uncertain.
    static func fallback(snapshot: ProcessSnapshot, now: Date) -> AgentTopology {
        var descendants: Set<ProcessIdentity> = []
        var ttys: Set<Int32> = []
        var ancestors: Set<Int32> = []
        for agent in snapshot.agents {
            descendants.formUnion(agent.descendants)
            if let tty = agent.ttyDevice { ttys.insert(tty) }
            ancestors.formUnion(agent.ancestors.map(\.identity.pid))
        }
        return AgentTopology(
            builtAt: now,
            agentIdentities: Set(snapshot.agents.map(\.identity)),
            descendantIdentities: descendants,
            ttyDevices: ttys,
            ancestorPIDs: ancestors,
            isComplete: false
        )
    }

    /// P-C/P-D: Unix socket peers (`unsi_conn_so` ↔ `soi_so`), loopback TCP port pairs, pipe handle pairs, and owners
    /// of LISTEN sockets (TCP port or Unix path) that an agent-tree socket connects to — plus the reverse cases (a
    /// process connected to an agent-tree listener).
    static func ipcPeers(treePIDs: Set<Int32>, fileDescriptors: [Int32: [FDEntry]]) -> [IPCPeerHint] {
        // Index the non-tree side once.
        var unixBySocket: [UInt64: Set<Int32>] = [:]
        var unixByPeer: [UInt64: Set<Int32>] = [:]
        var unixListeners: [String: Set<Int32>] = [:]
        var unixClientsByPath: [String: Set<Int32>] = [:]
        var tcpByLocalPort: [UInt16: [(pid: Int32, info: TCPSocketInfo)]] = [:]
        var tcpListeners: [UInt16: [(pid: Int32, info: TCPSocketInfo)]] = [:]
        var tcpClientsByRemotePort: [UInt16: [(pid: Int32, info: TCPSocketInfo)]] = [:]
        var pipesByHandle: [UInt64: Set<Int32>] = [:]
        var pipesByPeer: [UInt64: Set<Int32>] = [:]
        // Tree listeners for the reverse direction.
        var treeTCPListeners: [UInt16: Set<Int32>] = [:]
        var treeUnixListeners: [String: Set<Int32>] = [:]

        for (pid, entries) in fileDescriptors {
            let inTree = treePIDs.contains(pid)
            for entry in entries {
                switch entry {
                case .unixSocket(let unix):
                    if inTree {
                        if unix.isListening, let path = unix.path, !path.isEmpty { treeUnixListeners[path, default: []].insert(pid) }
                        continue
                    }
                    if unix.socket != 0 { unixBySocket[unix.socket, default: []].insert(pid) }
                    if unix.peerSocket != 0 { unixByPeer[unix.peerSocket, default: []].insert(pid) }
                    if unix.isListening, let path = unix.path, !path.isEmpty { unixListeners[path, default: []].insert(pid) }
                    if !unix.isListening, let path = unix.peerPath, !path.isEmpty { unixClientsByPath[path, default: []].insert(pid) }
                case .tcp(let tcp):
                    if inTree {
                        if tcp.isListening { treeTCPListeners[tcp.localPort, default: []].insert(pid) }
                        continue
                    }
                    if tcp.isListening {
                        tcpListeners[tcp.localPort, default: []].append((pid, tcp))
                    } else if tcp.isConnected, tcp.remote?.isLoopback == true {
                        tcpByLocalPort[tcp.localPort, default: []].append((pid, tcp))
                        tcpClientsByRemotePort[tcp.remotePort, default: []].append((pid, tcp))
                    }
                case .pipe(let handle, let peer):
                    guard !inTree else { continue }
                    if handle != 0 { pipesByHandle[handle, default: []].insert(pid) }
                    if peer != 0 { pipesByPeer[peer, default: []].insert(pid) }
                case .ptyMaster:
                    continue
                }
            }
        }

        var hints: Set<IPCPeerHint> = []
        func add(_ peers: Set<Int32>?, _ kind: IPCPeerHint.Kind, _ agentSide: Int32, _ detail: String?) {
            for peer in peers ?? [] where !treePIDs.contains(peer) {
                hints.insert(IPCPeerHint(peerPID: peer, kind: kind, agentSidePID: agentSide, detail: detail))
            }
        }

        for (pid, entries) in fileDescriptors where treePIDs.contains(pid) {
            for entry in entries {
                switch entry {
                case .unixSocket(let unix):
                    let detail = (unix.path?.isEmpty == false ? unix.path : nil) ?? unix.peerPath
                    if unix.peerSocket != 0 { add(unixBySocket[unix.peerSocket], .unixSocket, pid, detail) }
                    if unix.socket != 0 { add(unixByPeer[unix.socket], .unixSocket, pid, detail) }
                    if !unix.isListening, let path = unix.peerPath, !path.isEmpty {
                        add(unixListeners[path], .listener, pid, path)
                    }
                case .tcp(let tcp):
                    guard !tcp.isListening, tcp.isConnected, let remote = tcp.remote, remote.isLoopback, tcp.remotePort != 0
                    else { continue }
                    let detail = "\(remote):\(tcp.remotePort)"
                    let pairs = (tcpByLocalPort[tcp.remotePort] ?? []).filter { $0.info.remotePort == tcp.localPort }
                    if !pairs.isEmpty {
                        add(Set(pairs.map(\.pid)), .loopbackTCP, pid, detail)
                    } else {
                        let owners = (tcpListeners[tcp.remotePort] ?? []).filter { listener in
                            guard let local = listener.info.local else { return true }
                            return local.isLoopback || local.isUnspecified
                        }
                        add(Set(owners.map(\.pid)), .listener, pid, detail)
                    }
                case .pipe(let handle, let peer):
                    if peer != 0 { add(pipesByHandle[peer], .pipe, pid, nil) }
                    if handle != 0 { add(pipesByPeer[handle], .pipe, pid, nil) }
                case .ptyMaster:
                    continue
                }
            }
        }

        // Reverse direction: outsiders connected to an agent-tree listener whose connection is not accepted yet (or
        // whose accepted socket we did not pair above).
        for (port, listeners) in treeTCPListeners {
            for client in tcpClientsByRemotePort[port] ?? [] {
                for listener in listeners {
                    add([client.pid], .loopbackTCP, listener, "\(client.info.remote.map(String.init(describing:)) ?? "127.0.0.1"):\(port)")
                }
            }
        }
        for (path, listeners) in treeUnixListeners {
            for listener in listeners { add(unixClientsByPath[path], .unixSocket, listener, path) }
        }

        return hints.sorted {
            ($0.peerPID, $0.agentSidePID, $0.kind.rawValue, $0.detail ?? "") < ($1.peerPID, $1.agentSidePID, $1.kind.rawValue, $1.detail ?? "")
        }
    }
}

// MARK: - Automation helpers (P-E)

/// `osascript`, `open`, `shortcuts`, `mcpbridge`, `simctl`, `xcodebuild` inside agent trees and their likely targets
/// (Xcode for `mcpbridge`/`xcodebuild`, Simulator for `simctl`, the default browser for `open <url>`). An empty
/// target list means "unknown" → KakurenekoPause thaws everything.
enum AutomationHelperTargets {
    static let tools: Set<String> = ["osascript", "open", "shortcuts", "mcpbridge", "simctl", "xcodebuild"]
    static let xcode = "com.apple.dt.Xcode"
    static let simulator = "com.apple.iphonesimulator"

    /// Well-known application names → bundle identifiers (`open -a Safari`, `tell application "Google Chrome"`).
    static let knownApplications: [String: String] = [
        "safari": "com.apple.Safari", "google chrome": "com.google.Chrome", "chrome": "com.google.Chrome",
        "chromium": "org.chromium.Chromium", "arc": "company.thebrowser.Browser", "firefox": "org.mozilla.firefox",
        "microsoft edge": "com.microsoft.edgemac", "brave browser": "com.brave.Browser", "orion": "com.kagi.kagimacOS",
        "xcode": xcode, "simulator": simulator, "finder": "com.apple.finder", "terminal": "com.apple.Terminal",
        "iterm": "com.googlecode.iterm2", "iterm2": "com.googlecode.iterm2", "music": "com.apple.Music",
        "notes": "com.apple.Notes", "mail": "com.apple.mail", "messages": "com.apple.MobileSMS",
        "calendar": "com.apple.iCal", "reminders": "com.apple.reminders", "preview": "com.apple.Preview",
        "textedit": "com.apple.TextEdit", "photos": "com.apple.Photos", "keynote": "com.apple.iWork.Keynote",
        "pages": "com.apple.iWork.Pages", "numbers": "com.apple.iWork.Numbers",
        "visual studio code": "com.microsoft.VSCode", "cursor": "com.todesktop.230313mzl4w4u92",
        "slack": "com.tinyspeck.slackmacgap", "spotify": "com.spotify.client",
    ]

    /// The helper tool a process is, with the arguments that follow it (`xcrun simctl …` → `simctl`).
    static func tool(executablePath: String?, argv: [String], comm: String) -> (tool: String, arguments: [String])? {
        let names = [executablePath.map(AgentSignatureRules.basename), argv.first.map(AgentSignatureRules.basename), comm]
            .compactMap { $0 }
        if let tool = names.first(where: tools.contains) { return (tool, Array(argv.dropFirst())) }
        if names.contains("xcrun") {
            var index = 1
            while index < argv.count {
                let arg = argv[index]
                if tools.contains(arg) { return (arg, Array(argv.dropFirst(index + 1))) }
                if arg == "--sdk" || arg == "--toolchain" || arg == "-sdk" {
                    index += 2
                    continue
                }
                if arg.hasPrefix("-") {
                    index += 1
                    continue
                }
                break
            }
        }
        return nil
    }

    static func targets(
        tool: String,
        arguments: [String],
        bundleIdentifier: (String) -> String?,
        defaultBrowser: () -> String?
    ) -> [String] {
        switch tool {
        case "mcpbridge", "xcodebuild": [xcode]
        case "simctl": [simulator]
        case "open": openTargets(arguments, bundleIdentifier: bundleIdentifier, defaultBrowser: defaultBrowser)
        case "osascript": osascriptTargets(arguments, bundleIdentifier: bundleIdentifier)
        default: [] // shortcuts and anything else: unknown
        }
    }

    /// `open -b id`, `open -a App|/path/App.app`, `open -e` (TextEdit), `open -R` (Finder), `open https://…` (default
    /// browser). Anything else (files, other schemes, `-t`) is unknown.
    static func openTargets(_ arguments: [String], bundleIdentifier: (String) -> String?, defaultBrowser: () -> String?) -> [String] {
        var explicit: [String] = []
        var unknown = false
        var urls = 0
        var others = 0
        var index = 0
        loop: while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "-b", "--bundle":
                if index + 1 < arguments.count { explicit.append(arguments[index + 1]) } else { unknown = true }
                index += 2
                continue
            case "-a", "--application":
                if index + 1 < arguments.count, let id = applicationIdentifier(arguments[index + 1], bundleIdentifier: bundleIdentifier) {
                    explicit.append(id)
                } else {
                    unknown = true
                }
                index += 2
                continue
            case "-e": explicit.append("com.apple.TextEdit")
            case "-R", "--reveal": explicit.append("com.apple.finder")
            case "-t", "--text": unknown = true
            case "-u", "--url":
                if index + 1 < arguments.count, isWebURL(arguments[index + 1]) { urls += 1 } else { others += 1 }
                index += 2
                continue
            case "--args":
                break loop
            case "--env", "--stdin", "--stdout", "--stderr", "-s":
                index += 2
                continue
            default:
                if arg.hasPrefix("-") { break }
                if isWebURL(arg) { urls += 1 } else { others += 1 }
            }
            index += 1
        }
        if unknown { return [] }
        if !explicit.isEmpty { return orderedUnique(explicit) }
        if urls > 0, others == 0, let browser = defaultBrowser() { return [browser] }
        return []
    }

    /// `osascript -e 'tell application "Safari" …'` / `application id "com.x"` / JXA `Application('Xcode')`. A script
    /// file, stdin, `System Events` or an unknown application name → unknown.
    static func osascriptTargets(_ arguments: [String], bundleIdentifier: (String) -> String?) -> [String] {
        var lines: [String] = []
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "-e" {
                if index + 1 < arguments.count { lines.append(arguments[index + 1]) }
                index += 2
                continue
            }
            if arg == "-l" || arg == "-s" {
                index += 2
                continue
            }
            if arg.hasPrefix("-") && arg != "-" {
                index += 1
                continue
            }
            return [] // a script file (or "-" = stdin): contents unknown
        }
        guard !lines.isEmpty else { return [] }
        let references = applicationReferences(in: lines.joined(separator: "\n"))
        guard !references.isEmpty else { return [] }
        var targets: [String] = []
        for reference in references {
            switch reference {
            case .bundleID(let id): targets.append(id)
            case .name(let name):
                if name.lowercased() == "system events" { return [] }
                guard let id = applicationIdentifier(name, bundleIdentifier: bundleIdentifier) else { return [] }
                targets.append(id)
            }
        }
        return orderedUnique(targets)
    }

    enum ApplicationReference: Equatable {
        case name(String)
        case bundleID(String)
    }

    /// Finds `application "Name"`, `application id "id"`, `app "Name"` and `Application('Name')` references.
    static func applicationReferences(in script: String) -> [ApplicationReference] {
        func skipping(_ prefix: String, in text: String, at index: String.Index) -> String.Index? {
            text.range(of: prefix, options: [.caseInsensitive, .anchored], range: index..<text.endIndex)?.upperBound
        }
        var references: [ApplicationReference] = []
        var searchStart = script.startIndex
        while let range = script.range(of: "app", options: .caseInsensitive, range: searchStart..<script.endIndex) {
            searchStart = range.upperBound
            // Word boundary before "app".
            if range.lowerBound > script.startIndex {
                let previous = script[script.index(before: range.lowerBound)]
                if previous.isLetter || previous.isNumber || previous == "_" { continue }
            }
            var cursor = skipping("lication", in: script, at: range.upperBound) ?? range.upperBound
            if cursor < script.endIndex, script[cursor].isLetter || script[cursor].isNumber { continue }
            // Skip spaces and an optional "(" (JXA).
            while cursor < script.endIndex, script[cursor] == " " || script[cursor] == "(" { cursor = script.index(after: cursor) }
            var isID = false
            if let afterID = skipping("id ", in: script, at: cursor) {
                isID = true
                cursor = afterID
                while cursor < script.endIndex, script[cursor] == " " { cursor = script.index(after: cursor) }
            }
            guard cursor < script.endIndex, script[cursor] == "\"" || script[cursor] == "'" else { continue }
            let quote = script[cursor]
            let valueStart = script.index(after: cursor)
            guard let valueEnd = script[valueStart...].firstIndex(of: quote) else { continue }
            let value = String(script[valueStart..<valueEnd])
            searchStart = valueEnd
            guard !value.isEmpty, value.count <= 255 else { continue }
            references.append(isID ? .bundleID(value) : .name(value))
        }
        return references
    }

    /// `/Applications/Foo.app` → its bundle id; `Safari`/`Safari.app` → the well-known table.
    static func applicationIdentifier(_ value: String, bundleIdentifier: (String) -> String?) -> String? {
        if value.contains("/") {
            let path = value.hasSuffix("/") ? String(value.dropLast()) : value
            guard path.hasSuffix(".app") else { return nil }
            return bundleIdentifier(path)
        }
        let name = value.hasSuffix(".app") ? String(value.dropLast(4)) : value
        return knownApplications[name.lowercased()]
    }

    static func isWebURL(_ value: String) -> Bool {
        let lower = value.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
