import Foundation

struct WorkspaceCodemapSelectionGraphRuntimeKey: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let catalogGeneration: UInt64
    let repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken
    let contributionGeneration: WorkspaceCodemapSelectionGraphContributionGeneration
    let schemaVersion: UInt32
    let policyVersion: UInt32

    init(
        snapshot: WorkspaceCodemapLiveGraphSnapshot,
        schemaVersion: UInt32 = CodeMapSelectionGraphContribution.currentSchemaVersion,
        policyVersion: UInt32 = CodeMapSelectionGraphContribution.currentPolicyVersion
    ) {
        rootEpoch = snapshot.rootEpoch
        catalogGeneration = snapshot.catalogGeneration
        repositoryAuthority = snapshot.repositoryAuthority
        contributionGeneration = snapshot.contributionGeneration
        self.schemaVersion = schemaVersion
        self.policyVersion = policyVersion
    }

    init(generation: WorkspaceCodemapProjectionGeneration) {
        rootEpoch = generation.rootEpoch
        catalogGeneration = generation.catalogGeneration
        repositoryAuthority = generation.repositoryAuthority
        contributionGeneration = generation.contributionGeneration
        schemaVersion = generation.schemaVersion
        policyVersion = generation.policyVersion
    }
}

struct WorkspaceCodemapSelectionGraphRuntimeSizeAccounting: Hashable {
    static let zero = Self(nodes: 0, postings: 0, edges: 0, bytes: 0)

    let nodes: UInt64
    let postings: UInt64
    let edges: UInt64
    let bytes: UInt64

    init(_ accounting: WorkspaceCodemapSelectionGraphSizeAccounting) {
        nodes = accounting.nodes
        postings = accounting.postings
        edges = accounting.edges
        bytes = accounting.bytes
    }

    init(nodes: UInt64, postings: UInt64, edges: UInt64, bytes: UInt64) {
        self.nodes = nodes
        self.postings = postings
        self.edges = edges
        self.bytes = bytes
    }
}

struct WorkspaceCodemapSelectionGraphRuntimePublishedSummary: Hashable {
    let key: WorkspaceCodemapSelectionGraphRuntimeKey
    let nodeCount: UInt64
    let uniqueEdgeCount: UInt64
    let sizeAccounting: WorkspaceCodemapSelectionGraphRuntimeSizeAccounting
    let isEmpty: Bool
    let definitionUniverseCoverage: WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage

    init(
        key: WorkspaceCodemapSelectionGraphRuntimeKey,
        nodeCount: UInt64,
        uniqueEdgeCount: UInt64,
        sizeAccounting: WorkspaceCodemapSelectionGraphRuntimeSizeAccounting,
        isEmpty: Bool,
        definitionUniverseCoverage: WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage = .incomplete(
            progress: .notStarted,
            remainingCount: nil,
            retry: nil
        )
    ) {
        self.key = key
        self.nodeCount = nodeCount
        self.uniqueEdgeCount = uniqueEdgeCount
        self.sizeAccounting = sizeAccounting
        self.isEmpty = isEmpty
        self.definitionUniverseCoverage = definitionUniverseCoverage
    }
}

struct WorkspaceCodemapSelectionGraphRuntimePolicy: Hashable {
    static let initial = Self(
        maximumActiveRebuildCount: 1,
        maximumReservedBindingCount: 100_000,
        maximumInputBindingCount: 100_000,
        maximumSelectedSourceCountPerQuery: 4096,
        maximumResolvedTargetCountPerQuery: 100_000,
        maximumReferenceFailureCountPerQuery: 100_000,
        graphSizePolicy: .initial,
        maximumProjectionSegmentByteCount: 8 * 1024 * 1024,
        maximumStagedProjectionByteCount: 32 * 1024 * 1024
    )

    let maximumActiveRebuildCount: Int
    let maximumReservedBindingCount: Int
    let maximumInputBindingCount: Int
    let maximumSelectedSourceCountPerQuery: Int
    let maximumResolvedTargetCountPerQuery: Int
    let maximumReferenceFailureCountPerQuery: Int
    let graphSizePolicy: WorkspaceCodemapSelectionGraphSizePolicy
    let maximumProjectionSegmentByteCount: UInt64
    let maximumStagedProjectionByteCount: UInt64

