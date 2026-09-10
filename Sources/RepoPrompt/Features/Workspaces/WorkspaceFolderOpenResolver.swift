enum WorkspaceRecentOrdering {
    nonisolated static func sorted(_ workspaces: [WorkspaceModel]) -> [WorkspaceModel] {
        workspaces.sorted {
            rank(for: $0) < rank(for: $1)
        }
    }

    private nonisolated static func rank(for workspace: WorkspaceModel) -> WorkspaceExactRootCandidateRank {
        WorkspaceExactRootCandidateRank(
            dateModified: workspace.dateModified,
            name: workspace.name,
            workspaceID: workspace.id
        )
    }
}

enum WorkspaceFolderOpenResolver {
    nonisolated static func containsExactRoot(
        _ folderPath: String,
        in workspace: WorkspaceModel
    ) -> Bool {
        containsExactRoot(WorkspaceRootSetKey(paths: [folderPath]), in: workspace)
    }

    nonisolated static func containsExactRoot(
        _ expectedRoot: WorkspaceRootSetKey,
        in workspace: WorkspaceModel
    ) -> Bool {
        WorkspaceExactRootPath.contains(expectedRoot, in: workspace.repoPaths)
    }

    nonisolated static func eligibleMatches(
        forFolderPath path: String,
        in workspaces: [WorkspaceModel],
        admittingEphemeral: Bool = false
    ) -> [WorkspaceModel] {
        let selectedRoot = WorkspaceRootSetKey(paths: [path])
        guard !selectedRoot.isEmpty else { return [] }

        let matches = workspaces.filter { workspace in
            guard !workspace.isSystemWorkspace,
                  !workspace.isHiddenInMenus,
                  workspace.consolidatedIntoWorkspaceID == nil,
                  !workspace.isEphemeral || admittingEphemeral
            else {
                return false
            }

            return containsExactRoot(selectedRoot, in: workspace)
        }
        return WorkspaceRecentOrdering.sorted(matches)
    }

    nonisolated static func bestEligibleMatch(
        forFolderPath path: String,
        in workspaces: [WorkspaceModel],
        admittingEphemeral: Bool = false
    ) -> WorkspaceModel? {
        eligibleMatches(
            forFolderPath: path,
            in: workspaces,
            admittingEphemeral: admittingEphemeral
        ).first
    }
}
