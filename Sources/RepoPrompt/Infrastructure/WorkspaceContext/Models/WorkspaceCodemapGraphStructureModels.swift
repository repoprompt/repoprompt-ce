import Foundation

enum WorkspaceCodemapStructureStatus: String, Codable, Hashable {
    case ok
    case partial
    case pending
    case unavailable
}

enum WorkspaceCodemapStructureSeedState: String, Codable, Hashable {
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
    let fileID: UUID
    let standardizedRelativePath: String?
    let state: WorkspaceCodemapStructureSeedState
}

struct WorkspaceCodemapGraphStructureNode: Hashable {
    let fileID: UUID
    let standardizedRelativePath: String
    let depth: Int
    let isSeed: Bool
    let reachedBy: Set<WorkspaceCodemapStructureTraversalReachDirection>
}

struct WorkspaceCodemapGraphStructureEdge: Hashable {
    let sourceFileID: UUID
    let targetFileID: UUID
    let symbols: [String]
    let ambiguous: Bool
}

struct WorkspaceCodemapGraphStructureUnresolved: Hashable {
    let sourceFileID: UUID
    let referencedName: String
    let reason: WorkspaceCodemapGraphUnresolvedReason
}

struct WorkspaceCodemapGraphStructureTruncation: Hashable {
    let droppedNodeCount: Int
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
    case maxTokens
    case deadline
    case graphRevoked(WorkspaceCodemapGraphRevocationReason)
    case graphPending
}

struct WorkspaceCodemapGraphStructureRootResult: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let status: WorkspaceCodemapStructureStatus
    let coverage: WorkspaceCodemapGraphCatalogCoverage?
    let updatesPending: Bool
    let reconciling: Bool
    let receipt: WorkspaceCodemapGraphSnapshotReceipt?
    let seeds: [WorkspaceCodemapGraphStructureSeed]
    let nodes: [WorkspaceCodemapGraphStructureNode]
    let edges: [WorkspaceCodemapGraphStructureEdge]
    let unresolved: [WorkspaceCodemapGraphStructureUnresolved]
    let truncation: WorkspaceCodemapGraphStructureTruncation?
    let issues: [WorkspaceCodemapGraphStructureIssue]

    var hasUsefulData: Bool {
        !nodes.isEmpty || !edges.isEmpty || !unresolved.isEmpty
    }
}

struct WorkspaceCodemapStructureIssueRecord: Hashable {
    let code: String
    let phase: String
    let path: String?
    let retryable: Bool
    let retryAfterMilliseconds: Int?
    let attempted: Int?
    let limit: Int?
    let message: String
}

struct WorkspaceCodemapStructureSeedResult: Hashable {
    let fileID: UUID
    let path: String
    let state: WorkspaceCodemapStructureSeedState
}

struct WorkspaceCodemapStructureNodeResult: Hashable {
    let fileID: UUID
    let path: String
    let depth: Int
    let isSeed: Bool
    let reachedBy: Set<WorkspaceCodemapStructureTraversalReachDirection>
}

struct WorkspaceCodemapStructureEdgeResult: Hashable {
    let fromPath: String
    let toPath: String
    let symbols: [String]
    let ambiguous: Bool
}

struct WorkspaceCodemapStructureUnresolvedResult: Hashable {
    let fromPath: String
    let name: String
    let reason: WorkspaceCodemapGraphUnresolvedReason
}

struct WorkspaceCodemapStructureRootResult: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let rootDisplayName: String
    let status: WorkspaceCodemapStructureStatus
    let coverage: WorkspaceCodemapGraphCatalogCoverage?
    let updatesPending: Bool
    let seeds: [WorkspaceCodemapStructureSeedResult]
    let nodes: [WorkspaceCodemapStructureNodeResult]
    let edges: [WorkspaceCodemapStructureEdgeResult]
    let unresolved: [WorkspaceCodemapStructureUnresolvedResult]
    let truncation: WorkspaceCodemapGraphStructureTruncation?
    let issues: [WorkspaceCodemapStructureIssueRecord]
    let receipt: WorkspaceCodemapGraphSnapshotReceipt?

    var hasUsefulData: Bool {
        !nodes.isEmpty || !edges.isEmpty || !unresolved.isEmpty
    }
}

struct WorkspaceCodemapStructureAggregateResult: Hashable {
    let status: WorkspaceCodemapStructureStatus
    let roots: [WorkspaceCodemapStructureRootResult]
    let issues: [WorkspaceCodemapStructureIssueRecord]

    var orderedNodeFileIDs: [UUID] {
        roots.flatMap { $0.nodes.map(\.fileID) }
    }
}

enum WorkspaceCodemapStructureGraphRevalidationResult: Hashable {
    case valid(updatesPending: Bool)
    case invalid(code: String, message: String)
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
