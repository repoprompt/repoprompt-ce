import Cocoa
import Foundation

#if DEBUG
    private var codeScanActorDebugLoggingEnabled = false
#endif

private func codeScanActorDebugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
        guard codeScanActorDebugLoggingEnabled else { return }
        print("[CodeScanActor] \(message())")
    #endif
}

private actor CodeScanAsyncLimiter {
    private enum WaiterState {
        case waiting(CheckedContinuation<Void, Error>)
        case cancelled
    }

    private let capacity: Int
    private var availablePermits: Int
    private var waiterOrder: [UUID] = []
    private var waiterStates: [UUID: WaiterState] = [:]
    #if DEBUG
        private var permitsInUse = 0
        private var maxObservedPermitsInUse = 0
    #endif

    init(capacity: Int) {
        precondition(capacity > 0, "Limiter must have at least one permit")
        self.capacity = capacity
        availablePermits = capacity
    }

    func withPermit<T>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await body()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if availablePermits > 0 {
            availablePermits -= 1
            #if DEBUG
                permitsInUse += 1
                maxObservedPermitsInUse = max(maxObservedPermitsInUse, permitsInUse)
            #endif
            return
        }

        let waiterID = UUID()
        defer { waiterStates.removeValue(forKey: waiterID) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task { await self.enqueueWaiter(id: waiterID, continuation: continuation) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    private func enqueueWaiter(id: UUID, continuation: CheckedContinuation<Void, Error>) {
        if case .cancelled? = waiterStates.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
            return
        }

        if availablePermits > 0 {
            availablePermits -= 1
            #if DEBUG
                permitsInUse += 1
                maxObservedPermitsInUse = max(maxObservedPermitsInUse, permitsInUse)
            #endif
            continuation.resume()
            return
        }

        waiterStates[id] = .waiting(continuation)
        waiterOrder.append(id)
    }

    private func cancelWaiter(id: UUID) {
        if case let .waiting(continuation)? = waiterStates.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        } else if waiterStates[id] == nil {
            waiterStates[id] = .cancelled
        }
    }

    private func release() {
        #if DEBUG
            permitsInUse = max(permitsInUse - 1, 0)
        #endif

        while !waiterOrder.isEmpty {
            let waiterID = waiterOrder.removeFirst()
            guard let state = waiterStates.removeValue(forKey: waiterID) else { continue }
            switch state {
            case let .waiting(continuation):
                #if DEBUG
                    permitsInUse += 1
                    maxObservedPermitsInUse = max(maxObservedPermitsInUse, permitsInUse)
                #endif
                continuation.resume()
                return
            case .cancelled:
                continue
            }
        }

        #if DEBUG
            assert(availablePermits < capacity, "CodeScanAsyncLimiter over-release detected")
        #endif
        availablePermits = min(availablePermits + 1, capacity)
    }

    #if DEBUG
        func maxObservedPermitsForTesting() -> Int {
            maxObservedPermitsInUse
        }
    #endif
}

