import Foundation

struct ContextBuilderWorkspaceContext {
    let parentAgentSessionID: UUID
    let frozenTabContext: MCPServerViewModel.TabContextSnapshot
    let worktreeBindings: [AgentSessionWorktreeBinding]
    let lookupContext: WorkspaceLookupContext
    let providerWorkspacePath: String
    let reviewGitContext: FrozenPromptGitReviewContext
    let reviewTargetResolution: ContextBuilderReviewTargetResolution

    var tabID: UUID {
        frozenTabContext.tabID
    }

    static func resolve(
        from snapshot: MCPServerViewModel.TabContextSnapshot,
        workspaceRepoPaths: [String],
        workspaceDirectoryPath: String,
        store: WorkspaceFileContextStore,
        reviewDiagnosticSink: ContextBuilderReviewDiagnosticSink? = nil
    ) async throws -> ContextBuilderWorkspaceContext {
        guard let parentAgentSessionID = snapshot.activeAgentSessionID else {
            throw ContextBuilderWorkspaceContextError.missingParentAgentSession
        }
        guard snapshot.runID != nil else {
            throw ContextBuilderWorkspaceContextError.missingParentAgentRun
        }
        guard let workspaceID = snapshot.workspaceID else {
            throw ContextBuilderWorkspaceContextError.missingWorkspace
        }
        guard case let .hydrated(bindings) = snapshot.worktreeBindingState else {
            throw ContextBuilderWorkspaceContextError.unavailableWorktreeBindingState
        }

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
                    canonicalRootPaths: requestedRootPaths,
                    physicalRootPaths: []
                ),
                bindingProjection: nil
            )
        } else {
            do {
                lookupContext = try await AgentWorkspaceLookupContextResolver.requiredLookupContext(
                    source: AgentWorkspaceLookupContextSource(
                        activeAgentSessionID: parentAgentSessionID,
                        worktreeBindingState: .hydrated(bindings)
                    ),
                    store: store
                )
            } catch {
                throw ContextBuilderWorkspaceContextError.unavailableWorktreeProjection
            }
        }

        let reviewGitContext = await FrozenPromptGitReviewContext.make(
            workspaceID: workspaceID,
            workspaceDirectoryPath: workspaceDirectoryPath,
            workspaceRootPaths: workspaceRepoPaths,
            tabID: snapshot.tabID,
            sessionID: parentAgentSessionID,
            bindings: bindings,
            base: "HEAD",
            store: store
        )
        let reviewTargetResolution = try await ContextBuilderReviewTargetResolver(
            diagnosticSink: reviewDiagnosticSink
        ).resolve(
            input: ContextBuilderReviewTargetInput(
                workspaceID: workspaceID,
                tabID: snapshot.tabID,
                selectionRevision: snapshot.selectionRevision,
                selection: snapshot.selection,
                lookupContext: lookupContext,
                reviewGitContext: reviewGitContext
            ),
            store: store
        )

        let providerWorkspacePath: String
        if let target = reviewTargetResolution.availableTarget {
            providerWorkspacePath = target.primaryCheckout.checkoutRootPath
        } else if !bindings.isEmpty {
            let fallback = workspaceRepoPaths.first ?? workspaceDirectoryPath
            guard let projected = try AgentWorktreeRuntimeWorkspaceResolver.effectiveWorkspacePath(
                bindings: bindings,
                fallbackWorkspacePath: fallback
            ) else {
                throw ContextBuilderWorkspaceContextError.missingWorkspaceRoot
            }
            providerWorkspacePath = projected
        } else if workspaceRepoPaths.count == 1, let onlyRoot = workspaceRepoPaths.first {
            providerWorkspacePath = onlyRoot
        } else {
            // A neutral CWD is not Git authority. Nested Agent Context Builder Git calls use the
            // frozen selected-repository target carried in the run-scoped tab snapshot.
            providerWorkspacePath = workspaceDirectoryPath
        }

        let context = ContextBuilderWorkspaceContext(
            parentAgentSessionID: parentAgentSessionID,
            frozenTabContext: snapshot,
            worktreeBindings: bindings,
            lookupContext: lookupContext,
            providerWorkspacePath: StandardizedPath.absolute(providerWorkspacePath),
            reviewGitContext: reviewGitContext,
            reviewTargetResolution: reviewTargetResolution
        )
        try context.validateAvailability()
        return context
    }

    func validateAvailability() throws {
        do {
            try AgentWorktreeRuntimeWorkspaceResolver.validateBindingsAvailable(worktreeBindings)
        } catch {
            throw ContextBuilderWorkspaceContextError.unavailableWorktreeProjection
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: providerWorkspacePath, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw ContextBuilderWorkspaceContextError.unavailableProviderWorkspace
        }
    }

    func validateReviewTargetAvailability(store: WorkspaceFileContextStore) async throws {
        guard case let .available(target) = reviewTargetResolution else { return }
        if let reason = await ContextBuilderReviewTargetResolver().revalidate(target, store: store) {
            throw reason
        }
    }

    func validateFinalReviewSelection(
        _ selection: StoredSelection,
        workspaceID: UUID,
        tabID: UUID,
        selectionRevision: UInt64,
        store: WorkspaceFileContextStore
    ) async throws {
        guard case let .available(target) = reviewTargetResolution else {
            if case let .unavailable(reason) = reviewTargetResolution { throw reason }
            throw ContextBuilderReviewTargetUnavailableReason.missingFrozenTarget
        }
        if let reason = try await ContextBuilderReviewTargetResolver().validateSelection(
            input: ContextBuilderReviewTargetInput(
                workspaceID: workspaceID,
                tabID: tabID,
                selectionRevision: selectionRevision,
                selection: selection,
                lookupContext: lookupContext,
                reviewGitContext: reviewGitContext
            ),
            frozenTarget: target,
            store: store
        ) {
            throw reason
        }
    }

    func nestedDiscoveryTabContext(runID: UUID) -> MCPServerViewModel.TabContextSnapshot {
        let source = frozenTabContext
        return MCPServerViewModel.TabContextSnapshot(
            tabID: source.tabID,
            windowID: source.windowID,
            workspaceID: source.workspaceID,
            promptText: source.promptText,
            usedAgentOutputAsPrompt: source.usedAgentOutputAsPrompt,
            selection: source.selection,
            selectionRevision: source.selectionRevision,
            selectedMetaPromptIDs: source.selectedMetaPromptIDs,
            selectedContextBuilderPromptIDs: source.selectedContextBuilderPromptIDs,
            tabName: source.tabName,
            runID: runID,
            activeAgentSessionID: parentAgentSessionID,
            worktreeBindingState: .hydrated(worktreeBindings),
            frozenLookupContext: lookupContext,
            contextBuilderReviewTargetResolution: reviewTargetResolution,
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
    case unavailableWorktreeBindingState
    case unavailableWorktreeProjection
    case unavailableProviderWorkspace

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
        case .unavailableWorktreeBindingState:
            "The invoking Agent Mode worktree bindings are not hydrated or are unavailable. Context Builder stopped rather than falling back to the canonical checkout."
        case .unavailableWorktreeProjection:
            "The invoking Agent Mode worktree bindings could not be loaded. Context Builder stopped rather than falling back to the canonical checkout."
        case .unavailableProviderWorkspace:
            "The invoking Agent Mode workspace is unavailable. Context Builder stopped rather than falling back to another checkout."
        }
    }
}
