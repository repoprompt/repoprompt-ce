import Foundation

package struct WorkspaceIndexEntry: Codable, Equatable {
    package let id: UUID
    package var name: String
    package var customStoragePath: URL?
    package var isSystemWorkspace: Bool
    package var isHiddenInMenus: Bool

    package init(
        id: UUID,
        name: String,
        customStoragePath: URL?,
        isSystemWorkspace: Bool,
        isHiddenInMenus: Bool
    ) {
        self.id = id
        self.name = name
        self.customStoragePath = customStoragePath
        self.isSystemWorkspace = isSystemWorkspace
        self.isHiddenInMenus = isHiddenInMenus
    }

    package init(workspace: WorkspaceModel) {
        self.init(
            id: workspace.id,
            name: workspace.name,
            customStoragePath: workspace.customStoragePath,
            isSystemWorkspace: workspace.isSystemWorkspace,
            isHiddenInMenus: workspace.isHiddenInMenus
        )
    }
}

package struct WorkspaceSessionID: Hashable, Codable {
    package let rawValue: UUID

    package init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

package struct WorkspaceTabSelectionKey: Hashable, Codable {
    package let workspaceID: UUID
    package let tabID: UUID

    package init(workspaceID: UUID, tabID: UUID) {
        self.workspaceID = workspaceID
        self.tabID = tabID
    }
}

package struct WorkspaceSessionReadiness: Equatable, Codable {
    package var generation: UInt64
    package var isReady: Bool
    package var catalogGeneration: UInt64?
    package var unavailableReason: String?

    package init(
        generation: UInt64 = 0,
        isReady: Bool = false,
        catalogGeneration: UInt64? = nil,
        unavailableReason: String? = nil
    ) {
        self.generation = generation
        self.isReady = isReady
        self.catalogGeneration = catalogGeneration
        self.unavailableReason = unavailableReason
    }
}

package struct WorkspaceSessionLifecycleReadiness: Equatable {
    package let workspaceID: UUID?
    package let generation: UInt64
    package let catalogGeneration: UInt64?

    package init(workspaceID: UUID?, generation: UInt64, catalogGeneration: UInt64? = nil) {
        self.workspaceID = workspaceID
        self.generation = generation
        self.catalogGeneration = catalogGeneration
    }
}

/// Immutable, non-escalating access to the selected workspace engine. The facade intentionally
/// has no root load/unload, mutation, persistence, or command-admission operation.
package struct WorkspaceSessionQueryCapability: @unchecked Sendable {
    private let rootsClosure: @Sendable () async -> [WorkspaceRootRecord]
    private let rootScopeAvailabilityClosure: @Sendable (WorkspaceLookupRootScope) async -> WorkspaceLookupRootScopeAvailability
    private let catalogGenerationClosure: @Sendable (WorkspaceLookupRootScope) async -> UInt64
    private let catalogDiagnosticsClosure: @Sendable (WorkspaceLookupRootScope) async -> WorkspaceCatalogDiagnostics
    private let searchCatalogAccessClosure: @Sendable (
        WorkspaceLookupRootScope,
        WorkspaceSearchCatalogAccessRequirement
    ) async -> WorkspaceSearchCatalogAccess
    private let lookupPathClosure: @Sendable (WorkspacePathLookupRequest) async -> WorkspacePathLookupResult?

    package init(
        roots: @escaping @Sendable () async -> [WorkspaceRootRecord],
        rootScopeAvailability: @escaping @Sendable (WorkspaceLookupRootScope) async -> WorkspaceLookupRootScopeAvailability,
        catalogGeneration: @escaping @Sendable (WorkspaceLookupRootScope) async -> UInt64,
        catalogDiagnostics: @escaping @Sendable (WorkspaceLookupRootScope) async -> WorkspaceCatalogDiagnostics,
        searchCatalogAccess: @escaping @Sendable (
            WorkspaceLookupRootScope,
            WorkspaceSearchCatalogAccessRequirement
        ) async -> WorkspaceSearchCatalogAccess,
        lookupPath: @escaping @Sendable (WorkspacePathLookupRequest) async -> WorkspacePathLookupResult?
    ) {
        rootsClosure = roots
        rootScopeAvailabilityClosure = rootScopeAvailability
        catalogGenerationClosure = catalogGeneration
        catalogDiagnosticsClosure = catalogDiagnostics
        searchCatalogAccessClosure = searchCatalogAccess
        lookupPathClosure = lookupPath
    }

    package func roots() async -> [WorkspaceRootRecord] {
        await rootsClosure()
    }

    package func rootScopeAvailability(_ scope: WorkspaceLookupRootScope) async -> WorkspaceLookupRootScopeAvailability {
        await rootScopeAvailabilityClosure(scope)
    }

    package func catalogGeneration(_ scope: WorkspaceLookupRootScope = .visibleWorkspace) async -> UInt64 {
        await catalogGenerationClosure(scope)
    }

    package func catalogDiagnostics(_ scope: WorkspaceLookupRootScope = .visibleWorkspace) async -> WorkspaceCatalogDiagnostics {
        await catalogDiagnosticsClosure(scope)
    }

    package func searchCatalogAccess(
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        requirement: WorkspaceSearchCatalogAccessRequirement = .recordsAndPathIndexes
    ) async -> WorkspaceSearchCatalogAccess {
        await searchCatalogAccessClosure(rootScope, requirement)
    }

    package func lookupPath(_ request: WorkspacePathLookupRequest) async -> WorkspacePathLookupResult? {
        await lookupPathClosure(request)
    }
}

/// The sole mutable root-lifecycle capability for one selected session. It owns generation-scoped
/// hydration/unload and exactly-once close; only the session receives this object.
package actor WorkspaceSessionLifecycleOwner {
    private let underlyingQuery: WorkspaceSessionQueryCapability
    private let hydrateClosure: @Sendable (WorkspaceModel?, UInt64) async throws -> WorkspaceSessionLifecycleReadiness
    private let unloadClosure: @Sendable (UInt64) async throws -> Void
    private let closeClosure: @Sendable () async -> Void
    private var unloadedGenerations: Set<UInt64> = []
    private var isClosed = false

    package init(
        query: WorkspaceSessionQueryCapability,
        hydrate: @escaping @Sendable (WorkspaceModel?, UInt64) async throws -> WorkspaceSessionLifecycleReadiness,
        unload: @escaping @Sendable (UInt64) async throws -> Void,
        close: @escaping @Sendable () async -> Void
    ) {
        underlyingQuery = query
        hydrateClosure = hydrate
        unloadClosure = unload
        closeClosure = close
    }

    package nonisolated func makeQueryCapability() -> WorkspaceSessionQueryCapability {
        WorkspaceSessionQueryCapability(
            roots: { [weak self] in await self?.queryRoots() ?? [] },
            rootScopeAvailability: { [weak self] scope in
                await self?.queryRootScopeAvailability(scope)
                    ?? .sessionWorktreeUnavailable(missingPhysicalRootPaths: [])
            },
            catalogGeneration: { [weak self] scope in
                await self?.queryCatalogGeneration(scope) ?? 0
            },
            catalogDiagnostics: { [weak self] scope in
                await self?.queryCatalogDiagnostics(scope)
                    ?? WorkspaceCatalogDiagnostics(
                        generation: 0,
                        rootScope: scope,
                        rootCount: 0,
                        folderCount: 0,
                        fileCount: 0
                    )
            },
            searchCatalogAccess: { [weak self] scope, requirement in
                await self?.querySearchCatalogAccess(scope, requirement: requirement)
                    ?? .unavailable(.sessionWorktreeUnavailable(missingPhysicalRootPaths: []))
            },
            lookupPath: { [weak self] request in
                await self?.queryLookupPath(request)
            }
        )
    }

    package nonisolated var query: WorkspaceSessionQueryCapability {
        makeQueryCapability()
    }

    package func hydrate(
        workspace: WorkspaceModel?,
        generation: UInt64
    ) async throws -> WorkspaceSessionLifecycleReadiness {
        guard !isClosed else { throw WorkspaceSessionFailure("workspace lifecycle is closed") }
        return try await hydrateClosure(workspace, generation)
    }

    package func unload(generation: UInt64) async throws {
        guard generation > 0, unloadedGenerations.insert(generation).inserted else { return }
        try await unloadClosure(generation)
    }

    package func close() async {
        guard !isClosed else { return }
        isClosed = true
        await closeClosure()
    }

    private func queryRoots() async -> [WorkspaceRootRecord] {
        guard !isClosed else { return [] }
        return await underlyingQuery.roots()
    }

    private func queryRootScopeAvailability(
        _ scope: WorkspaceLookupRootScope
    ) async -> WorkspaceLookupRootScopeAvailability {
        guard !isClosed else {
            return .sessionWorktreeUnavailable(missingPhysicalRootPaths: [])
        }
        return await underlyingQuery.rootScopeAvailability(scope)
    }

    private func queryCatalogGeneration(_ scope: WorkspaceLookupRootScope) async -> UInt64 {
        guard !isClosed else { return 0 }
        return await underlyingQuery.catalogGeneration(scope)
    }

    private func queryCatalogDiagnostics(_ scope: WorkspaceLookupRootScope) async -> WorkspaceCatalogDiagnostics {
        guard !isClosed else {
            return WorkspaceCatalogDiagnostics(
                generation: 0,
                rootScope: scope,
                rootCount: 0,
                folderCount: 0,
                fileCount: 0
            )
        }
        return await underlyingQuery.catalogDiagnostics(scope)
    }

    private func querySearchCatalogAccess(
        _ scope: WorkspaceLookupRootScope,
        requirement: WorkspaceSearchCatalogAccessRequirement
    ) async -> WorkspaceSearchCatalogAccess {
        guard !isClosed else {
            return .unavailable(.sessionWorktreeUnavailable(missingPhysicalRootPaths: []))
        }
        return await underlyingQuery.searchCatalogAccess(rootScope: scope, requirement: requirement)
    }

    private func queryLookupPath(
        _ request: WorkspacePathLookupRequest
    ) async -> WorkspacePathLookupResult? {
        guard !isClosed else { return nil }
        return await underlyingQuery.lookupPath(request)
    }
}

package enum WorkspaceSessionAvailability: Equatable, Codable {
    case created
    case hydrating
    case awaitingActivation
    case active
    case switching
    case failed(String)
    case closing
    case closed
}

package struct WorkspaceSessionSnapshot: @unchecked Sendable, Equatable {
    package let sessionID: WorkspaceSessionID
    package let snapshotSequence: UInt64
    package let stateGeneration: UInt64
    package let workspaces: [WorkspaceModel]
    package let activeWorkspaceID: UUID?
    package let selectionRevisions: [WorkspaceTabSelectionKey: UInt64]
    package let dirtyGenerations: [UUID: UInt64]
    package let savedGenerations: [UUID: UInt64]
    package let switchState: WorkspaceSwitchState
    package let readiness: WorkspaceSessionReadiness
    package let availability: WorkspaceSessionAvailability

    package init(
        sessionID: WorkspaceSessionID,
        snapshotSequence: UInt64,
        stateGeneration: UInt64,
        workspaces: [WorkspaceModel],
        activeWorkspaceID: UUID?,
        selectionRevisions: [WorkspaceTabSelectionKey: UInt64],
        dirtyGenerations: [UUID: UInt64],
        savedGenerations: [UUID: UInt64],
        switchState: WorkspaceSwitchState,
        readiness: WorkspaceSessionReadiness,
        availability: WorkspaceSessionAvailability
    ) {
        self.sessionID = sessionID
        self.snapshotSequence = snapshotSequence
        self.stateGeneration = stateGeneration
        self.workspaces = workspaces
        self.activeWorkspaceID = activeWorkspaceID
        self.selectionRevisions = selectionRevisions
        self.dirtyGenerations = dirtyGenerations
        self.savedGenerations = savedGenerations
        self.switchState = switchState
        self.readiness = readiness
        self.availability = availability
    }

    package func selectionRevision(workspaceID: UUID, tabID: UUID) -> UInt64 {
        selectionRevisions[WorkspaceTabSelectionKey(workspaceID: workspaceID, tabID: tabID), default: 0]
    }

    package func selection(workspaceID: UUID, tabID: UUID) -> StoredSelection? {
        workspaces.first(where: { $0.id == workspaceID })?
            .composeTabs.first(where: { $0.id == tabID })?.selection
    }
}

package struct WorkspaceSessionActivationToken: Hashable {
    package let sessionID: WorkspaceSessionID
    package let activationID: UUID
    package let firstAuthoritativeGeneration: UInt64

    package init(
        sessionID: WorkspaceSessionID,
        activationID: UUID,
        firstAuthoritativeGeneration: UInt64
    ) {
        self.sessionID = sessionID
        self.activationID = activationID
        self.firstAuthoritativeGeneration = firstAuthoritativeGeneration
    }
}

package struct WorkspaceSessionAdmissionToken: Hashable {
    package let sessionID: WorkspaceSessionID
    package let activationID: UUID
    package let admittedGeneration: UInt64
    package let snapshotSequence: UInt64

    package init(
        sessionID: WorkspaceSessionID,
        activationID: UUID,
        admittedGeneration: UInt64,
        snapshotSequence: UInt64
    ) {
        self.sessionID = sessionID
        self.activationID = activationID
        self.admittedGeneration = admittedGeneration
        self.snapshotSequence = snapshotSequence
    }
}

package enum WorkspaceSessionAdmissionResult: Equatable {
    case admitted(WorkspaceSessionAdmissionToken)
    case notReady(WorkspaceSessionAvailability)
}

package struct WorkspaceSessionCommandSource: Equatable, Codable {
    package let kind: String
    package let correlationID: UUID?

    package init(kind: String, correlationID: UUID? = nil) {
        self.kind = kind
        self.correlationID = correlationID
    }
}

package enum WorkspaceCommand: @unchecked Sendable, Equatable {
    case create(WorkspaceModel, makeActive: Bool)
    case delete(workspaceID: UUID)
    case replace(WorkspaceModel)
    case replaceOrderedRoots(workspaceID: UUID, roots: [String])
    case setActive(workspaceID: UUID)
}

package struct ComposeTabNonSelectionPatch: @unchecked Sendable, Equatable {
    package var name: String
    package var lastModified: Date
    package var isPinned: Bool
    package var activeChatSessionID: UUID?
    package var activeAgentSessionID: UUID?
    package var expandedFolders: [String]
    package var promptText: String
    package var selectedMetaPromptIDs: [UUID]
    package var activeSubView: FilesTab?
    package var contextOverrides: ContextBuilderOverrides
    package var contextBuilder: ContextBuilderTabConfig

    package init(tab: ComposeTabState) {
        name = tab.name
        lastModified = tab.lastModified
        isPinned = tab.isPinned
        activeChatSessionID = tab.activeChatSessionID
        activeAgentSessionID = tab.activeAgentSessionID
        expandedFolders = tab.expandedFolders
        promptText = tab.promptText
        selectedMetaPromptIDs = tab.selectedMetaPromptIDs
        activeSubView = tab.activeSubView
        contextOverrides = tab.contextOverrides
        contextBuilder = tab.contextBuilder
    }

    package func applying(to tab: ComposeTabState) -> ComposeTabState {
        var updated = tab
        updated.name = name
        updated.lastModified = lastModified
        updated.isPinned = isPinned
        updated.activeChatSessionID = activeChatSessionID
        updated.activeAgentSessionID = activeAgentSessionID
        updated.expandedFolders = expandedFolders
        updated.promptText = promptText
        updated.selectedMetaPromptIDs = selectedMetaPromptIDs
        updated.activeSubView = activeSubView
        updated.contextOverrides = contextOverrides
        updated.contextBuilder = contextBuilder
        return updated
    }
}

package enum ComposeTabCommand: @unchecked Sendable, Equatable {
    case create(workspaceID: UUID, tab: ComposeTabState, makeActive: Bool)
    case patch(workspaceID: UUID, tabID: UUID, patch: ComposeTabNonSelectionPatch)
    case patchStashed(workspaceID: UUID, stashedTabID: UUID, patch: ComposeTabNonSelectionPatch)
    case remove(workspaceID: UUID, tabID: UUID)
    case activate(workspaceID: UUID, tabID: UUID)
    case reorder(workspaceID: UUID, orderedTabIDs: [UUID])
    case stash(workspaceID: UUID, tabID: UUID, stashedTabID: UUID, stashedAt: Date)
    case restore(workspaceID: UUID, stashedTabID: UUID)
    case deleteStashed(workspaceID: UUID, stashedTabIDs: Set<UUID>)
}

package struct WorkspaceSelectionCommand: @unchecked Sendable, Equatable {
    package let workspaceID: UUID
    package let tabID: UUID
    package let expectedRevision: UInt64
    package let selection: StoredSelection

    package init(
        workspaceID: UUID,
        tabID: UUID,
        expectedRevision: UInt64,
        selection: StoredSelection
    ) {
        self.workspaceID = workspaceID
        self.tabID = tabID
        self.expectedRevision = expectedRevision
        self.selection = selection
    }
}

package struct WorkspaceSelectionAndTabPatchCommand: @unchecked Sendable, Equatable {
    package let selection: WorkspaceSelectionCommand
    package let patch: ComposeTabNonSelectionPatch

    package init(selection: WorkspaceSelectionCommand, patch: ComposeTabNonSelectionPatch) {
        self.selection = selection
        self.patch = patch
    }
}

package enum WorkspacePersistenceCommand: Equatable {
    case saveIndex
    case saveWorkspace(workspaceID: UUID)
    case flushWorkspace(workspaceID: UUID)
    case reloadWorkspace(workspaceID: UUID)
    case reloadIndex
}

package struct WorkspaceSwitchCommand: Equatable {
    package let targetWorkspaceID: UUID
    package let shouldSaveCurrentState: Bool
    package let reason: WorkspaceSwitchReason

    package init(
        targetWorkspaceID: UUID,
        shouldSaveCurrentState: Bool,
        reason: WorkspaceSwitchReason
    ) {
        self.targetWorkspaceID = targetWorkspaceID
        self.shouldSaveCurrentState = shouldSaveCurrentState
        self.reason = reason
    }
}

package struct WorkspaceRefreshCommand: Equatable {
    package let workspaceID: UUID
    package let expectedReadinessGeneration: UInt64

    package init(workspaceID: UUID, expectedReadinessGeneration: UInt64) {
        self.workspaceID = workspaceID
        self.expectedReadinessGeneration = expectedReadinessGeneration
    }
}

package enum WorkspaceSessionCommand: @unchecked Sendable, Equatable {
    case workspace(WorkspaceCommand)
    case composeTab(ComposeTabCommand)
    case selection(WorkspaceSelectionCommand)
    case selectionAndPatch(WorkspaceSelectionAndTabPatchCommand)
    case persistence(WorkspacePersistenceCommand)
    case switchWorkspace(WorkspaceSwitchCommand)
    case refresh(WorkspaceRefreshCommand)
}

package struct WorkspaceSessionCommandEnvelope: @unchecked Sendable, Equatable {
    package let commandID: UUID
    package let admissionToken: WorkspaceSessionAdmissionToken
    package let expectedGeneration: UInt64
    package let command: WorkspaceSessionCommand
    package let source: WorkspaceSessionCommandSource

    package init(
        commandID: UUID = UUID(),
        admissionToken: WorkspaceSessionAdmissionToken,
        expectedGeneration: UInt64,
        command: WorkspaceSessionCommand,
        source: WorkspaceSessionCommandSource
    ) {
        self.commandID = commandID
        self.admissionToken = admissionToken
        self.expectedGeneration = expectedGeneration
        self.command = command
        self.source = source
    }
}

package enum WorkspaceSessionPersistenceDisposition: Equatable {
    case notRequested
    case pending
    case written
    case suppressedByNewerState
    case failed(String)
}

package struct WorkspaceSessionCommandReceipt: Equatable {
    package let commandID: UUID
    package let sessionID: WorkspaceSessionID
    package let activationID: UUID
    package let resultingGeneration: UInt64
    package let selectionRevision: UInt64?
    package let dirtyGeneration: UInt64?
    package let persistenceDisposition: WorkspaceSessionPersistenceDisposition
    package let snapshotSequence: UInt64

    package init(
        commandID: UUID,
        sessionID: WorkspaceSessionID,
        activationID: UUID,
        resultingGeneration: UInt64,
        selectionRevision: UInt64? = nil,
        dirtyGeneration: UInt64? = nil,
        persistenceDisposition: WorkspaceSessionPersistenceDisposition = .notRequested,
        snapshotSequence: UInt64
    ) {
        self.commandID = commandID
        self.sessionID = sessionID
        self.activationID = activationID
        self.resultingGeneration = resultingGeneration
        self.selectionRevision = selectionRevision
        self.dirtyGeneration = dirtyGeneration
        self.persistenceDisposition = persistenceDisposition
        self.snapshotSequence = snapshotSequence
    }
}

package struct WorkspaceSessionConflict: Equatable {
    package enum Kind: Equatable {
        case generation(expected: UInt64, actual: UInt64)
        case selectionRevision(key: WorkspaceTabSelectionKey, expected: UInt64, actual: UInt64)
        case readinessGeneration(expected: UInt64, actual: UInt64)
    }

    package let kind: Kind

    package init(kind: Kind) {
        self.kind = kind
    }
}

package enum WorkspaceSessionRejection: Equatable {
    case foreignSession
    case expiredActivation
    case workspaceNotFound(UUID)
    case tabNotFound(workspaceID: UUID, tabID: UUID)
    case duplicateWorkspace(UUID)
    case duplicateTab(workspaceID: UUID, tabID: UUID)
    case cannotDeleteLastWorkspace
    case invalidCommand(String)
}

package struct WorkspaceSessionFailure: Error, Equatable {
    package let message: String

    package init(_ message: String) {
        self.message = message
    }
}

package enum WorkspaceSessionCommandResult: @unchecked Sendable, Equatable {
    case committed(WorkspaceSessionCommandReceipt)
    case unchanged(WorkspaceSessionCommandReceipt)
    case stale(latestSnapshot: WorkspaceSessionSnapshot, conflict: WorkspaceSessionConflict)
    case notReady(WorkspaceSessionAvailability)
    case rejected(WorkspaceSessionRejection)
    case failed(WorkspaceSessionFailure)
}

package protocol WorkspaceSessionCommandIngress: Sendable {
    func currentSnapshot() async -> WorkspaceSessionSnapshot?
    func observations(after sequence: UInt64?) async -> AsyncStream<WorkspaceSessionSnapshot>
    func admit() async -> WorkspaceSessionAdmissionResult
    func execute(_ command: WorkspaceSessionCommandEnvelope) async -> WorkspaceSessionCommandResult
    func shutdown() async
}

package struct WorkspaceSessionHydrationInput: @unchecked Sendable, Equatable {
    package let workspaces: [WorkspaceModel]
    package let activeWorkspaceID: UUID?

    package init(workspaces: [WorkspaceModel], activeWorkspaceID: UUID?) {
        self.workspaces = workspaces
        self.activeWorkspaceID = activeWorkspaceID
    }
}

package enum WorkspaceSessionHydrationResult: @unchecked Sendable, Equatable {
    case awaitingFirstSnapshotApplication(WorkspaceSessionSnapshot)
    case alreadyHydrated(WorkspaceSessionSnapshot?)
    case failed(WorkspaceSessionFailure)
}

package enum WorkspaceSessionActivationResult: Equatable {
    case activated(WorkspaceSessionActivationToken)
    case wrongSnapshot(expected: UInt64, actual: UInt64)
    case notReady(WorkspaceSessionAvailability)
}

package protocol WorkspaceSelectionRevisionAllocating: Sendable {
    func allocate() async -> UInt64
}
