import Foundation

struct AgentSessionSidebarSnapshot: Equatable {
    var searchText: String
    var visibleSessionCount: Int
    var archivedVisibleSessionCount: Int
    var collapsedThreadKeys: Set<AgentSidebarThreadKey> = []
    /// Thread keys that have already received one-shot default collapse handling
    /// during this view-model lifetime. Explicit user expand/collapse actions
    /// and Expand All mark keys handled so later renders do not immediately
    /// re-collapse them by default.
    var defaultCollapsedThreadKeysHandled: Set<AgentSidebarThreadKey> = []
    /// Per-tab "unseen" run-state attention. Populated when a session's run
    /// transitions to a user-relevant state (completed / failed / waiting) in
    /// the background — i.e. while the user is looking at a different tab —
    /// and cleared once the user opens, resumes, or explicitly dismisses the
    /// badge on that row. Persists across sidebar re-renders but never to
    /// disk; ephemeral per `AgentModeViewModel` instance.
    var attentionRunStateByTabID: [UUID: AgentSessionRunState] = [:]
    /// Deterministic mark time for each unseen-attention badge. Kept in lockstep
    /// with `attentionRunStateByTabID` and intentionally not persisted.
    var attentionMarkedAtByTabID: [UUID: Date] = [:]
    var revision: Int = 0
    var rowContentRevision: Int = 0
}

@MainActor
final class AgentSessionSidebarUIStore: ObservableObject {
    @Published private(set) var snapshot = AgentSessionSidebarSnapshot(
        searchText: "",
        visibleSessionCount: AgentModeViewModel.sessionSidebarPageSize,
        archivedVisibleSessionCount: AgentModeViewModel.sessionSidebarArchivedPageSize
    )
    @Published private(set) var selectionState = AgentSidebarSelectionState()

    func update(searchText: String, visibleSessionCount: Int, archivedVisibleSessionCount: Int) {
        var next = snapshot
        next.searchText = searchText
        next.visibleSessionCount = visibleSessionCount
        next.archivedVisibleSessionCount = archivedVisibleSessionCount
        _ = publish(
            next,
            eventName: "sessionSidebar",
            force: false,
            affectsRowContent: false
        )
    }

    func handleSelectionGesture(
        _ gesture: AgentSidebarSelectionGesture,
        identity: AgentSidebarSelectionIdentity,
        renderedOrder: [AgentSidebarSelectionIdentity],
        workspaceID: UUID
    ) -> AgentSidebarSelectionGestureDisposition {
        var next = selectionState
        let disposition = next.handle(
            gesture,
            identity: identity,
            renderedOrder: renderedOrder,
            workspaceID: workspaceID
        )
        publishSelection(next, eventName: "sessionSidebar.selection.gesture")
        return disposition
    }

    func selectAll(renderedOrder: [AgentSidebarSelectionIdentity], workspaceID: UUID) {
        var next = selectionState
        next.selectAll(renderedOrder: renderedOrder, workspaceID: workspaceID)
        publishSelection(next, eventName: "sessionSidebar.selection.selectAll")
    }

    func clearSelection() {
        var next = selectionState
        next.clear()
        publishSelection(next, eventName: "sessionSidebar.selection.clear")
    }

    func reconcileSelection(renderedOrder: [AgentSidebarSelectionIdentity], workspaceID: UUID?) {
        var next = selectionState
        next.reconcile(renderedOrder: renderedOrder, workspaceID: workspaceID)
        publishSelection(next, eventName: "sessionSidebar.selection.reconcile")
    }

    func beginBulkAction(
        kind: AgentSidebarBulkActionKind,
        origin: AgentSidebarBulkActionOrigin,
        presentationTargets: Set<AgentSidebarSelectionIdentity>,
        commandProgressPlacement: AgentSidebarCommandProgressPlacement?,
        workspaceID: UUID
    ) -> UUID? {
        guard selectionState.inFlightAction == nil, !presentationTargets.isEmpty else { return nil }
        switch origin {
        case .selection:
            guard commandProgressPlacement == nil,
                  selectionState.workspaceID == workspaceID,
                  !selectionState.selectedIdentities.isEmpty,
                  presentationTargets.isSubset(of: selectionState.selectedIdentities)
            else { return nil }
        case .command:
            guard selectionState.selectedIdentities.isEmpty,
                  let commandProgressPlacement
            else { return nil }
            switch commandProgressPlacement {
            case .row:
                guard presentationTargets.count == 1 else { return nil }
            case .archivedHeader:
                guard kind == .delete,
                      presentationTargets.allSatisfy({ identity in
                          if case .archived = identity { return true }
                          return false
                      })
                else { return nil }
            }
        }

        let token = UUID()
        var next = selectionState
        next.workspaceID = workspaceID
        next.notice = nil
        next.inFlightAction = AgentSidebarBulkActionOperation(
            token: token,
            workspaceID: workspaceID,
            kind: kind,
            origin: origin,
            presentationTargets: presentationTargets,
            commandProgressPlacement: commandProgressPlacement
        )
        next.revision &+= 1
        publishSelection(next, eventName: "sessionSidebar.selection.bulkBegin")
        return token
    }

