import AppKit
import Combine
import Foundation
import RepoPromptDomainRuntime
import RepoPromptShared

// Cross-window endpoint source for oversight links.
//
// This is the only place that walks `allWindows` on oversight's behalf. It never switches, focuses,
// or activates a window: resolution, snapshotting, and observation are strictly read-only with
// respect to window state.
#if DEBUG
    enum AgentSessionLinkCatalogReadScope {
        static let isRoleLookupTaskLocal = BoxedTaskLocal<Bool>(false)
        static var isRoleLookup: Bool {
            isRoleLookupTaskLocal.get()
        }
    }

    /// Opt-in counters for the bounded actual-route catalog regression fixture.
    @MainActor
    enum AgentSessionLinkCatalogReadProbe {
        static var enabled = false
        static var snapshot = [0, 0, 0, 0]
        static var roleSnapshot = [0, 0, 0, 0]
        static func record(_ index: Int) {
            snapshot[index] += 1
            if AgentSessionLinkCatalogReadScope.isRoleLookup { roleSnapshot[index] += 1 }
        }
    }
#endif

extension WindowStatesManager: AgentSessionLinkEndpointHost, PreparedAgentSessionRuntimeRegistry {
    var preparedSessionRuntimes: (any PreparedAgentSessionRuntimeRegistry)? {
        self
    }

    func addingPreparedRuntimeCarriers(
        to original: AgentSessionCarrierResolver.Snapshot, sessionIDs: Set<UUID>?, windowIDs: Set<Int>
    ) -> AgentSessionCarrierResolver.Snapshot {
        var snapshot = original
        for (id, location) in preparedOversightLocations {
            guard sessionIDs?.contains(id) != false, location.isCurrent,
                  let source = location.window,
                  windowIDs.contains(source.windowID) || preparedOversightWindows[id] != nil,
                  !AgentSessionDeletionRegistry.shared.isPermanentlyDeleted(sessionID: id),
                  !AgentSessionDeletionRegistry.shared.isDeletionInProgress(sessionID: id) else { continue }
            if let metadata = snapshot.metadata[id], metadata.contains(where: {
                $0.workspaceID != location.workspace.id || $0.entry.tabID != location.entry.tabID
            }) {
                snapshot.ambiguousSessionIDs.insert(id)
                continue
            }
            snapshot.sessionIDs.insert(id)
            snapshot.claimedWorkspaceIDs[id, default: []].insert(location.workspace.id)
            if snapshot.metadata[id]?.isEmpty != false {
                snapshot.metadata[id] = [.init(window: source, workspaceID: location.workspace.id, entry: location.entry)]
            }
            guard !snapshot.ambiguousSessionIDs.contains(id), !snapshot.replicatedSessionIDs.contains(id),
                  let owner = preparedOversightWindows[id], !owner.isClosing,
                  let witness = preparedOversightOwnerLocations[id], witness.isCurrent,
                  witness.agreesOnCarrierAndProvenance(with: location), !preparedOversightHandoffs.contains(id),
                  let runtime = owner.agentModeViewModel.sessions[location.tab.id], runtime.activeAgentSessionID == id,
                  runtime.permitsBoundOperationAndSave,
                  let tabs = owner.workspaceManager.activeWorkspace?.composeTabs, tabs.count == 1,
                  let tab = tabs.first else { continue }
            if let existing = snapshot.uniqueLocations[id], existing.window !== source {
                snapshot.ambiguousSessionIDs.insert(id)
                continue
            }
            let row = AgentSessionCarrierResolver.Observation(
                window: owner, workspaceID: location.workspace.id, workspaceName: location.workspace.name,
                sessionID: id, tab: tab, stashedTabID: nil, entry: location.entry, hasCurrentMetadataOwner: true
            )
            snapshot.rows.removeAll { $0.sessionID == id }
            snapshot.rows.append(row)
            snapshot.uniqueLocations[id] = row
        }
        return snapshot
    }

    func hasPreparedRuntime(_ sessionID: UUID) -> Bool {
        preparedOversightWindows[sessionID] != nil
    }

    func claimPreparedRuntimeVisit(_ sessionID: UUID) -> Bool {
        preparedOversightUIVisits.insert(sessionID).inserted
    }

    func finishPreparedRuntimeVisit(_ sessionID: UUID) {
        preparedOversightUIVisits.remove(sessionID)
        notifyAgentSessionLinkTopologyChanged()
    }

    func queuePreparedRuntimeVisit(_ sessionID: UUID, resume: @escaping @MainActor () async -> Void) {
        preparedOversightPendingVisits[sessionID] = resume
        schedulePreparedOversightCleanup()
    }

    func prepareScopedSavedTarget(_ sessionID: UUID, isStillAuthorized: @escaping @MainActor () -> Bool) async -> Bool {
        if case .success = await prepareSavedOversightTarget(sessionID, isStillAuthorized: isStillAuthorized) { return true }
        return false
    }

    /// A closing UI carrier is not withdrawal of an accepted task. Transfer its last exact
    /// witness to the already-bound private runtime before the window can disappear. The
    /// registry owns no extra window or provider, and consent/deletion remain independent.
    func detachPreparedRuntimeCarriers(from source: WindowState) {
        for (id, location) in preparedOversightOwnerLocations where location.window === source {
            guard let owner = preparedOversightWindows[id], owner !== source else { continue }
            let detached = SavedOversightSessionLocation(
                window: owner,
                workspace: location.workspace,
                tab: location.tab,
                stashedTabID: location.stashedTabID,
                entry: location.entry
            )
            preparedOversightOwnerLocations[id] = detached
            preparedOversightLocations[id] = detached
            preparedOversightCarrierSubscriptions.removeValue(forKey: id)
        }
    }

    func beginPreparedOversightPreparation(_ id: UUID) {
        preparedOversightPreparationInFlight[id, default: 0] += 1
    }

    func endPreparedOversightPreparation(_ id: UUID) {
        let count = preparedOversightPreparationInFlight[id, default: 0]
        if count <= 1 {
            preparedOversightPreparationInFlight.removeValue(forKey: id)
            schedulePreparedOversightCleanup()
        } else { preparedOversightPreparationInFlight[id] = count - 1 }
    }

    enum SavedOversightPreparationFailure: String, Error {
        case missing = "target_missing"
        case ambiguous = "target_ambiguous"
        case changed = "target_binding_changed"
        case unreadable = "target_saved_state_unreadable"
    }

