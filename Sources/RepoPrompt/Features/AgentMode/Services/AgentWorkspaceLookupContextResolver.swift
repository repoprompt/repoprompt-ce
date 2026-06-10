import Foundation

struct AgentWorkspaceLookupContextSource: Equatable {
    let activeAgentSessionID: UUID?
    let worktreeBindings: [AgentSessionWorktreeBinding]

    var identity: AgentWorkspaceLookupContextIdentity {
        AgentWorkspaceLookupContextIdentity(
            activeAgentSessionID: activeAgentSessionID,
            worktreeBindingFingerprint: Self.worktreeBindingFingerprint(worktreeBindings)
        )
    }

    static func worktreeBindingFingerprint(_ bindings: [AgentSessionWorktreeBinding]) -> String {
        bindings
            .map { binding in
                [
                    binding.repositoryID,
                    binding.repoKey,
                    StandardizedPath.absolute((binding.logicalRootPath as NSString).expandingTildeInPath),
                    binding.worktreeID,
                    StandardizedPath.absolute((binding.worktreeRootPath as NSString).expandingTildeInPath),
                    binding.branch ?? "",
                    binding.head ?? ""
                ].joined(separator: "\u{1F}")
            }
            .sorted()
            .joined(separator: "\u{1E}")
    }
}

struct AgentWorkspaceLookupContextIdentity: Hashable {
    let activeAgentSessionID: UUID?
    let worktreeBindingFingerprint: String
}

enum AgentWorkspaceLookupContextResolver {
    static func requiredLookupContext(
        source: AgentWorkspaceLookupContextSource,
        store: WorkspaceFileContextStore
    ) async throws -> WorkspaceLookupContext {
        guard let sessionID = source.activeAgentSessionID,
              !source.worktreeBindings.isEmpty
        else {
            return .visibleWorkspace
        }

        try AgentWorktreeRuntimeWorkspaceResolver.validateBindingsAvailable(source.worktreeBindings)
        guard let projection = await WorkspaceRootBindingProjectionMaterializer(store: store).materialize(
            sessionID: sessionID,
            bindings: source.worktreeBindings
        ),
            !projection.isEmpty
        else {
            throw AgentWorkspaceLookupContextResolutionError.unavailableProjection
        }

        switch await store.rootScopeAvailability(projection.lookupRootScope) {
        case .available:
            return WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
        case .sessionWorktreeUnavailable:
            throw AgentWorkspaceLookupContextResolutionError.unavailableProjection
        }
    }

    static func lookupContext(
        source: AgentWorkspaceLookupContextSource,
        store: WorkspaceFileContextStore
    ) async -> WorkspaceLookupContext {
        guard let sessionID = source.activeAgentSessionID,
              !source.worktreeBindings.isEmpty,
              let projection = await WorkspaceRootBindingProjectionMaterializer(store: store).materialize(
                  sessionID: sessionID,
                  bindings: source.worktreeBindings
              ),
              !projection.isEmpty
        else {
            return WorkspaceLookupContext.visibleWorkspace
        }
        return WorkspaceLookupContext(rootScope: projection.lookupRootScope, bindingProjection: projection)
    }
}

enum AgentWorkspaceLookupContextResolutionError: LocalizedError {
    case unavailableProjection

    var errorDescription: String? {
        "The Agent session worktree projection is unavailable. The operation stopped rather than falling back to the canonical checkout."
    }
}
