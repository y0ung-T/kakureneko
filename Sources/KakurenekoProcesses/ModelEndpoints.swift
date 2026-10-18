import Darwin
import KakurenekoKit
import Foundation
import Synchronization

/// An IPv4 or IPv6 address (IPv4-mapped IPv6 addresses normalise to `.v4`).
enum IPAddress: Sendable, Hashable, CustomStringConvertible {
    /// Host byte order (`127.0.0.1` = `0x7F000001`).
    case v4(UInt32)
    /// The 128 bits as two big-endian halves.
    case v6(UInt64, UInt64)

    init?(_ string: String) {
        var v4 = in_addr()
        if inet_pton(AF_INET, string, &v4) == 1 {
            self = .v4(UInt32(bigEndian: v4.s_addr))
            return
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, string, &v6) == 1 {
            self = IPAddress(v6)
            return
        }
        return nil
    }

    /// From a network-order `in_addr`.
    init(_ address: in_addr) {
        self = .v4(UInt32(bigEndian: address.s_addr))
    }

    /// From an `in6_addr`; `::ffff:a.b.c.d` becomes `.v4`.
    init(_ address: in6_addr) {
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        var hi: UInt64 = 0
        var lo: UInt64 = 0
        for index in 0..<8 { hi = hi << 8 | UInt64(bytes[index]) }
        for index in 8..<16 { lo = lo << 8 | UInt64(bytes[index]) }
        if hi == 0, lo >> 32 == 0xFFFF {
            self = .v4(UInt32(truncatingIfNeeded: lo))
        } else {
            self = .v6(hi, lo)
        }
    }

    var isLoopback: Bool {
        switch self {
        case .v4(let value): value >> 24 == 127
        case .v6(let hi, let lo): hi == 0 && lo == 1
        }
    }

    var isUnspecified: Bool {
        switch self {
        case .v4(let value): value == 0
        case .v6(let hi, let lo): hi == 0 && lo == 0
        }
    }

    var description: String {
        switch self {
        case .v4(let value):
            return "\(value >> 24).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
        case .v6(let hi, let lo):
            var address = in6_addr()
            withUnsafeMutableBytes(of: &address) { raw in
                for index in 0..<8 { raw[index] = UInt8(truncatingIfNeeded: hi >> (56 - 8 * UInt64(index))) }
                for index in 0..<8 { raw[8 + index] = UInt8(truncatingIfNeeded: lo >> (56 - 8 * UInt64(index))) }
            }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return "?" }
            return LibProc.string(fromCChars: buffer[...])
        }
    }
}

/// An address prefix such as `160.79.104.0/23`.
struct CIDRBlock: Sendable, Hashable {
    let network: IPAddress
    let prefixLength: Int

    init?(_ notation: String) {
        let parts = notation.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, let address = IPAddress(String(parts[0])), let length = Int(parts[1]) else { return nil }
        switch address {
        case .v4: guard (0...32).contains(length) else { return nil }
        case .v6: guard (0...128).contains(length) else { return nil }
        }
        network = address
        prefixLength = length
    }

    func contains(_ address: IPAddress) -> Bool {
        switch (network, address) {
        case (.v4(let net), .v4(let value)):
            guard prefixLength > 0 else { return true }
            let mask: UInt32 = prefixLength >= 32 ? .max : ~(UInt32.max >> UInt32(prefixLength))
            return net & mask == value & mask
        case (.v6(let netHi, let netLo), .v6(let hi, let lo)):
            let hiBits = min(prefixLength, 64)
            let loBits = max(0, prefixLength - 64)
            let hiMask: UInt64 = hiBits == 0 ? 0 : (hiBits >= 64 ? .max : ~(UInt64.max >> UInt64(hiBits)))
            let loMask: UInt64 = loBits == 0 ? 0 : (loBits >= 64 ? .max : ~(UInt64.max >> UInt64(loBits)))
            return netHi & hiMask == hi & hiMask && netLo & loMask == lo & loMask
        default:
            return false
        }
    }
}

/// The model-API destination set used by E4 (brief §5.4): Anthropic's published ranges plus the addresses the known
/// API hosts resolved to at the last refresh.
struct ModelEndpointSet: Sendable {
    static let staticNetworks: [CIDRBlock] = ["160.79.104.0/23", "2607:6bc0::/48"].compactMap(CIDRBlock.init)

    var resolved: Set<IPAddress> = []