    init(
        maximumActiveRebuildCount: Int,
        maximumReservedBindingCount: Int,
        maximumInputBindingCount: Int,
        maximumSelectedSourceCountPerQuery: Int,
        maximumResolvedTargetCountPerQuery: Int,
        maximumReferenceFailureCountPerQuery: Int,
        graphSizePolicy: WorkspaceCodemapSelectionGraphSizePolicy,
        maximumProjectionSegmentByteCount: UInt64 = 8 * 1024 * 1024,
        maximumStagedProjectionByteCount: UInt64 = 32 * 1024 * 1024
    ) {
        precondition(maximumActiveRebuildCount > 0)
        precondition(maximumReservedBindingCount > 0)
        precondition(maximumInputBindingCount > 0)
        precondition(maximumSelectedSourceCountPerQuery > 0)
        precondition(maximumResolvedTargetCountPerQuery > 0)
        precondition(maximumReferenceFailureCountPerQuery > 0)
        precondition(maximumProjectionSegmentByteCount > 0)
        precondition(maximumStagedProjectionByteCount >= maximumProjectionSegmentByteCount)
        self.maximumActiveRebuildCount = maximumActiveRebuildCount
        self.maximumReservedBindingCount = maximumReservedBindingCount
        self.maximumInputBindingCount = maximumInputBindingCount
        self.maximumSelectedSourceCountPerQuery = maximumSelectedSourceCountPerQuery
        self.maximumResolvedTargetCountPerQuery = maximumResolvedTargetCountPerQuery
        self.maximumReferenceFailureCountPerQuery = maximumReferenceFailureCountPerQuery
        self.graphSizePolicy = graphSizePolicy
        self.maximumProjectionSegmentByteCount = maximumProjectionSegmentByteCount
        self.maximumStagedProjectionByteCount = maximumStagedProjectionByteCount
    }
}

enum WorkspaceCodemapSelectionGraphProjectionByteAccounting {
    /// Conservative retained-byte accounting for a normalized immutable segment. The graph
    /// recomputes this value and never trusts a producer's declared byte count on its own.
    static func normalizedByteCount(
        entries: [WorkspaceCodemapProjectionEntry]
    ) -> Result<UInt64, WorkspaceCodemapProjectionAccountingError> {
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
        } catch let error as WorkspaceCodemapProjectionAccountingError {
            return .failure(error)
        } catch {
            preconditionFailure("Unexpected projection byte-accounting error: \(error)")
        }
    }

    private static func add(_ current: UInt64, _ value: Int) throws -> UInt64 {
        guard let converted = UInt64(exactly: value) else {
            throw WorkspaceCodemapProjectionAccountingError.overflow(.stagedGraphBytes)
        }
        let (next, overflow) = current.addingReportingOverflow(converted)
        guard !overflow else {
            throw WorkspaceCodemapProjectionAccountingError.overflow(.stagedGraphBytes)
        }
        return next
    }

    private static func add(_ current: UInt64, _ value: UInt64) throws -> UInt64 {
        let (next, overflow) = current.addingReportingOverflow(value)
        guard !overflow else {
            throw WorkspaceCodemapProjectionAccountingError.overflow(.stagedGraphBytes)
        }
        return next
    }
}

enum WorkspaceCodemapSelectionGraphRuntimeExternalUnavailableReason: Hashable {
    case rootUnloaded
    case authorityRevoked
}

enum WorkspaceCodemapSelectionGraphRuntimeValidationReason: Hashable {
    case bindingNotResolved
    case terminalBinding
    case bindingRootEpochMismatch
    case catalogGenerationMismatch
    case repositoryAuthorityMismatch
    case duplicateFileID
    case duplicateRelativePath
    case inconsistentCompletionAuthority
    case contributionSchemaMismatch
    case contributionPolicyMismatch
}

enum WorkspaceCodemapSelectionGraphRuntimeBusyReason: Hashable {
    case actorActiveRebuildLimit
    case actorReservedBindingLimit
    case processAdmission(CodeMapSelectionGraphAdmissionBusyReason)
}

enum WorkspaceCodemapSelectionGraphRuntimeRejectionReason: Hashable {
    case rootEpochMismatch
    case staleSnapshot(
        received: WorkspaceCodemapSelectionGraphContributionGeneration,
        current: WorkspaceCodemapSelectionGraphContributionGeneration
    )
    case equalGenerationAuthorityConflict
    case rootUnavailable(WorkspaceCodemapSelectionGraphRuntimeExternalUnavailableReason)
    case invalidSnapshot(WorkspaceCodemapSelectionGraphRuntimeValidationReason)
    case inputBindingLimit(attempted: Int, limit: Int)
    case graphSize(WorkspaceCodemapSelectionGraphSizeRejection)
    case modelStore(WorkspaceCodemapSelectionGraphContributionRejection)
    case edge(WorkspaceCodemapSelectionGraphEdgeRejection)
    case accountingOverflow
}

