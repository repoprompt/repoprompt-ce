import Foundation

final class WorkspaceManagerSearchReadinessSource: WorkspaceSearchReadinessSource, @unchecked Sendable {
    private weak var workspaceManager: WorkspaceManagerViewModel?

    @MainActor
    init(_ workspaceManager: WorkspaceManagerViewModel) {
        self.workspaceManager = workspaceManager
    }

    func readinessSnapshot() async -> WorkspaceSearchReadinessSnapshot {
        await MainActor.run {
            guard let workspaceManager else {
                return WorkspaceSearchReadinessSnapshot(
                    workspaceID: nil,
                    phase: .idle,
                    generation: 0
                )
            }

            switch workspaceManager.workspaceSearchReadinessState {
            case .idle:
                return WorkspaceSearchReadinessSnapshot(
                    workspaceID: nil,
                    phase: .idle,
                    generation: 0
                )
            case let .activating(workspaceID, generation):
                return WorkspaceSearchReadinessSnapshot(
                    workspaceID: workspaceID,
                    phase: .activating,
                    generation: generation
                )
            case let .loadingCatalog(workspaceID, generation, _, _, failures):
                return WorkspaceSearchReadinessSnapshot(
                    workspaceID: workspaceID,
                    phase: .loadingCatalog,
                    generation: generation,
                    failureCount: failures.count
                )
            case let .buildingIndexes(workspaceID, generation, _, failures):
                return WorkspaceSearchReadinessSnapshot(
                    workspaceID: workspaceID,
                    phase: .buildingIndexes,
                    generation: generation,
                    failureCount: failures.count
                )
            case let .ready(workspaceID, generation, _, _, _):
                return WorkspaceSearchReadinessSnapshot(
                    workspaceID: workspaceID,
                    phase: .ready,
                    generation: generation
                )
            case let .degraded(workspaceID, generation, _, _, failures, _):
                return WorkspaceSearchReadinessSnapshot(
                    workspaceID: workspaceID,
                    phase: .degraded,
                    generation: generation,
                    failureCount: failures.count
                )
            }
        }
    }
}
