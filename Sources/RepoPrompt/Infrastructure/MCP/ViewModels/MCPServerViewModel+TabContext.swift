import Combine
import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptFoundation
import RepoPromptMCPServer
import RepoPromptShared
import RepoPromptVCS
import RepoPromptWorkspaceContext
import RepoPromptWorkspaceCore

#if DEBUG
    private func tabContextLog(_ message: @autoclosure () -> String) {
        // print("[TabContext] \(message())")
    }
#else
    private func tabContextLog(_ message: @autoclosure () -> String) {}
#endif

extension MCPServerViewModel {
    struct ContextBuilderCommittedTabSnapshot {
        let identity: WorkspaceSelectionIdentity
        let nestedRunID: UUID
        let tab: ComposeTabState
        let selectionRevision: UInt64
        let usedAgentOutputAsPrompt: Bool
    }

    struct ContextBuilderTabContextCommitResult {
        let outcome: ContextBuilderTabContextCommitOutcome
        let committedTab: ContextBuilderCommittedTabSnapshot?
    }

    private struct CommittedTabWrite {
        let identity: WorkspaceSelectionIdentity
        let tab: ComposeTabState
        let selectionRevision: UInt64
        let usedAgentOutputAsPrompt: Bool
    }

    enum ContextBuilderTabContextCommitOutcome: Equatable {
        case committed
        case staleOrNoLongerCurrent
        case missingFinalContext(runID: UUID, connectionID: UUID?)
        case failed(String)
    }

    enum ContextBuilderTeardownPublicationOutcome: Equatable {
        case peerEOFDetached
        case detachedAfterResponseDeliveryDrained(reason: String)
        case detachedWithoutOrderlyPeerEOF(reason: String)
        case resolvedWithoutPeerEOFDetachment(reason: String)
        case timedOut
        case cancelled

        var completedDiscoveryCanCommit: Bool {
            switch self {
            case .peerEOFDetached, .detachedAfterResponseDeliveryDrained:
                true
            case .detachedWithoutOrderlyPeerEOF, .resolvedWithoutPeerEOFDetachment, .timedOut, .cancelled:
                false
            }
        }

        var diagnosticSource: String {
            switch self {
            case .peerEOFDetached:
                "peer_eof_detached"
            case let .detachedAfterResponseDeliveryDrained(reason):
                "detached_after_response_delivery_drained:\(reason)"
            case let .detachedWithoutOrderlyPeerEOF(reason):
                "detached_without_orderly_peer_eof:\(reason)"
            case let .resolvedWithoutPeerEOFDetachment(reason):
                "resolved_without_detachment:\(reason)"
            case .timedOut:
                "timeout"
            case .cancelled:
                "cancelled"
            }
        }
    }

    @MainActor
    final class ContextBuilderTeardownPublicationCoordinator {
        struct Key: Hashable {
            let runID: UUID
            let connectionID: UUID
        }

        private struct Waiter {
            let continuation: CheckedContinuation<ContextBuilderTeardownPublicationOutcome, Never>
            let timeoutWorkItem: DispatchWorkItem
        }

        private var retainedOutcomes: [Key: ContextBuilderTeardownPublicationOutcome] = [:]
        private var retainedOutcomeOrder: [Key] = []
        private var waiters: [Key: [UUID: Waiter]] = [:]
        private let retainedOutcomeLimit = 64

        func publish(
            _ outcome: ContextBuilderTeardownPublicationOutcome,
            runID: UUID,
            connectionID: UUID
        ) {
            let key = Key(runID: runID, connectionID: connectionID)
            guard retainedOutcomes[key] == nil else { return }
            retainedOutcomes[key] = outcome
            retainedOutcomeOrder.removeAll { $0 == key }
            retainedOutcomeOrder.append(key)
            while retainedOutcomeOrder.count > retainedOutcomeLimit {
                let expired = retainedOutcomeOrder.removeFirst()
                retainedOutcomes.removeValue(forKey: expired)
            }
            let pending = waiters.removeValue(forKey: key)?.values ?? [:].values
            for waiter in pending {
                waiter.timeoutWorkItem.cancel()
                waiter.continuation.resume(returning: outcome)
            }
        }

