import Darwin

/// One ancestor of the hook (`InboxAncestor` on the app side).
struct HookAncestor {
    var pid: Int32
    var ppid: Int32
    var startSec: Int64
    var startUsec: Int32
    /// `p_comm`
    var exe: String
    var argv0: String?
    /// Only when `isRecordableArgv1` (path-like); argv[1] can be a prompt.
    var argv1: String?
    /// `proc_pidpath`
    var path: String?
    /// `e_tdev` (-1 = no controlling tty)
    var tdev: Int32
    /// `python … -m <module>`: the module name, only for Python interpreters and only a plain dotted identifier
    /// (`InboxAncestor.isRecordableModule`), so `python -m aider` can be attributed.
    var module: String? = nil
}

/// Walks the parent chain with `sysctl(KERN_PROC_PID)` (works through root-owned `login`), reading argv with ONE
/// `KERN_PROCARGS2` call per ancestor into a reused 16 KiB buffer (argv only, never the environment).
enum HookAncestry {
    static let argumentBufferSize = 16 * 1024
    /// `PROC_PIDPATHINFO_MAXSIZE` (4 × MAXPATHLEN; the macro is not imported into Swift).
    static let pathBufferSize = 4 * 1024
    static let maxArgv0Bytes = 1_024
    static let maxArgv1Bytes = 512

    static func collect(startingAt firstPID: Int32) -> [HookAncestor] {
        var ancestors: [HookAncestor] = []
        var argumentBuffer = [UInt8](repeating: 0, count: argumentBufferSize)
        var pathBuffer = [CChar](repeating: 0, count: pathBufferSize)
        var pid = firstPID
        var seen: Set<Int32> = []
        while ancestors.count < HookConstants.maxAncestors, pid > 1, !seen.contains(pid) {
            seen.insert(pid)
            guard let info = kernelInfo(pid) else { break }
            let start = info.kp_proc.p_un.__p_starttime
            let parsed = arguments(of: pid, buffer: &argumentBuffer)
            ancestors.append(HookAncestor(
                pid: pid,
                ppid: info.kp_eproc.e_ppid,
                startSec: Int64(start.tv_sec),
                startUsec: Int32(start.tv_usec),
                exe: HookText.string(fromCTuple: info.kp_proc.p_comm),
                argv0: parsed.argv0,
                argv1: parsed.argv1,
                path: executablePath(of: pid, buffer: &pathBuffer),
                tdev: info.kp_eproc.e_tdev,
                module: parsed.module
            ))
            pid = info.kp_eproc.e_ppid
        }
        return ancestors
    }

