import Combine
import Foundation
import MCP

#if DEBUG
    private func tabContextLog(_ message: @autoclosure () -> String) {
        // print("[TabContext] \(message())")
    }
#else
    private func tabContextLog(_ message: @autoclosure () -> String) {}
#endif

extension MCPServerViewModel {
    struct PendingPolicyRunIDMappingToken {
        let id: UUID
        let connectionID: UUID
        let runID: UUID
        let displacedConnectionID: UUID?
        let displacedConnectionRunID: UUID?
        let displacedPendingPolicyTokenID: UUID?
        let previousRunID: UUID?
        let previousRunPrimaryConnectionID: UUID?
        let previousPendingPolicyTokenID: UUID?
        let previousWindowID: Int?
    }

    /// Ordered, immutable coordinator lanes displaced by one pending-policy replacement.
    /// Keys retain connection and binding-generation identity so later replacement churn cannot
    /// redirect a drain to another tab, workspace, run, or context generation.
    struct ReadFileAutoSelectionHandoverLineage {
        let successorKey: MCPReadFileAutoSelectionCoordinator.ContextKey
        let predecessorKeys: [MCPReadFileAutoSelectionCoordinator.ContextKey]
    }

    enum PendingPolicyRunIDMappingRollbackResult: Equatable {
        case restored
        case supersededBySameConnection
        case supersededByOtherConnection
    }

    /// Value snapshot of a compose tab plus MCP routing metadata.
    ///
    /// This is the tab-first runtime model for MCP/Agent work. It intentionally
    /// does not change persisted `WorkspaceModel` / `ComposeTabState` schemas.
    struct TabContextSnapshot {
        let tabID: UUID
        let windowID: Int
        let workspaceID: UUID?
        var promptText: String
        var selection: StoredSelection
        /// Monotonic canonical selection revision observed when this snapshot last synchronized.
        /// A final commit uses it to avoid overwriting selection persisted by a newer connection.
        var selectionRevision: UInt64
        /// Selected stored prompt IDs for computing meta tokens in tab-context snapshots.
        var selectedMetaPromptIDs: [UUID]
        /// Selected Context Builder prompt IDs. These are distinct from StoredPrompt IDs.
        var selectedContextBuilderPromptIDs: [UUID]
        /// Tab name for MCP metadata block generation.
        var tabName: String
        /// Optional run lease associated with this snapshot.
        var runID: UUID?
        /// Active persisted Agent session bound to this tab, if any.
        var activeAgentSessionID: UUID?
        /// Hydration-aware worktree binding state for the active Agent session at snapshot time.
        var worktreeBindingState: AgentSessionWorktreeBindingState
        var worktreeBindings: [AgentSessionWorktreeBinding] {
            get { worktreeBindingState.bindings ?? [] }
            set { worktreeBindingState = .hydrated(newValue) }
        }

        /// Frozen lookup context inherited by nested run-scoped tools.
        var frozenLookupContext: WorkspaceLookupContext?
        /// True if this snapshot was created via explicit `bind_context` / `_tabID` binding.
        /// Explicit bindings should persist even when the bound tab is not the active tab.
        let explicitlyBound: Bool
        /// Ephemeral identity for deferred read-file auto-selection work. A replacement binding
        /// receives a fresh generation so stale queued work cannot apply to the new snapshot.
        var readFileAutoSelectionGeneration: UInt64

        init(
            tabID: UUID,
            windowID: Int,
            workspaceID: UUID?,
            promptText: String,
            selection: StoredSelection,
            selectionRevision: UInt64 = 0,
            selectedMetaPromptIDs: [UUID],
            selectedContextBuilderPromptIDs: [UUID] = [],
            tabName: String,
            runID: UUID?,
            activeAgentSessionID: UUID? = nil,
            worktreeBindings: [AgentSessionWorktreeBinding] = [],
            worktreeBindingState: AgentSessionWorktreeBindingState? = nil,
            frozenLookupContext: WorkspaceLookupContext? = nil,
            explicitlyBound: Bool,
            readFileAutoSelectionGeneration: UInt64 = 0
        ) {
            self.tabID = tabID
            self.windowID = windowID
            self.workspaceID = workspaceID
            self.promptText = promptText
            self.selection = selection
            self.selectionRevision = selectionRevision
            self.selectedMetaPromptIDs = selectedMetaPromptIDs
            self.selectedContextBuilderPromptIDs = selectedContextBuilderPromptIDs
            self.tabName = tabName
            self.runID = runID
            self.activeAgentSessionID = activeAgentSessionID
            self.worktreeBindingState = worktreeBindingState
                ?? (activeAgentSessionID == nil ? .notApplicable : .hydrated(worktreeBindings))
            self.frozenLookupContext = frozenLookupContext
            self.explicitlyBound = explicitlyBound
            self.readFileAutoSelectionGeneration = readFileAutoSelectionGeneration
        }
    }

    /// TEMPORARY COMPATIBILITY ALIAS for code not yet migrated off the
    /// pre-snapshot name. New code should use `TabContextSnapshot`.
    typealias TabScopedContext = TabContextSnapshot

    enum TabContextSnapshotSource: String, Equatable {
        case explicitBinding
        case runInstall
        case runHandover
        case pendingRunScoped
        case implicitBindingCompatibility
        case explicitHint
    }

    struct TabContextHint: Equatable {
        let tabID: UUID
        let workspaceID: UUID?
        let windowID: Int?
    }

    enum TabContextResolutionPolicy: Equatable {
        /// Agent/restricted tools: require a bound, run-scoped, or explicit hinted tab context.
        case requireExplicitOrRunScoped
        /// Legacy non-agent tools during migration: allow active-tab fallback only; pending/headless routing remains run-scoped.
        case allowLegacyImplicitRouting
        /// One-shot callers that may use active UI compatibility but should not consume runless pending queues.
        case allowActiveTabCompatibility

        var allowsLegacyImplicitRouting: Bool {
            self == .allowLegacyImplicitRouting
        }

        var allowsActiveTabCompatibility: Bool {
            switch self {
            case .allowLegacyImplicitRouting, .allowActiveTabCompatibility:
                true
            case .requireExplicitOrRunScoped:
                false
            }
        }
    }

    enum ActiveTabCompatibilityFallbackDecision: Equatable {
        case allowed
        case disabled
        case prohibitedForRunScoped(MCPRunPurpose?)
        case notAllowedByPolicy
    }

    struct ActiveTabCompatibilityFallbackDiagnostic: Equatable {
        enum Outcome: String, Equatable {
            case allowed
            case disabled
            case prohibitedForRunScoped
        }

        let toolName: String
        let connectionID: UUID?
        let windowID: Int?
        let clientName: String?
        let outcome: Outcome
        let message: String
        let timestamp: Date
    }

    enum TabContextResolution {
        case tabContextSnapshot(TabContextSnapshot, source: TabContextSnapshotSource)
        case activeTabCompatibility

        var snapshot: TabContextSnapshot? {
            if case let .tabContextSnapshot(snapshot, _) = self { return snapshot }
            return nil
        }
    }

    struct ConnectionBindingSnapshot: Equatable {
        enum BindingKind: Equatable {
            case unbound
            case windowOnly
            case tabContext
        }

        let windowID: Int?
        let tabID: UUID?
        let workspaceID: UUID?
        let workspaceName: String?
        let tabName: String?
        let repoPaths: [String]
        let explicitlyBound: Bool
        let runID: UUID?

        var bindingKind: BindingKind {
            if tabID != nil {
                return .tabContext
            }
            if windowID != nil {
                return .windowOnly
            }
            return .unbound
        }
    }

    @MainActor
    struct PendingRunScopedContextStore {
        private var storage: [String: [Int: [UUID: TabScopedContext]]] = [:]

        var isEmpty: Bool {
            storage.isEmpty
        }

        func contains(clientName: String, windowID: Int, runID: UUID) -> Bool {
            storage[clientName]?[windowID]?[runID] != nil
        }

        @discardableResult
        mutating func enqueueReplacing(_ context: TabScopedContext, clientName: String, windowID: Int) -> Int {
            guard let runID = context.runID else { return queueLength(clientName: clientName, windowID: windowID) }

            // Keep exactly one pending entry per run for a client. If the run is reinstalled
            // for a different window/tab before a socket claims it, the newest exact run
            // context wins deterministically instead of leaving FIFO order to decide.
            if var windowMap = storage[clientName] {
                for existingWindowID in Array(windowMap.keys) {
                    windowMap[existingWindowID]?.removeValue(forKey: runID)
                    if windowMap[existingWindowID]?.isEmpty == true {
                        windowMap.removeValue(forKey: existingWindowID)
                    }
                }
                storage[clientName] = windowMap.isEmpty ? nil : windowMap
            }

            var windowMap = storage[clientName] ?? [:]
            var runMap = windowMap[windowID] ?? [:]
            runMap[runID] = context
            windowMap[windowID] = runMap
            storage[clientName] = windowMap
            return runMap.count
        }

        mutating func pop(clientName: String, windowID: Int, runID: UUID) -> (context: TabScopedContext?, remaining: Int) {
            guard var windowMap = storage[clientName],
                  var runMap = windowMap[windowID]
            else {
                return (nil, 0)
            }

            let context = runMap.removeValue(forKey: runID)
            if runMap.isEmpty {
                windowMap.removeValue(forKey: windowID)
            } else {
                windowMap[windowID] = runMap
            }
            if windowMap.isEmpty {
                storage.removeValue(forKey: clientName)
            } else {
                storage[clientName] = windowMap
            }
            return (context, runMap.count)
        }

        mutating func popByRunID(clientName: String, runID: UUID) -> (context: TabScopedContext?, windowID: Int?, remaining: Int) {
            guard var windowMap = storage[clientName] else {
                return (nil, nil, 0)
            }

            for windowID in windowMap.keys.sorted() {
                guard var runMap = windowMap[windowID], let context = runMap.removeValue(forKey: runID) else {
                    continue
                }
                if runMap.isEmpty {
                    windowMap.removeValue(forKey: windowID)
                } else {
                    windowMap[windowID] = runMap
                }
                if windowMap.isEmpty {
                    storage.removeValue(forKey: clientName)
                } else {
                    storage[clientName] = windowMap
                }
                return (context, windowID, runMap.count)
            }

            return (nil, nil, 0)
        }

        func queueLength(clientName: String, windowID: Int) -> Int {
            storage[clientName]?[windowID]?.count ?? 0
        }

        mutating func clear(clientName: String) {
            storage.removeValue(forKey: clientName)
        }

        /// Clear only one window queue for a given client.
        @discardableResult
        mutating func clear(clientName: String, windowID: Int) -> Int {
            guard var windowMap = storage[clientName] else { return 0 }
            let removed = windowMap[windowID]?.count ?? 0
            windowMap.removeValue(forKey: windowID)
            if windowMap.isEmpty {
                storage.removeValue(forKey: clientName)
            } else {
                storage[clientName] = windowMap
            }
            return removed
        }

