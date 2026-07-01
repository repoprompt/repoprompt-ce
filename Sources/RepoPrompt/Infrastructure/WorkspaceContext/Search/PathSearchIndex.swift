import Foundation

/// Define size_t for C interop
typealias size_t = Int

/// Immutable high-performance path search index backed by C-owned sorted arrays.
///
/// The C storage is read-only after initialization, so concurrent readers can safely retain and
/// query an older generation while a replacement index is built and published elsewhere.
final class PathSearchIndex: @unchecked Sendable {
    struct Candidate: Equatable {
        let index: Int
        let path: String
        let filename: String
        let score: Int32
        let tieBreakKey: String
    }

    struct ProjectedSearchDiagnostics: Equatable {
        let examinedCount: Int
        let matchedCount: Int
        let heapPeakCount: Int
        let heapComparisonCount: Int
        let scratchBytes: Int
    }

    enum ProjectedSearchOutcome {
        case completed([Candidate], ProjectedSearchDiagnostics)
        case cancelled(ProjectedSearchDiagnostics)
    }

    private let cIndex: OpaquePointer? // const path_search_index_t*
    private let originalPaths: [String]
    private let filenames: [String]

    init(paths: [String]) {
        originalPaths = paths
        filenames = paths.map { path in
            URL(fileURLWithPath: path).lastPathComponent
        }

        guard !paths.isEmpty else {
            cIndex = nil
            return
        }

        let cPaths = paths.map { strdup($0) }
        defer { cPaths.forEach { free($0) } }
        let cPathPointers = cPaths.map { UnsafePointer<CChar>($0) }
        cIndex = cPathPointers.withUnsafeBufferPointer { buffer in
            path_search_create(buffer.baseAddress, paths.count)
        }
    }

    deinit {
        if let cIndex {
            path_search_destroy(cIndex)
        }
    }

    /// Builds an immutable index from a non-actor async context so UI callers do not perform the
    /// C allocation and sort on `MainActor`.
    static func build(paths: [String]) async -> PathSearchIndex {
        PathSearchIndex(paths: paths)
    }

    /// Returns candidates in the C index's authoritative rank order: descending score, then
    /// ascending lexical tie-break key. The current matcher is boolean, so accepted matches all
    /// have score 1 and retain the historical lexical ordering exactly.
    func search(_ pattern: String, limit: Int = 300) async -> [Candidate] {
        searchSynchronously(pattern, limit: limit)
    }

    /// Synchronous immutable query used by readers that already execute away from UI actors.
    func searchSynchronously(_ pattern: String, limit: Int = 300) -> [Candidate] {
        guard let cIndex, limit > 0 else { return [] }
        let result = pattern.withCString { patternCString in
            path_search_find(cIndex, patternCString, limit)
        }
        guard let result else { return [] }
        defer { search_result_destroy(result) }

        let resultPointer = UnsafePointer<search_result_t>(result)
        let count = Int(resultPointer.pointee.count)
        guard count > 0,
              let indices = resultPointer.pointee.indices,
              let scores = resultPointer.pointee.scores,
              let tieBreakKeys = resultPointer.pointee.tieBreakKeys
        else { return [] }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(count)
        for resultIndex in 0 ..< count {
            let pathIndex = Int(indices[resultIndex])
            guard originalPaths.indices.contains(pathIndex),
                  let tieBreakCString = tieBreakKeys[resultIndex]
            else { continue }
            candidates.append(Candidate(
                index: pathIndex,
                path: originalPaths[pathIndex],
                filename: filenames[pathIndex],
                score: scores[resultIndex],
                tieBreakKey: String(cString: tieBreakCString)
            ))
        }
        return candidates
    }

    func searchProjectedSynchronously(
        _ pattern: String,
        displayPrefix: String,
        absolutePrefix: String,
        limit: Int = 300
    ) -> [Candidate] {
        switch searchProjectedSynchronously(
            pattern,
            displayPrefix: displayPrefix,
            absolutePrefix: absolutePrefix,
            limit: limit,
            cancellation: nil
        ) {
        case let .completed(candidates, _): candidates
        case .cancelled: []
        }
    }

    func searchProjected(
        _ pattern: String,
        displayPrefix: String,
        absolutePrefix: String,
        limit: Int = 300
    ) async -> ProjectedSearchOutcome {
        guard let cancellation = PathSearchCancellation() else {
            return searchProjectedSynchronously(
                pattern,
                displayPrefix: displayPrefix,
                absolutePrefix: absolutePrefix,
                limit: limit,
                cancellation: nil
            )
        }
        let worker = Task.detached { [self, cancellation] in
            searchProjectedSynchronously(
                pattern,
                displayPrefix: displayPrefix,
                absolutePrefix: absolutePrefix,
                limit: limit,
                cancellation: cancellation
            )
        }
        return await withTaskCancellationHandler {
            if Task.isCancelled {
                cancellation.cancel()
                worker.cancel()
            }
            return await worker.value
        } onCancel: {
            cancellation.cancel()
            worker.cancel()
        }
    }

    private func searchProjectedSynchronously(
        _ pattern: String,
        displayPrefix: String,
        absolutePrefix: String,
        limit: Int,
        cancellation: PathSearchCancellation?
    ) -> ProjectedSearchOutcome {
        let emptyDiagnostics = ProjectedSearchDiagnostics(
            examinedCount: 0,
            matchedCount: 0,
            heapPeakCount: 0,
            heapComparisonCount: 0,
            scratchBytes: 0
        )
        guard let cIndex, limit > 0 else { return .completed([], emptyDiagnostics) }
        var stats = path_search_work_stats_t()
        let result = pattern.withCString { patternCString in
            displayPrefix.withCString { displayCString in
                absolutePrefix.withCString { absoluteCString in
                    path_search_projected_find_cancellable(
                        cIndex,
                        patternCString,
                        displayCString,
                        absoluteCString,
                        limit,
                        cancellation?.pointer,
                        &stats
                    )
                }
            }
        }
        let diagnostics = ProjectedSearchDiagnostics(
            examinedCount: stats.examinedCount,
            matchedCount: stats.matchedCount,
            heapPeakCount: stats.heapPeakCount,
            heapComparisonCount: stats.heapComparisonCount,
            scratchBytes: stats.scratchBytes
        )
        guard let result else {
            return stats.cancelled ? .cancelled(diagnostics) : .completed([], diagnostics)
        }
        defer { search_result_destroy(result) }

        if stats.cancelled { return .cancelled(diagnostics) }

        let resultPointer = UnsafePointer<search_result_t>(result)
        let count = Int(resultPointer.pointee.count)
        guard count > 0,
              let indices = resultPointer.pointee.indices,
              let scores = resultPointer.pointee.scores
        else { return .completed([], diagnostics) }
        let candidates: [Candidate] = (0 ..< count).compactMap { resultIndex in
            let pathIndex = Int(indices[resultIndex])
            guard originalPaths.indices.contains(pathIndex) else { return nil }
            let relativePath = originalPaths[pathIndex]
            return Candidate(
                index: pathIndex,
                path: relativePath,
                filename: filenames[pathIndex],
                score: scores[resultIndex],
                tieBreakKey: displayPrefix + relativePath + "\n" + absolutePrefix + relativePath
            )
        }
        return .completed(candidates, diagnostics)
    }

