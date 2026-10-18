import Foundation

/// The one JSON configuration for every file Kakureneko persists (settings, outbox, journal,
/// manifest, resume manifest, notify state) and for Codable round-trips in tests.
///
/// * Dates: ISO 8601 UTC with milliseconds (`2026-10-12T22:00:00.000Z`); decoding also accepts
///   ISO 8601 without fractional seconds and numeric epoch seconds. Precision on disk is 1 ms and the
///   round trip is exact for whole-millisecond dates (all `TestClock` dates). Dates from `Date()` lose
///   their sub-millisecond part — compare those with a tolerance in tests.
/// * Output: pretty-printed with sorted keys (stable diffs; these are Kakureneko's own files —
///   agent config files are never re-serialized, see KakurenekoInstall).
/// * Unknown keys are ignored by every Kit decoder (forward compatibility).
public enum KakurenekoJSON {
    public static func makeEncoder(pretty: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(KakurenekoJSON.iso8601String(from: date))
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                if let date = KakurenekoJSON.date(fromISO8601: string) { return date }
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unparseable date: \(string)")
            }
            let seconds = try container.decode(Double.self)
            return Date(timeIntervalSince1970: seconds)
        }
        return decoder
    }

    public static func encode<T: Encodable>(_ value: T, pretty: Bool = true) throws -> Data {
        try makeEncoder(pretty: pretty).encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try makeDecoder().decode(type, from: data)
    }

    /// `2026-10-12T22:00:00.123Z` — rounded to the nearest millisecond.
    public static func iso8601String(from date: Date) -> String {
        let ms = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let seconds = ms >= 0 ? ms / 1000 : (ms - 999) / 1000
        let fraction = ms - seconds * 1000
        let whole = Date(timeIntervalSince1970: TimeInterval(seconds)).formatted(Date.ISO8601FormatStyle(timeZone: .gmt))
        let digits = String(fraction)
        return String(whole.dropLast()) + "." + String(repeating: "0", count: 3 - digits.count) + digits + "Z"
    }

    /// Parses ISO 8601 (UTC `Z`) with or without fractional seconds. The result is millisecond-exact:
    /// `date(fromISO8601: iso8601String(from: d)) == d` for every whole-millisecond `d`.
    public static func date(fromISO8601 string: String) -> Date? {
        guard let t = string.firstIndex(of: "T") else { return nil }
        var base = string
        var fractionMs: Int64 = 0
        if let dot = string[t...].firstIndex(of: ".") {
            var end = string.index(after: dot)
            while end < string.endIndex, string[end].isASCII, string[end].isNumber { end = string.index(after: end) }
            let digits = String(string[string.index(after: dot)..<end])
            fractionMs = Int64(String((digits + "000").prefix(3))) ?? 0
            if digits.count > 3, let next = digits.dropFirst(3).first?.wholeNumberValue, next >= 5 { fractionMs += 1 }
            base = String(string[..<dot]) + String(string[end...])
        }
        guard let whole = try? Date.ISO8601FormatStyle(timeZone: .gmt).parse(base) else { return nil }
        let wholeSeconds = Int64(whole.timeIntervalSince1970.rounded())
        return Date(timeIntervalSince1970: Double(wholeSeconds * 1000 + fractionMs) / 1000)
    }
}
