import Foundation

/// Persisted binding from a workspace logical root to a Git worktree for one agent session.
///
/// This value is the profile-scoped durable identity consumed by runtime path projection,
/// working-directory resolution, and standalone worktree operations.
package struct AgentSessionWorktreeBinding: Codable, Equatable, Identifiable, Sendable {
    package let id: String
    package let repositoryID: String
    package let repoKey: String
    package let logicalRootPath: String
    package let logicalRootName: String?
    package let worktreeID: String
    package let worktreeRootPath: String
    /// Common Git directory captured when the binding was created.
    /// Legacy bindings may omit it; fresh repository/worktree IDs are still required at use time.
    package let commonGitDir: String?
    package let isMainWorktree: Bool?
    package let worktreeName: String?
    package let branch: String?
    package let head: String?
    package let visualLabel: String?
    package let visualColorHex: String?
    package let boundAt: Date
    package let source: String

    package init(
        id: String,
        repositoryID: String,
        repoKey: String,
        logicalRootPath: String,
        logicalRootName: String? = nil,
        worktreeID: String,
        worktreeRootPath: String,
        commonGitDir: String? = nil,
        isMainWorktree: Bool? = nil,
        worktreeName: String? = nil,
        branch: String? = nil,
        head: String? = nil,
        visualLabel: String? = nil,
        visualColorHex: String? = nil,
        boundAt: Date = Date(),
        source: String
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.repoKey = repoKey
        self.logicalRootPath = logicalRootPath
        self.logicalRootName = logicalRootName
        self.worktreeID = worktreeID
        self.worktreeRootPath = worktreeRootPath
        self.commonGitDir = commonGitDir
        self.isMainWorktree = isMainWorktree
        self.worktreeName = worktreeName
        self.branch = branch
        self.head = head
        self.visualLabel = visualLabel
        self.visualColorHex = visualColorHex
        self.boundAt = boundAt
        self.source = source
    }

    package var summary: AgentSessionWorktreeBindingSummary {
        AgentSessionWorktreeBindingSummary(binding: self)
    }

    package func updatingCheckout(branch: String?, head: String?) -> AgentSessionWorktreeBinding {
        AgentSessionWorktreeBinding(
            id: id,
            repositoryID: repositoryID,
            repoKey: repoKey,
            logicalRootPath: logicalRootPath,
            logicalRootName: logicalRootName,
            worktreeID: worktreeID,
            worktreeRootPath: worktreeRootPath,
            commonGitDir: commonGitDir,
            isMainWorktree: isMainWorktree,
            worktreeName: worktreeName,
            branch: branch,
            head: head,
            visualLabel: visualLabel,
            visualColorHex: visualColorHex,
            boundAt: boundAt,
            source: source
        )
    }
}

/// Lightweight worktree-binding data copied into session-list/index records so callers can show
/// identity without loading full transcripts.
package struct AgentSessionWorktreeBindingSummary: Codable, Equatable, Identifiable, Sendable {
    package let id: String
    package let repositoryID: String
    package let repoKey: String
    package let logicalRootPath: String
    package let logicalRootName: String?
    package let worktreeID: String
    package let worktreeRootPath: String
    package let commonGitDir: String?
    package let isMainWorktree: Bool?
    package let worktreeName: String?
    package let branch: String?
    package let visualLabel: String?
    package let visualColorHex: String?
    package let boundAt: Date

    package init(
        id: String,
        repositoryID: String,
        repoKey: String,
        logicalRootPath: String,
        logicalRootName: String? = nil,
        worktreeID: String,
        worktreeRootPath: String,
        commonGitDir: String? = nil,
        isMainWorktree: Bool? = nil,
        worktreeName: String? = nil,
        branch: String? = nil,
        visualLabel: String? = nil,
        visualColorHex: String? = nil,
        boundAt: Date
    ) {
        self.id = id
        self.repositoryID = repositoryID
        self.repoKey = repoKey
        self.logicalRootPath = logicalRootPath
        self.logicalRootName = logicalRootName
        self.worktreeID = worktreeID
        self.worktreeRootPath = worktreeRootPath
        self.commonGitDir = commonGitDir
        self.isMainWorktree = isMainWorktree
        self.worktreeName = worktreeName
        self.branch = branch
        self.visualLabel = visualLabel
        self.visualColorHex = visualColorHex
        self.boundAt = boundAt
    }

    init(binding: AgentSessionWorktreeBinding) {
        self.init(
            id: binding.id,
            repositoryID: binding.repositoryID,
            repoKey: binding.repoKey,
            logicalRootPath: binding.logicalRootPath,
            logicalRootName: binding.logicalRootName,
            worktreeID: binding.worktreeID,
            worktreeRootPath: binding.worktreeRootPath,
            commonGitDir: binding.commonGitDir,
            isMainWorktree: binding.isMainWorktree,
            worktreeName: binding.worktreeName,
            branch: binding.branch,
            visualLabel: binding.visualLabel,
            visualColorHex: binding.visualColorHex,
            boundAt: binding.boundAt
        )
    }
}

package struct AgentWorktreeRuntimeWorkspaceError: LocalizedError, Equatable, Sendable {
    package let binding: AgentSessionWorktreeBinding

    package init(binding: AgentSessionWorktreeBinding) {
        self.binding = binding
    }

    package var errorDescription: String? {
        let label = binding.visualLabel
            ?? binding.worktreeName
            ?? binding.branch
            ?? binding.worktreeID
        let logicalRoot = binding.logicalRootName ?? binding.logicalRootPath
        return "Agent session is bound to worktree '\(label)' for root '\(logicalRoot)', but the worktree path or Git identity is unavailable or changed: \(binding.worktreeRootPath). Recreate or repair that Git worktree, bind the session to another worktree, or unbind the session before starting the agent."
    }
}

extension Sequence<AgentSessionWorktreeBinding> {
    package var worktreeBindingSummaries: [AgentSessionWorktreeBindingSummary] {
        map(\.summary)
    }
}
