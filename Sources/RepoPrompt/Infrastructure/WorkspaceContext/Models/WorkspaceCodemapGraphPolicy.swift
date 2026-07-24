import Foundation

struct WorkspaceCodemapGraphQueryBudget: Hashable {
    let maximumTokenCount: Int
    let maximumNodeCount: Int
    let maximumEdgeCount: Int
    let maximumGraphByteCount: UInt64
    let graphEvidenceTokenCount: Int
    let renderTokenCount: Int
}

/// The single internal home for graph indexing, update, safety, traversal, and
/// rendering limits. These are implementation policy, not public settings.
struct WorkspaceCodemapGraphPolicy: Hashable {
    static let initial: WorkspaceCodemapGraphPolicy = {
        guard let policy = WorkspaceCodemapGraphPolicy() else {
            preconditionFailure("The built-in workspace codemap graph policy must be valid.")
        }
        return policy
    }()

    // Bounds overlay memory and guarantees one changed-set diff fits one apply cycle.
    let maximumChangedSetFileIDCount: Int
    let maximumCoalescedFileIDCount: Int

    /// Fences are rare destructive safeguards; exceeding this cap requires resync/revocation.
    let maximumFencedFileIDCount: Int

    // Bounded watcher-gap recovery prevents indefinite reconciliation.
    let maximumReconciliationAttemptCount: Int
    let maximumReconciliationWallClockMilliseconds: UInt64

    /// A fixed server deadline keeps traversal cancellation observable and non-user-tunable.
    let requestDeadlineMilliseconds: UInt64

    // Exact-name fanout and resident graph storage remain bounded independently of query output.
    let candidateOverflowThreshold: UInt64
    let graphSizePolicy: WorkspaceCodemapSelectionGraphSizePolicy

    // The public max_tokens value clamps; all other query limits derive here.
    let minimumTokenCount: Int
    let defaultTokenCount: Int
    let maximumTokenCount: Int
    let maximumQueryNodeCount: Int
    let maximumQueryEdgeCount: Int
    let maximumQueryGraphByteCount: UInt64
    let tokenCountPerQueryNode: Int
    let queryEdgeCountPerToken: Int
    let queryGraphByteCountPerToken: UInt64

    // Rendering reserves this fraction for actionable graph evidence.
    let renderedEvidenceBudgetNumerator: Int
    let renderedEvidenceBudgetDenominator: Int

    init?(
        maximumChangedSetFileIDCount: Int = 4096,
        maximumCoalescedFileIDCount: Int = 10000,
        maximumFencedFileIDCount: Int = 100_000,
        maximumReconciliationAttemptCount: Int = 3,
        maximumReconciliationWallClockMilliseconds: UInt64 = 60000,
        requestDeadlineMilliseconds: UInt64 = 10000,
        candidateOverflowThreshold: UInt64 = 4096,
        graphSizePolicy: WorkspaceCodemapSelectionGraphSizePolicy = .initial,
        minimumTokenCount: Int = 1000,
        defaultTokenCount: Int = 6000,
        maximumTokenCount: Int = 25000,
        maximumQueryNodeCount: Int = 200,
        maximumQueryEdgeCount: Int = 10000,
        maximumQueryGraphByteCount: UInt64 = 4 * 1024 * 1024,
        tokenCountPerQueryNode: Int = 50,
        queryEdgeCountPerToken: Int = 2,
        queryGraphByteCountPerToken: UInt64 = 16,
        renderedEvidenceBudgetNumerator: Int = 1,
        renderedEvidenceBudgetDenominator: Int = 4
    ) {
        guard maximumChangedSetFileIDCount > 0,
              maximumChangedSetFileIDCount <= maximumCoalescedFileIDCount,
              maximumFencedFileIDCount > 0,
              maximumReconciliationAttemptCount > 0,
              maximumReconciliationWallClockMilliseconds > 0,
              requestDeadlineMilliseconds > 0,
              candidateOverflowThreshold > 0,
              candidateOverflowThreshold == graphSizePolicy.maxDefinitionCandidates,
              minimumTokenCount >= 1000,
              minimumTokenCount <= defaultTokenCount,
              defaultTokenCount <= maximumTokenCount,
              maximumTokenCount <= 25000,
              (1 ... 200).contains(maximumQueryNodeCount),
              (1 ... 10000).contains(maximumQueryEdgeCount),
              maximumQueryGraphByteCount > 0,
              tokenCountPerQueryNode > 0,
              queryEdgeCountPerToken > 0,
              queryGraphByteCountPerToken > 0,
              renderedEvidenceBudgetNumerator > 0,
              renderedEvidenceBudgetNumerator < renderedEvidenceBudgetDenominator
        else { return nil }
        self.maximumChangedSetFileIDCount = maximumChangedSetFileIDCount
        self.maximumCoalescedFileIDCount = maximumCoalescedFileIDCount
        self.maximumFencedFileIDCount = maximumFencedFileIDCount
        self.maximumReconciliationAttemptCount = maximumReconciliationAttemptCount
        self.maximumReconciliationWallClockMilliseconds = maximumReconciliationWallClockMilliseconds
        self.requestDeadlineMilliseconds = requestDeadlineMilliseconds
        self.candidateOverflowThreshold = candidateOverflowThreshold
        self.graphSizePolicy = graphSizePolicy
        self.minimumTokenCount = minimumTokenCount
        self.defaultTokenCount = defaultTokenCount
        self.maximumTokenCount = maximumTokenCount
        self.maximumQueryNodeCount = maximumQueryNodeCount
        self.maximumQueryEdgeCount = maximumQueryEdgeCount
        self.maximumQueryGraphByteCount = maximumQueryGraphByteCount
        self.tokenCountPerQueryNode = tokenCountPerQueryNode
        self.queryEdgeCountPerToken = queryEdgeCountPerToken
        self.queryGraphByteCountPerToken = queryGraphByteCountPerToken
        self.renderedEvidenceBudgetNumerator = renderedEvidenceBudgetNumerator
        self.renderedEvidenceBudgetDenominator = renderedEvidenceBudgetDenominator
    }

    func queryBudget(
        maximumTokenCount requestedTokenCount: Int,
        includesSignatures: Bool
    ) -> WorkspaceCodemapGraphQueryBudget {
        let clampedTokenCount = min(max(requestedTokenCount, minimumTokenCount), maximumTokenCount)
        let nodeCount = min(
            maximumQueryNodeCount,
            max(1, clampedTokenCount / tokenCountPerQueryNode)
        )
        let edgeCount = min(
            maximumQueryEdgeCount,
            clampedTokenCount * queryEdgeCountPerToken
        )
        let graphByteCount = min(
            maximumQueryGraphByteCount,
            UInt64(clampedTokenCount) * queryGraphByteCountPerToken
        )
        let evidenceTokenCount = includesSignatures
            ? clampedTokenCount * renderedEvidenceBudgetNumerator / renderedEvidenceBudgetDenominator
            : clampedTokenCount
        return WorkspaceCodemapGraphQueryBudget(
            maximumTokenCount: clampedTokenCount,
            maximumNodeCount: nodeCount,
            maximumEdgeCount: edgeCount,
            maximumGraphByteCount: graphByteCount,
            graphEvidenceTokenCount: evidenceTokenCount,
            renderTokenCount: includesSignatures ? clampedTokenCount - evidenceTokenCount : 0
        )
    }
}
