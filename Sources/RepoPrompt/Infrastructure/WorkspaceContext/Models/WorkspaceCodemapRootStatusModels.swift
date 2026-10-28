import Foundation

package enum WorkspaceCodemapRootAvailability: String, Hashable {
    case notInitialized
    case indexing
    case ready
    case updating
    case reconciling
    case unavailable
    case revoked
}

package enum WorkspaceCodemapRootStatusUnavailableReason: String, Hashable {
    /// No usable source authority for this root. A healthy filesystem root never reports this.
    case sourceRootUnavailable
    case setupFailed
    case graphUnavailable
    case retryExhausted
    case workerRecoveryExhausted
    case budgetLimited
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

package struct WorkspaceCodemapRootStatusSnapshot: Hashable {
    package let rootEpoch: WorkspaceCodemapRootEpoch
    package let availability: WorkspaceCodemapRootAvailability
    package let isGenerationSuspended: Bool
    package let coverage: WorkspaceCodemapGraphCatalogCoverage?
    package let graphRevision: UInt64?
    let appliedGeneration: WorkspaceCodemapSelectionGraphContributionGeneration
    let observedGeneration: WorkspaceCodemapSelectionGraphContributionGeneration
    package let updatesPending: Bool
    let reconciliationAttempt: Int?
    let reconciliationDeadlineUptimeNanoseconds: UInt64?
    let commitCadence: WorkspaceCodemapGraphCommitCadence
    let diagnostics: WorkspaceCodemapGraphRootDiagnostics
    package let unavailableReason: WorkspaceCodemapRootStatusUnavailableReason?
    var graphIndexBudget: WorkspaceCodemapGraphIndexBudget?
}

package struct WorkspaceCodemapRootStatusUpdate: Hashable {
    package let revision: UInt64
    package let roots: [WorkspaceCodemapRootStatusSnapshot]
}

package enum WorkspaceCodemapRootSuspensionUpdateResult: Hashable {
    case changed
    case unchanged
    case rootUnavailable
}
