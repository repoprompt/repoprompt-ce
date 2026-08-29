import Combine
import Foundation
import OSLog

struct WorkspaceSelectionIdentity: Hashable {
    let workspaceID: UUID
    let tabID: UUID
}

struct MCPSelectionPropagationRegistration: Equatable {
    let sourceRevision: UInt64
    let peerHostIDs: Set<UUID>
}

struct MCPSelectionPeerPropagation: Equatable {
    let identity: WorkspaceSelectionIdentity
    let selection: StoredSelection
    let sourceRevision: UInt64
    let peerHostIDs: Set<UUID>
    let mirrorToUIIfActive: Bool
}

/// Identifies the exact peer manager generation allowed to receive one propagation.
/// The host revalidates registration and closing state at each commit/apply boundary.
struct MCPSelectionPeerMutationFence: Equatable {
    let hostID: UUID
}

private struct WorkspaceSelectionMirrorTarget: Equatable {
    let identity: WorkspaceSelectionIdentity
    let selection: StoredSelection
    let contextRevision: UInt64

    var workspaceID: UUID {
        identity.workspaceID
    }

    var tabID: UUID {
        identity.tabID
    }
}

@MainActor
protocol WorkspaceSelectionHost: AnyObject {
    var activeWorkspace: WorkspaceModel? { get }
    var selectionMirrorContextRevision: UInt64 { get }
    var liveUISelectionRevision: UInt64 { get }
    func composeTab(with id: UUID) -> ComposeTabState?
    func composeTab(for identity: WorkspaceSelectionIdentity) -> ComposeTabState?
    func publishActiveComposeTabSnapshot(commitToMemory: Bool, touchModified: Bool)
    @discardableResult
    func updateComposeTabStoredOnly(_ tab: ComposeTabState, inWorkspaceID workspaceID: UUID) -> Bool
    func updateComposeTabSelectionPresentation(_ selection: StoredSelection, for identity: WorkspaceSelectionIdentity)
    func committedSelectionRevision(for identity: WorkspaceSelectionIdentity) -> UInt64
    func registerMCPSelectionSourceMutation(
        for identity: WorkspaceSelectionIdentity
    ) -> MCPSelectionPropagationRegistration
    func acceptMCPPeerSelectionRevision(_ revision: UInt64, for identity: WorkspaceSelectionIdentity) -> Bool
    func canCommitMCPSelectionPeerMutation(_ fence: MCPSelectionPeerMutationFence) -> Bool
    func propagateMCPSelectionToPeerHosts(_ propagation: MCPSelectionPeerPropagation) async
    func applySelectionMirrorAttempt(
        _ selection: StoredSelection,
        forTabID tabID: UUID,
        workspaceID: UUID
    ) async
}

extension WorkspaceSelectionHost {
    var liveUISelectionRevision: UInt64 {
        0
    }

    func updateComposeTabSelectionPresentation(_: StoredSelection, for _: WorkspaceSelectionIdentity) {}

    func committedSelectionRevision(for _: WorkspaceSelectionIdentity) -> UInt64 {
        0
    }

    func registerMCPSelectionSourceMutation(
        for _: WorkspaceSelectionIdentity
    ) -> MCPSelectionPropagationRegistration {
        MCPSelectionPropagationRegistration(sourceRevision: 0, peerHostIDs: [])
    }

    func acceptMCPPeerSelectionRevision(_: UInt64, for _: WorkspaceSelectionIdentity) -> Bool {
        true
    }

    func canCommitMCPSelectionPeerMutation(_: MCPSelectionPeerMutationFence) -> Bool {
        false
    }

    func propagateMCPSelectionToPeerHosts(_: MCPSelectionPeerPropagation) async {}
}

private extension WorkspaceSelectionHost {
    func activeSelectionMirrorTarget() -> WorkspaceSelectionMirrorTarget? {
        guard let workspace = activeWorkspace,
              let tabID = workspace.activeComposeTabID ?? workspace.composeTabs.first?.id,
              let tab = workspace.composeTabs.first(where: { $0.id == tabID })
        else { return nil }
        return WorkspaceSelectionMirrorTarget(
            identity: WorkspaceSelectionIdentity(workspaceID: workspace.id, tabID: tabID),
            selection: tab.selection,
            contextRevision: selectionMirrorContextRevision
        )
    }
}

extension WorkspaceManagerViewModel: WorkspaceSelectionHost {
    func committedSelectionRevision(for identity: WorkspaceSelectionIdentity) -> UInt64 {
        selectionRevisionForMCP(workspaceID: identity.workspaceID, tabID: identity.tabID)
    }
}

/// Window-scoped coordinator that makes compose-tab `StoredSelection` the runtime
/// selection source while the WorkspaceFiles UI adapter still owns checkbox state.
@MainActor
final class WorkspaceSelectionCoordinator {
    private enum SelectionPersistenceResult {
        case committed(StoredSelection)
        case conflict(current: StoredSelection)
        case targetUnavailable
    }

    private enum SelectionMutationKind: String {
        case remove
        case promote
        case demote
        case slices
    }

    private static let logger = Logger(
        subsystem: "com.repoprompt.workspace",
        category: "SelectionPersistence"
    )

    struct Snapshot: Equatable {
        let tabID: UUID?
        let selection: StoredSelection
        let isVirtual: Bool
    }

    struct Change: Equatable {
        let tabID: UUID?
        let selection: StoredSelection
        let source: Source
    }

    struct TransactionResult: Equatable {
        let identity: WorkspaceSelectionIdentity
        let before: StoredSelection
        let after: StoredSelection
        let revision: UInt64
    }

    enum Source: String, Equatable {
        case uiFlush
        case runtimeMutation
        case virtual
        case mcpTabContext
        case mcpPeerContext
        case mirror

        var isMCPSelectionSource: Bool {
            self == .mcpTabContext || self == .mcpPeerContext
        }
    }

