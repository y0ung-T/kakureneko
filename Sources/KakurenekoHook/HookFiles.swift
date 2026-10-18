import Darwin

/// Filesystem helpers: `<root>` resolution, directory creation, atomic writes.
enum HookFiles {
    /// `<root>`: the `.kakureneko` directory holding this binary when it runs as `…/.kakureneko/bin/kakureneko-hook`
    /// (a `KAKURENEKO_HOME` dev install stays inside its fake home), else `$HOME/.kakureneko`.
    static var root: String { root(executablePath: ownExecutablePath(), home: homeDirectory()) }

    /// The `.kakureneko` directory containing `executablePath` when it is `…/.kakureneko/bin/kakureneko-hook`, else
    /// `<home>/.kakureneko`.
    static func root(executablePath: String?, home: String) -> String {
        if let own = executablePath, own.hasSuffix(HookConstants.ownBinarySuffix) {
            return String(own.dropLast("/bin/kakureneko-hook".count))
        }
        return home + "/.kakureneko"
    }

    static func ownExecutablePath() -> String? {
        var buffer = [CChar](repeating: 0, count: HookAncestry.pathBufferSize)
        return HookAncestry.executablePath(of: getpid(), buffer: &buffer)
    }

    /// `$HOME` when absolute, else the password database entry, else the per-user temp directory (0700) — never a
    /// shared directory like `/tmp`, where another user could create `.kakureneko/inbox` first and read payloads.
    static func homeDirectory() -> String {
        if let home = HookEnvironment.value("HOME"), home.hasPrefix("/") { return trimmedTrailingSlash(home) }
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return trimmedTrailingSlash(String(cString: dir))
        }
        return darwinUserTempDirectory() ?? "/var/empty"
    }

    static func trimmedTrailingSlash(_ path: String) -> String {
        var path = path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// `mkdir -p` with mode 0700 for every component it creates. True when `path` exists as a directory.
    @discardableResult
    static func makeDirectories(_ path: String) -> Bool {
        if isDirectory(path) { return true }
        var current = path.hasPrefix("/") ? "" : "."
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            current += "/" + component
            if mkdir(current, 0o700) != 0 && errno != EEXIST { return false }
        }
        return isDirectory(path)
    }

    static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// Writes `bytes` to a fresh file (`O_CREAT|O_EXCL|O_CLOEXEC`, 0600). Returns errno on failure (0 = ok).
    static func writeExclusive(_ path: String, _ bytes: [UInt8]) -> Int32 {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return errno }
        let failure = writeAll(fd, bytes)
        close(fd)
        if failure != 0 { unlink(path) }
        return failure
    }

    /// `write(2)` loop. Returns errno on failure (0 = ok).
    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Int32 {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, $0.count - offset) }
            if n < 0 {
                if errno == EINTR { continue }
                return errno
            }
            if n == 0 { return EIO }
            offset += n
        }
        return 0
    }

    /// Counts `*.event` entries, stopping once `limit` is exceeded (cheap back-pressure check).
    static func countEvents(in directory: String, exceeding limit: Int) -> Int {
        guard let dir = opendir(directory) else { return 0 }
        defer { closedir(dir) }
        var count = 0
        let suffix = Array(".event".utf8)
        while let entry = readdir(dir) {
            var name = entry.pointee.d_name
            let length = Int(entry.pointee.d_namlen)
            let matches = withUnsafeBytes(of: &name) { raw -> Bool in
                guard length > suffix.count, length <= raw.count else { return false }
                return Array(raw[(length - suffix.count)..<length]) == suffix
            }
            if matches {
                count += 1
                if count > limit { break }
            }
        }
        return count
    }

    /// `confstr(_CS_DARWIN_USER_TEMP_DIR)` (trailing slash removed).
    static func darwinUserTempDirectory() -> String? {
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, size) > 0 else { return nil }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return path.isEmpty ? nil : trimmedTrailingSlash(path)
    }
}

/// Inbox delivery: `$KAKURENEKO_INBOX` → `<root>/inbox` → fallback (`$KAKURENEKO_FALLBACK_INBOX` ?? user temp dir).
enum HookInbox {
    enum Outcome {
        case written(usedFallback: Bool, primaryError: String)
        /// Back-pressure: the inbox already holds more than `maxQueuedFiles` events.
        case dropped(inbox: String)
        case failed(String)
    }

    private enum Attempt {
        case written
        case dropped
        case failed(String)
    }

    static func deliver(_ file: [UInt8], epochNanoseconds: UInt64, root: String) -> Outcome {
        let primary = primaryInbox(root: root, override: HookEnvironment.value(HookConstants.inboxVariable))
        let primaryError: String
        switch attempt(file, inbox: primary, epochNanoseconds: epochNanoseconds) {
        case .written: return .written(usedFallback: false, primaryError: "")
        case .dropped: return .dropped(inbox: primary)
        case .failed(let reason): primaryError = reason
        }
        guard let fallback = fallbackInbox() else { return .failed("primary: \(primaryError); no fallback inbox") }
        switch attempt(file, inbox: fallback, epochNanoseconds: epochNanoseconds) {
        case .written: return .written(usedFallback: true, primaryError: primaryError)
        case .dropped: return .dropped(inbox: fallback)
        case .failed(let reason): return .failed("primary: \(primaryError); fallback: \(reason)")
        }
    }

