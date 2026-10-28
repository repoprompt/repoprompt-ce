import RepoPromptDomainRuntime
import SwiftUI

/// Oversight and copy facts for one active sidebar row, resolved once per list render.
///
/// The row previously re-resolved these inside its own body through closures, which made every
/// row's inputs incomparable. Capturing them as values lets an unrelated link-candidate or
/// projection notification leave unchanged rows untouched (#1373).
struct AgentSidebarRowOversightFacts: Equatable {
    var role = AgentSessionOversightRole.none
    var summary: AgentSidebarOversightSummary?
    var targetEndpoint: DomainAgentSessionLinkEndpointIdentity?
    var creatorSessionID: UUID?
    var creatorDisplayName: String?
    var copySessionIDTarget: AgentSessionCopyIDTarget?
    /// Live preconditions of identity-only oversight preparation. Non-nil only while the row still
    /// lacks an exact endpoint; a change re-runs the preparation task once those settle.
    var preparationKey: AgentSidebarOversightPreparationKey?

    static let none = AgentSidebarRowOversightFacts()
}

/// Inputs `prepareSidebarOversightSession` gates on that a row would otherwise never observe.
struct AgentSidebarOversightPreparationKey: Hashable {
    let sessionID: UUID
    let hasLiveSession: Bool
    let hasLoadedPersistedState: Bool
    let isLoading: Bool
    let bindingTransitionInProgress: Bool
    let isDirty: Bool
}

/// Every value an active sidebar row renders. Equality is the row's whole render identity:
/// anything the row shows must be here, and nothing else may invalidate it.
struct AgentSidebarActiveRowModel: Equatable {
    let session: AgentModeViewModel.SidebarSession
    let workspaceID: UUID?
    let isActive: Bool
    let runState: AgentSessionRunState
    let attentionRunState: AgentSessionRunState?
    let oversight: AgentSidebarRowOversightFacts
    let isSelected: Bool
    let showsSelectionPresentation: Bool
    let isInteractionEnabled: Bool
    let commandProgressKind: AgentSidebarBulkActionKind?

    var identity: AgentSidebarSelectionIdentity {
        .active(tabID: session.tabID)
    }
}

#if DEBUG
    /// Test probe for `AgentSessionRow` body evaluations, keyed by row title. Production never sets it.
    @MainActor
    enum AgentSidebarRowRenderProbe {
        static var onSessionRowBody: ((String) -> Void)?
        /// Reports the model each active row body renders.
        static var onActiveRowBody: ((AgentSidebarActiveRowModel) -> Void)?
        /// Reports the active rows (with their headers) each list body renders.
        static var onActiveRowsRendered: (([AgentSidebarRenderedActiveRow]) -> Void)?
        /// Reports unequal row models so tests can name the field that invalidated a row.
        static var onActiveRowModelChange: ((AgentSidebarActiveRowModel, AgentSidebarActiveRowModel) -> Void)?
    }
#endif

/// Shared, non-observed action owner for one sidebar list.
///
/// Rows skipped by equality keep the closures from their last render, so those closures must
/// never capture values that can change without changing the row model. Anything list-wide
/// (the rendered selection order, the bound view models) is read from here at call time.
///
/// Deliberately not observable: the owning list writes it from `body` (`bind`, `recordRender`).
/// Adding `@Published` state here would turn those writes into update-during-render cycles.
@MainActor
final class AgentSidebarActiveRowActions {
    private(set) weak var agentModeVM: AgentModeViewModel?
    private weak var promptManager: PromptViewModel?
    /// Latest rendered selection order; shift-range and Cmd-A read it at gesture time.
    private(set) var renderedSelectionOrder: [AgentSidebarSelectionIdentity] = []
    private var renderedSessions: [AgentModeViewModel.SidebarSession] = []
    private var renderedOversightFacts: [UUID: AgentSidebarRowOversightFacts] = [:]

    func bind(agentModeVM: AgentModeViewModel, promptManager: PromptViewModel) {
        self.agentModeVM = agentModeVM
        self.promptManager = promptManager
    }

