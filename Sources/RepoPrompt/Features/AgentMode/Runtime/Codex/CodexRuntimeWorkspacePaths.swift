import Foundation

/// Launch/execution directory pair for one Codex controller.
///
/// A worktree-bound session launches the Codex app-server from the workspace's logical root so
/// process startup behaves exactly like an unbound session, while thread and turn execution still
/// target the bound worktree. Unbound sessions use the same directory for both roles.
struct CodexRuntimeWorkspacePaths: Equatable {
    /// Directory the Codex app-server process launches from.
    let processLaunchDirectory: String?
    /// Directory Codex thread/turn execution and the primary sandbox writable root target.
    let executionDirectory: String?

    private init(processLaunchDirectory: String?, executionDirectory: String?) {
        self.processLaunchDirectory = processLaunchDirectory
        self.executionDirectory = executionDirectory
    }

    /// Both roles share one directory — the shape of every session without a primary
    /// worktree binding.
    static func uniform(_ path: String?) -> CodexRuntimeWorkspacePaths {
        CodexRuntimeWorkspacePaths(processLaunchDirectory: path, executionDirectory: path)
    }

    /// A validated worktree binding keeps process launch anchored to its logical workspace while
    /// routing thread and turn execution through the worktree.
    static func worktreeBound(
        logicalRootPath: String,
        validatedWorktreeRootPath: String
    ) -> CodexRuntimeWorkspacePaths {
        CodexRuntimeWorkspacePaths(
            processLaunchDirectory: logicalRootPath,
            executionDirectory: validatedWorktreeRootPath
        )
    }
}

/// Validation failures for the Codex launch-directory projection.
///
/// Thrown before provider startup so a broken selected logical root is as actionable as an
/// unavailable worktree (`AgentWorktreeRuntimeWorkspaceError`).
enum CodexRuntimeWorkspacePathsError: LocalizedError, Equatable {
    case emptyLogicalRoot
    case launchDirectoryUnavailable(path: String)

    var errorDescription: String? {
        switch self {
        case .emptyLogicalRoot:
            "Agent session is bound to a worktree whose workspace root path is empty. Rebind the session to a worktree of a loaded workspace root, or unbind the session before starting the agent."
        case let .launchDirectoryUnavailable(path):
            "Agent session is bound to a worktree for workspace root '\(path)', but that root directory is unavailable. Restore the workspace root, bind the session to another worktree, or unbind the session before starting the agent."
        }
    }
}