    /// `$KAKURENEKO_INBOX` (tests) → `<root>/inbox`.
    static func primaryInbox(root: String, override: String?) -> String {
        override.map(HookFiles.trimmedTrailingSlash) ?? root + "/inbox"
    }

    static func fallbackInbox() -> String? {
        fallbackInbox(override: HookEnvironment.value(HookConstants.fallbackInboxVariable),
                      userTemp: HookFiles.darwinUserTempDirectory())
    }

    /// `$KAKURENEKO_FALLBACK_INBOX` (tests) → `confstr(_CS_DARWIN_USER_TEMP_DIR)/com.kakureneko/inbox`.
    static func fallbackInbox(override: String?, userTemp: String?) -> String? {
        if let override { return HookFiles.trimmedTrailingSlash(override) }
        return userTemp.map { $0 + "/" + HookConstants.fallbackInboxRelativePath }
    }

    /// `<inbox>/.tmp/<ns>-<pid>.tmp` → `rename(2)` → `<inbox>/<ns>-<pid>.event`.
    private static func attempt(_ file: [UInt8], inbox: String, epochNanoseconds: UInt64) -> Attempt {
        let temporaryDirectory = inbox + "/.tmp"
        guard HookFiles.makeDirectories(temporaryDirectory) else { return .failed("mkdir errno \(errno)") }
        if HookFiles.countEvents(in: inbox, exceeding: HookConstants.maxQueuedFiles) > HookConstants.maxQueuedFiles {
            return .dropped
        }
        var nanoseconds = epochNanoseconds
        for _ in 0..<4 {
            let stem = fileStem(epochNanoseconds: nanoseconds)
            let temporaryPath = temporaryDirectory + "/" + stem + ".tmp"
            let failure = HookFiles.writeExclusive(temporaryPath, file)
            if failure == EEXIST {
                nanoseconds += 1
                continue
            }
            guard failure == 0 else { return .failed("write errno \(failure)") }
            let finalPath = inbox + "/" + stem + ".event"
            guard rename(temporaryPath, finalPath) == 0 else {
                let code = errno
                unlink(temporaryPath)
                return .failed("rename errno \(code)")
            }
            return .written
        }
        return .failed("name collision")
    }

    /// `<19-digit zero-padded ns>-<pid>` (`InboxFile.fileName` without the extension).
    static func fileStem(epochNanoseconds: UInt64) -> String {
        let digits = String(epochNanoseconds)
        return String(repeating: "0", count: max(0, 19 - digits.count)) + digits + "-" + String(getpid())
    }
}

/// `<root>/log/hook.log` diagnostics (never payloads), rotated to `hook.log.1` above 1 MB.
enum HookLog {
    static func write(root: String, invocation: HookInvocation, _ message: String) {
        let directory = root + "/log"
        guard HookFiles.makeDirectories(directory) else { return }
        let path = directory + "/hook.log"
        var info = stat()
        if stat(path, &info) == 0, Int(info.st_size) >= HookConstants.logRotateBytes {
            _ = rename(path, path + ".1")
        }
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let milliseconds = clock_gettime_nsec_np(CLOCK_REALTIME) / 1_000_000
        let agent = invocation.hasValidLabels ? invocation.agent : "?"
        let event = invocation.hasValidLabels ? invocation.event : "?"
        let line = "\(milliseconds) pid=\(getpid()) \(agent) \(event): \(message)\n"
        _ = HookFiles.writeAll(fd, Array(line.utf8))
    }
}

/// `KAKURENEKO_RECORD=1`: `<root>/recordings/<agent>/<event>-<ts>.json` with argv, the raw stdin and the
/// allow-listed environment (fixtures for normalizer tests, brief §3.7.7).
enum HookRecorder {
    static func record(
        root: String,
        invocation: HookInvocation,
        timestampMilliseconds: Int64,
        payload: HookPayload,
        environment: [(name: String, value: String)]
    ) {
        let directory = root + "/recordings/" + invocation.agent
        guard HookFiles.makeDirectories(directory) else { return }
        var json = HookJSONWriter(capacity: payload.bytes.count + 1_024)
        json.raw("{")
        json.integerField("v", HookConstants.headerVersion, leadingComma: false)
        json.stringField("agent", invocation.agent)
        json.stringField("event", invocation.event)
        json.integerField("ts", timestampMilliseconds)
        json.integerField("pid", getpid())
        json.integerField("ppid", getppid())
        if let cwd = HookHeader.currentDirectory() { json.stringField("cwd", cwd) }
        json.stringField("payloadSource", payload.source.rawValue)
        json.raw(#","argv":["#)
        for (index, argument) in invocation.arguments.enumerated() {
            if index > 0 { json.raw(",") }
            json.string(argument)
        }
        json.raw("]")
        if payload.source == .stdin {
            json.stringField("stdin", String(decoding: payload.bytes, as: UTF8.self))
        }
        json.raw(#","env":{"#)
        for (index, entry) in environment.enumerated() {
            json.stringField(entry.name, entry.value, leadingComma: index > 0)
        }
        json.raw("}}\n")
        let base = directory + "/" + invocation.event + "-" + String(timestampMilliseconds)
        if HookFiles.writeExclusive(base + ".json", json.bytes) == EEXIST {
            _ = HookFiles.writeExclusive(base + "-" + String(getpid()) + ".json", json.bytes)
        }
    }
}
