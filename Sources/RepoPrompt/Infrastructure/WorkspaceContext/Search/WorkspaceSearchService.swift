import Foundation

/// Actor-owned workspace path-search facade built from immutable root catalog shards.
///
/// Each catalog shard owns one immutable C `PathSearchIndex`. Scope generations retain the
/// relevant root-index references, and searches merge root-local candidates into the exact
/// historical global rank order without rebuilding or mutating a shared C index.
actor WorkspaceSearchService {
    private struct RefreshFlightToken: Equatable {
        let bindingEpoch: UInt64
        let rebuildSerial: UInt64
        let targetGeneration: UInt64
    }

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
    private var currentRefreshFlightToken: RefreshFlightToken?
    private weak var boundStore: WorkspaceFileContextStore?
    private var boundRootScope: WorkspaceLookupRootScope?
    private var bindingEpoch: UInt64 = 0
    private var freshnessListenerSerial: UInt64 = 0
    private var isFreshnessListenerRunning = false
    private var catalogChangeListenerTask: Task<Void, Never>?
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
        private var catalogChangeWillHandleHandler: (@Sendable (WorkspaceSearchCatalogChangeEvent) async -> Void)?
        private var projectionNeutralGenerationDidCommitHandler: (@Sendable (UInt64) async -> Void)?
        private var automaticRebuildDidStartHandler: (@Sendable (UInt64) async -> Void)?
        private var automaticRebuildDidCommitHandler: (@Sendable (UInt64) async -> Void)?
    #endif

    init(automaticIndexBuildDelayNanoseconds: UInt64 = 0) {
        self.automaticIndexBuildDelayNanoseconds = automaticIndexBuildDelayNanoseconds
    }

    deinit {
        catalogChangeListenerTask?.cancel()
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

        func setCatalogChangeWillHandleHandler(
            _ handler: (@Sendable (WorkspaceSearchCatalogChangeEvent) async -> Void)?
        ) {
            catalogChangeWillHandleHandler = handler
        }

        func setProjectionNeutralGenerationDidCommitHandler(
            _ handler: (@Sendable (UInt64) async -> Void)?
        ) {
            projectionNeutralGenerationDidCommitHandler = handler
        }

        func setAutomaticRebuildDidStartHandler(
            _ handler: (@Sendable (UInt64) async -> Void)?
        ) {
            automaticRebuildDidStartHandler = handler
        }

        func setAutomaticRebuildDidCommitHandler(
            _ handler: (@Sendable (UInt64) async -> Void)?
        ) {
            automaticRebuildDidCommitHandler = handler
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
        freshnessListenerSerial &+= 1
        let listenerSerial = freshnessListenerSerial
        catalogChangeListenerTask?.cancel()
        catalogChangeListenerTask = nil
        isFreshnessListenerRunning = false
        cancelRefreshFlight()

        let isSameBinding = boundStore === store && boundRootScope == rootScope
        if !isSameBinding {
            bindingEpoch &+= 1
            readyRootPathIndexes = []
            currentSnapshotGeneration = nil
            currentIndexedGeneration = nil
            currentDiagnostics = nil
            latestObservedCatalogGeneration = nil
            isReadyIndexUsable = true
        }
        boundStore = store
        boundRootScope = rootScope
        let epoch = bindingEpoch

        let stream = await store.searchCatalogChangeEvents(rootScope: rootScope)
        guard isCurrentBinding(store: store, rootScope: rootScope, epoch: epoch),
              freshnessListenerSerial == listenerSerial
        else { return }
        isFreshnessListenerRunning = true
        catalogChangeListenerTask = Task { [weak self, weak store] in
            for await event in stream {
                guard !Task.isCancelled, let store else { return }
                await self?.handleSearchCatalogChangeEvent(
                    event,
                    store: store,
                    rootScope: rootScope,
                    epoch: epoch,
                    listenerSerial: listenerSerial,
                    debounceNanoseconds: debounceNanoseconds
                )
            }
        }

        let catalogGeneration = await store.catalogGeneration(rootScope: rootScope)
        guard isCurrentBinding(store: store, rootScope: rootScope, epoch: epoch),
              freshnessListenerSerial == listenerSerial,
              isFreshnessListenerRunning
        else { return }
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
        freshnessListenerSerial &+= 1
        isFreshnessListenerRunning = false
        catalogChangeListenerTask?.cancel()
        catalogChangeListenerTask = nil
        cancelRefreshFlight()
    }

    @discardableResult
    func rebuildIndex(from snapshot: WorkspaceSearchCatalogSnapshot) async -> UInt64 {
        cancelRefreshFlight()
        let serial = rebuildSerial
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
        await reconcileBoundCatalogAfterManualRebuild()
        return snapshot.generation
    }

    @discardableResult
    func prepareIndex(from snapshot: WorkspaceSearchCatalogSnapshot) async -> UInt64 {
        await rebuildIndex(from: snapshot)
    }

    func reset() async {
        cancelRefreshFlight()
        bindingEpoch &+= 1
        freshnessListenerSerial &+= 1
        isFreshnessListenerRunning = false
        catalogChangeListenerTask?.cancel()
        catalogChangeListenerTask = nil
        boundStore = nil
        boundRootScope = nil
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
        let rootPathIndexesAtSearchStart = readyRootPathIndexes
        let generationAtSearchStart = currentIndexedGeneration
        let snapshotGenerationAtSearchStart = currentSnapshotGeneration
        let pendingGenerationAtSearchStart = pendingGeneration
        let pendingRebuildGenerationAtSearchStart = pendingRebuildGeneration
        let activeRebuildGenerationAtSearchStart = activeRebuildGeneration
        let observedGenerationAtSearchStart = latestObservedCatalogGeneration
        let isReadyIndexUsableAtSearchStart = isReadyIndexUsable
        let storeAtSearchStart = boundStore
        let rootScopeAtSearchStart = boundRootScope
        let bindingEpochAtSearchStart = bindingEpoch
        let wasBoundAtSearchStart = rootScopeAtSearchStart != nil

        let results: [WorkspaceSearchCatalogEntry]
        if boundedLimit == 0 || !isReadyIndexUsableAtSearchStart || generationAtSearchStart == nil {
            results = []
        } else {
            #if DEBUG
                if let searchDidCaptureGenerationHandler {
                    await searchDidCaptureGenerationHandler(generationAtSearchStart)
                }
            #endif
            if trimmed.isEmpty {
                for index in rootPathIndexesAtSearchStart {
                    index.recordEmptyQueryShadowParity(limit: boundedLimit)
                }
                results = Self.mergeRootEntries(rootPathIndexesAtSearchStart, limit: boundedLimit)
            } else {
                results = await withTaskGroup(of: [WorkspaceSearchCatalogEntry].self) { group in
                    group.addTask {
                        await Self.searchRootIndexes(
                            rootPathIndexesAtSearchStart,
                            query: trimmed,
                            limit: boundedLimit
                        )
                    }
                    let value = await group.next() ?? []
                    group.cancelAll()
                    return value
                }
            }
        }

        var observedGenerationForResult = observedGenerationAtSearchStart
        var bindingValidationSucceeded = !wasBoundAtSearchStart
        if let storeAtSearchStart, let rootScopeAtSearchStart {
            let wasCancelledBeforeValidation = Task.isCancelled
            let authoritativeGeneration = await storeAtSearchStart.catalogGeneration(rootScope: rootScopeAtSearchStart)
            let wasCancelledDuringValidation = wasCancelledBeforeValidation || Task.isCancelled
            if !wasCancelledDuringValidation,
               isCurrentBinding(
                   store: storeAtSearchStart,
                   rootScope: rootScopeAtSearchStart,
                   epoch: bindingEpochAtSearchStart
               )
            {
                latestObservedCatalogGeneration = authoritativeGeneration
                observedGenerationForResult = authoritativeGeneration
                bindingValidationSucceeded = true
            }
        }

        var stale = Self.isSearchStale(
            indexedGeneration: generationAtSearchStart,
            observedGeneration: observedGenerationForResult,
            pendingGeneration: pendingRebuildGenerationAtSearchStart,
            activeGeneration: activeRebuildGenerationAtSearchStart,
            isReadyIndexUsable: isReadyIndexUsableAtSearchStart
        )
        if wasBoundAtSearchStart, !bindingValidationSucceeded {
            stale = true
        }
        if currentIndexedGeneration != generationAtSearchStart {
            stale = true
        }
        return WorkspaceSearchQueryResult(
            query: query,
            indexedGeneration: generationAtSearchStart,
            snapshotGeneration: snapshotGenerationAtSearchStart,
            pendingGeneration: pendingGenerationAtSearchStart,
            observedGeneration: observedGenerationForResult,
            results: results,
            isIndexReady: generationAtSearchStart != nil && isReadyIndexUsableAtSearchStart,
            isStale: stale
        )
    }

    private static func isSearchStale(
        indexedGeneration: UInt64?,
        observedGeneration: UInt64?,
        pendingGeneration: UInt64?,
        activeGeneration: UInt64?,
        isReadyIndexUsable: Bool
    ) -> Bool {
        guard let indexedGeneration else {
            return pendingGeneration != nil || activeGeneration != nil || observedGeneration != nil
        }
        if let observedGeneration, observedGeneration != indexedGeneration {
            return true
        }
        if let pendingGeneration, pendingGeneration != indexedGeneration {
            return true
        }
        if let activeGeneration, activeGeneration != indexedGeneration {
            return true
        }
        return !isReadyIndexUsable
    }

    private func handleSearchCatalogChangeEvent(
        _ event: WorkspaceSearchCatalogChangeEvent,
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope,
        epoch: UInt64,
        listenerSerial: UInt64,
        debounceNanoseconds: UInt64
    ) async {
        guard isCurrentBinding(store: store, rootScope: rootScope, epoch: epoch),
              freshnessListenerSerial == listenerSerial,
              isFreshnessListenerRunning
        else { return }
        #if DEBUG
            await catalogChangeWillHandleHandler?(event)
        #endif
        guard isCurrentBinding(store: store, rootScope: rootScope, epoch: epoch),
              freshnessListenerSerial == listenerSerial,
              isFreshnessListenerRunning
        else { return }
        if event.kind == .rootUnloaded {
            dropReadyRootIndex(matching: event)
        }

        let catalogGeneration = await store.catalogGeneration(rootScope: rootScope)
        guard isCurrentBinding(store: store, rootScope: rootScope, epoch: epoch),
              freshnessListenerSerial == listenerSerial,
              isFreshnessListenerRunning
        else { return }
        latestObservedCatalogGeneration = catalogGeneration
        if catalogGeneration == currentIndexedGeneration,
           pendingRebuildGeneration == nil,
           activeRebuildGeneration == nil
        {
            return
        }
        if event.kind == .generationAdvancedWithoutProjectionChange {
            guard event.catalogGeneration == catalogGeneration else {
                // A later catalog event is already buffered. Let that event either commit the
                // newest projection-neutral generation or schedule the required rebuild.
                return
            }
            if advanceReadyIndexGenerationWithoutProjectionRebuild(to: catalogGeneration) {
                #if DEBUG
                    await projectionNeutralGenerationDidCommitHandler?(catalogGeneration)
                #endif
                return
            }
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

    private func advanceReadyIndexGenerationWithoutProjectionRebuild(to generation: UInt64) -> Bool {
        guard currentRefreshFlightToken == nil,
              pendingRebuildGeneration == nil,
              activeRebuildGeneration == nil,
              currentSnapshotGeneration != nil,
              currentIndexedGeneration != nil
        else { return false }

        currentSnapshotGeneration = generation
        currentIndexedGeneration = generation
        if let diagnostics = currentDiagnostics {
            currentDiagnostics = WorkspaceCatalogDiagnostics(
                generation: generation,
                rootScope: diagnostics.rootScope,
                rootCount: diagnostics.rootCount,
                folderCount: diagnostics.folderCount,
                fileCount: diagnostics.fileCount
            )
        }
        return true
    }

    private func isCurrentBinding(
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope,
        epoch: UInt64
    ) -> Bool {
        bindingEpoch == epoch && boundStore === store && boundRootScope == rootScope
    }

    private func reconcileBoundCatalogAfterManualRebuild() async {
        guard isFreshnessListenerRunning,
              let store = boundStore,
              let rootScope = boundRootScope
        else { return }
        let epoch = bindingEpoch
        let listenerSerial = freshnessListenerSerial
        let catalogGeneration = await store.catalogGeneration(rootScope: rootScope)
        guard isCurrentBinding(store: store, rootScope: rootScope, epoch: epoch),
              freshnessListenerSerial == listenerSerial,
              isFreshnessListenerRunning
        else { return }
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

    private func cancelRefreshFlight() {
        rebuildSerial &+= 1
        currentRefreshFlightToken = nil
        pendingRebuildTask?.cancel()
        pendingRebuildTask = nil
        pendingRebuildGeneration = nil
        activeRebuildGeneration = nil
    }

    private func scheduleRebuild(
        from store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope,
        targetGeneration: UInt64,
        debounceNanoseconds: UInt64
    ) {
        guard isFreshnessListenerRunning,
              boundStore === store,
              boundRootScope == rootScope
        else { return }
        if currentRefreshFlightToken?.targetGeneration == targetGeneration {
            return
        }
        if currentRefreshFlightToken == nil, currentIndexedGeneration == targetGeneration {
            return
        }

        #if DEBUG
            if currentRefreshFlightToken != nil, pendingRebuildGeneration != nil {
                debugDebounceCancellationCount += 1
            }
        #endif
        rebuildSerial &+= 1
        let token = RefreshFlightToken(
            bindingEpoch: bindingEpoch,
            rebuildSerial: rebuildSerial,
            targetGeneration: targetGeneration
        )
        currentRefreshFlightToken = token
        pendingRebuildGeneration = targetGeneration
        activeRebuildGeneration = nil
        pendingRebuildTask?.cancel()
        pendingRebuildTask = Task { [weak self, store] in
            if debounceNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: debounceNanoseconds)
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            await self?.rebuildFromStoreIfCurrent(
                store: store,
                rootScope: rootScope,
                token: token
            )
        }
    }

    private func rebuildFromStoreIfCurrent(
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope,
        token: RefreshFlightToken
    ) async {
        guard ownsRefreshFlight(token, store: store, rootScope: rootScope),
              pendingRebuildGeneration == token.targetGeneration
        else { return }
        pendingRebuildGeneration = nil
        activeRebuildGeneration = token.targetGeneration

        let snapshot = await store.searchCatalogSnapshot(rootScope: rootScope)
        guard ownsRefreshFlight(token, store: store, rootScope: rootScope),
              !Task.isCancelled
        else { return }
        latestObservedCatalogGeneration = snapshot.generation
        guard snapshot.generation == token.targetGeneration else {
            retireRefreshFlight(token)
            scheduleRebuild(
                from: store,
                rootScope: rootScope,
                targetGeneration: snapshot.generation,
                debounceNanoseconds: 0
            )
            return
        }

        #if DEBUG
            await automaticRebuildDidStartHandler?(token.targetGeneration)
        #endif
        guard ownsRefreshFlight(token, store: store, rootScope: rootScope),
              !Task.isCancelled
        else { return }
        if automaticIndexBuildDelayNanoseconds > 0 {
            do {
                try await Task.sleep(nanoseconds: automaticIndexBuildDelayNanoseconds)
            } catch {
                return
            }
        }
        guard ownsRefreshFlight(token, store: store, rootScope: rootScope),
              !Task.isCancelled
        else { return }
        let prepared = Self.prepareIndex(from: snapshot)
        let authoritativeGeneration = await store.catalogGeneration(rootScope: rootScope)
        guard ownsRefreshFlight(token, store: store, rootScope: rootScope) else { return }
        #if DEBUG
            recordPreparedIndexWork(prepared)
        #endif
        latestObservedCatalogGeneration = authoritativeGeneration

        let generationStillMatches = !Task.isCancelled &&
            authoritativeGeneration == prepared.generation &&
            latestObservedCatalogGeneration == prepared.generation
        guard generationStillMatches else {
            discardedAutomaticRebuildCompletions += 1
            retireRefreshFlight(token)
            scheduleRebuild(
                from: store,
                rootScope: rootScope,
                targetGeneration: authoritativeGeneration,
                debounceNanoseconds: 0
            )
            return
        }
        guard !Self.hasDuplicateRootIdentities(prepared.rootPathIndexes) else {
            #if DEBUG
                assertionFailure("Prepared search index contains duplicate root identities")
            #endif
            discardedAutomaticRebuildCompletions += 1
            retireRefreshFlight(token)
            return
        }

        commit(prepared)
        retireRefreshFlight(token)
        #if DEBUG
            await automaticRebuildDidCommitHandler?(prepared.generation)
        #endif
    }

    private func ownsRefreshFlight(
        _ token: RefreshFlightToken,
        store: WorkspaceFileContextStore,
        rootScope: WorkspaceLookupRootScope
    ) -> Bool {
        currentRefreshFlightToken == token &&
            isFreshnessListenerRunning &&
            isCurrentBinding(store: store, rootScope: rootScope, epoch: token.bindingEpoch)
    }

    private func retireRefreshFlight(_ token: RefreshFlightToken) {
        guard currentRefreshFlightToken == token else { return }
        currentRefreshFlightToken = nil
        pendingRebuildTask = nil
        pendingRebuildGeneration = nil
        activeRebuildGeneration = nil
    }

    private func dropReadyRootIndex(matching event: WorkspaceSearchCatalogChangeEvent) {
        guard let lifetimeID = event.rootLifetimeID else { return }
        readyRootPathIndexes.removeAll {
            $0.identity.rootID == event.rootID && $0.identity.lifetimeID == lifetimeID
        }
    }

    private static func hasDuplicateRootIdentities(
        _ rootPathIndexes: [WorkspaceSearchRootPathIndex]
    ) -> Bool {
        var identities = Set<WorkspaceSearchRootPathIndexIdentity>()
        var rootIDs = Set<UUID>()
        for rootPathIndex in rootPathIndexes {
            guard identities.insert(rootPathIndex.identity).inserted,
                  rootIDs.insert(rootPathIndex.identity.rootID).inserted
            else { return true }
        }
        return false
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
    ) async -> [WorkspaceSearchCatalogEntry] {
        var candidateBatches: [[WorkspaceSearchRootPathIndex.Candidate]] = []
        candidateBatches.reserveCapacity(rootPathIndexes.count)
        for index in rootPathIndexes {
            if Task.isCancelled { return [] }
            await candidateBatches.append(index.searchVerifyingShadow(query, limit: limit))
        }
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
            if Task.isCancelled { return [] }
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
