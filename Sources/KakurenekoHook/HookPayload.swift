import Darwin

/// The event payload and where it came from (`InboxHeader.payloadSource`).
struct HookPayload {
    enum Source: String {
        case stdin, argv, none
    }

    var bytes: [UInt8]
    var source: Source

    /// Inactivity limit between stdin chunks (contract: 300 ms poll idle limit).
    static let idleMilliseconds: Int32 = 300
    /// Total stdin budget, so a slowly dripping writer can never push the run into the 2 s watchdog before the
    /// inbox file is written.
    static let totalBudgetMilliseconds: UInt64 = 1_200

    /// argv JSON wins; a terminal stdin is NEVER read (Aider: the user's tty); otherwise stdin (bounded). Aider's
    /// stdin is never read at all: it sends no payload, and a piped stdin there is input meant for Aider itself.
    static func collect(argvPayload: [UInt8]?, agent: String? = nil) -> HookPayload {
        if let argvPayload { return HookPayload(bytes: argvPayload, source: .argv) }
        guard agent != "aider", fcntl(STDIN_FILENO, F_GETFD) != -1, isatty(STDIN_FILENO) == 0 else {
            return HookPayload(bytes: [], source: .none)
        }
        let bytes = readStandardInput()
        return HookPayload(bytes: bytes, source: bytes.isEmpty ? .none : .stdin)
    }

    /// Reads stdin to EOF with the idle limit, the total budget and the 4 MiB cap. Beyond the cap a pipe or socket
    /// is drained and discarded (the writer never sees EPIPE); any other descriptor stops at the cap.
    private static func readStandardInput() -> [UInt8] {
        var info = stat()
        let isStream = fstat(STDIN_FILENO, &info) == 0
            && ((info.st_mode & S_IFMT) == S_IFIFO || (info.st_mode & S_IFMT) == S_IFSOCK)
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var collected: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        while true {
            let elapsed = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1_000_000
            guard elapsed < totalBudgetMilliseconds else { break }
            let timeout = Int32(min(UInt64(idleMilliseconds), totalBudgetMilliseconds - elapsed))
            descriptor.revents = 0
            let ready = poll(&descriptor, 1, timeout)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { break } // idle: the writer keeps stdin open but sends nothing more
            let count = chunk.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                break
            }
            if count == 0 { break } // EOF
            let room = HookConstants.maxPayloadBytes - collected.count
            if room > 0 { collected.append(contentsOf: chunk[0..<min(count, room)]) }
            if collected.count >= HookConstants.maxPayloadBytes && !isStream { break }
        }
        return collected
    }
}
