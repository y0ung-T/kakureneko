import Darwin

/// Minimal JSON writer. Only strings the hook escaped itself are emitted; the agent payload is never parsed or
/// re-escaped (it follows the header line byte for byte).
struct HookJSONWriter {
    private(set) var bytes: [UInt8] = []

    init(capacity: Int = 2_048) { bytes.reserveCapacity(capacity) }

    mutating func raw(_ text: StaticString) {
        bytes.append(contentsOf: UnsafeBufferPointer(start: text.utf8Start, count: text.utf8CodeUnitCount))
    }

    mutating func key(_ name: String) {
        string(name)
        bytes.append(UInt8(ascii: ":"))
    }

    mutating func integer<T: BinaryInteger>(_ value: T) {
        bytes.append(contentsOf: String(value).utf8)
    }

    /// A JSON string literal. Control characters are escaped; U+2028/U+2029 too (harmless, stricter parsers).
    /// The escaped body is cut to at most `maxBytes` bytes on a scalar boundary (escapes can grow a string 6×).
    mutating func string(_ value: String, maxBytes: Int = .max) {
        bytes.append(UInt8(ascii: "\""))
        var used = 0
        for scalar in value.unicodeScalars {
            let escaped = Self.escape(scalar)
            if used + escaped.count > maxBytes { break }
            bytes.append(contentsOf: escaped)
            used += escaped.count
        }
        bytes.append(UInt8(ascii: "\""))
    }

    /// Length of `value`'s escaped JSON body (without the quotes).
    static func escapedLength(_ value: String) -> Int {
        value.unicodeScalars.reduce(0) { $0 + escape($1).count }
    }

    private static func escape(_ scalar: Unicode.Scalar) -> [UInt8] {
        switch scalar.value {
        case 0x22: Array(#"\""#.utf8)
        case 0x5C: Array(#"\\"#.utf8)
        case 0x0A: Array(#"\n"#.utf8)
        case 0x0D: Array(#"\r"#.utf8)
        case 0x09: Array(#"\t"#.utf8)
        case 0x08: Array(#"\b"#.utf8)
        case 0x0C: Array(#"\f"#.utf8)
        case 0x00..<0x20, 0x7F, 0x2028, 0x2029:
            Array(#"\u"#.utf8) + Array(hex4(scalar.value).utf8)
        default:
            Array(String(scalar).utf8)
        }
    }

    private static func hex4(_ value: UInt32) -> String {
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: max(0, 4 - hex.count)) + hex
    }

    mutating func stringField(_ name: String, _ value: String, maxBytes: Int = .max, leadingComma: Bool = true) {
        if leadingComma { bytes.append(UInt8(ascii: ",")) }
        key(name)
        string(value, maxBytes: maxBytes)
    }

    mutating func integerField<T: BinaryInteger>(_ name: String, _ value: T, leadingComma: Bool = true) {
        if leadingComma { bytes.append(UInt8(ascii: ",")) }
        key(name)
        integer(value)
    }
}

/// Line 1 of the inbox file (`InboxHeader`, brief §4.3):
/// `{"v":1,"agent":…,"event":…,"ts":…,"pid":…,"ppid":…,"cwd":…,"payloadSource":…,"env":{…},"ancestry":[…]}`.
enum HookHeader {
    /// The app rejects a header line above `InboxFile.maxHeaderBytes` (64 KiB); stay a little below it.
    static let byteBudget = HookConstants.maxHeaderBytes - 1_024
    /// Per-string cap of the escaped JSON body in compact mode.
    static let compactStringBytes = 512

    /// The header, rebuilt in compact mode when the full one would exceed `byteBudget` (only possible with hostile,
    /// escape-heavy environment or argv strings; raw lengths are already capped).
    static func bounded(
        invocation: HookInvocation,
        timestampMilliseconds: Int64,
        payloadSource: HookPayload.Source,
        environment: [(name: String, value: String)],
        ancestry: [HookAncestor],
        cwd: String? = currentDirectory()
    ) -> [UInt8] {
        let full = make(invocation: invocation, timestampMilliseconds: timestampMilliseconds, payloadSource: payloadSource,
                        environment: environment, ancestry: ancestry, cwd: cwd, compact: false)
        guard full.count > byteBudget else { return full }
        return make(invocation: invocation, timestampMilliseconds: timestampMilliseconds, payloadSource: payloadSource,
                    environment: environment, ancestry: ancestry, cwd: cwd, compact: true)
    }

    /// One header line. `compact`: every string is cut to `compactStringBytes` escaped bytes, except `argv1`/`path`,
    /// which are dropped instead (a truncated path would mis-attribute).
    static func make(
        invocation: HookInvocation,
        timestampMilliseconds: Int64,
        payloadSource: HookPayload.Source,
        environment: [(name: String, value: String)],
        ancestry: [HookAncestor],
        cwd: String? = currentDirectory(),
        compact: Bool = false
    ) -> [UInt8] {
        let cap = compact ? compactStringBytes : Int.max
        func keepsPath(_ value: String) -> Bool { !compact || HookJSONWriter.escapedLength(value) <= cap }
        var json = HookJSONWriter()
        json.raw("{")
        json.integerField("v", HookConstants.headerVersion, leadingComma: false)
        json.stringField("agent", invocation.agent)
        json.stringField("event", invocation.event)
        json.integerField("ts", timestampMilliseconds)
        json.integerField("pid", getpid())
        json.integerField("ppid", getppid())
        if let cwd { json.stringField("cwd", cwd, maxBytes: cap) }
        json.stringField("payloadSource", payloadSource.rawValue)
        json.raw(#","env":{"#)
        for (index, entry) in environment.enumerated() {
            json.stringField(entry.name, entry.value, maxBytes: cap, leadingComma: index > 0)
        }
        json.raw(#"},"ancestry":["#)
        for (index, ancestor) in ancestry.enumerated() {
            if index > 0 { json.raw(",") }
            json.raw("{")
            json.integerField("pid", ancestor.pid, leadingComma: false)
            json.integerField("ppid", ancestor.ppid)
            json.integerField("startSec", ancestor.startSec)
            json.integerField("startUsec", ancestor.startUsec)
            json.stringField("exe", ancestor.exe, maxBytes: cap)
            if let argv0 = ancestor.argv0 { json.stringField("argv0", argv0, maxBytes: cap) }
            if let argv1 = ancestor.argv1, keepsPath(argv1) { json.stringField("argv1", argv1) }
            if let path = ancestor.path, keepsPath(path) { json.stringField("path", path) }
            if let module = ancestor.module { json.stringField("module", module) } // ≤ 128 identifier bytes
            json.integerField("tdev", ancestor.tdev)
            json.raw("}")
        }
        json.raw("]}")
        return json.bytes
    }

    static func currentDirectory() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) + 1)
        guard getcwd(&buffer, buffer.count) != nil else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return path.isEmpty ? nil : HookText.truncated(path, maxBytes: HookConstants.maxValueBytes * 4)
    }
}
