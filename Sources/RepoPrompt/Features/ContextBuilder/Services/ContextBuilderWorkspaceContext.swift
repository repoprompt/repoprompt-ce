import Foundation

struct ContextBuilderWorkspaceContext {
    let parentAgentSessionID: UUID
    let parentAgentRunID: UUID
    let tabID: UUID
    let windowID: Int
    let workspaceID: UUID
    let frozenTabContext: MCPServerViewModel.TabContextSnapshot
    let worktreeBindings: [AgentSessionWorktreeBinding]
    let lookupContext: WorkspaceLookupContext
    let providerWorkspacePath: String

    static func resolve(
        from snapshot: MCPServerViewModel.TabContextSnapshot,
        workspaceRepoPaths: [String],
        store: WorkspaceFileContextStore
    ) async throws -> ContextBuilderWorkspaceContext {
        guard let parentAgentSessionID = snapshot.activeAgentSessionID else {
            throw ContextBuilderWorkspaceContextError.missingParentAgentSession
        }
        guard let parentAgentRunID = snapshot.runID else {
            throw ContextBuilderWorkspaceContextError.missingParentAgentRun
        }
        guard let workspaceID = snapshot.workspaceID else {
            throw ContextBuilderWorkspaceContextError.missingWorkspace
        }
        guard let fallbackWorkspacePath = workspaceRepoPaths.first else {
            throw ContextBuilderWorkspaceContextError.missingWorkspaceRoot
        }

        let bindings = snapshot.worktreeBindings
        try AgentWorktreeRuntimeWorkspaceResolver.validateBindingsAvailable(bindings)

        let lookupContext: WorkspaceLookupContext
        if bindings.isEmpty {
            let requestedRootPaths = Set(workspaceRepoPaths.compactMap {
                AgentWorktreeRuntimeWorkspaceResolver.standardizedWorkspacePath($0)
            })
            let primaryRoots = await store.roots().filter { $0.kind == .primaryWorkspace }
            let loadedPrimaryRootPaths = Set(primaryRoots.map(\.standardizedFullPath))
            guard !requestedRootPaths.isEmpty,
                  requestedRootPaths.isSubset(of: loadedPrimaryRootPaths)
            else {
                throw ContextBuilderWorkspaceContextError.unavailableWorkspaceProjection
            }
            lookupContext = WorkspaceLookupContext(
                rootScope: .sessionBoundWorkspace(
                    logicalRootPaths: loadedPrimaryRootPaths.subtracting(requestedRootPaths),
                    physicalRootPaths: []
                ),
                bindingProjection: nil
            )
        } else {
            guard let projection = await WorkspaceRootBindingProjectionMaterializer(store: store).materialize(
                sessionID: parentAgentSessionID,
                bindings: bindings
            ),
                !projection.isEmpty
            else {
                throw ContextBuilderWorkspaceContextError.unavailableWorktreeProjection
            }

            let requestedPhysicalRootPaths = Set(bindings.compactMap {
                AgentWorktreeRuntimeWorkspaceResolver.standardizedWorkspacePath($0.worktreeRootPath)
            })
            guard requestedPhysicalRootPaths.isSubset(of: projection.physicalRootPaths) else {
                throw ContextBuilderWorkspaceContextError.unavailableWorktreeProjection
            }

            let loadedRoots = await store.rootRefs(scope: projection.lookupRootScope)
            let loadedPaths = Set(loadedRoots.compactMap { root in
                AgentWorktreeRuntimeWorkspaceResolver.standardizedWorkspacePath(root.standardizedFullPath)
            })
            guard projection.physicalRootRefs.allSatisfy({ root in
                guard let path = AgentWorktreeRuntimeWorkspaceResolver.standardizedWorkspacePath(root.standardizedFullPath) else {
                    return false
                }
                return loadedPaths.contains(path)
            }) else {
                throw ContextBuilderWorkspaceContextError.unavailableWorktreeProjection
            }
            lookupContext = WorkspaceLookupContext(
                rootScope: projection.lookupRootScope,
                bindingProjection: projection
            )
        }

        guard let providerWorkspacePath = try AgentWorktreeRuntimeWorkspaceResolver.effectiveWorkspacePath(
            bindings: bindings,
            fallbackWorkspacePath: fallbackWorkspacePath
        ) else {
            throw ContextBuilderWorkspaceContextError.missingWorkspaceRoot
        }

        let context = ContextBuilderWorkspaceContext(
            parentAgentSessionID: parentAgentSessionID,
            parentAgentRunID: parentAgentRunID,
            tabID: snapshot.tabID,
            windowID: snapshot.windowID,
            workspaceID: workspaceID,
            frozenTabContext: snapshot,
            worktreeBindings: bindings,
            lookupContext: lookupContext,
            providerWorkspacePath: providerWorkspacePath
        )
        try context.validateAvailability()
        return context
    }

    func validateAvailability() throws {
        try AgentWorktreeRuntimeWorkspaceResolver.validateBindingsAvailable(worktreeBindings)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: providerWorkspacePath, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw ContextBuilderWorkspaceContextError.unavailableProviderWorkspace(providerWorkspacePath)
        }
    }

    func nestedDiscoveryTabContext(runID: UUID) -> MCPServerViewModel.TabContextSnapshot {
        let source = frozenTabContext
        return MCPServerViewModel.TabContextSnapshot(
            tabID: source.tabID,
            windowID: source.windowID,
            workspaceID: source.workspaceID,
            promptText: source.promptText,
            selection: source.selection,
            selectedMetaPromptIDs: source.selectedMetaPromptIDs,
            tabName: source.tabName,
            runID: runID,
            activeAgentSessionID: parentAgentSessionID,
            worktreeBindings: worktreeBindings,
            explicitlyBound: source.explicitlyBound,
            readFileAutoSelectionGeneration: source.readFileAutoSelectionGeneration
        )
    }
}

enum ContextBuilderWorkspaceContextError: LocalizedError, Equatable {
    case missingParentAgentSession
    case missingParentAgentRun
    case missingWorkspace
    case missingWorkspaceRoot
    case unavailableWorkspaceProjection
    case unavailableWorktreeProjection
    case unavailableProviderWorkspace(String)

    var errorDescription: String? {
        switch self {
        case .missingParentAgentSession:
            "context_builder could not freeze the invoking Agent Mode session identity. Retry after Agent Mode routing settles."
        case .missingParentAgentRun:
            "context_builder could not freeze the invoking Agent Mode run identity. Retry after Agent Mode routing settles."
        case .missingWorkspace:
            "context_builder could not freeze the invoking workspace identity."
        case .missingWorkspaceRoot:
            "context_builder requires a project workspace root for the invoking Agent Mode run."
        case .unavailableWorkspaceProjection:
            "The invoking Agent Mode workspace roots could not be loaded. Context Builder stopped rather than using the visible workspace."
        case .unavailableWorktreeProjection:
            "The invoking Agent Mode worktree bindings could not be loaded. Context Builder stopped rather than falling back to the canonical checkout."
        case let .unavailableProviderWorkspace(path):
            "The invoking Agent Mode workspace path is unavailable: \(path). Context Builder stopped rather than falling back to another checkout."
        }
    }
}
