import Combine
import Foundation
import RepoPromptCore

@MainActor
final class WorkspaceSessionObservationBridge: ObservableObject {
    @Published private(set) var snapshot: WorkspaceSessionSnapshot
    @Published private(set) var workspaces: [WorkspaceModel]
    @Published private(set) var activeWorkspaceID: UUID?

    private var observationToken: WorkspaceSessionObservationToken?

    init(controller: WorkspaceSessionController) {
        let initial = controller.snapshot
        snapshot = initial
        workspaces = initial.workspaces
        activeWorkspaceID = initial.activeWorkspaceID
        observationToken = controller.observe { [weak self] snapshot in
            guard let self, snapshot.generation >= self.snapshot.generation else { return }
            self.snapshot = snapshot
            workspaces = snapshot.workspaces
            activeWorkspaceID = snapshot.activeWorkspaceID
        }
    }
}
