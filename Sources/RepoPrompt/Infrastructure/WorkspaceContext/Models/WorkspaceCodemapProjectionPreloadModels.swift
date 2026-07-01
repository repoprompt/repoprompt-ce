import Foundation

enum WorkspaceCodemapProjectionPreloadLaunchPhase: Hashable {
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

enum WorkspaceCodemapProjectionPreloadPhase: Hashable {
    case scheduled
    case waitingForAdmission
    case readingCatalogPage
    case loadingEnvelopes
    case classifyingBatch
    case resolvingArtifacts
    case writingManifestCheckpoint
    case publishingProjectionSegment
    case checkpointed
    case suspendedBusy
    case budgetLimited
    case complete
    case cancelled
    case superseded
}

struct WorkspaceCodemapProjectionDemandTicket: Hashable {
    let id: UUID
    let rootEpoch: WorkspaceCodemapRootEpoch
    let catalogGeneration: UInt64
    let ingressGeneration: UInt64

    init(
        id: UUID = UUID(),
        rootEpoch: WorkspaceCodemapRootEpoch,
        catalogGeneration: UInt64,
        ingressGeneration: UInt64
    ) {
        self.id = id
        self.rootEpoch = rootEpoch
        self.catalogGeneration = catalogGeneration
        self.ingressGeneration = ingressGeneration
    }
}

enum WorkspaceCodemapProjectionDemandBusyReason: Hashable {
    case requestLimit
    case fileIDLimit(attempted: Int, limit: Int)
    case metadataByteLimit(attempted: UInt64, limit: UInt64)
}

enum WorkspaceCodemapProjectionDemandUnavailableReason: Hashable {
    case rootNotRegistered
    case capabilityUnavailable
    case generationMismatch
    case projectionBudget(WorkspaceCodemapProjectionBudget)
}

enum WorkspaceCodemapProjectionDemandStatus: Hashable {
    case waitingForSetup(retryAfterMilliseconds: UInt64)
    case queued(progress: WorkspaceCodemapProjectionProgress, retryAfterMilliseconds: UInt64)
    case joined(progress: WorkspaceCodemapProjectionProgress, retryAfterMilliseconds: UInt64)
    case waitingForBatchBoundary(progress: WorkspaceCodemapProjectionProgress, retryAfterMilliseconds: UInt64)
    case activeBatch(progress: WorkspaceCodemapProjectionProgress, retryAfterMilliseconds: UInt64)
    case suspendedBusy(progress: WorkspaceCodemapProjectionProgress, retryAfterMilliseconds: UInt64)
    case ready(WorkspaceCodemapProjectionCoverageProof)
    case stale
    case expired
    case cancelled
    case unavailable(
        reason: WorkspaceCodemapProjectionDemandUnavailableReason,
        retryAfterMilliseconds: UInt64?
    )
}

enum WorkspaceCodemapProjectionDemandAcquisition: Hashable {
    case acquired(
        ticket: WorkspaceCodemapProjectionDemandTicket,
        status: WorkspaceCodemapProjectionDemandStatus
    )
    case busy(
        reason: WorkspaceCodemapProjectionDemandBusyReason,
        retryAfterMilliseconds: UInt64
    )
    case unavailable(
        reason: WorkspaceCodemapProjectionDemandUnavailableReason,
        retryAfterMilliseconds: UInt64?
    )
}

struct WorkspaceCodemapProjectionCatalogToken: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let topologyGeneration: UInt64
    let appliedIndexGeneration: UInt64
    let catalogGeneration: UInt64
    let ingressGeneration: UInt64
    let projectionInvalidationGeneration: UInt64
}

struct WorkspaceCodemapProjectionCatalogCursor: Hashable {
    let standardizedRelativePath: String
    let fileID: UUID
}

struct WorkspaceCodemapProjectionCatalogCandidate: Hashable {
    let identity: WorkspaceCodemapArtifactBindingIdentity
    let language: LanguageType
    let requestGeneration: UInt64
    let pathGeneration: UInt64
}

