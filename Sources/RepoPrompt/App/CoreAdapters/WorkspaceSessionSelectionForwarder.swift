import Foundation
import RepoPromptCore

/// Temporary Slice 1 bridge. Slice 2 deletes this when Core owns selection coordination.
@MainActor
final class WorkspaceSessionSelectionForwarder: WorkspaceSelectionHost {
    private let controller: WorkspaceSessionController
    private weak var manager: WorkspaceManagerViewModel?

    init(controller: WorkspaceSessionController, manager: WorkspaceManagerViewModel) {
        self.controller = controller
        self.manager = manager
    }

    var activeWorkspace: WorkspaceModel? {
        controller.activeWorkspace
    }

    func composeTab(with id: UUID) -> ComposeTabState? {
        controller.composeTab(with: id)
    }

    func publishActiveComposeTabSnapshot(commitToMemory: Bool, touchModified: Bool) {
        manager?.publishActiveComposeTabSnapshot(commitToMemory: commitToMemory, touchModified: touchModified)
    }

    func updateComposeTabStoredOnly(_ tab: ComposeTabState) {
        guard let workspace = controller.workspaces.first(where: { workspace in
            workspace.composeTabs.contains(where: { $0.id == tab.id })
        }) else { return }
        _ = controller.mutateComposeTab(
            workspaceID: workspace.id,
            tabID: tab.id,
            options: .storedOnly
        ) { $0 = tab }
    }
}
