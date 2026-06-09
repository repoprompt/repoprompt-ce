import Combine
import Foundation
import RepoPromptCore

/// App-only UI bridge over the canonical Core selection controller.
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
        case mirror
    }

    private weak var workspaceManager: WorkspaceManagerViewModel?
    let store: WorkspaceFileContextStore
    let mutationService: WorkspaceSelectionMutationService
    let controller: WorkspaceSelectionController
    private let changeSubject = PassthroughSubject<Change, Never>()
    private var applyingSelectionMirrorDepth = 0
    private var observationToken: WorkspaceSelectionObservationToken?

    var changes: AnyPublisher<Change, Never> {
        changeSubject.eraseToAnyPublisher()
    }

    var isApplyingSelectionMirror: Bool {
        applyingSelectionMirrorDepth > 0
    }

    init(
        controller: WorkspaceSelectionController,
        store: WorkspaceFileContextStore
    ) {
        self.controller = controller
        self.store = store
        mutationService = controller.mutationService
        observationToken = controller.observe { [weak self] change in
            self?.changeSubject.send(Change(
                tabID: change.tabID,
                selection: change.selection,
                source: Source(rawValue: change.source.rawValue) ?? .runtimeMutation
            ))
        }
    }

    func attachWorkspaceManager(_ workspaceManager: WorkspaceManagerViewModel) {
        self.workspaceManager = workspaceManager
    }

    func activeTabID() -> UUID? {
        controller.activeTabID()
    }

    func activeSelectionSnapshot(flushPendingUI: Bool = true) -> Snapshot {
        if flushPendingUI {
            flushPendingUISelectionToActiveTab()
        }
        let snapshot = controller.activeSelectionSnapshot()
        return Snapshot(tabID: snapshot.tabID, selection: snapshot.selection, isVirtual: snapshot.isVirtual)
    }

    func virtualSelectionSnapshot(tabID: UUID, selection: StoredSelection) -> Snapshot {
        let snapshot = controller.virtualSelectionSnapshot(tabID: tabID, selection: selection)
        return Snapshot(tabID: snapshot.tabID, selection: snapshot.selection, isVirtual: snapshot.isVirtual)
    }

    func selectionSnapshot(for tabID: UUID, flushPendingUIIfActive: Bool = true) -> Snapshot? {
        if tabID == activeTabID() {
            return activeSelectionSnapshot(flushPendingUI: flushPendingUIIfActive)
        }
        guard let selection = workspaceManager?.composeTab(with: tabID)?.selection else { return nil }
        return Snapshot(tabID: tabID, selection: selection, isVirtual: true)
    }

    func flushPendingUISelectionToActiveTab() {
        guard !isApplyingSelectionMirror,
              let workspaceManager,
              let pending = controller.beginExternallyCommittedSelection(source: .uiFlush)
        else { return }
        workspaceManager.publishActiveComposeTabSnapshot(commitToMemory: true, touchModified: false)
        controller.finishExternallyCommittedSelection(target: pending.target, previous: pending.previous)
    }

    @discardableResult
    func persistActiveSelection(
        _ selection: StoredSelection,
        source: Source = .runtimeMutation,
        mirrorToUI: Bool = true
    ) async -> StoredSelection {
        let target = controller.activeTarget()
        let coreSource = WorkspaceSelectionController.Source(rawValue: source.rawValue) ?? .runtimeMutation
        let result = controller.persistActiveSelection(selection, source: coreSource, publishChange: false)
        guard let target,
              controller.selectionSnapshot(for: target) == result
        else { return result }

        let change = Change(tabID: target.tabID, selection: result, source: source)
        if mirrorToUI {
            await deliverMirrored(change)
        } else {
            changeSubject.send(change)
        }
        return result
    }

    @discardableResult
    func persistSelection(
        _ selection: StoredSelection,
        for tabID: UUID,
        source: Source = .runtimeMutation,
        mirrorToUIIfActive: Bool = true
    ) async -> StoredSelection {
        if tabID == activeTabID() {
            return await persistActiveSelection(selection, source: source, mirrorToUI: mirrorToUIIfActive)
        }
        return persistVirtualSelection(selection, for: tabID, source: source)
    }

    @discardableResult
    func persistVirtualSelection(
        _ selection: StoredSelection,
        for tabID: UUID,
        source: Source = .virtual
    ) -> StoredSelection {
        let target = controller.target(forTabID: tabID)
        let result = controller.persistVirtualSelection(selection, for: tabID, publishChange: false)
        if let target,
           controller.selectionSnapshot(for: target) == result
        {
            changeSubject.send(Change(tabID: target.tabID, selection: result, source: source))
        }
        return result
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
        flushPendingUISelectionToActiveTab()
        let target = controller.activeTarget()
        let result = await controller.addPathsToActiveSelection(
            paths: paths,
            mode: mode,
            rootScope: rootScope,
            publishChange: false
        )
        if result.mutated,
           let target,
           controller.selectionSnapshot(for: target) == result.selection
        {
            await deliverMirrored(Change(
                tabID: target.tabID,
                selection: result.selection,
                source: .runtimeMutation
            ))
        }
        return result
    }

    @discardableResult
    func removePathsFromActiveSelection(
        paths: [String],
        mode: String = "full",
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> WorkspaceRemoveSelectionResult {
        flushPendingUISelectionToActiveTab()
        let target = controller.activeTarget()
        let result = await controller.removePathsFromActiveSelection(
            paths: paths,
            mode: mode,
            rootScope: rootScope,
            publishChange: false
        )
        if result.mutated,
           let target,
           controller.selectionSnapshot(for: target) == result.selection
        {
            await deliverMirrored(Change(
                tabID: target.tabID,
                selection: result.selection,
                source: .runtimeMutation
            ))
        }
        return result
    }

    func withApplyingSelectionMirror<T>(_ operation: () async throws -> T) async rethrows -> T {
        applyingSelectionMirrorDepth += 1
        defer { applyingSelectionMirrorDepth = max(0, applyingSelectionMirrorDepth - 1) }
        return try await operation()
    }

    private func deliverMirrored(_ change: Change) async {
        await withApplyingSelectionMirror {
            changeSubject.send(change)
        }
    }
}
