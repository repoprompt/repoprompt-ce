import Foundation

enum AgentSessionWorktreeBindingState: Equatable {
    case notApplicable
    case hydrated([AgentSessionWorktreeBinding])
    case unhydrated
    case unavailable

    var bindings: [AgentSessionWorktreeBinding]? {
        guard case let .hydrated(bindings) = self else { return nil }
        return bindings
    }
}

struct AgentWorkspaceLookupContextSource: Equatable {
    let activeAgentSessionID: UUID?
    let worktreeBindingState: AgentSessionWorktreeBindingState

    init(
        activeAgentSessionID: UUID?,
        worktreeBindingState: AgentSessionWorktreeBindingState
    ) {
        self.activeAgentSessionID = activeAgentSessionID
        self.worktreeBindingState = worktreeBindingState
    }

    init(
        activeAgentSessionID: UUID?,
        worktreeBindings: [AgentSessionWorktreeBinding]
    ) {
        self.init(
            activeAgentSessionID: activeAgentSessionID,
            worktreeBindingState: activeAgentSessionID == nil ? .notApplicable : .hydrated(worktreeBindings)
        )
    }

    var worktreeBindings: [AgentSessionWorktreeBinding] {
        worktreeBindingState.bindings ?? []
    }

    var identity: AgentWorkspaceLookupContextIdentity {
        AgentWorkspaceLookupContextIdentity(
            activeAgentSessionID: activeAgentSessionID,
            worktreeBindingFingerprint: Self.worktreeBindingFingerprint(worktreeBindingState)
        )
    }

    static func worktreeBindingFingerprint(_ bindings: [AgentSessionWorktreeBinding]) -> String {
        worktreeBindingFingerprint(.hydrated(bindings))
    }

    static func worktreeBindingFingerprint(_ state: AgentSessionWorktreeBindingState) -> String {
        switch state {
        case .notApplicable:
            "not-applicable"
        case .unhydrated:
            "unhydrated"
        case .unavailable:
            "unavailable"
        case let .hydrated(bindings):
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
        guard let sessionID = source.activeAgentSessionID else {
            return .visibleWorkspace
        }
        guard case let .hydrated(bindings) = source.worktreeBindingState else {
            throw AgentWorkspaceLookupContextResolutionError.unknownBindingState
        }
        guard !bindings.isEmpty else {
            return .visibleWorkspace
        }

        let visibleRootPaths = await Set(store.rootRefs(scope: .visibleWorkspace).map(\.standardizedFullPath))
        let logicalRootPaths = Set(bindings.compactMap {
            AgentWorktreeRuntimeWorkspaceResolver.standardizedWorkspacePath($0.logicalRootPath)
        })
        guard logicalRootPaths.count == bindings.count,
              logicalRootPaths.isSubset(of: visibleRootPaths)
        else {
            throw AgentWorkspaceLookupContextResolutionError.unavailableProjection
        }

        do {
            try AgentWorktreeRuntimeWorkspaceResolver.validateBindingsAvailable(bindings)
        } catch {
            throw AgentWorkspaceLookupContextResolutionError.unavailableProjection
        }
        guard let projection = await WorkspaceRootBindingProjectionMaterializer(store: store).materialize(
            sessionID: sessionID,
            bindings: bindings
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

    static func authoritativeLookupContextOrFailClosed(
        source: AgentWorkspaceLookupContextSource,
        store: WorkspaceFileContextStore
    ) async -> WorkspaceLookupContext {
        do {
            return try await requiredLookupContext(source: source, store: store)
        } catch {
            return WorkspaceLookupContext(
                rootScope: .sessionBoundWorkspace(canonicalRootPaths: [], physicalRootPaths: []),
                bindingProjection: nil
            )
        }
    }

    /// Permissive resolution is reserved for non-authoritative UI consumers.
    static func lookupContext(
        source: AgentWorkspaceLookupContextSource,
        store: WorkspaceFileContextStore
    ) async -> WorkspaceLookupContext {
        guard let sessionID = source.activeAgentSessionID,
              case let .hydrated(bindings) = source.worktreeBindingState,
              !bindings.isEmpty,
              let projection = await WorkspaceRootBindingProjectionMaterializer(store: store).materialize(
                  sessionID: sessionID,
                  bindings: bindings
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
    case unknownBindingState

    var errorDescription: String? {
        switch self {
        case .unavailableProjection:
            "The Agent session worktree projection is unavailable. The operation stopped rather than falling back to the canonical checkout."
        case .unknownBindingState:
            "The Agent session worktree bindings are not hydrated or are unavailable. The operation stopped rather than falling back to the canonical checkout."
        }
    }
}