enum WorkspaceCodemapSelectionGraphRuntimeRebuildDisposition: Hashable {
    case published(WorkspaceCodemapSelectionGraphRuntimePublishedSummary)
    case publishedEmpty(WorkspaceCodemapSelectionGraphRuntimePublishedSummary)
    case busy(
        WorkspaceCodemapSelectionGraphRuntimeKey,
        WorkspaceCodemapSelectionGraphRuntimeBusyReason
    )
    case cancelled(WorkspaceCodemapSelectionGraphRuntimeKey)
    case rejected(
        WorkspaceCodemapSelectionGraphRuntimeKey?,
        WorkspaceCodemapSelectionGraphRuntimeRejectionReason
    )
    case superseded(WorkspaceCodemapSelectionGraphRuntimeKey)
}

struct WorkspaceCodemapSelectionGraphRuntimeQuerySource: Hashable {
    let fileID: UUID
    let requestGeneration: UInt64
}

struct WorkspaceCodemapSelectionGraphRuntimeQueryOutputBudget: Hashable {
    static let unbounded = Self(
        maximumResolvedTargetCount: .max,
        maximumResolutionCount: .max,
        maximumReferenceFailureCount: .max,
        maximumByteCount: .max
    )

    let maximumResolvedTargetCount: Int
    let maximumResolutionCount: Int
    let maximumReferenceFailureCount: Int
    let maximumByteCount: Int
}

enum WorkspaceCodemapSelectionGraphRuntimeQueryOutputBudgetDimension: Hashable {
    case resolvedTargets
    case resolutions
    case referenceFailures
    case bytes
}

struct WorkspaceCodemapSelectionGraphRuntimeQuery: Hashable {
    let key: WorkspaceCodemapSelectionGraphRuntimeKey
    let selectedSources: [WorkspaceCodemapSelectionGraphRuntimeQuerySource]
    let outputBudget: WorkspaceCodemapSelectionGraphRuntimeQueryOutputBudget

    init(
        key: WorkspaceCodemapSelectionGraphRuntimeKey,
        selectedSources: [WorkspaceCodemapSelectionGraphRuntimeQuerySource],
        outputBudget: WorkspaceCodemapSelectionGraphRuntimeQueryOutputBudget = .unbounded
    ) {
        self.key = key
        self.selectedSources = selectedSources
        self.outputBudget = outputBudget
    }
}

struct WorkspaceCodemapSelectionGraphRuntimeEndpoint: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let fileID: UUID
    let requestGeneration: UInt64
}

struct WorkspaceCodemapSelectionGraphRuntimeSourceCoverage: Hashable {
    let source: WorkspaceCodemapSelectionGraphRuntimeQuerySource
    let state: WorkspaceCodemapSelectionGraphSourceCoverageState
}

struct WorkspaceCodemapSelectionGraphRuntimeResolution: Hashable {
    let source: WorkspaceCodemapSelectionGraphRuntimeEndpoint
    let target: WorkspaceCodemapSelectionGraphRuntimeEndpoint
}

struct WorkspaceCodemapSelectionGraphRuntimeReferenceFailureRecord: Hashable {
    let source: WorkspaceCodemapSelectionGraphRuntimeEndpoint
    let referencedName: String
    let failure: WorkspaceCodemapSelectionGraphReferenceFailure
}

struct WorkspaceCodemapSelectionGraphRuntimeQueryResult: Hashable {
    let key: WorkspaceCodemapSelectionGraphRuntimeKey
    let selectedSources: [WorkspaceCodemapSelectionGraphRuntimeQuerySource]
    let targets: [WorkspaceCodemapSelectionGraphRuntimeEndpoint]
    let resolutions: [WorkspaceCodemapSelectionGraphRuntimeResolution]
    let sourceCoverage: [WorkspaceCodemapSelectionGraphRuntimeSourceCoverage]
    let definitionUniverseCoverage: WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage
    let referenceFailures: [WorkspaceCodemapSelectionGraphRuntimeReferenceFailureRecord]
    let publishedSummary: WorkspaceCodemapSelectionGraphRuntimePublishedSummary
    let materializedByteCount: Int
}

