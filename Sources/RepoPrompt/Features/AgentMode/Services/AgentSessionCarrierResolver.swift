import Foundation

/// One synchronous view of presented identities and every physical claim touching them. This is
/// request-local evidence, never a cache or authority retained across an await or mutation.
@MainActor
enum AgentSessionCarrierResolver {
    struct Observation {
        let window: WindowState
        let workspaceID: UUID
        let workspaceName: String
        let sessionID: UUID
        let tab: ComposeTabState
        let stashedTabID: UUID?
        let entry: AgentSessionIndexEntry?
        let hasCurrentMetadataOwner: Bool
    }

    struct MetadataObservation {
        let window: WindowState
        let workspaceID: UUID
        let entry: AgentSessionIndexEntry
    }

    struct Snapshot {
        var rows: [Observation] = []
        var ambiguousSessionIDs: Set<UUID> = []
        var placementConflictSessionIDs: Set<UUID> = []
        var metadata: [UUID: [MetadataObservation]] = [:]
        var uniqueLocations: [UUID: Observation] = [:]
        /// Equal replicas are readable, but no synchronous canonical write owner is established.
        var replicatedSessionIDs: Set<UUID> = []
        var claimedWorkspaceIDs: [UUID: Set<UUID>] = [:]
        var sessionIDs: Set<UUID> = []
        fileprivate var fences: [WindowFence] = []

        func affectedWorkspaceIDs(for sessionID: UUID) -> Set<UUID> {
            Set(metadata[sessionID, default: []].map(\.workspaceID))
                .union(claimedWorkspaceIDs[sessionID] ?? [])
        }

        @MainActor
        func isCurrent() -> Bool {
            fences.allSatisfy { fence in
                let store = fence.window.agentModeViewModel.sessionIndexStore
                return !fence.window.isClosing
                    && fence.window.workspaceManager.activeWorkspaceID == fence.workspaceID
                    && store.sessionIndexOwner == fence.owner
                    && store.latestSessionIndexOwner == fence.latestOwner
            }
        }
    }

    fileprivate struct WindowFence {
        let window: WindowState
        let workspaceID: UUID?
        let owner: AgentModeViewModel.SessionIndexOwner?
        let latestOwner: AgentModeViewModel.SessionIndexOwner?
    }

    private struct PhysicalKey: Hashable {
        let workspaceID: UUID
        let tabID: UUID
        let stashedTabID: UUID?
    }

    private struct LiveAddress: Hashable {
        let workspaceID: UUID?
        let tabID: UUID
    }

    private struct Placement: Equatable {
        let workspaceID: UUID
        let parentSessionID: UUID?
        let createdByOverseerSessionID: UUID?
        let organizationalParentID: UUID?
        let delegationScopeID: UUID?

        init(_ observation: MetadataObservation) {
            workspaceID = observation.workspaceID
            parentSessionID = observation.entry.parentSessionID
            createdByOverseerSessionID = observation.entry.createdByOverseerSessionID
            organizationalParentID = observation.entry.organizationalParentID
            delegationScopeID = observation.entry.delegationScopeID
        }
    }

    private struct Presentation: Equatable {
        let name: String
        let workspaceName: String?
        let isPinned: Bool
        let pinnedOrder: Int?
        let group: String?
        let groupOrder: Int?

        init(_ tab: ComposeTabState, workspaceName: String?) {
            name = tab.name
            self.workspaceName = workspaceName
            isPinned = tab.isPinned
            pinnedOrder = tab.pinnedOrder
            group = tab.sidebarGroup
            groupOrder = tab.sidebarGroupOrder
        }
    }

    private struct PhysicalEvidence {
        let key: PhysicalKey
        let presentation: Presentation
        var sourceWindows: Set<ObjectIdentifier>
    }

    private struct WindowCapture {
        let window: WindowState
        let workspace: WorkspaceModel?
        let entries: [UUID: AgentSessionIndexEntry]
        let hasCurrentOwner: Bool
        let directCarriers: [WorkspaceManagerViewModel.SessionCarrier]
    }