    func contains(_ address: IPAddress) -> Bool {
        resolved.contains(address) || Self.staticNetworks.contains { $0.contains(address) }
    }
}

/// Resolves a host name to addresses. Production uses `getaddrinfo` off the cooperative pool; tests inject fakes
/// (tests must never touch the network).
typealias HostResolver = @Sendable (String) async -> [IPAddress]

/// Keeps `ModelEndpointSet` fresh: resolves the brief's host list at `start()` and every 10 minutes.
final class ModelEndpointRegistry: Sendable {
    /// brief §5.4 / R05 §5.1 (+ the long-tail agents' API hosts). `*.githubcopilot.com` is enumerated.
    static let hosts: [String] = [
        "api.anthropic.com",
        "api.openai.com", "chatgpt.com",
        "api.githubcopilot.com", "api.individual.githubcopilot.com", "api.business.githubcopilot.com",
        "api.enterprise.githubcopilot.com", "copilot-proxy.githubusercontent.com",
        "api2.cursor.sh", "api5.cursor.sh",
        "generativelanguage.googleapis.com", "cloudcode-pa.googleapis.com",
        "server.self-serve.windsurf.com", "inference.codeium.com",
        "api.x.ai", "api.mistral.ai", "api.moonshot.ai", "dashscope-intl.aliyuncs.com", "api.deepseek.com",
        "openrouter.ai",
    ]
    static let refreshInterval: Duration = .seconds(600)

    private struct State {
        var perHost: [String: Set<IPAddress>] = [:]
        var task: Task<Void, Never>?
        var refreshCount = 0
    }

    private let state = Mutex(State())
    private let resolver: HostResolver
    private let clock: any KakurenekoClock
    private let logger: KakurenekoLogger

    init(resolver: @escaping HostResolver, clock: any KakurenekoClock, logger: KakurenekoLogger) {
        self.resolver = resolver
        self.clock = clock
        self.logger = logger
    }

    deinit {
        state.withLock { $0.task?.cancel() }
    }

    /// Current destination set (static ranges + last resolution).
    var current: ModelEndpointSet {
        state.withLock { ModelEndpointSet(resolved: $0.perHost.values.reduce(into: Set<IPAddress>()) { $0.formUnion($1) }) }
    }

    /// Number of completed refreshes (diagnostics/tests).
    var refreshCount: Int { state.withLock { $0.refreshCount } }

    /// Starts the periodic refresh (idempotent). The first resolution runs immediately.
    func start() {
        state.withLock { s in
            guard s.task == nil else { return }
            let clock = self.clock
            s.task = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    do {
                        try await clock.sleep(for: Self.refreshInterval)
                    } catch {
                        return
                    }
                }
            }
        }
    }

    func stop() {
        let task = state.withLock { s -> Task<Void, Never>? in
            defer { s.task = nil }
            return s.task
        }
        task?.cancel()
    }

    /// Resolves every host once. A host that fails to resolve keeps its previous addresses.
    func refresh() async {
        var fresh: [String: Set<IPAddress>] = [:]
        for host in Self.hosts {
            if Task.isCancelled { return }
            let addresses = await resolver(host)
            if !addresses.isEmpty { fresh[host] = Set(addresses) }
        }
        let total = state.withLock { s -> Int in
            for (host, addresses) in fresh { s.perHost[host] = addresses }
            s.refreshCount += 1
            return s.perHost.values.reduce(0) { $0 + $1.count }
        }
        logger.debug("model endpoints refreshed: \(fresh.count)/\(Self.hosts.count) hosts, \(total) addresses")
    }

    /// `getaddrinfo` on a GCD queue (it blocks; never on the cooperative pool).
    static let systemResolver: HostResolver = { host in
        await withCheckedContinuation { (continuation: CheckedContinuation<[IPAddress], Never>) in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: resolveSynchronously(host))
            }
        }
    }

    static func resolveSynchronously(_ host: String) -> [IPAddress] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }
        var addresses: [IPAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            if let sockaddr = entry.pointee.ai_addr {
                switch Int32(entry.pointee.ai_family) {
                case AF_INET:
                    let address = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    addresses.append(IPAddress(address))
                case AF_INET6:
                    let address = sockaddr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                    addresses.append(IPAddress(address))
                default:
                    break
                }
            }
            cursor = entry.pointee.ai_next
        }
        return addresses
    }
}
