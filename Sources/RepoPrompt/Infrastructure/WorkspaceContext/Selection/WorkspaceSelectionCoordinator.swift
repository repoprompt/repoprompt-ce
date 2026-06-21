import Combine
import Foundation
import RepoPromptCore

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
    var selectedWorkspaceSessionID: WorkspaceSessionID? { get }
    var selectionMirrorContextRevision: UInt64 { get }
    var liveUISelectionRevision: UInt64 { get }
    func composeTab(with id: UUID) -> ComposeTabState?
    func composeTab(for identity: WorkspaceSelectionIdentity) -> ComposeTabState?
    func publishActiveComposeTabSnapshot(commitToMemory: Bool, touchModified: Bool)
    func commitSelectionThroughSelectedSession(
        _ selection: StoredSelection,
        for identity: WorkspaceSelectionIdentity,
        expectedRevision: UInt64,
        source: String
    ) async -> WorkspaceSessionCommandResult?
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
    var selectedWorkspaceSessionID: WorkspaceSessionID? {
        nil
    }

    var liveUISelectionRevision: UInt64 {
        0
    }

    func updateComposeTabSelectionPresentation(_: StoredSelection, for _: WorkspaceSelectionIdentity) {}

    func commitSelectionThroughSelectedSession(
        _: StoredSelection,
        for _: WorkspaceSelectionIdentity,
        expectedRevision _: UInt64,
        source _: String
    ) async -> WorkspaceSessionCommandResult? {
        nil
    }

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

enum WorkspaceSelectionMutationDisposition: Equatable {
    case committed
    case unchanged
    case stale
    case notReady
    case rejected
    case failed
    case commandIngressUnavailable
    case identityChanged
    case activationChanged
    case retryLimitExceeded
}

struct WorkspaceSelectionMutationOutcome: Equatable {
    let disposition: WorkspaceSelectionMutationDisposition
    let previousSelection: StoredSelection
    let selection: StoredSelection
    let revision: UInt64?
    let attempts: Int