    /// Records what the list just rendered so notification filtering and row actions see the
    /// same rows the user sees.
    func recordRender(
        sessions: [AgentModeViewModel.SidebarSession],
        renderedSelectionOrder: [AgentSidebarSelectionIdentity],
        oversightFacts: [UUID: AgentSidebarRowOversightFacts]
    ) {
        renderedSessions = sessions
        self.renderedSelectionOrder = renderedSelectionOrder
        renderedOversightFacts = oversightFacts
    }

    /// Bounded current oversight facts for one row. Reads only in-memory projections.
    func oversightFacts(for session: AgentModeViewModel.SidebarSession) -> AgentSidebarRowOversightFacts {
        guard let agentModeVM, let sessionID = session.sessionID else { return .none }
        let creator = agentModeVM.agentSidebarLaneCreator(tabID: session.tabID, expectedSessionID: sessionID)
        let role = agentModeVM.agentSidebarOversightRole(tabID: session.tabID, expectedSessionID: sessionID)
        return AgentSidebarRowOversightFacts(
            role: role,
            // The row renders the summary only inside its role mark. The summary also carries
            // window-wide counts (available observers) that change for every row whenever any one
            // session's eligibility changes, so unmarked rows must not depend on it.
            summary: role.hasMark
                ? Self.renderedSummary(
                    agentModeVM.agentSidebarOversightSummary(tabID: session.tabID, expectedSessionID: sessionID)
                )
                : nil,
            targetEndpoint: agentModeVM.agentSidebarOversightTargetEndpoint(
                tabID: session.tabID,
                expectedSessionID: sessionID
            ),
            creatorSessionID: creator?.sessionID,
            creatorDisplayName: creator?.label,
            copySessionIDTarget: agentModeVM.agentSessionCopyIDTarget(
                tabID: session.tabID,
                sessionID: sessionID,
                tabName: session.title
            ),
            preparationKey: Self.preparationKey(agentModeVM: agentModeVM, tabID: session.tabID, sessionID: sessionID)
        )
    }

    private static func preparationKey(
        agentModeVM: AgentModeViewModel,
        tabID: UUID,
        sessionID: UUID
    ) -> AgentSidebarOversightPreparationKey? {
        guard agentModeVM.agentSidebarOversightTargetEndpoint(tabID: tabID, expectedSessionID: sessionID) == nil
        else { return nil }
        let live = agentModeVM.sessions[tabID]
        return AgentSidebarOversightPreparationKey(
            sessionID: sessionID,
            hasLiveSession: live != nil,
            hasLoadedPersistedState: live?.hasLoadedPersistedState ?? false,
            isLoading: live?.persistedLoadTask != nil,
            bindingTransitionInProgress: live?.bindingTransitionInProgress ?? false,
            isDirty: live?.isDirty ?? false
        )
    }

    /// Click-time check for the verbatim Copy Session ID fallback: the row's tab must still resolve
    /// to the captured session in the active workspace.
    func isCurrentRowSessionID(_ sessionID: UUID, tabID: UUID, workspaceID: UUID?) -> Bool {
        guard let agentModeVM, let promptManager, let workspaceID,
              agentModeVM.workspaceManager?.activeWorkspaceID == workspaceID,
              let snapshot = promptManager.sidebarWorkspaceSnapshot, snapshot.workspaceID == workspaceID
        else { return false }
        return agentModeVM.agentChatsSidebarSessions(for: snapshot.composeTabs)
            .first { $0.tabID == tabID }?.sessionID == sessionID
    }

    /// Recorded facts mirror what a closed row renders. `observerIneligibleReason` is overlaid from
    /// the process-wide persistence presentation, whose updates post no sidebar invalidation, and
    /// the row never renders it: menus re-resolve the reason when they open. Keeping it out stops
    /// recorded facts drifting from the live projection between notifications.
    nonisolated static func renderedSummary(_ summary: AgentSidebarOversightSummary?) -> AgentSidebarOversightSummary? {
        guard var summary else { return nil }
        summary.observerIneligibleReason = nil
        return summary
    }

