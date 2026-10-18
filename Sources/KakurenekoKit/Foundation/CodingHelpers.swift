import Foundation

extension KeyedDecodingContainer {
    /// Tolerant decode: returns `defaultValue` when the key is missing, `null`, or has the wrong type.
    /// Used by every persisted Kit type so older/newer files never fail to load.
    public func tolerantDecode<T: Decodable>(_ type: T.Type, forKey key: Key, default defaultValue: T) -> T {
        (try? decodeIfPresent(type, forKey: key)) ?? defaultValue
    }

    /// Tolerant optional decode: `nil` when missing, `null` or of the wrong type.
    public func tolerantDecodeIfPresent<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    /// Numbers that may arrive as Int, Double or numeric String.
    public func tolerantDouble(forKey key: Key) -> Double? {
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return d }
        if let i = try? decodeIfPresent(Int64.self, forKey: key) { return Double(i) }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Double(s) }
        return nil
    }
}