    private weak var workspaceManager: (any WorkspaceSelectionHost)?
    let store: WorkspaceFileContextStore
    let mutationService: WorkspaceSelectionMutationService
    private let changeSubject = PassthroughSubject<Change, Never>()
    private var applyingSelectionMirrorDepth = 0
    enum SelectionMirrorOutcome: Equatable {
        case converged
        case deferred
        case invalidated
        case cancelled
    }

    private struct MCPSelectionMirrorDemand {
        let requestID: UInt64
        /// `nil` denotes a coalesced repair that resolves the latest active target when it runs.
        let target: WorkspaceSelectionMirrorTarget?
        let selectionRevision: UInt64?
        let peerMutationFence: MCPSelectionPeerMutationFence?
    }

    private struct MCPSelectionMirrorWorker {
        let demand: MCPSelectionMirrorDemand
        let task: Task<Void, Never>
    }

    private struct DeferredUISelectionFence {
        let selection: StoredSelection
        let liveUISelectionRevision: UInt64
    }

    private var nextSelectionRevision: UInt64 = 0
    private var selectionRevisionByIdentity: [WorkspaceSelectionIdentity: UInt64] = [:]
    private var deferredUISelectionFenceByIdentity: [WorkspaceSelectionIdentity: DeferredUISelectionFence] = [:]
    private var nextSelectionMirrorTaskID: UInt64 = 0
    private var mcpSelectionMirrorWorker: MCPSelectionMirrorWorker?
    private var pendingMCPSelectionMirrorDemand: MCPSelectionMirrorDemand?
    private var mcpSelectionMirrorWaiters: [UInt64: CheckedContinuation<SelectionMirrorOutcome, Never>] = [:]
    private var mcpSelectionMirrorDeadlineTasks: [UInt64: Task<Void, Never>] = [:]
    private let mcpSelectionMirrorTimeout: Duration

    #if DEBUG
        struct SelectionMirrorDebugSnapshot: Equatable {
            let activePhysicalWorkerCount: Int
            let pendingDemandCount: Int
            let logicalWaiterCount: Int
            let liveDeadlineCount: Int
            let workersCreated: UInt64
            let workersExited: UInt64
            let deadlinesCreated: UInt64
            let deadlinesCancelled: UInt64
            let deadlinesFired: UInt64
            let deadlinesExited: UInt64
        }

        private var selectionMirrorWorkersCreated: UInt64 = 0
        private var selectionMirrorWorkersExited: UInt64 = 0
        private var selectionMirrorDeadlinesCreated: UInt64 = 0
        private var selectionMirrorDeadlinesCancelled: UInt64 = 0
        private var selectionMirrorDeadlinesFired: UInt64 = 0
        private var selectionMirrorDeadlinesExited: UInt64 = 0

        func selectionMirrorDebugSnapshot() -> SelectionMirrorDebugSnapshot {
            SelectionMirrorDebugSnapshot(
                activePhysicalWorkerCount: mcpSelectionMirrorWorker == nil ? 0 : 1,
                pendingDemandCount: pendingMCPSelectionMirrorDemand == nil ? 0 : 1,
                logicalWaiterCount: mcpSelectionMirrorWaiters.count,
                liveDeadlineCount: mcpSelectionMirrorDeadlineTasks.count,
                workersCreated: selectionMirrorWorkersCreated,
                workersExited: selectionMirrorWorkersExited,
                deadlinesCreated: selectionMirrorDeadlinesCreated,
                deadlinesCancelled: selectionMirrorDeadlinesCancelled,
                deadlinesFired: selectionMirrorDeadlinesFired,
                deadlinesExited: selectionMirrorDeadlinesExited
            )
        }
    #endif

    static let defaultMCPSelectionMirrorTimeout: Duration = .seconds(10)

    var changes: AnyPublisher<Change, Never> {
        changeSubject.eraseToAnyPublisher()
    }

    var isApplyingSelectionMirror: Bool {
        applyingSelectionMirrorDepth > 0
    }

    init(
        workspaceManager: (any WorkspaceSelectionHost)? = nil,
        store: WorkspaceFileContextStore,
        mutationService: WorkspaceSelectionMutationService? = nil,
        mcpSelectionMirrorTimeout: Duration = WorkspaceSelectionCoordinator.defaultMCPSelectionMirrorTimeout
    ) {
        self.workspaceManager = workspaceManager
        self.store = store
        self.mutationService = mutationService ?? WorkspaceSelectionMutationService(store: store)
        self.mcpSelectionMirrorTimeout = mcpSelectionMirrorTimeout
    }

    func attachWorkspaceManager(_ workspaceManager: any WorkspaceSelectionHost) {
        self.workspaceManager = workspaceManager
    }

    func activeSelectionIdentity() -> WorkspaceSelectionIdentity? {
        guard let workspace = workspaceManager?.activeWorkspace,
              let tabID = workspace.activeComposeTabID ?? workspace.composeTabs.first?.id
        else { return nil }
        return WorkspaceSelectionIdentity(workspaceID: workspace.id, tabID: tabID)
    }

    func activeTabID() -> UUID? {
        activeSelectionIdentity()?.tabID
    }

    func activeSelectionSnapshot(flushPendingUI: Bool = true) -> Snapshot {
        if flushPendingUI {
            flushPendingUISelectionToActiveTab()
        }
        guard let workspaceManager, let identity = activeSelectionIdentity() else {
            return Snapshot(tabID: nil, selection: StoredSelection(), isVirtual: false)
        }
        return Snapshot(
            tabID: identity.tabID,
            selection: workspaceManager.composeTab(for: identity)?.selection ?? StoredSelection(),
            isVirtual: false
        )
    }

    func virtualSelectionSnapshot(tabID: UUID, selection: StoredSelection) -> Snapshot {
        Snapshot(tabID: tabID, selection: selection, isVirtual: true)
    }

