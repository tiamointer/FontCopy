import CryptoKit
import Foundation

public enum FileHash {
    public static func sha256Hex(for url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func shortHash(_ hash: String, length: Int = 8) -> String {
        String(hash.prefix(length))
    }
}
