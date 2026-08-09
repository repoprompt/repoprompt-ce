import RepoPromptDomainRuntime

/// Compatibility aliases while the app adapts presentation/session UI to the domain-owned
/// persisted worktree-binding models.
typealias AgentSessionWorktreeBinding = RepoPromptDomainRuntime.AgentSessionWorktreeBinding
typealias AgentSessionWorktreeBindingSummary = RepoPromptDomainRuntime.AgentSessionWorktreeBindingSummary
typealias AgentWorktreeRuntimeWorkspaceError = RepoPromptDomainRuntime.AgentWorktreeRuntimeWorkspaceError

extension Sequence<AgentSessionWorktreeBinding> {
    var worktreeBindingSummaries: [AgentSessionWorktreeBindingSummary] {
        map(\.summary)
    }
}
