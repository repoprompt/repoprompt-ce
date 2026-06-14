@testable import RepoPrompt

@MainActor
enum WorkspaceRootLoadTestSupport {
    static func loadRootMatchingCurrentFileSystemSettings(
        in window: WindowState,
        path: String,
        kind: WorkspaceRootKind = .primaryWorkspace
    ) async throws -> WorkspaceRootRecord {
        let settings = GlobalSettingsStore.shared.fileSystemSettingsSnapshot()
        return try await window.workspaceFileContextStore.loadRoot(
            path: path,
            kind: kind,
            respectGitignore: settings.respectGitignore,
            respectRepoIgnore: settings.respectRepoIgnore,
            respectCursorignore: settings.respectCursorignore,
            skipSymlinks: settings.skipSymlinks,
            enableHierarchicalIgnores: settings.enableHierarchicalIgnores
        )
    }
}