    func path(at index: Int) -> String? {
        guard originalPaths.indices.contains(index) else { return nil }
        return originalPaths[index]
    }

    func filename(at index: Int) -> String? {
        guard filenames.indices.contains(index) else { return nil }
        return filenames[index]
    }

    var count: Int {
        originalPaths.count
    }
}

private final class PathSearchCancellation: @unchecked Sendable {
    let pointer: OpaquePointer

    init?() {
        guard let pointer = path_search_cancellation_create() else { return nil }
        self.pointer = pointer
    }

    deinit {
        path_search_cancellation_destroy(pointer)
    }

    func cancel() {
        path_search_cancellation_cancel(pointer)
    }
}

struct WorkspaceSearchRootPathIndexIdentity: Equatable, Hashable {
    let rootID: UUID
    let lifetimeID: UUID
    let topologyGeneration: UInt64
}

final class WorkspaceProjectedPathSearchShadowControl: @unchecked Sendable {
    struct Lease {
        let projection: WorkspaceProjectedPathSearchIndex
        fileprivate let generation: UInt64
    }

    let scope: WorkspaceRootSeedShadowScope
    private let lock = NSLock()
    private var projection: WorkspaceProjectedPathSearchIndex?
    private var generation: UInt64 = 0

    init(scope: WorkspaceRootSeedShadowScope, projection: WorkspaceProjectedPathSearchIndex) {
        self.scope = scope
        self.projection = projection
    }

    func begin() -> Lease? {
        lock.lock()
        defer { lock.unlock() }
        guard let projection else { return nil }
        return Lease(projection: projection, generation: generation)
    }

    /// Returns true only when this completion still owns the active generation.
    /// A mismatch drops the projection before releasing the lock, so no later query can rerun it.
    func complete(_ lease: Lease, matched: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard projection != nil, generation == lease.generation else { return false }
        if !matched {
            projection = nil
            generation &+= 1
        }
        return true
    }

    @discardableResult
    func invalidate() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard projection != nil else { return false }
        projection = nil
        generation &+= 1
        return true
    }

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return projection != nil
    }
}

/// Immutable root-local search projection retained by catalog snapshots and active readers.
///
/// Shard patches share one materialized base index and append immutable overlay segments.
/// Every published generation owns its segment head, so compaction can replace the current chain
/// without invalidating older readers that retained a previous generation.
final class WorkspaceSearchRootPathIndex: @unchecked Sendable {
    enum BuildKind: Equatable {
        case full
        case overlay
        case reused
        case projectedReuse
    }

    struct Candidate {
        let entry: WorkspaceSearchCatalogEntry
        let score: Int32
        let tieBreakKey: String
    }

    private static let maximumOverlaySegmentCount = 16

    private final class MaterializedBase: @unchecked Sendable {
        let entries: [WorkspaceSearchCatalogEntry]
        let index: PathSearchIndex

        init(entries: [WorkspaceSearchCatalogEntry]) {
            self.entries = entries
            #if DEBUG
                let keyStart = WorkspaceFileSearchDebugTiming.now()
                let keys = entries.map(\.pathSearchIndexKey)
                let keyEnd = WorkspaceFileSearchDebugTiming.now()
                WorkspaceFileSearchDebugContext.catalogBuildObserver?.recordPathIndexKey(
                    nanoseconds: WorkspaceFileSearchDebugTiming.elapsed(since: keyStart, through: keyEnd)
                )
                let indexStart = WorkspaceFileSearchDebugTiming.now()
                index = PathSearchIndex(paths: keys)
                let indexEnd = WorkspaceFileSearchDebugTiming.now()
                WorkspaceFileSearchDebugContext.catalogBuildObserver?.recordPathIndexConstruction(
                    nanoseconds: WorkspaceFileSearchDebugTiming.elapsed(since: indexStart, through: indexEnd)
                )
            #else
                index = PathSearchIndex(paths: entries.map(\.pathSearchIndexKey))
            #endif
        }
    }

    private final class OverlaySegment: @unchecked Sendable {
        let entries: [WorkspaceSearchCatalogEntry]
        let index: PathSearchIndex?
        let affectedEntryIDs: Set<UUID>
        let previous: OverlaySegment?
        let depth: Int
        private let compactedSegments: [OverlaySegment]?

        init(
            entries: [WorkspaceSearchCatalogEntry],
            affectedEntryIDs: Set<UUID>,
            previous: OverlaySegment?
        ) {
            self.entries = entries
            index = entries.isEmpty ? nil : PathSearchIndex(paths: entries.map(\.pathSearchIndexKey))
            self.affectedEntryIDs = affectedEntryIDs
            self.previous = previous
            depth = (previous?.depth ?? 0) + 1
            compactedSegments = nil
        }

        static func compact(_ head: OverlaySegment) -> OverlaySegment {
            // Compact only the chain of immutable handles. Payload indexes and tombstones remain
            // shared, so compaction work is proportional to segment count rather than target size.
            var segments: [OverlaySegment] = []
            var segment: OverlaySegment? = head
            while let current = segment {
                segments.append(current)
                segment = current.previous
            }
            return OverlaySegment(compactedSegments: segments)
        }

        private init(compactedSegments: [OverlaySegment]) {
            entries = []
            index = nil
            affectedEntryIDs = []
            previous = nil
            depth = 1
            self.compactedSegments = compactedSegments
        }

        func visitLeavesNewestFirst(_ body: (OverlaySegment) -> Void) {
            var stack = [self]
            while let segment = stack.popLast() {
                if let compactedSegments = segment.compactedSegments {
                    stack.append(contentsOf: compactedSegments.reversed())
                } else {
                    body(segment)
                }
            }
        }
    }

    let identity: WorkspaceSearchRootPathIndexIdentity
    let rootPath: String
    let entries: [WorkspaceSearchCatalogEntry]
    let buildKind: BuildKind

    private let base: MaterializedBase?
    private let projectedIndex: WorkspaceProjectedPathSearchIndex?
    private let overlaySegmentHead: OverlaySegment?
    private let shadowControl: WorkspaceProjectedPathSearchShadowControl?

    init(
        identity: WorkspaceSearchRootPathIndexIdentity,
        rootPath: String,
        entries: [WorkspaceSearchCatalogEntry],
        shadowControl: WorkspaceProjectedPathSearchShadowControl? = nil
    ) {
        self.identity = identity
        self.rootPath = rootPath
        self.entries = entries
        buildKind = .full
        base = MaterializedBase(entries: entries)
        projectedIndex = nil
        overlaySegmentHead = nil
        self.shadowControl = shadowControl
    }

