#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif
import Foundation

/// Stable content identity shared by portable semantic owners.
///
/// Transport authentication and request signing belong to the Server protocol boundary;
/// this utility intentionally exposes only deterministic SHA-256 content digests.
public enum PortableContentDigest {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