    func isCurrentBulkAction(token: UUID, workspaceID: UUID) -> Bool {
        selectionState.inFlightAction?.token == token
            && selectionState.inFlightAction?.workspaceID == workspaceID
    }

    func retireCommandRowProgress(
        token: UUID,
        forRemovedTabIDs tabIDs: Set<UUID>,
        workspaceID: UUID
    ) {
        guard !tabIDs.isEmpty,
              var operation = selectionState.inFlightAction,
              operation.token == token,
              operation.origin == .command,
              operation.commandProgressPlacement == .row,
              operation.workspaceID == workspaceID,
              !operation.commandRowProgressRetired,
              operation.presentationTargets.contains(where: { tabIDs.contains($0.tabID) })
        else { return }

        operation.commandRowProgressRetired = true
        var next = selectionState
        next.inFlightAction = operation
        next.revision &+= 1
        publishSelection(next, eventName: "sessionSidebar.selection.commandRowProgressRetired")
    }

    func finishBulkAction(token: UUID, workspaceID: UUID, notice: AgentSidebarBulkActionNotice?) {
        guard isCurrentBulkAction(token: token, workspaceID: workspaceID) else { return }
        var next = selectionState
        next.inFlightAction = nil
        if next.selectedIdentities.isEmpty { next.workspaceID = nil }
        next.notice = notice
        next.revision &+= 1
        publishSelection(next, eventName: "sessionSidebar.selection.bulkFinish")
    }

    func invalidateSelectionForWorkspaceChange() {
        var next = AgentSidebarSelectionState()
        next.revision = selectionState.revision &+ 1
        publishSelection(next, eventName: "sessionSidebar.selection.workspaceChange")
    }

    func dismissBulkActionNotice() {
        guard selectionState.notice != nil else { return }
        var next = selectionState
        next.notice = nil
        next.revision &+= 1
        publishSelection(next, eventName: "sessionSidebar.selection.noticeDismiss")
    }

    func isThreadCollapsed(_ key: AgentSidebarThreadKey) -> Bool {
        snapshot.collapsedThreadKeys.contains(key)
    }

    func setThreadCollapsed(_ collapsed: Bool, for key: AgentSidebarThreadKey) {
        var next = snapshot
        if collapsed {
            next.collapsedThreadKeys.insert(key)
        } else {
            next.collapsedThreadKeys.remove(key)
        }
        next.defaultCollapsedThreadKeysHandled.insert(key)
        _ = publish(next, eventName: "sessionSidebar.threadCollapse", force: false)
    }

    func toggleThreadCollapse(_ key: AgentSidebarThreadKey) {
        setThreadCollapsed(!isThreadCollapsed(key), for: key)
    }

    func clearCollapsedThreads() {
        var next = snapshot
        next.collapsedThreadKeys.removeAll()
        _ = publish(next, eventName: "sessionSidebar.threadCollapse.clear", force: false)
    }

    func expandAllSidebarThreads(eligibleKeys: [AgentSidebarThreadKey]) {
        var next = snapshot
        next.collapsedThreadKeys.removeAll()
        next.defaultCollapsedThreadKeysHandled.formUnion(eligibleKeys)
        _ = publish(next, eventName: "sessionSidebar.threadCollapse.expandAll", force: false)
    }

    func seedDefaultCollapsedThreads(eligibleKeys: [AgentSidebarThreadKey]) {
        let newKeys = eligibleKeys.filter { !snapshot.defaultCollapsedThreadKeysHandled.contains($0) }
        guard !newKeys.isEmpty else { return }
        var next = snapshot
        next.collapsedThreadKeys.formUnion(newKeys)
        next.defaultCollapsedThreadKeysHandled.formUnion(newKeys)
        _ = publish(next, eventName: "sessionSidebar.threadCollapse.seedDefaults", force: false)
    }

    // MARK: - Run-state attention

    /// States that should be rendered as persistent background-attention badges.
    /// `.running` is handled by the current run-state indicator, not by attention;
    /// `.idle` and `.cancelled` never raise attention.
    static func isAttentionEligible(_ state: AgentSessionRunState) -> Bool {
        switch state {
        case .completed, .failed,
             .waitingForUser, .waitingForQuestion, .waitingForApproval:
            true
        case .idle, .running, .cancelled:
            false
        }
    }