    /// Keeps a canonical MCP selection authoritative while an already-enqueued UI snapshot
    /// still reflects the pre-mutation file-tree state. A genuinely newer UI mutation advances
    /// `liveUISelectionRevision` and is allowed to become canonical, including ABA transitions.
    func selectionForActiveUISnapshot(_ liveUISelection: StoredSelection, tabID: UUID) -> StoredSelection {
        guard let workspaceManager,
              let identity = activeSelectionIdentity(),
              identity.tabID == tabID,
              let fence = deferredUISelectionFenceByIdentity[identity]
        else { return liveUISelection }

        guard workspaceManager.composeTab(for: identity)?.selection == fence.selection else {
            deferredUISelectionFenceByIdentity.removeValue(forKey: identity)
            return liveUISelection
        }

        guard workspaceManager.liveUISelectionRevision == fence.liveUISelectionRevision else {
            deferredUISelectionFenceByIdentity.removeValue(forKey: identity)
            return liveUISelection
        }

        return fence.selection
    }

    /// Advances an existing fence after the app programmatically reapplies tab UI state.
    /// This keeps tab-switch/restore work from masquerading as a newer manual UI mutation.
    func refreshDeferredUISelectionFence(forTabID tabID: UUID) {
        guard let workspaceManager,
              let identity = activeSelectionIdentity(),
              identity.tabID == tabID,
              let fence = deferredUISelectionFenceByIdentity[identity],
              workspaceManager.composeTab(for: identity)?.selection == fence.selection
        else { return }
        deferredUISelectionFenceByIdentity[identity] = DeferredUISelectionFence(
            selection: fence.selection,
            liveUISelectionRevision: workspaceManager.liveUISelectionRevision
        )
    }

    /// Protects an already-persisted MCP selection from UI snapshots that were queued before
    /// the canonical write. This is the generic presentation fence used when a caller has
    /// already written canonical tab state outside `persistSelection`.
    func protectCanonicalMCPSelectionFromDeferredUISnapshots(
        _ selection: StoredSelection,
        for identity: WorkspaceSelectionIdentity
    ) {
        guard let workspaceManager,
              workspaceManager.composeTab(for: identity)?.selection == selection
        else { return }
        updateSelectionPresentation(
            selection,
            for: identity,
            workspaceManager: workspaceManager
        )
    }

    func selectionSnapshot(
        for identity: WorkspaceSelectionIdentity,
        flushPendingUIIfActive: Bool = true
    ) -> Snapshot? {
        if identity == activeSelectionIdentity() {
            return activeSelectionSnapshot(flushPendingUI: flushPendingUIIfActive)
        }
        guard let selection = workspaceManager?.composeTab(for: identity)?.selection else { return nil }
        return Snapshot(tabID: identity.tabID, selection: selection, isVirtual: true)
    }

    func selectionSnapshot(for tabID: UUID, flushPendingUIIfActive: Bool = true) -> Snapshot? {
        guard let workspaceID = workspaceManager?.activeWorkspace?.id else { return nil }
        return selectionSnapshot(
            for: WorkspaceSelectionIdentity(workspaceID: workspaceID, tabID: tabID),
            flushPendingUIIfActive: flushPendingUIIfActive
        )
    }

    func flushPendingUISelectionToActiveTab() {
        guard !isApplyingSelectionMirror, let workspaceManager else { return }
        let previousIdentity = activeSelectionIdentity()
        let previousSelection = previousIdentity.flatMap { workspaceManager.composeTab(for: $0)?.selection } ?? StoredSelection()
        workspaceManager.publishActiveComposeTabSnapshot(commitToMemory: true, touchModified: false)
        let snapshot = activeSelectionSnapshot(flushPendingUI: false)
        guard snapshot.tabID != previousIdentity?.tabID || snapshot.selection != previousSelection else { return }
        if let identity = activeSelectionIdentity() {
            recordSelectionRevision(for: identity)
        }
        changeSubject.send(Change(tabID: snapshot.tabID, selection: snapshot.selection, source: .uiFlush))
    }

    @discardableResult
    func persistActiveSelection(
        _ selection: StoredSelection,
        source: Source = .runtimeMutation,
        mirrorToUI: Bool = true
    ) async -> StoredSelection {
        guard let identity = activeSelectionIdentity() else { return selection }
        return await persistSelection(
            selection,
            for: identity,
            source: source,
            mirrorToUIIfActive: mirrorToUI
        )
    }

    @discardableResult
    func persistSelection(
        _ selection: StoredSelection,
        for identity: WorkspaceSelectionIdentity,
        source: Source = .runtimeMutation,
        mirrorToUIIfActive: Bool = true,
        expectedCurrentSelection: StoredSelection? = nil,
        peerSourceRevision: UInt64? = nil,
        peerMutationFence: MCPSelectionPeerMutationFence? = nil
    ) async -> StoredSelection {
        switch await persistSelectionResult(
            selection,
            for: identity,
            source: source,
            mirrorToUIIfActive: mirrorToUIIfActive,
            expectedCurrentSelection: expectedCurrentSelection,
            peerSourceRevision: peerSourceRevision,
            peerMutationFence: peerMutationFence
        ) {
        case let .committed(committed):
            committed
        case let .conflict(current):
            current
        case .targetUnavailable:
            selection
        }
    }