    /// Point reads of one UUID in known workspace locations. No folder enumeration, provider
    /// reconnect, UI activation or unrelated session hydration is performed.
    func resolveSavedOversightLocation(_ target: UUID) async -> Result<SavedOversightSessionLocation, SavedOversightPreparationFailure> {
        let deletion = AgentSessionDeletionRegistry.shared
        guard !deletion.isPermanentlyDeleted(sessionID: target), !deletion.isDeletionInProgress(sessionID: target) else { return .failure(.missing) }
        let windows = allWindows.filter { !$0.isClosing }
        let census = AgentSessionCarrierResolver.capture(windows: windows, sessionIDs: [target])
        guard !census.ambiguousSessionIDs.contains(target), !census.replicatedSessionIDs.contains(target) else { return .failure(.ambiguous) }
        if let location = preparedOversightOwnerLocations[target], location.isCurrent,
           let owner = preparedOversightWindows[target], !owner.isClosing,
           census.uniqueLocations[target]?.window === owner
        {
            // The exact runtime remains authoritative after its original UI window closes.
            // Resolve its existing binding, not a nonexistent UI carrier or a second owner.
            preparedOversightLocations[target] = location
            return .success(location)
        }
        var owners: [UUID: (WindowState, WorkspaceModel)] = [:]
        for window in windows {
            for workspace in window.workspaceManager.workspaces {
                if owners[workspace.id] == nil || window.workspaceManager.activeWorkspaceID == workspace.id {
                    owners[workspace.id] = (window, workspace)
                }
            }
        }
        let matches = agentSessionLinkCandidates(forSessionIDs: [target], includeLocation: false)[target] ?? []
        let live = matches.count == 1 ? matches.first : nil
        var found: SavedOversightSessionLocation?
        for (_, (window, workspace)) in owners {
            let entry: AgentSessionIndexEntry?
            do {
                if let live, live.workspaceID == workspace.id, live.restorationReadiness.isAuthoritative,
                   let current = census.metadata[target]?.first(where: { $0.workspaceID == workspace.id })?.entry
                {
                    // A current authoritative runtime remains usable when saving is unavailable.
                    // Disk is continuity for a cold owner, not a veto over known live state.
                    entry = current
                } else if let record = try await AgentSessionDataService.shared.metadataRecordForSessionID(target, for: workspace) {
                    guard record.id == target, record.workspaceID == nil || record.workspaceID == workspace.id else { return .failure(.ambiguous) }
                    entry = record.sidebarEntry()
                } else {
                    entry = census.metadata[target]?.first(where: { $0.workspaceID == workspace.id })?.entry
                }
            } catch { return .failure(.unreadable) }
            guard let entry else { continue }
            let tabs = workspace.composeTabs.filter { $0.id == entry.tabID }
            let stashes = workspace.stashedTabs.filter { $0.tab.id == entry.tabID }
            guard tabs.count + stashes.count == 1 else {
                return .failure(tabs.isEmpty && stashes.isEmpty ? .missing : .ambiguous)
            }
            let location = SavedOversightSessionLocation(
                window: window, workspace: workspace, tab: tabs.first ?? stashes[0].tab,
                stashedTabID: stashes.first?.id, entry: entry
            )
            guard location.isCurrent, !deletion.isPermanentlyDeleted(sessionID: target), !deletion.isDeletionInProgress(sessionID: target) else { return .failure(.changed) }
            guard found == nil else { return .failure(.ambiguous) }
            found = location
        }
        guard let found else { return .failure(.missing) }
        // Metadata is not authority. Bound the pre-card cache; live owners remain separately held.
        if preparedOversightLocations.count >= 128, preparedOversightLocations[target] == nil {
            preparedOversightLocations = preparedOversightLocations.filter { preparedOversightWindows[$0.key] != nil }
        }
        preparedOversightLocations[target] = found
        return .success(found)
    }

