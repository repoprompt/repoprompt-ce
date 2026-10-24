import CryptoKit
import Foundation

/// Immutable bundled annotations. A snapshot can describe an admitted model but cannot
/// authorize an execution target. Its identity is derived from bundled content.
struct RoutingModelProfileSnapshot {
    let resolver: RoutingModelProfileResolver
    let digest: String

    var identity: String {
        "bundled:\(digest):\(resolver.profileVersion)"
    }

    static let bundled: RoutingModelProfileSnapshot = {
        let bytes = BundledRoutingProfiles.data
        return .init(resolver: .bundled, digest: digest(bytes))
    }()

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
