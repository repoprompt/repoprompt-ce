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

/// Causal cancellation result: dispatch and accepted cancellation publication are distinct effects.
struct AgentSessionRunStopOutcome {
    let initiatedCancellation: Bool
    let stopped: Bool
}

/// Result of an archive whose targets were checked at stash-commit time.
struct AgentSessionArchiveOutcome {
    var archived: Set<UUID> = []
    /// Targets refused at commit time because they were not idle and the scope lacked `control`.
    var requiresControl: Set<UUID> = []
}

/// Unarchive completion separates the local projection from acknowledged owner persistence.
struct AgentSessionUnarchiveOutcome {
    struct Failure {
        let reason: String
        var localChanges = false
        var persistenceConfirmed = false
    }

    var restored: Set<UUID> = []
    var failures: [UUID: Failure] = [:]
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
    /// Fresh values for one synchronous read region, never an authority cache.
    func states(of sessionIDs: [UUID]) -> [UUID: AgentSessionOrganizeState]
    /// Every loaded session, active and archived.
    func loadedSessionIDs() -> [UUID]
    /// Displayed pinned order (sidebar order) for one loaded workspace.
    func pinnedSessionOrder(workspaceID: UUID) -> [UUID]?
    /// Group mirrors for every active tab in one loaded workspace.
    func groupEntries(workspaceID: UUID) -> [(sessionID: UUID, group: String, order: Int?)]?

    func rename(_ sessionID: UUID, to name: String) -> Bool
    func rename(_ sessionIDs: [UUID], to name: String) -> Set<UUID>
    func rename(_ names: [UUID: String]) -> Set<UUID>
    /// Returns the sessions whose pin state changed.
    func setPinned(_ pinned: Bool, sessionIDs: [UUID]) -> Set<UUID>
    /// Writes explicit pin ranks, only to sessions that are still pinned and active. Writes nothing
    /// else. Returns the sessions whose rank changed.
    func setPinnedRanks(_ ranks: [UUID: Int?]) -> Set<UUID>
    /// Returns the sessions whose group changed.
    func setGroup(_ group: String?, order: Int?, sessionIDs: [UUID]) -> Set<UUID>
    func setGroups(_ groups: [UUID: (name: String?, order: Int?)]) -> Set<UUID>
    /// Writes group order values, only to sessions that are still grouped and active. Writes nothing
    /// else. Returns the sessions whose value changed.
    func setGroupOrderValues(_ values: [UUID: Int?]) -> Set<UUID>
    /// Run state aggregated across every open window: `running` if any window runs the session,
    /// otherwise `unknown` if any lookup fails, otherwise `idle` (also for sessions with no live run).
    func runState(of sessionID: UUID) -> DomainDelegationScopeTargetState
    func runStates(of sessionIDs: [UUID]) -> [UUID: DomainDelegationScopeTargetState]
    /// Archives (stashes) active sessions, one stash per session. `isAuthorized(sessionID)` is folded
    /// into that session's stash mutation-context check, which the stash re-evaluates after its own
    /// suspensions and immediately before it commits; a session it refuses is not archived. Returns
    /// the sessions that were archived.
    func archive(_ sessionIDs: [UUID], isAuthorized: @escaping @MainActor (UUID) -> Bool) async -> Set<UUID>
    /// Restores without switching tabs. Completion waits for owner persistence and exact carrier
    /// readback; authority is checked before mutation and again after each owning save.
    func unarchive(
        _ sessionIDs: [UUID], isAuthorized: @escaping @MainActor (UUID) -> Bool
    ) async -> AgentSessionUnarchiveOutcome
    /// Cancels one proven live runtime owner, checking authority immediately before the claim.
    /// `stopped` requires an accepted cancelled terminal publication for that exact run and binding.
    func stopRun(
        _ sessionID: UUID, isStillAuthorized: @escaping @MainActor () -> Bool
    ) async -> AgentSessionRunStopOutcome
}

