import Foundation
import RepoPromptCodeMapCore

/// Bounded catalog paging and writer contracts owned directly by the graph index.
struct WorkspaceCodemapGraphIndexCatalogToken: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let topologyGeneration: UInt64
    let appliedIndexGeneration: UInt64
    let catalogGeneration: UInt64
    let ingressGeneration: UInt64
    let graphIndexInvalidationGeneration: UInt64
}

struct WorkspaceCodemapGraphIndexCatalogCursor: Hashable {
    let standardizedRelativePath: String
    let fileID: UUID
}

struct WorkspaceCodemapGraphIndexCatalogCandidate: Hashable {
    let identity: WorkspaceCodemapArtifactBindingIdentity
    let language: LanguageType
    let requestGeneration: UInt64
    let pathGeneration: UInt64
}

struct WorkspaceCodemapGraphIndexCatalogPageRequest: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let token: WorkspaceCodemapGraphIndexCatalogToken?
    let cursor: WorkspaceCodemapGraphIndexCatalogCursor?
    let maximumEntryCount: Int
    let maximumPathByteCount: UInt64

    init(
        rootEpoch: WorkspaceCodemapRootEpoch,
        token: WorkspaceCodemapGraphIndexCatalogToken?,
        cursor: WorkspaceCodemapGraphIndexCatalogCursor?,
        maximumEntryCount: Int,
        maximumPathByteCount: UInt64
    ) {
        precondition(maximumEntryCount > 0)
        precondition(maximumPathByteCount > 0)
        precondition(token == nil || token?.rootEpoch == rootEpoch)
        precondition(cursor == nil || token != nil)
        self.rootEpoch = rootEpoch
        self.token = token
        self.cursor = cursor
        self.maximumEntryCount = maximumEntryCount
        self.maximumPathByteCount = maximumPathByteCount
    }
}

enum WorkspaceCodemapGraphIndexCatalogPageError: Error, Hashable {
    case rootMismatch
    case tokenMismatch
    case entryLimit(attempted: Int, limit: Int)
    case pathByteLimit(attempted: UInt64, limit: UInt64)
    case duplicateFileID(UUID)
    case nonCanonicalOrder
    case cursorOrder
    case endCursorMismatch
    case continuationCursorMismatch
    case supportedCandidateCountMismatch
    case pathByteCountOverflow
}

struct WorkspaceCodemapGraphIndexCatalogPage: Hashable {
    let token: WorkspaceCodemapGraphIndexCatalogToken
    let entries: [WorkspaceCodemapGraphIndexCatalogCandidate]
    let nextCursor: WorkspaceCodemapGraphIndexCatalogCursor?
    let isEnd: Bool
    let pathByteCount: UInt64
    let supportedCandidateCountThroughPage: UInt64

    private init(
        token: WorkspaceCodemapGraphIndexCatalogToken,
        entries: [WorkspaceCodemapGraphIndexCatalogCandidate],
        nextCursor: WorkspaceCodemapGraphIndexCatalogCursor?,
        isEnd: Bool,
        pathByteCount: UInt64,
        supportedCandidateCountThroughPage: UInt64
    ) {
        self.token = token
        self.entries = entries
        self.nextCursor = nextCursor
        self.isEnd = isEnd
        self.pathByteCount = pathByteCount
        self.supportedCandidateCountThroughPage = supportedCandidateCountThroughPage
    }

