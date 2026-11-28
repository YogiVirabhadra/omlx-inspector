import CryptoKit
import Foundation

/// SHA-256 digests as lowercase hexadecimal text: the form used for record digests,
/// message fingerprints, and history chain hashes.
enum SHA256Hex {
    private static let digits = Array("0123456789abcdef".utf8)

    /// The lowercase hexadecimal SHA-256 digest of `data`.
    static func digest<Bytes: DataProtocol>(of data: Bytes) -> String {
        var text: [UInt8] = []
        text.reserveCapacity(64)
        for byte in SHA256.hash(data: data) {
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: text, as: UTF8.self)
    }
}