    private init(
        identity: WorkspaceSearchRootPathIndexIdentity,
        rootPath: String,
        entries: [WorkspaceSearchCatalogEntry],
        buildKind: BuildKind,
        base: MaterializedBase,
        overlaySegmentHead: OverlaySegment?,
        shadowControl: WorkspaceProjectedPathSearchShadowControl?
    ) {
        self.identity = identity
        self.rootPath = rootPath
        self.entries = entries
        self.buildKind = buildKind
        self.base = base
        projectedIndex = nil
        self.overlaySegmentHead = overlaySegmentHead
        self.shadowControl = shadowControl
    }

    init(
        identity: WorkspaceSearchRootPathIndexIdentity,
        rootPath: String,
        entries: [WorkspaceSearchCatalogEntry],
        projectedIndex: WorkspaceProjectedPathSearchIndex
    ) {
        precondition(projectedIndex.entries == entries)
        self.identity = identity
        self.rootPath = rootPath
        self.entries = entries
        buildKind = .projectedReuse
        base = nil
        self.projectedIndex = projectedIndex
        overlaySegmentHead = nil
        shadowControl = nil
    }

    convenience init?(
        identity: WorkspaceSearchRootPathIndexIdentity,
        root: WorkspaceRootRecord,
        projectedSnapshot snapshot: WorkspaceRootReusableSnapshot,
        projectedPlanHandle: WorkspaceRootTargetSeedPlanHandle,
        additionalChangedRelativePaths: FileSystemSeededInventoryChangedPaths,
        entries: [WorkspaceSearchCatalogEntry]
    ) {
        guard let projectedIndex = WorkspaceProjectedPathSearchIndex(
            snapshot: snapshot,
            planHandle: projectedPlanHandle,
            additionalChangedRelativePaths: additionalChangedRelativePaths,
            root: root,
            authoritativeEntries: entries
        ) else { return nil }
        self.init(
            identity: identity,
            rootPath: root.standardizedFullPath,
            entries: entries,
            projectedIndex: projectedIndex
        )
    }

    #if DEBUG
        convenience init?(
            identity: WorkspaceSearchRootPathIndexIdentity,
            root: WorkspaceRootRecord,
            projectedSnapshot snapshot: WorkspaceRootReusableSnapshot,
            changedRelativeFilePaths: Set<String>,
            tombstonedBaseRelativeFilePaths: Set<String>,
            entries: [WorkspaceSearchCatalogEntry]
        ) {
            guard let projectedIndex = WorkspaceProjectedPathSearchIndex(
                snapshot: snapshot,
                changedRelativeFilePaths: changedRelativeFilePaths,
                tombstonedBaseRelativeFilePaths: tombstonedBaseRelativeFilePaths,
                root: root,
                authoritativeEntries: entries
            ) else { return nil }
            self.init(
                identity: identity,
                rootPath: root.standardizedFullPath,
                entries: entries,
                projectedIndex: projectedIndex
            )
        }
    #endif

    var count: Int {
        entries.count
    }

    func applyingPatch(
        identity: WorkspaceSearchRootPathIndexIdentity,
        entries: [WorkspaceSearchCatalogEntry],
        changedFileIDs: Set<UUID>
    ) -> WorkspaceSearchRootPathIndex {
        guard identity.rootID == self.identity.rootID,
              identity.lifetimeID == self.identity.lifetimeID
        else {
            return WorkspaceSearchRootPathIndex(identity: identity, rootPath: rootPath, entries: entries)
        }

        guard !changedFileIDs.isEmpty else {
            if let projectedIndex {
                return WorkspaceSearchRootPathIndex(
                    identity: identity,
                    rootPath: rootPath,
                    entries: entries,
                    projectedIndex: projectedIndex
                )
            }
            guard let base else {
                return WorkspaceSearchRootPathIndex(identity: identity, rootPath: rootPath, entries: entries)
            }
            return WorkspaceSearchRootPathIndex(
                identity: identity,
                rootPath: rootPath,
                entries: entries,
                buildKind: .reused,
                base: base,
                overlaySegmentHead: overlaySegmentHead,
                shadowControl: shadowControl
            )
        }

        if let projectedIndex {
            var changedRelativePaths = Set<String>()
            changedRelativePaths.reserveCapacity(changedFileIDs.count * 2)
            var resolvedFileIDs = Set<UUID>()
            for previous in self.entries where changedFileIDs.contains(previous.id) {
                changedRelativePaths.insert(previous.standardizedRelativePath)
                resolvedFileIDs.insert(previous.id)
            }
            for current in entries where changedFileIDs.contains(current.id) {
                changedRelativePaths.insert(current.standardizedRelativePath)
                resolvedFileIDs.insert(current.id)
            }
            guard resolvedFileIDs == changedFileIDs else {
                return WorkspaceSearchRootPathIndex(identity: identity, rootPath: rootPath, entries: entries)
            }
            guard let nextProjectedIndex = projectedIndex.applyingPatch(
                entries: entries,
                changedRelativePaths: changedRelativePaths
            ) else {
                return WorkspaceSearchRootPathIndex(identity: identity, rootPath: rootPath, entries: entries)
            }
            return WorkspaceSearchRootPathIndex(
                identity: identity,
                rootPath: rootPath,
                entries: entries,
                projectedIndex: nextProjectedIndex
            )
        }

        shadowControl?.invalidate()
        guard let base else {
            return WorkspaceSearchRootPathIndex(identity: identity, rootPath: rootPath, entries: entries)
        }
        let segmentEntries = entries.filter { changedFileIDs.contains($0.id) }
        var nextSegmentHead = OverlaySegment(
            entries: segmentEntries,
            affectedEntryIDs: changedFileIDs,
            previous: overlaySegmentHead
        )
        if nextSegmentHead.depth > Self.maximumOverlaySegmentCount {
            nextSegmentHead = OverlaySegment.compact(nextSegmentHead)
        }
        return WorkspaceSearchRootPathIndex(
            identity: identity,
            rootPath: rootPath,
            entries: entries,
            buildKind: .overlay,
            base: base,
            overlaySegmentHead: nextSegmentHead,
            shadowControl: nil
        )
    }

