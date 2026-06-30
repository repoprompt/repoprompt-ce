import Foundation

struct WorkspaceCodemapStructureOutputLimits: Equatable {
    let maximumFileCount: Int
    let maximumCodemapTokenCount: Int

    init(maximumFileCount: Int, maximumCodemapTokenCount: Int) {
        precondition(maximumFileCount > 0)
        precondition(maximumCodemapTokenCount >= 0)
        self.maximumFileCount = maximumFileCount
        self.maximumCodemapTokenCount = maximumCodemapTokenCount
    }
}

enum WorkspaceCodemapStructureOutcome: String, Equatable {
    case ready
    case partial
    case pending
    case busy
    case timeout
    case unavailable
    case stale
    case budget
}

enum WorkspaceCodemapStructureIssue: Equatable {
    case candidate(WorkspaceCodemapOperationCandidateIssue)
    case artifactPending(fileID: UUID, ticket: WorkspaceCodemapArtifactDemandTicket)
    case artifactUnavailable(fileID: UUID, reason: WorkspaceCodemapArtifactDemandUnavailableReason)
    case traversalPartial(WorkspaceCodemapStructureTraversalPartialReason)
    case traversalPending(WorkspaceCodemapStructureTraversalPendingReason)
    case traversalUnavailable(WorkspaceCodemapStructureTraversalUnavailableReason)
    case traversalStale(WorkspaceCodemapStructureTraversalStaleReason)
    case traversalBudget(WorkspaceCodemapStructureTraversalBudgetReason)
    case busy(retryAfterMilliseconds: Int)
    case readinessTimeout(
        elapsedMilliseconds: Int,
        limitMilliseconds: Int,
        retryAfterMilliseconds: Int
    )
    case projectionUnavailable(
        reason: WorkspaceCodemapProjectionDemandUnavailableReason,
        retryAfterMilliseconds: Int?
    )
    case projectionBudget(WorkspaceCodemapProjectionBudget)
    case freezeUnavailable(
        rootEpoch: WorkspaceCodemapRootEpoch,
        reason: WorkspaceCodemapPresentationFreezeUnavailableReason
    )
    case renderUnavailable(
        rootEpoch: WorkspaceCodemapRootEpoch,
        reason: WorkspaceCodemapPresentationRenderUnavailableReason
    )
    case fileLimit(attempted: Int, limit: Int)
    case seedDemandLimit(attempted: Int, limit: Int)
    case tokenLimit(path: String, attempted: Int, limit: Int)
    case publicationStale(WorkspaceCodemapStructurePublicationStaleReason)
}

struct WorkspaceCodemapStructureRenderedEntry: Equatable {
    let entry: WorkspaceCodemapOperationRenderedEntry
    let isSeed: Bool
    let depth: Int
    let reachedBy: Set<WorkspaceCodemapStructureTraversalReachDirection>
}

struct WorkspaceCodemapStructurePresentation: Equatable {
    let outcome: WorkspaceCodemapStructureOutcome
    let entries: [WorkspaceCodemapStructureRenderedEntry]
    let issues: [WorkspaceCodemapStructureIssue]
    let requestedSeedCount: Int
    let resolvedSeedCount: Int
    let examinedEdgeCount: Int
    let codemapTokenCount: Int

    static func stale(
        _ reason: WorkspaceCodemapStructurePublicationStaleReason,
        requestedSeedCount: Int
    ) -> Self {
        Self(
            outcome: .stale,
            entries: [],
            issues: [.publicationStale(reason)],
            requestedSeedCount: requestedSeedCount,
            resolvedSeedCount: 0,
            examinedEdgeCount: 0,
            codemapTokenCount: 0
        )
    }
}
