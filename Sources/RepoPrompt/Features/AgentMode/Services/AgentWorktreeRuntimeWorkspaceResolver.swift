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
        let worktreePath = standardizedWorkspacePath(binding.worktreeRootPath)
        guard let worktreePath else {
            throw AgentWorktreeRuntimeWorkspaceError(binding: binding)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: worktreePath, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw AgentWorktreeRuntimeWorkspaceError(binding: binding)
        }
        return worktreePath
    }

    static func validateBindingsAvailable(_ bindings: [AgentSessionWorktreeBinding]) throws {
        for binding in bindings {
            let worktreePath = standardizedWorkspacePath(binding.worktreeRootPath)
            guard let worktreePath else {
                throw AgentWorktreeRuntimeWorkspaceError(binding: binding)
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: worktreePath, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                throw AgentWorktreeRuntimeWorkspaceError(binding: binding)
            }
        }
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
