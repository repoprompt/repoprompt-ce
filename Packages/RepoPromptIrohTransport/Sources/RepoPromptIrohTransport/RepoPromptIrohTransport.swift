import Foundation

/// Constants and safe convenience entry points for the isolated transport spike.
public enum RepoPromptIrohSpike {
    public static let alpn = Data("repoprompt-remote/1".utf8)
    public static let maximumFrameBytes = 1_048_576
    public static let maximumConcurrentStreams = 8

    /// Starts an endpoint from caller-owned bytes. The bridge validates and copies the secret;
    /// neither this package nor Rust persists it.
    public static func start(
        secret: Data,
        relayEnabled: Bool,
        generation: UInt64
    ) async throws -> TransportEndpoint {
        try validate(secret: secret)
        return try await startEndpoint(
            secretKey: secret,
            alpn: alpn,
            relayEnabled: relayEnabled,
            generation: generation
        )
    }

    /// Starts the production endpoint. Unlike the spike entry point, inbound
    /// streams are surfaced to Swift as authenticated requests instead of
    /// being echoed inside Rust.
    public static func startApplication(
        secret: Data,
        relayEnabled: Bool,
        generation: UInt64
    ) async throws -> TransportEndpoint {
        try validate(secret: secret)
        return try await startApplicationEndpoint(
            secretKey: secret,
            alpn: alpn,
            relayEnabled: relayEnabled,
            generation: generation
        )
    }

    private static func validate(secret: Data) throws {
        guard secret.count == 32 else {
            throw SpikeInputError.invalidSecretLength(secret.count)
        }
    }
}

public enum SpikeInputError: Error, LocalizedError, Equatable {
    case invalidSecretLength(Int)
    case invalidHexSecret

    public var errorDescription: String? {
        switch self {
        case let .invalidSecretLength(count):
            "Expected a 32-byte endpoint secret, received \(count) bytes."
        case .invalidHexSecret:
            "The endpoint secret must be exactly 64 hexadecimal characters."
        }
    }
}

public extension Data {
    init(spikeHex: String) throws {
        guard spikeHex.count == 64 else {
            throw SpikeInputError.invalidHexSecret
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        var index = spikeHex.startIndex
        while index < spikeHex.endIndex {
            let next = spikeHex.index(index, offsetBy: 2)
            guard let byte = UInt8(spikeHex[index ..< next], radix: 16) else {
                throw SpikeInputError.invalidHexSecret
            }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    var spikeHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