    /// Whether a session-link notification changed anything a rendered row shows. Global
    /// candidate notifications fire for every window on any binding or eligibility change;
    /// only a real change to these rows may re-render the list.
    func renderedOversightFactsChanged() -> Bool {
        renderedSessions.contains { session in
            oversightFacts(for: session) != (renderedOversightFacts[session.tabID] ?? .none)
        }
    }

    func handleSelectionGesture(
        _ gesture: AgentSidebarSelectionGesture,
        model: AgentSidebarActiveRowModel
    ) -> AgentSidebarSelectionGestureDisposition {
        guard let agentModeVM else { return .ignored }
        return agentModeVM.handleSidebarSelectionGesture(
            gesture,
            identity: model.identity,
            renderedOrder: renderedSelectionOrder,
            workspaceID: model.workspaceID
        )
    }

    func select(_ model: AgentSidebarActiveRowModel) {
        guard let agentModeVM, let promptManager else { return }
        Task {
            guard agentModeVM.workspaceManager?.activeWorkspaceID == model.workspaceID else { return }
            await promptManager.switchComposeTab(model.session.tabID)
        }
    }

    func performSingleBulkAction(_ action: AgentSidebarBulkActionKind, model: AgentSidebarActiveRowModel) {
        guard let workspaceID = model.workspaceID else { return }
        let tabID = model.session.tabID
        performBulkAction(action, origin: .command, commandProgressPlacement: .row, targets: .init(
            workspaceID: workspaceID,
            activeDeleteTabIDs: action == .delete ? [tabID] : [],
            archivedDeleteTargets: [],
            stashTabIDs: action == .stash ? [tabID] : [],
            pinTabIDs: action == .pin ? [tabID] : [],
            unpinTabIDs: action == .unpin ? [tabID] : []
        ))
    }

    func performBulkAction(
        _ action: AgentSidebarBulkActionKind,
        origin: AgentSidebarBulkActionOrigin,
        commandProgressPlacement: AgentSidebarCommandProgressPlacement?,
        targets: AgentModeViewModel.SidebarBulkMutationTargets
    ) {
        guard let agentModeVM, let promptManager else { return }
        Task {
            await agentModeVM.performSidebarBulkAction(
                action,
                origin: origin,
                commandProgressPlacement: commandProgressPlacement,
                targets: targets,
                promptManager: promptManager
            )
        }
    }

    func prepareOversight(_ model: AgentSidebarActiveRowModel) {
        guard let agentModeVM, let sessionID = model.session.sessionID, let workspaceID = model.workspaceID,
              agentModeVM.canPerformDirectSidebarCommand(workspaceID: workspaceID)
        else { return }
        agentModeVM.prepareSidebarOversightSession(
            tabID: model.session.tabID, sessionID: sessionID, workspaceID: workspaceID
        )
    }
}

private struct AgentSidebarPreparationTaskID: Hashable {
    let sessionID: UUID?
    let key: AgentSidebarOversightPreparationKey?
}

/// One active sidebar row whose render identity is its value model.
///
/// `AgentSessionRow` carries many action closures, which SwiftUI cannot compare, so without this
/// wrapper every list re-render re-evaluated every row body: a session switch with hundreds of
/// pinned rows rebuilt hundreds of rows instead of the two whose selection changed (#1373).
/// Row identity (and therefore in-flight taps) still comes from `AgentSidebarKeyedRowList`.
struct AgentSidebarActiveRow: View, Equatable {
    let model: AgentSidebarActiveRowModel
    let actions: AgentSidebarActiveRowActions

    static func == (lhs: AgentSidebarActiveRow, rhs: AgentSidebarActiveRow) -> Bool {
        let equal = lhs.model == rhs.model && lhs.actions === rhs.actions
        #if DEBUG
            if !equal { AgentSidebarRowRenderProbe.onActiveRowModelChange?(lhs.model, rhs.model) }
        #endif
        return equal
    }