    static func validated(
        request: WorkspaceCodemapGraphIndexCatalogPageRequest,
        token: WorkspaceCodemapGraphIndexCatalogToken,
        entries: [WorkspaceCodemapGraphIndexCatalogCandidate],
        nextCursor: WorkspaceCodemapGraphIndexCatalogCursor?,
        isEnd: Bool,
        supportedCandidateCountThroughPage: UInt64
    ) -> Result<Self, WorkspaceCodemapGraphIndexCatalogPageError> {
        guard token.rootEpoch == request.rootEpoch else { return .failure(.rootMismatch) }
        guard request.token == nil || request.token == token else { return .failure(.tokenMismatch) }
        guard entries.count <= request.maximumEntryCount else {
            return .failure(.entryLimit(attempted: entries.count, limit: request.maximumEntryCount))
        }

        var fileIDs = Set<UUID>()
        var previous = request.cursor
        var pathByteCount: UInt64 = 0
        for entry in entries {
            guard entry.identity.rootID == token.rootEpoch.rootID,
                  entry.identity.rootLifetimeID == token.rootEpoch.rootLifetimeID
            else { return .failure(.rootMismatch) }
            guard fileIDs.insert(entry.identity.fileID).inserted else {
                return .failure(.duplicateFileID(entry.identity.fileID))
            }
            let cursor = WorkspaceCodemapGraphIndexCatalogCursor(
                standardizedRelativePath: entry.identity.standardizedRelativePath,
                fileID: entry.identity.fileID
            )
            if let previous {
                guard workspaceCodemapGraphIndexCatalogKeyPrecedes(previous, cursor) else {
                    return .failure(request.cursor == previous ? .cursorOrder : .nonCanonicalOrder)
                }
            }
            previous = cursor
            guard let byteCount = UInt64(exactly: entry.identity.standardizedRelativePath.utf8.count) else {
                return .failure(.pathByteCountOverflow)
            }
            let (nextPathByteCount, overflow) = pathByteCount.addingReportingOverflow(byteCount)
            guard !overflow else { return .failure(.pathByteCountOverflow) }
            pathByteCount = nextPathByteCount
        }
        guard pathByteCount <= request.maximumPathByteCount else {
            return .failure(.pathByteLimit(
                attempted: pathByteCount,
                limit: request.maximumPathByteCount
            ))
        }
        if isEnd {
            guard nextCursor == nil else { return .failure(.endCursorMismatch) }
        } else {
            guard let last = previous, last != request.cursor, nextCursor == last else {
                return .failure(.continuationCursorMismatch)
            }
        }
        guard request.cursor != nil || supportedCandidateCountThroughPage == UInt64(entries.count) else {
            return .failure(.supportedCandidateCountMismatch)
        }
        guard supportedCandidateCountThroughPage >= UInt64(entries.count) else {
            return .failure(.supportedCandidateCountMismatch)
        }
        return .success(Self(
            token: token,
            entries: entries,
            nextCursor: nextCursor,
            isEnd: isEnd,
            pathByteCount: pathByteCount,
            supportedCandidateCountThroughPage: supportedCandidateCountThroughPage
        ))
    }
}

enum WorkspaceCodemapGraphIndexCatalogUnavailableReason: Hashable {
    case rootNotCurrent
    case catalogNotReady
    case catalogUnavailable
}

enum WorkspaceCodemapGraphIndexCatalogPageDisposition: Hashable {
    case page(WorkspaceCodemapGraphIndexCatalogPage)
    case stale
    case unavailable(WorkspaceCodemapGraphIndexCatalogUnavailableReason)
}

enum WorkspaceCodemapGraphIndexCatalogTokenDisposition: Hashable {
    case current
    case stale
    case unavailable(WorkspaceCodemapGraphIndexCatalogUnavailableReason)
}

private func workspaceCodemapGraphIndexCatalogKeyPrecedes(
    _ lhs: WorkspaceCodemapGraphIndexCatalogCursor,
    _ rhs: WorkspaceCodemapGraphIndexCatalogCursor
) -> Bool {
    if lhs.standardizedRelativePath != rhs.standardizedRelativePath {
        return lhs.standardizedRelativePath.utf8.lexicographicallyPrecedes(
            rhs.standardizedRelativePath.utf8
        )
    }
    return lhs.fileID.uuidString.utf8.lexicographicallyPrecedes(rhs.fileID.uuidString.utf8)
}

enum WorkspaceCodemapGraphIndexLaunchPhase: Hashable {
    case notScheduled
    case eligibilityQueued
    case setupJoining
    case engineScheduling
    case handedOff
    case terminalNonGit
    case transientRetry
    case cancelled
    case superseded
}

enum WorkspaceCodemapGraphIndexPhase: Hashable {
    case scheduled
    case waitingForAdmission
    case readingCatalogPage
    case loadingEnvelopes
    case classifyingBatch
    case resolvingArtifacts
    case writingManifestCheckpoint
    case publishingGraphChanges
    case checkpointed
    case suspendedBusy
    case budgetLimited
    case complete
    case cancelled
    case superseded
}

struct WorkspaceCodemapGraphIndexGeneration: Hashable {
    let catalogToken: WorkspaceCodemapGraphIndexCatalogToken
    let repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken
    let contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration
    let schemaVersion: UInt32
    let policyVersion: UInt32

