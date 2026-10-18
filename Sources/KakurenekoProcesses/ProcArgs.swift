import Darwin
import Foundation

/// What `KERN_PROCARGS2` yields for one process, reduced to what Kakureneko may keep (memory only).
///
/// Privacy: argv can contain prompt text — it is kept in memory for matching only, never logged or persisted.
/// Of the environment ONLY the four allow-listed variables are extracted; every other variable is skipped
/// without being copied.
struct ProcArguments: Sendable, Hashable {
    /// The path handed to `execve` (the interpreter for `#!` scripts; unresolved symlinks). Fallback for matching when
    /// `proc_pidpath` is nil (binary replaced by an auto-update).
    var executablePath: String?
    /// argv, capped at `ProcArgsParser.maxArguments` entries / `maxArgumentBytes` bytes in total.
    var argv: [String]
    /// Allow-listed environment only (`ProcArgsParser.environmentAllowList`).
    var environment: [String: String]
}

/// Pure parser for the `KERN_PROCARGS2` buffer layout: `int32 argc | exec_path\0 | \0 padding | argv[argc]\0… |
/// envp\0… | \0 | apple[]…` (R08 §7). Short buffers truncate silently (argv comes first).
enum ProcArgsParser {
    /// The only environment variables ever read (ARCHITECTURE §9.2).
    static let environmentAllowList = ["VSCODE_ESM_ENTRYPOINT", "__CFBundleIdentifier", "TERM_PROGRAM", "CLAUDE_CODE_ENTRYPOINT"]
    /// `AgentProcess.arguments` caps.
    static let maxArguments = 32
    static let maxArgumentBytes = 4096
    /// Cap per allow-listed environment value (untrusted input).
    static let maxEnvironmentValueBytes = 1024
    /// argc sanity bound (a corrupt buffer must not make us loop).
    static let maxArgc: Int32 = 1 << 16

    private static let allowListPrefixes: [(name: String, prefix: [UInt8])] = environmentAllowList.map {
        ($0, Array(($0 + "=").utf8))
    }
    /// First bytes of the allow-listed names: a cheap pre-filter so most variables are skipped after one byte.
    private static let allowListFirstBytes: Set<UInt8> = Set(environmentAllowList.compactMap { $0.utf8.first })

    static func parse(_ bytes: UnsafeRawBufferPointer) -> ProcArguments? {
        let count = bytes.count
        guard count >= MemoryLayout<Int32>.size else { return nil }
        let argc = bytes.loadUnaligned(as: Int32.self)
        guard argc >= 0, argc <= maxArgc else { return nil }
        var index = MemoryLayout<Int32>.size

        /// Returns the bounds of the NUL-terminated string at `index` and advances past its terminator.
        func nextString() -> Range<Int> {
            let start = index
            while index < count, bytes[index] != 0 { index += 1 }
            let range = start..<index
            if index < count { index += 1 }
            return range
        }
        func decode(_ range: Range<Int>, limit: Int) -> String {
            let end = min(range.upperBound, range.lowerBound + limit)
            return String(decoding: UnsafeRawBufferPointer(rebasing: bytes[range.lowerBound..<end]), as: UTF8.self)
        }

        let execRange = nextString()
        let executablePath = execRange.isEmpty ? nil : decode(execRange, limit: Int(4 * MAXPATHLEN))
        while index < count, bytes[index] == 0 { index += 1 }

        var argv: [String] = []
        var budget = maxArgumentBytes
        var parsed: Int32 = 0
        while parsed < argc, index < count {
            let range = nextString()
            parsed += 1
            if argv.count < maxArguments, budget > 0 {
                let value = decode(range, limit: budget)
                budget -= value.utf8.count
                argv.append(value)
            }
        }

        var environment: [String: String] = [:]
        while index < count {
            let range = nextString()
            if range.isEmpty { break } // end of envp
            guard allowListFirstBytes.contains(bytes[range.lowerBound]) else { continue }
            for entry in allowListPrefixes where range.count >= entry.prefix.count {
                var matches = true
                for (offset, byte) in entry.prefix.enumerated() where bytes[range.lowerBound + offset] != byte {
                    matches = false
                    break
                }
                if matches {
                    let valueRange = (range.lowerBound + entry.prefix.count)..<range.upperBound
                    environment[entry.name] = decode(valueRange, limit: maxEnvironmentValueBytes)
                    break
                }
            }
        }
        return ProcArguments(executablePath: executablePath, argv: argv, environment: environment)
    }

