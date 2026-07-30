import CryptoKit
import Foundation
import RepoPromptCodeMapCore

struct CodeMapSourceValidationToken: Hashable {
    let fingerprint: FileContentFingerprint
}

enum CodeMapSourceProvenance: Hashable {
    case validatedWorktree(CodeMapSourceValidationToken)
    case cleanGitBlob(repositoryNamespace: GitBlobRepositoryNamespace, blobOID: GitBlobOID)
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

    var coreSnapshot: CodeMapCoreSourceSnapshot {
        CodeMapCoreSourceSnapshot(
            rawByteCount: rawByteCount,
            rawSHA256: rawSHA256,
            decoderPolicy: decoderPolicy,
            decodeResult: decodeResult
        )
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