        func wait(
            runID: UUID,
            connectionID: UUID,
            timeoutSeconds: TimeInterval
        ) async -> ContextBuilderTeardownPublicationOutcome {
            let key = Key(runID: runID, connectionID: connectionID)
            if let outcome = retainedOutcomes[key] { return outcome }

            let waiterID = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if let outcome = retainedOutcomes[key] {
                        continuation.resume(returning: outcome)
                        return
                    }
                    let timeoutWorkItem = DispatchWorkItem { [weak self] in
                        Task { @MainActor in
                            self?.resolveWaiter(
                                key: key,
                                waiterID: waiterID,
                                outcome: .timedOut
                            )
                        }
                    }
                    waiters[key, default: [:]][waiterID] = Waiter(
                        continuation: continuation,
                        timeoutWorkItem: timeoutWorkItem
                    )
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + timeoutSeconds,
                        execute: timeoutWorkItem
                    )
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.resolveWaiter(
                        key: key,
                        waiterID: waiterID,
                        outcome: .cancelled
                    )
                }
            }
        }

        private func resolveWaiter(
            key: Key,
            waiterID: UUID,
            outcome: ContextBuilderTeardownPublicationOutcome
        ) {
            guard let waiter = waiters[key]?.removeValue(forKey: waiterID) else { return }
            if waiters[key]?.isEmpty == true {
                waiters.removeValue(forKey: key)
            }
            waiter.timeoutWorkItem.cancel()
            waiter.continuation.resume(returning: outcome)
        }
    }

    typealias PendingPolicyRunIDMappingToken = MCPRunRouteBindings.PendingPolicyToken

    enum PendingPolicyRunIDMappingRollbackResult: Equatable {
        case restored
        case supersededBySameConnection
        case supersededByOtherConnection
    }

    /// Value snapshot of a compose tab plus MCP routing metadata.
    ///
    /// This is the tab-first runtime model for MCP/Agent work. It intentionally
    /// does not change persisted `WorkspaceModel` / `ComposeTabState` schemas.
    typealias TabContextSnapshot = MCPTabContextSnapshot

    typealias TabContextSnapshotSource = MCPTabContextSnapshotSource

    enum MCPTabContextSelectionMirrorPolicy {
        struct Result: Equatable {
            let selection: StoredSelection
            let preservedManualMode: Bool
        }

        static func isExplicitAutoReset(_ selection: StoredSelection) -> Bool {
            selection.codemapAutoEnabled
                && selection.selectedPaths.isEmpty
                && selection.manualCodemapPaths.isEmpty
                && selection.slices.isEmpty
        }

        static func reconcileIncomingSnapshotSelection(
            boundSelection: StoredSelection,
            incomingSnapshotSelection: StoredSelection,
            isRunScopedWorktreeContext: Bool
        ) -> Result {
            if isRunScopedWorktreeContext {
                return Result(selection: boundSelection, preservedManualMode: false)
            }

            if boundSelection.codemapAutoEnabled == false,
               incomingSnapshotSelection.codemapAutoEnabled,
               !isExplicitAutoReset(incomingSnapshotSelection)
            {
                return Result(
                    selection: StoredSelection(
                        selectedPaths: incomingSnapshotSelection.selectedPaths,
                        manualCodemapPaths: boundSelection.manualCodemapPaths,
                        slices: incomingSnapshotSelection.slices,
                        codemapAutoEnabled: false
                    ),
                    preservedManualMode: true
                )
            }

            return Result(selection: incomingSnapshotSelection, preservedManualMode: false)
        }
    }

    typealias TabContextHint = MCPTabContextHint

    typealias TabContextResolution = MCPTabContextResolution

    typealias ConnectionBindingSnapshot = MCPConnectionBindingSnapshot

    // MARK: - Auto-binding for headless clients

    /// Identify headless agent clients we want to auto-bind
    private func isHeadlessClientName(_ name: String) -> Bool {
        MCPClientIdentity.isHeadlessAgentClient(name)
    }

    @MainActor
    private func recordLastContext(route routeResources: MCPHostRouteResources, clientName: String, context: MCPTabContextSnapshot) {
        var perWindow = routeResources.runRouteBindings.lastContextByClientAndWindow[clientName] ?? [:]
        perWindow[context.windowID] = context
        routeResources.runRouteBindings.lastContextByClientAndWindow[clientName] = perWindow
    }

    @MainActor
    private static func popPendingContextForBinding(
        from store: inout MCPRunRouteBindings.PendingRunScopedContextStore,
        clientName: String,
        windowID: Int,
        runHint: UUID?
    ) -> (context: MCPTabContextSnapshot?, remaining: Int, usedRunHint: Bool) {
        guard let runHint else {
            return (nil, store.queueLength(clientName: clientName, windowID: windowID), false)
        }
        let result = store.pop(clientName: clientName, windowID: windowID, runID: runHint)
        let usedRunHint = result.context?.runID == runHint
        return (result.context, result.remaining, usedRunHint)
    }

    @MainActor
    private func shouldKeepBinding(
        route routeResources: MCPHostRouteResources,
        connectionID: UUID,
        clientName: String?,
        providedWindowID: Int?,
        bound: MCPTabContextSnapshot
    ) -> Bool {
        // Always keep bindings tied to an active discovery run – they manage their own lifecycle.
        if bound.runID != nil {
            return true
        }

        // Always keep explicit bindings from bind_context / _tabID – they persist regardless of active tab.
        if bound.explicitlyBound {
            return true
        }

        guard let manager = workspaceManager else {
            return false
        }

        guard
            let workspaceID = bound.workspaceID,
            let workspaceIndex = manager.workspaces.firstIndex(where: { $0.id == workspaceID }),
            manager.workspaces[workspaceIndex].composeTabs.contains(where: { $0.id == bound.tabID })
        else {
            return false
        }

        if let hinted = providedWindowID, hinted != bound.windowID {
            return false
        }

        // For headless clients with implicit auto-binding, release binding when
        // there's no pending work and the bound tab is not the active tab.
        // This allows the client to rebind to the new active tab.
        if let clientName, isHeadlessClientName(clientName) {
            let hasPending: Bool = if let runID = routeResources.runRouteBindings.connectionIDToRunID[connectionID] {
                routeResources.runRouteBindings.pendingRunScopedTabContexts.contains(clientName: clientName, windowID: bound.windowID, runID: runID)
            } else {
                routeResources.runRouteBindings.pendingRunScopedTabContexts.queueLength(clientName: clientName, windowID: bound.windowID) > 0
            }
            let isActiveTab = (manager.workspaces[workspaceIndex].activeComposeTabID == bound.tabID)
            if !hasPending, !isActiveTab {
                return false
            }
        }

        return true
    }

    @MainActor
    private func removeRunIDMapping(route routeResources: MCPHostRouteResources, runID: UUID, connectionID: UUID) {
        if routeResources.runRouteBindings.connectionIDByRunID[runID] == connectionID {
            routeResources.runRouteBindings.connectionIDByRunID.removeValue(forKey: runID)
        }
        if routeResources.runRouteBindings.connectionIDToRunID[connectionID] == runID {
            routeResources.runRouteBindings.connectionIDToRunID.removeValue(forKey: connectionID)
        }
    }

    @MainActor
    private func readFileAutoSelectionContextKey(
        connectionID: UUID,
        context: MCPTabContextSnapshot
    ) -> MCPReadFileAutoSelectionCoordinator.ContextKey {
        MCPReadFileAutoSelectionCoordinator.ContextKey(
            windowID: context.windowID,
            workspaceID: context.workspaceID,
            tabID: context.tabID,
            route: .bound(connectionID: connectionID, runID: context.runID),
            bindingGeneration: context.readFileAutoSelectionGeneration
        )
    }

    @MainActor
    private func activateReadFileAutoSelection(route routeResources: MCPHostRouteResources, _ context: inout MCPTabContextSnapshot) {
        routeResources.runRouteBindings.nextReadFileAutoSelectionBindingGeneration &+= 1
        context.readFileAutoSelectionGeneration = routeResources.runRouteBindings.nextReadFileAutoSelectionBindingGeneration
    }

    @MainActor
    private func invalidateReadFileAutoSelection(route routeResources: MCPHostRouteResources, connectionID: UUID, context: MCPTabContextSnapshot) {
        let key = readFileAutoSelectionContextKey(connectionID: connectionID, context: context)
        evictReadFileAutoSelectionCoverageCertificate(for: key)
        #if DEBUG
            readFileAutoSelectionForcedAuthoritativeProbeIDsByContext.removeValue(forKey: key)
            let serverIdentity = ObjectIdentifier(self)
            Task {
                await MCPReadFileAutoSelectionProbeRegistry.shared.cancel(
                    serverIdentity: serverIdentity,
                    contextKey: key
                )
                await MCPApplyEditsRebaseProbeRegistry.shared.cancel(
                    serverIdentity: serverIdentity,
                    contextKey: key
                )
            }
        #endif
        readFileAutoSelectionCoordinator(route: routeResources).invalidate(context: key)
    }

    @MainActor
    private func releaseBinding(route routeResources: MCPHostRouteResources, connectionID: UUID, preserveConnectionRunIDMapping: Bool = false) {
        routeResources.runRouteBindings.readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: connectionID)
        fileToolLookupContextCacheByConnectionID.removeValue(forKey: connectionID)
        pendingFileToolLookupContextResolutionByConnectionID.removeValue(forKey: connectionID)?.task.cancel()
        guard let context = routeResources.runRouteBindings.tabContextByConnectionID.removeValue(forKey: connectionID) else { return }
        routeResources.publishRelease(connectionID: connectionID)
        invalidateReadFileAutoSelection(route: routeResources, connectionID: connectionID, context: context)
        endMirroringForConnection(connectionID)
        routeResources.runRouteBindings.presentationWindowByConnection.removeValue(forKey: connectionID)
        let updatedMappings = Self.runMappingsAfterBindingRelease(
            contextRunID: context.runID,
            connectionID: connectionID,
            connectionIDByRunID: routeResources.runRouteBindings.connectionIDByRunID,
            connectionIDToRunID: routeResources.runRouteBindings.connectionIDToRunID,
            preserveConnectionRunIDMapping: preserveConnectionRunIDMapping
        )
        routeResources.runRouteBindings.connectionIDByRunID = updatedMappings.connectionIDByRunID
        routeResources.runRouteBindings.connectionIDToRunID = updatedMappings.connectionIDToRunID
        tabContextLog("releaseBinding connectionID=\(connectionID) tab=\(context.tabID) window=\(context.windowID) preserveRunMapping=\(preserveConnectionRunIDMapping)")
    }

    nonisolated static func runMappingsAfterBindingRelease(
        contextRunID: UUID?,
        connectionID: UUID,
        connectionIDByRunID: [UUID: UUID],
        connectionIDToRunID: [UUID: UUID],
        preserveConnectionRunIDMapping: Bool
    ) -> (connectionIDByRunID: [UUID: UUID], connectionIDToRunID: [UUID: UUID]) {
        var byRun = connectionIDByRunID
        var toRun = connectionIDToRunID
        if let contextRunID {
            if byRun[contextRunID] == connectionID {
                byRun.removeValue(forKey: contextRunID)
            }
            if !preserveConnectionRunIDMapping, toRun[connectionID] == contextRunID {
                toRun.removeValue(forKey: connectionID)
            }
        } else if !preserveConnectionRunIDMapping {
            toRun.removeValue(forKey: connectionID)
        }
        return (byRun, toRun)
    }

    @MainActor
    private func beginMirroringForConnection(route routeResources: MCPHostRouteResources, _ connectionID: UUID, context: MCPTabContextSnapshot) {
        if tabContextCancellablesByConnectionID[connectionID] != nil { return }

        guard let manager = workspaceManager else {
            tabContextLog("beginMirroring skipped - no workspace manager connectionID=\(connectionID)")
            return
        }
        tabContextLog("beginMirroring connectionID=\(connectionID) tab=\(context.tabID) runID=\(context.runID?.uuidString ?? "nil")")

        var bag = Set<AnyCancellable>()

        manager.composeTabSnapshotPublisher(for: context.tabID)
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                Task { @MainActor in
                    guard let self else { return }

                    // 1) Skip stale snapshots by lastModified
                    if let live = manager.composeTab(with: context.tabID),
                       snapshot.lastModified < live.lastModified
                    {
                        tabContextLog("skip stale snapshot connectionID=\(connectionID) tab=\(context.tabID) snapshot.ts=\(snapshot.lastModified) live.ts=\(live.lastModified)")
                        return
                    }

                    // 2) Keep the existing transient-snapshot guard
                    if let storedSelection = manager.composeTab(with: context.tabID)?.selection,
                       snapshot.selection != storedSelection
                    {
                        let incomingCount = snapshot.selection.selectedPaths.count
                        let storedCount = storedSelection.selectedPaths.count
                        tabContextLog("skip transient snapshot connectionID=\(connectionID) tab=\(context.tabID) incomingSelCount=\(incomingCount) storedSelCount=\(storedCount)")
                        return
                    }

                    // 3) Merge snapshot into bound context, but preserve frozen run-scoped
                    // worktree selection. The visible compose-tab snapshot can lag or be
                    // intentionally empty for hidden worktree runs; importing it would erase
                    // the source selection used by run-scoped tools.
                    guard var bound = routeResources.runRouteBindings.tabContextByConnectionID[connectionID] else { return }
                    let mirrorResult = MCPTabContextSelectionMirrorPolicy.reconcileIncomingSnapshotSelection(
                        boundSelection: bound.selection,
                        incomingSnapshotSelection: snapshot.selection,
                        isRunScopedWorktreeContext: bound.runID != nil && !bound.worktreeBindings.isEmpty
                    )
                    let incomingSelection = mirrorResult.selection
                    if mirrorResult.preservedManualMode {
                        // DON'T call commitTabContext here - it creates an infinite loop!
                        // The bound context correction is enough; next operation will sync to UI.
                        tabContextLog("preserved manual mode on snapshot connectionID=\(connectionID) tab=\(context.tabID)")
                    }

                    // 4) Apply if changed
                    let selectionChanged = bound.selection != incomingSelection
                    let promptChanged = bound.promptText != snapshot.promptText
                    let metaChanged = bound.selectedMetaPromptIDs != snapshot.selectedMetaPromptIDs
                    let nameChanged = bound.tabName != snapshot.name
                    let incomingBindingState = snapshot.activeAgentSessionID.map {
                        self.agentWorktreeBindingStateProvider?($0, snapshot.id) ?? .unhydrated
                    } ?? .notApplicable
                    let sourceChanged = bound.runID == nil
                        && AgentWorkspaceLookupContextSource(
                            activeAgentSessionID: bound.activeAgentSessionID,
                            worktreeBindingState: bound.worktreeBindingState
                        ).identity != AgentWorkspaceLookupContextSource(
                            activeAgentSessionID: snapshot.activeAgentSessionID,
                            worktreeBindingState: incomingBindingState
                        ).identity
                    if selectionChanged || promptChanged || metaChanged || nameChanged || sourceChanged {
                        bound.selection = incomingSelection
                        if let workspaceID = bound.workspaceID {
                            bound.selectionRevision = manager.selectionRevisionForMCP(
                                workspaceID: workspaceID,
                                tabID: bound.tabID
                            )
                        }
                        bound.promptText = snapshot.promptText
                        bound.selectedMetaPromptIDs = snapshot.selectedMetaPromptIDs
                        bound.tabName = snapshot.name
                        if sourceChanged {
                            self.replaceFileToolBindingSource(
                                route: routeResources,
                                connectionID: connectionID,
                                context: &bound,
                                activeAgentSessionID: snapshot.activeAgentSessionID,
                                worktreeBindingState: incomingBindingState
                            )
                        }
                        routeResources.runRouteBindings.tabContextByConnectionID[connectionID] = bound
                        tabContextLog("applied snapshot connectionID=\(connectionID) tab=\(context.tabID) selCount=\(incomingSelection.selectedPaths.count) promptChars=\(snapshot.promptText.count)")
                    }
                }
            }
            .store(in: &bag)

        tabContextCancellablesByConnectionID[connectionID] = bag
    }

    @MainActor
    private func endMirroringForConnection(_ connectionID: UUID) {
        tabContextLog("endMirroring connectionID=\(connectionID)")
        tabContextCancellablesByConnectionID[connectionID]?.forEach { $0.cancel() }
        tabContextCancellablesByConnectionID.removeValue(forKey: connectionID)
    }

    @MainActor
    func pushVirtualContextToUI(_ context: MCPTabContextSnapshot) async {
        // `commitTabContext` already recounts when it applies the active tab. Avoid a
        // duplicate immediate recount after the heavy file-selector projection.
        await commitTabContext(context)
    }

    @MainActor
    func pendingContextQueueLength(route routeResources: MCPHostRouteResources, clientName: String, windowID: Int) -> Int {
        routeResources.runRouteBindings.pendingRunScopedTabContexts.queueLength(clientName: clientName, windowID: windowID)
    }

    // MARK: - Tab Binding APIs for MCP Routing

    /// Returns the currently bound tab ID for a connection, if any.
    /// Only returns a tab ID if the binding is for this window.
    @MainActor
    func boundTabID(route routeResources: MCPHostRouteResources, forConnection connectionID: UUID?) -> UUID? {
        guard let connectionID,
              let ctx = routeResources.runRouteBindings.tabContextByConnectionID[connectionID]
        else { return nil }

        // Only treat it as "bound here" if this MCPServerViewModel owns that window
        guard ctx.windowID == routeResources.identity.routeID else { return nil }
        return ctx.tabID
    }

    #if DEBUG
        @MainActor
        func debugSelectionRevisionForBoundConnection(_ connectionID: UUID) -> UInt64? {
            routeResources.runRouteBindings.tabContextByConnectionID[connectionID]?.selectionRevision
        }
    #endif

    @MainActor
    func connectionBindingSnapshot(route routeResources: MCPHostRouteResources, forConnection connectionID: UUID) -> MCPConnectionBindingSnapshot {
        if let context = routeResources.runRouteBindings.tabContextByConnectionID[connectionID],
           context.windowID == routeResources.identity.routeID
        {
            let workspace = context.workspaceID.flatMap { workspaceID in
                workspaceManager?.workspaces.first(where: { $0.id == workspaceID })
            }
            let resolvedTabName =
                workspaceManager?.composeTabName(with: context.tabID)
                    ?? promptVM.currentComposeTabs.first(where: { $0.id == context.tabID })?.name
                    ?? context.tabName
            return MCPConnectionBindingSnapshot(
                windowID: context.windowID,
                tabID: context.tabID,
                workspaceID: context.workspaceID,
                workspaceName: workspace?.name,
                tabName: resolvedTabName,
                repoPaths: workspace?.repoPaths ?? [],
                explicitlyBound: context.explicitlyBound,
                runID: context.runID
            )
        }

        if let mappedWindowID = routeResources.runRouteBindings.presentationWindowByConnection[connectionID],
           mappedWindowID == routeResources.identity.routeID
        {
            let workspace = workspaceManager?.activeWorkspace
            return MCPConnectionBindingSnapshot(
                windowID: mappedWindowID,
                tabID: nil,
                workspaceID: workspace?.id,
                workspaceName: workspace?.name,
                tabName: nil,
                repoPaths: workspace?.repoPaths ?? [],
                explicitlyBound: false,
                runID: nil
            )
        }

        return MCPConnectionBindingSnapshot(
            windowID: nil,
            tabID: nil,
            workspaceID: nil,
            workspaceName: nil,
            tabName: nil,
            repoPaths: [],
            explicitlyBound: false,
            runID: nil
        )
    }

    @MainActor
    func clearExplicitBinding(route routeResources: MCPHostRouteResources, forConnection connectionID: UUID) -> MCPConnectionBindingSnapshot? {
        guard let context = routeResources.runRouteBindings.tabContextByConnectionID[connectionID],
              context.windowID == routeResources.identity.routeID,
              context.runID == nil,
              context.explicitlyBound
        else {
            return nil
        }

        let snapshot = connectionBindingSnapshot(route: routeResources, forConnection: connectionID)
        releaseBinding(route: routeResources, connectionID: connectionID)
        return snapshot
    }

    @MainActor
    func clearNonRunScopedBinding(route routeResources: MCPHostRouteResources, forConnection connectionID: UUID) -> MCPConnectionBindingSnapshot? {
        guard let context = routeResources.runRouteBindings.tabContextByConnectionID[connectionID],
              context.windowID == routeResources.identity.routeID,
              context.runID == nil
        else {
            return nil
        }

        let snapshot = connectionBindingSnapshot(route: routeResources, forConnection: connectionID)
        releaseBinding(route: routeResources, connectionID: connectionID)
        return snapshot
    }

    /// Proactively removes all cached tab-context state for a closing tab while preserving window affinity.
    @MainActor
    func purgeClosedTabContext(route routeResources: MCPHostRouteResources, tabID: UUID) {
        gitArtifactAdvertisementRegistry.removeTab(tabID: tabID)
        let boundConnections = routeResources.runRouteBindings.tabContextByConnectionID.compactMap { connectionID, context in
            context.tabID == tabID ? connectionID : nil
        }

        for connectionID in boundConnections {
            routeResources.runRouteBindings.readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: connectionID)
            fileToolLookupContextCacheByConnectionID.removeValue(forKey: connectionID)
            pendingFileToolLookupContextResolutionByConnectionID.removeValue(forKey: connectionID)?.task.cancel()
            guard let context = routeResources.runRouteBindings.tabContextByConnectionID.removeValue(forKey: connectionID) else { continue }
            invalidateReadFileAutoSelection(route: routeResources, connectionID: connectionID, context: context)
            endMirroringForConnection(connectionID)
            if let runID = context.runID {
                cleanupRunIDMapping(route: routeResources, runID: runID, connectionID: connectionID)
            } else {
                routeResources.runRouteBindings.connectionIDToRunID.removeValue(forKey: connectionID)
            }
            tabContextLog("purgeClosedTabContext removed bound context connectionID=\(connectionID) tab=\(tabID)")
        }

        let removedPending = routeResources.runRouteBindings.pendingRunScopedTabContexts.purge(tabID: tabID)
        if !removedPending.isEmpty {
            tabContextLog("purgeClosedTabContext removed \(removedPending.count) pending contexts for tab=\(tabID)")
        }

        for (clientName, perWindow) in routeResources.runRouteBindings.lastContextByClientAndWindow {
            let filtered = perWindow.filter { $0.value.tabID != tabID }
            if filtered.isEmpty {
                routeResources.runRouteBindings.lastContextByClientAndWindow.removeValue(forKey: clientName)
            } else if filtered.count != perWindow.count {
                routeResources.runRouteBindings.lastContextByClientAndWindow[clientName] = filtered
            }
        }
    }

    enum TabBindError: Swift.Error {
        case missingWorkspace
        case workspaceNotLoaded(UUID)
        case tabNotFound(UUID)
        case runMappingRejected(UUID)
    }

    @MainActor
    func makeTabContextSnapshot(
        tabID: UUID,
        workspaceID requestedWorkspaceID: UUID?,
        windowID: Int,
        runID: UUID?,
        explicitlyBound: Bool,
        captureActiveUIState: Bool,
        flushActiveSelection: Bool
    ) throws -> MCPTabContextSnapshot {
        guard let manager = workspaceManager else {
            throw TabBindError.missingWorkspace
        }
        guard let stored = manager.collectMCPTabContextComposeSnapshot(
            tabID: tabID,
            workspaceID: requestedWorkspaceID,
            captureActiveUIState: false,
            flushPendingUISelection: false
        ) else {
            if let requestedWorkspaceID,
               !manager.workspaces.contains(where: { $0.id == requestedWorkspaceID })
            {
                throw TabBindError.workspaceNotLoaded(requestedWorkspaceID)
            }
            throw TabBindError.tabNotFound(tabID)
        }

        let storedSnapshot = stored.snapshot
        let storedWorktreeBindingState = storedSnapshot.activeAgentSessionID.map {
            agentWorktreeBindingStateProvider?($0, storedSnapshot.id) ?? .unhydrated
        } ?? .notApplicable
        let preserveStoredSelection = storedWorktreeBindingState.bindings?.isEmpty == false
        let captured = manager.collectMCPTabContextComposeSnapshot(
            tabID: tabID,
            workspaceID: stored.workspaceID,
            captureActiveUIState: captureActiveUIState,
            // Worktree-only paths intentionally are not mirrored into the logical base UI.
            // Flushing that UI would erase the canonical tab selection on the next request.
            flushPendingUISelection: flushActiveSelection && !preserveStoredSelection
        ) ?? stored
        var snapshot = captured.snapshot
        if preserveStoredSelection {
            snapshot.selection = storedSnapshot.selection
        }
        return MCPTabContextSnapshot(
            tabID: snapshot.id,
            windowID: windowID,
            workspaceID: captured.workspaceID,
            promptText: snapshot.promptText,
            selection: snapshot.selection,
            selectionRevision: manager.selectionRevisionForMCP(
                workspaceID: captured.workspaceID,
                tabID: snapshot.id
            ),
            selectedMetaPromptIDs: snapshot.selectedMetaPromptIDs,
            selectedContextBuilderPromptIDs: snapshot.contextBuilder.selectedContextBuilderPromptIDs,
            tabName: snapshot.name,
            runID: runID,
            activeAgentSessionID: snapshot.activeAgentSessionID,
            worktreeBindingState: snapshot.activeAgentSessionID.map {
                agentWorktreeBindingStateProvider?($0, snapshot.id) ?? .unhydrated
            } ?? .notApplicable,
            explicitlyBound: explicitlyBound
        )
    }

    @MainActor
    private func makeTabContextSnapshot(
        from composeSnapshot: ComposeTabState,
        workspaceID requestedWorkspaceID: UUID?,
        windowID: Int,
        runID: UUID?,
        explicitlyBound: Bool,
        captureActiveUIState: Bool,
        flushActiveSelection: Bool
    ) -> MCPTabContextSnapshot {
        let resolvedWorkspaceID: UUID? = {
            if let requestedWorkspaceID { return requestedWorkspaceID }
            return workspaceManager?.workspaces.first(where: { workspace in
                workspace.composeTabs.contains(where: { $0.id == composeSnapshot.id })
            })?.id ?? workspaceManager?.activeWorkspace?.id
        }()

        if captureActiveUIState,
           let resolvedWorkspaceID,
           let captured = workspaceManager?.collectMCPTabContextComposeSnapshot(
               tabID: composeSnapshot.id,
               workspaceID: resolvedWorkspaceID,
               captureActiveUIState: true,
               flushPendingUISelection: flushActiveSelection
           )
        {
            let snapshot = captured.snapshot
            return MCPTabContextSnapshot(
                tabID: snapshot.id,
                windowID: windowID,
                workspaceID: captured.workspaceID,
                promptText: snapshot.promptText,
                selection: snapshot.selection,
                selectionRevision: workspaceManager?.selectionRevisionForMCP(
                    workspaceID: captured.workspaceID,
                    tabID: snapshot.id
                ) ?? 0,
                selectedMetaPromptIDs: snapshot.selectedMetaPromptIDs,
                selectedContextBuilderPromptIDs: snapshot.contextBuilder.selectedContextBuilderPromptIDs,
                tabName: snapshot.name,
                runID: runID,
                activeAgentSessionID: snapshot.activeAgentSessionID,
                worktreeBindingState: snapshot.activeAgentSessionID.map {
                    agentWorktreeBindingStateProvider?($0, snapshot.id) ?? .unhydrated
                } ?? .notApplicable,
                explicitlyBound: explicitlyBound
            )
        }

        return MCPTabContextSnapshot(
            tabID: composeSnapshot.id,
            windowID: windowID,
            workspaceID: resolvedWorkspaceID,
            promptText: composeSnapshot.promptText,
            selection: composeSnapshot.selection,
            selectionRevision: resolvedWorkspaceID.map {
                workspaceManager?.selectionRevisionForMCP(
                    workspaceID: $0,
                    tabID: composeSnapshot.id
                ) ?? 0
            } ?? 0,
            selectedMetaPromptIDs: composeSnapshot.selectedMetaPromptIDs,
            selectedContextBuilderPromptIDs: composeSnapshot.contextBuilder.selectedContextBuilderPromptIDs,
            tabName: composeSnapshot.name,
            runID: runID,
            activeAgentSessionID: composeSnapshot.activeAgentSessionID,
            worktreeBindingState: composeSnapshot.activeAgentSessionID.map {
                agentWorktreeBindingStateProvider?($0, composeSnapshot.id) ?? .unhydrated
            } ?? .notApplicable,
            explicitlyBound: explicitlyBound
        )
    }

    /// Binds a connection to a specific compose tab context snapshot.
    /// Used by the primary bind_context/context_id flow and the legacy hidden _tabID alias.
    @MainActor
    func bindTabForConnection(
        route routeResources: MCPHostRouteResources,
        connectionID: UUID,
        clientName: String?,
        tabID: UUID,
        workspaceID: UUID,
        windowID: Int,
        runID: UUID? = nil,
        frozenFileToolAuthority: MCPFrozenFileToolAuthority? = nil,
        explicitlyBound: Bool = true
    ) throws {
        guard let manager = workspaceManager else {
            throw TabBindError.missingWorkspace
        }

        guard let wsIndex = manager.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            throw TabBindError.workspaceNotLoaded(workspaceID)
        }

        let ws = manager.workspaces[wsIndex]
        guard let tab = ws.composeTabs.first(where: { $0.id == tabID }) else {
            throw TabBindError.tabNotFound(tabID)
        }

        // Build the replacement before releasing a usable binding. A stale or otherwise invalid
        // target must not turn a failed rebind into an unbound connection.
        var context = try makeTabContextSnapshot(
            tabID: tab.id,
            workspaceID: ws.id,
            windowID: windowID,
            runID: runID,
            explicitlyBound: explicitlyBound,
            captureActiveUIState: false,
            flushActiveSelection: false
        )
        context.frozenFileToolAuthority = frozenFileToolAuthority

        if routeResources.runRouteBindings.tabContextByConnectionID[connectionID] != nil {
            releaseBinding(route: routeResources, connectionID: connectionID)
        }

        activateReadFileAutoSelection(route: routeResources, &context)
        routeResources.runRouteBindings.tabContextByConnectionID[connectionID] = context
        routeResources.publishBinding(connectionID: connectionID, context: context)
        routeResources.runRouteBindings.presentationWindowByConnection[connectionID] = windowID
        if let runID {
            let mappingSucceeded = registerRunIDMapping(route: routeResources, connectionID: connectionID, runID: runID, windowID: windowID)
            guard mappingSucceeded else {
                fileToolLookupContextCacheByConnectionID.removeValue(forKey: connectionID)
                pendingFileToolLookupContextResolutionByConnectionID.removeValue(forKey: connectionID)?.task.cancel()
                routeResources.runRouteBindings.tabContextByConnectionID.removeValue(forKey: connectionID)
                routeResources.runRouteBindings.presentationWindowByConnection.removeValue(forKey: connectionID)
                throw TabBindError.runMappingRejected(runID)
            }
        }
        if let clientName {
            recordLastContext(route: routeResources, clientName: clientName, context: context)
        }
        beginMirroringForConnection(route: routeResources, connectionID, context: context)
        tabContextLog("bindTabForConnection connectionID=\(connectionID) tab=\(tabID) window=\(windowID) workspace=\(workspaceID) runID=\(runID?.uuidString ?? "nil")")
    }

    /// Rebinds connection to target tab if currently bound to a different tab.
    /// Used by oracle_send when continuing a chat that lives on a different tab.
    /// - Returns: true if rebinding occurred, false if already on correct tab or target invalid
    @MainActor
    @discardableResult
    func rebindToTabIfNeeded(
        route routeResources: MCPHostRouteResources,
        connectionID: UUID,
        clientName: String?,
        windowID: Int,
        targetTabID: UUID,
        targetWorkspaceID: UUID
    ) throws -> Bool {
        let currentBoundTabID = routeResources.runRouteBindings.tabContextByConnectionID[connectionID]?.tabID

        // Already bound to the target tab
        if currentBoundTabID == targetTabID {
            return false
        }

        // Verify target tab exists before rebinding
        guard workspaceManager?.composeTab(with: targetTabID) != nil else {
            tabContextLog("rebindToTabIfNeeded skipped - target tab \(targetTabID) not found")
            return false
        }

        try bindTabForConnection(
            route: routeResources,
            connectionID: connectionID,
            clientName: clientName,
            tabID: targetTabID,
            workspaceID: targetWorkspaceID,
            windowID: windowID
        )
        tabContextLog("rebindToTabIfNeeded migrated connectionID=\(connectionID) to tab=\(targetTabID)")
        return true
    }

    @MainActor
    @discardableResult
    func installTabContext(
        route routeResources: MCPHostRouteResources,
        clientID: String?,
        clientName: String?,
        windowID: Int,
        workspaceID providedWorkspaceID: UUID? = nil,
        snapshot: ComposeTabState,
        runID: UUID? = nil,
        signalRouting: Bool = true,
        deferRunIDReplacementForPendingPolicy: Bool = false
    ) -> PendingPolicyRunIDMappingToken? {
        tabContextLog("installTabContext tab=\(snapshot.id) window=\(windowID) clientID=\(clientID ?? "nil") clientName=\(clientName ?? "nil") runID=\(runID?.uuidString ?? "nil")")
        let resolvedWorkspaceID: UUID? = {
            if let providedWorkspaceID {
                return providedWorkspaceID
            }
            return workspaceManager?.activeWorkspace?.id
        }()

        let context = makeTabContextSnapshot(
            from: snapshot,
            workspaceID: resolvedWorkspaceID,
            windowID: windowID,
            runID: runID,
            explicitlyBound: false, // discovery run binding, not explicit bind_context
            captureActiveUIState: false,
            flushActiveSelection: false
        )
        return installTabContext(
            route: routeResources,
            clientID: clientID,
            clientName: clientName,
            windowID: windowID,
            context: context,
            signalRouting: signalRouting,
            deferRunIDReplacementForPendingPolicy: deferRunIDReplacementForPendingPolicy
        )
    }

    @MainActor
    @discardableResult
    func installFrozenTabContext(
        route routeResources: MCPHostRouteResources,
        clientID: String?,
        clientName: String?,
        context: MCPTabContextSnapshot,
        signalRouting: Bool = true,
        deferRunIDReplacementForPendingPolicy: Bool = false
    ) -> PendingPolicyRunIDMappingToken? {
        tabContextLog("installFrozenTabContext tab=\(context.tabID) window=\(context.windowID) clientID=\(clientID ?? "nil") clientName=\(clientName ?? "nil") runID=\(context.runID?.uuidString ?? "nil")")
        return installTabContext(
            route: routeResources,
            clientID: clientID,
            clientName: clientName,
            windowID: context.windowID,
            context: context,
            signalRouting: signalRouting,
            deferRunIDReplacementForPendingPolicy: deferRunIDReplacementForPendingPolicy
        )
    }

    @MainActor
    private func installTabContext(
        route routeResources: MCPHostRouteResources,
        clientID: String?,
        clientName: String?,
        windowID: Int,
        context initialContext: MCPTabContextSnapshot,
        signalRouting: Bool,
        deferRunIDReplacementForPendingPolicy: Bool
    ) -> PendingPolicyRunIDMappingToken? {
        var context = initialContext
        if let clientID,
           let uuid = UUID(uuidString: clientID)
        {
            // Conflict-safe immediate binding path
            if let existing = routeResources.runRouteBindings.tabContextByConnectionID[uuid],
               let existingRun = existing.runID,
               let newRun = context.runID,
               existingRun != newRun
            {
                // Do not overwrite another run's binding; queue instead (requires clientName)
                tabContextLog("installTabContext declined overwrite connectionID=\(uuid) existingRun=\(existingRun) newRun=\(newRun); queuing by clientName")
                if let clientName {
                    enqueuePendingContext(route: routeResources, context, clientName: clientName, windowID: windowID)
                } else {
                    tabContextLog("[warning] installTabContext conflict but no clientName provided; cannot queue")
                }
                return nil
            }
            if deferRunIDReplacementForPendingPolicy, routeResources.runRouteBindings.tabContextByConnectionID[uuid] != nil {
                tabContextLog("installTabContext declined pending-policy overwrite of existing context connectionID=\(uuid)")
                return nil
            }

            tabContextLog("installTabContext immediate bind connectionID=\(uuid)")
            routeResources.runRouteBindings.readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: uuid)
            if let previous = routeResources.runRouteBindings.tabContextByConnectionID[uuid] {
                invalidateReadFileAutoSelection(route: routeResources, connectionID: uuid, context: previous)
                endMirroringForConnection(uuid)
            }
            activateReadFileAutoSelection(route: routeResources, &context)
            routeResources.runRouteBindings.tabContextByConnectionID[uuid] = context
            routeResources.publishBinding(connectionID: uuid, context: context)
            routeResources.runRouteBindings.presentationWindowByConnection[uuid] = context.windowID
            var pendingPolicyToken: PendingPolicyRunIDMappingToken?
            if let runID = context.runID {
                if deferRunIDReplacementForPendingPolicy {
                    pendingPolicyToken = registerPendingPolicyRunIDMapping(
                        route: routeResources,
                        connectionID: uuid,
                        runID: runID,
                        windowID: context.windowID
                    )
                } else {
                    _ = registerRunIDMapping(
                        route: routeResources,
                        connectionID: uuid,
                        runID: runID,
                        windowID: context.windowID,
                        signalRouting: signalRouting
                    )
                }
                // Consume any queued intent for this exact run after direct installation.
                if let clientName {
                    let popped = routeResources.runRouteBindings.pendingRunScopedTabContexts.popByRunID(clientName: clientName, runID: runID)
                    if popped.context != nil {
                        tabContextLog("installTabContext consumed queued intent for client=\(clientName) runID=\(runID) window=\(windowID) remaining=\(popped.remaining)")
                    }
                }
            }
            if let clientName {
                recordLastContext(route: routeResources, clientName: clientName, context: context)
            }
            beginMirroringForConnection(route: routeResources, uuid, context: context)
            return pendingPolicyToken
        }

        guard let clientName else {
            tabContextLog("[warning] installTabContext missing client identifier; context cannot be queued.")
            return nil
        }

        enqueuePendingContext(route: routeResources, context, clientName: clientName, windowID: windowID)
        return nil
    }

    @MainActor
    private func enqueuePendingContext(route routeResources: MCPHostRouteResources, _ context: MCPTabContextSnapshot, clientName: String, windowID: Int) {
        guard let runID = context.runID else {
            tabContextLog("enqueuePendingContext skipped runless context clientName=\(clientName) window=\(windowID) tab=\(context.tabID)")
            return
        }
        let queueBefore = routeResources.runRouteBindings.pendingRunScopedTabContexts.queueLength(clientName: clientName, windowID: windowID)
        let queueSize = routeResources.runRouteBindings.pendingRunScopedTabContexts.enqueueReplacing(context, clientName: clientName, windowID: windowID)
        recordLastContext(route: routeResources, clientName: clientName, context: context)
        tabContextLog("enqueuePendingContext clientName=\(clientName) window=\(windowID) tab=\(context.tabID) queueBefore=\(queueBefore) queueAfter=\(queueSize) runID=\(runID.uuidString)")
    }

    @MainActor
    private func bindPendingContextToConnection(
        route routeResources: MCPHostRouteResources,
        clientName: String,
        windowID: Int,
        connectionID: UUID,
        registerRunMapping: Bool = true
    ) -> MCPTabContextSnapshot? {
        let queueBefore = routeResources.runRouteBindings.pendingRunScopedTabContexts.queueLength(clientName: clientName, windowID: windowID)
        let runHint = routeResources.runRouteBindings.connectionIDToRunID[connectionID]

        // Only set a hint mapping if we don't already have one; do not override
        if routeResources.runRouteBindings.presentationWindowByConnection[connectionID] == nil {
            routeResources.runRouteBindings.presentationWindowByConnection[connectionID] = windowID
        }
        if let runID = runHint,
           let previousConnection = routeResources.runRouteBindings.connectionIDByRunID[runID],
           previousConnection != connectionID,
           let existing = routeResources.runRouteBindings.tabContextByConnectionID[previousConnection]
        {
            if existing.windowID == windowID {
                routeResources.runRouteBindings.readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: previousConnection)
                routeResources.runRouteBindings.readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: connectionID)
                fileToolLookupContextCacheByConnectionID.removeValue(forKey: previousConnection)
                pendingFileToolLookupContextResolutionByConnectionID.removeValue(forKey: previousConnection)?.task.cancel()
                routeResources.runRouteBindings.tabContextByConnectionID.removeValue(forKey: previousConnection)
                invalidateReadFileAutoSelection(route: routeResources, connectionID: previousConnection, context: existing)
                endMirroringForConnection(previousConnection)
                routeResources.runRouteBindings.connectionIDToRunID.removeValue(forKey: previousConnection)
                routeResources.runRouteBindings.presentationWindowByConnection.removeValue(forKey: previousConnection)
                var rebound = existing
                activateReadFileAutoSelection(route: routeResources, &rebound)
                routeResources.runRouteBindings.tabContextByConnectionID[connectionID] = rebound
                routeResources.runRouteBindings.presentationWindowByConnection[connectionID] = rebound.windowID
                if registerRunMapping {
                    _ = registerRunIDMapping(route: routeResources, connectionID: connectionID, runID: runID, windowID: rebound.windowID)
                }
                recordLastContext(route: routeResources, clientName: clientName, context: rebound)
                beginMirroringForConnection(route: routeResources, connectionID, context: rebound)
                tabContextLog("bindPendingContextToConnection handover: runID=\(runID) tab=\(rebound.tabID) \(previousConnection) -> \(connectionID) queueBefore=\(queueBefore)")
                return rebound
            } else {
                tabContextLog("bindPendingContextToConnection handover skipped window mismatch runID=\(runID) prevWindow=\(existing.windowID) currentWindow=\(windowID)")
            }
        }
        let result = Self.popPendingContextForBinding(
            from: &routeResources.runRouteBindings.pendingRunScopedTabContexts,
            clientName: clientName,
            windowID: windowID,
            runHint: runHint
        )
        var usedRunHint = result.usedRunHint

        if runHint != nil, result.context == nil {
            tabContextLog("bindPendingContextToConnection no exact match for runHint connectionID=\(connectionID) clientName=\(clientName) window=\(windowID) runHint=\(runHint!.uuidString) queueBefore=\(queueBefore) remaining=\(result.remaining)")
        }

        guard var context = result.context else {
            tabContextLog("bindPendingContextToConnection no pending context clientName=\(clientName) window=\(windowID) connectionID=\(connectionID) queueBefore=\(queueBefore) remaining=\(result.remaining) runHint=\(runHint?.uuidString ?? "nil")")
            return nil
        }

        routeResources.runRouteBindings.readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: connectionID)
        activateReadFileAutoSelection(route: routeResources, &context)
        routeResources.runRouteBindings.tabContextByConnectionID[connectionID] = context
        routeResources.publishBinding(connectionID: connectionID, context: context)
        routeResources.runRouteBindings.presentationWindowByConnection[connectionID] = context.windowID
        if let runID = context.runID {
            if registerRunMapping {
                let mappingSucceeded = registerRunIDMapping(route: routeResources, connectionID: connectionID, runID: runID, windowID: context.windowID)
                // If we successfully registered the mapping, or if the initial runHint matched, count it as used
                usedRunHint = usedRunHint || (runHint == runID) || mappingSucceeded
            } else {
                usedRunHint = usedRunHint || runHint == runID
            }
        }
        recordLastContext(route: routeResources, clientName: clientName, context: context)
        beginMirroringForConnection(route: routeResources, connectionID, context: context)

        tabContextLog(
            "bindPendingContextToConnection clientName=\(clientName) window=\(windowID) connectionID=\(connectionID) runID=\(context.runID?.uuidString ?? "nil") tab=\(context.tabID) queueBefore=\(queueBefore) remaining=\(result.remaining) usedRunHint=\(usedRunHint) fallback=false"
        )
        return context
    }

    @MainActor
    @discardableResult
    func promotePendingContextForRunMapping(
        route routeResources: MCPHostRouteResources,
        clientName: String,
        windowID: Int,
        connectionID: UUID
    ) -> MCPTabContextSnapshot? {
        guard routeResources.runRouteBindings.connectionIDToRunID[connectionID] != nil,
              let runID = routeResources.runRouteBindings.connectionIDToRunID[connectionID],
              routeResources.runRouteBindings.pendingRunScopedTabContexts.contains(
                  clientName: clientName,
                  windowID: windowID,
                  runID: runID
              )
        else {
            return nil
        }
        return bindPendingContextToConnection(
            route: routeResources,
            clientName: clientName,
            windowID: windowID,
            connectionID: connectionID,
            registerRunMapping: false
        )
    }

    typealias RequestMetadata = MCPRequestMetadata

    @MainActor
    func updateBoundFileToolAuthority(
        route routeResources: MCPHostRouteResources,
        connectionID: UUID,
        tabID: UUID,
        workspaceID: UUID,
        authority: MCPFrozenFileToolAuthority
    ) {
        guard var context = routeResources.runRouteBindings.tabContextByConnectionID[connectionID],
              context.tabID == tabID,
              context.workspaceID == workspaceID
        else { return }
        context.frozenFileToolAuthority = authority
        routeResources.runRouteBindings.tabContextByConnectionID[connectionID] = context
        routeResources.publishBinding(connectionID: connectionID, context: context)
    }

    @MainActor
    func captureRequestMetadata() async -> MCPRequestMetadata {
        #if DEBUG
            if let requestMetadataOverrideForTesting {
                return requestMetadataOverrideForTesting
            }
        #endif
        // Project the ingress packet before any suspension; its routing evidence is immutable.
        if let invocationContext = MCPInvocationContextBridge.current {
            return invocationContext.metadata
        }
        let connectionID = await service.currentRequestConnectionID()
        let runPurpose: MCPRunPurpose? = if let connectionID {
            await ServerNetworkManager.shared.runPurpose(for: connectionID)
        } else {
            nil
        }
        return await MCPRequestMetadata(
            connectionID: connectionID,
            clientName: service.currentRequestClientName(),
            windowID: service.currentRequestWindowID(),
            runPurpose: runPurpose,
            tabContextHint: ServerNetworkManager.currentTabContextHint,
            explicitWindowRoutingHint: service.currentRequestExplicitWindowRoutingHint()
        )
    }

    @MainActor
    func resolveTabContext(
        route routeResources: MCPHostRouteResources,
        from metadata: MCPRequestMetadata,
        explicitHint: MCPTabContextHint? = nil,
        toolName: String = "unknown",
        startMirroring: Bool = true
    ) throws -> MCPTabContextResolution {
        try resolveTabContext(
            route: routeResources,
            connectionID: metadata.connectionID,
            clientName: metadata.clientName,
            providedWindowID: metadata.windowID,
            explicitHint: explicitHint ?? metadata.tabContextHint,
            toolName: toolName,
            runPurpose: metadata.runPurpose,
            startMirroring: startMirroring
        )
    }

    typealias ResolvedTabContextSnapshot = MCPResolvedTabContextSnapshot

    @MainActor
    func resolveTabContextSnapshot(
        route routeResources: MCPHostRouteResources,
        from metadata: MCPRequestMetadata,
        explicitHint: MCPTabContextHint? = nil,
        toolName: String,
        startMirroring: Bool = true
    ) throws -> MCPResolvedTabContextSnapshot {
        switch try resolveTabContext(
            route: routeResources,
            from: metadata,
            explicitHint: explicitHint,
            toolName: toolName,
            startMirroring: startMirroring
        ) {
        case let .tabContextSnapshot(snapshot, source):
            MCPResolvedTabContextSnapshot(
                snapshot: snapshot,
                source: source
            )
        }
    }

    @MainActor
    private func selectionOnlyCommitContext(from context: MCPTabContextSnapshot) -> MCPTabContextSnapshot {
        guard let latest = try? makeTabContextSnapshot(
            tabID: context.tabID,
            workspaceID: context.workspaceID,
            windowID: context.windowID,
            runID: context.runID,
            explicitlyBound: context.explicitlyBound,
            captureActiveUIState: true,
            flushActiveSelection: false
        ) else {
            return context
        }
        var merged = latest
        merged.selection = context.selection
        merged.selectedContextBuilderPromptIDs = context.selectedContextBuilderPromptIDs
        merged.activeAgentSessionID = context.activeAgentSessionID
        merged.worktreeBindingState = context.worktreeBindingState
        merged.frozenFileToolAuthority = context.frozenFileToolAuthority
        merged.frozenLookupContext = context.frozenLookupContext
        merged.contextBuilderReviewTargetResolution = context.contextBuilderReviewTargetResolution
        merged.readFileAutoSelectionGeneration = context.readFileAutoSelectionGeneration
        return merged
    }

    enum MCPSelectionCoordinatorPersistenceResult: Equatable {
        case persisted
        case unchanged
        case unavailable
    }

    struct PrimaryGitArtifactCommitResult: Equatable {
        let selection: StoredSelection
        let selectionRevision: UInt64
        let newlyAddedArtifacts: [GitDiffPublishedArtifact]
        let autoSelectedAliases: [String]
    }

    private func selectionForPrimaryGitArtifactCommit(
        latestSelection: StoredSelection,
        contextSelection: StoredSelection
    ) -> StoredSelection {
        func appendUnique(
            _ paths: [String],
            to output: inout [String],
            identities: inout Set<String>
        ) {
            for path in paths {
                let identity = StoredSelectionPathNormalization.standardizedPath(path) ?? path
                guard !identity.isEmpty, identities.insert(identity).inserted else { continue }
                output.append(path)
            }
        }

        var selectedPaths: [String] = []
        var selectedIdentities = Set<String>()
        appendUnique(contextSelection.selectedPaths, to: &selectedPaths, identities: &selectedIdentities)
        appendUnique(latestSelection.selectedPaths, to: &selectedPaths, identities: &selectedIdentities)

        var manualCodemapPaths: [String] = []
        var manualCodemapIdentities = Set<String>()
        appendUnique(
            contextSelection.manualCodemapPaths,
            to: &manualCodemapPaths,
            identities: &manualCodemapIdentities
        )
        appendUnique(
            latestSelection.manualCodemapPaths,
            to: &manualCodemapPaths,
            identities: &manualCodemapIdentities
        )

        var slices = contextSelection.slices
        var sliceIdentities = Set(contextSelection.slices.keys.map {
            StoredSelectionPathNormalization.standardizedPath($0) ?? $0
        })
        for (path, ranges) in latestSelection.slices {
            let identity = StoredSelectionPathNormalization.standardizedPath(path) ?? path
            guard !identity.isEmpty, sliceIdentities.insert(identity).inserted else { continue }
            slices[path] = ranges
        }

        return StoredSelection(
            selectedPaths: selectedPaths,
            manualCodemapPaths: manualCodemapPaths,
            slices: slices,
            codemapAutoEnabled: contextSelection.codemapAutoEnabled && latestSelection.codemapAutoEnabled
        )
    }

    enum MCPManageSelectionArtifactCommitResult: Equatable {
        case committed(selection: StoredSelection, selectionRevision: UInt64)
        case conflict(reason: String)
        case unavailable(reason: String)
    }

    struct MCPSelectionPersistenceVerification: Equatable {
        let outcome: MCPSelectionCoordinatorPersistenceResult
        let expectedSelection: StoredSelection
        let canonicalSelection: StoredSelection?

        var isVerified: Bool {
            canonicalSelection == expectedSelection
        }
    }

    static func logicalizeSelectionForPersistence(
        _ selection: StoredSelection,
        lookupContext: WorkspaceLookupContext
    ) -> StoredSelection {
        lookupContext.logicalizeSelection(selection)
    }

    @MainActor
    @discardableResult
    static func persistMCPSelectionThroughCoordinator(
        _ selection: StoredSelection,
        for tabID: UUID,
        workspaceID: UUID?,
        selectionCoordinator: WorkspaceSelectionCoordinator?,
        mirrorToUIIfActive: Bool = true,
        expectedCurrentSelection: StoredSelection? = nil,
        commitAuthorization: WorkspaceSelectionCoordinator.CommitAuthorization? = nil
    ) async -> MCPSelectionCoordinatorPersistenceResult {
        guard let workspaceID, let selectionCoordinator else { return .unavailable }
        let identity = WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: tabID)
        guard let current = selectionCoordinator.selectionSnapshot(
            for: identity,
            flushPendingUIIfActive: false
        ) else { return .unavailable }
        let outcome: MCPSelectionCoordinatorPersistenceResult = current.selection == selection ? .unchanged : .persisted
        _ = await selectionCoordinator.persistSelection(
            selection,
            for: identity,
            source: .mcpTabContext,
            mirrorToUIIfActive: mirrorToUIIfActive,
            expectedCurrentSelection: expectedCurrentSelection,
            commitAuthorization: commitAuthorization
        )
        return outcome
    }

    @MainActor
    static func persistMCPSelectionAndVerifyThroughCoordinator(
        _ selection: StoredSelection,
        for tabID: UUID,
        workspaceID: UUID?,
        selectionCoordinator: WorkspaceSelectionCoordinator?,
        mirrorToUIIfActive: Bool = true,
        expectedCurrentSelection: StoredSelection? = nil,
        commitAuthorization: WorkspaceSelectionCoordinator.CommitAuthorization? = nil
    ) async -> MCPSelectionPersistenceVerification {
        let outcome = await persistMCPSelectionThroughCoordinator(
            selection,
            for: tabID,
            workspaceID: workspaceID,
            selectionCoordinator: selectionCoordinator,
            mirrorToUIIfActive: mirrorToUIIfActive,
            expectedCurrentSelection: expectedCurrentSelection,
            commitAuthorization: commitAuthorization
        )
        let canonicalSelection = workspaceID.flatMap { workspaceID in
            selectionCoordinator?
                .selectionSnapshot(
                    for: WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: tabID),
                    flushPendingUIIfActive: false
                )?
                .selection
        }
        return MCPSelectionPersistenceVerification(
            outcome: outcome,
            expectedSelection: selection,
            canonicalSelection: canonicalSelection
        )
    }

    @MainActor
    private func canonicalPersistedSelection(
        for tabID: UUID,
        workspaceID: UUID?
    ) -> StoredSelection? {
        guard let workspaceID else { return nil }
        let identity = WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: tabID)
        if let selection = selectionCoordinator?
            .selectionSnapshot(for: identity, flushPendingUIIfActive: false)?
            .selection
        {
            return selection
        }
        return workspaceManager?.composeTab(for: identity)?.selection
    }

    @MainActor
    private func persistenceSafeTabContext(_ context: MCPTabContextSnapshot) async -> MCPTabContextSnapshot {
        let lookupContext = await lookupContext(for: context)
        var persisted = context
        persisted.selection = Self.logicalizeSelectionForPersistence(context.selection, lookupContext: lookupContext)
        return persisted
    }

    @MainActor
    @discardableResult
    func persistResolvedTabContextSnapshot(
        route routeResources: MCPHostRouteResources,
        _ resolved: MCPResolvedTabContextSnapshot,
        metadata: MCPRequestMetadata,
        mutated: Bool
    ) async -> MCPSelectionPersistenceVerification? {
        guard mutated else { return nil }
        let context = await persistenceSafeTabContext(resolved.snapshot)
        // The visible file-tree UI is backed by logical workspace roots. Mirroring a
        // worktree-only selection through it would drop paths that exist only in the bound root.
        var verification = await Self.persistMCPSelectionAndVerifyThroughCoordinator(
            context.selection,
            for: context.tabID,
            workspaceID: context.workspaceID,
            selectionCoordinator: selectionCoordinator,
            mirrorToUIIfActive: context.worktreeBindings.isEmpty
        )
        if verification.outcome == .unavailable {
            await commitTabContext(selectionOnlyCommitContext(from: context))
            verification = MCPSelectionPersistenceVerification(
                outcome: .unavailable,
                expectedSelection: context.selection,
                canonicalSelection: canonicalPersistedSelection(
                    for: context.tabID,
                    workspaceID: context.workspaceID
                )
            )
        }

        if let canonicalSelection = verification.canonicalSelection,
           canonicalSelection == verification.expectedSelection,
           MCPTabContextSelectionMirrorPolicy.isExplicitAutoReset(canonicalSelection)
        {
            synchronizeBoundTabContextAfterVerifiedAutoReset(
                route: routeResources,
                resolvedContext: resolved,
                persistedContext: context,
                canonicalSelection: canonicalSelection,
                metadata: metadata
            )
        } else if let canonicalSelection = verification.canonicalSelection,
                  canonicalSelection == verification.expectedSelection,
                  let connectionID = metadata.connectionID,
                  let latest = routeResources.runRouteBindings.tabContextByConnectionID[connectionID],
                  latest.tabID == context.tabID,
                  latest.windowID == context.windowID,
                  latest.workspaceID == context.workspaceID,
                  latest.runID == context.runID,
                  latest.readFileAutoSelectionGeneration == context.readFileAutoSelectionGeneration
        {
            var refreshed = selectionOnlyCommitContext(from: context)
            refreshed.selection = canonicalSelection
            if let workspaceID = context.workspaceID {
                refreshed.selectionRevision = workspaceManager?.selectionRevisionForMCP(
                    workspaceID: workspaceID,
                    tabID: context.tabID
                ) ?? latest.selectionRevision
            }
            refreshed.readFileAutoSelectionGeneration = latest.readFileAutoSelectionGeneration
            routeResources.runRouteBindings.tabContextByConnectionID[connectionID] = refreshed
        }
        return verification
    }

    @MainActor
    private func synchronizeBoundTabContextAfterVerifiedAutoReset(
        route routeResources: MCPHostRouteResources,
        resolvedContext: MCPResolvedTabContextSnapshot,
        persistedContext: MCPTabContextSnapshot,
        canonicalSelection: StoredSelection,
        metadata: MCPRequestMetadata
    ) {
        guard MCPTabContextSelectionMirrorPolicy.isExplicitAutoReset(canonicalSelection),
              resolvedContext.source != nil,
              let connectionID = metadata.connectionID,
              var latest = routeResources.runRouteBindings.tabContextByConnectionID[connectionID],
              latest.tabID == persistedContext.tabID,
              latest.windowID == persistedContext.windowID,
              latest.runID == persistedContext.runID,
              latest.readFileAutoSelectionGeneration == persistedContext.readFileAutoSelectionGeneration
        else { return }
        if let latestWorkspaceID = latest.workspaceID,
           let persistedWorkspaceID = persistedContext.workspaceID,
           latestWorkspaceID != persistedWorkspaceID
        {
            return
        }

        latest.selection = canonicalSelection
        if let workspaceID = persistedContext.workspaceID {
            latest.selectionRevision = workspaceManager?.selectionRevisionForMCP(
                workspaceID: workspaceID,
                tabID: persistedContext.tabID
            ) ?? latest.selectionRevision
        }
        routeResources.runRouteBindings.tabContextByConnectionID[connectionID] = latest
    }

    struct ReadFileAutoSelectionAuthoritativeResult: Equatable {
        let persistedSelection: StoredSelection
        let canonicalUnchanged: Bool
        let coordinatorVerified: Bool
        let selectionRevision: UInt64
    }

    @MainActor
    private func currentReadFileAutoSelectionTab(
        route routeResources: MCPHostRouteResources,
        for contextKey: MCPReadFileAutoSelectionCoordinator.ContextKey
    ) -> (manager: WorkspaceManagerViewModel, identity: WorkspaceSelectionIdentity, tab: ComposeTabState)? {
        guard isReadFileAutoSelectionContextCurrent(route: routeResources, contextKey),
              let manager = workspaceManager,
              let workspaceID = contextKey.workspaceID,
              let workspace = manager.workspaces.first(where: { $0.id == workspaceID }),
              let tab = workspace.composeTabs.first(where: { $0.id == contextKey.tabID })
        else { return nil }
        return (
            manager,
            WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: contextKey.tabID),
            tab
        )
    }

    @MainActor
    func acceptReadFileAutoSelection(
        route routeResources: MCPHostRouteResources,
        selection: StoredSelection,
        lookupContext: WorkspaceLookupContext,
        contextKey: MCPReadFileAutoSelectionCoordinator.ContextKey,
        expectedBaseSelection: StoredSelection,
        automaticCodemapDisposition: MCPReadFileAutoSelectionCoordinator.AutomaticCodemapDisposition,
        authority: MCPFrozenFileToolAuthority
    ) async -> ReadFileAutoSelectionAuthoritativeResult? {
        guard isReadFileAutoSelectionContextCurrent(route: routeResources, contextKey) else { return nil }

        #if DEBUG
            if let handler = readFileAutoSelectionPersistenceWillResolveHandlerForTesting {
                await handler()
            }
        #endif
        guard isReadFileAutoSelectionContextCurrent(route: routeResources, contextKey),
              let currentTarget = currentReadFileAutoSelectionTab(route: routeResources, for: contextKey),
              currentTarget.tab.selection == expectedBaseSelection
        else { return nil }

        guard let manager = workspaceManager else { return nil }
        do {
            try await authority.validate(workspaceManager: manager, store: promptVM.workspaceFileContextStore)
        } catch { return nil }
        let commitAuthorization: WorkspaceSelectionCoordinator.CommitAuthorization = { [weak self] commit in
            guard let self, !Task.isCancelled,
                  isReadFileAutoSelectionContextCurrent(route: routeResources, contextKey),
                  let context = readFileAutoSelectionContext(route: routeResources, for: contextKey)
            else { return false }
            if context.runID == nil {
                guard let workspaceID = contextKey.workspaceID,
                      prospectiveFileToolLookupSourceIsCurrent(
                          route: routeResources,
                          tabID: contextKey.tabID,
                          workspaceID: workspaceID,
                          expectedSourceIdentity: authority.sourceIdentity
                      )
                else { return false }
            } else if context.fileToolAuthoritySourceIdentity != authority.sourceIdentity {
                return false
            }
            return (try? authority.performIfCurrent(workspaceManager: manager, operation: commit)) == true
        }
        guard commitAuthorization({}) else { return nil }

        let logicalSelection = lookupContext.logicalizeSelection(selection)
        let logicalExpectedBaseSelection = lookupContext.logicalizeSelection(expectedBaseSelection)
        let expectedBaseForPreservation = StoredSelection(
            selectedPaths: StoredSelectionPathNormalization.standardizedPaths(logicalExpectedBaseSelection.selectedPaths),
            manualCodemapPaths: StoredSelectionPathNormalization.standardizedPaths(
                logicalExpectedBaseSelection.manualCodemapPaths
            ),
            slices: StoredSelectionPathNormalization.standardizedSlices(logicalExpectedBaseSelection.slices).mapValues {
                SliceRangeMath.normalize($0)
            },
            codemapAutoEnabled: logicalExpectedBaseSelection.codemapAutoEnabled
        )
        let persistedSelection = StoredSelection(
            selectedPaths: StoredSelectionPathNormalization.standardizedPaths(logicalSelection.selectedPaths),
            manualCodemapPaths: StoredSelectionPathNormalization.standardizedPaths(
                logicalSelection.manualCodemapPaths
            ),
            slices: StoredSelectionPathNormalization.standardizedSlices(logicalSelection.slices).mapValues {
                SliceRangeMath.normalize($0)
            },
            codemapAutoEnabled: logicalSelection.codemapAutoEnabled
        )
        guard MCPReadFileAutoSelectionCoordinator.authoritativeSelection(
            expectedBaseForPreservation,
            isPreservedBy: persistedSelection,
            automaticCodemapDisposition: automaticCodemapDisposition
        ),
            let target = currentReadFileAutoSelectionTab(route: routeResources, for: contextKey)
        else { return nil }
        let canonicalUnchanged = target.tab.selection == persistedSelection
        var coordinatorVerified = canonicalUnchanged

        if !canonicalUnchanged {
            var verification = await EditFlowPerf.measure(EditFlowPerf.Stage.ReadFile.AutoSelect.canonicalStoredCommit) {
                await Self.persistMCPSelectionAndVerifyThroughCoordinator(
                    persistedSelection,
                    for: contextKey.tabID,
                    workspaceID: contextKey.workspaceID,
                    selectionCoordinator: selectionCoordinator,
                    mirrorToUIIfActive: false,
                    expectedCurrentSelection: expectedBaseSelection,
                    commitAuthorization: commitAuthorization
                )
            }
            guard let refreshedTarget = currentReadFileAutoSelectionTab(route: routeResources, for: contextKey) else { return nil }
            if verification.outcome == .unavailable {
                guard refreshedTarget.tab.selection == expectedBaseSelection else { return nil }
                var updatedTab = refreshedTarget.tab
                updatedTab.selection = persistedSelection
                updatedTab.lastModified = Date()
                await EditFlowPerf.measure(EditFlowPerf.Stage.ReadFile.AutoSelect.canonicalStoredCommit) {
                    _ = commitAuthorization {
                        _ = refreshedTarget.manager.updateComposeTabStoredOnly(
                            updatedTab,
                            inWorkspaceID: refreshedTarget.identity.workspaceID
                        )
                    }
                }
                verification = MCPSelectionPersistenceVerification(
                    outcome: .unavailable,
                    expectedSelection: persistedSelection,
                    canonicalSelection: currentReadFileAutoSelectionTab(route: routeResources, for: contextKey)?.tab.selection
                )
            }
            coordinatorVerified = verification.isVerified
        }

        guard coordinatorVerified, commitAuthorization({}),
              let finalTarget = currentReadFileAutoSelectionTab(route: routeResources, for: contextKey),
              finalTarget.tab.selection == persistedSelection
        else { return nil }
        if canonicalUnchanged {
            finalTarget.manager.updateComposeTabSelectionPresentation(
                persistedSelection,
                for: finalTarget.identity
            )
        }
        let selectionRevision = finalTarget.manager.selectionRevisionForMCP(
            workspaceID: finalTarget.identity.workspaceID,
            tabID: finalTarget.identity.tabID
        )

        if case let .bound(connectionID, _) = contextKey.route,
           var latest = routeResources.runRouteBindings.tabContextByConnectionID[connectionID],
           latest.readFileAutoSelectionGeneration == contextKey.bindingGeneration
        {
            latest.selection = persistedSelection
            latest.selectionRevision = selectionRevision
            routeResources.runRouteBindings.tabContextByConnectionID[connectionID] = latest
        }

        return ReadFileAutoSelectionAuthoritativeResult(
            persistedSelection: persistedSelection,
            canonicalUnchanged: canonicalUnchanged,
            coordinatorVerified: coordinatorVerified,
            selectionRevision: selectionRevision
        )
    }

    @MainActor
    func resolveFileToolLookupRootScope(
        route routeResources: MCPHostRouteResources,
        from metadata: MCPRequestMetadata
    ) async -> WorkspaceLookupRootScope {
        await resolveFileToolLookupContext(route: routeResources, from: metadata).rootScope
    }

    @MainActor
    func resolveFileToolLookupContext(
        route routeResources: MCPHostRouteResources,
        tabID: UUID,
        workspaceID: UUID?
    ) async throws -> WorkspaceLookupContext {
        try await resolveFileToolAuthority(
            route: routeResources,
            tabID: tabID,
            workspaceID: workspaceID
        ).lookupContext
    }

    @MainActor
    func resolveFileToolAuthority(
        route routeResources: MCPHostRouteResources,
        tabID: UUID,
        workspaceID: UUID?
    ) async throws -> MCPFrozenFileToolAuthority {
        try await requiredFileToolLookupContext(route: routeResources, from: MCPRequestMetadata(
            connectionID: nil,
            clientName: nil,
            windowID: routeResources.identity.routeID,
            tabContextHint: MCPTabContextHint(
                tabID: tabID,
                workspaceID: workspaceID,
                windowID: routeResources.identity.routeID
            )
        ))
    }

    @MainActor
    func prospectiveFileToolLookupSourceIsCurrent(
        route routeResources: MCPHostRouteResources,
        tabID: UUID,
        workspaceID: UUID,
        expectedSourceIdentity: AgentWorkspaceLookupContextIdentity?
    ) -> Bool {
        guard var snapshot = try? makeTabContextSnapshot(
            tabID: tabID,
            workspaceID: workspaceID,
            windowID: routeResources.identity.routeID,
            runID: nil,
            explicitlyBound: false,
            captureActiveUIState: false,
            flushActiveSelection: false
        ) else { return false }

        if let sessionID = snapshot.activeAgentSessionID {
            snapshot.worktreeBindingState = agentWorktreeBindingStateProvider?(sessionID, snapshot.tabID) ?? .unhydrated
        } else {
            snapshot.worktreeBindingState = .notApplicable
        }
        let source = AgentWorkspaceLookupContextSource(
            activeAgentSessionID: snapshot.activeAgentSessionID,
            worktreeBindingState: snapshot.worktreeBindingState
        )
        return fileToolLookupSnapshotIsCurrent(route: routeResources, snapshot, connectionID: nil)
            && source.authorityIdentity == expectedSourceIdentity
    }

    @MainActor
    func performIfFileToolAuthorityIsCurrent(
        route routeResources: MCPHostRouteResources,
        _ authority: MCPFrozenFileToolAuthority,
        tabID: UUID,
        workspaceID: UUID,
        operation: @MainActor () throws -> Void
    ) async throws -> Bool {
        guard prospectiveFileToolLookupSourceIsCurrent(
            route: routeResources,
            tabID: tabID,
            workspaceID: workspaceID,
            expectedSourceIdentity: authority.sourceIdentity
        ) else { return false }

        #if DEBUG
            if let debugAfterFileToolLookupContextRootValidationForTesting {
                await debugAfterFileToolLookupContextRootValidationForTesting()
            }
        #endif

        guard prospectiveFileToolLookupSourceIsCurrent(
            route: routeResources,
            tabID: tabID,
            workspaceID: workspaceID,
            expectedSourceIdentity: authority.sourceIdentity
        ) else { return false }
        guard let workspaceManager else { return false }
        do {
            try await authority.validate(
                workspaceManager: workspaceManager,
                store: promptVM.workspaceFileContextStore
            )
        } catch is MCPFileToolAuthorityFailure {
            return false
        }
        try Task.checkCancellation()
        guard prospectiveFileToolLookupSourceIsCurrent(
            route: routeResources,
            tabID: tabID,
            workspaceID: workspaceID,
            expectedSourceIdentity: authority.sourceIdentity
        ) else { return false }
        return try authority.performIfCurrent(
            workspaceManager: workspaceManager,
            operation: operation
        )
    }

    @MainActor
    func resolveFileToolLookupContext(
        route routeResources: MCPHostRouteResources,
        from metadata: MCPRequestMetadata
    ) async -> WorkspaceLookupContext {
        await (try? resolveFileToolLookupContext(route: routeResources, from: metadata, rootCatalogSnapshot: nil))
            ?? AgentWorkspaceLookupContextResolver.failClosedLookupContext
    }

    @MainActor
    func requiredFileToolLookupContext(
        route routeResources: MCPHostRouteResources,
        from metadata: MCPRequestMetadata,
        readinessTimeout: Duration = MCPTimeoutPolicy.fileToolAuthorityReadinessWaitTimeout
    ) async throws -> MCPFrozenFileToolAuthority {
        let routed = try resolveTabContextSnapshot(
            route: routeResources,
            from: metadata,
            toolName: "file_tool_lookup_scope"
        )
        let authorityConnectionID = fileToolAuthorityConnectionID(metadata: metadata, routed: routed)
        if let frozenAuthority = routed.snapshot.frozenFileToolAuthority {
            guard let workspaceManager else { throw MCPFileToolAuthorityFailure.unavailable }
            var liveSourceSnapshot = routed.snapshot
            if routed.snapshot.runID == nil,
               let workspaceID = routed.snapshot.workspaceID,
               let current = try? makeTabContextSnapshot(
                   tabID: routed.snapshot.tabID,
                   workspaceID: workspaceID,
                   windowID: routed.snapshot.windowID,
                   runID: nil,
                   explicitlyBound: routed.snapshot.explicitlyBound,
                   captureActiveUIState: false,
                   flushActiveSelection: false
               )
            {
                liveSourceSnapshot.activeAgentSessionID = current.activeAgentSessionID
                liveSourceSnapshot.worktreeBindingState = current.activeAgentSessionID.map {
                    agentWorktreeBindingStateProvider?($0, current.tabID) ?? .unhydrated
                } ?? .notApplicable
            }
            if frozenAuthority.sourceIdentity != liveSourceSnapshot.fileToolAuthoritySourceIdentity {
                if let connectionID = authorityConnectionID,
                   var bound = routeResources.runRouteBindings.tabContextByConnectionID[connectionID],
                   fileToolLookupRouteMatches(bound, routed.snapshot)
                {
                    replaceFileToolBindingSource(
                        route: routeResources,
                        connectionID: connectionID,
                        context: &bound,
                        activeAgentSessionID: liveSourceSnapshot.activeAgentSessionID,
                        worktreeBindingState: liveSourceSnapshot.worktreeBindingState
                    )
                    routeResources.runRouteBindings.tabContextByConnectionID[connectionID] = bound
                }
                throw MCPFileToolAuthorityFailure.superseded
            }
            do {
                try await frozenAuthority.validate(
                    workspaceManager: workspaceManager,
                    store: promptVM.workspaceFileContextStore
                )
            } catch {
                // A changed visible-root catalog permanently revokes a nested run's
                // frozen scope, including when a newly loaded root was not admitted.
                let currentRoots = await Set(promptVM.workspaceFileContextStore.rootRefs(scope: .visibleWorkspace))
                if routed.snapshot.runID != nil,
                   let connectionID = authorityConnectionID,
                   frozenAuthority.canonicalRoots != currentRoots,
                   var bound = routeResources.runRouteBindings.tabContextByConnectionID[connectionID],
                   fileToolLookupRouteMatches(bound, routed.snapshot),
                   bound.frozenFileToolAuthority?.rootCatalogSnapshot == frozenAuthority.rootCatalogSnapshot
                {
                    bound.frozenLookupContext = nil
                    routeResources.runRouteBindings.tabContextByConnectionID[connectionID] = bound
                }
                throw error
            }
            return frozenAuthority
        }
        var authoritySnapshot = routed.snapshot
        guard await hydrateFileToolLookupSnapshotIfNeeded(
            route: routeResources,
            &authoritySnapshot,
            connectionID: authorityConnectionID
        ) else {
            throw MCPFileToolAuthorityFailure.superseded
        }
        guard let workspaceID = authoritySnapshot.workspaceID,
              let workspaceManager
        else {
            throw MCPFileToolAuthorityFailure.unavailable
        }
        let authoritySource = AgentWorkspaceLookupContextSource(
            activeAgentSessionID: authoritySnapshot.activeAgentSessionID,
            worktreeBindingState: authoritySnapshot.worktreeBindingState
        )
        let capturedRoute = MCPResolvedTabContextSnapshot(
            snapshot: authoritySnapshot,
            source: routed.source
        )

        // A nested run keeps the original root identities even if readiness for
        // the changed catalog fails before a new snapshot can be captured. The
        // scope's canonicalRoots are only the retained (unbound) subset, so the
        // live catalog is compared against the captured full logical catalog.
        if authoritySnapshot.runID != nil,
           let frozenLookupContext = authoritySnapshot.frozenLookupContext,
           case let .validatedSessionBoundWorkspace(canonicalRoots, _, _) = frozenLookupContext.rootScope
        {
            let capturedLogicalRoots = frozenLookupContext.bindingProjection.map { Set($0.visibleLogicalRootRefs) }
                ?? canonicalRoots
            let currentRoots = await Set(promptVM.workspaceFileContextStore.rootRefs(scope: .visibleWorkspace))
            guard capturedLogicalRoots == currentRoots else {
                if let connectionID = authorityConnectionID,
                   var bound = routeResources.runRouteBindings.tabContextByConnectionID[connectionID],
                   fileToolLookupRouteMatches(bound, authoritySnapshot),
                   bound.frozenLookupContext == frozenLookupContext
                {
                    bound.frozenLookupContext = nil
                    routeResources.runRouteBindings.tabContextByConnectionID[connectionID] = bound
                }
                throw MCPFileToolAuthorityFailure.superseded
            }
        }

        let rootCatalogSnapshot: WorkspaceRootCatalogSnapshot
        do {
            rootCatalogSnapshot = try await workspaceManager.awaitWorkspaceRootCatalogSnapshot(
                workspaceID: workspaceID,
                timeout: readinessTimeout
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WorkspaceRootCatalogSnapshotError {
            throw Self.fileToolAuthorityFailure(for: error)
        }

        guard fileToolLookupSnapshotIsCurrent(
            route: routeResources,
            authoritySnapshot,
            connectionID: authorityConnectionID
        ), fileToolBindingSourceIsCurrent(authoritySource, for: authoritySnapshot)
        else {
            throw MCPFileToolAuthorityFailure.superseded
        }

        do {
            let lookupContext: WorkspaceLookupContext
            if authoritySnapshot.runID != nil,
               let frozenLookupContext = authoritySnapshot.frozenLookupContext
            {
                if case let .validatedSessionBoundWorkspace(canonicalRoots, _, _) = frozenLookupContext.rootScope {
                    let capturedLogicalRoots = frozenLookupContext.bindingProjection.map { Set($0.visibleLogicalRootRefs) }
                        ?? canonicalRoots
                    let currentRoots = await Set(promptVM.workspaceFileContextStore.rootRefs(scope: .visibleWorkspace))
                    guard capturedLogicalRoots == currentRoots else {
                        if let connectionID = authorityConnectionID,
                           var bound = routeResources.runRouteBindings.tabContextByConnectionID[connectionID],
                           fileToolLookupRouteMatches(bound, authoritySnapshot),
                           bound.frozenLookupContext == frozenLookupContext
                        {
                            bound.frozenLookupContext = nil
                            routeResources.runRouteBindings.tabContextByConnectionID[connectionID] = bound
                        }
                        throw MCPFileToolAuthorityFailure.superseded
                    }
                }
                lookupContext = frozenLookupContext
            } else if metadata.runPurpose == .discoverRun,
                      authoritySnapshot.runID != nil
            {
                // A nested run whose frozen scope was revoked must never recover it
                // from the newly visible roots.
                throw MCPFileToolAuthorityFailure.superseded
            } else {
                lookupContext = try await resolveFileToolLookupContext(
                    route: routeResources,
                    from: metadata,
                    rootCatalogSnapshot: rootCatalogSnapshot,
                    capturedRoute: capturedRoute
                )
            }
            guard lookupContext != AgentWorkspaceLookupContextResolver.failClosedLookupContext,
                  fileToolRootCatalogSnapshotIsCurrent(rootCatalogSnapshot)
            else {
                throw MCPFileToolAuthorityFailure.superseded
            }
            let frozenAuthority = try await MCPFrozenFileToolAuthority.capture(
                lookupContext: lookupContext,
                rootCatalogSnapshot: rootCatalogSnapshot,
                store: promptVM.workspaceFileContextStore,
                sourceIdentity: authoritySource.authorityIdentity
            )
            guard fileToolLookupSnapshotIsCurrent(
                route: routeResources,
                authoritySnapshot,
                connectionID: authorityConnectionID
            ), fileToolBindingSourceIsCurrent(authoritySource, for: authoritySnapshot),
            fileToolRootCatalogSnapshotIsCurrent(rootCatalogSnapshot)
            else {
                throw MCPFileToolAuthorityFailure.superseded
            }
            try await frozenAuthority.validate(
                workspaceManager: workspaceManager,
                store: promptVM.workspaceFileContextStore
            )
            return frozenAuthority
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as MCPFileToolAuthorityFailure {
            if error == .unavailable,
               !fileToolLookupSnapshotIsCurrent(
                   route: routeResources,
                   authoritySnapshot,
                   connectionID: authorityConnectionID
               ) || !fileToolBindingSourceIsCurrent(authoritySource, for: authoritySnapshot)
            {
                throw MCPFileToolAuthorityFailure.superseded
            }
            throw error
        } catch {
            throw MCPFileToolAuthorityFailure.unavailable
        }
    }

    static func fileToolAuthorityFailure(
        for error: WorkspaceRootCatalogSnapshotError
    ) -> MCPFileToolAuthorityFailure {
        switch error {
        case .readinessTimedOut: .timedOut
        case .readinessSuperseded, .workspaceNotActive: .superseded
        case .inconsistentRootProjection: .mismatchedProjection
        case .missingWorkspaceIdentity, .readinessUnavailable: .unavailable
        }
    }

    private func unavailableFileToolLookupContext(
        rootCatalogSnapshot: WorkspaceRootCatalogSnapshot?
    ) throws -> WorkspaceLookupContext {
        guard rootCatalogSnapshot == nil else {
            throw MCPFileToolAuthorityFailure.unavailable
        }
        return AgentWorkspaceLookupContextResolver.failClosedLookupContext
    }

    @MainActor
    private func resolveFileToolLookupContext(
        route routeResources: MCPHostRouteResources,
        from metadata: MCPRequestMetadata,
        rootCatalogSnapshot: WorkspaceRootCatalogSnapshot?,
        capturedRoute: MCPResolvedTabContextSnapshot? = nil
    ) async throws -> WorkspaceLookupContext {
        let purpose = metadata.runPurpose ?? .unknown
        var resolved = capturedRoute ?? (try? resolveTabContextSnapshot(
            route: routeResources,
            from: metadata,
            toolName: "file_tool_lookup_scope"
        ))
        let authorityConnectionID = resolved.map {
            fileToolAuthorityConnectionID(metadata: metadata, routed: $0)
        } ?? metadata.connectionID
        if var snapshot = resolved?.snapshot {
            if capturedRoute == nil,
               snapshot.runID == nil,
               let workspaceID = snapshot.workspaceID,
               let liveTab = workspaceManager?.composeTab(
                   for: WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: snapshot.tabID)
               ),
               liveTab.activeAgentSessionID != snapshot.activeAgentSessionID
            {
                snapshot.activeAgentSessionID = liveTab.activeAgentSessionID
                snapshot.worktreeBindingState = liveTab.activeAgentSessionID.map {
                    agentWorktreeBindingStateProvider?($0, snapshot.tabID) ?? .unhydrated
                } ?? .notApplicable
                if let connectionID = authorityConnectionID,
                   var bound = routeResources.runRouteBindings.tabContextByConnectionID[connectionID],
                   fileToolLookupRouteMatches(bound, snapshot)
                {
                    replaceFileToolBindingSource(
                        route: routeResources,
                        connectionID: connectionID,
                        context: &bound,
                        activeAgentSessionID: snapshot.activeAgentSessionID,
                        worktreeBindingState: snapshot.worktreeBindingState
                    )
                    routeResources.runRouteBindings.tabContextByConnectionID[connectionID] = bound
                }
            }

            guard await hydrateFileToolLookupSnapshotIfNeeded(
                route: routeResources,
                &snapshot,
                connectionID: authorityConnectionID
            ) else {
                return try unavailableFileToolLookupContext(rootCatalogSnapshot: rootCatalogSnapshot)
            }

            resolved?.snapshot = snapshot
            if let connectionID = authorityConnectionID,
               var bound = routeResources.runRouteBindings.tabContextByConnectionID[connectionID],
               fileToolLookupRouteMatches(bound, snapshot)
            {
                if bound.activeAgentSessionID != snapshot.activeAgentSessionID
                    || bound.worktreeBindingState != snapshot.worktreeBindingState
                {
                    replaceFileToolBindingSource(
                        route: routeResources,
                        connectionID: connectionID,
                        context: &bound,
                        activeAgentSessionID: snapshot.activeAgentSessionID,
                        worktreeBindingState: snapshot.worktreeBindingState
                    )
                }
                routeResources.runRouteBindings.tabContextByConnectionID[connectionID] = bound
            }
        }

        let baseScope = Self.resolveFileToolLookupRootScope(purpose: purpose, resolvedContext: resolved)
        guard let resolved else {
            if purpose == .agentModeRun {
                return try unavailableFileToolLookupContext(rootCatalogSnapshot: rootCatalogSnapshot)
            }
            return WorkspaceLookupContext(rootScope: baseScope, bindingProjection: nil)
        }
        if let frozenAuthority = resolved.snapshot.frozenFileToolAuthority {
            return frozenAuthority.lookupContext
        }

        let source = AgentWorkspaceLookupContextSource(
            activeAgentSessionID: resolved.snapshot.activeAgentSessionID,
            worktreeBindingState: resolved.snapshot.worktreeBindingState
        )
        guard let connectionID = authorityConnectionID,
              let boundSnapshot = routeResources.runRouteBindings.tabContextByConnectionID[connectionID],
              fileToolLookupSnapshotMatches(boundSnapshot, resolved.snapshot),
              source.activeAgentSessionID != nil,
              !source.worktreeBindings.isEmpty
        else {
            let lookupContext = try await authoritativeFileToolLookupContext(
                source: source,
                rootCatalogSnapshot: rootCatalogSnapshot
            )
            return Self.fileToolLookupContext(lookupContext, applying: baseScope)
        }

        let visibleRootFingerprint = await fileToolVisibleRootFingerprint(
            rootCatalogSnapshot: rootCatalogSnapshot
        )
        guard fileToolLookupSnapshotIsCurrent(route: routeResources, resolved.snapshot, connectionID: connectionID),
              fileToolBindingSourceIsCurrent(source, for: resolved.snapshot)
        else {
            #if DEBUG
                fileToolLookupContextStaleCompletionCount += 1
            #endif
            return try unavailableFileToolLookupContext(rootCatalogSnapshot: rootCatalogSnapshot)
        }
        let cacheKey = FileToolLookupContextCacheKey(
            connectionID: connectionID,
            windowID: resolved.snapshot.windowID,
            workspaceID: resolved.snapshot.workspaceID,
            tabID: resolved.snapshot.tabID,
            runID: resolved.snapshot.runID,
            bindingGeneration: resolved.snapshot.readFileAutoSelectionGeneration,
            baseScope: baseScope,
            sourceIdentity: source.identity,
            visibleRootFingerprint: visibleRootFingerprint,
            readinessTicket: rootCatalogSnapshot?.ticket
        )
        if let cached = fileToolLookupContextCacheByConnectionID[connectionID],
           cached.key == cacheKey,
           cached.sessionRootLifetimeSnapshot.isGenerationCurrent()
        {
            let canReuse = await AgentWorkspaceLookupContextResolver.canReuseAuthoritativeLookupContext(
                cached.context,
                source: source,
                visibleRoots: rootCatalogSnapshot?.primaryRoots,
                store: promptVM.workspaceFileContextStore
            )
            if canReuse {
                #if DEBUG
                    if let debugAfterFileToolLookupContextRootValidationForTesting {
                        await debugAfterFileToolLookupContextRootValidationForTesting()
                    }
                #endif
                try Task.checkCancellation()
                let currentVisibleRootFingerprint = await fileToolVisibleRootFingerprint(
                    rootCatalogSnapshot: rootCatalogSnapshot
                )
                try Task.checkCancellation()
                guard currentVisibleRootFingerprint == visibleRootFingerprint,
                      fileToolRootCatalogSnapshotIsCurrent(rootCatalogSnapshot),
                      fileToolLookupSnapshotIsCurrent(route: routeResources, resolved.snapshot, connectionID: connectionID),
                      fileToolBindingSourceIsCurrent(source, for: resolved.snapshot)
                else {
                    fileToolLookupContextCacheByConnectionID.removeValue(forKey: connectionID)
                    #if DEBUG
                        fileToolLookupContextStaleCompletionCount += 1
                    #endif
                    return try unavailableFileToolLookupContext(rootCatalogSnapshot: rootCatalogSnapshot)
                }
                var currentCachedContext: WorkspaceLookupContext?
                let cachedLifetimeIsCurrent = await cached.sessionRootLifetimeSnapshot.isCurrent()
                try Task.checkCancellation()
                guard cachedLifetimeIsCurrent,
                      cached.sessionRootLifetimeSnapshot.performIfGenerationCurrent({
                          currentCachedContext = cached.context
                      }), let currentCachedContext
                else {
                    fileToolLookupContextCacheByConnectionID.removeValue(forKey: connectionID)
                    #if DEBUG
                        fileToolLookupContextStaleCompletionCount += 1
                    #endif
                    return try unavailableFileToolLookupContext(rootCatalogSnapshot: rootCatalogSnapshot)
                }
                #if DEBUG
                    fileToolLookupContextCacheHitCount += 1
                #endif
                try Task.checkCancellation()
                return currentCachedContext
            }
            fileToolLookupContextCacheByConnectionID.removeValue(forKey: connectionID)
        }
        fileToolLookupContextCacheByConnectionID.removeValue(forKey: connectionID)

        let pendingResolution: PendingFileToolLookupContextResolution
        if var pending = pendingFileToolLookupContextResolutionByConnectionID[connectionID],
           pending.key == cacheKey
        {
            pending.waiterCount += 1
            pendingFileToolLookupContextResolutionByConnectionID[connectionID] = pending
            #if DEBUG
                fileToolLookupContextCoalescedWaitCount += 1
                if let debugFileToolLookupContextDidCoalesceForTesting {
                    await debugFileToolLookupContextDidCoalesceForTesting()
                }
            #endif
            pendingResolution = pending
        } else {
            supersedePendingFileToolLookupContextResolution(connectionID: connectionID)
            #if DEBUG
                fileToolLookupContextCacheMissCount += 1
                let beforeResolution = debugBeforeFileToolLookupContextResolutionForTesting
            #endif
            let resolutionID = UUID()
            let resolutionTask: Task<FileToolLookupResolution, Never> = Task { @MainActor in
                do {
                    #if DEBUG
                        if let beforeResolution {
                            await beforeResolution()
                        }
                    #endif
                    return try await .success(authoritativeFileToolLookupContext(
                        source: source,
                        rootCatalogSnapshot: rootCatalogSnapshot
                    ))
                } catch is CancellationError {
                    return .failure(.cancelled)
                } catch {
                    return .failure(.authority((error as? MCPFileToolAuthorityFailure) ?? .unavailable))
                }
            }
            pendingResolution = PendingFileToolLookupContextResolution(
                id: resolutionID,
                key: cacheKey,
                task: resolutionTask,
                supersession: FileToolLookupResolutionSupersession(),
                waiterCount: 1
            )
            pendingFileToolLookupContextResolutionByConnectionID[connectionID] = pendingResolution
        }

        let resolution: FileToolLookupResolution
        do {
            resolution = try await FileToolLookupResolutionWaiter().value(from: pendingResolution.task)
        } catch is CancellationError {
            releaseCancelledFileToolLookupResolutionWaiter(
                connectionID: connectionID,
                pendingResolution: pendingResolution
            )
            throw CancellationError()
        }
        guard !pendingResolution.supersession.isSuperseded else {
            throw MCPFileToolAuthorityFailure.superseded
        }
        let lookupContext: WorkspaceLookupContext
        switch resolution {
        case let .success(context):
            lookupContext = context
        case .failure(.cancelled):
            if pendingFileToolLookupContextResolutionByConnectionID[connectionID]?.id == pendingResolution.id {
                pendingFileToolLookupContextResolutionByConnectionID.removeValue(forKey: connectionID)
            }
            throw CancellationError()
        case let .failure(.authority(failure)):
            if pendingFileToolLookupContextResolutionByConnectionID[connectionID]?.id == pendingResolution.id {
                pendingFileToolLookupContextResolutionByConnectionID.removeValue(forKey: connectionID)
            }
            throw failure
        }
        try checkFileToolLookupCallerCancellation(
            connectionID: connectionID,
            pendingResolution: pendingResolution
        )
        let currentVisibleRootFingerprint = await fileToolVisibleRootFingerprint(
            rootCatalogSnapshot: rootCatalogSnapshot
        )
        try checkFileToolLookupCallerCancellation(
            connectionID: connectionID,
            pendingResolution: pendingResolution
        )
        let ownsPendingResolution = pendingFileToolLookupContextResolutionByConnectionID[connectionID]?.id
            == pendingResolution.id
        let publishedEntry = fileToolLookupContextCacheByConnectionID[connectionID]
            .flatMap { $0.key == cacheKey ? $0 : nil }
        guard currentVisibleRootFingerprint == visibleRootFingerprint,
              fileToolRootCatalogSnapshotIsCurrent(rootCatalogSnapshot),
              ownsPendingResolution || publishedEntry != nil,
              fileToolLookupSnapshotIsCurrent(route: routeResources, resolved.snapshot, connectionID: connectionID),
              fileToolBindingSourceIsCurrent(source, for: resolved.snapshot)
        else {
            if ownsPendingResolution {
                pendingFileToolLookupContextResolutionByConnectionID.removeValue(forKey: connectionID)
            }
            #if DEBUG
                fileToolLookupContextStaleCompletionCount += 1
            #endif
            return try unavailableFileToolLookupContext(rootCatalogSnapshot: rootCatalogSnapshot)
        }
        let adjustedLookupContext = publishedEntry?.context
            ?? Self.fileToolLookupContext(lookupContext, applying: baseScope)
        guard let bindingProjection = adjustedLookupContext.bindingProjection else {
            if ownsPendingResolution {
                pendingFileToolLookupContextResolutionByConnectionID.removeValue(forKey: connectionID)
            }
            return adjustedLookupContext
        }

        let lifetime = if let publishedEntry {
            publishedEntry.sessionRootLifetimeSnapshot
        } else {
            await promptVM.workspaceFileContextStore.sessionBoundRootScopeValidationSnapshot(
                adjustedLookupContext.rootScope,
                expectedPhysicalRoots: bindingProjection.physicalRootRefs
            )
        }
        try checkFileToolLookupCallerCancellation(
            connectionID: connectionID,
            pendingResolution: pendingResolution
        )
        guard let lifetime, await lifetime.isCurrent() else {
            if ownsPendingResolution {
                pendingFileToolLookupContextResolutionByConnectionID.removeValue(forKey: connectionID)
            }
            #if DEBUG
                fileToolLookupContextStaleCompletionCount += 1
            #endif
            return try unavailableFileToolLookupContext(rootCatalogSnapshot: rootCatalogSnapshot)
        }

        if let publishedEntry {
            var currentContext: WorkspaceLookupContext?
            guard fileToolLookupContextCacheByConnectionID[connectionID]?.key == cacheKey,
                  lifetime.performIfGenerationCurrent({ currentContext = publishedEntry.context }),
                  let currentContext
            else {
                fileToolLookupContextCacheByConnectionID.removeValue(forKey: connectionID)
                return try unavailableFileToolLookupContext(rootCatalogSnapshot: rootCatalogSnapshot)
            }
            return currentContext
        }

        let entry = FileToolLookupContextCacheEntry(
            key: cacheKey,
            context: adjustedLookupContext,
            sessionRootLifetimeSnapshot: lifetime
        )
        guard pendingFileToolLookupContextResolutionByConnectionID[connectionID]?.id == pendingResolution.id,
              fileToolLookupContextCacheByConnectionID[connectionID] == nil,
              lifetime.performIfGenerationCurrent({
                  fileToolLookupContextCacheByConnectionID[connectionID] = entry
              })
        else {
            pendingFileToolLookupContextResolutionByConnectionID.removeValue(forKey: connectionID)
            return try unavailableFileToolLookupContext(rootCatalogSnapshot: rootCatalogSnapshot)
        }
        pendingFileToolLookupContextResolutionByConnectionID.removeValue(forKey: connectionID)
        return adjustedLookupContext
    }

    @MainActor
    private func checkFileToolLookupCallerCancellation(
        connectionID: UUID,
        pendingResolution: PendingFileToolLookupContextResolution
    ) throws {
        do {
            try Task.checkCancellation()
        } catch {
            releaseCancelledFileToolLookupResolutionWaiter(
                connectionID: connectionID,
                pendingResolution: pendingResolution
            )
            throw error
        }
    }

    @MainActor
    private func releaseCancelledFileToolLookupResolutionWaiter(
        connectionID: UUID,
        pendingResolution: PendingFileToolLookupContextResolution
    ) {
        guard var pending = pendingFileToolLookupContextResolutionByConnectionID[connectionID],
              pending.id == pendingResolution.id
        else { return }
        pending.waiterCount = max(0, pending.waiterCount - 1)
        pendingFileToolLookupContextResolutionByConnectionID[connectionID] = pending
        guard pending.waiterCount == 0 else { return }

        Task { @MainActor [weak self, task = pending.task, resolutionID = pending.id] in
            _ = await task.value
            guard let self,
                  let completed = pendingFileToolLookupContextResolutionByConnectionID[connectionID],
                  completed.id == resolutionID,
                  completed.waiterCount == 0
            else { return }
            pendingFileToolLookupContextResolutionByConnectionID.removeValue(forKey: connectionID)
        }
    }

    /// Routing replacement is not caller cancellation. Mark the flight before stopping its work so
    /// every existing waiter receives a retryable superseded result, including across ABA changes.
    @MainActor
    private func supersedePendingFileToolLookupContextResolution(connectionID: UUID) {
        let pending = pendingFileToolLookupContextResolutionByConnectionID.removeValue(forKey: connectionID)
        pending?.supersession.markSuperseded()
        pending?.task.cancel()
    }

    @MainActor
    private func replaceFileToolBindingSource(
        route routeResources: MCPHostRouteResources,
        connectionID: UUID,
        context: inout MCPTabContextSnapshot,
        activeAgentSessionID: UUID?,
        worktreeBindingState: AgentSessionWorktreeBindingState
    ) {
        let currentIdentity = AgentWorkspaceLookupContextSource(
            activeAgentSessionID: context.activeAgentSessionID,
            worktreeBindingState: context.worktreeBindingState
        ).identity
        let replacementIdentity = AgentWorkspaceLookupContextSource(
            activeAgentSessionID: activeAgentSessionID,
            worktreeBindingState: worktreeBindingState
        ).identity
        guard currentIdentity != replacementIdentity else { return }

        invalidateReadFileAutoSelection(route: routeResources, connectionID: connectionID, context: context)
        context.frozenFileToolAuthority = nil
        context.activeAgentSessionID = activeAgentSessionID
        context.worktreeBindingState = worktreeBindingState
        activateReadFileAutoSelection(route: routeResources, &context)
        fileToolLookupContextCacheByConnectionID.removeValue(forKey: connectionID)
        supersedePendingFileToolLookupContextResolution(connectionID: connectionID)
    }

    @MainActor
    private func hydrateFileToolLookupSnapshotIfNeeded(
        route routeResources: MCPHostRouteResources,
        _ snapshot: inout MCPTabContextSnapshot,
        connectionID: UUID?
    ) async -> Bool {
        guard let sessionID = snapshot.activeAgentSessionID else {
            snapshot.worktreeBindingState = .notApplicable
            return true
        }
        if snapshot.runID == nil,
           let agentWorktreeBindingStateProvider
        {
            snapshot.worktreeBindingState = agentWorktreeBindingStateProvider(sessionID, snapshot.tabID)
        }
        guard snapshot.worktreeBindingState == .unhydrated,
              let agentWorktreeBindingStateResolver
        else { return true }

        let bindingGeneration = snapshot.readFileAutoSelectionGeneration
        let hydratedState = await agentWorktreeBindingStateResolver(sessionID, snapshot.tabID)
        guard fileToolLookupSnapshotIsCurrent(
            route: routeResources,
            snapshot,
            connectionID: connectionID,
            expectedBindingGeneration: bindingGeneration
        ),
            agentWorktreeBindingStateProvider?(sessionID, snapshot.tabID) == hydratedState
            || agentWorktreeBindingStateProvider == nil
        else {
            #if DEBUG
                fileToolLookupContextStaleCompletionCount += 1
            #endif
            return false
        }
        snapshot.worktreeBindingState = hydratedState
        return true
    }

    /// Resolves mutation routing and lookup authority together so an inactive,
    /// persisted Agent tab can hydrate its worktree binding before the mutation
    /// gate evaluates it. Re-resolving the snapshot after hydration keeps stale or
    /// superseded routes fail-closed instead of falling back to the visible checkout.
    @MainActor
    func resolveMutationFileToolContext(
        route routeResources: MCPHostRouteResources,
        from metadata: MCPRequestMetadata,
        toolName: String
    ) async throws -> (
        resolvedContext: MCPResolvedTabContextSnapshot,
        lookupContext: WorkspaceLookupContext
    ) {
        var resolvedContext = try resolveTabContextSnapshot(
            route: routeResources,
            from: metadata,
            toolName: toolName
        )
        let lookupContext = await resolveFileToolLookupContext(route: routeResources, from: metadata)
        if resolvedContext.snapshot.activeAgentSessionID != nil,
           case .unhydrated = resolvedContext.snapshot.worktreeBindingState
        {
            resolvedContext = try resolveTabContextSnapshot(
                route: routeResources,
                from: metadata,
                toolName: toolName
            )
        }
        return (resolvedContext, lookupContext)
    }

    @MainActor
    private func fileToolVisibleRootFingerprint(
        rootCatalogSnapshot: WorkspaceRootCatalogSnapshot? = nil
    ) async -> String {
        let roots = if let rootCatalogSnapshot {
            rootCatalogSnapshot.primaryRoots
        } else {
            await promptVM.workspaceFileContextStore.rootRefs(scope: .visibleWorkspace)
        }
        return roots
            .map { "\($0.id.uuidString)\u{1F}\($0.standardizedFullPath)" }
            .sorted()
            .joined(separator: "\u{1E}")
    }

    @MainActor
    private func authoritativeFileToolLookupContext(
        source: AgentWorkspaceLookupContextSource,
        rootCatalogSnapshot: WorkspaceRootCatalogSnapshot?
    ) async throws -> WorkspaceLookupContext {
        guard let rootCatalogSnapshot else {
            return await AgentWorkspaceLookupContextResolver.authoritativeLookupContextOrFailClosed(
                source: source,
                store: promptVM.workspaceFileContextStore
            )
        }
        return try await AgentWorkspaceLookupContextResolver.requiredLookupContext(
            source: source,
            visibleRoots: rootCatalogSnapshot.primaryRoots,
            store: promptVM.workspaceFileContextStore
        )
    }

    @MainActor
    private func fileToolRootCatalogSnapshotIsCurrent(
        _ snapshot: WorkspaceRootCatalogSnapshot?
    ) -> Bool {
        guard let snapshot else { return true }
        return fileToolRootCatalogTicketIsCurrent(snapshot.ticket)
    }

    @MainActor
    private func fileToolRootCatalogTicketIsCurrent(
        _ ticket: WorkspaceSearchReadinessTicket
    ) -> Bool {
        do {
            try workspaceManager?.validateWorkspaceSearchReadiness(
                ticket,
                admission: .rootCatalog
            )
            return workspaceManager != nil
        } catch {
            return false
        }
    }

    @MainActor
    func fileToolLookupSnapshotIsCurrent(
        route routeResources: MCPHostRouteResources,
        _ snapshot: MCPTabContextSnapshot,
        connectionID: UUID?,
        expectedBindingGeneration: UInt64? = nil
    ) -> Bool {
        if snapshot.runID == nil,
           let workspaceID = snapshot.workspaceID
        {
            guard let liveTab = workspaceManager?.composeTab(
                for: WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: snapshot.tabID)
            ), liveTab.activeAgentSessionID == snapshot.activeAgentSessionID
            else { return false }
        }
        guard let connectionID else { return true }
        guard let current = routeResources.runRouteBindings.tabContextByConnectionID[connectionID],
              fileToolLookupSnapshotMatches(current, snapshot)
        else { return false }
        return expectedBindingGeneration == nil
            || current.readFileAutoSelectionGeneration == expectedBindingGeneration
    }

    @MainActor
    func fileToolAuthorityConnectionID(
        metadata: MCPRequestMetadata,
        routed: MCPResolvedTabContextSnapshot
    ) -> UUID? {
        // A runless one-shot hint never installs a connection binding. Its authority is
        // the captured tab and root catalog, not a connection entry that cannot exist.
        if routed.isRunlessOneShotHint {
            return nil
        }
        return metadata.connectionID
    }

    @MainActor
    private func fileToolLookupRouteMatches(
        _ lhs: MCPTabContextSnapshot,
        _ rhs: MCPTabContextSnapshot
    ) -> Bool {
        lhs.tabID == rhs.tabID
            && lhs.windowID == rhs.windowID
            && lhs.workspaceID == rhs.workspaceID
            && lhs.runID == rhs.runID
            && lhs.readFileAutoSelectionGeneration == rhs.readFileAutoSelectionGeneration
    }

    @MainActor
    func fileToolLookupSnapshotMatches(
        _ lhs: MCPTabContextSnapshot,
        _ rhs: MCPTabContextSnapshot
    ) -> Bool {
        fileToolLookupRouteMatches(lhs, rhs)
            && lhs.activeAgentSessionID == rhs.activeAgentSessionID
    }

    @MainActor
    func fileToolBindingSourceIsCurrent(
        _ source: AgentWorkspaceLookupContextSource,
        for snapshot: MCPTabContextSnapshot
    ) -> Bool {
        guard let sessionID = source.activeAgentSessionID else { return true }
        if snapshot.runID != nil {
            return AgentWorkspaceLookupContextSource(
                activeAgentSessionID: sessionID,
                worktreeBindingState: snapshot.worktreeBindingState
            ).identity == source.identity
        }
        guard let agentWorktreeBindingStateProvider else { return true }
        let currentState = agentWorktreeBindingStateProvider(sessionID, snapshot.tabID)
        return AgentWorkspaceLookupContextSource(
            activeAgentSessionID: sessionID,
            worktreeBindingState: currentState
        ).identity == source.identity
    }

    static func fileToolLookupContext(
        _ lookupContext: WorkspaceLookupContext,
        applying baseScope: WorkspaceLookupRootScope
    ) -> WorkspaceLookupContext {
        if baseScope == .visibleWorkspacePlusGitData,
           lookupContext.bindingProjection == nil,
           case let .validatedSessionBoundWorkspace(canonicalRoots, physicalRoots, _) = lookupContext.rootScope,
           !canonicalRoots.isEmpty, physicalRoots.isEmpty
        {
            return WorkspaceLookupContext(
                rootScope: .validatedSessionBoundWorkspace(
                    canonicalRoots: canonicalRoots,
                    physicalRoots: physicalRoots,
                    includesGitData: true
                ),
                bindingProjection: nil
            )
        }
        if lookupContext == .visibleWorkspace, baseScope != .visibleWorkspace {
            return WorkspaceLookupContext(rootScope: baseScope, bindingProjection: nil)
        }
        return lookupContext
    }

    @MainActor
    func materializeWorkspaceBindingProjection(
        sessionID: UUID,
        bindings: [AgentSessionWorktreeBinding]
    ) async -> WorkspaceRootBindingProjection? {
        await WorkspaceRootBindingProjectionMaterializer(store: promptVM.workspaceFileContextStore).materialize(
            sessionID: sessionID,
            bindings: bindings
        )
    }

    static func resolveFileToolLookupRootScope(
        purpose: MCPRunPurpose,
        resolvedContext: MCPResolvedTabContextSnapshot?
    ) -> WorkspaceLookupRootScope {
        if purpose == .discoverRun,
           let resolvedContext,
           resolvedContext.snapshot.runID != nil
        {
            return .visibleWorkspacePlusGitData
        }
        return .visibleWorkspace
    }

    static func spawnParentSourceTabIDForAgentSessionCreation(
        purpose: MCPRunPurpose,
        resolvedContext: MCPResolvedTabContextSnapshot?
    ) -> UUID? {
        guard purpose == .agentModeRun,
              let resolvedContext,
              isExactRunScopedTabContext(resolvedContext)
        else {
            return nil
        }
        return resolvedContext.snapshot.tabID
    }

    /// Whether this request presents exact run-scoped tab context, independent of connection purpose.
    ///
    /// This is the marker that separates an Agent Mode run's *own* connection from an external client
    /// that merely started a run: a supervisor connection also carries a connection→run mapping, but
    /// only a run-installed, handed-over, or pending-run-scoped context is server-installed routing
    /// for the run itself. It is therefore usable as fail-closed Agent-origin evidence when every
    /// captured/live/cached run purpose has been lost.
    @MainActor
    func hasExactRunScopedTabContext(route routeResources: MCPHostRouteResources, metadata: MCPRequestMetadata) -> Bool {
        guard let resolvedContext = try? resolveTabContextSnapshot(
            route: routeResources,
            from: metadata,
            toolName: "agent_session_run_scope"
        ) else {
            return false
        }
        return Self.isExactRunScopedTabContext(resolvedContext)
    }

    static func isExactRunScopedTabContext(
        _ resolvedContext: MCPResolvedTabContextSnapshot
    ) -> Bool {
        guard resolvedContext.snapshot.runID != nil
        else {
            return false
        }
        switch resolvedContext.source {
        case .runInstall, .runHandover, .pendingRunScoped:
            return true
        case .explicitBinding, .explicitHint, nil:
            return false
        }
    }

    /// Compatibility wrapper for Agent Explore/Manage call sites that have not yet adopted the
    /// parent-only name. This resolver must never be used as an Oracle packaging-source resolver.
    static func spawnSourceTabIDForAgentSessionCreation(
        purpose: MCPRunPurpose,
        resolvedContext: MCPResolvedTabContextSnapshot?
    ) -> UUID? {
        spawnParentSourceTabIDForAgentSessionCreation(
            purpose: purpose,
            resolvedContext: resolvedContext
        )
    }

    @MainActor
    func resolveSpawnParentSourceTabIDForAgentSessionCreation(
        route routeResources: MCPHostRouteResources,
        metadata: MCPRequestMetadata
    ) async -> UUID? {
        var purpose: MCPRunPurpose
        if let connectionID = metadata.connectionID {
            purpose = await ServerNetworkManager.shared.runPurpose(for: connectionID)
            if purpose == .agentModeRun || purpose == .unknown {
                let didRehydrate = await ServerNetworkManager.shared.rehydrateRunTabContextForConnectionIfPossible(connectionID)
                if didRehydrate {
                    purpose = await ServerNetworkManager.shared.runPurpose(for: connectionID)
                }
            }
        } else {
            purpose = .unknown
        }
        let resolvedContext = try? resolveTabContextSnapshot(
            route: routeResources,
            from: metadata,
            toolName: "agent_session_spawn_source"
        )
        return Self.spawnParentSourceTabIDForAgentSessionCreation(
            purpose: purpose,
            resolvedContext: resolvedContext
        )
    }

    /// Compatibility wrapper for Agent Explore/Manage call sites. Agent Run uses the explicit
    /// parent-only resolver plus a separate immutable Oracle launch-source resolver.
    @MainActor
    func resolveSpawnSourceTabIDForAgentSessionCreation(
        route routeResources: MCPHostRouteResources,
        metadata: MCPRequestMetadata
    ) async -> UUID? {
        await resolveSpawnParentSourceTabIDForAgentSessionCreation(route: routeResources, metadata: metadata)
    }

    @MainActor
    private func reconciledAgentRunLaunchPurpose(
        metadata: MCPRequestMetadata
    ) async throws -> MCPRunPurpose {
        var currentPurpose: MCPRunPurpose = .unknown
        var cachedRunPolicyPurpose: MCPRunPurpose?
        if let connectionID = metadata.connectionID {
            let networkManager = ServerNetworkManager.shared
            currentPurpose = await networkManager.runPurpose(for: connectionID)
            if currentPurpose == .agentModeRun || currentPurpose == .discoverRun || currentPurpose == .unknown {
                _ = await networkManager.rehydrateRunTabContextForConnectionIfPossible(connectionID)
                currentPurpose = await networkManager.runPurpose(for: connectionID)
            }
            if let runID = await networkManager.runIDForConnection(connectionID) {
                cachedRunPolicyPurpose = await networkManager.runPolicyPurpose(for: runID)
            }
        }

        let scopedPurposes = [metadata.runPurpose, currentPurpose, cachedRunPolicyPurpose]
            .compactMap { purpose -> MCPRunPurpose? in
                guard let purpose, purpose != .unknown else { return nil }
                return purpose
            }
        let distinctPurposes = Set(scopedPurposes.map(\.rawValue))
        guard distinctPurposes.count <= 1 else {
            throw MCPError.invalidParams(
                "agent_run.start observed conflicting run purposes while resolving its launch source. Refusing ambiguous routing."
            )
        }
        return scopedPurposes.first ?? .unknown
    }

    @MainActor
    func resolveImplicitContextBuilderGitTarget(
        route routeResources: MCPHostRouteResources,
        metadata: MCPRequestMetadata
    ) async throws -> ContextBuilderReviewTargetResolution? {
        let purpose = try await reconciledAgentRunLaunchPurpose(metadata: metadata)
        guard purpose == .discoverRun else { return nil }
        let resolved = try resolveTabContextSnapshot(
            route: routeResources,
            from: metadata,
            toolName: "context_builder nested git target"
        )
        guard Self.isExactRunScopedTabContext(resolved),
              resolved.snapshot.activeAgentSessionID != nil
        else { return nil }
        guard resolved.snapshot.runID != nil else {
            return .unavailable(.missingFrozenTarget)
        }
        return resolved.snapshot.contextBuilderReviewTargetResolution
            ?? .unavailable(.missingFrozenTarget)
    }

    @MainActor
    func validateContextBuilderGitArtifactSelection(
        route routeResources: MCPHostRouteResources,
        metadata: MCPRequestMetadata,
        target: ContextBuilderReviewTarget
    ) async throws {
        let resolved = try resolveTabContextSnapshot(
            route: routeResources,
            from: metadata,
            toolName: "context_builder nested git publication"
        )
        guard Self.isExactRunScopedTabContext(resolved),
              let workspaceID = resolved.snapshot.workspaceID,
              workspaceID == target.workspaceID,
              resolved.snapshot.tabID == target.tabID,
              resolved.snapshot.contextBuilderReviewTargetResolution == .available(target),
              let lookupContext = resolved.snapshot.frozenLookupContext
        else {
            throw ContextBuilderReviewTargetUnavailableReason.workspaceOrTabMismatch
        }
        let reviewContext = FrozenPromptGitReviewContext(
            artifactCapability: target.artifactCapability,
            compareIntent: .uncommittedHEAD,
            displayContext: target.displayContext
        )
        _ = try await ContextBuilderReviewTargetResolver().finalizeSelection(
            input: ContextBuilderReviewTargetInput(
                workspaceID: workspaceID,
                tabID: resolved.snapshot.tabID,
                selectionRevision: resolved.snapshot.selectionRevision,
                selection: resolved.snapshot.selection,
                lookupContext: lookupContext,
                reviewGitContext: reviewContext
            ),
            initialResolution: .available(target),
            store: promptVM.workspaceFileContextStore
        )
    }

    /// Resolves and freezes the exact compose tab whose immutable review package will be
    /// delegated to a child Agent run. This is intentionally separate from conversation-parent
    /// resolution: a top-level explicit-window launch has no Agent parent but still has a packaging
    /// source.
    @MainActor
    func resolveAgentRunOracleReviewLaunchSnapshot(
        route routeResources: MCPHostRouteResources,
        metadata: MCPRequestMetadata,
        targetWindow: WindowState
    ) async throws -> AgentRunOracleReviewLaunchSnapshot {
        let purpose = try await reconciledAgentRunLaunchPurpose(metadata: metadata)
        let binding = metadata.connectionID.map { connectionBindingSnapshot(route: routeResources, forConnection: $0) }
        let explicitWindowRoutingHint = metadata.explicitWindowRoutingHint

        for candidateWindowID in [
            metadata.windowID,
            metadata.tabContextHint?.windowID,
            binding?.windowID,
            explicitWindowRoutingHint?.windowID
        ].compactMap(\.self) {
            guard candidateWindowID == targetWindow.windowID else {
                throw MCPError.invalidParams(
                    "agent_run.start launch-source routing conflicts with the target window. Bind or hint the intended window before retrying."
                )
            }
        }

        let hasValidatedExplicitWindowRoute: Bool
        if let explicitWindowRoutingHint {
            guard explicitWindowRoutingHint.connectionID == metadata.connectionID,
                  explicitWindowRoutingHint.toolName == "agent_run",
                  explicitWindowRoutingHint.provenance == .hiddenWindowArgument,
                  explicitWindowRoutingHint.windowID == metadata.windowID,
                  explicitWindowRoutingHint.windowID == targetWindow.windowID,
                  explicitWindowRoutingHint.windowStateIdentity == ObjectIdentifier(targetWindow),
                  explicitWindowRoutingHint.serverViewModelIdentity == ObjectIdentifier(targetWindow.mcpServer)
            else {
                throw MCPError.invalidParams(
                    "agent_run.start received an explicit window route that does not match its authorized connection, tool, effective window, or target window."
                )
            }
            hasValidatedExplicitWindowRoute = true
        } else {
            hasValidatedExplicitWindowRoute = false
        }

        let isRunScoped = purpose == .agentModeRun || purpose == .discoverRun
        let resolved: MCPResolvedTabContextSnapshot
        let route: AgentRunOracleReviewLaunchRoute
        if metadata.tabContextHint != nil || binding?.bindingKind == .tabContext || isRunScoped {
            resolved = try resolveTabContextSnapshot(
                route: routeResources,
                from: metadata,
                toolName: "agent_run.start review source"
            )
            if isRunScoped, !Self.isExactRunScopedTabContext(resolved) {
                throw MCPError.invalidParams(
                    "agent_run.start was invoked from a run-scoped connection without an exact run tab."
                )
            }
            route = isRunScoped ? .runScoped : .explicitTabContext
        } else {
            guard hasValidatedExplicitWindowRoute else {
                throw MCPError.invalidParams(
                    "agent_run.start requires an explicit tab context, an exact run-scoped tab, or an explicit request-scoped window route."
                )
            }
            guard let workspace = targetWindow.workspaceManager.activeWorkspace,
                  !workspace.isSystemWorkspace,
                  let activeComposeTabID = workspace.activeComposeTabID
            else {
                throw MCPError.invalidParams(
                    "agent_run.start could not capture an active project compose tab for its explicit window launch source."
                )
            }
            resolved = try MCPResolvedTabContextSnapshot(
                snapshot: makeTabContextSnapshot(
                    tabID: activeComposeTabID,
                    workspaceID: workspace.id,
                    windowID: targetWindow.windowID,
                    runID: nil,
                    explicitlyBound: false,
                    captureActiveUIState: true,
                    flushActiveSelection: true
                ),
                source: nil
            )
            route = .explicitWindowActiveCompose
        }

        guard resolved.snapshot.windowID == targetWindow.windowID,
              let sourceWorkspaceID = resolved.snapshot.workspaceID,
              let activeWorkspace = targetWindow.workspaceManager.activeWorkspace,
              activeWorkspace.id == sourceWorkspaceID,
              !activeWorkspace.isSystemWorkspace
        else {
            throw MCPError.invalidParams(
                "agent_run.start review source must belong to the target window's active project workspace."
            )
        }

        return AgentRunOracleReviewLaunchSnapshot(
            route: route,
            windowID: resolved.snapshot.windowID,
            workspaceID: sourceWorkspaceID,
            tabID: resolved.snapshot.tabID,
            selectionRevision: resolved.snapshot.selectionRevision,
            promptText: resolved.snapshot.promptText,
            selection: resolved.snapshot.selection,
            sourceAgentSessionID: resolved.snapshot.activeAgentSessionID,
            routedRunID: resolved.snapshot.runID
        )
    }

    nonisolated static func shouldRejectAgentRunStartWithoutResolvedSource(
        capturedPurpose: MCPRunPurpose?,
        currentPurpose: MCPRunPurpose,
        cachedRunPolicyPurpose: MCPRunPurpose?
    ) -> Bool {
        capturedPurpose == .agentModeRun || capturedPurpose == .discoverRun
            || currentPurpose == .agentModeRun || currentPurpose == .discoverRun
            || cachedRunPolicyPurpose == .agentModeRun || cachedRunPolicyPurpose == .discoverRun
    }

    @MainActor
    func validateAgentRunStartRouting(
        metadata: MCPRequestMetadata,
        resolvedSourceTabID: UUID?
    ) async throws {
        guard resolvedSourceTabID == nil, let connectionID = metadata.connectionID else {
            return
        }
        let networkManager = ServerNetworkManager.shared
        let purpose = await networkManager.runPurpose(for: connectionID)
        let cachedRunPolicyPurpose: MCPRunPurpose? = if purpose == .agentModeRun {
            nil
        } else if let runID = await networkManager.runIDForConnection(connectionID) {
            await networkManager.runPolicyPurpose(for: runID)
        } else {
            nil
        }
        guard Self.shouldRejectAgentRunStartWithoutResolvedSource(
            capturedPurpose: metadata.runPurpose,
            currentPurpose: purpose,
            cachedRunPolicyPurpose: cachedRunPolicyPurpose
        ) else {
            return
        }
        throw MCPError.invalidParams("agent_run.start was invoked from an Agent Mode run, but RepoPrompt could not resolve its run-scoped tab context. Refusing to create an unparented top-level run; reconnect the agent MCP client or retry after the run is routed.")
    }

    @MainActor
    func resolveSpawnParentSessionID(
        route routeResources: MCPHostRouteResources,
        metadata: MCPRequestMetadata,
        targetWindow: WindowState
    ) async -> UUID? {
        guard let sourceTabID = await resolveSpawnParentSourceTabIDForAgentSessionCreation(
            route: routeResources,
            metadata: metadata
        ) else {
            return nil
        }
        return targetWindow.agentModeViewModel.mcpSpawnParentSessionID(sourceTabID: sourceTabID)
    }

    /// The caller's exact oversight endpoint incarnation, derived from the same server-owned routing as
    /// `resolveSpawnParentSessionID` and then resolved to a live `(window, tab)` binding.
    ///
    /// Oversight authority is incarnation-scoped, so a session UUID is not a sufficient caller
    /// identity: the same UUID can be live in two windows at once. The routed source tab is what the
    /// server actually knows, so the endpoint is built from it and cross-checked against the session
    /// the spawn-parent resolver reports, and any disagreement fails closed.
    @MainActor
    func resolveAgentSessionLinkObserverEndpoint(
        route routeResources: MCPHostRouteResources,
        metadata: MCPRequestMetadata,
        targetWindow: WindowState
    ) async -> DomainAgentSessionLinkEndpointIdentity? {
        guard let sourceTabID = await resolveSpawnParentSourceTabIDForAgentSessionCreation(
            route: routeResources,
            metadata: metadata
        ) else {
            return nil
        }
        let agentModeVM = targetWindow.agentModeViewModel
        guard let sessionID = agentModeVM.mcpSpawnParentSessionID(sourceTabID: sourceTabID),
              let endpoint = agentModeVM.linkExecutionRuntime.agentSessionLinkObserverEndpoint(tabID: sourceTabID),
              endpoint.sessionID == sessionID
        else {
            return nil
        }
        return endpoint
    }

    nonisolated static func tabContextRoutingErrorMessage(
        toolName: String,
        runPurpose: MCPRunPurpose? = nil
    ) -> String {
        switch runPurpose {
        case .agentModeRun:
            return agentModeRoutingRecoveryMessage(toolName: toolName)
        case .discoverRun:
            // Discovery connections cannot call bind_context; never suggest it.
            return "No tab context is bound for \(toolName) in this Context Builder discovery run. " +
                "Retry the tool call once. If it fails again, stop and report that the RepoPrompt connection lost its Context Builder routing."
        case .unknown, nil:
            break
        }
        return "No tab context is bound for \(toolName). To resolve:\n" +
            "• Call 'bind_context' with op='list' to see available windows and context_id values\n" +
            "• Call 'bind_context' with op='bind' and a context_id to bind this connection to a tab context\n" +
            "• Or pass a matching explicit tab context hint for this tool call"
    }

    private nonisolated static func agentModeRoutingRecoveryMessage(toolName: String) -> String {
        "RepoPrompt could not route \(toolName) to the active Agent Mode run. " +
            "Retry the tool call once. If it fails again, tell the user the RepoPrompt connection failed and ask them to restart this Agent Mode run."
    }

    static func hint(_ hint: MCPTabContextHint, matches context: MCPTabContextSnapshot) -> Bool {
        guard hint.tabID == context.tabID else { return false }
        if let workspaceID = hint.workspaceID, context.workspaceID != workspaceID { return false }
        if let windowID = hint.windowID, context.windowID != windowID { return false }
        return true
    }

    @MainActor
    private func resolveRunHandoverIfPossible(
        route routeResources: MCPHostRouteResources,
        connectionID: UUID,
        clientName: String?,
        providedWindowID: Int?
    ) -> MCPTabContextSnapshot? {
        guard let runID = routeResources.runRouteBindings.connectionIDToRunID[connectionID],
              let previousConnection = routeResources.runRouteBindings.connectionIDByRunID[runID],
              previousConnection != connectionID,
              let existing = routeResources.runRouteBindings.tabContextByConnectionID[previousConnection]
        else {
            return nil
        }

        if let windowID = providedWindowID {
            routeResources.runRouteBindings.presentationWindowByConnection[connectionID] = routeResources.runRouteBindings.presentationWindowByConnection[connectionID] ?? windowID
            guard existing.windowID == windowID else {
                tabContextLog("resolveTabContext handover skipped (window mismatch) runID=\(runID) prevWindow=\(existing.windowID) newWindow=\(windowID)")
                return nil
            }
        }

        routeResources.runRouteBindings.readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: previousConnection)
        routeResources.runRouteBindings.readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: connectionID)
        fileToolLookupContextCacheByConnectionID.removeValue(forKey: previousConnection)
        supersedePendingFileToolLookupContextResolution(connectionID: previousConnection)
        routeResources.runRouteBindings.tabContextByConnectionID.removeValue(forKey: previousConnection)
        invalidateReadFileAutoSelection(route: routeResources, connectionID: previousConnection, context: existing)
        endMirroringForConnection(previousConnection)
        routeResources.runRouteBindings.connectionIDToRunID.removeValue(forKey: previousConnection)
        routeResources.runRouteBindings.presentationWindowByConnection.removeValue(forKey: previousConnection)

        var rebound = existing
        activateReadFileAutoSelection(route: routeResources, &rebound)
        routeResources.runRouteBindings.tabContextByConnectionID[connectionID] = rebound
        routeResources.runRouteBindings.presentationWindowByConnection[connectionID] = rebound.windowID
        let mappingOK = registerRunIDMapping(route: routeResources, connectionID: connectionID, runID: runID, windowID: rebound.windowID)
        if let clientName { recordLastContext(route: routeResources, clientName: clientName, context: rebound) }
        beginMirroringForConnection(route: routeResources, connectionID, context: rebound)
        tabContextLog("resolveTabContext handover: runID=\(runID) \(previousConnection) -> \(connectionID) mappingOK=\(mappingOK) window=\(providedWindowID?.description ?? "nil")")
        return rebound
    }

    @MainActor
    func resolveTabContext(
        route routeResources: MCPHostRouteResources,
        connectionID: UUID?,
        clientName: String?,
        providedWindowID: Int?,
        explicitHint: MCPTabContextHint? = nil,
        toolName: String = "unknown",
        runPurpose: MCPRunPurpose? = nil,
        startMirroring: Bool = true
    ) throws -> MCPTabContextResolution {
        // Prefer network-provided window ID, but if it's missing and we've
        // already learned the mapping for this connection, use our mapping.
        var resolvedWindowID = providedWindowID
        if resolvedWindowID == nil, let cid = connectionID, let mapped = routeResources.runRouteBindings.presentationWindowByConnection[cid] {
            resolvedWindowID = mapped
            tabContextLog("resolveTabContext used stored window mapping for connectionID=\(cid) window=\(mapped)")
        }

        // 1) Existing bound tab-context snapshot for this connection is authoritative only
        // when it is compatible with any current run hint and the requested policy.
        if let connectionID, let bound = routeResources.runRouteBindings.tabContextByConnectionID[connectionID] {
            let requiredRunID = routeResources.runRouteBindings.connectionIDToRunID[connectionID]
            let boundMatchesRunHint = requiredRunID.map { bound.runID == $0 } ?? true
            let boundIsAuthoritative = bound.runID != nil || bound.explicitlyBound
            if !boundMatchesRunHint || !boundIsAuthoritative {
                let shouldPreserveRunHint = requiredRunID != nil && bound.runID == nil
                tabContextLog("resolveTabContext released non-authoritative binding connectionID=\(connectionID) boundRun=\(bound.runID?.uuidString ?? "nil") requiredRun=\(requiredRunID?.uuidString ?? "nil") explicit=\(bound.explicitlyBound) preserveRunHint=\(shouldPreserveRunHint)")
                releaseBinding(route: routeResources, connectionID: connectionID, preserveConnectionRunIDMapping: shouldPreserveRunHint)
            } else if shouldKeepBinding(
                route: routeResources,
                connectionID: connectionID,
                clientName: clientName,
                providedWindowID: resolvedWindowID,
                bound: bound
            ) {
                if let explicitHint, !Self.hint(explicitHint, matches: bound) {
                    var conflicts: [String] = []
                    if explicitHint.tabID != bound.tabID {
                        conflicts.append("context_id hint=\(explicitHint.tabID), bound=\(bound.tabID)")
                    }
                    if let workspaceID = explicitHint.workspaceID, workspaceID != bound.workspaceID {
                        conflicts.append(
                            "workspace_id hint=\(workspaceID), bound=\(bound.workspaceID?.uuidString ?? "none")"
                        )
                    }
                    if let windowID = explicitHint.windowID, windowID != bound.windowID {
                        conflicts.append("window_id hint=\(windowID), bound=\(bound.windowID)")
                    }
                    throw MCPError.invalidParams(
                        "Explicit tab context hint for \(toolName) conflicts with this connection's authoritative " +
                            "tab-context binding: \(conflicts.joined(separator: "; ")); clear or intentionally rebind " +
                            "the connection before targeting a different tab context."
                    )
                }
                if let hinted = resolvedWindowID {
                    if let existing = routeResources.runRouteBindings.presentationWindowByConnection[connectionID], existing != hinted {
                        tabContextLog("resolveTabContext ignoring mismatched window hint for bound connectionID=\(connectionID) existing=\(existing) hinted=\(hinted)")
                    } else if routeResources.runRouteBindings.presentationWindowByConnection[connectionID] == nil {
                        routeResources.runRouteBindings.presentationWindowByConnection[connectionID] = hinted
                    }
                }
                if startMirroring {
                    beginMirroringForConnection(route: routeResources, connectionID, context: bound)
                }
                tabContextLog("resolveTabContext using bound context connectionID=\(connectionID) runID=\(bound.runID?.uuidString ?? "nil") tab=\(bound.tabID)")
                let source: MCPTabContextSnapshotSource = bound.runID == nil ? .explicitBinding : .runInstall
                return .tabContextSnapshot(bound, source: source)
            } else {
                tabContextLog("resolveTabContext released stale binding connectionID=\(connectionID) tab=\(bound.tabID) window=\(bound.windowID)")
                releaseBinding(route: routeResources, connectionID: connectionID)
            }
        }

        // 2) Exact runID handover from a replaced connection.
        if let connectionID,
           let handedOver = resolveRunHandoverIfPossible(
               route: routeResources,
               connectionID: connectionID,
               clientName: clientName,
               providedWindowID: resolvedWindowID
           )
        {
            if let explicitHint, !Self.hint(explicitHint, matches: handedOver) {
                throw MCPError.invalidParams("Explicit tab context hint for \(toolName) conflicts with the active run-scoped tab context. Hint tab: \(explicitHint.tabID); run tab: \(handedOver.tabID).")
            }
            return .tabContextSnapshot(handedOver, source: .runHandover)
        }

        // 3) Explicit one-shot tab/context hint, allowed when no binding exists.
        if let explicitHint {
            let hintWindowID = explicitHint.windowID ?? resolvedWindowID ?? routeResources.identity.routeID
            let snapshot = try makeTabContextSnapshot(
                tabID: explicitHint.tabID,
                workspaceID: explicitHint.workspaceID,
                windowID: hintWindowID,
                runID: connectionID.flatMap { routeResources.runRouteBindings.connectionIDToRunID[$0] },
                explicitlyBound: false,
                captureActiveUIState: true,
                flushActiveSelection: true
            )
            tabContextLog("resolveTabContext using explicit one-shot hint tool=\(toolName) tab=\(snapshot.tabID) window=\(snapshot.windowID)")
            return .tabContextSnapshot(snapshot, source: .explicitHint)
        }

        // 4) Exact pending run-scoped context. This consumes pending only when the
        // connection already carries a runID hint; runless FIFO pending binding is not supported.
        if let connectionID,
           routeResources.runRouteBindings.connectionIDToRunID[connectionID] != nil,
           let clientName,
           let windowID = resolvedWindowID,
           let context = bindPendingContextToConnection(route: routeResources, clientName: clientName, windowID: windowID, connectionID: connectionID)
        {
            tabContextLog("resolveTabContext bound exact pending run context connectionID=\(connectionID) clientName=\(clientName) runID=\(context.runID?.uuidString ?? "nil") tab=\(context.tabID)")
            return .tabContextSnapshot(context, source: .pendingRunScoped)
        }

        // The final runtime never infers domain context from a mutable active tab.
        throw MCPError.invalidParams(Self.tabContextRoutingErrorMessage(toolName: toolName, runPurpose: runPurpose))
    }

    @MainActor
    func contextForCurrentRequest(route routeResources: MCPHostRouteResources, toolName: String) async throws -> (UUID, MCPTabContextSnapshot) {
        guard let connectionID = MCPInvocationContextBridge.current?.connectionID else {
            throw MCPError.invalidParams("No active connection for \(toolName)")
        }
        let invocationContext = try service.captureInvocationContext(
            toolName: toolName,
            expectedWindowID: routeResources.identity.routeID
        )
        let metadata = invocationContext.metadata
        let purpose = metadata.runPurpose

        do {
            let resolution = try resolveTabContext(
                route: routeResources,
                from: metadata,
                toolName: toolName
            )
            guard case let .tabContextSnapshot(context, _) = resolution else {
                throw MCPError.invalidParams(Self.tabContextRoutingErrorMessage(toolName: toolName, runPurpose: purpose))
            }
            routeResources.runRouteBindings.presentationWindowByConnection[connectionID] = context.windowID
            beginMirroringForConnection(route: routeResources, connectionID, context: context)
            return (connectionID, context)
        } catch {
            if purpose == .agentModeRun {
                throw MCPError.invalidParams(Self.tabContextRoutingErrorMessage(
                    toolName: toolName,
                    runPurpose: purpose
                ))
            }
            throw error
        }
    }

    @MainActor
    func requireCurrentTabContext(route routeResources: MCPHostRouteResources, toolName: String) async throws -> MCPTabContextSnapshot {
        let (_, context) = try await contextForCurrentRequest(route: routeResources, toolName: toolName)
        return context
    }

    @MainActor
    func commitPrimaryGitArtifactsToCurrentTab(
        route routeResources: MCPHostRouteResources,
        toolName: String,
        candidates: [GitDiffPublishedArtifact],
        sourceSelection: StoredSelection? = nil,
        capturedContext: DomainReadAppExecutionContext? = nil
    ) async throws -> PrimaryGitArtifactCommitResult {
        // Domain reads commit against the tab context captured at resolve time; re-resolving the
        // current request here could publish primary artifacts into a different tab than the read
        // that produced them. Only the legacy non-domain path may resolve the current request.
        let connectionID: UUID
        let context: MCPTabContextSnapshot
        if let capturedContext {
            guard let capturedConnectionID = capturedContext.metadata.connectionID else {
                throw MCPError.internalError(
                    "Connection identity is unavailable for Git artifact publication"
                )
            }
            connectionID = capturedConnectionID
            context = capturedContext.resolvedTabContext.snapshot
        } else {
            (connectionID, context) = try await contextForCurrentRequest(route: routeResources, toolName: toolName)
        }
        guard let workspaceID = context.workspaceID,
              let selectionCoordinator
        else {
            throw MCPError.internalError("Canonical tab selection is unavailable for Git artifact publication")
        }

        let identity = WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: context.tabID)
        let lookupContext = await lookupContext(for: context)
        let contextSelection = sourceSelection ?? Self.logicalizeSelectionForPersistence(
            context.selection,
            lookupContext: lookupContext
        )
        var mergeResult: WorkspaceGitDiffArtifactSelectionMergeResult?
        guard let transaction = await selectionCoordinator.transformSelection(
            for: identity,
            source: .mcpTabContext,
            mirrorToUIIfActive: context.worktreeBindings.isEmpty,
            { latestSelection in
                let latestSelection = Self.logicalizeSelectionForPersistence(
                    latestSelection,
                    lookupContext: lookupContext
                )
                let commitBase = selectionForPrimaryGitArtifactCommit(
                    latestSelection: latestSelection,
                    contextSelection: contextSelection
                )
                let merged = mergePrimaryGitDiffArtifactsIntoSelection(
                    existing: commitBase,
                    candidates: candidates
                )
                mergeResult = merged
                return merged.selection
            }
        ), let mergeResult else {
            throw MCPError.internalError("Canonical tab selection could not commit Git artifacts")
        }

        guard let canonicalSelection = selectionCoordinator.selectionSnapshot(
            for: identity,
            flushPendingUIIfActive: false
        )?.selection else {
            throw MCPError.internalError("Canonical Git artifact selection disappeared after commit")
        }
        let committedRevision = workspaceManager?.selectionRevisionForMCP(
            workspaceID: workspaceID,
            tabID: context.tabID
        ) ?? transaction.revision
        let committedIdentities = Set(canonicalSelection.selectedPaths.compactMap {
            StoredSelectionPathNormalization.standardizedPath($0)
        })
        let verifiedNewlyAdded = mergeResult.newlyAddedArtifacts.filter { artifact in
            guard let identity = StoredSelectionPathNormalization.standardizedPath(artifact.absolutePath) else {
                return false
            }
            return committedIdentities.contains(identity)
        }
        guard verifiedNewlyAdded.count == mergeResult.newlyAddedArtifacts.count else {
            throw MCPError.internalError("Canonical Git artifact selection verification failed")
        }

        // The legacy path always mirrors the connection (contextForCurrentRequest registers it),
        // so a missing entry means the tab moved. A captured domain read never registered a
        // mirror, so absence is expected there; a present-but-moved mirror stays a hard failure.
        if var latest = routeResources.runRouteBindings.tabContextByConnectionID[connectionID] {
            guard latest.tabID == context.tabID,
                  latest.windowID == context.windowID,
                  latest.workspaceID == context.workspaceID,
                  latest.runID == context.runID
            else {
                throw MCPError.internalError("Git artifact publication tab context is no longer current")
            }
            latest.selection = canonicalSelection
            latest.selectionRevision = committedRevision
            routeResources.runRouteBindings.tabContextByConnectionID[connectionID] = latest
        } else if capturedContext == nil {
            throw MCPError.internalError("Git artifact publication tab context is no longer current")
        }

        return PrimaryGitArtifactCommitResult(
            selection: canonicalSelection,
            selectionRevision: committedRevision,
            newlyAddedArtifacts: verifiedNewlyAdded,
            autoSelectedAliases: verifiedNewlyAdded.compactMap(\.clientAlias)
        )
    }

    @MainActor
    func replaceAdvertisedGitArtifactsForCurrentTab(
        route routeResources: MCPHostRouteResources,
        toolName: String,
        artifacts: [GitDiffPublishedArtifact],
        expectedSelectionRevision: UInt64? = nil,
        capturedContext: DomainReadAppExecutionContext? = nil
    ) async throws -> MCPGitArtifactAdvertisementSnapshot {
        // Domain reads advertise against the tab context captured at resolve time; re-resolving
        // the current request here could target a different tab than the read that produced the
        // artifacts. Only the legacy non-domain path may resolve the current request.
        let connectionID: UUID
        let context: MCPTabContextSnapshot
        if let capturedContext {
            guard let capturedConnectionID = capturedContext.metadata.connectionID else {
                throw MCPError.internalError(
                    "Connection identity is unavailable for Git artifact advertisement"
                )
            }
            connectionID = capturedConnectionID
            context = capturedContext.resolvedTabContext.snapshot
        } else {
            (connectionID, context) = try await contextForCurrentRequest(route: routeResources, toolName: toolName)
        }
        guard let workspaceID = context.workspaceID else {
            throw MCPError.internalError("Workspace identity is unavailable for Git artifact advertisement")
        }
        let reviewContext = await promptVM.freezePromptGitReviewContext(
            workspaceID: workspaceID,
            tabID: context.tabID,
            sessionID: context.activeAgentSessionID,
            bindings: context.worktreeBindings,
            base: "HEAD"
        )
        guard let capability = reviewContext.artifactCapability else {
            throw MCPError.internalError("Git artifact capability is unavailable for advertisement")
        }
        let identity = WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: context.tabID)
        let advertisedArtifacts = artifacts.filter {
            $0.selectionDisposition == .primaryAutoSelect
                || $0.selectionDisposition == .advertisedSelectable
        }
        let rootPath = capability.gitDataRoot.standardizedFullPath
        var advertisedPaths: [String] = []
        var seenPaths = Set<String>()
        for artifact in advertisedArtifacts {
            guard let alias = artifact.clientAlias,
                  alias == "_git_data/\(artifact.gitDataRelativePath)",
                  alias.hasPrefix("_git_data/"),
                  GitDiffArtifactPathPolicy.isSafeRelativeArtifactPath(artifact.gitDataRelativePath),
                  artifact.absolutePath == StandardizedPath.join(
                      standardizedRoot: rootPath,
                      standardizedRelativePath: artifact.gitDataRelativePath
                  )
            else {
                gitArtifactAdvertisementRegistry.invalidate(identity: identity)
                throw MCPError.internalError(
                    "Git artifact advertisement contains an invalid selectable alias"
                )
            }
            if seenPaths.insert(artifact.absolutePath).inserted {
                advertisedPaths.append(artifact.absolutePath)
            }
        }

        let authorization = await SelectedGitDiffArtifactAuthorizationService().authorizeExactPaths(
            ExactSelectedGitArtifactAuthorizationRequest(
                exactAbsolutePaths: advertisedPaths,
                capability: capability,
                store: promptVM.workspaceFileContextStore
            )
        )
        let dispositions = authorization.dispositionsByAbsolutePath
        for artifact in advertisedArtifacts {
            guard let disposition = dispositions[artifact.absolutePath] else {
                gitArtifactAdvertisementRegistry.invalidate(identity: identity)
                throw MCPError.internalError(
                    "Git artifact advertisement authorization returned no disposition for \(artifact.clientAlias ?? "_git_data/<invalid>")"
                )
            }
            if case .authorized = disposition {
                continue
            }
            let diagnostic: String = if case let .rejected(_, reason) = disposition {
                reason.diagnosticLabel
            } else {
                "artifact was not authorized"
            }
            gitArtifactAdvertisementRegistry.invalidate(identity: identity)
            throw MCPError.internalError(
                "Git artifact advertisement rejected \(artifact.clientAlias ?? "_git_data/<invalid>"): \(diagnostic)"
            )
        }

        let visibleRootsAreCurrent = await SelectedGitDiffArtifactAuthorizationService()
            .visibleRootCheckoutsAreCurrent(
                capability: capability,
                store: promptVM.workspaceFileContextStore
            )
        guard visibleRootsAreCurrent,
              gitArtifactAdvertisementContextIsCurrent(
                  route: routeResources,
                  connectionID: connectionID,
                  expected: context,
                  expectedSelectionRevision: expectedSelectionRevision
              )
        else {
            gitArtifactAdvertisementRegistry.invalidate(identity: identity)
            throw MCPError.internalError(
                "Git artifact advertisement context changed during authorization"
            )
        }

        return try gitArtifactAdvertisementRegistry.replace(
            identity: identity,
            capability: capability,
            artifacts: artifacts
        )
    }

    @MainActor
    private func gitArtifactAdvertisementContextIsCurrent(
        route routeResources: MCPHostRouteResources,
        connectionID: UUID,
        expected: MCPTabContextSnapshot,
        expectedSelectionRevision: UInt64?
    ) -> Bool {
        guard let workspaceID = expected.workspaceID,
              routeResources.runRouteBindings.presentationWindowByConnection[connectionID] == expected.windowID,
              let manager = workspaceManager,
              manager.activeWorkspaceID == workspaceID,
              let tab = manager.composeTab(with: expected.tabID)
        else { return false }

        let currentSelectionRevision = expectedSelectionRevision ?? expected.selectionRevision
        guard manager.selectionRevisionForMCP(
            workspaceID: workspaceID,
            tabID: expected.tabID
        ) == currentSelectionRevision else { return false }

        if let latest = routeResources.runRouteBindings.tabContextByConnectionID[connectionID] {
            return latest.tabID == expected.tabID
                && latest.windowID == expected.windowID
                && latest.workspaceID == expected.workspaceID
                && latest.runID == expected.runID
                && latest.activeAgentSessionID == expected.activeAgentSessionID
                && latest.worktreeBindingState == expected.worktreeBindingState
                && latest.selectionRevision == currentSelectionRevision
        }

        let activeTabID = manager.activeWorkspace?.activeComposeTabID
            ?? manager.activeWorkspace?.composeTabs.first?.id
        return activeTabID == expected.tabID
            && tab.activeAgentSessionID == expected.activeAgentSessionID
    }

    @MainActor
    func invalidateAdvertisedGitArtifactsForCurrentTab(
        route routeResources: MCPHostRouteResources,
        toolName: String,
        capturedContext: DomainReadAppExecutionContext? = nil
    ) async {
        let context: MCPTabContextSnapshot? = if let capturedContext {
            capturedContext.resolvedTabContext.snapshot
        } else {
            await (try? contextForCurrentRequest(route: routeResources, toolName: toolName))?.1
        }
        guard let context, let workspaceID = context.workspaceID else { return }
        gitArtifactAdvertisementRegistry.invalidate(
            identity: WorkspaceSelectionIdentity(
                workspaceID: workspaceID,
                tabID: context.tabID
            )
        )
    }

    @MainActor
    func commitManageSelectionArtifactMutation(
        route routeResources: MCPHostRouteResources,
        resolvedContext: MCPResolvedTabContextSnapshot,
        metadata: MCPRequestMetadata,
        expectedPhysicalSelection: StoredSelection,
        requestedPhysicalSelection: StoredSelection,
        lookupContext: WorkspaceLookupContext,
        fence: MCPManageSelectionArtifactAuthorizationFence
    ) async -> MCPManageSelectionArtifactCommitResult {
        let context = resolvedContext.snapshot
        guard let workspaceID = context.workspaceID,
              fence.identity == WorkspaceSelectionIdentity(
                  workspaceID: workspaceID,
                  tabID: context.tabID
              ),
              let selectionCoordinator
        else {
            return .unavailable(reason: "canonical tab selection is unavailable")
        }

        guard fence.capability.workspaceID == workspaceID,
              fence.capability.creatorTabID == context.tabID,
              fence.capability.sessionID == context.activeAgentSessionID
        else {
            return .conflict(reason: "workspace, tab, or session binding changed")
        }
        let currentRoot = await promptVM.workspaceFileContextStore.exactRootRef(
            path: fence.capability.gitDataRoot.standardizedFullPath,
            kind: .workspaceGitData
        )
        guard currentRoot == fence.capability.gitDataRoot else {
            if let snapshot = fence.grantSnapshot {
                gitArtifactAdvertisementRegistry.invalidate(
                    identity: fence.identity,
                    generation: snapshot.generation
                )
            }
            return .conflict(reason: "Git-data root was unloaded or reloaded")
        }
        let visibleRootsAreCurrent = await SelectedGitDiffArtifactAuthorizationService()
            .visibleRootCheckoutsAreCurrent(
                capability: fence.capability,
                store: promptVM.workspaceFileContextStore
            )
        guard visibleRootsAreCurrent else {
            if let snapshot = fence.grantSnapshot {
                gitArtifactAdvertisementRegistry.invalidate(
                    identity: fence.identity,
                    generation: snapshot.generation
                )
            }
            return .conflict(reason: "visible checkout was unloaded, reloaded, or changed")
        }
        if let snapshot = fence.grantSnapshot,
           !gitArtifactAdvertisementRegistry.isCurrent(snapshot)
        {
            return .conflict(reason: "Git artifact advertisement was replaced")
        }

        if let connectionID = metadata.connectionID {
            guard let latest = routeResources.runRouteBindings.tabContextByConnectionID[connectionID],
                  latest.tabID == context.tabID,
                  latest.windowID == context.windowID,
                  latest.workspaceID == context.workspaceID,
                  latest.runID == context.runID,
                  latest.activeAgentSessionID == context.activeAgentSessionID,
                  latest.worktreeBindingState == context.worktreeBindingState
            else {
                return .conflict(reason: "tab routing or checkout binding changed")
            }
        }

        let expected = lookupContext.logicalizeSelection(expectedPhysicalSelection)
        let requested = lookupContext.logicalizeSelection(requestedPhysicalSelection)
        var matchedExpected = false
        guard let transaction = await selectionCoordinator.transformSelection(
            for: fence.identity,
            source: .mcpTabContext,
            mirrorToUIIfActive: context.worktreeBindings.isEmpty,
            { latestSelection in
                guard latestSelection == expected else { return latestSelection }
                matchedExpected = true
                return requested
            }
        ) else {
            return .unavailable(reason: "canonical tab selection could not be committed")
        }
        guard matchedExpected else {
            return .conflict(reason: "canonical selection changed concurrently")
        }
        guard let canonicalSelection = selectionCoordinator.selectionSnapshot(
            for: fence.identity,
            flushPendingUIIfActive: false
        )?.selection,
            canonicalSelection == requested
        else {
            return .conflict(reason: "canonical selection verification failed")
        }

        let revision = workspaceManager?.selectionRevisionForMCP(
            workspaceID: workspaceID,
            tabID: context.tabID
        ) ?? transaction.revision
        if let connectionID = metadata.connectionID,
           var latest = routeResources.runRouteBindings.tabContextByConnectionID[connectionID],
           latest.tabID == context.tabID,
           latest.workspaceID == context.workspaceID,
           latest.runID == context.runID
        {
            latest.selection = canonicalSelection
            latest.selectionRevision = revision
            routeResources.runRouteBindings.tabContextByConnectionID[connectionID] = latest
        }
        return .committed(
            selection: canonicalSelection,
            selectionRevision: revision
        )
    }

    @MainActor
    func validateManageSelectionArtifactFence(
        _ fence: MCPManageSelectionArtifactAuthorizationFence
    ) async -> Bool {
        let currentRoot = await promptVM.workspaceFileContextStore.exactRootRef(
            path: fence.capability.gitDataRoot.standardizedFullPath,
            kind: .workspaceGitData
        )
        guard currentRoot == fence.capability.gitDataRoot else { return false }
        guard await SelectedGitDiffArtifactAuthorizationService()
            .visibleRootCheckoutsAreCurrent(
                capability: fence.capability,
                store: promptVM.workspaceFileContextStore
            )
        else { return false }
        guard let snapshot = fence.grantSnapshot else { return true }
        return gitArtifactAdvertisementRegistry.isCurrent(snapshot)
    }

    @MainActor
    static func test_popPendingContextForBinding(
        from store: inout MCPRunRouteBindings.PendingRunScopedContextStore,
        clientName: String,
        windowID: Int,
        runHint: UUID?
    ) -> (context: MCPTabContextSnapshot?, remaining: Int, usedRunHint: Bool) {
        popPendingContextForBinding(
            from: &store,
            clientName: clientName,
            windowID: windowID,
            runHint: runHint
        )
    }

    static func test_resolveFileToolLookupRootScope(
        purpose: MCPRunPurpose,
        resolvedContext: MCPResolvedTabContextSnapshot?
    ) -> WorkspaceLookupRootScope {
        resolveFileToolLookupRootScope(purpose: purpose, resolvedContext: resolvedContext)
    }

    @MainActor
    func cleanupRunIDMapping(
        route routeResources: MCPHostRouteResources,
        runID: UUID,
        connectionID: UUID,
        signalRoutingFailure: Bool = true,
        routingWaitGeneration: UUID? = nil
    ) {
        routeResources.runRouteBindings.readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: connectionID)
        if routeResources.runRouteBindings.connectionIDByRunID[runID] == connectionID {
            routeResources.runRouteBindings.connectionIDByRunID.removeValue(forKey: runID)
            routeResources.runRouteBindings.pendingPolicyTokenIDByRunID.removeValue(forKey: runID)
        }
        if routeResources.runRouteBindings.connectionIDToRunID[connectionID] == runID {
            routeResources.runRouteBindings.connectionIDToRunID.removeValue(forKey: connectionID)
        }
        tabContextLog("cleanupRunIDMapping removed runID=\(runID) connectionID=\(connectionID)")

        // A stale generation must not fail routing for a newer replacement connection.
        if signalRoutingFailure, routeResources.runRouteBindings.connectionID(forRunID: runID) == nil {
            MCPRoutingWaiter.signalFailed(runID, generation: routingWaitGeneration)
        }
    }

    @MainActor
    @discardableResult
    func registerRunIDMapping(
        route routeResources: MCPHostRouteResources,
        connectionID: UUID,
        runID: UUID,
        windowID: Int,
        signalRouting: Bool = true
    ) -> Bool {
        switch routeResources.runRouteBindings.register(connectionID: connectionID, runID: runID, windowID: windowID) {
        case .refusedOwnerUnavailable:
            tabContextLog("registerRunIDMapping refused: route owner unavailable")
            return false
        case let .refusedBoundRun(boundRun):
            tabContextLog("registerRunIDMapping refused: connectionID=\(connectionID) already bound to runID=\(boundRun), new=\(runID)")
            return false
        case let .refusedWindow(existingWindow):
            tabContextLog("registerRunIDMapping refused window mismatch runID=\(runID) existingWindow=\(existingWindow) newWindow=\(windowID)")
            return false
        case let .registered(displacedConnectionID):
            if let existingConnection = displacedConnectionID {
                Task {
                    await ServerNetworkManager.shared.handleConnectionReplaced(
                        existing: existingConnection,
                        by: connectionID,
                        runID: runID,
                        message: "Connection replaced by new connection for same runID"
                    )
                }
            }
        }
        tabContextLog("registerRunIDMapping connectionID=\(connectionID) runID=\(runID) windowID=\(windowID)")
        if signalRouting { MCPRoutingWaiter.signalRouted(runID) }
        ServerNetworkManager.noteRunRouteChanged(runID: runID)
        return true
    }

    @MainActor
    func registerPendingPolicyRunIDMapping(
        route routeResources: MCPHostRouteResources,
        connectionID: UUID,
        runID: UUID,
        windowID: Int,
        clientName: String? = nil
    ) -> PendingPolicyRunIDMappingToken? {
        guard var token = routeResources.runRouteBindings.beginPendingPolicy(
            connectionID: connectionID, runID: runID, windowID: windowID
        ) else { return nil }
        if let clientName,
           let promotedContext = promotePendingContextForRunMapping(
               route: routeResources,
               clientName: clientName,
               windowID: windowID,
               connectionID: connectionID
           )
        {
            token.promotedContext = promotedContext
            token.promotedContextClientName = clientName
            token.promotedContextWindowID = windowID
        } else {
            inheritDisplacedRunContextIfNeeded(route: routeResources, for: token, clientName: clientName)
        }
        installReadFileAutoSelectionHandoverLineage(route: routeResources, for: token)
        tabContextLog("registerPendingPolicyRunIDMapping connectionID=\(connectionID) runID=\(runID) windowID=\(windowID)")
        return token
    }

    /// A settlement-retained policy can be re-matched by a restarted MCP child after the
    /// run's pending context was consumed. Copy (not move) the displaced connection's live
    /// run context so rollback leaves the displaced owner intact and its teardown removes
    /// only its own entry.
    @MainActor
    private func inheritDisplacedRunContextIfNeeded(
        route routeResources: MCPHostRouteResources,
        for token: PendingPolicyRunIDMappingToken,
        clientName: String?
    ) {
        guard routeResources.runRouteBindings.tabContextByConnectionID[token.connectionID] == nil,
              let displacedConnectionID = token.displacedConnectionID,
              token.displacedConnectionRunID == token.runID,
              let displacedContext = routeResources.runRouteBindings.tabContextByConnectionID[displacedConnectionID],
              displacedContext.runID == token.runID,
              displacedContext.windowID == routeResources.runRouteBindings.presentationWindowByConnection[token.connectionID]
        else { return }

        var inherited = displacedContext
        activateReadFileAutoSelection(route: routeResources, &inherited)
        routeResources.runRouteBindings.tabContextByConnectionID[token.connectionID] = inherited
        routeResources.publishBinding(connectionID: token.connectionID, context: inherited)
        if let clientName { recordLastContext(route: routeResources, clientName: clientName, context: inherited) }
        beginMirroringForConnection(route: routeResources, token.connectionID, context: inherited)
        tabContextLog("registerPendingPolicyRunIDMapping inherited run context runID=\(token.runID) \(displacedConnectionID) -> \(token.connectionID)")
    }

    @MainActor
    private func installReadFileAutoSelectionHandoverLineage(
        route routeResources: MCPHostRouteResources,
        for token: PendingPolicyRunIDMappingToken
    ) {
        guard let successorContext = routeResources.runRouteBindings.tabContextByConnectionID[token.connectionID],
              successorContext.runID == token.runID
        else {
            routeResources.runRouteBindings.readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: token.connectionID)
            return
        }
        let successorKey = readFileAutoSelectionContextKey(
            connectionID: token.connectionID,
            context: successorContext
        )

        guard let displacedConnectionID = token.displacedConnectionID else {
            let preservesCurrentSuccessor = token.displacedConnectionRunID == token.runID
                && routeResources.runRouteBindings.connectionIDByRunID[token.runID] == token.connectionID
                && routeResources.runRouteBindings.connectionIDToRunID[token.connectionID] == token.runID
                && routeResources.runRouteBindings.readFileAutoSelectionHandoverLineageByConnectionID[token.connectionID]?.successorKey == successorKey
            if !preservesCurrentSuccessor {
                routeResources.runRouteBindings.readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: token.connectionID)
            }
            return
        }

        routeResources.runRouteBindings.readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: token.connectionID)
        guard token.displacedConnectionRunID == token.runID,
              let displacedContext = routeResources.runRouteBindings.tabContextByConnectionID[displacedConnectionID],
              displacedContext.runID == token.runID,
              successorContext.windowID == displacedContext.windowID,
              successorContext.workspaceID == displacedContext.workspaceID,
              successorContext.tabID == displacedContext.tabID
        else { return }

        let displacedKey = readFileAutoSelectionContextKey(
            connectionID: displacedConnectionID,
            context: displacedContext
        )
        var predecessorKeys: [MCPReadFileAutoSelectionCoordinator.ContextKey] = []
        if let inherited = routeResources.runRouteBindings.readFileAutoSelectionHandoverLineageByConnectionID[displacedConnectionID],
           inherited.successorKey == displacedKey
        {
            predecessorKeys.append(contentsOf: inherited.predecessorKeys)
        }
        if !predecessorKeys.contains(displacedKey) {
            predecessorKeys.append(displacedKey)
        }
        routeResources.runRouteBindings.readFileAutoSelectionHandoverLineageByConnectionID[token.connectionID] = .init(
            successorKey: successorKey,
            predecessorKeys: predecessorKeys
        )
    }

    @MainActor
    func isCurrentPendingPolicyRunIDMapping(route routeResources: MCPHostRouteResources, _ token: PendingPolicyRunIDMappingToken) -> Bool {
        routeResources.runRouteBindings.isCurrent(token)
    }

    @MainActor
    func rollbackPendingPolicyRunIDMapping(
        route routeResources: MCPHostRouteResources,
        _ token: PendingPolicyRunIDMappingToken,
        clientName: String?,
        windowID: Int?,
        signalRoutingFailure: Bool,
        routingWaitGeneration: UUID? = nil
    ) -> PendingPolicyRunIDMappingRollbackResult {
        guard isCurrentPendingPolicyRunIDMapping(route: routeResources, token) else {
            let supersededBySameConnection = routeResources.runRouteBindings.connectionIDByRunID[token.runID] == token.connectionID
            if routeResources.runRouteBindings.connectionIDToRunID[token.connectionID] != token.runID {
                removeTabContext(
                    route: routeResources,
                    forConnectionID: token.connectionID,
                    clientName: clientName,
                    windowID: windowID,
                    runID: token.runID,
                    removeQueuedPendingContext: false
                )
            }
            if signalRoutingFailure, routeResources.runRouteBindings.connectionID(forRunID: token.runID) == nil {
                MCPRoutingWaiter.signalFailed(token.runID, generation: routingWaitGeneration)
            }
            return supersededBySameConnection
                ? .supersededBySameConnection
                : .supersededByOtherConnection
        }

        routeResources.runRouteBindings.rollback(token) {
            let promotedContextToRestore: (context: MCPTabContextSnapshot, clientName: String, windowID: Int)? = {
                guard let promotedContext = token.promotedContext,
                      let promotedRunID = promotedContext.runID,
                      let promotedContextClientName = token.promotedContextClientName,
                      let promotedContextWindowID = token.promotedContextWindowID,
                      let boundContext = routeResources.runRouteBindings.tabContextByConnectionID[token.connectionID],
                      boundContext.runID == promotedRunID,
                      boundContext.tabID == promotedContext.tabID,
                      boundContext.windowID == promotedContext.windowID,
                      boundContext.workspaceID == promotedContext.workspaceID,
                      !routeResources.runRouteBindings.pendingRunScopedTabContexts.contains(
                          clientName: promotedContextClientName,
                          runID: promotedRunID
                      )
                else {
                    return nil
                }
                return (promotedContext, promotedContextClientName, promotedContextWindowID)
            }()
            removeTabContext(
                route: routeResources,
                forConnectionID: token.connectionID,
                clientName: clientName,
                windowID: windowID,
                runID: token.runID,
                removeQueuedPendingContext: false
            )
            if let promotedContextToRestore {
                _ = routeResources.runRouteBindings.pendingRunScopedTabContexts.enqueueReplacing(
                    promotedContextToRestore.context,
                    clientName: promotedContextToRestore.clientName,
                    windowID: promotedContextToRestore.windowID
                )
            }
        }

        if signalRoutingFailure, routeResources.runRouteBindings.connectionID(forRunID: token.runID) == nil {
            MCPRoutingWaiter.signalFailed(token.runID, generation: routingWaitGeneration)
        }
        return .restored
    }

    @MainActor
    @discardableResult
    func detachContextBuilderTabContextForDiscoveryTeardown(
        route routeResources: MCPHostRouteResources,
        connectionID: UUID,
        runID: UUID
    ) -> Bool {
        guard routeResources.runRouteBindings.connectionIDByRunID[runID] == connectionID,
              routeResources.runRouteBindings.connectionIDToRunID[connectionID] == runID,
              let context = routeResources.runRouteBindings.tabContextByConnectionID[connectionID],
              context.runID == runID,
              routeResources.runRouteBindings.detachedContextBuilderTabContextByRunID[runID] == nil
        else { return false }

        routeResources.runRouteBindings.detachedContextBuilderTabContextByRunID[runID] = .init(
            connectionID: connectionID,
            context: context
        )
        invalidateReadFileAutoSelection(route: routeResources, connectionID: connectionID, context: context)
        endMirroringForConnection(connectionID)
        routeResources.runRouteBindings.readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: connectionID)
        fileToolLookupContextCacheByConnectionID.removeValue(forKey: connectionID)
        pendingFileToolLookupContextResolutionByConnectionID.removeValue(forKey: connectionID)?.task.cancel()
        routeResources.runRouteBindings.tabContextByConnectionID.removeValue(forKey: connectionID)
        routeResources.runRouteBindings.presentationWindowByConnection.removeValue(forKey: connectionID)
        routeResources.runRouteBindings.connectionIDByRunID.removeValue(forKey: runID)
        routeResources.runRouteBindings.pendingPolicyTokenIDByRunID.removeValue(forKey: runID)
        routeResources.runRouteBindings.connectionIDToRunID.removeValue(forKey: connectionID)
        tabContextLog("Detached Context Builder context for discovery teardown connectionID=\(connectionID) runID=\(runID)")
        return true
    }

    @MainActor
    func contextBuilderFinalContextConnectionID(route routeResources: MCPHostRouteResources, runID: UUID) -> UUID? {
        if let connectionID = routeResources.runRouteBindings.connectionIDByRunID[runID],
           routeResources.runRouteBindings.connectionIDToRunID[connectionID] == runID,
           routeResources.runRouteBindings.tabContextByConnectionID[connectionID]?.runID == runID
        {
            return connectionID
        }
        return routeResources.runRouteBindings.detachedContextBuilderTabContextByRunID[runID]?.connectionID
    }

    @MainActor
    func isDetachedContextBuilderConnection(route routeResources: MCPHostRouteResources, connectionID: UUID, runID: UUID) -> Bool {
        routeResources.runRouteBindings.detachedContextBuilderTabContextByRunID[runID]?.connectionID == connectionID
    }

    @MainActor
    func discardDetachedContextBuilderTabContext(route routeResources: MCPHostRouteResources, runID: UUID) {
        routeResources.runRouteBindings.detachedContextBuilderTabContextByRunID.removeValue(forKey: runID)
    }

    @MainActor
    func commitContextBuilderTabContext(
        route routeResources: MCPHostRouteResources,
        connectionID: UUID,
        expectedRunID: UUID,
        isStillCurrent: @MainActor () -> Bool,
        progressReporter: ContextBuilderMCPProgressReporter? = nil,
        deferRunMappingCleanupUntilCaller: Bool = false,
        promptFallback: String? = nil
    ) async -> ContextBuilderTabContextCommitResult {
        guard isStillCurrent(), !Task.isCancelled else {
            discardDetachedContextBuilderTabContext(route: routeResources, runID: expectedRunID)
            return ContextBuilderTabContextCommitResult(
                outcome: .staleOrNoLongerCurrent,
                committedTab: nil
            )
        }

        let alreadyFinishedAutoSelection: Bool
        if routeResources.runRouteBindings.tabContextByConnectionID[connectionID]?.runID == expectedRunID {
            alreadyFinishedAutoSelection = false
        } else if let detached = routeResources.runRouteBindings.detachedContextBuilderTabContextByRunID[expectedRunID],
                  detached.connectionID == connectionID,
                  detached.context.runID == expectedRunID
        {
            // Destructively claim the run-owned snapshot and move it into the existing
            // commit implementation without suspending between removal and insertion.
            routeResources.runRouteBindings.detachedContextBuilderTabContextByRunID.removeValue(forKey: expectedRunID)
            routeResources.runRouteBindings.tabContextByConnectionID[connectionID] = detached.context
            alreadyFinishedAutoSelection = true
        } else {
            return ContextBuilderTabContextCommitResult(
                outcome: .missingFinalContext(runID: expectedRunID, connectionID: connectionID),
                committedTab: nil
            )
        }

        if var finalContext = routeResources.runRouteBindings.tabContextByConnectionID[connectionID],
           finalContext.runID == expectedRunID,
           finalContext.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let promptFallback,
           !promptFallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            finalContext.promptText = promptFallback
            finalContext.usedAgentOutputAsPrompt = true
            routeResources.runRouteBindings.tabContextByConnectionID[connectionID] = finalContext
        }

        let committedWrite = await commitAndClearTabContextSnapshot(
            route: routeResources,
            connectionID: connectionID,
            expectedRunID: expectedRunID,
            isStillCurrent: isStillCurrent,
            progressReporter: progressReporter,
            deferRunMappingCleanupUntilCaller: deferRunMappingCleanupUntilCaller,
            readFileAutoSelectionAlreadyFinished: alreadyFinishedAutoSelection
        )

        // Peer EOF may have transferred the live context while its auto-selection lane
        // was finishing. The locally captured commit snapshot remains authoritative;
        // consume any duplicate detached ownership exactly once.
        if routeResources.runRouteBindings.detachedContextBuilderTabContextByRunID[expectedRunID]?.connectionID == connectionID {
            routeResources.runRouteBindings.detachedContextBuilderTabContextByRunID.removeValue(forKey: expectedRunID)
        }

        if let committedWrite {
            let committedTab = ContextBuilderCommittedTabSnapshot(
                identity: committedWrite.identity,
                nestedRunID: expectedRunID,
                tab: committedWrite.tab,
                selectionRevision: committedWrite.selectionRevision,
                usedAgentOutputAsPrompt: committedWrite.usedAgentOutputAsPrompt
            )
            return ContextBuilderTabContextCommitResult(
                outcome: .committed,
                committedTab: committedTab
            )
        }
        if !isStillCurrent() || Task.isCancelled {
            return ContextBuilderTabContextCommitResult(
                outcome: .staleOrNoLongerCurrent,
                committedTab: nil
            )
        }
        return ContextBuilderTabContextCommitResult(
            outcome: .failed("Context Builder could not commit its final context for run \(expectedRunID.uuidString)."),
            committedTab: nil
        )
    }

    @MainActor
    @discardableResult
    func commitAndClearTabContext(
        route routeResources: MCPHostRouteResources,
        connectionID: UUID,
        expectedRunID: UUID? = nil,
        isStillCurrent: @MainActor () -> Bool = { true },
        progressReporter: ContextBuilderMCPProgressReporter? = nil,
        deferRunMappingCleanupUntilCaller: Bool = false,
        readFileAutoSelectionAlreadyFinished: Bool = false
    ) async -> Bool {
        await commitAndClearTabContextSnapshot(
            route: routeResources,
            connectionID: connectionID,
            expectedRunID: expectedRunID,
            isStillCurrent: isStillCurrent,
            progressReporter: progressReporter,
            deferRunMappingCleanupUntilCaller: deferRunMappingCleanupUntilCaller,
            readFileAutoSelectionAlreadyFinished: readFileAutoSelectionAlreadyFinished
        ) != nil
    }

    @MainActor
    private func commitAndClearTabContextSnapshot(
        route routeResources: MCPHostRouteResources,
        connectionID: UUID,
        expectedRunID: UUID? = nil,
        isStillCurrent: @MainActor () -> Bool = { true },
        progressReporter: ContextBuilderMCPProgressReporter? = nil,
        deferRunMappingCleanupUntilCaller: Bool = false,
        readFileAutoSelectionAlreadyFinished: Bool = false
    ) async -> CommittedTabWrite? {
        // Capture the authoritative snapshot on the main actor before the first suspension.
        // Connection cleanup may remove the dictionary entry while draining auto-selection,
        // but it cannot invalidate this locally owned snapshot.
        guard let commitOwnedContext = routeResources.runRouteBindings.tabContextByConnectionID[connectionID] else { return nil }

        // Decide whether we will commit stored UI state for this context.
        // Mismatch or logical cancellation => clear binding only.
        var shouldCommit = isStillCurrent()
        if let expected = expectedRunID, commitOwnedContext.runID != expected {
            tabContextLog("commitAndClearTabContext run mismatch connectionID=\(connectionID) expectedRunID=\(expected.uuidString) actualRunID=\(commitOwnedContext.runID?.uuidString ?? "nil") tab=\(commitOwnedContext.tabID) — clearing binding without commit")
            shouldCommit = false
        }

        if shouldCommit, !readFileAutoSelectionAlreadyFinished {
            let key = readFileAutoSelectionContextKey(connectionID: connectionID, context: commitOwnedContext)
            await progressReporter?(.readFileAutoSelectionFinish)
            let finishResult = await readFileAutoSelectionCoordinator(route: routeResources).finish(context: key)
            evictReadFileAutoSelectionCoverageCertificate(for: key)
            #if DEBUG
                readFileAutoSelectionForcedAuthoritativeProbeIDsByContext.removeValue(forKey: key)
            #endif
            if finishResult == .cancelled || finishResult == .invalidated {
                shouldCommit = false
            }
            if !isStillCurrent() || Task.isCancelled {
                shouldCommit = false
            }
        } else if !shouldCommit {
            invalidateReadFileAutoSelection(route: routeResources, connectionID: connectionID, context: commitOwnedContext)
        }

        // Clear the mutable tab snapshot regardless of mismatch so future calls cannot
        // mutate state being committed. Successful Context Builder completion may retain
        // the connection/run routing maps until its independently-owned transport teardown joins.
        endMirroringForConnection(connectionID)
        routeResources.runRouteBindings.readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: connectionID)
        fileToolLookupContextCacheByConnectionID.removeValue(forKey: connectionID)
        pendingFileToolLookupContextResolutionByConnectionID.removeValue(forKey: connectionID)?.task.cancel()
        routeResources.runRouteBindings.tabContextByConnectionID.removeValue(forKey: connectionID)
        if !deferRunMappingCleanupUntilCaller {
            routeResources.runRouteBindings.presentationWindowByConnection.removeValue(forKey: connectionID)
            if let runID = commitOwnedContext.runID {
                routeResources.runRouteBindings.connectionIDByRunID.removeValue(forKey: runID)
            }
            routeResources.runRouteBindings.connectionIDToRunID.removeValue(forKey: connectionID)
        }

        guard shouldCommit, isStillCurrent(), !Task.isCancelled else { return nil }

        tabContextLog("commitAndClearTabContext committing tab=\(commitOwnedContext.tabID) connectionID=\(connectionID) runID=\(commitOwnedContext.runID?.uuidString ?? "nil")")

        // IMPORTANT: Await the commit to ensure tab state is written before caller reads it.
        // The immutable payload remains owned by this run even if transport cleanup proceeds.
        await progressReporter?(.tabContextCommit)
        guard let committedTab = await commitTabContext(
            commitOwnedContext,
            isStillCurrent: isStillCurrent
        ), isStillCurrent(), !Task.isCancelled else { return nil }

        if !committedTab.tab.name.isEmpty {
            let tabName = committedTab.tab.name
            NotificationService.shared.notifyContextBuilderComplete(
                tabName: tabName,
                tabID: committedTab.tab.id,
                fallbackToDockBounce: true
            )
        }

        // End-of-run flush: persist this run's final state to disk (coalesced by DiskWriter)
        guard let manager = workspaceManager else { return nil }
        await progressReporter?(.statePersistence)
        await manager.pollAndSaveStateAsync(source: .mcpTabContextEndOfRun)
        guard isStillCurrent(), !Task.isCancelled else { return nil }
        return committedTab
    }

    #if DEBUG
        @MainActor
        func readFileAutoSelectionHandoverPredecessorConnectionIDsForTesting(
            connectionID: UUID
        ) -> [UUID] {
            guard let context = routeResources.runRouteBindings.tabContextByConnectionID[connectionID],
                  let runID = context.runID,
                  routeResources.runRouteBindings.connectionIDByRunID[runID] == connectionID,
                  routeResources.runRouteBindings.connectionIDToRunID[connectionID] == runID,
                  let lineage = runRouteBindings.readFileAutoSelectionHandoverLineageByConnectionID[connectionID],
                  lineage.successorKey == readFileAutoSelectionContextKey(
                      connectionID: connectionID,
                      context: context
                  )
            else { return [] }
            return lineage.predecessorKeys.compactMap { key in
                guard case let .bound(predecessorConnectionID, _) = key.route else { return nil }
                return predecessorConnectionID
            }
        }
    #endif

    @MainActor
    func finishReadFileAutoSelectionForConnectionTeardown(route routeResources: MCPHostRouteResources, connectionID: UUID) async {
        guard let context = routeResources.runRouteBindings.tabContextByConnectionID[connectionID] else { return }
        let key = readFileAutoSelectionContextKey(connectionID: connectionID, context: context)
        _ = await readFileAutoSelectionCoordinator(route: routeResources).finish(context: key)
        evictReadFileAutoSelectionCoverageCertificate(for: key)
        #if DEBUG
            readFileAutoSelectionForcedAuthoritativeProbeIDsByContext.removeValue(forKey: key)
            await MCPReadFileAutoSelectionProbeRegistry.shared.cancel(
                serverIdentity: ObjectIdentifier(self),
                contextKey: key
            )
            await MCPApplyEditsRebaseProbeRegistry.shared.cancel(
                serverIdentity: ObjectIdentifier(self),
                contextKey: key
            )
        #endif
    }

    @MainActor
    func removeTabContext(
        route routeResources: MCPHostRouteResources,
        forConnectionID connectionID: UUID?,
        clientName: String?,
        windowID: Int?,
        runID: UUID? = nil,
        removeQueuedPendingContext: Bool = true
    ) {
        if let connectionID {
            routeResources.runRouteBindings.readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: connectionID)
            if let context = routeResources.runRouteBindings.tabContextByConnectionID[connectionID],
               runID == nil || context.runID == runID
            {
                invalidateReadFileAutoSelection(route: routeResources, connectionID: connectionID, context: context)
                endMirroringForConnection(connectionID)
                fileToolLookupContextCacheByConnectionID.removeValue(forKey: connectionID)
                pendingFileToolLookupContextResolutionByConnectionID.removeValue(forKey: connectionID)?.task.cancel()
                routeResources.runRouteBindings.tabContextByConnectionID.removeValue(forKey: connectionID)
                routeResources.publishRelease(connectionID: connectionID)
                routeResources.runRouteBindings.presentationWindowByConnection.removeValue(forKey: connectionID)

                if let boundRunID = context.runID,
                   routeResources.runRouteBindings.connectionIDByRunID[boundRunID] == connectionID
                {
                    routeResources.runRouteBindings.connectionIDByRunID.removeValue(forKey: boundRunID)
                    routeResources.runRouteBindings.pendingPolicyTokenIDByRunID.removeValue(forKey: boundRunID)
                }
                if routeResources.runRouteBindings.connectionIDToRunID[connectionID] == context.runID {
                    routeResources.runRouteBindings.connectionIDToRunID.removeValue(forKey: connectionID)
                }

                tabContextLog("removeTabContext removed bound context connectionID=\(connectionID) runID=\(runID?.uuidString ?? "nil") tab=\(context.tabID)")
            } else if let runID {
                // A successful Context Builder commit may already have consumed the mutable
                // tab snapshot while deliberately retaining routing maps for a live child
                // connection. The caller owns removing those maps after termination joins.
                var removedDeferredMapping = false
                if routeResources.runRouteBindings.connectionIDByRunID[runID] == connectionID {
                    routeResources.runRouteBindings.connectionIDByRunID.removeValue(forKey: runID)
                    routeResources.runRouteBindings.pendingPolicyTokenIDByRunID.removeValue(forKey: runID)
                    removedDeferredMapping = true
                }
                if routeResources.runRouteBindings.connectionIDToRunID[connectionID] == runID {
                    routeResources.runRouteBindings.connectionIDToRunID.removeValue(forKey: connectionID)
                    removedDeferredMapping = true
                }
                if removedDeferredMapping {
                    routeResources.runRouteBindings.presentationWindowByConnection.removeValue(forKey: connectionID)
                    tabContextLog("removeTabContext removed deferred mapping connectionID=\(connectionID) runID=\(runID.uuidString)")
                }
            }
        }

        if let runID, connectionID == nil {
            routeResources.runRouteBindings.detachedContextBuilderTabContextByRunID.removeValue(forKey: runID)
            // This is an explicit cleanup by runID (called when discovery ends)
            for (boundConnectionID, context) in routeResources.runRouteBindings.tabContextByConnectionID where context.runID == runID {
                routeResources.runRouteBindings.readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: boundConnectionID)
            }
            if let mappedConnection = routeResources.runRouteBindings.connectionIDByRunID[runID] {
                routeResources.runRouteBindings.connectionIDToRunID.removeValue(forKey: mappedConnection)
                routeResources.runRouteBindings.presentationWindowByConnection.removeValue(forKey: mappedConnection)
            }
            routeResources.runRouteBindings.connectionIDByRunID.removeValue(forKey: runID)
            routeResources.runRouteBindings.pendingPolicyTokenIDByRunID.removeValue(forKey: runID)
        }

        // Only explicit run cleanup owns queued intent. Mapping rollback must not
        // consume a newer pending context for the same client/run generation.
        if removeQueuedPendingContext, let clientName, let runID {
            removePendingContext(route: routeResources, clientName: clientName, windowID: windowID, runID: runID)
        }
    }

    @MainActor
    private func removePendingContext(route routeResources: MCPHostRouteResources, clientName: String, windowID: Int?, runID: UUID) {
        if let windowID {
            let result = routeResources.runRouteBindings.pendingRunScopedTabContexts.pop(clientName: clientName, windowID: windowID, runID: runID)
            if result.context != nil {
                tabContextLog("removePendingContext removed pending context clientName=\(clientName) window=\(windowID) runID=\(runID.uuidString) remaining=\(result.remaining)")
            }
            return
        }

        let result = routeResources.runRouteBindings.pendingRunScopedTabContexts.popByRunID(clientName: clientName, runID: runID)
        if let _ = result.context, let windowID = result.windowID {
            tabContextLog("removePendingContext removed pending context clientName=\(clientName) window=\(windowID) runID=\(runID.uuidString) remaining=\(result.remaining)")
        } else {
            tabContextLog("removePendingContext no pending context found for clientName=\(clientName) runID=\(runID.uuidString)")
        }
    }

    @MainActor
    private func commitTabContext(
        _ context: MCPTabContextSnapshot,
        isStillCurrent: @MainActor () -> Bool = { true }
    ) async -> CommittedTabWrite? {
        guard isStillCurrent(), !Task.isCancelled else { return nil }
        guard let manager = workspaceManager else {
            tabContextLog("[warning] commitTabContext missing workspace manager for windowID \(context.windowID); skipping commit.")
            return nil
        }
        tabContextLog("commitTabContext using workspaceManager \(ObjectIdentifier(manager)) for context.windowID=\(context.windowID) self.windowID=\(windowID)")
        let targetWorkspaceID = context.workspaceID ?? manager.activeWorkspace?.id
        guard let workspaceID = targetWorkspaceID,
              let workspaceIndex = manager.workspaces.firstIndex(where: { $0.id == workspaceID }),
              let tabIndex = manager.workspaces[workspaceIndex].composeTabs.firstIndex(where: { $0.id == context.tabID })
        else {
            tabContextLog("[warning] commitTabContext skipping commit for tab \(context.tabID) – workspace unavailable.")
            return nil
        }

        var updatedTab = manager.workspaces[workspaceIndex].composeTabs[tabIndex]
        let isActive = (manager.workspaces[workspaceIndex].activeComposeTabID == updatedTab.id)
        let canonicalSelectionAdvanced = manager.selectionRevisionForMCP(
            workspaceID: workspaceID,
            tabID: context.tabID
        ) != context.selectionRevision

        if canonicalSelectionAdvanced {
            tabContextLog("commitTabContext preserving newer canonical selection tab=\(context.tabID) window=\(context.windowID) runID=\(context.runID?.uuidString ?? "nil")")
        } else {
            updatedTab.selection = context.selection
        }
        updatedTab.promptText = context.promptText
        if context.usedAgentOutputAsPrompt {
            updatedTab.contextOverrides.useOverridePrompt = false
            updatedTab.contextOverrides.overridePromptText = ""
        }
        updatedTab.selectedMetaPromptIDs = context.selectedMetaPromptIDs
        updatedTab.lastModified = Date()

        // Preserve the active file-selector tab before storing. `applyComposeTabState(_:)`
        // reloads from the workspace store, so setting this only on the local apply copy
        // would be discarded and a nil stored value would re-open the license default
        // Context Builder tab on every MCP selection commit.
        if isActive {
            updatedTab.activeSubView = promptVM.storedActiveSubView
        }

        // 1) Persist to backing store without publishing UI snapshots (prevents tool echo)
        guard isStillCurrent(), !Task.isCancelled else { return nil }
        guard manager.updateComposeTabStoredOnly(updatedTab, inWorkspaceID: workspaceID) else { return nil }
        let identity = WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: context.tabID)
        guard let storedTab = manager.composeTab(for: identity),
              storedTab.selection == updatedTab.selection
        else { return nil }
        selectionCoordinator?.protectCanonicalMCPSelectionFromDeferredUISnapshots(
            storedTab.selection,
            for: identity
        )
        let committedSelectionRevision = manager.selectionRevisionForMCP(
            workspaceID: identity.workspaceID,
            tabID: identity.tabID
        )
        guard committedSelectionRevision >= context.selectionRevision else { return nil }
        let committedTab = CommittedTabWrite(
            identity: identity,
            tab: storedTab,
            selectionRevision: committedSelectionRevision,
            usedAgentOutputAsPrompt: context.usedAgentOutputAsPrompt
        )
        tabContextLog("commitTabContext stored selection/prompt tab=\(context.tabID) window=\(context.windowID) runID=\(context.runID?.uuidString ?? "nil") workspaceID=\(workspaceID)")

        // 2) Apply to live UI ONLY if this tab is the active tab and the run still owns commit.
        guard isActive else {
            tabContextLog("commitTabContext skipping live UI apply (tab not active) tab=\(updatedTab.id)")
            return committedTab
        }
        guard !canonicalSelectionAdvanced else {
            tabContextLog("commitTabContext skipping stale live UI apply tab=\(updatedTab.id)")
            return committedTab
        }
        guard isStillCurrent(), !Task.isCancelled else { return nil }

        let applyTab = updatedTab

        // Fence cross‑tab snapshot emissions while we apply THIS tab's state
        manager.beginApplyingTabContext(forTabID: context.tabID)
        tabContextLog("commitTabContext applying to UI: tab=\(applyTab.id) selectionCount=\(applyTab.selection.selectedPaths.count) promptChars=\(applyTab.promptText.count)")
        await manager.applyComposeTabState(applyTab)
        // Refresh after the full UI apply because its final recount can enqueue another stale snapshot.
        selectionCoordinator?.protectCanonicalMCPSelectionFromDeferredUISnapshots(
            applyTab.selection,
            for: identity
        )
        manager.endApplyingTabContext(forTabID: context.tabID)
        tabContextLog("commitTabContext UI applied: tab=\(applyTab.id)")
        guard isStillCurrent(), !Task.isCancelled else { return nil }
        return committedTab
    }
}