    private func persistSelectionResult(
        _ selection: StoredSelection,
        for identity: WorkspaceSelectionIdentity,
        source: Source = .runtimeMutation,
        mirrorToUIIfActive: Bool = true,
        expectedCurrentSelection: StoredSelection? = nil,
        peerSourceRevision: UInt64? = nil,
        peerMutationFence: MCPSelectionPeerMutationFence? = nil
    ) async -> SelectionPersistenceResult {
        guard let workspaceManager,
              let currentSelection = workspaceManager.composeTab(for: identity)?.selection
        else { return .targetUnavailable }
        if let expectedCurrentSelection,
           currentSelection != expectedCurrentSelection
        {
            return .conflict(current: currentSelection)
        }
        if source == .mcpPeerContext {
            guard let peerSourceRevision,
                  let peerMutationFence,
                  workspaceManager.canCommitMCPSelectionPeerMutation(peerMutationFence),
                  workspaceManager.acceptMCPPeerSelectionRevision(peerSourceRevision, for: identity)
            else { return .conflict(current: currentSelection) }
        }

        let propagationRegistration = source == .mcpTabContext
            ? workspaceManager.registerMCPSelectionSourceMutation(for: identity)
            : nil
        let isActive = identity == activeSelectionIdentity()
        let mirrorToUI = isActive && mirrorToUIIfActive

        if currentSelection == selection {
            guard canCommitPeerMutation(
                peerMutationFence,
                source: source,
                workspaceManager: workspaceManager
            ) else { return .conflict(current: currentSelection) }
            if shouldUpdateSelectionPresentation(source: source, mirrorToUI: mirrorToUI) {
                updateSelectionPresentation(
                    selection,
                    for: identity,
                    workspaceManager: workspaceManager
                )
            }
            if mirrorToUI, source.isMCPSelectionSource {
                let revision = recordSelectionRevision(for: identity)
                await enqueueMCPSelectionMirror(
                    selection,
                    for: identity,
                    revision: revision,
                    peerMutationFence: peerMutationFence
                )
            }
            if let propagationRegistration {
                await workspaceManager.propagateMCPSelectionToPeerHosts(
                    MCPSelectionPeerPropagation(
                        identity: identity,
                        selection: selection,
                        sourceRevision: propagationRegistration.sourceRevision,
                        peerHostIDs: propagationRegistration.peerHostIDs,
                        mirrorToUIIfActive: mirrorToUIIfActive
                    )
                )
            }
            return .committed(selection)
        }

        let requiredPeerMutationFence = source == .mcpPeerContext ? peerMutationFence : nil
        guard let revision = persist(
            selection,
            for: identity,
            peerMutationFence: requiredPeerMutationFence
        ) else { return .targetUnavailable }
        guard canCommitPeerMutation(
            peerMutationFence,
            source: source,
            workspaceManager: workspaceManager
        ) else { return .committed(selection) }
        if shouldUpdateSelectionPresentation(source: source, mirrorToUI: mirrorToUI) {
            updateSelectionPresentation(
                selection,
                for: identity,
                workspaceManager: workspaceManager
            )
        }
        let change = Change(tabID: identity.tabID, selection: selection, source: source)
        if mirrorToUI, source.isMCPSelectionSource {
            changeSubject.send(change)
            await enqueueMCPSelectionMirror(
                selection,
                for: identity,
                revision: revision,
                peerMutationFence: peerMutationFence
            )
        } else if mirrorToUI {
            await applySelectionMirror {
                changeSubject.send(change)
            }
        } else {
            changeSubject.send(change)
        }
        if let propagationRegistration {
            await workspaceManager.propagateMCPSelectionToPeerHosts(
                MCPSelectionPeerPropagation(
                    identity: identity,
                    selection: selection,
                    sourceRevision: propagationRegistration.sourceRevision,
                    peerHostIDs: propagationRegistration.peerHostIDs,
                    mirrorToUIIfActive: mirrorToUIIfActive
                )
            )
        }
        return .committed(selection)
    }

    /// Applies a synchronous transform to the latest canonical tab selection and stores the
    /// result before any actor suspension. Mirroring and peer propagation happen only after
    /// the canonical commit, so callers never replace a concurrently advanced selection.
    @discardableResult
    func transformSelection(
        for identity: WorkspaceSelectionIdentity,
        source: Source = .runtimeMutation,
        mirrorToUIIfActive: Bool = true,
        _ transform: (StoredSelection) -> StoredSelection
    ) async -> TransactionResult? {
        guard let workspaceManager,
              let before = workspaceManager.composeTab(for: identity)?.selection
        else { return nil }

        let after = transform(before)
        let propagationRegistration = source == .mcpTabContext
            ? workspaceManager.registerMCPSelectionSourceMutation(for: identity)
            : nil
        let isActive = identity == activeSelectionIdentity()
        let mirrorToUI = isActive && mirrorToUIIfActive
        let canonicalRevision: UInt64
        let mirrorRevision: UInt64

        if after == before {
            canonicalRevision = workspaceManager.committedSelectionRevision(for: identity)
            mirrorRevision = selectionRevisionByIdentity[identity] ?? recordSelectionRevision(for: identity)
        } else {
            guard let persistedRevision = persist(after, for: identity) else { return nil }
            canonicalRevision = workspaceManager.committedSelectionRevision(for: identity)
            mirrorRevision = persistedRevision
        }

        if shouldUpdateSelectionPresentation(source: source, mirrorToUI: mirrorToUI) {
            updateSelectionPresentation(after, for: identity, workspaceManager: workspaceManager)
        }
        if after != before, !mirrorToUI || source.isMCPSelectionSource {
            changeSubject.send(Change(tabID: identity.tabID, selection: after, source: source))
        }

        if mirrorToUI, source.isMCPSelectionSource {
            await enqueueMCPSelectionMirror(
                after,
                for: identity,
                revision: mirrorRevision,
                peerMutationFence: nil
            )
        } else if mirrorToUI, after != before {
            await applySelectionMirror {
                changeSubject.send(Change(tabID: identity.tabID, selection: after, source: source))
            }
        }

        if let propagationRegistration {
            await workspaceManager.propagateMCPSelectionToPeerHosts(
                MCPSelectionPeerPropagation(
                    identity: identity,
                    selection: after,
                    sourceRevision: propagationRegistration.sourceRevision,
                    peerHostIDs: propagationRegistration.peerHostIDs,
                    mirrorToUIIfActive: mirrorToUIIfActive
                )
            )
        }

        return TransactionResult(
            identity: identity,
            before: before,
            after: after,
            revision: canonicalRevision
        )
    }