enum WorkspaceCodemapStructureTraversalDirection: String, Hashable {
    case referencedDefinitions
    case referrers
    case both
}

enum WorkspaceCodemapStructureTraversalReachDirection: String, Hashable {
    case referencedDefinitions
    case referrers
}

struct WorkspaceCodemapStructureTraversalLimits: Hashable {
    let maximumDepth: Int
    let maximumNodeCount: Int
    let maximumEdgeCount: Int
    let maximumByteCount: Int

    init(
        maximumDepth: Int,
        maximumNodeCount: Int,
        maximumEdgeCount: Int,
        maximumByteCount: Int
    ) {
        precondition(maximumDepth >= 0)
        precondition(maximumNodeCount > 0)
        precondition(maximumEdgeCount >= 0)
        precondition(maximumByteCount > 0)
        self.maximumDepth = maximumDepth
        self.maximumNodeCount = maximumNodeCount
        self.maximumEdgeCount = maximumEdgeCount
        self.maximumByteCount = maximumByteCount
    }
}

struct WorkspaceCodemapSelectionGraphRuntimeStructureQuery: Hashable {
    let key: WorkspaceCodemapSelectionGraphRuntimeKey
    let seeds: [WorkspaceCodemapSelectionGraphRuntimeQuerySource]
    let direction: WorkspaceCodemapStructureTraversalDirection
    let limits: WorkspaceCodemapStructureTraversalLimits
}

struct WorkspaceCodemapSelectionGraphRuntimeStructureNode: Hashable {
    let endpoint: WorkspaceCodemapSelectionGraphRuntimeEndpoint
    let depth: Int
    let reachedBy: Set<WorkspaceCodemapStructureTraversalReachDirection>
}

struct WorkspaceCodemapSelectionGraphRuntimeStructureResult: Hashable {
    let key: WorkspaceCodemapSelectionGraphRuntimeKey
    let seeds: [WorkspaceCodemapSelectionGraphRuntimeQuerySource]
    let nodes: [WorkspaceCodemapSelectionGraphRuntimeStructureNode]
    let examinedEdgeCount: Int
    let definitionUniverseCoverage: WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage
    let referenceFailures: [WorkspaceCodemapSelectionGraphRuntimeReferenceFailureRecord]
    let publishedSummary: WorkspaceCodemapSelectionGraphRuntimePublishedSummary
    let materializedByteCount: Int
}

enum WorkspaceCodemapSelectionGraphRuntimeStructureBudgetDimension: Hashable {
    case nodes
    case edges
    case bytes
}

enum WorkspaceCodemapSelectionGraphRuntimeStructureDisposition: Hashable {
    case readyPartial(WorkspaceCodemapSelectionGraphRuntimeStructureResult)
    case budget(
        WorkspaceCodemapSelectionGraphRuntimeStructureResult,
        WorkspaceCodemapSelectionGraphRuntimeStructureBudgetDimension
    )
    case definitionUniverse(WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage)
    case unavailable(WorkspaceCodemapSelectionGraphRuntimeQueryUnavailableReason)
}

enum WorkspaceCodemapSelectionGraphRuntimeQueryUnavailableReason: Hashable {
    case notBuilt
    case rebuilding
    case staleCurrentness(currentKey: WorkspaceCodemapSelectionGraphRuntimeKey?)
    case actorAdmissionRejected(WorkspaceCodemapSelectionGraphRuntimeBusyReason)
    case processAdmissionRejected(CodeMapSelectionGraphAdmissionBusyReason)
    case cancelled
    case budgetExceeded
    case outputBudgetExceeded(WorkspaceCodemapSelectionGraphRuntimeQueryOutputBudgetDimension)
    case invalidSnapshot
    case explicitRootUnavailable(WorkspaceCodemapSelectionGraphRuntimeExternalUnavailableReason)
    case invalidQuery
}

enum WorkspaceCodemapSelectionGraphRuntimeQueryDisposition: Hashable {
    case readyPartial(WorkspaceCodemapSelectionGraphRuntimeQueryResult)
    case definitionUniverse(WorkspaceCodemapSelectionGraphDefinitionUniverseCoverage)
    case unavailable(WorkspaceCodemapSelectionGraphRuntimeQueryUnavailableReason)
}

