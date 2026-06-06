import Foundation

package enum WorkspaceFileTreeSnapshotMode: String {
    case none
    case selected
    case full
    case folders
    case auto

    package init(fileTreeOption: FileTreeOption) {
        switch fileTreeOption {
        case .none:
            self = .none
        case .selected:
            self = .selected
        case .files:
            self = .full
        case .auto:
            self = .auto
        }
    }
}

package struct WorkspaceFileTreeSnapshotRequest {
    fileprivate let selectedFileIDs: Set<UUID>
    package let mode: WorkspaceFileTreeSnapshotMode
    package let filePathDisplay: FilePathDisplay
    package let onlyIncludeRootsWithSelectedFiles: Bool
    package let includeLegend: Bool
    package let showCodeMapMarkers: Bool
    package let rootScope: WorkspaceLookupRootScope
    package let startPath: String?
    package let maxDepth: Int?

    package init(
        mode: WorkspaceFileTreeSnapshotMode,
        filePathDisplay: FilePathDisplay,
        onlyIncludeRootsWithSelectedFiles: Bool,
        includeLegend: Bool,
        showCodeMapMarkers: Bool = true,
        rootScope: WorkspaceLookupRootScope = .allLoaded,
        startPath: String? = nil,
        maxDepth: Int? = nil
    ) {
        selectedFileIDs = []
        self.mode = mode
        self.filePathDisplay = filePathDisplay
        self.onlyIncludeRootsWithSelectedFiles = onlyIncludeRootsWithSelectedFiles
        self.includeLegend = includeLegend
        self.showCodeMapMarkers = showCodeMapMarkers
        self.rootScope = rootScope
        self.startPath = startPath
        self.maxDepth = maxDepth
    }
}

package struct WorkspaceObservedCodemapResult: @unchecked Sendable {
    package let fullPath: String
    package let modificationDate: Date
    package let fileAPI: FileAPI?

    package init(fullPath: String, modificationDate: Date, fileAPI: FileAPI?) {
        self.fullPath = StandardizedPath.absolute(fullPath)
        self.modificationDate = modificationDate
        self.fileAPI = fileAPI
    }
}

package struct WorkspaceCodemapFileAPIAggregate {
    package let orderedFileAPIs: [FileAPI]
    package let firstFileAPIByStandardizedNestedPath: [String: FileAPI]
}

package enum WorkspaceFileCatalogMaterializationResult: Equatable {
    case materialized(WorkspaceFileRecord)
    case ineligible(CatalogRegularFileIneligibilityReason)

    package var file: WorkspaceFileRecord? {
        if case let .materialized(file) = self { return file }
        return nil
    }

    package var ineligibilityReason: CatalogRegularFileIneligibilityReason? {
        if case let .ineligible(reason) = self { return reason }
        return nil
    }
}

package enum WorkspaceExplicitFileMaterializationResult: Equatable {
    case materialized(WorkspaceFileRecord)
    case noCandidate
    case blocked
    case ambiguous
}

package enum WorkspaceExplicitCatalogFileLookupResult: Equatable {
    case matched(WorkspaceFileRecord)
    case noCandidate
    case blocked
    case ambiguous
}

package struct WorkspaceDisplayRootRefsSnapshot: Equatable {
    package let visibleRoots: [WorkspaceRootRef]
    package let allRoots: [WorkspaceRootRef]
}

