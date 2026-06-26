import Foundation

/// Actor-owned workspace path-search facade built from immutable root catalog shards.
///
/// Each catalog shard owns one immutable C `PathSearchIndex`. Scope generations retain the
/// relevant root-index references, and searches merge root-local candidates into the exact
/// historical global rank order without rebuilding or mutating a shared C index.
actor WorkspaceSearchService {
    private struct PreparedIndex {
        let generation: UInt64
        let diagnostics: WorkspaceCatalogDiagnostics
        let rootPathIndexes: [WorkspaceSearchRootPathIndex]
        let entryCount: Int
        #if DEBUG
            let orderMicroseconds: UInt64
            let materializationMicroseconds: UInt64
            let cIndexBuildMicroseconds: UInt64
            let totalMicroseconds: UInt64
        #endif
    }

    private struct RankedCandidateCursor {
        let rootIndex: Int
        let candidateIndex: Int
    }

    private struct EntryCursor {
        let rootIndex: Int
        let entryIndex: Int
    }

    private var readyRootPathIndexes: [WorkspaceSearchRootPathIndex] = []
    private var currentSnapshotGeneration: UInt64?
    private var currentIndexedGeneration: UInt64?
    private var currentDiagnostics: WorkspaceCatalogDiagnostics?
    private var latestObservedCatalogGeneration: UInt64?
    private var pendingRebuildGeneration: UInt64?
    private var activeRebuildGeneration: UInt64?
    private var rebuildSerial: UInt64 = 0
    private var appliedIndexListenerTask: Task<Void, Never>?
    private var pendingRebuildTask: Task<Void, Never>?
    private var automaticIndexBuildDelayNanoseconds: UInt64
    private var discardedAutomaticRebuildCompletions = 0
    private var isReadyIndexUsable = true
    #if DEBUG
        struct RebuildWorkDiagnosticsSnapshot: Equatable {
            let rebuildCount: Int
            let orderMicroseconds: UInt64
            let materializationMicroseconds: UInt64
            let cIndexBuildMicroseconds: UInt64
            let totalMicroseconds: UInt64
            let debounceCancellationCount: Int
            let staleDiscardedCount: Int
            let lastEntryCount: Int
        }

        private var debugRebuildCount = 0
        private var debugOrderMicroseconds: UInt64 = 0
        private var debugMaterializationMicroseconds: UInt64 = 0
        private var debugCIndexBuildMicroseconds: UInt64 = 0
        private var debugTotalMicroseconds: UInt64 = 0
        private var debugDebounceCancellationCount = 0
        private var debugLastEntryCount = 0
        private var searchDidCaptureGenerationHandler: (@Sendable (UInt64?) async -> Void)?
    #endif

    init(automaticIndexBuildDelayNanoseconds: UInt64 = 0) {
        self.automaticIndexBuildDelayNanoseconds = automaticIndexBuildDelayNanoseconds
    }

    deinit {
        appliedIndexListenerTask?.cancel()
        pendingRebuildTask?.cancel()
    }

    var indexedGeneration: UInt64? {
        currentIndexedGeneration
    }

    var snapshotGeneration: UInt64? {
        currentSnapshotGeneration
    }

    var diagnostics: WorkspaceCatalogDiagnostics? {
        currentDiagnostics
    }

    var indexedPathCount: Int {
        readyRootPathIndexes.reduce(0) { $0 + $1.count }
    }

    var pendingGeneration: UInt64? {
        pendingRebuildGeneration ?? activeRebuildGeneration
    }

    var observedCatalogGeneration: UInt64? {
        latestObservedCatalogGeneration
    }

    var discardedStaleRebuildCount: Int {
        discardedAutomaticRebuildCompletions
    }

    #if DEBUG
        func workDiagnosticsSnapshot() -> RebuildWorkDiagnosticsSnapshot {
            RebuildWorkDiagnosticsSnapshot(
                rebuildCount: debugRebuildCount,
                orderMicroseconds: debugOrderMicroseconds,
                materializationMicroseconds: debugMaterializationMicroseconds,
                cIndexBuildMicroseconds: debugCIndexBuildMicroseconds,
                totalMicroseconds: debugTotalMicroseconds,
                debounceCancellationCount: debugDebounceCancellationCount,
                staleDiscardedCount: discardedAutomaticRebuildCompletions,
                lastEntryCount: debugLastEntryCount
            )
        }

        func setSearchDidCaptureGenerationHandler(
            _ handler: (@Sendable (UInt64?) async -> Void)?
        ) {
            searchDidCaptureGenerationHandler = handler
        }

        static func authoritativeGlobalResultsForTesting(
            from snapshot: WorkspaceSearchCatalogSnapshot,
            query: String,
            limit: Int
        ) -> [WorkspaceSearchCatalogEntry] {
            let boundedLimit = max(0, limit)
            guard boundedLimit > 0 else { return [] }
            let orderedEntries = orderEntries(snapshot.entries)
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return Array(orderedEntries.prefix(boundedLimit))
            }
            let index = PathSearchIndex(paths: orderedEntries.map(\.pathSearchIndexKey))
            return index.searchSynchronously(trimmed, limit: boundedLimit).compactMap { candidate in
                guard orderedEntries.indices.contains(candidate.index) else { return nil }
                return orderedEntries[candidate.index]
            }
        }
    #endif

    func startKeepingFresh(
        with store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope = .visibleWorkspace,
        debounceNanoseconds: UInt64 = 50_000_000
    ) async {
        appliedIndexListenerTask?.cancel()
        let stream = await store.appliedIndexEvents()
        appliedIndexListenerTask = Task { [weak self, store] in
            for await event in stream {
                await self?.handleAppliedIndexEvent(
                    event,
                    store: store,
                    rootScope: rootScope,
                    debounceNanoseconds: debounceNanoseconds
                )
            }
        }

        let catalogGeneration = await store.catalogGeneration(rootScope: rootScope)
        latestObservedCatalogGeneration = catalogGeneration
        if catalogGeneration != currentIndexedGeneration,
           catalogGeneration != pendingRebuildGeneration,
           catalogGeneration != activeRebuildGeneration
        {
            scheduleRebuild(
                from: store,
                rootScope: rootScope,
                targetGeneration: catalogGeneration,
                debounceNanoseconds: 0
            )
        }
    }

    func stopKeepingFresh() {
        appliedIndexListenerTask?.cancel()
        appliedIndexListenerTask = nil
        pendingRebuildTask?.cancel()
        pendingRebuildTask = nil
        pendingRebuildGeneration = nil
        activeRebuildGeneration = nil
    }

    @discardableResult
    func rebuildIndex(from snapshot: WorkspaceSearchCatalogSnapshot) async -> UInt64 {
        rebuildSerial &+= 1
        let serial = rebuildSerial
        pendingRebuildTask?.cancel()
        pendingRebuildTask = nil
        pendingRebuildGeneration = nil
        activeRebuildGeneration = snapshot.generation
        latestObservedCatalogGeneration = snapshot.generation

        let prepared = Self.prepareIndex(from: snapshot)
        #if DEBUG
            recordPreparedIndexWork(prepared)
        #endif
        guard serial == rebuildSerial, !Task.isCancelled else {
            activeRebuildGeneration = nil
            return currentIndexedGeneration ?? snapshot.generation
        }
        commit(prepared)
        activeRebuildGeneration = nil
        return snapshot.generation
    }

    @discardableResult
    func prepareIndex(from snapshot: WorkspaceSearchCatalogSnapshot) async -> UInt64 {
        await rebuildIndex(from: snapshot)
    }

    func reset() async {
        rebuildSerial &+= 1
        appliedIndexListenerTask?.cancel()
        appliedIndexListenerTask = nil
        pendingRebuildTask?.cancel()
        pendingRebuildTask = nil
        readyRootPathIndexes = []
        currentSnapshotGeneration = nil
        currentIndexedGeneration = nil
        currentDiagnostics = nil
        latestObservedCatalogGeneration = nil
        pendingRebuildGeneration = nil
        activeRebuildGeneration = nil
        isReadyIndexUsable = true
    }

    func search(_ query: String, limit: Int = 300) async -> WorkspaceSearchQueryResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let boundedLimit = max(0, limit)
        let stale = isSearchStale
        let pendingGenerationAtSearchStart = pendingGeneration
        let observedGenerationAtSearchStart = latestObservedCatalogGeneration
        let isReadyIndexUsableAtSearchStart = isReadyIndexUsable
        guard boundedLimit > 0 else {
            return queryResult(query: query, results: [], isStale: stale)
        }

        guard isReadyIndexUsableAtSearchStart, currentIndexedGeneration != nil else {
            return queryResult(query: query, results: [], isStale: stale)
        }

        let rootPathIndexesAtSearchStart = readyRootPathIndexes
        let generationAtSearchStart = currentIndexedGeneration
        let snapshotGenerationAtSearchStart = currentSnapshotGeneration
        #if DEBUG
            if let searchDidCaptureGenerationHandler {
                await searchDidCaptureGenerationHandler(generationAtSearchStart)
            }
        #endif

        let results: [WorkspaceSearchCatalogEntry] = if trimmed.isEmpty {
            Self.mergeRootEntries(rootPathIndexesAtSearchStart, limit: boundedLimit)
        } else {
            await Task.detached {
                Self.searchRootIndexes(
                    rootPathIndexesAtSearchStart,
                    query: trimmed,
                    limit: boundedLimit
                )
            }.value
        }
        return WorkspaceSearchQueryResult(
            query: query,
            indexedGeneration: generationAtSearchStart,
            snapshotGeneration: snapshotGenerationAtSearchStart,
            pendingGeneration: pendingGenerationAtSearchStart,
            observedGeneration: observedGenerationAtSearchStart,
            results: results,
            isIndexReady: generationAtSearchStart != nil && isReadyIndexUsableAtSearchStart,
            isStale: stale
        )
    }

    private var isSearchStale: Bool {
        guard let currentIndexedGeneration else {
            return pendingRebuildGeneration != nil || activeRebuildGeneration != nil || latestObservedCatalogGeneration != nil
        }
        if let latestObservedCatalogGeneration, latestObservedCatalogGeneration != currentIndexedGeneration {
            return true
        }
        if let pendingRebuildGeneration, pendingRebuildGeneration != currentIndexedGeneration {
            return true
        }
        if let activeRebuildGeneration, activeRebuildGeneration != currentIndexedGeneration {
            return true
        }
        return !isReadyIndexUsable
    }

    private func queryResult(
        query: String,
        results: [WorkspaceSearchCatalogEntry],
        isStale: Bool
    ) -> WorkspaceSearchQueryResult {
        WorkspaceSearchQueryResult(
            query: query,
            indexedGeneration: currentIndexedGeneration,
            snapshotGeneration: currentSnapshotGeneration,
            pendingGeneration: pendingGeneration,
            observedGeneration: latestObservedCatalogGeneration,
            results: results,
            isIndexReady: currentIndexedGeneration != nil && isReadyIndexUsable,
            isStale: isStale
        )
    }

    private func handleAppliedIndexEvent(
        _ event: WorkspaceAppliedIndexBatchEvent,
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope,
        debounceNanoseconds: UInt64
    ) async {
        if event.isRootUnload {
            dropReadyRootIndex(rootID: event.rootID)
        }

        let catalogGeneration = await store.catalogGeneration(rootScope: rootScope)
        latestObservedCatalogGeneration = catalogGeneration
        if catalogGeneration == currentIndexedGeneration,
           pendingRebuildGeneration == nil,
           activeRebuildGeneration == nil
        {
            return
        }
        if catalogGeneration == pendingRebuildGeneration || catalogGeneration == activeRebuildGeneration {
            return
        }
        scheduleRebuild(
            from: store,
            rootScope: rootScope,
            targetGeneration: catalogGeneration,
            debounceNanoseconds: debounceNanoseconds
        )
    }

    private func scheduleRebuild(
        from store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope,
        targetGeneration: UInt64,
        debounceNanoseconds: UInt64
    ) {
        pendingRebuildGeneration = targetGeneration
        #if DEBUG
            if pendingRebuildTask != nil {
                debugDebounceCancellationCount += 1
            }
        #endif
        pendingRebuildTask?.cancel()
        pendingRebuildTask = Task { [weak self, store] in
            if debounceNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: debounceNanoseconds)
                } catch {
                    return
                }
            }
            await self?.rebuildFromStoreIfCurrent(
                store: store,
                rootScope: rootScope,
                targetGeneration: targetGeneration,
                debounceNanoseconds: debounceNanoseconds
            )
        }
    }

    private func rebuildFromStoreIfCurrent(
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope,
        targetGeneration: UInt64,
        debounceNanoseconds: UInt64
    ) async {
        guard pendingRebuildGeneration == targetGeneration || activeRebuildGeneration == targetGeneration else { return }
        pendingRebuildGeneration = nil
        activeRebuildGeneration = targetGeneration
        let snapshot = await store.searchCatalogSnapshot(rootScope: rootScope)
        latestObservedCatalogGeneration = snapshot.generation
        guard snapshot.generation == targetGeneration else {
            activeRebuildGeneration = nil
            scheduleRebuild(
                from: store,
                rootScope: rootScope,
                targetGeneration: snapshot.generation,
                debounceNanoseconds: 0
            )
            return
        }

        if automaticIndexBuildDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: automaticIndexBuildDelayNanoseconds)
        }
        let prepared = Self.prepareIndex(from: snapshot)
        #if DEBUG
            recordPreparedIndexWork(prepared)
        #endif
        guard !Task.isCancelled,
              latestObservedCatalogGeneration == prepared.generation,
              pendingRebuildGeneration == nil || pendingRebuildGeneration == prepared.generation,
              activeRebuildGeneration == prepared.generation
        else {
            discardedAutomaticRebuildCompletions += 1
            if activeRebuildGeneration == prepared.generation {
                activeRebuildGeneration = nil
            }
            return
        }
        commit(prepared)
        activeRebuildGeneration = nil
        pendingRebuildTask = nil
    }

    private func dropReadyRootIndex(rootID: UUID) {
        readyRootPathIndexes.removeAll { $0.identity.rootID == rootID }
    }

    private func commit(_ prepared: PreparedIndex) {
        readyRootPathIndexes = prepared.rootPathIndexes
        currentSnapshotGeneration = prepared.generation
        currentDiagnostics = prepared.diagnostics
        currentIndexedGeneration = prepared.generation
        isReadyIndexUsable = true
    }

    private static func prepareIndex(from snapshot: WorkspaceSearchCatalogSnapshot) -> PreparedIndex {
        #if DEBUG
            let totalStart = DispatchTime.now().uptimeNanoseconds
            let materializationStart = totalStart
        #endif
        let rootPathIndexes = snapshot.rootPathIndexes
        let entryCount = rootPathIndexes.reduce(0) { $0 + $1.count }
        #if DEBUG
            let end = DispatchTime.now().uptimeNanoseconds
            return PreparedIndex(
                generation: snapshot.generation,
                diagnostics: snapshot.diagnostics,
                rootPathIndexes: rootPathIndexes,
                entryCount: entryCount,
                orderMicroseconds: 0,
                materializationMicroseconds: elapsedMicroseconds(since: materializationStart, through: end),
                cIndexBuildMicroseconds: 0,
                totalMicroseconds: elapsedMicroseconds(since: totalStart, through: end)
            )
        #else
            return PreparedIndex(
                generation: snapshot.generation,
                diagnostics: snapshot.diagnostics,
                rootPathIndexes: rootPathIndexes,
                entryCount: entryCount
            )
        #endif
    }

    private static func searchRootIndexes(
        _ rootPathIndexes: [WorkspaceSearchRootPathIndex],
        query: String,
        limit: Int
    ) -> [WorkspaceSearchCatalogEntry] {
        let candidateBatches = rootPathIndexes.map { $0.search(query, limit: limit) }
        var heap: [RankedCandidateCursor] = []
        heap.reserveCapacity(candidateBatches.count)

        func cursorPrecedes(_ lhs: RankedCandidateCursor, _ rhs: RankedCandidateCursor) -> Bool {
            candidatePrecedes(
                candidateBatches[lhs.rootIndex][lhs.candidateIndex],
                candidateBatches[rhs.rootIndex][rhs.candidateIndex]
            )
        }

        func push(_ cursor: RankedCandidateCursor) {
            heap.append(cursor)
            var index = heap.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard cursorPrecedes(heap[index], heap[parent]) else { break }
                heap.swapAt(index, parent)
                index = parent
            }
        }

        func pop() -> RankedCandidateCursor? {
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

        for rootIndex in candidateBatches.indices where !candidateBatches[rootIndex].isEmpty {
            push(RankedCandidateCursor(rootIndex: rootIndex, candidateIndex: 0))
        }

        var seenIDs = Set<UUID>()
        var results: [WorkspaceSearchCatalogEntry] = []
        results.reserveCapacity(limit)
        while results.count < limit, let cursor = pop() {
            let candidate = candidateBatches[cursor.rootIndex][cursor.candidateIndex]
            if seenIDs.insert(candidate.entry.id).inserted {
                results.append(candidate.entry)
            }
            let nextCandidateIndex = cursor.candidateIndex + 1
            if nextCandidateIndex < candidateBatches[cursor.rootIndex].count {
                push(RankedCandidateCursor(rootIndex: cursor.rootIndex, candidateIndex: nextCandidateIndex))
            }
        }
        return results
    }

    private static func mergeRootEntries(
        _ rootPathIndexes: [WorkspaceSearchRootPathIndex],
        limit: Int
    ) -> [WorkspaceSearchCatalogEntry] {
        var heap: [EntryCursor] = []
        heap.reserveCapacity(rootPathIndexes.count)

        func cursorPrecedes(_ lhs: EntryCursor, _ rhs: EntryCursor) -> Bool {
            entryPrecedes(
                rootPathIndexes[lhs.rootIndex].entries[lhs.entryIndex],
                rootPathIndexes[rhs.rootIndex].entries[rhs.entryIndex]
            )
        }

        func push(_ cursor: EntryCursor) {
            heap.append(cursor)
            var index = heap.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard cursorPrecedes(heap[index], heap[parent]) else { break }
                heap.swapAt(index, parent)
                index = parent
            }
        }

        func pop() -> EntryCursor? {
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

        for rootIndex in rootPathIndexes.indices where !rootPathIndexes[rootIndex].entries.isEmpty {
            push(EntryCursor(rootIndex: rootIndex, entryIndex: 0))
        }

        var results: [WorkspaceSearchCatalogEntry] = []
        results.reserveCapacity(limit)
        while results.count < limit, let cursor = pop() {
            results.append(rootPathIndexes[cursor.rootIndex].entries[cursor.entryIndex])
            let nextEntryIndex = cursor.entryIndex + 1
            if nextEntryIndex < rootPathIndexes[cursor.rootIndex].entries.count {
                push(EntryCursor(rootIndex: cursor.rootIndex, entryIndex: nextEntryIndex))
            }
        }
        return results
    }

    private static func candidatePrecedes(
        _ lhs: WorkspaceSearchRootPathIndex.Candidate,
        _ rhs: WorkspaceSearchRootPathIndex.Candidate
    ) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        switch WorkspaceFileContextStore.compareUTF8Binary(lhs.tieBreakKey, rhs.tieBreakKey) {
        case .orderedAscending:
            return true
        case .orderedDescending:
            return false
        case .orderedSame:
            return entryPrecedes(lhs.entry, rhs.entry)
        }
    }

    private static func entryPrecedes(
        _ lhs: WorkspaceSearchCatalogEntry,
        _ rhs: WorkspaceSearchCatalogEntry
    ) -> Bool {
        WorkspaceFileContextStore.searchCatalogEntryPrecedes(lhs, rhs)
    }

    private static func orderEntries(_ entries: [WorkspaceSearchCatalogEntry]) -> [WorkspaceSearchCatalogEntry] {
        entries.sorted(by: entryPrecedes)
    }

    #if DEBUG
        private func recordPreparedIndexWork(_ prepared: PreparedIndex) {
            debugRebuildCount += 1
            debugOrderMicroseconds &+= prepared.orderMicroseconds
            debugMaterializationMicroseconds &+= prepared.materializationMicroseconds
            debugCIndexBuildMicroseconds &+= prepared.cIndexBuildMicroseconds
            debugTotalMicroseconds &+= prepared.totalMicroseconds
            debugLastEntryCount = prepared.entryCount
        }

        private static func elapsedMicroseconds(since start: UInt64, through end: UInt64) -> UInt64 {
            end >= start ? (end - start) / 1000 : 0
        }
    #endif
}