        mutating func purge(tabID: UUID) -> [TabScopedContext] {
            var removed: [TabScopedContext] = []
            let clientNames = Array(storage.keys)

            for clientName in clientNames {
                guard var windowMap = storage[clientName] else { continue }
                for windowID in Array(windowMap.keys) {
                    guard var runMap = windowMap[windowID] else { continue }
                    for (runID, context) in runMap where context.tabID == tabID {
                        removed.append(context)
                        runMap.removeValue(forKey: runID)
                    }
                    if runMap.isEmpty {
                        windowMap.removeValue(forKey: windowID)
                    } else {
                        windowMap[windowID] = runMap
                    }
                }

                if windowMap.isEmpty {
                    storage.removeValue(forKey: clientName)
                } else {
                    storage[clientName] = windowMap
                }
            }

            return removed
        }
    }

    // MARK: - Auto-binding for headless clients

    /// Identify headless agent clients we want to auto-bind
    private func isHeadlessClientName(_ name: String) -> Bool {
        MCPClientIdentity.isHeadlessAgentClient(name)
    }

    @MainActor
    private func recordLastContext(clientName: String, context: TabScopedContext) {
        var perWindow = lastContextByClientAndWindow[clientName] ?? [:]
        perWindow[context.windowID] = context
        lastContextByClientAndWindow[clientName] = perWindow
    }

    @MainActor
    private static func popPendingContextForBinding(
        from store: inout PendingRunScopedContextStore,
        clientName: String,
        windowID: Int,
        runHint: UUID?
    ) -> (context: TabScopedContext?, remaining: Int, usedRunHint: Bool) {
        guard let runHint else {
            return (nil, store.queueLength(clientName: clientName, windowID: windowID), false)
        }
        let result = store.pop(clientName: clientName, windowID: windowID, runID: runHint)
        let usedRunHint = result.context?.runID == runHint
        return (result.context, result.remaining, usedRunHint)
    }

    @MainActor
    private func shouldKeepBinding(
        connectionID: UUID,
        clientName: String?,
        providedWindowID: Int?,
        bound: TabScopedContext
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
            let hasPending: Bool = if let runID = connectionIDToRunID[connectionID] {
                pendingRunScopedTabContexts.contains(clientName: clientName, windowID: bound.windowID, runID: runID)
            } else {
                pendingRunScopedTabContexts.queueLength(clientName: clientName, windowID: bound.windowID) > 0
            }
            let isActiveTab = (manager.workspaces[workspaceIndex].activeComposeTabID == bound.tabID)
            if !hasPending, !isActiveTab {
                return false
            }
        }

