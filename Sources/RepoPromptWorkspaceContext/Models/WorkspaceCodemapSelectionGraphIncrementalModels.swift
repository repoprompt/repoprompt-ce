import Foundation
import RepoPromptFoundation
import RepoPromptPersistence

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
    let rootAuthority: WorkspaceCodemapRootAuthorityToken
    let catalogWatermark: WorkspaceCodemapGraphIndexCatalogToken
    let coverage: WorkspaceCodemapGraphCatalogCoverage
    let appliedGeneration: WorkspaceCodemapSelectionGraphContributionGeneration
    let schemaVersion: UInt32
    let policyVersion: UInt32
    // Persistent (structurally shared) storage: a commit derives the next snapshot by copying
    // only the trie paths its diff touches, while readers keep pinning earlier snapshots.
    // Posting sets and reverse adjacency are unordered; every reader imposes its own order.
    let slotsByFileID: PersistentHashMap<UUID, WorkspaceCodemapGraphSlot>
    let nodesByFileID: PersistentHashMap<UUID, WorkspaceCodemapGraphSnapshotNode>
    let definitionPostings: PersistentHashMap<String, PersistentHashSet<UUID>>
    let referencePostings: PersistentHashMap<String, PersistentHashSet<UUID>>
    /// Per-source evidence, sorted by target path (small, rebuilt only for affected sources).
    let outgoingEdgesBySource: PersistentHashMap<UUID, [WorkspaceCodemapGraphEdgeEvidence]>
    /// Target file ID -> source file ID -> evidence.
    let reverseEdgesByTarget: PersistentHashMap<UUID, PersistentHashMap<UUID, WorkspaceCodemapGraphEdgeEvidence>>
    let unresolvedBySource: PersistentHashMap<UUID, [WorkspaceCodemapGraphUnresolvedRecord]>
    let sizeAccounting: WorkspaceCodemapGraphSizeAccounting

    /// Incoming evidence for `target`, in unspecified order.
    func reverseEdges(target: UUID) -> [WorkspaceCodemapGraphEdgeEvidence] {
        guard let bySource = reverseEdgesByTarget[target] else { return [] }
        return Array(bySource.values)
    }
}

enum WorkspaceCodemapGraphApplyRejection: Error, Hashable {
    case rootEpochMismatch
    case rootAuthorityMismatch
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
    /// Ordering comparisons and visited items of the last candidate build. Diff builds stay
    /// proportional to the diff and the postings/edges it reaches, not to the resident graph.
    var lastCandidateComparisonCount: UInt64 = 0
    var lastCandidateVisitCount: UInt64 = 0
    var maximumDiffCandidateVisitCount: UInt64 = 0
    /// Storage entries copied or shifted per candidate. Persistent storage keeps this bounded by
    /// the diff (times the trie depth), not by the resident graph.
    var lastCandidateCopiedEntryCount: UInt64 = 0
    var maximumDiffCandidateCopiedEntryCount: UInt64 = 0
    var totalCandidateCopiedEntryCount: UInt64 = 0
    var totalCandidateComparisonCount: UInt64 = 0
    var totalCandidateVisitCount: UInt64 = 0
    var totalApplyDurationMilliseconds: UInt64 = 0
    var observedToAppliedGenerationLag: UInt64 = 0
}
