import Foundation

enum WorkspaceCodemapRootStatusState: Hashable {
    case idle
    case preparing
    case generating
    case waiting
    case ready
    case paused
    case unavailable
}

struct WorkspaceCodemapRootStatusSnapshot: Hashable {
    let rootEpoch: WorkspaceCodemapRootEpoch
    let state: WorkspaceCodemapRootStatusState
    /// Durable candidate coverage accepted by the projection catalog.
    let processedCandidateCount: UInt64
    /// Ephemeral candidates resolved locally in the active batch, expressed through the root.
    let locallyResolvedCandidateCountThroughRoot: UInt64?
    let totalCandidateCount: UInt64?

    init(
        rootEpoch: WorkspaceCodemapRootEpoch,
        state: WorkspaceCodemapRootStatusState,
        processedCandidateCount: UInt64,
        locallyResolvedCandidateCountThroughRoot: UInt64? = nil,
        totalCandidateCount: UInt64?
    ) {
        self.rootEpoch = rootEpoch
        self.state = state
        self.processedCandidateCount = processedCandidateCount
        self.locallyResolvedCandidateCountThroughRoot = locallyResolvedCandidateCountThroughRoot
        self.totalCandidateCount = totalCandidateCount
    }

    var displayProcessedCandidateCount: UInt64 {
        let displayed = max(
            processedCandidateCount,
            locallyResolvedCandidateCountThroughRoot ?? 0
        )
        guard let totalCandidateCount else { return displayed }
        return min(displayed, totalCandidateCount)
    }
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