    func search(_ query: String, limit: Int) -> [Candidate] {
        guard limit > 0 else { return [] }
        if let projectedIndex {
            return projectedIndex.search(query, limit: limit)
        }
        guard let base else { return [] }

        var candidateLists: [[Candidate]] = []
        var suppressedEntryIDs = Set<UUID>()
        var segment = overlaySegmentHead
        while let current = segment {
            current.visitLeavesNewestFirst { leaf in
                let boundedSegmentLimit = min(limit, leaf.entries.count)
                let segmentOverfetch = min(
                    suppressedEntryIDs.count,
                    leaf.entries.count - boundedSegmentLimit
                )
                let candidates = leaf.index?
                    .searchSynchronously(
                        query,
                        limit: boundedSegmentLimit + segmentOverfetch
                    )
                    .compactMap { candidate -> Candidate? in
                        guard leaf.entries.indices.contains(candidate.index) else { return nil }
                        let entry = leaf.entries[candidate.index]
                        guard !suppressedEntryIDs.contains(entry.id) else { return nil }
                        return Candidate(entry: entry, score: candidate.score, tieBreakKey: candidate.tieBreakKey)
                    } ?? []
                if !candidates.isEmpty { candidateLists.append(candidates) }
                suppressedEntryIDs.formUnion(leaf.affectedEntryIDs)
            }
            segment = current.previous
        }

        let boundedBaseLimit = min(base.entries.count, limit)
        let baseOverfetch = min(suppressedEntryIDs.count, base.entries.count - boundedBaseLimit)
        let baseCandidates = base.index
            .searchSynchronously(query, limit: boundedBaseLimit + baseOverfetch)
            .compactMap { candidate -> Candidate? in
                guard base.entries.indices.contains(candidate.index) else { return nil }
                let entry = base.entries[candidate.index]
                guard !suppressedEntryIDs.contains(entry.id) else { return nil }
                return Candidate(
                    entry: entry,
                    score: candidate.score,
                    tieBreakKey: candidate.tieBreakKey
                )
            }
        if !baseCandidates.isEmpty { candidateLists.append(baseCandidates) }

        var candidateOffsets = Array(repeating: 0, count: candidateLists.count)
        var results: [Candidate] = []
        results.reserveCapacity(limit)
        while results.count < limit {
            var bestListIndex: Int?
            for listIndex in candidateLists.indices
                where candidateOffsets[listIndex] < candidateLists[listIndex].count
            {
                guard let currentBest = bestListIndex else {
                    bestListIndex = listIndex
                    continue
                }
                if Self.candidatePrecedes(
                    candidateLists[listIndex][candidateOffsets[listIndex]],
                    candidateLists[currentBest][candidateOffsets[currentBest]]
                ) {
                    bestListIndex = listIndex
                }
            }
            guard let bestListIndex else { break }
            results.append(candidateLists[bestListIndex][candidateOffsets[bestListIndex]])
            candidateOffsets[bestListIndex] += 1
        }
        return results
    }

    func searchVerifyingShadow(_ query: String, limit: Int) async -> [Candidate] {
        let results = search(query, limit: limit)
        guard !Task.isCancelled, let lease = shadowControl?.begin() else { return results }
        let shadowProjection = lease.projection
        switch await shadowProjection.searchCancellable(query, limit: limit) {
        case .cancelled:
            return results
        case let .completed(projected, _):
            let matched = projected.count == results.count
                && zip(projected, results).allSatisfy { projected, authoritative in
                    projected.entry == authoritative.entry
                        && projected.score == authoritative.score
                        && projected.tieBreakKey == authoritative.tieBreakKey
                }
            if shadowControl?.complete(lease, matched: matched) == true {
                WorktreeStartupInstrumentation.recordProjectedSearchComparison(
                    matched: matched,
                    baseEntryCount: shadowProjection.baseEntryCount,
                    overlayEntryCount: shadowProjection.overlayEntryCount,
                    tombstoneCount: shadowProjection.tombstoneCount
                )
            }
        }
        return results
    }

    func recordEmptyQueryShadowParity(limit: Int) {
        guard let shadowControl, let lease = shadowControl.begin(), limit > 0 else { return }
        let shadowProjection = lease.projection
        let authoritative = Array(entries.prefix(limit))
        let projected = Array(shadowProjection.entries.prefix(limit))
        let matched = authoritative == projected
        if shadowControl.complete(lease, matched: matched) {
            WorktreeStartupInstrumentation.recordProjectedSearchComparison(
                matched: matched,
                baseEntryCount: shadowProjection.baseEntryCount,
                overlayEntryCount: shadowProjection.overlayEntryCount,
                tombstoneCount: shadowProjection.tombstoneCount
            )
        }
    }

    var projectedAccumulatedChangedPathCount: Int? {
        projectedIndex?.accumulatedChangedRelativePathCount
    }

    var overlaySegmentCountForTesting: Int {
        overlaySegmentHead?.depth ?? projectedIndex?.overlaySegmentCountForTesting ?? 0
    }

    private static func candidatePrecedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        switch WorkspaceFileContextStore.compareUTF8Binary(lhs.tieBreakKey, rhs.tieBreakKey) {
        case .orderedAscending:
            return true
        case .orderedDescending:
            return false
        case .orderedSame:
            break
        }
        return WorkspaceFileContextStore.searchCatalogEntryPrecedes(lhs.entry, rhs.entry)
    }
}

final class WorkspaceProjectedPathSearchIndex: @unchecked Sendable {
    typealias Candidate = WorkspaceSearchRootPathIndex.Candidate

    enum CancellableSearchOutcome {
        case completed([Candidate], PathSearchIndex.ProjectedSearchDiagnostics)
        case cancelled(PathSearchIndex.ProjectedSearchDiagnostics)
    }

    let entries: [WorkspaceSearchCatalogEntry]
    let baseEntryCount: Int
    let overlayEntryCount: Int
    let tombstoneCount: Int
    let accumulatedChangedRelativePathCount: Int

    private static let maximumOverlaySegmentCount = 16

    private struct AffectedRelativePaths: @unchecked Sendable {
        private enum Storage: @unchecked Sendable {
            case memory(Set<String>)
            case seeded(FileSystemSeededInventoryChangedPaths, [WorkspaceSearchCatalogEntry])
        }

        private let storage: Storage
        let count: Int

        init(_ paths: Set<String>) {
            storage = .memory(paths)
            count = paths.count
        }

        init(
            changed: FileSystemSeededInventoryChangedPaths,
            entries: [WorkspaceSearchCatalogEntry]
        ) throws {
            storage = .seeded(changed, entries)
            var result = 0
            let reader = try changed.makeReader()
            var changedPath = try reader.next()
            var entryIndex = 0
            while changedPath != nil || entryIndex < entries.count {
                if let path = changedPath, entryIndex < entries.count {
                    let entryPath = entries[entryIndex].standardizedRelativePath
                    switch WorkspaceFileContextStore.compareUTF8Binary(path, entryPath) {
                    case .orderedAscending:
                        changedPath = try reader.next()
                    case .orderedDescending:
                        entryIndex += 1
                    case .orderedSame:
                        changedPath = try reader.next()
                        entryIndex += 1
                    }
                    result += 1
                } else if changedPath != nil {
                    result += 1
                    changedPath = try reader.next()
                } else {
                    result += entries.count - entryIndex
                    entryIndex = entries.count
                }
            }
            count = result
        }

        var isEmpty: Bool {
            count == 0
        }