    /// Applies an exclusive target state to exact store-derived paths for one captured selection identity.
    @discardableResult
    func setPreResolvedFilePathsInSelection(
        _ absolutePaths: [String],
        targetState: WorkspacePreResolvedSelectionTargetState,
        for identity: WorkspaceSelectionIdentity,
        lookupContext: WorkspaceLookupContext
    ) async -> TransactionResult? {
        await transformSelection(for: identity, source: .runtimeMutation) { latestSelection in
            let physicalSelection = lookupContext.physicalizeSelection(latestSelection)
            let updatedPhysicalSelection = self.mutationService.setPreResolvedFilePaths(
                base: physicalSelection,
                absolutePaths: absolutePaths,
                targetState: targetState
            )
            return lookupContext.logicalizeSelection(updatedPhysicalSelection)
        }
    }

    @discardableResult
    func persistVirtualSelection(
        _ selection: StoredSelection,
        for identity: WorkspaceSelectionIdentity,
        source: Source = .virtual
    ) async -> StoredSelection {
        await persistSelection(
            selection,
            for: identity,
            source: source,
            mirrorToUIIfActive: false
        )
    }

    @discardableResult
    func replaceActiveSelection(_ selection: StoredSelection) async -> StoredSelection {
        await persistActiveSelection(selection, source: .runtimeMutation)
    }

