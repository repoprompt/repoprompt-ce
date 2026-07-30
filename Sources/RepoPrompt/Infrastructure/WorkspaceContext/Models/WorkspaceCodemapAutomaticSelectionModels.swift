import Foundation

struct WorkspaceCodemapAutomaticSelectionSourceIdentity: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let fileID: UUID
    let catalogGeneration: UInt64
    let requestGeneration: UInt64
}

struct WorkspaceCodemapAutomaticSelectionTarget: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let fileID: UUID
    let catalogGeneration: UInt64
    let requestGeneration: UInt64
    let logicalPath: WorkspaceCodemapLogicalPresentationPath
}

struct WorkspaceCodemapAutomaticSelectionGraphSeed: Hashable {
    let fileID: UUID
    let requestGeneration: UInt64
}

enum WorkspaceCodemapAutomaticSelectionGraphSourceState: Hashable {
    case covered
    case pending
    case notIndexed
    case excluded
    case fenced
    case staleGeneration(expected: UInt64, committed: UInt64?)
}

struct WorkspaceCodemapAutomaticSelectionGraphSource: Hashable {
    let fileID: UUID
    let requestGeneration: UInt64
    let state: WorkspaceCodemapAutomaticSelectionGraphSourceState
}

struct WorkspaceCodemapAutomaticSelectionGraphTarget: Hashable {
    let fileID: UUID
    let requestGeneration: UInt64
    let standardizedRelativePath: String
}

struct WorkspaceCodemapAutomaticSelectionGraphQuery: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let sources: [WorkspaceCodemapAutomaticSelectionGraphSeed]
    let maximumTargetCount: Int
    let maximumResolutionCount: Int
    let maximumReferenceFailureCount: Int
    let maximumByteCount: Int

    init(
        rootEpoch: WorkspaceCodemapRootEpoch,
        sources: [WorkspaceCodemapAutomaticSelectionGraphSeed],
        maximumTargetCount: Int,
        maximumResolutionCount: Int,
        maximumReferenceFailureCount: Int,
        maximumByteCount: Int
    ) {
        precondition(maximumTargetCount >= 0)
        precondition(maximumResolutionCount >= 0)
        precondition(maximumReferenceFailureCount >= 0)
        precondition(maximumByteCount >= 0)
        self.rootEpoch = rootEpoch
        self.sources = sources
        self.maximumTargetCount = maximumTargetCount
        self.maximumResolutionCount = maximumResolutionCount
        self.maximumReferenceFailureCount = maximumReferenceFailureCount
        self.maximumByteCount = maximumByteCount
    }
}

struct WorkspaceCodemapAutomaticSelectionGraphQueryResult: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let receipt: WorkspaceCodemapGraphSnapshotReceipt
    let coverage: WorkspaceCodemapGraphCatalogCoverage
    let freshness: WorkspaceCodemapGraphSnapshotFreshness
    let reconciling: Bool
    let sources: [WorkspaceCodemapAutomaticSelectionGraphSource]
    let targets: [WorkspaceCodemapAutomaticSelectionGraphTarget]
    let resolutionCount: Int
    let referenceFailureCount: Int
    let materializedByteCount: Int
}

enum WorkspaceCodemapAutomaticSelectionBudgetReason: Hashable {
    case sourceLimit(attempted: Int, limit: Int)
    case uniqueSourceLimit(attempted: Int, limit: Int)
    case sourceIssueLimit(attempted: Int, limit: Int)
    case rootLimit(attempted: Int, limit: Int)
    case targetDemandLimit(attempted: Int, limit: Int)
    case targetLimit(attempted: Int, limit: Int)
    case resolutionLimit(attempted: Int, limit: Int)
    case referenceFailureLimit(attempted: Int, limit: Int)
    case byteLimit(attempted: Int, limit: Int)
    case accountingOverflow
}

enum WorkspaceCodemapAutomaticSelectionGraphDisposition: Hashable {
    case ready(WorkspaceCodemapAutomaticSelectionGraphQueryResult)
    case pending
    case revoked(WorkspaceCodemapGraphRevocationReason)
    case budget(WorkspaceCodemapAutomaticSelectionBudgetReason)
    case cancelled
}

enum WorkspaceCodemapAutomaticSelectionStatus: String, Hashable {
    case ok
    case partial
    case pending
    case unavailable
}

