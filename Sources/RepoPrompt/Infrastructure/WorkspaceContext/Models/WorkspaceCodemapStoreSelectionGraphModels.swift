import Foundation

struct WorkspaceCodemapSelectionGraphFactory {
    private let makeGraph: @Sendable (WorkspaceCodemapRootEpoch) -> WorkspaceCodemapSelectionGraph

    init(
        makeGraph: @escaping @Sendable (WorkspaceCodemapRootEpoch) -> WorkspaceCodemapSelectionGraph
    ) {
        self.makeGraph = makeGraph
    }

    func make(rootEpoch: WorkspaceCodemapRootEpoch) -> WorkspaceCodemapSelectionGraph {
        makeGraph(rootEpoch)
    }

    static let production = Self { rootEpoch in
        WorkspaceCodemapSelectionGraph(rootEpoch: rootEpoch)
    }
}

struct WorkspaceCodemapStoreSelectionGraphSourceIdentity: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let ticket: WorkspaceCodemapArtifactDemandTicket

    init(ticket: WorkspaceCodemapArtifactDemandTicket) {
        rootEpoch = ticket.rootEpoch
        self.ticket = ticket
    }

    init(
        rootEpoch: WorkspaceCodemapRootEpoch,
        ticket: WorkspaceCodemapArtifactDemandTicket
    ) {
        self.rootEpoch = rootEpoch
        self.ticket = ticket
    }
}

struct WorkspaceCodemapStoreSelectionGraphQuery: Hashable {
    let selectedSources: [WorkspaceCodemapStoreSelectionGraphSourceIdentity]
}

struct WorkspaceCodemapSelectionGraphReadinessEvent: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
}

struct WorkspaceCodemapStoreSelectionGraphQueryBudgetPolicy: Hashable {
    static let initial = Self(
        maximumTargetCount: 100_000,
        maximumResolutionCount: 100_000,
        maximumReferenceFailureCount: 100_000
    )

    let maximumRootCount: Int
    let maximumRawSourceCount: Int
    let maximumUniqueSourceCount: Int
    let maximumSourceIssueCount: Int
    let maximumTargetCount: Int
    let maximumResolutionCount: Int
    let maximumReferenceFailureCount: Int
    let maximumByteCount: Int

    init(
        maximumRootCount: Int = 64,
        maximumRawSourceCount: Int = 4096,
        maximumUniqueSourceCount: Int = 4096,
        maximumSourceIssueCount: Int = 4096,
        maximumTargetCount: Int,
        maximumResolutionCount: Int,
        maximumReferenceFailureCount: Int,
        maximumByteCount: Int = 64 * 1024 * 1024
    ) {
        precondition(maximumRootCount > 0)
        precondition(maximumRawSourceCount > 0)
        precondition(maximumUniqueSourceCount > 0)
        precondition(maximumSourceIssueCount >= 0)
        precondition(maximumTargetCount >= 0)
        precondition(maximumResolutionCount >= 0)
        precondition(maximumReferenceFailureCount >= 0)
        precondition(maximumByteCount >= 0)
        self.maximumRootCount = maximumRootCount
        self.maximumRawSourceCount = maximumRawSourceCount
        self.maximumUniqueSourceCount = maximumUniqueSourceCount
        self.maximumSourceIssueCount = maximumSourceIssueCount
        self.maximumTargetCount = maximumTargetCount
        self.maximumResolutionCount = maximumResolutionCount
        self.maximumReferenceFailureCount = maximumReferenceFailureCount
        self.maximumByteCount = maximumByteCount
    }

    func remaining(
        targetCount: Int,
        resolutionCount: Int,
        referenceFailureCount: Int,
        byteCount: Int
    ) -> Self {
        Self(
            maximumRootCount: maximumRootCount,
            maximumRawSourceCount: maximumRawSourceCount,
            maximumUniqueSourceCount: maximumUniqueSourceCount,
            maximumSourceIssueCount: maximumSourceIssueCount,
            maximumTargetCount: maximumTargetCount - targetCount,
            maximumResolutionCount: maximumResolutionCount - resolutionCount,
            maximumReferenceFailureCount: maximumReferenceFailureCount - referenceFailureCount,
            maximumByteCount: maximumByteCount - byteCount
        )
    }
}

