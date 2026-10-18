import Darwin
import notify

/// SIGALRM watchdog (contract: `alarm(2)` + SIGALRM → `_exit(0)`). A global function so it converts to a
/// `@convention(c)` handler without captures.
func hookWatchdogFired(_ signal: Int32) {
    _exit(0)
}

/// The whole hook run. Every path ends in `exit(0)`; nothing is ever written to stderr, and stdout only carries
/// the two documented answers (`HookResponse`).
enum HookMain {
    /// Hard ceiling for one hook run (contract: `alarm(2)`).
    static let watchdogSeconds: UInt32 = 2

    static func run(_ arguments: [String]) -> Never {
        signal(SIGALRM, hookWatchdogFired)
        alarm(watchdogSeconds)
        signal(SIGPIPE, SIG_IGN)

        guard let invocation = HookInvocation(arguments: arguments) else { exit(0) }
        // Answer first: the agent may be waiting for the decision while we collect the rest.
        HookResponse.write(for: invocation)
        guard invocation.hasValidLabels else { exit(0) }

        let root = HookFiles.root
        let payload = HookPayload.collect(argvPayload: invocation.argvPayload, agent: invocation.agent)
        if !invocation.chain.isEmpty {
            var chained = invocation.chain
            // Only an argv payload (Codex notify) is forwarded; a stdin payload never becomes an argument.
            if payload.source == .argv { chained.append(String(decoding: payload.bytes, as: UTF8.self)) }
            if !HookChain.spawnDetached(chained) {
                HookLog.write(root: root, invocation: invocation, "chain spawn failed (errno \(errno))")
            }
        }

        let nanoseconds = clock_gettime_nsec_np(CLOCK_REALTIME)
        let timestampMilliseconds = Int64(nanoseconds / 1_000_000)
        let environment = HookEnvironment.allowListed()
        let header = HookHeader.bounded(
            invocation: invocation,
            timestampMilliseconds: timestampMilliseconds,
            payloadSource: payload.source,
            environment: environment,
            ancestry: HookAncestry.collect(startingAt: getppid())
        )
        var file = header
        file.append(0x0A)
        file.append(contentsOf: payload.bytes)

        switch HookInbox.deliver(file, epochNanoseconds: nanoseconds, root: root) {
        case .written(let usedFallback, let primaryError):
            if usedFallback {
                HookLog.write(root: root, invocation: invocation, "primary inbox not writable (\(primaryError)); used fallback")
            }
            notify_post(HookConstants.inboxDarwinNotification)
        case .dropped(let inbox):
            HookLog.write(root: root, invocation: invocation, "more than \(HookConstants.maxQueuedFiles) queued files in \(inbox); event dropped")
        case .failed(let reason):
            HookLog.write(root: root, invocation: invocation, "event not delivered: \(reason)")
        }

        if HookEnvironment.isTruthy(getenv(HookConstants.recordVariable)) {
            HookRecorder.record(
                root: root,
                invocation: invocation,
                timestampMilliseconds: timestampMilliseconds,
                payload: payload,
                environment: environment
            )
        }
        exit(0)
    }
}

/// Constants mirrored from KakurenekoKit (the hook links nothing but Darwin; KakurenekoEventsTests verify parity
/// end to end against `InboxHeader`/`InboxFile`/`KakurenekoID`).
enum HookConstants {
    static let inboxDarwinNotification = "com.kakureneko.inbox"
    static let ownBinarySuffix = "/.kakureneko/bin/kakureneko-hook"
    static let fallbackInboxRelativePath = "com.kakureneko/inbox"
    static let maxQueuedFiles = 5_000
    static let maxPayloadBytes = 4 << 20
    /// `InboxFile.maxHeaderBytes`: the app rejects longer header lines.
    static let maxHeaderBytes = 64 << 10
    static let maxAncestors = 8
    static let headerVersion = 1
    static let inboxVariable = "KAKURENEKO_INBOX"
    static let fallbackInboxVariable = "KAKURENEKO_FALLBACK_INBOX"
    static let recordVariable = "KAKURENEKO_RECORD"
    static let logRotateBytes = 1 << 20
    /// Per-string caps inside the header (the header must stay well below `InboxFile.maxHeaderBytes` = 64 KiB).
    static let maxValueBytes = 1_024
    static let maxLabelBytes = 64
}

/// The two documented stdout answers (brief §4.2). Everything else keeps stdout empty.
enum HookResponse {
    static func write(for invocation: HookInvocation) {
        let answer: StaticString
        if invocation.agent == "cursor" && invocation.event == "beforeSubmitPrompt" {
            answer = #"{"continue":true}"#
        } else if invocation.agent == "cline" {
            answer = #"{"cancel":false}"#
        } else {
            return
        }
        var offset = 0
        let count = answer.utf8CodeUnitCount
        while offset < count {
            let n = Darwin.write(STDOUT_FILENO, answer.utf8Start + offset, count - offset)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return }
            offset += n
        }
    }
}

/// The environment allow-list (identical to `InboxHeader.environmentAllowList`).
enum HookEnvironment {
    static let allowList: [String] = [
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

    /// `/TOKEN|KEY|SECRET|PASSWORD/` (case-insensitive) — never copied, even if allow-listed by mistake.
    static func isForbidden(_ name: String) -> Bool {
        let upper = name.uppercased()
        return ["TOKEN", "KEY", "SECRET", "PASSWORD"].contains { upper.contains($0) }
    }

    /// Allow-listed variables that are set, in allow-list order, values capped.
    static func allowListed() -> [(name: String, value: String)] {
        var result: [(name: String, value: String)] = []
        for name in allowList where !isForbidden(name) {
            guard let raw = getenv(name) else { continue }
            result.append((name, HookText.truncated(String(cString: raw), maxBytes: HookConstants.maxValueBytes)))
        }
        return result
    }

    /// `1`, `true`, `yes`, `on` (case-insensitive) — same rule as `KakurenekoEnvironment.isTruthy`.
    static func isTruthy(_ raw: UnsafeMutablePointer<CChar>?) -> Bool {
        guard let raw else { return false }
        let value = String(cString: raw).lowercased().filter { $0 != " " && $0 != "\t" }
        return value == "1" || value == "true" || value == "yes" || value == "on"
    }

    /// `getenv` as a non-empty Swift string.
    static func value(_ name: String) -> String? {
        guard let raw = getenv(name) else { return nil }
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }
}

/// Small string helpers (no Foundation).
enum HookText {
    /// `value` cut to at most `maxBytes` UTF-8 bytes on a scalar boundary.
    static func truncated(_ value: String, maxBytes: Int) -> String {
        guard value.utf8.count > maxBytes else { return value }
        var result = String.UnicodeScalarView()
        var used = 0
        for scalar in value.unicodeScalars {
            let size = UTF8.width(scalar)
            if used + size > maxBytes { break }
            result.append(scalar)
            used += size
        }
        return String(result)
    }

    /// Decodes a NUL-terminated C buffer (repairs invalid UTF-8).
    static func string<T>(fromCTuple tuple: T) -> String {
        var copy = tuple
        return withUnsafeBytes(of: &copy) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
