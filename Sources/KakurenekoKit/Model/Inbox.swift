import Foundation

/// One process in the hook's ancestry chain (brief §4.3), nearest first (index 0 = the hook's parent).
/// Collected by the hook with `sysctl(KERN_PROC_PID)` (+ `KERN_PROCARGS2` for argv, + `proc_pidpath`), ≤ 8 levels.
///
/// `argv1` and `path` exist because node/python agents are only recognisable by them (brief §5.3: Codex npm
/// `node …/codex.js`, Gemini `node …/gemini`, Copilot npm, Qwen/Auggie, Aider `python3.12 …/bin/aider`).
public struct InboxAncestor: Sendable, Hashable, Codable {
    public var pid: Int32
    /// Parent pid (`kinfo_proc.kp_eproc.e_ppid`). Optional for compatibility.
    public var ppid: Int32?
    /// `p_starttime.tv_sec`
    public var startSec: Int64
    /// `p_starttime.tv_usec`
    public var startUsec: Int32
    /// `p_comm` (≤ 16 chars). For native Claude Code this is its version string (`2.1.296`): never match on it alone.
    public var exe: String?
    /// argv[0] from `KERN_PROCARGS2` (argv only, never env).
    public var argv0: String?
    /// argv[1] from the same `KERN_PROCARGS2` read, ONLY when it looks like a path (contains `/`, no whitespace,
    /// ≤ 512 bytes); otherwise absent — argv[1] can be a prompt and must never be recorded.
    public var argv1: String?
    /// `proc_pidpath` (absent for other users' processes or a binary replaced by an auto-update).
    public var path: String?
    /// Controlling tty (`e_tdev`); absent or -1 = none.
    public var tdev: Int32?
    /// The module of a Python interpreter started as `python … -m <module>` (`python -m aider`), from the same
    /// `KERN_PROCARGS2` read. Recorded ONLY for Python interpreters (argv[0] or path basename starting with
    /// `python`, any case) and only when `isRecordableModule` (a plain dotted identifier — never free text).
    public var module: String?

    public init(pid: Int32, ppid: Int32? = nil, startSec: Int64, startUsec: Int32, exe: String? = nil, argv0: String? = nil,
                tdev: Int32? = nil, argv1: String? = nil, path: String? = nil, module: String? = nil) {
        self.pid = pid
        self.ppid = ppid
        self.startSec = startSec
        self.startUsec = startUsec
        self.exe = exe
        self.argv0 = argv0
        self.tdev = tdev
        self.argv1 = argv1
        self.path = path
        self.module = module
    }

    /// Identity (pid + start time) of this ancestor.
    public var identity: ProcessIdentity { ProcessIdentity(pid: pid, startSec: startSec, startUsec: startUsec) }
    /// Controlling tty if any.
    public var controllingTTY: Int32? {
        guard let tdev, tdev != -1 else { return nil }
        return tdev
    }

    /// Input for `AgentSignatureMatching.match` (exe path + argv[0]/argv[1]; `p_comm` only as `comm`). A recorded
    /// Python `module` becomes `[argv0, "-m", module]`, the argv shape the matcher's interpreter rule reads.
    public var descriptor: ProcessDescriptor {
        let head = argv0 ?? exe ?? ""
        let rest: [String] = if let module { ["-m", module] } else { argv1.map { [$0] } ?? [] }
        return ProcessDescriptor(executablePath: path, argv: [head] + rest, comm: exe)
    }

    /// The hook's rule for recording argv[1]: a path-looking string (contains `/`, no whitespace, ≤ 512 bytes).
    public static func isRecordableArgv1(_ value: String) -> Bool {
        value.contains("/") && value.utf8.count <= 512 && !value.contains(where: \.isWhitespace)
    }

    /// Maximum length of a recorded Python module name.
    public static let maxModuleBytes = 128