    init(
        catalogToken: WorkspaceCodemapGraphIndexCatalogToken,
        repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken,
        contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration,
        schemaVersion: UInt32 = CodeMapSelectionGraphContribution.currentSchemaVersion,
        policyVersion: UInt32 = CodeMapSelectionGraphContribution.currentPolicyVersion
    ) {
        precondition(schemaVersion > 0)
        precondition(policyVersion > 0)
        self.catalogToken = catalogToken
        self.repositoryAuthority = repositoryAuthority
        self.contributionGeneration = contributionGeneration
        self.schemaVersion = schemaVersion
        self.policyVersion = policyVersion
    }

    var rootEpoch: WorkspaceCodemapRootEpoch {
        catalogToken.rootEpoch
    }

    var catalogGeneration: UInt64 {
        catalogToken.catalogGeneration
    }
}

enum WorkspaceCodemapGraphIndexEntryOutcome: Hashable {
    case contributed(CodeMapSelectionGraphContribution)
    case empty(CodeMapSelectionGraphContribution)
    case terminalArtifact(WorkspaceCodemapGraphTerminalArtifactReason)
    case terminalExcluded(WorkspaceCodemapGraphTerminalExclusionReason)
}

struct WorkspaceCodemapGraphIndexEntry: Hashable {
    let identity: WorkspaceCodemapArtifactBindingIdentity
    let requestGeneration: UInt64
    let pathGeneration: UInt64
    let pipelineIdentity: CodeMapPipelineIdentity
    let outcome: WorkspaceCodemapGraphIndexEntryOutcome
}

enum WorkspaceCodemapGraphIndexAccountingField: Hashable {
    case supportedCandidates
    case processedCandidates
    case contributed
    case empty
    case terminalArtifacts
    case terminalExcluded
    case transient
    case catalogPages
    case catalogPathBytes
    case publishedGraphChanges
    case publishedGraphChangeBytes
    case retainedPathBytes
    case retainedSourceBytes
    case retainedGraphIndexBytes
    case stagedGraphBytes
    case residentGraphBytes
    case queuedManifestMutationBytes
}

enum WorkspaceCodemapGraphIndexAccountingError: Error, Hashable {
    case overflow(WorkspaceCodemapGraphIndexAccountingField)
    case underflow(WorkspaceCodemapGraphIndexAccountingField)
}

struct WorkspaceCodemapGraphIndexCounts: Hashable {
    static let zero = Self(
        supportedCandidateCount: 0,
        processedCandidateCount: 0,
        contributedCount: 0,
        emptyCount: 0,
        terminalArtifactCount: 0,
        terminalExcludedCount: 0,
        transientCount: 0
    )

    let supportedCandidateCount: UInt64
    let processedCandidateCount: UInt64
    let contributedCount: UInt64
    let emptyCount: UInt64
    let terminalArtifactCount: UInt64
    let terminalExcludedCount: UInt64
    let transientCount: UInt64

    func adding(
        _ other: Self
    ) -> Result<Self, WorkspaceCodemapGraphIndexAccountingError> {
        do {
            return try .success(Self(
                supportedCandidateCount: graphIndexAdding(
                    supportedCandidateCount,
                    other.supportedCandidateCount,
                    field: .supportedCandidates
                ),
                processedCandidateCount: graphIndexAdding(
                    processedCandidateCount,
                    other.processedCandidateCount,
                    field: .processedCandidates
                ),
                contributedCount: graphIndexAdding(
                    contributedCount,
                    other.contributedCount,
                    field: .contributed
                ),
                emptyCount: graphIndexAdding(emptyCount, other.emptyCount, field: .empty),
                terminalArtifactCount: graphIndexAdding(
                    terminalArtifactCount,
                    other.terminalArtifactCount,
                    field: .terminalArtifacts
                ),
                terminalExcludedCount: graphIndexAdding(
                    terminalExcludedCount,
                    other.terminalExcludedCount,
                    field: .terminalExcluded
                ),
                transientCount: graphIndexAdding(
                    transientCount,
                    other.transientCount,
                    field: .transient
                )
            ))
        } catch let error as WorkspaceCodemapGraphIndexAccountingError {
            return .failure(error)
        } catch {
            preconditionFailure("Unexpected graph-index accounting error: \(error)")
        }
    }
}