    /// `sysctl({CTL_KERN, KERN_PROC, KERN_PROC_PID, pid})` — the same call as `KernelProcessLookup`, so the
    /// `(pid, startSec, startUsec)` identity matches every other module's (ARCHITECTURE §8).
    static func kernelInfo(_ pid: Int32) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let rc = mib.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, 4, &info, &size, nil, 0) }
        guard rc == 0, size >= MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else { return nil }
        return info
    }

    /// Largest argument area the hook will read (`ARG_MAX` is 1 MiB on macOS).
    static let maxArgumentAreaBytes = (1 << 20) + 4_096

    /// argv[0], (path-like only) argv[1] and (Python only) the `-m` module from `KERN_PROCARGS2`:
    /// `int32 argc | exec_path\0 | \0 padding | argv[0]\0 | argv[1]\0 | … | envp…` (env is never touched).
    static func arguments(of pid: Int32, buffer: inout [UInt8]) -> (argv0: String?, argv1: String?, module: String?) {
        guard let size = readArgumentArea(of: pid, into: &buffer), size > MemoryLayout<Int32>.size else {
            return (nil, nil, nil)
        }
        return parseArguments(buffer, size: size)
    }

    /// One `KERN_PROCARGS2` read into the reused buffer; returns the byte count, or nil when unusable.
    ///
    /// When the argument area does not fit, the kernel silently copies its TAIL (the end of argv/env), not its head
    /// — verified on macOS 26 with a 40 KB argv and a 16 KiB buffer. Parsing that would report environment or
    /// prompt bytes as argv[0]/argv[1]. So a completely filled buffer counts as possibly truncated: the exact size
    /// is queried (no copy) and the reused buffer grows once (≤ `maxArgumentAreaBytes`) for a re-read; if it still
    /// does not fit, nothing is reported for this ancestor.
    static func readArgumentArea(of pid: Int32, into buffer: inout [UInt8]) -> Int? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        func read(_ buffer: inout [UInt8]) -> Int? {
            var size = buffer.count
            let rc = buffer.withUnsafeMutableBytes { raw in
                mib.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, 3, raw.baseAddress, &size, nil, 0) }
            }
            return rc == 0 ? min(size, buffer.count) : nil
        }
        guard let size = read(&buffer) else { return nil }
        if size < buffer.count { return size }
        var needed = 0
        let rc = mib.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, 3, nil, &needed, nil, 0) }
        guard rc == 0, needed > 0, needed + 4_096 <= maxArgumentAreaBytes else { return nil }
        if buffer.count < needed + 4_096 { buffer = [UInt8](repeating: 0, count: needed + 4_096) }
        guard let second = read(&buffer), second < buffer.count else { return nil }
        return second
    }

    /// argv strings looked at for a Python `-m` (interpreter options come first: `python3 -u -X dev -m aider`).
    static let maxScannedArguments = 8
    /// Strings longer than this are never a module name or an option: they end the `-m` scan.
    static let maxScannedArgumentBytes = 512

    /// Parses argv[0], argv[1] (path-like only) and a Python `-m` module out of a `KERN_PROCARGS2` area of `size`
    /// bytes. Never reads past argv[argc − 1] (the environment follows).
    static func parseArguments(_ buffer: [UInt8], size: Int) -> (argv0: String?, argv1: String?, module: String?) {
        guard size > MemoryLayout<Int32>.size else { return (nil, nil, nil) }
        let end = min(size, buffer.count)
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return (nil, nil, nil) }
        var index = MemoryLayout<Int32>.size
        // exec_path (only used to recognise a Python interpreter), then the NUL padding after it.
        let execBegin = index
        while index < end, buffer[index] != 0 { index += 1 }
        let execPath = String(decoding: buffer[execBegin..<min(index, execBegin + HookConstants.maxValueBytes)], as: UTF8.self)
        while index < end, buffer[index] == 0 { index += 1 }
        var strings: [String] = []
        while strings.count < min(Int(argc), maxScannedArguments), index < end {
            let begin = index
            while index < end, buffer[index] != 0 { index += 1 }
            guard index < end else { break } // truncated string: unusable
            strings.append(String(decoding: buffer[begin..<min(index, begin + maxScannedArgumentBytes + 1)], as: UTF8.self))
            index += 1
        }
        let argv0 = strings.first.map { HookText.truncated($0, maxBytes: maxArgv0Bytes) }
        let argv1 = strings.count > 1 && isRecordableArgv1(strings[1]) ? strings[1] : nil
        let python = strings.first.map(isPythonInterpreter) == true || isPythonInterpreter(execPath)
        let module = python ? pythonModule(strings) : nil
        return (argv0.flatMap { $0.isEmpty ? nil : $0 }, argv1, module)
    }

    /// Same rule as `InboxAncestor.isRecordableArgv1`: contains `/`, no whitespace, ≤ 512 bytes.
    static func isRecordableArgv1(_ value: String) -> Bool {
        value.contains("/") && value.utf8.count <= maxArgv1Bytes && !value.contains(where: \.isWhitespace)
    }

    /// Same rule as `InboxAncestor.isPythonInterpreterName`: the basename starts with `python` (any case).
    static func isPythonInterpreter(_ name: String) -> Bool {
        let base = name.split(separator: "/").last.map(String.init) ?? name
        return base.lowercased().hasPrefix("python")
    }

    /// Python options that take a separate value (skipped while looking for `-m`).
    static let pythonValueOptions: Set<String> = ["-W", "-X", "--check-hash-based-pycs"]

    /// The `-m` module of a Python argv (`[python, opts…, -m, module, …]` or `-mmodule`), when it is a plain dotted
    /// identifier (`InboxAncestor.isRecordableModule`). A script path, `-c`, `-` or anything else ends the scan.
    static func pythonModule(_ argv: [String]) -> String? {
        var index = 1
        while index < argv.count {
            let arg = argv[index]
            if arg == "-m" {
                return index + 1 < argv.count && isRecordableModule(argv[index + 1]) ? argv[index + 1] : nil
            }
            if arg.hasPrefix("-m"), arg.utf8.count > 2 {
                let module = String(arg.dropFirst(2))
                return isRecordableModule(module) ? module : nil
            }
            if arg == "-c" || arg == "-" || arg == "--" || !arg.hasPrefix("-") { return nil }
            index += pythonValueOptions.contains(arg) ? 2 : 1
        }
        return nil
    }

    /// Same rule as `InboxAncestor.isRecordableModule`: a plain dotted ASCII identifier, ≤ 128 bytes.
    static func isRecordableModule(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        func isLetter(_ c: UInt8) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F }
        func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            guard let first = part.utf8.first, isLetter(first) else { return false }
            return part.utf8.allSatisfy { isLetter($0) || isDigit($0) }
        }
    }

    static func executablePath(of pid: Int32, buffer: inout [CChar]) -> String? {
        let length = buffer.withUnsafeMutableBufferPointer { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(Int(length)).prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let path = String(decoding: bytes, as: UTF8.self)
        return path.isEmpty ? nil : HookText.truncated(path, maxBytes: HookConstants.maxValueBytes)
    }
}