    /// The hook's rule for recording a `-m` module: a plain dotted ASCII identifier (`aider`, `aider.main`,
    /// `openhands.cli`), ≤ 128 bytes. Anything else (spaces, slashes, quotes, a leading digit) is never recorded.
    public static func isRecordableModule(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maxModuleBytes else { return false }
        func isLetter(_ c: UInt8) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F } // A-Z a-z _
        func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            guard let first = part.utf8.first, isLetter(first) else { return false }
            return part.utf8.allSatisfy { isLetter($0) || isDigit($0) }
        }
    }

    /// True for a Python interpreter name (`python`, `python3`, `python3.12`, `Python`): the hook records `module`
    /// only for these.
    public static func isPythonInterpreterName(_ name: String) -> Bool {
        let base = name.split(separator: "/").last.map(String.init) ?? name
        return base.lowercased().hasPrefix("python")
    }

    private enum CodingKeys: String, CodingKey { case pid, ppid, startSec, startUsec, exe, argv0, argv1, path, tdev, module }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try c.decode(Int32.self, forKey: .pid)
        ppid = c.tolerantDecodeIfPresent(Int32.self, forKey: .ppid)
        startSec = c.tolerantDecode(Int64.self, forKey: .startSec, default: 0)
        startUsec = c.tolerantDecode(Int32.self, forKey: .startUsec, default: 0)
        exe = c.tolerantDecodeIfPresent(String.self, forKey: .exe)
        argv0 = c.tolerantDecodeIfPresent(String.self, forKey: .argv0)
        argv1 = c.tolerantDecodeIfPresent(String.self, forKey: .argv1)
        path = c.tolerantDecodeIfPresent(String.self, forKey: .path)
        tdev = c.tolerantDecodeIfPresent(Int32.self, forKey: .tdev)
        // Re-validated on decode: the header is untrusted input like any inbox content.
        module = c.tolerantDecodeIfPresent(String.self, forKey: .module).flatMap { Self.isRecordableModule($0) ? $0 : nil }
    }
}

/// Line 1 of an inbox file, written by `kakureneko-hook` itself (brief §4.3, binding schema).
///
/// ```json
/// {"v":1,"agent":"claude","event":"Stop","ts":1791811783024,"pid":7940,"ppid":7938,"cwd":"/Users/x/proj",
///  "payloadSource":"stdin","env":{"CLAUDE_PID":"96888", "TERM_PROGRAM":"Apple_Terminal"},
///  "ancestry":[{"pid":96888,"ppid":96880,"startSec":1791810323,"startUsec":1234,"exe":"2.1.296","argv0":"claude",
///               "path":"/Users/x/.local/share/claude/versions/2.1.296","tdev":268435460}]}
/// ```
/// Decoding is tolerant: unknown keys are ignored; `env`, `ancestry`, `cwd`, `payloadSource` may be absent.
public struct InboxHeader: Sendable, Hashable, Codable {
    /// Header schema version. Currently 1.
    public var v: Int
    /// argv[1] verbatim (`claude`, `codex`, …). Map with `AgentID(label:)`; attribution may relabel it.
    public var agent: String
    /// argv[2] verbatim — the raw event name (`Stop`, `notify`, `session.status`, …).
    public var event: String
    /// Epoch milliseconds when the hook ran.
    public var ts: Int64
    /// pid of the hook process.
    public var pid: Int32
    /// Parent of the hook (the agent itself for exec-form hooks, else its hook shell).
    public var ppid: Int32
    /// Working directory of the hook.
    public var cwd: String?
    /// Where the payload came from: `stdin`, `argv` (Codex notify: last argv JSON) or `none` (no payload, or
    /// stdin is a terminal — Aider runs the hook with the user's tty as stdin, which is never read).
    public var payloadSource: String?
    /// Allow-listed environment only (brief §4.3). Never contains tokens/keys/secrets.
    public var env: [String: String]
    /// Ancestry, nearest first, ≤ 8 entries.
    public var ancestry: [InboxAncestor]

    public static let currentVersion = 1

    public init(
        v: Int = InboxHeader.currentVersion,
        agent: String,
        event: String,
        ts: Int64,
        pid: Int32,
        ppid: Int32,
        cwd: String? = nil,
        payloadSource: String? = nil,
        env: [String: String] = [:],
        ancestry: [InboxAncestor] = []
    ) {
        self.v = v
        self.agent = agent
        self.event = event
        self.ts = ts
        self.pid = pid
        self.ppid = ppid
        self.cwd = cwd
        self.payloadSource = payloadSource
        self.env = env
        self.ancestry = ancestry
    }