    static func capture(windows: [WindowState], sessionIDs requestedIDs: Set<UUID>? = nil) -> Snapshot {
        var seenWindows: Set<ObjectIdentifier> = []
        let windows = windows.filter { !$0.isClosing && seenWindows.insert(ObjectIdentifier($0)).inserted }
        // A census intentionally enumerates owners. Point reads never enumerate dictionary keys,
        // unrelated workspaces, or unrelated live sessions to discover their candidate identities.
        let ids: Set<UUID>
        if let requestedIDs {
            ids = requestedIDs
        } else {
            var discovered: Set<UUID> = []
            for window in windows {
                discovered.formUnion(window.agentModeViewModel.ownerValidatedSessionIndex.keys)
                for session in window.agentModeViewModel.sessions.values {
                    if let id = session.activeAgentSessionID { discovered.insert(id) }
                }
                // Inactive-only sessions are not loaded census members. Their claims are still
                // discovered below through the exact identity/address closure of loaded members.
                if let workspace = window.workspaceManager.activeWorkspace {
                    for tab in workspace.composeTabs {
                        if let id = tab.activeAgentSessionID { discovered.insert(id) }
                    }
                    for stash in workspace.stashedTabs {
                        if let id = stash.tab.activeAgentSessionID { discovered.insert(id) }
                    }
                }
            }
            ids = discovered
        }

        var snapshot = Snapshot()
        var captures: [WindowCapture] = []
        var tabIDs: Set<UUID> = []
        var liveAddresses: [UUID: Set<LiveAddress>] = [:]
        var identitiesByTabID: [UUID: Set<UUID>] = [:]
        for window in windows {
            let manager = window.workspaceManager
            let workspace = manager.activeWorkspace
            let vm = window.agentModeViewModel
            let store = vm.sessionIndexStore
            let owner = store.sessionIndexOwner
            let validOwner = owner.map { $0.workspaceID == workspace?.id && store.isOwnerCurrent($0) } ?? false
            snapshot.fences.append(WindowFence(
                window: window, workspaceID: workspace?.id, owner: owner, latestOwner: store.latestSessionIndexOwner
            ))
            let ownerEntries = validOwner ? store.ownerValidatedSessionIndex : [:]
            var entries: [UUID: AgentSessionIndexEntry] = [:]
            for id in ids {
                if let entry = ownerEntries[id], let workspace {
                    entries[id] = entry
                    tabIDs.insert(entry.tabID)
                    snapshot.metadata[id, default: []].append(MetadataObservation(window: window, workspaceID: workspace.id, entry: entry))
                    snapshot.sessionIDs.insert(id)
                }
                let liveTabIDs = vm.liveSessionTabIDs(for: id)
                tabIDs.formUnion(liveTabIDs)
                for tabID in liveTabIDs {
                    // Re-read the live object after the maintained reverse lookup.
                    guard vm.sessions[tabID]?.activeAgentSessionID == id else { continue }
                    identitiesByTabID[tabID, default: []].insert(id)
                    snapshot.sessionIDs.insert(id)
                    liveAddresses[id, default: []].insert(LiveAddress(workspaceID: workspace?.id, tabID: tabID))
                }
            }
            let direct = manager.sessionCarriers(sessionIDs: ids)
            tabIDs.formUnion(direct.map(\.tab.id))
            captures.append(WindowCapture(
                window: window, workspace: workspace, entries: entries, hasCurrentOwner: validOwner,
                directCarriers: direct
            ))
        }

        // Read competing live identities at every discovered address, even when the physical
        // carrier there belongs to an inactive workspace or another requested identity.
        for capture in captures {
            for tabID in tabIDs {
                if let id = capture.window.agentModeViewModel.sessions[tabID]?.activeAgentSessionID {
                    identitiesByTabID[tabID, default: []].insert(id)
                }
            }
        }

        let activeWorkspaceIDs = Set(captures.compactMap { $0.workspace?.id })
        var physical: [UUID: PhysicalEvidence] = [:]
        var physicalKeys: [UUID: Set<PhysicalKey>] = [:]
        for capture in captures {
            let window = capture.window
            let vm = window.agentModeViewModel
            let activeWorkspaceID = capture.workspace?.id
            // Address closure spans windows as well as workspaces: a requested identity cannot
            // ignore another owner's explicit claim on the address through which it will mutate.
            // Capture is synchronous: reuse this manager's direct physical rows within this
            // request, retaining every duplicate. This is not a cache across awaits or mutations.
            let additionalCarriers = window.workspaceManager.sessionCarriers(
                sessionIDs: [], tabIDs: tabIDs, excludingSessionIDs: ids
            )
            for carrier in capture.directCarriers + additionalCarriers {
                let tab = carrier.tab
                let isActiveWorkspace = carrier.workspaceID == activeWorkspaceID
                // Another window's inactive catalog copy is not a second physical owner of a
                // currently open workspace. Its stale title or active/archive projection must
                // not poison the real owner's next read or undo. Other workspace identities
                // still contribute conflict evidence through the indexed address closure.
                if !isActiveWorkspace, activeWorkspaceIDs.contains(carrier.workspaceID) { continue }
                let key = PhysicalKey(workspaceID: carrier.workspaceID, tabID: tab.id, stashedTabID: carrier.stashedTabID)
                var claims: Set<UUID> = []
                if let persistedID = tab.activeAgentSessionID { claims.insert(persistedID) }
                let effectiveID: UUID?
                if isActiveWorkspace {
                    if carrier.stashedTabID == nil {
                        effectiveID = vm.authoritativeSessionID(for: tab)
                            ?? (capture.hasCurrentOwner ? vm.preferredActiveSidebarEntry(
                                for: tab.id, tabName: tab.name, workspaceID: carrier.workspaceID
                            )?.id : nil)
                        if let liveID = vm.sessions[tab.id]?.activeAgentSessionID { claims.insert(liveID) }
                    } else {
                        effectiveID = tab.activeAgentSessionID
                            ?? (capture.hasCurrentOwner ? vm.preferredSidebarEntry(for: tab.id, tabName: tab.name)?.id : nil)
                    }
                    if let effectiveID { claims.insert(effectiveID) }
                } else {
                    // An inactive workspace contributes persisted conflict evidence only. Its
                    // tab UUID does not authorize borrowing the active workspace's live/fallback ID.
                    effectiveID = nil
                }
                identitiesByTabID[tab.id, default: []].formUnion(claims)
                for id in claims where ids.contains(id) {
                    snapshot.sessionIDs.insert(id)
                    snapshot.claimedWorkspaceIDs[id, default: []].insert(carrier.workspaceID)
                    physicalKeys[id, default: []].insert(key)
                    let presentation = Presentation(tab, workspaceName: window.workspaceManager.workspace(withID: carrier.workspaceID)?.name)
                    let sourceWindow = ObjectIdentifier(window)
                    if var existing = physical[id] {
                        if existing.key != key || existing.presentation != presentation || !existing.sourceWindows.insert(sourceWindow).inserted {
                            snapshot.ambiguousSessionIDs.insert(id)
                        }
                        physical[id] = existing
                    } else {
                        physical[id] = PhysicalEvidence(key: key, presentation: presentation, sourceWindows: [sourceWindow])
                    }
                }
                // A historical candidate that loses fallback selection stays metadata-only.
                guard let effectiveID, ids.contains(effectiveID), let workspace = capture.workspace else { continue }
                snapshot.rows.append(Observation(
                    window: window, workspaceID: workspace.id, workspaceName: workspace.name,
                    sessionID: effectiveID, tab: tab, stashedTabID: carrier.stashedTabID,
                    entry: capture.entries[effectiveID], hasCurrentMetadataOwner: capture.hasCurrentOwner
                ))
            }
        }
        for claims in identitiesByTabID.values where claims.count > 1 {
            snapshot.ambiguousSessionIDs.formUnion(claims.intersection(ids))
        }
        for (id, addresses) in liveAddresses {
            // Keep an ownerless live address too: lack of a workspace must not erase a second
            // binding. A singleton orphan remains metadata-only and supplies no mutation location.
            let keys = physicalKeys[id] ?? []
            let hasUnmatchedAddress = !keys.isEmpty && addresses.contains { address in
                !keys.contains { key in
                    key.workspaceID == address.workspaceID && key.tabID == address.tabID && key.stashedTabID == nil
                }
            }
            if addresses.count > 1 || hasUnmatchedAddress { snapshot.ambiguousSessionIDs.insert(id) }
        }
        for (id, observations) in snapshot.metadata {
            guard let first = observations.first else { continue }
            let placement = Placement(first)
            let hasMetadataConflict = observations.contains { Placement($0) != placement }
            let hasCarrierConflict = snapshot.claimedWorkspaceIDs[id]?.contains { $0 != placement.workspaceID } == true
            if hasMetadataConflict || hasCarrierConflict {
                snapshot.placementConflictSessionIDs.insert(id)
                snapshot.ambiguousSessionIDs.insert(id)
            }
        }
        for row in snapshot.rows where !snapshot.ambiguousSessionIDs.contains(row.sessionID) {
            if snapshot.uniqueLocations[row.sessionID] == nil {
                snapshot.uniqueLocations[row.sessionID] = row
            } else {
                snapshot.replicatedSessionIDs.insert(row.sessionID)
            }
        }
        return snapshot
    }
}
