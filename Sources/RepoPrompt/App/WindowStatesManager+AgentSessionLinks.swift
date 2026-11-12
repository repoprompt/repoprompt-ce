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
            guard !snapshot.ambiguousSessionIDs.contains(id),
                  let owner = preparedOversightWindows[id], !owner.isClosing,
                  let witness = preparedOversightOwnerLocations[id], witness.isCurrent,
                  witness.agreesOnCarrierAndProvenance(with: location), !preparedOversightHandoffs.contains(id),
                  let runtime = owner.agentModeViewModel.sessions[location.tab.id], runtime.activeAgentSessionID == id,
                  runtime.permitsBoundOperationAndSave,
                  let tabs = owner.workspaceManager.activeWorkspace?.composeTabs, tabs.count == 1,
                  let tab = tabs.first else { continue }
            if let existing = snapshot.uniqueLocations[id],
               existing.workspaceID != location.workspace.id || existing.tab.id != location.tab.id
            {
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
        preparedOversightWindows[sessionID] != nil || retiringPreparedOversightWindows[sessionID] != nil
            || AgentSessionRuntimeStore.shared.hasRetiringWriter(sessionID: sessionID)
    }

    func claimPreparedRuntimeVisit(_ sessionID: UUID) -> Bool {
        preparedOversightUIVisits.insert(sessionID).inserted
    }

    func finishPreparedRuntimeVisit(_ sessionID: UUID) {
        preparedOversightUIVisits.remove(sessionID)
        notifyAgentSessionLinkTopologyChanged()
    }

    /// Latest guarded UI intent wins. These closures schedule activation, not waiter completion;
    /// a newer explicit visit supersedes an older queued one without running both.
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

    /// Metadata replicas and saved preparation witnesses project the admitted writer's placement.
    /// Updating the witnesses in the same synchronous region prevents our own projection from
    /// looking like an unrelated provenance change during the subsequent durable flush.
    func projectDelegationPlacement(_ writer: AgentSessionRuntimeStore.Writer) {
        guard writer.isCurrent else { return }
        let id = writer.identity.sessionID
        func projected(_ entry: AgentSessionIndexEntry) -> AgentSessionIndexEntry {
            var copy = entry
            copy.organizationalParentID = writer.session.organizationalParentID
            copy.delegationScopeID = writer.session.delegationScopeID
            return copy
        }
        for window in sessionRuntimeWindows where window.workspaceManager.activeWorkspaceID == writer.identity.workspaceID {
            let vm = window.agentModeViewModel
            if let entry = vm.ownerValidatedSessionIndex[id], entry.tabID == writer.session.tabID {
                vm.sessionIndexStore.applyLocalUpsert(projected(entry))
            }
        }
        func projectedLocation(_ location: SavedOversightSessionLocation) -> SavedOversightSessionLocation {
            SavedOversightSessionLocation(
                window: location.window, workspace: location.workspace, tab: location.tab,
                stashedTabID: location.stashedTabID, entry: projected(location.entry)
            )
        }
        if let location = preparedOversightLocations[id], location.workspace.id == writer.identity.workspaceID {
            preparedOversightLocations[id] = projectedLocation(location)
        }
        if let location = preparedOversightOwnerLocations[id], location.workspace.id == writer.identity.workspaceID {
            preparedOversightOwnerLocations[id] = projectedLocation(location)
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

    typealias SavedOversightPreparationFailure = AgentSavedSessionTargetLoader.Failure

    /// Point reads of one UUID in known workspace locations. No folder enumeration, provider
    /// reconnect, UI activation or unrelated session hydration is performed.
    func resolveSavedOversightLocation(_ target: UUID) async -> Result<SavedOversightSessionLocation, SavedOversightPreparationFailure> {
        let deletion = AgentSessionDeletionRegistry.shared
        guard !deletion.isPermanentlyDeleted(sessionID: target), !deletion.isDeletionInProgress(sessionID: target) else { return .failure(.missing) }
        let windows = allWindows.filter { !$0.isClosing }
        let census = AgentSessionCarrierResolver.capture(windows: windows, sessionIDs: [target])
        guard !census.ambiguousSessionIDs.contains(target) else { return .failure(.ambiguous) }
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
        func location(for saved: AgentSavedSessionTargetLoader.Target) -> SavedOversightSessionLocation? {
            guard let (window, _) = owners[saved.workspace.id], !window.isClosing else { return nil }
            return SavedOversightSessionLocation(
                window: window, workspace: saved.workspace, tab: saved.tab,
                stashedTabID: saved.stashedTabID, entry: saved.entry
            )
        }
        let resolution = await AgentSavedSessionTargetLoader.load(
            sessionID: target,
            workspaces: owners.values.map(\.1).sorted { $0.id.uuidString < $1.id.uuidString },
            readRecord: { id, workspace in
                try await AgentSessionDataService.shared.metadataRecordForSessionID(id, for: workspace)
            },
            currentMetadata: { workspaceID in
                let current = AgentSessionCarrierResolver.capture(windows: self.allWindows, sessionIDs: [target])
                guard let entry = current.metadata[target]?.first(where: { $0.workspaceID == workspaceID })?.entry else { return nil }
                let matches = self.agentSessionLinkCandidates(forSessionIDs: [target], includeLocation: false)[target] ?? []
                let live = matches.count == 1 ? matches.first : nil
                return .init(entry: entry, isAuthoritative: live?.workspaceID == workspaceID && live?.restorationReadiness.isAuthoritative == true)
            },
            currentWorkspace: { workspaceID in
                guard let (window, _) = owners[workspaceID], !window.isClosing else { return nil }
                return window.workspaceManager.workspace(withID: workspaceID)
            },
            isAvailable: {
                !deletion.isPermanentlyDeleted(sessionID: target) && !deletion.isDeletionInProgress(sessionID: target)
            },
            isCurrent: { saved in
                let current = AgentSessionCarrierResolver.capture(windows: self.allWindows, sessionIDs: [target])
                return !current.ambiguousSessionIDs.contains(target) && location(for: saved)?.isCurrent == true
            }
        )
        let found: SavedOversightSessionLocation
        switch resolution {
        case let .failure(reason): return .failure(reason)
        case let .success(saved):
            guard let current = location(for: saved) else { return .failure(.changed) }
            found = current
        }
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
        guard isStillAuthorized(), !Task.isCancelled, !preparedOversightUIVisits.contains(target),
              retiringPreparedOversightWindows[target] == nil,
              !AgentSessionRuntimeStore.shared.hasRetiringWriter(sessionID: target) else { return .failure(.changed) }
        let resolution = await resolveSavedOversightLocation(target)
        guard case let .success(location) = resolution else {
            if case let .failure(reason) = resolution { return .failure(reason) }
            return .failure(.missing)
        }
        guard isStillAuthorized(), location.isCurrent, let source = location.window,
              retiringPreparedOversightWindows[target] == nil,
              !AgentSessionRuntimeStore.shared.hasRetiringWriter(sessionID: target) else { return .failure(.changed) }
        if preparedOversightWindows[target] != nil,
           preparedOversightOwnerLocations[target]?.isCurrent != true
           || preparedOversightOwnerLocations[target]?.agreesOnCarrierAndProvenance(with: location) != true
        {
            guard await releasePreparedOversightOwnerForVisit(sessionID: target, preparingReplacement: true) else { return .failure(.changed) }
        }
        guard isStillAuthorized(), !Task.isCancelled, location.isCurrent else { return .failure(.changed) }
        // Resolve after every preparation suspension. The window below is an adapter for the
        // exact writer, not an election among agreeing presentation replicas.
        let writerOwner: WindowState?
        switch AgentSessionRuntimeStore.shared.resolveWriter(sessionID: target, expectedWorkspaceID: location.workspace.id) {
        case let .unique(writer):
            guard let exact = sessionRuntimeWindows.first(where: {
                !$0.isClosing && $0.agentModeViewModel.sessions[writer.session.tabID] === writer.session
            }) else { return .failure(.changed) }
            writerOwner = exact
        case .unavailable(.absent): writerOwner = nil
        case .unavailable: return .failure(.changed)
        case .conflicting: return .failure(.ambiguous)
        }
        let carriers = AgentSessionCarrierResolver.capture(windows: allWindows, sessionIDs: [target])
        guard !carriers.ambiguousSessionIDs.contains(target) else { return .failure(.ambiguous) }
        let owner: WindowState
        if let writerOwner {
            owner = writerOwner
        } else if let existing = preparedOversightWindows[target], !existing.isClosing {
            owner = existing
        } else if !carriers.replicatedSessionIDs.contains(target),
                  location.stashedTabID == nil, source.workspaceManager.activeWorkspaceID == location.workspace.id,
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
        guard !owner.agentModeViewModel.isAwaitingWorkspaceAdoption else { return .failure(.changed) }
        let ready = await owner.agentModeViewModel.prepareSavedOversightSession(
            tabID: location.tab.id, sessionID: target, workspaceID: location.workspace.id,
            isStillAuthorized: { isStillAuthorized() && location.isCurrent }
        )
        guard isStillAuthorized(), location.isCurrent,
              !owner.agentModeViewModel.isAwaitingWorkspaceAdoption else { return .failure(.changed) }
        guard ready else { return .failure(.unreadable) }
        guard case let .unique(writer) = AgentSessionRuntimeStore.shared.resolveWriter(
            sessionID: target, expectedWorkspaceID: location.workspace.id
        ), writer.session === owner.agentModeViewModel.sessions[location.tab.id],
        (try? writer.admitCommand().get()) != nil else { return .failure(.changed) }
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
        if let retiring = retiringPreparedOversightWindows[sessionID] {
            // An explicit visit may retry a failed final save, but never joins a still-running
            // drain on the UI path. That visit will be queued and resumed by the drain owner.
            guard !preparedOversightHandoffs.contains(sessionID), !retiring.isPreparedSessionTeardownInFlight else { return false }
            let released = await finishRetiringPreparedOversightOwner(sessionID: sessionID, owner: retiring)
            if released { preparedOversightPendingVisits.removeValue(forKey: sessionID) }
            return released
        }
        guard let owner = preparedOversightWindows[sessionID] else {
            return !AgentSessionRuntimeStore.shared.hasRetiringWriter(sessionID: sessionID)
        }
        guard preparedOversightPreparationInFlight[sessionID, default: 0] <= (preparingReplacement ? 1 : 0),
              owner.agentModeViewModel.preparedOversightSessionsAreIdle,
              await !(AgentRunSessionStore.hasActiveRegistration(sessionID: sessionID)),
              await !owner.agentModeViewModel.preparedOversightRuntimeIsBusy(),
              preparedOversightWindows[sessionID] === owner else { return false }
        beginPreparedOversightPreparation(sessionID)
        preparedOversightHandoffs.insert(sessionID)
        defer {
            endPreparedOversightPreparation(sessionID)
            preparedOversightHandoffs.remove(sessionID)
        }
        guard await owner.agentModeViewModel.settlePreparedOversightHandoff(),
              await !owner.agentModeViewModel.preparedOversightRuntimeIsBusy(),
              preparedOversightWindows[sessionID] === owner else { return false }
        // Withdraw and capture the old exact endpoint before yielding to its final save. This parks
        // the durable link for re-establishment at the newly visited binding, rather than relinking.
        movePreparedOwnerToRetirement(sessionID: sessionID, owner: owner)
        owner.beginClose()
        guard await owner.tearDownPreparedSessionOwner() else { return false }
        guard retiringPreparedOversightWindows[sessionID] === owner else { return false }
        retiringPreparedOversightWindows.removeValue(forKey: sessionID)
        // This caller owns the visit/replacement. Do not execute another activation recursively.
        preparedOversightPendingVisits.removeValue(forKey: sessionID)
        return true
    }

    /// Event-driven lifetime, not a polling timer or an independent link authority. The bridge's
    /// committed live links retain an owner; a saved intent alone does not keep a revoked run alive.
    func schedulePreparedOversightCleanup() {
        guard !isTerminating, !preparedOversightWindows.isEmpty || !retiringPreparedOversightWindows.isEmpty else { return }
        preparedOversightCleanupDirty = true
        guard preparedOversightCleanupTask == nil else { return }
        preparedOversightCleanupTask = Task { @MainActor [weak self] in
            defer { self?.preparedOversightCleanupTask = nil }
            while let self, preparedOversightCleanupDirty, !isTerminating, !Task.isCancelled {
                preparedOversightCleanupDirty = false
                // A durable tombstone is a new settlement fact, not a storage retry. It can
                // release an owner whose earlier drain met an in-progress deletion.
                for (id, owner) in retiringPreparedOversightWindows
                    where AgentSessionDeletionRegistry.shared.isPermanentlyDeleted(sessionID: id)
                    && !preparedOversightHandoffs.contains(id)
                {
                    preparedOversightPendingVisits.removeValue(forKey: id)
                    _ = await finishRetiringPreparedOversightOwner(sessionID: id, owner: owner)
                }
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
                        if deleted { preparedOversightPendingVisits.removeValue(forKey: id) }
                        await retirePreparedOversightOwner(sessionID: id, preservingIntent: false)
                        // The drain owner consumes the latest queued visit after acknowledged
                        // retirement, including visits arriving while its final save is suspended.
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
                    guard owner.agentModeViewModel.preparedOversightSessionsAreIdle,
                          await !AgentRunSessionStore.hasActiveRegistration(sessionID: id),
                          await !owner.agentModeViewModel.preparedOversightRuntimeIsBusy(),
                          preparedOversightWindows[id] === owner else { continue }
                    if let visit = preparedOversightPendingVisits.removeValue(forKey: id) {
                        await visit()
                    } else if !retained.contains(id), pairs.isEmpty {
                        await retirePreparedOversightOwner(sessionID: id, preservingIntent: true)
                    }
                }
            }
        }
    }

    private func movePreparedOwnerToRetirement(sessionID: UUID, owner: WindowState) {
        precondition(preparedOversightWindows[sessionID] === owner)
        owner.agentModeViewModel.beginPreparedOversightRetirement()
        preparedOversightWindows.removeValue(forKey: sessionID)
        preparedOversightOwnerLocations.removeValue(forKey: sessionID)
        preparedOversightCarrierSubscriptions.removeValue(forKey: sessionID)
        preparedOversightConsentPairs.removeValue(forKey: sessionID)
        preparedOversightRunObservations.removeValue(forKey: sessionID)?.invalidate()
        retiringPreparedOversightWindows[sessionID] = owner
    }

    private func retirePreparedOversightOwner(sessionID: UUID, preservingIntent: Bool) async {
        guard let owner = preparedOversightWindows[sessionID] else { return }
        movePreparedOwnerToRetirement(sessionID: sessionID, owner: owner)
        owner.beginClose(preservingOversightIntent: preservingIntent)
        guard await finishRetiringPreparedOversightOwner(sessionID: sessionID, owner: owner) else { return }
        // Read only after drain: a newer visit may have arrived during invalidation or IO.
        let visit = preparedOversightPendingVisits.removeValue(forKey: sessionID)
        let deletion = AgentSessionDeletionRegistry.shared
        if !isTerminating, !deletion.isPermanentlyDeleted(sessionID: sessionID), !deletion.isDeletionInProgress(sessionID: sessionID) {
            await visit?()
        }
    }

    /// Failed durability retains the old writer and the deferred visit. Only an explicit visit
    /// (or shutdown) retries; no cleanup loop silently drops the response or spins on storage.
    private func finishRetiringPreparedOversightOwner(sessionID: UUID, owner: WindowState) async -> Bool {
        guard retiringPreparedOversightWindows[sessionID] === owner,
              preparedOversightHandoffs.insert(sessionID).inserted else { return false }
        defer { preparedOversightHandoffs.remove(sessionID) }
        // Own the entire drain before the first await, including link invalidation.
        if !isTerminating {
            await AgentSessionLinkRuntimeBridge.shared.invalidateWindow(owner.windowID, reason: .windowClosed)
        }
        guard await owner.tearDownPreparedSessionOwner() else {
            let deletion = AgentSessionDeletionRegistry.shared
            if !deletion.isPermanentlyDeleted(sessionID: sessionID), !deletion.isDeletionInProgress(sessionID: sessionID) {
                AgentSessionLinkRuntimeBridge.shared.launchCoordinatorReportWarning(
                    id: "prepared-runtime-unsettled",
                    message: "A background managed session could not finish saving or draining its owned effects. Retirement was not acknowledged. Its in-memory writer is retained; check storage before relying on restart continuity."
                )
            }
            return false
        }
        guard retiringPreparedOversightWindows[sessionID] === owner else { return false }
        retiringPreparedOversightWindows.removeValue(forKey: sessionID)
        return true
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
                        group.addTask { @MainActor in
                            let saved = await owner.tearDownPreparedSessionOwner()
                            if saved {
                                self.retiringPreparedOversightWindows = self.retiringPreparedOversightWindows.filter { $0.value !== owner }
                            }
                            return saved
                        }
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
        schedulePreparedOversightCleanup()
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
        return viewModel.linkExecutionRuntime.agentSessionLinkRequestManualWakeNow(for: endpoint)
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
        return viewModel.linkExecutionRuntime.agentSessionLinkAutoWakeSnoozeProjection(
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
        return viewModel.linkExecutionRuntime.agentSessionLinkMutateAutoWakeSnooze(
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
        viewModel.linkExecutionRuntime.agentSessionLinkPublishPromptInventory(inventory, to: endpoint)
    }

    func agentSessionLinkPublishRunCatalogProjection(
        _ projection: AgentSessionLinkRunCatalogProjection
    ) {
        guard let endpoint = projection.routeToken?.observerEndpoint,
              let viewModel = agentSessionLinkOwningViewModel(for: endpoint)
        else { return }
        viewModel.linkExecutionRuntime.agentSessionLinkPublishRunCatalogProjection(projection, to: endpoint)
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
        viewModel.linkExecutionRuntime.agentSessionLinkPublishPassiveStatusNotices(snapshot, to: endpoint)
    }

    func agentSessionLinkWillActivate(_ endpoint: DomainAgentSessionLinkEndpointIdentity) async {
        guard let viewModel = agentSessionLinkOwningViewModel(for: endpoint) else { return }
        await viewModel.agentSessionLinkWillActivate(endpoint)
    }

    func agentSessionLinkWithholdPromptInventory(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> UInt64? {
        guard let viewModel = agentSessionLinkOwningViewModel(for: endpoint) else { return nil }
        return viewModel.linkExecutionRuntime.agentSessionLinkWithholdPromptInventory(for: endpoint)
    }

    func agentSessionLinkReleasePromptInventoryHold(
        _ token: UInt64?,
        for endpoint: DomainAgentSessionLinkEndpointIdentity,
        publishing inventory: AgentSessionLinkPromptInventory?
    ) {
        guard let viewModel = agentSessionLinkOwningViewModel(for: endpoint) else { return }
        viewModel.linkExecutionRuntime.agentSessionLinkReleasePromptInventoryHold(
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
        guard viewModel.linkExecutionRuntime.agentSessionLinkObserverEndpoint(tabID: endpoint.tabID) == endpoint else {
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
    /// The transaction itself runs on the target's runtime scope, which does not own the
    /// observer's presentation or the target presentation's teardown flag. Both facts are read here, from the same
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

    /// Resolves the command runtime through the process writer authority. The endpoint's route ID
    /// is an incarnation fence, not a window-selection instruction. Existing liveness probes retain
    /// presentation-close refusal until the separate presentation-lifetime cutover.
    private func agentSessionLinkCommandRuntime(for candidate: AgentSessionLinkEndpointCandidate) -> AgentSessionLinkExecutionRuntime? {
        guard !isTerminating,
              case let .unique(writer) = AgentSessionRuntimeStore.shared.resolveWriter(
                  sessionID: candidate.sessionID, expectedWorkspaceID: candidate.workspaceID
              ), let runtime = writer.scope.linkExecution,
              runtime.admit(candidate) != nil else { return nil }
        return runtime
    }

    func agentSessionLinkStartStopFence(for candidate: AgentSessionLinkEndpointCandidate) -> AgentRunStartStopFence? {
        guard let runtime = agentSessionLinkCommandRuntime(for: candidate),
              let command = runtime.admit(candidate) else { return nil }
        return AgentRunStartStopFence(session: command.writer.session)
    }

    func agentSessionLinkPerformSend(
        to candidate: AgentSessionLinkEndpointCandidate,
        request: AgentSessionLinkSendRequest,
        liveness: @escaping AgentSessionLinkSendLivenessProbe,
        commitAuthorization: @MainActor () async -> AgentSessionLinkSendCommitOutcome
    ) async -> AgentSessionLinkSendTransactionOutcome {
        guard !isTerminating else { return .blocked(.shuttingDown) }
        guard let runtime = agentSessionLinkCommandRuntime(for: candidate) else {
            return .blocked(.endpointHost)
        }
        return await runtime.agentSessionLinkPerformSend(
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
        guard !isTerminating,
              case let .unique(writer) = AgentSessionRuntimeStore.shared.resolveWriter(
                  sessionID: endpoint.sessionID, expectedWorkspaceID: endpoint.workspaceID
              ), let runtime = writer.scope.linkExecution else { return nil }
        return runtime.agentSessionLinkModelCandidate(for: endpoint)
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
        guard let runtime = agentSessionLinkCommandRuntime(for: candidate) else {
            return .blocked(.endpointHost)
        }
        return await runtime.agentSessionLinkPerformSetModel(
            to: candidate, modelID: modelID, liveness: liveness,
            availability: runtime.commands.modelAvailability, reauthorize: reauthorize
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
        guard let runtime = agentSessionLinkCommandRuntime(for: candidate) else {
            return .blocked(.endpointHost)
        }
        return await runtime.agentSessionLinkPerformStop(
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

    /// Routes compaction through the exact runtime writer. Presentation liveness remains a
    /// separate admission input; it never elects the mutation owner.
    func agentSessionLinkPerformCompact(
        to candidate: AgentSessionLinkEndpointCandidate,
        request: AgentSessionLinkCompactRequest,
        liveness: @escaping AgentSessionLinkSendLivenessProbe,
        commitAuthorization: @MainActor () async -> AgentSessionLinkSendCommitOutcome
    ) async -> AgentSessionLinkSendTransactionOutcome {
        guard !isTerminating else { return .blocked(.shuttingDown) }
        guard let runtime = agentSessionLinkCommandRuntime(for: candidate) else {
            return .blocked(.endpointHost)
        }
        return await runtime.agentSessionLinkPerformCompact(
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