    private enum CodingKeys: String, CodingKey { case v, agent, event, ts, pid, ppid, cwd, payloadSource, env, ancestry }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = c.tolerantDecode(Int.self, forKey: .v, default: 1)
        agent = try c.decode(String.self, forKey: .agent)
        event = try c.decode(String.self, forKey: .event)
        ts = try c.decode(Int64.self, forKey: .ts)
        pid = c.tolerantDecode(Int32.self, forKey: .pid, default: 0)
        ppid = c.tolerantDecode(Int32.self, forKey: .ppid, default: 0)
        cwd = c.tolerantDecodeIfPresent(String.self, forKey: .cwd)
        payloadSource = c.tolerantDecodeIfPresent(String.self, forKey: .payloadSource)
        env = c.tolerantDecode([String: String].self, forKey: .env, default: [:])
        ancestry = c.tolerantDecode([InboxAncestor].self, forKey: .ancestry, default: [])
    }

    /// Timestamp as `Date`.
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(ts) / 1000) }

    /// The env allow-list (brief §4.3). The hook copies only these keys; the app ignores any other key.
    public static let environmentAllowList: [String] = [
        // Claude
        "CLAUDE_PID", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_EXECPATH",
        "CLAUDE_CONFIG_DIR", "CLAUDE_PROJECT_DIR",
        // Cursor, Codex, Gemini, Copilot
        "CURSOR_VERSION", "CURSOR_PROJECT_DIR", "CODEX_HOME", "GEMINI_SESSION_ID", "GEMINI_CWD", "COPILOT_HOME",
        // Others
        "AI_AGENT", "FACTORY_PROJECT_DIR", "QWEN_PROJECT_DIR", "AUGMENT_CONVERSATION_ID", "DEVIN_PROJECT_DIR",
        "GROK_SESSION_ID", "OPENHANDS_SESSION_ID", "CRUSH_SESSION_ID",
        // Host
        "TERM_PROGRAM", "__CFBundleIdentifier", "TMUX", "ITERM_SESSION_ID",
    ]

    /// True if `name` may never be copied even if allow-listed by mistake (`/TOKEN|KEY|SECRET|PASSWORD/`).
    public static func isForbiddenEnvironmentName(_ name: String) -> Bool {
        let upper = name.uppercased()
        return ["TOKEN", "KEY", "SECRET", "PASSWORD"].contains { upper.contains($0) }
    }
}

/// The two-part inbox file (brief §4.3): line 1 = `InboxHeader` JSON, rest = agent payload byte for byte.
///
/// File name: `<19-digit epoch-ns>-<pid>.event`, written to `<inbox>/.tmp/<name>.tmp` with
/// `O_CREAT|O_EXCL|O_CLOEXEC` 0600 then `rename(2)`d into `<inbox>/`. The hook implements the writer
/// in Darwin-only Swift; this type is the reference implementation the app and tests use.
public enum InboxFile {
    public static let fileExtension = "event"
    public static let tempExtension = "tmp"
    /// Hook back-pressure: above this many files in the inbox the hook drops the event (exit 0).
    public static let maxQueuedFiles = 5_000
    /// Payload cap (hook reads at most this much stdin).
    public static let maxPayloadBytes = 4 << 20
    /// Header line cap enforced by the app when parsing.
    public static let maxHeaderBytes = 64 << 10
    /// `bad/` and `.tmp/` entries older than this are garbage-collected by the app.
    public static let garbageCollectionAge: TimeInterval = 24 * 3600

    public enum ParseError: Error, Sendable, Equatable {
        case noHeaderLine
        case headerTooLarge(Int)
        case badHeader(String)
        case unsupportedVersion(Int)
    }

    /// `0001791811783024000-7940.event` (19-digit zero-padded nanoseconds; lexicographic = chronological).
    public static func fileName(epochNanoseconds: UInt64, pid: Int32) -> String {
        let digits = String(epochNanoseconds)
        let padded = String(repeating: "0", count: max(0, 19 - digits.count)) + digits
        return "\(padded)-\(pid).\(fileExtension)"
    }

    /// Parses `<ns>-<pid>.event`.
    public static func parseFileName(_ name: String) -> (epochNanoseconds: UInt64, pid: Int32)? {
        guard name.hasSuffix(".\(fileExtension)") else { return nil }
        let stem = name.dropLast(fileExtension.count + 1)
        let parts = stem.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, let ns = UInt64(parts[0]), let pid = Int32(parts[1]) else { return nil }
        return (ns, pid)
    }

    /// Splits and decodes a file's contents.
    public static func parse(_ data: Data) throws(ParseError) -> (header: InboxHeader, payload: Data) {
        guard let newline = data.firstIndex(of: 0x0A) else {
            if data.count > maxHeaderBytes { throw .headerTooLarge(data.count) }
            throw .noHeaderLine
        }
        let headerBytes = data[data.startIndex..<newline]
        if headerBytes.count > maxHeaderBytes { throw .headerTooLarge(headerBytes.count) }
        let header: InboxHeader
        do {
            header = try JSONDecoder().decode(InboxHeader.self, from: Data(headerBytes))
        } catch {
            throw .badHeader(String(describing: error))
        }
        guard header.v >= 1 else { throw .unsupportedVersion(header.v) }
        let payload = Data(data[data.index(after: newline)...])
        return (header, payload)
    }

    /// Serializes a header + payload exactly like the hook does (tests and in-process emitters).
    public static func serialize(header: InboxHeader, payload: Data) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out = try encoder.encode(header)
        out.append(0x0A)
        out.append(payload)
        return out
    }
}
