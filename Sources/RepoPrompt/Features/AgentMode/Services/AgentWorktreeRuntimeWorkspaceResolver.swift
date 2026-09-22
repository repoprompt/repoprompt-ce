import Foundation

enum AgentWorktreeRuntimeWorkspaceResolver {
    struct Dependencies {
        let directoryExists: (String) -> Bool
        let resolveIdentity: (String) -> GitWorktreeIdentitySnapshot?

        static let live = Dependencies(
            directoryExists: { path in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                    && isDirectory.boolValue
            },
            resolveIdentity: { path in
                GitWorktreeIdentityResolver.resolve(atWorkTreeRoot: URL(fileURLWithPath: path))
            }
        )
    }

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
        fallbackWorkspacePath: String?,
        dependencies: Dependencies = .live
    ) throws -> String? {
        let primaryWorkspacePath = standardizedWorkspacePath(fallbackWorkspacePath)
        let binding = primaryExecutionBinding(
            in: bindings,
            fallbackWorkspacePath: fallbackWorkspacePath
        )

        guard let binding else {
            return primaryWorkspacePath
        }
        return try validatedWorktreeRootPath(for: binding, dependencies: dependencies)
    }

    /// Codex-specific projection of the same primary-binding selection used by
    /// `effectiveWorkspacePath`: the app-server process launches from the binding's logical root
    /// while thread/turn execution targets the bound worktree. The logical root is validated
    /// eagerly so a launch-directory failure surfaces before provider startup instead of as an
    /// opaque process-spawn error.
    static func codexRuntimeWorkspacePaths(
        bindings: [AgentSessionWorktreeBinding],
        fallbackWorkspacePath: String?,
        dependencies: Dependencies = .live
    ) throws -> CodexRuntimeWorkspacePaths {
        let primaryWorkspacePath = standardizedWorkspacePath(fallbackWorkspacePath)
        let binding = primaryExecutionBinding(
            in: bindings,
            fallbackWorkspacePath: fallbackWorkspacePath
        )

        guard let binding else {
            return .uniform(primaryWorkspacePath)
        }
        let executionDirectory = try validatedWorktreeRootPath(for: binding, dependencies: dependencies)
        guard let processLaunchDirectory = standardizedWorkspacePath(binding.logicalRootPath) else {
            throw CodexRuntimeWorkspacePathsError.emptyLogicalRoot
        }
        guard dependencies.directoryExists(processLaunchDirectory) else {
            throw CodexRuntimeWorkspacePathsError.launchDirectoryUnavailable(path: processLaunchDirectory)
        }
        return .worktreeBound(
            logicalRootPath: processLaunchDirectory,
            validatedWorktreeRootPath: executionDirectory
        )
    }

    static func validateBindingsAvailable(
        _ bindings: [AgentSessionWorktreeBinding],
        dependencies: Dependencies = .live
    ) throws {
        for binding in bindings {
            _ = try validatedWorktreeRootPath(for: binding, dependencies: dependencies)
        }
    }

    private static func validatedWorktreeRootPath(
        for binding: AgentSessionWorktreeBinding,
        dependencies: Dependencies
    ) throws -> String {
        guard let worktreePath = standardizedWorkspacePath(binding.worktreeRootPath),
              dependencies.directoryExists(worktreePath),
              let identity = dependencies.resolveIdentity(worktreePath),
              matchesPersistedBinding(binding, identity: identity, worktreePath: worktreePath)
        else {
            throw AgentWorktreeRuntimeWorkspaceError(binding: binding)
        }
        return worktreePath
    }

    private static func matchesPersistedBinding(
        _ binding: AgentSessionWorktreeBinding,
        identity: GitWorktreeIdentitySnapshot,
        worktreePath: String
    ) -> Bool {
        guard identity.repository.repositoryID == binding.repositoryID,
              identity.worktreeID == binding.worktreeID,
              GitRepoRootAuthorization.isPathWithinAuthorizedRoots(
                  worktreePath,
                  roots: [identity.worktreeRootPath]
              )
        else {
            return false
        }

        if let commonGitDir = binding.commonGitDir,
           GitRepoRootAuthorization.canonicalPath(commonGitDir)
           != GitRepoRootAuthorization.canonicalPath(identity.repository.commonGitDir)
        {
            return false
        }
        if let isMainWorktree = binding.isMainWorktree,
           isMainWorktree != identity.isMain
        {
            return false
        }
        return true
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
