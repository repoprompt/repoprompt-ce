import Foundation
import RepoPromptDomainRuntime
import RepoPromptVCS

/// Compatibility aliases while the app adapts presentation/session UI to the domain-owned
/// persisted worktree-binding models.
typealias AgentSessionWorktreeBinding = RepoPromptDomainRuntime.AgentSessionWorktreeBinding
typealias AgentSessionWorktreeBindingSummary = RepoPromptDomainRuntime.AgentSessionWorktreeBindingSummary
typealias AgentWorktreeRuntimeWorkspaceError = RepoPromptDomainRuntime.AgentWorktreeRuntimeWorkspaceError

extension AgentSessionWorktreeBinding {
    init(
        id: String,
        worktree: GitWorktreeDescriptor,
        logicalRootPath: String,
        logicalRootName: String?,
        visualLabel: String? = nil,
        visualColorHex: String? = nil,
        boundAt: Date = Date(),
        source: String
    ) {
        self.init(
            id: id, repositoryID: worktree.repository.repositoryID, repoKey: worktree.repository.repoKey,
            logicalRootPath: logicalRootPath, logicalRootName: logicalRootName,
            worktreeID: worktree.worktreeID, worktreeRootPath: worktree.path,
            commonGitDir: worktree.repository.commonGitDir, isMainWorktree: worktree.isMain,
            worktreeName: worktree.name, branch: worktree.branch, head: worktree.head,
            visualLabel: visualLabel, visualColorHex: visualColorHex, boundAt: boundAt, source: source
        )
    }
}

extension Sequence<AgentSessionWorktreeBinding> {
    var worktreeBindingSummaries: [AgentSessionWorktreeBindingSummary] {
        map(\.summary)
    }
}
