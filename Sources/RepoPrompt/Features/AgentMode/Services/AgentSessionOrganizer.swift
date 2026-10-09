import Foundation
import RepoPromptDomainRuntime

// Shared organizing primitives behind `session_admin` organize/release ops and the sidebar bulk
// dispatcher (design §3.4). One mutation path per action means human and agent semantics cannot
// drift: pin/unpin/stash still route through `PromptViewModel`, rename through
// `AgentModeViewModel.renameSession`, so every existing invariant (workspace dirtiness, saves, Codex
// thread-name sync, projection removal callbacks) is preserved.
//
// SEARCH-HELPER: session organizer, sidebar groups, pin order, archive/unarchive without switching.

/// Organizing-relevant state of one loaded session (its workspace is a window's active workspace).
struct AgentSessionOrganizeState: Equatable {
    let sessionID: UUID
    let workspaceID: UUID
    let tabID: UUID
    var name: String
    var isArchived: Bool
    var isPinned: Bool
    var pinnedOrder: Int?
    var sidebarGroup: String?
    var sidebarGroupOrder: Int?
    /// `idle` when there is no live run; `unknown` when it cannot be established.
    var runState: DomainDelegationScopeTargetState
}

/// Result of an archive whose targets were checked at stash-commit time.
struct AgentSessionArchiveOutcome {
    var archived: Set<UUID> = []
    /// Targets refused at commit time because they were not idle and the scope lacked `control`.
    var requiresControl: Set<UUID> = []
}

/// Records which targets a commit-time check last refused on run state. A stash evaluates its check
/// more than once (before and after its preflight suspension); the last evaluation decides.
@MainActor
final class AgentSessionRunStateRefusals {
    private(set) var refused: Set<UUID> = []

    /// Records the run-state verdict for `sessionID` and returns it.
    func admit(_ sessionID: UUID, _ allowed: Bool) -> Bool {
        if allowed { refused.remove(sessionID) } else { refused.insert(sessionID) }
        return allowed
    }

    /// The target was refused for another reason (lease), not run state.
    func clear(_ sessionID: UUID) {
        refused.remove(sessionID)
    }
}

/// The organizing mutations a handler may perform, all on loaded sessions only.
@MainActor
protocol AgentSessionOrganizingBackend: AnyObject {
    /// `nil` when the session is not in any open window's active workspace.
    func state(of sessionID: UUID) -> AgentSessionOrganizeState?
    /// Every loaded session, active and archived.
    func loadedSessionIDs() -> [UUID]
    /// Displayed pinned order (sidebar order) for one loaded workspace.
    func pinnedSessionOrder(workspaceID: UUID) -> [UUID]?
    /// Group mirrors for every active tab in one loaded workspace.
    func groupEntries(workspaceID: UUID) -> [(sessionID: UUID, group: String, order: Int?)]?

    func rename(_ sessionID: UUID, to name: String) -> Bool
    /// Returns the sessions whose pin state changed.
    func setPinned(_ pinned: Bool, sessionIDs: [UUID]) -> Set<UUID>
    /// Writes explicit pin ranks, only to sessions that are still pinned and active. Writes nothing
    /// else. Returns the sessions whose rank changed.
    func setPinnedRanks(_ ranks: [UUID: Int?]) -> Set<UUID>
    /// Returns the sessions whose group changed.
    func setGroup(_ group: String?, order: Int?, sessionIDs: [UUID]) -> Set<UUID>
    /// Writes group order values, only to sessions that are still grouped and active. Writes nothing
    /// else. Returns the sessions whose value changed.
    func setGroupOrderValues(_ values: [UUID: Int?]) -> Set<UUID>
    /// Run state aggregated across every open window: `running` if any window runs the session,
    /// otherwise `unknown` if any lookup fails, otherwise `idle` (also for sessions with no live run).
    func runState(of sessionID: UUID) -> DomainDelegationScopeTargetState
    /// Archives (stashes) active sessions, one stash per session. `isAuthorized(sessionID)` is folded
    /// into that session's stash mutation-context check, which the stash re-evaluates after its own
    /// suspensions and immediately before it commits; a session it refuses is not archived. Returns
    /// the sessions that were archived.
    func archive(_ sessionIDs: [UUID], isAuthorized: @escaping @MainActor (UUID) -> Bool) async -> Set<UUID>
    /// Restores archived sessions to the sidebar without switching the user's current tab.
    func unarchive(_ sessionIDs: [UUID]) -> Set<UUID>
    /// Cancels the session's live run. Returns false when nothing could be cancelled.
    func stopRun(_ sessionID: UUID) async -> Bool
}

// MARK: - Production backend