struct WorkspaceCodemapGraphIndexCatalogCompletion: Hashable {
    let token: WorkspaceCodemapGraphIndexCatalogToken
    let finalCursor: WorkspaceCodemapGraphIndexCatalogCursor?
    let supportedCandidateCount: UInt64
}

struct WorkspaceCodemapGraphIndexRetry: Hashable {
    let attempt: UInt64
    let retryAfterMilliseconds: UInt64?
    let nextEligibleAdmissionUptimeNanoseconds: UInt64?
}

struct WorkspaceCodemapGraphIndexInBatchProgress: Hashable {
    let batchID: UUID
    let acceptedProcessedCandidateBaseline: UInt64
    let resolvedCandidateCount: UInt64
    let candidateCount: UInt64

    init(
        batchID: UUID,
        acceptedProcessedCandidateBaseline: UInt64,
        resolvedCandidateCount: UInt64,
        candidateCount: UInt64
    ) {
        precondition(resolvedCandidateCount <= candidateCount)
        precondition(acceptedProcessedCandidateBaseline <= UInt64.max - resolvedCandidateCount)
        self.batchID = batchID
        self.acceptedProcessedCandidateBaseline = acceptedProcessedCandidateBaseline
        self.resolvedCandidateCount = resolvedCandidateCount
        self.candidateCount = candidateCount
    }

    var locallyResolvedCandidateCountThroughRoot: UInt64 {
        acceptedProcessedCandidateBaseline + resolvedCandidateCount
    }

    func recordingResolvedCandidate() -> Self? {
        guard resolvedCandidateCount < candidateCount else { return nil }
        let (nextResolvedCandidateCount, overflow) = resolvedCandidateCount.addingReportingOverflow(1)
        guard !overflow,
              acceptedProcessedCandidateBaseline <= UInt64.max - nextResolvedCandidateCount
        else { return nil }
        return Self(
            batchID: batchID,
            acceptedProcessedCandidateBaseline: acceptedProcessedCandidateBaseline,
            resolvedCandidateCount: nextResolvedCandidateCount,
            candidateCount: candidateCount
        )
    }
}

struct WorkspaceCodemapGraphIndexProgress: Hashable {
    static let notStarted = Self(
        phase: .scheduled,
        counts: .zero,
        catalogPageCount: 0,
        catalogPathByteCount: 0,
        publishedGraphChangeCount: 0,
        publishedGraphChangeByteCount: 0,
        catalogCompletion: nil
    )

    let phase: WorkspaceCodemapGraphIndexPhase
    let counts: WorkspaceCodemapGraphIndexCounts
    let catalogPageCount: UInt64
    let catalogPathByteCount: UInt64
    let publishedGraphChangeCount: UInt64
    let publishedGraphChangeByteCount: UInt64
    let catalogCompletion: WorkspaceCodemapGraphIndexCatalogCompletion?

    func advancing(
        to phase: WorkspaceCodemapGraphIndexPhase,
        by delta: WorkspaceCodemapGraphIndexProgressDelta,
        catalogCompletion: WorkspaceCodemapGraphIndexCatalogCompletion? = nil
    ) -> Result<Self, WorkspaceCodemapGraphIndexAccountingError> {
        let counts: WorkspaceCodemapGraphIndexCounts
        switch self.counts.adding(delta.counts) {
        case let .success(value):
            counts = value
        case let .failure(error):
            return .failure(error)
        }
        do {
            return try .success(Self(
                phase: phase,
                counts: counts,
                catalogPageCount: graphIndexAdding(
                    catalogPageCount,
                    delta.catalogPageCount,
                    field: .catalogPages
                ),
                catalogPathByteCount: graphIndexAdding(
                    catalogPathByteCount,
                    delta.catalogPathByteCount,
                    field: .catalogPathBytes
                ),
                publishedGraphChangeCount: graphIndexAdding(
                    publishedGraphChangeCount,
                    delta.publishedGraphChangeCount,
                    field: .publishedGraphChanges
                ),
                publishedGraphChangeByteCount: graphIndexAdding(
                    publishedGraphChangeByteCount,
                    delta.publishedGraphChangeByteCount,
                    field: .publishedGraphChangeBytes
                ),
                catalogCompletion: catalogCompletion ?? self.catalogCompletion
            ))
        } catch let error as WorkspaceCodemapGraphIndexAccountingError {
            return .failure(error)
        } catch {
            preconditionFailure("Unexpected graph-index progress error: \(error)")
        }
    }
}

