import Foundation

struct MCPMutationRetryableFailure: Error, Equatable {
    let errorCode: String
    let errorMessage: String
    let retryable: Bool
    let retryAfterMilliseconds: Int
    let suggestion: String

    static let retryDelayMilliseconds = 1000

    static func worktreeScopeUnavailable(missingPhysicalRootPaths: [String]) -> MCPMutationRetryableFailure {
        let message: String
        if missingPhysicalRootPaths.isEmpty {
            message = "The Agent session worktree scope is unavailable. The mutation stopped before path translation rather than falling back to the canonical checkout."
        } else {
            let count = missingPhysicalRootPaths.count
            let noun = count == 1 ? "worktree root is" : "worktree roots are"
            message = "The bound physical \(noun) unavailable. The mutation stopped before path translation rather than falling back to the canonical checkout."
        }
        return MCPMutationRetryableFailure(
            errorCode: "worktree_scope_unavailable",
            errorMessage: message,
            retryable: true,
            retryAfterMilliseconds: retryDelayMilliseconds,
            suggestion: "Retry after the suggested delay. If the worktree remains unavailable, restore it or rebind the Agent session to an available worktree."
        )
    }

    static func workspaceFreshnessUnavailable() -> MCPMutationRetryableFailure {
        MCPMutationRetryableFailure(
            errorCode: "workspace_freshness_timeout",
            errorMessage: "Workspace file ingress did not become fresh before mutation. No filesystem mutation was started.",
            retryable: true,
            retryAfterMilliseconds: retryDelayMilliseconds,
            suggestion: "Retry after the suggested delay. This failure occurred before mutation, so replay is safe."
        )
    }

    static func worktreeScopeHydrating() -> MCPMutationRetryableFailure {
        MCPMutationRetryableFailure(
            errorCode: "worktree_scope_hydrating",
            errorMessage: "The inactive Agent tab's worktree scope is still being restored. No filesystem mutation was started.",
            retryable: true,
            retryAfterMilliseconds: retryDelayMilliseconds,
            suggestion: "Retry after the suggested delay. This failure occurred before mutation, so replay is safe."
        )
    }

    static func unresolvedRouteFailure(
        for snapshot: MCPServerViewModel.TabContextSnapshot
    ) -> MCPMutationRetryableFailure? {
        guard snapshot.activeAgentSessionID != nil else { return nil }
        guard case .unhydrated = snapshot.worktreeBindingState else { return nil }
        return .worktreeScopeHydrating()
    }

    @MainActor
    static func mutationScopeFailure(
        for lookupContext: WorkspaceLookupContext,
        store: WorkspaceFileContextStore
    ) async -> MCPMutationRetryableFailure? {
        if lookupContext == AgentWorkspaceLookupContextResolver.failClosedLookupContext {
            return .worktreeScopeUnavailable(missingPhysicalRootPaths: [])
        }
        switch await store.rootScopeAvailability(lookupContext.rootScope) {
        case .available:
            return nil
        case let .sessionWorktreeUnavailable(missingPhysicalRootPaths):
            return .worktreeScopeUnavailable(missingPhysicalRootPaths: missingPhysicalRootPaths)
        }
    }
}

extension ToolResultDTOs.FileActionReply {
    static func retryableFailure(
        action: String,
        path: String,
        newPath: String?,
        failure: MCPMutationRetryableFailure
    ) -> ToolResultDTOs.FileActionReply {
        ToolResultDTOs.FileActionReply(
            status: "failed",
            action: action,
            path: path,
            newPath: newPath,
            warning: nil,
            errorMessage: failure.errorMessage,
            errorCode: failure.errorCode,
            retryable: failure.retryable,
            retryAfterMilliseconds: failure.retryAfterMilliseconds,
            suggestion: failure.suggestion
        )
    }
}
