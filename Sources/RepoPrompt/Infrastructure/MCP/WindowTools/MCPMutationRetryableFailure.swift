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