    /// Convenience for tests and fixtures.
    static func parse(_ data: [UInt8]) -> ProcArguments? {
        data.withUnsafeBytes { parse($0) }
    }

    /// Builds a `KERN_PROCARGS2`-shaped buffer (tests and fakes).
    static func encode(executablePath: String, argv: [String], environment: [String], padding: Int = 3) -> [UInt8] {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(argv.count).littleEndian) { bytes.append(contentsOf: $0) }
        bytes.append(contentsOf: Array(executablePath.utf8) + [0])
        bytes.append(contentsOf: [UInt8](repeating: 0, count: padding))
        for arg in argv { bytes.append(contentsOf: Array(arg.utf8) + [0]) }
        for entry in environment { bytes.append(contentsOf: Array(entry.utf8) + [0]) }
        bytes.append(0)
        bytes.append(contentsOf: Array("executable_path=\(executablePath)".utf8) + [0])
        return bytes
    }
}

/// Reads `KERN_PROCARGS2` with a caller-owned buffer that is reused for every pid of one scan (64 KiB, R08 §7:
/// a reused buffer cuts the argv pass from 9.6 ms to ~2.4 ms for ~600 pids).
struct ProcArgsReader {
    static let bufferSize = 64 << 10
    private var buffer: [UInt8]

    init() {
        buffer = [UInt8](repeating: 0, count: Self.bufferSize)
    }

    mutating func read(pid: Int32) -> ProcArguments? {
        guard pid > 0 else { return nil }
        let first = Self.read(pid: pid, into: &buffer)
        if let parsed = first.arguments { return parsed }
        // A process whose argument area exceeds the buffer answers ENOMEM, or (macOS 26, see HookAncestry) silently
        // copies only its TAIL, which would parse environment strings as argv: a filled buffer counts as truncated.
        // Retry once with exactly enough room (≤ KERN_ARGMAX); still not fitting reports nothing.
        guard first.error == ENOMEM || first.truncated, let needed = Self.argumentAreaSize(pid: pid) else { return nil }
        let maximum = Self.argumentMax()
        guard needed + 4_096 <= maximum else { return nil }
        var large = [UInt8](repeating: 0, count: needed + 4_096)
        let second = Self.read(pid: pid, into: &large)
        return second.truncated ? nil : second.arguments
    }

    private static func read(pid: Int32, into buffer: inout [UInt8]) -> (arguments: ProcArguments?, error: Int32, truncated: Bool) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        let rc = buffer.withUnsafeMutableBytes { raw in
            mib.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, 3, raw.baseAddress, &size, nil, 0) }
        }
        guard rc == 0 else { return (nil, errno, false) }
        guard size > MemoryLayout<Int32>.size else { return (nil, 0, false) }
        if size >= buffer.count { return (nil, 0, true) }
        let parsed = buffer.withUnsafeBytes { ProcArgsParser.parse(UnsafeRawBufferPointer(rebasing: $0[0..<size])) }
        return (parsed, 0, false)
    }

    /// The exact size of a process' argument area (a sysctl without a buffer copies nothing).
    private static func argumentAreaSize(pid: Int32) -> Int? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var needed = 0
        let rc = mib.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, 3, nil, &needed, nil, 0) }
        return rc == 0 && needed > 0 ? needed : nil
    }

    private static func argumentMax() -> Int {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let rc = mib.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, 2, &value, &size, nil, 0) }
        guard rc == 0, value > 0 else { return 1 << 20 }
        return min(Int(value), 4 << 20)
    }
}