enum WorkspaceCodemapAutomaticSelectionIssue: Equatable {
    case emptySources
    case sourceOutsideRootScope(WorkspaceCodemapAutomaticSelectionSourceIdentity)
    case sourceNotCataloged(WorkspaceCodemapAutomaticSelectionSourceIdentity)
    case sourcePending(WorkspaceCodemapAutomaticSelectionSourceIdentity)
    case sourceNotIndexed(WorkspaceCodemapAutomaticSelectionSourceIdentity)
    case sourceExcluded(WorkspaceCodemapAutomaticSelectionSourceIdentity)
    case sourceFenced(WorkspaceCodemapAutomaticSelectionSourceIdentity)
    case sourceGenerationChanged(
        WorkspaceCodemapAutomaticSelectionSourceIdentity,
        committedGeneration: UInt64?
    )
    case rootEpochChanged(WorkspaceCodemapRootEpoch)
    case rootScopeChanged
    case graphNotInitialized(WorkspaceCodemapRootEpoch)
    case updatesPending(WorkspaceCodemapRootEpoch)
    case reconciling(WorkspaceCodemapRootEpoch)
    case graphUnavailable(WorkspaceCodemapRootEpoch)
    case graphRevoked(WorkspaceCodemapRootEpoch, WorkspaceCodemapGraphRevocationReason)
    case targetNotCataloged(rootEpoch: WorkspaceCodemapRootEpoch, fileID: UUID)
    case targetGenerationChanged(rootEpoch: WorkspaceCodemapRootEpoch, fileID: UUID)
    case targetLogicalPathUnavailable(rootEpoch: WorkspaceCodemapRootEpoch, fileID: UUID)
    case targetDemandPending(rootEpoch: WorkspaceCodemapRootEpoch, fileID: UUID)
    case targetDemandUnavailable(
        rootEpoch: WorkspaceCodemapRootEpoch,
        fileID: UUID,
        reason: WorkspaceCodemapArtifactDemandUnavailableReason
    )
    case receiptInvalid(rootEpoch: WorkspaceCodemapRootEpoch, reason: WorkspaceCodemapGraphReceiptInvalidReason?)
    case budget(WorkspaceCodemapAutomaticSelectionBudgetReason)
}

enum WorkspaceCodemapAutomaticSelectionAggregateCoverage: Equatable {
    case ok
    case partial([WorkspaceCodemapAutomaticSelectionIssue])
    case pending([WorkspaceCodemapAutomaticSelectionIssue])
    case unavailable([WorkspaceCodemapAutomaticSelectionIssue])

    var status: WorkspaceCodemapAutomaticSelectionStatus {
        switch self {
        case .ok: .ok
        case .partial: .partial
        case .pending: .pending
        case .unavailable: .unavailable
        }
    }
}

struct WorkspaceCodemapAutomaticSelectionRootReceipt: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let graphReceipt: WorkspaceCodemapGraphSnapshotReceipt
    let sources: [WorkspaceCodemapAutomaticSelectionGraphSeed]
    let targets: [WorkspaceCodemapAutomaticSelectionTarget]

    var affectedFileIDs: Set<UUID> {
        Set(sources.map(\.fileID)).union(targets.map(\.fileID))
    }
}

struct WorkspaceCodemapAutomaticSelectionReceipt: Hashable {
    let rootScope: WorkspaceLookupRootScope
    let rootScopeEpochs: [WorkspaceCodemapRootEpoch]
    let roots: [WorkspaceCodemapAutomaticSelectionRootReceipt]
}

struct WorkspaceCodemapAutomaticSelectionRootResult: Equatable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let status: WorkspaceCodemapAutomaticSelectionStatus
    let targets: [WorkspaceCodemapAutomaticSelectionTarget]
    let sources: [WorkspaceCodemapAutomaticSelectionGraphSource]
    let issues: [WorkspaceCodemapAutomaticSelectionIssue]
    let coverage: WorkspaceCodemapGraphCatalogCoverage?
    let graphTargetCount: Int
    let graphResolutionCount: Int
    let graphReferenceFailureCount: Int
    let graphByteCount: Int
    let receipt: WorkspaceCodemapAutomaticSelectionRootReceipt?
}

struct WorkspaceCodemapAutomaticSelectionResult: Equatable {
    let roots: [WorkspaceCodemapAutomaticSelectionRootResult]
    let aggregateCoverage: WorkspaceCodemapAutomaticSelectionAggregateCoverage
    let receipt: WorkspaceCodemapAutomaticSelectionReceipt?

