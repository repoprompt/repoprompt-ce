import Foundation

struct ContextBuilderWorkspaceContext {
    let parentAgentSessionID: UUID
    let frozenTabContext: MCPServerViewModel.TabContextSnapshot
    let worktreeBindings: [AgentSessionWorktreeBinding]
    let lookupContext: WorkspaceLookupContext
    let primaryRootSnapshot: WorkspacePrimaryRootSnapshot?
    let providerWorkspacePath: String
    let reviewGitContext: FrozenPromptGitReviewContext
    let reviewTargetResolution: ContextBuilderReviewTargetResolution
    private let boundWorkspaceProbe: ContextBuilderBoundWorkspaceProbe
    private let reviewDiagnosticSink: ContextBuilderReviewDiagnosticSink?
    private let readinessDiagnosticSink: ContextBuilderWorkspaceReadinessDiagnosticSink?

    var tabID: UUID {
        frozenTabContext.tabID
    }

    @MainActor
    static func resolve(
        from snapshot: MCPServerViewModel.TabContextSnapshot,
        workspaceRepoPaths: [String],
        workspaceDirectoryPath: String,
        workspaceManager: WorkspaceManagerViewModel,
        reviewDiagnosticSink: ContextBuilderReviewDiagnosticSink? = nil,
        readinessDiagnosticSink: ContextBuilderWorkspaceReadinessDiagnosticSink? = nil,
        boundWorkspaceProbe: ContextBuilderBoundWorkspaceProbe = .init()
    ) async throws -> ContextBuilderWorkspaceContext {
        var phase: ContextBuilderWorkspaceReadinessDiagnosticEvent.Phase? = .admission
        var primaryRootSnapshot: WorkspacePrimaryRootSnapshot?
        let expectedCount = WorkspacePrimaryRootManifest(normalizedPaths: workspaceRepoPaths.map {
            workspaceManager.fileManager.workspaceRootIdentity(for: $0)
        }).orderedPaths.count
        do {
            try Task.checkCancellation()
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

            let store = workspaceManager.fileManager.workspaceFileContextStore
            let lookupContext: WorkspaceLookupContext
            if bindings.isEmpty {
                let ready: WorkspacePrimaryRootSnapshot
                do {
                    ready = try await workspaceManager.readyPrimaryRootSnapshot(
                        workspaceID: workspaceID, expectedRepoPaths: workspaceRepoPaths
                    )
                } catch let failure as WorkspaceRootReadinessFailure {
                    throw ContextBuilderWorkspaceContextError.readiness(failure)
                }
                primaryRootSnapshot = ready
                lookupContext = WorkspaceLookupContext(
                    rootScope: .validatedSessionBoundWorkspace(canonicalRoots: Set(ready.roots), physicalRoots: []),
                    bindingProjection: nil
                )
            } else {
                primaryRootSnapshot = nil
                do {
                    lookupContext = try await AgentWorkspaceLookupContextResolver.requiredLookupContext(
                        source: AgentWorkspaceLookupContextSource(
                            activeAgentSessionID: parentAgentSessionID,
                            worktreeBindingState: .hydrated(bindings)
                        ),
                        store: store
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw ContextBuilderWorkspaceContextError.unavailableWorktreeProjection
                }
            }

            emitReadiness(
                phase: .admission,
                snapshot: snapshot,
                roots: primaryRootSnapshot,
                expectedCount: expectedCount,
                sink: readinessDiagnosticSink
            )
            phase = .resolved
            let frozenRootPaths = primaryRootSnapshot?.roots.map(\.standardizedFullPath) ?? workspaceRepoPaths
            let reviewGitContext = await FrozenPromptGitReviewContext.make(
                workspaceID: workspaceID,
                workspaceDirectoryPath: workspaceDirectoryPath,
                workspaceRootPaths: frozenRootPaths,
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
                guard let projected = try await boundWorkspaceProbe.effectiveWorkspacePath(
                    bindings: bindings,
                    fallback: fallback
                ) else {
                    throw ContextBuilderWorkspaceContextError.missingWorkspaceRoot
                }
                providerWorkspacePath = projected
            } else if frozenRootPaths.count == 1, let onlyRoot = frozenRootPaths.first {
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
                primaryRootSnapshot: primaryRootSnapshot,
                providerWorkspacePath: StandardizedPath.absolute(providerWorkspacePath),
                reviewGitContext: reviewGitContext,
                reviewTargetResolution: reviewTargetResolution,
                boundWorkspaceProbe: boundWorkspaceProbe,
                reviewDiagnosticSink: reviewDiagnosticSink,
                readinessDiagnosticSink: readinessDiagnosticSink
            )
            // The validator owns this phase outcome; the outer catch must not emit it twice.
            phase = nil
            try await context.validateStartupAvailability(workspaceManager: workspaceManager, phase: .resolved)
            return context
        } catch {
            if let phase {
                emitReadiness(
                    phase: phase,
                    snapshot: snapshot,
                    roots: primaryRootSnapshot,
                    expectedCount: expectedCount,
                    error: error,
                    sink: readinessDiagnosticSink
                )
            }
            throw error
        }
    }

    /// Unbound admission and every later startup check share the manager's bounded probe owner.
    @MainActor
    func validateStartupAvailability(
        workspaceManager: WorkspaceManagerViewModel,
        phase: ContextBuilderWorkspaceReadinessDiagnosticEvent.Phase = .startupRevalidation
    ) async throws {
        do {
            try Task.checkCancellation()
            if let primaryRootSnapshot {
                do {
                    try await workspaceManager.validatePrimaryRootSnapshot(
                        primaryRootSnapshot, additionalDirectoryPaths: [providerWorkspacePath]
                    )
                } catch let failure as WorkspaceRootReadinessFailure {
                    throw ContextBuilderWorkspaceContextError.readiness(failure)
                }
            } else {
                try await boundWorkspaceProbe.validate(bindings: worktreeBindings, providerPath: providerWorkspacePath)
            }
            Self.emitReadiness(
                phase: phase,
                snapshot: frozenTabContext,
                roots: primaryRootSnapshot,
                expectedCount: primaryRootSnapshot?.roots.count ?? 0,
                sink: readinessDiagnosticSink
            )
        } catch {
            Self.emitReadiness(
                phase: phase,
                snapshot: frozenTabContext,
                roots: primaryRootSnapshot,
                expectedCount: primaryRootSnapshot?.roots.count ?? 0,
                error: error,
                sink: readinessDiagnosticSink
            )
            throw error
        }
    }

    private static func emitReadiness(
        phase: ContextBuilderWorkspaceReadinessDiagnosticEvent.Phase,
        snapshot: MCPServerViewModel.TabContextSnapshot,
        roots: WorkspacePrimaryRootSnapshot?,
        expectedCount: Int,
        error: Error? = nil,
        sink: ContextBuilderWorkspaceReadinessDiagnosticSink?
    ) {
        let failure: WorkspaceRootReadinessFailure? = if case let .readiness(value) = error as? ContextBuilderWorkspaceContextError { value }
        else { nil }
        let event = ContextBuilderWorkspaceReadinessDiagnosticEvent(
            phase: phase, outcome: error == nil ? .ready : (error is CancellationError ? .cancelled : .rejected),
            workspaceID: snapshot.workspaceID, tabID: snapshot.tabID, runID: snapshot.runID,
            activationGeneration: roots?.ticket.activationGeneration,
            rootIntentGeneration: roots?.ticket.rootIntentGeneration,
            expectedCount: expectedCount, loadedCount: failure?.loadedCount ?? roots?.roots.count ?? 0,
            missingCount: failure?.missingCount ?? 0, reason: failure?.reason, retryable: failure?.retryable
        )
        sink?(event)
        ContextBuilderWorkspaceReadinessDiagnosticTracer.emit(event)
    }

    /// Run authority trusts the frozen primary-root validation fences, but bound invocations
    /// recheck their provider CWD through the invocation-owned off-main filesystem probe.
    @MainActor
    func isProviderWorkspaceAvailableForRunAuthority() async throws -> Bool {
        guard primaryRootSnapshot == nil else { return true }
        return try await boundWorkspaceProbe.directoryExists(at: providerWorkspacePath)
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

    func authorizeFinalReviewSelection(
        _ selection: StoredSelection,
        workspaceID: UUID,
        tabID: UUID,
        selectionRevision: UInt64,
        store: WorkspaceFileContextStore
    ) async throws -> ContextBuilderFinalReviewAuthorization {
        try await ContextBuilderReviewTargetResolver(
            diagnosticSink: reviewDiagnosticSink
        ).finalizeSelection(
            input: ContextBuilderReviewTargetInput(
                workspaceID: workspaceID,
                tabID: tabID,
                selectionRevision: selectionRevision,
                selection: selection,
                lookupContext: lookupContext,
                reviewGitContext: reviewGitContext
            ),
            initialResolution: reviewTargetResolution,
            store: store
        )
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
    case readiness(WorkspaceRootReadinessFailure)
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
        case let .readiness(failure):
            "\(failure.reason.contextBuilderCategoryCode); retryable=\(failure.retryable). \(failure.reason.contextBuilderGuidance)"
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

extension WorkspaceRootReadinessFailure.Reason {
    var contextBuilderCategoryCode: String {
        switch self {
        case .emptyConfiguration: "context_builder_empty_configuration"
        case .invalidConfiguration: "context_builder_invalid_configuration"
        case .workspaceUnavailable: "context_builder_workspace_unavailable"
        case .workspaceInactive: "context_builder_workspace_inactive"
        case .rootsChanging: "context_builder_roots_changing"
        case .rootsUnavailable: "context_builder_roots_unavailable"
        case .wrongRootKind: "context_builder_wrong_root_kind"
        case .incompleteProjection: "context_builder_incomplete_projection"
        case .staleInvocation: "context_builder_stale_invocation"
        }
    }

    var contextBuilderGuidance: String {
        switch self {
        case .emptyConfiguration:
            "Configure at least one workspace root before retrying Context Builder."
        case .invalidConfiguration:
            "Correct blank or invalid workspace root entries before retrying Context Builder."
        case .workspaceUnavailable:
            "The invoking workspace is no longer available. Open an existing workspace and start a new request."
        case .workspaceInactive:
            "Activate the invoking workspace, then retry this request. Context Builder will not use another workspace."
        case .rootsChanging:
            "Workspace roots are still changing. Retry this request shortly."
        case .rootsUnavailable(.missingDirectory):
            "subreason=missingDirectory. Restore or remove the configured directory, then refresh the workspace and retry."
        case .rootsUnavailable(.notDirectory):
            "subreason=notDirectory. Replace the configured file with a directory or correct the root configuration, then refresh and retry."
        case .rootsUnavailable(.accessDenied):
            "subreason=accessDenied. Restore directory access, then refresh the workspace and retry."
        case .rootsUnavailable(.loadFailed):
            "subreason=loadFailed. Refresh the workspace and retry after resolving its root loading issue."
        case .wrongRootKind:
            "Correct workspace root ownership before retrying. A non-primary root cannot substitute for a configured primary root."
        case .incompleteProjection:
            "Not all configured primary roots are queryable. Refresh the workspace and retry."
        case .staleInvocation:
            "The captured workspace roots changed. Start a new Context Builder request after the workspace settles."
        }
    }
}
