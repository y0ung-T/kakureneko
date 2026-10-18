import CryptoKit
import Foundation

/// SHA-256 helpers for the install manifest (`sha256Before`/`sha256After`) and helper deployment.
enum Digest {
    /// Lower-case hex SHA-256 of `data`.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { byte in
            let hex = String(byte, radix: 16)
            return byte < 0x10 ? "0" + hex : hex
        }.joined()
    }

    /// Lower-case hex SHA-256 of the UTF-8 bytes of `text`.
    static func sha256Hex(_ text: String) -> String { sha256Hex(Data(text.utf8)) }
}
