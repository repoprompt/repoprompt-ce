import Foundation
import MCP
import RepoPromptDomainRuntime

private struct AgentSessionLaneBindingLocation: Hashable {
    let workspaceID: UUID
    let tabID: UUID
}

extension WindowStatesManager {
    func agentSessionLinkWasCreatedBy(sessionID: UUID, creatorSessionID: UUID) -> Bool {
        guard !isTerminating else { return false }
        return allWindows.contains { window in
            !window.isClosing && window.agentModeViewModel.agentSessionLinkWasCreatedBy(
                sessionID: sessionID, creatorSessionID: creatorSessionID
            )
        }
    }

    func agentSessionLinkHasActiveChildSessions(parentSessionID: UUID) -> Bool {
        guard !isTerminating else { return true }
        return AgentSessionLaneChildRetirementRecord.hasBlockingDescendant(
            of: parentSessionID, in: agentSessionLinkLiveChildRetirementRecords()
        )
    }

    private func agentSessionLinkLiveChildRetirementRecords() -> [AgentSessionLaneChildRetirementRecord] {
        allWindows.filter { !$0.isClosing }.flatMap {
            $0.agentModeViewModel.agentSessionLinkChildRetirementRecords()
        }
    }

    func agentSessionLinkHasPersistedActiveChildSessions(parentSessionID: UUID) async -> Bool {
        do {
            let records = try await agentSessionLinkPersistedChildRetirementRecords()
            return isTerminating || AgentSessionLaneChildRetirementRecord.hasBlockingDescendant(
                of: parentSessionID, in: agentSessionLinkMergedChildRetirementRecords(persisted: records)
            )
        } catch { return true }
    }

    /// A hydrated session's live quiescence is newer than its unflushed disk header, so hydrated
    /// records may shadow persisted or index rows for the same session ID under coherent lineage;
    /// index and unhydrated records can only add evidence.
    /// `AgentSessionLaneChildRetirementRecord.merging` owns the per-session verdict, including
    /// ambiguous-lineage fail-closed handling.
    private func agentSessionLinkMergedChildRetirementRecords(
        persisted: [AgentSessionLaneChildRetirementRecord]
    ) -> [AgentSessionLaneChildRetirementRecord] {
        var persistedBySessionID: [UUID: [AgentSessionLaneChildRetirementRecord]] = [:]
        for record in persisted {
            persistedBySessionID[record.sessionID, default: []].append(record)
        }
        var liveBySessionID: [UUID: [AgentSessionLaneChildRetirementRecord]] = [:]
        for record in agentSessionLinkLiveChildRetirementRecords() {
            liveBySessionID[record.sessionID, default: []].append(record)
        }
        var merged: [AgentSessionLaneChildRetirementRecord] = []
        for sessionID in Set(persistedBySessionID.keys).union(liveBySessionID.keys) {
            merged += AgentSessionLaneChildRetirementRecord.merging(
                sessionID: sessionID,
                live: liveBySessionID[sessionID] ?? [],
                persisted: persistedBySessionID[sessionID] ?? []
            )
        }
        return merged
    }

    private func agentSessionLinkPersistedChildRetirementRecords() async throws -> [AgentSessionLaneChildRetirementRecord] {
        var visited: Set<UUID> = []
        var records: [AgentSessionLaneChildRetirementRecord] = []
        for window in allWindows where !window.isClosing {
            for workspace in window.workspaceManager.workspaces where visited.insert(workspace.id).inserted {
                try await records.append(contentsOf: AgentSessionDataService.shared.persistedChildRetirementRecords(
                    workspace: workspace
                ))
            }
        }
        return records
    }