    @discardableResult
    func addPathsToActiveSelection(
        paths: [String],
        mode: String = "full",
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> WorkspaceAddSelectionResult {
        let current = activeSelectionSnapshot(flushPendingUI: true).selection
        let result = await mutationService.addPaths(
            existing: current,
            paths: paths,
            rawPaths: paths,
            mode: mode,
            rootScope: rootScope
        )
        if result.mutated {
            _ = await persistActiveSelection(result.selection, source: .runtimeMutation)
        }
        return result
    }

    @discardableResult
    func removePathsFromActiveSelection(
        paths: [String],
        mode: String = "full",
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> WorkspaceRemoveSelectionResult {
        let current = activeSelectionSnapshot(flushPendingUI: true).selection
        let result = await mutationService.removePaths(
            existing: current,
            paths: paths,
            rawPaths: paths,
            mode: mode,
            rootScope: rootScope
        )
        if result.mutated {
            _ = await persistActiveSelection(result.selection, source: .runtimeMutation)
        }
        return result
    }

    private func mutationPersistenceOutcome(
        _ result: SelectionPersistenceResult,
        sourceSelection: StoredSelection,
        identity: WorkspaceSelectionIdentity,
        kind: SelectionMutationKind
    ) -> (selection: StoredSelection, mutated: Bool) {
        switch result {
        case let .committed(selection):
            return (selection, true)
        case let .conflict(current):
            Self.logger.debug(
                """
                Selection mutation conflict kind=\(kind.rawValue, privacy: .public) \
                workspaceID=\(identity.workspaceID.uuidString, privacy: .public) \
                tabID=\(identity.tabID.uuidString, privacy: .public)
                """
            )
            return (current, false)
        case .targetUnavailable:
            Self.logger.debug(
                """
                Selection mutation target unavailable kind=\(kind.rawValue, privacy: .public) \
                workspaceID=\(identity.workspaceID.uuidString, privacy: .public) \
                tabID=\(identity.tabID.uuidString, privacy: .public)
                """
            )
            return (sourceSelection, false)
        }
    }

    @discardableResult
    func removePathsInActiveSelection(
        paths: [String],
        mode: String = "full",
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        lookupContext explicitLookupContext: WorkspaceLookupContext? = nil
    ) async -> WorkspaceRemoveSelectionResult {
        guard let identity = activeSelectionIdentity() else {
            return WorkspaceRemoveSelectionResult(selection: StoredSelection(), invalidPaths: [], resolvedMap: [:], mutated: false)
        }
        let lookupContext = explicitLookupContext ?? WorkspaceLookupContext(rootScope: rootScope, bindingProjection: nil)
        let currentSelection = activeSelectionSnapshot(flushPendingUI: true).selection
        let current = lookupContext.physicalizeSelection(currentSelection)
        let translatedPaths = lookupContext.translateInputPaths(paths)
        let result = await mutationService.removePaths(
            existing: current,
            paths: translatedPaths,
            rawPaths: paths,
            mode: mode,
            rootScope: lookupContext.rootScope
        )
        let logicalSelection = lookupContext.logicalizeSelection(result.selection)
        guard result.mutated else {
            return WorkspaceRemoveSelectionResult(
                selection: logicalSelection,
                invalidPaths: result.invalidPaths,
                resolvedMap: result.resolvedMap,
                mutated: false
            )
        }
        let persistenceResult = await persistSelectionResult(
            logicalSelection,
            for: identity,
            source: .runtimeMutation,
            expectedCurrentSelection: currentSelection
        )
        let outcome = mutationPersistenceOutcome(
            persistenceResult,
            sourceSelection: currentSelection,
            identity: identity,
            kind: .remove
        )
        return WorkspaceRemoveSelectionResult(
            selection: outcome.selection,
            invalidPaths: result.invalidPaths,
            resolvedMap: result.resolvedMap,
            mutated: outcome.mutated
        )
    }

    @discardableResult
    func promotePathsInActiveSelection(
        paths: [String],
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        lookupContext explicitLookupContext: WorkspaceLookupContext? = nil
    ) async -> (selection: StoredSelection, invalidPaths: [String], mutated: Bool) {
        guard let identity = activeSelectionIdentity() else {
            return (StoredSelection(), [], false)
        }
        let currentSelection = activeSelectionSnapshot(flushPendingUI: true).selection
        return await promotePathsInSelection(
            paths: paths,
            for: identity,
            expectedCurrentSelection: currentSelection,
            rootScope: rootScope,
            lookupContext: explicitLookupContext
        )
    }

    @discardableResult
    func promotePathsInSelection(
        paths: [String],
        for identity: WorkspaceSelectionIdentity,
        expectedCurrentSelection: StoredSelection,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        lookupContext explicitLookupContext: WorkspaceLookupContext? = nil
    ) async -> (selection: StoredSelection, invalidPaths: [String], mutated: Bool) {
        let lookupContext = explicitLookupContext ?? WorkspaceLookupContext(rootScope: rootScope, bindingProjection: nil)
        let current = lookupContext.physicalizeSelection(expectedCurrentSelection)
        let translatedPaths = lookupContext.translateInputPaths(paths)
        let result = await mutationService.promotePaths(
            existing: current,
            paths: translatedPaths,
            rawPaths: paths,
            rootScope: lookupContext.rootScope
        )
        let logicalSelection = lookupContext.logicalizeSelection(result.selection)
        guard result.mutated else {
            return (logicalSelection, result.invalidPaths, false)
        }
        let persistenceResult = await persistSelectionResult(
            logicalSelection,
            for: identity,
            source: .runtimeMutation,
            expectedCurrentSelection: expectedCurrentSelection
        )
        let outcome = mutationPersistenceOutcome(
            persistenceResult,
            sourceSelection: expectedCurrentSelection,
            identity: identity,
            kind: .promote
        )
        return (outcome.selection, result.invalidPaths, outcome.mutated)
    }

    @discardableResult
    func demotePathsInActiveSelection(
        paths: [String],
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        lookupContext explicitLookupContext: WorkspaceLookupContext? = nil
    ) async -> WorkspaceDemoteSelectionResult {
        guard let identity = activeSelectionIdentity() else {
            return WorkspaceDemoteSelectionResult(
                selection: StoredSelection(),
                invalidPaths: [],
                codemapUnavailable: [],
                mutated: false,
                validCandidateCount: 0
            )
        }
        let currentSelection = activeSelectionSnapshot(flushPendingUI: true).selection
        return await demotePathsInSelection(
            paths: paths,
            for: identity,
            expectedCurrentSelection: currentSelection,
            rootScope: rootScope,
            lookupContext: explicitLookupContext
        )
    }

    @discardableResult
    func demotePathsInSelection(
        paths: [String],
        for identity: WorkspaceSelectionIdentity,
        expectedCurrentSelection: StoredSelection,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        lookupContext explicitLookupContext: WorkspaceLookupContext? = nil
    ) async -> WorkspaceDemoteSelectionResult {
        let lookupContext = explicitLookupContext ?? WorkspaceLookupContext(rootScope: rootScope, bindingProjection: nil)
        let current = lookupContext.physicalizeSelection(expectedCurrentSelection)
        let translatedPaths = lookupContext.translateInputPaths(paths)
        let result = await mutationService.demotePaths(
            existing: current,
            paths: translatedPaths,
            rawPaths: paths,
            rootScope: lookupContext.rootScope
        )
        let logicalSelection = lookupContext.logicalizeSelection(result.selection)
        guard result.mutated else {
            return WorkspaceDemoteSelectionResult(
                selection: logicalSelection,
                invalidPaths: result.invalidPaths,
                codemapUnavailable: result.codemapUnavailable,
                mutated: false,
                validCandidateCount: result.validCandidateCount
            )
        }
        let persistenceResult = await persistSelectionResult(
            logicalSelection,
            for: identity,
            source: .runtimeMutation,
            expectedCurrentSelection: expectedCurrentSelection
        )
        let outcome = mutationPersistenceOutcome(
            persistenceResult,
            sourceSelection: expectedCurrentSelection,
            identity: identity,
            kind: .demote
        )
        return WorkspaceDemoteSelectionResult(
            selection: outcome.selection,
            invalidPaths: result.invalidPaths,
            codemapUnavailable: result.codemapUnavailable,
            mutated: outcome.mutated,
            validCandidateCount: result.validCandidateCount
        )
    }

    @discardableResult
    func clearSlicesInActiveSelection(
        paths: [String],
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        lookupContext explicitLookupContext: WorkspaceLookupContext? = nil
    ) async -> WorkspaceSliceSelectionMutationResult {
        guard let identity = activeSelectionIdentity() else {
            return WorkspaceSliceSelectionMutationResult(
                selection: StoredSelection(),
                invalidPaths: [],
                resolvedMap: [:],
                mutated: false
            )
        }
        let currentSelection = activeSelectionSnapshot(flushPendingUI: true).selection
        return await clearSlicesInSelection(
            paths: paths,
            for: identity,
            expectedCurrentSelection: currentSelection,
            rootScope: rootScope,
            lookupContext: explicitLookupContext
        )
    }

    @discardableResult
    func clearSlicesInSelection(
        paths: [String],
        for identity: WorkspaceSelectionIdentity,
        expectedCurrentSelection: StoredSelection,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        lookupContext explicitLookupContext: WorkspaceLookupContext? = nil
    ) async -> WorkspaceSliceSelectionMutationResult {
        let lookupContext = explicitLookupContext ?? WorkspaceLookupContext(rootScope: rootScope, bindingProjection: nil)
        let current = lookupContext.physicalizeSelection(expectedCurrentSelection)
        let entries = lookupContext.translateSliceInputs(
            paths.map { WorkspaceSelectionSliceInput(path: $0, ranges: []) }
        )
        let result = await mutationService.mutateSlices(
            base: current,
            entries: entries,
            mode: .remove,
            rootScope: lookupContext.rootScope
        )
        let logicalSelection = lookupContext.logicalizeSelection(result.selection)
        guard result.mutated else {
            return WorkspaceSliceSelectionMutationResult(
                selection: logicalSelection,
                invalidPaths: result.invalidPaths,
                resolvedMap: result.resolvedMap,
                mutated: false
            )
        }
        let persistenceResult = await persistSelectionResult(
            logicalSelection,
            for: identity,
            source: .runtimeMutation,
            expectedCurrentSelection: expectedCurrentSelection
        )
        let outcome = mutationPersistenceOutcome(
            persistenceResult,
            sourceSelection: expectedCurrentSelection,
            identity: identity,
            kind: .slices
        )
        return WorkspaceSliceSelectionMutationResult(
            selection: outcome.selection,
            invalidPaths: result.invalidPaths,
            resolvedMap: result.resolvedMap,
            mutated: outcome.mutated
        )
    }

    func withApplyingSelectionMirror<T>(_ operation: () async throws -> T) async rethrows -> T {
        applyingSelectionMirrorDepth += 1
        defer { applyingSelectionMirrorDepth = max(0, applyingSelectionMirrorDepth - 1) }
        return try await operation()
    }

    private func applySelectionMirror(_ operation: () async -> Void) async {
        await withApplyingSelectionMirror {
            await operation()
        }
    }

    @discardableResult
    func mirrorSelectionToActiveUI(
        _ selection: StoredSelection,
        forTabID tabID: UUID
    ) async -> SelectionMirrorOutcome {
        guard !Task.isCancelled else { return .cancelled }
        guard let workspaceManager,
              let target = workspaceManager.activeSelectionMirrorTarget(),
              target.tabID == tabID,
              target.selection == selection
        else { return .invalidated }
        let revision = selectionRevisionByIdentity[target.identity]
        return await enqueueSelectionMirror(target, selectionRevision: revision == 0 ? nil : revision)
    }

    private func enqueueMCPSelectionMirror(
        _ selection: StoredSelection,
        for identity: WorkspaceSelectionIdentity,
        revision: UInt64,
        peerMutationFence: MCPSelectionPeerMutationFence?
    ) async {
        guard let workspaceManager,
              let target = workspaceManager.activeSelectionMirrorTarget(),
              target.identity == identity,
              target.selection == selection
        else { return }
        await enqueueSelectionMirror(
            target,
            selectionRevision: revision,
            peerMutationFence: peerMutationFence
        )
    }

    private func enqueueSelectionMirror(
        _ target: WorkspaceSelectionMirrorTarget,
        selectionRevision: UInt64?,
        peerMutationFence: MCPSelectionPeerMutationFence? = nil
    ) async -> SelectionMirrorOutcome {
        let requestID = allocateSelectionMirrorTaskID()
        let demand = MCPSelectionMirrorDemand(
            requestID: requestID,
            target: target,
            selectionRevision: selectionRevision,
            peerMutationFence: peerMutationFence
        )
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                mcpSelectionMirrorWaiters[requestID] = continuation
                let timeout = mcpSelectionMirrorTimeout
                #if DEBUG
                    selectionMirrorDeadlinesCreated &+= 1
                #endif
                mcpSelectionMirrorDeadlineTasks[requestID] = Task { @MainActor [weak self] in
                    defer { self?.selectionMirrorDeadlineExited() }
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    self?.selectionMirrorDeadlineFired(requestID)
                }
                enqueueSelectionMirrorDemand(demand)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelSelectionMirrorRequest(requestID)
            }
        }
    }