    init(
        roots: [WorkspaceCodemapAutomaticSelectionRootResult],
        aggregateCoverage: WorkspaceCodemapAutomaticSelectionAggregateCoverage? = nil,
        receipt: WorkspaceCodemapAutomaticSelectionReceipt? = nil
    ) {
        self.roots = roots.sorted { workspaceCodemapRootEpochPrecedes($0.rootEpoch, $1.rootEpoch) }
        self.aggregateCoverage = aggregateCoverage ?? Self.aggregate(for: self.roots)
        self.receipt = receipt
    }

    var status: WorkspaceCodemapAutomaticSelectionStatus {
        aggregateCoverage.status
    }

    /// Useful targets survive mixed-root partial, pending, and unavailable results.
    var targets: [WorkspaceCodemapAutomaticSelectionTarget] {
        roots.flatMap(\.targets).sorted(by: automaticSelectionTargetPrecedes)
    }

    var issues: [WorkspaceCodemapAutomaticSelectionIssue] {
        roots.flatMap(\.issues).sorted(by: automaticSelectionIssuePrecedes)
    }

    private static func aggregate(
        for roots: [WorkspaceCodemapAutomaticSelectionRootResult]
    ) -> WorkspaceCodemapAutomaticSelectionAggregateCoverage {
        guard !roots.isEmpty else { return .unavailable([.emptySources]) }
        let issues = roots.flatMap(\.issues).sorted(by: automaticSelectionIssuePrecedes)
        let hasTargets = roots.contains { !$0.targets.isEmpty }
        if roots.allSatisfy({ $0.status == .ok }) { return .ok }
        if hasTargets { return .partial(issues) }
        if roots.contains(where: { $0.status == .pending || $0.status == .partial }) {
            return .pending(issues)
        }
        return .unavailable(issues)
    }
}

enum WorkspaceCodemapAutomaticSelectionRootRevalidation: Equatable {
    case valid(rootEpoch: WorkspaceCodemapRootEpoch, targets: [WorkspaceCodemapAutomaticSelectionTarget])
    case invalid(rootEpoch: WorkspaceCodemapRootEpoch, issues: [WorkspaceCodemapAutomaticSelectionIssue])
}

struct WorkspaceCodemapAutomaticSelectionRevalidation: Equatable {
    let roots: [WorkspaceCodemapAutomaticSelectionRootRevalidation]
    let validTargets: [WorkspaceCodemapAutomaticSelectionTarget]
    let issues: [WorkspaceCodemapAutomaticSelectionIssue]
}

struct WorkspaceCodemapRootScopedFileSlot: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let fileID: UUID

    init(rootEpoch: WorkspaceCodemapRootEpoch, fileID: UUID) {
        self.rootEpoch = rootEpoch
        self.fileID = fileID
    }

    init(target: WorkspaceCodemapAutomaticSelectionTarget) {
        self.init(rootEpoch: target.rootEpoch, fileID: target.fileID)
    }

    init(ticket: WorkspaceCodemapArtifactDemandTicket) {
        self.init(rootEpoch: ticket.rootEpoch, fileID: ticket.fileID)
    }

    init(source: WorkspaceCodemapAutomaticSelectionSourceIdentity) {
        self.init(rootEpoch: source.rootEpoch, fileID: source.fileID)
    }
}

func workspaceCodemapRootEpochPrecedes(
    _ lhs: WorkspaceCodemapRootEpoch,
    _ rhs: WorkspaceCodemapRootEpoch
) -> Bool {
    if lhs.rootID != rhs.rootID { return lhs.rootID.uuidString < rhs.rootID.uuidString }
    return lhs.rootLifetimeID.uuidString < rhs.rootLifetimeID.uuidString
}

func automaticSelectionTargetPrecedes(
    _ lhs: WorkspaceCodemapAutomaticSelectionTarget,
    _ rhs: WorkspaceCodemapAutomaticSelectionTarget
) -> Bool {
    if lhs.rootEpoch != rhs.rootEpoch {
        return workspaceCodemapRootEpochPrecedes(lhs.rootEpoch, rhs.rootEpoch)
    }
    if lhs.logicalPath.displayPath != rhs.logicalPath.displayPath {
        return lhs.logicalPath.displayPath.utf8.lexicographicallyPrecedes(rhs.logicalPath.displayPath.utf8)
    }
    return lhs.fileID.uuidString < rhs.fileID.uuidString
}

func automaticSelectionIssuePrecedes(
    _ lhs: WorkspaceCodemapAutomaticSelectionIssue,
    _ rhs: WorkspaceCodemapAutomaticSelectionIssue
) -> Bool {
    String(reflecting: lhs) < String(reflecting: rhs)
}

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

struct WorkspaceCodemapAutomaticSelectionBudgetPolicy: Hashable {
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