    func agentSessionLinkBindingCount(sessionID: UUID) -> Int {
        guard !isTerminating else { return 0 }
        var locations: Set<AgentSessionLaneBindingLocation> = []
        var projectionOwners: [AgentSessionLaneBindingLocation: Set<Int>] = [:]
        var activeOwners: [AgentSessionLaneBindingLocation: Set<Int>] = [:]
        var ephemeralLocations: Set<AgentSessionLaneBindingLocation> = []
        var duplicateWithinWindow = false
        for window in allWindows where !window.isClosing {
            var seenInWindow: Set<AgentSessionLaneBindingLocation> = []
            for workspace in window.workspaceManager.workspaces {
                for tab in workspace.composeTabs where tab.activeAgentSessionID == sessionID {
                    let location = AgentSessionLaneBindingLocation(workspaceID: workspace.id, tabID: tab.id)
                    if !seenInWindow.insert(location).inserted { duplicateWithinWindow = true }
                    locations.insert(location)
                    projectionOwners[location, default: []].insert(window.windowID)
                    if workspace.isEphemeral { ephemeralLocations.insert(location) }
                    if window.workspaceManager.activeWorkspaceID == workspace.id {
                        activeOwners[location, default: []].insert(window.windowID)
                    }
                }
            }
        }
        // A durable workspace is reloaded on activation, so its inactive catalog copies are not
        // separate bindings. Ephemeral workspaces have no canonical disk copy: every other window
        // can reopen its stale tab, and must still block retirement. A distinct location, second
        // active owner, or duplicate entry within one window also fails closed.
        let count = locations.reduce(0) { count, location in
            let owners = ephemeralLocations.contains(location)
                ? projectionOwners[location]?.count ?? 0
                : activeOwners[location]?.count ?? 0
            return count + max(owners, 1)
        }
        return duplicateWithinWindow ? max(count, 2) : count
    }

    func agentSessionLinkClaimLaneRetirement(endpoint: DomainAgentSessionLinkEndpointIdentity) -> UUID? {
        guard !isTerminating,
              let window = window(withID: endpoint.windowID),
              !window.isClosing,
              window.workspaceManager.activeWorkspace?.id == endpoint.workspaceID,
              window.agentModeViewModel.agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint
        else { return nil }
        return workspaceActivityCoordinator.claimLaneRetirement(workspaceID: endpoint.workspaceID)
    }

    func agentSessionLinkReleaseLaneRetirement(endpoint: DomainAgentSessionLinkEndpointIdentity, claimID: UUID) {
        workspaceActivityCoordinator.releaseLaneRetirement(workspaceID: endpoint.workspaceID, claimID: claimID)
    }

    /// Route only to a registered, non-closing window whose requested workspace is already active.
    /// No window focus or workspace switch is performed on the overseer's behalf.
    func agentSessionLinkCreateLane(
        destinationWindowID: Int,
        workspaceID: UUID,
        creatorSessionID: UUID,
        sessionName: String?,
        selection: AgentSessionLanePolicy.RoleSelection
    ) async throws -> AgentSessionLaneHostCreationOutcome {
        guard !isTerminating,
              let window = window(withID: destinationWindowID),
              !window.isClosing,
              window.workspaceManager.activeWorkspaceID == workspaceID,
              window.workspaceManager.activeWorkspace?.id == workspaceID
        else {
            throw MCPError.invalidParams("The lane destination is unavailable.")
        }
        let outcome = try await window.agentModeViewModel.mcpCreateOversightLane(
            creatorSessionID: creatorSessionID,
            sessionName: sessionName,
            selection: selection,
            expectedWorkspaceID: workspaceID
        )
        switch outcome {
        case let .created(sessionID, tabID, bindingToken):
            return .created(sessionID: sessionID, tabID: tabID, bindingToken: bindingToken)
        case let .creationIncomplete(sessionID, tabID):
            return .creationIncomplete(sessionID: sessionID, tabID: tabID)
        }
    }