        func contains(_ relativePath: String) -> Bool {
            switch storage {
            case let .memory(paths):
                return paths.contains(relativePath)
            case let .seeded(changed, entries):
                if (try? changed.contains(relativePath)) == true { return true }
                return WorkspaceProjectedPathSearchIndex.entryIndex(
                    relativePath: relativePath,
                    entries: entries
                ) != nil
            }
        }

        func visit(_ body: (String) -> Void) {
            switch storage {
            case let .memory(paths):
                for path in paths {
                    body(path)
                }
            case let .seeded(changed, entries):
                guard let reader = try? changed.makeReader() else { return }
                var changedPath = try? reader.next()
                var entryIndex = 0
                while changedPath != nil || entryIndex < entries.count {
                    if let path = changedPath ?? nil, entryIndex < entries.count {
                        let entryPath = entries[entryIndex].standardizedRelativePath
                        switch WorkspaceFileContextStore.compareUTF8Binary(path, entryPath) {
                        case .orderedAscending:
                            body(path)
                            changedPath = try? reader.next()
                        case .orderedDescending:
                            body(entryPath)
                            entryIndex += 1
                        case .orderedSame:
                            body(path)
                            changedPath = try? reader.next()
                            entryIndex += 1
                        }
                    } else if let path = changedPath ?? nil {
                        body(path)
                        changedPath = try? reader.next()
                    } else {
                        while entryIndex < entries.count {
                            body(entries[entryIndex].standardizedRelativePath)
                            entryIndex += 1
                        }
                    }
                }
            }
        }
    }

    private final class OverlaySegment: @unchecked Sendable {
        let entries: [WorkspaceSearchCatalogEntry]
        let index: PathSearchIndex?
        let affectedRelativePaths: AffectedRelativePaths
        let previous: OverlaySegment?
        let depth: Int
        private let compactedSegments: [OverlaySegment]?

        init(
            entries: [WorkspaceSearchCatalogEntry],
            affectedRelativePaths: AffectedRelativePaths,
            previous: OverlaySegment?
        ) {
            self.entries = entries
            index = entries.isEmpty ? nil : PathSearchIndex(paths: entries.map(\.pathSearchIndexKey))
            self.affectedRelativePaths = affectedRelativePaths
            self.previous = previous
            depth = (previous?.depth ?? 0) + 1
            compactedSegments = nil
        }

        static func compact(_ head: OverlaySegment) -> OverlaySegment {
            // Compact only handles; never merge changed-path payloads into a target-sized rebuild.
            var segments: [OverlaySegment] = []
            var segment: OverlaySegment? = head
            while let current = segment {
                segments.append(current)
                segment = current.previous
            }
            return OverlaySegment(compactedSegments: segments)
        }

        private init(compactedSegments: [OverlaySegment]) {
            entries = []
            index = nil
            affectedRelativePaths = AffectedRelativePaths([])
            previous = nil
            depth = 1
            self.compactedSegments = compactedSegments
        }

        func visitLeavesNewestFirst(_ body: (OverlaySegment) -> Void) {
            var stack = [self]
            while let segment = stack.popLast() {
                if let compactedSegments = segment.compactedSegments {
                    stack.append(contentsOf: compactedSegments.reversed())
                } else {
                    body(segment)
                }
            }
        }
    }

    private let relativeBase: WorkspaceSearchRelativePathBase
    private let targetEntriesByBaseIndex: [WorkspaceSearchCatalogEntry?]
    private let overlaySegmentHead: OverlaySegment?
    private let displayPrefix: String
    private let absolutePrefix: String
    private let unsegmentedChangedPathCount: Int

    init?(
        snapshot: WorkspaceRootReusableSnapshot,
        planHandle: WorkspaceRootTargetSeedPlanHandle,
        additionalChangedRelativePaths: FileSystemSeededInventoryChangedPaths,
        root: WorkspaceRootRecord,
        authoritativeEntries: [WorkspaceSearchCatalogEntry]
    ) {
        guard snapshot.identity == planHandle.snapshotIdentity,
              snapshot.identity == planHandle.snapshot.identity
        else { return nil }
        let projectedDisplayPrefix = root.name + "/"
        let projectedAbsolutePrefix = root.standardizedFullPath + "/"
        guard authoritativeEntries.allSatisfy({ entry in
            entry.displayPath == projectedDisplayPrefix + entry.standardizedRelativePath
                && entry.standardizedFullPath == projectedAbsolutePrefix + entry.standardizedRelativePath
        }), zip(authoritativeEntries, authoritativeEntries.dropFirst()).allSatisfy({ previous, next in
            WorkspaceFileContextStore.compareUTF8Binary(
                previous.standardizedRelativePath,
                next.standardizedRelativePath
            ) == .orderedAscending
        }), zip(snapshot.searchBase.stableOrdinals, snapshot.searchBase.stableOrdinals.dropFirst())
            .allSatisfy({ previous, next in previous < next })
        else { return nil }

        let additionalChanged = additionalChangedRelativePaths
        var remainingAdditionalChangedCount = additionalChanged.count
        var targets = [WorkspaceSearchCatalogEntry?](
            repeating: nil,
            count: snapshot.searchBase.relativePaths.count
        )
        var overlayEntries: [WorkspaceSearchCatalogEntry] = []
        var authoritativeIndex = 0
        var planChangedPathCount = 0

        do {
            let reader = try planHandle.makeReader()
            while let record = try reader.next() {
                guard let relativePath = String(data: record.relativePathBytes, encoding: .utf8) else {
                    return nil
                }
                let standardizedRelativePath = StandardizedPath.relative(relativePath)
                while authoritativeIndex < authoritativeEntries.count,
                      WorkspaceFileContextStore.compareUTF8Binary(
                          authoritativeEntries[authoritativeIndex].standardizedRelativePath,
                          standardizedRelativePath
                      ) == .orderedAscending
                {
                    let addition = authoritativeEntries[authoritativeIndex]
                    guard try additionalChanged.contains(addition.standardizedRelativePath) else { return nil }
                    overlayEntries.append(addition)
                    authoritativeIndex += 1
                }

                let matchedEntry: WorkspaceSearchCatalogEntry? = if authoritativeIndex < authoritativeEntries.count,
                                                                    WorkspaceFileContextStore.compareUTF8Binary(
                                                                        authoritativeEntries[authoritativeIndex]
                                                                            .standardizedRelativePath,
                                                                        standardizedRelativePath
                                                                    ) == .orderedSame
                {
                    authoritativeEntries[authoritativeIndex]
                } else {
                    nil
                }

                switch record.disposition {
                case .ordinaryFile:
                    switch record.baseAction {
                    case .reuse:
                        if try additionalChanged.contains(standardizedRelativePath) {
                            if let matchedEntry { overlayEntries.append(matchedEntry) }
                        } else {
                            guard let matchedEntry,
                                  let baseOrdinal = record.baseOrdinal,
                                  let baseIndex = Self.baseSearchIndex(
                                      for: baseOrdinal,
                                      stableOrdinals: snapshot.searchBase.stableOrdinals
                                  ),
                                  snapshot.searchBase.relativePaths[baseIndex] == standardizedRelativePath
                            else { return nil }
                            targets[baseIndex] = matchedEntry
                        }
                    case .overlay, .none:
                        planChangedPathCount += 1
                        if try additionalChanged.contains(standardizedRelativePath) {
                            remainingAdditionalChangedCount -= 1
                        }
                        guard let matchedEntry else {
                            guard try additionalChanged.contains(standardizedRelativePath) else { return nil }
                            break
                        }
                        overlayEntries.append(matchedEntry)
                    case .tombstone:
                        return nil
                    }
                case .baseTombstone:
                    planChangedPathCount += 1
                    if try additionalChanged.contains(standardizedRelativePath) {
                        remainingAdditionalChangedCount -= 1
                        if let matchedEntry { overlayEntries.append(matchedEntry) }
                    } else if matchedEntry != nil {
                        return nil
                    }
                case .ordinaryDirectory, .policyIgnoredTrackedFile:
                    if let matchedEntry {
                        guard try additionalChanged.contains(standardizedRelativePath) else { return nil }
                        overlayEntries.append(matchedEntry)
                    }
                }
                if matchedEntry != nil { authoritativeIndex += 1 }
            }
        } catch {
            return nil
        }

        while authoritativeIndex < authoritativeEntries.count {
            let addition = authoritativeEntries[authoritativeIndex]
            guard (try? additionalChanged.contains(addition.standardizedRelativePath)) == true else { return nil }
            overlayEntries.append(addition)
            authoritativeIndex += 1
        }
        let resolvedBaseEntryCount = targets.compactMap(\.self).count
        guard resolvedBaseEntryCount + overlayEntries.count == authoritativeEntries.count else { return nil }

        relativeBase = snapshot.searchBase
        targetEntriesByBaseIndex = targets
        let affectedRelativePaths: AffectedRelativePaths
        do {
            affectedRelativePaths = try AffectedRelativePaths(
                changed: additionalChanged,
                entries: overlayEntries
            )
        } catch {
            return nil
        }
        overlaySegmentHead = affectedRelativePaths.isEmpty
            ? nil
            : OverlaySegment(
                entries: overlayEntries,
                affectedRelativePaths: affectedRelativePaths,
                previous: nil
            )
        entries = authoritativeEntries
        baseEntryCount = resolvedBaseEntryCount
        overlayEntryCount = overlayEntries.count
        tombstoneCount = targets.count - baseEntryCount
        accumulatedChangedRelativePathCount = planChangedPathCount + remainingAdditionalChangedCount
        unsegmentedChangedPathCount = max(
            0,
            accumulatedChangedRelativePathCount - affectedRelativePaths.count
        )
        displayPrefix = projectedDisplayPrefix
        absolutePrefix = projectedAbsolutePrefix
    }

