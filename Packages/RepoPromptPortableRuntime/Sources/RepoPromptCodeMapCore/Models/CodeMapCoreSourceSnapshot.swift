import Foundation

public enum CodeMapSourceDecoderPolicy: String, Codable, Hashable, Sendable {
    case workspaceAutomaticV1
    #if DEBUG
        case testOnlyMismatch
    #endif
}

public struct CodeMapRawSourceDigest: Hashable, Codable, Sendable {
    private static let requiredByteCount = 32

    public let bytes: Data

    public init(bytes: Data) {
        precondition(bytes.count == Self.requiredByteCount, "A raw source digest must contain exactly 32 SHA-256 bytes.")
        self.bytes = bytes
    }

    public var lowercaseHex: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decodedBytes = try container.decode(Data.self)
        guard decodedBytes.count == Self.requiredByteCount else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "A raw source digest must contain exactly 32 SHA-256 bytes."
            )
        }
        bytes = decodedBytes
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bytes)
    }
}

public struct CodeMapDecodedSource: Equatable, Sendable {
    public let text: String
    public let detectedEncodingRawValue: UInt

    public init(text: String, detectedEncodingRawValue: UInt) {
        self.text = text
        self.detectedEncodingRawValue = detectedEncodingRawValue
    }
}

public enum CodeMapSourceDecodeFailure: String, Codable, Equatable, Sendable {
    case undecodable
}

public enum CodeMapSourceDecodeResult: Equatable, Sendable {
    case decoded(CodeMapDecodedSource)
    case failed(CodeMapSourceDecodeFailure)
}

public struct CodeMapCoreSourceSnapshot: Equatable, Sendable {
    public let rawByteCount: Int
    public let rawSHA256: CodeMapRawSourceDigest
    public let decoderPolicy: CodeMapSourceDecoderPolicy
    public let decodeResult: CodeMapSourceDecodeResult

    public init(
        rawByteCount: Int,
        rawSHA256: CodeMapRawSourceDigest,
        decoderPolicy: CodeMapSourceDecoderPolicy,
        decodeResult: CodeMapSourceDecodeResult
    ) {
        self.rawByteCount = rawByteCount
        self.rawSHA256 = rawSHA256
        self.decoderPolicy = decoderPolicy
        self.decodeResult = decodeResult
    }
}