actor CodeScanActor {
    struct SelfHealingScanRequestResult {
        let submittedFileIDs: Set<UUID>
        let alreadyScheduledFileIDs: Set<UUID>
    }

    /// Conservative default scan concurrency: scale modestly with CPU, capped to avoid parser/generator memory spikes.
    private static var defaultMaxConcurrentScans: Int {
        let cpu = ProcessInfo.processInfo.activeProcessorCount
        return min(max(4, cpu / 2), 6)
    }

    /// Concurrency limit
    private let maxConcurrentScans: Int

    /// Suspends scan tasks before entering SyntaxManager's Tree-sitter parse/query phase.
    /// The global SyntaxManager lock remains the safety backstop for all Tree-sitter entry points.
    private let treeSitterParseLimiter = CodeScanAsyncLimiter(capacity: 1)

    init(maxConcurrentScans: Int = CodeScanActor.defaultMaxConcurrentScans) {
        self.maxConcurrentScans = max(1, maxConcurrentScans)
    }

    /// Track the latest known modification date for each file to avoid double-counting
    private var latestFileModDates: [UUID: Date] = [:]

    /// How many scans are running right now
    private var activeScans = 0

    /// The queue of ScanRequests waiting for a free slot
    private var queue: [ScanRequest] = []

    /// Tracks all active scanning tasks so we can cancel them if needed
    private var scanTasks = Set<ScanningTask>()

    #if DEBUG
        private var scanWillStartHandlerForTesting: (@Sendable (UUID) async -> Void)?
    #endif

    /// Tracks how many scans remain (queued + active)
    private var outstandingScans = 0

    /// Tracks how many scans have been requested in total (for the progress ‘denominator’)
    private var totalScheduled = 0

    // -------------------------------------
    //  Progress stream
    // -------------------------------------
    private var progressContinuations = [UUID: AsyncStream<(Int, Int)>.Continuation]()
    private var progressCoalescingTask: Task<Void, Never>?

    /// Changed to 2 seconds
    private let progressCoalescingDelay: UInt64 = 2_000_000_000

    private var lastKnownProgress: (Int, Int)?

    // New: store a pending progress that we’ll flush in one shot
    private var pendingProgress: (Int, Int)?
    private var lastProgressFlushTime: Date = .distantPast

    // -------------------------------------
    //  BATCHED results stream
    // -------------------------------------
    private var resultContinuations = [UUID: AsyncStream<[ScanResult]>.Continuation]()
    private var resultBatchBuffer = [ScanResult]()
    /// File IDs yielded to the store but not yet acknowledged as installed or rejected.
    private var resultDeliveryPendingFileIDs = Set<UUID>()
    private var resultsCoalescingTask: Task<Void, Never>?
    private let resultsCoalescingDelay: UInt64 = 2_000_000_000 // e.g. 2 seconds
    private var lastResultsScheduleCall = DispatchTime.now()

    // New: immediate flush threshold for large bursts (reduces end-to-end latency)
    private let resultsImmediateFlushThreshold = 500

    /// -------------------------------------
    ///  Cache and lightweight API completion state
    /// -------------------------------------
    private let cacheManager = CodeMapCacheManager()
    /// Lightweight completion/accounting state for files that have produced an accepted API.
    /// Full `FileAPI` values are delivered through `ScanResult` and persisted in root caches; this set avoids retaining a duplicate actor-owned copy.
    private var acceptedAPIFileIDs = Set<UUID>()
    private var fileIDsByRoot: [String: Set<UUID>] = [:]
    private var rootKeyByFileID: [UUID: String] = [:]

    // NEW: actor-owned in-memory cache (root path → entire cache payload)
    private var rootCaches: [String: CodeMapCacheRootFolder] = [:]

    private struct RootCacheLoadTask {
        let id: UUID
        let task: Task<CodeMapCacheRootFolder?, Never>
    }

    /// Single-flight disk loads for actor-owned root caches.
    private var rootCacheLoadTasks: [String: RootCacheLoadTask] = [:]

    #if DEBUG
        private var rootCacheDiskLoadCount = 0
        private var rootCacheDiskLoadDuration: TimeInterval = 0
        private var rootCacheDiskLoadFileEntryCount = 0
        private var rootCacheDiskSaveCount = 0
        private var rootCacheDiskSaveDuration: TimeInterval = 0
        private var rootCacheDiskSaveFileEntryCount = 0
    #endif

    /// Root lifecycle tokens used to drop suspended request ingestion after unload/clear/purge/cancel.
    private var rootLifecycleGenerations: [String: UInt64] = [:]

    // NEW: track which roots need to be flushed to disk
    private var dirtyRootFoldersForDisk: Set<String> = []

    // NEW: old-generation lookup during initial root-load rebuilds
    private var rebuildLookupByRoot: [String: [String: CodeMapCacheFileEntry]] = [:]

    // -------------------------------------
    // MARK: - NEW: Track cache processing

    /// -------------------------------------
    /// How many files are currently being processed from cache.
    private var cacheProcessingCount = 0 // NEW

    // -------------------------------------
    // MARK: - Nested Data Structures

    /// -------------------------------------
    enum ScanBatchPurpose {
        case initialRootLoad
        case selfHealing
        case adhoc
    }

    struct ScanRequest {
        let fileID: UUID
        let modificationDate: Date
        let content: String
        let fileExtension: String
        let relativePath: String
        let fullPath: String
        let rootFolderPath: String
    }

    struct ScanResult: @unchecked Sendable {
        // Invariant: completed result batches must not retain ScanRequest.content.
        let fileID: UUID
        let modificationDate: Date
        let fileExtension: String
        let relativePath: String
        let fullPath: String
        let rootFolderPath: String
        let fileAPI: FileAPI?

        init(request: ScanRequest, fileAPI: FileAPI?) {
            fileID = request.fileID
            modificationDate = request.modificationDate
            fileExtension = request.fileExtension
            relativePath = request.relativePath
            fullPath = request.fullPath
            rootFolderPath = request.rootFolderPath
            self.fileAPI = fileAPI
        }
    }

    #if DEBUG
        struct CodemapMemoryCounters {
            let fileAPIEntryCount: Int
            let latestFileModDateCount: Int
            let trackedRootCount: Int
            let trackedFileIDCount: Int
            let rootKeyByFileIDCount: Int

            let rootCacheRootCount: Int
            let rootCacheFileEntryCount: Int
            let dirtyRootCount: Int
            let rootCacheLoadTaskCount: Int

            let rebuildLookupRootCount: Int
            let rebuildLookupFileEntryCount: Int

            let queuedCount: Int
            let activeScanCount: Int
            let outstandingScanCount: Int
            let totalScheduledCount: Int
            let cacheProcessingCount: Int

            let resultBatchBufferCount: Int
            let resultBatchBufferFileAPICount: Int

            let actorRetainedFileAPILikeEntryCount: Int
        }
    #endif

    private struct ScanningTask: Hashable {
        let id: UUID
        let request: ScanRequest
        let task: Task<Void, Never>

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }

        static func == (lhs: ScanningTask, rhs: ScanningTask) -> Bool {
            lhs.id == rhs.id
        }
    }

    private enum CacheCheckResult {
        case hit
        case miss
        case staleRoot
    }

    private func isUsableCacheEntry(
        _ entry: CodeMapCacheFileEntry,
        for request: ScanRequest,
        rootKey: String,
        contentFingerprint: CodeMapContentFingerprint
    ) -> Bool {
        guard entry.modificationDate >= request.modificationDate else { return false }
        guard entry.contentFingerprint == contentFingerprint else { return false }

        let standardizedRoot = StandardizedPath.absolute(rootKey)
        let standardizedFullPath = StandardizedPath.absolute(request.fullPath)
        guard StandardizedPath.isDescendant(standardizedFullPath, of: standardizedRoot) else { return false }

        let standardizedRelativePath = StandardizedPath.relative(request.relativePath)
        let expectedFullPath = StandardizedPath.join(
            standardizedRoot: standardizedRoot,
            standardizedRelativePath: standardizedRelativePath
        )
        guard standardizedFullPath == expectedFullPath else { return false }

        let cachedAPIPath = StandardizedPath.absolute(entry.fileAPI.filePath)
        guard cachedAPIPath == standardizedFullPath else { return false }

        return true
    }

    // -------------------------------------------------------
    // MARK: 1) Subscribe to batched scanning results

    /// -------------------------------------------------------
    nonisolated func subscribeToScanResults() -> AsyncStream<[ScanResult]> {
        let id = UUID()
        return AsyncStream { continuation in
            Task { await self.addResultContinuation(continuation, withID: id) }
            continuation.onTermination = { _ in
                Task { await self.removeResultContinuation(id) }
            }
        }
    }

    private func addResultContinuation(
        _ continuation: AsyncStream<[ScanResult]>.Continuation,
        withID id: UUID
    ) {
        resultContinuations[id] = continuation
    }

    private func removeResultContinuation(_ id: UUID) {
        resultContinuations.removeValue(forKey: id)
    }

    // -------------------------------------------------------
    // MARK: 2) Subscribe to progress

    /// -------------------------------------------------------
    nonisolated func subscribeToProgress() -> AsyncStream<(Int, Int)> {
        let id = UUID()
        return AsyncStream { continuation in
            Task { await self.addProgressContinuation(continuation, withID: id) }
            continuation.onTermination = { _ in
                Task { await self.removeProgressContinuation(withID: id) }
            }
        }
    }

    private func addProgressContinuation(
        _ continuation: AsyncStream<(Int, Int)>.Continuation,
        withID id: UUID
    ) {
        progressContinuations[id] = continuation
    }

    private func removeProgressContinuation(withID id: UUID) {
        progressContinuations.removeValue(forKey: id)
    }

    private func ensureRootCacheLoaded(forRootKey rootKey: String) async -> CodeMapCacheRootFolder? {
        if let existing = rootCaches[rootKey] {
            return existing
        }

        if rebuildLookupByRoot[rootKey] != nil {
            return rootCaches[rootKey]
        }

        if let existingLoad = rootCacheLoadTasks[rootKey] {
            let loaded = await existingLoad.task.value
            guard rootCacheLoadTasks[rootKey]?.id == existingLoad.id else {
                return rootCaches[rootKey]
            }
            rootCacheLoadTasks.removeValue(forKey: rootKey)
            guard rebuildLookupByRoot[rootKey] == nil else {
                return rootCaches[rootKey]
            }
            if let loaded {
                return installLoadedRootCache(loaded, forRootKey: rootKey)
            }
            return rootCaches[rootKey]
        }

        let loadID = UUID()
        #if DEBUG
            let rootCacheDiskLoadStart = CFAbsoluteTimeGetCurrent()
        #endif
        let loadTask = Task<CodeMapCacheRootFolder?, Never> { [cacheManager] in
            await cacheManager.loadRootFolderCacheAsync(rootFolderPath: rootKey)
        }
        rootCacheLoadTasks[rootKey] = RootCacheLoadTask(id: loadID, task: loadTask)

        let loaded = await loadTask.value
        #if DEBUG
            rootCacheDiskLoadCount += 1
            rootCacheDiskLoadDuration += CFAbsoluteTimeGetCurrent() - rootCacheDiskLoadStart
            rootCacheDiskLoadFileEntryCount += loaded?.files.count ?? 0
        #endif
        guard rootCacheLoadTasks[rootKey]?.id == loadID else {
            return rootCaches[rootKey]
        }
        rootCacheLoadTasks.removeValue(forKey: rootKey)
        guard rebuildLookupByRoot[rootKey] == nil else {
            return rootCaches[rootKey]
        }
        if let loaded {
            return installLoadedRootCache(loaded, forRootKey: rootKey)
        }
        return rootCaches[rootKey]
    }

    private func installLoadedRootCache(_ loaded: CodeMapCacheRootFolder, forRootKey rootKey: String) -> CodeMapCacheRootFolder {
        if let current = rootCaches[rootKey] {
            var merged = loaded
            for (relativePath, entry) in current.files {
                merged.files[relativePath] = entry
            }
            rootCaches[rootKey] = merged
            return merged
        }

        rootCaches[rootKey] = loaded
        return loaded
    }

    private func prefetchRootCachesIfNeeded(forRootKeys rootKeys: Set<String>) async {
        guard !rootKeys.isEmpty else { return }
        for rootKey in rootKeys.sorted() {
            guard rootCaches[rootKey] == nil, rebuildLookupByRoot[rootKey] == nil else { continue }
            _ = await ensureRootCacheLoaded(forRootKey: rootKey)
        }
    }

    private func rootHasQueuedOrActiveWork(forRootKey rootKey: String) -> Bool {
        queue.contains { canonicalRoot($0.rootFolderPath) == rootKey } ||
            scanTasks.contains { canonicalRoot($0.request.rootFolderPath) == rootKey }
    }

    private func hasQueuedOrActiveScan(for fileID: UUID) -> Bool {
        queue.contains { $0.fileID == fileID } ||
            scanTasks.contains { $0.request.fileID == fileID }
    }

    private func evictCleanIdleRootCachesIfNeeded() {
        guard cacheProcessingCount == 0 else { return }

        for rootKey in Array(rootCaches.keys) {
            guard !dirtyRootFoldersForDisk.contains(rootKey),
                  rebuildLookupByRoot[rootKey] == nil,
                  rootCacheLoadTasks[rootKey] == nil,
                  !rootHasQueuedOrActiveWork(forRootKey: rootKey)
            else {
                continue
            }

            rootCaches.removeValue(forKey: rootKey)
        }
    }

    private func cancelRootCacheLoad(forRootKey rootKey: String) {
        rootCacheLoadTasks.removeValue(forKey: rootKey)?.task.cancel()
    }

    private func cancelRootCacheLoads(forRootKeys rootKeys: some Sequence<String>) {
        for rootKey in rootKeys {
            cancelRootCacheLoad(forRootKey: rootKey)
        }
    }

    private func cancelAllRootCacheLoads() {
        for load in rootCacheLoadTasks.values {
            load.task.cancel()
        }
        rootCacheLoadTasks.removeAll()
    }

    private func rootGeneration(forRootKey rootKey: String) -> UInt64 {
        rootLifecycleGenerations[rootKey, default: 0]
    }

    private func rootGenerations(forRootKeys rootKeys: Set<String>) -> [String: UInt64] {
        rootKeys.reduce(into: [String: UInt64]()) { result, rootKey in
            result[rootKey] = rootGeneration(forRootKey: rootKey)
        }
    }

    private func rootGenerationMatches(rootKey: String, expected: UInt64?) -> Bool {
        guard let expected else { return true }
        return rootGeneration(forRootKey: rootKey) == expected
    }

    private func removeTrackingForDroppedRequest(_ request: ScanRequest) {
        guard latestFileModDates[request.fileID] == request.modificationDate else { return }
        let rootKey = canonicalRoot(request.rootFolderPath)
        latestFileModDates.removeValue(forKey: request.fileID)
        if rootKeyByFileID[request.fileID] == rootKey {
            rootKeyByFileID.removeValue(forKey: request.fileID)
            fileIDsByRoot[rootKey]?.remove(request.fileID)
            if fileIDsByRoot[rootKey]?.isEmpty == true {
                fileIDsByRoot.removeValue(forKey: rootKey)
            }
        }
    }

    private func rootGenerationsStillMatch(_ expectedGenerations: [String: UInt64]) -> Bool {
        expectedGenerations.allSatisfy { rootGeneration(forRootKey: $0.key) == $0.value }
    }

    private func advanceRootGenerations(forRootKeys rootKeys: some Sequence<String>) {
        for rootKey in rootKeys {
            rootLifecycleGenerations[rootKey, default: 0] &+= 1
        }
    }

    private func knownRootKeys() -> Set<String> {
        Set(fileIDsByRoot.keys)
            .union(rootCaches.keys)
            .union(rootCacheLoadTasks.keys)
            .union(rebuildLookupByRoot.keys)
            .union(queue.map { canonicalRoot($0.rootFolderPath) })
            .union(scanTasks.map { canonicalRoot($0.request.rootFolderPath) })
    }

    @discardableResult
    private func removeBufferedResults(forRootKeys rootKeys: some Sequence<String>) -> Int {
        let rootKeySet = Set(rootKeys)
        guard !rootKeySet.isEmpty, !resultBatchBuffer.isEmpty else { return 0 }

        let beforeCount = resultBatchBuffer.count
        resultBatchBuffer.removeAll { result in
            rootKeySet.contains(canonicalRoot(result.rootFolderPath))
        }
        let removedCount = beforeCount - resultBatchBuffer.count
        if resultBatchBuffer.isEmpty {
            resultsCoalescingTask?.cancel()
            resultsCoalescingTask = nil
        }
        return removedCount
    }

    // -------------------------------------------------------
    // MARK: 3) Cancel scans & unload for a given root

    /// -------------------------------------------------------
    func cancelAndUnloadScans(forRootFolder rootFolderPath: String) async {
        let rootKey = canonicalRoot(rootFolderPath)
        advanceRootGenerations(forRootKeys: [rootKey])

        // Remove any queued scan requests
        let queuedToRemove = queue.count(where: { canonicalRoot($0.rootFolderPath) == rootKey })
        queue.removeAll { canonicalRoot($0.rootFolderPath) == rootKey }

        // Cancel active tasks
        let tasksToCancel = scanTasks.filter { canonicalRoot($0.request.rootFolderPath) == rootKey }
        for taskRecord in tasksToCancel {
            taskRecord.task.cancel()
            scanTasks.remove(taskRecord)
            activeScans = max(activeScans - 1, 0)
        }

        // Drop buffered completed results before they can flush into a reloaded same-path root.
        removeBufferedResults(forRootKeys: [rootKey])

        // Drop any in-flight load plus the in-memory root cache and dirty flag
        cancelRootCacheLoad(forRootKey: rootKey)
        rootCaches.removeValue(forKey: rootKey)
        dirtyRootFoldersForDisk.remove(rootKey)
        rebuildLookupByRoot.removeValue(forKey: rootKey)
        removeTrackedFiles(forRootKeys: [rootKey])

        // Adjust outstandingScans
        let totalRemoved = tasksToCancel.count + queuedToRemove
        outstandingScans = max(outstandingScans - totalRemoved, 0)

        pushProgressUpdate()
        scheduleNextScan()
    }

    // -------------------------------------------------------
    // MARK: 3b) Cancel scans & unload for multiple roots

    /// -------------------------------------------------------
    func cancelAndUnloadScans(forRootFolders rootFolderPaths: [String]) async {
        let rootKeys = Set(rootFolderPaths.map { canonicalRoot($0) })
        guard !rootKeys.isEmpty else { return }
        advanceRootGenerations(forRootKeys: rootKeys)

        var queuedToRemove = 0
        queue.removeAll {
            let shouldRemove = rootKeys.contains(canonicalRoot($0.rootFolderPath))
            if shouldRemove {
                queuedToRemove += 1
            }
            return shouldRemove
        }

        let tasksToCancel = scanTasks.filter { rootKeys.contains(canonicalRoot($0.request.rootFolderPath)) }
        for taskRecord in tasksToCancel {
            taskRecord.task.cancel()
            scanTasks.remove(taskRecord)
        }
        activeScans = max(activeScans - tasksToCancel.count, 0)

        removeBufferedResults(forRootKeys: rootKeys)

        cancelRootCacheLoads(forRootKeys: rootKeys)
        for rootKey in rootKeys {
            rootCaches.removeValue(forKey: rootKey)
            dirtyRootFoldersForDisk.remove(rootKey)
            rebuildLookupByRoot.removeValue(forKey: rootKey)
        }
        removeTrackedFiles(forRootKeys: rootKeys)

        let totalRemoved = tasksToCancel.count + queuedToRemove
        outstandingScans = max(outstandingScans - totalRemoved, 0)

        pushProgressUpdate()
        scheduleNextScan()
    }

    // -------------------------------------------------------
    // MARK: 4) Check cache (asynchronously) and handle result

    /// -------------------------------------------------------
    /// Modified: use async/background cache lookup + coalesced/immediate flush heuristic
    private func checkCacheAndHandleResult(
        for request: ScanRequest,
        expectedRootGeneration: UInt64? = nil,
        initialRootLookupFiles: [String: CodeMapCacheFileEntry]? = nil,
        removeStaleCacheEntryOnMiss: Bool = false
    ) async -> CacheCheckResult {
        let cacheCheckStart = CodeMapPerfRuntime.sharedPipelineStats.map { _ in CodeMapPerfRuntime.currentTime() }
        defer {
            if let cacheCheckStart {
                CodeMapPerfRuntime.sharedPipelineStats?.addDuration(\.actorCacheCheckDuration, CodeMapPerfRuntime.durationSince(cacheCheckStart))
            }
        }
        cacheProcessingCount += 1
        pushProgressUpdate()
        defer {
            cacheProcessingCount = max(cacheProcessingCount - 1, 0)
            pushProgressUpdate()
        }

        // 1) Ensure the actor-owned in-memory cache is loaded once per root.
        let rootKey = canonicalRoot(request.rootFolderPath)
        guard rootGenerationMatches(rootKey: rootKey, expected: expectedRootGeneration) else {
            return .staleRoot
        }
        let rootCache: CodeMapCacheRootFolder? = if initialRootLookupFiles != nil {
            rootCaches[rootKey]
        } else {
            await ensureRootCacheLoaded(forRootKey: rootKey)
        }
        guard rootGenerationMatches(rootKey: rootKey, expected: expectedRootGeneration) else {
            return .staleRoot
        }

        // 2) If we have a fresh, content-identical, path-owned entry for this file, use it.
        let lookupFiles = initialRootLookupFiles ?? rootCaches[rootKey]?.files ?? rootCache?.files
        let contentFingerprint = CodeMapContentFingerprint(content: request.content)
        if let entry = lookupFiles?[request.relativePath] {
            if isUsableCacheEntry(entry, for: request, rootKey: rootKey, contentFingerprint: contentFingerprint) {
                let cachedAPI = entry.fileAPI
                acceptedAPIFileIDs.insert(request.fileID)

                resultBatchBuffer.append(ScanResult(request: request, fileAPI: cachedAPI))
                maybeFlushResultsIfNeeded()

                outstandingScans = max(outstandingScans - 1, 0)
                CodeMapPerfRuntime.sharedPipelineStats?.increment(\.cacheHits)
                pushProgressUpdate()
                return .hit
            }

            if removeStaleCacheEntryOnMiss {
                removeCacheEntry(relativePath: request.relativePath, rootKey: rootKey)
            }
        }

        // Cache miss or stale
        CodeMapPerfRuntime.sharedPipelineStats?.increment(\.cacheMisses)
        return .miss
    }

    private func removeCacheEntry(relativePath: String, rootKey: String) {
        guard var rootEntry = rootCaches[rootKey],
              rootEntry.files.removeValue(forKey: relativePath) != nil
        else {
            return
        }

        rootCaches[rootKey] = rootEntry
        dirtyRootFoldersForDisk.insert(rootKey)
    }

    // -------------------------------------------------------
    // MARK: - Helper: remove older queued request for the same file

    /// -------------------------------------------------------
    private func removeQueuedRequest(for fileID: UUID) {
        // Remove from queue
        let beforeCount = queue.count
        queue.removeAll { $0.fileID == fileID }
        let removedCount = beforeCount - queue.count

        if removedCount > 0 {
            // Adjust counters if we removed older requests
            outstandingScans = max(outstandingScans - removedCount, 0)
        }

        // Also cancel any active scans for that file if needed
        let activeTasks = scanTasks.filter { $0.request.fileID == fileID }
        var canceledActive = 0
        for task in activeTasks {
            task.task.cancel()
            scanTasks.remove(task)
            activeScans = max(activeScans - 1, 0)
            outstandingScans = max(outstandingScans - 1, 0)
            canceledActive += 1
        }
        if canceledActive > 0 {
            scheduleNextScan()
        }
    }

    // -------------------------------------------------------
    // MARK: 5) Request scans (single or batch) - ASYNC versions

    /// -------------------------------------------------------
    func requestScan(_ request: ScanRequest) async {
        let ingestStart = CodeMapPerfRuntime.sharedPipelineStats.map { _ in CodeMapPerfRuntime.currentTime() }
        defer {
            if let ingestStart {
                CodeMapPerfRuntime.sharedPipelineStats?.addDuration(\.actorRequestIngestDuration, CodeMapPerfRuntime.durationSince(ingestStart))
            }
        }
        let rootKey = canonicalRoot(request.rootFolderPath)
        let expectedRootGeneration = rootGeneration(forRootKey: rootKey)

        // 1) If we already know about this file with a newer or equal mod date, skip.
        if let knownDate = latestFileModDates[request.fileID], knownDate >= request.modificationDate {
            return
        }

        // 2) Remove any older queued requests for this file.
        removeQueuedRequest(for: request.fileID)
        latestFileModDates[request.fileID] = request.modificationDate
        trackFileID(request.fileID, forRootKey: rootKey)

        // 3) Bump the counters:
        // Only count as a new file if we haven't seen it before.
        if !acceptedAPIFileIDs.contains(request.fileID) {
            totalScheduled += 1
        }
        outstandingScans += 1
        CodeMapPerfRuntime.sharedPipelineStats?.increment(\.requestsEnqueued)
        pushProgressUpdate()

        // 4) Check cache first.
        switch await checkCacheAndHandleResult(for: request, expectedRootGeneration: expectedRootGeneration) {
        case .hit:
            evictCleanIdleRootCachesIfNeeded()
            return
        case .staleRoot:
            removeTrackingForDroppedRequest(request)
            outstandingScans = max(outstandingScans - 1, 0)
            pushProgressUpdate()
            return
        case .miss:
            break
        }

        guard rootGenerationMatches(rootKey: rootKey, expected: expectedRootGeneration) else {
            removeTrackingForDroppedRequest(request)
            outstandingScans = max(outstandingScans - 1, 0)
            pushProgressUpdate()
            return
        }

        // 5) Cache miss, so queue the scan.
        queue.append(request)
        pushProgressUpdate()
        scheduleNextScan()
    }

    @discardableResult
    func requestScans(
        _ requests: [ScanRequest],
        purpose: ScanBatchPurpose = .adhoc,
        rootFolderPaths: [String] = [],
        purgeCachesOnEmptyInitialRequests: Bool = false
    ) async -> Set<UUID> {
        let ingestStart = CodeMapPerfRuntime.sharedPipelineStats.map { _ in CodeMapPerfRuntime.currentTime() }
        defer {
            if let ingestStart {
                CodeMapPerfRuntime.sharedPipelineStats?.addDuration(\.actorRequestIngestDuration, CodeMapPerfRuntime.durationSince(ingestStart))
            }
        }
        let shouldHandleEmptyInitial = purpose == .initialRootLoad &&
            !rootFolderPaths.isEmpty &&
            purgeCachesOnEmptyInitialRequests
        if requests.isEmpty, !shouldHandleEmptyInitial { return [] }

        let rootsFromRequests = Set(requests.map { canonicalRoot($0.rootFolderPath) })
        let rootsFromArgs = Set(rootFolderPaths.map { canonicalRoot($0) })
        let rootsForRebuild = rootsFromRequests.union(rootsFromArgs)
        let expectedRootGenerations = rootGenerations(forRootKeys: rootsForRebuild)
        let initialRootRelativePathsByRoot = initialRootRelativePathSets(for: requests)

        let initialRootLookupByRoot: [String: [String: CodeMapCacheFileEntry]]
        if purpose == .initialRootLoad {
            #if DEBUG
                let cacheRebuildStartMS = CodeMapInitialRootLoadDiagnostics.start()
            #endif
            initialRootLookupByRoot = await prepareCacheRebuild(forRoots: rootsForRebuild)
            #if DEBUG
                CodeMapInitialRootLoadDiagnostics.cacheRebuild(
                    rootCount: rootsForRebuild.count,
                    requestCount: requests.count,
                    startMS: cacheRebuildStartMS
                )
            #endif
            guard rootGenerationsStillMatch(expectedRootGenerations) else { return [] }
        } else {
            initialRootLookupByRoot = [:]
        }

        if requests.isEmpty {
            if purpose == .initialRootLoad {
                pruneInitialRootCaches(
                    forRoots: rootsForRebuild,
                    keepingRelativePathsByRoot: initialRootRelativePathsByRoot,
                    expectedRootGenerations: expectedRootGenerations
                )
                clearRebuildLookups(forRoots: rootsForRebuild)
                if queue.isEmpty, activeScans == 0 { performCacheCleanup() }
            }
            return []
        }

        var requestsToQueue = [ScanRequest]()
        var seenSelfHealingFileIDs = Set<UUID>()

        for request in requests {
            let rootKey = canonicalRoot(request.rootFolderPath)

            // Self-healing never replaces queued or active work: it only submits genuinely idle files.
            if purpose == .selfHealing {
                guard seenSelfHealingFileIDs.insert(request.fileID).inserted,
                      !hasQueuedOrActiveScan(for: request.fileID)
                else { continue }
            } else {
                // Ad hoc scans may skip unchanged files; initial loads must requeue them.
                if purpose == .adhoc,
                   let knownDate = latestFileModDates[request.fileID],
                   knownDate >= request.modificationDate
                {
                    continue
                }
                removeQueuedRequest(for: request.fileID)
            }

            latestFileModDates[request.fileID] = request.modificationDate
            trackFileID(request.fileID, forRootKey: rootKey)
            requestsToQueue.append(request)
        }

        if requestsToQueue.isEmpty {
            if purpose == .initialRootLoad {
                pruneInitialRootCaches(
                    forRoots: rootsForRebuild,
                    keepingRelativePathsByRoot: initialRootRelativePathsByRoot,
                    expectedRootGenerations: expectedRootGenerations
                )
                clearRebuildLookups(forRoots: rootsForRebuild)
                if queue.isEmpty, activeScans == 0 { performCacheCleanup() }
            } else if queue.isEmpty, activeScans == 0 {
                evictCleanIdleRootCachesIfNeeded()
            }
            return []
        }

        let submittedFileIDs = Set(requestsToQueue.map(\.fileID))
        var droppedFileIDs = Set<UUID>()

        // Determine how many of these requests are for new files.
        let newFilesCount = requestsToQueue.count(where: { !acceptedAPIFileIDs.contains($0.fileID) })

        // Only bump totalScheduled for new files;
        // outstandingScans counts all scan requests (new or rescan).
        totalScheduled += newFilesCount
        outstandingScans += requestsToQueue.count
        CodeMapPerfRuntime.sharedPipelineStats?.increment(\.requestsEnqueued, by: requestsToQueue.count)
        pushProgressUpdate()

        if purpose != .initialRootLoad {
            await prefetchRootCachesIfNeeded(forRootKeys: rootsForRebuild)
        }

        var finalQueue = [ScanRequest]()
        var droppedRequests = 0
        finalQueue.reserveCapacity(requestsToQueue.count)
        #if DEBUG
            let cacheCheckStartMS = purpose == .initialRootLoad ? CodeMapInitialRootLoadDiagnostics.start() : nil
        #endif
        for request in requestsToQueue {
            let rootKey = canonicalRoot(request.rootFolderPath)
            let expectedGeneration = expectedRootGenerations[rootKey]
            guard rootGenerationMatches(rootKey: rootKey, expected: expectedGeneration) else {
                removeTrackingForDroppedRequest(request)
                droppedFileIDs.insert(request.fileID)
                droppedRequests += 1
                continue
            }

            switch await checkCacheAndHandleResult(
                for: request,
                expectedRootGeneration: expectedGeneration,
                initialRootLookupFiles: initialRootLookupByRoot[rootKey],
                removeStaleCacheEntryOnMiss: purpose == .initialRootLoad
            ) {
            case .hit:
                break
            case .miss:
                finalQueue.append(request)
            case .staleRoot:
                removeTrackingForDroppedRequest(request)
                droppedFileIDs.insert(request.fileID)
                droppedRequests += 1
            }
        }

        let queueableRequests = finalQueue.filter { request in
            let rootKey = canonicalRoot(request.rootFolderPath)
            let shouldQueue = rootGenerationMatches(rootKey: rootKey, expected: expectedRootGenerations[rootKey])
            if !shouldQueue {
                removeTrackingForDroppedRequest(request)
                droppedFileIDs.insert(request.fileID)
            }
            return shouldQueue
        }
        droppedRequests += finalQueue.count - queueableRequests.count
        #if DEBUG
            if purpose == .initialRootLoad {
                CodeMapInitialRootLoadDiagnostics.cacheCheck(
                    requestCount: requestsToQueue.count,
                    queueableRequests: queueableRequests.count,
                    droppedRequests: droppedRequests,
                    startMS: cacheCheckStartMS
                )
            }
        #endif
        if droppedRequests > 0 {
            outstandingScans = max(outstandingScans - droppedRequests, 0)
            pushProgressUpdate()
        }

        if purpose == .initialRootLoad {
            #if DEBUG
                let pruneStartMS = CodeMapInitialRootLoadDiagnostics.start()
            #endif
            pruneInitialRootCaches(
                forRoots: rootsForRebuild,
                keepingRelativePathsByRoot: initialRootRelativePathsByRoot,
                expectedRootGenerations: expectedRootGenerations
            )
            #if DEBUG
                CodeMapInitialRootLoadDiagnostics.prune(
                    rootCount: rootsForRebuild.count,
                    startMS: pruneStartMS
                )
            #endif
        }

        if !queueableRequests.isEmpty {
            #if DEBUG
                let enqueueStartMS = purpose == .initialRootLoad ? CodeMapInitialRootLoadDiagnostics.start() : nil
            #endif
            queue.append(contentsOf: queueableRequests)
            pushProgressUpdate()
            scheduleNextScan()
            #if DEBUG
                if purpose == .initialRootLoad {
                    CodeMapInitialRootLoadDiagnostics.enqueue(
                        queueableRequests: queueableRequests.count,
                        startMS: enqueueStartMS
                    )
                }
            #endif
        }

        if purpose == .initialRootLoad {
            clearRebuildLookups(forRoots: rootsForRebuild)
            if queueableRequests.isEmpty, queue.isEmpty, activeScans == 0 {
                performCacheCleanup()
            }
        } else if queueableRequests.isEmpty, queue.isEmpty, activeScans == 0 {
            evictCleanIdleRootCachesIfNeeded()
        }
        return submittedFileIDs.subtracting(droppedFileIDs)
    }

    func requestSelfHealingScans(
        _ requests: [ScanRequest],
        rootFolderPaths: [String] = [],
        existingScanModificationDatesByFileID: [UUID: Date] = [:]
    ) async -> SelfHealingScanRequestResult {
        let requestedFileIDs = Set(requests.map(\.fileID))
        let alreadyScheduledFileIDs = Set(requestedFileIDs.filter { fileID in
            if hasQueuedOrActiveScan(for: fileID)
                || resultBatchBuffer.contains(where: { $0.fileID == fileID })
                || resultDeliveryPendingFileIDs.contains(fileID)
            {
                return true
            }
            guard acceptedAPIFileIDs.contains(fileID),
                  let expectedModificationDate = existingScanModificationDatesByFileID[fileID],
                  let latestModificationDate = latestFileModDates[fileID]
            else { return false }
            return latestModificationDate >= expectedModificationDate
        })
        let submittedFileIDs = await requestScans(
            requests.filter { !alreadyScheduledFileIDs.contains($0.fileID) },
            purpose: .selfHealing,
            rootFolderPaths: rootFolderPaths
        )
        return SelfHealingScanRequestResult(
            submittedFileIDs: submittedFileIDs,
            alreadyScheduledFileIDs: alreadyScheduledFileIDs
        )
    }

    // -------------------------------------------------------
    // MARK: 6) Non-isolated wrappers for backward-compatible calls

    /// -------------------------------------------------------
    nonisolated func requestScan(_ request: ScanRequest) {
        Task { await self.requestScan(request) }
    }

    nonisolated func requestScans(
        _ requests: [ScanRequest],
        purpose: ScanBatchPurpose = .adhoc,
        rootFolderPaths: [String] = [],
        purgeCachesOnEmptyInitialRequests: Bool = false
    ) {
        Task {
            await self.requestScans(
                requests,
                purpose: purpose,
                rootFolderPaths: rootFolderPaths,
                purgeCachesOnEmptyInitialRequests: purgeCachesOnEmptyInitialRequests
            )
        }
    }

    // -------------------------------------------------------
    // MARK: 7) Scheduling & finishing scans

    /// -------------------------------------------------------
    private func scheduleNextScan() {
        // Pump the queue without recursion.
        // - Drains oversized files inline (so we don't build a deep call stack).
        // - Starts as many scans as we have capacity for (up to maxConcurrentScans).
        while activeScans < maxConcurrentScans, !queue.isEmpty {
            let request = queue.removeFirst()

            if let oversizeReason = SyntaxManager.shared.parsingOversizeReason(for: request.content) {
                CodeMapPerfRuntime.sharedPipelineStats?.increment(\.oversizedSkips)
                handleOversizedRequest(request, reason: oversizeReason)
                continue
            }

            activeScans += 1
            pushProgressUpdate()

            let uniqueTaskID = UUID()
            let treeSitterParseLimiter = treeSitterParseLimiter
            #if DEBUG
                let scanWillStartHandlerForTesting = scanWillStartHandlerForTesting
            #endif
            let scanTask = Task<Void, Never> { [request, treeSitterParseLimiter] in
                var fileAPI: FileAPI?
                do {
                    #if DEBUG
                        await scanWillStartHandlerForTesting?(request.fileID)
                    #endif
                    try Task.checkCancellation()
                    let parseStart = CodeMapPerfRuntime.sharedPipelineStats.map { _ in CodeMapPerfRuntime.currentTime() }
                    let namedRanges = try await treeSitterParseLimiter.withPermit {
                        try Task.checkCancellation()
                        return try? SyntaxManager.shared.codeMap(
                            content: request.content,
                            fileExtension: request.fileExtension
                        )
                    }
                    if let parseStart {
                        CodeMapPerfRuntime.sharedPipelineStats?.addDuration(\.parseAndQueryDuration, CodeMapPerfRuntime.durationSince(parseStart))
                    }
                    if namedRanges == nil {
                        CodeMapPerfRuntime.sharedPipelineStats?.increment(\.parseFailures)
                    }
                    try Task.checkCancellation()
                    let generatorStart = CodeMapPerfRuntime.sharedPipelineStats.map { _ in CodeMapPerfRuntime.currentTime() }
                    let generatorStats = CodeMapPerfRuntime.makeGeneratorStats()
                    fileAPI = CodeMapGenerator.generateCodeMap(
                        from: namedRanges ?? [],
                        content: request.content,
                        fullPath: request.fullPath,
                        perfOptions: CodeMapPerfRuntime.makeGeneratorOptions(),
                        perfStats: generatorStats
                    )
                    if let generatorStats {
                        CodeMapPerfRuntime.sharedPipelineStats?.mergeGeneratorStats(generatorStats)
                    }
                    if let generatorStart {
                        CodeMapPerfRuntime.sharedPipelineStats?.addDuration(\.generatorDuration, CodeMapPerfRuntime.durationSince(generatorStart))
                    }
                    if fileAPI == nil {
                        CodeMapPerfRuntime.sharedPipelineStats?.increment(\.nilAPIs)
                    } else {
                        CodeMapPerfRuntime.sharedPipelineStats?.increment(\.generatedAPIs)
                    }
                } catch {
                    fileAPI = nil
                    CodeMapPerfRuntime.sharedPipelineStats?.increment(\.nilAPIs)
                }
                self.finishScan(uniqueID: uniqueTaskID, request: request, fileAPI: fileAPI)
            }
            let record = ScanningTask(id: uniqueTaskID, request: request, task: scanTask)
            scanTasks.insert(record)
        }

        // If we've drained the queue and no scans are running, flush caches/results.
        if queue.isEmpty, activeScans == 0 {
            performCacheCleanup()
        }
    }

    private func handleOversizedRequest(_ request: ScanRequest, reason: SyntaxManager.ParseOversizeReason) {
        codeScanActorDebugLog("Skipping code map for oversized file: \(request.relativePath) - \(reason)")
        acceptedAPIFileIDs.remove(request.fileID)
        let rootKey = canonicalRoot(request.rootFolderPath)
        if var rootEntry = rootCaches[rootKey] {
            if rootEntry.files.removeValue(forKey: request.relativePath) != nil {
                rootCaches[rootKey] = rootEntry
                dirtyRootFoldersForDisk.insert(rootKey)
            }
        }
        outstandingScans = max(outstandingScans - 1, 0)
        resultBatchBuffer.append(ScanResult(request: request, fileAPI: nil))
        maybeFlushResultsIfNeeded()
        pushProgressUpdate()
    }

    // Modified: use size-aware flushing instead of always scheduling
    private func finishScan(
        uniqueID: UUID,
        request: ScanRequest,
        fileAPI: FileAPI?
    ) {
        guard let st = scanTasks.first(where: { $0.id == uniqueID }) else { return }
        scanTasks.remove(st)
        activeScans = max(activeScans - 1, 0)

        // Persist successful scan results into the actor-owned cache
        if let fileAPI {
            acceptedAPIFileIDs.insert(request.fileID)

            // Update the in-memory root cache
            let rootKey = canonicalRoot(request.rootFolderPath)
            var rootEntry = rootCaches[rootKey] ?? CodeMapCacheRootFolder(files: [:])
            rootEntry.files[request.relativePath] = CodeMapCacheFileEntry(
                modificationDate: request.modificationDate,
                contentFingerprint: CodeMapContentFingerprint(content: request.content),
                fileAPI: fileAPI
            )
            rootCaches[rootKey] = rootEntry

            // Mark this root as needing a disk flush
            dirtyRootFoldersForDisk.insert(rootKey)
        }

        outstandingScans = max(outstandingScans - 1, 0)

        resultBatchBuffer.append(ScanResult(request: request, fileAPI: fileAPI))
        maybeFlushResultsIfNeeded()

        pushProgressUpdate()
        scheduleNextScan()
    }

    // -------------------------------------------------------
    // MARK: 8) Cancel everything

    /// -------------------------------------------------------
    func cancelAllScans() {
        advanceRootGenerations(forRootKeys: knownRootKeys())
        cancelAllRootCacheLoads()

        for st in scanTasks {
            st.task.cancel()
        }
        scanTasks.removeAll()
        queue.removeAll()
        activeScans = 0
        outstandingScans = 0
        totalScheduled = 0
        cacheProcessingCount = 0
        rebuildLookupByRoot.removeAll()

        // Flush dirty caches to disk so we don't lose recent work
        performCacheCleanup()
        pushProgressUpdate()
    }

    /// Clears all cached code maps for all root folders
    func clearAllCaches(rootFolders: [String]) {
        let rootsToInvalidate = knownRootKeys().union(rootFolders.map { canonicalRoot($0) })
        advanceRootGenerations(forRootKeys: rootsToInvalidate)

        // Remove cache for each root folder (disk)
        for rootPath in rootFolders {
            cacheManager.removeRootFolder(canonicalRoot(rootPath))
        }
        // Clear the in-memory caches
        cancelAllRootCacheLoads()
        acceptedAPIFileIDs.removeAll()
        latestFileModDates.removeAll()
        fileIDsByRoot.removeAll()
        rootKeyByFileID.removeAll()
        rootCaches.removeAll()
        dirtyRootFoldersForDisk.removeAll()
        rebuildLookupByRoot.removeAll()
    }

    /// Removes on-disk caches for roots that no longer exist in any workspace.
    func purgeStaleRootCaches(keepingRootPaths: [String]) {
        let keepRoots = Set(keepingRootPaths.map { canonicalRoot($0) })
        let staleTrackedRoots = Set(fileIDsByRoot.keys).subtracting(keepRoots)
        let staleKnownRoots = knownRootKeys().subtracting(keepRoots)
        advanceRootGenerations(forRootKeys: staleKnownRoots)
        removeTrackedFiles(forRootKeys: staleTrackedRoots)

        let staleLoadingRoots = Set(rootCacheLoadTasks.keys).subtracting(keepRoots)
        cancelRootCacheLoads(forRootKeys: staleLoadingRoots)

        for rootKey in Array(rootCaches.keys) where !keepRoots.contains(rootKey) {
            rootCaches.removeValue(forKey: rootKey)
            dirtyRootFoldersForDisk.remove(rootKey)
            rebuildLookupByRoot.removeValue(forKey: rootKey)
        }

        cacheManager.purgeStaleRootCaches(keepingRootPaths: Array(keepRoots))
    }

    // -------------------------------------------------------
    // MARK: 9) Progress logic (2-second debounce, no early flush)

    /// -------------------------------------------------------
    private func pushProgressUpdate() {
        // Always store the latest progress in `pendingProgress`
        let newRemaining = queue.count + activeScans
        let totalActive = newRemaining + cacheProcessingCount
        let finalProgress = (totalActive, totalScheduled)

        pendingProgress = finalProgress

        // If the last flush was more than 2 seconds ago,
        // flush immediately instead of scheduling again.
        let now = Date()
        if now.timeIntervalSince(lastProgressFlushTime) >= 2.0 {
            flushProgressUpdate()
        } else {
            // Otherwise, cancel any existing coalescing task
            // and schedule a new flush for 2s from now.
            progressCoalescingTask?.cancel()
            progressCoalescingTask = Task {
                do {
                    try await Task.sleep(nanoseconds: progressCoalescingDelay)
                    try Task.checkCancellation()
                    flushProgressUpdate()
                } catch {
                    // Canceled, do nothing.
                }
            }
        }
    }

    private func flushProgressUpdate() {
        guard let progress = pendingProgress else { return }
        pendingProgress = nil

        // Only yield if there's an actual change from last time
        if let last = lastKnownProgress, last == progress {
            return
        }

        for continuation in progressContinuations.values {
            continuation.yield(progress)
        }

        lastKnownProgress = progress
        lastProgressFlushTime = Date() // Store the last flush time
        progressCoalescingTask = nil
    }

    // -------------------------------------------------------
    // MARK: 10) Batched result logic

    // -------------------------------------------------------
    // New: size-aware batch flush (falls back to existing 2s debounce)
    private func maybeFlushResultsIfNeeded() {
        if resultBatchBuffer.count >= resultsImmediateFlushThreshold {
            flushResultBatch()
        } else {
            scheduleBatchedResultFlush()
        }
    }

    private func scheduleBatchedResultFlush() {
        resultsCoalescingTask?.cancel()

        lastResultsScheduleCall = .now()

        resultsCoalescingTask = Task {
            do {
                try await Task.sleep(nanoseconds: resultsCoalescingDelay)
                try Task.checkCancellation()
                flushResultBatch()
            } catch {
                // Task was canceled, so simply exit.
            }
        }
    }

    private func flushResultBatch() {
        guard !resultBatchBuffer.isEmpty else { return }

        let batch = resultBatchBuffer
        resultBatchBuffer.removeAll()
        resultDeliveryPendingFileIDs.formUnion(batch.map(\.fileID))
        CodeMapPerfRuntime.sharedPipelineStats?.recordResultBatch(size: batch.count)

        for continuation in resultContinuations.values {
            continuation.yield(batch)
        }
        resultsCoalescingTask = nil
    }

    func acknowledgeScanResults(fileIDs: some Sequence<UUID>) {
        resultDeliveryPendingFileIDs.subtract(fileIDs)
    }

    // -------------------------------------------------------
    // MARK: 11) Final cleanup

    /// -------------------------------------------------------
    private func performCacheCleanup() {
        // Flush dirty roots to disk
        if !dirtyRootFoldersForDisk.isEmpty {
            for rootPath in Array(dirtyRootFoldersForDisk) {
                guard let rootEntry = rootCaches[rootPath] else { continue }
                let saveStart = Date()
                if cacheManager.saveRootFolderCache(rootPath, rootEntry: rootEntry) {
                    #if DEBUG
                        rootCacheDiskSaveCount += 1
                        rootCacheDiskSaveDuration += Date().timeIntervalSince(saveStart)
                        rootCacheDiskSaveFileEntryCount += rootEntry.files.count
                    #endif
                    dirtyRootFoldersForDisk.remove(rootPath)
                }
            }
        }

        // Ensure any pending result batches get delivered
        flushResultBatch()
        evictCleanIdleRootCachesIfNeeded()
    }

    // -------------------------------------------------------
    // MARK: 12) Cache rebuild helpers

    /// -------------------------------------------------------
    private func prepareCacheRebuild(forRoots roots: Set<String>) async -> [String: [String: CodeMapCacheFileEntry]] {
        guard !roots.isEmpty else { return [:] }

        var lookupByRoot: [String: [String: CodeMapCacheFileEntry]] = [:]
        lookupByRoot.reserveCapacity(roots.count)
        for rootKey in roots {
            let existing = await ensureRootCacheLoaded(forRootKey: rootKey)
            lookupByRoot[rootKey] = existing?.files ?? [:]
        }
        return lookupByRoot
    }

    private func initialRootRelativePathSets(for requests: [ScanRequest]) -> [String: Set<String>] {
        requests.reduce(into: [String: Set<String>]()) { result, request in
            let rootKey = canonicalRoot(request.rootFolderPath)
            result[rootKey, default: []].insert(request.relativePath)
        }
    }

    private func pruneInitialRootCaches(
        forRoots roots: Set<String>,
        keepingRelativePathsByRoot relativePathsByRoot: [String: Set<String>],
        expectedRootGenerations: [String: UInt64]
    ) {
        guard !roots.isEmpty else { return }

        for rootKey in roots {
            guard rootGenerationMatches(rootKey: rootKey, expected: expectedRootGenerations[rootKey]),
                  var rootEntry = rootCaches[rootKey],
                  !rootEntry.files.isEmpty
            else {
                continue
            }

            let relativePathsToKeep = relativePathsByRoot[rootKey] ?? []
            let originalCount = rootEntry.files.count
            rootEntry.files = rootEntry.files.filter { relativePathsToKeep.contains($0.key) }
            guard rootEntry.files.count != originalCount else { continue }

            rootCaches[rootKey] = rootEntry
            dirtyRootFoldersForDisk.insert(rootKey)
        }
    }

    private func clearRebuildLookups(forRoots roots: Set<String>) {
        for rootKey in roots {
            rebuildLookupByRoot.removeValue(forKey: rootKey)
        }
    }

    private func trackFileID(_ fileID: UUID, forRootKey rootKey: String) {
        if let previousRootKey = rootKeyByFileID[fileID], previousRootKey != rootKey {
            fileIDsByRoot[previousRootKey]?.remove(fileID)
            if fileIDsByRoot[previousRootKey]?.isEmpty == true {
                fileIDsByRoot.removeValue(forKey: previousRootKey)
            }
        }

        rootKeyByFileID[fileID] = rootKey
        fileIDsByRoot[rootKey, default: []].insert(fileID)
    }

    private func removeTrackedFiles(forRootKeys rootKeys: some Sequence<String>) {
        for rootKey in rootKeys {
            guard let fileIDs = fileIDsByRoot.removeValue(forKey: rootKey) else { continue }
            for fileID in fileIDs {
                if rootKeyByFileID[fileID] == rootKey {
                    rootKeyByFileID.removeValue(forKey: fileID)
                }
                acceptedAPIFileIDs.remove(fileID)
                latestFileModDates.removeValue(forKey: fileID)
                resultDeliveryPendingFileIDs.remove(fileID)
            }
        }
    }

    private func canonicalRoot(_ rootPath: String) -> String {
        (rootPath as NSString).standardizingPath
    }

    #if DEBUG
        func codemapMemoryCounters() -> CodemapMemoryCounters {
            let trackedFileIDCount = fileIDsByRoot.values.reduce(0) { $0 + $1.count }
            let rootCacheFileEntryCount = rootCaches.values.reduce(0) { $0 + $1.files.count }
            let rebuildLookupFileEntryCount = rebuildLookupByRoot.values.reduce(0) { $0 + $1.count }
            let resultBatchBufferFileAPICount = resultBatchBuffer.reduce(0) { partial, result in
                partial + (result.fileAPI == nil ? 0 : 1)
            }
            let actorRetainedFileAPILikeEntryCount = rootCacheFileEntryCount
                + rebuildLookupFileEntryCount
                + resultBatchBufferFileAPICount

            return CodemapMemoryCounters(
                fileAPIEntryCount: 0,
                latestFileModDateCount: latestFileModDates.count,
                trackedRootCount: fileIDsByRoot.count,
                trackedFileIDCount: trackedFileIDCount,
                rootKeyByFileIDCount: rootKeyByFileID.count,
                rootCacheRootCount: rootCaches.count,
                rootCacheFileEntryCount: rootCacheFileEntryCount,
                dirtyRootCount: dirtyRootFoldersForDisk.count,
                rootCacheLoadTaskCount: rootCacheLoadTasks.count,
                rebuildLookupRootCount: rebuildLookupByRoot.count,
                rebuildLookupFileEntryCount: rebuildLookupFileEntryCount,
                queuedCount: queue.count,
                activeScanCount: activeScans,
                outstandingScanCount: outstandingScans,
                totalScheduledCount: totalScheduled,
                cacheProcessingCount: cacheProcessingCount,
                resultBatchBufferCount: resultBatchBuffer.count,
                resultBatchBufferFileAPICount: resultBatchBufferFileAPICount,
                actorRetainedFileAPILikeEntryCount: actorRetainedFileAPILikeEntryCount
            )
        }

        func setScanWillStartHandlerForTesting(
            _ handler: (@Sendable (UUID) async -> Void)?
        ) {
            scanWillStartHandlerForTesting = handler
        }

        func scanStateForTesting() -> (
            acceptedAPIFileIDCount: Int,
            latestFileModDateCount: Int,
            trackedRoots: [String: Int],
            queueCount: Int,
            activeScanCount: Int,
            outstandingScanCount: Int
        ) {
            (
                acceptedAPIFileIDs.count,
                latestFileModDates.count,
                fileIDsByRoot.mapValues(\.count),
                queue.count,
                activeScans,
                outstandingScans
            )
        }

        func installCacheEntryForTesting(
            rootFolderPath: String,
            relativePath: String,
            entry: CodeMapCacheFileEntry
        ) {
            let rootKey = canonicalRoot(rootFolderPath)
            var rootEntry = rootCaches[rootKey] ?? CodeMapCacheRootFolder(files: [:])
            rootEntry.files[relativePath] = entry
            rootCaches[rootKey] = rootEntry
            dirtyRootFoldersForDisk.insert(rootKey)
        }

        func flushCachesForTesting() {
            performCacheCleanup()
        }

        func appendBufferedResultForTesting(_ request: ScanRequest, fileAPI: FileAPI?) {
            resultBatchBuffer.append(ScanResult(request: request, fileAPI: fileAPI))
        }

        func flushResultBatchForTesting() {
            flushResultBatch()
        }

        func resultContinuationCountForTesting() -> Int {
            resultContinuations.count
        }

        func resultBatchBufferCountForTesting() -> Int {
            resultBatchBuffer.count
        }

        struct RootCacheDiskLoadCounters {
            let count: Int
            let duration: TimeInterval
            let loadedFileEntryCount: Int
        }

        struct RootCacheDiskSaveCounters {
            let count: Int
            let duration: TimeInterval
            let savedFileEntryCount: Int
        }

        func rootCacheDiskLoadCountersForTesting() -> RootCacheDiskLoadCounters {
            RootCacheDiskLoadCounters(
                count: rootCacheDiskLoadCount,
                duration: rootCacheDiskLoadDuration,
                loadedFileEntryCount: rootCacheDiskLoadFileEntryCount
            )
        }

        func resetRootCacheDiskLoadCountersForTesting() {
            rootCacheDiskLoadCount = 0
            rootCacheDiskLoadDuration = 0
            rootCacheDiskLoadFileEntryCount = 0
        }

        func rootCacheDiskSaveCountersForTesting() -> RootCacheDiskSaveCounters {
            RootCacheDiskSaveCounters(
                count: rootCacheDiskSaveCount,
                duration: rootCacheDiskSaveDuration,
                savedFileEntryCount: rootCacheDiskSaveFileEntryCount
            )
        }

        func resetRootCacheDiskSaveCountersForTesting() {
            rootCacheDiskSaveCount = 0
            rootCacheDiskSaveDuration = 0
            rootCacheDiskSaveFileEntryCount = 0
        }

        func treeSitterParseLimiterMaxObservedPermitsForTesting() async -> Int {
            await treeSitterParseLimiter.maxObservedPermitsForTesting()
        }
    #endif
}
