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
        to original: AgentSessionCarrierResolver.Snapshot, sessionIDs _: Set<UUID>?, windowIDs _: Set<Int>
    ) -> AgentSessionCarrierResolver.Snapshot {
        // Compatibility for the remaining presentation census. An independent host is never
        // turned into a synthetic WindowState carrier or a candidate writer by that census.
        original
    }

    static let agentHostRecoveryWarningPrefix = "agent-host-recovery:"

    func reportRetainedAgentHostDrain(_ drain: AgentSessionHostDrainRuntime) {
        guard case .retained? = drain.outcome else { return }
        AgentSessionLinkRuntimeBridge.shared.launchCoordinatorReportWarning(
            id: Self.agentHostRecoveryWarningPrefix + drain.recoveryID.uuidString,
            message: "A background Agent session could not finish saving or releasing its resources. Its original owner is retained. Retry settlement after correcting any storage problems."
        )
    }

    /// Connect presentation to the original producer. This never starts or retries a drain.
    func observeAgentHostDrainRecovery(_ drain: AgentSessionHostDrainRuntime) {
        let warningID = Self.agentHostRecoveryWarningPrefix + drain.recoveryID.uuidString
        drain.observeRecovery { [weak self, weak drain] outcome in
            switch outcome {
            case .released:
                AgentSessionLinkRuntimeBridge.shared.dismissPersistenceWarnings(ids: [warningID])
            case .retained:
                if let drain {
                    self?.reportRetainedAgentHostDrain(drain)
                    if let id = drain.scope.executableHost?.workspaceActivation?.savedCarrierSessionID,
                       AgentSessionDeletionRegistry.shared.isPermanentlyDeleted(sessionID: id)
                    {
                        self?.schedulePreparedOversightCleanup()
                    }
                }
            case .cancelled, .timedOut:
                break
            }
        }
    }

    /// The warning names an exact drain, not a reusable session ID. Reading or visiting it
    /// never retries the save; only the explicit action below joins the retained producer.
    func retryRetainedAgentHostDrain(warningID: String) async {
        let prefix = Self.agentHostRecoveryWarningPrefix
        guard !isTerminating, warningID.hasPrefix(prefix),
              let recoveryID = UUID(uuidString: String(warningID.dropFirst(prefix.count))),
              let drain = agentRuntimeStore.retainedDrains.first(where: { $0.recoveryID == recoveryID }),
              case .retained? = drain.outcome else { return }
        observeAgentHostDrainRecovery(drain)
        drain.attemptRecovery()
        _ = await drain.wait(until: .now.advanced(by: .seconds(5)))
    }

    func hasPreparedRuntime(_ sessionID: UUID) -> Bool {
        canonicalSavedHost(sessionID) != nil || agentRuntimeStore.hasRetiringWriter(sessionID: sessionID)
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
    func beginRuntimeVisitIntent(_ sessionID: UUID) -> UUID? {
        // A visit that cannot acquire the active handoff must leave that handoff's intent in place.
        guard !isTerminating, !preparedOversightUIVisits.contains(sessionID) else { return nil }
        let ticket = UUID()
        canonicalDeferredVisitTickets[sessionID] = ticket
        return ticket
    }

    func isRuntimeVisitIntentCurrent(_ sessionID: UUID, intent: UUID?) -> Bool {
        guard let intent else { return false }
        return !isTerminating && canonicalDeferredVisitTickets[sessionID] == intent
    }

    func queuePreparedRuntimeVisit(_ sessionID: UUID, resume: @escaping @MainActor () async -> Void) {
        queuePreparedRuntimeVisit(sessionID, intent: beginRuntimeVisitIntent(sessionID), resume: resume)
    }

    func queuePreparedRuntimeVisit(_ sessionID: UUID, intent: UUID?, resume: @escaping @MainActor () async -> Void) {
        guard let ticket = intent, isRuntimeVisitIntentCurrent(sessionID, intent: ticket) else { return }
        let drains = agentRuntimeStore.retainedDrains.filter {
            !$0.scope.liveSessionTabIDs(for: sessionID).isEmpty
        }
        if drains.count == 1, let drain = drains.first {
            observeAgentHostDrainRecovery(drain)
            preparedOversightPendingVisits.removeValue(forKey: sessionID)
            drain.deferVisit(presenterID: sessionID, isDestinationCurrent: { [weak self] in
                self?.isRuntimeVisitIntentCurrent(sessionID, intent: ticket) == true
            }) { [weak self] in
                guard let self else { return }
                let deliver: @MainActor () async -> Void = { [weak self] in
                    guard self?.isRuntimeVisitIntentCurrent(sessionID, intent: ticket) == true else { return }
                    // The visit itself revalidates its presenter and workspace before admission.
                    await resume()
                }
                #if DEBUG
                    if let test_scheduleCanonicalVisitResume {
                        test_scheduleCanonicalVisitResume(deliver)
                        return
                    }
                #endif
                Task { await deliver() }
            }
            return
        }
        if !hasPreparedRuntime(sessionID) {
            Task { [weak self] in
                guard self?.isRuntimeVisitIntentCurrent(sessionID, intent: ticket) == true else { return }
                await resume()
            }
            return
        }
        preparedOversightPendingVisits[sessionID] = { [weak self] in
            guard self?.isRuntimeVisitIntentCurrent(sessionID, intent: ticket) == true else { return }
            await resume()
        }
        schedulePreparedOversightCleanup()
    }

    func prepareScopedSavedTarget(_ sessionID: UUID, isStillAuthorized: @escaping @MainActor () -> Bool) async -> Bool {
        if case .success = await prepareSavedOversightTarget(sessionID, isStillAuthorized: isStillAuthorized) { return true }
        return false
    }

    /// Update agreeing presentation metadata from the exact writer, not the reverse.
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

    /// Approval preflight is a point read only. It never composes a host or creates a claim.
    func checkSavedOversightTarget(_ sessionID: UUID) async -> SavedOversightPreparationFailure? {
        guard !isTerminating, !AgentSessionDeletionRegistry.shared.blocksNewOversight(sessionID: sessionID) else { return .missing }
        switch agentRuntimeStore.resolveWriter(sessionID: sessionID) {
        case let .unique(writer):
            if (try? writer.admitCommand().get()) != nil { return nil }
            guard AgentSavedSessionTargetLoader.canHydrateOriginalColdWriter(writer) else { return .changed }
        case .conflicting: return .ambiguous
        case .unavailable(.absent): break
        case .unavailable: return .changed
        }
        do {
            _ = try await AppSavedAgentSessionExecution.resolve(sessionID, domain: AppDomainRuntimeComposition.shared.runtime) { [self] in
                !isTerminating && !Task.isCancelled
            }
            return nil
        } catch let failure as SavedOversightPreparationFailure {
            return failure
        } catch {
            return .unreadable
        }
    }

    func prepareSavedOversightTarget(
        _ target: UUID, providerEnvironment: AppSavedAgentSessionExecution.ProviderEnvironment? = nil,
        isStillAuthorized: @escaping @MainActor () -> Bool
    ) async -> Result<AgentSessionRuntimeStore.Writer, SavedOversightPreparationFailure> {
        let authorized: @MainActor () -> Bool = { [self] in
            !Task.isCancelled && !isTerminating && isStillAuthorized()
                && !preparedOversightUIVisits.contains(target)
                && !AgentSessionDeletionRegistry.shared.blocksNewOversight(sessionID: target)
        }
        guard authorized() else { return .failure(.changed) }
        let originalColdWriter: AgentSessionRuntimeStore.Writer?
        switch agentRuntimeStore.resolveWriter(sessionID: target) {
        case let .unique(writer):
            guard let host = writer.scope.executableHost, !host.route.isClosing, writer.scope.linkExecution != nil,
                  host.route.identity.kind != .independent || host.workspaceActivation?.isCurrent == true else { return .failure(.changed) }
            if (try? writer.admitCommand().get()) != nil { return .success(writer) }
            guard AgentSavedSessionTargetLoader.canHydrateOriginalColdWriter(writer) else { return .failure(.changed) }
            originalColdWriter = writer
        case .conflicting: return .failure(.ambiguous)
        case .unavailable(.absent): originalColdWriter = nil
        case .unavailable: return .failure(.changed)
        }
        let domain = AppDomainRuntimeComposition.shared.runtime
        do {
            let lookup = try await AppSavedAgentSessionExecution.resolve(target, domain: domain, isStillAuthorized: authorized)
            if let originalColdWriter {
                let loaded = try await AppSavedAgentSessionExecution.hydrateOriginal(originalColdWriter, lookup: lookup, isStillAuthorized: authorized)
                guard authorized(), (try? loaded.writer.admitCommand().get()) != nil else { return .failure(.changed) }
                notifyAgentSessionLinkTopologyChanged()
                return .success(loaded.writer)
            }
            #if DEBUG
                let rootProbeCheckpoint = test_savedHostRootProbeCheckpoint
                let environment = providerEnvironment ?? test_savedHostProviderEnvironments[target]
            #else
                let rootProbeCheckpoint: WorkspaceRootDirectoryProbe.Checkpoint? = nil
                let environment = providerEnvironment
            #endif
            let result = try await AppSavedAgentSessionExecution.compose(
                target: lookup.target, catalog: lookup.catalog, domain: domain,
                installRoute: { host in
                    try await host.registerHostCatalog(service: environment?.mcpTransport ?? AppGlobalMCPServiceComposition.transport)
                }, providerEnvironment: environment, rootProbeCheckpoint: rootProbeCheckpoint, isStillAuthorized: authorized
            )
            let writer = result.writer
            if result.source == .savedPayload, let runtime = writer.scope.linkExecution,
               let endpoint = runtime.agentSessionLinkObserverEndpoint(tabID: writer.session.tabID),
               let candidate = runtime.agentSessionLinkRuntimeCandidate(for: endpoint, displayName: lookup.target.entry.name)
            {
                preparedOversightRunObservations[target] = agentSessionLinkInstallObservation(for: candidate) { [weak self] in
                    self?.schedulePreparedOversightCleanup()
                }
                notifyAgentSessionLinkTopologyChanged()
                schedulePreparedOversightCleanup()
            }
            guard authorized(), (try? writer.admitCommand().get()) != nil else { return .failure(.changed) }
            return .success(writer)
        } catch let failure as SavedOversightPreparationFailure {
            return .failure(failure)
        } catch let failure as AgentSavedSessionTargetLoader.RuntimeLoadFailure {
            if case let .lookup(reason) = failure.reason { return .failure(reason) }
            return .failure(.changed)
        } catch {
            return .failure(Task.isCancelled || !authorized() ? .changed : .unreadable)
        }
    }

    private func canonicalSavedHost(_ sessionID: UUID) -> AgentSessionRuntimeHost? {
        guard case let .unique(writer) = agentRuntimeStore.resolveWriter(sessionID: sessionID),
              let host = writer.scope.executableHost, host.workspaceActivation?.savedCarrierSessionID == sessionID else { return nil }
        return host
    }

    private func startSavedHostRetirement(
        _ host: AgentSessionRuntimeHost, sessionID: UUID, destructive: Bool
    ) -> AgentSessionHostDrainRuntime {
        if let drain = host.scope.retainedDrain { return drain }
        let drain = destructive ? host.beginFinalShutdown() : host.beginRetirement()
        let bridge = AgentSessionLinkRuntimeBridge.shared
        if !destructive { bridge.noteOversightWindowClosing(windowID: host.routeID) }
        if let visit = preparedOversightPendingVisits.removeValue(forKey: sessionID), !destructive {
            queuePreparedRuntimeVisit(sessionID, intent: canonicalDeferredVisitTickets[sessionID], resume: visit)
        }
        preparedOversightConsentPairs.removeValue(forKey: sessionID)
        preparedOversightRunObservations.removeValue(forKey: sessionID)?.invalidate()
        observeAgentHostDrainRecovery(drain)
        Task { @MainActor in
            await bridge.invalidateWindow(host.routeID, reason: .windowClosed)
            drain.startIfNeeded()
        }
        return drain
    }

    /// A UI visit may take over an idle saved runtime, but never creates a second writer or
    /// cancels an accepted managed task. Active ownership is the ordinary binding-transition block.
    func releasePreparedOversightOwnerForVisit(sessionID: UUID, preparingReplacement: Bool = false) async -> Bool {
        if let host = canonicalSavedHost(sessionID) {
            guard !preparingReplacement, preparedOversightPreparationInFlight[sessionID] == nil,
                  let session = host.scope.sessions.values.first(where: { $0.activeAgentSessionID == sessionID }),
                  host.scope.settlement(for: session).canJoinHostDrain else { return false }
            let drain = startSavedHostRetirement(host, sessionID: sessionID, destructive: false)
            return await drain.wait(until: .now.advanced(by: .seconds(2))) == .released
        }
        return !agentRuntimeStore.hasRetiringWriter(sessionID: sessionID)
    }

    /// Event-driven lifetime, not a polling timer or an independent link authority. The bridge's
    /// committed live links retain an owner; a saved intent alone does not keep a revoked run alive.
    func schedulePreparedOversightCleanup() {
        guard !isTerminating,
              agentRuntimeStore.retainedExecutionHosts.contains(where: { $0.workspaceActivation?.savedCarrierSessionID != nil })
              || agentRuntimeStore.retainedDrains.contains(where: { $0.scope.executableHost?.workspaceActivation?.savedCarrierSessionID != nil })
        else { return }
        preparedOversightCleanupDirty = true
        guard preparedOversightCleanupTask == nil else { return }
        preparedOversightCleanupTask = Task { @MainActor [weak self] in
            defer { self?.preparedOversightCleanupTask = nil }
            while let self, preparedOversightCleanupDirty, !isTerminating, !Task.isCancelled {
                preparedOversightCleanupDirty = false
                // A durable tombstone is a new settlement fact, not a storage retry. It can
                // release an owner whose earlier drain met an in-progress deletion.
                for drain in agentRuntimeStore.retainedDrains {
                    guard let id = drain.scope.executableHost?.workspaceActivation?.savedCarrierSessionID,
                          AgentSessionDeletionRegistry.shared.isPermanentlyDeleted(sessionID: id) else { continue }
                    preparedOversightPendingVisits.removeValue(forKey: id)
                    canonicalDeferredVisitTickets.removeValue(forKey: id)
                    drain.settleAfterDurableDeletion(sessionID: id)
                }
                let bridge = AgentSessionLinkRuntimeBridge.shared
                let inventory = await bridge.oversightInventory(includeLocation: false)
                let consent = bridge.delegationScopes.linkConsent
                let retained = Set(inventory.live.filter { item in
                    item.sourceScopeID.map {
                        consent.permits(scopeID: $0, observer: item.observerSessionID, target: item.targetSessionID, at: Date())
                    } ?? true
                }.flatMap { [$0.observerSessionID, $0.targetSessionID] })
                for host in agentRuntimeStore.retainedExecutionHosts {
                    guard let id = host.workspaceActivation?.savedCarrierSessionID,
                          preparedOversightPreparationInFlight[id] == nil,
                          canonicalSavedHost(id) === host, !host.scope.isRetiring,
                          let session = host.scope.sessions.values.first(where: { $0.activeAgentSessionID == id }) else { continue }
                    let pairs = inventory.persisted.filter { $0.targetSessionID == id || $0.observerSessionID == id }
                    for pair in pairs where pair.targetSessionID == id {
                        preparedOversightConsentPairs[id, default: []].update(with: pair)
                    }
                    let known = preparedOversightConsentPairs[id] ?? []
                    let revoked = !known.isEmpty && known.allSatisfy { pair in
                        pair.sourceScopeID.map { !consent.permits(scopeID: $0, observer: pair.observerSessionID, target: id, at: Date()) } ?? false
                    }
                    let deleted = AgentSessionDeletionRegistry.shared.isPermanentlyDeleted(sessionID: id)
                    let destructive = deleted || revoked
                    let visitPending = preparedOversightPendingVisits[id] != nil
                    let naturallyUnowned = !retained.contains(id) && pairs.isEmpty
                    if destructive || ((visitPending || naturallyUnowned) && host.scope.settlement(for: session).canJoinHostDrain) {
                        _ = startSavedHostRetirement(host, sessionID: id, destructive: destructive)
                    }
                }
            }
        }
    }

    private func independentLinkRuntime(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> AgentSessionLinkExecutionRuntime? {
        guard !isTerminating,
              case let .unique(writer) = agentRuntimeStore.resolveWriter(sessionID: endpoint.sessionID, expectedWorkspaceID: endpoint.workspaceID),
              let host = writer.scope.executableHost, host.route.identity.kind == .independent,
              host.routeID == endpoint.windowID, host.workspaceActivation?.isCurrent == true,
              let runtime = writer.scope.linkExecution, runtime.admit(endpoint: endpoint) != nil else { return nil }
        return runtime
    }

    private func independentLinkCandidates(sessionIDs: Set<UUID>? = nil) -> [AgentSessionLinkEndpointCandidate] {
        agentRuntimeStore.retainedExecutionHosts.flatMap { host -> [AgentSessionLinkEndpointCandidate] in
            guard host.route.identity.kind == .independent, let runtime = host.scope.linkExecution else { return [] }
            return host.scope.sessions.values.compactMap { session in
                guard let id = session.activeAgentSessionID, sessionIDs?.contains(id) != false,
                      let endpoint = runtime.agentSessionLinkObserverEndpoint(tabID: session.tabID),
                      independentLinkRuntime(for: endpoint) === runtime else { return nil }
                let title = host.scope.persistence.composition?.displayName(session.tabID) ?? "Agent Session"
                return runtime.agentSessionLinkRuntimeCandidate(for: endpoint, displayName: title)
            }
        }
    }

    /// Lookout gets a value-only read of saved runs, without promoting them to presenters.
    func savedHostStatusSamples() -> [AgentSessionStatusCensus.Sample] {
        independentLinkCandidates().compactMap { candidate in
            guard let runtime = independentLinkRuntime(for: candidate.domainEndpoint),
                  let command = runtime.admit(candidate), let host = command.writer.scope.executableHost,
                  let activation = host.workspaceActivation, activation.savedCarrierSessionID == candidate.sessionID
            else { return nil }
            let session = command.writer.session
            var sample = AgentSessionStatusCensus.Sample(
                candidate: candidate, status: AgentModeViewModel.statusProjection(for: session),
                outcome: AgentModeViewModel.laneBoard(for: session, blockers: [], subagentCounts: (0, 0)).runOutcome,
                ownerIdentity: ObjectIdentifier(host), sessionIdentity: ObjectIdentifier(session)
            )
            let workspace = activation.catalogFileLease?.snapshot.document.metadata
            sample.workspaceName = workspace?.name
            sample.workspaceRoots = workspace?.repoPaths ?? []
            return sample
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
        var candidates = independentLinkCandidates()
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
        if let runtime = independentLinkRuntime(for: endpoint) {
            return independentLinkCandidates(sessionIDs: [endpoint.sessionID]).first { $0.domainEndpoint == endpoint }
                ?? runtime.agentSessionLinkRuntimeCandidate(for: endpoint, displayName: "Agent Session")
        }
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
        for candidate in independentLinkCandidates(sessionIDs: sessionIDs) {
            result[candidate.sessionID, default: []].append(candidate)
        }
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
        if let runtime = independentLinkRuntime(for: candidate.domainEndpoint),
           let command = runtime.admit(candidate)
        {
            return AgentModeViewModel.observationSnapshot(for: command.writer.session, candidate: candidate, subagentCounts: nil)
        }
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
        if let runtime = independentLinkRuntime(for: candidate.domainEndpoint), let command = runtime.admit(candidate) {
            return AgentModeViewModel.statusProjection(for: command.writer.session)
        }
        guard let window = window(withID: candidate.windowID) else { return nil }
        return window.agentModeViewModel.agentSessionLinkStatusProjection(for: candidate)
    }

    func agentSessionLinkAutoWakeOnUpdatesEnabled(
        for candidate: AgentSessionLinkEndpointCandidate
    ) -> Bool {
        if let runtime = independentLinkRuntime(for: candidate.domainEndpoint), let command = runtime.admit(candidate) {
            return command.writer.session.oversight.autoWakeOnUpdates
        }
        guard let window = window(withID: candidate.windowID) else { return false }
        return window.agentModeViewModel.agentSessionLinkAutoWakeOnUpdatesEnabled(for: candidate)
    }

    func agentSessionLinkAutoWakeTargetSessionIDs(
        for candidate: AgentSessionLinkEndpointCandidate
    ) -> Set<UUID> {
        if let runtime = independentLinkRuntime(for: candidate.domainEndpoint), let command = runtime.admit(candidate) {
            return command.writer.session.oversight.autoWakeTargetSessionIDs
        }
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
        if let runtime = independentLinkRuntime(for: endpoint), let command = runtime.admit(endpoint: endpoint) {
            let session = command.writer.session
            if session.oversight.waitingOn != waitingOn {
                session.oversight.waitingOn = waitingOn
                session.monitorObservationSignal.send(())
            }
            return true
        }
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
        if let runtime = independentLinkRuntime(for: candidate.domainEndpoint),
           let command = runtime.admit(candidate)
        {
            let session = command.writer.session
            let publishers = [
                session.$runState.map { _ in () }.eraseToAnyPublisher(),
                session.$items.map { _ in () }.eraseToAnyPublisher(),
                session.monitorObservationSignal.eraseToAnyPublisher()
            ] + session.interactionStatePublishers(includeHookGate: false)
            let cancellable = Publishers.MergeMany(publishers).receive(on: DispatchQueue.main).sink { _ in
                MainActor.assumeIsolated { onChange() }
            }
            return AgentSessionLinkObservationToken { cancellable.cancel() }
        }
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
        let runtime = independentLinkRuntime(for: endpoint) ?? agentSessionLinkOwningViewModel(for: endpoint)?.linkExecutionRuntime
        runtime?.agentSessionLinkPublishPromptInventory(inventory, to: endpoint)
    }

    func agentSessionLinkPublishRunCatalogProjection(
        _ projection: AgentSessionLinkRunCatalogProjection
    ) {
        guard let endpoint = projection.routeToken?.observerEndpoint else { return }
        let runtime = independentLinkRuntime(for: endpoint) ?? agentSessionLinkOwningViewModel(for: endpoint)?.linkExecutionRuntime
        runtime?.agentSessionLinkPublishRunCatalogProjection(projection, to: endpoint)
    }

    /// Routes one passive status-notice queue to the exact incarnation it was reduced for.
    ///
    /// Addressed like every other publication here: a session UUID is not an address, and a queue
    /// handed to a namesake incarnation would let it claim notices about targets it never observed.
    func agentSessionLinkPublishPassiveStatusNotices(
        _ snapshot: AgentSessionLinkPassiveStatusNotices.Snapshot,
        to endpoint: DomainAgentSessionLinkEndpointIdentity
    ) {
        let runtime = independentLinkRuntime(for: endpoint) ?? agentSessionLinkOwningViewModel(for: endpoint)?.linkExecutionRuntime
        runtime?.agentSessionLinkPublishPassiveStatusNotices(snapshot, to: endpoint)
    }

    func agentSessionLinkWillActivate(_ endpoint: DomainAgentSessionLinkEndpointIdentity) async {
        guard let viewModel = agentSessionLinkOwningViewModel(for: endpoint) else { return }
        await viewModel.agentSessionLinkWillActivate(endpoint)
    }

    func agentSessionLinkWithholdPromptInventory(
        for endpoint: DomainAgentSessionLinkEndpointIdentity
    ) -> UInt64? {
        let runtime = independentLinkRuntime(for: endpoint) ?? agentSessionLinkOwningViewModel(for: endpoint)?.linkExecutionRuntime
        return runtime?.agentSessionLinkWithholdPromptInventory(for: endpoint)
    }

    func agentSessionLinkReleasePromptInventoryHold(
        _ token: UInt64?,
        for endpoint: DomainAgentSessionLinkEndpointIdentity,
        publishing inventory: AgentSessionLinkPromptInventory?
    ) {
        let runtime = independentLinkRuntime(for: endpoint) ?? agentSessionLinkOwningViewModel(for: endpoint)?.linkExecutionRuntime
        runtime?.agentSessionLinkReleasePromptInventoryHold(
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
        guard !isTerminating,
              case let .unique(writer) = AgentSessionRuntimeStore.shared.resolveWriter(
                  sessionID: candidate.sessionID, expectedWorkspaceID: candidate.workspaceID
              ), let runtime = writer.scope.linkExecution
        else { return .failure(.endpointInvalidated) }
        let sourceIsAvailable: @MainActor () -> Bool
        if writer.scope.executableHost?.workspaceActivation?.isCurrent == true {
            sourceIsAvailable = { [weak self] in self?.isTerminating == false }
        } else {
            guard let window = window(withID: candidate.windowID),
                  window.agentModeViewModel.linkExecutionRuntime === runtime
            else { return .failure(.endpointInvalidated) }
            sourceIsAvailable = { [weak self, weak window] in
                guard let self, let window else { return false }
                return !isTerminating && !window.isClosing && self.window(withID: candidate.windowID) === window
            }
        }
        return await runtime.agentSessionLinkTranscriptPage(
            for: candidate,
            anchor: anchor,
            direction: direction,
            maxItems: maxItems,
            maxOutputBytes: maxOutputBytes,
            readerSessionID: readerSessionID,
            sourceIsAvailable: sourceIsAvailable
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
        let targetWindowIsClosing = independentLinkRuntime(for: target) == nil && (targetWindow.map(\.isClosing) ?? true)
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
        let independent = agentRuntimeStore.retainedExecutionHosts.filter { $0.routeID == windowID && $0.route.identity.kind == .independent }
        if independent.count == 1, let host = independent.first {
            return host.workspaceActivation?.modelAvailability ?? .none
        }
        guard independent.isEmpty, let window = modelRoutingWindow(withID: windowID) else { return .none }
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

    /// Routes managed steering through the exact session writer. The liveness probe still
    /// supplies the host's current presentation-close admission policy.
    func agentSessionLinkPerformSteer(
        to candidate: AgentSessionLinkEndpointCandidate,
        request: AgentSessionLinkSendRequest,
        liveness: @escaping AgentSessionLinkSendLivenessProbe,
        commitAuthorization: @MainActor () async -> AgentSessionLinkSendCommitOutcome
    ) async -> AgentSessionLinkSendTransactionOutcome {
        guard !isTerminating else { return .blocked(.shuttingDown) }
        guard let runtime = agentSessionLinkCommandRuntime(for: candidate) else {
            return .blocked(.endpointHost)
        }
        return await runtime.agentSessionLinkPerformSteer(
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

    /// Inspects the canonical writer's interaction runtime without activating presentation.
    func agentSessionLinkPendingInteraction(
        for candidate: AgentSessionLinkEndpointCandidate
    ) -> AgentSessionLinkPendingInteractionInspection {
        guard !isTerminating,
              independentLinkRuntime(for: candidate.domainEndpoint) != nil || window(withID: candidate.windowID)?.isClosing == false,
              let runtime = agentSessionLinkCommandRuntime(for: candidate)
        else { return .none }
        return runtime.agentSessionLinkPendingInteraction(for: candidate)
    }

    /// Routes an observer answer through the target writer, retaining request-scoped authority.
    func agentSessionLinkRespondToPendingInteraction(
        for candidate: AgentSessionLinkEndpointCandidate,
        request: AgentSessionLinkInteractionResponseRequest,
        authorize: @escaping @MainActor @Sendable () async -> Bool
    ) async -> AgentSessionLinkInteractionResponseOutcome {
        guard !isTerminating,
              independentLinkRuntime(for: candidate.domainEndpoint) != nil || window(withID: candidate.windowID)?.isClosing == false,
              let runtime = agentSessionLinkCommandRuntime(for: candidate)
        else { return .unavailable }
        return await runtime.agentSessionLinkRespondToPendingInteraction(
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