package actor WorkspaceFileContextStore {
    private struct RootState {
        let root: WorkspaceRootRecord
        let service: FileSystemService
        var folderIDsByRelativePath: [String: UUID]
        var fileIDsByRelativePath: [String: UUID]
        var childFolderIDsByFolderID: [UUID: [UUID]]
        var childFileIDsByFolderID: [UUID: [UUID]]
    }

    private struct RootLoadConfiguration: Hashable {
        let kind: WorkspaceRootKind
        let respectGitignore: Bool
        let respectRepoIgnore: Bool
        let respectCursorignore: Bool
        let skipSymlinks: Bool
        let enableHierarchicalIgnores: Bool
    }

    private struct ScopedIngressBarrierTarget {
        let watcherAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark
        let acceptedServicePublicationSequence: UInt64

        func covers(_ other: ScopedIngressBarrierTarget) -> Bool {
            watcherAcceptedWatermark >= other.watcherAcceptedWatermark
                && acceptedServicePublicationSequence >= other.acceptedServicePublicationSequence
        }
    }

    private struct ScopedIngressBarrierFlight {
        let token: UInt64
        let target: ScopedIngressBarrierTarget
        let task: Task<WorkspaceIngressBarrierSample, Never>
    }

    #if DEBUG
        struct ScopedIngressBarrierStats: Equatable {
            let launchCount: Int
            let joinCount: Int
            let successorCount: Int
        }
    #endif

    #if DEBUG
        private var rootLoadWillStartHandler: (@Sendable (String) async -> Void)?
        private var rootLoadDidJoinInFlightHandler: (@Sendable (String) async -> Void)?
        private var rootUnloadDidDetachHandler: (@Sendable ([String]) async -> Void)?
        private var ensureIndexedFilesEligibilityDidResolveHandler: (@Sendable (UUID, String) async -> Void)?
        private var watcherSinkWillApplyHandler: (@Sendable (UUID) async -> Void)?
        private var publisherIngressWillWaitHandler: (@Sendable (Set<UUID>) async -> Void)?
        private var watcherServiceStateWillReconcileHandler: (@Sendable (UUID, Bool) async -> Void)?
        private var appliedIngressDidCaptureWatermarksHandler: (@Sendable ([UUID: UInt64]) async -> Void)?
        private var scopedIngressBarrierWillFlushHandler: (@Sendable (UUID) async -> Void)?
        private var scopedIngressBarrierLaunchCountsByRootID: [UUID: Int] = [:]
        private var scopedIngressBarrierJoinCountsByRootID: [UUID: Int] = [:]
        private var scopedIngressBarrierSuccessorCountsByRootID: [UUID: Int] = [:]

        func setRootLoadWillStartHandler(_ handler: (@Sendable (String) async -> Void)?) {
            rootLoadWillStartHandler = handler
        }

        func setRootLoadDidJoinInFlightHandler(_ handler: (@Sendable (String) async -> Void)?) {
            rootLoadDidJoinInFlightHandler = handler
        }

        func setRootUnloadDidDetachHandler(_ handler: (@Sendable ([String]) async -> Void)?) {
            rootUnloadDidDetachHandler = handler
        }

        func setEnsureIndexedFilesEligibilityDidResolveHandler(_ handler: (@Sendable (UUID, String) async -> Void)?) {
            ensureIndexedFilesEligibilityDidResolveHandler = handler
        }

        func setWatcherSinkWillApplyHandler(_ handler: (@Sendable (UUID) async -> Void)?) {
            watcherSinkWillApplyHandler = handler
        }

        func setPublisherIngressWillWaitHandler(_ handler: (@Sendable (Set<UUID>) async -> Void)?) {
            publisherIngressWillWaitHandler = handler
        }

        func setWatcherServiceStateWillReconcileHandler(_ handler: (@Sendable (UUID, Bool) async -> Void)?) {
            watcherServiceStateWillReconcileHandler = handler
        }

        func setAppliedIngressDidCaptureWatermarksHandler(_ handler: (@Sendable ([UUID: UInt64]) async -> Void)?) {
            appliedIngressDidCaptureWatermarksHandler = handler
        }

        func setScopedIngressBarrierWillFlushHandler(_ handler: (@Sendable (UUID) async -> Void)?) {
            scopedIngressBarrierWillFlushHandler = handler
        }

        func scopedIngressBarrierStatsForTesting(rootID: UUID) -> ScopedIngressBarrierStats {
            ScopedIngressBarrierStats(
                launchCount: scopedIngressBarrierLaunchCountsByRootID[rootID] ?? 0,
                joinCount: scopedIngressBarrierJoinCountsByRootID[rootID] ?? 0,
                successorCount: scopedIngressBarrierSuccessorCountsByRootID[rootID] ?? 0
            )
        }
    #endif

    private enum ExplicitDiskLookupCandidatesResult {
        case candidates([(rootID: UUID, relativePath: String)])
        case ambiguousAlias
    }

    private struct RootIndexBuffers {
        var foldersByID: [UUID: WorkspaceFolderRecord] = [:]
        var filesByID: [UUID: WorkspaceFileRecord] = [:]
        var folderIDsByStandardizedFullPath: [String: UUID] = [:]
        var fileIDsByStandardizedFullPath: [String: UUID] = [:]
    }

    private struct SearchCatalogSnapshotCacheEntry {
        let validationToken: UInt64
        let snapshot: WorkspaceSearchCatalogSnapshot
    }

    private let runtimeDependencies: WorkspaceRuntimeDependencies
    private var rootStatesByID: [UUID: RootState] = [:]
    private var rootIDsByStandardizedPath: [String: UUID] = [:]
    private var foldersByID: [UUID: WorkspaceFolderRecord] = [:]
    private var filesByID: [UUID: WorkspaceFileRecord] = [:]
    private var folderIDsByStandardizedFullPath: [String: UUID] = [:]
    private var fileIDsByStandardizedFullPath: [String: UUID] = [:]
    private var managedOnlyFileIDs = Set<UUID>()
    private var managedOnlyFolderIDs = Set<UUID>()
    private var rootLoadOrder: [UUID] = []
    private var unloadingRootPaths: Set<String> = []
    private var unloadWaitersByRootPath: [String: [UUID: CheckedContinuation<Void, Error>]] = [:]
    private var rootLoadTasksByPath: [String: Task<WorkspaceRootRecord, Error>] = [:]
    private var rootLoadConfigurationsByPath: [String: RootLoadConfiguration] = [:]
    private var catalogGenerationsByScope: [WorkspaceLookupRootScope: UInt64] = [
        .visibleWorkspace: 0,
        .visibleWorkspacePlusGitData: 0,
        .allLoaded: 0
    ]
    private var searchCatalogSnapshotsByScope: [WorkspaceLookupRootScope: SearchCatalogSnapshotCacheEntry] = [:]
    private static let maxCachedSearchCatalogSnapshotScopes = 16
    private static let defaultMaxPendingDeltasPerRoot = 10000
    private let pathMatchWorker = PathMatchWorker()
    private let codeScanActor: CodeScanActor
    private let deferredReplayBuffer = DeferredReplayBufferActor(
        maxPendingDeltasPerRoot: WorkspaceFileContextStore.defaultMaxPendingDeltasPerRoot
    )
    private var codemapSnapshotsByFileID: [UUID: WorkspaceCodemapSnapshot] = [:]
    private var codemapFileIDsByRootID: [UUID: Set<UUID>] = [:]
    private var cachedCodemapFileAPIAggregate: WorkspaceCodemapFileAPIAggregate?
    private var codemapUpdateContinuations: [UUID: AsyncStream<WorkspaceCodemapUpdateEvent>.Continuation] = [:]
    private var fileSystemDeltaContinuations: [UUID: AsyncStream<WorkspaceFileSystemDeltaEvent>.Continuation] = [:]
    private var appliedIndexContinuations: [UUID: AsyncStream<WorkspaceAppliedIndexBatchEvent>.Continuation] = [:]
    private var appliedIndexGenerationsByRootID: [UUID: UInt64] = [:]
    private var watcherSubscriptionsByRootID: [UUID: FileSystemDeltaPublicationSubscription] = [:]
    private let publisherIngressCoordinator = WorkspaceFileSystemIngressCoordinator()
    private var scopedIngressBarrierFlightsByRootID: [UUID: ScopedIngressBarrierFlight] = [:]
    private var nextScopedIngressBarrierToken: UInt64 = 0
    private static let maxConcurrentScopedIngressBarriers = 8
    private var codeScanResultTask: Task<Void, Never>?

    package init(runtimeDependencies: WorkspaceRuntimeDependencies) {
        self.runtimeDependencies = runtimeDependencies
        codeScanActor = CodeScanActor(cacheRoot: runtimeDependencies.codeMapCacheRoot)
    }

    deinit {
        codeScanResultTask?.cancel()
        for subscription in watcherSubscriptionsByRootID.values {
            subscription.cancel()
        }
        for continuation in codemapUpdateContinuations.values {
            continuation.finish()
        }
        for continuation in fileSystemDeltaContinuations.values {
            continuation.finish()
        }
        for continuation in appliedIndexContinuations.values {
            continuation.finish()
        }
    }

    package func roots() -> [WorkspaceRootRecord] {
        rootLoadOrder.compactMap { rootStatesByID[$0]?.root }
    }

    package func rootRecords(forRootFolderPaths rootFolderPaths: [String], includeSystemRoots: Bool = true) -> [WorkspaceRootRecord] {
        let standardizedRootPaths = Set(rootFolderPaths.map { ($0 as NSString).standardizingPath })
        guard !standardizedRootPaths.isEmpty else { return [] }
        return rootLoadOrder.compactMap { rootID in
            guard let root = rootStatesByID[rootID]?.root,
                  standardizedRootPaths.contains(root.standardizedFullPath),
                  includeSystemRoots || !root.isSystemRoot
            else {
                return nil
            }
            return root
        }
    }

    package func fileSystemDeltaEvents() -> AsyncStream<WorkspaceFileSystemDeltaEvent> {
        let streamID = UUID()
        return AsyncStream { continuation in
            fileSystemDeltaContinuations[streamID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeFileSystemDeltaContinuation(id: streamID) }
            }
        }
    }

    private func removeFileSystemDeltaContinuation(id: UUID) {
        fileSystemDeltaContinuations.removeValue(forKey: id)
    }

    package func appliedIndexEvents() -> AsyncStream<WorkspaceAppliedIndexBatchEvent> {
        let streamID = UUID()
        return AsyncStream { continuation in
            appliedIndexContinuations[streamID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeAppliedIndexContinuation(id: streamID) }
            }
        }
    }

    private func removeAppliedIndexContinuation(id: UUID) {
        appliedIndexContinuations.removeValue(forKey: id)
    }

    package func startWatchingRoot(id rootID: UUID) async throws {
        let state = try state(for: rootID)
        if watcherSubscriptionsByRootID[rootID] != nil { return }

        let root = state.root
        let diagnosticRootToken = state.service.diagnosticRootToken
        let ingress = publisherIngressCoordinator.openPublisherIngress(rootID: rootID) { [weak self] publication, correlation in
            WorkspaceRuntimePerf.lifecycleEvent(
                WorkspaceRuntimePerf.Lifecycle.WorkspaceIngress.storeSinkBegan,
                correlation: correlation,
                WorkspaceRuntimePerf.Dimensions(
                    changeCount: publication.deltas.count,
                    rootToken: diagnosticRootToken.uuidString,
                    ingressSequence: publication.watcherAcceptedWatermark?.rawValue,
                    barrierSequence: publication.servicePublicationSequence
                )
            )
            await self?.handleObservedPublisherFileSystemPublication(
                publication,
                root: root,
                publicationCorrelation: correlation,
                diagnosticRootToken: diagnosticRootToken
            )
        }
        let source = state.service.subscribeToChanges { [publisherIngressCoordinator] publication in
            publisherIngressCoordinator.accept(
                ingress,
                publication: publication,
                lifecycleCorrelation: nil
            )
        }
        guard rootStatesByID[rootID] != nil,
              publisherIngressCoordinator.isPublisherIngressOpen(ingress)
        else {
            source.cancel()
            publisherIngressCoordinator.closePublisherIngress(rootID: rootID)
            return
        }
        watcherSubscriptionsByRootID[rootID] = source
        await state.service.startWatchingForChanges()
    }

    package func stopWatchingRoot(id rootID: UUID) async {
        guard let state = rootStatesByID[rootID] else {
            watcherSubscriptionsByRootID.removeValue(forKey: rootID)?.cancel()
            publisherIngressCoordinator.closePublisherIngress(rootID: rootID)
            await waitForCurrentPublisherIngress(rootIDs: [rootID])
            publisherIngressCoordinator.finishPublisherIngress(rootIDs: [rootID])
            return
        }
        await stopWatchingRoot(id: rootID, service: state.service)
    }

    private func stopWatchingRoot(id rootID: UUID, service: FileSystemService) async {
        let detachedStop = await service.detachWatcherAndCaptureAcceptedWatermark()
        let priorAcceptedSequence = publisherIngressCoordinator.appliedSnapshot(rootID: rootID)
            .acceptedServicePublicationSequence
        await waitForCurrentPublisherIngress(rootIDs: [rootID])
        await publisherIngressCoordinator.waitUntilApplied(
            rootID: rootID,
            servicePublicationSequence: priorAcceptedSequence
        )
        _ = await service.flushPendingEventsNow(
            throughAcceptedWatcherWatermark: detachedStop.acceptedWatermark
        )
        let acceptedDownstreamCut = publisherIngressCoordinator.appliedSnapshot(rootID: rootID)
            .acceptedServicePublicationSequence
        await publisherIngressCoordinator.waitUntilApplied(
            rootID: rootID,
            servicePublicationSequence: max(priorAcceptedSequence, acceptedDownstreamCut)
        )
        let applied = publisherIngressCoordinator.appliedSnapshot(rootID: rootID)
        assert(applied.appliedWatcherWatermark >= detachedStop.acceptedWatermark)
        watcherSubscriptionsByRootID.removeValue(forKey: rootID)?.cancel()
        publisherIngressCoordinator.closePublisherIngress(rootID: rootID)
        #if DEBUG
            if let watcherServiceStateWillReconcileHandler {
                await watcherServiceStateWillReconcileHandler(rootID, false)
            }
        #endif
        await service.finishDetachedWatcherStop(detachedStop)
        await waitForCurrentPublisherIngress(rootIDs: [rootID])
        publisherIngressCoordinator.finishPublisherIngress(rootIDs: [rootID])
    }

    private func waitForCurrentPublisherIngress(rootIDs: Set<UUID>) async {
        #if DEBUG
            if publisherIngressCoordinator.pendingPublisherIngressCount(rootIDs: rootIDs) > 0,
               let publisherIngressWillWaitHandler
            {
                await publisherIngressWillWaitHandler(rootIDs)
            }
        #endif
        await publisherIngressCoordinator.waitForCurrentPublisherIngress(rootIDs: rootIDs)
    }

    private func yieldFileSystemDeltaEvent(_ event: WorkspaceFileSystemDeltaEvent) {
        for continuation in fileSystemDeltaContinuations.values {
            continuation.yield(event)
        }
    }

    private func yieldAppliedIndexEvent(_ event: WorkspaceAppliedIndexBatchEvent) {
        for continuation in appliedIndexContinuations.values {
            continuation.yield(event)
        }
    }

    private func nextAppliedIndexGeneration(forRootID rootID: UUID) -> UInt64 {
        let next = (appliedIndexGenerationsByRootID[rootID] ?? 0) &+ 1
        appliedIndexGenerationsByRootID[rootID] = next
        return next
    }

    package func replayObservedFileSystemDeltas(rootID: UUID, deltas: [FileSystemDelta]) async {
        guard let root = rootStatesByID[rootID]?.root else { return }
        await handleObservedFileSystemDeltas(deltas, root: root)
    }

    #if DEBUG
        func publishSyntheticFileSystemDeltasForTesting(rootID: UUID, deltas: [FileSystemDelta]) async throws {
            let state = try state(for: rootID)
            await state.service.publishFileSystemDeltas(deltas, source: .syntheticMutation)
        }

        func publisherIngressCountForTesting(rootID: UUID) -> Int {
            publisherIngressCoordinator.pendingPublisherIngressCount(rootIDs: [rootID])
        }

        func rootWatcherIsActiveForTesting(rootID: UUID) async throws -> Bool {
            let state = try state(for: rootID)
            return await state.service.isWatchingForChangesForTesting()
        }

        func acceptWatcherPayloadForTesting(
            rootID: UUID,
            events: [(absolutePath: String, flags: FileSystemWatchEventFlags, eventId: FileSystemWatchEventID)],
            scheduleDrain: Bool = true
        ) async throws -> FileSystemWatcherIngressMailbox.Watermark? {
            let state = try state(for: rootID)
            return await state.service.acceptWatcherPayloadForTesting(events, scheduleDrain: scheduleDrain)
        }

        func appliedIngressSnapshotForTesting(rootID: UUID) -> WorkspaceFileSystemIngressCoordinator.AppliedSnapshot {
            publisherIngressCoordinator.appliedSnapshot(rootID: rootID)
        }
    #endif

    private func handleObservedPublisherFileSystemPublication(
        _ publication: FileSystemDeltaPublication,
        root: WorkspaceRootRecord,
        publicationCorrelation: WorkspaceRuntimePerf.LifecycleCorrelation?,
        diagnosticRootToken: UUID
    ) async {
        #if DEBUG
            if let watcherSinkWillApplyHandler {
                await watcherSinkWillApplyHandler(root.id)
            }
        #endif
        await handleObservedFileSystemDeltas(
            publication.deltas,
            root: root,
            publicationCorrelation: publicationCorrelation,
            diagnosticRootToken: diagnosticRootToken,
            watcherAcceptedWatermark: publication.watcherAcceptedWatermark,
            servicePublicationSequence: publication.servicePublicationSequence
        )
    }

    private func handleObservedFileSystemDeltas(
        _ deltas: [FileSystemDelta],
        root: WorkspaceRootRecord,
        publicationCorrelation: WorkspaceRuntimePerf.LifecycleCorrelation? = nil,
        diagnosticRootToken: UUID? = nil,
        watcherAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark? = nil,
        servicePublicationSequence: UInt64? = nil
    ) async {
        guard rootStatesByID[root.id] != nil else { return }
        for delta in deltas {
            guard await isDiscoveryFacingFileSystemDelta(delta, rootID: root.id) else { continue }
            yieldFileSystemDeltaEvent(WorkspaceFileSystemDeltaEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                delta: delta
            ))
        }
        let preparedDeltas = FileSystemDeltaPreparation.coalesce(deltas, inRoot: root.standardizedFullPath)
            .compactMap { FileSystemDeltaPreparation.prepare($0, inRoot: root.standardizedFullPath) }
        await applyPreparedIndexDeltas(rootID: root.id, deltas: preparedDeltas)
        WorkspaceRuntimePerf.lifecycleEvent(
            WorkspaceRuntimePerf.Lifecycle.WorkspaceIngress.storeCanonicalApplyCompleted,
            correlation: publicationCorrelation,
            WorkspaceRuntimePerf.Dimensions(
                appliedCount: preparedDeltas.count,
                rootToken: diagnosticRootToken?.uuidString,
                ingressSequence: watcherAcceptedWatermark?.rawValue,
                barrierSequence: servicePublicationSequence
            )
        )
    }

    private func isDiscoveryFacingFileSystemDelta(_ delta: FileSystemDelta, rootID: UUID) async -> Bool {
        guard let state = rootStatesByID[rootID] else { return false }
        switch delta {
        case let .fileAdded(relativePath):
            return await state.service.catalogEligibleRegularFileExists(relativePath: relativePath)
        case let .folderAdded(relativePath):
            return await state.service.catalogFolderIsDiscoverable(relativePath: relativePath)
        case let .fileRemoved(relativePath), let .fileModified(relativePath, _):
            guard let file = file(rootID: rootID, relativePath: relativePath) else { return false }
            return isDiscoverableFileID(file.id)
        case let .folderRemoved(relativePath), let .folderModified(relativePath, _):
            guard let folder = folder(rootID: rootID, relativePath: relativePath) else { return false }
            return isDiscoverableFolderID(folder.id)
        }
    }

    package func files(inRoot rootID: UUID) -> [WorkspaceFileRecord] {
        guard let state = rootStatesByID[rootID] else { return [] }
        return state.fileIDsByRelativePath.values
            .filter(isDiscoverableFileID)
            .compactMap { filesByID[$0] }
            .sorted { $0.standardizedRelativePath < $1.standardizedRelativePath }
    }

    package func folders(inRoot rootID: UUID) -> [WorkspaceFolderRecord] {
        guard let state = rootStatesByID[rootID] else { return [] }
        return state.folderIDsByRelativePath.values
            .filter(isDiscoverableFolderID)
            .compactMap { foldersByID[$0] }
            .sorted { $0.standardizedRelativePath < $1.standardizedRelativePath }
    }

    package func catalogGeneration(rootScope: WorkspaceLookupRootScope = .visibleWorkspace) -> UInt64 {
        scopedSnapshotGeneration(scope: rootScope)
    }

    package func catalogDiagnostics(rootScope: WorkspaceLookupRootScope = .visibleWorkspace) -> WorkspaceCatalogDiagnostics {
        let roots = rootsForPathLookup(scope: rootScope)
        let allowedRootIDs = Set(roots.map(\.id))
        let folderCount = foldersByID.values.reduce(into: 0) { count, folder in
            if allowedRootIDs.contains(folder.rootID), isDiscoverableFolderID(folder.id) { count += 1 }
        }
        let fileCount = filesByID.values.reduce(into: 0) { count, file in
            if allowedRootIDs.contains(file.rootID), isDiscoverableFileID(file.id) { count += 1 }
        }
        return WorkspaceCatalogDiagnostics(
            generation: scopedSnapshotGeneration(scope: rootScope),
            rootScope: rootScope,
            rootCount: roots.count,
            folderCount: folderCount,
            fileCount: fileCount
        )
    }

    package func searchCatalogSnapshot(rootScope: WorkspaceLookupRootScope = .visibleWorkspace) -> WorkspaceSearchCatalogSnapshot {
        let catalogSnapshotState = WorkspaceRuntimePerf.begin(WorkspaceRuntimePerf.Stage.Search.catalogSnapshot)
        let validationToken = searchCatalogSnapshotValidationToken(scope: rootScope)
        if let cached = searchCatalogSnapshotsByScope[rootScope] {
            if cached.validationToken == validationToken {
                WorkspaceRuntimePerf.end(
                    WorkspaceRuntimePerf.Stage.Search.catalogSnapshot,
                    catalogSnapshotState,
                    WorkspaceRuntimePerf.Dimensions(
                        fileCount: cached.snapshot.diagnostics.fileCount,
                        cacheHit: true,
                        rootCount: cached.snapshot.diagnostics.rootCount,
                        folderCount: cached.snapshot.diagnostics.folderCount
                    )
                )
                return cached.snapshot
            }
            searchCatalogSnapshotsByScope.removeValue(forKey: rootScope)
        }
        let roots = rootsForPathLookup(scope: rootScope)
        let rootsByID = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
        let allowedRootIDs = Set(rootsByID.keys)
        let files = filesByID.values
            .filter { allowedRootIDs.contains($0.rootID) && isDiscoverableFileID($0.id) }
            .sorted {
                if $0.standardizedFullPath == $1.standardizedFullPath {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.standardizedFullPath < $1.standardizedFullPath
            }
        let entries = files.compactMap { file -> WorkspaceSearchCatalogEntry? in
            guard let root = rootsByID[file.rootID] else { return nil }
            return WorkspaceSearchCatalogEntry(file: file, root: root)
        }
        let diagnostics = WorkspaceCatalogDiagnostics(
            generation: scopedSnapshotGeneration(scope: rootScope),
            rootScope: rootScope,
            rootCount: roots.count,
            folderCount: foldersByID.values.reduce(into: 0) { count, folder in
                if allowedRootIDs.contains(folder.rootID), isDiscoverableFolderID(folder.id) { count += 1 }
            },
            fileCount: files.count
        )
        let snapshot = WorkspaceSearchCatalogSnapshot(
            generation: diagnostics.generation,
            rootScope: rootScope,
            roots: roots,
            files: files,
            entries: entries,
            diagnostics: diagnostics
        )
        WorkspaceRuntimePerf.end(
            WorkspaceRuntimePerf.Stage.Search.catalogSnapshot,
            catalogSnapshotState,
            WorkspaceRuntimePerf.Dimensions(
                fileCount: diagnostics.fileCount,
                cacheHit: false,
                rootCount: diagnostics.rootCount,
                folderCount: diagnostics.folderCount
            )
        )
        cacheSearchCatalogSnapshot(snapshot, validationToken: validationToken, scope: rootScope)
        return snapshot
    }

    package func directFolderChildren(
        rootID: UUID,
        relativePath: String = ""
    ) -> WorkspaceDirectFolderChildrenSnapshot? {
        guard let state = rootStatesByID[rootID] else { return nil }
        let key = StandardizedPath.relative(relativePath)
        guard let folderID = state.folderIDsByRelativePath[key] else { return nil }
        return directFolderChildren(folderID: folderID)
    }

    package func directFolderChildren(folderID: UUID) -> WorkspaceDirectFolderChildrenSnapshot? {
        guard isDiscoverableFolderID(folderID),
              let folder = foldersByID[folderID],
              let state = rootStatesByID[folder.rootID]
        else { return nil }
        let childFolders = (state.childFolderIDsByFolderID[folderID] ?? [])
            .filter(isDiscoverableFolderID)
            .compactMap { foldersByID[$0] }
            .sorted(by: compareDirectChildFolders)
        let childFiles = (state.childFileIDsByFolderID[folderID] ?? [])
            .filter(isDiscoverableFileID)
            .compactMap { filesByID[$0] }
            .sorted(by: compareDirectChildFiles)
        return WorkspaceDirectFolderChildrenSnapshot(
            generation: scopedSnapshotGeneration(scope: .allLoaded),
            root: state.root,
            folder: folder,
            childFolders: childFolders,
            childFiles: childFiles
        )
    }

    private func compareDirectChildFolders(_ lhs: WorkspaceFolderRecord, _ rhs: WorkspaceFolderRecord) -> Bool {
        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        if lhs.standardizedRelativePath != rhs.standardizedRelativePath {
            return lhs.standardizedRelativePath < rhs.standardizedRelativePath
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private func compareDirectChildFiles(_ lhs: WorkspaceFileRecord, _ rhs: WorkspaceFileRecord) -> Bool {
        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        if lhs.standardizedRelativePath != rhs.standardizedRelativePath {
            return lhs.standardizedRelativePath < rhs.standardizedRelativePath
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    @discardableResult
    package func warmPathLookupIndexes(rootScope: WorkspaceLookupRootScope = .visibleWorkspace) async -> UInt64 {
        while true {
            let staticData = buildStaticSnapshot(scope: rootScope)
            let warmedGeneration = await pathMatchWorker.prepare(staticData: staticData)
            let currentGeneration = scopedSnapshotGeneration(scope: rootScope)
            if warmedGeneration == currentGeneration || Task.isCancelled {
                return warmedGeneration
            }
        }
    }

    /// Awaits callback payloads accepted before the captured cut through canonical store application.
    ///
    /// FSEvents not yet delivered by macOS remain outside this contract. Later accepted callbacks
    /// may join the same actor-visible batch or overflow sentinel, so the captured watcher cut is a
    /// lower bound rather than a strict exclusion boundary. Synthetic publications are ordered with
    /// watcher publications and included in the downstream service-publication cut, but they do not
    /// advance watcher-accepted watermarks.
    package func awaitAppliedIngressForAllRoots() async -> [WorkspaceIngressBarrierSample] {
        await awaitAppliedIngress(rootIDs: rootLoadOrder)
    }

    /// Awaits freshness only for roots represented by `rootScope`.
    /// Concurrent requests for the same root share a watermark-keyed flight when the
    /// existing flight covers both the callback-accepted and publisher-accepted cuts.
    package func awaitAppliedIngress(rootScope: WorkspaceLookupRootScope) async -> [WorkspaceIngressBarrierSample] {
        await awaitAppliedIngress(rootIDs: rootsForPathLookup(scope: rootScope).map(\.id))
    }

    /// Resolves the narrowest safe workspace freshness scope for an explicit request.
    /// Absolute paths await only their containing loaded root. Absolute paths outside all
    /// loaded roots (including always-readable support files) do not pay a workspace barrier.
    /// Relative and alias-shaped paths await the caller's fallback scope because resolution
    /// may depend on more than one candidate root.
    package func awaitAppliedIngressForExplicitRequest(
        userPath: String,
        fallbackScope: WorkspaceLookupRootScope
    ) async -> [WorkspaceIngressBarrierSample] {
        let trimmed = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        guard standardized.hasPrefix("/") else {
            return await awaitAppliedIngress(rootScope: fallbackScope)
        }
        let containingRootID = rootLoadOrder.compactMap { rootID -> WorkspaceRootRecord? in
            rootStatesByID[rootID]?.root
        }
        .filter { StandardizedPath.isDescendant(standardized, of: $0.standardizedFullPath) }
        .max { $0.standardizedFullPath.count < $1.standardizedFullPath.count }?
        .id
        guard let containingRootID else { return [] }
        return await awaitAppliedIngress(rootIDs: [containingRootID])
    }

    private func awaitAppliedIngress(rootIDs: [UUID]) async -> [WorkspaceIngressBarrierSample] {
        let orderedRootIDs = rootIDs.reduce(into: [UUID]()) { result, rootID in
            guard rootStatesByID[rootID] != nil, !result.contains(rootID) else { return }
            result.append(rootID)
        }
        guard !orderedRootIDs.isEmpty else { return [] }

        let targetsByRootID = Dictionary(uniqueKeysWithValues: orderedRootIDs.compactMap { rootID in
            rootStatesByID[rootID].map { state in
                (
                    rootID,
                    ScopedIngressBarrierTarget(
                        watcherAcceptedWatermark: state.service.captureAcceptedWatcherWatermark(),
                        acceptedServicePublicationSequence: publisherIngressCoordinator.appliedSnapshot(rootID: rootID)
                            .acceptedServicePublicationSequence
                    )
                )
            }
        })

        #if DEBUG
            if let appliedIngressDidCaptureWatermarksHandler {
                await appliedIngressDidCaptureWatermarksHandler(targetsByRootID.mapValues { $0.watcherAcceptedWatermark.rawValue })
            }
        #endif

        var samplesByIndex: [Int: WorkspaceIngressBarrierSample] = [:]
        for chunkStart in stride(from: 0, to: orderedRootIDs.count, by: Self.maxConcurrentScopedIngressBarriers) {
            let chunkEnd = min(chunkStart + Self.maxConcurrentScopedIngressBarriers, orderedRootIDs.count)
            await withTaskGroup(of: (Int, WorkspaceIngressBarrierSample?).self) { group in
                for index in chunkStart ..< chunkEnd {
                    let rootID = orderedRootIDs[index]
                    guard let target = targetsByRootID[rootID] else { continue }
                    group.addTask { [weak self] in
                        await (index, self?.awaitAppliedIngress(rootID: rootID, target: target))
                    }
                }
                for await (index, sample) in group {
                    if let sample { samplesByIndex[index] = sample }
                }
            }
        }
        return samplesByIndex.keys.sorted().compactMap { samplesByIndex[$0] }
    }

    private func awaitAppliedIngress(
        rootID: UUID,
        target: ScopedIngressBarrierTarget
    ) async -> WorkspaceIngressBarrierSample? {
        guard let state = rootStatesByID[rootID] else { return nil }
        if let flight = scopedIngressBarrierFlightsByRootID[rootID], flight.target.covers(target) {
            #if DEBUG
                scopedIngressBarrierJoinCountsByRootID[rootID, default: 0] += 1
            #endif
            return await flight.task.value
        }

        let isSuccessor = scopedIngressBarrierFlightsByRootID[rootID] != nil
        nextScopedIngressBarrierToken &+= 1
        let token = nextScopedIngressBarrierToken
        let publisherIngressCoordinator = publisherIngressCoordinator
        let root = state.root
        let service = state.service
        #if DEBUG
            scopedIngressBarrierLaunchCountsByRootID[rootID, default: 0] += 1
            if isSuccessor {
                scopedIngressBarrierSuccessorCountsByRootID[rootID, default: 0] += 1
            }
            let scopedIngressBarrierWillFlushHandler = scopedIngressBarrierWillFlushHandler
            let publisherIngressWillWaitHandler = publisherIngressWillWaitHandler
        #endif
        #if DEBUG || EDIT_FLOW_PERF
            let lifecycleCorrelation = WorkspaceRuntimePerf.currentLifecycleCorrelation
        #else
            let lifecycleCorrelation: WorkspaceRuntimePerf.LifecycleCorrelation? = nil
        #endif
        let task = Task {
            #if DEBUG
                if let scopedIngressBarrierWillFlushHandler {
                    await scopedIngressBarrierWillFlushHandler(rootID)
                }
                let pendingCount = await service.pendingRawEventCountForDiagnostics()
            #else
                let pendingCount = 0
            #endif
            WorkspaceRuntimePerf.lifecycleEvent(
                WorkspaceRuntimePerf.Lifecycle.WorkspaceIngress.rootFlushBegan,
                correlation: lifecycleCorrelation,
                WorkspaceRuntimePerf.Dimensions(
                    pendingRawEventCount: pendingCount,
                    rootToken: service.diagnosticRootToken.uuidString,
                    ingressSequence: target.watcherAcceptedWatermark.rawValue
                )
            )
            #if DEBUG
                if target.acceptedServicePublicationSequence > publisherIngressCoordinator.appliedSnapshot(rootID: rootID).appliedServicePublicationSequence,
                   let publisherIngressWillWaitHandler
                {
                    await publisherIngressWillWaitHandler([rootID])
                }
            #endif
            await publisherIngressCoordinator.waitUntilApplied(
                rootID: rootID,
                servicePublicationSequence: target.acceptedServicePublicationSequence
            )
            let publishedSequence = await service.flushPendingEventsNow(
                throughAcceptedWatcherWatermark: target.watcherAcceptedWatermark
            )
            let acceptedDownstreamCut = publisherIngressCoordinator.appliedSnapshot(rootID: rootID)
                .acceptedServicePublicationSequence
            await publisherIngressCoordinator.waitUntilApplied(
                rootID: rootID,
                servicePublicationSequence: max(
                    target.acceptedServicePublicationSequence,
                    acceptedDownstreamCut
                )
            )
            let applied = publisherIngressCoordinator.appliedSnapshot(rootID: rootID)
            WorkspaceRuntimePerf.lifecycleEvent(
                WorkspaceRuntimePerf.Lifecycle.WorkspaceIngress.rootFlushEnded,
                correlation: lifecycleCorrelation,
                WorkspaceRuntimePerf.Dimensions(
                    pendingRawEventCount: pendingCount,
                    rootToken: service.diagnosticRootToken.uuidString,
                    ingressSequence: applied.appliedWatcherWatermark.rawValue,
                    barrierSequence: applied.appliedServicePublicationSequence
                )
            )
            return WorkspaceIngressBarrierSample(
                rootID: rootID,
                rootPath: root.standardizedFullPath,
                pendingRawEventCountBeforeFlush: pendingCount,
                acceptedWatcherWatermark: target.watcherAcceptedWatermark.rawValue,
                publishedServicePublicationSequence: publishedSequence,
                appliedServicePublicationSequence: applied.appliedServicePublicationSequence,
                appliedWatcherWatermark: applied.appliedWatcherWatermark.rawValue
            )
        }
        scopedIngressBarrierFlightsByRootID[rootID] = ScopedIngressBarrierFlight(
            token: token,
            target: target,
            task: task
        )
        let sample = await task.value
        if scopedIngressBarrierFlightsByRootID[rootID]?.token == token {
            scopedIngressBarrierFlightsByRootID.removeValue(forKey: rootID)
        }
        return sample
    }

    /// Compatibility wrapper for callers that still consume the original diagnostic shape.
    package func flushPendingServiceEventsForAllRoots() async -> [(rootPath: String, pendingRawEventCountBeforeFlush: Int)] {
        await awaitAppliedIngressForAllRoots().map { sample in
            (sample.rootPath, sample.pendingRawEventCountBeforeFlush)
        }
    }

    // MARK: - Deferred replay buffer ownership

    package func updateDeferredReplayRoutingState(
        isWindowFocused: Bool,
        isReplayActive: Bool,
        routingVersion: UInt64
    ) async {
        await deferredReplayBuffer.updateRoutingState(
            isWindowFocused: isWindowFocused,
            isReplayActive: isReplayActive,
            routingVersion: routingVersion
        )
    }

    package func updateDeferredReplayImmediateChunkSizeOverride(_ chunkSize: Int?) async {
        await deferredReplayBuffer.updateImmediateReplayChunkSizeOverride(chunkSize)
    }

    package func registerDeferredReplayRootGeneration(_ generation: UInt64, forRootKey rootKey: String) async {
        await deferredReplayBuffer.registerActiveRootGeneration(generation, forRootKey: rootKey)
    }

    package func unregisterDeferredReplayRootGeneration(forRootKey rootKey: String) async {
        await deferredReplayBuffer.unregisterActiveRootGeneration(forRootKey: rootKey)
    }

    package func ingestDeferredReplayLiveDeltas(
        _ deltas: [FileSystemDelta],
        forRootKey rootKey: String,
        rootGeneration: UInt64
    ) async -> DeferredReplayIngressResult {
        await deferredReplayBuffer.ingestLiveDeltas(deltas, forRootKey: rootKey, rootGeneration: rootGeneration)
    }

    package func ingestDeferredReplayLiveDeltas(
        _ deltas: [FileSystemDelta],
        forRootKey rootKey: String
    ) async -> DeferredReplayIngressResult {
        await deferredReplayBuffer.ingestLiveDeltas(deltas, forRootKey: rootKey)
    }

    package func finishDeferredReplayPreparedImmediateIngress(_ immediateReplay: PreparedImmediateReplay) async {
        await deferredReplayBuffer.finishPreparedImmediateIngress(immediateReplay)
    }

    package func enqueueDeferredReplayDeltas(
        _ deltas: [FileSystemDelta],
        forRootKey rootKey: String
    ) async -> DeferredReplayIngressResult {
        await deferredReplayBuffer.enqueueDeferredDeltas(deltas, forRootKey: rootKey)
    }

    package func drainDeferredReplayPreparedBatches(
        preferredRootOrder: [String],
        chunkSize: Int
    ) async -> [PreparedFileSystemReplayBatch] {
        await deferredReplayBuffer.drainPreparedBatches(
            preferredRootOrder: preferredRootOrder,
            chunkSize: chunkSize
        )
    }

    package func clearDeferredReplayRoot(_ rootKey: String) async {
        await deferredReplayBuffer.clearRoot(rootKey)
    }

    package func clearDeferredReplayBuffer() async {
        await deferredReplayBuffer.clearAll()
    }

    package func hasDeferredReplayPendingWork() async -> Bool {
        await deferredReplayBuffer.hasPendingWork()
    }

    package func pendingDeferredReplayDeltaCount(forRootKey rootKey: String) async -> Int {
        await deferredReplayBuffer.pendingDeltaCount(forRootKey: rootKey)
    }

    package func deferredReplayPendingWorkSnapshot() async -> DeferredReplayPendingWorkSnapshot {
        await deferredReplayBuffer.pendingWorkSnapshot()
    }

    #if DEBUG
        package func deferredReplayDiagnosticsSnapshot() async -> DeferredReplayBufferDiagnostics {
            await deferredReplayBuffer.diagnosticsSnapshot()
        }
    #endif

    package func refreshFileSystemSettings(
        rootID: UUID,
        respectGitignore: Bool,
        respectRepoIgnore: Bool,
        respectCursorignore: Bool,
        skipSymlinks: Bool,
        enableHierarchicalIgnores: Bool
    ) async throws -> Bool {
        let state = try state(for: rootID)
        try await state.service.updateRespectGitignore(respectGitignore)
        try await state.service.updateRespectRepoIgnore(respectRepoIgnore)
        try await state.service.updateRespectCursorignore(respectCursorignore)
        await state.service.updateSkipSymlinks(skipSymlinks)
        await state.service.updateEnableHierarchicalIgnores(enableHierarchicalIgnores)
        try await state.service.refreshIgnoreRules()
        return await state.service.takePendingIgnoreRulesChange() != nil
    }

    package func allCodemapSnapshots() -> [WorkspaceCodemapSnapshot] {
        codemapSnapshotsByFileID.values
            .filter { isDiscoverableFileID($0.fileID) }
            .sorted { $0.fullPath < $1.fullPath }
    }

    package func allCodemapFileAPIs() -> [FileAPI] {
        codemapFileAPIAggregate().orderedFileAPIs
    }

    package func codemapFileAPIAggregate() -> WorkspaceCodemapFileAPIAggregate {
        let actorBodyTotal = WorkspaceRuntimePerf.begin(WorkspaceRuntimePerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.actorBodyTotal)
        defer { WorkspaceRuntimePerf.end(WorkspaceRuntimePerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.actorBodyTotal, actorBodyTotal) }

        if let cachedCodemapFileAPIAggregate {
            return cachedCodemapFileAPIAggregate
        }

        #if DEBUG || EDIT_FLOW_PERF
            let stateSnapshot = WorkspaceRuntimePerf.begin(WorkspaceRuntimePerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.stateSnapshot)
            let discoverableSnapshots = codemapSnapshotsByFileID.values
                .filter { isDiscoverableFileID($0.fileID) }
            WorkspaceRuntimePerf.end(WorkspaceRuntimePerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.stateSnapshot, stateSnapshot)

            let materialization = WorkspaceRuntimePerf.begin(WorkspaceRuntimePerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.materialization)
            let APIs = discoverableSnapshots
                .sorted { $0.fullPath < $1.fullPath }
                .compactMap(\.fileAPI)
        #else
            let APIs = allCodemapSnapshots().compactMap(\.fileAPI)
        #endif
        var firstFileAPIByStandardizedNestedPath: [String: FileAPI] = [:]
        firstFileAPIByStandardizedNestedPath.reserveCapacity(APIs.count)
        for api in APIs {
            let standardizedNestedPath = StandardizedPath.absolute(api.filePath)
            if firstFileAPIByStandardizedNestedPath[standardizedNestedPath] == nil {
                firstFileAPIByStandardizedNestedPath[standardizedNestedPath] = api
            }
        }
        let aggregate = WorkspaceCodemapFileAPIAggregate(
            orderedFileAPIs: APIs,
            firstFileAPIByStandardizedNestedPath: firstFileAPIByStandardizedNestedPath
        )
        #if DEBUG || EDIT_FLOW_PERF
            WorkspaceRuntimePerf.end(WorkspaceRuntimePerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.materialization, materialization)
        #endif
        cachedCodemapFileAPIAggregate = aggregate
        return aggregate
    }

    package func codemapSnapshotDictionary() -> [UUID: WorkspaceCodemapSnapshot] {
        codemapSnapshotsByFileID.filter { isDiscoverableFileID($0.key) }
    }

    package func codemapSnapshots(inRoot rootID: UUID) -> [WorkspaceCodemapSnapshot] {
        guard let fileIDs = codemapFileIDsByRootID[rootID] else { return [] }
        return fileIDs
            .filter(isDiscoverableFileID)
            .compactMap { codemapSnapshotsByFileID[$0] }
            .sorted { $0.relativePath < $1.relativePath }
    }

    package func codemapSnapshot(fileID: UUID) -> WorkspaceCodemapSnapshot? {
        guard isDiscoverableFileID(fileID) else { return nil }
        return codemapSnapshotsByFileID[fileID]
    }

    package func codemapSnapshot(rootID: UUID, relativePath: String) -> WorkspaceCodemapSnapshot? {
        guard let file = file(rootID: rootID, relativePath: relativePath), isDiscoverableFileID(file.id) else { return nil }
        return codemapSnapshotsByFileID[file.id]
    }

    @discardableResult
    package func applyObservedCodemapResults(_ results: [WorkspaceObservedCodemapResult]) -> [String] {
        var snapshotsByRootID: [UUID: [WorkspaceCodemapSnapshot]] = [:]
        var droppedPaths: [String] = []
        for result in results {
            guard let fileID = fileIDsByStandardizedFullPath[result.fullPath],
                  isDiscoverableFileID(fileID),
                  let file = filesByID[fileID],
                  let state = rootStatesByID[file.rootID]
            else {
                droppedPaths.append(result.fullPath)
                continue
            }

            let snapshot = WorkspaceCodemapSnapshot(
                fileID: file.id,
                rootID: file.rootID,
                rootPath: state.root.standardizedFullPath,
                relativePath: file.standardizedRelativePath,
                fullPath: file.standardizedFullPath,
                modificationDate: result.modificationDate,
                fileAPI: result.fileAPI
            )
            codemapSnapshotsByFileID[file.id] = snapshot
            codemapFileIDsByRootID[file.rootID, default: []].insert(file.id)
            snapshotsByRootID[file.rootID, default: []].append(snapshot)
        }
        if !snapshotsByRootID.isEmpty {
            invalidateAllCodemapFileAPIsCache()
        }

        for (rootID, snapshots) in snapshotsByRootID {
            guard let root = rootStatesByID[rootID]?.root else { continue }
            yieldCodemapUpdate(WorkspaceCodemapUpdateEvent(
                rootID: rootID,
                rootPath: root.standardizedFullPath,
                snapshots: snapshots.sorted { $0.relativePath < $1.relativePath }
            ))
        }
        return Array(Set(droppedPaths)).sorted()
    }

    package func ensureIndexedFiles(paths: [String]) async -> [String] {
        var indexed: [String] = []
        var upsertedFilesByRoot: [UUID: [WorkspaceFileRecord]] = [:]
        for rawPath in paths {
            let fullPath = StandardizedPath.absolute(rawPath)
            guard fileIDsByStandardizedFullPath[fullPath] == nil,
                  let root = loadedRoot(containing: fullPath),
                  let service = rootStatesByID[root.id]?.service
            else { continue }
            let originalRootID = root.id
            let originalRootPath = root.standardizedFullPath
            let relativePath = relativePath(for: fullPath, rootPath: originalRootPath)
            guard !relativePath.isEmpty,
                  await service.catalogEligibleRegularFileExists(relativePath: relativePath)
            else { continue }
            #if DEBUG
                if let ensureIndexedFilesEligibilityDidResolveHandler {
                    await ensureIndexedFilesEligibilityDidResolveHandler(originalRootID, fullPath)
                }
            #endif
            guard fileIDsByStandardizedFullPath[fullPath] == nil,
                  folderIDsByStandardizedFullPath[fullPath] == nil,
                  var state = rootStatesByID[originalRootID],
                  state.root.id == originalRootID,
                  state.root.standardizedFullPath == originalRootPath,
                  rootIDsByStandardizedPath[originalRootPath] == originalRootID,
                  loadedRoot(containing: fullPath)?.id == originalRootID,
                  state.fileIDsByRelativePath[relativePath] == nil,
                  state.folderIDsByRelativePath[relativePath] == nil
            else { continue }
            var indexes = RootIndexBuffers()
            let hierarchy = relativePath.split(separator: "/").count
            indexFiles(
                [FSItemDTO(relativePath: relativePath, isDirectory: false, hierarchy: hierarchy)],
                root: state.root,
                state: &state,
                indexes: &indexes
            )
            guard !indexes.filesByID.isEmpty else { continue }
            commit(indexes)
            rootStatesByID[originalRootID] = state
            clearSearchCatalogSnapshotCache()
            indexed.append(fullPath)
            upsertedFilesByRoot[originalRootID, default: []].append(contentsOf: indexes.filesByID.values)
        }
        if !indexed.isEmpty {
            let affectedKinds = Set(upsertedFilesByRoot.keys.compactMap { rootStatesByID[$0]?.root.kind })
            invalidatePathMatchSnapshot(affectedRootKinds: affectedKinds)
            for (rootID, files) in upsertedFilesByRoot {
                guard let root = rootStatesByID[rootID]?.root else { continue }
                publishAppliedIndexEvent(root: root, upsertedFiles: files)
            }
        }
        return indexed
    }

    private func loadedRoot(containing fullPath: String) -> WorkspaceRootRecord? {
        rootStatesByID.values
            .map(\.root)
            .filter { fullPath == $0.standardizedFullPath || fullPath.hasPrefix($0.standardizedFullPath + "/") }
            .max { $0.standardizedFullPath.count < $1.standardizedFullPath.count }
    }

    private func relativePath(for fullPath: String, rootPath: String) -> String {
        guard fullPath != rootPath else { return "" }
        let start = fullPath.index(fullPath.startIndex, offsetBy: rootPath.count)
        let suffix = fullPath[start...]
        return StandardizedPath.relative(String(suffix).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    package func makeFileTreeSelectionSnapshot(_ request: WorkspaceFileTreeSnapshotRequest) -> FileTreeSelectionSnapshot {
        makeFileTreeSelectionSnapshot(request, selectedStoreFileIDs: request.selectedFileIDs)
    }

    package func makeFileTreeSelectionSnapshot(
        selection: StoredSelection,
        request: WorkspaceFileTreeSnapshotRequest,
        profile: PathLocateProfile = .uiAssisted
    ) async -> FileTreeSelectionSnapshot {
        var selectedStoreFileIDs = Set<UUID>()
        for path in selection.selectedPaths {
            guard let result = await lookupSelectionPath(path, profile: profile, rootScope: request.rootScope) else { continue }
            if let file = result.file {
                selectedStoreFileIDs.insert(file.id)
            }
            if let folder = result.folder,
               let state = rootStatesByID[folder.rootID]
            {
                selectedStoreFileIDs.formUnion(descendantFileIDs(in: folder.id, state: state))
            }
        }
        for (path, _) in selection.slices {
            guard let result = await lookupSelectionPath(path, profile: profile, rootScope: request.rootScope),
                  let file = result.file
            else { continue }
            selectedStoreFileIDs.insert(file.id)
        }
        return await makeFileTreeSelectionSnapshot(request, selectedStoreFileIDs: selectedStoreFileIDs, profile: profile)
    }

    private func lookupSelectionPath(
        _ userPath: String,
        profile: PathLocateProfile,
        rootScope: WorkspaceLookupRootScope
    ) async -> WorkspacePathLookupResult? {
        switch lookupCatalogFileForExplicitRequest(userPath, rootScope: rootScope) {
        case let .matched(file):
            return lookupPath(rootID: file.rootID, relativePath: file.standardizedRelativePath)
        case .ambiguous, .blocked:
            return nil
        case .noCandidate:
            break
        }
        switch try? await materializeExplicitlyRequestedFile(userPath, rootScope: rootScope) {
        case let .some(.materialized(file)):
            return lookupPath(rootID: file.rootID, relativePath: file.standardizedRelativePath)
        case .some(.ambiguous), .some(.blocked):
            return nil
        case .some(.noCandidate), .none:
            break
        }
        if let direct = directAbsoluteLookup(userPath, rootScope: rootScope), isDiscoverableLookupResult(direct) {
            return direct
        }
        if let direct = directUnambiguousRelativeLookup(userPath, rootScope: rootScope), isDiscoverableLookupResult(direct) {
            return direct
        }
        return await lookupPath(userPath, profile: profile, rootScope: rootScope)
    }

    private func directAbsoluteLookup(_ userPath: String, rootScope: WorkspaceLookupRootScope) -> WorkspacePathLookupResult? {
        let expanded = (userPath as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        let standardizedPath = StandardizedPath.absolute(expanded)
        guard let root = rootsForPathLookup(scope: rootScope)
            .filter({ candidate in
                standardizedPath == candidate.standardizedFullPath
                    || standardizedPath.hasPrefix(candidate.standardizedFullPath + "/")
            })
            .max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count })
        else { return nil }
        let relativePath = relativePath(for: standardizedPath, rootPath: root.standardizedFullPath)
        return lookupPath(rootID: root.id, relativePath: relativePath)
    }

    private func directUnambiguousRelativeLookup(_ userPath: String, rootScope: WorkspaceLookupRootScope) -> WorkspacePathLookupResult? {
        let expanded = (userPath as NSString).expandingTildeInPath
        guard !expanded.hasPrefix("/") else { return nil }
        let relativePath = StandardizedPath.relative(expanded)
        guard !relativePath.isEmpty else { return nil }
        let matches = rootsForPathLookup(scope: rootScope).compactMap { root in
            lookupPath(rootID: root.id, relativePath: relativePath)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func isDiscoverableLookupResult(_ result: WorkspacePathLookupResult) -> Bool {
        if let file = result.file, !isDiscoverableFileID(file.id) { return false }
        if let folder = result.folder, !isDiscoverableFolderID(folder.id) { return false }
        return true
    }

    private func descendantFileIDs(in folderID: UUID, state: RootState) -> Set<UUID> {
        var fileIDs = Set((state.childFileIDsByFolderID[folderID] ?? []).filter(isDiscoverableFileID))
        for childFolderID in (state.childFolderIDsByFolderID[folderID] ?? []).filter(isDiscoverableFolderID) {
            fileIDs.formUnion(descendantFileIDs(in: childFolderID, state: state))
        }
        return fileIDs
    }

    private func makeFileTreeSelectionSnapshot(
        _ request: WorkspaceFileTreeSnapshotRequest,
        selectedStoreFileIDs: Set<UUID>
    ) -> FileTreeSelectionSnapshot {
        makeFileTreeSelectionSnapshot(
            request,
            selectedStoreFileIDs: selectedStoreFileIDs,
            startFolder: nil
        )
    }

    private func makeFileTreeSelectionSnapshot(
        _ request: WorkspaceFileTreeSnapshotRequest,
        selectedStoreFileIDs: Set<UUID>,
        profile: PathLocateProfile
    ) async -> FileTreeSelectionSnapshot {
        let trimmedStartPath = request.startPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedStartPath, !trimmedStartPath.isEmpty else {
            return makeFileTreeSelectionSnapshot(request, selectedStoreFileIDs: selectedStoreFileIDs, startFolder: nil)
        }
        let startFolder = await (lookupSelectionPath(trimmedStartPath, profile: profile, rootScope: request.rootScope))?.folder
        return makeFileTreeSelectionSnapshot(request, selectedStoreFileIDs: selectedStoreFileIDs, startFolder: startFolder)
    }

    private func makeFileTreeSelectionSnapshot(
        _ request: WorkspaceFileTreeSnapshotRequest,
        selectedStoreFileIDs: Set<UUID>,
        startFolder: WorkspaceFolderRecord?
    ) -> FileTreeSelectionSnapshot {
        let selectedFileIDs = selectedStoreFileIDs
        let explicitlyIncludedManagedOnlyFileIDs = request.mode == .selected
            ? Set(selectedFileIDs.filter { managedOnlyFileIDs.contains($0) })
            : []
        let explicitlyIncludedManagedOnlyFolderIDs = managedOnlyAncestorFolderIDs(for: explicitlyIncludedManagedOnlyFileIDs)
        let roots: [FileTreeFolderSnapshot]
        if let startFolder,
           let state = rootStatesByID[startFolder.rootID],
           let root = rootStatesByID[startFolder.rootID]?.root
        {
            var visited = Set<UUID>()
            roots = makeFileTreeFolderSnapshot(
                startFolder,
                rootStandardizedPath: root.standardizedFullPath,
                state: state,
                visited: &visited,
                explicitlyIncludedManagedOnlyFileIDs: explicitlyIncludedManagedOnlyFileIDs,
                explicitlyIncludedManagedOnlyFolderIDs: explicitlyIncludedManagedOnlyFolderIDs
            ).map { [$0] } ?? []
        } else if request.startPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            roots = []
        } else {
            roots = rootsForPathLookup(scope: request.rootScope).compactMap { root -> FileTreeFolderSnapshot? in
                guard let state = rootStatesByID[root.id],
                      let rootFolderID = state.folderIDsByRelativePath[""],
                      let rootFolder = foldersByID[rootFolderID]
                else { return nil }
                var visited = Set<UUID>()
                return makeFileTreeFolderSnapshot(
                    rootFolder,
                    rootStandardizedPath: root.standardizedFullPath,
                    state: state,
                    visited: &visited,
                    explicitlyIncludedManagedOnlyFileIDs: explicitlyIncludedManagedOnlyFileIDs,
                    explicitlyIncludedManagedOnlyFolderIDs: explicitlyIncludedManagedOnlyFolderIDs
                )
            }
        }

        return FileTreeSelectionSnapshot(
            roots: roots,
            selectedFileIDs: selectedFileIDs,
            mode: request.mode.rawValue,
            showFullPaths: request.filePathDisplay == .full,
            onlyIncludeRootsWithSelectedFiles: request.onlyIncludeRootsWithSelectedFiles,
            includeLegend: request.includeLegend,
            showCodeMapMarkers: request.showCodeMapMarkers,
            maxDepth: request.maxDepth
        )
    }

    package func codemapUpdates() -> AsyncStream<WorkspaceCodemapUpdateEvent> {
        ensureCodeScanResultTask()
        let id = UUID()
        return AsyncStream { continuation in
            codemapUpdateContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeCodemapUpdateContinuation(id) }
            }
        }
    }

    package func codemapScanProgressUpdates() -> AsyncStream<(Int, Int)> {
        codeScanActor.subscribeToProgress()
    }

    package func cancelAllCodemapScans() async {
        await codeScanActor.cancelAllScans()
    }

    package func clearAllCodemapCaches(rootFolders: [String]) async {
        await codeScanActor.clearAllCaches(rootFolders: rootFolders)
        removeAllCodemapSnapshots()
    }

    package func purgeStaleCodemapCaches(keepingRootPaths: [String]) async {
        await codeScanActor.purgeStaleRootCaches(keepingRootPaths: keepingRootPaths)
    }

    #if DEBUG
        package func codemapMemoryCounters() async -> CodeScanActor.CodemapMemoryCounters {
            await codeScanActor.codemapMemoryCounters()
        }
    #endif

    private func removeCodemapUpdateContinuation(_ id: UUID) {
        codemapUpdateContinuations.removeValue(forKey: id)
    }

    @discardableResult
    package func loadRoot(
        path: String,
        isSystemRoot: Bool = false,
        kind: WorkspaceRootKind? = nil,
        respectGitignore: Bool = true,
        respectRepoIgnore: Bool = true,
        respectCursorignore: Bool = true,
        skipSymlinks: Bool = true,
        enableHierarchicalIgnores: Bool = true,
        cancelUnderlyingLoadOnCallerCancellation: Bool = false
    ) async throws -> WorkspaceRootRecord {
        let standardizedPath = (path as NSString).standardizingPath
        #if DEBUG
            let rootLoadRouteStartMS = WorkspaceRuntimeDebugLog.timestampMSIfEnabled()
            let rootLoadName = URL(fileURLWithPath: standardizedPath).lastPathComponent
        #endif
        try Task.checkCancellation()
        try await waitForRootUnloadIfNeeded(standardizedPath: standardizedPath)
        try Task.checkCancellation()
        let loadConfiguration = RootLoadConfiguration(
            kind: kind ?? (isSystemRoot ? .supplementalSystem : .primaryWorkspace),
            respectGitignore: respectGitignore,
            respectRepoIgnore: respectRepoIgnore,
            respectCursorignore: respectCursorignore,
            skipSymlinks: skipSymlinks,
            enableHierarchicalIgnores: enableHierarchicalIgnores
        )
        if let existingID = rootIDsByStandardizedPath[standardizedPath],
           let existing = rootStatesByID[existingID]?.root
        {
            guard let existingConfiguration = rootLoadConfigurationsByPath[standardizedPath], existingConfiguration == loadConfiguration else {
                throw WorkspaceFileContextStoreError.rootAlreadyLoadedWithDifferentConfiguration(standardizedPath)
            }
            #if DEBUG
                WorkspaceRuntimeDebugLog.event(
                    "store.rootLoad.existing",
                    fields: [
                        "rootName": rootLoadName,
                        "rootID": WorkspaceRuntimeDebugLog.shortID(existing.id),
                        "kind": "\(loadConfiguration.kind)",
                        "duration": rootLoadRouteStartMS.map { WorkspaceRuntimeDebugLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
            return existing
        }
        if let inFlight = rootLoadTasksByPath[standardizedPath] {
            guard rootLoadConfigurationsByPath[standardizedPath] == loadConfiguration else {
                throw WorkspaceFileContextStoreError.rootLoadInFlightWithDifferentConfiguration(standardizedPath)
            }
            #if DEBUG
                WorkspaceRuntimeDebugLog.event(
                    "store.rootLoad.joinInFlight",
                    fields: [
                        "rootName": rootLoadName,
                        "kind": "\(loadConfiguration.kind)"
                    ]
                )
                if let rootLoadDidJoinInFlightHandler {
                    await rootLoadDidJoinInFlightHandler(standardizedPath)
                }
            #endif
            return try await awaitRootLoadTask(
                inFlight,
                standardizedPath: standardizedPath,
                cancelUnderlyingLoadOnCallerCancellation: cancelUnderlyingLoadOnCallerCancellation
            )
        }

        #if DEBUG
            WorkspaceRuntimeDebugLog.event(
                "store.rootLoad.scheduled",
                fields: [
                    "rootName": rootLoadName,
                    "kind": "\(loadConfiguration.kind)"
                ]
            )
        #endif
        let task = Task { [weak self] in
            guard let self else { throw WorkspaceFileContextStoreError.storeDeallocated }
            return try await performLoadRoot(
                standardizedPath: standardizedPath,
                isSystemRoot: isSystemRoot,
                kind: kind,
                respectGitignore: respectGitignore,
                respectRepoIgnore: respectRepoIgnore,
                respectCursorignore: respectCursorignore,
                skipSymlinks: skipSymlinks,
                enableHierarchicalIgnores: enableHierarchicalIgnores
            )
        }
        rootLoadTasksByPath[standardizedPath] = task
        rootLoadConfigurationsByPath[standardizedPath] = loadConfiguration
        Task { [weak self] in
            _ = try? await task.value
            await self?.clearCompletedRootLoadTask(standardizedPath: standardizedPath)
        }
        return try await awaitRootLoadTask(
            task,
            standardizedPath: standardizedPath,
            cancelUnderlyingLoadOnCallerCancellation: cancelUnderlyingLoadOnCallerCancellation
        )
    }

    private func awaitRootLoadTask(
        _ task: Task<WorkspaceRootRecord, Error>,
        standardizedPath: String,
        cancelUnderlyingLoadOnCallerCancellation: Bool
    ) async throws -> WorkspaceRootRecord {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            guard cancelUnderlyingLoadOnCallerCancellation else { return }
            task.cancel()
            Task { await self.cancelRootLoad(path: standardizedPath) }
        }
    }

    package func cancelRootLoad(path: String) {
        let standardizedPath = (path as NSString).standardizingPath
        rootLoadTasksByPath[standardizedPath]?.cancel()
        rootLoadTasksByPath.removeValue(forKey: standardizedPath)
        if rootIDsByStandardizedPath[standardizedPath] == nil {
            rootLoadConfigurationsByPath.removeValue(forKey: standardizedPath)
        }
    }

    private func clearCompletedRootLoadTask(standardizedPath: String) {
        rootLoadTasksByPath.removeValue(forKey: standardizedPath)
        if rootIDsByStandardizedPath[standardizedPath] == nil {
            rootLoadConfigurationsByPath.removeValue(forKey: standardizedPath)
        }
    }

    private func performLoadRoot(
        standardizedPath: String,
        isSystemRoot: Bool,
        kind: WorkspaceRootKind?,
        respectGitignore: Bool,
        respectRepoIgnore: Bool,
        respectCursorignore: Bool,
        skipSymlinks: Bool,
        enableHierarchicalIgnores: Bool
    ) async throws -> WorkspaceRootRecord {
        if let existingID = rootIDsByStandardizedPath[standardizedPath],
           let existing = rootStatesByID[existingID]?.root
        {
            return existing
        }

        #if DEBUG
            if let rootLoadWillStartHandler {
                await rootLoadWillStartHandler(standardizedPath)
            }
        #endif

        let rootURL = URL(fileURLWithPath: standardizedPath).standardizedFileURL
        #if DEBUG
            let performLoadStartMS = WorkspaceRuntimeDebugLog.timestampMSIfEnabled()
            WorkspaceRuntimeDebugLog.event(
                "store.rootLoad.begin",
                fields: [
                    "rootName": rootURL.lastPathComponent,
                    "kind": "\(kind ?? (isSystemRoot ? .supplementalSystem : .primaryWorkspace))",
                    "isSystemRoot": "\(isSystemRoot)"
                ]
            )
        #endif
        let root = if let kind {
            WorkspaceRootRecord(name: rootURL.lastPathComponent, fullPath: rootURL.path, kind: kind)
        } else {
            WorkspaceRootRecord(name: rootURL.lastPathComponent, fullPath: rootURL.path, isSystemRoot: isSystemRoot)
        }
        let service = try await FileSystemService(
            path: root.fullPath,
            respectGitignore: respectGitignore,
            respectRepoIgnore: respectRepoIgnore,
            respectCursorignore: respectCursorignore,
            skipSymlinks: skipSymlinks,
            enableHierarchicalIgnores: enableHierarchicalIgnores,
            dependencies: runtimeDependencies
        )

        #if DEBUG
            var rootRecordCreatedFields: [String: String] = [
                "rootName": root.name,
                "rootID": WorkspaceRuntimeDebugLog.shortID(root.id),
                "kind": "\(root.kind)",
                "durationSinceStoreRootLoadBegin": performLoadStartMS.map { WorkspaceRuntimeDebugLog.formatElapsedMS(since: $0) } ?? "notMeasured"
            ]
            rootRecordCreatedFields.merge(
                WorkspaceRootLoadDiagnosticFields.rootRecordCreatedFields(forPath: standardizedPath),
                uniquingKeysWith: { _, diagnostic in diagnostic }
            )
            WorkspaceRuntimeDebugLog.event("store.rootLoad.rootRecordCreated", fields: rootRecordCreatedFields)
        #endif

        var state = RootState(
            root: root,
            service: service,
            folderIDsByRelativePath: [:],
            fileIDsByRelativePath: [:],
            childFolderIDsByFolderID: [:],
            childFileIDsByFolderID: [:]
        )

        var stagedIndexes = RootIndexBuffers()
        let rootFolder = WorkspaceFolderRecord(
            id: root.id,
            rootID: root.id,
            name: root.name,
            relativePath: "",
            fullPath: root.fullPath,
            parentFolderID: nil
        )
        stagedIndexes.foldersByID[rootFolder.id] = rootFolder
        stagedIndexes.folderIDsByStandardizedFullPath[rootFolder.standardizedFullPath] = rootFolder.id
        state.folderIDsByRelativePath[""] = rootFolder.id

        #if DEBUG
            let walkStartMS = WorkspaceRuntimeDebugLog.timestampMSIfEnabled()
            var chunkCount = 0
        #endif
        for try await event in await service.loadContentsInChunks(of: rootURL) {
            try Task.checkCancellation()
            guard case let .preparedItems(chunk) = event else { continue }
            #if DEBUG
                chunkCount += 1
                if chunkCount == 1 {
                    var firstChunkFields: [String: String] = [
                        "rootName": root.name,
                        "rootID": WorkspaceRuntimeDebugLog.shortID(root.id),
                        "chunkFolders": "\(chunk.folders.count)",
                        "chunkFiles": "\(chunk.files.count)",
                        "durationSinceStoreRootLoadBegin": performLoadStartMS.map { WorkspaceRuntimeDebugLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                    firstChunkFields.merge(
                        WorkspaceRootLoadDiagnosticFields.firstPreparedChunkFields(forPath: standardizedPath),
                        uniquingKeysWith: { _, diagnostic in diagnostic }
                    )
                    WorkspaceRuntimeDebugLog.event("store.rootLoad.firstPreparedChunk", fields: firstChunkFields)
                }
            #endif
            indexFolders(chunk.folders, root: root, state: &state, indexes: &stagedIndexes)
            indexFiles(chunk.files, root: root, state: &state, indexes: &stagedIndexes)
        }
        try Task.checkCancellation()
        #if DEBUG
            WorkspaceRuntimeDebugLog.event(
                "store.rootLoad.walk",
                fields: [
                    "rootName": root.name,
                    "chunkCount": "\(chunkCount)",
                    "folders": "\(stagedIndexes.foldersByID.count)",
                    "files": "\(stagedIndexes.filesByID.count)",
                    "duration": walkStartMS.map { WorkspaceRuntimeDebugLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
            let commitStartMS = WorkspaceRuntimeDebugLog.timestampMSIfEnabled()
        #endif

        commit(stagedIndexes)
        #if DEBUG
            WorkspaceRuntimeDebugLog.event(
                "store.rootLoad.commit",
                fields: [
                    "rootName": root.name,
                    "folders": "\(stagedIndexes.foldersByID.count)",
                    "files": "\(stagedIndexes.filesByID.count)",
                    "duration": commitStartMS.map { WorkspaceRuntimeDebugLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
        rootIDsByStandardizedPath[root.standardizedFullPath] = root.id
        rootStatesByID[root.id] = state
        rootLoadOrder.append(root.id)
        appliedIndexGenerationsByRootID[root.id] = 0
        invalidatePathMatchSnapshot(affectedRootKinds: [root.kind])
        #if DEBUG
            WorkspaceRuntimeDebugLog.event(
                "store.rootLoad.end",
                fields: [
                    "rootName": root.name,
                    "rootID": WorkspaceRuntimeDebugLog.shortID(root.id),
                    "folders": "\(stagedIndexes.foldersByID.count)",
                    "files": "\(stagedIndexes.filesByID.count)",
                    "duration": performLoadStartMS.map { WorkspaceRuntimeDebugLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
        return root
    }

    private func waitForRootUnloadIfNeeded(standardizedPath: String) async throws {
        try Task.checkCancellation()
        while unloadingRootPaths.contains(standardizedPath) {
            let waiterID = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    unloadWaitersByRootPath[standardizedPath, default: [:]][waiterID] = continuation
                }
            } onCancel: {
                Task { await self.cancelRootUnloadWaiter(standardizedPath: standardizedPath, waiterID: waiterID) }
            }
            try Task.checkCancellation()
        }
    }

    private func cancelRootUnloadWaiter(standardizedPath: String, waiterID: UUID) {
        guard let waiter = unloadWaitersByRootPath[standardizedPath]?.removeValue(forKey: waiterID) else { return }
        if unloadWaitersByRootPath[standardizedPath]?.isEmpty == true {
            unloadWaitersByRootPath.removeValue(forKey: standardizedPath)
        }
        waiter.resume(throwing: CancellationError())
    }

    private func finishRootUnload(for standardizedPaths: [String]) {
        for path in standardizedPaths {
            unloadingRootPaths.remove(path)
            let waiters = unloadWaitersByRootPath.removeValue(forKey: path) ?? [:]
            for waiter in waiters.values {
                waiter.resume()
            }
        }
    }

    package func unloadRoot(id rootID: UUID) async {
        await unloadRoots(ids: [rootID])
    }

    package func unloadRoots(ids rootIDs: [UUID]) async {
        var seenRootIDs = Set<UUID>()
        let orderedRootIDs = rootIDs.filter { seenRootIDs.insert($0).inserted }
        guard !orderedRootIDs.isEmpty else { return }

        var statesToUnload: [(rootID: UUID, state: RootState)] = []
        for rootID in orderedRootIDs {
            guard let state = rootStatesByID.removeValue(forKey: rootID) else { continue }
            statesToUnload.append((rootID, state))
        }
        guard !statesToUnload.isEmpty else { return }
        let removedRootIDSet = Set(statesToUnload.map(\.rootID))
        rootLoadOrder.removeAll { removedRootIDSet.contains($0) }
        for entry in statesToUnload {
            rootIDsByStandardizedPath.removeValue(forKey: entry.state.root.standardizedFullPath)
            rootLoadConfigurationsByPath.removeValue(forKey: entry.state.root.standardizedFullPath)
        }
        clearSearchCatalogSnapshotCache()
        #if DEBUG
            let rootUnloadStartMS = WorkspaceRuntimeDebugLog.timestampMSIfEnabled()
            let rootUnloadFolderCount = statesToUnload.reduce(0) { $0 + $1.state.folderIDsByRelativePath.count }
            let rootUnloadFileCount = statesToUnload.reduce(0) { $0 + $1.state.fileIDsByRelativePath.count }
            WorkspaceRuntimeDebugLog.event(
                "store.rootUnload.begin",
                fields: [
                    "rootCount": "\(statesToUnload.count)",
                    "folderCount": "\(rootUnloadFolderCount)",
                    "fileCount": "\(rootUnloadFileCount)"
                ]
            )
            let detachStartMS = WorkspaceRuntimeDebugLog.timestampMSIfEnabled()
        #endif

        let unloadingPaths = statesToUnload.map(\.state.root.standardizedFullPath)
        for path in unloadingPaths {
            unloadingRootPaths.insert(path)
        }
        #if DEBUG
            if let rootUnloadDidDetachHandler {
                await rootUnloadDidDetachHandler(unloadingPaths)
            }
        #endif

        #if DEBUG
            WorkspaceRuntimeDebugLog.event(
                "store.rootUnload.detach",
                fields: [
                    "rootCount": "\(statesToUnload.count)",
                    "duration": detachStartMS.map { WorkspaceRuntimeDebugLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
            let stopWatchersStartMS = WorkspaceRuntimeDebugLog.timestampMSIfEnabled()
        #endif

        // Stop watchers after the roots have been detached from actor lookup tables.
        // This keeps stale ingress from resolving against roots being unloaded while
        // preserving the existing awaited teardown semantics.
        for entry in statesToUnload {
            #if DEBUG
                let stopWatcherRootStartMS = WorkspaceRuntimeDebugLog.timestampMSIfEnabled()
            #endif
            await stopWatchingRoot(id: entry.rootID, service: entry.state.service)
            #if DEBUG
                WorkspaceRuntimeDebugLog.event(
                    "store.rootUnload.stopWatcherRoot",
                    fields: [
                        "rootName": entry.state.root.name,
                        "rootID": WorkspaceRuntimeDebugLog.shortID(entry.rootID),
                        "duration": stopWatcherRootStartMS.map { WorkspaceRuntimeDebugLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                )
            #endif
        }
        #if DEBUG
            WorkspaceRuntimeDebugLog.event(
                "store.rootUnload.stopWatchers",
                fields: [
                    "rootCount": "\(statesToUnload.count)",
                    "duration": stopWatchersStartMS.map { WorkspaceRuntimeDebugLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
            let indexCleanupStartMS = WorkspaceRuntimeDebugLog.timestampMSIfEnabled()
        #endif

        var rootPathsToUnload: [String] = []
        for entry in statesToUnload {
            let rootID = entry.rootID
            let state = entry.state
            let discoverableFolderIDsByPath = state.folderIDsByRelativePath.filter { isDiscoverableFolderID($0.value) }
            let discoverableFileIDsByPath = state.fileIDsByRelativePath.filter { isDiscoverableFileID($0.value) }
            rootPathsToUnload.append(state.root.standardizedFullPath)
            for folderID in state.folderIDsByRelativePath.values {
                managedOnlyFolderIDs.remove(folderID)
                if let folder = foldersByID.removeValue(forKey: folderID),
                   folderIDsByStandardizedFullPath[folder.standardizedFullPath] == folderID
                {
                    folderIDsByStandardizedFullPath.removeValue(forKey: folder.standardizedFullPath)
                }
            }
            for fileID in state.fileIDsByRelativePath.values {
                managedOnlyFileIDs.remove(fileID)
                if let file = filesByID.removeValue(forKey: fileID),
                   fileIDsByStandardizedFullPath[file.standardizedFullPath] == fileID
                {
                    fileIDsByStandardizedFullPath.removeValue(forKey: file.standardizedFullPath)
                }
            }
            let removedFileIDs = removeCodemapSnapshots(forRootID: rootID)
            yieldCodemapRemoval(root: state.root, removedFileIDs: removedFileIDs, isRootUnload: true)
            let generation = nextAppliedIndexGeneration(forRootID: rootID)
            yieldAppliedIndexEvent(WorkspaceAppliedIndexBatchEvent(
                rootID: rootID,
                rootPath: state.root.standardizedFullPath,
                generation: generation,
                removedFileIDs: Array(discoverableFileIDsByPath.values),
                removedFolderIDs: Array(discoverableFolderIDsByPath.values),
                removedFilePaths: Array(discoverableFileIDsByPath.keys).sorted(),
                removedFolderPaths: Array(discoverableFolderIDsByPath.keys).sorted(),
                requiresFullResync: true,
                isRootUnload: true
            ))
            appliedIndexGenerationsByRootID.removeValue(forKey: rootID)
        }

        let unloadedRootKinds = Set(statesToUnload.map(\.state.root.kind))
        invalidatePathMatchSnapshot(affectedRootKinds: unloadedRootKinds)
        #if DEBUG
            WorkspaceRuntimeDebugLog.event(
                "store.rootUnload.indexCleanup",
                fields: [
                    "rootCount": "\(statesToUnload.count)",
                    "removedFolders": "\(rootUnloadFolderCount)",
                    "removedFiles": "\(rootUnloadFileCount)",
                    "duration": indexCleanupStartMS.map { WorkspaceRuntimeDebugLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
            let codeScanCancelStartMS = WorkspaceRuntimeDebugLog.timestampMSIfEnabled()
        #endif
        await codeScanActor.cancelAndUnloadScans(forRootFolders: rootPathsToUnload)
        #if DEBUG
            WorkspaceRuntimeDebugLog.event(
                "store.rootUnload.codeScanCancel",
                fields: [
                    "rootCount": "\(statesToUnload.count)",
                    "duration": codeScanCancelStartMS.map { WorkspaceRuntimeDebugLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
        invalidatePathMatchCache()
        finishRootUnload(for: unloadingPaths)
        #if DEBUG
            WorkspaceRuntimeDebugLog.event(
                "store.rootUnload.end",
                fields: [
                    "rootCount": "\(statesToUnload.count)",
                    "duration": rootUnloadStartMS.map { WorkspaceRuntimeDebugLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
    }

    package func file(rootID: UUID, relativePath: String) -> WorkspaceFileRecord? {
        guard let state = rootStatesByID[rootID] else { return nil }
        let key = StandardizedPath.relative(relativePath)
        guard let fileID = state.fileIDsByRelativePath[key] else { return nil }
        return filesByID[fileID]
    }

    package func folder(rootID: UUID, relativePath: String) -> WorkspaceFolderRecord? {
        guard let state = rootStatesByID[rootID] else { return nil }
        let key = StandardizedPath.relative(relativePath)
        guard let folderID = state.folderIDsByRelativePath[key] else { return nil }
        return foldersByID[folderID]
    }

    package func readContent(
        rootID: UUID,
        relativePath: String,
        workloadClass: ContentReadWorkloadClass = .unspecified
    ) async throws -> String? {
        let state = try state(for: rootID)
        let lifecycleCorrelation = WorkspaceRuntimePerf.currentLifecycleCorrelation
        WorkspaceRuntimePerf.lifecycleEvent(
            WorkspaceRuntimePerf.Lifecycle.ReadFile.storeReadContentEntered,
            correlation: lifecycleCorrelation,
            WorkspaceRuntimePerf.Dimensions(
                workloadClass: workloadClass.rawValue,
                rootToken: state.service.diagnosticRootToken.uuidString
            )
        )
        let forwardState = WorkspaceRuntimePerf.begin(
            WorkspaceRuntimePerf.Stage.ReadFile.storeReadContentForwardAwait,
            WorkspaceRuntimePerf.Dimensions(workloadClass: workloadClass.rawValue)
        )
        do {
            let content = try await state.service.loadContent(
                ofRelativePath: StandardizedPath.relative(relativePath),
                workloadClass: workloadClass
            )
            WorkspaceRuntimePerf.end(
                WorkspaceRuntimePerf.Stage.ReadFile.storeReadContentForwardAwait,
                forwardState,
                WorkspaceRuntimePerf.Dimensions(outcome: "returned", workloadClass: workloadClass.rawValue)
            )
            WorkspaceRuntimePerf.lifecycleEvent(
                WorkspaceRuntimePerf.Lifecycle.ReadFile.storeReadContentReturned,
                correlation: lifecycleCorrelation,
                WorkspaceRuntimePerf.Dimensions(
                    outcome: "returned",
                    workloadClass: workloadClass.rawValue,
                    rootToken: state.service.diagnosticRootToken.uuidString
                )
            )
            return content
        } catch {
            WorkspaceRuntimePerf.end(
                WorkspaceRuntimePerf.Stage.ReadFile.storeReadContentForwardAwait,
                forwardState,
                WorkspaceRuntimePerf.Dimensions(outcome: error is CancellationError ? "cancelled" : "error", workloadClass: workloadClass.rawValue)
            )
            WorkspaceRuntimePerf.lifecycleEvent(
                WorkspaceRuntimePerf.Lifecycle.ReadFile.storeReadContentReturned,
                correlation: lifecycleCorrelation,
                WorkspaceRuntimePerf.Dimensions(
                    outcome: error is CancellationError ? "cancelled" : "error",
                    workloadClass: workloadClass.rawValue,
                    rootToken: state.service.diagnosticRootToken.uuidString
                )
            )
            throw error
        }
    }

    package func readContentWithDate(
        rootID: UUID,
        relativePath: String,
        workloadClass: ContentReadWorkloadClass = .unspecified
    ) async throws -> (content: String?, modificationDate: Date) {
        let state = try state(for: rootID)
        let lifecycleCorrelation = WorkspaceRuntimePerf.currentLifecycleCorrelation
        WorkspaceRuntimePerf.lifecycleEvent(
            WorkspaceRuntimePerf.Lifecycle.ReadFile.storeReadContentEntered,
            correlation: lifecycleCorrelation,
            WorkspaceRuntimePerf.Dimensions(
                workloadClass: workloadClass.rawValue,
                rootToken: state.service.diagnosticRootToken.uuidString
            )
        )
        let forwardState = WorkspaceRuntimePerf.begin(
            WorkspaceRuntimePerf.Stage.ReadFile.storeReadContentForwardAwait,
            WorkspaceRuntimePerf.Dimensions(workloadClass: workloadClass.rawValue)
        )
        do {
            let loaded = try await state.service.loadContentWithDate(
                ofRelativePath: StandardizedPath.relative(relativePath),
                workloadClass: workloadClass
            )
            WorkspaceRuntimePerf.end(
                WorkspaceRuntimePerf.Stage.ReadFile.storeReadContentForwardAwait,
                forwardState,
                WorkspaceRuntimePerf.Dimensions(outcome: "returned", workloadClass: workloadClass.rawValue)
            )
            WorkspaceRuntimePerf.lifecycleEvent(
                WorkspaceRuntimePerf.Lifecycle.ReadFile.storeReadContentReturned,
                correlation: lifecycleCorrelation,
                WorkspaceRuntimePerf.Dimensions(
                    outcome: "returned",
                    workloadClass: workloadClass.rawValue,
                    rootToken: state.service.diagnosticRootToken.uuidString
                )
            )
            return loaded
        } catch {
            WorkspaceRuntimePerf.end(
                WorkspaceRuntimePerf.Stage.ReadFile.storeReadContentForwardAwait,
                forwardState,
                WorkspaceRuntimePerf.Dimensions(outcome: error is CancellationError ? "cancelled" : "error", workloadClass: workloadClass.rawValue)
            )
            WorkspaceRuntimePerf.lifecycleEvent(
                WorkspaceRuntimePerf.Lifecycle.ReadFile.storeReadContentReturned,
                correlation: lifecycleCorrelation,
                WorkspaceRuntimePerf.Dimensions(
                    outcome: error is CancellationError ? "cancelled" : "error",
                    workloadClass: workloadClass.rawValue,
                    rootToken: state.service.diagnosticRootToken.uuidString
                )
            )
            throw error
        }
    }

    package func fileExistsOnDisk(rootID: UUID, relativePath: String) async throws -> Bool {
        let state = try state(for: rootID)
        return await state.service.fileExistsOnDisk(relativePath: StandardizedPath.relative(relativePath))
    }

    package func fileModificationDate(rootID: UUID, relativePath: String) async throws -> Date {
        let state = try state(for: rootID)
        return try await state.service.getFileModificationDate(atRelativePath: StandardizedPath.relative(relativePath))
    }

    package func itemModificationDateIfAvailable(rootID: UUID, relativePath: String) async throws -> Date? {
        let state = try state(for: rootID)
        return await state.service.getItemModificationDateIfAvailable(atRelativePath: StandardizedPath.relative(relativePath))
    }

    package func refreshIgnoreRules(rootID: UUID) async throws {
        let state = try state(for: rootID)
        try await state.service.refreshIgnoreRules()
    }

    package func fullPath(rootID: UUID, relativePath: String) async -> String? {
        guard let state = rootStatesByID[rootID] else { return nil }
        return await state.service.fullPath(forRelativePath: StandardizedPath.relative(relativePath))
    }

    package func requestCodemapScan(fileID: UUID) async throws {
        guard let file = filesByID[fileID] else { return }
        try await requestCodemapScans(for: [file])
    }

    package func requestCodemapScan(rootID: UUID, relativePath: String) async throws {
        guard let file = file(rootID: rootID, relativePath: relativePath) else { return }
        try await requestCodemapScans(for: [file])
    }

    package func requestCodemapScans(inRoot rootID: UUID) async throws {
        try await requestCodemapScans(for: files(inRoot: rootID))
    }

    package func requestCodemapScansForAllRoots() async throws {
        try await requestCodemapScans(for: rootLoadOrder.flatMap { files(inRoot: $0) })
    }

    package func requestInitialRootCodemapScans(
        rootFolderPaths: [String],
        purgeCachesOnEmptyInitialRequests: Bool = false
    ) async throws {
        ensureCodeScanResultTask()
        #if DEBUG
            let collectFilesStartMS = WorkspaceRuntimeDebugLog.timestampMSIfEnabled()
        #endif
        let standardizedRootPaths = rootFolderPaths.map { ($0 as NSString).standardizingPath }
        var filesToScan: [WorkspaceFileRecord] = []
        filesToScan.reserveCapacity(standardizedRootPaths.count * 64)
        for rootPath in standardizedRootPaths {
            guard let rootID = rootIDsByStandardizedPath[rootPath] else { continue }
            filesToScan.append(contentsOf: files(inRoot: rootID).filter { file in
                let ext = (file.name as NSString).pathExtension
                return SyntaxManager.isSupportedFileExtension(ext)
            })
        }
        #if DEBUG
            WorkspaceRuntimeDebugLog.event(
                "store.initialCodemapScan.collectFiles",
                fields: [
                    "source": "paths",
                    "rootCount": "\(standardizedRootPaths.count)",
                    "supportedFiles": "\(filesToScan.count)",
                    "duration": collectFilesStartMS.map { WorkspaceRuntimeDebugLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
            let buildRequestsStartMS = WorkspaceRuntimeDebugLog.timestampMSIfEnabled()
        #endif
        let requests = try await codemapScanRequests(for: filesToScan)
        #if DEBUG
            WorkspaceRuntimeDebugLog.event(
                "store.initialCodemapScan.buildRequests",
                fields: [
                    "source": "paths",
                    "supportedFiles": "\(filesToScan.count)",
                    "requests": "\(requests.count)",
                    "duration": buildRequestsStartMS.map { WorkspaceRuntimeDebugLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
            let submitStartMS = WorkspaceRuntimeDebugLog.timestampMSIfEnabled()
        #endif
        await codeScanActor.requestScans(
            requests,
            purpose: .initialRootLoad,
            rootFolderPaths: standardizedRootPaths,
            purgeCachesOnEmptyInitialRequests: purgeCachesOnEmptyInitialRequests
        )
        #if DEBUG
            WorkspaceRuntimeDebugLog.event(
                "store.initialCodemapScan.submit",
                fields: [
                    "source": "paths",
                    "requests": "\(requests.count)",
                    "rootCount": "\(standardizedRootPaths.count)",
                    "duration": submitStartMS.map { WorkspaceRuntimeDebugLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
    }

    package func requestInitialRootCodemapScans(
        rootIDs: [UUID],
        purgeCachesOnEmptyInitialRequests: Bool = false
    ) async throws {
        ensureCodeScanResultTask()
        #if DEBUG
            let collectFilesStartMS = WorkspaceRuntimeDebugLog.timestampMSIfEnabled()
        #endif
        var seenRootIDs = Set<UUID>()
        var orderedRootIDs: [UUID] = []
        var filesToScan: [WorkspaceFileRecord] = []
        filesToScan.reserveCapacity(rootIDs.count * 64)
        for rootID in rootIDs where seenRootIDs.insert(rootID).inserted {
            guard rootStatesByID[rootID] != nil else { continue }
            orderedRootIDs.append(rootID)
            filesToScan.append(contentsOf: files(inRoot: rootID).filter { file in
                let ext = (file.name as NSString).pathExtension
                return SyntaxManager.isSupportedFileExtension(ext)
            })
        }
        #if DEBUG
            WorkspaceRuntimeDebugLog.event(
                "store.initialCodemapScan.collectFiles",
                fields: [
                    "source": "rootIDs",
                    "rootCount": "\(orderedRootIDs.count)",
                    "supportedFiles": "\(filesToScan.count)",
                    "duration": collectFilesStartMS.map { WorkspaceRuntimeDebugLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
        guard !orderedRootIDs.isEmpty else { return }
        #if DEBUG
            let buildRequestsStartMS = WorkspaceRuntimeDebugLog.timestampMSIfEnabled()
        #endif
        let requests = try await codemapScanRequests(for: filesToScan)
        #if DEBUG
            WorkspaceRuntimeDebugLog.event(
                "store.initialCodemapScan.buildRequests",
                fields: [
                    "source": "rootIDs",
                    "supportedFiles": "\(filesToScan.count)",
                    "requests": "\(requests.count)",
                    "duration": buildRequestsStartMS.map { WorkspaceRuntimeDebugLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif

        var currentRootIDs = Set<UUID>()
        var currentRootFolderPaths: [String] = []
        for rootID in orderedRootIDs {
            guard let state = rootStatesByID[rootID] else { continue }
            currentRootIDs.insert(rootID)
            currentRootFolderPaths.append(state.root.standardizedFullPath)
        }
        guard !currentRootFolderPaths.isEmpty else { return }
        let currentRequests = requests.filter { request in
            guard let file = filesByID[request.fileID] else { return false }
            return currentRootIDs.contains(file.rootID)
        }
        #if DEBUG
            let submitStartMS = WorkspaceRuntimeDebugLog.timestampMSIfEnabled()
        #endif
        await codeScanActor.requestScans(
            currentRequests,
            purpose: .initialRootLoad,
            rootFolderPaths: currentRootFolderPaths,
            purgeCachesOnEmptyInitialRequests: purgeCachesOnEmptyInitialRequests
        )
        #if DEBUG
            WorkspaceRuntimeDebugLog.event(
                "store.initialCodemapScan.submit",
                fields: [
                    "source": "rootIDs",
                    "requests": "\(currentRequests.count)",
                    "rootCount": "\(currentRootFolderPaths.count)",
                    "duration": submitStartMS.map { WorkspaceRuntimeDebugLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
    }

    package func requestCodemapScans(for files: [WorkspaceFileRecord]) async throws {
        ensureCodeScanResultTask()
        let requests = try await codemapScanRequests(for: files)
        let rootFolderPaths = Array(Set(requests.map(\.rootFolderPath)))
        guard !rootFolderPaths.isEmpty else { return }
        await codeScanActor.requestScans(requests, rootFolderPaths: rootFolderPaths)
    }

    private func codemapScanRequests(for files: [WorkspaceFileRecord]) async throws -> [CodeScanActor.ScanRequest] {
        var requests: [CodeScanActor.ScanRequest] = []
        requests.reserveCapacity(files.count)
        for file in files {
            guard isDiscoverableFileID(file.id), let state = rootStatesByID[file.rootID] else { continue }
            do {
                let loaded = try await state.service.loadContentWithDate(
                    ofRelativePath: file.standardizedRelativePath,
                    workloadClass: .codemap
                )
                guard let content = loaded.content else { continue }
                requests.append(CodeScanActor.ScanRequest(
                    fileID: file.id,
                    modificationDate: loaded.modificationDate,
                    content: content,
                    fileExtension: (file.name as NSString).pathExtension,
                    relativePath: file.standardizedRelativePath,
                    fullPath: file.standardizedFullPath,
                    rootFolderPath: state.root.standardizedFullPath
                ))
            } catch {
                continue
            }
        }
        return requests
    }

    @discardableResult
    package func createFile(rootID: UUID, relativePath: String, content: String) async throws -> WorkspaceFileCatalogMaterializationResult {
        let state = try state(for: rootID)
        let standardizedRelativePath = StandardizedPath.relative(relativePath)
        try await state.service.createFile(atRelativePath: standardizedRelativePath, content: content)
        return try await materializeCatalogFileAfterDiskWrite(rootID: rootID, relativePath: standardizedRelativePath)
    }

    @discardableResult
    package func editFile(rootID: UUID, relativePath: String, newContent: String) async throws -> WorkspaceFileCatalogMaterializationResult? {
        let state = try state(for: rootID)
        let standardizedRelativePath = StandardizedPath.relative(relativePath)
        do {
            try await state.service.editFile(atRelativePath: standardizedRelativePath, newContent: newContent)
        } catch FileSystemError.fileNotFound {
            pruneCatalogFileMissingOnDisk(rootID: rootID, relativePath: standardizedRelativePath, publishDelta: true)
            throw FileSystemError.fileNotFound
        }
        if let file = file(rootID: rootID, relativePath: standardizedRelativePath) {
            invalidateCodemapSnapshot(rootID: rootID, relativePath: standardizedRelativePath)
            if isDiscoverableFileID(file.id) {
                publishAppliedIndexEvent(root: state.root, modifiedFileIDs: [file.id])
            }
            return .materialized(file)
        }
        return try await materializeCatalogFileAfterDiskWrite(rootID: rootID, relativePath: standardizedRelativePath)
    }

    package func moveFile(rootID: UUID, from oldRelativePath: String, to newRelativePath: String) async throws {
        let state = try state(for: rootID)
        let oldPath = StandardizedPath.relative(oldRelativePath)
        let newPath = StandardizedPath.relative(newRelativePath)
        let oldFile = file(rootID: rootID, relativePath: oldPath)
        let oldFileWasDiscoverable = oldFile.map { isDiscoverableFileID($0.id) } ?? false
        try await state.service.moveFile(
            atRelativePath: oldPath,
            toRelativePath: newPath
        )
        let destinationEligibility = await state.service.catalogRegularFileEligibility(relativePath: newPath)
        let destinationManagedOnly: Bool
        switch destinationEligibility {
        case .eligible:
            destinationManagedOnly = false
        case .ineligible(.ignored):
            destinationManagedOnly = true
        case let .ineligible(reason):
            throw WorkspaceFileContextStoreError.catalogMaterializationFailed("moved file is not catalog-eligible at destination: \(reason.description)")
        }
        removeFile(relativePath: oldPath, rootID: rootID)
        indexFile(relativePath: newPath, root: state.root, managedOnly: destinationManagedOnly)
        publishAppliedIndexEvent(
            root: state.root,
            upsertedFiles: destinationManagedOnly ? [] : (file(rootID: rootID, relativePath: newPath).map { [$0] } ?? []),
            removedFileIDs: oldFileWasDiscoverable ? (oldFile.map { [$0.id] } ?? []) : [],
            removedFilePaths: oldFileWasDiscoverable ? (oldFile.map { [$0.standardizedRelativePath] } ?? []) : []
        )
    }

    package func deleteFile(rootID: UUID, relativePath: String) async throws {
        let state = try state(for: rootID)
        let standardizedRelativePath = StandardizedPath.relative(relativePath)
        let oldFile = file(rootID: rootID, relativePath: standardizedRelativePath)
        let oldFileWasDiscoverable = oldFile.map { isDiscoverableFileID($0.id) } ?? false
        do {
            try await state.service.deleteFile(atRelativePath: standardizedRelativePath)
        } catch FileSystemError.fileNotFound {
            if oldFile != nil {
                pruneCatalogFileMissingOnDisk(rootID: rootID, relativePath: standardizedRelativePath, publishDelta: true)
            }
            throw FileSystemError.fileNotFound
        }
        removeFile(relativePath: standardizedRelativePath, rootID: rootID)
        if let oldFile, oldFileWasDiscoverable {
            publishAppliedIndexEvent(root: state.root, removedFileIDs: [oldFile.id], removedFilePaths: [oldFile.standardizedRelativePath])
        }
    }

    package func moveItemToTrash(rootID: UUID, relativePath: String) async throws {
        let state = try state(for: rootID)
        let standardizedRelativePath = StandardizedPath.relative(relativePath)
        let oldFile = file(rootID: rootID, relativePath: standardizedRelativePath)
        let oldFileWasDiscoverable = oldFile.map { isDiscoverableFileID($0.id) } ?? false
        let oldFolder = folder(rootID: rootID, relativePath: standardizedRelativePath)
        let oldFolderWasDiscoverable = oldFolder.map { isDiscoverableFolderID($0.id) } ?? false
        do {
            try await state.service.moveItemToTrash(atRelativePath: standardizedRelativePath)
        } catch FileSystemError.fileNotFound {
            if oldFile != nil || oldFolder != nil {
                pruneCatalogItemMissingOnDisk(rootID: rootID, relativePath: standardizedRelativePath, publishDelta: true)
            }
            throw FileSystemError.fileNotFound
        }
        if let oldFile {
            removeFile(relativePath: standardizedRelativePath, rootID: rootID)
            if oldFileWasDiscoverable {
                publishAppliedIndexEvent(root: state.root, removedFileIDs: [oldFile.id], removedFilePaths: [oldFile.standardizedRelativePath])
            }
        } else if let oldFolder {
            let removal = removeFolderTree(relativePath: standardizedRelativePath, rootID: rootID)
            publishAppliedIndexEvent(
                root: state.root,
                removedFileIDs: removal.fileIDs,
                removedFolderIDs: removal.folderIDs.isEmpty && oldFolderWasDiscoverable ? [oldFolder.id] : removal.folderIDs,
                removedFilePaths: removal.filePaths,
                removedFolderPaths: removal.folderPaths.isEmpty && oldFolderWasDiscoverable ? [oldFolder.standardizedRelativePath] : removal.folderPaths
            )
        }
    }

    package func validateCatalogFileStillPresent(_ file: WorkspaceFileRecord) async -> WorkspaceFileRecord? {
        let lifecycleCorrelation = WorkspaceRuntimePerf.currentLifecycleCorrelation
        WorkspaceRuntimePerf.lifecycleEvent(
            WorkspaceRuntimePerf.Lifecycle.Search.contentFreshnessStoreEntered,
            correlation: lifecycleCorrelation
        )
        let validationState = WorkspaceRuntimePerf.begin(WorkspaceRuntimePerf.Stage.Search.contentFreshnessValidationStoreActorBody)
        var outcome = "missing"
        defer {
            WorkspaceRuntimePerf.end(
                WorkspaceRuntimePerf.Stage.Search.contentFreshnessValidationStoreActorBody,
                validationState,
                WorkspaceRuntimePerf.Dimensions(outcome: outcome)
            )
            WorkspaceRuntimePerf.lifecycleEvent(
                WorkspaceRuntimePerf.Lifecycle.Search.contentFreshnessStoreReturned,
                correlation: lifecycleCorrelation,
                WorkspaceRuntimePerf.Dimensions(outcome: outcome)
            )
        }
        guard let state = rootStatesByID[file.rootID],
              let current = self.file(rootID: file.rootID, relativePath: file.standardizedRelativePath)
        else { return nil }
        if await state.service.regularFileExistsOnDisk(relativePath: current.standardizedRelativePath) {
            outcome = "current"
            return current
        }
        pruneCatalogFileMissingOnDisk(rootID: file.rootID, relativePath: current.standardizedRelativePath, publishDelta: true)
        return nil
    }

    @discardableResult
    package func pruneMissingCatalogFilesForExactMutationLookup(
        _ userPath: String,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> Bool {
        let trimmed = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        var candidates: [WorkspaceFileRecord] = []
        func appendCandidate(rootID: UUID, relativePath: String) {
            guard let file = file(rootID: rootID, relativePath: relativePath),
                  !candidates.contains(where: { $0.id == file.id })
            else { return }
            candidates.append(file)
        }
        func appendAbsoluteCandidate(_ path: String) {
            let absolute = StandardizedPath.absolute(path)
            guard let fileID = fileIDsByStandardizedFullPath[absolute], let file = filesByID[fileID],
                  rootsForPathLookup(scope: rootScope).contains(where: { $0.id == file.rootID }),
                  !candidates.contains(where: { $0.id == file.id })
            else { return }
            candidates.append(file)
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardizedInput = (expanded as NSString).standardizingPath
        let roots = rootRefs(scope: rootScope)
        if standardizedInput.hasPrefix("/") {
            appendAbsoluteCandidate(standardizedInput)
            let pseudoAlias = standardizedInput.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            switch WorkspaceAliasResolver.resolve(userPath: pseudoAlias, roots: roots, options: RootAliasOptions(requireRemainder: true)) {
            case let .prefixed(root, _, remainder):
                appendCandidate(rootID: root.id, relativePath: remainder)
            case .ambiguous, .bareRoot, .notAliasPrefixed:
                break
            }
        } else {
            switch WorkspaceAliasResolver.resolve(userPath: standardizedInput, roots: roots, options: RootAliasOptions(requireRemainder: true)) {
            case let .prefixed(root, _, remainder):
                appendCandidate(rootID: root.id, relativePath: remainder)
            case .ambiguous, .bareRoot, .notAliasPrefixed:
                break
            }
            let relative = StandardizedPath.relative(standardizedInput)
            if !relative.isEmpty {
                for root in roots {
                    appendCandidate(rootID: root.id, relativePath: relative)
                }
            }
        }

        var pruned = false
        for candidate in candidates {
            if await validateCatalogFileStillPresent(candidate) == nil {
                pruned = true
            }
        }
        return pruned
    }

    /// Returns an exact cataloged file without touching disk. Disk recovery for ignored
    /// files is intentionally reserved for absolute-path misses.
    package func lookupCatalogFileForExplicitRequest(
        _ userPath: String,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) -> WorkspaceExplicitCatalogFileLookupResult {
        #if DEBUG || EDIT_FLOW_PERF
            var exactCatalogLookupOutcome = "noCandidate"
            var exactCatalogLookupRoute = "empty"
            let exactCatalogLookupActorBody = WorkspaceRuntimePerf.begin(WorkspaceRuntimePerf.Stage.ReadFile.exactCatalogLookupActorBody)
            defer {
                let dimensions = WorkspaceRuntimePerf.Dimensions(status: exactCatalogLookupRoute, outcome: exactCatalogLookupOutcome)
                WorkspaceRuntimePerf.end(
                    WorkspaceRuntimePerf.Stage.ReadFile.exactCatalogLookupActorBody,
                    exactCatalogLookupActorBody,
                    dimensions
                )
                WorkspaceRuntimePerf.lifecycleEvent(
                    WorkspaceRuntimePerf.Lifecycle.ReadFile.exactCatalogLookupResolved,
                    dimensions
                )
            }
        #endif

        let trimmed = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .noCandidate }
        guard !StandardizedPath.containsNUL(trimmed) else {
            #if DEBUG || EDIT_FLOW_PERF
                exactCatalogLookupRoute = "blocked"
                exactCatalogLookupOutcome = "blocked"
            #endif
            return .blocked
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardized = StandardizedPath.absolute(expanded)
        let roots = rootRefs(scope: rootScope)

        if standardized.hasPrefix("/") {
            #if DEBUG || EDIT_FLOW_PERF
                exactCatalogLookupRoute = "absolute"
            #endif
            guard let root = roots
                .filter({ StandardizedPath.isDescendant(standardized, of: $0.standardizedFullPath) })
                .max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count })
            else { return .noCandidate }
            let relativePath = String(standardized.dropFirst(root.standardizedFullPath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let file = file(rootID: root.id, relativePath: relativePath) else { return .noCandidate }
            #if DEBUG || EDIT_FLOW_PERF
                exactCatalogLookupOutcome = "matched"
            #endif
            return .matched(file)
        }

        switch WorkspaceAliasResolver.resolve(
            userPath: standardized,
            roots: roots,
            options: RootAliasOptions(requireRemainder: true)
        ) {
        case let .prefixed(root, _, remainder):
            #if DEBUG || EDIT_FLOW_PERF
                exactCatalogLookupRoute = "rootAlias"
            #endif
            guard let file = file(rootID: root.id, relativePath: remainder) else { return .noCandidate }
            #if DEBUG || EDIT_FLOW_PERF
                exactCatalogLookupOutcome = "matched"
            #endif
            return .matched(file)
        case .ambiguous:
            #if DEBUG || EDIT_FLOW_PERF
                exactCatalogLookupRoute = "rootAlias"
                exactCatalogLookupOutcome = "ambiguous"
            #endif
            return .ambiguous
        case .bareRoot, .notAliasPrefixed:
            break
        }

        #if DEBUG || EDIT_FLOW_PERF
            exactCatalogLookupRoute = "relative"
        #endif
        let relativePath = StandardizedPath.relative(standardized)
        guard !relativePath.isEmpty,
              relativePath != "..",
              !relativePath.hasPrefix("../")
        else {
            #if DEBUG || EDIT_FLOW_PERF
                exactCatalogLookupOutcome = "blocked"
            #endif
            return .blocked
        }
        let matches = roots.compactMap { file(rootID: $0.id, relativePath: relativePath) }
        guard matches.count <= 1 else {
            #if DEBUG || EDIT_FLOW_PERF
                exactCatalogLookupOutcome = "ambiguous"
            #endif
            return .ambiguous
        }
        guard let match = matches.first else { return .noCandidate }
        #if DEBUG || EDIT_FLOW_PERF
            exactCatalogLookupOutcome = "matched"
        #endif
        return .matched(match)
    }

    /// Resolves an exact file path that the caller explicitly requested, even when
    /// discovery policy hides it. Ignore rules remain discovery filters: background scans,
    /// replay, tree rendering, search, and fuzzy matching still skip managed-only files.
    package func materializeExplicitlyRequestedFile(
        _ userPath: String,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async throws -> WorkspaceExplicitFileMaterializationResult {
        let trimmed = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .noCandidate }
        guard !StandardizedPath.containsNUL(trimmed) else { return .blocked }
        guard (trimmed as NSString).expandingTildeInPath.hasPrefix("/") else { return .noCandidate }

        let candidates: [(rootID: UUID, relativePath: String)]
        switch explicitDiskLookupCandidates(for: trimmed, rootScope: rootScope) {
        case let .candidates(resolvedCandidates):
            candidates = resolvedCandidates
        case .ambiguousAlias:
            return .ambiguous
        }
        var materializable: [(rootID: UUID, relativePath: String, managedOnly: Bool)] = []
        var foundBlockedCandidate = false
        for candidate in candidates {
            guard let state = rootStatesByID[candidate.rootID] else { continue }
            switch await state.service.catalogRegularFileEligibility(relativePath: candidate.relativePath) {
            case .eligible:
                materializable.append((candidate.rootID, candidate.relativePath, false))
            case .ineligible(.ignored):
                materializable.append((candidate.rootID, candidate.relativePath, true))
            case .ineligible(.missingOrDirectory):
                pruneCatalogFileMissingOnDisk(rootID: candidate.rootID, relativePath: candidate.relativePath, publishDelta: true)
                continue
            case .ineligible:
                foundBlockedCandidate = true
            }
        }
        guard materializable.count <= 1 else { return .ambiguous }
        guard let candidate = materializable.first,
              let state = rootStatesByID[candidate.rootID]
        else { return foundBlockedCandidate ? .blocked : .noCandidate }
        let registeredEligibility = await state.service.registerExplicitlyManagedRegularFile(relativePath: candidate.relativePath)
        let managedOnly: Bool
        switch registeredEligibility {
        case .eligible:
            managedOnly = false
        case .ineligible(.ignored):
            managedOnly = true
        case .ineligible(.missingOrDirectory):
            pruneCatalogFileMissingOnDisk(rootID: candidate.rootID, relativePath: candidate.relativePath, publishDelta: true)
            return .noCandidate
        case .ineligible:
            return .blocked
        }
        return try await .materialized(materializeCatalogRegularFile(
            rootID: candidate.rootID,
            relativePath: candidate.relativePath,
            managedOnly: managedOnly
        ))
    }

    @discardableResult
    package func materializeCatalogFileAfterDiskWrite(
        rootID: UUID,
        relativePath: String
    ) async throws -> WorkspaceFileCatalogMaterializationResult {
        let state = try state(for: rootID)
        let standardizedRelativePath = StandardizedPath.relative(relativePath)
        let eligibility = await state.service.catalogRegularFileEligibility(relativePath: standardizedRelativePath)
        switch eligibility {
        case .ineligible(.ignored):
            // A direct app/MCP write is an explicit request to manage this exact file.
            // Keep it available for follow-up read_file/apply_edits calls without making
            // ignored siblings discoverable through scans or replay.
            return try await .materialized(materializeCatalogRegularFile(rootID: rootID, relativePath: standardizedRelativePath, managedOnly: true))
        case let .ineligible(reason):
            guard isExpectedDiskWriteCatalogIneligibility(reason) else {
                throw WorkspaceFileContextStoreError.catalogMaterializationFailed(
                    "file was written but is not catalog-eligible after the write: \(reason.description)"
                )
            }
            return .ineligible(reason)
        case .eligible:
            return try await .materialized(materializeCatalogRegularFile(rootID: rootID, relativePath: standardizedRelativePath, managedOnly: false))
        }
    }

    private func explicitDiskLookupCandidates(
        for userPath: String,
        rootScope: WorkspaceLookupRootScope
    ) -> ExplicitDiskLookupCandidatesResult {
        let expanded = (userPath as NSString).expandingTildeInPath
        let standardized = StandardizedPath.absolute(expanded)
        let roots = rootRefs(scope: rootScope)
        var candidates: [(rootID: UUID, relativePath: String)] = []
        var seen = Set<String>()

        func append(root: WorkspaceRootRef, relativePath rawRelativePath: String) {
            let relativePath = StandardizedPath.relative(rawRelativePath)
            guard !relativePath.isEmpty,
                  relativePath != "..",
                  !relativePath.hasPrefix("../")
            else { return }
            let absolutePath = StandardizedPath.join(
                standardizedRoot: root.standardizedFullPath,
                standardizedRelativePath: relativePath
            )
            guard StandardizedPath.isDescendant(absolutePath, of: root.standardizedFullPath) else { return }
            let key = "\(root.id.uuidString)|\(relativePath)"
            guard seen.insert(key).inserted else { return }
            candidates.append((root.id, relativePath))
        }

        func appendAbsolute(_ absolutePath: String) {
            guard let root = roots
                .filter({ StandardizedPath.isDescendant(absolutePath, of: $0.standardizedFullPath) })
                .max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count })
            else { return }
            let relativePath = String(absolutePath.dropFirst(root.standardizedFullPath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            append(root: root, relativePath: relativePath)
        }

        if standardized.hasPrefix("/") {
            appendAbsolute(standardized)
            return .candidates(candidates)
        }

        switch WorkspaceAliasResolver.resolve(
            userPath: standardized,
            roots: roots,
            options: RootAliasOptions(requireRemainder: true)
        ) {
        case let .prefixed(root, _, remainder):
            append(root: root, relativePath: remainder)
            return .candidates(candidates)
        case .ambiguous:
            return .ambiguousAlias
        case .bareRoot, .notAliasPrefixed:
            break
        }

        for root in roots {
            append(root: root, relativePath: standardized)
        }
        return .candidates(candidates)
    }

    private func materializeCatalogRegularFile(
        rootID: UUID,
        relativePath: String,
        managedOnly: Bool
    ) async throws -> WorkspaceFileRecord {
        let state = try state(for: rootID)
        let standardizedRelativePath = StandardizedPath.relative(relativePath)
        if let existing = file(rootID: rootID, relativePath: standardizedRelativePath) {
            let wasManagedOnly = managedOnlyFileIDs.contains(existing.id)
            if !managedOnly {
                promoteToDiscoverable(existing)
                if wasManagedOnly {
                    invalidatePathMatchSnapshot(affectedRootKinds: [state.root.kind])
                    publishAppliedIndexEvent(
                        root: state.root,
                        upsertedFiles: [existing],
                        upsertedFolders: discoverableParentFolders(for: standardizedRelativePath, rootID: rootID)
                    )
                }
            }
            return existing
        }

        guard await regularFileAppearsPresentOnDisk(root: state.root, relativePath: standardizedRelativePath) else {
            throw WorkspaceFileContextStoreError.catalogMaterializationFailed(
                "eligible file disappeared before it could be added to the workspace catalog: \(standardizedRelativePath)"
            )
        }
        indexFile(relativePath: standardizedRelativePath, root: state.root, managedOnly: managedOnly)
        guard let file = file(rootID: rootID, relativePath: standardizedRelativePath) else {
            throw WorkspaceFileContextStoreError.catalogMaterializationFailed(
                "eligible file exists on disk but the workspace catalog did not return a record: \(standardizedRelativePath)"
            )
        }
        if !managedOnly {
            publishAppliedIndexEvent(
                root: state.root,
                upsertedFiles: [file],
                upsertedFolders: discoverableParentFolders(for: standardizedRelativePath, rootID: rootID)
            )
        }
        return file
    }

    private func isExpectedDiskWriteCatalogIneligibility(_ reason: CatalogRegularFileIneligibilityReason) -> Bool {
        switch reason {
        case .ignored, .symbolicLink, .nonRegularFile, .symlinkComponent, .outsideCanonicalRoot, .outsideRoot:
            true
        case .invalidRelativePath, .missingOrDirectory:
            false
        }
    }

    private func regularFileAppearsPresentOnDisk(root: WorkspaceRootRecord, relativePath: String) async -> Bool {
        guard let service = rootStatesByID[root.id]?.service else { return false }
        return await service.regularFileExistsOnDisk(relativePath: StandardizedPath.relative(relativePath))
    }

    @discardableResult
    private func pruneCatalogFileMissingOnDisk(
        rootID: UUID,
        relativePath: String,
        publishDelta: Bool
    ) -> Bool {
        guard let state = rootStatesByID[rootID],
              let oldFile = file(rootID: rootID, relativePath: relativePath)
        else { return false }
        let oldFileWasDiscoverable = isDiscoverableFileID(oldFile.id)
        removeFile(relativePath: oldFile.standardizedRelativePath, rootID: rootID)
        if publishDelta, oldFileWasDiscoverable {
            publishAppliedIndexEvent(root: state.root, removedFileIDs: [oldFile.id], removedFilePaths: [oldFile.standardizedRelativePath])
        }
        return true
    }

    @discardableResult
    private func pruneCatalogItemMissingOnDisk(
        rootID: UUID,
        relativePath: String,
        publishDelta: Bool
    ) -> Bool {
        let standardizedRelativePath = StandardizedPath.relative(relativePath)
        if pruneCatalogFileMissingOnDisk(rootID: rootID, relativePath: standardizedRelativePath, publishDelta: publishDelta) {
            return true
        }
        guard let state = rootStatesByID[rootID],
              let oldFolder = folder(rootID: rootID, relativePath: standardizedRelativePath)
        else { return false }
        let oldFolderWasDiscoverable = isDiscoverableFolderID(oldFolder.id)
        let removal = removeFolderTree(relativePath: standardizedRelativePath, rootID: rootID)
        if publishDelta {
            publishAppliedIndexEvent(
                root: state.root,
                removedFileIDs: removal.fileIDs,
                removedFolderIDs: removal.folderIDs.isEmpty && oldFolderWasDiscoverable ? [oldFolder.id] : removal.folderIDs,
                removedFilePaths: removal.filePaths,
                removedFolderPaths: removal.folderPaths.isEmpty && oldFolderWasDiscoverable ? [oldFolder.standardizedRelativePath] : removal.folderPaths
            )
        }
        return true
    }

    private func applyPreparedIndexDeltas(rootID: UUID, deltas: [PreparedFileSystemDelta]) async {
        guard let root = rootStatesByID[rootID]?.root else { return }
        var upsertedFiles: [WorkspaceFileRecord] = []
        var upsertedFolders: [WorkspaceFolderRecord] = []
        var removedFileIDs: [UUID] = []
        var removedFolderIDs: [UUID] = []
        var removedFilePaths: [String] = []
        var removedFolderPaths: [String] = []
        var modifiedFileIDs: [UUID] = []
        var modifiedFolderIDs: [UUID] = []
        for prepared in deltas {
            let relativePath = prepared.relativePath
            switch prepared.delta {
            case .fileAdded:
                guard let state = rootStatesByID[rootID],
                      await state.service.catalogEligibleRegularFileExists(relativePath: relativePath),
                      await regularFileAppearsPresentOnDisk(root: root, relativePath: relativePath)
                else { continue }
                let existed = file(rootID: rootID, relativePath: relativePath) != nil
                let existingFolderPaths = Set(rootStatesByID[rootID].map { Array($0.folderIDsByRelativePath.keys) } ?? [])
                indexFile(relativePath: relativePath, root: root)
                if let file = file(rootID: rootID, relativePath: relativePath) {
                    // Publish existing records too: file-system deltas may have already
                    // indexed the catalog while UI replay still has optimistic UUIDs.
                    // Treating add as an upsert lets subscribers reconcile to store IDs.
                    upsertedFiles.append(file)
                    if !existed {
                        upsertedFolders.append(contentsOf: newlyIndexedParentFolders(for: relativePath, rootID: rootID, existingFolderPaths: existingFolderPaths))
                    }
                    upsertedFolders.append(contentsOf: discoverableParentFolders(for: relativePath, rootID: rootID))
                }
            case .folderAdded:
                guard let state = rootStatesByID[rootID],
                      await state.service.catalogFolderIsDiscoverable(relativePath: relativePath)
                else { continue }
                indexFolder(relativePath: relativePath, root: root)
                if let folder = folder(rootID: rootID, relativePath: relativePath) {
                    // Same upsert semantics as files: repeated folder add deltas are
                    // harmless and allow UI identity reconciliation.
                    upsertedFolders.append(folder)
                }
            case .fileRemoved:
                if let oldFile = file(rootID: rootID, relativePath: relativePath) {
                    let oldFileWasDiscoverable = isDiscoverableFileID(oldFile.id)
                    removeFile(relativePath: relativePath, rootID: rootID)
                    if oldFileWasDiscoverable {
                        removedFileIDs.append(oldFile.id)
                        removedFilePaths.append(oldFile.standardizedRelativePath)
                    }
                }
            case .folderRemoved:
                if let oldFolder = folder(rootID: rootID, relativePath: relativePath) {
                    let oldFolderWasDiscoverable = isDiscoverableFolderID(oldFolder.id)
                    let removal = removeFolderTree(relativePath: relativePath, rootID: rootID)
                    removedFileIDs.append(contentsOf: removal.fileIDs)
                    removedFolderIDs.append(contentsOf: removal.folderIDs.isEmpty && oldFolderWasDiscoverable ? [oldFolder.id] : removal.folderIDs)
                    removedFilePaths.append(contentsOf: removal.filePaths)
                    removedFolderPaths.append(contentsOf: removal.folderPaths.isEmpty && oldFolderWasDiscoverable ? [oldFolder.standardizedRelativePath] : removal.folderPaths)
                }
            case .fileModified:
                if let file = file(rootID: rootID, relativePath: relativePath) {
                    invalidateCodemapSnapshot(rootID: rootID, relativePath: relativePath)
                    if isDiscoverableFileID(file.id) { modifiedFileIDs.append(file.id) }
                }
            case .folderModified:
                if let folder = folder(rootID: rootID, relativePath: relativePath), isDiscoverableFolderID(folder.id) {
                    modifiedFolderIDs.append(folder.id)
                }
            }
        }
        publishAppliedIndexEvent(
            root: root,
            upsertedFiles: upsertedFiles,
            upsertedFolders: upsertedFolders,
            removedFileIDs: removedFileIDs,
            removedFolderIDs: removedFolderIDs,
            removedFilePaths: removedFilePaths,
            removedFolderPaths: removedFolderPaths,
            modifiedFileIDs: modifiedFileIDs,
            modifiedFolderIDs: modifiedFolderIDs
        )
    }

    package func lookupPath(
        _ userPath: String,
        profile: PathLocateProfile = .uiAssisted,
        rootScope: WorkspaceLookupRootScope = .allLoaded
    ) async -> WorkspacePathLookupResult? {
        let request = WorkspacePathLookupRequest(userPath: userPath, profile: profile, rootScope: rootScope)
        return await lookupPath(request)
    }

    package func lookupPath(_ request: WorkspacePathLookupRequest) async -> WorkspacePathLookupResult? {
        let normalizedPath = normalizeUserInputPath(request.userPath)
        guard !normalizedPath.isEmpty else { return nil }

        let selectedFileFullPaths = request.selectedFileFullPaths
        let staticData = buildStaticSnapshot(scope: request.rootScope)
        guard let match = await pathMatchWorker.locate(
            userPath: normalizedPath,
            profile: request.profile,
            staticData: staticData,
            selectedFileFullPaths: selectedFileFullPaths,
            selectionSig: selectionSignature(for: selectedFileFullPaths)
        ) else { return nil }
        return lookupResult(input: request.userPath, match: match)
    }

    package func lookupPaths(_ requests: [WorkspacePathLookupRequest]) async -> [String: WorkspacePathLookupResult] {
        struct LookupBatchKey: Hashable {
            let rootScope: WorkspaceLookupRootScope
            let profile: PathLocateProfile
            let selectedFileFullPaths: Set<String>
        }

        var grouped: [LookupBatchKey: [(original: String, normalized: String)]] = [:]
        for request in requests {
            let normalizedPath = normalizeUserInputPath(request.userPath)
            guard !normalizedPath.isEmpty else { continue }
            let key = LookupBatchKey(
                rootScope: request.rootScope,
                profile: request.profile,
                selectedFileFullPaths: request.selectedFileFullPaths
            )
            grouped[key, default: []].append((request.userPath, normalizedPath))
        }

        var results: [String: WorkspacePathLookupResult] = [:]
        for (key, paths) in grouped {
            let staticData = buildStaticSnapshot(scope: key.rootScope)
            let matches = await pathMatchWorker.locateMany(
                userPaths: paths.map(\.normalized),
                profile: key.profile,
                staticData: staticData,
                selectedFileFullPaths: key.selectedFileFullPaths,
                selectionSig: selectionSignature(for: key.selectedFileFullPaths)
            )
            for path in paths {
                guard let match = matches[path.normalized],
                      let result = lookupResult(input: path.original, match: match)
                else { continue }
                results[path.original] = result
            }
        }
        return results
    }

    package func findCreationPath(
        userPath: String,
        rootScope: WorkspaceLookupRootScope = .allLoaded,
        selectedFileFullPaths: Set<String> = []
    ) async -> FileCreationResult? {
        let normalizedPath = normalizeUserInputPath(userPath)
        guard !normalizedPath.isEmpty else { return nil }
        let staticData = buildStaticSnapshot(scope: rootScope)
        return await pathMatchWorker.findCreationPath(
            userPath: normalizedPath,
            staticData: staticData,
            selectedFileFullPaths: selectedFileFullPaths,
            selectionSig: selectionSignature(for: selectedFileFullPaths)
        )
    }

    package func resolveCreationPath(
        userPath: String,
        rootScope: WorkspaceLookupRootScope = .allLoaded,
        selectedFileFullPaths: Set<String> = [],
        mode: CreationResolutionMode
    ) async -> FileCreationResolution? {
        let normalizedPath = normalizeUserInputPath(userPath)
        guard !normalizedPath.isEmpty else { return nil }
        let staticData = buildStaticSnapshot(scope: rootScope)
        return await pathMatchWorker.resolveCreationPath(
            userPath: normalizedPath,
            staticData: staticData,
            selectedFileFullPaths: selectedFileFullPaths,
            selectionSig: selectionSignature(for: selectedFileFullPaths),
            mode: mode
        )
    }

    package func lookupPath(rootID: UUID, relativePath: String) -> WorkspacePathLookupResult? {
        guard let state = rootStatesByID[rootID] else { return nil }
        let key = StandardizedPath.relative(relativePath)
        if let fileID = state.fileIDsByRelativePath[key], let file = filesByID[fileID] {
            return lookupResult(input: relativePath, root: state.root, correctedPath: file.standardizedRelativePath)
        }
        if let folderID = state.folderIDsByRelativePath[key], let folder = foldersByID[folderID] {
            return lookupResult(input: relativePath, root: state.root, correctedPath: folder.standardizedRelativePath)
        }
        return nil
    }

    package func lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(
        _ userPath: String,
        rootScope: WorkspaceLookupRootScope
    ) -> WorkspacePathLookupResult? {
        let trimmed = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !StandardizedPath.containsNUL(trimmed) else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        let standardizedPath = StandardizedPath.absolute(expanded)
        guard let root = rootsForPathLookup(scope: rootScope)
            .filter({ StandardizedPath.isDescendant(standardizedPath, of: $0.standardizedFullPath) })
            .max(by: { $0.standardizedFullPath.count < $1.standardizedFullPath.count })
        else { return nil }
        let relativePath = relativePath(for: standardizedPath, rootPath: root.standardizedFullPath)
        guard let result = lookupPath(rootID: root.id, relativePath: relativePath),
              isDiscoverableLookupResult(result)
        else { return nil }
        return result
    }

    package func rootRefs(scope: WorkspaceLookupRootScope = .allLoaded) -> [WorkspaceRootRef] {
        rootsForPathLookup(scope: scope).map {
            WorkspaceRootRef(id: $0.id, name: $0.name, fullPath: $0.standardizedFullPath)
        }
    }

    package func displayRootRefsSnapshot() -> WorkspaceDisplayRootRefsSnapshot {
        WorkspaceDisplayRootRefsSnapshot(
            visibleRoots: rootRefs(scope: .visibleWorkspace),
            allRoots: rootRefs(scope: .allLoaded)
        )
    }

    package func exactPathResolutionIssue(
        for userPath: String,
        kind: WorkspaceExactPathLookupKind,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) -> PathResolutionIssue? {
        let trimmedInput = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return .emptyInput }
        if StandardizedPath.containsNUL(trimmedInput) {
            return .invalidPathCharacters(
                input: trimmedInput,
                reason: "embedded NUL (\\0) characters are not allowed"
            )
        }
        let expanded = (trimmedInput as NSString).expandingTildeInPath
        let standardized = StandardizedPath.absolute(expanded)
        guard !standardized.hasPrefix("/") else { return nil }

        let roots = rootRefs(scope: rootScope)
        guard !roots.isEmpty else { return nil }

        switch WorkspaceAliasResolver.resolve(
            userPath: standardized,
            roots: roots,
            options: RootAliasOptions(requireRemainder: false, allowCompatibilityAlias: true)
        ) {
        case let .ambiguous(alias, matchingRoots):
            return .ambiguousAlias(alias: alias, matchingRoots: matchingRoots)
        case let .bareRoot(root, _):
            switch kind {
            case .folder, .either:
                if rootStatesByID[root.id] != nil { return nil }
            case .file:
                break
            }
        case let .prefixed(root, _, remainder):
            let absolute = StandardizedPath.join(
                standardizedRoot: root.standardizedFullPath,
                standardizedRelativePath: StandardizedPath.relative(remainder)
            )
            if exactRecordExists(standardizedFullPath: absolute, kind: kind) { return nil }
        case .notAliasPrefixed:
            break
        }

        let relative = StandardizedPath.relative(standardized.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        guard !relative.isEmpty else { return nil }
        let matchingRoots = roots.filter { root in
            let absolute = StandardizedPath.join(
                standardizedRoot: root.standardizedFullPath,
                standardizedRelativePath: relative
            )
            return exactRecordExists(standardizedFullPath: absolute, kind: kind)
        }
        guard matchingRoots.count > 1 else { return nil }
        return .ambiguousRootMatch(input: trimmedInput, candidateRoots: matchingRoots)
    }

    package func lookupFiles(
        atPaths paths: [String],
        profile: PathLocateProfile = .mcpSelection,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async -> [String: WorkspaceFileRecord] {
        var files: [String: WorkspaceFileRecord] = [:]
        var generalLookupPaths: [String] = []
        for path in paths {
            switch lookupCatalogFileForExplicitRequest(path, rootScope: rootScope) {
            case let .matched(file):
                files[path] = file
                continue
            case .ambiguous, .blocked:
                continue
            case .noCandidate:
                break
            }
            switch try? await materializeExplicitlyRequestedFile(path, rootScope: rootScope) {
            case let .some(.materialized(file)):
                files[path] = file
            case .some(.ambiguous), .some(.blocked):
                continue
            case .some(.noCandidate), .none:
                generalLookupPaths.append(path)
            }
        }
        let requests = generalLookupPaths.map { WorkspacePathLookupRequest(userPath: $0, profile: profile, rootScope: rootScope) }
        let results = await lookupPaths(requests)
        for path in generalLookupPaths where files[path] == nil {
            if let file = results[path]?.file {
                files[path] = file
            }
        }
        return files
    }

    package func resolveFolderInput(
        _ path: String,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        profile: PathLocateProfile = .mcpSelection
    ) async -> (folder: WorkspaceFolderRecord?, displayPath: String?, issue: PathResolutionIssue?) {
        let cleaned = normalizeUserInputPath(path).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return (nil, nil, .emptyInput) }

        if let issue = exactPathResolutionIssue(for: cleaned, kind: .folder, rootScope: rootScope) {
            return (nil, nil, issue)
        }

        let roots = rootRefs(scope: rootScope)
        if cleaned.hasPrefix("/") {
            if let folderID = folderIDsByStandardizedFullPath[StandardizedPath.absolute(cleaned)],
               isDiscoverableFolderID(folderID),
               let folder = foldersByID[folderID],
               let root = rootRefs(scope: rootScope).first(where: { $0.id == folder.rootID })
            {
                return (folder, ClientPathFormatter.displayPath(root: root, relativePath: folder.standardizedRelativePath, visibleRoots: roots), nil)
            }
            let pseudoAlias = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            switch WorkspaceAliasResolver.resolve(userPath: pseudoAlias, roots: roots, options: RootAliasOptions(requireRemainder: false)) {
            case let .bareRoot(root, _):
                if let folder = rootFolderRecord(rootID: root.id) {
                    return (folder, ClientPathFormatter.displayPath(root: root, relativePath: "", visibleRoots: roots), nil)
                }
            case let .prefixed(root, _, remainder):
                if let folder = folder(rootID: root.id, relativePath: remainder), isDiscoverableFolderID(folder.id) {
                    return (folder, ClientPathFormatter.displayPath(root: root, relativePath: folder.standardizedRelativePath, visibleRoots: roots), nil)
                }
            case let .ambiguous(alias, matchingRoots):
                return (nil, nil, .ambiguousAlias(alias: alias, matchingRoots: matchingRoots))
            case .notAliasPrefixed:
                break
            }
        }

        switch WorkspaceAliasResolver.resolve(userPath: cleaned, roots: roots, options: RootAliasOptions(requireRemainder: false)) {
        case let .bareRoot(root, _):
            if let folder = rootFolderRecord(rootID: root.id) {
                return (folder, ClientPathFormatter.displayPath(root: root, relativePath: "", visibleRoots: roots), nil)
            }
        case let .prefixed(root, _, remainder):
            if let folder = folder(rootID: root.id, relativePath: remainder), isDiscoverableFolderID(folder.id) {
                return (folder, ClientPathFormatter.displayPath(root: root, relativePath: folder.standardizedRelativePath, visibleRoots: roots), nil)
            }
        case let .ambiguous(alias, matchingRoots):
            return (nil, nil, .ambiguousAlias(alias: alias, matchingRoots: matchingRoots))
        case .notAliasPrefixed:
            break
        }

        let relative = StandardizedPath.relative(cleaned)
        let directRelativeMatches = roots.compactMap { root -> (WorkspaceRootRef, WorkspaceFolderRecord)? in
            guard let folder = folder(rootID: root.id, relativePath: relative), isDiscoverableFolderID(folder.id) else { return nil }
            return (root, folder)
        }
        if directRelativeMatches.count == 1, let match = directRelativeMatches.first {
            return (
                match.1,
                ClientPathFormatter.displayPath(root: match.0, relativePath: match.1.standardizedRelativePath, visibleRoots: roots),
                nil
            )
        }

        let generalLookupState = WorkspaceRuntimePerf.begin(WorkspaceRuntimePerf.Stage.ReadFile.folderResolutionGeneralLookupFallback)
        let lookup = await lookupPath(WorkspacePathLookupRequest(userPath: cleaned, profile: profile, rootScope: rootScope))
        WorkspaceRuntimePerf.end(
            WorkspaceRuntimePerf.Stage.ReadFile.folderResolutionGeneralLookupFallback,
            generalLookupState,
            WorkspaceRuntimePerf.Dimensions(outcome: lookup?.folder == nil ? "noFolder" : "folder")
        )
        if let folder = lookup?.folder,
           let root = roots.first(where: { $0.id == folder.rootID })
        {
            return (folder, ClientPathFormatter.displayPath(root: root, relativePath: folder.standardizedRelativePath, visibleRoots: roots), nil)
        }
        return (nil, nil, nil)
    }

    package func expandFolderInputToFiles(
        _ path: String,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        profile: PathLocateProfile = .mcpSelection
    ) async -> WorkspaceFolderExpansionResult {
        let resolution = await resolveFolderInput(path, rootScope: rootScope, profile: profile)
        if let folder = resolution.folder {
            return WorkspaceFolderExpansionResult(
                files: descendantFiles(in: folder.id),
                handled: true,
                displayPath: resolution.displayPath,
                issue: nil
            )
        }
        if let issue = resolution.issue {
            return WorkspaceFolderExpansionResult(files: [], handled: false, displayPath: nil, issue: issue)
        }
        return WorkspaceFolderExpansionResult(files: [], handled: false, displayPath: nil, issue: .unresolved(input: path))
    }

    private func exactRecordExists(standardizedFullPath: String, kind: WorkspaceExactPathLookupKind) -> Bool {
        let absolute = StandardizedPath.absolute(standardizedFullPath)
        switch kind {
        case .file:
            return fileIDsByStandardizedFullPath[absolute] != nil
        case .folder:
            return folderIDsByStandardizedFullPath[absolute].map(isDiscoverableFolderID) ?? false
        case .either:
            return fileIDsByStandardizedFullPath[absolute] != nil || (folderIDsByStandardizedFullPath[absolute].map(isDiscoverableFolderID) ?? false)
        }
    }

    private func rootFolderRecord(rootID: UUID) -> WorkspaceFolderRecord? {
        guard let state = rootStatesByID[rootID],
              let folderID = state.folderIDsByRelativePath[""]
        else { return nil }
        return foldersByID[folderID]
    }

    private func descendantFiles(in folderID: UUID) -> [WorkspaceFileRecord] {
        guard let folder = foldersByID[folderID], let state = rootStatesByID[folder.rootID] else { return [] }
        let ids = descendantFileIDs(in: folderID, state: state)
        return ids.compactMap { filesByID[$0] }
            .sorted { $0.standardizedRelativePath < $1.standardizedRelativePath }
    }

    private func lookupResult(input: String, match: PathMatchLocation) -> WorkspacePathLookupResult? {
        let rootPath = (match.rootPath as NSString).standardizingPath
        guard let rootID = rootIDsByStandardizedPath[rootPath],
              let state = rootStatesByID[rootID]
        else { return nil }
        return lookupResult(input: input, root: state.root, correctedPath: match.correctedPath)
    }

    private func lookupResult(input: String, root: WorkspaceRootRecord, correctedPath: String) -> WorkspacePathLookupResult? {
        let correctedPath = StandardizedPath.relative(correctedPath)
        let fullPath = ((root.standardizedFullPath as NSString).appendingPathComponent(correctedPath) as NSString).standardizingPath
        let file = fileIDsByStandardizedFullPath[fullPath].flatMap { filesByID[$0] }
        let folder = folderIDsByStandardizedFullPath[fullPath].flatMap { foldersByID[$0] }
        guard file != nil || folder != nil else { return nil }
        return WorkspacePathLookupResult(
            input: input,
            location: WorkspacePathLocation(rootID: root.id, rootPath: root.standardizedFullPath, correctedPath: correctedPath),
            file: file,
            folder: folder
        )
    }

    private func buildStaticSnapshot(scope: WorkspaceLookupRootScope) -> StaticPathMatchData {
        let snapshotState = WorkspaceRuntimePerf.begin(WorkspaceRuntimePerf.Stage.ReadFile.pathLookupStaticSnapshotBuild)
        defer { WorkspaceRuntimePerf.end(WorkspaceRuntimePerf.Stage.ReadFile.pathLookupStaticSnapshotBuild, snapshotState) }
        let roots = rootsForPathLookup(scope: scope)
        let allowedRootIDs = Set(roots.map(\.id))
        var fileRecords: [String: FileRecord] = [:]
        for file in filesByID.values.sorted(by: { $0.standardizedFullPath < $1.standardizedFullPath }) {
            guard allowedRootIDs.contains(file.rootID),
                  isDiscoverableFileID(file.id),
                  let root = rootStatesByID[file.rootID]?.root,
                  fileRecords[file.standardizedFullPath] == nil
            else { continue }
            fileRecords[file.standardizedFullPath] = FrozenFileRecord(
                name: file.name,
                relativePath: file.standardizedRelativePath,
                fullPath: file.standardizedFullPath,
                rootFolderPath: root.standardizedFullPath
            ) as FileRecord
        }
        var folderRecords: [String: FolderRecord] = [:]
        for folder in foldersByID.values.sorted(by: { $0.standardizedFullPath < $1.standardizedFullPath }) {
            guard allowedRootIDs.contains(folder.rootID),
                  isDiscoverableFolderID(folder.id),
                  let root = rootStatesByID[folder.rootID]?.root,
                  folderRecords[folder.standardizedFullPath] == nil
            else { continue }
            folderRecords[folder.standardizedFullPath] = FrozenFolderRecord(
                name: folder.name,
                relativePath: folder.standardizedRelativePath,
                fullPath: folder.standardizedFullPath,
                rootPath: root.standardizedFullPath,
                displayName: folder.name
            ) as FolderRecord
        }
        let rootFolders: [FolderRecord] = roots.compactMap { root in
            guard let folderID = rootStatesByID[root.id]?.folderIDsByRelativePath[""],
                  let folder = foldersByID[folderID]
            else { return nil }
            return FrozenFolderRecord(
                name: folder.name,
                relativePath: "",
                fullPath: folder.standardizedFullPath,
                rootPath: root.standardizedFullPath,
                displayName: folder.name
            ) as FolderRecord
        }
        return StaticPathMatchData(
            filesByFullPath: fileRecords,
            foldersByFullPath: folderRecords,
            rootFolders: rootFolders,
            id: scopedSnapshotGeneration(scope: scope)
        )
    }

    private func scopedSnapshotGeneration(scope: WorkspaceLookupRootScope) -> UInt64 {
        (catalogGenerationsByScope[scope] ?? 0) &* 3 &+ scopeDiscriminator(scope)
    }

    private func searchCatalogSnapshotValidationToken(scope: WorkspaceLookupRootScope) -> UInt64 {
        switch scope {
        case .sessionBoundWorkspace:
            scopedSnapshotGeneration(scope: .allLoaded)
        default:
            scopedSnapshotGeneration(scope: scope)
        }
    }

    private func cacheSearchCatalogSnapshot(
        _ snapshot: WorkspaceSearchCatalogSnapshot,
        validationToken: UInt64,
        scope: WorkspaceLookupRootScope
    ) {
        if searchCatalogSnapshotsByScope[scope] == nil,
           searchCatalogSnapshotsByScope.count >= Self.maxCachedSearchCatalogSnapshotScopes
        {
            clearSearchCatalogSnapshotCache()
        }
        searchCatalogSnapshotsByScope[scope] = SearchCatalogSnapshotCacheEntry(
            validationToken: validationToken,
            snapshot: snapshot
        )
    }

    private func scopeDiscriminator(_ scope: WorkspaceLookupRootScope) -> UInt64 {
        switch scope {
        case .visibleWorkspace:
            return 0
        case .visibleWorkspacePlusGitData:
            return 1
        case .allLoaded:
            return 2
        case let .sessionBoundWorkspace(logicalRootPaths, physicalRootPaths):
            var hasher = Hasher()
            hasher.combine("sessionBoundWorkspace")
            hasher.combine(logicalRootPaths.sorted())
            hasher.combine(physicalRootPaths.sorted())
            return UInt64(bitPattern: Int64(hasher.finalize()))
        }
    }

    private func bumpCatalogGenerations(affectedRootKinds: Set<WorkspaceRootKind>) {
        guard !affectedRootKinds.isEmpty else { return }
        for scope in WorkspaceFileContextStore.catalogGenerationScopes {
            guard scopeIncludesAnyRootKind(scope, affectedRootKinds) else { continue }
            catalogGenerationsByScope[scope] = (catalogGenerationsByScope[scope] ?? 0) &+ 1
        }
    }

    private static let catalogGenerationScopes: [WorkspaceLookupRootScope] = [
        .visibleWorkspace,
        .visibleWorkspacePlusGitData,
        .allLoaded
    ]

    private func scopeIncludesAnyRootKind(_ scope: WorkspaceLookupRootScope, _ kinds: Set<WorkspaceRootKind>) -> Bool {
        switch scope {
        case .visibleWorkspace:
            kinds.contains(.primaryWorkspace)
        case .visibleWorkspacePlusGitData:
            kinds.contains(.primaryWorkspace) || kinds.contains(.workspaceGitData)
        case .allLoaded:
            true
        case .sessionBoundWorkspace:
            kinds.contains(.primaryWorkspace) || kinds.contains(.sessionWorktree)
        }
    }

    private func rootsForPathLookup(scope: WorkspaceLookupRootScope) -> [WorkspaceRootRecord] {
        let allRoots = roots()
        switch scope {
        case .visibleWorkspace:
            return allRoots.filter { $0.kind == .primaryWorkspace }
        case .visibleWorkspacePlusGitData:
            return allRoots.filter { $0.kind == .primaryWorkspace || $0.kind == .workspaceGitData }
        case .allLoaded:
            return allRoots
        case let .sessionBoundWorkspace(logicalRootPaths, physicalRootPaths):
            return allRoots.filter { root in
                switch root.kind {
                case .primaryWorkspace:
                    !logicalRootPaths.contains(root.standardizedFullPath)
                case .sessionWorktree:
                    physicalRootPaths.contains(root.standardizedFullPath)
                case .workspaceGitData, .supplementalSystem:
                    false
                }
            }
        }
    }

    private func normalizeUserInputPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }

    private func clearSearchCatalogSnapshotCache() {
        searchCatalogSnapshotsByScope.removeAll(keepingCapacity: true)
    }

    private func invalidatePathMatchSnapshot(affectedRootKinds: Set<WorkspaceRootKind>) {
        bumpCatalogGenerations(affectedRootKinds: affectedRootKinds)
        clearSearchCatalogSnapshotCache()
        invalidatePathMatchCache()
    }

    private func invalidatePathMatchCache() {
        Task { await pathMatchWorker.invalidateCache() }
    }

    private func indexFolder(relativePath: String, root: WorkspaceRootRecord) {
        guard var state = rootStatesByID[root.id] else { return }
        var stagedIndexes = RootIndexBuffers()
        indexFolders([FSItemDTO(relativePath: relativePath, isDirectory: true, hierarchy: relativePath.split(separator: "/").count)], root: root, state: &state, indexes: &stagedIndexes)
        commit(stagedIndexes)
        rootStatesByID[root.id] = state
        if let folder = folder(rootID: root.id, relativePath: relativePath) {
            promoteFolderToDiscoverable(folder)
        }
        invalidatePathMatchSnapshot(affectedRootKinds: [root.kind])
    }

    private func indexFile(relativePath: String, root: WorkspaceRootRecord, managedOnly: Bool = false) {
        guard var state = rootStatesByID[root.id] else { return }
        let existingFolderPaths = Set(state.folderIDsByRelativePath.keys)
        var stagedIndexes = RootIndexBuffers()
        indexFiles([FSItemDTO(relativePath: relativePath, isDirectory: false, hierarchy: relativePath.split(separator: "/").count)], root: root, state: &state, indexes: &stagedIndexes)
        commit(stagedIndexes)
        rootStatesByID[root.id] = state
        if let file = file(rootID: root.id, relativePath: relativePath) {
            if managedOnly {
                if managedOnlyFileIDs.insert(file.id).inserted {
                    invalidateAllCodemapFileAPIsCache()
                }
                for folder in newlyIndexedParentFolders(for: relativePath, rootID: root.id, existingFolderPaths: existingFolderPaths) {
                    managedOnlyFolderIDs.insert(folder.id)
                }
            } else {
                promoteToDiscoverable(file)
            }
        }
        invalidatePathMatchSnapshot(affectedRootKinds: [root.kind])
    }

    private func discoverableParentFolders(for fileRelativePath: String, rootID: UUID) -> [WorkspaceFolderRecord] {
        guard let state = rootStatesByID[rootID] else { return [] }
        let standardizedPath = StandardizedPath.relative(fileRelativePath)
        var current = (standardizedPath as NSString).deletingLastPathComponent
        var folders: [WorkspaceFolderRecord] = []
        while !current.isEmpty, current != "." {
            let key = StandardizedPath.relative(current)
            if let folderID = state.folderIDsByRelativePath[key],
               isDiscoverableFolderID(folderID),
               let folder = foldersByID[folderID]
            {
                folders.append(folder)
            }
            let next = (key as NSString).deletingLastPathComponent
            guard next != key else { break }
            current = next
        }
        return folders.sorted { $0.standardizedRelativePath < $1.standardizedRelativePath }
    }

    private func newlyIndexedParentFolders(
        for fileRelativePath: String,
        rootID: UUID,
        existingFolderPaths: Set<String>
    ) -> [WorkspaceFolderRecord] {
        guard let state = rootStatesByID[rootID] else { return [] }
        let standardizedPath = StandardizedPath.relative(fileRelativePath)
        let parentPath = (standardizedPath as NSString).deletingLastPathComponent
        guard !parentPath.isEmpty, parentPath != "." else { return [] }
        var folders: [WorkspaceFolderRecord] = []
        var current = parentPath
        while !current.isEmpty, current != "." {
            let key = StandardizedPath.relative(current)
            if !existingFolderPaths.contains(key),
               let folderID = state.folderIDsByRelativePath[key],
               let folder = foldersByID[folderID]
            {
                folders.append(folder)
            }
            let next = (key as NSString).deletingLastPathComponent
            guard next != key else { break }
            current = next
        }
        return folders.sorted { $0.standardizedRelativePath < $1.standardizedRelativePath }
    }

    private func publishAppliedIndexEvent(
        root: WorkspaceRootRecord,
        upsertedFiles: [WorkspaceFileRecord] = [],
        upsertedFolders: [WorkspaceFolderRecord] = [],
        removedFileIDs: [UUID] = [],
        removedFolderIDs: [UUID] = [],
        removedFilePaths: [String] = [],
        removedFolderPaths: [String] = [],
        modifiedFileIDs: [UUID] = [],
        modifiedFolderIDs: [UUID] = []
    ) {
        let upsertedFiles = upsertedFiles.filter { isDiscoverableFileID($0.id) }
        let upsertedFolders = upsertedFolders.filter { isDiscoverableFolderID($0.id) }
        let modifiedFileIDs = modifiedFileIDs.filter(isDiscoverableFileID)
        let modifiedFolderIDs = modifiedFolderIDs.filter(isDiscoverableFolderID)
        guard !upsertedFiles.isEmpty || !upsertedFolders.isEmpty || !removedFileIDs.isEmpty || !removedFolderIDs.isEmpty || !removedFilePaths.isEmpty || !removedFolderPaths.isEmpty || !modifiedFileIDs.isEmpty || !modifiedFolderIDs.isEmpty else { return }
        let generation = nextAppliedIndexGeneration(forRootID: root.id)
        yieldAppliedIndexEvent(WorkspaceAppliedIndexBatchEvent(
            rootID: root.id,
            rootPath: root.standardizedFullPath,
            generation: generation,
            upsertedFiles: upsertedFiles.sorted { $0.standardizedRelativePath < $1.standardizedRelativePath },
            upsertedFolders: upsertedFolders.sorted { $0.standardizedRelativePath < $1.standardizedRelativePath },
            removedFileIDs: removedFileIDs,
            removedFolderIDs: removedFolderIDs,
            removedFilePaths: removedFilePaths.sorted(),
            removedFolderPaths: removedFolderPaths.sorted(),
            modifiedFileIDs: modifiedFileIDs,
            modifiedFolderIDs: modifiedFolderIDs
        ))
    }

    private func removeFile(relativePath: String, rootID: UUID) {
        guard var state = rootStatesByID[rootID] else { return }
        let removedFileID = removeFile(relativePath: relativePath, state: &state)
        rootStatesByID[rootID] = state
        if let removedFileID {
            yieldCodemapRemoval(root: state.root, removedFileIDs: [removedFileID], isRootUnload: false)
            invalidatePathMatchSnapshot(affectedRootKinds: [state.root.kind])
        }
    }

    private func invalidateCodemapSnapshot(rootID: UUID, relativePath: String) {
        guard let state = rootStatesByID[rootID],
              let fileID = state.fileIDsByRelativePath[StandardizedPath.relative(relativePath)],
              codemapSnapshotsByFileID.removeValue(forKey: fileID) != nil
        else { return }
        codemapFileIDsByRootID[rootID]?.remove(fileID)
        invalidateAllCodemapFileAPIsCache()
        yieldCodemapRemoval(root: state.root, removedFileIDs: [fileID], isRootUnload: false)
    }

    @discardableResult
    private func removeFile(relativePath: String, state: inout RootState) -> UUID? {
        let key = StandardizedPath.relative(relativePath)
        guard let fileID = state.fileIDsByRelativePath.removeValue(forKey: key),
              let file = filesByID.removeValue(forKey: fileID)
        else { return nil }
        fileIDsByStandardizedFullPath.removeValue(forKey: file.standardizedFullPath)
        managedOnlyFileIDs.remove(fileID)
        if codemapSnapshotsByFileID.removeValue(forKey: fileID) != nil {
            invalidateAllCodemapFileAPIsCache()
        }
        codemapFileIDsByRootID[file.rootID]?.remove(fileID)
        if let parentID = file.parentFolderID {
            state.childFileIDsByFolderID[parentID]?.removeAll { $0 == fileID }
        }
        return fileID
    }

    private func removeFolderTree(relativePath: String, rootID: UUID) -> (fileIDs: [UUID], folderIDs: [UUID], filePaths: [String], folderPaths: [String]) {
        guard var state = rootStatesByID[rootID] else { return ([], [], [], []) }
        let key = StandardizedPath.relative(relativePath)
        guard !key.isEmpty,
              let folderID = state.folderIDsByRelativePath[key],
              let folder = foldersByID[folderID]
        else { return ([], [], [], []) }

        let filePaths = state.fileIDsByRelativePath.keys
            .filter { $0 == key || $0.hasPrefix(key + "/") }
        var removedFileIDs: [UUID] = []
        var removedFilePaths: [String] = []
        for path in filePaths {
            let wasDiscoverable = state.fileIDsByRelativePath[path].map(isDiscoverableFileID) ?? false
            if let removedFileID = removeFile(relativePath: path, state: &state), wasDiscoverable {
                removedFileIDs.append(removedFileID)
                removedFilePaths.append(path)
            }
        }

        let folderPaths = state.folderIDsByRelativePath.keys
            .filter { $0 == key || $0.hasPrefix(key + "/") }
            .sorted { $0.count > $1.count }
        var removedFolderIDs: [UUID] = []
        var removedFolderPaths: [String] = []
        for path in folderPaths {
            guard let id = state.folderIDsByRelativePath.removeValue(forKey: path),
                  let removed = foldersByID.removeValue(forKey: id)
            else { continue }
            let wasDiscoverable = isDiscoverableFolderID(id)
            if wasDiscoverable {
                removedFolderIDs.append(id)
                removedFolderPaths.append(path)
            }
            managedOnlyFolderIDs.remove(id)
            folderIDsByStandardizedFullPath.removeValue(forKey: removed.standardizedFullPath)
            if let parentID = removed.parentFolderID {
                state.childFolderIDsByFolderID[parentID]?.removeAll { $0 == id }
            }
            state.childFolderIDsByFolderID.removeValue(forKey: id)
            state.childFileIDsByFolderID.removeValue(forKey: id)
        }

        if let parentID = folder.parentFolderID {
            state.childFolderIDsByFolderID[parentID]?.removeAll { $0 == folderID }
        }
        rootStatesByID[rootID] = state
        if !removedFileIDs.isEmpty {
            yieldCodemapRemoval(root: state.root, removedFileIDs: removedFileIDs, isRootUnload: false)
        }
        invalidatePathMatchSnapshot(affectedRootKinds: [state.root.kind])
        return (removedFileIDs, removedFolderIDs, removedFilePaths, removedFolderPaths)
    }

    private func invalidateAllCodemapFileAPIsCache() {
        cachedCodemapFileAPIAggregate = nil
    }

    private func isDiscoverableFileID(_ fileID: UUID) -> Bool {
        !managedOnlyFileIDs.contains(fileID)
    }

    private func isDiscoverableFolderID(_ folderID: UUID) -> Bool {
        !managedOnlyFolderIDs.contains(folderID)
    }

    private func promoteToDiscoverable(_ file: WorkspaceFileRecord) {
        if managedOnlyFileIDs.remove(file.id) != nil {
            invalidateAllCodemapFileAPIsCache()
        }
        if let folderID = file.parentFolderID, let folder = foldersByID[folderID] {
            promoteFolderToDiscoverable(folder)
        }
    }

    private func promoteFolderToDiscoverable(_ folder: WorkspaceFolderRecord) {
        var folderID: UUID? = folder.id
        while let id = folderID {
            managedOnlyFolderIDs.remove(id)
            folderID = foldersByID[id]?.parentFolderID
        }
    }

    private func ensureCodeScanResultTask() {
        guard codeScanResultTask == nil else { return }
        let actor = codeScanActor
        codeScanResultTask = Task { [weak self] in
            let stream = actor.subscribeToScanResults()
            for await results in stream {
                guard !Task.isCancelled else { break }
                await self?.applyCodeScanResults(results)
            }
        }
    }

    private func applyCodeScanResults(_ results: [CodeScanActor.ScanResult]) {
        var snapshotsByRootID: [UUID: [WorkspaceCodemapSnapshot]] = [:]
        for result in results {
            guard isDiscoverableFileID(result.fileID),
                  let file = filesByID[result.fileID],
                  let state = rootStatesByID[file.rootID],
                  state.root.standardizedFullPath == (result.rootFolderPath as NSString).standardizingPath
            else { continue }

            let snapshot = WorkspaceCodemapSnapshot(
                fileID: result.fileID,
                rootID: file.rootID,
                rootPath: state.root.standardizedFullPath,
                relativePath: file.standardizedRelativePath,
                fullPath: file.standardizedFullPath,
                modificationDate: result.modificationDate,
                fileAPI: result.fileAPI
            )
            codemapSnapshotsByFileID[result.fileID] = snapshot
            codemapFileIDsByRootID[file.rootID, default: []].insert(result.fileID)
            snapshotsByRootID[file.rootID, default: []].append(snapshot)
        }
        if !snapshotsByRootID.isEmpty {
            invalidateAllCodemapFileAPIsCache()
        }

        for (rootID, snapshots) in snapshotsByRootID {
            guard let root = rootStatesByID[rootID]?.root else { continue }
            yieldCodemapUpdate(WorkspaceCodemapUpdateEvent(
                rootID: rootID,
                rootPath: root.standardizedFullPath,
                snapshots: snapshots.sorted { $0.relativePath < $1.relativePath }
            ))
        }
    }

    private func removeAllCodemapSnapshots() {
        let fileIDsByRootID = codemapFileIDsByRootID
        guard !fileIDsByRootID.isEmpty else { return }
        codemapSnapshotsByFileID.removeAll(keepingCapacity: false)
        codemapFileIDsByRootID.removeAll(keepingCapacity: false)
        invalidateAllCodemapFileAPIsCache()
        for (rootID, fileIDs) in fileIDsByRootID {
            guard let root = rootStatesByID[rootID]?.root else { continue }
            yieldCodemapRemoval(root: root, removedFileIDs: Array(fileIDs), isRootUnload: false)
        }
    }

    @discardableResult
    private func removeCodemapSnapshots(forRootID rootID: UUID) -> [UUID] {
        guard let fileIDs = codemapFileIDsByRootID.removeValue(forKey: rootID) else { return [] }
        var removedSnapshot = false
        for fileID in fileIDs {
            removedSnapshot = codemapSnapshotsByFileID.removeValue(forKey: fileID) != nil || removedSnapshot
        }
        if removedSnapshot {
            invalidateAllCodemapFileAPIsCache()
        }
        return Array(fileIDs)
    }

    private func yieldCodemapRemoval(root: WorkspaceRootRecord, removedFileIDs: [UUID], isRootUnload: Bool) {
        guard !removedFileIDs.isEmpty || isRootUnload else { return }
        yieldCodemapUpdate(WorkspaceCodemapUpdateEvent(
            rootID: root.id,
            rootPath: root.standardizedFullPath,
            snapshots: [],
            removedFileIDs: removedFileIDs,
            isRootUnload: isRootUnload
        ))
    }

    private func yieldCodemapUpdate(_ event: WorkspaceCodemapUpdateEvent) {
        for continuation in codemapUpdateContinuations.values {
            continuation.yield(event)
        }
    }

    private func state(for rootID: UUID) throws -> RootState {
        guard let state = rootStatesByID[rootID] else {
            throw WorkspaceFileContextStoreError.rootNotLoaded(rootID)
        }
        return state
    }

    private func managedOnlyAncestorFolderIDs(for fileIDs: Set<UUID>) -> Set<UUID> {
        var folderIDs = Set<UUID>()
        for fileID in fileIDs {
            var folderID = filesByID[fileID]?.parentFolderID
            while let currentFolderID = folderID {
                folderIDs.insert(currentFolderID)
                folderID = foldersByID[currentFolderID]?.parentFolderID
            }
        }
        return folderIDs
    }

    private func makeFileTreeFolderSnapshot(
        _ folder: WorkspaceFolderRecord,
        rootStandardizedPath: String,
        state: RootState,
        visited: inout Set<UUID>,
        explicitlyIncludedManagedOnlyFileIDs: Set<UUID> = [],
        explicitlyIncludedManagedOnlyFolderIDs: Set<UUID> = []
    ) -> FileTreeFolderSnapshot? {
        guard visited.insert(folder.id).inserted else { return nil }

        let childFolders = (state.childFolderIDsByFolderID[folder.id] ?? [])
            .filter { isDiscoverableFolderID($0) || explicitlyIncludedManagedOnlyFolderIDs.contains($0) }
            .compactMap { foldersByID[$0] }
            .sorted { $0.name < $1.name }
        let childFiles = (state.childFileIDsByFolderID[folder.id] ?? [])
            .filter { isDiscoverableFileID($0) || explicitlyIncludedManagedOnlyFileIDs.contains($0) }
            .compactMap { filesByID[$0] }
            .sorted { $0.name < $1.name }

        var children: [FileTreeNodeSnapshot] = []
        children.reserveCapacity(childFolders.count + childFiles.count)
        for childFolder in childFolders {
            if let snapshot = makeFileTreeFolderSnapshot(
                childFolder,
                rootStandardizedPath: rootStandardizedPath,
                state: state,
                visited: &visited,
                explicitlyIncludedManagedOnlyFileIDs: explicitlyIncludedManagedOnlyFileIDs,
                explicitlyIncludedManagedOnlyFolderIDs: explicitlyIncludedManagedOnlyFolderIDs
            ) {
                children.append(.folder(snapshot))
            }
        }
        for file in childFiles {
            children.append(.file(FileTreeFileSnapshot(
                id: file.id,
                name: file.name,
                fileExtension: (file.name as NSString).pathExtension.isEmpty ? nil : (file.name as NSString).pathExtension,
                hasCodeMap: codemapSnapshotsByFileID[file.id]?.fullPath == file.standardizedFullPath && codemapSnapshotsByFileID[file.id]?.fileAPI != nil
            )))
        }

        return FileTreeFolderSnapshot(
            id: folder.id,
            name: folder.name,
            fullPath: folder.fullPath,
            standardizedFullPath: folder.standardizedFullPath,
            standardizedRootPath: rootStandardizedPath,
            children: children
        )
    }

    private func commit(_ indexes: RootIndexBuffers) {
        foldersByID.merge(indexes.foldersByID) { _, new in new }
        filesByID.merge(indexes.filesByID) { _, new in new }
        folderIDsByStandardizedFullPath.merge(indexes.folderIDsByStandardizedFullPath) { _, new in new }
        fileIDsByStandardizedFullPath.merge(indexes.fileIDsByStandardizedFullPath) { _, new in new }
    }

    private func indexFolders(_ items: [FSItemDTO], root: WorkspaceRootRecord, state: inout RootState, indexes: inout RootIndexBuffers) {
        for item in items {
            let relativePath = StandardizedPath.relative(item.relativePath)
            guard state.folderIDsByRelativePath[relativePath] == nil else { continue }
            let parentPath = (relativePath as NSString).deletingLastPathComponent
            let parentID = ensureParentFolderID(for: parentPath, root: root, state: &state, indexes: &indexes)
            let folder = WorkspaceFolderRecord(
                rootID: root.id,
                name: URL(fileURLWithPath: relativePath).lastPathComponent,
                relativePath: relativePath,
                fullPath: (root.fullPath as NSString).appendingPathComponent(relativePath),
                parentFolderID: parentID
            )
            indexes.foldersByID[folder.id] = folder
            indexes.folderIDsByStandardizedFullPath[folder.standardizedFullPath] = folder.id
            state.folderIDsByRelativePath[folder.standardizedRelativePath] = folder.id
            state.childFolderIDsByFolderID[parentID, default: []].append(folder.id)
        }
    }

    private func indexFiles(_ items: [FSItemDTO], root: WorkspaceRootRecord, state: inout RootState, indexes: inout RootIndexBuffers) {
        for item in items {
            let relativePath = StandardizedPath.relative(item.relativePath)
            guard state.fileIDsByRelativePath[relativePath] == nil else { continue }
            let parentID = ensureParentFolderID(for: (relativePath as NSString).deletingLastPathComponent, root: root, state: &state, indexes: &indexes)
            let file = WorkspaceFileRecord(
                rootID: root.id,
                name: URL(fileURLWithPath: relativePath).lastPathComponent,
                relativePath: relativePath,
                fullPath: (root.fullPath as NSString).appendingPathComponent(relativePath),
                parentFolderID: parentID
            )
            indexes.filesByID[file.id] = file
            indexes.fileIDsByStandardizedFullPath[file.standardizedFullPath] = file.id
            state.fileIDsByRelativePath[file.standardizedRelativePath] = file.id
            state.childFileIDsByFolderID[parentID, default: []].append(file.id)
        }
    }

    private func ensureParentFolderID(for relativePath: String, root: WorkspaceRootRecord, state: inout RootState, indexes: inout RootIndexBuffers) -> UUID {
        let key = StandardizedPath.relative(relativePath)
        if key.isEmpty || key == "." { return root.id }
        if let existing = state.folderIDsByRelativePath[key] { return existing }

        let parentPath = (key as NSString).deletingLastPathComponent
        let parentID = ensureParentFolderID(for: parentPath, root: root, state: &state, indexes: &indexes)
        let folder = WorkspaceFolderRecord(
            rootID: root.id,
            name: URL(fileURLWithPath: key).lastPathComponent,
            relativePath: key,
            fullPath: (root.fullPath as NSString).appendingPathComponent(key),
            parentFolderID: parentID
        )
        indexes.foldersByID[folder.id] = folder
        indexes.folderIDsByStandardizedFullPath[folder.standardizedFullPath] = folder.id
        state.folderIDsByRelativePath[folder.standardizedRelativePath] = folder.id
        state.childFolderIDsByFolderID[parentID, default: []].append(folder.id)
        return folder.id
    }
}

package enum WorkspaceFileContextStoreError: Error, Equatable {
    case rootNotLoaded(UUID)
    case storeDeallocated
    case rootAlreadyLoadedWithDifferentConfiguration(String)
    case rootLoadInFlightWithDifferentConfiguration(String)
    case catalogMaterializationFailed(String)
}

extension WorkspaceFileContextStoreError: LocalizedError {
    package var errorDescription: String? {
        switch self {
        case let .rootNotLoaded(id):
            "Workspace root is not loaded: \(id)."
        case .storeDeallocated:
            "Workspace file context store was deallocated."
        case let .rootAlreadyLoadedWithDifferentConfiguration(path):
            "Workspace root is already loaded with a different configuration: \(path)."
        case let .rootLoadInFlightWithDifferentConfiguration(path):
            "Workspace root load is already in flight with a different configuration: \(path)."
        case let .catalogMaterializationFailed(message):
            message
        }
    }
}