struct WorkspaceCodemapGraphIndexProgressDelta: Hashable {
    static let zero = Self(
        counts: .zero,
        catalogPageCount: 0,
        catalogPathByteCount: 0,
        publishedGraphChangeCount: 0,
        publishedGraphChangeByteCount: 0
    )

    let counts: WorkspaceCodemapGraphIndexCounts
    let catalogPageCount: UInt64
    let catalogPathByteCount: UInt64
    let publishedGraphChangeCount: UInt64
    let publishedGraphChangeByteCount: UInt64
}

enum WorkspaceCodemapGraphIndexByteAccounting {
    static func normalizedByteCount(
        entries: [WorkspaceCodemapGraphIndexEntry]
    ) -> Result<UInt64, WorkspaceCodemapGraphIndexAccountingError> {
        do {
            var bytes: UInt64 = 128
            for entry in entries {
                bytes = try add(bytes, UInt64(160))
                bytes = try add(bytes, entry.identity.standardizedRootPath.utf8.count)
                bytes = try add(bytes, entry.identity.standardizedRelativePath.utf8.count)
                bytes = try add(bytes, entry.identity.standardizedFullPath.utf8.count)
                bytes = try add(bytes, entry.pipelineIdentity.canonicalBytes.count)
                switch entry.outcome {
                case let .contributed(contribution), let .empty(contribution):
                    bytes = try add(bytes, contribution.artifactKey.canonicalBytes.count)
                    bytes = try add(bytes, UInt64(CodeMapSHA256Digest.byteCount))
                    for name in contribution.sortedUniqueDefinitions {
                        bytes = try add(bytes, UInt64(16))
                        bytes = try add(bytes, name.utf8.count)
                    }
                    for name in contribution.sortedUniqueReferences {
                        bytes = try add(bytes, UInt64(16))
                        bytes = try add(bytes, name.utf8.count)
                    }
                case .terminalArtifact, .terminalExcluded:
                    bytes = try add(bytes, UInt64(8))
                }
            }
            return .success(bytes)
        } catch let error as WorkspaceCodemapGraphIndexAccountingError {
            return .failure(error)
        } catch {
            preconditionFailure("Unexpected graph-index byte-accounting error: \(error)")
        }
    }

    private static func add(_ current: UInt64, _ value: Int) throws -> UInt64 {
        guard let converted = UInt64(exactly: value) else {
            throw WorkspaceCodemapGraphIndexAccountingError.overflow(.stagedGraphBytes)
        }
        return try add(current, converted)
    }

    private static func add(_ current: UInt64, _ value: UInt64) throws -> UInt64 {
        let (next, overflow) = current.addingReportingOverflow(value)
        guard !overflow else {
            throw WorkspaceCodemapGraphIndexAccountingError.overflow(.stagedGraphBytes)
        }
        return next
    }
}

enum WorkspaceCodemapGraphIndexBudgetDimension: Hashable {
    case catalogEntries
    case catalogPathBytes
    case activeBatches
    case retainedSourceBytes
    case retainedGraphIndexBytes
    case stagedGraphBytes
    case residentGraph(WorkspaceCodemapSelectionGraphSizeDimension)
    case queuedManifestMutationBytes
}

struct WorkspaceCodemapGraphIndexBudget: Hashable {
    let dimension: WorkspaceCodemapGraphIndexBudgetDimension
    let attempted: UInt64
    let limit: UInt64
}

struct WorkspaceCodemapGraphIndexResourceAccounting: Hashable {
    static let zero = Self(
        retainedPathBytes: 0,
        retainedSourceBytes: 0,
        retainedGraphIndexBytes: 0,
        stagedGraphBytes: 0,
        residentGraphBytes: 0,
        queuedManifestMutationBytes: 0
    )

    let retainedPathBytes: UInt64
    let retainedSourceBytes: UInt64
    let retainedGraphIndexBytes: UInt64
    let stagedGraphBytes: UInt64
    let residentGraphBytes: UInt64
    let queuedManifestMutationBytes: UInt64