    func prepareSavedOversightTarget(
        _ target: UUID, isStillAuthorized: @escaping @MainActor () -> Bool
    ) async -> Result<WindowState, SavedOversightPreparationFailure> {
        guard isStillAuthorized(), !Task.isCancelled, !preparedOversightUIVisits.contains(target) else { return .failure(.changed) }
        let resolution = await resolveSavedOversightLocation(target)
        guard case let .success(location) = resolution else {
            if case let .failure(reason) = resolution { return .failure(reason) }
            return .failure(.missing)
        }
        guard isStillAuthorized(), location.isCurrent, let source = location.window else { return .failure(.changed) }
        if preparedOversightWindows[target] != nil,
           preparedOversightOwnerLocations[target]?.isCurrent != true
           || preparedOversightOwnerLocations[target]?.agreesOnCarrierAndProvenance(with: location) != true
        {
            guard await releasePreparedOversightOwnerForVisit(sessionID: target, preparingReplacement: true) else { return .failure(.changed) }
        }
        let owner: WindowState
        if let existing = preparedOversightWindows[target], !existing.isClosing {
            owner = existing
        } else if location.stashedTabID == nil, source.workspaceManager.activeWorkspaceID == location.workspace.id,
                  location.tab.activeAgentSessionID == nil || location.tab.activeAgentSessionID == target
        {
            owner = source
        } else {
            #if DEBUG
                owner = test_preparedOversightOwnerFactory?(location.runtimeWorkspace, source)
                    ?? WindowState.makePreparedSessionOwner(workspace: location.runtimeWorkspace, borrowing: source)
            #else
                owner = WindowState.makePreparedSessionOwner(workspace: location.runtimeWorkspace, borrowing: source)
            #endif
            preparedOversightWindows[target] = owner
            preparedOversightOwnerLocations[target] = location
            preparedOversightCarrierSubscriptions[target] = source.workspaceManager.$workspaces
                .dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.schedulePreparedOversightCleanup() }
        }
        let ready = await owner.agentModeViewModel.prepareSavedOversightSession(
            tabID: location.tab.id, sessionID: target, workspaceID: location.workspace.id,
            isStillAuthorized: { isStillAuthorized() && location.isCurrent }
        )
        guard isStillAuthorized(), location.isCurrent else { return .failure(.changed) }
        guard ready else { return .failure(.unreadable) }
        if preparedOversightWindows[target] != nil, preparedOversightRunObservations[target] == nil,
           let candidate = owner.agentModeViewModel.agentSessionLinkCandidates(isWindowClosing: false, includeLocation: false).first(where: { $0.sessionID == target })
        {
            preparedOversightRunObservations[target] = owner.agentModeViewModel.agentSessionLinkInstallObservation(for: candidate) { [weak self] in
                self?.schedulePreparedOversightCleanup()
            }
        }
        return .success(owner)
    }

    /// A UI visit may take over an idle saved runtime, but never creates a second writer or
    /// cancels an accepted managed task. Active ownership is the ordinary binding-transition block.
    func releasePreparedOversightOwnerForVisit(sessionID: UUID, preparingReplacement: Bool = false) async -> Bool {
        guard let owner = preparedOversightWindows[sessionID] else { return true }
        guard preparedOversightPreparationInFlight[sessionID, default: 0] <= (preparingReplacement ? 1 : 0),
              owner.agentModeViewModel.sessions.values.allSatisfy({ !$0.runState.isActive }),
              await !(AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)) else { return false }
        beginPreparedOversightPreparation(sessionID)
        preparedOversightHandoffs.insert(sessionID)
        defer {
            endPreparedOversightPreparation(sessionID)
            preparedOversightHandoffs.remove(sessionID)
        }
        guard await owner.agentModeViewModel.settlePreparedOversightHandoff() else { return false }
        // Withdraw and capture the old exact endpoint before yielding to its final save. This parks
        // the durable link for re-establishment at the newly visited binding, rather than relinking.
        owner.beginClose()
        await owner.tearDownPreparedSessionOwner()
        if preparedOversightWindows[sessionID] === owner {
            preparedOversightWindows.removeValue(forKey: sessionID)
            preparedOversightOwnerLocations.removeValue(forKey: sessionID)
            preparedOversightCarrierSubscriptions.removeValue(forKey: sessionID)
            preparedOversightConsentPairs.removeValue(forKey: sessionID)
            preparedOversightRunObservations.removeValue(forKey: sessionID)?.invalidate()
        }
        return true
    }

    /// Event-driven lifetime, not a polling timer or an independent link authority. The bridge's
    /// committed live links retain an owner; a saved intent alone does not keep a revoked run alive.
    func schedulePreparedOversightCleanup() {
        guard !isTerminating, !preparedOversightWindows.isEmpty else { return }
        preparedOversightCleanupDirty = true
        guard preparedOversightCleanupTask == nil else { return }
        preparedOversightCleanupTask = Task { @MainActor [weak self] in
            defer { self?.preparedOversightCleanupTask = nil }
            while let self, preparedOversightCleanupDirty, !isTerminating, !Task.isCancelled {
                preparedOversightCleanupDirty = false
                let bridge = AgentSessionLinkRuntimeBridge.shared
                let inventory = await bridge.oversightInventory(includeLocation: false)
                let consent = bridge.delegationScopes.linkConsent
                let retained = Set(inventory.live.filter { item in
                    item.sourceScopeID.map {
                        consent.permits(scopeID: $0, observer: item.observerSessionID, target: item.targetSessionID, at: Date())
                    } ?? true
                }.flatMap { [$0.observerSessionID, $0.targetSessionID] })
                for id in Array(preparedOversightWindows.keys) where preparedOversightPreparationInFlight[id] == nil {
                    guard let owner = preparedOversightWindows[id] else { continue }
                    let deleted = AgentSessionDeletionRegistry.shared.isPermanentlyDeleted(sessionID: id)
                        || AgentSessionDeletionRegistry.shared.isDeletionInProgress(sessionID: id)
                    let pairs = inventory.persisted.filter { $0.targetSessionID == id }
                    for pair in pairs {
                        preparedOversightConsentPairs[id, default: []].update(with: pair)
                    }
                    let knownPairs = preparedOversightConsentPairs[id] ?? []
                    let revoked = !knownPairs.isEmpty && knownPairs.allSatisfy { pair in
                        pair.sourceScopeID.map { !consent.permits(scopeID: $0, observer: pair.observerSessionID, target: id, at: Date()) } ?? false
                    }
                    if deleted || revoked {
                        let visit = preparedOversightPendingVisits.removeValue(forKey: id)
                        await retirePreparedOversightOwner(sessionID: id, preservingIntent: false)
                        // Revocation cancels managed authority, not the user's own pending UI
                        // visit. A deleted target, in contrast, must never be hydrated again.
                        if !deleted { await visit?() }
                        continue
                    }
                    // UI placement is not authority. Refresh the witness without replacing the
                    // running owner, cancelling its provider, or dropping the durable link.
                    if preparedOversightOwnerLocations[id]?.isCurrent != true,
                       case let .success(location) = await resolveSavedOversightLocation(id),
                       preparedOversightOwnerLocations[id]?.agreesOnCarrierAndProvenance(with: location) == true
                    {
                        preparedOversightOwnerLocations[id] = location
                    }
                    guard owner.agentModeViewModel.sessions.values.allSatisfy({ !$0.runState.isActive }),
                          await !AgentRunSessionStore.hasActiveRegistration(sessionID: id) else { continue }
                    if let visit = preparedOversightPendingVisits.removeValue(forKey: id) {
                        await visit()
                    } else if !retained.contains(id), pairs.isEmpty {
                        await retirePreparedOversightOwner(sessionID: id, preservingIntent: true)
                    }
                }
            }
        }
    }

    private func retirePreparedOversightOwner(sessionID: UUID, preservingIntent: Bool) async {
        guard let owner = preparedOversightWindows.removeValue(forKey: sessionID) else { return }
        preparedOversightOwnerLocations.removeValue(forKey: sessionID)
        preparedOversightCarrierSubscriptions.removeValue(forKey: sessionID)
        preparedOversightConsentPairs.removeValue(forKey: sessionID)
        preparedOversightRunObservations.removeValue(forKey: sessionID)?.invalidate()
        retiringPreparedOversightWindows[sessionID] = owner
        defer { retiringPreparedOversightWindows.removeValue(forKey: sessionID) }
        owner.beginClose(preservingOversightIntent: preservingIntent)
        if !isTerminating {
            await AgentSessionLinkRuntimeBridge.shared.invalidateWindow(owner.windowID, reason: .windowClosed)
        }
        if await !owner.tearDownPreparedSessionOwner(), !AgentSessionDeletionRegistry.shared.isPermanentlyDeleted(sessionID: sessionID) {
            AgentSessionLinkRuntimeBridge.shared.launchCoordinatorReportWarning(
                id: "prepared-runtime-unsettled",
                message: "A retired background managed session could not finish saving. Its final write was not acknowledged as durable. Check storage before relying on restart continuity."
            )
        }
    }

    /// Quit joins nonvisual owners under one absolute budget, independent of filesystem/provider
    /// cooperation. A deadline is reported as unsettled, never as a completed save or teardown.
    func shutdownPreparedOversightOwners(timeout: TimeInterval = 2) async -> Bool {
        preparedOversightCleanupTask?.cancel()
        let owners = Array(preparedOversightWindows.values) + Array(retiringPreparedOversightWindows.values)
        preparedOversightWindows.removeAll()
        preparedOversightOwnerLocations.removeAll()
        preparedOversightCarrierSubscriptions.removeAll()
        preparedOversightConsentPairs.removeAll()
        preparedOversightRunObservations.values.forEach { $0.invalidate() }
        preparedOversightRunObservations.removeAll()
        preparedOversightPendingVisits.removeAll()
        preparedOversightUIVisits.removeAll()
        for owner in owners {
            owner.beginClose()
        }
        guard !owners.isEmpty else { return true }
        var timer: Task<Void, Never>?
        let completed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let gate = PreparedOversightShutdownGate(continuation)
            timer = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(max(0, timeout))) } catch { return }
                gate.finish(false)
            }
            Task { @MainActor in
                let settled = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
                    for owner in owners {
                        group.addTask { @MainActor in await owner.tearDownPreparedSessionOwner() }
                    }
                    var saved = true
                    for await result in group {
                        saved = saved && result
                    }
                    return saved
                }
                gate.finish(settled)
            }
        }
        timer?.cancel()
        preparedOversightCleanupTask = nil
        if !completed {
            AgentSessionLinkRuntimeBridge.shared.launchCoordinatorReportWarning(
                id: "prepared-runtime-quit-unsettled",
                message: "Background managed session saving or teardown did not settle within the quit budget. Completion was not acknowledged."
            )
        }
        return completed
    }

    private final class PreparedOversightShutdownGate {
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func finish(_ value: Bool) {
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(returning: value)
        }
    }

    func agentSessionLinkCandidates(includeLocation: Bool) -> [AgentSessionLinkEndpointCandidate] {
        #if DEBUG
            if AgentSessionLinkCatalogReadProbe.enabled {
                AgentSessionLinkCatalogReadProbe.record(0)
                if includeLocation { AgentSessionLinkCatalogReadProbe.record(1) }
            }
        #endif
        guard !isTerminating else { return [] }
        var candidates: [AgentSessionLinkEndpointCandidate] = []
        for window in sessionRuntimeWindows where !window.isClosing {
            guard modelRoutingWindow(withID: window.windowID) === window else { continue }
            candidates.append(
                contentsOf: window.agentModeViewModel.agentSessionLinkCandidates(isWindowClosing: false, includeLocation: includeLocation)
            )
        }
        return candidates
    }

    func agentSessionLinkPublishCreatorNames(_ names: [UUID: String]) {
        for window in sessionRuntimeWindows where !window.isClosing {
            window.agentModeViewModel.agentSessionLinkPublishCreatorNames(names)
        }
    }

    func agentSessionLinkSheetWindow(windowID: Int) -> NSWindow? {
        allWindows.first(where: { $0.windowID == windowID })?.nsWindow
    }

    func agentSessionLinkCandidate(
        for endpoint: DomainAgentSessionLinkEndpointIdentity, includeLocation: Bool
    ) -> AgentSessionLinkEndpointCandidate? {
        guard let window = modelRoutingWindow(withID: endpoint.windowID) else { return nil }
        #if DEBUG
            if AgentSessionLinkCatalogReadProbe.enabled, includeLocation { AgentSessionLinkCatalogReadProbe.record(1) }
        #endif
        return window.agentModeViewModel.agentSessionLinkCandidate(for: endpoint, includeLocation: includeLocation)
    }

    func agentSessionLinkCandidates(
        forSessionIDs sessionIDs: Set<UUID>, includeLocation: Bool
    ) -> [UUID: [AgentSessionLinkEndpointCandidate]] {
        #if DEBUG
            if AgentSessionLinkCatalogReadProbe.enabled {
                AgentSessionLinkCatalogReadProbe.record(0)
                if includeLocation { AgentSessionLinkCatalogReadProbe.record(1) }
            }
        #endif
        var result = Dictionary(uniqueKeysWithValues: sessionIDs.map { ($0, [AgentSessionLinkEndpointCandidate]()) })
        guard !isTerminating else { return result }
        for window in sessionRuntimeWindows where !window.isClosing {
            guard modelRoutingWindow(withID: window.windowID) === window else { continue }
            let local = window.agentModeViewModel.agentSessionLinkCandidates(
                forSessionIDs: sessionIDs, includeLocation: includeLocation
            )
            for sessionID in sessionIDs {
                result[sessionID, default: []] += local[sessionID] ?? []
            }
        }
        return result
    }

    func agentSessionLinkRunFacts(
        for candidate: AgentSessionLinkEndpointCandidate, capturedStatus: DomainAgentSessionLinkStatus
    ) -> AgentRunQuietFacts? {
        guard !isTerminating, let window = modelRoutingWindow(withID: candidate.windowID), !window.isClosing else { return nil }
        return window.agentModeViewModel.agentSessionLinkRunFacts(for: candidate, capturedStatus: capturedStatus)
    }

    func agentSessionLinkObservationSnapshot(
        for candidate: AgentSessionLinkEndpointCandidate
    ) -> DomainAgentSessionObservationSnapshot {
        guard let window = window(withID: candidate.windowID) else {
            return DomainAgentSessionObservationSnapshot(
                sessionID: candidate.sessionID,
                displayName: candidate.displayName,
                providerDisplayName: candidate.providerDisplayName,
                status: .idle,
                board: DomainAgentSessionLaneBoard(
                    runOutcome: .none,
                    failureReason: nil,
                    sendBlockers: [AgentModeViewModel.SendBlocker.sessionUnavailable.rawValue],
                    subagentRunning: 0,
                    subagentFinished: 0
                ),
                idleForSend: false,
                pendingInteractionKind: nil,
                latestVisibleAssistantPreview: nil,
                visibleRowCount: 0,
                lastActivityAt: Date()
            )
        }
        return window.agentModeViewModel.agentSessionLinkObservationSnapshot(for: candidate)
    }

    func agentSessionLinkRefreshSubagentCensus(
        for candidates: [AgentSessionLinkEndpointCandidate]
    ) async {
        #if DEBUG
            if AgentSessionLinkCatalogReadProbe.enabled { AgentSessionLinkCatalogReadProbe.record(3) }
        #endif
        guard !isTerminating else { return }
        // One metadata load per workspace/window in a multi-target poll or wait. Never activate a
        // workspace or switch focus just to observe it.
        var refreshed: Set<String> = []
        for candidate in candidates {
            guard let window = window(withID: candidate.windowID),
                  !window.isClosing,
                  let workspace = window.workspaceManager.activeWorkspace,
                  workspace.id == candidate.workspaceID
            else { continue }
            let key = "\(candidate.windowID):\(workspace.id.uuidString)"
            guard refreshed.insert(key).inserted else { continue }
            await window.agentModeViewModel.agentSessionLinkRefreshSubagentCensus(for: workspace)
        }
    }

    func agentSessionLinkForgetDeletedSubagent(_ sessionID: UUID) {
        guard !isTerminating else { return }
        for window in sessionRuntimeWindows where !window.isClosing {
            window.agentModeViewModel.agentSessionLinkForgetDeletedSubagent(sessionID)
        }
    }

    func agentSessionLinkStatusProjection(
        for candidate: AgentSessionLinkEndpointCandidate
    ) -> AgentSessionLinkStatusProjection? {
        guard let window = window(withID: candidate.windowID) else { return nil }
        return window.agentModeViewModel.agentSessionLinkStatusProjection(for: candidate)
    }

    func agentSessionLinkAutoWakeOnUpdatesEnabled(
        for candidate: AgentSessionLinkEndpointCandidate
    ) -> Bool {
        guard let window = window(withID: candidate.windowID) else { return false }
        return window.agentModeViewModel.agentSessionLinkAutoWakeOnUpdatesEnabled(for: candidate)
    }

    func agentSessionLinkAutoWakeTargetSessionIDs(
        for candidate: AgentSessionLinkEndpointCandidate
    ) -> Set<UUID> {
        guard let window = window(withID: candidate.windowID) else { return [] }
        return window.agentModeViewModel.agentSessionLinkAutoWakeTargetSessionIDs(for: candidate)
    }

    @discardableResult
    func agentSessionLinkSetAutoWakeOnUpdatesEnabled(
        _ enabled: Bool,
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> Bool {
        guard let viewModel = agentSessionLinkOwningViewModel(for: endpoint) else { return false }
        return viewModel.agentSessionLinkSetAutoWakeOnUpdatesEnabled(enabled, for: endpoint)
    }

    @discardableResult
    func agentSessionLinkSetAutoWakeTargetSessionIDs(
        _ targetSessionIDs: Set<UUID>,
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> Bool {
        guard let viewModel = agentSessionLinkOwningViewModel(for: endpoint) else { return false }
        return viewModel.agentSessionLinkSetAutoWakeTargetSessionIDs(targetSessionIDs, for: endpoint)
    }

    @discardableResult
    func agentSessionLinkSetRoutineWakeInterval(
        enabled: Bool,
        seconds: Int,
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> Bool {
        guard let viewModel = agentSessionLinkOwningViewModel(for: endpoint) else { return false }
        return viewModel.agentSessionLinkSetRoutineWakeInterval(
            enabled: enabled,
            seconds: seconds,
            for: endpoint
        )
    }

    @discardableResult
    func agentSessionLinkSetPeriodicIdleWake(
        enabled: Bool,
        seconds: Int,
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> Bool {
        guard let viewModel = agentSessionLinkOwningViewModel(for: endpoint) else { return false }
        return viewModel.agentSessionLinkSetPeriodicIdleWake(
            enabled: enabled,
            seconds: seconds,
            for: endpoint
        )
    }

    /// Routes one `Wake now` request to the view model that *is* this exact incarnation.
    ///
    /// Same addressing rule as the policy writes above: a superseded incarnation must not have a turn
    /// reserved on the live one that replaced it.
    @discardableResult
    func agentSessionLinkRequestManualWakeNow(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> AgentMonitorWakeNowOutcome {
        guard let viewModel = agentSessionLinkOwningViewModel(for: endpoint) else {
            return .refused(.observerUnavailable)
        }
        return viewModel.agentSessionLinkRequestManualWakeNow(for: endpoint)
    }

    @discardableResult
    func agentSessionLinkSetWaitingOn(
        _ waitingOn: DomainAgentSessionWaitingOn?,
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> Bool {
        guard let viewModel = agentSessionLinkOwningViewModel(for: endpoint) else { return false }
        return viewModel.agentSessionLinkSetWaitingOn(waitingOn, for: endpoint)
    }

    /// Routes one pure Auto-wake snooze read to the view model that *is* this exact incarnation.
    ///
    /// Addressed exactly like every other endpoint-scoped call here: a session UUID is not an address,
    /// and an in-place rebind keeps that UUID while advancing the binding generations. A retired or
    /// replaced endpoint therefore fails closed rather than reading a namesake's policy.
    func agentSessionLinkAutoWakeSnoozeProjection(
        for endpoint: DomainAgentSessionLinkEndpointIdentity,
        targetSessionID: UUID,
        expectedReference: DomainAgentSessionLinkReference
    ) -> Result<AgentSessionLinkAutoWakeSnoozeProjection?, AgentSessionLinkAutoWakeSnoozeFailure> {
        guard let viewModel = agentSessionLinkOwningViewModel(for: endpoint) else {
            return .failure(.observerUnavailable)
        }
        return viewModel.agentSessionLinkAutoWakeSnoozeProjection(
            endpoint: endpoint,
            targetSessionID: targetSessionID,
            expectedReference: expectedReference
        )
    }

    /// Routes one Auto-wake snooze mutation to the view model that *is* this exact incarnation.
    ///
    /// The same-session-UUID replacement case is the one this exists to refuse: a stale monitor row or
    /// a late MCP call naming a superseded incarnation must not install or clear policy on the live
    /// one.
    func agentSessionLinkMutateAutoWakeSnooze(
        for endpoint: DomainAgentSessionLinkEndpointIdentity,
        targetSessionID: UUID,
        expectedReference: DomainAgentSessionLinkReference,
        command: AgentSessionLinkAutoWakeSnoozeCommand,
        origin: AgentSessionLinkAutoWakeSnoozeOrigin
    ) -> Result<AgentSessionLinkAutoWakeSnoozeMutationOutcome, AgentSessionLinkAutoWakeSnoozeFailure> {
        guard let viewModel = agentSessionLinkOwningViewModel(for: endpoint) else {
            return .failure(.observerUnavailable)
        }
        return viewModel.agentSessionLinkMutateAutoWakeSnooze(
            endpoint: endpoint,
            targetSessionID: targetSessionID,
            expectedReference: expectedReference,
            command: command,
            origin: origin
        )
    }

    func agentSessionLinkInstallObservation(
        for candidate: AgentSessionLinkEndpointCandidate,
        onChange: @escaping @MainActor () -> Void
    ) -> AgentSessionLinkObservationToken? {
        guard let window = window(withID: candidate.windowID), !window.isClosing else { return nil }
        return window.agentModeViewModel.agentSessionLinkInstallObservation(
            for: candidate,
            onChange: onChange
        )
    }

    /// Routes an Oversee projection to the one window/tab that *is* this endpoint incarnation.
    ///
    /// Previously this fanned out to every non-closing window holding a session with the same UUID.
    /// Duplicate live incarnations are explicitly modelled (the resolver refuses them as
    /// `.ambiguous`), so that fan-out handed an unauthorized incarnation the granted incarnation's
    /// rows, notices, and — through the prompt inventory — its agent-facing oversight supplement.
    func agentSessionLinkPublishProjection(
        _ props: AgentMonitorPillProps,
        to endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        guard let viewModel = agentSessionLinkOwningViewModel(for: endpoint) else { return }
        viewModel.agentSessionLinkPublishProjection(props, to: endpoint)
        if props.inbound.isEmpty, props.outbound.isEmpty { schedulePreparedOversightCleanup() }
    }

    func agentSessionLinkPublishPromptInventory(
        _ inventory: AgentSessionLinkPromptInventory,
        to endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        guard let viewModel = agentSessionLinkOwningViewModel(for: endpoint) else { return }
        viewModel.agentSessionLinkPublishPromptInventory(inventory, to: endpoint)
    }

    func agentSessionLinkPublishRunCatalogProjection(
        _ projection: AgentSessionLinkRunCatalogProjection
    ) {
        guard let endpoint = projection.routeToken?.observerEndpoint,
              let viewModel = agentSessionLinkOwningViewModel(for: endpoint)
        else { return }
        viewModel.agentSessionLinkPublishRunCatalogProjection(projection, to: endpoint)
    }

    /// Routes one passive status-notice queue to the exact incarnation it was reduced for.
    ///
    /// Addressed like every other publication here: a session UUID is not an address, and a queue
    /// handed to a namesake incarnation would let it claim notices about targets it never observed.
    func agentSessionLinkPublishPassiveStatusNotices(
        _ snapshot: AgentSessionLinkPassiveStatusNotices.Snapshot,
        to endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        guard let viewModel = agentSessionLinkOwningViewModel(for: endpoint) else { return }
        viewModel.agentSessionLinkPublishPassiveStatusNotices(snapshot, to: endpoint)
    }

    func agentSessionLinkWillActivate(_ endpoint: DomainAgentSessionLinkEndpointIdentity) async {
        guard let viewModel = agentSessionLinkOwningViewModel(for: endpoint) else { return }
        await viewModel.agentSessionLinkWillActivate(endpoint)
    }

    func agentSessionLinkWithholdPromptInventory(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> UInt64? {
        guard let viewModel = agentSessionLinkOwningViewModel(for: endpoint) else { return nil }
        return viewModel.agentSessionLinkWithholdPromptInventory(for: endpoint)
    }

    func agentSessionLinkReleasePromptInventoryHold(
        _ token: UInt64?,
        for endpoint: DomainAgentSessionLinkEndpointIdentity,
        publishing inventory: AgentSessionLinkPromptInventory?
    ) {
        guard let viewModel = agentSessionLinkOwningViewModel(for: endpoint) else { return }
        viewModel.agentSessionLinkReleasePromptInventoryHold(
            token,
            for: endpoint,
            publishing: inventory
        )
    }

    /// The view model that currently owns this exact endpoint incarnation, or `nil`.
    private func agentSessionLinkOwningViewModel(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> AgentModeViewModel? {
        guard !isTerminating,
              let window = window(withID: endpoint.windowID),
              !window.isClosing
        else {
            return nil
        }
        let viewModel = window.agentModeViewModel
        // Full incarnation match, not `(tabID, sessionID)`: an in-place rebind keeps both while
        // advancing the binding generations.
        guard viewModel.agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint else {
            return nil
        }
        return viewModel
    }

    func agentSessionLinkTranscriptPage(
        for candidate: AgentSessionLinkEndpointCandidate,
        anchor: AgentSessionLinkTranscriptAnchor?,
        direction: AgentSessionLinkReadDirectionInput,
        maxItems: Int,
        maxOutputBytes: Int,
        readerSessionID: UUID?
    ) async -> Result<AgentSessionLinkTranscriptPage, AgentSessionLinkReadUnavailableReason> {
        guard let window = window(withID: candidate.windowID), !window.isClosing else {
            return .failure(.endpointInvalidated)
        }
        return await window.agentModeViewModel.agentSessionLinkTranscriptPage(
            for: candidate,
            anchor: anchor,
            direction: direction,
            maxItems: maxItems,
            maxOutputBytes: maxOutputBytes,
            readerSessionID: readerSessionID
        )
    }

    /// Cross-window liveness for one send, answered in a single synchronous MainActor pass.
    ///
    /// The transaction itself runs on the target window's `AgentModeViewModel`, which cannot see the
    /// observer's window or its own window's teardown flag. Both facts are read here, from the same
    /// candidate snapshot, so the two fences the transaction crosses compare like with like. Nothing
    /// here focuses, activates, or switches a window.
    func agentSessionLinkSendLiveness(
        observer: DomainAgentSessionLinkEndpointIdentity,
        target: DomainAgentSessionLinkEndpointIdentity
    ) -> AgentSessionLinkSendLiveness {
        guard !isTerminating else { return .unavailable }
        // Resolved independently of the candidate sweep: a window with no eligible candidates is not
        // the same thing as a window that is tearing down.
        let targetWindow = window(withID: target.windowID)
        let targetWindowIsClosing = targetWindow.map(\.isClosing) ?? true
        let live = agentSessionLinkCandidates()
        return AgentSessionLinkSendLiveness(
            observerEndpointIsLive: live.contains { $0.domainEndpoint == observer },
            targetEndpointIsLive: live.contains { $0.domainEndpoint == target },
            targetWindowIsClosing: targetWindowIsClosing
        )
    }

    /// Routes the send transaction to the exact owning window.
    ///
    /// Window liveness is re-checked here rather than trusted from the candidate: the whole
    /// transaction runs on that window's `AgentModeViewModel`, and a terminating manager or closing
    /// window must refuse before any target state is touched. Nothing here focuses or activates the
    /// window.
    func agentSessionLinkStartStopFence(for candidate: AgentSessionLinkEndpointCandidate) -> AgentRunStartStopFence? {
        guard !isTerminating,
              let window = window(withID: candidate.windowID), !window.isClosing,
              let session = window.agentModeViewModel.agentSessionLinkLiveSession(matching: candidate)
        else { return nil }
        return AgentRunStartStopFence(session: session)
    }

    func agentSessionLinkPerformSend(
        to candidate: AgentSessionLinkEndpointCandidate,
        request: AgentSessionLinkSendRequest,
        liveness: @escaping AgentSessionLinkSendLivenessProbe,
        commitAuthorization: @MainActor () async -> AgentSessionLinkSendCommitOutcome
    ) async -> AgentSessionLinkSendTransactionOutcome {
        guard !isTerminating else { return .blocked(.shuttingDown) }
        guard let window = window(withID: candidate.windowID), !window.isClosing else {
            return .blocked(.endpointHost)
        }
        return await window.agentModeViewModel.agentSessionLinkPerformSend(
            to: candidate,
            request: request,
            liveness: liveness,
            commitAuthorization: commitAuthorization
        )
    }

    // MARK: - Management delegation

    func agentSessionLinkModelAvailability(windowID: Int) -> AgentModelCatalog.AvailabilityContext {
        #if DEBUG
            if AgentSessionLinkCatalogReadProbe.enabled { AgentSessionLinkCatalogReadProbe.record(2) }
        #endif
        guard let window = modelRoutingWindow(withID: windowID) else { return .none }
        return window.apiSettingsViewModel.agentAvailability
    }

    func agentSessionLinkLocalInputSnapshot(for endpoint: DomainAgentSessionLinkEndpointIdentity, includeRecords: Bool) -> AgentSessionLinkRetainedLocalInputIndex.Snapshot? {
        guard !isTerminating, let window = modelRoutingWindow(withID: endpoint.windowID), !window.isClosing else { return nil }
        return window.agentModeViewModel.agentSessionLinkLocalInputSnapshot(for: endpoint, includeRecords: includeRecords)
    }

    func agentSessionLinkModelCandidate(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> AgentSessionLinkEndpointCandidate? {
        guard let window = modelRoutingWindow(withID: endpoint.windowID) else { return nil }
        return window.agentModeViewModel.agentSessionLinkModelCandidate(for: endpoint)
    }

    func agentSessionLinkBootstrapState(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> AgentSessionOverseerBootstrapState? {
        guard !isTerminating, let window = modelRoutingWindow(withID: endpoint.windowID), !window.isClosing else { return nil }
        return window.agentModeViewModel.agentSessionLinkBootstrapState(for: endpoint)
    }

    func agentSessionLinkBootstrapRefusal(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> AgentSessionOverseerBootstrapRefusal? {
        guard !isTerminating else { return .terminating }
        guard let window = modelRoutingWindow(withID: endpoint.windowID), !window.isClosing else { return .notLoaded }
        return window.agentModeViewModel.agentSessionLinkBootstrapRefusal(for: endpoint)
    }

    func agentSessionLinkActivateOverseer(
        for endpoint: DomainAgentSessionLinkEndpointIdentity, expected: AgentSessionOverseerBootstrapState
    ) -> Bool {
        guard !isTerminating, let window = modelRoutingWindow(withID: endpoint.windowID), !window.isClosing else { return false }
        return window.agentModeViewModel.agentSessionLinkActivateOverseer(for: endpoint, expected: expected)
    }

    func agentSessionLinkPerformSetModel(
        to candidate: AgentSessionLinkEndpointCandidate,
        modelID: String,
        liveness: @escaping AgentSessionLinkSendLivenessProbe,
        reauthorize: @MainActor () async -> AgentSessionLinkSendCommitOutcome
    ) async -> AgentSessionLinkModelOutcome {
        guard !isTerminating else { return .blocked(.shuttingDown) }
        guard let window = modelRoutingWindow(withID: candidate.windowID) else {
            return .blocked(.endpointHost)
        }
        return await window.agentModeViewModel.agentSessionLinkPerformSetModel(
            to: candidate, modelID: modelID, liveness: liveness,
            availability: { window.apiSettingsViewModel.agentAvailability }, reauthorize: reauthorize
        )
    }

    /// Routes one managed steer to the exact owning window, refusing during teardown before any
    /// target state is touched. Nothing here focuses or activates the window.
    func agentSessionLinkPerformSteer(
        to candidate: AgentSessionLinkEndpointCandidate,
        request: AgentSessionLinkSendRequest,
        liveness: @escaping AgentSessionLinkSendLivenessProbe,
        commitAuthorization: @MainActor () async -> AgentSessionLinkSendCommitOutcome
    ) async -> AgentSessionLinkSendTransactionOutcome {
        guard !isTerminating else { return .blocked(.shuttingDown) }
        guard let window = window(withID: candidate.windowID), !window.isClosing else {
            return .blocked(.endpointHost)
        }
        return await window.agentModeViewModel.agentSessionLinkPerformSteer(
            to: candidate,
            request: request,
            liveness: liveness,
            commitAuthorization: commitAuthorization
        )
    }

    /// Routes Stop without focusing or activating the target window.
    func agentSessionLinkPerformStop(
        to candidate: AgentSessionLinkEndpointCandidate,
        request: AgentSessionLinkStopRequest,
        liveness: @escaping AgentSessionLinkSendLivenessProbe,
        queueHasCommittedDrain: @escaping @MainActor () -> Bool,
        withdrawInbound: @escaping @MainActor () -> Bool,
        commitAuthorization: @MainActor () async -> AgentSessionLinkSendCommitOutcome
    ) async -> AgentSessionLinkStopTransactionOutcome {
        guard !isTerminating else { return .blocked(.shuttingDown) }
        guard let window = window(withID: candidate.windowID), !window.isClosing else {
            return .blocked(.endpointHost)
        }
        return await window.agentModeViewModel.agentSessionLinkPerformStop(
            to: candidate,
            request: request,
            liveness: liveness,
            queueHasCommittedDrain: queueHasCommittedDrain,
            withdrawInbound: withdrawInbound,
            commitAuthorization: commitAuthorization
        )
    }

    /// Routes a read-only interaction inspection to the exact owning window. Never focuses it.
    func agentSessionLinkPendingInteraction(
        for candidate: AgentSessionLinkEndpointCandidate
    ) -> AgentSessionLinkPendingInteractionInspection {
        guard !isTerminating,
              let window = window(withID: candidate.windowID),
              !window.isClosing
        else { return .none }
        return window.agentModeViewModel.agentSessionLinkPendingInteraction(for: candidate)
    }

    /// Routes one observer answer to the exact owning window, refusing during teardown.
    func agentSessionLinkRespondToPendingInteraction(
        for candidate: AgentSessionLinkEndpointCandidate,
        request: AgentSessionLinkInteractionResponseRequest,
        authorize: @escaping @MainActor @Sendable () async -> Bool
    ) async -> AgentSessionLinkInteractionResponseOutcome {
        guard !isTerminating,
              let window = window(withID: candidate.windowID),
              !window.isClosing
        else { return .unavailable }
        return await window.agentModeViewModel.agentSessionLinkRespondToPendingInteraction(
            for: candidate,
            request: request,
            authorize: authorize
        )
    }

    /// Routes the compaction transaction to the exact owning window, with the same terminating and
    /// closing refusals as a send. Nothing here focuses or activates the window.
    func agentSessionLinkPerformCompact(
        to candidate: AgentSessionLinkEndpointCandidate,
        request: AgentSessionLinkCompactRequest,
        liveness: @escaping AgentSessionLinkSendLivenessProbe,
        commitAuthorization: @MainActor () async -> AgentSessionLinkSendCommitOutcome
    ) async -> AgentSessionLinkSendTransactionOutcome {
        guard !isTerminating else { return .blocked(.shuttingDown) }
        guard let window = window(withID: candidate.windowID), !window.isClosing else {
            return .blocked(.endpointHost)
        }
        return await window.agentModeViewModel.agentSessionLinkPerformCompact(
            to: candidate,
            request: request,
            liveness: liveness,
            commitAuthorization: commitAuthorization
        )
    }

    // MARK: - Launch restoration inputs

    /// Identity-only descriptors for every compose-tab binding in every window's active workspace.
    ///
    /// Built from the workspace model rather than from live `TabSession`s, so a background tab that
    /// has never been visited is still *described*. That distinction is the whole reason automatic
    /// restoration can wait for natural hydration instead of force-loading every saved transcript.
    func agentSessionLinkComposeTabDescriptors() -> [AgentSessionLinkComposeTabDescriptor] {
        guard !isTerminating else { return [] }
        var descriptors: [AgentSessionLinkComposeTabDescriptor] = []
        for window in sessionRuntimeWindows where !window.isClosing {
            descriptors.append(contentsOf: window.agentModeViewModel.agentSessionLinkComposeTabDescriptors())
        }
        return descriptors
    }

    /// Current discovery level of every registered, non-closing window.
    ///
    /// An empty result is meaningful: it means no window has described its bindings yet, and the
    /// coordinator must wait rather than conclude a saved session is absent.
    func agentSessionLinkDiscoveryStates() -> [AgentSessionLinkDiscoveryState] {
        guard !isTerminating else { return [] }
        return allWindows
            .filter { !$0.isClosing }
            .map(\.agentModeViewModel.agentSessionLinkDiscoveryState)
    }

    func agentSessionLinkRestoreTopologyState() -> AgentSessionOversightRestoreTopologyState {
        agentSessionOversightRestoreTopologyState
    }

    /// Fans a restoration hydration request out to every non-closing window. Each window loads only
    /// the compose tabs of its own active workspace that are bound to one of these sessions, in the
    /// background; nothing is selected, focused, or activated.
    func agentSessionLinkRequestRestorationHydration(sessionIDs: Set<UUID>) {
        guard !isTerminating, !sessionIDs.isEmpty else { return }
        for window in sessionRuntimeWindows where !window.isClosing {
            window.agentModeViewModel.agentSessionLinkRequestRestorationHydration(sessionIDs: sessionIDs)
        }
    }

    /// Repaints every non-closing window with the process-wide durable-oversight level.
    ///
    /// Broadcast rather than addressed to an endpoint: a tab with no links at all never receives an
    /// authority projection, and that is precisely the tab whose Add button has to explain why saving
    /// is currently unavailable.
    func agentSessionLinkPublishPersistencePresentation(
        _ presentation: AgentSessionOversightPersistencePresentation
    ) {
        guard !isTerminating else { return }
        for window in sessionRuntimeWindows where !window.isClosing {
            window.agentModeViewModel.agentSessionLinkApplyPersistencePresentation(presentation)
        }
    }

    // MARK: - Attachment and lifecycle invalidation

    /// Attaches the process-wide bridge to this manager. Idempotent; safe to call on every window
    /// registration.
    func attachAgentSessionLinkBridge() {
        AgentSessionCarrierResolver.preparedSessionRuntimes = preparedSessionRuntimes
        AgentSessionLinkRuntimeBridge.shared.attach(host: self)
    }

    /// Republishes the outer restore topology to the launch coordinator.
    ///
    /// Called from the restore-gate transitions and from window registration/unregistration. The
    /// event carries nothing: the coordinator rereads the current level snapshot every pass.
    func notifyAgentSessionLinkTopologyChanged() {
        guard !isTerminating else { return }
        AgentSessionLinkRuntimeBridge.shared.noteTopologyMayHaveChanged()
    }

    /// Window close/unregister. Revokes every link with either endpoint in that window.
    ///
    /// Fired before the surviving endpoints repaint so both sides observe one authority transition.
    func invalidateAgentSessionLinks(forClosedWindowID windowID: Int) {
        guard !isTerminating else { return }
        Task { @MainActor in
            await AgentSessionLinkRuntimeBridge.shared.invalidateWindow(windowID, reason: .windowClosed)
        }
    }

    /// Workspace switch on one window. Only links bound to the window's previous workspace are
    /// revoked; links held by other windows on that workspace survive.
    func invalidateAgentSessionLinks(forWindowID windowID: Int, leavingWorkspaceID workspaceID: UUID) {
        guard !isTerminating else { return }
        Task { @MainActor in
            await AgentSessionLinkRuntimeBridge.shared.invalidateWorkspace(
                workspaceID,
                windowID: windowID,
                reason: .workspaceSwitched
            )
        }
    }
}