        return true
    }

    @MainActor
    private func removeRunIDMapping(runID: UUID, connectionID: UUID) {
        if connectionIDByRunID[runID] == connectionID {
            connectionIDByRunID.removeValue(forKey: runID)
        }
        if connectionIDToRunID[connectionID] == runID {
            connectionIDToRunID.removeValue(forKey: connectionID)
        }
    }

    @MainActor
    private func readFileAutoSelectionContextKey(
        connectionID: UUID,
        context: TabScopedContext
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
    private func activateReadFileAutoSelection(_ context: inout TabScopedContext) {
        nextReadFileAutoSelectionBindingGeneration &+= 1
        context.readFileAutoSelectionGeneration = nextReadFileAutoSelectionBindingGeneration
    }

    @MainActor
    private func invalidateReadFileAutoSelection(connectionID: UUID, context: TabScopedContext) {
        readFileAutoSelectionCoordinator.invalidate(
            context: readFileAutoSelectionContextKey(connectionID: connectionID, context: context)
        )
    }

    @MainActor
    private func releaseBinding(connectionID: UUID, preserveConnectionRunIDMapping: Bool = false) {
        readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: connectionID)
        guard let context = tabContextByConnectionID.removeValue(forKey: connectionID) else { return }
        invalidateReadFileAutoSelection(connectionID: connectionID, context: context)
        endMirroringForConnection(connectionID)
        windowIDByConnection.removeValue(forKey: connectionID)
        let updatedMappings = Self.runMappingsAfterBindingRelease(
            contextRunID: context.runID,
            connectionID: connectionID,
            connectionIDByRunID: connectionIDByRunID,
            connectionIDToRunID: connectionIDToRunID,
            preserveConnectionRunIDMapping: preserveConnectionRunIDMapping
        )
        connectionIDByRunID = updatedMappings.connectionIDByRunID
        connectionIDToRunID = updatedMappings.connectionIDToRunID
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
    private func beginMirroringForConnection(_ connectionID: UUID, context: TabScopedContext) {
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

                    // 3) Merge snapshot into bound context, but preserve manual codemap mode once set.
                    guard var bound = self.tabContextByConnectionID[connectionID] else { return }
                    var incomingSelection = snapshot.selection

                    // Preserve manual=false stickiness
                    let wasManual = (bound.selection.codemapAutoEnabled == false)
                    if wasManual && incomingSelection.codemapAutoEnabled == true {
                        incomingSelection = StoredSelection(
                            selectedPaths: incomingSelection.selectedPaths,
                            autoCodemapPaths: incomingSelection.autoCodemapPaths,
                            slices: incomingSelection.slices,
                            codemapAutoEnabled: false
                        )
                        // DON'T call commitTabContext here - it creates an infinite loop!
                        // The bound context correction is enough; next operation will sync to UI.
                        tabContextLog("preserved manual mode on snapshot connectionID=\(connectionID) tab=\(context.tabID)")
                    }

                    // 4) Apply if changed
                    let selectionChanged = bound.selection != incomingSelection
                    let promptChanged = bound.promptText != snapshot.promptText
                    let metaChanged = bound.selectedMetaPromptIDs != snapshot.selectedMetaPromptIDs
                    let nameChanged = bound.tabName != snapshot.name
                    if selectionChanged || promptChanged || metaChanged || nameChanged {
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
                        self.tabContextByConnectionID[connectionID] = bound
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
    private func pushVirtualContextToUI(_ context: TabScopedContext) async {
        // `commitTabContext` already recounts when it applies the active tab. Avoid a
        // duplicate immediate recount after the heavy file-selector projection.
        await commitTabContext(context)
    }

    @MainActor
    func pendingContextQueueLength(clientName: String, windowID: Int) -> Int {
        pendingRunScopedTabContexts.queueLength(clientName: clientName, windowID: windowID)
    }

    // MARK: - Tab Binding APIs for MCP Routing

    /// Returns the currently bound tab ID for a connection, if any.
    /// Only returns a tab ID if the binding is for this window.
    @MainActor
    func boundTabID(forConnection connectionID: UUID?) -> UUID? {
        guard let connectionID,
              let ctx = tabContextByConnectionID[connectionID]
        else { return nil }

        // Only treat it as "bound here" if this MCPServerViewModel owns that window
        guard ctx.windowID == windowID else { return nil }
        return ctx.tabID
    }

    #if DEBUG
        @MainActor
        func debugSelectionRevisionForBoundConnection(_ connectionID: UUID) -> UInt64? {
            tabContextByConnectionID[connectionID]?.selectionRevision
        }
    #endif

    @MainActor
    func connectionBindingSnapshot(forConnection connectionID: UUID) -> ConnectionBindingSnapshot {
        if let context = tabContextByConnectionID[connectionID],
           context.windowID == windowID
        {
            let workspace = context.workspaceID.flatMap { workspaceID in
                workspaceManager?.workspaces.first(where: { $0.id == workspaceID })
            }
            let resolvedTabName =
                workspaceManager?.composeTabName(with: context.tabID)
                    ?? promptVM.currentComposeTabs.first(where: { $0.id == context.tabID })?.name
                    ?? context.tabName
            return ConnectionBindingSnapshot(
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

        if let mappedWindowID = windowIDByConnection[connectionID],
           mappedWindowID == windowID
        {
            let workspace = workspaceManager?.activeWorkspace
            return ConnectionBindingSnapshot(
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

        return ConnectionBindingSnapshot(
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
    func clearExplicitBinding(forConnection connectionID: UUID) -> ConnectionBindingSnapshot? {
        guard let context = tabContextByConnectionID[connectionID],
              context.windowID == windowID,
              context.runID == nil,
              context.explicitlyBound
        else {
            return nil
        }

        let snapshot = connectionBindingSnapshot(forConnection: connectionID)
        releaseBinding(connectionID: connectionID)
        return snapshot
    }

    @MainActor
    func clearNonRunScopedBinding(forConnection connectionID: UUID) -> ConnectionBindingSnapshot? {
        guard let context = tabContextByConnectionID[connectionID],
              context.windowID == windowID,
              context.runID == nil
        else {
            return nil
        }

        let snapshot = connectionBindingSnapshot(forConnection: connectionID)
        releaseBinding(connectionID: connectionID)
        return snapshot
    }

    /// Returns live run IDs currently bound to a tab in this window.
    @MainActor
    func liveRunIDsBound(toTabID tabID: UUID) -> [UUID] {
        let runIDs = tabContextByConnectionID.values.compactMap { context -> UUID? in
            guard context.tabID == tabID, let runID = context.runID else { return nil }
            return liveConnectionID(forRunID: runID) != nil ? runID : nil
        }
        return Array(Set(runIDs)).sorted { $0.uuidString < $1.uuidString }
    }

    /// Proactively removes all cached tab-context state for a closing tab while preserving window affinity.
    @MainActor
    func purgeClosedTabContext(tabID: UUID) {
        let boundConnections = tabContextByConnectionID.compactMap { connectionID, context in
            context.tabID == tabID ? connectionID : nil
        }

        for connectionID in boundConnections {
            readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: connectionID)
            guard let context = tabContextByConnectionID.removeValue(forKey: connectionID) else { continue }
            invalidateReadFileAutoSelection(connectionID: connectionID, context: context)
            endMirroringForConnection(connectionID)
            if let runID = context.runID {
                cleanupRunIDMapping(runID: runID, connectionID: connectionID)
            } else {
                connectionIDToRunID.removeValue(forKey: connectionID)
            }
            tabContextLog("purgeClosedTabContext removed bound context connectionID=\(connectionID) tab=\(tabID)")
        }

        let removedPending = pendingRunScopedTabContexts.purge(tabID: tabID)
        if !removedPending.isEmpty {
            tabContextLog("purgeClosedTabContext removed \(removedPending.count) pending contexts for tab=\(tabID)")
        }

        for (clientName, perWindow) in lastContextByClientAndWindow {
            let filtered = perWindow.filter { $0.value.tabID != tabID }
            if filtered.isEmpty {
                lastContextByClientAndWindow.removeValue(forKey: clientName)
            } else if filtered.count != perWindow.count {
                lastContextByClientAndWindow[clientName] = filtered
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
    private func makeTabContextSnapshot(
        tabID: UUID,
        workspaceID requestedWorkspaceID: UUID?,
        windowID: Int,
        runID: UUID?,
        explicitlyBound: Bool,
        captureActiveUIState: Bool,
        flushActiveSelection: Bool
    ) throws -> TabContextSnapshot {
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
        return TabContextSnapshot(
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
    ) -> TabContextSnapshot {
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
            return TabContextSnapshot(
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

        return TabContextSnapshot(
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
        connectionID: UUID,
        clientName: String?,
        tabID: UUID,
        workspaceID: UUID,
        windowID: Int,
        runID: UUID? = nil,
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

        // Tear down any previous binding for this connection
        if tabContextByConnectionID[connectionID] != nil {
            releaseBinding(connectionID: connectionID)
        }

        // Explicit tab-context bindings preserve the tab's stored state unless a caller opts into
        // active selection flushing through the snapshot helper.
        var context = try makeTabContextSnapshot(
            tabID: tab.id,
            workspaceID: ws.id,
            windowID: windowID,
            runID: runID,
            explicitlyBound: explicitlyBound,
            captureActiveUIState: false,
            flushActiveSelection: false
        )

        activateReadFileAutoSelection(&context)
        tabContextByConnectionID[connectionID] = context
        windowIDByConnection[connectionID] = windowID
        if let runID {
            let mappingSucceeded = registerRunIDMapping(connectionID: connectionID, runID: runID, windowID: windowID)
            guard mappingSucceeded else {
                tabContextByConnectionID.removeValue(forKey: connectionID)
                windowIDByConnection.removeValue(forKey: connectionID)
                throw TabBindError.runMappingRejected(runID)
            }
        }
        if let clientName {
            recordLastContext(clientName: clientName, context: context)
        }
        beginMirroringForConnection(connectionID, context: context)
        tabContextLog("bindTabForConnection connectionID=\(connectionID) tab=\(tabID) window=\(windowID) workspace=\(workspaceID) runID=\(runID?.uuidString ?? "nil")")
    }

    /// Rebinds connection to target tab if currently bound to a different tab.
    /// Used by oracle_send when continuing a chat that lives on a different tab.
    /// - Returns: true if rebinding occurred, false if already on correct tab or target invalid
    @MainActor
    @discardableResult
    func rebindToTabIfNeeded(
        connectionID: UUID,
        clientName: String?,
        windowID: Int,
        targetTabID: UUID,
        targetWorkspaceID: UUID
    ) throws -> Bool {
        let currentBoundTabID = tabContextByConnectionID[connectionID]?.tabID

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
        clientID: String?,
        clientName: String?,
        context: TabContextSnapshot,
        signalRouting: Bool = true,
        deferRunIDReplacementForPendingPolicy: Bool = false
    ) -> PendingPolicyRunIDMappingToken? {
        tabContextLog("installFrozenTabContext tab=\(context.tabID) window=\(context.windowID) clientID=\(clientID ?? "nil") clientName=\(clientName ?? "nil") runID=\(context.runID?.uuidString ?? "nil")")
        return installTabContext(
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
        clientID: String?,
        clientName: String?,
        windowID: Int,
        context initialContext: TabContextSnapshot,
        signalRouting: Bool,
        deferRunIDReplacementForPendingPolicy: Bool
    ) -> PendingPolicyRunIDMappingToken? {
        var context = initialContext
        if let clientID,
           let uuid = UUID(uuidString: clientID)
        {
            // Conflict-safe immediate binding path
            if let existing = tabContextByConnectionID[uuid],
               let existingRun = existing.runID,
               let newRun = context.runID,
               existingRun != newRun
            {
                // Do not overwrite another run's binding; queue instead (requires clientName)
                tabContextLog("installTabContext declined overwrite connectionID=\(uuid) existingRun=\(existingRun) newRun=\(newRun); queuing by clientName")
                if let clientName {
                    enqueuePendingContext(context, clientName: clientName, windowID: windowID)
                } else {
                    tabContextLog("[warning] installTabContext conflict but no clientName provided; cannot queue")
                }
                return nil
            }
            if deferRunIDReplacementForPendingPolicy, tabContextByConnectionID[uuid] != nil {
                tabContextLog("installTabContext declined pending-policy overwrite of existing context connectionID=\(uuid)")
                return nil
            }

            tabContextLog("installTabContext immediate bind connectionID=\(uuid)")
            readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: uuid)
            if let previous = tabContextByConnectionID[uuid] {
                invalidateReadFileAutoSelection(connectionID: uuid, context: previous)
                endMirroringForConnection(uuid)
            }
            activateReadFileAutoSelection(&context)
            tabContextByConnectionID[uuid] = context
            windowIDByConnection[uuid] = context.windowID
            var pendingPolicyToken: PendingPolicyRunIDMappingToken?
            if let runID = context.runID {
                if deferRunIDReplacementForPendingPolicy {
                    pendingPolicyToken = registerPendingPolicyRunIDMapping(
                        connectionID: uuid,
                        runID: runID,
                        windowID: context.windowID
                    )
                } else {
                    _ = registerRunIDMapping(
                        connectionID: uuid,
                        runID: runID,
                        windowID: context.windowID,
                        signalRouting: signalRouting
                    )
                }
                // Consume any queued intent for this exact run after direct installation.
                if let clientName {
                    let popped = pendingRunScopedTabContexts.popByRunID(clientName: clientName, runID: runID)
                    if popped.context != nil {
                        tabContextLog("installTabContext consumed queued intent for client=\(clientName) runID=\(runID) window=\(windowID) remaining=\(popped.remaining)")
                    }
                }
            }
            if let clientName {
                recordLastContext(clientName: clientName, context: context)
            }
            beginMirroringForConnection(uuid, context: context)
            return pendingPolicyToken
        }

        guard let clientName else {
            tabContextLog("[warning] installTabContext missing client identifier; context cannot be queued.")
            return nil
        }

        enqueuePendingContext(context, clientName: clientName, windowID: windowID)
        return nil
    }

    @MainActor
    private func enqueuePendingContext(_ context: TabScopedContext, clientName: String, windowID: Int) {
        guard let runID = context.runID else {
            tabContextLog("enqueuePendingContext skipped runless context clientName=\(clientName) window=\(windowID) tab=\(context.tabID)")
            return
        }
        let queueBefore = pendingRunScopedTabContexts.queueLength(clientName: clientName, windowID: windowID)
        let queueSize = pendingRunScopedTabContexts.enqueueReplacing(context, clientName: clientName, windowID: windowID)
        recordLastContext(clientName: clientName, context: context)
        tabContextLog("enqueuePendingContext clientName=\(clientName) window=\(windowID) tab=\(context.tabID) queueBefore=\(queueBefore) queueAfter=\(queueSize) runID=\(runID.uuidString)")
    }

    @MainActor
    private func bindPendingContextToConnection(
        clientName: String,
        windowID: Int,
        connectionID: UUID
    ) -> TabScopedContext? {
        let queueBefore = pendingRunScopedTabContexts.queueLength(clientName: clientName, windowID: windowID)
        let runHint = connectionIDToRunID[connectionID]

        // Only set a hint mapping if we don't already have one; do not override
        if windowIDByConnection[connectionID] == nil {
            windowIDByConnection[connectionID] = windowID
        }
        if let runID = runHint,
           let previousConnection = connectionIDByRunID[runID],
           previousConnection != connectionID,
           let existing = tabContextByConnectionID[previousConnection]
        {
            if existing.windowID == windowID {
                readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: previousConnection)
                readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: connectionID)
                tabContextByConnectionID.removeValue(forKey: previousConnection)
                invalidateReadFileAutoSelection(connectionID: previousConnection, context: existing)
                endMirroringForConnection(previousConnection)
                connectionIDToRunID.removeValue(forKey: previousConnection)
                windowIDByConnection.removeValue(forKey: previousConnection)
                var rebound = existing
                activateReadFileAutoSelection(&rebound)
                tabContextByConnectionID[connectionID] = rebound
                windowIDByConnection[connectionID] = rebound.windowID
                _ = registerRunIDMapping(connectionID: connectionID, runID: runID, windowID: rebound.windowID)
                recordLastContext(clientName: clientName, context: rebound)
                beginMirroringForConnection(connectionID, context: rebound)
                tabContextLog("bindPendingContextToConnection handover: runID=\(runID) tab=\(rebound.tabID) \(previousConnection) -> \(connectionID) queueBefore=\(queueBefore)")
                return rebound
            } else {
                tabContextLog("bindPendingContextToConnection handover skipped window mismatch runID=\(runID) prevWindow=\(existing.windowID) currentWindow=\(windowID)")
            }
        }
        let result = Self.popPendingContextForBinding(
            from: &pendingRunScopedTabContexts,
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

        readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: connectionID)
        activateReadFileAutoSelection(&context)
        tabContextByConnectionID[connectionID] = context
        windowIDByConnection[connectionID] = context.windowID
        if let runID = context.runID {
            let mappingSucceeded = registerRunIDMapping(connectionID: connectionID, runID: runID, windowID: context.windowID)
            // If we successfully registered the mapping, or if the initial runHint matched, count it as used
            usedRunHint = usedRunHint || (runHint == runID) || mappingSucceeded
        }
        recordLastContext(clientName: clientName, context: context)
        beginMirroringForConnection(connectionID, context: context)

        tabContextLog(
            "bindPendingContextToConnection clientName=\(clientName) window=\(windowID) connectionID=\(connectionID) runID=\(context.runID?.uuidString ?? "nil") tab=\(context.tabID) queueBefore=\(queueBefore) remaining=\(result.remaining) usedRunHint=\(usedRunHint) fallback=false"
        )
        return context
    }

    struct RequestMetadata {
        let connectionID: UUID?
        let clientName: String?
        let windowID: Int?
        /// Run purpose known at request capture time. Agent Mode / run-scoped calls
        /// must fail closed instead of using active-tab compatibility.
        let runPurpose: MCPRunPurpose?
        /// One-shot dispatch-level tab-context hint from context_id / legacy _tabID.
        /// This is not a sticky connection binding; resolvers validate it against any
        /// existing binding and otherwise use it for this call only.
        let tabContextHint: TabContextHint?

        init(
            connectionID: UUID?,
            clientName: String?,
            windowID: Int?,
            runPurpose: MCPRunPurpose? = nil,
            tabContextHint: TabContextHint? = nil
        ) {
            self.connectionID = connectionID
            self.clientName = clientName
            self.windowID = windowID
            self.runPurpose = runPurpose
            self.tabContextHint = tabContextHint
        }
    }

    @MainActor
    func captureRequestMetadata() async -> RequestMetadata {
        let connectionID = await service.currentRequestConnectionID()
        let runPurpose: MCPRunPurpose? = if let connectionID {
            await ServerNetworkManager.shared.runPurpose(for: connectionID)
        } else {
            nil
        }
        return await RequestMetadata(
            connectionID: connectionID,
            clientName: service.currentRequestClientName(),
            windowID: service.currentRequestWindowID(),
            runPurpose: runPurpose,
            tabContextHint: ServerNetworkManager.currentTabContextHint
        )
    }

    @MainActor
    func resolveTabContext(
        from metadata: RequestMetadata,
        explicitHint: TabContextHint? = nil,
        toolName: String = "unknown",
        policy: TabContextResolutionPolicy
    ) throws -> TabContextResolution {
        try resolveTabContext(
            connectionID: metadata.connectionID,
            clientName: metadata.clientName,
            providedWindowID: metadata.windowID,
            explicitHint: explicitHint ?? metadata.tabContextHint,
            toolName: toolName,
            policy: policy,
            runPurpose: metadata.runPurpose
        )
    }

    struct ResolvedTabContextSnapshot {
        var snapshot: TabContextSnapshot
        let usesActiveTabCompatibility: Bool
    }

    nonisolated static func activeTabCompatibilityFallbackDecision(
        policy: TabContextResolutionPolicy,
        fallbackEnabled: Bool,
        hasRunScopedContext: Bool,
        runPurpose: MCPRunPurpose?
    ) -> ActiveTabCompatibilityFallbackDecision {
        guard policy.allowsActiveTabCompatibility else { return .notAllowedByPolicy }
        if hasRunScopedContext || runPurpose == .agentModeRun || runPurpose == .discoverRun {
            return .prohibitedForRunScoped(runPurpose)
        }
        guard fallbackEnabled else { return .disabled }
        return .allowed
    }

    @MainActor
    func setActiveTabCompatibilityFallbackEnabled(_ enabled: Bool) {
        activeTabCompatibilityFallbackEnabled = enabled
    }

    @MainActor
    func clearActiveTabCompatibilityFallbackDiagnostics() {
        activeTabCompatibilityFallbackDiagnostics.removeAll()
    }

    @MainActor
    private func recordActiveTabCompatibilityFallbackDiagnostic(
        toolName: String,
        connectionID: UUID?,
        windowID: Int?,
        clientName: String?,
        outcome: ActiveTabCompatibilityFallbackDiagnostic.Outcome,
        message: String
    ) {
        let diagnostic = ActiveTabCompatibilityFallbackDiagnostic(
            toolName: toolName,
            connectionID: connectionID,
            windowID: windowID,
            clientName: clientName,
            outcome: outcome,
            message: message,
            timestamp: Date()
        )
        activeTabCompatibilityFallbackDiagnostics.append(diagnostic)
        if activeTabCompatibilityFallbackDiagnostics.count > 100 {
            activeTabCompatibilityFallbackDiagnostics.removeFirst(activeTabCompatibilityFallbackDiagnostics.count - 100)
        }
        tabContextLog("active-tab compatibility \(outcome.rawValue): tool=\(toolName) connectionID=\(connectionID?.uuidString ?? "nil") window=\(windowID.map(String.init) ?? "nil") client=\(clientName ?? "nil") message=\(message)")
    }

    @MainActor
    func activeTabCompatibilitySnapshot(
        metadata: RequestMetadata,
        toolName: String
    ) throws -> TabContextSnapshot {
        guard let manager = workspaceManager else {
            throw TabBindError.missingWorkspace
        }
        guard let workspace = manager.activeWorkspace else {
            throw TabBindError.missingWorkspace
        }
        guard let tabID = workspace.activeComposeTabID ?? workspace.composeTabs.first?.id else {
            throw TabBindError.tabNotFound(UUID())
        }
        let resolvedWindowID = metadata.windowID
            ?? metadata.connectionID.flatMap { windowIDByConnection[$0] }
            ?? windowID
        let runID = metadata.connectionID.flatMap { connectionIDToRunID[$0] }
        let snapshot = try makeTabContextSnapshot(
            tabID: tabID,
            workspaceID: workspace.id,
            windowID: resolvedWindowID,
            runID: runID,
            explicitlyBound: false,
            captureActiveUIState: true,
            flushActiveSelection: true
        )
        tabContextLog("active-tab compatibility snapshot for \(toolName) tab=\(snapshot.tabID) window=\(snapshot.windowID)")
        return snapshot
    }

    @MainActor
    func resolveTabContextSnapshot(
        from metadata: RequestMetadata,
        explicitHint: TabContextHint? = nil,
        toolName: String,
        policy: TabContextResolutionPolicy
    ) throws -> ResolvedTabContextSnapshot {
        switch try resolveTabContext(
            from: metadata,
            explicitHint: explicitHint,
            toolName: toolName,
            policy: policy
        ) {
        case let .tabContextSnapshot(snapshot, _):
            ResolvedTabContextSnapshot(snapshot: snapshot, usesActiveTabCompatibility: false)
        case .activeTabCompatibility:
            try ResolvedTabContextSnapshot(
                snapshot: activeTabCompatibilitySnapshot(metadata: metadata, toolName: toolName),
                usesActiveTabCompatibility: true
            )
        }
    }

    @MainActor
    private func selectionOnlyCommitContext(from context: TabContextSnapshot) -> TabContextSnapshot {
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
        merged.frozenLookupContext = context.frozenLookupContext
        merged.readFileAutoSelectionGeneration = context.readFileAutoSelectionGeneration
        return merged
    }

    enum MCPSelectionCoordinatorPersistenceResult: Equatable {
        case persisted
        case unchanged
        case unavailable
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
        mirrorToUIIfActive: Bool = true
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
            mirrorToUIIfActive: mirrorToUIIfActive
        )
        return outcome
    }

    @MainActor
    static func persistMCPSelectionAndVerifyThroughCoordinator(
        _ selection: StoredSelection,
        for tabID: UUID,
        workspaceID: UUID?,
        selectionCoordinator: WorkspaceSelectionCoordinator?,
        mirrorToUIIfActive: Bool = true
    ) async -> MCPSelectionPersistenceVerification {
        let outcome = await persistMCPSelectionThroughCoordinator(
            selection,
            for: tabID,
            workspaceID: workspaceID,
            selectionCoordinator: selectionCoordinator,
            mirrorToUIIfActive: mirrorToUIIfActive
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
    private func persistenceSafeTabContext(_ context: TabContextSnapshot) async -> TabContextSnapshot {
        let lookupContext = await lookupContext(for: context)
        var persisted = context
        persisted.selection = Self.logicalizeSelectionForPersistence(context.selection, lookupContext: lookupContext)
        return persisted
    }

    @MainActor
    @discardableResult
    func persistResolvedTabContextSnapshot(
        _ resolved: ResolvedTabContextSnapshot,
        metadata: RequestMetadata,
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

        if !resolved.usesActiveTabCompatibility,
           let canonicalSelection = verification.canonicalSelection,
           canonicalSelection == verification.expectedSelection,
           let connectionID = metadata.connectionID,
           let latest = tabContextByConnectionID[connectionID],
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
            tabContextByConnectionID[connectionID] = refreshed
        }
        return verification
    }

    @MainActor
    private func readFileAutoSelectionPersistenceContext(
        selection: StoredSelection,
        contextKey: MCPReadFileAutoSelectionCoordinator.ContextKey
    ) async -> TabContextSnapshot? {
        guard var context = readFileAutoSelectionContext(for: contextKey),
              context.tabID == contextKey.tabID
        else { return nil }
        context.selection = selection
        return context
    }

    @MainActor
    private func persistedSelectionForReadFileAutoSelection(
        selection: StoredSelection,
        contextKey: MCPReadFileAutoSelectionCoordinator.ContextKey
    ) async -> StoredSelection {
        guard let persistenceContext = await readFileAutoSelectionPersistenceContext(
            selection: selection,
            contextKey: contextKey
        ) else { return selection }
        #if DEBUG
            if let handler = readFileAutoSelectionPersistenceWillResolveHandlerForTesting {
                await handler()
            }
        #endif
        let persistedContext = await persistenceSafeTabContext(persistenceContext)
        return persistedContext.selection
    }

    @MainActor
    private func currentReadFileAutoSelectionTab(
        for contextKey: MCPReadFileAutoSelectionCoordinator.ContextKey
    ) -> (manager: WorkspaceManagerViewModel, identity: WorkspaceSelectionIdentity, tab: ComposeTabState)? {
        guard isReadFileAutoSelectionContextCurrent(contextKey),
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
        selection: StoredSelection,
        contextKey: MCPReadFileAutoSelectionCoordinator.ContextKey
    ) async -> Bool {
        guard isReadFileAutoSelectionContextCurrent(contextKey) else { return false }

        let persistedSelection = await persistedSelectionForReadFileAutoSelection(
            selection: selection,
            contextKey: contextKey
        )
        guard let target = currentReadFileAutoSelectionTab(for: contextKey) else { return false }

        if case let .bound(connectionID, _) = contextKey.route,
           var latest = tabContextByConnectionID[connectionID]
        {
            latest.selection = persistedSelection
            tabContextByConnectionID[connectionID] = latest
        }

        guard target.tab.selection != persistedSelection else { return false }
        let persistenceResult = await EditFlowPerf.measure(EditFlowPerf.Stage.ReadFile.AutoSelect.canonicalStoredCommit) {
            await Self.persistMCPSelectionThroughCoordinator(
                persistedSelection,
                for: contextKey.tabID,
                workspaceID: contextKey.workspaceID,
                selectionCoordinator: selectionCoordinator,
                mirrorToUIIfActive: false
            )
        }
        guard let refreshedTarget = currentReadFileAutoSelectionTab(for: contextKey) else { return false }
        if persistenceResult == .unavailable {
            var updatedTab = refreshedTarget.tab
            updatedTab.selection = persistedSelection
            updatedTab.lastModified = Date()
            await EditFlowPerf.measure(EditFlowPerf.Stage.ReadFile.AutoSelect.canonicalStoredCommit) {
                _ = refreshedTarget.manager.updateComposeTabStoredOnly(
                    updatedTab,
                    inWorkspaceID: refreshedTarget.identity.workspaceID
                )
            }
        }
        return true
    }

    @MainActor
    func resolveFileToolLookupRootScope(
        from metadata: RequestMetadata
    ) async -> WorkspaceLookupRootScope {
        await resolveFileToolLookupContext(from: metadata).rootScope
    }

    @MainActor
    func resolveFileToolLookupContext(
        tabID: UUID,
        workspaceID: UUID?
    ) async throws -> WorkspaceLookupContext {
        let snapshot = try makeTabContextSnapshot(
            tabID: tabID,
            workspaceID: workspaceID,
            windowID: windowID,
            runID: nil,
            explicitlyBound: false,
            captureActiveUIState: false,
            flushActiveSelection: false
        )
        return await lookupContext(for: snapshot)
    }

    @MainActor
    func resolveFileToolLookupContext(
        from metadata: RequestMetadata
    ) async -> WorkspaceLookupContext {
        let purpose = metadata.runPurpose ?? .unknown
        var resolved = try? resolveTabContextSnapshot(
            from: metadata,
            toolName: "file_tool_lookup_scope",
            policy: .allowLegacyImplicitRouting
        )
        if var snapshot = resolved?.snapshot,
           let sessionID = snapshot.activeAgentSessionID,
           snapshot.worktreeBindingState == .unhydrated,
           let agentWorktreeBindingStateResolver
        {
            snapshot.worktreeBindingState = await agentWorktreeBindingStateResolver(sessionID, snapshot.tabID)
            resolved?.snapshot = snapshot
            if let connectionID = metadata.connectionID,
               var bound = tabContextByConnectionID[connectionID],
               bound.tabID == snapshot.tabID,
               bound.windowID == snapshot.windowID,
               bound.workspaceID == snapshot.workspaceID,
               bound.runID == snapshot.runID,
               bound.activeAgentSessionID == snapshot.activeAgentSessionID,
               bound.readFileAutoSelectionGeneration == snapshot.readFileAutoSelectionGeneration
            {
                bound.worktreeBindingState = snapshot.worktreeBindingState
                tabContextByConnectionID[connectionID] = bound
            }
        }
        let baseScope = Self.resolveFileToolLookupRootScope(purpose: purpose, resolvedContext: resolved)
        guard let resolved else {
            return WorkspaceLookupContext(rootScope: baseScope, bindingProjection: nil)
        }
        if resolved.usesActiveTabCompatibility,
           resolved.snapshot.activeAgentSessionID == nil
        {
            return WorkspaceLookupContext(rootScope: baseScope, bindingProjection: nil)
        }
        if let frozenLookupContext = resolved.snapshot.frozenLookupContext {
            return frozenLookupContext
        }
        let lookupContext = await AgentWorkspaceLookupContextResolver.authoritativeLookupContextOrFailClosed(
            source: AgentWorkspaceLookupContextSource(
                activeAgentSessionID: resolved.snapshot.activeAgentSessionID,
                worktreeBindingState: resolved.snapshot.worktreeBindingState
            ),
            store: promptVM.workspaceFileContextStore
        )
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
        resolvedContext: ResolvedTabContextSnapshot?
    ) -> WorkspaceLookupRootScope {
        if purpose == .discoverRun,
           let resolvedContext,
           !resolvedContext.usesActiveTabCompatibility,
           resolvedContext.snapshot.runID != nil
        {
            return .visibleWorkspacePlusGitData
        }
        return .visibleWorkspace
    }

    static func spawnSourceTabIDForAgentSessionCreation(
        purpose: MCPRunPurpose,
        resolvedContext: ResolvedTabContextSnapshot?
    ) -> UUID? {
        guard purpose == .agentModeRun,
              let resolvedContext,
              !resolvedContext.usesActiveTabCompatibility
        else {
            return nil
        }
        return resolvedContext.snapshot.tabID
    }

    static func spawnParentSourceTabIDForAgentSessionCreation(
        purpose: MCPRunPurpose,
        resolvedContext: ResolvedTabContextSnapshot?
    ) -> UUID? {
        spawnSourceTabIDForAgentSessionCreation(
            purpose: purpose,
            resolvedContext: resolvedContext
        )
    }

    @MainActor
    func resolveSpawnSourceTabIDForAgentSessionCreation(
        metadata: RequestMetadata
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
            from: metadata,
            toolName: "agent_session_spawn_source",
            policy: .allowLegacyImplicitRouting
        )
        return Self.spawnSourceTabIDForAgentSessionCreation(
            purpose: purpose,
            resolvedContext: resolvedContext
        )
    }

    nonisolated static func shouldRejectAgentRunStartWithoutResolvedSource(
        capturedPurpose: MCPRunPurpose?,
        currentPurpose: MCPRunPurpose,
        cachedRunPolicyPurpose: MCPRunPurpose?
    ) -> Bool {
        capturedPurpose == .agentModeRun || currentPurpose == .agentModeRun || cachedRunPolicyPurpose == .agentModeRun
    }

    @MainActor
    func validateAgentRunStartRouting(
        metadata: RequestMetadata,
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
        metadata: RequestMetadata,
        targetWindow: WindowState
    ) async -> UUID? {
        guard let sourceTabID = await resolveSpawnSourceTabIDForAgentSessionCreation(
            metadata: metadata
        ) else {
            return nil
        }
        return targetWindow.agentModeViewModel.mcpSpawnParentSessionID(sourceTabID: sourceTabID)
    }

    nonisolated static func tabContextRoutingErrorMessage(
        toolName: String,
        runPurpose: MCPRunPurpose? = nil
    ) -> String {
        if runPurpose == .agentModeRun {
            return agentModeRoutingRecoveryMessage(toolName: toolName)
        }
        return "No tab context is bound for \(toolName). To resolve:\n" +
            "• Call 'bind_context' with op='list' to see available windows and context_id values\n" +
            "• Call 'bind_context' with op='bind' and a context_id to bind this connection to a tab context\n" +
            "• Or pass a matching explicit tab context hint for this tool call"
    }

    nonisolated static func activeTabCompatibilityDisabledMessage(toolName: String) -> String {
        "Active-tab compatibility fallback is disabled for \(toolName). Bind explicitly instead:\n" +
            "• Call 'bind_context' with op='list' to discover context_id values\n" +
            "• Call 'bind_context' with op='bind' and the intended context_id before retrying\n" +
            "• Or pass a matching context_id/_tabID hint on this tool call"
    }

    private nonisolated static func agentModeRoutingRecoveryMessage(toolName: String) -> String {
        "RepoPrompt could not route \(toolName) to the active Agent Mode run. " +
            "Retry the tool call once. If it fails again, tell the user the RepoPrompt connection failed and ask them to restart this Agent Mode run."
    }

    nonisolated static func runScopedActiveTabCompatibilityMessage(toolName: String, runPurpose: MCPRunPurpose?) -> String {
        if runPurpose == .agentModeRun {
            return agentModeRoutingRecoveryMessage(toolName: toolName)
        }
        let purpose = runPurpose?.rawValue ?? "run-scoped"
        return "Active-tab compatibility fallback is not allowed for \(toolName) during \(purpose) execution. " +
            "Bind the MCP connection to its invoking tab context with bind_context/context_id, or retry after run-scoped routing is established."
    }

    private static func hint(_ hint: TabContextHint, matches context: TabContextSnapshot) -> Bool {
        guard hint.tabID == context.tabID else { return false }
        if let workspaceID = hint.workspaceID, context.workspaceID != workspaceID { return false }
        if let windowID = hint.windowID, context.windowID != windowID { return false }
        return true
    }

    @MainActor
    private func resolveRunHandoverIfPossible(
        connectionID: UUID,
        clientName: String?,
        providedWindowID: Int?
    ) -> TabContextSnapshot? {
        guard let runID = connectionIDToRunID[connectionID],
              let previousConnection = connectionIDByRunID[runID],
              previousConnection != connectionID,
              let existing = tabContextByConnectionID[previousConnection]
        else {
            return nil
        }

        if let windowID = providedWindowID {
            windowIDByConnection[connectionID] = windowIDByConnection[connectionID] ?? windowID
            guard existing.windowID == windowID else {
                tabContextLog("resolveTabContext handover skipped (window mismatch) runID=\(runID) prevWindow=\(existing.windowID) newWindow=\(windowID)")
                return nil
            }
        }

        readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: previousConnection)
        readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: connectionID)
        tabContextByConnectionID.removeValue(forKey: previousConnection)
        invalidateReadFileAutoSelection(connectionID: previousConnection, context: existing)
        endMirroringForConnection(previousConnection)
        connectionIDToRunID.removeValue(forKey: previousConnection)
        windowIDByConnection.removeValue(forKey: previousConnection)

        var rebound = existing
        activateReadFileAutoSelection(&rebound)
        tabContextByConnectionID[connectionID] = rebound
        windowIDByConnection[connectionID] = rebound.windowID
        let mappingOK = registerRunIDMapping(connectionID: connectionID, runID: runID, windowID: rebound.windowID)
        if let clientName { recordLastContext(clientName: clientName, context: rebound) }
        beginMirroringForConnection(connectionID, context: rebound)
        tabContextLog("resolveTabContext handover: runID=\(runID) \(previousConnection) -> \(connectionID) mappingOK=\(mappingOK) window=\(providedWindowID?.description ?? "nil")")
        return rebound
    }

    @MainActor
    func resolveTabContext(
        connectionID: UUID?,
        clientName: String?,
        providedWindowID: Int?,
        explicitHint: TabContextHint? = nil,
        toolName: String = "unknown",
        policy: TabContextResolutionPolicy,
        runPurpose: MCPRunPurpose? = nil
    ) throws -> TabContextResolution {
        // Prefer network-provided window ID, but if it's missing and we've
        // already learned the mapping for this connection, use our mapping.
        var resolvedWindowID = providedWindowID
        if resolvedWindowID == nil, let cid = connectionID, let mapped = windowIDByConnection[cid] {
            resolvedWindowID = mapped
            tabContextLog("resolveTabContext used stored window mapping for connectionID=\(cid) window=\(mapped)")
        }

        // 1) Existing bound tab-context snapshot for this connection is authoritative only
        // when it is compatible with any current run hint and the requested policy.
        if let connectionID, let bound = tabContextByConnectionID[connectionID] {
            let requiredRunID = connectionIDToRunID[connectionID]
            let boundMatchesRunHint = requiredRunID.map { bound.runID == $0 } ?? true
            let boundAllowedByPolicy = policy != .requireExplicitOrRunScoped || bound.runID != nil || bound.explicitlyBound
            if !boundMatchesRunHint || !boundAllowedByPolicy {
                let shouldPreserveRunHint = requiredRunID != nil && bound.runID == nil
                tabContextLog("resolveTabContext released incompatible binding connectionID=\(connectionID) boundRun=\(bound.runID?.uuidString ?? "nil") requiredRun=\(requiredRunID?.uuidString ?? "nil") explicit=\(bound.explicitlyBound) policy=\(policy) preserveRunHint=\(shouldPreserveRunHint)")
                releaseBinding(connectionID: connectionID, preserveConnectionRunIDMapping: shouldPreserveRunHint)
            } else if shouldKeepBinding(
                connectionID: connectionID,
                clientName: clientName,
                providedWindowID: resolvedWindowID,
                bound: bound
            ) {
                if let explicitHint, !Self.hint(explicitHint, matches: bound) {
                    throw MCPError.invalidParams("Explicit tab context hint for \(toolName) targets tab \(explicitHint.tabID), but this connection is already bound to tab \(bound.tabID). Clear or intentionally rebind the connection before targeting a different tab context.")
                }
                if let hinted = resolvedWindowID {
                    if let existing = windowIDByConnection[connectionID], existing != hinted {
                        tabContextLog("resolveTabContext ignoring mismatched window hint for bound connectionID=\(connectionID) existing=\(existing) hinted=\(hinted)")
                    } else if windowIDByConnection[connectionID] == nil {
                        windowIDByConnection[connectionID] = hinted
                    }
                }
                beginMirroringForConnection(connectionID, context: bound)
                tabContextLog("resolveTabContext using bound context connectionID=\(connectionID) runID=\(bound.runID?.uuidString ?? "nil") tab=\(bound.tabID)")
                let source: TabContextSnapshotSource = {
                    if bound.runID != nil { return .runInstall }
                    return bound.explicitlyBound ? .explicitBinding : .implicitBindingCompatibility
                }()
                return .tabContextSnapshot(bound, source: source)
            } else {
                tabContextLog("resolveTabContext released stale binding connectionID=\(connectionID) tab=\(bound.tabID) window=\(bound.windowID)")
                releaseBinding(connectionID: connectionID)
            }
        }

        // 2) Exact runID handover from a replaced connection.
        if let connectionID,
           let handedOver = resolveRunHandoverIfPossible(
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
            let hintWindowID = explicitHint.windowID ?? resolvedWindowID ?? windowID
            let snapshot = try makeTabContextSnapshot(
                tabID: explicitHint.tabID,
                workspaceID: explicitHint.workspaceID,
                windowID: hintWindowID,
                runID: connectionID.flatMap { connectionIDToRunID[$0] },
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
           connectionIDToRunID[connectionID] != nil,
           let clientName,
           let windowID = resolvedWindowID,
           let context = bindPendingContextToConnection(clientName: clientName, windowID: windowID, connectionID: connectionID)
        {
            tabContextLog("resolveTabContext bound exact pending run context connectionID=\(connectionID) clientName=\(clientName) runID=\(context.runID?.uuidString ?? "nil") tab=\(context.tabID)")
            return .tabContextSnapshot(context, source: .pendingRunScoped)
        }

        // 5) Named active-tab compatibility fallback for legacy, non-agent callers.
        let hasRunScopedContext = connectionID.flatMap { connectionIDToRunID[$0] } != nil
        switch Self.activeTabCompatibilityFallbackDecision(
            policy: policy,
            fallbackEnabled: activeTabCompatibilityFallbackEnabled,
            hasRunScopedContext: hasRunScopedContext,
            runPurpose: runPurpose
        ) {
        case .allowed:
            let message = "Using temporary legacy active-tab compatibility fallback. Clients should bind explicitly with bind_context/context_id."
            recordActiveTabCompatibilityFallbackDiagnostic(
                toolName: toolName,
                connectionID: connectionID,
                windowID: resolvedWindowID,
                clientName: clientName,
                outcome: .allowed,
                message: message
            )
            return .activeTabCompatibility
        case .disabled:
            let message = Self.activeTabCompatibilityDisabledMessage(toolName: toolName)
            recordActiveTabCompatibilityFallbackDiagnostic(
                toolName: toolName,
                connectionID: connectionID,
                windowID: resolvedWindowID,
                clientName: clientName,
                outcome: .disabled,
                message: message
            )
            throw MCPError.invalidParams(message)
        case let .prohibitedForRunScoped(prohibitedPurpose):
            let message = Self.runScopedActiveTabCompatibilityMessage(toolName: toolName, runPurpose: prohibitedPurpose)
            recordActiveTabCompatibilityFallbackDiagnostic(
                toolName: toolName,
                connectionID: connectionID,
                windowID: resolvedWindowID,
                clientName: clientName,
                outcome: .prohibitedForRunScoped,
                message: message
            )
            throw MCPError.invalidParams(message)
        case .notAllowedByPolicy:
            break
        }

        // 6) Fail closed with routing guidance.
        throw MCPError.invalidParams(Self.tabContextRoutingErrorMessage(toolName: toolName, runPurpose: runPurpose))
    }

    @MainActor
    private func contextForCurrentRequest(toolName: String) async throws -> (UUID, TabContextSnapshot) {
        guard let connectionID = await service.currentRequestConnectionID() else {
            throw MCPError.invalidParams("No active connection for \(toolName)")
        }

        let metadata = await RequestMetadata(
            connectionID: connectionID,
            clientName: service.currentRequestClientName(),
            windowID: service.currentRequestWindowID(),
            tabContextHint: ServerNetworkManager.currentTabContextHint
        )
        let purpose = await ServerNetworkManager.shared.runPurpose(for: connectionID)

        do {
            let resolution = try resolveTabContext(
                from: metadata,
                toolName: toolName,
                policy: .requireExplicitOrRunScoped
            )
            guard case let .tabContextSnapshot(context, _) = resolution else {
                throw MCPError.invalidParams(Self.tabContextRoutingErrorMessage(toolName: toolName, runPurpose: purpose))
            }
            windowIDByConnection[connectionID] = context.windowID
            beginMirroringForConnection(connectionID, context: context)
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
    func requireCurrentTabContext(toolName: String) async throws -> TabScopedContext {
        let (_, context) = try await contextForCurrentRequest(toolName: toolName)
        return context
    }

    private nonisolated static func resolveLiveConnectionID(
        forRunID runID: UUID,
        connectionIDByRunID: [UUID: UUID],
        connectionIDToRunID: [UUID: UUID]
    ) -> UUID? {
        guard let connectionID = connectionIDByRunID[runID] else {
            return nil
        }
        guard connectionIDToRunID[connectionID] == runID else {
            return nil
        }
        return connectionID
    }

    @MainActor
    func connectionID(forRunID runID: UUID) -> UUID? {
        liveConnectionID(forRunID: runID)
    }

    @MainActor
    func liveConnectionID(forRunID runID: UUID) -> UUID? {
        Self.resolveLiveConnectionID(
            forRunID: runID,
            connectionIDByRunID: connectionIDByRunID,
            connectionIDToRunID: connectionIDToRunID
        )
    }

    @MainActor
    func hasLiveRunID(_ runID: UUID) -> Bool {
        liveConnectionID(forRunID: runID) != nil
    }

    nonisolated static func test_liveConnectionID(
        forRunID runID: UUID,
        connectionIDByRunID: [UUID: UUID],
        connectionIDToRunID: [UUID: UUID]
    ) -> UUID? {
        resolveLiveConnectionID(
            forRunID: runID,
            connectionIDByRunID: connectionIDByRunID,
            connectionIDToRunID: connectionIDToRunID
        )
    }

    @MainActor
    static func test_popPendingContextForBinding(
        from store: inout PendingRunScopedContextStore,
        clientName: String,
        windowID: Int,
        runHint: UUID?
    ) -> (context: TabScopedContext?, remaining: Int, usedRunHint: Bool) {
        popPendingContextForBinding(
            from: &store,
            clientName: clientName,
            windowID: windowID,
            runHint: runHint
        )
    }

    static func test_resolveFileToolLookupRootScope(
        purpose: MCPRunPurpose,
        resolvedContext: ResolvedTabContextSnapshot?
    ) -> WorkspaceLookupRootScope {
        resolveFileToolLookupRootScope(purpose: purpose, resolvedContext: resolvedContext)
    }

    /// Returns all connection IDs associated with a runID.
    /// This includes both the primary mapping (connectionIDByRunID) and any reverse mappings
    /// (connectionIDToRunID). Used by ContextBuilderAgentViewModel to find agent connections
    /// while avoiding termination of host MCP connections that may share the same runID.
    @MainActor
    func connectionIDs(forRunID runID: UUID) -> [UUID] {
        var ids: [UUID] = []
        if let primary = connectionIDByRunID[runID] {
            ids.append(primary)
        }
        for (connectionID, mappedRun) in connectionIDToRunID where mappedRun == runID {
            if !ids.contains(connectionID) {
                ids.append(connectionID)
            }
        }
        return ids
    }

    @MainActor
    func hasRunID(_ runID: UUID) -> Bool {
        hasLiveRunID(runID)
    }

    @MainActor
    func cleanupRunIDMapping(
        runID: UUID,
        connectionID: UUID,
        signalRoutingFailure: Bool = true
    ) {
        readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: connectionID)
        if connectionIDByRunID[runID] == connectionID {
            connectionIDByRunID.removeValue(forKey: runID)
            pendingPolicyRunIDMappingTokenIDByRunID.removeValue(forKey: runID)
        }
        if connectionIDToRunID[connectionID] == runID {
            connectionIDToRunID.removeValue(forKey: connectionID)
        }
        tabContextLog("cleanupRunIDMapping removed runID=\(runID) connectionID=\(connectionID)")

        // A stale generation must not fail routing for a newer replacement connection.
        if signalRoutingFailure, liveConnectionID(forRunID: runID) == nil {
            MCPRoutingWaiter.signalFailed(runID)
        }
    }

    @MainActor
    @discardableResult
    func registerRunIDMapping(
        connectionID: UUID,
        runID: UUID,
        windowID: Int,
        signalRouting: Bool = true
    ) -> Bool {
        // Fast path: already mapped to this exact run/connection.
        if connectionIDByRunID[runID] == connectionID,
           connectionIDToRunID[connectionID] == runID
        {
            pendingPolicyRunIDMappingTokenIDByRunID.removeValue(forKey: runID)
            windowIDByConnection[connectionID] = windowID
            if signalRouting {
                MCPRoutingWaiter.signalRouted(runID)
            }
            return true
        }

        // If this connection is already bound to a different run, refuse remap
        if let bound = tabContextByConnectionID[connectionID],
           let boundRun = bound.runID,
           boundRun != runID
        {
            tabContextLog("registerRunIDMapping refused: connectionID=\(connectionID) already bound to runID=\(boundRun), new=\(runID)")
            return false
        }

        if let existingConnection = connectionIDByRunID[runID],
           existingConnection != connectionID
        {
            let existingWindow = windowIDByConnection[existingConnection]
            if let existingWindow, existingWindow != windowID {
                tabContextLog("registerRunIDMapping refused window mismatch runID=\(runID) existingWindow=\(existingWindow) newWindow=\(windowID)")
                return false
            }
            // Handle connection replacement - uses soft-disconnect for same-session reconnects
            tabContextLog("registerRunIDMapping handling connection replacement: old=\(existingConnection) new=\(connectionID) runID=\(runID)")
            Task {
                await ServerNetworkManager.shared.handleConnectionReplaced(
                    existing: existingConnection,
                    by: connectionID,
                    runID: runID,
                    message: "Connection replaced by new connection for same runID"
                )
            }
            connectionIDToRunID.removeValue(forKey: existingConnection)
        }

        if let previous = connectionIDToRunID[connectionID], previous != runID {
            // Avoid dangling reverse mapping for stale run
            connectionIDByRunID.removeValue(forKey: previous)
        }
        windowIDByConnection[connectionID] = windowID
        connectionIDByRunID[runID] = connectionID
        connectionIDToRunID[connectionID] = runID
        pendingPolicyRunIDMappingTokenIDByRunID.removeValue(forKey: runID)
        tabContextLog("registerRunIDMapping connectionID=\(connectionID) runID=\(runID) windowID=\(windowID)")

        if signalRouting {
            MCPRoutingWaiter.signalRouted(runID)
        }

        return true
    }

    @MainActor
    func registerPendingPolicyRunIDMapping(
        connectionID: UUID,
        runID: UUID,
        windowID: Int
    ) -> PendingPolicyRunIDMappingToken? {
        if let bound = tabContextByConnectionID[connectionID],
           let boundRun = bound.runID,
           boundRun != runID
        {
            tabContextLog("registerPendingPolicyRunIDMapping refused: connectionID=\(connectionID) already bound to runID=\(boundRun), new=\(runID)")
            return nil
        }

        let displacedConnectionID = connectionIDByRunID[runID]
        if let displacedConnectionID,
           displacedConnectionID != connectionID,
           let existingWindow = windowIDByConnection[displacedConnectionID],
           existingWindow != windowID
        {
            tabContextLog("registerPendingPolicyRunIDMapping refused window mismatch runID=\(runID) existingWindow=\(existingWindow) newWindow=\(windowID)")
            return nil
        }

        let previousRunID = connectionIDToRunID[connectionID]
        let token = PendingPolicyRunIDMappingToken(
            id: UUID(),
            connectionID: connectionID,
            runID: runID,
            displacedConnectionID: displacedConnectionID == connectionID ? nil : displacedConnectionID,
            displacedConnectionRunID: displacedConnectionID.flatMap { connectionIDToRunID[$0] },
            displacedPendingPolicyTokenID: pendingPolicyRunIDMappingTokenIDByRunID[runID],
            previousRunID: previousRunID,
            previousRunPrimaryConnectionID: previousRunID.flatMap { connectionIDByRunID[$0] },
            previousPendingPolicyTokenID: previousRunID.flatMap { pendingPolicyRunIDMappingTokenIDByRunID[$0] },
            previousWindowID: windowIDByConnection[connectionID]
        )
        installReadFileAutoSelectionHandoverLineage(for: token)

        if let displacedConnectionID = token.displacedConnectionID,
           connectionIDToRunID[displacedConnectionID] == runID
        {
            connectionIDToRunID.removeValue(forKey: displacedConnectionID)
        }
        if let previousRunID, previousRunID != runID,
           connectionIDByRunID[previousRunID] == connectionID
        {
            connectionIDByRunID.removeValue(forKey: previousRunID)
            pendingPolicyRunIDMappingTokenIDByRunID.removeValue(forKey: previousRunID)
        }
        windowIDByConnection[connectionID] = windowID
        connectionIDByRunID[runID] = connectionID
        connectionIDToRunID[connectionID] = runID
        pendingPolicyRunIDMappingTokenIDByRunID[runID] = token.id
        tabContextLog("registerPendingPolicyRunIDMapping connectionID=\(connectionID) runID=\(runID) windowID=\(windowID)")
        return token
    }

    @MainActor
    private func installReadFileAutoSelectionHandoverLineage(
        for token: PendingPolicyRunIDMappingToken
    ) {
        guard let successorContext = tabContextByConnectionID[token.connectionID],
              successorContext.runID == token.runID
        else {
            readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: token.connectionID)
            return
        }
        let successorKey = readFileAutoSelectionContextKey(
            connectionID: token.connectionID,
            context: successorContext
        )

        guard let displacedConnectionID = token.displacedConnectionID else {
            let preservesCurrentSuccessor = token.displacedConnectionRunID == token.runID
                && connectionIDByRunID[token.runID] == token.connectionID
                && connectionIDToRunID[token.connectionID] == token.runID
                && readFileAutoSelectionHandoverLineageByConnectionID[token.connectionID]?.successorKey == successorKey
            if !preservesCurrentSuccessor {
                readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: token.connectionID)
            }
            return
        }

        readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: token.connectionID)
        guard token.displacedConnectionRunID == token.runID,
              connectionIDByRunID[token.runID] == displacedConnectionID,
              connectionIDToRunID[displacedConnectionID] == token.runID,
              let displacedContext = tabContextByConnectionID[displacedConnectionID],
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
        if let inherited = readFileAutoSelectionHandoverLineageByConnectionID[displacedConnectionID],
           inherited.successorKey == displacedKey
        {
            predecessorKeys.append(contentsOf: inherited.predecessorKeys)
        }
        if !predecessorKeys.contains(displacedKey) {
            predecessorKeys.append(displacedKey)
        }
        readFileAutoSelectionHandoverLineageByConnectionID[token.connectionID] = .init(
            successorKey: successorKey,
            predecessorKeys: predecessorKeys
        )
    }

    @MainActor
    func isCurrentPendingPolicyRunIDMapping(_ token: PendingPolicyRunIDMappingToken) -> Bool {
        pendingPolicyRunIDMappingTokenIDByRunID[token.runID] == token.id
            && connectionIDByRunID[token.runID] == token.connectionID
            && connectionIDToRunID[token.connectionID] == token.runID
    }

    @MainActor
    func rollbackPendingPolicyRunIDMapping(
        _ token: PendingPolicyRunIDMappingToken,
        clientName: String?,
        windowID: Int?,
        signalRoutingFailure: Bool
    ) -> PendingPolicyRunIDMappingRollbackResult {
        guard isCurrentPendingPolicyRunIDMapping(token) else {
            let supersededBySameConnection = connectionIDByRunID[token.runID] == token.connectionID
            if connectionIDToRunID[token.connectionID] != token.runID {
                removeTabContext(
                    forConnectionID: token.connectionID,
                    clientName: clientName,
                    windowID: windowID,
                    runID: token.runID,
                    removeQueuedPendingContext: false
                )
            }
            if signalRoutingFailure, liveConnectionID(forRunID: token.runID) == nil {
                MCPRoutingWaiter.signalFailed(token.runID)
            }
            return supersededBySameConnection
                ? .supersededBySameConnection
                : .supersededByOtherConnection
        }

        pendingPolicyRunIDMappingTokenIDByRunID.removeValue(forKey: token.runID)
        removeTabContext(
            forConnectionID: token.connectionID,
            clientName: clientName,
            windowID: windowID,
            runID: token.runID,
            removeQueuedPendingContext: false
        )
        if connectionIDByRunID[token.runID] == token.connectionID {
            connectionIDByRunID.removeValue(forKey: token.runID)
        }
        if connectionIDToRunID[token.connectionID] == token.runID {
            connectionIDToRunID.removeValue(forKey: token.connectionID)
        }

        if let displacedConnectionID = token.displacedConnectionID,
           token.displacedPendingPolicyTokenID == nil,
           token.displacedConnectionRunID == token.runID,
           connectionIDByRunID[token.runID] == nil,
           connectionIDToRunID[displacedConnectionID] == nil
        {
            connectionIDByRunID[token.runID] = displacedConnectionID
            connectionIDToRunID[displacedConnectionID] = token.runID
        } else if token.displacedConnectionID == nil {
            connectionIDByRunID.removeValue(forKey: token.runID)
        }

        if let previousRunID = token.previousRunID,
           token.previousPendingPolicyTokenID == nil
        {
            let currentPrimaryConnectionID = connectionIDByRunID[previousRunID]
            let previousPrimaryIsUnchanged = currentPrimaryConnectionID == token.previousRunPrimaryConnectionID
            let canRestorePreviousPrimary = token.previousRunPrimaryConnectionID == token.connectionID
                && currentPrimaryConnectionID == nil
            if previousPrimaryIsUnchanged || canRestorePreviousPrimary {
                connectionIDToRunID[token.connectionID] = previousRunID
                if canRestorePreviousPrimary {
                    connectionIDByRunID[previousRunID] = token.connectionID
                }
            }
        } else {
            connectionIDToRunID.removeValue(forKey: token.connectionID)
        }

        let restoredPreviousRun = token.previousRunID.map {
            connectionIDToRunID[token.connectionID] == $0
        } ?? true
        if restoredPreviousRun, let previousWindowID = token.previousWindowID {
            windowIDByConnection[token.connectionID] = previousWindowID
        } else {
            windowIDByConnection.removeValue(forKey: token.connectionID)
        }

        if signalRoutingFailure, liveConnectionID(forRunID: token.runID) == nil {
            MCPRoutingWaiter.signalFailed(token.runID)
        }
        return .restored
    }

    @MainActor
    func updateCurrentTabContext(
        toolName: String,
        mutation: (inout TabScopedContext) -> Void
    ) async throws {
        var (connectionID, context) = try await contextForCurrentRequest(toolName: toolName)
        let previousPrompt = context.promptText
        mutation(&context)
        if context.promptText != previousPrompt {
            let (cleanPrompt, taskName) = stripTaskNameTag(from: context.promptText)
            context.promptText = cleanPrompt
            if let taskName,
               !taskName.isEmpty
            {
                let sanitized = sanitizeTaskName(taskName)
                if !sanitized.isEmpty {
                    renameComposeTabIfNeeded(tabID: context.tabID, newName: sanitized)
                }
            }
        }
        tabContextByConnectionID[connectionID] = context
        await pushVirtualContextToUI(context)
    }

    private func stripTaskNameTag(from prompt: String) -> (cleanPrompt: String, taskName: String?) {
        guard !prompt.isEmpty else {
            return (prompt, nil)
        }

        // Pattern supports:
        // 1. <taskname="value"/> - double-quoted, self-closing
        // 2. <taskname='value'/> - single-quoted, self-closing
        // 3. <taskname=value/>   - unquoted, self-closing
        // 4. <taskname="value">  - double-quoted, not self-closing
        // 5. <taskname='value'>  - single-quoted, not self-closing
        // 6. <taskname=value>    - unquoted, not self-closing
        let pattern = #"^[ \t]*<taskname=(?:"([^"]*)"|'([^']*)'|([^/>]+?))\s*/?>[ \t]*(?:\r?\n)?"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .anchorsMatchLines]
        ) else {
            return (prompt, nil)
        }

        let fullRange = NSRange(prompt.startIndex ..< prompt.endIndex, in: prompt)
        let matches = regex.matches(in: prompt, options: [], range: fullRange)
        guard !matches.isEmpty else {
            return (prompt, nil)
        }

        var extractedName: String?
        if let first = matches.first {
            // Check capture groups 1-3 (double-quoted, single-quoted, unquoted)
            for groupIndex in 1 ... 3 {
                let range = first.range(at: groupIndex)
                if range.location != NSNotFound,
                   let nameRange = Range(range, in: prompt)
                {
                    let captured = String(prompt[nameRange])
                    if !captured.isEmpty {
                        extractedName = captured.trimmingCharacters(in: .whitespacesAndNewlines)
                        break
                    }
                }
            }
        }

        // Return original prompt unchanged, just extract the task name
        return (prompt, extractedName)
    }

    private func sanitizeTaskName(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let collapsed = trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let filtered = collapsed.filter { $0 != "\n" && $0 != "\r" && $0 != "\t" && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
        guard !filtered.isEmpty else { return "" }

        let maxLength = 80
        if filtered.count > maxLength {
            let end = filtered.index(filtered.startIndex, offsetBy: maxLength)
            return String(filtered[..<end])
        }
        return filtered
    }

    @MainActor
    private func renameComposeTabIfNeeded(tabID: UUID, newName: String) {
        if let existing = promptVM.currentComposeTabs.first(where: { $0.id == tabID }),
           existing.name == newName
        {
            return
        }
        promptVM.renameComposeTab(tabID, to: newName)
    }

    @MainActor
    @discardableResult
    func commitAndClearTabContext(
        connectionID: UUID,
        expectedRunID: UUID? = nil,
        isStillCurrent: @MainActor () -> Bool = { true },
        progressReporter: ContextBuilderMCPProgressReporter? = nil,
        deferRunMappingCleanupUntilCaller: Bool = false
    ) async -> Bool {
        // Capture the authoritative snapshot on the main actor before the first suspension.
        // Connection cleanup may remove the dictionary entry while draining auto-selection,
        // but it cannot invalidate this locally owned snapshot.
        guard let commitOwnedContext = tabContextByConnectionID[connectionID] else { return false }

        // Decide whether we will commit stored UI state for this context.
        // Mismatch or logical cancellation => clear binding only.
        var shouldCommit = isStillCurrent()
        if let expected = expectedRunID, commitOwnedContext.runID != expected {
            tabContextLog("commitAndClearTabContext run mismatch connectionID=\(connectionID) expectedRunID=\(expected.uuidString) actualRunID=\(commitOwnedContext.runID?.uuidString ?? "nil") tab=\(commitOwnedContext.tabID) — clearing binding without commit")
            shouldCommit = false
        }

        if shouldCommit {
            let key = readFileAutoSelectionContextKey(connectionID: connectionID, context: commitOwnedContext)
            await progressReporter?(.readFileAutoSelectionFinish)
            let finishResult = await readFileAutoSelectionCoordinator.finish(context: key)
            if finishResult == .cancelled {
                shouldCommit = false
            }
            if !isStillCurrent() || Task.isCancelled {
                shouldCommit = false
            }
        } else {
            invalidateReadFileAutoSelection(connectionID: connectionID, context: commitOwnedContext)
        }

        // Clear the mutable tab snapshot regardless of mismatch so future calls cannot
        // mutate state being committed. Successful Context Builder completion may retain
        // the connection/run routing maps until its independently-owned transport teardown joins.
        endMirroringForConnection(connectionID)
        readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: connectionID)
        tabContextByConnectionID.removeValue(forKey: connectionID)
        if !deferRunMappingCleanupUntilCaller {
            windowIDByConnection.removeValue(forKey: connectionID)
            if let runID = commitOwnedContext.runID {
                connectionIDByRunID.removeValue(forKey: runID)
            }
            connectionIDToRunID.removeValue(forKey: connectionID)
        }

        guard shouldCommit, isStillCurrent(), !Task.isCancelled else { return false }

        tabContextLog("commitAndClearTabContext committing tab=\(commitOwnedContext.tabID) connectionID=\(connectionID) runID=\(commitOwnedContext.runID?.uuidString ?? "nil")")

        // IMPORTANT: Await the commit to ensure tab state is written before caller reads it.
        // The immutable payload remains owned by this run even if transport cleanup proceeds.
        await progressReporter?(.tabContextCommit)
        let didCommit = await commitTabContext(commitOwnedContext, isStillCurrent: isStillCurrent)
        guard didCommit, isStillCurrent(), !Task.isCancelled else { return false }

        var discoveredTabName: String?
        if let manager = workspaceManager,
           let tab = manager.composeTab(with: commitOwnedContext.tabID)
        {
            discoveredTabName = tab.name
        } else if let tab = promptVM.currentComposeTabs.first(where: { $0.id == commitOwnedContext.tabID }) {
            discoveredTabName = tab.name
        }
        if let tabName = discoveredTabName, !tabName.isEmpty {
            NotificationService.shared.notifyContextBuilderComplete(
                tabName: tabName,
                fallbackToDockBounce: true
            )
        }

        // End-of-run flush: persist this run's final state to disk (coalesced by DiskWriter)
        guard let manager = workspaceManager else { return false }
        await progressReporter?(.statePersistence)
        await manager.pollAndSaveStateAsync(source: .mcpTabContextEndOfRun)
        return isStillCurrent() && !Task.isCancelled
    }

    #if DEBUG
        @MainActor
        func readFileAutoSelectionHandoverPredecessorConnectionIDsForTesting(
            connectionID: UUID
        ) -> [UUID] {
            guard let context = tabContextByConnectionID[connectionID],
                  let runID = context.runID,
                  connectionIDByRunID[runID] == connectionID,
                  connectionIDToRunID[connectionID] == runID,
                  let lineage = readFileAutoSelectionHandoverLineageByConnectionID[connectionID],
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
    func finishReadFileAutoSelectionForConnectionTeardown(connectionID: UUID) async {
        guard let context = tabContextByConnectionID[connectionID] else { return }
        let key = readFileAutoSelectionContextKey(connectionID: connectionID, context: context)
        _ = await readFileAutoSelectionCoordinator.finish(context: key)
    }

    @MainActor
    func removeTabContext(
        forConnectionID connectionID: UUID?,
        clientName: String?,
        windowID: Int?,
        runID: UUID? = nil,
        removeQueuedPendingContext: Bool = true
    ) {
        if let connectionID {
            readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: connectionID)
            if let context = tabContextByConnectionID[connectionID],
               runID == nil || context.runID == runID
            {
                invalidateReadFileAutoSelection(connectionID: connectionID, context: context)
                endMirroringForConnection(connectionID)
                tabContextByConnectionID.removeValue(forKey: connectionID)
                windowIDByConnection.removeValue(forKey: connectionID)

                if let boundRunID = context.runID,
                   connectionIDByRunID[boundRunID] == connectionID
                {
                    connectionIDByRunID.removeValue(forKey: boundRunID)
                    pendingPolicyRunIDMappingTokenIDByRunID.removeValue(forKey: boundRunID)
                }
                if connectionIDToRunID[connectionID] == context.runID {
                    connectionIDToRunID.removeValue(forKey: connectionID)
                }

                tabContextLog("removeTabContext removed bound context connectionID=\(connectionID) runID=\(runID?.uuidString ?? "nil") tab=\(context.tabID)")
            } else if let runID {
                // A successful Context Builder commit may already have consumed the mutable
                // tab snapshot while deliberately retaining routing maps for a live child
                // connection. The caller owns removing those maps after termination joins.
                var removedDeferredMapping = false
                if connectionIDByRunID[runID] == connectionID {
                    connectionIDByRunID.removeValue(forKey: runID)
                    pendingPolicyRunIDMappingTokenIDByRunID.removeValue(forKey: runID)
                    removedDeferredMapping = true
                }
                if connectionIDToRunID[connectionID] == runID {
                    connectionIDToRunID.removeValue(forKey: connectionID)
                    removedDeferredMapping = true
                }
                if removedDeferredMapping {
                    windowIDByConnection.removeValue(forKey: connectionID)
                    tabContextLog("removeTabContext removed deferred mapping connectionID=\(connectionID) runID=\(runID.uuidString)")
                }
            }
        }

        if let runID, connectionID == nil {
            // This is an explicit cleanup by runID (called when discovery ends)
            for (boundConnectionID, context) in tabContextByConnectionID where context.runID == runID {
                readFileAutoSelectionHandoverLineageByConnectionID.removeValue(forKey: boundConnectionID)
            }
            if let mappedConnection = connectionIDByRunID[runID] {
                connectionIDToRunID.removeValue(forKey: mappedConnection)
                windowIDByConnection.removeValue(forKey: mappedConnection)
            }
            connectionIDByRunID.removeValue(forKey: runID)
            pendingPolicyRunIDMappingTokenIDByRunID.removeValue(forKey: runID)
        }

        // Only explicit run cleanup owns queued intent. Mapping rollback must not
        // consume a newer pending context for the same client/run generation.
        if removeQueuedPendingContext, let clientName, let runID {
            removePendingContext(clientName: clientName, windowID: windowID, runID: runID)
        }
    }

    @MainActor
    private func removePendingContext(clientName: String, windowID: Int?, runID: UUID) {
        if let windowID {
            let result = pendingRunScopedTabContexts.pop(clientName: clientName, windowID: windowID, runID: runID)
            if result.context != nil {
                tabContextLog("removePendingContext removed pending context clientName=\(clientName) window=\(windowID) runID=\(runID.uuidString) remaining=\(result.remaining)")
            }
            return
        }

        let result = pendingRunScopedTabContexts.popByRunID(clientName: clientName, runID: runID)
        if let _ = result.context, let windowID = result.windowID {
            tabContextLog("removePendingContext removed pending context clientName=\(clientName) window=\(windowID) runID=\(runID.uuidString) remaining=\(result.remaining)")
        } else {
            tabContextLog("removePendingContext no pending context found for clientName=\(clientName) runID=\(runID.uuidString)")
        }
    }

    @MainActor
    private func commitTabContext(
        _ context: TabScopedContext,
        isStillCurrent: @MainActor () -> Bool = { true }
    ) async -> Bool {
        guard isStillCurrent(), !Task.isCancelled else { return false }
        guard let manager = workspaceManager else {
            tabContextLog("[warning] commitTabContext missing workspace manager for windowID \(context.windowID); skipping commit.")
            return false
        }
        tabContextLog("commitTabContext using workspaceManager \(ObjectIdentifier(manager)) for context.windowID=\(context.windowID) self.windowID=\(windowID)")
        let targetWorkspaceID = context.workspaceID ?? manager.activeWorkspace?.id
        guard let workspaceID = targetWorkspaceID,
              let workspaceIndex = manager.workspaces.firstIndex(where: { $0.id == workspaceID }),
              let tabIndex = manager.workspaces[workspaceIndex].composeTabs.firstIndex(where: { $0.id == context.tabID })
        else {
            tabContextLog("[warning] commitTabContext skipping commit for tab \(context.tabID) – workspace unavailable.")
            return false
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
        guard isStillCurrent(), !Task.isCancelled else { return false }
        _ = manager.updateComposeTabStoredOnly(updatedTab, inWorkspaceID: workspaceID)
        tabContextLog("commitTabContext stored selection/prompt tab=\(context.tabID) window=\(context.windowID) runID=\(context.runID?.uuidString ?? "nil") workspaceID=\(workspaceID)")

        // 2) Apply to live UI ONLY if this tab is the active tab and the run still owns commit.
        guard isActive else {
            tabContextLog("commitTabContext skipping live UI apply (tab not active) tab=\(updatedTab.id)")
            return true
        }
        guard !canonicalSelectionAdvanced else {
            tabContextLog("commitTabContext skipping stale live UI apply tab=\(updatedTab.id)")
            return true
        }
        guard isStillCurrent(), !Task.isCancelled else { return false }

        let applyTab = updatedTab

        // Fence cross‑tab snapshot emissions while we apply THIS tab's state
        manager.beginApplyingTabContext(forTabID: context.tabID)
        tabContextLog("commitTabContext applying to UI: tab=\(applyTab.id) selectionCount=\(applyTab.selection.selectedPaths.count) promptChars=\(applyTab.promptText.count)")
        await manager.applyComposeTabState(applyTab)
        manager.endApplyingTabContext(forTabID: context.tabID)
        tabContextLog("commitTabContext UI applied: tab=\(applyTab.id)")
        return isStillCurrent() && !Task.isCancelled
    }
}
