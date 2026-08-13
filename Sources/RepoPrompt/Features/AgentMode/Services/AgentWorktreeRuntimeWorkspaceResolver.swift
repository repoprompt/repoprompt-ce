import Foundation

enum AgentWorktreeRuntimeWorkspaceResolutionError: LocalizedError, Equatable {
    case activeWorkspaceRootsUnavailable
    case invalidActiveWorkspaceRoot
    case duplicateActiveWorkspaceRoot(path: String)
    case emptyLogicalRoot
    case logicalRootNotInActiveWorkspace(path: String)
    case duplicateLogicalRoot(path: String)
    case ambiguousExecutionBinding

    var errorDescription: String? {
        switch self {
        case .activeWorkspaceRootsUnavailable:
            "The active workspace has no roots, so its Agent worktree binding cannot be authorized. Restore the workspace root or unbind the session."
        case .invalidActiveWorkspaceRoot:
            "The active workspace contains an invalid root path, so its Agent worktree binding cannot be authorized. Correct the workspace roots or unbind the session."
        case let .duplicateActiveWorkspaceRoot(path):
            "The active workspace contains duplicate canonical root '\(path)', so its Agent worktree binding is ambiguous. Remove the duplicate root or unbind the session."
        case .emptyLogicalRoot:
            "The Agent worktree binding has no logical root. Rebind the session to a current workspace root."
        case let .logicalRootNotInActiveWorkspace(path):
            "The Agent worktree binding targets logical root '\(path)', which is not part of the active workspace. Rebind the session to a current workspace root."
        case let .duplicateLogicalRoot(path):
            "The Agent session has duplicate worktree bindings for logical root '\(path)'. Remove the duplicate binding before starting the provider."
        case .ambiguousExecutionBinding:
            "The Agent session has multiple secondary worktree bindings but no canonical-primary binding. Bind the canonical primary root or leave only one authorized binding."
        }
    }
}

enum AgentWorktreeRuntimeWorkspaceResolver {
    static func primaryExecutionBinding(
        in bindings: [AgentSessionWorktreeBinding],
        workspaceRootPaths: [String]
    ) throws -> AgentSessionWorktreeBinding? {
        guard !bindings.isEmpty else {
            return nil
        }

        let authorizedRoots = try canonicalWorkspaceRoots(workspaceRootPaths)
        let canonicalPrimaryPath = authorizedRoots[0]
        let authorizedRootSet = Set(authorizedRoots)
        var bindingsByCanonicalRoot: [String: AgentSessionWorktreeBinding] = [:]

        for binding in bindings {
            guard let logicalRootPath = standardizedWorkspacePath(binding.logicalRootPath) else {
                throw AgentWorktreeRuntimeWorkspaceResolutionError.emptyLogicalRoot
            }
            let canonicalLogicalRoot = GitRepoRootAuthorization.canonicalPath(logicalRootPath)
            guard authorizedRootSet.contains(canonicalLogicalRoot) else {
                throw AgentWorktreeRuntimeWorkspaceResolutionError.logicalRootNotInActiveWorkspace(path: logicalRootPath)
            }
            guard bindingsByCanonicalRoot.updateValue(binding, forKey: canonicalLogicalRoot) == nil else {
                throw AgentWorktreeRuntimeWorkspaceResolutionError.duplicateLogicalRoot(path: logicalRootPath)
            }
        }

        if bindings.count == 1 {
            return bindings[0]
        }
        guard let primaryBinding = bindingsByCanonicalRoot[canonicalPrimaryPath] else {
            throw AgentWorktreeRuntimeWorkspaceResolutionError.ambiguousExecutionBinding
        }
        return primaryBinding
    }

    static func effectiveWorkspacePath(
        bindings: [AgentSessionWorktreeBinding],
        workspaceRootPaths: [String]
    ) throws -> String? {
        let primaryWorkspacePath = standardizedWorkspacePath(workspaceRootPaths.first)
        let binding = try primaryExecutionBinding(
            in: bindings,
            workspaceRootPaths: workspaceRootPaths
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
        workspaceRootPaths: [String]
    ) throws -> CodexRuntimeWorkspacePaths {
        let primaryWorkspacePath = standardizedWorkspacePath(workspaceRootPaths.first)
        let binding = try primaryExecutionBinding(
            in: bindings,
            workspaceRootPaths: workspaceRootPaths
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

    private static func canonicalWorkspaceRoots(_ workspaceRootPaths: [String]) throws -> [String] {
        guard !workspaceRootPaths.isEmpty else {
            throw AgentWorktreeRuntimeWorkspaceResolutionError.activeWorkspaceRootsUnavailable
        }
        var seen: Set<String> = []
        return try workspaceRootPaths.map { rootPath in
            guard let standardizedRoot = standardizedWorkspacePath(rootPath) else {
                throw AgentWorktreeRuntimeWorkspaceResolutionError.invalidActiveWorkspaceRoot
            }
            let canonicalRoot = GitRepoRootAuthorization.canonicalPath(standardizedRoot)
            guard seen.insert(canonicalRoot).inserted else {
                throw AgentWorktreeRuntimeWorkspaceResolutionError.duplicateActiveWorkspaceRoot(path: standardizedRoot)
            }
            return canonicalRoot
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