enum WorkspaceCodemapStoreSelectionGraphPartialReason: Hashable {
    case sourceCoverageIncomplete
    case referenceFailuresPresent
}

enum WorkspaceCodemapStoreSelectionGraphQueryIncompleteReason: Hashable {
    case definitionUniverse(
        rootEpoch: WorkspaceCodemapRootEpoch,
        progress: WorkspaceCodemapProjectionProgress,
        remainingCount: UInt64?,
        retry: WorkspaceCodemapProjectionRetry?
    )
}

struct WorkspaceCodemapStoreSelectionGraphRootResult: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let result: WorkspaceCodemapSelectionGraphRuntimeQueryResult
    let partialReasons: Set<WorkspaceCodemapStoreSelectionGraphPartialReason>
}

struct WorkspaceCodemapStoreSelectionGraphQueryResult: Hashable {
    let roots: [WorkspaceCodemapStoreSelectionGraphRootResult]
}

enum WorkspaceCodemapStoreSelectionGraphQueryUnavailableReason: Hashable {
    case emptySources
    case foreignRootEpoch(UUID)
    case duplicateSourceConflict(UUID)
    case sourceNotReady(UUID)
    case notActivated(WorkspaceCodemapRootEpoch)
    case invalidGraphResult(WorkspaceCodemapRootEpoch)
    case definitionUniverse(
        rootEpoch: WorkspaceCodemapRootEpoch,
        reason: WorkspaceCodemapSelectionGraphUnavailableReason
    )
    case runtime(
        rootEpoch: WorkspaceCodemapRootEpoch,
        reason: WorkspaceCodemapSelectionGraphRuntimeQueryUnavailableReason
    )
}

enum WorkspaceCodemapStoreSelectionGraphQueryStaleReason: Hashable {
    case currentness(WorkspaceCodemapRootEpoch)
    case runtime(
        rootEpoch: WorkspaceCodemapRootEpoch,
        reason: WorkspaceCodemapSelectionGraphRuntimeQueryUnavailableReason
    )
}

enum WorkspaceCodemapStoreSelectionGraphQueryBusyReason: Hashable {
    case definitionUniverse(
        rootEpoch: WorkspaceCodemapRootEpoch,
        progress: WorkspaceCodemapProjectionProgress,
        retryAfterMilliseconds: UInt64?
    )
    case runtime(
        rootEpoch: WorkspaceCodemapRootEpoch,
        reason: WorkspaceCodemapSelectionGraphRuntimeQueryUnavailableReason
    )
}

enum WorkspaceCodemapStoreSelectionGraphQueryBudgetReason: Hashable {
    case sourceLimit(attempted: Int, limit: Int)
    case uniqueSourceLimit(attempted: Int, limit: Int)
    case sourceIssueLimit(attempted: Int, limit: Int)
    case rootLimit(attempted: Int, limit: Int)
    case targetLimit(attempted: Int, limit: Int)
    case resolutionLimit(attempted: Int, limit: Int)
    case referenceFailureLimit(attempted: Int, limit: Int)
    case byteLimit(attempted: Int, limit: Int)
    case accountingOverflow
    case definitionUniverse(
        rootEpoch: WorkspaceCodemapRootEpoch,
        dimension: WorkspaceCodemapProjectionBudgetDimension,
        attempted: UInt64,
        limit: UInt64
    )
    case runtime(
        rootEpoch: WorkspaceCodemapRootEpoch,
        reason: WorkspaceCodemapSelectionGraphRuntimeQueryUnavailableReason
    )
}

enum WorkspaceCodemapStoreSelectionGraphQueryDisposition: Hashable {
    case readyPartial(WorkspaceCodemapStoreSelectionGraphQueryResult)
    case incomplete(WorkspaceCodemapStoreSelectionGraphQueryIncompleteReason)
    case unavailable(WorkspaceCodemapStoreSelectionGraphQueryUnavailableReason)
    case stale(WorkspaceCodemapStoreSelectionGraphQueryStaleReason)
    case busy(WorkspaceCodemapStoreSelectionGraphQueryBusyReason)
    case budget(WorkspaceCodemapStoreSelectionGraphQueryBudgetReason)
}