    private func enqueueSelectionMirrorDemand(_ demand: MCPSelectionMirrorDemand) {
        if let worker = mcpSelectionMirrorWorker {
            if let pending = pendingMCPSelectionMirrorDemand {
                finishSelectionMirrorRequest(pending.requestID, outcome: .deferred)
            }
            pendingMCPSelectionMirrorDemand = demand
            finishSelectionMirrorRequest(worker.demand.requestID, outcome: .deferred)
            worker.task.cancel()
            return
        }
        startSelectionMirrorWorker(for: demand)
    }

    private func startSelectionMirrorWorker(for demand: MCPSelectionMirrorDemand) {
        precondition(mcpSelectionMirrorWorker == nil)
        #if DEBUG
            selectionMirrorWorkersCreated &+= 1
        #endif
        let task = Task { @MainActor [weak self, weak workspaceManager] in
            guard let self, let workspaceManager else { return }
            var outcome: SelectionMirrorOutcome = .invalidated
            var attemptedTarget: WorkspaceSelectionMirrorTarget?
            if mcpSelectionMirrorWorker?.demand.requestID == demand.requestID,
               canApplyPeerMirror(demand.peerMutationFence, workspaceManager: workspaceManager),
               let target = demand.target ?? workspaceManager.activeSelectionMirrorTarget()
            {
                let revisionIsCurrent = demand.selectionRevision.map {
                    selectionRevisionByIdentity[target.identity] == $0
                } ?? true
                if revisionIsCurrent, workspaceManager.activeSelectionMirrorTarget() == target {
                    attemptedTarget = target
                    await applySelectionMirror {
                        await workspaceManager.applySelectionMirrorAttempt(
                            target.selection,
                            forTabID: target.tabID,
                            workspaceID: target.workspaceID
                        )
                    }
                    if mcpSelectionMirrorWorker?.demand.requestID == demand.requestID,
                       canApplyPeerMirror(demand.peerMutationFence, workspaceManager: workspaceManager),
                       workspaceManager.activeSelectionMirrorTarget() == target,
                       !Task.isCancelled
                    {
                        refreshDeferredUISelectionFence(forTabID: target.tabID)
                        outcome = .converged
                    } else {
                        outcome = .deferred
                    }
                }
            }
            selectionMirrorWorkerExited(demand.requestID, attemptedTarget: attemptedTarget, outcome: outcome)
        }
        mcpSelectionMirrorWorker = MCPSelectionMirrorWorker(demand: demand, task: task)
    }

