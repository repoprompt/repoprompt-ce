#if DEBUG
    import Foundation

    struct WorkspaceFileSearchPhaseSnapshot: Equatable {
        enum Status: String, Equatable {
            case completed
            case cancelled
            case failed
        }

        struct TopLevel: Equatable {
            let readySearchMicroseconds: UInt64
            let readinessFreshnessPreambleMicroseconds: UInt64
            let firstCatalogAccessMicroseconds: UInt64
            let fileSearchActorMicroseconds: UInt64
            let residualOrchestrationMicroseconds: Int64
            let reconciliationDeltaMicroseconds: Int64
        }

        struct Catalog: Equatable {
            let rebuildCount: Int
            let filterMicroseconds: UInt64
            let sortMicroseconds: UInt64
            let fileSortMicroseconds: UInt64
            let folderSortMicroseconds: UInt64
            let sortResidualMicroseconds: UInt64
            let sortReconciliationDeltaMicroseconds: Int64
            let sortInvocationCount: Int
            let sortFileInputCount: Int
            let sortFolderInputCount: Int
            let materializationMicroseconds: UInt64
            let pathIndexKeyMicroseconds: UInt64
            let pathIndexConstructionMicroseconds: UInt64
            let compositionCacheResidualMicroseconds: UInt64
            let totalMicroseconds: UInt64
            let fileCount: Int
            let rootCount: Int
        }

        struct FileActor: Equatable {
            let descriptorMicroseconds: UInt64
            let filterMicroseconds: UInt64
            let sortAndInputMicroseconds: UInt64
            let batchConstructionAndInitialEnqueueMicroseconds: UInt64
            let deterministicDrainToHitMicroseconds: UInt64
            let postHitResidualMicroseconds: UInt64
            let residualMicroseconds: Int64
        }

        struct Counts: Equatable {
            let sourceFileCount: Int
            let descriptorsBuilt: Int
            let admittedFileCount: Int
            let sortInputCount: Int
            let totalBatchCount: Int
            let initiallyEnqueuedBatchCount: Int
            let deterministicallyDrainedBatchCount: Int
            let entriesExaminedByDrainedBatches: Int
            let returnedHitOrdinal: Int
            let returnedHitPrefixLength: Int
        }

        let status: Status
        let topLevel: TopLevel
        let catalog: Catalog
        let fileActor: FileActor
        let counts: Counts
    }

    struct WorkspaceCatalogSortAttributionSample: Equatable {
        let directFileSortNanoseconds: UInt64
        let directFolderSortNanoseconds: UInt64
        let keyDerivationNanoseconds: UInt64
        let projectionAssemblyNanoseconds: UInt64
        let projectedFileSortNanoseconds: UInt64
        let projectionMappingNanoseconds: UInt64
        let directFileComparatorCalls: Int
        let projectedFileComparatorCalls: Int
        let folderComparatorCalls: Int
        let directAndProjectedOrdersMatch: Bool
        let firstMismatchIndex: Int?
    }

    struct WorkspaceCatalogSortAttributionProbe: Equatable {
        enum Status: String, Equatable {
            case completed
            case empty
            case unavailable
        }

        let status: Status
        let sourceFileCount: Int
        let sourceFolderCount: Int
        let samples: [WorkspaceCatalogSortAttributionSample]
        let directAndProjectedOrdersMatch: Bool
        let firstMismatchIndex: Int?
        let orderedFileIDs: [UUID]
    }

    final class WorkspaceFileSearchCatalogBuildObserver: @unchecked Sendable {
        struct Snapshot {
            let filterNanoseconds: UInt64
            let sortNanoseconds: UInt64
            let fileSortNanoseconds: UInt64
            let folderSortNanoseconds: UInt64
            let sortResidualNanoseconds: UInt64
            let sortReconciliationDeltaNanoseconds: Int64
            let sortInvocationCount: Int
            let sortFileInputCount: Int
            let sortFolderInputCount: Int
            let materializationNanoseconds: UInt64
            let pathIndexKeyNanoseconds: UInt64
            let pathIndexConstructionNanoseconds: UInt64
        }

        private let lock = NSLock()
        private var filterNanoseconds: UInt64 = 0
        private var sortNanoseconds: UInt64 = 0
        private var fileSortNanoseconds: UInt64 = 0
        private var folderSortNanoseconds: UInt64 = 0
        private var sortResidualNanoseconds: UInt64 = 0
        private var sortReconciliationDeltaNanoseconds: Int64 = 0
        private var sortInvocationCount = 0
        private var sortFileInputCount = 0
        private var sortFolderInputCount = 0
        private var materializationNanoseconds: UInt64 = 0
        private var pathIndexKeyNanoseconds: UInt64 = 0
        private var pathIndexConstructionNanoseconds: UInt64 = 0

        func recordFilter(nanoseconds: UInt64) {
            withLock { filterNanoseconds &+= nanoseconds }
        }

        func recordSort(
            nanoseconds: UInt64,
            fileNanoseconds: UInt64,
            folderNanoseconds: UInt64,
            fileInputCount: Int,
            folderInputCount: Int
        ) {
            let signedResidual = Int64(nanoseconds) - Int64(fileNanoseconds) - Int64(folderNanoseconds)
            assert(
                signedResidual >= -1_000_000,
                "Nested catalog sort timers exceeded their aggregate by more than 1 ms"
            )
            let residualNanoseconds = UInt64(max(0, signedResidual))
            let reconciliationDelta = Int64(nanoseconds)
                - Int64(fileNanoseconds)
                - Int64(folderNanoseconds)
                - Int64(residualNanoseconds)
            withLock {
                sortNanoseconds &+= nanoseconds
                fileSortNanoseconds &+= fileNanoseconds
                folderSortNanoseconds &+= folderNanoseconds
                sortResidualNanoseconds &+= residualNanoseconds
                sortReconciliationDeltaNanoseconds += reconciliationDelta
                sortInvocationCount += 1
                sortFileInputCount += fileInputCount
                sortFolderInputCount += folderInputCount
            }
        }

        func recordMaterialization(nanoseconds: UInt64) {
            withLock { materializationNanoseconds &+= nanoseconds }
        }

        func recordPathIndexKey(nanoseconds: UInt64) {
            withLock { pathIndexKeyNanoseconds &+= nanoseconds }
        }

        func recordPathIndexConstruction(nanoseconds: UInt64) {
            withLock { pathIndexConstructionNanoseconds &+= nanoseconds }
        }

        func snapshot() -> Snapshot {
            withLock {
                Snapshot(
                    filterNanoseconds: filterNanoseconds,
                    sortNanoseconds: sortNanoseconds,
                    fileSortNanoseconds: fileSortNanoseconds,
                    folderSortNanoseconds: folderSortNanoseconds,
                    sortResidualNanoseconds: sortResidualNanoseconds,
                    sortReconciliationDeltaNanoseconds: sortReconciliationDeltaNanoseconds,
                    sortInvocationCount: sortInvocationCount,
                    sortFileInputCount: sortFileInputCount,
                    sortFolderInputCount: sortFolderInputCount,
                    materializationNanoseconds: materializationNanoseconds,
                    pathIndexKeyNanoseconds: pathIndexKeyNanoseconds,
                    pathIndexConstructionNanoseconds: pathIndexConstructionNanoseconds
                )
            }
        }

        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }
    }

    final class WorkspaceFileSearchPhaseCollector: @unchecked Sendable {
        private struct State {
            var status: WorkspaceFileSearchPhaseSnapshot.Status = .failed
            var preambleNanoseconds: UInt64 = 0
            var catalogAccessNanoseconds: UInt64 = 0
            var actorNanoseconds: UInt64 = 0
            var descriptorNanoseconds: UInt64 = 0
            var actorFilterNanoseconds: UInt64 = 0
            var sortAndInputNanoseconds: UInt64 = 0
            var batchAndInitialEnqueueNanoseconds: UInt64 = 0
            var drainToHitNanoseconds: UInt64 = 0
            var postHitNanoseconds: UInt64 = 0
            var catalog = WorkspaceFileSearchPhaseSnapshot.Catalog(
                rebuildCount: 0,
                filterMicroseconds: 0,
                sortMicroseconds: 0,
                fileSortMicroseconds: 0,
                folderSortMicroseconds: 0,
                sortResidualMicroseconds: 0,
                sortReconciliationDeltaMicroseconds: 0,
                sortInvocationCount: 0,
                sortFileInputCount: 0,
                sortFolderInputCount: 0,
                materializationMicroseconds: 0,
                pathIndexKeyMicroseconds: 0,
                pathIndexConstructionMicroseconds: 0,
                compositionCacheResidualMicroseconds: 0,
                totalMicroseconds: 0,
                fileCount: 0,
                rootCount: 0
            )
            var sourceFileCount = 0
            var descriptorsBuilt = 0
            var admittedFileCount = 0
            var sortInputCount = 0
            var totalBatchCount = 0
            var initiallyEnqueuedBatchCount = 0
            var deterministicallyDrainedBatchCount = 0
            var entriesExaminedByDrainedBatches = 0
            var returnedHitOrdinal = 0
            var returnedHitPrefixLength = 0
            var requestedPathLimit = Int.max
        }

        private let lock = NSLock()
        private var state = State()

        func recordReadinessFreshnessPreamble(nanoseconds: UInt64) {
            withState { $0.preambleNanoseconds = nanoseconds }
        }

        func recordFirstCatalogAccess(nanoseconds: UInt64) {
            withState { $0.catalogAccessNanoseconds = nanoseconds }
        }

        func recordFileSearchActor(nanoseconds: UInt64) {
            withState { $0.actorNanoseconds = nanoseconds }
        }

        func setRequestedPathLimit(_ limit: Int) {
            withState { $0.requestedPathLimit = limit }
        }

        func requestedPathLimit() -> Int {
            readState().requestedPathLimit
        }

        func recordDescriptors(nanoseconds: UInt64, sourceCount: Int, builtCount: Int) {
            withState {
                $0.descriptorNanoseconds = nanoseconds
                $0.sourceFileCount = sourceCount
                $0.descriptorsBuilt = builtCount
            }
        }

        func recordActorFilter(nanoseconds: UInt64, admittedCount: Int) {
            withState {
                $0.actorFilterNanoseconds = nanoseconds
                $0.admittedFileCount = admittedCount
            }
        }

        func recordSortAndInput(nanoseconds: UInt64, inputCount: Int) {
            withState {
                $0.sortAndInputNanoseconds = nanoseconds
                $0.sortInputCount = inputCount
            }
        }

        func recordBatchAndInitialEnqueue(
            nanoseconds: UInt64,
            totalBatchCount: Int,
            initiallyEnqueuedBatchCount: Int
        ) {
            withState {
                $0.batchAndInitialEnqueueNanoseconds = nanoseconds
                $0.totalBatchCount = totalBatchCount
                $0.initiallyEnqueuedBatchCount = initiallyEnqueuedBatchCount
            }
        }

        func recordDeterministicDrainToHit(
            nanoseconds: UInt64,
            drainedBatchCount: Int,
            entriesExamined: Int,
            returnedHitOrdinal: Int,
            returnedHitPrefixLength: Int
        ) {
            withState {
                $0.drainToHitNanoseconds = nanoseconds
                $0.deterministicallyDrainedBatchCount = drainedBatchCount
                $0.entriesExaminedByDrainedBatches = entriesExamined
                $0.returnedHitOrdinal = returnedHitOrdinal
                $0.returnedHitPrefixLength = returnedHitPrefixLength
            }
        }

        func recordPostHitResidual(nanoseconds: UInt64) {
            withState { $0.postHitNanoseconds = nanoseconds }
        }

        func recordCatalogRebuild(_ catalog: WorkspaceFileSearchPhaseSnapshot.Catalog) {
            withState { $0.catalog = catalog }
        }

        func finish(status: WorkspaceFileSearchPhaseSnapshot.Status) {
            withState { $0.status = status }
        }

        func snapshot(readySearchNanoseconds: UInt64) -> WorkspaceFileSearchPhaseSnapshot {
            let captured = readState()
            let readySearchMicroseconds = WorkspaceFileSearchDebugTiming.microseconds(readySearchNanoseconds)
            let preambleMicroseconds = WorkspaceFileSearchDebugTiming.microseconds(captured.preambleNanoseconds)
            let catalogAccessMicroseconds = WorkspaceFileSearchDebugTiming.microseconds(captured.catalogAccessNanoseconds)
            let actorMicroseconds = WorkspaceFileSearchDebugTiming.microseconds(captured.actorNanoseconds)
            let topClassified = preambleMicroseconds &+ catalogAccessMicroseconds &+ actorMicroseconds
            let topResidual = Int64(readySearchMicroseconds) - Int64(topClassified)
            let topReconciliation = Int64(readySearchMicroseconds)
                - Int64(topClassified)
                - topResidual

            let descriptorMicroseconds = WorkspaceFileSearchDebugTiming.microseconds(captured.descriptorNanoseconds)
            let filterMicroseconds = WorkspaceFileSearchDebugTiming.microseconds(captured.actorFilterNanoseconds)
            let sortAndInputMicroseconds = WorkspaceFileSearchDebugTiming.microseconds(captured.sortAndInputNanoseconds)
            let batchMicroseconds = WorkspaceFileSearchDebugTiming.microseconds(captured.batchAndInitialEnqueueNanoseconds)
            let drainMicroseconds = WorkspaceFileSearchDebugTiming.microseconds(captured.drainToHitNanoseconds)
            let postHitMicroseconds = WorkspaceFileSearchDebugTiming.microseconds(captured.postHitNanoseconds)
            let actorClassified = descriptorMicroseconds &+ filterMicroseconds &+ sortAndInputMicroseconds
                &+ batchMicroseconds &+ drainMicroseconds &+ postHitMicroseconds

            return WorkspaceFileSearchPhaseSnapshot(
                status: captured.status,
                topLevel: WorkspaceFileSearchPhaseSnapshot.TopLevel(
                    readySearchMicroseconds: readySearchMicroseconds,
                    readinessFreshnessPreambleMicroseconds: preambleMicroseconds,
                    firstCatalogAccessMicroseconds: catalogAccessMicroseconds,
                    fileSearchActorMicroseconds: actorMicroseconds,
                    residualOrchestrationMicroseconds: topResidual,
                    reconciliationDeltaMicroseconds: topReconciliation
                ),
                catalog: captured.catalog,
                fileActor: WorkspaceFileSearchPhaseSnapshot.FileActor(
                    descriptorMicroseconds: descriptorMicroseconds,
                    filterMicroseconds: filterMicroseconds,
                    sortAndInputMicroseconds: sortAndInputMicroseconds,
                    batchConstructionAndInitialEnqueueMicroseconds: batchMicroseconds,
                    deterministicDrainToHitMicroseconds: drainMicroseconds,
                    postHitResidualMicroseconds: postHitMicroseconds,
                    residualMicroseconds: Int64(actorMicroseconds) - Int64(actorClassified)
                ),
                counts: WorkspaceFileSearchPhaseSnapshot.Counts(
                    sourceFileCount: captured.sourceFileCount,
                    descriptorsBuilt: captured.descriptorsBuilt,
                    admittedFileCount: captured.admittedFileCount,
                    sortInputCount: captured.sortInputCount,
                    totalBatchCount: captured.totalBatchCount,
                    initiallyEnqueuedBatchCount: captured.initiallyEnqueuedBatchCount,
                    deterministicallyDrainedBatchCount: captured.deterministicallyDrainedBatchCount,
                    entriesExaminedByDrainedBatches: captured.entriesExaminedByDrainedBatches,
                    returnedHitOrdinal: captured.returnedHitOrdinal,
                    returnedHitPrefixLength: captured.returnedHitPrefixLength
                )
            )
        }

        private func withState(_ body: (inout State) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            body(&state)
        }

        private func readState() -> State {
            lock.lock()
            defer { lock.unlock() }
            return state
        }
    }

    enum WorkspaceFileSearchDebugContext {
        @TaskLocal static var collector: WorkspaceFileSearchPhaseCollector?
        @TaskLocal static var catalogBuildObserver: WorkspaceFileSearchCatalogBuildObserver?
    }

    enum WorkspaceFileSearchDebugTiming {
        static func now() -> UInt64 {
            DispatchTime.now().uptimeNanoseconds
        }

        static func elapsed(since start: UInt64, through end: UInt64) -> UInt64 {
            end >= start ? end - start : 0
        }

        static func microseconds(_ nanoseconds: UInt64) -> UInt64 {
            nanoseconds / 1000
        }
    }
#endif