struct WorkspaceCodemapProjectionCatalogPageRequest: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let token: WorkspaceCodemapProjectionCatalogToken?
    let cursor: WorkspaceCodemapProjectionCatalogCursor?
    let maximumEntryCount: Int
    let maximumPathByteCount: UInt64

    init(
        rootEpoch: WorkspaceCodemapRootEpoch,
        token: WorkspaceCodemapProjectionCatalogToken?,
        cursor: WorkspaceCodemapProjectionCatalogCursor?,
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

enum WorkspaceCodemapProjectionCatalogPageError: Error, Hashable {
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
    case accounting(WorkspaceCodemapProjectionAccountingError)
}

struct WorkspaceCodemapProjectionCatalogPage: Hashable {
    let token: WorkspaceCodemapProjectionCatalogToken
    let entries: [WorkspaceCodemapProjectionCatalogCandidate]
    let nextCursor: WorkspaceCodemapProjectionCatalogCursor?
    let isEnd: Bool
    let pathByteCount: UInt64
    let supportedCandidateCountThroughPage: UInt64

    private init(
        token: WorkspaceCodemapProjectionCatalogToken,
        entries: [WorkspaceCodemapProjectionCatalogCandidate],
        nextCursor: WorkspaceCodemapProjectionCatalogCursor?,
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
        request: WorkspaceCodemapProjectionCatalogPageRequest,
        token: WorkspaceCodemapProjectionCatalogToken,
        entries: [WorkspaceCodemapProjectionCatalogCandidate],
        nextCursor: WorkspaceCodemapProjectionCatalogCursor?,
        isEnd: Bool,
        supportedCandidateCountThroughPage: UInt64
    ) -> Result<Self, WorkspaceCodemapProjectionCatalogPageError> {
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
            let cursor = WorkspaceCodemapProjectionCatalogCursor(
                standardizedRelativePath: entry.identity.standardizedRelativePath,
                fileID: entry.identity.fileID
            )
            if let previous {
                guard projectionCatalogKeyPrecedes(previous, cursor) else {
                    return .failure(request.cursor == previous ? .cursorOrder : .nonCanonicalOrder)
                }
            }
            previous = cursor
            guard let byteCount = UInt64(exactly: entry.identity.standardizedRelativePath.utf8.count)
            else { return .failure(.accounting(.overflow(.catalogPathBytes))) }
            do {
                pathByteCount = try projectionAdding(
                    pathByteCount,
                    byteCount,
                    field: .catalogPathBytes
                )
            } catch let error as WorkspaceCodemapProjectionAccountingError {
                return .failure(.accounting(error))
            } catch {
                preconditionFailure("Unexpected projection page error: \(error)")
            }
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

enum WorkspaceCodemapProjectionCatalogUnavailableReason: Hashable {
    case rootNotCurrent
    case catalogNotReady
    case catalogUnavailable
}

enum WorkspaceCodemapProjectionCatalogPageDisposition: Hashable {
    case page(WorkspaceCodemapProjectionCatalogPage)
    case stale
    case unavailable(WorkspaceCodemapProjectionCatalogUnavailableReason)
}

enum WorkspaceCodemapProjectionCatalogTokenDisposition: Hashable {
    case current
    case stale
    case unavailable(WorkspaceCodemapProjectionCatalogUnavailableReason)
}

struct WorkspaceCodemapProjectionGeneration: Hashable {
    let catalogToken: WorkspaceCodemapProjectionCatalogToken
    let repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken
    let contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration
    let schemaVersion: UInt32
    let policyVersion: UInt32

    init(
        catalogToken: WorkspaceCodemapProjectionCatalogToken,
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

enum WorkspaceCodemapProjectionTerminalArtifactReason: Hashable {
    case oversize
    case decodeFailed
    case parseFailed
}

enum WorkspaceCodemapProjectionTerminalExclusionReason: Hashable {
    case securityExcluded
    case nonRegular
    case gitlink
    case repositoryBoundary
}

enum WorkspaceCodemapProjectionEntryOutcome: Hashable {
    case contributed(CodeMapSelectionGraphContribution)
    case empty(CodeMapSelectionGraphContribution)
    case terminalArtifact(WorkspaceCodemapProjectionTerminalArtifactReason)
    case terminalExcluded(WorkspaceCodemapProjectionTerminalExclusionReason)
}

struct WorkspaceCodemapProjectionEntry: Hashable {
    let identity: WorkspaceCodemapArtifactBindingIdentity
    let requestGeneration: UInt64
    let pathGeneration: UInt64
    let pipelineIdentity: CodeMapPipelineIdentity
    let outcome: WorkspaceCodemapProjectionEntryOutcome
}

enum WorkspaceCodemapProjectionAccountingField: Hashable {
    case supportedCandidates
    case processedCandidates
    case contributed
    case empty
    case terminalArtifacts
    case terminalExcluded
    case transient
    case catalogPages
    case catalogPathBytes
    case publishedSegments
    case publishedSegmentBytes
    case retainedPathBytes
    case retainedSourceBytes
    case retainedProjectionBytes
    case stagedGraphBytes
    case residentGraphBytes
    case queuedManifestMutationBytes
}

enum WorkspaceCodemapProjectionAccountingError: Error, Hashable {
    case overflow(WorkspaceCodemapProjectionAccountingField)
    case underflow(WorkspaceCodemapProjectionAccountingField)
}

struct WorkspaceCodemapProjectionCounts: Hashable {
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
    ) -> Result<Self, WorkspaceCodemapProjectionAccountingError> {
        do {
            return try .success(Self(
                supportedCandidateCount: projectionAdding(
                    supportedCandidateCount,
                    other.supportedCandidateCount,
                    field: .supportedCandidates
                ),
                processedCandidateCount: projectionAdding(
                    processedCandidateCount,
                    other.processedCandidateCount,
                    field: .processedCandidates
                ),
                contributedCount: projectionAdding(
                    contributedCount,
                    other.contributedCount,
                    field: .contributed
                ),
                emptyCount: projectionAdding(emptyCount, other.emptyCount, field: .empty),
                terminalArtifactCount: projectionAdding(
                    terminalArtifactCount,
                    other.terminalArtifactCount,
                    field: .terminalArtifacts
                ),
                terminalExcludedCount: projectionAdding(
                    terminalExcludedCount,
                    other.terminalExcludedCount,
                    field: .terminalExcluded
                ),
                transientCount: projectionAdding(
                    transientCount,
                    other.transientCount,
                    field: .transient
                )
            ))
        } catch let error as WorkspaceCodemapProjectionAccountingError {
            return .failure(error)
        } catch {
            preconditionFailure("Unexpected projection accounting error: \(error)")
        }
    }
}

struct WorkspaceCodemapProjectionCatalogCompletion: Hashable {
    let token: WorkspaceCodemapProjectionCatalogToken
    let finalCursor: WorkspaceCodemapProjectionCatalogCursor?
    let supportedCandidateCount: UInt64
}

struct WorkspaceCodemapProjectionRetry: Hashable {
    let attempt: UInt64
    let retryAfterMilliseconds: UInt64?
    let nextEligibleAdmissionUptimeNanoseconds: UInt64?
}

struct WorkspaceCodemapProjectionProgress: Hashable {
    static let notStarted = Self(
        phase: .scheduled,
        counts: .zero,
        catalogPageCount: 0,
        catalogPathByteCount: 0,
        publishedSegmentCount: 0,
        publishedSegmentByteCount: 0,
        catalogCompletion: nil
    )

    let phase: WorkspaceCodemapProjectionPreloadPhase
    let counts: WorkspaceCodemapProjectionCounts
    let catalogPageCount: UInt64
    let catalogPathByteCount: UInt64
    let publishedSegmentCount: UInt64
    let publishedSegmentByteCount: UInt64
    let catalogCompletion: WorkspaceCodemapProjectionCatalogCompletion?

    func advancing(
        to phase: WorkspaceCodemapProjectionPreloadPhase,
        by delta: WorkspaceCodemapProjectionProgressDelta,
        catalogCompletion: WorkspaceCodemapProjectionCatalogCompletion? = nil
    ) -> Result<Self, WorkspaceCodemapProjectionAccountingError> {
        let counts: WorkspaceCodemapProjectionCounts
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
                catalogPageCount: projectionAdding(
                    catalogPageCount,
                    delta.catalogPageCount,
                    field: .catalogPages
                ),
                catalogPathByteCount: projectionAdding(
                    catalogPathByteCount,
                    delta.catalogPathByteCount,
                    field: .catalogPathBytes
                ),
                publishedSegmentCount: projectionAdding(
                    publishedSegmentCount,
                    delta.publishedSegmentCount,
                    field: .publishedSegments
                ),
                publishedSegmentByteCount: projectionAdding(
                    publishedSegmentByteCount,
                    delta.publishedSegmentByteCount,
                    field: .publishedSegmentBytes
                ),
                catalogCompletion: catalogCompletion ?? self.catalogCompletion
            ))
        } catch let error as WorkspaceCodemapProjectionAccountingError {
            return .failure(error)
        } catch {
            preconditionFailure("Unexpected projection progress error: \(error)")
        }
    }
}

struct WorkspaceCodemapProjectionProgressDelta: Hashable {
    static let zero = Self(
        counts: .zero,
        catalogPageCount: 0,
        catalogPathByteCount: 0,
        publishedSegmentCount: 0,
        publishedSegmentByteCount: 0
    )

    let counts: WorkspaceCodemapProjectionCounts
    let catalogPageCount: UInt64
    let catalogPathByteCount: UInt64
    let publishedSegmentCount: UInt64
    let publishedSegmentByteCount: UInt64
}

enum WorkspaceCodemapProjectionCoverageProofError: Error, Hashable {
    case catalogTokenMismatch
    case supportedCandidateCountMismatch(expected: UInt64, actual: UInt64)
    case processedCandidateCountMismatch(expected: UInt64, actual: UInt64)
    case transientCandidates(UInt64)
    case coveredCandidateCountMismatch(expected: UInt64, actual: UInt64)
    case accounting(WorkspaceCodemapProjectionAccountingError)
}

struct WorkspaceCodemapProjectionSuccessorSeal: Hashable {
    let predecessorProof: WorkspaceCodemapProjectionCoverageProof
    let successorProof: WorkspaceCodemapProjectionCoverageProof
}

struct WorkspaceCodemapProjectionCoverageProof: Hashable {
    let generation: WorkspaceCodemapProjectionGeneration
    let catalogCompletion: WorkspaceCodemapProjectionCatalogCompletion
    let counts: WorkspaceCodemapProjectionCounts
    let lastSegmentSequence: UInt64?
    let terminalCount: UInt64

    private init(
        generation: WorkspaceCodemapProjectionGeneration,
        catalogCompletion: WorkspaceCodemapProjectionCatalogCompletion,
        counts: WorkspaceCodemapProjectionCounts,
        lastSegmentSequence: UInt64?,
        terminalCount: UInt64
    ) {
        self.generation = generation
        self.catalogCompletion = catalogCompletion
        self.counts = counts
        self.lastSegmentSequence = lastSegmentSequence
        self.terminalCount = terminalCount
    }

    static func validated(
        generation: WorkspaceCodemapProjectionGeneration,
        catalogCompletion: WorkspaceCodemapProjectionCatalogCompletion,
        counts: WorkspaceCodemapProjectionCounts,
        lastSegmentSequence: UInt64?
    ) -> Result<Self, WorkspaceCodemapProjectionCoverageProofError> {
        guard catalogCompletion.token == generation.catalogToken else {
            return .failure(.catalogTokenMismatch)
        }
        guard counts.supportedCandidateCount == catalogCompletion.supportedCandidateCount else {
            return .failure(.supportedCandidateCountMismatch(
                expected: catalogCompletion.supportedCandidateCount,
                actual: counts.supportedCandidateCount
            ))
        }
        guard counts.processedCandidateCount == counts.supportedCandidateCount else {
            return .failure(.processedCandidateCountMismatch(
                expected: counts.supportedCandidateCount,
                actual: counts.processedCandidateCount
            ))
        }
        guard counts.transientCount == 0 else {
            return .failure(.transientCandidates(counts.transientCount))
        }

        let terminalCount: UInt64
        let coveredCount: UInt64
        do {
            terminalCount = try projectionAdding(
                counts.terminalArtifactCount,
                counts.terminalExcludedCount,
                field: .terminalArtifacts
            )
            let artifactCount = try projectionAdding(
                counts.contributedCount,
                counts.emptyCount,
                field: .contributed
            )
            coveredCount = try projectionAdding(
                artifactCount,
                terminalCount,
                field: .supportedCandidates
            )
        } catch let error as WorkspaceCodemapProjectionAccountingError {
            return .failure(.accounting(error))
        } catch {
            preconditionFailure("Unexpected projection proof error: \(error)")
        }

        guard coveredCount == counts.supportedCandidateCount else {
            return .failure(.coveredCandidateCountMismatch(
                expected: counts.supportedCandidateCount,
                actual: coveredCount
            ))
        }
        return .success(Self(
            generation: generation,
            catalogCompletion: catalogCompletion,
            counts: counts,
            lastSegmentSequence: lastSegmentSequence,
            terminalCount: terminalCount
        ))
    }

    func successor(
        contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration
    ) -> WorkspaceCodemapProjectionCoverageProof? {
        guard contributionGeneration > generation.contributionGeneration else { return nil }
        let successorGeneration = WorkspaceCodemapProjectionGeneration(
            catalogToken: generation.catalogToken,
            repositoryAuthority: generation.repositoryAuthority,
            contributionGeneration: contributionGeneration,
            schemaVersion: generation.schemaVersion,
            policyVersion: generation.policyVersion
        )
        guard case let .success(successor) = Self.validated(
            generation: successorGeneration,
            catalogCompletion: catalogCompletion,
            counts: counts,
            lastSegmentSequence: lastSegmentSequence
        ) else { return nil }
        return successor
    }

    var candidateCount: UInt64 {
        counts.supportedCandidateCount
    }

    var contributedCount: UInt64 {
        counts.contributedCount
    }
}

enum WorkspaceCodemapProjectionSegmentError: Error, Hashable {
    case empty
    case zeroByteCount
    case rootMismatch(UUID)
    case duplicateFileID(UUID)
    case pipelineMismatch(UUID)
    case schemaMismatch(UUID)
    case policyMismatch(UUID)
    case contributedWithoutNames(UUID)
    case emptyWithNames(UUID)
}

struct WorkspaceCodemapProjectionSegment: Hashable {
    let generation: WorkspaceCodemapProjectionGeneration
    let sequence: UInt64
    let entries: [WorkspaceCodemapProjectionEntry]
    let progress: WorkspaceCodemapProjectionProgress
    let byteCount: UInt64

    private init(
        generation: WorkspaceCodemapProjectionGeneration,
        sequence: UInt64,
        entries: [WorkspaceCodemapProjectionEntry],
        progress: WorkspaceCodemapProjectionProgress,
        byteCount: UInt64
    ) {
        self.generation = generation
        self.sequence = sequence
        self.entries = entries
        self.progress = progress
        self.byteCount = byteCount
    }

    static func validated(
        generation: WorkspaceCodemapProjectionGeneration,
        sequence: UInt64,
        entries: [WorkspaceCodemapProjectionEntry],
        progress: WorkspaceCodemapProjectionProgress,
        byteCount: UInt64
    ) -> Result<Self, WorkspaceCodemapProjectionSegmentError> {
        guard !entries.isEmpty else { return .failure(.empty) }
        guard byteCount > 0 else { return .failure(.zeroByteCount) }
        var fileIDs = Set<UUID>()
        for entry in entries {
            let fileID = entry.identity.fileID
            guard entry.identity.rootID == generation.rootEpoch.rootID,
                  entry.identity.rootLifetimeID == generation.rootEpoch.rootLifetimeID
            else { return .failure(.rootMismatch(fileID)) }
            guard fileIDs.insert(fileID).inserted else {
                return .failure(.duplicateFileID(fileID))
            }
            switch entry.outcome {
            case let .contributed(contribution):
                guard contribution.artifactKey.pipelineIdentity == entry.pipelineIdentity else {
                    return .failure(.pipelineMismatch(fileID))
                }
                guard contribution.schemaVersion == generation.schemaVersion else {
                    return .failure(.schemaMismatch(fileID))
                }
                guard contribution.policyVersion == generation.policyVersion else {
                    return .failure(.policyMismatch(fileID))
                }
                guard !contribution.sortedUniqueDefinitions.isEmpty ||
                    !contribution.sortedUniqueReferences.isEmpty
                else { return .failure(.contributedWithoutNames(fileID)) }
            case let .empty(contribution):
                guard contribution.artifactKey.pipelineIdentity == entry.pipelineIdentity else {
                    return .failure(.pipelineMismatch(fileID))
                }
                guard contribution.schemaVersion == generation.schemaVersion else {
                    return .failure(.schemaMismatch(fileID))
                }
                guard contribution.policyVersion == generation.policyVersion else {
                    return .failure(.policyMismatch(fileID))
                }
                guard contribution.sortedUniqueDefinitions.isEmpty,
                      contribution.sortedUniqueReferences.isEmpty
                else { return .failure(.emptyWithNames(fileID)) }
            case .terminalArtifact, .terminalExcluded:
                break
            }
        }
        return .success(Self(
            generation: generation,
            sequence: sequence,
            entries: entries,
            progress: progress,
            byteCount: byteCount
        ))
    }
}

enum WorkspaceCodemapProjectionSnapshot: Hashable {
    case segment(WorkspaceCodemapProjectionSegment)
    case seal(WorkspaceCodemapProjectionCoverageProof)
}

enum WorkspaceCodemapProjectionBudgetDimension: Hashable {
    case catalogEntries
    case catalogPathBytes
    case activeBatches
    case retainedSourceBytes
    case retainedProjectionBytes
    case stagedGraphBytes
    case residentGraph(WorkspaceCodemapSelectionGraphSizeDimension)
    case queuedManifestMutationBytes
}

struct WorkspaceCodemapProjectionBudget: Hashable {
    let dimension: WorkspaceCodemapProjectionBudgetDimension
    let attempted: UInt64
    let limit: UInt64
}

enum WorkspaceCodemapProjectionSnapshotDisposition: Hashable {
    case accepted(WorkspaceCodemapProjectionProgress)
    case exactDuplicate(WorkspaceCodemapProjectionProgress)
    case stale
    case superseded
    case busy(retryAfterMilliseconds: UInt64?)
    case budget(
        dimension: WorkspaceCodemapProjectionBudgetDimension,
        attempted: UInt64,
        limit: UInt64
    )
    case unavailable(WorkspaceCodemapSelectionGraphUnavailableReason)
}

struct WorkspaceCodemapProjectionResourceAccounting: Hashable {
    static let zero = Self(
        retainedPathBytes: 0,
        retainedSourceBytes: 0,
        retainedProjectionBytes: 0,
        stagedGraphBytes: 0,
        residentGraphBytes: 0,
        queuedManifestMutationBytes: 0
    )

    let retainedPathBytes: UInt64
    let retainedSourceBytes: UInt64
    let retainedProjectionBytes: UInt64
    let stagedGraphBytes: UInt64
    let residentGraphBytes: UInt64
    let queuedManifestMutationBytes: UInt64

    func adding(
        _ other: Self
    ) -> Result<Self, WorkspaceCodemapProjectionAccountingError> {
        do {
            return try .success(Self(
                retainedPathBytes: projectionAdding(
                    retainedPathBytes,
                    other.retainedPathBytes,
                    field: .retainedPathBytes
                ),
                retainedSourceBytes: projectionAdding(
                    retainedSourceBytes,
                    other.retainedSourceBytes,
                    field: .retainedSourceBytes
                ),
                retainedProjectionBytes: projectionAdding(
                    retainedProjectionBytes,
                    other.retainedProjectionBytes,
                    field: .retainedProjectionBytes
                ),
                stagedGraphBytes: projectionAdding(
                    stagedGraphBytes,
                    other.stagedGraphBytes,
                    field: .stagedGraphBytes
                ),
                residentGraphBytes: projectionAdding(
                    residentGraphBytes,
                    other.residentGraphBytes,
                    field: .residentGraphBytes
                ),
                queuedManifestMutationBytes: projectionAdding(
                    queuedManifestMutationBytes,
                    other.queuedManifestMutationBytes,
                    field: .queuedManifestMutationBytes
                )
            ))
        } catch let error as WorkspaceCodemapProjectionAccountingError {
            return .failure(error)
        } catch {
            preconditionFailure("Unexpected projection accounting error: \(error)")
        }
    }

    func subtracting(
        _ other: Self
    ) -> Result<Self, WorkspaceCodemapProjectionAccountingError> {
        do {
            return try .success(Self(
                retainedPathBytes: projectionSubtracting(
                    retainedPathBytes,
                    other.retainedPathBytes,
                    field: .retainedPathBytes
                ),
                retainedSourceBytes: projectionSubtracting(
                    retainedSourceBytes,
                    other.retainedSourceBytes,
                    field: .retainedSourceBytes
                ),
                retainedProjectionBytes: projectionSubtracting(
                    retainedProjectionBytes,
                    other.retainedProjectionBytes,
                    field: .retainedProjectionBytes
                ),
                stagedGraphBytes: projectionSubtracting(
                    stagedGraphBytes,
                    other.stagedGraphBytes,
                    field: .stagedGraphBytes
                ),
                residentGraphBytes: projectionSubtracting(
                    residentGraphBytes,
                    other.residentGraphBytes,
                    field: .residentGraphBytes
                ),
                queuedManifestMutationBytes: projectionSubtracting(
                    queuedManifestMutationBytes,
                    other.queuedManifestMutationBytes,
                    field: .queuedManifestMutationBytes
                )
            ))
        } catch let error as WorkspaceCodemapProjectionAccountingError {
            return .failure(error)
        } catch {
            preconditionFailure("Unexpected projection accounting error: \(error)")
        }
    }
}

struct WorkspaceCodemapProjectionPipelineScope: Hashable {
    let pipelineIdentity: CodeMapPipelineIdentity
    let manifestGeneration: UInt64?
}

struct WorkspaceCodemapProjectionPreloadCheckpoint: Hashable {
    let generation: WorkspaceCodemapProjectionGeneration
    let engineSessionID: UUID
    let phase: WorkspaceCodemapProjectionPreloadPhase
    let cursor: WorkspaceCodemapProjectionCatalogCursor?
    let progress: WorkspaceCodemapProjectionProgress
    let nextSegmentSequence: UInt64
    let pipelineScopes: [WorkspaceCodemapProjectionPipelineScope]
    let resources: WorkspaceCodemapProjectionResourceAccounting
    let pendingManifestMutationCount: UInt64
    let retry: WorkspaceCodemapProjectionRetry?
    let budget: WorkspaceCodemapProjectionBudget?
}

private func projectionAdding(
    _ lhs: UInt64,
    _ rhs: UInt64,
    field: WorkspaceCodemapProjectionAccountingField
) throws -> UInt64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow else { throw WorkspaceCodemapProjectionAccountingError.overflow(field) }
    return value
}

private func projectionSubtracting(
    _ lhs: UInt64,
    _ rhs: UInt64,
    field: WorkspaceCodemapProjectionAccountingField
) throws -> UInt64 {
    let (value, underflow) = lhs.subtractingReportingOverflow(rhs)
    guard !underflow else { throw WorkspaceCodemapProjectionAccountingError.underflow(field) }
    return value
}

private func projectionCatalogKeyPrecedes(
    _ lhs: WorkspaceCodemapProjectionCatalogCursor,
    _ rhs: WorkspaceCodemapProjectionCatalogCursor
) -> Bool {
    if lhs.standardizedRelativePath != rhs.standardizedRelativePath {
        return lhs.standardizedRelativePath.utf8.lexicographicallyPrecedes(
            rhs.standardizedRelativePath.utf8
        )
    }
    return lhs.fileID.uuidString.utf8.lexicographicallyPrecedes(rhs.fileID.uuidString.utf8)
}