/// Organizing over every open window's active workspace.
@MainActor
final class OpenWindowsAgentSessionOrganizer: AgentSessionOrganizingBackend {
    private struct Location {
        let window: WindowState
        let workspaceID: UUID
        let tabID: UUID
        /// Present when the session is archived.
        let stashedTabID: UUID?
        let tab: ComposeTabState
    }

    private let windows: @MainActor () -> [WindowState]

    init(windows: @escaping @MainActor () -> [WindowState] = { WindowStatesManager.shared.allWindows }) {
        self.windows = windows
    }

    // MARK: Shared window primitives (also used by the sidebar bulk dispatcher)

    /// Pin or unpin tabs in one window. The single pin mutation path for UI and agents.
    static func setTabsPinned(
        _ pinned: Bool,
        tabIDs: Set<UUID>,
        promptManager: PromptViewModel,
        isMutationContextCurrent: (@MainActor () -> Bool)? = nil
    ) -> PromptViewModel.ComposeTabPinMutationReport {
        promptManager.setComposeTabsPinned(pinned, for: tabIDs, isMutationContextCurrent: isMutationContextCurrent)
    }

    /// Archive (stash) tabs in one window. The single archive mutation path for UI and agents.
    static func stashTabs(
        _ tabIDs: Set<UUID>,
        promptManager: PromptViewModel,
        expandCascade: Bool = true,
        isMutationContextCurrent: (@MainActor () -> Bool)? = nil,
        onProjectionRemovalCommitted: PromptViewModel.ComposeTabsProjectionRemovalCallback? = nil
    ) async -> PromptViewModel.ComposeTabMutationReport {
        await promptManager.stashComposeTabs(
            withIDs: tabIDs,
            isMutationContextCurrent: isMutationContextCurrent,
            expandCascade: expandCascade,
            onProjectionRemovalCommitted: onProjectionRemovalCommitted
        )
    }

    // MARK: AgentSessionOrganizingBackend

    func state(of sessionID: UUID) -> AgentSessionOrganizeState? {
        guard let location = locate(sessionID) else { return nil }
        return state(sessionID: sessionID, location: location)
    }

    func loadedSessionIDs() -> [UUID] {
        var seen: Set<UUID> = []
        var result: [UUID] = []
        for window in liveWindows() {
            guard let workspace = window.workspaceManager.activeWorkspace else { continue }
            for row in window.agentModeViewModel.sidebarSessions(for: workspace.composeTabs) {
                if let id = row.sessionID, seen.insert(id).inserted { result.append(id) }
            }
            for stashed in workspace.stashedTabs {
                if let id = archivedSessionID(stashed, window: window), seen.insert(id).inserted { result.append(id) }
            }
        }
        return result
    }

    func pinnedSessionOrder(workspaceID: UUID) -> [UUID]? {
        guard let (window, workspace) = loadedWorkspace(workspaceID) else { return nil }
        return window.agentModeViewModel.sidebarSessions(for: workspace.composeTabs)
            .filter { $0.isPinned && $0.sessionID != nil }
            .compactMap(\.sessionID)
    }

    func groupEntries(workspaceID: UUID) -> [(sessionID: UUID, group: String, order: Int?)]? {
        guard let (window, workspace) = loadedWorkspace(workspaceID) else { return nil }
        let tabsByID = Dictionary(uniqueKeysWithValues: workspace.composeTabs.map { ($0.id, $0) })
        return window.agentModeViewModel.sidebarSessions(for: workspace.composeTabs).compactMap { row in
            guard let sessionID = row.sessionID, let tab = tabsByID[row.tabID], let group = tab.sidebarGroup else {
                return nil
            }
            return (sessionID, group, tab.sidebarGroupOrder)
        }
    }

    func rename(_ sessionID: UUID, to name: String) -> Bool {
        guard let location = locate(sessionID), location.stashedTabID == nil else { return false }
        location.window.agentModeViewModel.renameSession(tabID: location.tabID, to: name)
        return true
    }

    func setPinned(_ pinned: Bool, sessionIDs: [UUID]) -> Set<UUID> {
        var changed: Set<UUID> = []
        for (window, entries) in activeLocationsByWindow(sessionIDs) {
            let workspaceID = entries[0].location.workspaceID
            let report = Self.setTabsPinned(
                pinned,
                tabIDs: Set(entries.map(\.location.tabID)),
                promptManager: window.promptManager,
                isMutationContextCurrent: { window.workspaceManager.activeWorkspaceID == workspaceID }
            )
            for entry in entries where report.updatedTabIDs.contains(entry.location.tabID) {
                changed.insert(entry.sessionID)
            }
        }
        return changed
    }

    func setPinnedRanks(_ ranks: [UUID: Int?]) -> Set<UUID> {
        writeActiveTabField(Array(ranks.keys)) { tab, sessionID in
            guard tab.isPinned, let rank = ranks[sessionID], tab.pinnedOrder != rank else { return false }
            tab.pinnedOrder = rank
            return true
        }
    }

