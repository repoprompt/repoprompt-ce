import CryptoKit
import Foundation

enum CodeMapSourceDecoderPolicy: String, Codable, Hashable {
    case workspaceAutomaticV1
    #if DEBUG
        case testOnlyMismatch
    #endif
}

struct CodeMapRawSourceDigest: Hashable, Codable {
    private static let requiredByteCount = 32

    let bytes: Data

    init(bytes: Data) {
        precondition(bytes.count == Self.requiredByteCount, "A raw source digest must contain exactly 32 SHA-256 bytes.")
        self.bytes = bytes
    }

    var lowercaseHex: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bytes)
    }
}

struct CodeMapSourceValidationToken: Hashable {
    let fingerprint: FileContentFingerprint
}

enum CodeMapSourceProvenance: Hashable {
    case validatedWorktree(CodeMapSourceValidationToken)
    case cleanGitBlob(repositoryNamespace: GitBlobRepositoryNamespace, blobOID: GitBlobOID)
}

struct CodeMapDecodedSource: Equatable {
    let text: String
    let detectedEncodingRawValue: UInt
}

enum CodeMapSourceDecodeFailure: String, Codable, Equatable {
    case undecodable
}

enum CodeMapSourceDecodeResult: Equatable {
    case decoded(CodeMapDecodedSource)
    case failed(CodeMapSourceDecodeFailure)
}

struct CodeMapSourceSnapshot {
    let rawBytes: Data
    let rawByteCount: Int
    let rawSHA256: CodeMapRawSourceDigest
    let decoderPolicy: CodeMapSourceDecoderPolicy
    let decodeResult: CodeMapSourceDecodeResult
    let provenance: CodeMapSourceProvenance

    var validatedWorktreeToken: CodeMapSourceValidationToken? {
        guard case let .validatedWorktree(token) = provenance else { return nil }
        return token
    }

    init(
        validatedContent: ValidatedRawFileContentSnapshot,
        decoderPolicy: CodeMapSourceDecoderPolicy = .workspaceAutomaticV1
    ) {
        self.init(
            data: validatedContent.data,
            provenance: .validatedWorktree(
                CodeMapSourceValidationToken(fingerprint: validatedContent.fingerprint)
            ),
            decoderPolicy: decoderPolicy
        )
    }

    init(
        validatedGitBlob: ValidatedGitBlobSourceSnapshot,
        decoderPolicy: CodeMapSourceDecoderPolicy = .workspaceAutomaticV1
    ) {
        precondition(
            GitBlobOID.blob(
                bytes: validatedGitBlob.rawBytes,
                objectFormat: validatedGitBlob.blobOID.objectFormat
            ) == validatedGitBlob.blobOID,
            "Validated Git blob bytes must match their object ID."
        )
        self.init(
            data: validatedGitBlob.rawBytes,
            provenance: .cleanGitBlob(
                repositoryNamespace: validatedGitBlob.repositoryNamespace,
                blobOID: validatedGitBlob.blobOID
            ),
            decoderPolicy: decoderPolicy
        )
    }

    private init(
        data: Data,
        provenance: CodeMapSourceProvenance,
        decoderPolicy: CodeMapSourceDecoderPolicy
    ) {
        rawBytes = data
        rawByteCount = data.count
        rawSHA256 = CodeMapRawSourceDigest(bytes: Data(SHA256.hash(data: data)))
        self.decoderPolicy = decoderPolicy
        decodeResult = switch decoderPolicy {
        case .workspaceAutomaticV1:
            Self.decodeWorkspaceAutomatic(data)
        #if DEBUG
            case .testOnlyMismatch:
                Self.decodeWorkspaceAutomatic(data)
        #endif
        }
        self.provenance = provenance
    }

    private static func decodeWorkspaceAutomatic(_ data: Data) -> CodeMapSourceDecodeResult {
        if let detected = decodeWorkspaceAutomaticV1(data) {
            .decoded(
                CodeMapDecodedSource(
                    text: detected.string,
                    detectedEncodingRawValue: detected.encoding.rawValue
                )
            )
        } else {
            .failed(.undecodable)
        }
    }
}
