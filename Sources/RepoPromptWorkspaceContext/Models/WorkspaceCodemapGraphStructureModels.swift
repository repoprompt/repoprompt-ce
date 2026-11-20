import Foundation

package enum WorkspaceCodemapStructureStatus: String, Codable, Hashable {
    case ok
    case partial
    case pending
    case unavailable
}

package enum WorkspaceCodemapStructureSeedState: String, Codable, Hashable {
    case covered
    case pending
    case notIndexed = "not_indexed"
    case excluded
}

struct WorkspaceCodemapGraphStructureQuery: Hashable {
    let seedFileIDs: [UUID]
    let direction: WorkspaceCodemapStructureTraversalDirection?
    let maximumDepth: Int
    let budget: WorkspaceCodemapGraphQueryBudget
}

struct WorkspaceCodemapGraphStructureSeed: Hashable {
    package let fileID: UUID
    let standardizedRelativePath: String?
    package let state: WorkspaceCodemapStructureSeedState
}

struct WorkspaceCodemapGraphStructureNode: Hashable {
    package let fileID: UUID
    let standardizedRelativePath: String
    package let depth: Int
    package let isSeed: Bool
    package let reachedBy: Set<WorkspaceCodemapStructureTraversalReachDirection>
}

struct WorkspaceCodemapGraphStructureEdge: Hashable {
    let sourceFileID: UUID
    let targetFileID: UUID
    package let symbols: [String]
    package let ambiguous: Bool
}

struct WorkspaceCodemapGraphStructureUnresolved: Hashable {
    let sourceFileID: UUID
    let referencedName: String
    package let reason: WorkspaceCodemapGraphUnresolvedReason
}

package struct WorkspaceCodemapGraphStructureTruncation: Hashable {
    package let droppedNodeCount: Int
}

enum WorkspaceCodemapGraphStructureIssue: Hashable {
    case emptySeeds
    case updatesPending
    case watcherGapReconciling
    case indexing
    case seedPending(UUID)
    case seedNotIndexed(UUID)
    case seedExcluded(UUID)
    case seedFenced(UUID)
    case sizeLimit
    case deadline
    case graphRevoked(WorkspaceCodemapGraphRevocationReason)
    case graphPending
}

struct WorkspaceCodemapGraphStructureRootResult: Hashable {
    package let rootEpoch: WorkspaceCodemapRootEpoch
    package let status: WorkspaceCodemapStructureStatus
    package let coverage: WorkspaceCodemapGraphCatalogCoverage?
    package let updatesPending: Bool
    let reconciling: Bool
    let receipt: WorkspaceCodemapGraphSnapshotReceipt?
    package let seeds: [WorkspaceCodemapGraphStructureSeed]
    package let nodes: [WorkspaceCodemapGraphStructureNode]
    package let edges: [WorkspaceCodemapGraphStructureEdge]
    package let unresolved: [WorkspaceCodemapGraphStructureUnresolved]
    package let truncation: WorkspaceCodemapGraphStructureTruncation?
    package let issues: [WorkspaceCodemapGraphStructureIssue]

    package var hasUsefulData: Bool {
        !nodes.isEmpty || !edges.isEmpty || !unresolved.isEmpty
    }
}

package struct WorkspaceCodemapStructureIssueRecord: Hashable {
    package let code: String
    package let phase: String
    package let path: String?
    package let retryable: Bool
    package let retryAfterMilliseconds: Int?
    package let attempted: Int?
    package let limit: Int?
    package let message: String
}

package struct WorkspaceCodemapStructureSeedResult: Hashable {
    package let fileID: UUID
    package let path: String
    package let state: WorkspaceCodemapStructureSeedState
}

package struct WorkspaceCodemapStructureNodeResult: Hashable {
    package let fileID: UUID
    package let path: String
    package let depth: Int
    package let isSeed: Bool
    package let reachedBy: Set<WorkspaceCodemapStructureTraversalReachDirection>
}

package struct WorkspaceCodemapStructureEdgeResult: Hashable {
    package let fromPath: String
    package let toPath: String
    package let symbols: [String]
    package let ambiguous: Bool
}

package struct WorkspaceCodemapStructureUnresolvedResult: Hashable {
    package let fromPath: String
    package let name: String
    package let reason: WorkspaceCodemapGraphUnresolvedReason
}

package enum WorkspaceCodemapStructureStopReason: String, Hashable {
    case budgetExhausted = "graph_budget_exhausted"
    case retryExhausted = "graph_retry_exhausted"
    case workerRecoveryExhausted = "graph_worker_recovery_exhausted"
}

package struct WorkspaceCodemapStructureExecutionStop: Hashable {
    package let reason: WorkspaceCodemapStructureStopReason
    package let budget: WorkspaceCodemapGraphIndexBudget?
}

package struct WorkspaceCodemapStructureRootResult: Hashable {
    package let rootEpoch: WorkspaceCodemapRootEpoch
    package let rootDisplayName: String
    package let status: WorkspaceCodemapStructureStatus
    package let coverage: WorkspaceCodemapGraphCatalogCoverage?
    package let updatesPending: Bool
    package let seeds: [WorkspaceCodemapStructureSeedResult]
    package let nodes: [WorkspaceCodemapStructureNodeResult]
    package let edges: [WorkspaceCodemapStructureEdgeResult]
    package let unresolved: [WorkspaceCodemapStructureUnresolvedResult]
    package let truncation: WorkspaceCodemapGraphStructureTruncation?
    package let issues: [WorkspaceCodemapStructureIssueRecord]
    let receipt: WorkspaceCodemapGraphSnapshotReceipt?
    package var executionStop: WorkspaceCodemapStructureExecutionStop?

    package var hasUsefulData: Bool {
        !nodes.isEmpty || !edges.isEmpty || !unresolved.isEmpty
    }
}

package struct WorkspaceCodemapStructureAggregateResult: Hashable {
    package let status: WorkspaceCodemapStructureStatus
    package let roots: [WorkspaceCodemapStructureRootResult]
    package let issues: [WorkspaceCodemapStructureIssueRecord]

    var orderedNodeFileIDs: [UUID] {
        roots.flatMap { $0.nodes.map(\.fileID) }
    }
}

package enum WorkspaceCodemapStructureGraphRevalidationResult: Hashable {
    case valid(updatesPending: Bool)
    case invalid(code: String, message: String)
}

package enum WorkspaceCodemapStructureTraversalDirection: String, Hashable {
    case referencedDefinitions
    case referrers
    case both
}

package enum WorkspaceCodemapStructureTraversalReachDirection: String, Hashable {
    case referencedDefinitions
    case referrers
}
