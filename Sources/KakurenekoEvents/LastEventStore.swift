import KakurenekoKit
import Foundation

/// Persisted proof of life (brief §3.7 item 6): `~/.kakureneko/run/last-events.json`, a JSON object keyed by the
/// DELIVERING integration's agent label (`{"claude":"2026-10-12T22:00:00.000Z", …}`, `KakurenekoJSON` dates).
///
/// Decoding is tolerant: unknown labels and malformed values are skipped, a corrupt file reads as empty (and is
/// replaced on the next write). Writes are atomic (`AtomicFile`, mode 0600).
struct LastEventStore: Sendable {
    struct Loaded: Sendable {
        var values: [AgentID: Date]
        /// Why the file could not be used (nil when it was read or does not exist).
        var failure: String?
    }

    let file: URL

    func load() -> Loaded {
        let data: Data?
        do {
            data = try AtomicFile.readIfExists(file)
        } catch {
            return Loaded(values: [:], failure: String(describing: error))
        }
        guard let data else { return Loaded(values: [:], failure: nil) }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Loaded(values: [:], failure: "not a JSON object")
        }
        var values: [AgentID: Date] = [:]
        for (label, raw) in object {
            let agent = AgentID(label: label)
            guard agent != .unknown else { continue }
            let date: Date?
            switch raw {
            case let text as String: date = KakurenekoJSON.date(fromISO8601: text)
            case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
                date = Date(timeIntervalSince1970: number.doubleValue)
            default: date = nil
            }
            if let date, date > (values[agent] ?? .distantPast) { values[agent] = date }
        }
        return Loaded(values: values, failure: nil)
    }

    func save(_ values: [AgentID: Date]) throws {
        var byLabel: [String: Date] = [:]
        for (agent, date) in values where agent != .unknown { byLabel[agent.rawValue] = date }
        let data = try KakurenekoJSON.encode(byLabel)
        try AtomicFile.write(data, to: file, permissions: 0o600)
    }
}
