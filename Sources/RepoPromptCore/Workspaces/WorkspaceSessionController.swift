import Foundation

package struct WorkspaceSessionBindingCandidate: Equatable {
    package let tabID: UUID
    package let workspaceID: UUID
    package let workspaceName: String
    package let isActiveInWorkspace: Bool
    package let repoPaths: [String]

    package init(
        tabID: UUID,
        workspaceID: UUID,
        workspaceName: String,
        isActiveInWorkspace: Bool,
        repoPaths: [String]
    ) {
        self.tabID = tabID
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.isActiveInWorkspace = isActiveInWorkspace
        self.repoPaths = repoPaths
    }
}

package struct WorkspaceSessionSnapshot: Equatable {
    package let generation: UInt64
    package let workspaces: [WorkspaceModel]
    package let activeWorkspaceID: UUID?
    package let indexEntries: [WorkspaceIndexEntry]

    package init(
        generation: UInt64,
        workspaces: [WorkspaceModel],
        activeWorkspaceID: UUID?,
        indexEntries: [WorkspaceIndexEntry]
    ) {
        self.generation = generation
        self.workspaces = workspaces
        self.activeWorkspaceID = activeWorkspaceID
        self.indexEntries = indexEntries
    }

    package var activeWorkspace: WorkspaceModel? {
        guard let activeWorkspaceID else { return nil }
        return workspaces.first(where: { $0.id == activeWorkspaceID })
    }
}

package struct WorkspaceSessionMutationOptions {
    package var touchDateModified: Bool
    package var markDirty: Bool
    package var recordsSelectionRevisions: Bool

    package init(
        touchDateModified: Bool = true,
        markDirty: Bool = true,
        recordsSelectionRevisions: Bool = true
    ) {
        self.touchDateModified = touchDateModified
        self.markDirty = markDirty
        self.recordsSelectionRevisions = recordsSelectionRevisions
    }

    package static let hydration = WorkspaceSessionMutationOptions(
        touchDateModified: false,
        markDirty: false,
        recordsSelectionRevisions: false
    )
    package static let storedOnly = WorkspaceSessionMutationOptions(touchDateModified: false, markDirty: true)
}

package struct WorkspaceSessionTransaction {
    package var workspaces: [WorkspaceModel]
    package var activeWorkspaceID: UUID?

    package init(workspaces: [WorkspaceModel], activeWorkspaceID: UUID?) {
        self.workspaces = workspaces
        self.activeWorkspaceID = activeWorkspaceID
    }

    package mutating func workspaceIndex(id: UUID) -> Int? {
        workspaces.lastIndex(where: { $0.id == id })
    }
}