    var body: some View {
        #if DEBUG
            let _ = AgentSidebarRowRenderProbe.onActiveRowBody?(model)
        #endif
        let model = model
        let actions = actions
        let session = model.session
        let hasAgentSession = session.sessionID != nil
        let creatorSessionID = model.oversight.creatorSessionID
        let copySessionIDAction: (() -> Bool)? = model.oversight.copySessionIDTarget.map { target in
            { actions.agentModeVM?.copyAgentSessionID(target: target) ?? false }
        }
        // Resolvers stay lazy: menus and endpoint revalidation read fresh state at activation.
        // `model.oversight.summary`/`targetEndpoint` resolve through the same VM calls; they are in
        // the model so a change re-renders this row, which then re-reads them here.
        let resolveSummary: (@MainActor () -> AgentSidebarOversightSummary?)? = session.sessionID.map { sessionID in
            { @MainActor in actions.agentModeVM?.agentSidebarOversightSummary(tabID: session.tabID, expectedSessionID: sessionID) }
        }
        let resolveMenu: (@MainActor () -> AgentSidebarOversightMenuProps?)? = session.sessionID.map { sessionID in
            { @MainActor in actions.agentModeVM?.agentSidebarOversightMenuProps(tabID: session.tabID, expectedSessionID: sessionID) }
        }
        let resolveTargetEndpoint: (@MainActor () -> DomainAgentSessionLinkEndpointIdentity?)? =
            session.sessionID.map { sessionID in
                { @MainActor in
                    actions.agentModeVM?.agentSidebarOversightTargetEndpoint(tabID: session.tabID, expectedSessionID: sessionID)
                }
            }
        let resolveOverseerCandidate: (@MainActor (String) async -> Result<AgentOversightSessionIDResolution, AgentOversightResolutionMessage>)? = {
            raw in
            guard let rowSessionID = session.sessionID, let agentModeVM = actions.agentModeVM else {
                return .failure(AgentOversightResolutionMessage(message: AgentOversightUICopy.oversightUnavailableMessage))
            }
            return await agentModeVM.resolveSidebarOverseerCandidate(rawSessionID: raw, excludingTargetSessionID: rowSessionID)
        }
        let resolveTargetCandidate: (@MainActor (String) async -> Result<AgentOversightSessionIDResolution, AgentOversightResolutionMessage>)? = {
            raw in
            guard let endpoint = resolveTargetEndpoint?(), let agentModeVM = actions.agentModeVM else {
                return .failure(AgentOversightResolutionMessage(message: AgentOversightUICopy.staleSelectionMessage))
            }
            return agentModeVM.resolveSidebarTargetCandidate(rawSessionID: raw, observerEndpoint: endpoint)
        }

        AgentSessionRow(
            title: session.title,
            isActive: model.isActive,
            oversightRole: model.oversight.role,
            creatorSessionID: creatorSessionID,
            creatorDisplayName: model.oversight.creatorDisplayName,
            onOpenCreator: {
                guard let targetSessionID = session.sessionID, let creatorSessionID,
                      actions.agentModeVM?.agentSessionLinkLaneCreatorSessionID(
                          tabID: session.tabID,
                          expectedSessionID: targetSessionID
                      ) == creatorSessionID
                else { return }
                Task { await AgentSidebarCreatorNavigation.openIfAvailable(creatorSessionID) }
            },
            isPinned: session.isPinned,
            isMCPControlled: session.isMCPControlled,
            runState: model.runState,
            attentionRunState: model.attentionRunState,
            worktree: session.worktree,
            worktreeMergeAttention: session.worktreeMergeAttention,
            threadDepth: session.depth,
            hasThreadChildren: session.hasThreadChildren,
            isThreadCollapsed: session.isThreadCollapsed,
            hiddenThreadDescendantCount: session.hiddenThreadDescendantCount,
            hiddenThreadDescendantAttentionCount: session.hiddenThreadDescendantAttentionCount,
            onToggleThreadCollapse: session.hasThreadChildren
                ? { actions.agentModeVM?.requestSidebarThreadDisclosureToggle(for: session) }
                : nil,
            isSelected: model.isSelected,
            showsSelectionPresentation: model.showsSelectionPresentation,
            isInteractionEnabled: model.isInteractionEnabled,
            commandProgressKind: model.commandProgressKind,
            onSelectionGesture: { gesture in actions.handleSelectionGesture(gesture, model: model) },
            onSelect: { actions.select(model) },
            onTogglePin: { actions.performSingleBulkAction(session.isPinned ? .unpin : .pin, model: model) },
            onStash: session.canStash ? { actions.performSingleBulkAction(.stash, model: model) } : nil,
            onDelete: {
                guard let workspaceID = model.workspaceID, let agentModeVM = actions.agentModeVM,
                      agentModeVM.canPerformDirectSidebarCommand(workspaceID: workspaceID)
                else { return }
                #if DEBUG
                    agentModeVM.debugBeginSidebarDeleteRequest(
                        tabID: session.tabID,
                        source: "AgentSessionsSidebarView.rowDelete",
                        reason: "row_delete_confirmation"
                    )
                #endif
                actions.performSingleBulkAction(.delete, model: model)
            },
            onRename: { newName in
                guard let workspaceID = model.workspaceID, let agentModeVM = actions.agentModeVM,
                      agentModeVM.canPerformDirectSidebarCommand(workspaceID: workspaceID)
                else { return }
                agentModeVM.renameSession(tabID: session.tabID, to: newName)
            },
            onDismissAttention: hasAgentSession
                ? {
                    guard let agentModeVM = actions.agentModeVM,
                          agentModeVM.workspaceManager?.activeWorkspaceID == model.workspaceID
                    else { return }
                    agentModeVM.dismissSidebarRunAttention(tabID: session.tabID)
                }
                : nil,
            onCopySessionID: copySessionIDAction,
            resolveSidebarOversightSummary: resolveSummary,
            resolveSidebarOversightMenu: resolveMenu,
            prepareSidebarOversightMenu: { actions.prepareOversight(model) },
            sidebarOversightUnavailableReason: session.sessionID == nil
                ? AgentOversightUICopy.oversightAvailableAfterFirstMessage
                : nil,
            resolveSidebarOversightTargetEndpoint: resolveTargetEndpoint,
            onAddSidebarOversight: { observerEndpoint, targetEndpoint in
                await actions.agentModeVM?.addAgentSidebarOversight(
                    observerEndpoint: observerEndpoint,
                    targetEndpoint: targetEndpoint
                ) ?? .failed(message: AgentOversightUICopy.oversightUnavailableMessage)
            },
            onStopSidebarOversight: { observerEndpoint, targetEndpoint, reference in
                await actions.agentModeVM?.stopAgentSidebarOversight(
                    observerEndpoint: observerEndpoint,
                    targetEndpoint: targetEndpoint,
                    expectedReference: reference
                ) ?? .failed(message: AgentOversightUICopy.oversightUnavailableMessage)
            },
            onAddOversightLink: { observerEndpoint, targetEndpoint in
                await actions.agentModeVM?.addAgentOversightLink(
                    observerEndpoint: observerEndpoint,
                    targetEndpoint: targetEndpoint
                ) ?? .failed(message: AgentOversightUICopy.oversightUnavailableMessage)
            },
            resolveOverseerSessionIDCandidate: resolveOverseerCandidate,
            resolveTargetSessionIDCandidate: resolveTargetCandidate,
            onOpenLinkedSession: { endpoint in
                Task {
                    await AppDeepLinkRouter.shared.route(
                        agentSession: AgentSessionDeepLinkRoute(
                            windowID: endpoint.windowID,
                            workspaceID: endpoint.workspaceID,
                            tabID: endpoint.tabID,
                            sessionID: endpoint.sessionID
                        )
                    )
                }
            },
            sessionIDCopyAction: .systemClipboard(sessionID: session.sessionID) { sessionID in
                actions.isCurrentRowSessionID(sessionID, tabID: session.tabID, workspaceID: model.workspaceID)
            }
        )
        // Re-keyed on the preparation preconditions, not just the ID: hydration settling later must
        // retry preparation even when the session ID never changes.
        .task(id: AgentSidebarPreparationTaskID(sessionID: session.sessionID, key: model.oversight.preparationKey)) {
            actions.prepareOversight(model)
        }
    }
}
