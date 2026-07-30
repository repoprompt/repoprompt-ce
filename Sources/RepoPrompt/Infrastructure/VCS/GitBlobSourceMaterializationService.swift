import Foundation

struct ValidatedGitBlobSourceSnapshot {
    let rawBytes: Data
    let repositoryNamespace: GitBlobRepositoryNamespace
    let blobOID: GitBlobOID

    fileprivate init(
        rawBytes: Data,
        repositoryNamespace: GitBlobRepositoryNamespace,
        blobOID: GitBlobOID
    ) {
        precondition(
            GitBlobOID.blob(bytes: rawBytes, objectFormat: blobOID.objectFormat) == blobOID,
            "Validated Git blob bytes must match their object ID."
        )
        self.rawBytes = rawBytes
        self.repositoryNamespace = repositoryNamespace
        self.blobOID = blobOID
    }
}

struct GitBlobSourceMaterializationPolicy: Equatable {
    let maximumRawByteCount: Int

    static let `default` = GitBlobSourceMaterializationPolicy(maximumRawByteCount: 8 * 1024 * 1024)

    init(maximumRawByteCount: Int) {
        precondition(maximumRawByteCount >= 0 && maximumRawByteCount < Int.max)
        self.maximumRawByteCount = maximumRawByteCount
    }
}

enum GitBlobSourceMaterializationPhase: Equatable {
    case declaredSize
    case bytes
}

enum GitBlobSourceMaterializationStream: Equatable {
    case stdout
    case stderr
}

enum GitBlobSourceMaterializationError: Error, Equatable {
    case objectFormatMismatch
    case objectUnavailable
    case invalidDeclaredSize
    case oversized(limit: Int, actual: UInt64)
    case truncated(expected: UInt64, actual: Int)
    case excess(expected: UInt64, actualAtLeast: UInt64)
    case commandOutputOverflow(
        phase: GitBlobSourceMaterializationPhase,
        stream: GitBlobSourceMaterializationStream
    )
    case oidMismatch
}

struct GitBlobSourceMaterializationClient {
    let size: @Sendable (GitRepositoryLayout, GitBlobOID) async throws -> UInt64
    let bytes: @Sendable (GitRepositoryLayout, GitBlobOID, Int) async throws -> Data

    init(gitService: GitService) {
        size = { try await gitService.gitBlobObjectSize(in: $0, oid: $1) }
        bytes = { try await gitService.gitBlobObjectBytes(in: $0, oid: $1, expectedByteCount: $2) }
    }

    init(
        size: @escaping @Sendable (GitRepositoryLayout, GitBlobOID) async throws -> UInt64,
        bytes: @escaping @Sendable (GitRepositoryLayout, GitBlobOID, Int) async throws -> Data
    ) {
        self.size = size
        self.bytes = bytes
    }
}

struct GitBlobSourceMaterializationService {
    private let client: GitBlobSourceMaterializationClient
    private let policy: GitBlobSourceMaterializationPolicy
    private let oidForBytes: @Sendable (Data, GitObjectFormat) -> GitBlobOID

    init(
        gitService: GitService = GitService(),
        policy: GitBlobSourceMaterializationPolicy = .default
    ) {
        client = GitBlobSourceMaterializationClient(gitService: gitService)
        self.policy = policy
        oidForBytes = { GitBlobOID.blob(bytes: $0, objectFormat: $1) }
    }

    init(
        client: GitBlobSourceMaterializationClient,
        policy: GitBlobSourceMaterializationPolicy = .default,
        oidForBytes: @escaping @Sendable (Data, GitObjectFormat) -> GitBlobOID = {
            GitBlobOID.blob(bytes: $0, objectFormat: $1)
        }
    ) {
        self.client = client
        self.policy = policy
        self.oidForBytes = oidForBytes
    }

    func materialize(
        capability: GitCodemapRootCapability,
        blobOID: GitBlobOID
    ) async throws -> ValidatedGitBlobSourceSnapshot {
        try Task.checkCancellation()
        guard blobOID.objectFormat == capability.objectFormat,
              blobOID.objectFormat == capability.repositoryAuthority.objectFormat
        else {
            throw GitBlobSourceMaterializationError.objectFormatMismatch
        }

        let declaredSize: UInt64
        do {
            declaredSize = try await client.size(capability.repositoryLayout, blobOID)
        } catch is CancellationError {
            throw CancellationError()
        } catch GitBlobObjectReadError.malformedSize {
            throw GitBlobSourceMaterializationError.invalidDeclaredSize
        } catch GitBlobObjectReadError.stdoutLimitExceeded {
            throw GitBlobSourceMaterializationError.commandOutputOverflow(
                phase: .declaredSize,
                stream: .stdout
            )
        } catch GitBlobObjectReadError.stderrLimitExceeded {
            throw GitBlobSourceMaterializationError.commandOutputOverflow(
                phase: .declaredSize,
                stream: .stderr
            )
        } catch {
            throw GitBlobSourceMaterializationError.objectUnavailable
        }
        try Task.checkCancellation()
        guard declaredSize <= UInt64(policy.maximumRawByteCount) else {
            throw GitBlobSourceMaterializationError.oversized(
                limit: policy.maximumRawByteCount,
                actual: declaredSize
            )
        }

        let expectedByteCount = Int(declaredSize)
        let rawBytes: Data
        do {
            rawBytes = try await client.bytes(
                capability.repositoryLayout,
                blobOID,
                expectedByteCount
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch GitBlobObjectReadError.stdoutLimitExceeded {
            throw GitBlobSourceMaterializationError.excess(
                expected: declaredSize,
                actualAtLeast: declaredSize + 1
            )
        } catch GitBlobObjectReadError.stderrLimitExceeded {
            throw GitBlobSourceMaterializationError.commandOutputOverflow(
                phase: .bytes,
                stream: .stderr
            )
        } catch {
            throw GitBlobSourceMaterializationError.objectUnavailable
        }
        try Task.checkCancellation()
        guard rawBytes.count >= expectedByteCount else {
            throw GitBlobSourceMaterializationError.truncated(
                expected: declaredSize,
                actual: rawBytes.count
            )
        }
        guard rawBytes.count == expectedByteCount else {
            throw GitBlobSourceMaterializationError.excess(
                expected: declaredSize,
                actualAtLeast: UInt64(rawBytes.count)
            )
        }
        guard oidForBytes(rawBytes, blobOID.objectFormat) == blobOID else {
            throw GitBlobSourceMaterializationError.oidMismatch
        }
        try Task.checkCancellation()
        return ValidatedGitBlobSourceSnapshot(
            rawBytes: rawBytes,
            repositoryNamespace: capability.repositoryNamespace,
            blobOID: blobOID
        )
    }
}
