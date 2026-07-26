import Foundation

enum WorkspaceCodemapRootAvailability: String, Hashable {
    case notInitialized
    case indexing
    case ready
    case updating
    case reconciling
    case unavailable
    case revoked
}

enum WorkspaceCodemapRootStatusUnavailableReason: String, Hashable {
    case notGitRepository
    case setupFailed
    case graphUnavailable
}

struct WorkspaceCodemapGraphCommitCadence: Hashable {
    let successfulCommitCount: UInt64
    let resyncCommitCount: UInt64
    let lastCommittedUptimeNanoseconds: UInt64?
    let lastCommitIntervalMilliseconds: UInt64?
}

struct WorkspaceCodemapGraphRootDiagnostics: Hashable {
    let rejectedApplyCount: UInt64
    let fencedFileCount: Int
    let activeApply: Bool
    let safetyCounter: UInt64
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

struct WorkspaceCodemapRootStatusSnapshot: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let availability: WorkspaceCodemapRootAvailability
    let isGenerationSuspended: Bool
    let coverage: WorkspaceCodemapGraphCatalogCoverage?
    let graphRevision: UInt64?
    let appliedGeneration: WorkspaceCodemapSelectionGraphContributionGeneration
    let observedGeneration: WorkspaceCodemapSelectionGraphContributionGeneration
    let updatesPending: Bool
    let reconciliationAttempt: Int?
    let reconciliationDeadlineUptimeNanoseconds: UInt64?
    let commitCadence: WorkspaceCodemapGraphCommitCadence
    let diagnostics: WorkspaceCodemapGraphRootDiagnostics
    let unavailableReason: WorkspaceCodemapRootStatusUnavailableReason?
}

struct WorkspaceCodemapRootStatusUpdate: Hashable {
    let revision: UInt64
    let roots: [WorkspaceCodemapRootStatusSnapshot]
}

enum WorkspaceCodemapRootSuspensionUpdateResult: Hashable {
    case changed
    case unchanged
    case rootUnavailable
}
