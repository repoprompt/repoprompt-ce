import Foundation

package enum WorkspaceSearchReadinessPhase: String, Equatable {
    case idle
    case activating
    case loadingCatalog
    case buildingIndexes
    case ready
    case degraded
}

package struct WorkspaceSearchReadinessSnapshot: Equatable {
    package let workspaceID: UUID?
    package let phase: WorkspaceSearchReadinessPhase
    package let generation: UInt64
    package let failureCount: Int

    package init(
        workspaceID: UUID?,
        phase: WorkspaceSearchReadinessPhase,
        generation: UInt64,
        failureCount: Int = 0
    ) {
        self.workspaceID = workspaceID
        self.phase = phase
        self.generation = generation
        self.failureCount = max(0, failureCount)
    }
}

package protocol WorkspaceSearchReadinessSource: Sendable {
    func readinessSnapshot() async -> WorkspaceSearchReadinessSnapshot
}
