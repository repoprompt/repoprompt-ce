import RepoPromptWorkspaceContext

enum WorkspaceAppliedIndexFolderOrdering {
    /// Parents precede descendants; peers retain the existing relative-path ordering.
    /// Eager decoration computes path depth once per record, never inside the comparator.
    static func sorted(
        _ folders: [WorkspaceFolderRecord],
        pathDepth: (String) -> Int = { $0.split(separator: "/").count }
    ) -> [WorkspaceFolderRecord] {
        let decorated = folders.map { folder in
            (folder: folder, depth: pathDepth(folder.standardizedRelativePath))
        }
        return decorated.sorted { lhs, rhs in
            if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
            return lhs.folder.standardizedRelativePath < rhs.folder.standardizedRelativePath
        }.map(\.folder)
    }
}
