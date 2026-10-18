import Darwin
import Foundation
import os
import Synchronization

/// os.Logger categories (subsystem `com.kakureneko.Kakureneko`). One per module plus cross-cutting ones.
public enum LogCategory: String, Sendable, Codable, CaseIterable {
    case app
    case events
    case processes
    case sessions
    case power
    case pause
    case notify
    case install
    case coordinator
    /// Every "would …" line written while dry-run is active.
    case dryRun = "dryrun"
    case hook
    case guardian = "guard"
}

/// Severity levels mirrored into the optional file log.
public enum LogLevel: String, Sendable, Codable, CaseIterable, Comparable {
    case debug, info, notice, warning, error

    private var rank: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .notice: 2
        case .warning: 3
        case .error: 4
        }
    }
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rank < rhs.rank }
}

/// Structured logger: os.Logger + optional plain-text file sink.
///
/// Every service takes a `KakurenekoLogger` in its initializer (default: os only). There is no global
/// logger state. Privacy rule (binding): never log secrets (HMAC keys, topics, tokens), hook payload
/// bodies, prompt text or assistant messages. Log decisions, identities (pid/start) and counts.
public struct KakurenekoLogger: Sendable {
    public let category: LogCategory
    private let logger: Logger
    private let sink: FileLogSink?

    public init(_ category: LogCategory, sink: FileLogSink? = nil) {
        self.category = category
        self.logger = Logger(subsystem: KakurenekoID.logSubsystem, category: category.rawValue)
        self.sink = sink
    }

    /// Same sink, different category.
    public func with(category: LogCategory) -> KakurenekoLogger { KakurenekoLogger(category, sink: sink) }

    public func debug(_ message: @autoclosure () -> String) { log(.debug, message()) }
    public func info(_ message: @autoclosure () -> String) { log(.info, message()) }
    public func notice(_ message: @autoclosure () -> String) { log(.notice, message()) }
    public func warning(_ message: @autoclosure () -> String) { log(.warning, message()) }
    public func error(_ message: @autoclosure () -> String) { log(.error, message()) }

    public func log(_ level: LogLevel, _ message: String) {
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .notice: logger.notice("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
        sink?.write(level: level, category: category, message: message)
    }
}

/// Append-only plain-text log file (`~/.kakureneko/log/kakureneko.log` by default), rotated to `<name>.1`
/// when it exceeds `maxBytes`. Thread-safe. Lines: `<ISO8601> <level> [<category>] <message>`.
public final class FileLogSink: Sendable {
    public let url: URL
    public let maxBytes: Int
    public let minimumLevel: LogLevel
    private let state = Mutex<Int32>(-1)

    public init(url: URL, maxBytes: Int = 1 << 20, minimumLevel: LogLevel = .info) {
        self.url = url
        self.maxBytes = maxBytes
        self.minimumLevel = minimumLevel
    }

    deinit {
        state.withLock { fd in
            if fd >= 0 { close(fd) }
            fd = -1
        }
    }

    public func write(level: LogLevel, category: LogCategory, message: String) {
        guard level >= minimumLevel else { return }
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
        let line = "\(stamp) \(level.rawValue) [\(category.rawValue)] \(message.replacingOccurrences(of: "\n", with: "\\n"))\n"
        let bytes = Array(line.utf8)
        let path = url.path(percentEncoded: false)
        state.withLock { fd in
            if fd < 0 {
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
                if fd < 0 { return }
            }
            var st = stat()
            if fstat(fd, &st) == 0, Int(st.st_size) + bytes.count > maxBytes {
                close(fd)
                _ = rename(path, path + ".1")
                fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
                if fd < 0 { return }
            }
            _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        }
    }
}