extension AgentSessionOrganizingBackend {
    func rename(_ names: [UUID: String]) -> Set<UUID> {
        Set(names.compactMap { id, name in rename(id, to: name) ? id : nil })
    }

    func setGroups(_ groups: [UUID: (name: String?, order: Int?)]) -> Set<UUID> {
        var changed: Set<UUID> = []
        for (id, group) in groups {
            changed.formUnion(setGroup(group.name, order: group.order, sessionIDs: [id]))
        }
        return changed
    }

    func runStates(of sessionIDs: [UUID]) -> [UUID: DomainDelegationScopeTargetState] {
        Dictionary(Set(sessionIDs).map { ($0, runState(of: $0)) }, uniquingKeysWith: { first, _ in first })
    }

    func states(of sessionIDs: [UUID]) -> [UUID: AgentSessionOrganizeState] {
        var result: [UUID: AgentSessionOrganizeState] = [:]
        for id in sessionIDs {
            result[id] = state(of: id)
        }
        return result
    }

    func rename(_ sessionIDs: [UUID], to name: String) -> Set<UUID> {
        Set(sessionIDs.filter { rename($0, to: name) })
    }
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
        states(of: [sessionID])[sessionID]
    }

    func states(of sessionIDs: [UUID]) -> [UUID: AgentSessionOrganizeState] {
        let windows = liveWindows()
        let locations = locations(for: Set(sessionIDs), windows: windows)
        let statesByWindow = windows.map { $0.agentModeViewModel.authoritativeLiveSessionStates(for: Set(sessionIDs)) }
        return locations.mapValues { location in
            let id = location.sessionID
            return state(sessionID: id, location: location.location, runState: Self.runState(statesByWindow.compactMap { $0[id] }))
        }
    }

    func loadedSessionIDs() -> [UUID] {
        var seen: Set<UUID> = []
        var result: [UUID] = []
        for window in liveWindows() {
            guard let workspace = window.workspaceManager.activeWorkspace else { continue }
            for row in window.agentModeViewModel.sidebarSessions(for: workspace.composeTabs) {
                if let id = row.sessionID, seen.insert(id).inserted { result.append(id) }
            }
            var idsByTab: [UUID: UUID] = [:]
            for entry in window.agentModeViewModel.sessionIndex.values where idsByTab[entry.tabID] == nil {
                idsByTab[entry.tabID] = entry.id
            }
            for stashed in workspace.stashedTabs {
                if let id = stashed.tab.activeAgentSessionID ?? idsByTab[stashed.tab.id], seen.insert(id).inserted { result.append(id) }
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

    func rename(_ sessionIDs: [UUID], to name: String) -> Set<UUID> {
        rename(Dictionary(sessionIDs.map { ($0, name) }, uniquingKeysWith: { first, _ in first }))
    }

    func rename(_ names: [UUID: String]) -> Set<UUID> {
        var changed: Set<UUID> = []
        for (window, entries) in activeLocationsByWindow(Array(names.keys)) {
            for entry in entries {
                guard let name = names[entry.sessionID] else { continue }
                window.agentModeViewModel.renameSession(tabID: entry.location.tabID, to: name)
                changed.insert(entry.sessionID)
            }
        }
        return changed
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
            let updated = mutateActiveTabs(window: window, workspaceID: entries[0].location.workspaceID, tabIDs: tabIDs) { tab in
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

    func setGroups(_ groups: [UUID: (name: String?, order: Int?)]) -> Set<UUID> {
        writeActiveTabField(Array(groups.keys)) { tab, id in
            guard let group = groups[id] else { return false }
            let order = group.name == nil ? nil : group.order
            guard tab.sidebarGroup != group.name || tab.sidebarGroupOrder != order else { return false }
            tab.sidebarGroup = group.name
            tab.sidebarGroupOrder = order
            return true
        }
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
                let tabID = entry.location.tabID
                let capturedBinding = entry.location.tab.activeAgentSessionID
                let viewModel = window.agentModeViewModel
                let capturedIdentity = viewModel.agentSessionLifecycleIdentity(tabID: tabID, expectedSessionID: sessionID)
                let report = await Self.stashTabs(
                    [entry.location.tabID],
                    promptManager: window.promptManager,
                    expandCascade: false,
                    isMutationContextCurrent: {
                        // The preflight can suspend. Re-prove one writable carrier before the
                        // actual stash so a newly opened replica cannot receive a partial edit.
                        guard let writable = self.locate(sessionID), writable.window === window,
                              writable.workspaceID == workspaceID, writable.tabID == tabID,
                              writable.stashedTabID == nil,
                              window.workspaceManager.activeWorkspaceID == workspaceID,
                              let currentTab = window.workspaceManager.modelRoutingTab(workspaceID: workspaceID, tabID: tabID),
                              currentTab.activeAgentSessionID == capturedBinding,
                              viewModel.sessions[tabID]?.activeAgentSessionID.map({ $0 == sessionID }) ?? true,
                              viewModel.agentSessionLifecycleIdentity(tabID: tabID, expectedSessionID: sessionID) == capturedIdentity
                        else { return false }
                        // An unloaded legacy carrier may have only an owner-validated index binding.
                        guard capturedBinding == sessionID
                            || (capturedBinding == nil && viewModel.ownerValidatedSessionIndex[sessionID]?.tabID == tabID)
                        else { return false }
                        return isAuthorized(sessionID)
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
        Self.runState(liveWindows().compactMap { $0.agentModeViewModel.authoritativeLiveSessionStates(for: [sessionID])[sessionID] })
    }

    func runStates(of sessionIDs: [UUID]) -> [UUID: DomainDelegationScopeTargetState] {
        let ids = Set(sessionIDs)
        let states = liveWindows().map { $0.agentModeViewModel.authoritativeLiveSessionStates(for: ids) }
        return Dictionary(uniqueKeysWithValues: ids.map { id in (id, Self.runState(states.compactMap { $0[id] })) })
    }

    private static func runState(_ states: [AgentModeViewModel.AuthoritativeLiveSessionState]) -> DomainDelegationScopeTargetState {
        if states.contains(.running) { return .running }
        if states.contains(.ambiguous) { return .unknown }
        return .idle
    }

    func unarchive(
        _ sessionIDs: [UUID], isAuthorized: @escaping @MainActor (UUID) -> Bool
    ) async -> AgentSessionUnarchiveOutcome {
        var outcome = AgentSessionUnarchiveOutcome()
        var byWindow: [Int: (WindowState, [(UUID, Location)])] = [:]
        let initial = locations(for: Set(sessionIDs), windows: liveWindows(), writableOnly: true)
        var seen: Set<UUID> = []
        for sessionID in sessionIDs where seen.insert(sessionID).inserted {
            guard let location = initial[sessionID]?.location, location.stashedTabID != nil else { continue }
            byWindow[location.window.windowID, default: (location.window, [])].1.append((sessionID, location))
        }
        for windowID in byWindow.keys.sorted() {
            guard let (window, entries) = byWindow[windowID] else { continue }
            let manager = window.workspaceManager
            let workspaceID = entries[0].1.workspaceID
            guard window.promptManager.flushActiveComposeTabBeforeWorkspaceMutation(workspaceID: workspaceID)
            else { continue }
            // Flush callbacks and the preceding window's save can change a same-workspace carrier.
            // Reuse the indexed resolver for this region, never the pre-await locations as authority.
            let current = locations(for: Set(entries.map(\.0)), windows: liveWindows(), writableOnly: true)
            guard manager.activeWorkspaceID == workspaceID,
                  let index = manager.workspaces.firstIndex(where: { $0.id == workspaceID })
            else { continue }
            let ephemeral = manager.workspaces[index].isEphemeral
            let stashes = manager.workspaces[index].stashedTabs
            var stashIndexByID: [UUID: Int] = [:]
            for stashIndex in stashes.indices where stashIndexByID[stashes[stashIndex].id] == nil {
                stashIndexByID[stashes[stashIndex].id] = stashIndex
            }
            var tabs = manager.workspaces[index].composeTabs
            var activeTabIDs = Set(tabs.map(\.id))
            var removedIndexes: Set<Int> = []
            var changed: [(UUID, Location)] = []
            for (sessionID, original) in entries {
                guard !Task.isCancelled, isAuthorized(sessionID) else {
                    outcome.failures[sessionID] = .init(reason: "scope_no_longer_current")
                    continue
                }
                guard let location = current[sessionID]?.location,
                      location.window === window, location.workspaceID == workspaceID,
                      location.tabID == original.tabID, location.stashedTabID == original.stashedTabID,
                      let stashID = location.stashedTabID, let stashIndex = stashIndexByID[stashID],
                      !removedIndexes.contains(stashIndex)
                else {
                    outcome.failures[sessionID] = .init(reason: "target_changed")
                    continue
                }
                var tab = stashes[stashIndex].tab
                guard activeTabIDs.insert(tab.id).inserted else { continue }
                tab.lastModified = Date()
                removedIndexes.insert(stashIndex)
                tabs.append(tab)
                changed.append((sessionID, location))
            }
            guard !changed.isEmpty else { continue }
            guard manager.replaceComposeTabCarriers(
                workspaceID: workspaceID,
                composeTabs: tabs,
                stashedTabs: stashes.indices.filter { !removedIndexes.contains($0) }.map { stashes[$0] },
                dateModified: Date()
            ) else {
                for (id, _) in changed {
                    outcome.failures[id] = .init(reason: "target_changed")
                }
                continue
            }
            // Synchronous publication subscribers may replace or reorder the catalog. An
            // admitted publication is still a local effect, even if its owner has changed.
            guard manager.activeWorkspaceID == workspaceID,
                  let published = manager.composeTabCarrierWorkspace(workspaceID: workspaceID)
            else {
                for (id, _) in changed {
                    outcome.failures[id] = .init(reason: "target_changed", localChanges: true)
                }
                continue
            }
            window.promptManager.loadComposeTabsFromWorkspace(published.workspace)
            manager.markWorkspaceDirty()
            let persistence = await manager.pollAndSaveStateWithOutcomeAsync(workspaceID: workspaceID)
            guard persistence.acceptedForLifecycleAdmission, persistence.workspaceID == workspaceID else {
                for (id, _) in changed {
                    outcome.failures[id] = .init(reason: "persistence_rejected", localChanges: true)
                }
                continue
            }
            // A queued save can win first and make this save unnecessary. Check the existing
            // persistence owner's exact workspace, rather than equating .notRequired with durability.
            let durable = ephemeral ? nil : await manager.durableWorkspaceForMutationReadback(workspaceID: workspaceID)
            let readback = locations(for: Set(changed.map(\.0)), windows: liveWindows(), writableOnly: true)
            // Decode/read one workspace once; do not rescan its tab arrays for every requested ID.
            let durableTabs = Dictionary(grouping: durable?.composeTabs ?? [], by: \.id)
            let durableBindings = Dictionary(grouping: (durable?.composeTabs ?? []).filter { $0.activeAgentSessionID != nil }, by: \.activeAgentSessionID)
            let durableStashedTabs = Set((durable?.stashedTabs ?? []).map(\.tab.id))
            let durableStashedSessions = Set((durable?.stashedTabs ?? []).compactMap(\.tab.activeAgentSessionID))
            for (id, original) in changed {
                let carriers = durableTabs[original.tabID] ?? []
                let persisted = durable?.id == workspaceID && carriers.count == 1
                    && (
                        carriers[0].activeAgentSessionID == id
                            || (carriers[0].activeAgentSessionID == nil && original.tab.activeAgentSessionID == nil)
                    )
                    && !durableStashedTabs.contains(original.tabID) && !durableStashedSessions.contains(id)
                    && !(durableBindings[id] ?? []).contains { $0.id != original.tabID }
                guard ephemeral || persisted else {
                    outcome.failures[id] = .init(reason: "persistence_unconfirmed", localChanges: true)
                    continue
                }
                guard let location = readback[id]?.location,
                      location.window === window, location.workspaceID == workspaceID,
                      location.tabID == original.tabID, location.stashedTabID == nil
                else {
                    outcome.failures[id] = .init(reason: "target_changed", localChanges: true, persistenceConfirmed: persisted)
                    continue
                }
                guard !Task.isCancelled, isAuthorized(id) else {
                    outcome.failures[id] = .init(reason: "scope_no_longer_current", localChanges: true, persistenceConfirmed: persisted)
                    continue
                }
                outcome.restored.insert(id)
            }
        }
        return outcome
    }

    func stopRun(
        _ sessionID: UUID, isStillAuthorized: @escaping @MainActor () -> Bool
    ) async -> AgentSessionRunStopOutcome {
        guard !Task.isCancelled, let target = captureRunStopTarget(sessionID) else {
            return .init(initiatedCancellation: false, stopped: false)
        }
        var stopped = false
        let recorder = AgentRunCancellationOutcomeRecorder(
            expectedOwnership: target.ownership, expectedRunID: target.runID, expectedBinding: target.binding,
            onAcceptedPrimaryPublication: { _ in stopped = true }
        )
        let admission = AgentRunCancellationAdmission(
            scope: .activeRun, session: target.session, binding: target.binding,
            expectedOwnership: target.ownership, expectedRunID: target.runID,
            cancellationGeneration: target.cancellationGeneration, pendingStartFence: nil,
            validateAndClaim: { [weak self] in
                guard let self, !Task.isCancelled, isStillAuthorized(),
                      let current = captureRunStopTarget(sessionID)
                else { return false }
                return current.window === target.window && current.session === target.session
                    && current.workspaceID == target.workspaceID && current.tabID == target.tabID
                    && current.binding == target.binding && current.ownership == target.ownership
                    && current.runID == target.runID && current.cancellationGeneration == target.cancellationGeneration
            }
        )
        _ = await target.window.agentModeViewModel.cancelAgentRunForSessionLink(
            session: target.session, admission: admission, outcomeRecorder: recorder,
            completion: .terminalPublished
        )
        return .init(initiatedCancellation: recorder.initiatedCancellation, stopped: stopped)
    }

    private struct RunStopTarget {
        let window: WindowState
        let workspaceID: UUID
        let tabID: UUID
        let session: AgentModeViewModel.TabSession
        let binding: AgentPersistentSessionBindingIdentity
        let ownership: AgentRunOwnership
        let runID: UUID
        let cancellationGeneration: UUID
    }

    /// A representative physical carrier is not necessarily the runtime owner. Cold replicas
    /// contribute no live object; distinct live objects or unresolved local bindings refuse Stop.
    private func captureRunStopTarget(_ sessionID: UUID) -> RunStopTarget? {
        let windows = liveWindows()
        let capture = AgentSessionCarrierResolver.capture(windows: windows, sessionIDs: [sessionID])
        guard let location = capture.uniqueLocations[sessionID], location.stashedTabID == nil else { return nil }
        var candidate: (row: AgentSessionCarrierResolver.Observation, session: AgentModeViewModel.TabSession)?
        for window in windows {
            guard let result = window.agentModeViewModel.authoritativeLiveSessions(for: [sessionID])[sessionID] else { return nil }
            switch result {
            case .failure:
                return nil
            case .success(nil):
                continue
            case let .success(session?):
                guard let row = capture.rows.first(where: {
                    $0.window === window && $0.sessionID == sessionID && $0.stashedTabID == nil
                        && $0.workspaceID == location.workspaceID && $0.tab.id == session.tabID
                }) else { return nil }
                if let candidate, candidate.session !== session { return nil }
                if candidate == nil { candidate = (row, session) }
            }
        }
        guard let candidate,
              candidate.session.runState.isActive,
              !candidate.session.terminalCommitInProgress,
              let binding = candidate.session.persistentSessionBindingIdentity,
              let ownership = candidate.session.activeRunOwnership,
              let runID = candidate.session.runID
        else { return nil }
        return RunStopTarget(
            window: candidate.row.window, workspaceID: candidate.row.workspaceID,
            tabID: candidate.row.tab.id, session: candidate.session, binding: binding,
            ownership: ownership, runID: runID,
            cancellationGeneration: candidate.session.stopState.cancellationGeneration
        )
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

    private func locate(_ sessionID: UUID) -> Location? {
        locations(for: [sessionID], windows: liveWindows(), writableOnly: true)[sessionID]?.location
    }

    /// Equal replicas may supply a read value. Writes additionally require one presentation
    /// owner until canonical commit and revision-pinned peer projection are available.
    private func locations(
        for requested: Set<UUID>, windows: [WindowState], writableOnly: Bool = false
    ) -> [UUID: LocatedSession] {
        let snapshot = AgentSessionCarrierResolver.capture(windows: windows, sessionIDs: requested)
        let locations = snapshot.uniqueLocations.filter { !writableOnly || !snapshot.replicatedSessionIDs.contains($0.key) }
        return locations.mapValues { row in
            (row.sessionID, Location(
                window: row.window, workspaceID: row.workspaceID, tabID: row.tab.id,
                stashedTabID: row.stashedTabID, tab: row.tab
            ))
        }
    }

    private func state(sessionID: UUID, location: Location, runState: DomainDelegationScopeTargetState) -> AgentSessionOrganizeState {
        AgentSessionOrganizeState(
            sessionID: sessionID,
            workspaceID: location.workspaceID,
            tabID: location.tabID,
            name: location.tab.name,
            isArchived: location.stashedTabID != nil,
            isPinned: location.tab.isPinned,
            pinnedOrder: location.tab.pinnedOrder,
            sidebarGroup: location.tab.sidebarGroup,
            sidebarGroupOrder: location.tab.sidebarGroupOrder,
            runState: runState
        )
    }

    private typealias LocatedSession = (sessionID: UUID, location: Location)

    /// Active (non-archived) locations grouped by window, in first-seen order.
    private func activeLocationsByWindow(_ sessionIDs: [UUID]) -> [(WindowState, [LocatedSession])] {
        var order: [Int] = []
        var groups: [Int: (WindowState, [LocatedSession])] = [:]
        let locations = locations(for: Set(sessionIDs), windows: liveWindows(), writableOnly: true)
        for sessionID in sessionIDs {
            guard let location = locations[sessionID]?.location, location.stashedTabID == nil else { continue }
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
        _ write: (inout WorkspaceManagerViewModel.ComposeTabPresentation, UUID) -> Bool
    ) -> Set<UUID> {
        var changed: Set<UUID> = []
        for (window, entries) in activeLocationsByWindow(sessionIDs) {
            let sessionByTabID = Dictionary(
                entries.map { ($0.location.tabID, $0.sessionID) },
                uniquingKeysWith: { first, _ in first }
            )
            let updated = mutateActiveTabs(window: window, workspaceID: entries[0].location.workspaceID, tabIDs: Set(sessionByTabID.keys)) { tab in
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
        tabIDs: Set<UUID>,
        _ mutate: (inout WorkspaceManagerViewModel.ComposeTabPresentation) -> Bool
    ) -> Set<UUID> {
        let manager = window.workspaceManager
        guard window.promptManager.flushActiveComposeTabBeforeWorkspaceMutation(workspaceID: workspaceID),
              manager.activeWorkspaceID == workspaceID else { return [] }
        let changed = manager.updateComposeTabPresentation(workspaceID: workspaceID, tabIDs: tabIDs) { _, tab in
            _ = mutate(&tab)
        }
        guard !changed.isEmpty, let workspace = manager.activeWorkspace else { return [] }
        window.promptManager.loadComposeTabsFromWorkspace(workspace)
        manager.markWorkspaceDirty()
        manager.pollAndSaveState()
        return changed
    }
}