    func agentSessionLinkRetireLane(
        endpoint: DomainAgentSessionLinkEndpointIdentity,
        commit: Bool,
        isStillRetirable: @escaping @MainActor () -> Bool
    ) async -> Bool {
        guard !isTerminating,
              let window = window(withID: endpoint.windowID),
              !window.isClosing,
              window.workspaceManager.activeWorkspaceID == endpoint.workspaceID,
              window.agentModeViewModel.agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint
        else { return false }
        let persisted: [AgentSessionLaneChildRetirementRecord]
        do { persisted = try await agentSessionLinkPersistedChildRetirementRecords() }
        catch { return false }
        let descendants = AgentSessionLaneChildRetirementRecord.descendantIDs(
            of: endpoint.sessionID, in: agentSessionLinkMergedChildRetirementRecords(persisted: persisted)
        )
        let subtreeIsRetirable: @MainActor () -> Bool = { [weak self, weak window] in
            guard let self, let window, !self.isTerminating, !window.isClosing, isStillRetirable() else { return false }
            let records = agentSessionLinkMergedChildRetirementRecords(persisted: persisted)
            guard !AgentSessionLaneChildRetirementRecord.hasBlockingDescendant(of: endpoint.sessionID, in: records),
                  AgentSessionLaneChildRetirementRecord.descendantIDs(of: endpoint.sessionID, in: records) == descendants
            else { return false }
            // Cascade removal owns only this window's bindings. Other active owners must keep their tabs.
            for peer in allWindows where !peer.isClosing {
                for workspace in peer.workspaceManager.workspaces {
                    for tab in workspace.composeTabs {
                        guard let sessionID = tab.activeAgentSessionID, descendants.contains(sessionID) else { continue }
                        guard workspace.id == endpoint.workspaceID,
                              self.agentSessionLinkBindingCount(sessionID: sessionID) == 1,
                              peer === window || (!workspace.isEphemeral && peer.workspaceManager.activeWorkspaceID != workspace.id)
                        else { return false }
                    }
                }
            }
            return true
        }
        var removedTabIDs: Set<UUID> = []
        let retired = await window.agentModeViewModel.agentSessionLinkRetireLane(
            endpoint: endpoint,
            commit: commit,
            isStillRetirable: subtreeIsRetirable,
            descendantSessionIDs: descendants,
            didStash: { removedTabIDs = $0 }
        )
        guard retired else { return false }
        guard commit else { return true }
        guard let workspace = window.workspaceManager.activeWorkspace,
              workspace.stashedTabs.contains(where: { $0.tab.id == endpoint.tabID })
        else { return false }
        let stashedSubtree = workspace.stashedTabs.filter { removedTabIDs.contains($0.tab.id) }

        // The bridge holds the workspace activation claim. Reconcile the whole stashed subtree
        // before a peer can activate its old projection.
        for peer in allWindows where peer !== window && !peer.isClosing {
            let manager = peer.workspaceManager
            var projected = manager.workspaces
            var changed = false
            for index in projected.indices where projected[index].id == endpoint.workspaceID
                && manager.activeWorkspaceID != endpoint.workspaceID
            {
                for stashed in stashedSubtree {
                    guard let tabIndex = projected[index].composeTabs.firstIndex(where: {
                        $0.id == stashed.tab.id && $0.activeAgentSessionID == stashed.tab.activeAgentSessionID
                    }) else { continue }
                    projected[index].composeTabs.remove(at: tabIndex)
                    if let stashedIndex = projected[index].stashedTabs.firstIndex(where: {
                        $0.tab.id == stashed.tab.id
                    }) {
                        projected[index].stashedTabs[stashedIndex] = stashed
                    } else {
                        projected[index].stashedTabs.append(stashed)
                    }
                    if projected[index].activeComposeTabID == stashed.tab.id {
                        projected[index].activeComposeTabID = projected[index].composeTabs.first?.id
                    }
                    changed = true
                }
            }
            if changed { manager.workspaces = projected }
        }
        return true
    }

    func agentSessionLinkRetirementReadiness(endpoint: DomainAgentSessionLinkEndpointIdentity) -> Bool {
        guard !isTerminating,
              let window = window(withID: endpoint.windowID),
              !window.isClosing
        else { return false }
        return window.agentModeViewModel.agentSessionLinkRetirementReadiness(endpoint: endpoint)
    }

    func agentSessionLinkLaneProvenance(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> UUID? {
        guard !isTerminating,
              let window = window(withID: endpoint.windowID),
              !window.isClosing
        else { return nil }
        return window.agentModeViewModel.agentSessionLinkLaneProvenance(for: endpoint)
    }

    func agentSessionLinkLaneCreatorLabel(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> String? {
        guard !isTerminating,
              let window = window(withID: endpoint.windowID),
              !window.isClosing
        else { return nil }
        return window.agentModeViewModel.agentSessionLinkLaneCreatorLabel(for: endpoint)
    }
}
