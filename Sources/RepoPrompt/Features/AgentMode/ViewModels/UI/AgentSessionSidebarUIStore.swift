import Foundation

struct AgentSessionSidebarSnapshot: Equatable {
    var searchText: String
    var visibleSessionCount: Int
    var collapsedThreadKeys: Set<AgentSidebarThreadKey> = []
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
}

@MainActor
final class AgentSessionSidebarUIStore: ObservableObject {
    @Published private(set) var snapshot = AgentSessionSidebarSnapshot(
        searchText: "",
        visibleSessionCount: AgentModeViewModel.sessionSidebarPageSize
    )

    func update(searchText: String, visibleSessionCount: Int) {
        var next = snapshot
        next.searchText = searchText
        next.visibleSessionCount = visibleSessionCount
        _ = publish(next, eventName: "sessionSidebar", force: false)
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

    /// Publishes the next snapshot if it differs from the current one (or if
    /// `force` is true). Returns whether a new revision was emitted so callers
    /// can fall back to their own refresh path when nothing changed.
    @discardableResult
    private func publish(
        _ proposedSnapshot: AgentSessionSidebarSnapshot,
        eventName: String,
        force: Bool
    ) -> Bool {
        var next = proposedSnapshot
        guard force || next != snapshot else {
            #if DEBUG
                AgentModePerfDiagnostics.recordStoreUpdate("sessionSidebar", published: false)
            #endif
            return false
        }
        next.revision &+= 1
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
