import Foundation

struct WorkspaceCodemapGraphSizeAccounting: Hashable {
    static let zero = Self(nodes: 0, postings: 0, edges: 0, bytes: 0)

    let nodes: UInt64
    let postings: UInt64
    let edges: UInt64
    let bytes: UInt64
}

import RepoPromptCodeMapCore

struct WorkspaceCodemapGraphSnapshotNode: Hashable {
    let fileID: UUID
    let standardizedRelativePath: String
    let requestGeneration: UInt64
    let pathGeneration: UInt64
    let contribution: CodeMapSelectionGraphContribution
}

struct WorkspaceCodemapGraphEdgeEvidence: Hashable {
    let sourceFileID: UUID
    let targetFileID: UUID
    let matchedNames: [String]
    let candidateCount: UInt64
    let ambiguous: Bool
}

struct WorkspaceCodemapGraphUnresolvedRecord: Hashable {
    let sourceFileID: UUID
    let referencedName: String
    let reason: WorkspaceCodemapGraphUnresolvedReason
}

struct WorkspaceCodemapGraphCommittedSnapshot: Hashable {
    let snapshotID: UUID
    let graphRevision: UInt64
    let rootEpoch: WorkspaceCodemapRootEpoch
    let repositoryAuthority: WorkspaceCodemapRepositoryAuthorityToken
    let catalogWatermark: WorkspaceCodemapGraphIndexCatalogToken
    let coverage: WorkspaceCodemapGraphCatalogCoverage
    let appliedGeneration: WorkspaceCodemapSelectionGraphContributionGeneration
    let schemaVersion: UInt32
    let policyVersion: UInt32
    let slotsByFileID: [UUID: WorkspaceCodemapGraphSlot]
    let nodesByFileID: [UUID: WorkspaceCodemapGraphSnapshotNode]
    let definitionPostings: [String: [UUID]]
    let referencePostings: [String: [UUID]]
    let outgoingEdgesBySource: [UUID: [WorkspaceCodemapGraphEdgeEvidence]]
    let reverseEdgesByTarget: [UUID: [WorkspaceCodemapGraphEdgeEvidence]]
    let unresolvedBySource: [UUID: [WorkspaceCodemapGraphUnresolvedRecord]]
    let sizeAccounting: WorkspaceCodemapGraphSizeAccounting
}

enum WorkspaceCodemapGraphApplyRejection: Error, Hashable {
    case rootEpochMismatch
    case repositoryAuthorityMismatch
    case schemaMismatch
    case policyMismatch
    case staleGeneration
    case generationContinuity
    case catalogWatermarkRegression
    case invalidCheckpoint
    case graphSize(WorkspaceCodemapSelectionGraphSizeRejection)
    case accountingOverflow
}

enum WorkspaceCodemapGraphApplyDisposition: Hashable {
    case unchanged(generation: WorkspaceCodemapSelectionGraphContributionGeneration)
    case committed(
        revision: UInt64,
        appliedGeneration: WorkspaceCodemapSelectionGraphContributionGeneration,
        changedFileCount: Int,
        affectedSourceCount: Int,
        resync: Bool
    )
    case rejected(WorkspaceCodemapGraphApplyRejection)
    case revoked(WorkspaceCodemapGraphRevocationReason)
    case cancelled
}

struct WorkspaceCodemapGraphFenceIdentity: Hashable {
    let fileID: UUID
    let standardizedRelativePath: String?
    let requestGeneration: UInt64?
    let pathGeneration: UInt64?

    init(fileID: UUID, slot: WorkspaceCodemapGraphSlot?) {
        self.fileID = fileID
        standardizedRelativePath = slot?.standardizedRelativePath
        requestGeneration = slot?.requestGeneration
        pathGeneration = slot?.pathGeneration
    }

    func matches(_ slot: WorkspaceCodemapGraphSlot?) -> Bool {
        guard let slot, slot.fileID == fileID else { return slot == nil && standardizedRelativePath == nil }
        guard let standardizedRelativePath, let requestGeneration, let pathGeneration else { return true }
        return slot.standardizedRelativePath == standardizedRelativePath &&
            slot.requestGeneration == requestGeneration &&
            slot.pathGeneration == pathGeneration
    }
}

struct WorkspaceCodemapGraphPinnedSnapshot: Hashable {
    let snapshot: WorkspaceCodemapGraphCommittedSnapshot
    let receipt: WorkspaceCodemapGraphSnapshotReceipt
    let freshness: WorkspaceCodemapGraphSnapshotFreshness
    let reconciling: Bool
    let fenceIdentities: Set<WorkspaceCodemapGraphFenceIdentity>

    func isFenced(_ fileID: UUID) -> Bool {
        fenceIdentities.contains { $0.fileID == fileID && $0.matches(snapshot.slotsByFileID[fileID]) }
    }
}

enum WorkspaceCodemapGraphLatestSnapshotDisposition: Hashable {
    case ready(WorkspaceCodemapGraphPinnedSnapshot)
    case pending
    case revoked(WorkspaceCodemapGraphRevocationReason)
}

enum WorkspaceCodemapGraphReconciliationDisposition: Hashable {
    case started(attempt: Int)
    case coalesced(attempt: Int)
    case committed
    case failedRetryable(attempt: Int)
    case revoked(WorkspaceCodemapGraphRevocationReason)
}

struct WorkspaceCodemapGraphIncrementalAccounting: Hashable {
    let graphRevision: UInt64
    let coverage: WorkspaceCodemapGraphCatalogCoverage?
    let appliedGeneration: WorkspaceCodemapSelectionGraphContributionGeneration
    let observedGeneration: WorkspaceCodemapSelectionGraphContributionGeneration
    let safetyCounter: UInt64
    let fencedFileCount: Int
    let updatesPending: Bool
    let reconciling: Bool
    let reconciliationAttempt: Int?
    let reconciliationDeadlineUptimeNanoseconds: UInt64?
    let activeApply: Bool
    let successfulCommitCount: UInt64
    let resyncCommitCount: UInt64
    let rejectedApplyCount: UInt64
    let lastCommittedUptimeNanoseconds: UInt64?
    let lastCommitIntervalMilliseconds: UInt64?
    let revocationReason: WorkspaceCodemapGraphRevocationReason?
    var diffPullCount: UInt64 = 0
    var resyncPullCount: UInt64 = 0
    var revokedPullCount: UInt64 = 0
    var lastChangedFileCount: Int = 0
    var lastAffectedSourceCount: Int = 0
    var totalChangedFileCount: UInt64 = 0
    var totalAffectedSourceCount: UInt64 = 0
    var currentQueryCount: UInt64 = 0
    var pendingQueryCount: UInt64 = 0
    var partialCoverageQueryCount: UInt64 = 0
    var reconciliationStartedCount: UInt64 = 0
    var reconciliationCoalescedCount: UInt64 = 0
    var reconciliationCommittedCount: UInt64 = 0
    var reconciliationRetryCount: UInt64 = 0
    var reconciliationRevokedCount: UInt64 = 0
    var receiptValidationCount: UInt64 = 0
    var receiptRejectionCount: UInt64 = 0
    var lastApplyDurationMilliseconds: UInt64?
    var maximumApplyDurationMilliseconds: UInt64?
    var highFanoutApplyCount: UInt64 = 0
    var observedToAppliedGenerationLag: UInt64 = 0
}