enum WorkspaceCodemapSelectionGraphRuntimeDiagnosticEventKind: Hashable {
    case buildStarted
    case beforePublication
    case projectionSegmentAccepted
    case projectionCoverageSealed
    case projectionCoverageRevoked
}

struct WorkspaceCodemapSelectionGraphRuntimeDiagnosticEvent: Hashable {
    let operationID: UInt64
    let key: WorkspaceCodemapSelectionGraphRuntimeKey
    let kind: WorkspaceCodemapSelectionGraphRuntimeDiagnosticEventKind
}

struct WorkspaceCodemapSelectionGraphRuntimeDiagnostics {
    static let none = Self { _ in }

    let handle: @Sendable (WorkspaceCodemapSelectionGraphRuntimeDiagnosticEvent) -> Void
}

struct WorkspaceCodemapSelectionGraphRuntimeAccounting: Equatable {
    let activeRebuildCount: Int
    let reservedInputBindingCount: Int
    let publishedSummary: WorkspaceCodemapSelectionGraphRuntimePublishedSummary?
    let currentObservedKey: WorkspaceCodemapSelectionGraphRuntimeKey?
    let currentUnavailableReason: WorkspaceCodemapSelectionGraphRuntimeQueryUnavailableReason?
    let publishedCount: UInt64
    let emptyPublishedCount: UInt64
    let actorBusyCount: UInt64
    let processBusyCount: UInt64
    let cancelledCount: UInt64
    let budgetRejectedCount: UInt64
    let invalidSnapshotCount: UInt64
    let supersededPublicationCount: UInt64
    let materializedQueryResultCount: UInt64
    let stagedProjectionByteCount: UInt64
    let residentProjectionByteCount: UInt64
    let acceptedProjectionSegmentCount: UInt64
    let exactDuplicateProjectionSegmentCount: UInt64
    let rejectedProjectionSegmentCount: UInt64
    let completedProjectionCoverageCount: UInt64
    let revokedProjectionCoverageCount: UInt64

    init(
        activeRebuildCount: Int,
        reservedInputBindingCount: Int,
        publishedSummary: WorkspaceCodemapSelectionGraphRuntimePublishedSummary?,
        currentObservedKey: WorkspaceCodemapSelectionGraphRuntimeKey?,
        currentUnavailableReason: WorkspaceCodemapSelectionGraphRuntimeQueryUnavailableReason?,
        publishedCount: UInt64,
        emptyPublishedCount: UInt64,
        actorBusyCount: UInt64,
        processBusyCount: UInt64,
        cancelledCount: UInt64,
        budgetRejectedCount: UInt64,
        invalidSnapshotCount: UInt64,
        supersededPublicationCount: UInt64,
        materializedQueryResultCount: UInt64,
        stagedProjectionByteCount: UInt64 = 0,
        residentProjectionByteCount: UInt64 = 0,
        acceptedProjectionSegmentCount: UInt64 = 0,
        exactDuplicateProjectionSegmentCount: UInt64 = 0,
        rejectedProjectionSegmentCount: UInt64 = 0,
        completedProjectionCoverageCount: UInt64 = 0,
        revokedProjectionCoverageCount: UInt64 = 0
    ) {
        self.activeRebuildCount = activeRebuildCount
        self.reservedInputBindingCount = reservedInputBindingCount
        self.publishedSummary = publishedSummary
        self.currentObservedKey = currentObservedKey
        self.currentUnavailableReason = currentUnavailableReason
        self.publishedCount = publishedCount
        self.emptyPublishedCount = emptyPublishedCount
        self.actorBusyCount = actorBusyCount
        self.processBusyCount = processBusyCount
        self.cancelledCount = cancelledCount
        self.budgetRejectedCount = budgetRejectedCount
        self.invalidSnapshotCount = invalidSnapshotCount
        self.supersededPublicationCount = supersededPublicationCount
        self.materializedQueryResultCount = materializedQueryResultCount
        self.stagedProjectionByteCount = stagedProjectionByteCount
        self.residentProjectionByteCount = residentProjectionByteCount
        self.acceptedProjectionSegmentCount = acceptedProjectionSegmentCount
        self.exactDuplicateProjectionSegmentCount = exactDuplicateProjectionSegmentCount
        self.rejectedProjectionSegmentCount = rejectedProjectionSegmentCount
        self.completedProjectionCoverageCount = completedProjectionCoverageCount
        self.revokedProjectionCoverageCount = revokedProjectionCoverageCount
    }
}