    private func selectionMirrorWorkerExited(
        _ requestID: UInt64,
        attemptedTarget: WorkspaceSelectionMirrorTarget?,
        outcome: SelectionMirrorOutcome
    ) {
        guard let worker = mcpSelectionMirrorWorker, worker.demand.requestID == requestID else { return }
        #if DEBUG
            selectionMirrorWorkersExited &+= 1
        #endif
        mcpSelectionMirrorWorker = nil
        finishSelectionMirrorRequest(worker.demand.requestID, outcome: outcome)

        guard let workspaceManager else {
            if let pending = pendingMCPSelectionMirrorDemand {
                pendingMCPSelectionMirrorDemand = nil
                finishSelectionMirrorRequest(pending.requestID, outcome: .invalidated)
            }
            return
        }
        let currentTarget = workspaceManager.activeSelectionMirrorTarget()
        if pendingMCPSelectionMirrorDemand == nil,
           currentTarget != attemptedTarget,
           currentTarget != nil,
           canApplyPeerMirror(worker.demand.peerMutationFence, workspaceManager: workspaceManager)
        {
            pendingMCPSelectionMirrorDemand = MCPSelectionMirrorDemand(
                requestID: allocateSelectionMirrorTaskID(),
                target: nil,
                selectionRevision: nil,
                peerMutationFence: worker.demand.peerMutationFence
            )
        }
        if let pending = pendingMCPSelectionMirrorDemand {
            pendingMCPSelectionMirrorDemand = nil
            startSelectionMirrorWorker(for: pending)
        }
    }

    private func selectionMirrorDeadlineFired(_ requestID: UInt64) {
        guard mcpSelectionMirrorWaiters[requestID] != nil else { return }
        #if DEBUG
            selectionMirrorDeadlinesFired &+= 1
        #endif
        finishSelectionMirrorRequest(requestID, outcome: .deferred)
        if let worker = mcpSelectionMirrorWorker, worker.demand.requestID == requestID {
            worker.task.cancel()
            if pendingMCPSelectionMirrorDemand == nil {
                pendingMCPSelectionMirrorDemand = MCPSelectionMirrorDemand(
                    requestID: allocateSelectionMirrorTaskID(),
                    target: nil,
                    selectionRevision: nil,
                    peerMutationFence: worker.demand.peerMutationFence
                )
            }
        }
    }

    private func selectionMirrorDeadlineExited() {
        #if DEBUG
            selectionMirrorDeadlinesExited &+= 1
        #endif
    }

    private func cancelSelectionMirrorRequest(_ requestID: UInt64) {
        guard mcpSelectionMirrorWaiters[requestID] != nil else { return }
        finishSelectionMirrorRequest(requestID, outcome: .cancelled)
        if let worker = mcpSelectionMirrorWorker, worker.demand.requestID == requestID {
            worker.task.cancel()
            if pendingMCPSelectionMirrorDemand == nil {
                // Cancellation settles only the logical caller. The active task continues to own
                // the physical slot until exit, then this repair resolves latest canonical state.
                pendingMCPSelectionMirrorDemand = MCPSelectionMirrorDemand(
                    requestID: allocateSelectionMirrorTaskID(),
                    target: nil,
                    selectionRevision: nil,
                    peerMutationFence: worker.demand.peerMutationFence
                )
            }
        }
    }

    private func finishSelectionMirrorRequest(_ requestID: UInt64, outcome: SelectionMirrorOutcome) {
        if let deadline = mcpSelectionMirrorDeadlineTasks.removeValue(forKey: requestID) {
            deadline.cancel()
            #if DEBUG
                selectionMirrorDeadlinesCancelled &+= 1
            #endif
        }
        mcpSelectionMirrorWaiters.removeValue(forKey: requestID)?.resume(returning: outcome)
    }

    private func canCommitPeerMutation(
        _ fence: MCPSelectionPeerMutationFence?,
        source: Source,
        workspaceManager: any WorkspaceSelectionHost
    ) -> Bool {
        guard source == .mcpPeerContext else { return true }
        guard let fence else { return false }
        return workspaceManager.canCommitMCPSelectionPeerMutation(fence)
    }

    private func canApplyPeerMirror(
        _ fence: MCPSelectionPeerMutationFence?,
        workspaceManager: any WorkspaceSelectionHost
    ) -> Bool {
        guard let fence else { return true }
        return workspaceManager.canCommitMCPSelectionPeerMutation(fence)
    }

    private func shouldUpdateSelectionPresentation(source: Source, mirrorToUI: Bool) -> Bool {
        source.isMCPSelectionSource || (source == .runtimeMutation && mirrorToUI)
    }

    private func updateSelectionPresentation(
        _ selection: StoredSelection,
        for identity: WorkspaceSelectionIdentity,
        workspaceManager: any WorkspaceSelectionHost
    ) {
        // Fence already-enqueued UI snapshots before either the active mirror or a deferred
        // worktree presentation can run. A genuinely newer UI mutation advances the live
        // revision and is still allowed to replace canonical selection.
        deferredUISelectionFenceByIdentity[identity] = DeferredUISelectionFence(
            selection: selection,
            liveUISelectionRevision: workspaceManager.liveUISelectionRevision
        )
        workspaceManager.updateComposeTabSelectionPresentation(selection, for: identity)
    }

    private func allocateSelectionMirrorTaskID() -> UInt64 {
        nextSelectionMirrorTaskID &+= 1
        return nextSelectionMirrorTaskID
    }

    @discardableResult
    private func recordSelectionRevision(for identity: WorkspaceSelectionIdentity) -> UInt64 {
        nextSelectionRevision &+= 1
        selectionRevisionByIdentity[identity] = nextSelectionRevision
        return nextSelectionRevision
    }

    private func persist(
        _ selection: StoredSelection,
        for identity: WorkspaceSelectionIdentity,
        peerMutationFence: MCPSelectionPeerMutationFence? = nil
    ) -> UInt64? {
        guard let workspaceManager, var tab = workspaceManager.composeTab(for: identity) else { return nil }
        guard tab.selection != selection else { return nil }
        guard canApplyPeerMirror(peerMutationFence, workspaceManager: workspaceManager) else { return nil }
        tab.selection = selection
        tab.lastModified = Date()
        guard workspaceManager.updateComposeTabStoredOnly(tab, inWorkspaceID: identity.workspaceID) else { return nil }
        return recordSelectionRevision(for: identity)
    }
}
