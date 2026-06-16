import Combine
import CoreServices
import Dispatch
import Foundation

enum WorkspaceFileTreeSnapshotMode: String {
    case none
    case selected
    case full
    case folders
    case auto

    init(fileTreeOption: FileTreeOption) {
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

struct WorkspaceFileTreeSnapshotRequest {
    fileprivate let selectedFileIDs: Set<UUID>
    let mode: WorkspaceFileTreeSnapshotMode
    let filePathDisplay: FilePathDisplay
    let onlyIncludeRootsWithSelectedFiles: Bool
    let includeLegend: Bool
    let showCodeMapMarkers: Bool
    let rootScope: WorkspaceLookupRootScope
    let startPath: String?
    let maxDepth: Int?

    init(
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

struct WorkspaceObservedCodemapResult: @unchecked Sendable {
    let fullPath: String
    let modificationDate: Date
    let fileAPI: FileAPI?

    init(fullPath: String, modificationDate: Date, fileAPI: FileAPI?) {
        self.fullPath = StandardizedPath.absolute(fullPath)
        self.modificationDate = modificationDate
        self.fileAPI = fileAPI
    }
}

struct WorkspaceCodemapFileAPIAggregate {
    let orderedFileAPIs: [FileAPI]
    let firstFileAPIByStandardizedNestedPath: [String: FileAPI]
}

enum WorkspaceFileCatalogMaterializationResult: Equatable {
    case materialized(WorkspaceFileRecord)
    case ineligible(CatalogRegularFileIneligibilityReason)

    var file: WorkspaceFileRecord? {
        if case let .materialized(file) = self { return file }
        return nil
    }

    var ineligibilityReason: CatalogRegularFileIneligibilityReason? {
        if case let .ineligible(reason) = self { return reason }
        return nil
    }
}

enum WorkspaceExplicitFileMaterializationResult: Equatable {
    case materialized(WorkspaceFileRecord)
    case noCandidate
    case blocked
    case ambiguous
}

enum WorkspaceExplicitCatalogFileLookupResult: Equatable {
    case matched(WorkspaceFileRecord)
    case noCandidate
    case blocked
    case ambiguous
}

struct WorkspaceDisplayRootRefsSnapshot: Equatable {
    let visibleRoots: [WorkspaceRootRef]
    let allRoots: [WorkspaceRootRef]
}

actor WorkspaceFileContextStore {
    private struct RootState {
        let lifetimeID: UUID
        let root: WorkspaceRootRecord
        let service: FileSystemService
        var folderIDsByRelativePath: [String: UUID]
        var fileIDsByRelativePath: [String: UUID]
        var childFolderIDsByFolderID: [UUID: [UUID]]
        var childFileIDsByFolderID: [UUID: [UUID]]
    }

    private struct DetachedWatcherStop {
        let index: Int
        let rootID: UUID
        let rootPath: String
        let completionLatch: WorkspaceRootUnloadCompletionLatch
        let task: Task<Void, Never>
    }

    private struct RootLoadConfiguration: Hashable {
        let kind: WorkspaceRootKind
        let respectGitignore: Bool
        let respectRepoIgnore: Bool
        let respectCursorignore: Bool
        let skipSymlinks: Bool
        let enableHierarchicalIgnores: Bool
    }

    private enum CatalogInvalidationReason: String, Hashable {
        case fileSystemPublication = "file_system_publication"
        case rootLoad = "root_load"
        case rootUnload = "root_unload"
        case explicitMaterialization = "explicit_materialization"
        case managedFilePromotion = "managed_file_promotion"
        case catalogMutation = "catalog_mutation"
        case cacheCapacity = "cache_capacity"
    }

    private final class PublicationInvalidationBatch {
        var topologyInvalidationRequested = false
        var affectedRootKinds = Set<WorkspaceRootKind>()
        var affectedRootIDs = Set<UUID>()
        var reasons = Set<CatalogInvalidationReason>()
        var searchContentInvalidations = WorkspaceSearchContentInvalidationBatch()
    }

    private struct ScopedIngressBarrierTarget {
        let watcherAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark
        let acceptedServicePublicationSequence: UInt64

        func covers(_ other: ScopedIngressBarrierTarget) -> Bool {
            watcherAcceptedWatermark >= other.watcherAcceptedWatermark
                && acceptedServicePublicationSequence >= other.acceptedServicePublicationSequence
        }

        func merging(_ other: ScopedIngressBarrierTarget) -> ScopedIngressBarrierTarget {
            ScopedIngressBarrierTarget(
                watcherAcceptedWatermark: max(watcherAcceptedWatermark, other.watcherAcceptedWatermark),
                acceptedServicePublicationSequence: max(
                    acceptedServicePublicationSequence,
                    other.acceptedServicePublicationSequence
                )
            )
        }
    }

    private struct ScopedIngressBarrierCompletedCut {
        let target: ScopedIngressBarrierTarget
        let sample: WorkspaceIngressBarrierSample
    }

    #if DEBUG
        private struct ScopedIngressBarrierTaskOutput {
            let sample: WorkspaceIngressBarrierSample
            let completedAtNanoseconds: UInt64
        }
    #else
        private typealias ScopedIngressBarrierTaskOutput = WorkspaceIngressBarrierSample
    #endif

    private final class ScopedIngressBarrierJoin: @unchecked Sendable {
        private let lock = NSLock()
        private var isCompleted = false
        private var completedOutput: ScopedIngressBarrierTaskOutput?
        private var waiters: [UUID: CheckedContinuation<ScopedIngressBarrierTaskOutput?, Never>] = [:]

        func value() async -> ScopedIngressBarrierTaskOutput? {
            let waiterID = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    lock.lock()
                    if Task.isCancelled {
                        lock.unlock()
                        continuation.resume(returning: nil)
                    } else if isCompleted {
                        let output = completedOutput
                        lock.unlock()
                        continuation.resume(returning: output)
                    } else {
                        waiters[waiterID] = continuation
                        lock.unlock()
                    }
                }
            } onCancel: {
                cancelWaiter(id: waiterID)
            }
        }

        func complete(with output: ScopedIngressBarrierTaskOutput?) {
            let continuations: [CheckedContinuation<ScopedIngressBarrierTaskOutput?, Never>]
            lock.lock()
            guard !isCompleted else {
                lock.unlock()
                return
            }
            isCompleted = true
            completedOutput = output
            continuations = Array(waiters.values)
            waiters.removeAll(keepingCapacity: false)
            lock.unlock()
            continuations.forEach { $0.resume(returning: output) }
        }

        private func cancelWaiter(id waiterID: UUID) {
            let continuation: CheckedContinuation<ScopedIngressBarrierTaskOutput?, Never>?
            lock.lock()
            continuation = waiters.removeValue(forKey: waiterID)
            lock.unlock()
            continuation?.resume(returning: nil)
        }
    }

    private final class ScopedIngressBarrierFlight {
        let token: UInt64
        let target: ScopedIngressBarrierTarget
        let join: ScopedIngressBarrierJoin
        var task: Task<Void, Never>?
        #if DEBUG
            let startedAtNanoseconds: UInt64
        #endif

        init(
            token: UInt64,
            target: ScopedIngressBarrierTarget,
            join: ScopedIngressBarrierJoin,
            startedAtNanoseconds: UInt64 = 0
        ) {
            self.token = token
            self.target = target
            self.join = join
            #if DEBUG
                self.startedAtNanoseconds = startedAtNanoseconds
            #endif
        }
    }

    private final class ScopedIngressBarrierPendingFlight {
        var target: ScopedIngressBarrierTarget
        let join: ScopedIngressBarrierJoin
        #if DEBUG
            let enqueuedAtNanoseconds: UInt64
        #endif

        init(
            target: ScopedIngressBarrierTarget,
            join: ScopedIngressBarrierJoin,
            enqueuedAtNanoseconds: UInt64 = 0
        ) {
            self.target = target
            self.join = join
            #if DEBUG
                self.enqueuedAtNanoseconds = enqueuedAtNanoseconds
            #endif
        }
    }

    private final class ScopedIngressBarrierRootFlightState {
        var active: ScopedIngressBarrierFlight?
        var pending: ScopedIngressBarrierPendingFlight?

        init(
            active: ScopedIngressBarrierFlight? = nil,
            pending: ScopedIngressBarrierPendingFlight? = nil
        ) {
            self.active = active
            self.pending = pending
        }
    }

    #if DEBUG
        struct ScopedIngressBarrierStats: Equatable {
            let launchCount: Int
            let joinCount: Int
            let successorCount: Int
            let coalescedSuccessorCount: Int
            let noopCount: Int
        }

        struct ScopedIngressBarrierDebugSnapshot: Equatable {
            struct Active: Equatable {
                let targetWatcherWatermark: UInt64
                let targetServicePublicationSequence: UInt64
                let ageMilliseconds: UInt64
            }

            struct Pending: Equatable {
                let targetWatcherWatermark: UInt64
                let targetServicePublicationSequence: UInt64
                let ageMilliseconds: UInt64
            }

            struct Completed: Equatable {
                let token: UInt64
                let targetWatcherWatermark: UInt64
                let targetServicePublicationSequence: UInt64
                let publishedServicePublicationSequence: UInt64
                let appliedServicePublicationSequence: UInt64
                let appliedWatcherWatermark: UInt64
                let durationMilliseconds: UInt64
            }

            let launchCount: Int
            let joinCount: Int
            let successorCount: Int
            let coalescedSuccessorCount: Int
            let completionCount: Int
            let noopCount: Int
            let totalWaitMilliseconds: UInt64
            let maxWaitMilliseconds: UInt64
            let active: Active?
            let pending: Pending?
            let lastCompleted: Completed?
        }

        struct PublicationInvalidationDebugSample: Equatable {
            let servicePublicationSequence: UInt64
            let watcherAcceptedWatermark: UInt64?
            let preparedDeltaCount: Int
            let topologyInvalidationCount: Int
            let catalogGenerationAdvanceCount: Int
            let searchCatalogCacheClearCount: Int
            let pathWorkerInvalidationRequestCount: Int
            let contentInvalidationCount: Int
            let distinctContentKeyCount: Int
            let decodedCacheInvalidationRequestCount: Int
            let codemapInvalidationRequestCount: Int
            let appliedIndexEventYieldCount: Int
        }

        struct PublicationInvalidationHistoryDebugSnapshot: Equatable {
            let retainedSampleLimit: Int
            let totalObservedPublicationCount: Int
            let droppedPublicationSampleCount: Int
            let samples: [PublicationInvalidationDebugSample]
        }

        struct CatalogInvalidationDebugEvent: Equatable {
            let sequence: UInt64
            let reasons: [String]
            let affectedRootIDs: [UUID]
            let affectedRootKinds: [String]
            let evictedScopes: [String]
        }

        struct CatalogRebuildDebugSnapshot: Equatable {
            let rebuildCount: Int
            let filterMicroseconds: UInt64
            let sortMicroseconds: UInt64
            let materializationMicroseconds: UInt64
            let totalMicroseconds: UInt64
            let lastFileCount: Int
            let lastRootCount: Int
        }

        struct RootCatalogShardGenerationDebugSnapshot: Equatable {
            let rootID: UUID
            let publishedTopologyGeneration: UInt64?
            let liveTopologyGenerations: [UInt64]
            let retainedTopologyGenerations: [UInt64]
            let buildCount: Int
            let pathIndexBuildCount: Int
            let patchCount: Int
            let authoritativeRebuildCount: Int
            let fallbackReasonCounts: [String: Int]
            let lastAppliedIndexGeneration: UInt64?
            let deltaStateDirty: Bool
            let backstopCount: Int
            let maxLiveGenerationCount: Int
        }

        struct RootCatalogShardDebugSnapshot: Equatable {
            let liveGenerationCapPerRoot: Int
            let maxPatchLogicalMutationCount: Int
            let publishedShardCount: Int
            let totalBuildCount: Int
            let totalBackstopCount: Int
            let shadowComparisonCount: Int
            let shadowMismatchCount: Int
            let lastShadowByteCount: Int
            let roots: [RootCatalogShardGenerationDebugSnapshot]
        }

        struct StoreWorkDiagnosticsSnapshot: Equatable {
            let invalidations: [CatalogInvalidationDebugEvent]
            let catalogRebuild: CatalogRebuildDebugSnapshot
            let rootCatalogShards: RootCatalogShardDebugSnapshot
        }

        struct ReadSearchRootDiagnosticsSnapshot: Equatable {
            let rootID: UUID
            let rootToken: UUID
            let rootPath: String
            let rootKind: String
            let crawlCount: Int
            let watcherActive: Bool
            let ingress: WorkspaceFileSystemIngressCoordinator.DebugSnapshot
            let barrier: ScopedIngressBarrierDebugSnapshot
            let freshness: FileSystemService.FreshnessWorkDiagnosticsSnapshot
            let invalidation: PublicationInvalidationHistoryDebugSnapshot
            let producedAppliedIndexGeneration: UInt64
        }

        private final class PublicationInvalidationRecorder: @unchecked Sendable {
            let preparedDeltaCount: Int
            var topologyInvalidationCount = 0
            var catalogGenerationAdvanceCount = 0
            var searchCatalogCacheClearCount = 0
            var pathWorkerInvalidationRequestCount = 0
            var contentInvalidationCount = 0
            var decodedCacheInvalidationRequestCount = 0
            var codemapInvalidationRequestCount = 0
            var appliedIndexEventYieldCount = 0
            var distinctContentKeys = Set<WorkspaceSearchContentCacheKey>()

            init(preparedDeltaCount: Int) {
                self.preparedDeltaCount = preparedDeltaCount
            }
        }

        private struct PublicationInvalidationHistoryState {
            var totalObservedPublicationCount = 0
            var samples: [PublicationInvalidationDebugSample] = []
        }

        @TaskLocal private static var activePublicationInvalidationRecorder: PublicationInvalidationRecorder?
        private static let publicationInvalidationSampleLimit = 32
    #endif

    #if DEBUG
        private var rootLoadWillStartHandler: (@Sendable (String) async -> Void)?
        private var rootLoadDidJoinInFlightHandler: (@Sendable (String) async -> Void)?
        private var rootUnloadDidDetachHandler: (@Sendable ([String]) async -> Void)?
        private var ensureIndexedFilesEligibilityDidResolveHandler: (@Sendable (UUID, String) async -> Void)?
        private var watcherSinkWillApplyHandler: (@Sendable (UUID) async -> Void)?
        private var publisherIngressWillWaitHandler: (@Sendable (Set<UUID>) async -> Void)?
        private var watcherServiceStateWillReconcileHandler: (@Sendable (UUID, Bool) async -> Void)?
        private var watcherStopWillBeginHandler: (@Sendable (UUID) async -> Void)?
        private var rootUnloadTerminationDidCompleteHandler: (@Sendable (WorkspaceRootUnloadTerminationDiagnostics) async -> Void)?
        private var appliedIngressDidCaptureWatermarksHandler: (@Sendable ([UUID: UInt64]) async -> Void)?
        private var scopedIngressBarrierWillFlushHandler: (@Sendable (UUID) async -> Void)?
        private var watcherActivationFailurePointForNewServicesForTesting: FileSystemService.WatcherActivationFailurePoint?
        private var scopedIngressBarrierLaunchCountsByRootID: [UUID: Int] = [:]
        private var scopedIngressBarrierJoinCountsByRootID: [UUID: Int] = [:]
        private var scopedIngressBarrierSuccessorCountsByRootID: [UUID: Int] = [:]
        private var scopedIngressBarrierCoalescedSuccessorCountsByRootID: [UUID: Int] = [:]
        private var scopedIngressBarrierCompletionCountsByRootID: [UUID: Int] = [:]
        private var scopedIngressBarrierNoopCountsByRootID: [UUID: Int] = [:]
        private var scopedIngressBarrierTotalWaitMillisecondsByRootID: [UUID: UInt64] = [:]
        private var scopedIngressBarrierMaxWaitMillisecondsByRootID: [UUID: UInt64] = [:]
        private var lastCompletedScopedIngressBarrierByRootID: [UUID: ScopedIngressBarrierDebugSnapshot.Completed] = [:]
        private var publicationInvalidationHistoryByRootID: [UUID: PublicationInvalidationHistoryState] = [:]
        private var rootCrawlCountsByRootID: [UUID: Int] = [:]
        private var nextCatalogInvalidationSequence: UInt64 = 0
        private var catalogInvalidationHistory: [CatalogInvalidationDebugEvent] = []
        private var catalogRebuildCount = 0
        private var catalogRebuildFilterMicroseconds: UInt64 = 0
        private var catalogRebuildSortMicroseconds: UInt64 = 0
        private var catalogRebuildMaterializationMicroseconds: UInt64 = 0
        private var catalogRebuildTotalMicroseconds: UInt64 = 0
        private var catalogRebuildLastFileCount = 0
        private var catalogRebuildLastRootCount = 0
        private var rootCatalogShardBuildCountsByRootID: [UUID: Int] = [:]
        private var rootCatalogShardPatchCountsByRootID: [UUID: Int] = [:]
        private var rootCatalogShardAuthoritativeRebuildCountsByRootID: [UUID: Int] = [:]
        private var rootCatalogShardFallbackReasonCountsByRootID: [UUID: [String: Int]] = [:]
        private var rootCatalogShardBackstopCountsByRootID: [UUID: Int] = [:]
        private var rootCatalogShardMaxLiveGenerationCountsByRootID: [UUID: Int] = [:]
        private var rootCatalogShardShadowComparisonCount = 0
        private var rootCatalogShardShadowMismatchCount = 0
        private var rootCatalogShardLastShadowByteCount = 0

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

        func setWatcherStopWillBeginHandler(_ handler: (@Sendable (UUID) async -> Void)?) {
            watcherStopWillBeginHandler = handler
        }

        func setRootUnloadTerminationDidCompleteHandler(
            _ handler: (@Sendable (WorkspaceRootUnloadTerminationDiagnostics) async -> Void)?
        ) {
            rootUnloadTerminationDidCompleteHandler = handler
        }

        func setAppliedIngressDidCaptureWatermarksHandler(_ handler: (@Sendable ([UUID: UInt64]) async -> Void)?) {
            appliedIngressDidCaptureWatermarksHandler = handler
        }

        func setScopedIngressBarrierWillFlushHandler(_ handler: (@Sendable (UUID) async -> Void)?) {
            scopedIngressBarrierWillFlushHandler = handler
        }

        func setWatcherActivationFailureForNewServicesForTesting(
            _ failurePoint: FileSystemService.WatcherActivationFailurePoint?
        ) {
            watcherActivationFailurePointForNewServicesForTesting = failurePoint
        }

        func scopedIngressBarrierStatsForTesting(rootID: UUID) -> ScopedIngressBarrierStats {
            ScopedIngressBarrierStats(
                launchCount: scopedIngressBarrierLaunchCountsByRootID[rootID] ?? 0,
                joinCount: scopedIngressBarrierJoinCountsByRootID[rootID] ?? 0,
                successorCount: scopedIngressBarrierSuccessorCountsByRootID[rootID] ?? 0,
                coalescedSuccessorCount: scopedIngressBarrierCoalescedSuccessorCountsByRootID[rootID] ?? 0,
                noopCount: scopedIngressBarrierNoopCountsByRootID[rootID] ?? 0
            )
        }

        func scopedIngressBarrierFlightCountForTesting() -> Int {
            scopedIngressBarrierFlightStatesByRootID.values.reduce(0) { count, state in
                count + (state.active == nil ? 0 : 1) + (state.pending == nil ? 0 : 1)
            }
        }

        func fileSystemServiceForTesting(rootID: UUID) -> FileSystemService? {
            rootStatesByID[rootID]?.service
        }

        func readSearchRootDiagnosticsSnapshot(
            recentPublicationLimit: Int = 8
        ) async -> [ReadSearchRootDiagnosticsSnapshot] {
            let requestedLimit = min(max(0, recentPublicationLimit), Self.publicationInvalidationSampleLimit)
            var snapshots: [ReadSearchRootDiagnosticsSnapshot] = []
            snapshots.reserveCapacity(rootLoadOrder.count)
            for rootID in rootLoadOrder {
                guard let state = rootStatesByID[rootID] else { continue }
                let history = publicationInvalidationHistoryByRootID[rootID] ?? PublicationInvalidationHistoryState()
                let freshness = await state.service.freshnessWorkDiagnosticsSnapshot()
                let watcherActive = await state.service.isWatchingForChangesForTesting()
                snapshots.append(ReadSearchRootDiagnosticsSnapshot(
                    rootID: rootID,
                    rootToken: state.service.diagnosticRootToken,
                    rootPath: state.root.standardizedFullPath,
                    rootKind: Self.rootKindDiagnosticLabel(state.root.kind),
                    crawlCount: rootCrawlCountsByRootID[rootID] ?? 0,
                    watcherActive: watcherActive,
                    ingress: publisherIngressCoordinator.debugSnapshot(rootID: rootID),
                    barrier: scopedIngressBarrierDebugSnapshot(rootID: rootID),
                    freshness: freshness,
                    invalidation: PublicationInvalidationHistoryDebugSnapshot(
                        retainedSampleLimit: Self.publicationInvalidationSampleLimit,
                        totalObservedPublicationCount: history.totalObservedPublicationCount,
                        droppedPublicationSampleCount: max(0, history.totalObservedPublicationCount - history.samples.count),
                        samples: requestedLimit == 0 ? [] : Array(history.samples.suffix(requestedLimit))
                    ),
                    producedAppliedIndexGeneration: appliedIndexGenerationsByRootID[rootID] ?? 0
                ))
            }
            return snapshots
        }

        func storeWorkDiagnosticsSnapshot() -> StoreWorkDiagnosticsSnapshot {
            StoreWorkDiagnosticsSnapshot(
                invalidations: catalogInvalidationHistory,
                catalogRebuild: CatalogRebuildDebugSnapshot(
                    rebuildCount: catalogRebuildCount,
                    filterMicroseconds: catalogRebuildFilterMicroseconds,
                    sortMicroseconds: catalogRebuildSortMicroseconds,
                    materializationMicroseconds: catalogRebuildMaterializationMicroseconds,
                    totalMicroseconds: catalogRebuildTotalMicroseconds,
                    lastFileCount: catalogRebuildLastFileCount,
                    lastRootCount: catalogRebuildLastRootCount
                ),
                rootCatalogShards: rootCatalogShardDebugSnapshot()
            )
        }

        private func recordCatalogInvalidation(
            reasons: Set<CatalogInvalidationReason>,
            affectedRootIDs: Set<UUID>,
            affectedRootKinds: Set<WorkspaceRootKind>,
            evictedScopes: [WorkspaceLookupRootScope]
        ) {
            nextCatalogInvalidationSequence &+= 1
            catalogInvalidationHistory.append(CatalogInvalidationDebugEvent(
                sequence: nextCatalogInvalidationSequence,
                reasons: reasons.map(\.rawValue).sorted(),
                affectedRootIDs: affectedRootIDs.sorted { $0.uuidString < $1.uuidString },
                affectedRootKinds: affectedRootKinds.map(Self.rootKindDiagnosticLabel).sorted(),
                evictedScopes: evictedScopes.map(Self.scopeDiagnosticLabel).sorted()
            ))
            if catalogInvalidationHistory.count > 64 {
                catalogInvalidationHistory.removeFirst(catalogInvalidationHistory.count - 64)
            }
        }

        private func recordCatalogRebuild(
            filterMicroseconds: UInt64,
            sortMicroseconds: UInt64,
            materializationMicroseconds: UInt64,
            totalMicroseconds: UInt64,
            fileCount: Int,
            rootCount: Int
        ) {
            catalogRebuildCount += 1
            catalogRebuildFilterMicroseconds &+= filterMicroseconds
            catalogRebuildSortMicroseconds &+= sortMicroseconds
            catalogRebuildMaterializationMicroseconds &+= materializationMicroseconds
            catalogRebuildTotalMicroseconds &+= totalMicroseconds
            catalogRebuildLastFileCount = fileCount
            catalogRebuildLastRootCount = rootCount
        }

        private func rootCatalogShardDebugSnapshot() -> RootCatalogShardDebugSnapshot {
            var trackedRootIDs = Set(rootStatesByID.keys)
            trackedRootIDs.formUnion(publishedRootCatalogShardsByRootID.keys)
            trackedRootIDs.formUnion(rootCatalogShardWeakReferencesByRootID.keys)

            let staleDiagnosticRootIDs = Set(rootCatalogShardBuildCountsByRootID.keys).subtracting(trackedRootIDs)
            for rootID in staleDiagnosticRootIDs {
                rootCatalogShardBuildCountsByRootID.removeValue(forKey: rootID)
                rootCatalogShardPatchCountsByRootID.removeValue(forKey: rootID)
                rootCatalogShardAuthoritativeRebuildCountsByRootID.removeValue(forKey: rootID)
                rootCatalogShardFallbackReasonCountsByRootID.removeValue(forKey: rootID)
                rootCatalogShardBackstopCountsByRootID.removeValue(forKey: rootID)
                rootCatalogShardMaxLiveGenerationCountsByRootID.removeValue(forKey: rootID)
            }

            let roots = trackedRootIDs.sorted { $0.uuidString < $1.uuidString }.map { rootID in
                let liveShards = liveRootCatalogShards(rootID: rootID)
                let publishedShard = publishedRootCatalogShardsByRootID[rootID]
                let liveGenerations = liveShards.map(\.key.topologyGeneration).sorted()
                let retainedGenerations = liveShards.compactMap { shard -> UInt64? in
                    guard let publishedShard else { return shard.key.topologyGeneration }
                    return shard === publishedShard ? nil : shard.key.topologyGeneration
                }.sorted()
                let maxLiveCount = max(
                    rootCatalogShardMaxLiveGenerationCountsByRootID[rootID] ?? 0,
                    liveShards.count
                )
                rootCatalogShardMaxLiveGenerationCountsByRootID[rootID] = maxLiveCount
                return RootCatalogShardGenerationDebugSnapshot(
                    rootID: rootID,
                    publishedTopologyGeneration: publishedShard?.key.topologyGeneration,
                    liveTopologyGenerations: liveGenerations,
                    retainedTopologyGenerations: retainedGenerations,
                    buildCount: rootCatalogShardBuildCountsByRootID[rootID] ?? 0,
                    pathIndexBuildCount: rootCatalogShardBuildCountsByRootID[rootID] ?? 0,
                    patchCount: rootCatalogShardPatchCountsByRootID[rootID] ?? 0,
                    authoritativeRebuildCount: rootCatalogShardAuthoritativeRebuildCountsByRootID[rootID] ?? 0,
                    fallbackReasonCounts: rootCatalogShardFallbackReasonCountsByRootID[rootID] ?? [:],
                    lastAppliedIndexGeneration: rootCatalogShardDeltaStatesByRootID[rootID]?.lastAppliedIndexGeneration,
                    deltaStateDirty: rootCatalogShardDeltaStatesByRootID[rootID]?.isDirty ?? false,
                    backstopCount: rootCatalogShardBackstopCountsByRootID[rootID] ?? 0,
                    maxLiveGenerationCount: maxLiveCount
                )
            }
            return RootCatalogShardDebugSnapshot(
                liveGenerationCapPerRoot: Self.maxLiveRootCatalogShardGenerationsPerRoot,
                maxPatchLogicalMutationCount: Self.maxRootCatalogShardPatchLogicalMutationCount,
                publishedShardCount: publishedRootCatalogShardsByRootID.count,
                totalBuildCount: rootCatalogShardBuildCountsByRootID.values.reduce(0, +),
                totalBackstopCount: rootCatalogShardBackstopCountsByRootID.values.reduce(0, +),
                shadowComparisonCount: rootCatalogShardShadowComparisonCount,
                shadowMismatchCount: rootCatalogShardShadowMismatchCount,
                lastShadowByteCount: rootCatalogShardLastShadowByteCount,
                roots: roots
            )
        }

        private static func rootKindDiagnosticLabel(_ kind: WorkspaceRootKind) -> String {
            switch kind {
            case .primaryWorkspace: "primary_workspace"
            case .workspaceGitData: "workspace_git_data"
            case .supplementalSystem: "supplemental_system"
            case .sessionWorktree: "session_worktree"
            }
        }

        private static func scopeDiagnosticLabel(_ scope: WorkspaceLookupRootScope) -> String {
            switch scope {
            case .visibleWorkspace:
                "visible_workspace"
            case .visibleWorkspacePlusGitData:
                "visible_workspace_plus_git_data"
            case .allLoaded:
                "all_loaded"
            case let .sessionBoundWorkspace(logicalRootPaths, physicalRootPaths):
                "session_bound_workspace(logical=\(logicalRootPaths.sorted().joined(separator: ","));physical=\(physicalRootPaths.sorted().joined(separator: ",")))"
            }
        }

        private static func debugElapsedMicroseconds(since start: UInt64, through end: UInt64) -> UInt64 {
            end >= start ? (end - start) / 1000 : 0
        }

        private func scopedIngressBarrierDebugSnapshot(rootID: UUID) -> ScopedIngressBarrierDebugSnapshot {
            let now = debugNowNanoseconds()
            let state = scopedIngressBarrierFlightStatesByRootID[rootID]
            let active = state?.active.map { flight in
                ScopedIngressBarrierDebugSnapshot.Active(
                    targetWatcherWatermark: flight.target.watcherAcceptedWatermark.rawValue,
                    targetServicePublicationSequence: flight.target.acceptedServicePublicationSequence,
                    ageMilliseconds: Self.elapsedMilliseconds(
                        since: flight.startedAtNanoseconds,
                        now: now
                    )
                )
            }
            let pending = state?.pending.map { pending in
                ScopedIngressBarrierDebugSnapshot.Pending(
                    targetWatcherWatermark: pending.target.watcherAcceptedWatermark.rawValue,
                    targetServicePublicationSequence: pending.target.acceptedServicePublicationSequence,
                    ageMilliseconds: Self.elapsedMilliseconds(
                        since: pending.enqueuedAtNanoseconds,
                        now: now
                    )
                )
            }
            return ScopedIngressBarrierDebugSnapshot(
                launchCount: scopedIngressBarrierLaunchCountsByRootID[rootID] ?? 0,
                joinCount: scopedIngressBarrierJoinCountsByRootID[rootID] ?? 0,
                successorCount: scopedIngressBarrierSuccessorCountsByRootID[rootID] ?? 0,
                coalescedSuccessorCount: scopedIngressBarrierCoalescedSuccessorCountsByRootID[rootID] ?? 0,
                completionCount: scopedIngressBarrierCompletionCountsByRootID[rootID] ?? 0,
                noopCount: scopedIngressBarrierNoopCountsByRootID[rootID] ?? 0,
                totalWaitMilliseconds: scopedIngressBarrierTotalWaitMillisecondsByRootID[rootID] ?? 0,
                maxWaitMilliseconds: scopedIngressBarrierMaxWaitMillisecondsByRootID[rootID] ?? 0,
                active: active,
                pending: pending,
                lastCompleted: lastCompletedScopedIngressBarrierByRootID[rootID]
            )
        }

        func retainedReadSearchDiagnosticRootIDsForTesting() -> Set<UUID> {
            Set(scopedIngressBarrierLaunchCountsByRootID.keys)
                .union(scopedIngressBarrierJoinCountsByRootID.keys)
                .union(scopedIngressBarrierSuccessorCountsByRootID.keys)
                .union(scopedIngressBarrierCoalescedSuccessorCountsByRootID.keys)
                .union(scopedIngressBarrierCompletionCountsByRootID.keys)
                .union(scopedIngressBarrierNoopCountsByRootID.keys)
                .union(scopedIngressBarrierTotalWaitMillisecondsByRootID.keys)
                .union(scopedIngressBarrierMaxWaitMillisecondsByRootID.keys)
                .union(lastCompletedScopedIngressBarrierByRootID.keys)
                .union(publicationInvalidationHistoryByRootID.keys)
                .union(rootCrawlCountsByRootID.keys)
        }

        private func recordScopedIngressBarrierCompletion(
            rootID: UUID,
            token: UInt64,
            target: ScopedIngressBarrierTarget,
            sample: WorkspaceIngressBarrierSample,
            startedAtNanoseconds: UInt64,
            completedAtNanoseconds: UInt64
        ) {
            guard rootStatesByID[rootID] != nil else { return }
            scopedIngressBarrierCompletionCountsByRootID[rootID, default: 0] += 1
            let durationMilliseconds = Self.elapsedMilliseconds(
                since: startedAtNanoseconds,
                now: completedAtNanoseconds
            )
            scopedIngressBarrierTotalWaitMillisecondsByRootID[rootID, default: 0] += durationMilliseconds
            scopedIngressBarrierMaxWaitMillisecondsByRootID[rootID] = max(
                scopedIngressBarrierMaxWaitMillisecondsByRootID[rootID] ?? 0,
                durationMilliseconds
            )
            guard token > (lastCompletedScopedIngressBarrierByRootID[rootID]?.token ?? 0) else { return }
            lastCompletedScopedIngressBarrierByRootID[rootID] = ScopedIngressBarrierDebugSnapshot.Completed(
                token: token,
                targetWatcherWatermark: target.watcherAcceptedWatermark.rawValue,
                targetServicePublicationSequence: target.acceptedServicePublicationSequence,
                publishedServicePublicationSequence: sample.publishedServicePublicationSequence,
                appliedServicePublicationSequence: sample.appliedServicePublicationSequence,
                appliedWatcherWatermark: sample.appliedWatcherWatermark,
                durationMilliseconds: durationMilliseconds
            )
        }

        private func recordPublicationInvalidationDiagnostics(
            rootID: UUID,
            servicePublicationSequence: UInt64,
            watcherAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark?,
            recorder: PublicationInvalidationRecorder
        ) {
            guard rootStatesByID[rootID] != nil else { return }
            let sample = makePublicationInvalidationDebugSample(
                servicePublicationSequence: servicePublicationSequence,
                watcherAcceptedWatermark: watcherAcceptedWatermark,
                recorder: recorder
            )
            var history = publicationInvalidationHistoryByRootID[rootID] ?? PublicationInvalidationHistoryState()
            history.totalObservedPublicationCount += 1
            history.samples.append(sample)
            if history.samples.count > Self.publicationInvalidationSampleLimit {
                history.samples.removeFirst(history.samples.count - Self.publicationInvalidationSampleLimit)
            }
            publicationInvalidationHistoryByRootID[rootID] = history
        }

        private func makePublicationInvalidationDebugSample(
            servicePublicationSequence: UInt64,
            watcherAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark?,
            recorder: PublicationInvalidationRecorder
        ) -> PublicationInvalidationDebugSample {
            PublicationInvalidationDebugSample(
                servicePublicationSequence: servicePublicationSequence,
                watcherAcceptedWatermark: watcherAcceptedWatermark?.rawValue,
                preparedDeltaCount: recorder.preparedDeltaCount,
                topologyInvalidationCount: recorder.topologyInvalidationCount,
                catalogGenerationAdvanceCount: recorder.catalogGenerationAdvanceCount,
                searchCatalogCacheClearCount: recorder.searchCatalogCacheClearCount,
                pathWorkerInvalidationRequestCount: recorder.pathWorkerInvalidationRequestCount,
                contentInvalidationCount: recorder.contentInvalidationCount,
                distinctContentKeyCount: recorder.distinctContentKeys.count,
                decodedCacheInvalidationRequestCount: recorder.decodedCacheInvalidationRequestCount,
                codemapInvalidationRequestCount: recorder.codemapInvalidationRequestCount,
                appliedIndexEventYieldCount: recorder.appliedIndexEventYieldCount
            )
        }

        private static func elapsedMilliseconds(since start: UInt64, now: UInt64) -> UInt64 {
            guard now >= start else { return 0 }
            return (now - start) / 1_000_000
        }

        func searchDecodedContentCacheSnapshotForTesting() async -> WorkspaceSearchDecodedContentCache.Snapshot {
            await searchDecodedContentCache.snapshotForTesting()
        }

        func interactiveReadCacheSnapshotForTesting() async -> WorkspaceInteractiveReadCache.Snapshot {
            await interactiveReadCache.snapshotForTesting()
        }

        func searchLaneSnapshotForTesting() async -> StoreBackedWorkspaceSearchLane.Snapshot {
            await storeBackedSearchLane.snapshotForTesting()
        }

        func configureSearchLaneForTesting(
            _ configuration: StoreBackedWorkspaceSearchLane.Configuration
        ) async -> StoreBackedWorkspaceSearchLane.DebugConfigurationUpdateResult {
            await storeBackedSearchLane.configureForTesting(configuration)
        }

        func resetSearchLaneConfigurationForTesting() async -> StoreBackedWorkspaceSearchLane.DebugConfigurationUpdateResult {
            await storeBackedSearchLane.resetConfigurationForTesting()
        }

        func setSearchLanePermitAcquiredHandlerForTesting(
            _ handler: (@Sendable () async -> Void)?
        ) async {
            await storeBackedSearchLane.setPermitAcquiredHandlerForTesting(handler)
        }

        func setSearchContentReadChunkHandlerForTesting(
            rootID: UUID,
            _ handler: (@Sendable (String) async -> Void)?
        ) async throws {
            let state = try state(for: rootID)
            await state.service.setContentReadChunkHandlerForTesting(handler)
        }

        func resetSearchContentFingerprintRequestCountForTesting(rootID: UUID) async throws {
            let state = try state(for: rootID)
            await state.service.resetContentFingerprintRequestCountForTesting()
        }

        func searchContentFingerprintRequestCountForTesting(rootID: UUID) async throws -> Int {
            let state = try state(for: rootID)
            return await state.service.contentFingerprintRequestCountSnapshotForTesting()
        }

        func setCachedSearchContentWatcherActiveOverrideForTesting(
            rootID: UUID,
            _ isActive: Bool?
        ) async throws {
            let state = try state(for: rootID)
            await state.service.setCachedSearchContentWatcherActiveOverrideForTesting(isActive)
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

    private struct RootCatalogCanonicalConfigurationIdentity: Hashable {
        let canonicalPath: String
        let loadConfiguration: RootLoadConfiguration
    }

    private struct RootCatalogShardKey: Hashable {
        let canonicalConfigurationIdentity: RootCatalogCanonicalConfigurationIdentity
        let rootID: UUID
        let lifetimeID: UUID
        let topologyGeneration: UInt64
    }

    private final class RootCatalogShard: @unchecked Sendable {
        let key: RootCatalogShardKey
        let root: WorkspaceRootRecord
        let files: [WorkspaceFileRecord]
        let folders: [WorkspaceFolderRecord]
        let entries: [WorkspaceSearchCatalogEntry]
        let pathSearchIndex: WorkspaceSearchRootPathIndex
        let appliedIndexGeneration: UInt64

        var folderCount: Int {
            folders.count
        }

        init(
            key: RootCatalogShardKey,
            root: WorkspaceRootRecord,
            files: [WorkspaceFileRecord],
            folders: [WorkspaceFolderRecord],
            entries: [WorkspaceSearchCatalogEntry],
            appliedIndexGeneration: UInt64
        ) {
            self.key = key
            self.root = root
            self.files = files
            self.folders = folders
            self.entries = entries
            pathSearchIndex = WorkspaceSearchRootPathIndex(
                identity: WorkspaceSearchRootPathIndexIdentity(
                    rootID: key.rootID,
                    lifetimeID: key.lifetimeID,
                    topologyGeneration: key.topologyGeneration
                ),
                rootPath: root.standardizedFullPath,
                entries: entries
            )
            self.appliedIndexGeneration = appliedIndexGeneration
        }
    }

    private final class WeakRootCatalogShardReference {
        weak var shard: RootCatalogShard?

        init(_ shard: RootCatalogShard) {
            self.shard = shard
        }
    }

    private struct RootCatalogMergeCursor {
        let shardIndex: Int
        let elementIndex: Int
    }

    private struct AuthoritativeCatalogComponents {
        let files: [WorkspaceFileRecord]
        let folders: [WorkspaceFolderRecord]
        let entries: [WorkspaceSearchCatalogEntry]
    }

    private struct RootCatalogShardDeltaState {
        let lifetimeID: UUID
        var lastAppliedIndexGeneration: UInt64
        var isDirty: Bool
    }

    private enum RootCatalogShardFallbackReason: String {
        case missingShard = "missing_shard"
        case generationGap = "generation_gap"
        case generationOverflow = "generation_overflow"
        case fullResync = "full_resync"
        case dirtyRecovery = "dirty_recovery"
        case thresholdExceeded = "threshold_exceeded"
        case unsafeAmbiguity = "unsafe_ambiguity"
        case unload
        case retentionBackstop = "retention_backstop"
    }

    private enum RootCatalogShardBuildKind {
        case patch
        case authoritative
    }

    private struct RootCatalogShardBuilderOutput {
        let files: [WorkspaceFileRecord]
        let folders: [WorkspaceFolderRecord]
        let logicalMutationCount: Int
    }

    private struct SearchCatalogRootDependency: Hashable {
        let canonicalIdentity: String
        let rootID: UUID
        let lifetimeID: UUID
        let generation: UInt64
    }

    private enum SearchCatalogSnapshotValidationToken: Hashable {
        case staticScope(generation: UInt64)
        case sessionBound(
            logicalRootPaths: [String],
            physicalRootPaths: [String],
            dependencies: [SearchCatalogRootDependency]
        )
    }

    private struct SearchCatalogSnapshotCacheEntry {
        let validationToken: SearchCatalogSnapshotValidationToken
        let snapshot: WorkspaceSearchCatalogSnapshot
        var lastAccessSequence: UInt64
    }

    private struct SessionCatalogGenerationState {
        let validationToken: SearchCatalogSnapshotValidationToken
        let generation: UInt64
    }

    private struct StaticPathMatchSnapshotCacheEntry {
        let snapshot: StaticPathMatchData
        var lastAccessSequence: UInt64
    }

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
    private var catalogGenerationsByRootID: [UUID: UInt64] = [:]
    private var sessionCatalogGenerationStatesByScope: [WorkspaceLookupRootScope: SessionCatalogGenerationState] = [:]
    private var nextSessionCatalogGeneration: UInt64 = 0
    private var searchCatalogSnapshotsByScope: [WorkspaceLookupRootScope: SearchCatalogSnapshotCacheEntry] = [:]
    private var nextSearchCatalogSnapshotAccessSequence: UInt64 = 0
    private var publishedRootCatalogShardsByRootID: [UUID: RootCatalogShard] = [:]
    private var rootCatalogShardWeakReferencesByRootID: [UUID: [WeakRootCatalogShardReference]] = [:]
    private var rootCatalogShardDeltaStatesByRootID: [UUID: RootCatalogShardDeltaState] = [:]
    private var pathMatchSnapshotIdentitiesByScope: [WorkspaceLookupRootScope: PathMatchCacheIdentity] = [:]
    private var staticPathMatchSnapshotsByScope: [WorkspaceLookupRootScope: StaticPathMatchSnapshotCacheEntry] = [:]
    private var nextStaticPathMatchSnapshotAccessSequence: UInt64 = 0
    private let storeBackedSearchLane: StoreBackedWorkspaceSearchLane
    private let searchDecodedContentCache = WorkspaceSearchDecodedContentCache()
    private let interactiveReadCache = WorkspaceInteractiveReadCache()
    private let searchContentSchedulerOwnerID = UUID()
    private let interactiveReadSchedulerOwnerID = UUID()
    #if os(macOS)
        private let searchContentMemoryPressureSource: DispatchSourceMemoryPressure
    #endif
    private var searchContentInvalidationEpochsByFileID: [UUID: UInt64] = [:]
    private var nextSearchContentInvalidationEpoch: UInt64 = 0
    private var activePublicationInvalidationBatch: PublicationInvalidationBatch?
    private static let maxCachedSearchCatalogSnapshotScopes = 16
    private static let maxCachedStaticPathMatchSnapshotScopes = 16
    /// Covers overlapping readers/index builds while bounding retained full-root arrays. At the cap,
    /// callers receive an authoritative uncached rebuild until older ARC leases drain.
    private static let maxLiveRootCatalogShardGenerationsPerRoot = 8
    // The checked-in WI-3 baseline (`docs/investigations/mcp-tool-throughput-wi3-baseline-2026-06-11.md`)
    // records authoritative catalog rebuild work in roots/files, and its fixture
    // proves a three-file/two-root rebuild, but it does not establish a multi-record crossover.
    // Patch exactly one logical catalog record—the common single-file watcher case—and rebuild for
    // every broader batch until measured evidence supports increasing this deliberately conservative cap.
    private static let maxRootCatalogShardPatchLogicalMutationCount = 1
    private static let defaultMaxPendingDeltasPerRoot = 10000
    private let pathMatchWorker = PathMatchWorker()
    private let codeScanActor = CodeScanActor()
    private let deferredReplayBuffer = DeferredReplayBufferActor(
        maxPendingDeltasPerRoot: WorkspaceFileContextStore.defaultMaxPendingDeltasPerRoot
    )
    private var codemapSnapshotsByFileID: [UUID: WorkspaceCodemapSnapshot] = [:]
    private var codemapFileIDsByRootID: [UUID: Set<UUID>] = [:]
    private var pendingCodemapRepairFileIDs = Set<UUID>()
    private var initializingSessionWorktreeCodemapRootIDs = Set<UUID>()
    private var initializedSessionWorktreeCodemapRootIDs = Set<UUID>()
    private var cachedCodemapFileAPIAggregate: WorkspaceCodemapFileAPIAggregate?
    private var codemapUpdateContinuations: [UUID: AsyncStream<WorkspaceCodemapUpdateEvent>.Continuation] = [:]
    private var fileSystemDeltaContinuations: [UUID: AsyncStream<WorkspaceFileSystemDeltaEvent>.Continuation] = [:]
    private var appliedIndexContinuations: [UUID: AsyncStream<WorkspaceAppliedIndexBatchEvent>.Continuation] = [:]
    private var appliedIndexGenerationsByRootID: [UUID: UInt64] = [:]
    private var watcherCancellablesByRootID: [UUID: AnyCancellable] = [:]
    private let publisherIngressCoordinator: WorkspaceFileSystemIngressCoordinator
    private let unloadTerminationPolicy: WorkspaceRootUnloadTerminationPolicy
    private var scopedIngressBarrierFlightStatesByRootID: [UUID: ScopedIngressBarrierRootFlightState] = [:]
    private var completedScopedIngressBarrierCutsByRootID: [UUID: ScopedIngressBarrierCompletedCut] = [:]
    private var nextScopedIngressBarrierToken: UInt64 = 0
    private static let maxConcurrentScopedIngressBarriers = 8
    private var codeScanResultSubscriptionTask: Task<AsyncStream<[CodeScanActor.ScanResult]>, Never>?
    private var codeScanResultTask: Task<Void, Never>?
    #if DEBUG
        private let debugNowNanoseconds: @Sendable () -> UInt64
    #endif

    #if DEBUG
        init(
            searchLaneConfiguration: StoreBackedWorkspaceSearchLane.Configuration = .production,
            debugNowNanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
            unloadTerminationPolicy: WorkspaceRootUnloadTerminationPolicy = .production
        ) {
            storeBackedSearchLane = StoreBackedWorkspaceSearchLane(configuration: searchLaneConfiguration)
            self.debugNowNanoseconds = debugNowNanoseconds
            self.unloadTerminationPolicy = unloadTerminationPolicy
            publisherIngressCoordinator = WorkspaceFileSystemIngressCoordinator(debugNowNanoseconds: debugNowNanoseconds)
            #if os(macOS)
                let source = DispatchSource.makeMemoryPressureSource(
                    eventMask: [.warning, .critical],
                    queue: .global(qos: .utility)
                )
                searchContentMemoryPressureSource = source
                source.setEventHandler { [weak self] in
                    Task { await self?.clearSearchDecodedContentCache() }
                }
                source.activate()
            #endif
        }
    #else
        init(
            searchLaneConfiguration: StoreBackedWorkspaceSearchLane.Configuration = .production,
            unloadTerminationPolicy: WorkspaceRootUnloadTerminationPolicy = .production
        ) {
            storeBackedSearchLane = StoreBackedWorkspaceSearchLane(configuration: searchLaneConfiguration)
            self.unloadTerminationPolicy = unloadTerminationPolicy
            publisherIngressCoordinator = WorkspaceFileSystemIngressCoordinator()
            #if os(macOS)
                let source = DispatchSource.makeMemoryPressureSource(
                    eventMask: [.warning, .critical],
                    queue: .global(qos: .utility)
                )
                searchContentMemoryPressureSource = source
                source.setEventHandler { [weak self] in
                    Task { await self?.clearSearchDecodedContentCache() }
                }
                source.activate()
            #endif
        }
    #endif

    deinit {
        #if os(macOS)
            searchContentMemoryPressureSource.cancel()
        #endif
        codeScanResultTask?.cancel()
        for cancellable in watcherCancellablesByRootID.values {
            cancellable.cancel()
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

    func roots() -> [WorkspaceRootRecord] {
        rootLoadOrder.compactMap { rootStatesByID[$0]?.root }
    }

    func rootRecords(forRootFolderPaths rootFolderPaths: [String], includeSystemRoots: Bool = true) -> [WorkspaceRootRecord] {
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

    func fileSystemDeltaEvents() -> AsyncStream<WorkspaceFileSystemDeltaEvent> {
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

    func appliedIndexEvents() -> AsyncStream<WorkspaceAppliedIndexBatchEvent> {
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

    func startWatchingRoot(id rootID: UUID) async throws {
        let state = try state(for: rootID)
        if watcherCancellablesByRootID[rootID] != nil {
            try await reconcileWatcherServiceState(state.service, rootID: rootID)
            await waitForCurrentPublisherIngress(rootIDs: [rootID])
            return
        }
        guard try await attachPublisherIngress(state: state, rootID: rootID) else { return }
        do {
            try await reconcileWatcherServiceState(state.service, rootID: rootID)
            await waitForCurrentPublisherIngress(rootIDs: [rootID])
        } catch {
            watcherCancellablesByRootID.removeValue(forKey: rootID)?.cancel()
            publisherIngressCoordinator.closePublisherIngress(rootID: rootID)
            try? await reconcileWatcherServiceState(state.service, rootID: rootID)
            await waitForCurrentPublisherIngress(rootIDs: [rootID])
            throw error
        }
    }

    private func attachPublisherIngress(state: RootState, rootID: UUID) async throws -> Bool {
        let root = state.root
        let lifetimeID = state.lifetimeID
        let diagnosticRootToken = state.service.diagnosticRootToken
        let publisherIngressCoordinator = publisherIngressCoordinator
        let subscription = publisherIngressCoordinator.openPublisherIngress(rootID: rootID) { [weak self] publication, publicationCorrelation in
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.WorkspaceIngress.storeSinkBegan,
                correlation: publicationCorrelation,
                EditFlowPerf.Dimensions(
                    changeCount: publication.deltas.count,
                    rootToken: diagnosticRootToken.uuidString,
                    ingressSequence: publication.watcherAcceptedWatermark?.rawValue,
                    barrierSequence: publication.servicePublicationSequence
                )
            )
            await self?.handleObservedPublisherFileSystemPublication(
                publication,
                root: root,
                expectedLifetimeID: lifetimeID,
                publicationCorrelation: publicationCorrelation,
                diagnosticRootToken: diagnosticRootToken
            )
        }
        let publisher = await state.service.publisherForChanges()
        guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: lifetimeID),
              publisherIngressCoordinator.isPublisherIngressOpen(subscription)
        else {
            try await reconcileWatcherServiceState(state.service, rootID: rootID)
            return false
        }
        let cancellable = publisher.sink { publication in
            #if DEBUG || EDIT_FLOW_PERF
                let publicationCorrelation = EditFlowPerf.currentFileSystemPublicationCorrelation
            #else
                let publicationCorrelation: EditFlowPerf.LifecycleCorrelation? = nil
            #endif
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.WorkspaceIngress.storeSinkScheduled,
                correlation: publicationCorrelation,
                EditFlowPerf.Dimensions(
                    changeCount: publication.deltas.count,
                    rootToken: diagnosticRootToken.uuidString,
                    ingressSequence: publication.watcherAcceptedWatermark?.rawValue,
                    barrierSequence: publication.servicePublicationSequence
                )
            )
            publisherIngressCoordinator.accept(
                subscription,
                publication: publication,
                lifecycleCorrelation: publicationCorrelation
            )
        }
        guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: lifetimeID),
              publisherIngressCoordinator.isPublisherIngressOpen(subscription)
        else {
            cancellable.cancel()
            try await reconcileWatcherServiceState(state.service, rootID: rootID)
            return false
        }
        watcherCancellablesByRootID[rootID] = cancellable
        return true
    }

    #if DEBUG
        func attachPublisherIngressWithoutStartingWatcherForTesting(rootID: UUID) async throws -> Bool {
            if watcherCancellablesByRootID[rootID] != nil { return true }
            let state = try state(for: rootID)
            return try await attachPublisherIngress(state: state, rootID: rootID)
        }
    #endif

    func stopWatchingRoot(id rootID: UUID) async {
        watcherCancellablesByRootID.removeValue(forKey: rootID)?.cancel()
        publisherIngressCoordinator.closePublisherIngress(rootID: rootID)
        guard let state = rootStatesByID[rootID] else {
            await waitForCurrentPublisherIngress(rootIDs: [rootID])
            return
        }
        try? await reconcileWatcherServiceState(state.service, rootID: rootID)
        await waitForCurrentPublisherIngress(rootIDs: [rootID])
    }

    private func reconcileWatcherServiceState(_ service: FileSystemService, rootID: UUID) async throws {
        while true {
            let shouldWatch = publisherIngressCoordinator.hasOpenPublisherIngress(rootID: rootID)
            #if DEBUG
                if let watcherServiceStateWillReconcileHandler {
                    await watcherServiceStateWillReconcileHandler(rootID, shouldWatch)
                }
            #endif
            if shouldWatch {
                try await service.startWatchingForChanges()
            } else {
                await service.stopWatchingForChanges()
            }
            guard shouldWatch != publisherIngressCoordinator.hasOpenPublisherIngress(rootID: rootID) else { return }
        }
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
        // Canonical batches are the only delta authority for search shards. Raw FSEvents first
        // mutate the store indexes and can never patch a published shard directly.
        applyAppliedIndexEventToRootCatalogShard(event)
        #if DEBUG
            Self.activePublicationInvalidationRecorder?.appliedIndexEventYieldCount += 1
        #endif
        for continuation in appliedIndexContinuations.values {
            continuation.yield(event)
        }
    }

    private func nextAppliedIndexGeneration(forRootID rootID: UUID) -> UInt64 {
        let next = (appliedIndexGenerationsByRootID[rootID] ?? 0) &+ 1
        appliedIndexGenerationsByRootID[rootID] = next
        return next
    }

    func replayObservedFileSystemDeltas(rootID: UUID, deltas: [FileSystemDelta]) async {
        guard let root = rootStatesByID[rootID]?.root else { return }
        await handleObservedFileSystemDeltas(deltas, root: root)
    }

    #if DEBUG
        func replayFileSystemPublicationForInvalidationDiagnosticsForTesting(
            rootID: UUID,
            deltas: [FileSystemDelta]
        ) async throws -> PublicationInvalidationDebugSample {
            let root = try state(for: rootID).root
            let preparedDeltas = prepareObservedFileSystemDeltas(deltas, root: root)
            let recorder = await applyPreparedIndexDeltasRecordingInvalidations(
                rootID: rootID,
                deltas: preparedDeltas
            )
            return makePublicationInvalidationDebugSample(
                servicePublicationSequence: 0,
                watcherAcceptedWatermark: nil,
                recorder: recorder
            )
        }

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
            events: [(absolutePath: String, flags: FSEventStreamEventFlags, eventId: FSEventStreamEventId)],
            scheduleDrain: Bool = true
        ) async throws -> FileSystemWatcherIngressMailbox.Watermark? {
            let state = try state(for: rootID)
            return await state.service.acceptWatcherPayloadForTesting(events, scheduleDrain: scheduleDrain)
        }

        func appliedIngressSnapshotForTesting(rootID: UUID) -> WorkspaceFileSystemIngressCoordinator.AppliedSnapshot {
            publisherIngressCoordinator.appliedSnapshot(rootID: rootID)
        }

        func acceptedWatcherWatermarkForTesting(rootID: UUID) throws -> FileSystemWatcherIngressMailbox.Watermark {
            try state(for: rootID).service.captureAcceptedWatcherWatermark()
        }

        func publisherIngressDebugSnapshotForTesting(
            rootID: UUID
        ) -> WorkspaceFileSystemIngressCoordinator.DebugSnapshot {
            publisherIngressCoordinator.debugSnapshot(rootID: rootID)
        }

        func waitUntilPublisherIngressAppliedForTesting(
            rootID: UUID,
            servicePublicationSequence: UInt64
        ) async {
            await publisherIngressCoordinator.waitUntilApplied(
                rootID: rootID,
                servicePublicationSequence: servicePublicationSequence
            )
        }

        func rootLifetimeIDForTesting(rootID: UUID) throws -> UUID {
            try state(for: rootID).lifetimeID
        }

        func applyAppliedIndexEventToRootCatalogShardForTesting(
            _ event: WorkspaceAppliedIndexBatchEvent
        ) {
            applyAppliedIndexEventToRootCatalogShard(event)
        }

        func replayPublisherFileSystemPublicationForTesting(
            rootID: UUID,
            expectedLifetimeID: UUID,
            deltas: [FileSystemDelta],
            requiresFullResync: Bool = false
        ) async {
            guard let root = rootStatesByID[rootID]?.root else { return }
            await handleObservedFileSystemDeltas(
                deltas,
                root: root,
                expectedLifetimeID: expectedLifetimeID,
                requiresFullResync: requiresFullResync
            )
        }
    #endif

    private func handleObservedPublisherFileSystemPublication(
        _ publication: FileSystemDeltaPublication,
        root: WorkspaceRootRecord,
        expectedLifetimeID: UUID,
        publicationCorrelation: EditFlowPerf.LifecycleCorrelation?,
        diagnosticRootToken: UUID
    ) async {
        #if DEBUG
            if let watcherSinkWillApplyHandler {
                await watcherSinkWillApplyHandler(root.id)
            }
        #endif
        guard isRootLifetimeCurrent(rootID: root.id, expectedLifetimeID: expectedLifetimeID) else { return }
        if publication.source == .overflowRootRescan || publication.source == .recoveryFullResync {
            await invalidateRetainedSearchContentForRecoveryUncertainty(rootID: root.id)
            guard isRootLifetimeCurrent(rootID: root.id, expectedLifetimeID: expectedLifetimeID) else { return }
        }
        await handleObservedFileSystemDeltas(
            publication.deltas,
            root: root,
            expectedLifetimeID: expectedLifetimeID,
            publicationCorrelation: publicationCorrelation,
            diagnosticRootToken: diagnosticRootToken,
            watcherAcceptedWatermark: publication.watcherAcceptedWatermark,
            servicePublicationSequence: publication.servicePublicationSequence,
            requiresFullResync: publication.requiresFullResync
        )
    }

    private func handleObservedFileSystemDeltas(
        _ deltas: [FileSystemDelta],
        root: WorkspaceRootRecord,
        expectedLifetimeID: UUID? = nil,
        publicationCorrelation: EditFlowPerf.LifecycleCorrelation? = nil,
        diagnosticRootToken: UUID? = nil,
        watcherAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark? = nil,
        servicePublicationSequence: UInt64? = nil,
        requiresFullResync: Bool = false
    ) async {
        guard isRootLifetimeCurrent(rootID: root.id, expectedLifetimeID: expectedLifetimeID) else { return }
        for delta in deltas {
            guard await isDiscoveryFacingFileSystemDelta(delta, rootID: root.id) else { continue }
            guard isRootLifetimeCurrent(rootID: root.id, expectedLifetimeID: expectedLifetimeID) else { return }
            yieldFileSystemDeltaEvent(WorkspaceFileSystemDeltaEvent(
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                delta: delta
            ))
        }
        let preparedDeltas = prepareObservedFileSystemDeltas(deltas, root: root)
        #if DEBUG
            await applyPreparedIndexDeltas(
                rootID: root.id,
                deltas: preparedDeltas,
                expectedLifetimeID: expectedLifetimeID,
                watcherAcceptedWatermark: watcherAcceptedWatermark,
                servicePublicationSequence: servicePublicationSequence,
                requiresFullResync: requiresFullResync
            )
        #else
            await applyPreparedIndexDeltas(
                rootID: root.id,
                deltas: preparedDeltas,
                expectedLifetimeID: expectedLifetimeID,
                requiresFullResync: requiresFullResync
            )
        #endif
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.WorkspaceIngress.storeCanonicalApplyCompleted,
            correlation: publicationCorrelation,
            EditFlowPerf.Dimensions(
                appliedCount: preparedDeltas.count,
                rootToken: diagnosticRootToken?.uuidString,
                ingressSequence: watcherAcceptedWatermark?.rawValue,
                barrierSequence: servicePublicationSequence
            )
        )
    }

    private func prepareObservedFileSystemDeltas(
        _ deltas: [FileSystemDelta],
        root: WorkspaceRootRecord
    ) -> [PreparedFileSystemDelta] {
        FileSystemDeltaPreparation.coalesce(deltas, inRoot: root.standardizedFullPath)
            .compactMap { FileSystemDeltaPreparation.prepare($0, inRoot: root.standardizedFullPath) }
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

    func files(inRoot rootID: UUID) -> [WorkspaceFileRecord] {
        guard let state = rootStatesByID[rootID] else { return [] }
        return state.fileIDsByRelativePath.values
            .filter(isDiscoverableFileID)
            .compactMap { filesByID[$0] }
            .sorted { $0.standardizedRelativePath < $1.standardizedRelativePath }
    }

    func folders(inRoot rootID: UUID) -> [WorkspaceFolderRecord] {
        guard let state = rootStatesByID[rootID] else { return [] }
        return state.folderIDsByRelativePath.values
            .filter(isDiscoverableFolderID)
            .compactMap { foldersByID[$0] }
            .sorted { $0.standardizedRelativePath < $1.standardizedRelativePath }
    }

    func appliedIndexRootSnapshot(rootID: UUID) -> WorkspaceAppliedIndexRootSnapshot? {
        guard let root = rootStatesByID[rootID]?.root else { return nil }
        return WorkspaceAppliedIndexRootSnapshot(
            root: root,
            generation: appliedIndexGenerationsByRootID[rootID] ?? 0,
            files: files(inRoot: rootID),
            folders: folders(inRoot: rootID)
        )
    }

    func catalogGeneration(rootScope: WorkspaceLookupRootScope = .visibleWorkspace) -> UInt64 {
        scopedSnapshotGeneration(scope: rootScope)
    }

    func catalogDiagnostics(rootScope: WorkspaceLookupRootScope = .visibleWorkspace) -> WorkspaceCatalogDiagnostics {
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

    func withStoreBackedSearchAccess<T>(
        searchMode: SearchMode,
        admissionClass: BroadSearchAdmissionClass?,
        operation: @Sendable (FileSearchActor) async throws -> T
    ) async throws -> T {
        try await storeBackedSearchLane.withSearchAccess(
            searchMode: searchMode,
            admissionClass: admissionClass,
            operation: operation
        )
    }

    func rootScopeAvailability(_ rootScope: WorkspaceLookupRootScope) -> WorkspaceLookupRootScopeAvailability {
        guard case let .sessionBoundWorkspace(_, requestedPhysicalRootPaths) = rootScope else {
            return .available
        }
        let requested = Set(requestedPhysicalRootPaths.map {
            StandardizedPath.absolute(($0 as NSString).expandingTildeInPath)
        })
        let missing = requested.filter { path in
            guard let rootID = rootIDsByStandardizedPath[path],
                  rootStatesByID[rootID]?.root.kind == .sessionWorktree
            else { return true }
            var isDirectory: ObjCBool = false
            return !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) ||
                !isDirectory.boolValue
        }.sorted()
        return missing.isEmpty
            ? .available
            : .sessionWorktreeUnavailable(missingPhysicalRootPaths: missing)
    }

    func searchCatalogAccess(rootScope: WorkspaceLookupRootScope = .visibleWorkspace) -> WorkspaceSearchCatalogAccess {
        let availability = rootScopeAvailability(rootScope)
        guard availability == .available else {
            return .unavailable(availability)
        }
        return .available(searchCatalogSnapshot(rootScope: rootScope))
    }

    func searchCatalogSnapshot(rootScope: WorkspaceLookupRootScope = .visibleWorkspace) -> WorkspaceSearchCatalogSnapshot {
        let catalogSnapshotState = EditFlowPerf.begin(EditFlowPerf.Stage.Search.catalogSnapshot)
        let validationToken = searchCatalogSnapshotValidationToken(scope: rootScope)
        if var cached = searchCatalogSnapshotsByScope[rootScope] {
            if cached.validationToken == validationToken {
                cached.lastAccessSequence = nextSearchCatalogAccessSequence()
                searchCatalogSnapshotsByScope[rootScope] = cached
                EditFlowPerf.end(
                    EditFlowPerf.Stage.Search.catalogSnapshot,
                    catalogSnapshotState,
                    EditFlowPerf.Dimensions(
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
        #if DEBUG
            let rebuildStart = DispatchTime.now().uptimeNanoseconds
        #endif
        let roots = rootsForPathLookup(scope: rootScope)
        let generation = scopedSnapshotGeneration(scope: rootScope)
        var shouldCacheSnapshot = false
        let snapshot: WorkspaceSearchCatalogSnapshot
        if let shards = prepareAndPublishRootCatalogShardBatch(for: roots) {
            var composedSnapshot = composeSearchCatalogSnapshot(
                rootScope: rootScope,
                generation: generation,
                roots: roots,
                shards: shards
            )
            shouldCacheSnapshot = true
            #if DEBUG
                let authoritativeSnapshot = buildAuthoritativeSearchCatalogSnapshot(
                    rootScope: rootScope,
                    generation: generation,
                    roots: roots,
                    includePathIndexes: false
                )
                let composedBytes = catalogShadowBytes(composedSnapshot)
                let authoritativeBytes = catalogShadowBytes(authoritativeSnapshot)
                let shadowMatches = composedBytes == authoritativeBytes
                recordRootCatalogShardShadowComparison(
                    matched: shadowMatches,
                    byteCount: authoritativeBytes.count
                )
                if !shadowMatches {
                    assertionFailure("Root catalog shard composition diverged from the authoritative full rebuild")
                    composedSnapshot = buildAuthoritativeSearchCatalogSnapshot(
                        rootScope: rootScope,
                        generation: generation,
                        roots: roots
                    )
                    shouldCacheSnapshot = false
                }
            #endif
            snapshot = composedSnapshot
        } else {
            snapshot = buildAuthoritativeSearchCatalogSnapshot(
                rootScope: rootScope,
                generation: generation,
                roots: roots
            )
        }
        #if DEBUG
            let rebuildEnd = DispatchTime.now().uptimeNanoseconds
            recordCatalogRebuild(
                filterMicroseconds: 0,
                sortMicroseconds: 0,
                materializationMicroseconds: 0,
                totalMicroseconds: Self.debugElapsedMicroseconds(since: rebuildStart, through: rebuildEnd),
                fileCount: snapshot.files.count,
                rootCount: roots.count
            )
        #endif
        EditFlowPerf.end(
            EditFlowPerf.Stage.Search.catalogSnapshot,
            catalogSnapshotState,
            EditFlowPerf.Dimensions(
                fileCount: snapshot.diagnostics.fileCount,
                cacheHit: false,
                rootCount: snapshot.diagnostics.rootCount,
                folderCount: snapshot.diagnostics.folderCount
            )
        )
        if shouldCacheSnapshot {
            cacheSearchCatalogSnapshot(snapshot, validationToken: validationToken, scope: rootScope)
        }
        return snapshot
    }

    private func prepareAndPublishRootCatalogShardBatch(
        for roots: [WorkspaceRootRecord]
    ) -> [RootCatalogShard]? {
        var keysByRootID: [UUID: RootCatalogShardKey] = [:]
        keysByRootID.reserveCapacity(roots.count)
        var rootsNeedingBuild: [(root: WorkspaceRootRecord, key: RootCatalogShardKey)] = []
        rootsNeedingBuild.reserveCapacity(roots.count)

        for root in roots {
            guard let key = rootCatalogShardKey(for: root) else { return nil }
            keysByRootID[root.id] = key
            if publishedRootCatalogShardsByRootID[root.id]?.key != key {
                rootsNeedingBuild.append((root, key))
            }
        }

        for candidate in rootsNeedingBuild {
            let liveGenerationCount = liveRootCatalogShards(rootID: candidate.root.id).count
            if rootCatalogShardDeltaStatesByRootID[candidate.root.id]?.isDirty == true,
               liveGenerationCount >= Self.maxLiveRootCatalogShardGenerationsPerRoot
            {
                return nil
            }
            guard canPublishAnotherRootCatalogShard(rootID: candidate.root.id) else {
                markRootCatalogShardDirty(
                    rootID: candidate.root.id,
                    lifetimeID: candidate.key.lifetimeID,
                    lastAppliedIndexGeneration: appliedIndexGenerationsByRootID[candidate.root.id] ?? 0,
                    reason: .retentionBackstop
                )
                publishedRootCatalogShardsByRootID.removeValue(forKey: candidate.root.id)
                return nil
            }
        }

        // Build the complete replacement batch privately; the actor publishes it with one assignment below.
        var newlyBuiltShardsByRootID: [UUID: RootCatalogShard] = [:]
        newlyBuiltShardsByRootID.reserveCapacity(rootsNeedingBuild.count)
        for candidate in rootsNeedingBuild {
            let appliedIndexGeneration = appliedIndexGenerationsByRootID[candidate.root.id] ?? 0
            newlyBuiltShardsByRootID[candidate.root.id] = buildAuthoritativeRootCatalogShard(
                root: candidate.root,
                key: candidate.key,
                appliedIndexGeneration: appliedIndexGeneration
            )
        }

        var publication = publishedRootCatalogShardsByRootID
        publication.reserveCapacity(max(publication.count, roots.count))
        for root in roots {
            guard let key = keysByRootID[root.id] else { return nil }
            if let newlyBuilt = newlyBuiltShardsByRootID[root.id] {
                publication[root.id] = newlyBuilt
            } else if let retained = publishedRootCatalogShardsByRootID[root.id], retained.key == key {
                publication[root.id] = retained
            } else {
                return nil
            }
        }

        publishedRootCatalogShardsByRootID = publication
        for shard in newlyBuiltShardsByRootID.values {
            rootCatalogShardDeltaStatesByRootID[shard.key.rootID] = RootCatalogShardDeltaState(
                lifetimeID: shard.key.lifetimeID,
                lastAppliedIndexGeneration: shard.appliedIndexGeneration,
                isDirty: false
            )
            registerPublishedRootCatalogShard(shard, kind: .authoritative)
        }
        return roots.compactMap { publication[$0.id] }
    }

    private func rootCatalogShardKey(for root: WorkspaceRootRecord) -> RootCatalogShardKey? {
        guard let state = rootStatesByID[root.id],
              let loadConfiguration = rootLoadConfigurationsByPath[root.standardizedFullPath]
        else { return nil }
        return RootCatalogShardKey(
            canonicalConfigurationIdentity: RootCatalogCanonicalConfigurationIdentity(
                canonicalPath: root.standardizedFullPath,
                loadConfiguration: loadConfiguration
            ),
            rootID: root.id,
            lifetimeID: state.lifetimeID,
            topologyGeneration: catalogGenerationsByRootID[root.id] ?? 0
        )
    }

    private func buildAuthoritativeRootCatalogShard(
        root: WorkspaceRootRecord,
        key: RootCatalogShardKey,
        appliedIndexGeneration: UInt64
    ) -> RootCatalogShard {
        let components = buildAuthoritativeCatalogComponents(roots: [root])
        return RootCatalogShard(
            key: key,
            root: root,
            files: components.files,
            folders: components.folders,
            entries: components.entries,
            appliedIndexGeneration: appliedIndexGeneration
        )
    }

    private func registerPublishedRootCatalogShard(
        _ shard: RootCatalogShard,
        kind: RootCatalogShardBuildKind
    ) {
        rootCatalogShardWeakReferencesByRootID[shard.key.rootID, default: []]
            .append(WeakRootCatalogShardReference(shard))
        #if DEBUG
            rootCatalogShardBuildCountsByRootID[shard.key.rootID, default: 0] += 1
            switch kind {
            case .patch:
                rootCatalogShardPatchCountsByRootID[shard.key.rootID, default: 0] += 1
            case .authoritative:
                rootCatalogShardAuthoritativeRebuildCountsByRootID[shard.key.rootID, default: 0] += 1
            }
            let liveCount = liveRootCatalogShards(rootID: shard.key.rootID).count
            rootCatalogShardMaxLiveGenerationCountsByRootID[shard.key.rootID] = max(
                rootCatalogShardMaxLiveGenerationCountsByRootID[shard.key.rootID] ?? 0,
                liveCount
            )
        #endif
    }

    private func liveRootCatalogShards(rootID: UUID) -> [RootCatalogShard] {
        let live = (rootCatalogShardWeakReferencesByRootID[rootID] ?? []).compactMap(\.shard)
        if live.isEmpty {
            rootCatalogShardWeakReferencesByRootID.removeValue(forKey: rootID)
        } else {
            rootCatalogShardWeakReferencesByRootID[rootID] = live.map(WeakRootCatalogShardReference.init)
        }
        return live
    }

    private func canPublishAnotherRootCatalogShard(rootID: UUID) -> Bool {
        let liveGenerations = liveRootCatalogShards(rootID: rootID)
        guard liveGenerations.count < Self.maxLiveRootCatalogShardGenerationsPerRoot else {
            #if DEBUG
                rootCatalogShardBackstopCountsByRootID[rootID, default: 0] += 1
                rootCatalogShardMaxLiveGenerationCountsByRootID[rootID] = max(
                    rootCatalogShardMaxLiveGenerationCountsByRootID[rootID] ?? 0,
                    liveGenerations.count
                )
            #endif
            return false
        }
        return true
    }

    private func applyAppliedIndexEventToRootCatalogShard(_ event: WorkspaceAppliedIndexBatchEvent) {
        if event.isRootUnload {
            publishedRootCatalogShardsByRootID.removeValue(forKey: event.rootID)
            rootCatalogShardDeltaStatesByRootID.removeValue(forKey: event.rootID)
            recordRootCatalogShardFallback(rootID: event.rootID, reason: .unload)
            return
        }

        guard let state = rootStatesByID[event.rootID],
              state.root.standardizedFullPath == StandardizedPath.absolute(event.rootPath),
              let currentKey = rootCatalogShardKey(for: state.root)
        else {
            publishedRootCatalogShardsByRootID.removeValue(forKey: event.rootID)
            rootCatalogShardDeltaStatesByRootID.removeValue(forKey: event.rootID)
            return
        }

        guard let previousShard = publishedRootCatalogShardsByRootID[event.rootID] else {
            let reason: RootCatalogShardFallbackReason = if let deltaState = rootCatalogShardDeltaStatesByRootID[event.rootID],
                                                            deltaState.lifetimeID == state.lifetimeID,
                                                            deltaState.isDirty
            {
                .dirtyRecovery
            } else {
                .missingShard
            }
            rebuildRootCatalogShardAuthoritatively(
                root: state.root,
                key: currentKey,
                appliedIndexGeneration: event.generation,
                reason: reason
            )
            return
        }
        let deltaState = rootCatalogShardDeltaStatesByRootID[event.rootID] ?? RootCatalogShardDeltaState(
            lifetimeID: previousShard.key.lifetimeID,
            lastAppliedIndexGeneration: previousShard.appliedIndexGeneration,
            isDirty: false
        )
        guard deltaState.lifetimeID == state.lifetimeID,
              previousShard.key.lifetimeID == state.lifetimeID,
              previousShard.key.rootID == event.rootID,
              previousShard.key.canonicalConfigurationIdentity == currentKey.canonicalConfigurationIdentity
        else {
            rebuildRootCatalogShardAuthoritatively(
                root: state.root,
                key: currentKey,
                appliedIndexGeneration: event.generation,
                reason: .unsafeAmbiguity
            )
            return
        }
        if deltaState.isDirty {
            rebuildRootCatalogShardAuthoritatively(
                root: state.root,
                key: currentKey,
                appliedIndexGeneration: event.generation,
                reason: .dirtyRecovery
            )
            return
        }
        if event.requiresFullResync {
            rebuildRootCatalogShardAuthoritatively(
                root: state.root,
                key: currentKey,
                appliedIndexGeneration: event.generation,
                reason: .fullResync
            )
            return
        }
        if deltaState.lastAppliedIndexGeneration == UInt64.max || event.generation == 0 {
            rebuildRootCatalogShardAuthoritatively(
                root: state.root,
                key: currentKey,
                appliedIndexGeneration: event.generation,
                reason: .generationOverflow
            )
            return
        }
        guard event.generation == deltaState.lastAppliedIndexGeneration + 1 else {
            rebuildRootCatalogShardAuthoritatively(
                root: state.root,
                key: currentKey,
                appliedIndexGeneration: event.generation,
                reason: .generationGap
            )
            return
        }

        let hasTopologyMutation = !event.upsertedFiles.isEmpty
            || !event.upsertedFolders.isEmpty
            || !event.removedFileIDs.isEmpty
            || !event.removedFolderIDs.isEmpty
            || !event.removedFilePaths.isEmpty
            || !event.removedFolderPaths.isEmpty
        let expectedTopologyGeneration: UInt64
        if hasTopologyMutation {
            guard previousShard.key.topologyGeneration != UInt64.max else {
                rebuildRootCatalogShardAuthoritatively(
                    root: state.root,
                    key: currentKey,
                    appliedIndexGeneration: event.generation,
                    reason: .generationOverflow
                )
                return
            }
            expectedTopologyGeneration = previousShard.key.topologyGeneration + 1
        } else {
            expectedTopologyGeneration = previousShard.key.topologyGeneration
        }
        guard currentKey.topologyGeneration == expectedTopologyGeneration,
              let builderOutput = buildRootCatalogShardPatch(event: event, previousShard: previousShard)
        else {
            rebuildRootCatalogShardAuthoritatively(
                root: state.root,
                key: currentKey,
                appliedIndexGeneration: event.generation,
                reason: .unsafeAmbiguity
            )
            return
        }
        guard builderOutput.logicalMutationCount <= Self.maxRootCatalogShardPatchLogicalMutationCount else {
            rebuildRootCatalogShardAuthoritatively(
                root: state.root,
                key: currentKey,
                appliedIndexGeneration: event.generation,
                reason: .thresholdExceeded
            )
            return
        }
        guard canPublishAnotherRootCatalogShard(rootID: event.rootID) else {
            markRootCatalogShardDirty(
                rootID: event.rootID,
                lifetimeID: state.lifetimeID,
                lastAppliedIndexGeneration: event.generation,
                reason: .retentionBackstop
            )
            publishedRootCatalogShardsByRootID.removeValue(forKey: event.rootID)
            return
        }

        let patchedShard = RootCatalogShard(
            key: currentKey,
            root: state.root,
            files: builderOutput.files,
            folders: builderOutput.folders,
            entries: builderOutput.files.map { WorkspaceSearchCatalogEntry(file: $0, root: state.root) },
            appliedIndexGeneration: event.generation
        )
        var publication = publishedRootCatalogShardsByRootID
        publication[event.rootID] = patchedShard
        publishedRootCatalogShardsByRootID = publication
        rootCatalogShardDeltaStatesByRootID[event.rootID] = RootCatalogShardDeltaState(
            lifetimeID: state.lifetimeID,
            lastAppliedIndexGeneration: event.generation,
            isDirty: false
        )
        registerPublishedRootCatalogShard(patchedShard, kind: .patch)
    }

    private func rebuildRootCatalogShardAuthoritatively(
        root: WorkspaceRootRecord,
        key: RootCatalogShardKey,
        appliedIndexGeneration: UInt64,
        reason: RootCatalogShardFallbackReason
    ) {
        recordRootCatalogShardFallback(rootID: root.id, reason: reason)
        guard canPublishAnotherRootCatalogShard(rootID: root.id) else {
            markRootCatalogShardDirty(
                rootID: root.id,
                lifetimeID: key.lifetimeID,
                lastAppliedIndexGeneration: appliedIndexGeneration,
                reason: .retentionBackstop
            )
            publishedRootCatalogShardsByRootID.removeValue(forKey: root.id)
            return
        }
        let rebuiltShard = buildAuthoritativeRootCatalogShard(
            root: root,
            key: key,
            appliedIndexGeneration: appliedIndexGeneration
        )
        var publication = publishedRootCatalogShardsByRootID
        publication[root.id] = rebuiltShard
        publishedRootCatalogShardsByRootID = publication
        rootCatalogShardDeltaStatesByRootID[root.id] = RootCatalogShardDeltaState(
            lifetimeID: key.lifetimeID,
            lastAppliedIndexGeneration: appliedIndexGeneration,
            isDirty: false
        )
        registerPublishedRootCatalogShard(rebuiltShard, kind: .authoritative)
    }

    private func markRootCatalogShardDirty(
        rootID: UUID,
        lifetimeID: UUID,
        lastAppliedIndexGeneration: UInt64,
        reason: RootCatalogShardFallbackReason
    ) {
        rootCatalogShardDeltaStatesByRootID[rootID] = RootCatalogShardDeltaState(
            lifetimeID: lifetimeID,
            lastAppliedIndexGeneration: lastAppliedIndexGeneration,
            isDirty: true
        )
        recordRootCatalogShardFallback(rootID: rootID, reason: reason)
    }

    private func recordRootCatalogShardFallback(
        rootID: UUID,
        reason: RootCatalogShardFallbackReason
    ) {
        #if DEBUG
            rootCatalogShardFallbackReasonCountsByRootID[rootID, default: [:]][reason.rawValue, default: 0] += 1
        #endif
    }

    private func buildRootCatalogShardPatch(
        event: WorkspaceAppliedIndexBatchEvent,
        previousShard: RootCatalogShard
    ) -> RootCatalogShardBuilderOutput? {
        let oldFilesByID = Dictionary(uniqueKeysWithValues: previousShard.files.map { ($0.id, $0) })
        let oldFileIDsByPath = Dictionary(
            previousShard.files.map { ($0.standardizedRelativePath, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        let oldFoldersByID = Dictionary(uniqueKeysWithValues: previousShard.folders.map { ($0.id, $0) })
        let oldFolderIDsByPath = Dictionary(
            previousShard.folders.map { ($0.standardizedRelativePath, $0.id) },
            uniquingKeysWith: { first, _ in first }
        )

        let upsertedFilesByID = Dictionary(event.upsertedFiles.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let upsertedFoldersByID = Dictionary(event.upsertedFolders.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        guard upsertedFilesByID.count == event.upsertedFiles.count,
              upsertedFoldersByID.count == event.upsertedFolders.count,
              event.upsertedFiles.allSatisfy({ $0.rootID == event.rootID && filesByID[$0.id] == $0 }),
              event.upsertedFolders.allSatisfy({ $0.rootID == event.rootID && foldersByID[$0.id] == $0 })
        else { return nil }
        let representedFolderIDs = Set(oldFoldersByID.keys).union(upsertedFoldersByID.keys)
        for file in upsertedFilesByID.values {
            var parentFolderID = file.parentFolderID
            while let folderID = parentFolderID {
                guard representedFolderIDs.contains(folderID),
                      let folder = foldersByID[folderID]
                else { return nil }
                parentFolderID = folder.parentFolderID
            }
        }

        let removedFileIDs = Set(event.removedFileIDs)
        let removedFolderIDs = Set(event.removedFolderIDs)
        let removedFilePaths = Set(event.removedFilePaths.map(StandardizedPath.relative))
        let removedFolderPaths = Set(event.removedFolderPaths.map(StandardizedPath.relative))
        let modifiedFileIDs = Set(event.modifiedFileIDs)
        let modifiedFolderIDs = Set(event.modifiedFolderIDs)
        guard removedFileIDs.count == event.removedFileIDs.count,
              removedFolderIDs.count == event.removedFolderIDs.count,
              modifiedFileIDs.count == event.modifiedFileIDs.count,
              modifiedFolderIDs.count == event.modifiedFolderIDs.count,
              modifiedFileIDs.allSatisfy({ filesByID[$0]?.rootID == event.rootID }),
              modifiedFolderIDs.allSatisfy({ foldersByID[$0]?.rootID == event.rootID })
        else { return nil }

        var touchedFileIDs = Set(upsertedFilesByID.keys)
        var touchedFolderIDs = Set(upsertedFoldersByID.keys)
        for id in removedFileIDs {
            guard oldFilesByID[id] != nil else { return nil }
            touchedFileIDs.insert(id)
        }
        for path in removedFilePaths {
            guard let id = oldFileIDsByPath[path] else { return nil }
            touchedFileIDs.insert(id)
        }
        for id in modifiedFileIDs {
            guard oldFilesByID[id] != nil else { return nil }
            touchedFileIDs.insert(id)
        }
        for id in removedFolderIDs {
            guard oldFoldersByID[id] != nil else { return nil }
            touchedFolderIDs.insert(id)
        }
        for path in removedFolderPaths {
            guard let id = oldFolderIDsByPath[path] else { return nil }
            touchedFolderIDs.insert(id)
        }
        for id in modifiedFolderIDs {
            guard oldFoldersByID[id] != nil else { return nil }
            touchedFolderIDs.insert(id)
        }

        let upsertedFilePaths = Set(upsertedFilesByID.values.map(\.standardizedRelativePath))
        let upsertedFolderPaths = Set(upsertedFoldersByID.values.map(\.standardizedRelativePath))
        guard removedFileIDs.isDisjoint(with: upsertedFilesByID.keys),
              removedFolderIDs.isDisjoint(with: upsertedFoldersByID.keys),
              removedFilePaths.isDisjoint(with: upsertedFilePaths),
              removedFolderPaths.isDisjoint(with: upsertedFolderPaths),
              modifiedFileIDs.isDisjoint(with: removedFileIDs),
              modifiedFolderIDs.isDisjoint(with: removedFolderIDs)
        else { return nil }

        let logicalMutationCount = touchedFileIDs.count + touchedFolderIDs.count
        guard logicalMutationCount <= Self.maxRootCatalogShardPatchLogicalMutationCount else {
            return RootCatalogShardBuilderOutput(
                files: previousShard.files,
                folders: previousShard.folders,
                logicalMutationCount: logicalMutationCount
            )
        }

        func insertFile(_ file: WorkspaceFileRecord, into files: inout [WorkspaceFileRecord]) {
            var lowerBound = 0
            var upperBound = files.count
            while lowerBound < upperBound {
                let midpoint = (lowerBound + upperBound) / 2
                if Self.searchCatalogFilePrecedes(files[midpoint], file) {
                    lowerBound = midpoint + 1
                } else {
                    upperBound = midpoint
                }
            }
            files.insert(file, at: lowerBound)
        }

        func insertFolder(_ folder: WorkspaceFolderRecord, into folders: inout [WorkspaceFolderRecord]) {
            var lowerBound = 0
            var upperBound = folders.count
            while lowerBound < upperBound {
                let midpoint = (lowerBound + upperBound) / 2
                if Self.searchCatalogFolderPrecedes(folders[midpoint], folder) {
                    lowerBound = midpoint + 1
                } else {
                    upperBound = midpoint
                }
            }
            folders.insert(folder, at: lowerBound)
        }

        var files = previousShard.files
        if let touchedFileID = touchedFileIDs.first {
            files.removeAll { file in
                file.id == touchedFileID
                    || removedFilePaths.contains(file.standardizedRelativePath)
                    || upsertedFilePaths.contains(file.standardizedRelativePath)
            }
            if let upserted = upsertedFilesByID[touchedFileID] {
                insertFile(upserted, into: &files)
            } else if modifiedFileIDs.contains(touchedFileID), let modified = filesByID[touchedFileID] {
                insertFile(modified, into: &files)
            }
        }

        var folders = previousShard.folders
        if let touchedFolderID = touchedFolderIDs.first {
            folders.removeAll { folder in
                folder.id == touchedFolderID
                    || removedFolderPaths.contains(folder.standardizedRelativePath)
                    || upsertedFolderPaths.contains(folder.standardizedRelativePath)
            }
            if let upserted = upsertedFoldersByID[touchedFolderID] {
                insertFolder(upserted, into: &folders)
            } else if modifiedFolderIDs.contains(touchedFolderID), let modified = foldersByID[touchedFolderID] {
                insertFolder(modified, into: &folders)
            }
        }

        return RootCatalogShardBuilderOutput(
            files: files,
            folders: folders,
            logicalMutationCount: logicalMutationCount
        )
    }

    private func buildAuthoritativeCatalogComponents(
        roots: [WorkspaceRootRecord]
    ) -> AuthoritativeCatalogComponents {
        let rootsByID = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0) })
        let allowedRootIDs = Set(rootsByID.keys)
        let files = filesByID.values
            .filter { allowedRootIDs.contains($0.rootID) && isDiscoverableFileID($0.id) }
            .sorted(by: Self.searchCatalogFilePrecedes)
        let folders = foldersByID.values
            .filter { allowedRootIDs.contains($0.rootID) && isDiscoverableFolderID($0.id) }
            .sorted(by: Self.searchCatalogFolderPrecedes)
        let entries = files.compactMap { file -> WorkspaceSearchCatalogEntry? in
            guard let root = rootsByID[file.rootID] else { return nil }
            return WorkspaceSearchCatalogEntry(file: file, root: root)
        }
        return AuthoritativeCatalogComponents(files: files, folders: folders, entries: entries)
    }

    private func buildAuthoritativeSearchCatalogSnapshot(
        rootScope: WorkspaceLookupRootScope,
        generation: UInt64,
        roots: [WorkspaceRootRecord],
        includePathIndexes: Bool = true
    ) -> WorkspaceSearchCatalogSnapshot {
        let components = buildAuthoritativeCatalogComponents(roots: roots)
        let diagnostics = WorkspaceCatalogDiagnostics(
            generation: generation,
            rootScope: rootScope,
            rootCount: roots.count,
            folderCount: components.folders.count,
            fileCount: components.files.count
        )
        let rootPathIndexes = includePathIndexes
            ? buildAuthoritativeRootPathIndexes(roots: roots, entries: components.entries)
            : []
        return WorkspaceSearchCatalogSnapshot(
            generation: generation,
            rootScope: rootScope,
            roots: roots,
            files: components.files,
            entries: components.entries,
            rootPathIndexes: rootPathIndexes,
            diagnostics: diagnostics
        )
    }

    private func buildAuthoritativeRootPathIndexes(
        roots: [WorkspaceRootRecord],
        entries: [WorkspaceSearchCatalogEntry]
    ) -> [WorkspaceSearchRootPathIndex] {
        let entriesByRootID = Dictionary(grouping: entries, by: \.rootID)
        return roots.compactMap { root in
            guard let state = rootStatesByID[root.id] else { return nil }
            return WorkspaceSearchRootPathIndex(
                identity: WorkspaceSearchRootPathIndexIdentity(
                    rootID: root.id,
                    lifetimeID: state.lifetimeID,
                    topologyGeneration: catalogGenerationsByRootID[root.id] ?? 0
                ),
                rootPath: root.standardizedFullPath,
                entries: entriesByRootID[root.id] ?? []
            )
        }
    }

    private func composeSearchCatalogSnapshot(
        rootScope: WorkspaceLookupRootScope,
        generation: UInt64,
        roots: [WorkspaceRootRecord],
        shards: [RootCatalogShard]
    ) -> WorkspaceSearchCatalogSnapshot {
        let merged = mergeRootCatalogShards(shards)
        let diagnostics = WorkspaceCatalogDiagnostics(
            generation: generation,
            rootScope: rootScope,
            rootCount: roots.count,
            folderCount: shards.reduce(0) { $0 + $1.folderCount },
            fileCount: merged.files.count
        )
        return WorkspaceSearchCatalogSnapshot(
            generation: generation,
            rootScope: rootScope,
            roots: roots,
            files: merged.files,
            entries: merged.entries,
            rootPathIndexes: shards.map(\.pathSearchIndex),
            diagnostics: diagnostics,
            generationLease: WorkspaceSearchCatalogGenerationLease(
                retaining: shards.map { $0 as AnyObject }
            )
        )
    }

    private func mergeRootCatalogShards(
        _ shards: [RootCatalogShard]
    ) -> (files: [WorkspaceFileRecord], entries: [WorkspaceSearchCatalogEntry]) {
        let totalFileCount = shards.reduce(0) { $0 + $1.files.count }
        var files: [WorkspaceFileRecord] = []
        var entries: [WorkspaceSearchCatalogEntry] = []
        files.reserveCapacity(totalFileCount)
        entries.reserveCapacity(totalFileCount)
        var heap: [RootCatalogMergeCursor] = []
        heap.reserveCapacity(shards.count)

        func cursorPrecedes(_ lhs: RootCatalogMergeCursor, _ rhs: RootCatalogMergeCursor) -> Bool {
            let lhsFile = shards[lhs.shardIndex].files[lhs.elementIndex]
            let rhsFile = shards[rhs.shardIndex].files[rhs.elementIndex]
            if Self.searchCatalogFilePrecedes(lhsFile, rhsFile) { return true }
            if Self.searchCatalogFilePrecedes(rhsFile, lhsFile) { return false }
            if lhs.shardIndex == rhs.shardIndex { return lhs.elementIndex < rhs.elementIndex }
            return lhs.shardIndex < rhs.shardIndex
        }

        func push(_ cursor: RootCatalogMergeCursor) {
            heap.append(cursor)
            var index = heap.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard cursorPrecedes(heap[index], heap[parent]) else { break }
                heap.swapAt(index, parent)
                index = parent
            }
        }

        func pop() -> RootCatalogMergeCursor? {
            guard !heap.isEmpty else { return nil }
            if heap.count == 1 { return heap.removeLast() }
            let first = heap[0]
            heap[0] = heap.removeLast()
            var index = 0
            while true {
                let left = index * 2 + 1
                guard left < heap.count else { break }
                let right = left + 1
                let next = right < heap.count && cursorPrecedes(heap[right], heap[left]) ? right : left
                guard cursorPrecedes(heap[next], heap[index]) else { break }
                heap.swapAt(index, next)
                index = next
            }
            return first
        }

        for shardIndex in shards.indices where !shards[shardIndex].files.isEmpty {
            push(RootCatalogMergeCursor(shardIndex: shardIndex, elementIndex: 0))
        }
        while let cursor = pop() {
            let shard = shards[cursor.shardIndex]
            files.append(shard.files[cursor.elementIndex])
            entries.append(shard.entries[cursor.elementIndex])
            let nextElementIndex = cursor.elementIndex + 1
            if nextElementIndex < shard.files.count {
                push(RootCatalogMergeCursor(shardIndex: cursor.shardIndex, elementIndex: nextElementIndex))
            }
        }
        return (files, entries)
    }

    private static func searchCatalogFilePrecedes(_ lhs: WorkspaceFileRecord, _ rhs: WorkspaceFileRecord) -> Bool {
        if lhs.standardizedFullPath == rhs.standardizedFullPath {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.standardizedFullPath < rhs.standardizedFullPath
    }

    private static func searchCatalogFolderPrecedes(_ lhs: WorkspaceFolderRecord, _ rhs: WorkspaceFolderRecord) -> Bool {
        if lhs.standardizedFullPath == rhs.standardizedFullPath {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.standardizedFullPath < rhs.standardizedFullPath
    }

    #if DEBUG
        private func recordRootCatalogShardShadowComparison(matched: Bool, byteCount: Int) {
            rootCatalogShardShadowComparisonCount += 1
            rootCatalogShardLastShadowByteCount = byteCount
            if !matched {
                rootCatalogShardShadowMismatchCount += 1
            }
        }

        private func catalogShadowBytes(_ snapshot: WorkspaceSearchCatalogSnapshot) -> Data {
            let null = NSNull()
            let roots: [[String: Any]] = snapshot.roots.map { root in
                [
                    "id": root.id.uuidString,
                    "name": root.name,
                    "full_path": root.fullPath,
                    "standardized_full_path": root.standardizedFullPath,
                    "is_system_root": root.isSystemRoot,
                    "kind": Self.rootKindDiagnosticLabel(root.kind)
                ]
            }
            let files: [[String: Any]] = snapshot.files.map { file in
                [
                    "id": file.id.uuidString,
                    "root_id": file.rootID.uuidString,
                    "name": file.name,
                    "relative_path": file.relativePath,
                    "standardized_relative_path": file.standardizedRelativePath,
                    "full_path": file.fullPath,
                    "standardized_full_path": file.standardizedFullPath,
                    "parent_folder_id": file.parentFolderID.map { $0.uuidString as Any } ?? null,
                    "modification_date_bits": file.modificationDate.map {
                        String($0.timeIntervalSinceReferenceDate.bitPattern) as Any
                    } ?? null
                ]
            }
            let entries: [[String: Any]] = snapshot.entries.map { entry in
                [
                    "id": entry.id.uuidString,
                    "root_id": entry.rootID.uuidString,
                    "root_path": entry.rootPath,
                    "root_name": entry.rootName,
                    "name": entry.name,
                    "relative_path": entry.relativePath,
                    "standardized_relative_path": entry.standardizedRelativePath,
                    "full_path": entry.fullPath,
                    "standardized_full_path": entry.standardizedFullPath,
                    "display_path": entry.displayPath
                ]
            }
            let object: [String: Any] = [
                "generation": String(snapshot.generation),
                "root_scope": Self.scopeDiagnosticLabel(snapshot.rootScope),
                "roots": roots,
                "files": files,
                "entries": entries,
                "diagnostics": [
                    "generation": String(snapshot.diagnostics.generation),
                    "root_scope": Self.scopeDiagnosticLabel(snapshot.diagnostics.rootScope),
                    "root_count": snapshot.diagnostics.rootCount,
                    "folder_count": snapshot.diagnostics.folderCount,
                    "file_count": snapshot.diagnostics.fileCount,
                    "total_item_count": snapshot.diagnostics.totalItemCount
                ]
            ]
            return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
    #endif

    func directFolderChildren(
        rootID: UUID,
        relativePath: String = ""
    ) -> WorkspaceDirectFolderChildrenSnapshot? {
        guard let state = rootStatesByID[rootID] else { return nil }
        let key = StandardizedPath.relative(relativePath)
        guard let folderID = state.folderIDsByRelativePath[key] else { return nil }
        return directFolderChildren(folderID: folderID)
    }

    func directFolderChildren(folderID: UUID) -> WorkspaceDirectFolderChildrenSnapshot? {
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
    func warmPathLookupIndexes(rootScope: WorkspaceLookupRootScope = .visibleWorkspace) async -> UInt64 {
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
    func awaitAppliedIngressForAllRoots() async -> [WorkspaceIngressBarrierSample] {
        await awaitAppliedIngress(rootIDs: rootLoadOrder)
    }

    /// Awaits freshness only for roots represented by `rootScope`.
    /// Concurrent requests for the same root share a watermark-keyed flight when the
    /// existing flight covers both the callback-accepted and publisher-accepted cuts.
    func awaitAppliedIngress(rootScope: WorkspaceLookupRootScope) async -> [WorkspaceIngressBarrierSample] {
        await awaitAppliedIngress(rootIDs: rootsForPathLookup(scope: rootScope).map(\.id))
    }

    func awaitAppliedIngress(rootRefs: [WorkspaceRootRef]) async -> [WorkspaceIngressBarrierSample] {
        await awaitAppliedIngress(rootIDs: rootRefs.map(\.id))
    }

    func contentSearchFreshnessPolicy(
        rootScope: WorkspaceLookupRootScope,
        appliedIngressSamples: [WorkspaceIngressBarrierSample]
    ) async -> FileContentFreshnessPolicy {
        await contentSearchFreshnessPolicy(
            rootRefs: rootRefs(scope: rootScope),
            appliedIngressSamples: appliedIngressSamples
        )
    }

    func contentSearchFreshnessPolicy(
        rootRefs: [WorkspaceRootRef],
        appliedIngressSamples: [WorkspaceIngressBarrierSample]
    ) async -> FileContentFreshnessPolicy {
        guard !rootRefs.isEmpty,
              appliedIngressSamples.count == rootRefs.count
        else {
            return .validateDiskMetadata
        }
        let samplesByRootID = Dictionary(uniqueKeysWithValues: appliedIngressSamples.map { ($0.rootID, $0) })
        for root in rootRefs {
            guard let state = rootStatesByID[root.id],
                  let sample = samplesByRootID[root.id],
                  await state.service.canUseCachedSearchContent(
                      afterAppliedWatcherWatermark: sample.appliedWatcherWatermark
                  ),
                  publisherIngressCoordinator.appliedSnapshot(rootID: root.id)
                  .acceptedServicePublicationSequence <= sample.appliedServicePublicationSequence
            else {
                return .validateDiskMetadata
            }
        }
        return .cachedMetadata
    }

    /// Resolves the narrowest safe workspace freshness scope for an explicit request.
    /// Absolute paths await only their containing loaded root. Absolute paths outside all
    /// loaded roots (including always-readable support files) do not pay a workspace barrier.
    /// Relative and alias-shaped paths await the caller's fallback scope because resolution
    /// may depend on more than one candidate root.
    func awaitAppliedIngressForExplicitRequest(
        userPath: String,
        fallbackScope: WorkspaceLookupRootScope
    ) async -> [WorkspaceIngressBarrierSample] {
        await awaitAppliedIngressForExplicitRequest(
            userPath: userPath,
            fallbackRootRefs: rootRefs(scope: fallbackScope)
        )
    }

    func awaitAppliedIngressForExplicitRequest(
        userPath: String,
        fallbackRootRefs: [WorkspaceRootRef]
    ) async -> [WorkspaceIngressBarrierSample] {
        let trimmed = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        guard standardized.hasPrefix("/") else {
            return await awaitAppliedIngress(rootIDs: fallbackRootRefs.map(\.id))
        }
        let containingRootID = fallbackRootRefs
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
            guard !Task.isCancelled else { break }
            let chunkEnd = min(chunkStart + Self.maxConcurrentScopedIngressBarriers, orderedRootIDs.count)
            await withTaskGroup(of: (Int, WorkspaceIngressBarrierSample?).self) { group in
                for index in chunkStart ..< chunkEnd {
                    let rootID = orderedRootIDs[index]
                    guard let target = targetsByRootID[rootID] else { continue }
                    group.addTask { [weak self] in
                        guard !Task.isCancelled, let self else { return (index, nil) }
                        let sample = await awaitAppliedIngress(rootID: rootID, target: target)
                        return (index, sample)
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
        guard !Task.isCancelled, let state = rootStatesByID[rootID] else { return nil }
        if completedScopedIngressBarrierCutsByRootID[rootID] != nil {
            let applied = publisherIngressCoordinator.appliedSnapshot(rootID: rootID)
            if applied.appliedWatcherWatermark >= target.watcherAcceptedWatermark,
               applied.appliedServicePublicationSequence >= target.acceptedServicePublicationSequence
            {
                #if DEBUG
                    scopedIngressBarrierNoopCountsByRootID[rootID, default: 0] += 1
                #endif
                return WorkspaceIngressBarrierSample(
                    rootID: rootID,
                    rootPath: state.root.standardizedFullPath,
                    pendingRawEventCountBeforeFlush: 0,
                    acceptedWatcherWatermark: target.watcherAcceptedWatermark.rawValue,
                    publishedServicePublicationSequence: target.acceptedServicePublicationSequence,
                    appliedServicePublicationSequence: applied.appliedServicePublicationSequence,
                    appliedWatcherWatermark: applied.appliedWatcherWatermark.rawValue
                )
            }
        }
        let flightState = scopedIngressBarrierFlightStatesByRootID[rootID]
            ?? ScopedIngressBarrierRootFlightState()

        if let active = flightState.active, active.target.covers(target) {
            #if DEBUG
                scopedIngressBarrierJoinCountsByRootID[rootID, default: 0] += 1
            #endif
            guard let output = await active.join.value() else { return nil }
            return scopedIngressBarrierSample(from: output)
        }

        if let pending = flightState.pending, pending.target.covers(target) {
            #if DEBUG
                scopedIngressBarrierJoinCountsByRootID[rootID, default: 0] += 1
                scopedIngressBarrierCoalescedSuccessorCountsByRootID[rootID, default: 0] += 1
            #endif
            guard let output = await pending.join.value() else { return nil }
            return scopedIngressBarrierSample(from: output)
        }

        if let pending = flightState.pending {
            pending.target = pending.target.merging(target)
            #if DEBUG
                scopedIngressBarrierJoinCountsByRootID[rootID, default: 0] += 1
                scopedIngressBarrierCoalescedSuccessorCountsByRootID[rootID, default: 0] += 1
            #endif
            guard let output = await pending.join.value() else { return nil }
            return scopedIngressBarrierSample(from: output)
        }

        if flightState.active != nil {
            let join = ScopedIngressBarrierJoin()
            #if DEBUG
                let enqueuedAtNanoseconds = debugNowNanoseconds()
                scopedIngressBarrierSuccessorCountsByRootID[rootID, default: 0] += 1
            #else
                let enqueuedAtNanoseconds: UInt64 = 0
            #endif
            flightState.pending = ScopedIngressBarrierPendingFlight(
                target: target,
                join: join,
                enqueuedAtNanoseconds: enqueuedAtNanoseconds
            )
            scopedIngressBarrierFlightStatesByRootID[rootID] = flightState
            guard let output = await join.value() else { return nil }
            return scopedIngressBarrierSample(from: output)
        }

        let join = ScopedIngressBarrierJoin()
        launchScopedIngressBarrier(
            rootID: rootID,
            target: target,
            join: join,
            flightState: flightState
        )
        guard let output = await join.value() else { return nil }
        return scopedIngressBarrierSample(from: output)
    }

    private func launchScopedIngressBarrier(
        rootID: UUID,
        target: ScopedIngressBarrierTarget,
        join: ScopedIngressBarrierJoin,
        flightState: ScopedIngressBarrierRootFlightState
    ) {
        guard let state = rootStatesByID[rootID] else {
            join.complete(with: nil)
            return
        }
        nextScopedIngressBarrierToken &+= 1
        let token = nextScopedIngressBarrierToken
        let publisherIngressCoordinator = publisherIngressCoordinator
        let root = state.root
        let service = state.service
        #if DEBUG
            scopedIngressBarrierLaunchCountsByRootID[rootID, default: 0] += 1
            let barrierCompletionNowNanoseconds = debugNowNanoseconds
            let barrierStartedAtNanoseconds = barrierCompletionNowNanoseconds()
            let scopedIngressBarrierWillFlushHandler = scopedIngressBarrierWillFlushHandler
            let publisherIngressWillWaitHandler = publisherIngressWillWaitHandler
        #else
            let barrierStartedAtNanoseconds: UInt64 = 0
        #endif
        #if DEBUG || EDIT_FLOW_PERF
            let lifecycleCorrelation = EditFlowPerf.currentLifecycleCorrelation
        #else
            let lifecycleCorrelation: EditFlowPerf.LifecycleCorrelation? = nil
        #endif
        let flight = ScopedIngressBarrierFlight(
            token: token,
            target: target,
            join: join,
            startedAtNanoseconds: barrierStartedAtNanoseconds
        )
        flightState.active = flight
        scopedIngressBarrierFlightStatesByRootID[rootID] = flightState
        flight.task = Task { [weak self] in
            #if DEBUG
                if let scopedIngressBarrierWillFlushHandler {
                    await scopedIngressBarrierWillFlushHandler(rootID)
                }
            #endif
            guard !Task.isCancelled else {
                if let self {
                    await finishScopedIngressBarrier(
                        rootID: rootID,
                        token: token,
                        target: target,
                        output: nil,
                        startedAtNanoseconds: barrierStartedAtNanoseconds,
                        join: join
                    )
                } else {
                    join.complete(with: nil)
                }
                return
            }
            #if DEBUG
                let pendingCount = await service.pendingRawEventCountForDiagnostics()
            #else
                let pendingCount = 0
            #endif
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.WorkspaceIngress.rootFlushBegan,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(
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
            guard !Task.isCancelled else {
                if let self {
                    await finishScopedIngressBarrier(
                        rootID: rootID,
                        token: token,
                        target: target,
                        output: nil,
                        startedAtNanoseconds: barrierStartedAtNanoseconds,
                        join: join
                    )
                } else {
                    join.complete(with: nil)
                }
                return
            }
            await publisherIngressCoordinator.waitUntilApplied(
                rootID: rootID,
                servicePublicationSequence: target.acceptedServicePublicationSequence
            )
            guard !Task.isCancelled else {
                if let self {
                    await finishScopedIngressBarrier(
                        rootID: rootID,
                        token: token,
                        target: target,
                        output: nil,
                        startedAtNanoseconds: barrierStartedAtNanoseconds,
                        join: join
                    )
                } else {
                    join.complete(with: nil)
                }
                return
            }
            let publishedSequence = await service.flushPendingEventsNow(
                throughAcceptedWatcherWatermark: target.watcherAcceptedWatermark
            )
            guard !Task.isCancelled else {
                if let self {
                    await finishScopedIngressBarrier(
                        rootID: rootID,
                        token: token,
                        target: target,
                        output: nil,
                        startedAtNanoseconds: barrierStartedAtNanoseconds,
                        join: join
                    )
                } else {
                    join.complete(with: nil)
                }
                return
            }
            let acceptedDownstreamCut = publisherIngressCoordinator.appliedSnapshot(rootID: rootID)
                .acceptedServicePublicationSequence
            await publisherIngressCoordinator.waitUntilApplied(
                rootID: rootID,
                servicePublicationSequence: max(target.acceptedServicePublicationSequence, acceptedDownstreamCut)
            )
            guard !Task.isCancelled else {
                if let self {
                    await finishScopedIngressBarrier(
                        rootID: rootID,
                        token: token,
                        target: target,
                        output: nil,
                        startedAtNanoseconds: barrierStartedAtNanoseconds,
                        join: join
                    )
                } else {
                    join.complete(with: nil)
                }
                return
            }
            let applied = publisherIngressCoordinator.appliedSnapshot(rootID: rootID)
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.WorkspaceIngress.rootFlushEnded,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(
                    pendingRawEventCount: pendingCount,
                    rootToken: service.diagnosticRootToken.uuidString,
                    ingressSequence: applied.appliedWatcherWatermark.rawValue,
                    barrierSequence: applied.appliedServicePublicationSequence
                )
            )
            let sample = WorkspaceIngressBarrierSample(
                rootID: rootID,
                rootPath: root.standardizedFullPath,
                pendingRawEventCountBeforeFlush: pendingCount,
                acceptedWatcherWatermark: target.watcherAcceptedWatermark.rawValue,
                publishedServicePublicationSequence: publishedSequence,
                appliedServicePublicationSequence: applied.appliedServicePublicationSequence,
                appliedWatcherWatermark: applied.appliedWatcherWatermark.rawValue
            )
            #if DEBUG
                let output = ScopedIngressBarrierTaskOutput(
                    sample: sample,
                    completedAtNanoseconds: barrierCompletionNowNanoseconds()
                )
            #else
                let output = sample
            #endif
            if let self {
                await finishScopedIngressBarrier(
                    rootID: rootID,
                    token: token,
                    target: target,
                    output: output,
                    startedAtNanoseconds: barrierStartedAtNanoseconds,
                    join: join
                )
            } else {
                join.complete(with: output)
            }
        }
    }

    private func finishScopedIngressBarrier(
        rootID: UUID,
        token: UInt64,
        target: ScopedIngressBarrierTarget,
        output: ScopedIngressBarrierTaskOutput?,
        startedAtNanoseconds: UInt64,
        join: ScopedIngressBarrierJoin
    ) {
        guard let flightState = scopedIngressBarrierFlightStatesByRootID[rootID],
              flightState.active?.token == token
        else {
            join.complete(with: output)
            return
        }
        flightState.active = nil
        if let output {
            completedScopedIngressBarrierCutsByRootID[rootID] = ScopedIngressBarrierCompletedCut(
                target: target,
                sample: scopedIngressBarrierSample(from: output)
            )
        }
        #if DEBUG
            if let output {
                recordScopedIngressBarrierCompletion(
                    rootID: rootID,
                    token: token,
                    target: target,
                    sample: output.sample,
                    startedAtNanoseconds: startedAtNanoseconds,
                    completedAtNanoseconds: output.completedAtNanoseconds
                )
            }
        #endif

        if let output, let pending = flightState.pending {
            flightState.pending = nil
            launchScopedIngressBarrier(
                rootID: rootID,
                target: pending.target,
                join: pending.join,
                flightState: flightState
            )
            join.complete(with: output)
            return
        }

        let pending = flightState.pending
        flightState.pending = nil
        scopedIngressBarrierFlightStatesByRootID.removeValue(forKey: rootID)
        if output == nil {
            pending?.join.complete(with: nil)
        }
        join.complete(with: output)
    }

    private func scopedIngressBarrierSample(
        from output: ScopedIngressBarrierTaskOutput
    ) -> WorkspaceIngressBarrierSample {
        #if DEBUG
            output.sample
        #else
            output
        #endif
    }

    /// Compatibility wrapper for callers that still consume the original diagnostic shape.
    func flushPendingServiceEventsForAllRoots() async -> [(rootPath: String, pendingRawEventCountBeforeFlush: Int)] {
        await awaitAppliedIngressForAllRoots().map { sample in
            (sample.rootPath, sample.pendingRawEventCountBeforeFlush)
        }
    }

    // MARK: - Deferred replay buffer ownership

    func updateDeferredReplayRoutingState(
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

    func updateDeferredReplayImmediateChunkSizeOverride(_ chunkSize: Int?) async {
        await deferredReplayBuffer.updateImmediateReplayChunkSizeOverride(chunkSize)
    }

    func registerDeferredReplayRootGeneration(_ generation: UInt64, forRootKey rootKey: String) async {
        await deferredReplayBuffer.registerActiveRootGeneration(generation, forRootKey: rootKey)
    }

    func unregisterDeferredReplayRootGeneration(forRootKey rootKey: String) async {
        await deferredReplayBuffer.unregisterActiveRootGeneration(forRootKey: rootKey)
    }

    func ingestDeferredReplayLiveDeltas(
        _ deltas: [FileSystemDelta],
        forRootKey rootKey: String,
        rootGeneration: UInt64
    ) async -> DeferredReplayIngressResult {
        await deferredReplayBuffer.ingestLiveDeltas(deltas, forRootKey: rootKey, rootGeneration: rootGeneration)
    }

    func ingestDeferredReplayLiveDeltas(
        _ deltas: [FileSystemDelta],
        forRootKey rootKey: String
    ) async -> DeferredReplayIngressResult {
        await deferredReplayBuffer.ingestLiveDeltas(deltas, forRootKey: rootKey)
    }

    func finishDeferredReplayPreparedImmediateIngress(_ immediateReplay: PreparedImmediateReplay) async {
        await deferredReplayBuffer.finishPreparedImmediateIngress(immediateReplay)
    }

    func enqueueDeferredReplayDeltas(
        _ deltas: [FileSystemDelta],
        forRootKey rootKey: String
    ) async -> DeferredReplayIngressResult {
        await deferredReplayBuffer.enqueueDeferredDeltas(deltas, forRootKey: rootKey)
    }

    func drainDeferredReplayPreparedBatches(
        preferredRootOrder: [String],
        chunkSize: Int
    ) async -> [PreparedFileSystemReplayBatch] {
        await deferredReplayBuffer.drainPreparedBatches(
            preferredRootOrder: preferredRootOrder,
            chunkSize: chunkSize
        )
    }

    func clearDeferredReplayRoot(_ rootKey: String) async {
        await deferredReplayBuffer.clearRoot(rootKey)
    }

    func clearDeferredReplayBuffer() async {
        await deferredReplayBuffer.clearAll()
    }

    func hasDeferredReplayPendingWork() async -> Bool {
        await deferredReplayBuffer.hasPendingWork()
    }

    func pendingDeferredReplayDeltaCount(forRootKey rootKey: String) async -> Int {
        await deferredReplayBuffer.pendingDeltaCount(forRootKey: rootKey)
    }

    func deferredReplayPendingWorkSnapshot() async -> DeferredReplayPendingWorkSnapshot {
        await deferredReplayBuffer.pendingWorkSnapshot()
    }

    #if DEBUG
        func deferredReplayDiagnosticsSnapshot() async -> DeferredReplayBufferDiagnostics {
            await deferredReplayBuffer.diagnosticsSnapshot()
        }
    #endif

    func refreshFileSystemSettings(
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

    func allCodemapSnapshots() -> [WorkspaceCodemapSnapshot] {
        codemapSnapshotsByFileID.values
            .filter { isDiscoverableFileID($0.fileID) }
            .sorted { $0.fullPath < $1.fullPath }
    }

    func allCodemapFileAPIs() -> [FileAPI] {
        codemapFileAPIAggregate().orderedFileAPIs
    }

    func codemapFileAPIAggregate() -> WorkspaceCodemapFileAPIAggregate {
        let actorBodyTotal = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.actorBodyTotal)
        defer { EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.actorBodyTotal, actorBodyTotal) }

        if let cachedCodemapFileAPIAggregate {
            return cachedCodemapFileAPIAggregate
        }

        #if DEBUG || EDIT_FLOW_PERF
            let stateSnapshot = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.stateSnapshot)
            let discoverableSnapshots = codemapSnapshotsByFileID.values
                .filter { isDiscoverableFileID($0.fileID) }
            EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.stateSnapshot, stateSnapshot)

            let materialization = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.materialization)
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
            EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.AutoSelect.AllCodemapFileAPIs.materialization, materialization)
        #endif
        cachedCodemapFileAPIAggregate = aggregate
        return aggregate
    }

    func codemapSnapshotDictionary() -> [UUID: WorkspaceCodemapSnapshot] {
        codemapSnapshotsByFileID.filter { isDiscoverableFileID($0.key) }
    }

    func codemapSnapshots(inRoot rootID: UUID) -> [WorkspaceCodemapSnapshot] {
        guard let fileIDs = codemapFileIDsByRootID[rootID] else { return [] }
        return fileIDs
            .filter(isDiscoverableFileID)
            .compactMap { codemapSnapshotsByFileID[$0] }
            .sorted { $0.relativePath < $1.relativePath }
    }

    func codemapSnapshot(fileID: UUID) -> WorkspaceCodemapSnapshot? {
        guard isDiscoverableFileID(fileID) else { return nil }
        return codemapSnapshotsByFileID[fileID]
    }

    func codemapSnapshot(rootID: UUID, relativePath: String) -> WorkspaceCodemapSnapshot? {
        guard let file = file(rootID: rootID, relativePath: relativePath), isDiscoverableFileID(file.id) else { return nil }
        return codemapSnapshotsByFileID[file.id]
    }

    @discardableResult
    func invalidateCodemapSnapshotsForCheckoutMutation(rootIDs: [UUID]) -> [UUID] {
        var removedFileIDs: [UUID] = []
        for rootID in rootIDs {
            removedFileIDs.append(contentsOf: removeCodemapSnapshots(forRootID: rootID))
        }
        return removedFileIDs
    }

    @discardableResult
    func applyObservedCodemapResults(_ results: [WorkspaceObservedCodemapResult]) -> [String] {
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

    @discardableResult
    func reconcileLoadedRootCatalogWithDisk(rootID: UUID) async -> [FileSystemDelta] {
        guard let state = rootStatesByID[rootID] else { return [] }
        let root = state.root
        let folderPaths = Set(
            state.folderIDsByRelativePath.compactMap { relativePath, folderID -> String? in
                isDiscoverableFolderID(folderID) ? relativePath : nil
            }
        )
        guard !folderPaths.isEmpty else { return [] }

        let deltas: [FileSystemDelta]
        do {
            deltas = try await state.service.scanFoldersInParallel(folderPaths.sorted()).deltas
        } catch {
            return []
        }
        guard !deltas.isEmpty,
              let currentRoot = rootStatesByID[rootID]?.root,
              currentRoot.standardizedFullPath == root.standardizedFullPath
        else { return deltas }

        await handleObservedFileSystemDeltas(deltas, root: root)
        return deltas
    }

    func ensureIndexedFiles(paths: [String]) async -> [String] {
        struct EligibleFile {
            let fullPath: String
            let rootID: UUID
            let rootPath: String
            let relativePath: String
        }

        var eligibleFiles: [EligibleFile] = []
        for rawPath in paths {
            let fullPath = StandardizedPath.absolute(rawPath)
            guard fileIDsByStandardizedFullPath[fullPath] == nil,
                  let root = loadedRoot(containing: fullPath),
                  let service = rootStatesByID[root.id]?.service
            else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let relativePath = relativePath(for: fullPath, rootPath: root.standardizedFullPath)
            guard !relativePath.isEmpty,
                  await service.catalogEligibleRegularFileExists(relativePath: relativePath)
            else { continue }
            #if DEBUG
                if let ensureIndexedFilesEligibilityDidResolveHandler {
                    await ensureIndexedFilesEligibilityDidResolveHandler(root.id, fullPath)
                }
            #endif
            eligibleFiles.append(EligibleFile(
                fullPath: fullPath,
                rootID: root.id,
                rootPath: root.standardizedFullPath,
                relativePath: relativePath
            ))
        }

        var indexed: [String] = []
        var upsertedFilesByRoot: [UUID: [WorkspaceFileRecord]] = [:]
        for eligible in eligibleFiles {
            guard fileIDsByStandardizedFullPath[eligible.fullPath] == nil,
                  folderIDsByStandardizedFullPath[eligible.fullPath] == nil,
                  var state = rootStatesByID[eligible.rootID],
                  state.root.id == eligible.rootID,
                  state.root.standardizedFullPath == eligible.rootPath,
                  rootIDsByStandardizedPath[eligible.rootPath] == eligible.rootID,
                  loadedRoot(containing: eligible.fullPath)?.id == eligible.rootID,
                  state.fileIDsByRelativePath[eligible.relativePath] == nil,
                  state.folderIDsByRelativePath[eligible.relativePath] == nil
            else { continue }
            var indexes = RootIndexBuffers()
            let hierarchy = eligible.relativePath.split(separator: "/").count
            indexFiles(
                [FSItemDTO(relativePath: eligible.relativePath, isDirectory: false, hierarchy: hierarchy)],
                root: state.root,
                state: &state,
                indexes: &indexes
            )
            guard !indexes.filesByID.isEmpty else { continue }
            commit(indexes)
            rootStatesByID[eligible.rootID] = state
            indexed.append(eligible.fullPath)
            upsertedFilesByRoot[eligible.rootID, default: []].append(contentsOf: indexes.filesByID.values)
        }
        if !indexed.isEmpty {
            let affectedKinds = Set(upsertedFilesByRoot.keys.compactMap { rootStatesByID[$0]?.root.kind })
            invalidatePathMatchSnapshot(
                affectedRootKinds: affectedKinds,
                reason: .explicitMaterialization,
                affectedRootIDs: Set(upsertedFilesByRoot.keys)
            )
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

    func makeFileTreeSelectionSnapshot(_ request: WorkspaceFileTreeSnapshotRequest) -> FileTreeSelectionSnapshot {
        makeFileTreeSelectionSnapshot(request, selectedStoreFileIDs: request.selectedFileIDs)
    }

    func makeFileTreeSelectionSnapshot(
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

    func codemapUpdates() -> AsyncStream<WorkspaceCodemapUpdateEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            codemapUpdateContinuations[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeCodemapUpdateContinuation(id) }
            }
        }
    }

    func codemapScanProgressUpdates() -> AsyncStream<(Int, Int)> {
        codeScanActor.subscribeToProgress()
    }

    func cancelAllCodemapScans() async {
        await codeScanActor.cancelAllScans()
        pendingCodemapRepairFileIDs.removeAll()
    }

    func cancelCodemapScansForCheckoutMutation(rootIDs: [UUID]) async {
        let rootFolderPaths = rootIDs.compactMap { rootStatesByID[$0]?.root.standardizedFullPath }
        guard !rootFolderPaths.isEmpty else { return }
        await codeScanActor.cancelAndUnloadScans(forRootFolders: rootFolderPaths)
    }

    func clearAllCodemapCaches(rootFolders: [String]) async {
        await codeScanActor.clearAllCaches(rootFolders: rootFolders)
        removeAllCodemapSnapshots()
    }

    func purgeStaleCodemapCaches(keepingRootPaths: [String]) async {
        await codeScanActor.purgeStaleRootCaches(keepingRootPaths: keepingRootPaths)
    }

    #if DEBUG
        func codemapMemoryCounters() async -> CodeScanActor.CodemapMemoryCounters {
            await codeScanActor.codemapMemoryCounters()
        }

        func setCodemapScanWillStartHandlerForTesting(
            _ handler: (@Sendable (UUID) async -> Void)?
        ) async {
            await codeScanActor.setScanWillStartHandlerForTesting(handler)
        }
    #endif

    private func removeCodemapUpdateContinuation(_ id: UUID) {
        codemapUpdateContinuations.removeValue(forKey: id)
    }

    private func clearSessionWorktreeCodemapInitialization(rootIDs: [UUID]) {
        initializingSessionWorktreeCodemapRootIDs.subtract(rootIDs)
        initializedSessionWorktreeCodemapRootIDs.subtract(rootIDs)
    }

    private func completeSessionWorktreeCodemapInitialization(
        requestedRootIDs: [UUID],
        submittedRootIDs: [UUID]
    ) {
        initializingSessionWorktreeCodemapRootIDs.subtract(requestedRootIDs)
        let completedRootIDs = submittedRootIDs.filter { rootID in
            guard let root = rootStatesByID[rootID]?.root,
                  root.kind == .sessionWorktree,
                  !files(inRoot: rootID).isEmpty
            else { return false }
            return true
        }
        initializedSessionWorktreeCodemapRootIDs.formUnion(completedRootIDs)
    }

    @discardableResult
    func loadRoot(
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
            let rootLoadRouteStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
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
                WorkspaceRestorePerfLog.event(
                    "store.rootLoad.existing",
                    fields: [
                        "rootName": rootLoadName,
                        "rootID": WorkspaceRestorePerfLog.shortID(existing.id),
                        "kind": "\(loadConfiguration.kind)",
                        "duration": rootLoadRouteStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
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
                WorkspaceRestorePerfLog.event(
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
            WorkspaceRestorePerfLog.event(
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

    func cancelRootLoad(path: String) {
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
            let performLoadStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            WorkspaceRestorePerfLog.event(
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
            enableHierarchicalIgnores: enableHierarchicalIgnores
        )
        #if DEBUG
            if let watcherActivationFailurePointForNewServicesForTesting {
                await service.setWatcherActivationFailureForTesting(
                    watcherActivationFailurePointForNewServicesForTesting
                )
            }
        #endif

        #if DEBUG
            var rootRecordCreatedFields: [String: String] = [
                "rootName": root.name,
                "rootID": WorkspaceRestorePerfLog.shortID(root.id),
                "kind": "\(root.kind)",
                "durationSinceStoreRootLoadBegin": performLoadStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
            ]
            rootRecordCreatedFields.merge(
                WorkspaceRootLoadDiagnostics.rootRecordCreatedFields(forPath: standardizedPath),
                uniquingKeysWith: { _, diagnostic in diagnostic }
            )
            WorkspaceRestorePerfLog.event("store.rootLoad.rootRecordCreated", fields: rootRecordCreatedFields)
        #endif

        var state = RootState(
            lifetimeID: UUID(),
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
            let walkStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
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
                        "rootID": WorkspaceRestorePerfLog.shortID(root.id),
                        "chunkFolders": "\(chunk.folders.count)",
                        "chunkFiles": "\(chunk.files.count)",
                        "durationSinceStoreRootLoadBegin": performLoadStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                    ]
                    firstChunkFields.merge(
                        WorkspaceRootLoadDiagnostics.firstPreparedChunkFields(forPath: standardizedPath),
                        uniquingKeysWith: { _, diagnostic in diagnostic }
                    )
                    WorkspaceRestorePerfLog.event("store.rootLoad.firstPreparedChunk", fields: firstChunkFields)
                }
            #endif
            indexFolders(chunk.folders, root: root, state: &state, indexes: &stagedIndexes)
            indexFiles(chunk.files, root: root, state: &state, indexes: &stagedIndexes)
        }
        try Task.checkCancellation()
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "store.rootLoad.walk",
                fields: [
                    "rootName": root.name,
                    "chunkCount": "\(chunkCount)",
                    "folders": "\(stagedIndexes.foldersByID.count)",
                    "files": "\(stagedIndexes.filesByID.count)",
                    "duration": walkStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
            let commitStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif

        commit(stagedIndexes)
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "store.rootLoad.commit",
                fields: [
                    "rootName": root.name,
                    "folders": "\(stagedIndexes.foldersByID.count)",
                    "files": "\(stagedIndexes.filesByID.count)",
                    "duration": commitStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
        rootIDsByStandardizedPath[root.standardizedFullPath] = root.id
        rootStatesByID[root.id] = state
        rootLoadOrder.append(root.id)
        appliedIndexGenerationsByRootID[root.id] = 0
        catalogGenerationsByRootID[root.id] = 0
        #if DEBUG
            rootCrawlCountsByRootID[root.id, default: 0] += 1
        #endif
        invalidatePathMatchSnapshot(
            affectedRootKinds: [root.kind],
            reason: .rootLoad,
            affectedRootIDs: [root.id]
        )
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "store.rootLoad.end",
                fields: [
                    "rootName": root.name,
                    "rootID": WorkspaceRestorePerfLog.shortID(root.id),
                    "folders": "\(stagedIndexes.foldersByID.count)",
                    "files": "\(stagedIndexes.filesByID.count)",
                    "duration": performLoadStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
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

    func unloadRoot(id rootID: UUID) async {
        await unloadRoots(ids: [rootID])
    }

    func unloadRoots(ids rootIDs: [UUID]) async {
        var seenRootIDs = Set<UUID>()
        let orderedRootIDs = rootIDs.filter { seenRootIDs.insert($0).inserted }
        guard !orderedRootIDs.isEmpty else { return }

        var statesToUnload: [(rootID: UUID, state: RootState)] = []
        for rootID in orderedRootIDs {
            if let flightState = scopedIngressBarrierFlightStatesByRootID.removeValue(forKey: rootID) {
                flightState.active?.task?.cancel()
                flightState.active?.join.complete(with: nil)
                flightState.pending?.join.complete(with: nil)
            }
            completedScopedIngressBarrierCutsByRootID.removeValue(forKey: rootID)
            watcherCancellablesByRootID.removeValue(forKey: rootID)?.cancel()
            publisherIngressCoordinator.closePublisherIngress(rootID: rootID)
            guard let state = rootStatesByID.removeValue(forKey: rootID) else { continue }
            statesToUnload.append((rootID, state))
        }
        guard !statesToUnload.isEmpty else { return }
        invalidatePathMatchSnapshot(
            affectedRootKinds: Set(statesToUnload.map(\.state.root.kind)),
            reason: .rootUnload,
            affectedRootIDs: Set(statesToUnload.map(\.rootID))
        )
        for entry in statesToUnload {
            for fileID in entry.state.fileIDsByRelativePath.values {
                searchContentInvalidationEpochsByFileID.removeValue(forKey: fileID)
            }
            await searchDecodedContentCache.invalidate(rootID: entry.rootID)
            await interactiveReadCache.invalidate(rootID: entry.rootID)
        }
        #if DEBUG
            let rootUnloadStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
            let rootUnloadFolderCount = statesToUnload.reduce(0) { $0 + $1.state.folderIDsByRelativePath.count }
            let rootUnloadFileCount = statesToUnload.reduce(0) { $0 + $1.state.fileIDsByRelativePath.count }
            WorkspaceRestorePerfLog.event(
                "store.rootUnload.begin",
                fields: [
                    "rootCount": "\(statesToUnload.count)",
                    "folderCount": "\(rootUnloadFolderCount)",
                    "fileCount": "\(rootUnloadFileCount)"
                ]
            )
            let detachStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
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

        let removedRootIDSet = Set(statesToUnload.map(\.rootID))
        let removedFileIDs = statesToUnload.flatMap(\.state.fileIDsByRelativePath.values)
        pendingCodemapRepairFileIDs.subtract(removedFileIDs)
        initializingSessionWorktreeCodemapRootIDs.subtract(removedRootIDSet)
        initializedSessionWorktreeCodemapRootIDs.subtract(removedRootIDSet)
        rootLoadOrder.removeAll { removedRootIDSet.contains($0) }
        for entry in statesToUnload {
            rootIDsByStandardizedPath.removeValue(forKey: entry.state.root.standardizedFullPath)
            rootLoadConfigurationsByPath.removeValue(forKey: entry.state.root.standardizedFullPath)
        }
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "store.rootUnload.detach",
                fields: [
                    "rootCount": "\(statesToUnload.count)",
                    "duration": detachStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
            let stopWatchersStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif

        // Stop each detached service exactly once. The caller only waits through a bounded
        // completion latch; cancellation cannot interrupt synchronous FSEvents flush work.
        let detachedWatcherStops = startDetachedWatcherStops(statesToUnload)
        #if DEBUG
            if publisherIngressCoordinator.pendingPublisherIngressCount(rootIDs: removedRootIDSet) > 0,
               let publisherIngressWillWaitHandler
            {
                await publisherIngressWillWaitHandler(removedRootIDSet)
            }
        #endif
        let removedRootIDsInOrder = statesToUnload.map(\.rootID)
        async let publisherIngressReports = publisherIngressCoordinator.terminateClosedPublisherIngress(
            rootIDs: removedRootIDsInOrder,
            gracefulDrainTimeoutNanoseconds: unloadTerminationPolicy.publisherIngressGraceNanoseconds,
            sleep: unloadTerminationPolicy.sleep
        )
        let watcherStopReports = await awaitDetachedWatcherStops(detachedWatcherStops)
        let resolvedPublisherIngressReports = await publisherIngressReports
        let terminationDiagnostics = WorkspaceRootUnloadTerminationDiagnostics(
            publisherIngressReports: resolvedPublisherIngressReports,
            watcherStopReports: watcherStopReports
        )
        WorkspaceRootUnloadDiagnosticsLog.record(terminationDiagnostics)
        #if DEBUG
            if let rootUnloadTerminationDidCompleteHandler {
                await rootUnloadTerminationDidCompleteHandler(terminationDiagnostics)
            }
        #endif
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "store.rootUnload.stopWatchers",
                fields: [
                    "rootCount": "\(statesToUnload.count)",
                    "duration": stopWatchersStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
            let indexCleanupStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
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
            catalogGenerationsByRootID.removeValue(forKey: rootID)
            #if DEBUG
                publicationInvalidationHistoryByRootID.removeValue(forKey: rootID)
                scopedIngressBarrierLaunchCountsByRootID.removeValue(forKey: rootID)
                scopedIngressBarrierJoinCountsByRootID.removeValue(forKey: rootID)
                scopedIngressBarrierSuccessorCountsByRootID.removeValue(forKey: rootID)
                scopedIngressBarrierCoalescedSuccessorCountsByRootID.removeValue(forKey: rootID)
                scopedIngressBarrierCompletionCountsByRootID.removeValue(forKey: rootID)
                scopedIngressBarrierNoopCountsByRootID.removeValue(forKey: rootID)
                scopedIngressBarrierTotalWaitMillisecondsByRootID.removeValue(forKey: rootID)
                scopedIngressBarrierMaxWaitMillisecondsByRootID.removeValue(forKey: rootID)
                lastCompletedScopedIngressBarrierByRootID.removeValue(forKey: rootID)
                rootCrawlCountsByRootID.removeValue(forKey: rootID)
            #endif
        }

        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "store.rootUnload.indexCleanup",
                fields: [
                    "rootCount": "\(statesToUnload.count)",
                    "removedFolders": "\(rootUnloadFolderCount)",
                    "removedFiles": "\(rootUnloadFileCount)",
                    "duration": indexCleanupStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
            let codeScanCancelStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        await codeScanActor.cancelAndUnloadScans(forRootFolders: rootPathsToUnload)
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "store.rootUnload.codeScanCancel",
                fields: [
                    "rootCount": "\(statesToUnload.count)",
                    "duration": codeScanCancelStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
        finishRootUnload(for: unloadingPaths)
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "store.rootUnload.end",
                fields: [
                    "rootCount": "\(statesToUnload.count)",
                    "duration": rootUnloadStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
    }

    private func startDetachedWatcherStops(
        _ statesToUnload: [(rootID: UUID, state: RootState)]
    ) -> [DetachedWatcherStop] {
        statesToUnload.enumerated().map { index, entry in
            let completionLatch = WorkspaceRootUnloadCompletionLatch()
            let service = entry.state.service
            #if DEBUG
                let watcherStopWillBeginHandler = watcherStopWillBeginHandler
            #endif
            let task = Task.detached {
                #if DEBUG
                    if let watcherStopWillBeginHandler {
                        await watcherStopWillBeginHandler(entry.rootID)
                    }
                #endif
                await service.stopWatchingForChanges()
                completionLatch.complete()
            }
            return DetachedWatcherStop(
                index: index,
                rootID: entry.rootID,
                rootPath: entry.state.root.standardizedFullPath,
                completionLatch: completionLatch,
                task: task
            )
        }
    }

    private func awaitDetachedWatcherStops(
        _ stops: [DetachedWatcherStop]
    ) async -> [WorkspaceRootWatcherStopReport] {
        await withTaskGroup(of: (Int, WorkspaceRootWatcherStopReport).self) { group in
            for stop in stops {
                group.addTask { [unloadTerminationPolicy] in
                    let outcome = await WorkspaceRootUnloadBoundedWait.waitForCompletion(
                        stop.completionLatch,
                        timeoutNanoseconds: unloadTerminationPolicy.watcherStopGraceNanoseconds,
                        sleep: unloadTerminationPolicy.sleep
                    )
                    if outcome != .completed {
                        stop.task.cancel()
                    }
                    return (
                        stop.index,
                        WorkspaceRootWatcherStopReport(
                            rootID: stop.rootID,
                            rootPath: stop.rootPath,
                            outcome: outcome,
                            graceNanoseconds: unloadTerminationPolicy.watcherStopGraceNanoseconds
                        )
                    )
                }
            }
            var reports: [(Int, WorkspaceRootWatcherStopReport)] = []
            for await report in group {
                reports.append(report)
            }
            return reports.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    func file(rootID: UUID, relativePath: String) -> WorkspaceFileRecord? {
        guard let state = rootStatesByID[rootID] else { return nil }
        let key = StandardizedPath.relative(relativePath)
        guard let fileID = state.fileIDsByRelativePath[key] else { return nil }
        return filesByID[fileID]
    }

    func folder(rootID: UUID, relativePath: String) -> WorkspaceFolderRecord? {
        guard let state = rootStatesByID[rootID] else { return nil }
        let key = StandardizedPath.relative(relativePath)
        guard let folderID = state.folderIDsByRelativePath[key] else { return nil }
        return foldersByID[folderID]
    }

    func cachedSearchContentSnapshot(
        for expectedRecord: WorkspaceFileRecord
    ) async -> FileSearchContentSnapshot {
        guard let current = file(
            rootID: expectedRecord.rootID,
            relativePath: expectedRecord.standardizedRelativePath
        ), current.id == expectedRecord.id else {
            return staleSearchContentSnapshot(for: expectedRecord)
        }
        let epoch = searchContentInvalidationEpochsByFileID[current.id] ?? 0
        let cacheKey = WorkspaceSearchContentCacheKey(
            rootID: current.rootID,
            fileID: current.id,
            standardizedRelativePath: current.standardizedRelativePath
        )
        guard let cached = await searchDecodedContentCache.cachedSnapshot(
            for: cacheKey,
            invalidationEpoch: epoch
        ), searchContentRecordIsCurrent(current, invalidationEpoch: epoch) else {
            return staleSearchContentSnapshot(for: current)
        }
        return FileSearchContentSnapshot(
            content: cached.content,
            contentRevision: cached.revision,
            modificationDate: cached.modificationDate,
            isFresh: true
        )
    }

    func searchContentSnapshot(
        for expectedRecord: WorkspaceFileRecord,
        freshnessPolicy: FileContentFreshnessPolicy = .validateDiskMetadata
    ) async throws -> FileSearchContentSnapshot {
        for attempt in 0 ..< 2 {
            try Task.checkCancellation()
            guard let state = rootStatesByID[expectedRecord.rootID],
                  let current = file(rootID: expectedRecord.rootID, relativePath: expectedRecord.standardizedRelativePath),
                  current.id == expectedRecord.id
            else {
                return staleSearchContentSnapshot(for: expectedRecord)
            }

            let service = state.service
            let epoch = searchContentInvalidationEpochsByFileID[current.id] ?? 0
            let cacheKey = WorkspaceSearchContentCacheKey(
                rootID: current.rootID,
                fileID: current.id,
                standardizedRelativePath: current.standardizedRelativePath
            )
            if case .cachedMetadata = freshnessPolicy,
               let cached = await searchDecodedContentCache.cachedSnapshot(
                   for: cacheKey,
                   invalidationEpoch: epoch
               )
            {
                guard searchContentRecordIsCurrent(current, invalidationEpoch: epoch) else {
                    if attempt == 0 { continue }
                    return staleSearchContentSnapshot(for: current)
                }
                return FileSearchContentSnapshot(
                    content: cached.content,
                    contentRevision: cached.revision,
                    modificationDate: cached.modificationDate,
                    isFresh: true
                )
            }
            let fingerprint: FileContentFingerprint
            do {
                fingerprint = try await service.contentFingerprint(
                    ofRelativePath: current.standardizedRelativePath
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch FileSystemError.fileNotFound {
                pruneCatalogFileIfStillCurrent(current)
                return staleSearchContentSnapshot(for: current)
            } catch {
                return staleSearchContentSnapshot(for: current)
            }

            guard searchContentRecordIsCurrent(current, invalidationEpoch: epoch) else {
                if attempt == 0 { continue }
                return staleSearchContentSnapshot(for: current)
            }

            let schedulerOwnerID = searchContentSchedulerOwnerID
            do {
                let cached = try await searchDecodedContentCache.snapshot(
                    for: cacheKey,
                    fingerprint: fingerprint,
                    invalidationEpoch: epoch
                ) {
                    try await service.loadValidatedContent(
                        ofRelativePath: current.standardizedRelativePath,
                        expectedFingerprint: fingerprint,
                        workloadClass: .contentSearch,
                        schedulerOwnerID: schedulerOwnerID
                    )
                }
                guard let cached else {
                    if attempt == 0 { continue }
                    return staleSearchContentSnapshot(for: current)
                }
                guard searchContentRecordIsCurrent(current, invalidationEpoch: epoch) else {
                    if attempt == 0 { continue }
                    return staleSearchContentSnapshot(for: current)
                }
                return FileSearchContentSnapshot(
                    content: cached.content,
                    contentRevision: cached.revision,
                    modificationDate: cached.modificationDate,
                    isFresh: true
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ContentReadSchedulerError {
                throw error
            } catch FileContentValidationError.fingerprintChanged {
                if attempt == 0 { continue }
                return staleSearchContentSnapshot(for: current)
            } catch FileSystemError.fileNotFound {
                pruneCatalogFileIfStillCurrent(current)
                return staleSearchContentSnapshot(for: current)
            } catch {
                return staleSearchContentSnapshot(for: current)
            }
        }
        return staleSearchContentSnapshot(for: expectedRecord)
    }

    func interactiveReadSnapshot(
        for expectedRecord: WorkspaceFileRecord
    ) async throws -> WorkspaceInteractiveReadSnapshot? {
        for attempt in 0 ..< 2 {
            try Task.checkCancellation()
            guard let state = rootStatesByID[expectedRecord.rootID],
                  let current = file(
                      rootID: expectedRecord.rootID,
                      relativePath: expectedRecord.standardizedRelativePath
                  ),
                  current.id == expectedRecord.id
            else {
                return nil
            }

            let service = state.service
            let epoch = searchContentInvalidationEpochsByFileID[current.id] ?? 0
            let cacheKey = WorkspaceInteractiveReadCacheKey(
                rootID: current.rootID,
                rootLifetimeID: state.lifetimeID,
                fileID: current.id,
                standardizedRelativePath: current.standardizedRelativePath
            )
            let fingerprint: FileContentFingerprint
            do {
                fingerprint = try await service.contentFingerprint(
                    ofRelativePath: current.standardizedRelativePath
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch FileSystemError.fileNotFound {
                pruneCatalogFileIfStillCurrent(current)
                return nil
            } catch {
                return nil
            }

            guard searchContentRecordIsCurrent(current, invalidationEpoch: epoch) else {
                if attempt == 0 { continue }
                return nil
            }

            let schedulerOwnerID = interactiveReadSchedulerOwnerID
            do {
                let cached = try await interactiveReadCache.snapshot(
                    for: cacheKey,
                    fingerprint: fingerprint,
                    invalidationEpoch: epoch
                ) {
                    let loaded = try await service.loadValidatedContent(
                        ofRelativePath: current.standardizedRelativePath,
                        expectedFingerprint: fingerprint,
                        workloadClass: .interactiveRead,
                        schedulerOwnerID: schedulerOwnerID
                    )
                    guard let content = loaded.content else { return nil }
                    return await WorkspaceInteractiveReadProcessor.prepareOffActor(content)
                }
                guard let preparedContent = cached.preparedContent else {
                    if attempt == 0 { continue }
                    return nil
                }
                guard searchContentRecordIsCurrent(current, invalidationEpoch: epoch) else {
                    if attempt == 0 { continue }
                    return nil
                }
                return WorkspaceInteractiveReadSnapshot(
                    preparedContent: preparedContent,
                    cacheHit: cached.cacheHit
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ContentReadSchedulerError {
                throw error
            } catch FileContentValidationError.fingerprintChanged {
                if attempt == 0 { continue }
                return nil
            } catch FileSystemError.fileNotFound {
                pruneCatalogFileIfStillCurrent(current)
                return nil
            } catch {
                return nil
            }
        }
        return nil
    }

    func clearSearchDecodedContentCache() async {
        await searchDecodedContentCache.clear()
        await interactiveReadCache.clear()
    }

    func readContentPrefix(
        rootID: UUID,
        relativePath: String,
        maximumBytes: Int,
        workloadClass: ContentReadWorkloadClass = .unspecified
    ) async throws -> FileContentPrefix? {
        let state = try state(for: rootID)
        return try await state.service.loadContentPrefix(
            ofRelativePath: StandardizedPath.relative(relativePath),
            maximumBytes: maximumBytes,
            workloadClass: workloadClass
        )
    }

    func readContent(
        rootID: UUID,
        relativePath: String,
        workloadClass: ContentReadWorkloadClass = .unspecified
    ) async throws -> String? {
        let state = try state(for: rootID)
        let lifecycleCorrelation = EditFlowPerf.currentLifecycleCorrelation
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.ReadFile.storeReadContentEntered,
            correlation: lifecycleCorrelation,
            EditFlowPerf.Dimensions(
                workloadClass: workloadClass.rawValue,
                rootToken: state.service.diagnosticRootToken.uuidString
            )
        )
        let forwardState = EditFlowPerf.begin(
            EditFlowPerf.Stage.ReadFile.storeReadContentForwardAwait,
            EditFlowPerf.Dimensions(workloadClass: workloadClass.rawValue)
        )
        do {
            let content = try await state.service.loadContent(
                ofRelativePath: StandardizedPath.relative(relativePath),
                workloadClass: workloadClass
            )
            EditFlowPerf.end(
                EditFlowPerf.Stage.ReadFile.storeReadContentForwardAwait,
                forwardState,
                EditFlowPerf.Dimensions(outcome: "returned", workloadClass: workloadClass.rawValue)
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.storeReadContentReturned,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(
                    outcome: "returned",
                    workloadClass: workloadClass.rawValue,
                    rootToken: state.service.diagnosticRootToken.uuidString
                )
            )
            return content
        } catch {
            EditFlowPerf.end(
                EditFlowPerf.Stage.ReadFile.storeReadContentForwardAwait,
                forwardState,
                EditFlowPerf.Dimensions(outcome: error is CancellationError ? "cancelled" : "error", workloadClass: workloadClass.rawValue)
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.storeReadContentReturned,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(
                    outcome: error is CancellationError ? "cancelled" : "error",
                    workloadClass: workloadClass.rawValue,
                    rootToken: state.service.diagnosticRootToken.uuidString
                )
            )
            throw error
        }
    }

    func readContentWithDate(
        rootID: UUID,
        relativePath: String,
        workloadClass: ContentReadWorkloadClass = .unspecified
    ) async throws -> (content: String?, modificationDate: Date) {
        let state = try state(for: rootID)
        let lifecycleCorrelation = EditFlowPerf.currentLifecycleCorrelation
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.ReadFile.storeReadContentEntered,
            correlation: lifecycleCorrelation,
            EditFlowPerf.Dimensions(
                workloadClass: workloadClass.rawValue,
                rootToken: state.service.diagnosticRootToken.uuidString
            )
        )
        let forwardState = EditFlowPerf.begin(
            EditFlowPerf.Stage.ReadFile.storeReadContentForwardAwait,
            EditFlowPerf.Dimensions(workloadClass: workloadClass.rawValue)
        )
        do {
            let loaded = try await state.service.loadContentWithDate(
                ofRelativePath: StandardizedPath.relative(relativePath),
                workloadClass: workloadClass
            )
            EditFlowPerf.end(
                EditFlowPerf.Stage.ReadFile.storeReadContentForwardAwait,
                forwardState,
                EditFlowPerf.Dimensions(outcome: "returned", workloadClass: workloadClass.rawValue)
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.storeReadContentReturned,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(
                    outcome: "returned",
                    workloadClass: workloadClass.rawValue,
                    rootToken: state.service.diagnosticRootToken.uuidString
                )
            )
            return loaded
        } catch {
            EditFlowPerf.end(
                EditFlowPerf.Stage.ReadFile.storeReadContentForwardAwait,
                forwardState,
                EditFlowPerf.Dimensions(outcome: error is CancellationError ? "cancelled" : "error", workloadClass: workloadClass.rawValue)
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.storeReadContentReturned,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(
                    outcome: error is CancellationError ? "cancelled" : "error",
                    workloadClass: workloadClass.rawValue,
                    rootToken: state.service.diagnosticRootToken.uuidString
                )
            )
            throw error
        }
    }

    func fileExistsOnDisk(rootID: UUID, relativePath: String) async throws -> Bool {
        let state = try state(for: rootID)
        return await state.service.fileExistsOnDisk(relativePath: StandardizedPath.relative(relativePath))
    }

    func fileModificationDate(rootID: UUID, relativePath: String) async throws -> Date {
        let state = try state(for: rootID)
        return try await state.service.getFileModificationDate(atRelativePath: StandardizedPath.relative(relativePath))
    }

    func itemModificationDateIfAvailable(rootID: UUID, relativePath: String) async throws -> Date? {
        let state = try state(for: rootID)
        return await state.service.getItemModificationDateIfAvailable(atRelativePath: StandardizedPath.relative(relativePath))
    }

    func refreshIgnoreRules(rootID: UUID) async throws {
        let state = try state(for: rootID)
        try await state.service.refreshIgnoreRules()
    }

    func fullPath(rootID: UUID, relativePath: String) async -> String? {
        guard let state = rootStatesByID[rootID] else { return nil }
        return await state.service.fullPath(forRelativePath: StandardizedPath.relative(relativePath))
    }

    func requestCodemapScan(fileID: UUID) async throws {
        guard let file = filesByID[fileID] else { return }
        try await requestCodemapScans(for: [file])
    }

    func requestCodemapScan(rootID: UUID, relativePath: String) async throws {
        guard let file = file(rootID: rootID, relativePath: relativePath) else { return }
        try await requestCodemapScans(for: [file])
    }

    func requestCodemapScans(inRoot rootID: UUID) async throws {
        try await requestCodemapScans(for: files(inRoot: rootID))
    }

    func requestCodemapScansForAllRoots() async throws {
        try await requestCodemapScans(for: rootLoadOrder.flatMap { files(inRoot: $0) })
    }

    @discardableResult
    func initializeCodemapsForSessionWorktreeRoots(rootIDs: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        let pendingRootIDs = rootIDs.filter { rootID in
            guard seen.insert(rootID).inserted,
                  let root = rootStatesByID[rootID]?.root,
                  root.kind == .sessionWorktree,
                  !files(inRoot: rootID).isEmpty,
                  !initializingSessionWorktreeCodemapRootIDs.contains(rootID),
                  !initializedSessionWorktreeCodemapRootIDs.contains(rootID)
            else { return false }
            return true
        }
        guard !pendingRootIDs.isEmpty else { return [] }

        initializingSessionWorktreeCodemapRootIDs.formUnion(pendingRootIDs)
        Task.detached(priority: .utility) { [store = self, pendingRootIDs] in
            do {
                let submittedRootIDs = try await store.requestInitialRootCodemapScans(rootIDs: pendingRootIDs)
                await store.completeSessionWorktreeCodemapInitialization(
                    requestedRootIDs: pendingRootIDs,
                    submittedRootIDs: submittedRootIDs
                )
            } catch {
                await store.clearSessionWorktreeCodemapInitialization(rootIDs: pendingRootIDs)
            }
        }
        return pendingRootIDs
    }

    func enqueueMissingCodemapSnapshotRepairs(
        for files: [WorkspaceFileRecord]
    ) -> WorkspaceCodemapRepairResult {
        let snapshots = codemapSnapshotDictionary()
        var missingFiles: [WorkspaceFileRecord] = []
        var seenFileIDs = Set<UUID>()

        for file in files {
            guard seenFileIDs.insert(file.id).inserted,
                  isDiscoverableFileID(file.id),
                  filesByID[file.id] != nil,
                  snapshots[file.id] == nil
            else { continue }
            missingFiles.append(file)
        }

        var newlyQueuedFiles: [WorkspaceFileRecord] = []
        for file in missingFiles where pendingCodemapRepairFileIDs.insert(file.id).inserted {
            newlyQueuedFiles.append(file)
        }

        if !newlyQueuedFiles.isEmpty {
            Task.detached(priority: .utility) { [store = self, newlyQueuedFiles] in
                await store.performEnqueuedCodemapSnapshotRepairs(for: newlyQueuedFiles)
            }
        }

        return WorkspaceCodemapRepairResult(
            snapshotsByFileID: snapshots,
            pendingFileIDs: Set(missingFiles.map(\.id))
        )
    }

    private func performEnqueuedCodemapSnapshotRepairs(
        for files: [WorkspaceFileRecord]
    ) async {
        await ensureCodeScanResultTask()
        let currentFiles = files.filter { file in
            pendingCodemapRepairFileIDs.contains(file.id)
                && isDiscoverableFileID(file.id)
                && filesByID[file.id] != nil
                && codemapSnapshotsByFileID[file.id] == nil
        }
        let currentFileIDs = Set(currentFiles.map(\.id))
        guard !currentFiles.isEmpty else {
            pendingCodemapRepairFileIDs.subtract(files.map(\.id))
            return
        }

        do {
            let loadedRequests = try await codemapScanRequests(for: currentFiles)
            let stillMissingFileIDs = currentFileIDs.filter { codemapSnapshotsByFileID[$0] == nil }
            let requests = loadedRequests.filter { stillMissingFileIDs.contains($0.fileID) }
            guard !requests.isEmpty else {
                pendingCodemapRepairFileIDs.subtract(currentFileIDs)
                return
            }
            let rootFolderPaths = Array(Set(requests.map(\.rootFolderPath)))
            let requestResult = await codeScanActor.requestSelfHealingScans(
                requests,
                rootFolderPaths: rootFolderPaths,
                existingScanModificationDatesByFileID: Dictionary(
                    uniqueKeysWithValues: currentFiles.compactMap { file in
                        file.modificationDate.map { (file.id, $0) }
                    }
                )
            )
            let scheduledFileIDs = requestResult.submittedFileIDs.union(requestResult.alreadyScheduledFileIDs)
            pendingCodemapRepairFileIDs.subtract(currentFileIDs.subtracting(scheduledFileIDs))
            pendingCodemapRepairFileIDs.subtract(
                scheduledFileIDs.filter { codemapSnapshotsByFileID[$0] != nil }
            )
        } catch {
            pendingCodemapRepairFileIDs.subtract(currentFileIDs)
        }
    }

    func repairMissingCodemapSnapshots(
        for files: [WorkspaceFileRecord],
        timeout: Duration = .seconds(5),
        pollInterval: Duration = .milliseconds(25)
    ) async throws -> WorkspaceCodemapRepairResult {
        try Task.checkCancellation()
        await ensureCodeScanResultTask()

        var seenFileIDs = Set<UUID>()
        let missingFiles = files.filter { file in
            guard seenFileIDs.insert(file.id).inserted,
                  isDiscoverableFileID(file.id),
                  filesByID[file.id] != nil,
                  codemapSnapshotsByFileID[file.id] == nil
            else { return false }
            return true
        }
        guard !missingFiles.isEmpty else {
            return WorkspaceCodemapRepairResult(
                snapshotsByFileID: codemapSnapshotDictionary(),
                pendingFileIDs: []
            )
        }

        let requests = try await codemapScanRequests(for: missingFiles)
        let submittedFileIDs: Set<UUID>
        let alreadyScheduledFileIDs: Set<UUID>
        if requests.isEmpty {
            submittedFileIDs = []
            alreadyScheduledFileIDs = []
        } else {
            let rootFolderPaths = Array(Set(requests.map(\.rootFolderPath)))
            let requestResult = await codeScanActor.requestSelfHealingScans(
                requests,
                rootFolderPaths: rootFolderPaths
            )
            submittedFileIDs = requestResult.submittedFileIDs
            alreadyScheduledFileIDs = requestResult.alreadyScheduledFileIDs
        }

        if !submittedFileIDs.isEmpty, timeout > .zero {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while submittedFileIDs.contains(where: { codemapSnapshotsByFileID[$0] == nil }),
                  clock.now < deadline
            {
                try Task.checkCancellation()
                try await Task.sleep(for: pollInterval)
            }
        }

        try Task.checkCancellation()
        let snapshots = codemapSnapshotDictionary()
        return WorkspaceCodemapRepairResult(
            snapshotsByFileID: snapshots,
            pendingFileIDs: submittedFileIDs
                .union(alreadyScheduledFileIDs)
                .filter { snapshots[$0] == nil }
        )
    }

    func requestInitialRootCodemapScans(
        rootFolderPaths: [String],
        purgeCachesOnEmptyInitialRequests: Bool = false
    ) async throws {
        await ensureCodeScanResultTask()
        #if DEBUG
            let collectFilesStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
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
            WorkspaceRestorePerfLog.event(
                "store.initialCodemapScan.collectFiles",
                fields: [
                    "source": "paths",
                    "rootCount": "\(standardizedRootPaths.count)",
                    "supportedFiles": "\(filesToScan.count)",
                    "duration": collectFilesStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
            let buildRequestsStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        let requests = try await codemapScanRequests(for: filesToScan)
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "store.initialCodemapScan.buildRequests",
                fields: [
                    "source": "paths",
                    "supportedFiles": "\(filesToScan.count)",
                    "requests": "\(requests.count)",
                    "duration": buildRequestsStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
            let submitStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        await codeScanActor.requestScans(
            requests,
            purpose: .initialRootLoad,
            rootFolderPaths: standardizedRootPaths,
            purgeCachesOnEmptyInitialRequests: purgeCachesOnEmptyInitialRequests
        )
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "store.initialCodemapScan.submit",
                fields: [
                    "source": "paths",
                    "requests": "\(requests.count)",
                    "rootCount": "\(standardizedRootPaths.count)",
                    "duration": submitStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
    }

    @discardableResult
    func requestInitialRootCodemapScans(
        rootIDs: [UUID],
        purgeCachesOnEmptyInitialRequests: Bool = false
    ) async throws -> [UUID] {
        await ensureCodeScanResultTask()
        #if DEBUG
            let collectFilesStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
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
            WorkspaceRestorePerfLog.event(
                "store.initialCodemapScan.collectFiles",
                fields: [
                    "source": "rootIDs",
                    "rootCount": "\(orderedRootIDs.count)",
                    "supportedFiles": "\(filesToScan.count)",
                    "duration": collectFilesStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
        guard !orderedRootIDs.isEmpty else { return [] }
        #if DEBUG
            let buildRequestsStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        let requests = try await codemapScanRequests(for: filesToScan)
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "store.initialCodemapScan.buildRequests",
                fields: [
                    "source": "rootIDs",
                    "supportedFiles": "\(filesToScan.count)",
                    "requests": "\(requests.count)",
                    "duration": buildRequestsStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
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
        guard !currentRootFolderPaths.isEmpty else { return [] }
        let currentRequests = requests.filter { request in
            guard let file = filesByID[request.fileID] else { return false }
            return currentRootIDs.contains(file.rootID)
        }
        #if DEBUG
            let submitStartMS = WorkspaceRestorePerfLog.timestampMSIfEnabled()
        #endif
        let submittedFileIDs = await codeScanActor.requestScans(
            currentRequests,
            purpose: .initialRootLoad,
            rootFolderPaths: currentRootFolderPaths,
            purgeCachesOnEmptyInitialRequests: purgeCachesOnEmptyInitialRequests
        )
        #if DEBUG
            WorkspaceRestorePerfLog.event(
                "store.initialCodemapScan.submit",
                fields: [
                    "source": "rootIDs",
                    "requests": "\(currentRequests.count)",
                    "rootCount": "\(currentRootFolderPaths.count)",
                    "duration": submitStartMS.map { WorkspaceRestorePerfLog.formatElapsedMS(since: $0) } ?? "notMeasured"
                ]
            )
        #endif
        let submittedRootIDs = Set(currentRequests.compactMap { request -> UUID? in
            guard submittedFileIDs.contains(request.fileID) else { return nil }
            return filesByID[request.fileID]?.rootID
        })
        return orderedRootIDs.filter { submittedRootIDs.contains($0) }
    }

    func requestCodemapScans(for files: [WorkspaceFileRecord]) async throws {
        await ensureCodeScanResultTask()
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
    func createFile(rootID: UUID, relativePath: String, content: String) async throws -> WorkspaceFileCatalogMaterializationResult {
        let state = try state(for: rootID)
        let standardizedRelativePath = StandardizedPath.relative(relativePath)
        try await state.service.createFile(atRelativePath: standardizedRelativePath, content: content)
        return try await materializeCatalogFileAfterDiskWrite(rootID: rootID, relativePath: standardizedRelativePath)
    }

    @discardableResult
    func editFile(rootID: UUID, relativePath: String, newContent: String) async throws -> WorkspaceFileCatalogMaterializationResult? {
        let state = try state(for: rootID)
        let standardizedRelativePath = StandardizedPath.relative(relativePath)
        do {
            try await state.service.editFile(atRelativePath: standardizedRelativePath, newContent: newContent)
        } catch FileSystemError.fileNotFound {
            pruneCatalogFileMissingOnDisk(rootID: rootID, relativePath: standardizedRelativePath, publishDelta: true)
            throw FileSystemError.fileNotFound
        }
        if let file = file(rootID: rootID, relativePath: standardizedRelativePath) {
            invalidateSearchContent(file)
            invalidateCodemapSnapshot(rootID: rootID, relativePath: standardizedRelativePath)
            if isDiscoverableFileID(file.id) {
                publishAppliedIndexEvent(root: state.root, modifiedFileIDs: [file.id])
            }
            return .materialized(file)
        }
        return try await materializeCatalogFileAfterDiskWrite(rootID: rootID, relativePath: standardizedRelativePath)
    }

    func moveFile(rootID: UUID, from oldRelativePath: String, to newRelativePath: String) async throws {
        let state = try state(for: rootID)
        let oldPath = StandardizedPath.relative(oldRelativePath)
        let newPath = StandardizedPath.relative(newRelativePath)
        let oldFile = file(rootID: rootID, relativePath: oldPath)
        let oldFileWasDiscoverable = oldFile.map { isDiscoverableFileID($0.id) } ?? false
        try await state.service.moveFile(
            atRelativePath: oldPath,
            toRelativePath: newPath
        )
        let destinationEligibility = await state.service.registerExplicitlyManagedRegularFile(relativePath: newPath)
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

    func deleteFile(rootID: UUID, relativePath: String) async throws {
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

    func moveItemToTrash(rootID: UUID, relativePath: String) async throws {
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

    func validateCatalogFileStillPresent(_ file: WorkspaceFileRecord) async -> WorkspaceFileRecord? {
        let lifecycleCorrelation = EditFlowPerf.currentLifecycleCorrelation
        EditFlowPerf.lifecycleEvent(
            EditFlowPerf.Lifecycle.Search.contentFreshnessStoreEntered,
            correlation: lifecycleCorrelation
        )
        let validationState = EditFlowPerf.begin(EditFlowPerf.Stage.Search.contentFreshnessValidationStoreActorBody)
        var outcome = "missing"
        defer {
            EditFlowPerf.end(
                EditFlowPerf.Stage.Search.contentFreshnessValidationStoreActorBody,
                validationState,
                EditFlowPerf.Dimensions(outcome: outcome)
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.Search.contentFreshnessStoreReturned,
                correlation: lifecycleCorrelation,
                EditFlowPerf.Dimensions(outcome: outcome)
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
    func pruneMissingCatalogFilesForExactMutationLookup(
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
    func lookupCatalogFileForExplicitRequest(
        _ userPath: String,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) -> WorkspaceExplicitCatalogFileLookupResult {
        lookupCatalogFileForExplicitRequest(
            userPath,
            rootRefs: rootRefs(scope: rootScope)
        )
    }

    func lookupCatalogFileForExplicitRequest(
        _ userPath: String,
        rootRefs roots: [WorkspaceRootRef]
    ) -> WorkspaceExplicitCatalogFileLookupResult {
        #if DEBUG || EDIT_FLOW_PERF
            var exactCatalogLookupOutcome = "noCandidate"
            var exactCatalogLookupRoute = "empty"
            let exactCatalogLookupActorBody = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.exactCatalogLookupActorBody)
            defer {
                let dimensions = EditFlowPerf.Dimensions(status: exactCatalogLookupRoute, outcome: exactCatalogLookupOutcome)
                EditFlowPerf.end(
                    EditFlowPerf.Stage.ReadFile.exactCatalogLookupActorBody,
                    exactCatalogLookupActorBody,
                    dimensions
                )
                EditFlowPerf.lifecycleEvent(
                    EditFlowPerf.Lifecycle.ReadFile.exactCatalogLookupResolved,
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
    func materializeExplicitlyRequestedFile(
        _ userPath: String,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) async throws -> WorkspaceExplicitFileMaterializationResult {
        try await materializeExplicitlyRequestedFile(
            userPath,
            rootRefs: rootRefs(scope: rootScope)
        )
    }

    func materializeExplicitlyRequestedFile(
        _ userPath: String,
        rootRefs roots: [WorkspaceRootRef]
    ) async throws -> WorkspaceExplicitFileMaterializationResult {
        let trimmed = userPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .noCandidate }
        guard !StandardizedPath.containsNUL(trimmed) else { return .blocked }
        guard (trimmed as NSString).expandingTildeInPath.hasPrefix("/") else { return .noCandidate }

        let candidates: [(rootID: UUID, relativePath: String)]
        switch explicitDiskLookupCandidates(for: trimmed, rootRefs: roots) {
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
        return try .materialized(materializeCatalogRegularFile(
            rootID: candidate.rootID,
            relativePath: candidate.relativePath,
            managedOnly: managedOnly
        ))
    }

    @discardableResult
    func materializeCatalogFileAfterDiskWrite(
        rootID: UUID,
        relativePath: String
    ) async throws -> WorkspaceFileCatalogMaterializationResult {
        let state = try state(for: rootID)
        let standardizedRelativePath = StandardizedPath.relative(relativePath)
        let eligibility = await state.service.registerExplicitlyManagedRegularFile(relativePath: standardizedRelativePath)
        switch eligibility {
        case .ineligible(.ignored):
            // A direct app/MCP write is an explicit request to manage this exact file.
            // Keep it available for follow-up read_file/apply_edits calls without making
            // ignored siblings discoverable through scans or replay.
            return try .materialized(materializeCatalogRegularFile(rootID: rootID, relativePath: standardizedRelativePath, managedOnly: true))
        case let .ineligible(reason):
            guard isExpectedDiskWriteCatalogIneligibility(reason) else {
                throw WorkspaceFileContextStoreError.catalogMaterializationFailed(
                    "file was written but is not catalog-eligible after the write: \(reason.description)"
                )
            }
            return .ineligible(reason)
        case .eligible:
            return try .materialized(materializeCatalogRegularFile(rootID: rootID, relativePath: standardizedRelativePath, managedOnly: false))
        }
    }

    private func explicitDiskLookupCandidates(
        for userPath: String,
        rootRefs roots: [WorkspaceRootRef]
    ) -> ExplicitDiskLookupCandidatesResult {
        let expanded = (userPath as NSString).expandingTildeInPath
        let standardized = StandardizedPath.absolute(expanded)
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
    ) throws -> WorkspaceFileRecord {
        let state = try state(for: rootID)
        let standardizedRelativePath = StandardizedPath.relative(relativePath)
        if let existing = file(rootID: rootID, relativePath: standardizedRelativePath) {
            let wasManagedOnly = managedOnlyFileIDs.contains(existing.id)
            if !managedOnly {
                promoteToDiscoverable(existing)
                if wasManagedOnly {
                    invalidatePathMatchSnapshot(
                        affectedRootKinds: [state.root.kind],
                        reason: .managedFilePromotion,
                        affectedRootIDs: [state.root.id]
                    )
                    publishAppliedIndexEvent(
                        root: state.root,
                        upsertedFiles: [existing],
                        upsertedFolders: discoverableParentFolders(for: standardizedRelativePath, rootID: rootID)
                    )
                }
            }
            return existing
        }

        guard regularFileAppearsPresentOnDisk(root: state.root, relativePath: standardizedRelativePath) else {
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

    private func regularFileAppearsPresentOnDisk(root: WorkspaceRootRecord, relativePath: String) -> Bool {
        let fullPath = StandardizedPath.join(standardizedRoot: root.standardizedFullPath, standardizedRelativePath: StandardizedPath.relative(relativePath))
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory), !isDirectory.boolValue else { return false }
        if let values = try? URL(fileURLWithPath: fullPath).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            if values.isSymbolicLink == true { return false }
            if values.isRegularFile == false { return false }
        }
        return true
    }

    private func directoryAppearsPresentOnDisk(root: WorkspaceRootRecord, relativePath: String) -> Bool {
        let fullPath = StandardizedPath.join(standardizedRoot: root.standardizedFullPath, standardizedRelativePath: StandardizedPath.relative(relativePath))
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        if let values = try? URL(fileURLWithPath: fullPath).resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            if values.isSymbolicLink == true { return false }
            if values.isDirectory == false { return false }
        }
        return true
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

    #if DEBUG
        private func applyPreparedIndexDeltas(
            rootID: UUID,
            deltas: [PreparedFileSystemDelta],
            expectedLifetimeID: UUID? = nil,
            watcherAcceptedWatermark: FileSystemWatcherIngressMailbox.Watermark?,
            servicePublicationSequence: UInt64?,
            requiresFullResync: Bool = false
        ) async {
            guard let servicePublicationSequence else {
                await applyPreparedIndexDeltasBody(
                    rootID: rootID,
                    deltas: deltas,
                    expectedLifetimeID: expectedLifetimeID,
                    requiresFullResync: requiresFullResync
                )
                return
            }
            let recorder = await applyPreparedIndexDeltasRecordingInvalidations(
                rootID: rootID,
                deltas: deltas,
                expectedLifetimeID: expectedLifetimeID,
                requiresFullResync: requiresFullResync
            )
            guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: expectedLifetimeID) else { return }
            recordPublicationInvalidationDiagnostics(
                rootID: rootID,
                servicePublicationSequence: servicePublicationSequence,
                watcherAcceptedWatermark: watcherAcceptedWatermark,
                recorder: recorder
            )
        }

        private func applyPreparedIndexDeltasRecordingInvalidations(
            rootID: UUID,
            deltas: [PreparedFileSystemDelta],
            expectedLifetimeID: UUID? = nil,
            requiresFullResync: Bool = false
        ) async -> PublicationInvalidationRecorder {
            let recorder = PublicationInvalidationRecorder(preparedDeltaCount: deltas.count)
            await Self.$activePublicationInvalidationRecorder.withValue(recorder) {
                await applyPreparedIndexDeltasBody(
                    rootID: rootID,
                    deltas: deltas,
                    expectedLifetimeID: expectedLifetimeID,
                    requiresFullResync: requiresFullResync
                )
            }
            return recorder
        }
    #else
        private func applyPreparedIndexDeltas(
            rootID: UUID,
            deltas: [PreparedFileSystemDelta],
            expectedLifetimeID: UUID? = nil,
            requiresFullResync: Bool = false
        ) async {
            await applyPreparedIndexDeltasBody(
                rootID: rootID,
                deltas: deltas,
                expectedLifetimeID: expectedLifetimeID,
                requiresFullResync: requiresFullResync
            )
        }
    #endif

    private func applyPreparedIndexDeltasBody(
        rootID: UUID,
        deltas: [PreparedFileSystemDelta],
        expectedLifetimeID: UUID? = nil,
        requiresFullResync: Bool = false
    ) async {
        let applicableDeltas = await preflightPreparedIndexDeltas(
            rootID: rootID,
            deltas: deltas,
            expectedLifetimeID: expectedLifetimeID
        )
        guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: expectedLifetimeID) else { return }
        applyPreparedIndexDeltaMutations(
            rootID: rootID,
            deltas: applicableDeltas,
            requiresFullResync: requiresFullResync
        )
    }

    private func preflightPreparedIndexDeltas(
        rootID: UUID,
        deltas: [PreparedFileSystemDelta],
        expectedLifetimeID: UUID? = nil
    ) async -> [PreparedFileSystemDelta] {
        var applicableDeltas: [PreparedFileSystemDelta] = []
        applicableDeltas.reserveCapacity(deltas.count)
        for prepared in deltas {
            switch prepared.delta {
            case .fileAdded:
                guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: expectedLifetimeID),
                      let service = rootStatesByID[rootID]?.service,
                      await service.catalogEligibleRegularFileExists(relativePath: prepared.relativePath),
                      isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: expectedLifetimeID)
                else { continue }
                applicableDeltas.append(prepared)
            case .folderAdded:
                guard isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: expectedLifetimeID),
                      let service = rootStatesByID[rootID]?.service,
                      await service.catalogFolderIsDiscoverable(relativePath: prepared.relativePath),
                      isRootLifetimeCurrent(rootID: rootID, expectedLifetimeID: expectedLifetimeID)
                else { continue }
                applicableDeltas.append(prepared)
            case .fileRemoved, .folderRemoved, .fileModified, .folderModified:
                applicableDeltas.append(prepared)
            }
        }
        return applicableDeltas
    }

    private func applyPreparedIndexDeltaMutations(
        rootID: UUID,
        deltas: [PreparedFileSystemDelta],
        requiresFullResync: Bool = false
    ) {
        guard let root = rootStatesByID[rootID]?.root else { return }
        precondition(activePublicationInvalidationBatch == nil)
        let invalidationBatch = PublicationInvalidationBatch()
        activePublicationInvalidationBatch = invalidationBatch
        defer { activePublicationInvalidationBatch = nil }

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
                guard regularFileAppearsPresentOnDisk(root: root, relativePath: relativePath) else { continue }
                let existingFile = file(rootID: rootID, relativePath: relativePath)
                let existed = existingFile != nil
                if let existingFile {
                    invalidateSearchContent(existingFile)
                }
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
                guard directoryAppearsPresentOnDisk(root: root, relativePath: relativePath) else { continue }
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
                    invalidateSearchContent(file)
                    invalidateCodemapSnapshot(rootID: rootID, relativePath: relativePath)
                    if isDiscoverableFileID(file.id) { modifiedFileIDs.append(file.id) }
                }
            case .folderModified:
                if let folder = folder(rootID: rootID, relativePath: relativePath), isDiscoverableFolderID(folder.id) {
                    modifiedFolderIDs.append(folder.id)
                }
            }
        }

        finalizePublicationInvalidations(invalidationBatch)
        publishAppliedIndexEvent(
            root: root,
            upsertedFiles: upsertedFiles,
            upsertedFolders: upsertedFolders,
            removedFileIDs: removedFileIDs,
            removedFolderIDs: removedFolderIDs,
            removedFilePaths: removedFilePaths,
            removedFolderPaths: removedFolderPaths,
            modifiedFileIDs: modifiedFileIDs,
            modifiedFolderIDs: modifiedFolderIDs,
            requiresFullResync: requiresFullResync
        )
    }

    func lookupPath(
        _ userPath: String,
        profile: PathLocateProfile = .uiAssisted,
        rootScope: WorkspaceLookupRootScope = .allLoaded
    ) async -> WorkspacePathLookupResult? {
        let request = WorkspacePathLookupRequest(userPath: userPath, profile: profile, rootScope: rootScope)
        return await lookupPath(request)
    }

    func lookupPath(_ request: WorkspacePathLookupRequest) async -> WorkspacePathLookupResult? {
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

    func lookupPath(
        _ request: WorkspacePathLookupRequest,
        rootRefs: [WorkspaceRootRef]
    ) async -> WorkspacePathLookupResult? {
        let normalizedPath = normalizeUserInputPath(request.userPath)
        guard !normalizedPath.isEmpty else { return nil }

        let selectedFileFullPaths = request.selectedFileFullPaths
        let staticData = buildStaticSnapshot(scope: request.rootScope, rootRefs: rootRefs)
        guard let match = await pathMatchWorker.locate(
            userPath: normalizedPath,
            profile: request.profile,
            staticData: staticData,
            selectedFileFullPaths: selectedFileFullPaths,
            selectionSig: selectionSignature(for: selectedFileFullPaths)
        ) else { return nil }
        return lookupResult(input: request.userPath, match: match)
    }

    func lookupPaths(_ requests: [WorkspacePathLookupRequest]) async -> [String: WorkspacePathLookupResult] {
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

    func findCreationPath(
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

    func resolveCreationPath(
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

    func lookupPath(rootID: UUID, relativePath: String) -> WorkspacePathLookupResult? {
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

    func lookupDiscoverablePath(rootID: UUID, relativePath: String) -> WorkspacePathLookupResult? {
        guard let result = lookupPath(rootID: rootID, relativePath: relativePath),
              isDiscoverableLookupResult(result)
        else { return nil }
        return result
    }

    func lookupDiscoverableCatalogPathForExactAbsoluteSearchScope(
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

    func rootRefs(scope: WorkspaceLookupRootScope = .allLoaded) -> [WorkspaceRootRef] {
        rootsForPathLookup(scope: scope).map {
            WorkspaceRootRef(id: $0.id, name: $0.name, fullPath: $0.standardizedFullPath)
        }
    }

    func displayRootRefsSnapshot() -> WorkspaceDisplayRootRefsSnapshot {
        WorkspaceDisplayRootRefsSnapshot(
            visibleRoots: rootRefs(scope: .visibleWorkspace),
            allRoots: rootRefs(scope: .allLoaded)
        )
    }

    func exactPathResolutionIssue(
        for userPath: String,
        kind: WorkspaceExactPathLookupKind,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace
    ) -> PathResolutionIssue? {
        exactPathResolutionIssue(
            for: userPath,
            kind: kind,
            rootRefs: rootRefs(scope: rootScope)
        )
    }

    func exactPathResolutionIssue(
        for userPath: String,
        kind: WorkspaceExactPathLookupKind,
        rootRefs roots: [WorkspaceRootRef]
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

    func lookupFiles(
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

    func resolveFolderInput(
        _ path: String,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        profile: PathLocateProfile = .mcpSelection
    ) async -> (folder: WorkspaceFolderRecord?, displayPath: String?, issue: PathResolutionIssue?) {
        await resolveFolderInput(
            path,
            rootScope: rootScope,
            profile: profile,
            rootRefs: rootRefs(scope: rootScope)
        )
    }

    func resolveFolderInput(
        _ path: String,
        rootScope: WorkspaceLookupRootScope,
        profile: PathLocateProfile,
        rootRefs roots: [WorkspaceRootRef],
        validateIssue: Bool = true,
        allowGeneralLookupFallback: Bool = true
    ) async -> (folder: WorkspaceFolderRecord?, displayPath: String?, issue: PathResolutionIssue?) {
        let cleaned = normalizeUserInputPath(path).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return (nil, nil, .emptyInput) }

        if validateIssue,
           let issue = exactPathResolutionIssue(for: cleaned, kind: .folder, rootRefs: roots)
        {
            return (nil, nil, issue)
        }

        if cleaned.hasPrefix("/") {
            if let folderID = folderIDsByStandardizedFullPath[StandardizedPath.absolute(cleaned)],
               isDiscoverableFolderID(folderID),
               let folder = foldersByID[folderID],
               let root = roots.first(where: { $0.id == folder.rootID })
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

        guard allowGeneralLookupFallback else { return (nil, nil, nil) }
        let generalLookupState = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.folderResolutionGeneralLookupFallback)
        let lookup = await lookupPath(
            WorkspacePathLookupRequest(userPath: cleaned, profile: profile, rootScope: rootScope),
            rootRefs: roots
        )
        EditFlowPerf.end(
            EditFlowPerf.Stage.ReadFile.folderResolutionGeneralLookupFallback,
            generalLookupState,
            EditFlowPerf.Dimensions(outcome: lookup?.folder == nil ? "noFolder" : "folder")
        )
        if let folder = lookup?.folder,
           let root = roots.first(where: { $0.id == folder.rootID })
        {
            return (folder, ClientPathFormatter.displayPath(root: root, relativePath: folder.standardizedRelativePath, visibleRoots: roots), nil)
        }
        return (nil, nil, nil)
    }

    func expandFolderInputToFiles(
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
        let cacheIdentity = pathMatchCacheIdentity(scope: scope)
        if var cached = staticPathMatchSnapshotsByScope[scope],
           cached.snapshot.cacheIdentity == cacheIdentity
        {
            cached.lastAccessSequence = nextStaticPathMatchSnapshotAccessSequenceValue()
            staticPathMatchSnapshotsByScope[scope] = cached
            return cached.snapshot
        }
        let snapshot = buildStaticSnapshot(
            rootRefs: rootRefs(scope: scope),
            cacheIdentity: cacheIdentity
        )
        cacheStaticPathMatchSnapshot(snapshot, scope: scope)
        return snapshot
    }

    private func buildStaticSnapshot(
        scope: WorkspaceLookupRootScope,
        rootRefs roots: [WorkspaceRootRef]
    ) -> StaticPathMatchData {
        buildStaticSnapshot(
            rootRefs: roots,
            cacheIdentity: pathMatchCacheIdentity(scope: scope, rootRefs: roots)
        )
    }

    private func buildStaticSnapshot(
        rootRefs roots: [WorkspaceRootRef],
        cacheIdentity: PathMatchCacheIdentity
    ) -> StaticPathMatchData {
        let snapshotState = EditFlowPerf.begin(EditFlowPerf.Stage.ReadFile.pathLookupStaticSnapshotBuild)
        defer { EditFlowPerf.end(EditFlowPerf.Stage.ReadFile.pathLookupStaticSnapshotBuild, snapshotState) }
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
            cacheScopeID: cacheIdentity.scopeID,
            id: cacheIdentity.snapshotID
        )
    }

    private func cacheStaticPathMatchSnapshot(
        _ snapshot: StaticPathMatchData,
        scope: WorkspaceLookupRootScope
    ) {
        if staticPathMatchSnapshotsByScope[scope] == nil,
           staticPathMatchSnapshotsByScope.count >= Self.maxCachedStaticPathMatchSnapshotScopes,
           let eviction = staticPathMatchSnapshotsByScope.min(by: {
               $0.value.lastAccessSequence < $1.value.lastAccessSequence
           })
        {
            staticPathMatchSnapshotsByScope.removeValue(forKey: eviction.key)
            if pathMatchSnapshotIdentitiesByScope[eviction.key] == eviction.value.snapshot.cacheIdentity {
                pathMatchSnapshotIdentitiesByScope.removeValue(forKey: eviction.key)
            }
            invalidatePathMatchCache(snapshotIdentities: [eviction.value.snapshot.cacheIdentity])
        }
        pathMatchSnapshotIdentitiesByScope[scope] = snapshot.cacheIdentity
        staticPathMatchSnapshotsByScope[scope] = StaticPathMatchSnapshotCacheEntry(
            snapshot: snapshot,
            lastAccessSequence: nextStaticPathMatchSnapshotAccessSequenceValue()
        )
    }

    private func nextStaticPathMatchSnapshotAccessSequenceValue() -> UInt64 {
        nextStaticPathMatchSnapshotAccessSequence &+= 1
        return nextStaticPathMatchSnapshotAccessSequence
    }

    private func pathMatchCacheIdentity(scope: WorkspaceLookupRootScope) -> PathMatchCacheIdentity {
        PathMatchCacheIdentity(
            scopeID: scopeDiscriminator(scope),
            snapshotID: scopedSnapshotGeneration(scope: scope)
        )
    }

    private func pathMatchCacheIdentity(
        scope: WorkspaceLookupRootScope,
        rootRefs roots: [WorkspaceRootRef]
    ) -> PathMatchCacheIdentity {
        var hasher = Hasher()
        hasher.combine("explicitRootRefs")
        hasher.combine(scopeDiscriminator(scope))
        for root in roots {
            hasher.combine(root.id)
            hasher.combine(root.standardizedFullPath)
            hasher.combine(rootStatesByID[root.id]?.lifetimeID)
            hasher.combine(catalogGenerationsByRootID[root.id] ?? 0)
        }
        return PathMatchCacheIdentity(
            scopeID: scopeDiscriminator(scope),
            snapshotID: UInt64(bitPattern: Int64(hasher.finalize()))
        )
    }

    #if DEBUG
        func staticPathMatchSnapshotCacheCountForTesting() -> Int {
            staticPathMatchSnapshotsByScope.count
        }

        func sessionCatalogGenerationForTesting(scope: WorkspaceLookupRootScope) -> UInt64? {
            sessionCatalogGenerationStatesByScope[scope]?.generation
        }
    #endif

    private func scopedSnapshotGeneration(scope: WorkspaceLookupRootScope) -> UInt64 {
        let validationToken = searchCatalogSnapshotValidationToken(scope: scope)
        switch validationToken {
        case let .staticScope(generation):
            return generation
        case .sessionBound:
            if let state = sessionCatalogGenerationStatesByScope[scope],
               state.validationToken == validationToken
            {
                return state.generation
            }
            nextSessionCatalogGeneration &+= 1
            let generation = nextSessionCatalogGeneration
            sessionCatalogGenerationStatesByScope[scope] = SessionCatalogGenerationState(
                validationToken: validationToken,
                generation: generation
            )
            return generation
        }
    }

    private func searchCatalogSnapshotValidationToken(
        scope: WorkspaceLookupRootScope
    ) -> SearchCatalogSnapshotValidationToken {
        switch scope {
        case .visibleWorkspace, .visibleWorkspacePlusGitData, .allLoaded:
            let generation = (catalogGenerationsByScope[scope] ?? 0) &* 3 &+ scopeDiscriminator(scope)
            return .staticScope(generation: generation)
        case let .sessionBoundWorkspace(logicalRootPaths, physicalRootPaths):
            let normalizedLogicalRootPaths = normalizedSessionSelectorPaths(logicalRootPaths).sorted()
            let normalizedPhysicalRootPaths = normalizedSessionSelectorPaths(physicalRootPaths).sorted()
            let dependencies = rootsForPathLookup(scope: scope).compactMap { root -> SearchCatalogRootDependency? in
                guard let state = rootStatesByID[root.id] else { return nil }
                return SearchCatalogRootDependency(
                    canonicalIdentity: root.standardizedFullPath,
                    rootID: root.id,
                    lifetimeID: state.lifetimeID,
                    generation: catalogGenerationsByRootID[root.id] ?? 0
                )
            }.sorted {
                if $0.canonicalIdentity == $1.canonicalIdentity {
                    return $0.rootID.uuidString < $1.rootID.uuidString
                }
                return $0.canonicalIdentity < $1.canonicalIdentity
            }
            return .sessionBound(
                logicalRootPaths: normalizedLogicalRootPaths,
                physicalRootPaths: normalizedPhysicalRootPaths,
                dependencies: dependencies
            )
        }
    }

    private func cacheSearchCatalogSnapshot(
        _ snapshot: WorkspaceSearchCatalogSnapshot,
        validationToken: SearchCatalogSnapshotValidationToken,
        scope: WorkspaceLookupRootScope
    ) {
        if searchCatalogSnapshotsByScope[scope] == nil,
           searchCatalogSnapshotsByScope.count >= Self.maxCachedSearchCatalogSnapshotScopes,
           let eviction = searchCatalogSnapshotsByScope.min(by: {
               $0.value.lastAccessSequence < $1.value.lastAccessSequence
           })
        {
            evictSearchCatalogSnapshots(
                scopes: [eviction.key],
                reasons: [.cacheCapacity],
                affectedRootIDs: Set(eviction.value.snapshot.roots.map(\.id)),
                affectedRootKinds: Set(eviction.value.snapshot.roots.map(\.kind))
            )
        }
        searchCatalogSnapshotsByScope[scope] = SearchCatalogSnapshotCacheEntry(
            validationToken: validationToken,
            snapshot: snapshot,
            lastAccessSequence: nextSearchCatalogAccessSequence()
        )
    }

    private func nextSearchCatalogAccessSequence() -> UInt64 {
        nextSearchCatalogSnapshotAccessSequence &+= 1
        return nextSearchCatalogSnapshotAccessSequence
    }

    private func scopeDiscriminator(_ scope: WorkspaceLookupRootScope) -> UInt64 {
        switch scope {
        case .visibleWorkspace:
            return 0
        case .visibleWorkspacePlusGitData:
            return 1
        case .allLoaded:
            return 2
        case let .sessionBoundWorkspace(canonicalRootPaths, physicalRootPaths):
            var hasher = Hasher()
            hasher.combine("sessionBoundWorkspace")
            hasher.combine(normalizedSessionSelectorPaths(canonicalRootPaths).sorted())
            hasher.combine(normalizedSessionSelectorPaths(physicalRootPaths).sorted())
            return UInt64(bitPattern: Int64(hasher.finalize()))
        }
    }

    private func bumpCatalogGenerations(
        affectedRootKinds: Set<WorkspaceRootKind>,
        affectedRootIDs: Set<UUID>
    ) {
        guard !affectedRootKinds.isEmpty || !affectedRootIDs.isEmpty else { return }
        for scope in WorkspaceFileContextStore.catalogGenerationScopes {
            guard scopeIncludesAnyRootKind(scope, affectedRootKinds) else { continue }
            catalogGenerationsByScope[scope] = (catalogGenerationsByScope[scope] ?? 0) &+ 1
            #if DEBUG
                Self.activePublicationInvalidationRecorder?.catalogGenerationAdvanceCount += 1
            #endif
        }
        let rootIDsToAdvance = affectedRootIDs.isEmpty
            ? Set(rootStatesByID.values.compactMap { affectedRootKinds.contains($0.root.kind) ? $0.root.id : nil })
            : affectedRootIDs
        for rootID in rootIDsToAdvance {
            catalogGenerationsByRootID[rootID] = (catalogGenerationsByRootID[rootID] ?? 0) &+ 1
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

    private func normalizedSessionSelectorPaths(_ paths: Set<String>) -> Set<String> {
        Set(paths.map { StandardizedPath.absolute(($0 as NSString).expandingTildeInPath) })
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
        case let .sessionBoundWorkspace(canonicalRootPaths, physicalRootPaths):
            let normalizedCanonicalRootPaths = normalizedSessionSelectorPaths(canonicalRootPaths)
            let normalizedPhysicalRootPaths = normalizedSessionSelectorPaths(physicalRootPaths)
            return allRoots.filter { root in
                switch root.kind {
                case .primaryWorkspace:
                    normalizedCanonicalRootPaths.contains(root.standardizedFullPath)
                case .sessionWorktree:
                    normalizedPhysicalRootPaths.contains(root.standardizedFullPath)
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

    @discardableResult
    private func evictInvalidSearchCatalogSnapshots(
        reasons: Set<CatalogInvalidationReason>,
        affectedRootIDs: Set<UUID> = [],
        affectedRootKinds: Set<WorkspaceRootKind> = []
    ) -> [WorkspaceLookupRootScope] {
        let scopes = Set(searchCatalogSnapshotsByScope.compactMap { scope, entry in
            entry.validationToken == searchCatalogSnapshotValidationToken(scope: scope) ? nil : scope
        })
        return evictSearchCatalogSnapshots(
            scopes: scopes,
            reasons: reasons,
            affectedRootIDs: affectedRootIDs,
            affectedRootKinds: affectedRootKinds
        )
    }

    @discardableResult
    private func evictSearchCatalogSnapshots(
        scopes: Set<WorkspaceLookupRootScope>,
        reasons: Set<CatalogInvalidationReason>,
        affectedRootIDs: Set<UUID> = [],
        affectedRootKinds: Set<WorkspaceRootKind> = []
    ) -> [WorkspaceLookupRootScope] {
        let evictedScopes = Array(scopes).filter { searchCatalogSnapshotsByScope.removeValue(forKey: $0) != nil }
        #if DEBUG
            Self.activePublicationInvalidationRecorder?.searchCatalogCacheClearCount += 1
            recordCatalogInvalidation(
                reasons: reasons,
                affectedRootIDs: affectedRootIDs,
                affectedRootKinds: affectedRootKinds,
                evictedScopes: evictedScopes
            )
        #endif
        return evictedScopes
    }

    private func staleSearchContentSnapshot(for record: WorkspaceFileRecord) -> FileSearchContentSnapshot {
        FileSearchContentSnapshot(
            content: nil,
            contentRevision: nil,
            modificationDate: record.modificationDate ?? .distantPast,
            isFresh: false
        )
    }

    private func searchContentRecordIsCurrent(
        _ record: WorkspaceFileRecord,
        invalidationEpoch: UInt64
    ) -> Bool {
        guard let current = file(rootID: record.rootID, relativePath: record.standardizedRelativePath),
              current.id == record.id
        else { return false }
        return (searchContentInvalidationEpochsByFileID[record.id] ?? 0) == invalidationEpoch
    }

    private func pruneCatalogFileIfStillCurrent(_ record: WorkspaceFileRecord) {
        guard let current = file(rootID: record.rootID, relativePath: record.standardizedRelativePath),
              current.id == record.id
        else { return }
        pruneCatalogFileMissingOnDisk(
            rootID: current.rootID,
            relativePath: current.standardizedRelativePath,
            publishDelta: true
        )
    }

    private func invalidateSearchContent(_ file: WorkspaceFileRecord) {
        let key = WorkspaceSearchContentCacheKey(
            rootID: file.rootID,
            fileID: file.id,
            standardizedRelativePath: file.standardizedRelativePath
        )
        #if DEBUG
            if let recorder = Self.activePublicationInvalidationRecorder {
                recorder.contentInvalidationCount += 1
                recorder.distinctContentKeys.insert(key)
            }
        #endif
        nextSearchContentInvalidationEpoch &+= 1
        let invalidationEpoch = nextSearchContentInvalidationEpoch
        searchContentInvalidationEpochsByFileID[file.id] = invalidationEpoch
        if let activePublicationInvalidationBatch {
            activePublicationInvalidationBatch.searchContentInvalidations.record(key, through: invalidationEpoch)
            return
        }
        Task {
            await searchDecodedContentCache.invalidate(key, through: invalidationEpoch)
            await interactiveReadCache.invalidate(key, through: invalidationEpoch)
        }
    }

    private func invalidateRetainedSearchContentForRecoveryUncertainty(rootID: UUID) async {
        guard let state = rootStatesByID[rootID] else { return }
        var invalidations = WorkspaceSearchContentInvalidationBatch()
        for fileID in state.fileIDsByRelativePath.values {
            guard let file = filesByID[fileID] else { continue }
            let key = WorkspaceSearchContentCacheKey(
                rootID: file.rootID,
                fileID: file.id,
                standardizedRelativePath: file.standardizedRelativePath
            )
            nextSearchContentInvalidationEpoch &+= 1
            let invalidationEpoch = nextSearchContentInvalidationEpoch
            searchContentInvalidationEpochsByFileID[file.id] = invalidationEpoch
            invalidations.record(key, through: invalidationEpoch)
        }
        guard !invalidations.isEmpty else { return }
        await searchDecodedContentCache.invalidate(invalidations)
        await interactiveReadCache.invalidate(invalidations)
    }

    private func finalizePublicationInvalidations(_ batch: PublicationInvalidationBatch) {
        if batch.topologyInvalidationRequested {
            performPathMatchSnapshotInvalidation(
                affectedRootKinds: batch.affectedRootKinds,
                reasons: batch.reasons.isEmpty ? [.fileSystemPublication] : batch.reasons,
                affectedRootIDs: batch.affectedRootIDs
            )
        }
        guard !batch.searchContentInvalidations.isEmpty else { return }
        #if DEBUG
            Self.activePublicationInvalidationRecorder?.decodedCacheInvalidationRequestCount += 1
        #endif
        let searchContentInvalidations = batch.searchContentInvalidations
        Task {
            await searchDecodedContentCache.invalidate(searchContentInvalidations)
            await interactiveReadCache.invalidate(searchContentInvalidations)
        }
    }

    private func invalidatePathMatchSnapshot(
        affectedRootKinds: Set<WorkspaceRootKind>,
        reason: CatalogInvalidationReason = .catalogMutation,
        affectedRootIDs: Set<UUID> = []
    ) {
        if let activePublicationInvalidationBatch {
            activePublicationInvalidationBatch.topologyInvalidationRequested = true
            activePublicationInvalidationBatch.affectedRootKinds.formUnion(affectedRootKinds)
            activePublicationInvalidationBatch.affectedRootIDs.formUnion(affectedRootIDs)
            activePublicationInvalidationBatch.reasons.insert(.fileSystemPublication)
            return
        }
        performPathMatchSnapshotInvalidation(
            affectedRootKinds: affectedRootKinds,
            reasons: [reason],
            affectedRootIDs: affectedRootIDs
        )
    }

    private func performPathMatchSnapshotInvalidation(
        affectedRootKinds: Set<WorkspaceRootKind>,
        reasons: Set<CatalogInvalidationReason>,
        affectedRootIDs: Set<UUID>
    ) {
        #if DEBUG
            Self.activePublicationInvalidationRecorder?.topologyInvalidationCount += 1
        #endif
        bumpCatalogGenerations(
            affectedRootKinds: affectedRootKinds,
            affectedRootIDs: affectedRootIDs
        )
        // Keep the previous immutable shard until the canonical applied-index batch arrives.
        // The batch either publishes a contiguous patch or replaces it from the authoritative root snapshot.
        evictInvalidSearchCatalogSnapshots(
            reasons: reasons,
            affectedRootIDs: affectedRootIDs,
            affectedRootKinds: affectedRootKinds
        )
        let stalePathMatchIdentities = Set(pathMatchSnapshotIdentitiesByScope.compactMap { scope, identity in
            identity == pathMatchCacheIdentity(scope: scope) ? nil : identity
        })
        pathMatchSnapshotIdentitiesByScope = pathMatchSnapshotIdentitiesByScope.filter { scope, identity in
            identity == pathMatchCacheIdentity(scope: scope)
        }
        staticPathMatchSnapshotsByScope = staticPathMatchSnapshotsByScope.filter { scope, entry in
            entry.snapshot.cacheIdentity == pathMatchCacheIdentity(scope: scope)
        }
        invalidatePathMatchCache(snapshotIdentities: stalePathMatchIdentities)
    }

    private func invalidatePathMatchCache(snapshotIdentities: Set<PathMatchCacheIdentity>) {
        guard !snapshotIdentities.isEmpty else { return }
        #if DEBUG
            Self.activePublicationInvalidationRecorder?.pathWorkerInvalidationRequestCount += 1
        #endif
        Task { await pathMatchWorker.invalidateCache(snapshotIdentities: snapshotIdentities) }
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
        invalidatePathMatchSnapshot(affectedRootKinds: [root.kind], affectedRootIDs: [root.id])
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
        invalidatePathMatchSnapshot(affectedRootKinds: [root.kind], affectedRootIDs: [root.id])
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
        modifiedFolderIDs: [UUID] = [],
        requiresFullResync: Bool = false
    ) {
        let upsertedFiles = upsertedFiles.filter { isDiscoverableFileID($0.id) }
        let upsertedFolders = upsertedFolders.filter { isDiscoverableFolderID($0.id) }
        let modifiedFileIDs = modifiedFileIDs.filter(isDiscoverableFileID)
        let modifiedFolderIDs = modifiedFolderIDs.filter(isDiscoverableFolderID)
        guard requiresFullResync || !upsertedFiles.isEmpty || !upsertedFolders.isEmpty || !removedFileIDs.isEmpty || !removedFolderIDs.isEmpty || !removedFilePaths.isEmpty || !removedFolderPaths.isEmpty || !modifiedFileIDs.isEmpty || !modifiedFolderIDs.isEmpty else { return }
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
            modifiedFolderIDs: modifiedFolderIDs,
            requiresFullResync: requiresFullResync
        ))
    }

    private func removeFile(relativePath: String, rootID: UUID) {
        guard var state = rootStatesByID[rootID] else { return }
        let removedFileID = removeFile(relativePath: relativePath, state: &state)
        rootStatesByID[rootID] = state
        if let removedFileID {
            yieldCodemapRemoval(root: state.root, removedFileIDs: [removedFileID], isRootUnload: false)
            invalidatePathMatchSnapshot(affectedRootKinds: [state.root.kind], affectedRootIDs: [state.root.id])
        }
    }

    private func invalidateCodemapSnapshot(rootID: UUID, relativePath: String) {
        #if DEBUG
            Self.activePublicationInvalidationRecorder?.codemapInvalidationRequestCount += 1
        #endif
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
        invalidateSearchContent(file)
        searchContentInvalidationEpochsByFileID.removeValue(forKey: fileID)
        fileIDsByStandardizedFullPath.removeValue(forKey: file.standardizedFullPath)
        managedOnlyFileIDs.remove(fileID)
        pendingCodemapRepairFileIDs.remove(fileID)
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
        invalidatePathMatchSnapshot(affectedRootKinds: [state.root.kind], affectedRootIDs: [state.root.id])
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

    private func ensureCodeScanResultTask() async {
        guard codeScanResultTask == nil else { return }
        let subscriptionTask: Task<AsyncStream<[CodeScanActor.ScanResult]>, Never>
        if let existing = codeScanResultSubscriptionTask {
            subscriptionTask = existing
        } else {
            let actor = codeScanActor
            let created = Task { actor.subscribeToScanResults() }
            codeScanResultSubscriptionTask = created
            subscriptionTask = created
        }

        let stream = await subscriptionTask.value
        guard codeScanResultTask == nil else { return }
        codeScanResultSubscriptionTask = nil
        codeScanResultTask = Task { [weak self] in
            for await results in stream {
                guard !Task.isCancelled else { break }
                await self?.applyCodeScanResults(results)
            }
        }
    }

    private func applyCodeScanResults(_ results: [CodeScanActor.ScanResult]) async {
        pendingCodemapRepairFileIDs.subtract(results.map(\.fileID))
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
        await codeScanActor.acknowledgeScanResults(fileIDs: results.map(\.fileID))
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

    private func isRootLifetimeCurrent(rootID: UUID, expectedLifetimeID: UUID?) -> Bool {
        guard let state = rootStatesByID[rootID] else { return false }
        guard let expectedLifetimeID else { return true }
        return state.lifetimeID == expectedLifetimeID
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

enum WorkspaceFileContextStoreError: Error, Equatable {
    case rootNotLoaded(UUID)
    case storeDeallocated
    case rootAlreadyLoadedWithDifferentConfiguration(String)
    case rootLoadInFlightWithDifferentConfiguration(String)
    case catalogMaterializationFailed(String)
}

extension WorkspaceFileContextStoreError: LocalizedError {
    var errorDescription: String? {
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
