import Foundation

enum AgentWorktreeRuntimeWorkspaceResolver {
    static func primaryExecutionBinding(
        in bindings: [AgentSessionWorktreeBinding],
        fallbackWorkspacePath: String?
    ) -> AgentSessionWorktreeBinding? {
        let primaryWorkspacePath = standardizedWorkspacePath(fallbackWorkspacePath)
        return primaryWorkspacePath.flatMap { primaryPath in
            bindings.first { binding in
                standardizedWorkspacePath(binding.logicalRootPath) == primaryPath
            }
        } ?? (primaryWorkspacePath == nil && bindings.count == 1 ? bindings[0] : nil)
    }

    static func effectiveWorkspacePath(
        bindings: [AgentSessionWorktreeBinding],
        fallbackWorkspacePath: String?
    ) throws -> String? {
        let primaryWorkspacePath = standardizedWorkspacePath(fallbackWorkspacePath)
        let binding = primaryExecutionBinding(
            in: bindings,
            fallbackWorkspacePath: fallbackWorkspacePath
        )

        guard let binding else {
            return primaryWorkspacePath
        }
        return try validatedWorktreeRootPath(for: binding)
    }

    /// Codex-specific projection of the same primary-binding selection used by
    /// `effectiveWorkspacePath`: the app-server process launches from the binding's logical root
    /// while thread/turn execution targets the bound worktree. The logical root is validated
    /// eagerly so a launch-directory failure surfaces before provider startup instead of as an
    /// opaque process-spawn error.
    static func codexRuntimeWorkspacePaths(
        bindings: [AgentSessionWorktreeBinding],
        fallbackWorkspacePath: String?
    ) throws -> CodexRuntimeWorkspacePaths {
        let primaryWorkspacePath = standardizedWorkspacePath(fallbackWorkspacePath)
        let binding = primaryExecutionBinding(
            in: bindings,
            fallbackWorkspacePath: fallbackWorkspacePath
        )

        guard let binding else {
            return .uniform(primaryWorkspacePath)
        }
        let executionDirectory = try validatedWorktreeRootPath(for: binding)
        guard let processLaunchDirectory = standardizedWorkspacePath(binding.logicalRootPath) else {
            throw CodexRuntimeWorkspacePathsError.emptyLogicalRoot
        }
        guard directoryExists(atPath: processLaunchDirectory) else {
            throw CodexRuntimeWorkspacePathsError.launchDirectoryUnavailable(path: processLaunchDirectory)
        }
        return .worktreeBound(
            logicalRootPath: processLaunchDirectory,
            validatedWorktreeRootPath: executionDirectory
        )
    }

    static func validateBindingsAvailable(_ bindings: [AgentSessionWorktreeBinding]) throws {
        for binding in bindings {
            _ = try validatedWorktreeRootPath(for: binding)
        }
    }

    private static func validatedWorktreeRootPath(
        for binding: AgentSessionWorktreeBinding
    ) throws -> String {
        guard let worktreePath = standardizedWorkspacePath(binding.worktreeRootPath),
              directoryExists(atPath: worktreePath)
        else {
            throw AgentWorktreeRuntimeWorkspaceError(binding: binding)
        }
        return worktreePath
    }

    private static func directoryExists(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    static func standardizedWorkspacePath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath).standardizedFileURL.path
    }
}