@MainActor
package final class WorkspaceSessionObservationToken {
    private var cancelAction: (() -> Void)?

    init(cancelAction: @escaping () -> Void) {
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

@MainActor
package final class WorkspaceSessionController {
    package typealias Observer = @MainActor (WorkspaceSessionSnapshot) -> Void

    package let repository: WorkspaceRepository
    package let persistenceWriter: WorkspacePersistenceWriter
    private let accessPolicy: any WorkspaceAccessPolicy

    private var orderedWorkspaces: [WorkspaceModel] = []
    private var activeID: UUID?
    private var workspaceIndexMap: [UUID: Int] = [:]
    private var snapshotGeneration: UInt64 = 0
    private var stateGenerationByWorkspaceID: [UUID: UInt64] = [:]
    private var savedGenerationByWorkspaceID: [UUID: UInt64] = [:]
    private var repoPathBaselineByWorkspaceID: [UUID: [String]] = [:]
    private var selectionRevisionByKey: [WorkspaceTabSelectionKey: UInt64] = [:]
    private var observers: [UUID: Observer] = [:]

    package init(
        repository: WorkspaceRepository,
        persistenceWriter: WorkspacePersistenceWriter,
        accessPolicy: any WorkspaceAccessPolicy
    ) {
        self.repository = repository
        self.persistenceWriter = persistenceWriter
        self.accessPolicy = accessPolicy
    }

    package var snapshot: WorkspaceSessionSnapshot {
        WorkspaceSessionSnapshot(
            generation: snapshotGeneration,
            workspaces: orderedWorkspaces,
            activeWorkspaceID: activeID,
            indexEntries: orderedWorkspaces.filter { !$0.isEphemeral }.map(WorkspaceIndexEntry.init(workspace:))
        )
    }

    package var workspaces: [WorkspaceModel] {
        orderedWorkspaces
    }

    package var activeWorkspaceID: UUID? {
        activeID
    }

    package var activeWorkspace: WorkspaceModel? {
        guard let activeID, let index = workspaceIndexMap[activeID] else { return nil }
        return orderedWorkspaces[index]
    }

    package func workspace(id: UUID) -> WorkspaceModel? {
        workspaceIndexMap[id].map { orderedWorkspaces[$0] }
    }

    package func composeTab(with id: UUID) -> ComposeTabState? {
        for workspace in orderedWorkspaces {
            if let tab = workspace.composeTabs.first(where: { $0.id == id }) { return tab }
        }
        return nil
    }

    package func replaceAll(
        _ workspaces: [WorkspaceModel],
        activeWorkspaceID: UUID?,
        repositoryBaselines: [UUID: [String]]? = nil
    ) {
        let previous = orderedWorkspaces
        let previousSelectionRevisions = selectionRevisionByKey
        orderedWorkspaces = workspaces
        activeID = activeWorkspaceID.flatMap { id in workspaces.contains(where: { $0.id == id }) ? id : nil }
        if activeID == nil { activeID = workspaces.first?.id }
        rebuildIndexMap()
        stateGenerationByWorkspaceID = Dictionary(
            workspaces.map { ($0.id, stateGenerationByWorkspaceID[$0.id, default: 0]) },
            uniquingKeysWith: { _, last in last }
        )
        savedGenerationByWorkspaceID = Dictionary(
            workspaces.map { ($0.id, stateGenerationByWorkspaceID[$0.id, default: 0]) },
            uniquingKeysWith: { _, last in last }
        )
        repoPathBaselineByWorkspaceID = repositoryBaselines ?? Dictionary(
            workspaces.map { ($0.id, $0.repoPaths) },
            uniquingKeysWith: { _, last in last }
        )
        selectionRevisionByKey = preservedHydrationSelectionRevisions(
            previous: previous,
            current: workspaces,
            previousRevisions: previousSelectionRevisions
        )
        publish()
    }

    package func setActiveWorkspaceID(_ id: UUID?) {
        let resolved = id.flatMap { workspaceIndexMap[$0] == nil ? nil : $0 }
        guard activeID != resolved else { return }
        activeID = resolved
        publish()
    }

    @discardableResult
    package func mutateWorkspace(
        id: UUID,
        options: WorkspaceSessionMutationOptions = WorkspaceSessionMutationOptions(),
        _ mutation: (inout WorkspaceModel) -> Void
    ) -> WorkspaceModel? {
        guard let index = workspaceIndexMap[id] else { return nil }
        let old = orderedWorkspaces[index]
        var updated = old
        mutation(&updated)
        if options.touchDateModified { updated.dateModified = Date() }
        guard updated != old else { return old }
        orderedWorkspaces[index] = updated
        noteMutation(
            workspaceID: id,
            markDirty: options.markDirty,
            recordsSelectionRevisions: options.recordsSelectionRevisions,
            previous: old,
            current: updated
        )
        publish()
        return updated
    }

    @discardableResult
    package func mutateActiveWorkspace(
        options: WorkspaceSessionMutationOptions = WorkspaceSessionMutationOptions(),
        _ mutation: (inout WorkspaceModel) -> Void
    ) -> WorkspaceModel? {
        guard let activeID else { return nil }
        return mutateWorkspace(id: activeID, options: options, mutation)
    }

    @discardableResult
    package func mutateComposeTab(
        workspaceID: UUID,
        tabID: UUID,
        options: WorkspaceSessionMutationOptions = WorkspaceSessionMutationOptions(),
        _ mutation: (inout ComposeTabState) -> Void
    ) -> ComposeTabState? {
        var result: ComposeTabState?
        _ = mutateWorkspace(id: workspaceID, options: options) { workspace in
            guard let tabIndex = workspace.composeTabs.firstIndex(where: { $0.id == tabID }) else { return }
            mutation(&workspace.composeTabs[tabIndex])
            result = workspace.composeTabs[tabIndex]
        }
        return result
    }

    package func transaction(
        options: WorkspaceSessionMutationOptions = WorkspaceSessionMutationOptions(),
        _ mutation: (inout WorkspaceSessionTransaction) -> Void
    ) {
        let previous = orderedWorkspaces
        let previousActiveID = activeID
        var transaction = WorkspaceSessionTransaction(workspaces: previous, activeWorkspaceID: previousActiveID)
        mutation(&transaction)
        if options.touchDateModified {
            let oldByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            for index in transaction.workspaces.indices where oldByID[transaction.workspaces[index].id] != transaction.workspaces[index] {
                transaction.workspaces[index].dateModified = Date()
            }
        }
        guard transaction.workspaces != previous || transaction.activeWorkspaceID != previousActiveID else { return }
        orderedWorkspaces = transaction.workspaces
        activeID = transaction.activeWorkspaceID.flatMap { id in orderedWorkspaces.contains(where: { $0.id == id }) ? id : nil }
        rebuildIndexMap()
        let oldByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for workspace in orderedWorkspaces where oldByID[workspace.id] != workspace {
            noteMutation(
                workspaceID: workspace.id,
                markDirty: options.markDirty,
                recordsSelectionRevisions: options.recordsSelectionRevisions,
                previous: oldByID[workspace.id],
                current: workspace
            )
        }
        let currentIDs = Set(orderedWorkspaces.map(\.id))
        stateGenerationByWorkspaceID = stateGenerationByWorkspaceID.filter { currentIDs.contains($0.key) }
        savedGenerationByWorkspaceID = savedGenerationByWorkspaceID.filter { currentIDs.contains($0.key) }
        repoPathBaselineByWorkspaceID = repoPathBaselineByWorkspaceID.filter { currentIDs.contains($0.key) }
        publish()
    }

    package func markDirty(workspaceID: UUID) {
        guard workspaceIndexMap[workspaceID] != nil else { return }
        stateGenerationByWorkspaceID[workspaceID, default: 0] &+= 1
    }

    package func stateGeneration(workspaceID: UUID) -> UInt64 {
        stateGenerationByWorkspaceID[workspaceID, default: 0]
    }

    package func isDirty(workspaceID: UUID) -> Bool {
        stateGenerationByWorkspaceID[workspaceID, default: 0] != savedGenerationByWorkspaceID[workspaceID, default: 0]
    }

    package func recordSaveCompletion(
        workspaceID: UUID,
        capturedGeneration: UInt64,
        persistedWorkspace: WorkspaceModel
    ) {
        guard stateGenerationByWorkspaceID[workspaceID, default: 0] == capturedGeneration else { return }
        repoPathBaselineByWorkspaceID[workspaceID] = persistedWorkspace.repoPaths
        savedGenerationByWorkspaceID[workspaceID] = capturedGeneration
    }

    package func recordRepositoryBaseline(_ workspace: WorkspaceModel) {
        repoPathBaselineByWorkspaceID[workspace.id] = workspace.repoPaths
    }

    package func repositoryBaseline(workspaceID: UUID) -> [String]? {
        repoPathBaselineByWorkspaceID[workspaceID]
    }

    package func hasLocalRepoPathEdit(workspaceID: UUID) -> Bool {
        guard let workspace = workspace(id: workspaceID), let baseline = repoPathBaselineByWorkspaceID[workspaceID] else {
            return true
        }
        return Self.normalizedPaths(workspace.repoPaths) != Self.normalizedPaths(baseline)
    }

    package func selectionRevision(workspaceID: UUID, tabID: UUID) -> UInt64 {
        selectionRevisionByKey[WorkspaceTabSelectionKey(workspaceID: workspaceID, tabID: tabID), default: 0]
    }

    package func saveMetadata(
        for workspace: WorkspaceModel,
        source: WorkspaceSaveSource,
        owner: WorkspaceSaveOwner
    ) -> WorkspaceSavePayloadMetadata {
        let activeTab = workspace.activeComposeTabID.flatMap { id in workspace.composeTabs.first(where: { $0.id == id }) }
        let revision = activeTab.map { selectionRevision(workspaceID: workspace.id, tabID: $0.id) } ?? 0
        let selectionRecords = workspace.composeTabs.map { tab in
            WorkspaceSaveSelectionRecord(
                tabID: tab.id,
                revision: selectionRevision(workspaceID: workspace.id, tabID: tab.id),
                selection: tab.selection
            )
        }
        return WorkspaceSavePayloadMetadata(
            source: source,
            owner: owner,
            workspaceID: workspace.id,
            workspaceName: workspace.name,
            workspaceDateModified: workspace.dateModified,
            activeTabID: activeTab?.id,
            activeSelectionRevision: revision,
            activeSelection: activeTab?.selection,
            selectionRecords: selectionRecords
        )
    }

    package func observe(_ observer: @escaping Observer) -> WorkspaceSessionObservationToken {
        let id = UUID()
        observers[id] = observer
        observer(snapshot)
        return WorkspaceSessionObservationToken { [weak self] in self?.observers.removeValue(forKey: id) }
    }

    package func bindingCandidate(forContextID id: UUID) -> WorkspaceSessionBindingCandidate? {
        for workspace in orderedWorkspaces {
            guard let tab = workspace.composeTabs.first(where: { $0.id == id }) else { continue }
            return applyingAccessPolicy(
                WorkspaceSessionBindingCandidate(
                    tabID: tab.id,
                    workspaceID: workspace.id,
                    workspaceName: workspace.name,
                    isActiveInWorkspace: workspace.activeComposeTabID == tab.id,
                    repoPaths: workspace.repoPaths
                )
            )
        }
        return nil
    }

    package func bindingCandidates(
        matchingWorkingDirs dirs: [String],
        includeHidden: Bool = false
    ) -> [WorkspaceSessionBindingCandidate] {
        let normalizedDirs = dirs.map(Self.normalizePath).filter { !$0.isEmpty }
        guard !normalizedDirs.isEmpty,
              let workspace = activeWorkspace,
              includeHidden || !workspace.isHiddenInMenus,
              Self.workspaceMatches(workspace, normalizedDirs: normalizedDirs),
              let tab = workspace.composeTabs.first(where: { $0.id == workspace.activeComposeTabID }) ?? workspace.composeTabs.first
        else { return [] }
        return [applyingAccessPolicy(WorkspaceSessionBindingCandidate(
            tabID: tab.id,
            workspaceID: workspace.id,
            workspaceName: workspace.name,
            isActiveInWorkspace: workspace.activeComposeTabID == tab.id,
            repoPaths: workspace.repoPaths
        ))]
    }

    private func rebuildIndexMap() {
        workspaceIndexMap = Dictionary(
            orderedWorkspaces.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { _, last in last }
        )
    }

    private func noteMutation(
        workspaceID: UUID,
        markDirty: Bool,
        recordsSelectionRevisions: Bool,
        previous: WorkspaceModel?,
        current: WorkspaceModel
    ) {
        if markDirty { stateGenerationByWorkspaceID[workspaceID, default: 0] &+= 1 }
        if recordsSelectionRevisions, let previous {
            recordSelectionRevisions(previous: [previous], current: [current])
        }
    }

    private func recordSelectionRevisions(previous: [WorkspaceModel], current: [WorkspaceModel]) {
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for workspace in current {
            let oldTabs = Dictionary(
                (previousByID[workspace.id]?.composeTabs ?? []).map { ($0.id, $0.selection) },
                uniquingKeysWith: { _, last in last }
            )
            for tab in workspace.composeTabs where oldTabs[tab.id] != tab.selection {
                let key = WorkspaceTabSelectionKey(workspaceID: workspace.id, tabID: tab.id)
                selectionRevisionByKey[key] = persistenceWriter.allocateSelectionRevision()
            }
        }
    }

    private func preservedHydrationSelectionRevisions(
        previous: [WorkspaceModel],
        current: [WorkspaceModel],
        previousRevisions: [WorkspaceTabSelectionKey: UInt64]
    ) -> [WorkspaceTabSelectionKey: UInt64] {
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var preserved: [WorkspaceTabSelectionKey: UInt64] = [:]
        for workspace in current {
            let oldSelections = Dictionary(
                (previousByID[workspace.id]?.composeTabs ?? []).map { ($0.id, $0.selection) },
                uniquingKeysWith: { _, last in last }
            )
            for tab in workspace.composeTabs where oldSelections[tab.id] == tab.selection {
                let key = WorkspaceTabSelectionKey(workspaceID: workspace.id, tabID: tab.id)
                if let revision = previousRevisions[key] { preserved[key] = revision }
            }
        }
        return preserved
    }

    private func publish() {
        snapshotGeneration &+= 1
        let value = snapshot
        let callbacks = Array(observers.values)
        for observer in callbacks {
            observer(value)
        }
    }

    private func applyingAccessPolicy(_ candidate: WorkspaceSessionBindingCandidate) -> WorkspaceSessionBindingCandidate {
        WorkspaceSessionBindingCandidate(
            tabID: candidate.tabID,
            workspaceID: candidate.workspaceID,
            workspaceName: candidate.workspaceName,
            isActiveInWorkspace: candidate.isActiveInWorkspace,
            repoPaths: candidate.repoPaths.filter { accessPolicy.allowsWorkspaceRoot(URL(fileURLWithPath: $0)) }
        )
    }

    private nonisolated static func normalizedPaths(_ paths: [String]) -> [String] {
        paths.map { (($0 as NSString).standardizingPath).lowercased() }
    }

    private nonisolated static func normalizePath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    private nonisolated static func workspaceMatches(_ workspace: WorkspaceModel, normalizedDirs: [String]) -> Bool {
        let roots = workspace.repoPaths.map(normalizePath).filter { !$0.isEmpty }
        return !roots.isEmpty && normalizedDirs.allSatisfy { directory in
            roots.contains { root in directory == root || directory.hasPrefix(root.hasSuffix("/") ? root : root + "/") }
        }
    }
}