    func adding(
        _ other: Self
    ) -> Result<Self, WorkspaceCodemapGraphIndexAccountingError> {
        do {
            return try .success(Self(
                retainedPathBytes: graphIndexAdding(
                    retainedPathBytes,
                    other.retainedPathBytes,
                    field: .retainedPathBytes
                ),
                retainedSourceBytes: graphIndexAdding(
                    retainedSourceBytes,
                    other.retainedSourceBytes,
                    field: .retainedSourceBytes
                ),
                retainedGraphIndexBytes: graphIndexAdding(
                    retainedGraphIndexBytes,
                    other.retainedGraphIndexBytes,
                    field: .retainedGraphIndexBytes
                ),
                stagedGraphBytes: graphIndexAdding(
                    stagedGraphBytes,
                    other.stagedGraphBytes,
                    field: .stagedGraphBytes
                ),
                residentGraphBytes: graphIndexAdding(
                    residentGraphBytes,
                    other.residentGraphBytes,
                    field: .residentGraphBytes
                ),
                queuedManifestMutationBytes: graphIndexAdding(
                    queuedManifestMutationBytes,
                    other.queuedManifestMutationBytes,
                    field: .queuedManifestMutationBytes
                )
            ))
        } catch let error as WorkspaceCodemapGraphIndexAccountingError {
            return .failure(error)
        } catch {
            preconditionFailure("Unexpected graph-index accounting error: \(error)")
        }
    }

    func subtracting(
        _ other: Self
    ) -> Result<Self, WorkspaceCodemapGraphIndexAccountingError> {
        do {
            return try .success(Self(
                retainedPathBytes: graphIndexSubtracting(
                    retainedPathBytes,
                    other.retainedPathBytes,
                    field: .retainedPathBytes
                ),
                retainedSourceBytes: graphIndexSubtracting(
                    retainedSourceBytes,
                    other.retainedSourceBytes,
                    field: .retainedSourceBytes
                ),
                retainedGraphIndexBytes: graphIndexSubtracting(
                    retainedGraphIndexBytes,
                    other.retainedGraphIndexBytes,
                    field: .retainedGraphIndexBytes
                ),
                stagedGraphBytes: graphIndexSubtracting(
                    stagedGraphBytes,
                    other.stagedGraphBytes,
                    field: .stagedGraphBytes
                ),
                residentGraphBytes: graphIndexSubtracting(
                    residentGraphBytes,
                    other.residentGraphBytes,
                    field: .residentGraphBytes
                ),
                queuedManifestMutationBytes: graphIndexSubtracting(
                    queuedManifestMutationBytes,
                    other.queuedManifestMutationBytes,
                    field: .queuedManifestMutationBytes
                )
            ))
        } catch let error as WorkspaceCodemapGraphIndexAccountingError {
            return .failure(error)
        } catch {
            preconditionFailure("Unexpected graph-index accounting error: \(error)")
        }
    }
}

struct WorkspaceCodemapGraphIndexPipelineScope: Hashable {
    let pipelineIdentity: CodeMapPipelineIdentity
    let manifestGeneration: UInt64?
}

struct WorkspaceCodemapGraphIndexCheckpoint: Hashable {
    let generation: WorkspaceCodemapGraphIndexGeneration
    let engineSessionID: UUID
    let phase: WorkspaceCodemapGraphIndexPhase
    let cursor: WorkspaceCodemapGraphIndexCatalogCursor?
    let progress: WorkspaceCodemapGraphIndexProgress
    let nextGraphChangeSequence: UInt64
    let pipelineScopes: [WorkspaceCodemapGraphIndexPipelineScope]
    let resources: WorkspaceCodemapGraphIndexResourceAccounting
    let pendingManifestMutationCount: UInt64
    let retry: WorkspaceCodemapGraphIndexRetry?
    let budget: WorkspaceCodemapGraphIndexBudget?
}

private func graphIndexAdding(
    _ lhs: UInt64,
    _ rhs: UInt64,
    field: WorkspaceCodemapGraphIndexAccountingField
) throws -> UInt64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow else { throw WorkspaceCodemapGraphIndexAccountingError.overflow(field) }
    return value
}

private func graphIndexSubtracting(
    _ lhs: UInt64,
    _ rhs: UInt64,
    field: WorkspaceCodemapGraphIndexAccountingField
) throws -> UInt64 {
    let (value, underflow) = lhs.subtractingReportingOverflow(rhs)
    guard !underflow else { throw WorkspaceCodemapGraphIndexAccountingError.underflow(field) }
    return value
}
