import Foundation

/// Actor-owned workspace path-search facade built from store catalog snapshots.
///
/// The service keeps `PathSearchIndex` and all path-entry arrays off the main actor. Callers
/// provide immutable `WorkspaceSearchCatalogSnapshot` values from `WorkspaceFileContextStore`,
/// then query by text and receive pure value results.
package actor WorkspaceSearchService {
    private struct PreparedIndex {
        let generation: UInt64
        let diagnostics: WorkspaceCatalogDiagnostics
        let orderedEntries: [WorkspaceSearchCatalogEntry]
        let indexedPaths: [String]
        let entriesByIndexedPath: [String: WorkspaceSearchCatalogEntry]
        let index: PathSearchIndex
    }

    private var readyIndex = PathSearchIndex()
    private var orderedEntries: [WorkspaceSearchCatalogEntry] = []
    private var indexedPaths: [String] = []
    private var entriesByIndexedPath: [String: WorkspaceSearchCatalogEntry] = [:]
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

    package init(automaticIndexBuildDelayNanoseconds: UInt64 = 0) {
        self.automaticIndexBuildDelayNanoseconds = automaticIndexBuildDelayNanoseconds
    }

    deinit {
        appliedIndexListenerTask?.cancel()
        pendingRebuildTask?.cancel()
    }

    package var indexedGeneration: UInt64? {
        currentIndexedGeneration
    }

    package var snapshotGeneration: UInt64? {
        currentSnapshotGeneration
    }

    package var diagnostics: WorkspaceCatalogDiagnostics? {
        currentDiagnostics
    }

    package var indexedPathCount: Int {
        indexedPaths.count
    }

    package var pendingGeneration: UInt64? {
        pendingRebuildGeneration ?? activeRebuildGeneration
    }

    package var observedCatalogGeneration: UInt64? {
        latestObservedCatalogGeneration
    }

    package var discardedStaleRebuildCount: Int {
        discardedAutomaticRebuildCompletions
    }

    package func startKeepingFresh(
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

    package func stopKeepingFresh() {
        appliedIndexListenerTask?.cancel()
        appliedIndexListenerTask = nil
        pendingRebuildTask?.cancel()
        pendingRebuildTask = nil
        pendingRebuildGeneration = nil
        activeRebuildGeneration = nil
    }

    @discardableResult
    package func rebuildIndex(from snapshot: WorkspaceSearchCatalogSnapshot) async -> UInt64 {
        rebuildSerial &+= 1
        let serial = rebuildSerial
        pendingRebuildTask?.cancel()
        pendingRebuildTask = nil
        pendingRebuildGeneration = nil
        activeRebuildGeneration = snapshot.generation
        latestObservedCatalogGeneration = snapshot.generation

        let prepared = await Self.prepareIndex(from: snapshot)
        guard serial == rebuildSerial, !Task.isCancelled else {
            activeRebuildGeneration = nil
            return currentIndexedGeneration ?? snapshot.generation
        }
        commit(prepared)
        activeRebuildGeneration = nil
        return snapshot.generation
    }

    @discardableResult
    package func prepareIndex(from snapshot: WorkspaceSearchCatalogSnapshot) async -> UInt64 {
        await rebuildIndex(from: snapshot)
    }

    package func reset() async {
        rebuildSerial &+= 1
        appliedIndexListenerTask?.cancel()
        appliedIndexListenerTask = nil
        pendingRebuildTask?.cancel()
        pendingRebuildTask = nil
        orderedEntries = []
        indexedPaths = []
        entriesByIndexedPath = [:]
        currentSnapshotGeneration = nil
        currentIndexedGeneration = nil
        currentDiagnostics = nil
        latestObservedCatalogGeneration = nil
        pendingRebuildGeneration = nil
        activeRebuildGeneration = nil
        isReadyIndexUsable = true
        readyIndex = PathSearchIndex()
    }

    package func search(_ query: String, limit: Int = 300) async -> WorkspaceSearchQueryResult {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let boundedLimit = max(0, limit)
        let stale = isSearchStale
        let pendingGenerationAtSearchStart = pendingGeneration
        let observedGenerationAtSearchStart = latestObservedCatalogGeneration
        let isReadyIndexUsableAtSearchStart = isReadyIndexUsable
        guard boundedLimit > 0 else {
            return queryResult(query: query, results: [], isStale: stale)
        }

        guard !trimmed.isEmpty else {
            return queryResult(query: query, results: Array(orderedEntries.prefix(boundedLimit)), isStale: stale)
        }

        guard isReadyIndexUsableAtSearchStart, currentIndexedGeneration != nil else {
            return queryResult(query: query, results: [], isStale: stale)
        }

        let index = readyIndex
        let generationAtSearchStart = currentIndexedGeneration
        let snapshotGenerationAtSearchStart = currentSnapshotGeneration
        let entriesAtSearchStart = orderedEntries
        let entriesByPathAtSearchStart = entriesByIndexedPath
        let candidates = await index.search(trimmed, limit: boundedLimit)
        var seenIDs = Set<UUID>()
        var results: [WorkspaceSearchCatalogEntry] = []
        results.reserveCapacity(candidates.count)
        for candidate in candidates {
            let entry: WorkspaceSearchCatalogEntry? = if candidate.index >= 0, candidate.index < entriesAtSearchStart.count {
                entriesAtSearchStart[candidate.index]
            } else {
                entriesByPathAtSearchStart[candidate.path]
            }
            guard let entry, seenIDs.insert(entry.id).inserted else { continue }
            results.append(entry)
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
            invalidateReadyEntriesForRootUnload(rootID: event.rootID)
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
        let prepared = await Self.prepareIndex(from: snapshot)
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

    private func invalidateReadyEntriesForRootUnload(rootID: UUID) {
        guard orderedEntries.contains(where: { $0.rootID == rootID }) else { return }
        orderedEntries.removeAll { $0.rootID == rootID }
        indexedPaths = orderedEntries.map(Self.indexPath(for:))
        entriesByIndexedPath = Dictionary(zip(indexedPaths, orderedEntries), uniquingKeysWith: { first, _ in first })
        currentIndexedGeneration = nil
        currentSnapshotGeneration = nil
        currentDiagnostics = nil
        readyIndex = PathSearchIndex()
        isReadyIndexUsable = false
    }

    private func commit(_ prepared: PreparedIndex) {
        orderedEntries = prepared.orderedEntries
        indexedPaths = prepared.indexedPaths
        entriesByIndexedPath = prepared.entriesByIndexedPath
        currentSnapshotGeneration = prepared.generation
        currentDiagnostics = prepared.diagnostics
        readyIndex = prepared.index
        currentIndexedGeneration = prepared.generation
        isReadyIndexUsable = true
    }

    private static func prepareIndex(from snapshot: WorkspaceSearchCatalogSnapshot) async -> PreparedIndex {
        let ordered = orderEntries(snapshot.entries)
        let paths = ordered.map(indexPath(for:))
        let entriesByIndexedPath = Dictionary(zip(paths, ordered), uniquingKeysWith: { first, _ in first })
        let index = PathSearchIndex()
        await index.rebuild(paths: paths)
        return PreparedIndex(
            generation: snapshot.generation,
            diagnostics: snapshot.diagnostics,
            orderedEntries: ordered,
            indexedPaths: paths,
            entriesByIndexedPath: entriesByIndexedPath,
            index: index
        )
    }

    private static func orderEntries(_ entries: [WorkspaceSearchCatalogEntry]) -> [WorkspaceSearchCatalogEntry] {
        entries.sorted {
            if $0.rootPath != $1.rootPath { return $0.rootPath < $1.rootPath }
            if $0.standardizedRelativePath != $1.standardizedRelativePath {
                return $0.standardizedRelativePath < $1.standardizedRelativePath
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func indexPath(for entry: WorkspaceSearchCatalogEntry) -> String {
        // Include both the workspace display path and absolute path so the index works for UI-style
        // queries ("Root/Sources/App.swift") and absolute-path consumers while retaining a stable
        // one-entry-per-file mapping.
        entry.displayPath + "\n" + entry.standardizedFullPath
    }
}