    func setGroup(_ group: String?, order: Int?, sessionIDs: [UUID]) -> Set<UUID> {
        var changed: Set<UUID> = []
        for (window, entries) in activeLocationsByWindow(sessionIDs) {
            let tabIDs = Set(entries.map(\.location.tabID))
            let updated = mutateActiveTabs(window: window, workspaceID: entries[0].location.workspaceID) { tab in
                guard tabIDs.contains(tab.id) else { return false }
                let nextOrder = group == nil ? nil : order
                guard tab.sidebarGroup != group || tab.sidebarGroupOrder != nextOrder else { return false }
                tab.sidebarGroup = group
                tab.sidebarGroupOrder = nextOrder
                return true
            }
            for entry in entries where updated.contains(entry.location.tabID) {
                changed.insert(entry.sessionID)
            }
        }
        return changed
    }

    func setGroupOrderValues(_ values: [UUID: Int?]) -> Set<UUID> {
        writeActiveTabField(Array(values.keys)) { tab, sessionID in
            guard tab.sidebarGroup != nil, let value = values[sessionID], tab.sidebarGroupOrder != value else {
                return false
            }
            tab.sidebarGroupOrder = value
            return true
        }
    }

    func archive(_ sessionIDs: [UUID], isAuthorized: @escaping @MainActor (UUID) -> Bool) async -> Set<UUID> {
        var archived: Set<UUID> = []
        for (window, entries) in activeLocationsByWindow(sessionIDs) {
            let workspaceID = entries[0].location.workspaceID
            // One stash per session, each guarded by that session's own check. The stash evaluates
            // `isMutationContextCurrent` again after its preflight suspension, immediately before it
            // commits, so a session that started running meanwhile is refused at commit time. Only the
            // authorized tabs: an agent never archives children it was not authorized for.
            for entry in entries {
                let sessionID = entry.sessionID
                let report = await Self.stashTabs(
                    [entry.location.tabID],
                    promptManager: window.promptManager,
                    expandCascade: false,
                    isMutationContextCurrent: {
                        window.workspaceManager.activeWorkspaceID == workspaceID && isAuthorized(sessionID)
                    }
                )
                if report.removedComposeTabIDs.contains(entry.location.tabID) {
                    archived.insert(sessionID)
                }
            }
        }
        return archived
    }

    func runState(of sessionID: UUID) -> DomainDelegationScopeTargetState {
        var running = false
        var unknown = false
        for window in liveWindows() {
            switch Result(catching: { try window.agentModeViewModel.authoritativeLiveSession(for: sessionID) }) {
            case let .success(session?): running = running || session.runState.isActive
            case .success(nil): break
            case .failure: unknown = true
            }
        }
        return running ? .running : unknown ? .unknown : .idle
    }

    func unarchive(_ sessionIDs: [UUID]) -> Set<UUID> {
        var restored: Set<UUID> = []
        var byWindow: [Int: (WindowState, [(UUID, Location)])] = [:]
        for sessionID in sessionIDs {
            guard let location = locate(sessionID), location.stashedTabID != nil else { continue }
            byWindow[location.window.windowID, default: (location.window, [])].1.append((sessionID, location))
        }
        for (window, entries) in byWindow.values {
            let manager = window.workspaceManager
            let workspaceID = entries[0].1.workspaceID
            guard manager.activeWorkspaceID == workspaceID,
                  let index = manager.workspaces.firstIndex(where: { $0.id == workspaceID })
            else { continue }
            var restoredInWindow = false
            for (sessionID, location) in entries {
                guard let stashIndex = manager.workspaces[index].stashedTabs.firstIndex(where: {
                    $0.id == location.stashedTabID
                }) else { continue }
                var tab = manager.workspaces[index].stashedTabs[stashIndex].tab
                guard !manager.workspaces[index].composeTabs.contains(where: { $0.id == tab.id }) else { continue }
                tab.lastModified = Date()
                manager.workspaces[index].stashedTabs.remove(at: stashIndex)
                manager.workspaces[index].composeTabs.append(tab)
                restored.insert(sessionID)
                restoredInWindow = true
            }
            guard restoredInWindow else { continue }
            manager.workspaces[index].dateModified = Date()
            window.promptManager.loadComposeTabsFromWorkspace(manager.workspaces[index])
            manager.markWorkspaceDirty()
            manager.pollAndSaveState()
        }
        return restored
    }

    func stopRun(_ sessionID: UUID) async -> Bool {
        guard let location = locate(sessionID), location.stashedTabID == nil else { return false }
        await location.window.agentModeViewModel.cancelAgentRun(tabID: location.tabID)
        return true
    }

    // MARK: Private

    private func liveWindows() -> [WindowState] {
        windows().filter { !$0.isClosing }
    }

