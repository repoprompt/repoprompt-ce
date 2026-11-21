import Foundation
import Security

enum RemoteIrohIdentityStoreError: Error, Equatable {
    case randomGenerationFailed(OSStatus)
    case invalidGeneratedIdentityLength(Int)
}

struct RemoteIrohIdentity: Equatable {
    enum Origin: Equatable {
        case loaded
        case created
        case replacedCorruptValue
    }

    let secret: Data
    let origin: Origin
}

/// Owns the stable Iroh endpoint secret on macOS. Swift persists the exact
/// 32-byte value and passes it to Rust only when an endpoint is started.
final class RemoteIrohIdentityStore {
    static let byteCount = 32

    private let read: () throws -> Data?
    private let write: (Data) throws -> Void
    private let generate: () throws -> Data

    convenience init() {
        self.init(
            read: { try RemoteGatewayKeychain.shared.read(.remoteIrohIdentity) },
            write: { try RemoteGatewayKeychain.shared.write($0, for: .remoteIrohIdentity) },
            generate: Self.generateRandomSecret
        )
    }

    init(
        read: @escaping () throws -> Data?,
        write: @escaping (Data) throws -> Void,
        generate: @escaping () throws -> Data
    ) {
        self.read = read
        self.write = write
        self.generate = generate
    }

    func loadOrCreate() throws -> RemoteIrohIdentity {
        let stored = try read()
        if let stored, stored.count == Self.byteCount {
            return RemoteIrohIdentity(secret: stored, origin: .loaded)
        }

        let generated = try generate()
        guard generated.count == Self.byteCount else {
            throw RemoteIrohIdentityStoreError.invalidGeneratedIdentityLength(generated.count)
        }
        try write(generated)
        return RemoteIrohIdentity(
            secret: generated,
            origin: stored == nil ? .created : .replacedCorruptValue
        )
    }

    private static func generateRandomSecret() throws -> Data {
        var bytes = Data(count: byteCount)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw RemoteIrohIdentityStoreError.randomGenerationFailed(status)
        }
        return bytes
    }
}
