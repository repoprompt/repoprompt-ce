import CryptoKit
import Foundation

package enum StableUserInteractionIdentity {
    package static func uuid(from seed: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(seed.utf8)))
        let bytes: uuid_t = (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        )
        return UUID(uuid: bytes)
    }
}