    private func loadedWorkspace(_ workspaceID: UUID) -> (WindowState, WorkspaceModel)? {
        for window in liveWindows() {
            if let workspace = window.workspaceManager.activeWorkspace, workspace.id == workspaceID {
                return (window, workspace)
            }
        }
        return nil
    }

    private func archivedSessionID(_ stashed: StashedTab, window: WindowState) -> UUID? {
        if let id = stashed.tab.activeAgentSessionID { return id }
        return window.agentModeViewModel.sessionIndex.values.first { $0.tabID == stashed.tab.id }?.id
    }

    private func locate(_ sessionID: UUID) -> Location? {
        for window in liveWindows() {
            guard let workspace = window.workspaceManager.activeWorkspace else { continue }
            let rows = window.agentModeViewModel.sidebarSessions(for: workspace.composeTabs)
            if let row = rows.first(where: { $0.sessionID == sessionID }),
               let tab = workspace.composeTabs.first(where: { $0.id == row.tabID })
            {
                return Location(window: window, workspaceID: workspace.id, tabID: tab.id, stashedTabID: nil, tab: tab)
            }
            if let stashed = workspace.stashedTabs.first(where: { archivedSessionID($0, window: window) == sessionID }) {
                return Location(
                    window: window, workspaceID: workspace.id, tabID: stashed.tab.id,
                    stashedTabID: stashed.id, tab: stashed.tab
                )
            }
        }
        return nil
    }

    private func state(sessionID: UUID, location: Location) -> AgentSessionOrganizeState {
        // Aggregated across every window like the membership projector, and fail closed.
        let currentRunState = runState(of: sessionID)
        return AgentSessionOrganizeState(
            sessionID: sessionID,
            workspaceID: location.workspaceID,
            tabID: location.tabID,
            name: location.tab.name,
            isArchived: location.stashedTabID != nil,
            isPinned: location.tab.isPinned,
            pinnedOrder: location.tab.pinnedOrder,
            sidebarGroup: location.tab.sidebarGroup,
            sidebarGroupOrder: location.tab.sidebarGroupOrder,
            runState: currentRunState
        )
    }

    private typealias LocatedSession = (sessionID: UUID, location: Location)

    /// Active (non-archived) locations grouped by window, in first-seen order.
    private func activeLocationsByWindow(_ sessionIDs: [UUID]) -> [(WindowState, [LocatedSession])] {
        var order: [Int] = []
        var groups: [Int: (WindowState, [LocatedSession])] = [:]
        for sessionID in sessionIDs {
            guard let location = locate(sessionID), location.stashedTabID == nil else { continue }
            let key = location.window.windowID
            if groups[key] == nil {
                order.append(key)
                groups[key] = (location.window, [])
            }
            groups[key]?.1.append((sessionID, location))
        }
        return order.compactMap { groups[$0] }
    }

    /// Writes one field on the active tabs carrying `sessionIDs`, one workspace write per window.
    private func writeActiveTabField(
        _ sessionIDs: [UUID],
        _ write: (inout ComposeTabState, UUID) -> Bool
    ) -> Set<UUID> {
        var changed: Set<UUID> = []
        for (window, entries) in activeLocationsByWindow(sessionIDs) {
            let sessionByTabID = Dictionary(
                entries.map { ($0.location.tabID, $0.sessionID) },
                uniquingKeysWith: { first, _ in first }
            )
            let updated = mutateActiveTabs(window: window, workspaceID: entries[0].location.workspaceID) { tab in
                guard let sessionID = sessionByTabID[tab.id] else { return false }
                return write(&tab, sessionID)
            }
            for entry in entries where updated.contains(entry.location.tabID) {
                changed.insert(entry.sessionID)
            }
        }
        return changed
    }

    /// Mutates active compose tabs of one loaded workspace in a single workspace write. Returns the
    /// IDs of tabs whose `mutate` reported a change.
    private func mutateActiveTabs(
        window: WindowState,
        workspaceID: UUID,
        _ mutate: (inout ComposeTabState) -> Bool
    ) -> Set<UUID> {
        let manager = window.workspaceManager
        guard manager.activeWorkspaceID == workspaceID,
              let index = manager.workspaces.firstIndex(where: { $0.id == workspaceID })
        else { return [] }
        var changed: Set<UUID> = []
        var tabs = manager.workspaces[index].composeTabs
        for tabIndex in tabs.indices where mutate(&tabs[tabIndex]) {
            changed.insert(tabs[tabIndex].id)
        }
        guard !changed.isEmpty else { return [] }
        manager.workspaces[index].composeTabs = tabs
        window.promptManager.loadComposeTabsFromWorkspace(manager.workspaces[index])
        manager.markWorkspaceDirty()
        manager.pollAndSaveState()
        return changed
    }
}
