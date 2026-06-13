import Combine
import Foundation

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

extension WorkspaceManagerViewModel: WorkspaceSelectionHost {}

/// Window-scoped coordinator that makes compose-tab `StoredSelection` the runtime
/// selection source while the WorkspaceFiles UI adapter still owns checkbox state.
@MainActor
final class WorkspaceSelectionCoordinator {
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
    private struct MCPSelectionMirrorTail {
        let id: UInt64
        /// `nil` denotes a coalesced repair that resolves the latest active target when it runs.
        let target: WorkspaceSelectionMirrorTarget?
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
    private var mcpSelectionMirrorTail: MCPSelectionMirrorTail?

    var changes: AnyPublisher<Change, Never> {
        changeSubject.eraseToAnyPublisher()
    }

    var isApplyingSelectionMirror: Bool {
        applyingSelectionMirrorDepth > 0
    }

    init(
        workspaceManager: (any WorkspaceSelectionHost)? = nil,
        store: WorkspaceFileContextStore,
        mutationService: WorkspaceSelectionMutationService? = nil
    ) {
        self.workspaceManager = workspaceManager
        self.store = store
        self.mutationService = mutationService ?? WorkspaceSelectionMutationService(store: store)
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
        peerSourceRevision: UInt64? = nil,
        peerMutationFence: MCPSelectionPeerMutationFence? = nil
    ) async -> StoredSelection {
        guard let workspaceManager,
              let currentSelection = workspaceManager.composeTab(for: identity)?.selection
        else { return selection }
        if source == .mcpPeerContext {
            guard let peerSourceRevision,
                  let peerMutationFence,
                  workspaceManager.canCommitMCPSelectionPeerMutation(peerMutationFence),
                  workspaceManager.acceptMCPPeerSelectionRevision(peerSourceRevision, for: identity)
            else { return currentSelection }
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
            ) else { return currentSelection }
            if source.isMCPSelectionSource {
                updateMCPSelectionPresentation(
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
            return selection
        }

        let requiredPeerMutationFence = source == .mcpPeerContext ? peerMutationFence : nil
        guard let revision = persist(
            selection,
            for: identity,
            peerMutationFence: requiredPeerMutationFence
        ) else { return currentSelection }
        guard canCommitPeerMutation(
            peerMutationFence,
            source: source,
            workspaceManager: workspaceManager
        ) else { return selection }
        if source.isMCPSelectionSource {
            updateMCPSelectionPresentation(
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
        return selection
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

    func mirrorSelectionToActiveUI(_ selection: StoredSelection, forTabID tabID: UUID) async {
        guard let workspaceManager,
              let target = workspaceManager.activeSelectionMirrorTarget(),
              target.tabID == tabID,
              target.selection == selection
        else { return }
        let revision = selectionRevisionByIdentity[target.identity]
        await enqueueSelectionMirror(target, selectionRevision: revision == 0 ? nil : revision)
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
    ) async {
        let predecessor = mcpSelectionMirrorTail?.task
        let taskID = allocateSelectionMirrorTaskID()
        // The internal task owns its completion after canonical persistence, even if the
        // originating request is cancelled. Each task performs at most one suppressed apply.
        let task = Task { @MainActor [weak self, weak workspaceManager] in
            await predecessor?.value
            guard let self, let workspaceManager else { return }
            guard canApplyPeerMirror(peerMutationFence, workspaceManager: workspaceManager) else {
                discardSelectionMirrorTask(taskID)
                return
            }

            let revisionIsCurrent = selectionRevision.map {
                self.selectionRevisionByIdentity[target.identity] == $0
            } ?? true
            var attemptedTarget: WorkspaceSelectionMirrorTarget?
            if revisionIsCurrent,
               workspaceManager.activeSelectionMirrorTarget() == target
            {
                attemptedTarget = target
                await applySelectionMirror {
                    await workspaceManager.applySelectionMirrorAttempt(
                        target.selection,
                        forTabID: target.tabID,
                        workspaceID: target.workspaceID
                    )
                }
            }
            finishSelectionMirrorTask(
                taskID,
                attemptedTarget: attemptedTarget,
                peerMutationFence: peerMutationFence
            )
        }
        mcpSelectionMirrorTail = MCPSelectionMirrorTail(id: taskID, target: target, task: task)
        await task.value
    }

    /// Coalesces post-suspension churn into one latest-target successor. The completed request
    /// does not await this repair, so sustained switching cannot wedge the MCP drain.
    private func scheduleSelectionMirrorRepair(
        after predecessor: Task<Void, Never>?,
        peerMutationFence: MCPSelectionPeerMutationFence?
    ) {
        let taskID = allocateSelectionMirrorTaskID()
        let task = Task { @MainActor [weak self, weak workspaceManager] in
            await predecessor?.value
            guard let self, let workspaceManager else { return }
            guard canApplyPeerMirror(peerMutationFence, workspaceManager: workspaceManager) else {
                discardSelectionMirrorTask(taskID)
                return
            }

            let target = workspaceManager.activeSelectionMirrorTarget()
            if let target {
                await applySelectionMirror {
                    await workspaceManager.applySelectionMirrorAttempt(
                        target.selection,
                        forTabID: target.tabID,
                        workspaceID: target.workspaceID
                    )
                }
            }
            finishSelectionMirrorTask(
                taskID,
                attemptedTarget: target,
                peerMutationFence: peerMutationFence
            )
        }
        mcpSelectionMirrorTail = MCPSelectionMirrorTail(id: taskID, target: nil, task: task)
    }

    private func finishSelectionMirrorTask(
        _ taskID: UInt64,
        attemptedTarget: WorkspaceSelectionMirrorTarget?,
        peerMutationFence: MCPSelectionPeerMutationFence?
    ) {
        guard let workspaceManager,
              canApplyPeerMirror(peerMutationFence, workspaceManager: workspaceManager)
        else {
            discardSelectionMirrorTask(taskID)
            return
        }
        let currentTarget = workspaceManager.activeSelectionMirrorTarget()
        if currentTarget == attemptedTarget {
            if mcpSelectionMirrorTail?.id == taskID {
                mcpSelectionMirrorTail = nil
            }
            return
        }

        if let successor = mcpSelectionMirrorTail, successor.id != taskID {
            // An exact canonical successor or an existing latest-target repair already owns it.
            guard successor.target != currentTarget, successor.target != nil else { return }
            scheduleSelectionMirrorRepair(
                after: successor.task,
                peerMutationFence: peerMutationFence
            )
        } else if currentTarget != nil {
            scheduleSelectionMirrorRepair(
                after: nil,
                peerMutationFence: peerMutationFence
            )
        } else if mcpSelectionMirrorTail?.id == taskID {
            mcpSelectionMirrorTail = nil
        }
    }

    private func discardSelectionMirrorTask(_ taskID: UInt64) {
        if mcpSelectionMirrorTail?.id == taskID {
            mcpSelectionMirrorTail = nil
        }
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

    private func updateMCPSelectionPresentation(
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
