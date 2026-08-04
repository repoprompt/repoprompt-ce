import Foundation

package enum CodeMapSourceDecoderPolicy: String, Codable, Hashable, Sendable {
    case workspaceAutomaticV1
    #if DEBUG
        case testOnlyMismatch
    #endif
}

package struct CodeMapRawSourceDigest: Hashable, Codable, Sendable {
    private static let requiredByteCount = 32

    package let bytes: Data

    package init(bytes: Data) {
        precondition(bytes.count == Self.requiredByteCount, "A raw source digest must contain exactly 32 SHA-256 bytes.")
        self.bytes = bytes
    }

    package var lowercaseHex: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    package init(from decoder: Decoder) throws {
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

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bytes)
    }
}

package struct CodeMapDecodedSource: Equatable, Sendable {
    package let text: String
    package let detectedEncodingRawValue: UInt

    package init(text: String, detectedEncodingRawValue: UInt) {
        self.text = text
        self.detectedEncodingRawValue = detectedEncodingRawValue
    }
}

package enum CodeMapSourceDecodeFailure: String, Codable, Equatable, Sendable {
    case undecodable
}

package enum CodeMapSourceDecodeResult: Equatable, Sendable {
    case decoded(CodeMapDecodedSource)
    case failed(CodeMapSourceDecodeFailure)
}

package struct CodeMapCoreSourceSnapshot: Equatable, Sendable {
    package let rawByteCount: Int
    package let rawSHA256: CodeMapRawSourceDigest
    package let decoderPolicy: CodeMapSourceDecoderPolicy
    package let decodeResult: CodeMapSourceDecodeResult

    package init(
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
