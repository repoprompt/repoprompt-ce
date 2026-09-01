enum WorkspaceRecentOrdering {
    nonisolated static func sorted(_ workspaces: [WorkspaceModel]) -> [WorkspaceModel] {
        workspaces.sorted { lhs, rhs in
            if lhs.dateModified != rhs.dateModified {
                return lhs.dateModified > rhs.dateModified
            }
            let lhsFoldedName = lhs.name.lowercased()
            let rhsFoldedName = rhs.name.lowercased()
            if lhsFoldedName != rhsFoldedName {
                return lhsFoldedName < rhsFoldedName
            }
            if lhs.name != rhs.name {
                return lhs.name < rhs.name
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

enum WorkspaceFolderOpenResolver {
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
                  !workspace.isEphemeral || admittingEphemeral
            else {
                return false
            }

            return workspace.repoPaths.contains { rootPath in
                let root = WorkspaceRootSetKey(paths: [rootPath])
                return !root.isEmpty && root == selectedRoot
            }
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