    /// Stored attention state for a tab, if any.
    func attentionRunState(for tabID: UUID) -> AgentSessionRunState? {
        snapshot.attentionRunStateByTabID[tabID]
    }

    /// Time when the current unseen-attention state was first marked.
    func attentionMarkedAt(for tabID: UUID) -> Date? {
        snapshot.attentionMarkedAtByTabID[tabID]
    }

    /// Mark a tab as having unseen attention-worthy run state. No-op for
    /// states that are not attention-eligible, or when the stored state is
    /// already identical.
    @discardableResult
    func markRunStateAttention(
        tabID: UUID,
        state: AgentSessionRunState,
        markedAt: Date = Date()
    ) -> Bool {
        guard Self.isAttentionEligible(state) else { return false }
        if snapshot.attentionRunStateByTabID[tabID] == state { return false }
        var next = snapshot
        next.attentionRunStateByTabID[tabID] = state
        next.attentionMarkedAtByTabID[tabID] = markedAt
        return publish(next, eventName: "sessionSidebar.attention.mark", force: false)
    }

    /// Clear the unseen-attention badge for a single tab.
    @discardableResult
    func clearRunStateAttention(tabID: UUID) -> Bool {
        guard snapshot.attentionRunStateByTabID[tabID] != nil else { return false }
        var next = snapshot
        next.attentionRunStateByTabID.removeValue(forKey: tabID)
        next.attentionMarkedAtByTabID.removeValue(forKey: tabID)
        return publish(next, eventName: "sessionSidebar.attention.clear", force: false)
    }

    /// Clear attention for a batch of tabs (e.g. closing tabs).
    @discardableResult
    func clearRunStateAttention(for tabIDs: Set<UUID>) -> Bool {
        guard !tabIDs.isEmpty else { return false }
        var next = snapshot
        var changed = false
        for tabID in tabIDs {
            if next.attentionRunStateByTabID.removeValue(forKey: tabID) != nil {
                changed = true
            }
            if next.attentionMarkedAtByTabID.removeValue(forKey: tabID) != nil {
                changed = true
            }
        }
        guard changed else { return false }
        return publish(next, eventName: "sessionSidebar.attention.clearBatch", force: false)
    }

    func refresh() {
        _ = publish(snapshot, eventName: "sessionSidebar.refresh", force: true)
    }

    private func publishSelection(_ next: AgentSidebarSelectionState, eventName: String) {
        guard next != selectionState else { return }
        selectionState = next
        #if DEBUG
            AgentModePerfDiagnostics.recordStoreUpdate(
                eventName,
                published: true,
                details: [
                    "revision": String(next.revision),
                    "selectedCount": String(next.selectedIdentities.count),
                    "hasAnchor": String(next.anchor != nil),
                    "inFlightKind": next.inFlightAction?.kind.rawValue ?? "none",
                    "inFlightTargetCount": String(next.inFlightAction?.targetCount ?? 0),
                    "inFlightRowProgressRetired": String(next.inFlightAction?.commandRowProgressRetired ?? false),
                    "inFlightPlacement": next.inFlightAction?.commandProgressPlacement.map {
                        switch $0 {
                        case .row: "row"
                        case .archivedHeader: "archivedHeader"
                        }
                    } ?? "none",
                    "inFlightOrigin": next.inFlightAction.map {
                        switch $0.origin {
                        case .selection: "selection"
                        case .command: "command"
                        }
                    } ?? "none"
                ]
            )
        #endif
    }

    /// Publishes the next snapshot if it differs from the current one (or if
    /// `force` is true). Returns whether a new revision was emitted so callers
    /// can fall back to their own refresh path when nothing changed.
    @discardableResult
    private func publish(
        _ proposedSnapshot: AgentSessionSidebarSnapshot,
        eventName: String,
        force: Bool,
        affectsRowContent: Bool = true
    ) -> Bool {
        var next = proposedSnapshot
        guard force || next != snapshot else {
            #if DEBUG
                AgentModePerfDiagnostics.recordStoreUpdate("sessionSidebar", published: false)
            #endif
            return false
        }
        next.revision &+= 1
        if affectsRowContent { next.rowContentRevision &+= 1 }
        snapshot = next
        #if DEBUG
            AgentModePerfDiagnostics.recordStoreUpdate(
                eventName,
                published: true,
                details: [
                    "revision": String(snapshot.revision),
                    "visibleSessionCount": String(snapshot.visibleSessionCount),
                    "collapsedThreadCount": String(snapshot.collapsedThreadKeys.count),
                    "attentionCount": String(snapshot.attentionRunStateByTabID.count)
                ]
            )
        #endif
        return true
    }
}