    private static func baseSearchIndex(for ordinal: UInt64, stableOrdinals: [Int]) -> Int? {
        guard let target = Int(exactly: ordinal) else { return nil }
        var lowerBound = 0
        var upperBound = stableOrdinals.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if stableOrdinals[middle] < target {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        guard lowerBound < stableOrdinals.count, stableOrdinals[lowerBound] == target else { return nil }
        return lowerBound
    }

    private static func baseSearchIndex(forRelativePath path: String, relativePaths: [String]) -> Int? {
        var lowerBound = 0
        var upperBound = relativePaths.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if WorkspaceFileContextStore.compareUTF8Binary(relativePaths[middle], path) == .orderedAscending {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        guard lowerBound < relativePaths.count,
              WorkspaceFileContextStore.compareUTF8Binary(relativePaths[lowerBound], path) == .orderedSame
        else { return nil }
        return lowerBound
    }

    private static func entryIndex(
        relativePath: String,
        entries: [WorkspaceSearchCatalogEntry]
    ) -> Int? {
        var lowerBound = 0
        var upperBound = entries.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if WorkspaceFileContextStore.compareUTF8Binary(
                entries[middle].standardizedRelativePath,
                relativePath
            ) == .orderedAscending {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        guard lowerBound < entries.count,
              WorkspaceFileContextStore.compareUTF8Binary(
                  entries[lowerBound].standardizedRelativePath,
                  relativePath
              ) == .orderedSame
        else { return nil }
        return lowerBound
    }

    #if DEBUG
        init?(
            snapshot: WorkspaceRootReusableSnapshot,
            changedRelativeFilePaths: Set<String>,
            tombstonedBaseRelativeFilePaths: Set<String>,
            root: WorkspaceRootRecord,
            authoritativeEntries: [WorkspaceSearchCatalogEntry]
        ) {
            let changed = Set(
                changedRelativeFilePaths
                    .union(tombstonedBaseRelativeFilePaths)
                    .map(StandardizedPath.relative)
            )
            let entriesByRelativePath = Dictionary(
                authoritativeEntries.map { ($0.standardizedRelativePath, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let projectedDisplayPrefix = root.name + "/"
            let projectedAbsolutePrefix = root.standardizedFullPath + "/"
            guard authoritativeEntries.allSatisfy({ entry in
                entry.displayPath == projectedDisplayPrefix + entry.standardizedRelativePath
                    && entry.standardizedFullPath == projectedAbsolutePrefix + entry.standardizedRelativePath
            }) else { return nil }
            var targets: [WorkspaceSearchCatalogEntry?] = []
            targets.reserveCapacity(snapshot.searchBase.relativePaths.count)
            var baseRelativePaths = Set<String>()
            for relativePath in snapshot.searchBase.relativePaths {
                let standardized = StandardizedPath.relative(relativePath)
                baseRelativePaths.insert(standardized)
                if changed.contains(standardized) {
                    targets.append(nil)
                } else {
                    guard let entry = entriesByRelativePath[standardized] else { return nil }
                    targets.append(entry)
                }
            }

            relativeBase = snapshot.searchBase
            targetEntriesByBaseIndex = targets
            let overlayEntries = authoritativeEntries.filter {
                changed.contains($0.standardizedRelativePath)
                    || !baseRelativePaths.contains($0.standardizedRelativePath)
            }
            let affectedRelativePaths = changed.union(overlayEntries.map(\.standardizedRelativePath))
            overlaySegmentHead = affectedRelativePaths.isEmpty
                ? nil
                : OverlaySegment(
                    entries: overlayEntries,
                    affectedRelativePaths: AffectedRelativePaths(affectedRelativePaths),
                    previous: nil
                )
            entries = authoritativeEntries
            baseEntryCount = targets.compactMap(\.self).count
            overlayEntryCount = overlayEntries.count
            tombstoneCount = targets.count - baseEntryCount
            accumulatedChangedRelativePathCount = affectedRelativePaths.count
            unsegmentedChangedPathCount = 0
            displayPrefix = projectedDisplayPrefix
            absolutePrefix = projectedAbsolutePrefix
        }
    #endif

    private init?(
        relativeBase: WorkspaceSearchRelativePathBase,
        targetEntriesByBaseIndex: [WorkspaceSearchCatalogEntry?],
        overlaySegmentHead: OverlaySegment?,
        unsegmentedChangedPathCount: Int,
        displayPrefix: String,
        absolutePrefix: String,
        changedRelativePaths: Set<String>,
        authoritativeEntries: [WorkspaceSearchCatalogEntry]
    ) {
        let changed = Set(changedRelativePaths.map(StandardizedPath.relative))
        guard authoritativeEntries.allSatisfy({ entry in
            entry.displayPath == displayPrefix + entry.standardizedRelativePath
                && entry.standardizedFullPath == absolutePrefix + entry.standardizedRelativePath
        })
        else { return nil }

        let previouslySegmentedPaths = Self.affectedPathsNewestFirst(overlaySegmentHead)
        var nextUnsegmentedChangedPathCount = unsegmentedChangedPathCount
        for path in changed where !Self.contains(path, in: previouslySegmentedPaths) {
            if let baseIndex = Self.baseSearchIndex(
                forRelativePath: path,
                relativePaths: relativeBase.relativePaths
            ), targetEntriesByBaseIndex[baseIndex] == nil {
                nextUnsegmentedChangedPathCount = max(0, nextUnsegmentedChangedPathCount - 1)
            }
        }

        let segmentEntries = authoritativeEntries.filter { changed.contains($0.standardizedRelativePath) }
        var nextSegmentHead = OverlaySegment(
            entries: segmentEntries,
            affectedRelativePaths: AffectedRelativePaths(changed),
            previous: overlaySegmentHead
        )
        if nextSegmentHead.depth > Self.maximumOverlaySegmentCount {
            nextSegmentHead = OverlaySegment.compact(nextSegmentHead)
        }

        let allAffectedRelativePaths = Self.affectedPathsNewestFirst(nextSegmentHead)
        self.relativeBase = relativeBase
        self.targetEntriesByBaseIndex = targetEntriesByBaseIndex
        self.overlaySegmentHead = nextSegmentHead
        entries = authoritativeEntries
        baseEntryCount = targetEntriesByBaseIndex.lazy.compactMap(\.self).count(where: {
            !Self.contains($0.standardizedRelativePath, in: allAffectedRelativePaths)
        })
        overlayEntryCount = authoritativeEntries.count - baseEntryCount
        tombstoneCount = targetEntriesByBaseIndex.count - baseEntryCount
        accumulatedChangedRelativePathCount = nextUnsegmentedChangedPathCount
            + Self.uniquePathCount(allAffectedRelativePaths)
        self.unsegmentedChangedPathCount = nextUnsegmentedChangedPathCount
        self.displayPrefix = displayPrefix
        self.absolutePrefix = absolutePrefix
    }

    private static func affectedPathsNewestFirst(_ head: OverlaySegment?) -> [AffectedRelativePaths] {
        var result: [AffectedRelativePaths] = []
        var segment = head
        while let current = segment {
            current.visitLeavesNewestFirst { result.append($0.affectedRelativePaths) }
            segment = current.previous
        }
        return result
    }

    private static func contains(
        _ relativePath: String,
        in affectedPaths: [AffectedRelativePaths]
    ) -> Bool {
        affectedPaths.contains { $0.contains(relativePath) }
    }

    private static func uniquePathCount(_ affectedPaths: [AffectedRelativePaths]) -> Int {
        var result = 0
        for index in affectedPaths.indices {
            affectedPaths[index].visit { path in
                var isShadowed = false
                for newerIndex in 0 ..< index where affectedPaths[newerIndex].contains(path) {
                    isShadowed = true
                    break
                }
                if !isShadowed { result += 1 }
            }
        }
        return result
    }

    func applyingPatch(
        entries: [WorkspaceSearchCatalogEntry],
        changedRelativePaths: Set<String>
    ) -> WorkspaceProjectedPathSearchIndex? {
        WorkspaceProjectedPathSearchIndex(
            relativeBase: relativeBase,
            targetEntriesByBaseIndex: targetEntriesByBaseIndex,
            overlaySegmentHead: overlaySegmentHead,
            unsegmentedChangedPathCount: unsegmentedChangedPathCount,
            displayPrefix: displayPrefix,
            absolutePrefix: absolutePrefix,
            changedRelativePaths: changedRelativePaths,
            authoritativeEntries: entries
        )
    }

    func search(_ query: String, limit: Int) -> [Candidate] {
        guard limit > 0 else { return [] }
        var (candidateLists, suppressedRelativePaths) = overlayCandidateLists(query: query, limit: limit)
        let boundedBaseLimit = min(targetEntriesByBaseIndex.count, limit)
        let baseOverfetch = min(
            tombstoneCount,
            targetEntriesByBaseIndex.count - boundedBaseLimit
        )
        let baseCandidates = relativeBase.index.searchProjectedSynchronously(
            query,
            displayPrefix: displayPrefix,
            absolutePrefix: absolutePrefix,
            limit: boundedBaseLimit + baseOverfetch
        ).compactMap { candidate -> Candidate? in
            guard targetEntriesByBaseIndex.indices.contains(candidate.index),
                  let entry = targetEntriesByBaseIndex[candidate.index],
                  !Self.contains(entry.standardizedRelativePath, in: suppressedRelativePaths)
            else { return nil }
            return Candidate(entry: entry, score: candidate.score, tieBreakKey: candidate.tieBreakKey)
        }
        if !baseCandidates.isEmpty { candidateLists.append(baseCandidates) }
        return Self.merge(candidateLists, limit: limit)
    }

    func searchCancellable(
        _ query: String,
        limit: Int
    ) async -> CancellableSearchOutcome {
        guard limit > 0 else {
            return .completed([], .init(
                examinedCount: 0,
                matchedCount: 0,
                heapPeakCount: 0,
                heapComparisonCount: 0,
                scratchBytes: 0
            ))
        }
        var (candidateLists, suppressedRelativePaths) = overlayCandidateLists(query: query, limit: limit)
        let boundedBaseLimit = min(targetEntriesByBaseIndex.count, limit)
        let baseOverfetch = min(
            tombstoneCount,
            targetEntriesByBaseIndex.count - boundedBaseLimit
        )
        let baseOutcome = await relativeBase.index.searchProjected(
            query,
            displayPrefix: displayPrefix,
            absolutePrefix: absolutePrefix,
            limit: boundedBaseLimit + baseOverfetch
        )
        let baseCandidates: [Candidate]
        let diagnostics: PathSearchIndex.ProjectedSearchDiagnostics
        switch baseOutcome {
        case let .cancelled(value):
            return .cancelled(value)
        case let .completed(candidates, value):
            diagnostics = value
            baseCandidates = candidates.compactMap { candidate -> Candidate? in
                guard targetEntriesByBaseIndex.indices.contains(candidate.index),
                      let entry = targetEntriesByBaseIndex[candidate.index],
                      !Self.contains(entry.standardizedRelativePath, in: suppressedRelativePaths)
                else { return nil }
                return Candidate(entry: entry, score: candidate.score, tieBreakKey: candidate.tieBreakKey)
            }
        }
        guard !Task.isCancelled else { return .cancelled(diagnostics) }
        if !baseCandidates.isEmpty { candidateLists.append(baseCandidates) }
        return .completed(Self.merge(candidateLists, limit: limit), diagnostics)
    }

    var overlaySegmentCountForTesting: Int {
        overlaySegmentHead?.depth ?? 0
    }

    private func overlayCandidateLists(
        query: String,
        limit: Int
    ) -> ([[Candidate]], [AffectedRelativePaths]) {
        var candidateLists: [[Candidate]] = []
        var suppressedRelativePaths: [AffectedRelativePaths] = []
        var segment = overlaySegmentHead
        while let current = segment {
            current.visitLeavesNewestFirst { leaf in
                let boundedSegmentLimit = min(limit, leaf.entries.count)
                let segmentOverfetch = min(
                    suppressedRelativePaths.reduce(0) { $0 + $1.count },
                    leaf.entries.count - boundedSegmentLimit
                )
                let candidates = leaf.index?.searchSynchronously(
                    query,
                    limit: boundedSegmentLimit + segmentOverfetch
                ).compactMap { candidate -> Candidate? in
                    guard leaf.entries.indices.contains(candidate.index) else { return nil }
                    let entry = leaf.entries[candidate.index]
                    guard !Self.contains(entry.standardizedRelativePath, in: suppressedRelativePaths) else {
                        return nil
                    }
                    return Candidate(entry: entry, score: candidate.score, tieBreakKey: candidate.tieBreakKey)
                } ?? []
                if !candidates.isEmpty { candidateLists.append(candidates) }
                suppressedRelativePaths.append(leaf.affectedRelativePaths)
            }
            segment = current.previous
        }
        return (candidateLists, suppressedRelativePaths)
    }

    private static func merge(_ candidateLists: [[Candidate]], limit: Int) -> [Candidate] {
        var candidateOffsets = Array(repeating: 0, count: candidateLists.count)
        var results: [Candidate] = []
        results.reserveCapacity(limit)
        while results.count < limit {
            var bestListIndex: Int?
            for listIndex in candidateLists.indices
                where candidateOffsets[listIndex] < candidateLists[listIndex].count
            {
                guard let currentBest = bestListIndex else {
                    bestListIndex = listIndex
                    continue
                }
                if candidatePrecedes(
                    candidateLists[listIndex][candidateOffsets[listIndex]],
                    candidateLists[currentBest][candidateOffsets[currentBest]]
                ) {
                    bestListIndex = listIndex
                }
            }
            guard let bestListIndex else { break }
            results.append(candidateLists[bestListIndex][candidateOffsets[bestListIndex]])
            candidateOffsets[bestListIndex] += 1
        }
        return results
    }

    private static func candidatePrecedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.score != rhs.score { return lhs.score > rhs.score }
        switch WorkspaceFileContextStore.compareUTF8Binary(lhs.tieBreakKey, rhs.tieBreakKey) {
        case .orderedAscending:
            return true
        case .orderedDescending:
            return false
        case .orderedSame:
            return WorkspaceFileContextStore.searchCatalogEntryPrecedes(lhs.entry, rhs.entry)
        }
    }
}

extension WorkspaceSearchCatalogEntry {
    var pathSearchIndexKey: String {
        // Preserve the existing one-record index behavior for both UI display paths and absolute
        // path consumers. This exact string is also the global lexical tie-break key.
        displayPath + "\n" + standardizedFullPath
    }
}

// MARK: - LRU Cache Actor

/// Thread-safe LRU cache implementation using actors
actor LRUCacheActor<Key: Hashable, Value> {
    private struct Entry {
        let value: Value
        var timestamp: Date
    }

    private var cache: [Key: Entry] = [:]
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    func value(for key: Key) -> Value? {
        if var entry = cache[key] {
            entry.timestamp = Date()
            cache[key] = entry
            return entry.value
        }
        return nil
    }

    func set(_ value: Value, for key: Key) {
        cache[key] = Entry(value: value, timestamp: Date())

        // Evict oldest if over capacity
        if cache.count > capacity {
            let oldest = cache.min { $0.value.timestamp < $1.value.timestamp }
            if let oldestKey = oldest?.key {
                cache.removeValue(forKey: oldestKey)
            }
        }
    }

    func clear() {
        cache.removeAll()
    }
}

// MARK: - C Bridge Functions

@_silgen_name("path_search_create")
func path_search_create(_ paths: UnsafePointer<UnsafePointer<CChar>?>?, _ count: Int) -> OpaquePointer?

@_silgen_name("path_search_destroy")
func path_search_destroy(_ index: OpaquePointer?)

@_silgen_name("path_search_find")
func path_search_find(_ index: OpaquePointer?, _ pattern: UnsafePointer<CChar>?, _ limit: Int) -> OpaquePointer?

@_silgen_name("path_search_projected_find")
func path_search_projected_find(
    _ index: OpaquePointer?,
    _ pattern: UnsafePointer<CChar>?,
    _ displayPrefix: UnsafePointer<CChar>?,
    _ absolutePrefix: UnsafePointer<CChar>?,
    _ limit: Int
) -> OpaquePointer?

@_silgen_name("path_search_projected_find_cancellable")
func path_search_projected_find_cancellable(
    _ index: OpaquePointer?,
    _ pattern: UnsafePointer<CChar>?,
    _ displayPrefix: UnsafePointer<CChar>?,
    _ absolutePrefix: UnsafePointer<CChar>?,
    _ limit: Int,
    _ cancellation: OpaquePointer?,
    _ stats: UnsafeMutablePointer<path_search_work_stats_t>?
) -> OpaquePointer?

@_silgen_name("path_search_cancellation_create")
func path_search_cancellation_create() -> OpaquePointer?

@_silgen_name("path_search_cancellation_cancel")
func path_search_cancellation_cancel(_ cancellation: OpaquePointer?)

@_silgen_name("path_search_cancellation_destroy")
func path_search_cancellation_destroy(_ cancellation: OpaquePointer?)

@_silgen_name("search_result_destroy")
func search_result_destroy(_ result: OpaquePointer?)

struct search_result_t {
    var indices: UnsafeMutablePointer<size_t>?
    var scores: UnsafeMutablePointer<Int32>?
    var tieBreakKeys: UnsafeMutablePointer<UnsafePointer<CChar>?>?
    var count: size_t
    var capacity: size_t
}

struct path_search_work_stats_t {
    var examinedCount: size_t = 0
    var matchedCount: size_t = 0
    var heapPeakCount: size_t = 0
    var heapComparisonCount: size_t = 0
    var scratchBytes: size_t = 0
    var cancelled = false
}
