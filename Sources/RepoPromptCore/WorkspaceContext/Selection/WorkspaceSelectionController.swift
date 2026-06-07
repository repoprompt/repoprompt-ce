import Foundation

@MainActor
package final class WorkspaceSelectionObservationToken {
    private var cancelAction: (() -> Void)?

    package init(cancelAction: @escaping () -> Void) {
        self.cancelAction = cancelAction
    }

    package func cancel() {
        cancelAction?()
        cancelAction = nil
    }

    deinit {
        MainActor.assumeIsolated { cancel() }
    }
}

/// Canonical session-backed selection owner. UI flushing and mirroring remain app adapters.
@MainActor
package final class WorkspaceSelectionController {
    package struct Target: Hashable {
        package let workspaceID: UUID
        package let tabID: UUID

        package init(workspaceID: UUID, tabID: UUID) {
            self.workspaceID = workspaceID
            self.tabID = tabID
        }
    }

    package struct Snapshot: Equatable {
        package let tabID: UUID?
        package let selection: StoredSelection
        package let isVirtual: Bool

        package init(tabID: UUID?, selection: StoredSelection, isVirtual: Bool) {
            self.tabID = tabID
            self.selection = selection
            self.isVirtual = isVirtual
        }
    }

    package struct Change: Equatable {
        package let tabID: UUID?
        package let selection: StoredSelection
        package let source: Source

        package init(tabID: UUID?, selection: StoredSelection, source: Source) {
            self.tabID = tabID
            self.selection = selection
            self.source = source
        }
    }

    package enum Source: String, Equatable {
        case uiFlush
        case runtimeMutation
        case virtual
        case mirror
    }

    package typealias Observer = @MainActor (Change) -> Void

    package let sessionController: WorkspaceSessionController
    package let mutationService: WorkspaceSelectionMutationService
    private var observers: [UUID: Observer] = [:]
    private var selectionsByTarget: [Target: StoredSelection]
    private var pendingSourceByTarget: [Target: Source] = [:]
    private var suppressedObserverTargets: Set<Target> = []
    private var sessionObservationToken: WorkspaceSessionObservationToken?

    package init(
        sessionController: WorkspaceSessionController,
        mutationService: WorkspaceSelectionMutationService
    ) {
        self.sessionController = sessionController
        self.mutationService = mutationService
        selectionsByTarget = Self.selectionMap(from: sessionController.snapshot)
        sessionObservationToken = sessionController.observe { [weak self] snapshot in
            self?.handleSessionSnapshot(snapshot)
        }
    }

    package func activeTarget() -> Target? {
        guard let workspace = sessionController.activeWorkspace,
              let tab = workspace.composeTabs.first(where: { $0.id == workspace.activeComposeTabID }) ?? workspace.composeTabs.first
        else { return nil }
        return Target(workspaceID: workspace.id, tabID: tab.id)
    }

    package func activeTabID() -> UUID? {
        activeTarget()?.tabID
    }

    package func activeSelectionSnapshot() -> Snapshot {
        guard let target = activeTarget(),
              let tab = sessionController.workspace(id: target.workspaceID)?.composeTabs.first(where: { $0.id == target.tabID })
        else {
            return Snapshot(tabID: nil, selection: StoredSelection(), isVirtual: false)
        }
        return Snapshot(tabID: target.tabID, selection: tab.selection, isVirtual: false)
    }

    package func virtualSelectionSnapshot(tabID: UUID, selection: StoredSelection) -> Snapshot {
        Snapshot(tabID: tabID, selection: selection, isVirtual: true)
    }

    @discardableResult
    package func persistActiveSelection(
        _ selection: StoredSelection,
        source: Source = .runtimeMutation,
        publishChange: Bool = true
    ) -> StoredSelection {
        guard let target = activeTarget() else { return selection }
        persist(selection, for: target, source: source, publishChange: publishChange)
        return selection
    }

    @discardableResult
    package func persistVirtualSelection(
        _ selection: StoredSelection,
        for tabID: UUID,
        publishChange: Bool = true
    ) -> StoredSelection {
        guard let target = target(forTabID: tabID) else { return selection }
        persist(selection, for: target, source: .virtual, publishChange: publishChange)
        return selection
    }

    @discardableResult
    package func replaceActiveSelection(_ selection: StoredSelection) -> StoredSelection {
        persistActiveSelection(selection, source: .runtimeMutation)
    }

    @discardableResult
    package func addPathsToActiveSelection(
        paths: [String],
        mode: String = "full",
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        publishChange: Bool = true
    ) async -> WorkspaceAddSelectionResult {
        guard let target = activeTarget(), let current = selection(for: target) else {
            return WorkspaceAddSelectionResult(
                selection: StoredSelection(),
                invalidPaths: [],
                resolvedMap: [:],
                mutated: false,
                codemapUnavailable: []
            )
        }
        let result = await mutationService.addPaths(
            existing: current,
            paths: paths,
            rawPaths: paths,
            mode: mode,
            rootScope: rootScope
        )
        if result.mutated {
            persist(result.selection, for: target, source: .runtimeMutation, publishChange: publishChange)
        }
        return result
    }

    @discardableResult
    package func removePathsFromActiveSelection(
        paths: [String],
        mode: String = "full",
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        publishChange: Bool = true
    ) async -> WorkspaceRemoveSelectionResult {
        guard let target = activeTarget(), let current = selection(for: target) else {
            return WorkspaceRemoveSelectionResult(
                selection: StoredSelection(),
                invalidPaths: [],
                resolvedMap: [:],
                mutated: false
            )
        }
        let result = await mutationService.removePaths(
            existing: current,
            paths: paths,
            rawPaths: paths,
            mode: mode,
            rootScope: rootScope
        )
        if result.mutated {
            persist(result.selection, for: target, source: .runtimeMutation, publishChange: publishChange)
        }
        return result
    }

    /// Marks the active target so the next session selection change is classified as an app UI flush.
    package func beginExternallyCommittedSelection(source: Source) -> (target: Target, previous: StoredSelection)? {
        guard let target = activeTarget(), let previous = selection(for: target) else { return nil }
        pendingSourceByTarget[target] = source
        return (target, previous)
    }

    /// Completes an external in-memory commit and allocates the persistence revision without dirtying the workspace.
    package func finishExternallyCommittedSelection(target: Target, previous: StoredSelection) {
        guard let current = selection(for: target) else {
            pendingSourceByTarget.removeValue(forKey: target)
            return
        }
        if current != previous {
            sessionController.recordExternallyCommittedSelectionRevision(
                workspaceID: target.workspaceID,
                tabID: target.tabID,
                previous: previous,
                current: current
            )
        } else if let source = pendingSourceByTarget.removeValue(forKey: target) {
            publish(Change(tabID: target.tabID, selection: current, source: source))
        }
    }

    package func observe(_ observer: @escaping Observer) -> WorkspaceSelectionObservationToken {
        let id = UUID()
        observers[id] = observer
        return WorkspaceSelectionObservationToken { [weak self] in
            self?.observers.removeValue(forKey: id)
        }
    }

    private func persist(
        _ selection: StoredSelection,
        for target: Target,
        source: Source,
        publishChange: Bool
    ) {
        guard let previous = self.selection(for: target) else { return }
        guard previous != selection else {
            if publishChange {
                publish(Change(tabID: target.tabID, selection: selection, source: source))
            }
            return
        }
        if publishChange {
            pendingSourceByTarget[target] = source
        } else {
            suppressedObserverTargets.insert(target)
        }
        _ = sessionController.mutateComposeTab(
            workspaceID: target.workspaceID,
            tabID: target.tabID,
            options: .storedOnly
        ) { tab in
            tab.selection = selection
            tab.lastModified = Date()
        }
        if publishChange, pendingSourceByTarget.removeValue(forKey: target) != nil {
            // Defensive fallback if the session did not publish a changed snapshot.
            selectionsByTarget[target] = selection
            publish(Change(tabID: target.tabID, selection: selection, source: source))
        } else if !publishChange {
            suppressedObserverTargets.remove(target)
            selectionsByTarget[target] = selection
        }
    }

    package func selectionSnapshot(for target: Target) -> StoredSelection? {
        selection(for: target)
    }

    package func target(forTabID tabID: UUID) -> Target? {
        if let active = activeTarget(), active.tabID == tabID { return active }
        let matches = sessionController.workspaces.compactMap { workspace -> Target? in
            workspace.composeTabs.contains(where: { $0.id == tabID })
                ? Target(workspaceID: workspace.id, tabID: tabID)
                : nil
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func selection(for target: Target) -> StoredSelection? {
        sessionController.workspace(id: target.workspaceID)?
            .composeTabs.first(where: { $0.id == target.tabID })?
            .selection
    }

    private func handleSessionSnapshot(_ snapshot: WorkspaceSessionSnapshot) {
        let next = Self.selectionMap(from: snapshot)
        let changedTargets = Set(selectionsByTarget.keys).union(next.keys).filter {
            selectionsByTarget[$0] != next[$0]
        }
        selectionsByTarget = next
        for target in changedTargets.sorted(by: Self.targetOrdering) {
            guard let selection = next[target] else {
                pendingSourceByTarget.removeValue(forKey: target)
                suppressedObserverTargets.remove(target)
                continue
            }
            if suppressedObserverTargets.remove(target) != nil {
                pendingSourceByTarget.removeValue(forKey: target)
                continue
            }
            let source = pendingSourceByTarget.removeValue(forKey: target) ?? .mirror
            publish(Change(tabID: target.tabID, selection: selection, source: source))
        }
    }

    private func publish(_ change: Change) {
        let callbacks = Array(observers.values)
        for observer in callbacks {
            observer(change)
        }
    }

    private static func selectionMap(from snapshot: WorkspaceSessionSnapshot) -> [Target: StoredSelection] {
        var result: [Target: StoredSelection] = [:]
        for workspace in snapshot.workspaces {
            for tab in workspace.composeTabs {
                result[Target(workspaceID: workspace.id, tabID: tab.id)] = tab.selection
            }
        }
        return result
    }

    private static func targetOrdering(_ lhs: Target, _ rhs: Target) -> Bool {
        if lhs.workspaceID != rhs.workspaceID {
            return lhs.workspaceID.uuidString < rhs.workspaceID.uuidString
        }
        return lhs.tabID.uuidString < rhs.tabID.uuidString
    }
}