    var committed: Bool {
        disposition == .committed || disposition == .unchanged
    }
}

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

    private var nextMirrorRevision: UInt64 = 0
    private var mirrorRevisionByIdentity: [WorkspaceSelectionIdentity: UInt64] = [:]
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
        expectedCurrentSelection: StoredSelection? = nil,
        peerSourceRevision: UInt64? = nil,
        peerMutationFence: MCPSelectionPeerMutationFence? = nil
    ) async -> StoredSelection {
        let outcome = await persistSelectionOutcome(
            selection,
            for: identity,
            source: source,
            mirrorToUIIfActive: mirrorToUIIfActive,
            expectedCurrentSelection: expectedCurrentSelection,
            peerSourceRevision: peerSourceRevision,
            peerMutationFence: peerMutationFence
        )
        return outcome.selection
    }

    @discardableResult
    func persistSelectionOutcome(
        _ selection: StoredSelection,
        for identity: WorkspaceSelectionIdentity,
        source: Source = .runtimeMutation,
        mirrorToUIIfActive: Bool = true,
        expectedCurrentSelection: StoredSelection? = nil,
        peerSourceRevision: UInt64? = nil,
        peerMutationFence: MCPSelectionPeerMutationFence? = nil
    ) async -> WorkspaceSelectionMutationOutcome {
        guard let workspaceManager,
              let currentSelection = workspaceManager.composeTab(for: identity)?.selection
        else {
            return mutationOutcome(
                .identityChanged,
                previous: selection,
                selection: selection,
                attempts: 0
            )
        }
        let mutationFence = makeMutationFence(for: identity, workspaceManager: workspaceManager)
        if let expectedCurrentSelection,
           currentSelection != expectedCurrentSelection
        {
            return mutationOutcome(
                .stale,
                previous: expectedCurrentSelection,
                selection: currentSelection,
                revision: workspaceManager.committedSelectionRevision(for: identity),
                attempts: 0
            )
        }
        if source == .mcpPeerContext {
            guard let peerSourceRevision,
                  let peerMutationFence,
                  workspaceManager.canCommitMCPSelectionPeerMutation(peerMutationFence),
                  workspaceManager.acceptMCPPeerSelectionRevision(peerSourceRevision, for: identity)
            else {
                return mutationOutcome(
                    .activationChanged,
                    previous: currentSelection,
                    selection: currentSelection,
                    revision: workspaceManager.committedSelectionRevision(for: identity),
                    attempts: 0
                )
            }
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
            ) else {
                return mutationOutcome(
                    .activationChanged,
                    previous: currentSelection,
                    selection: currentSelection,
                    revision: workspaceManager.committedSelectionRevision(for: identity),
                    attempts: 0
                )
            }
            await finalizeSelectionMutation(
                previous: currentSelection,
                selection: selection,
                identity: identity,
                source: source,
                mirrorToUI: mirrorToUI,
                mirrorToUIIfActive: mirrorToUIIfActive,
                propagationRegistration: propagationRegistration,
                peerMutationFence: peerMutationFence,
                workspaceManager: workspaceManager
            )
            return mutationOutcome(
                .unchanged,
                previous: currentSelection,
                selection: selection,
                revision: workspaceManager.committedSelectionRevision(for: identity),
                attempts: 0
            )
        }

        let requiredPeerMutationFence = source == .mcpPeerContext ? peerMutationFence : nil
        let outcome = await commitCanonicalSelection(
            selection,
            for: identity,
            expectedRevision: workspaceManager.committedSelectionRevision(for: identity),
            previousSelection: currentSelection,
            attempts: 1,
            peerMutationFence: requiredPeerMutationFence,
            workspaceManager: workspaceManager
        )
        guard outcome.committed else { return outcome }
        guard mutationFenceFailure(
            mutationFence,
            for: identity,
            workspaceManager: workspaceManager
        ) == nil else { return outcome }
        guard canCommitPeerMutation(
            peerMutationFence,
            source: source,
            workspaceManager: workspaceManager
        ) else { return outcome }
        await finalizeSelectionMutation(
            previous: currentSelection,
            selection: outcome.selection,
            identity: identity,
            source: source,
            mirrorToUI: mirrorToUI,
            mirrorToUIIfActive: mirrorToUIIfActive,
            propagationRegistration: propagationRegistration,
            peerMutationFence: peerMutationFence,
            workspaceManager: workspaceManager
        )
        return outcome
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
        let outcome = await transformSelectionOutcome(
            for: identity,
            source: source,
            mirrorToUIIfActive: mirrorToUIIfActive,
            transform
        )
        guard outcome.committed, let revision = outcome.revision else { return nil }
        return TransactionResult(
            identity: identity,
            before: outcome.previousSelection,
            after: outcome.selection,
            revision: revision
        )
    }

    @discardableResult
    func transformSelectionOutcome(
        for identity: WorkspaceSelectionIdentity,
        source: Source = .runtimeMutation,
        mirrorToUIIfActive: Bool = true,
        _ transform: (StoredSelection) -> StoredSelection
    ) async -> WorkspaceSelectionMutationOutcome {
        guard let workspaceManager,
              var before = workspaceManager.composeTab(for: identity)?.selection
        else {
            return mutationOutcome(
                .identityChanged,
                previous: StoredSelection(),
                selection: StoredSelection(),
                attempts: 0
            )
        }

        let mutationFence = makeMutationFence(for: identity, workspaceManager: workspaceManager)
        let propagationRegistration = source == .mcpTabContext
            ? workspaceManager.registerMCPSelectionSourceMutation(for: identity)
            : nil
        let isActive = identity == activeSelectionIdentity()
        let mirrorToUI = isActive && mirrorToUIIfActive
        var expectedRevision = workspaceManager.committedSelectionRevision(for: identity)

        for attempt in 1 ... 3 {
            if let failure = mutationFenceFailure(
                mutationFence,
                for: identity,
                workspaceManager: workspaceManager
            ) {
                return mutationOutcome(
                    failure,
                    previous: before,
                    selection: before,
                    revision: expectedRevision,
                    attempts: attempt - 1
                )
            }

            let after = transform(before)
            if after == before {
                await finalizeSelectionMutation(
                    previous: before,
                    selection: after,
                    identity: identity,
                    source: source,
                    mirrorToUI: mirrorToUI,
                    mirrorToUIIfActive: mirrorToUIIfActive,
                    propagationRegistration: propagationRegistration,
                    peerMutationFence: nil,
                    workspaceManager: workspaceManager
                )
                return mutationOutcome(
                    .unchanged,
                    previous: before,
                    selection: after,
                    revision: expectedRevision,
                    attempts: attempt - 1
                )
            }

            let outcome = await commitCanonicalSelection(
                after,
                for: identity,
                expectedRevision: expectedRevision,
                previousSelection: before,
                attempts: attempt,
                workspaceManager: workspaceManager
            )
            switch outcome.disposition {
            case .committed, .unchanged:
                guard mutationFenceFailure(
                    mutationFence,
                    for: identity,
                    workspaceManager: workspaceManager
                ) == nil else { return outcome }
                await finalizeSelectionMutation(
                    previous: before,
                    selection: outcome.selection,
                    identity: identity,
                    source: source,
                    mirrorToUI: mirrorToUI,
                    mirrorToUIIfActive: mirrorToUIIfActive,
                    propagationRegistration: propagationRegistration,
                    peerMutationFence: nil,
                    workspaceManager: workspaceManager
                )
                return outcome
            case .stale:
                before = outcome.selection
                expectedRevision = outcome.revision ?? expectedRevision
                if attempt == 3 {
                    return mutationOutcome(
                        .retryLimitExceeded,
                        previous: before,
                        selection: before,
                        revision: expectedRevision,
                        attempts: attempt
                    )
                }
            default:
                return outcome
            }
        }

        return mutationOutcome(
            .retryLimitExceeded,
            previous: before,
            selection: before,
            revision: expectedRevision,
            attempts: 3
        )
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
        let revision = mirrorRevisionByIdentity[target.identity]
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
                self.mirrorRevisionByIdentity[target.identity] == $0
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
                refreshDeferredUISelectionFence(forTabID: target.tabID)
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
                refreshDeferredUISelectionFence(forTabID: target.tabID)
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
        nextMirrorRevision &+= 1
        mirrorRevisionByIdentity[identity] = nextMirrorRevision
        return nextMirrorRevision
    }

    private struct SelectionMutationFence {
        let hostID: ObjectIdentifier
        let sessionID: WorkspaceSessionID?
        let activeContextRevision: UInt64?
    }

    private func makeMutationFence(
        for identity: WorkspaceSelectionIdentity,
        workspaceManager: any WorkspaceSelectionHost
    ) -> SelectionMutationFence {
        SelectionMutationFence(
            hostID: ObjectIdentifier(workspaceManager),
            sessionID: workspaceManager.selectedWorkspaceSessionID,
            activeContextRevision: identity == activeSelectionIdentity()
                ? workspaceManager.selectionMirrorContextRevision
                : nil
        )
    }

    private func mutationFenceFailure(
        _ fence: SelectionMutationFence,
        for identity: WorkspaceSelectionIdentity,
        workspaceManager: any WorkspaceSelectionHost
    ) -> WorkspaceSelectionMutationDisposition? {
        guard ObjectIdentifier(workspaceManager) == fence.hostID,
              workspaceManager.selectedWorkspaceSessionID == fence.sessionID
        else { return .activationChanged }
        guard workspaceManager.composeTab(for: identity) != nil else { return .identityChanged }
        if let activeContextRevision = fence.activeContextRevision {
            guard identity == activeSelectionIdentity(),
                  workspaceManager.selectionMirrorContextRevision == activeContextRevision
            else { return .identityChanged }
        }
        return nil
    }

    private func mutationOutcome(
        _ disposition: WorkspaceSelectionMutationDisposition,
        previous: StoredSelection,
        selection: StoredSelection,
        revision: UInt64? = nil,
        attempts: Int
    ) -> WorkspaceSelectionMutationOutcome {
        WorkspaceSelectionMutationOutcome(
            disposition: disposition,
            previousSelection: previous,
            selection: selection,
            revision: revision,
            attempts: attempts
        )
    }

    private func commitCanonicalSelection(
        _ selection: StoredSelection,
        for identity: WorkspaceSelectionIdentity,
        expectedRevision: UInt64,
        previousSelection: StoredSelection,
        attempts: Int,
        peerMutationFence: MCPSelectionPeerMutationFence? = nil,
        workspaceManager: any WorkspaceSelectionHost
    ) async -> WorkspaceSelectionMutationOutcome {
        guard canApplyPeerMirror(peerMutationFence, workspaceManager: workspaceManager) else {
            return mutationOutcome(
                .activationChanged,
                previous: previousSelection,
                selection: previousSelection,
                revision: expectedRevision,
                attempts: attempts
            )
        }

        guard let result = await workspaceManager.commitSelectionThroughSelectedSession(
            selection,
            for: identity,
            expectedRevision: expectedRevision,
            source: "workspace-selection-coordinator"
        ) else {
            return mutationOutcome(
                .commandIngressUnavailable,
                previous: previousSelection,
                selection: previousSelection,
                revision: expectedRevision,
                attempts: attempts
            )
        }

        switch result {
        case let .committed(receipt):
            return mutationOutcome(
                .committed,
                previous: previousSelection,
                selection: selection,
                revision: receipt.selectionRevision ?? expectedRevision,
                attempts: attempts
            )
        case let .unchanged(receipt):
            return mutationOutcome(
                .unchanged,
                previous: previousSelection,
                selection: selection,
                revision: receipt.selectionRevision ?? expectedRevision,
                attempts: attempts
            )
        case let .stale(snapshot, _):
            guard let latest = snapshot.selection(
                workspaceID: identity.workspaceID,
                tabID: identity.tabID
            ) else {
                return mutationOutcome(
                    .identityChanged,
                    previous: previousSelection,
                    selection: previousSelection,
                    revision: expectedRevision,
                    attempts: attempts
                )
            }
            return mutationOutcome(
                .stale,
                previous: previousSelection,
                selection: latest,
                revision: snapshot.selectionRevision(
                    workspaceID: identity.workspaceID,
                    tabID: identity.tabID
                ),
                attempts: attempts
            )
        case .notReady:
            return mutationOutcome(
                .notReady,
                previous: previousSelection,
                selection: previousSelection,
                revision: expectedRevision,
                attempts: attempts
            )
        case .rejected:
            return mutationOutcome(
                .rejected,
                previous: previousSelection,
                selection: previousSelection,
                revision: expectedRevision,
                attempts: attempts
            )
        case .failed:
            return mutationOutcome(
                .failed,
                previous: previousSelection,
                selection: previousSelection,
                revision: expectedRevision,
                attempts: attempts
            )
        }
    }

    private func finalizeSelectionMutation(
        previous: StoredSelection,
        selection: StoredSelection,
        identity: WorkspaceSelectionIdentity,
        source: Source,
        mirrorToUI: Bool,
        mirrorToUIIfActive: Bool,
        propagationRegistration: MCPSelectionPropagationRegistration?,
        peerMutationFence: MCPSelectionPeerMutationFence?,
        workspaceManager: any WorkspaceSelectionHost
    ) async {
        let changed = previous != selection
        if source.isMCPSelectionSource {
            updateMCPSelectionPresentation(selection, for: identity, workspaceManager: workspaceManager)
        }

        if changed {
            let change = Change(tabID: identity.tabID, selection: selection, source: source)
            if mirrorToUI, source.isMCPSelectionSource {
                changeSubject.send(change)
                await enqueueMCPSelectionMirror(
                    selection,
                    for: identity,
                    revision: recordSelectionRevision(for: identity),
                    peerMutationFence: peerMutationFence
                )
            } else if mirrorToUI {
                await applySelectionMirror {
                    changeSubject.send(change)
                }
            } else {
                changeSubject.send(change)
            }
        } else if mirrorToUI, source.isMCPSelectionSource {
            await enqueueMCPSelectionMirror(
                selection,
                for: identity,
                revision: recordSelectionRevision(for: identity),
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
    }
}
