import Foundation
import RepoPromptC
import RepoPromptFileSystem
import RepoPromptWorkspaceCore

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
    let keyByteCount: Int

    init(paths: [String]) {
        originalPaths = paths
        keyByteCount = paths.reduce(0) { $0 + $1.utf8.count }
        filenames = paths.map { path in
            // Candidate filename metadata preserves original bytes; the matcher uses the original keys.
            let bytes = path.utf8
            let start = bytes.lastIndex(of: 0x2F).map { bytes.index(after: $0) } ?? bytes.startIndex
            let filename = String(decoding: bytes[start...], as: UTF8.self)
            guard !filename.isEmpty, filename != ".", filename != ".." else {
                return URL(fileURLWithPath: path).lastPathComponent
            }
            return filename
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

/// Allow one additional fresh-index unit for returned candidates and retained key bytes.
/// Rebase when candidate overfetch or duplicated key storage exceeds that allowance; matcher scans are separate.
struct WorkspacePathSearchCompactionPolicy {
    let maximumWorkRatio: Int

    init(maximumWorkRatio: Int) {
        precondition(maximumWorkRatio >= 1)
        self.maximumWorkRatio = maximumWorkRatio
    }

    static let production = Self(maximumWorkRatio: 2)

    func shouldRebase(
        baseCount: Int, currentCount: Int, overlayCount: Int, suppressedCount: Int,
        retainedKeyBytes: Int, freshKeyBytes: Int
    ) -> Bool {
        let limit = 1024
        let work = min(overlayCount, limit) + min(baseCount, limit + min(suppressedCount, baseCount))
        let freshWork = min(currentCount, limit)
        return exceedsBudget(work, reference: freshWork)
            || exceedsBudget(retainedKeyBytes, reference: freshKeyBytes)
    }

    private func exceedsBudget(_ value: Int, reference: Int) -> Bool {
        guard reference > 0 else { return value > 0 }
        let (budget, overflow) = reference.multipliedReportingOverflow(by: maximumWorkRatio)
        return !overflow && value > budget
    }
}

struct WorkspacePathSearchOverlayHistoryMetrics: Equatable {
    let recentPayloadCount: Int
    let compactedPageCount: Int
    let compactedPayloadCount: Int
    let maximumCompactedPagePayloadCount: Int

    var totalPayloadCount: Int {
        recentPayloadCount + compactedPayloadCount
    }

    var isWithinStructuralBounds: Bool {
        recentPayloadCount <= 16
            && maximumCompactedPagePayloadCount <= 17
            && compactedPayloadCount == compactedPageCount * 17
    }
}

/// Persistent newest-first overlay storage for materialized path indexes.
///
/// Recent payloads are copied only within a fixed bound. Full batches move into immutable pages;
/// pages share older tails across retained generations without nesting payload histories.
struct WorkspacePathSearchOverlayHistory<Payload>: @unchecked Sendable {
    private static var maximumRecentPayloadCount: Int {
        16
    }

    private static var compactedPagePayloadCount: Int {
        maximumRecentPayloadCount + 1
    }

    /// `previous` changes only during teardown after uniqueness has been established for that page.
    private final class Page: @unchecked Sendable {
        let payloadsNewestFirst: [Payload]
        var previous: Page?

        init(payloadsNewestFirst: [Payload], previous: Page?) {
            precondition(payloadsNewestFirst.count == WorkspacePathSearchOverlayHistory.compactedPagePayloadCount)
            self.payloadsNewestFirst = payloadsNewestFirst
            self.previous = previous
        }

        deinit {
            // Retain the tail before severing this page's link. Iteratively dismantle only a unique
            // prefix; a retained generation or active traversal may still own any shared tail.
            var tail = previous
            previous = nil
            while tail != nil, isKnownUniquelyReferenced(&tail) {
                let next = tail?.previous
                tail?.previous = nil
                tail = next
            }
        }
    }

    private let recentPayloadsNewestFirst: [Payload]
    private let compactedPageHead: Page?

    init() {
        recentPayloadsNewestFirst = []
        compactedPageHead = nil
    }

    private init(recentPayloadsNewestFirst: [Payload], compactedPageHead: Page?) {
        precondition(recentPayloadsNewestFirst.count <= Self.maximumRecentPayloadCount)
        self.recentPayloadsNewestFirst = recentPayloadsNewestFirst
        self.compactedPageHead = compactedPageHead
    }

    func appending(_ payload: Payload) -> Self {
        if recentPayloadsNewestFirst.count < Self.maximumRecentPayloadCount {
            var recent = [payload]
            recent.reserveCapacity(recentPayloadsNewestFirst.count + 1)
            recent.append(contentsOf: recentPayloadsNewestFirst)
            return Self(recentPayloadsNewestFirst: recent, compactedPageHead: compactedPageHead)
        }

        var pagePayloads = [payload]
        pagePayloads.reserveCapacity(Self.compactedPagePayloadCount)
        pagePayloads.append(contentsOf: recentPayloadsNewestFirst)
        return Self(
            recentPayloadsNewestFirst: [],
            compactedPageHead: Page(payloadsNewestFirst: pagePayloads, previous: compactedPageHead)
        )
    }

    func visitNewestFirst(_ body: (Payload) -> Void) {
        recentPayloadsNewestFirst.forEach(body)
        var page = compactedPageHead
        while let current = page {
            current.payloadsNewestFirst.forEach(body)
            page = current.previous
        }
    }

    var metricsForTesting: WorkspacePathSearchOverlayHistoryMetrics {
        var pageCount = 0
        var payloadCount = 0
        var maximumPagePayloadCount = 0
        var page = compactedPageHead
        while let current = page {
            pageCount += 1
            payloadCount += current.payloadsNewestFirst.count
            maximumPagePayloadCount = max(maximumPagePayloadCount, current.payloadsNewestFirst.count)
            page = current.previous
        }
        return WorkspacePathSearchOverlayHistoryMetrics(
            recentPayloadCount: recentPayloadsNewestFirst.count,
            compactedPageCount: pageCount,
            compactedPayloadCount: payloadCount,
            maximumCompactedPagePayloadCount: maximumPagePayloadCount
        )
    }
}

/// Immutable root-local search projection retained by catalog snapshots and active readers.
///
/// Shard patches share an immutable base and replace zero or one live overlay.
/// A synchronous rebase bounds overfetch and retained keys without mutating older readers.
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

    private final class MaterializedBase: @unchecked Sendable {
        let entries: [WorkspaceSearchCatalogEntry]
        let index: PathSearchIndex
        let positionByID: [UUID: Int]

        init(entries: [WorkspaceSearchCatalogEntry]) {
            self.entries = entries
            positionByID = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.id, $0.offset) })
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

    private struct OverlaySegment: @unchecked Sendable {
        let entries: [WorkspaceSearchCatalogEntry]
        let index: PathSearchIndex?
        let affectedEntryIDs: Set<UUID>

        init(entries: [WorkspaceSearchCatalogEntry], affectedEntryIDs: Set<UUID>) {
            self.entries = entries
            index = entries.isEmpty ? nil : PathSearchIndex(paths: entries.map(\.pathSearchIndexKey))
            self.affectedEntryIDs = affectedEntryIDs
        }
    }

    let identity: WorkspaceSearchRootPathIndexIdentity
    let rootPath: String
    let entries: [WorkspaceSearchCatalogEntry]
    let buildKind: BuildKind

    private let base: MaterializedBase?
    private let projectedIndex: WorkspaceProjectedPathSearchIndex?
    private let overlayHistory: WorkspacePathSearchOverlayHistory<OverlaySegment>
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
        overlayHistory = WorkspacePathSearchOverlayHistory()
        self.shadowControl = shadowControl
    }

    private init(
        identity: WorkspaceSearchRootPathIndexIdentity,
        rootPath: String,
        entries: [WorkspaceSearchCatalogEntry],
        buildKind: BuildKind,
        base: MaterializedBase,
        overlayHistory: WorkspacePathSearchOverlayHistory<OverlaySegment>,
        shadowControl: WorkspaceProjectedPathSearchShadowControl?
    ) {
        self.identity = identity
        self.rootPath = rootPath
        self.entries = entries
        self.buildKind = buildKind
        self.base = base
        projectedIndex = nil
        self.overlayHistory = overlayHistory
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
        overlayHistory = WorkspacePathSearchOverlayHistory()
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
        changedFileIDs: Set<UUID>,
        policy: WorkspacePathSearchCompactionPolicy = .production
    ) -> WorkspaceSearchRootPathIndex {
        guard identity.rootID == self.identity.rootID,
              identity.lifetimeID == self.identity.lifetimeID
        else {
            return WorkspaceSearchRootPathIndex(identity: identity, rootPath: rootPath, entries: entries)
        }

        if !changedFileIDs.isEmpty { shadowControl?.invalidate() }
        let unchanged: Bool
        if changedFileIDs.isEmpty {
            unchanged = true
        } else if entries.count == self.entries.count, changedFileIDs.count == 1,
                  let id = changedFileIDs.first,
                  let old = self.entries.first(where: { $0.id == id }),
                  let new = entries.first(where: { $0.id == id })
        {
            unchanged = old.isByteIdentical(to: new)
        } else {
            let old = self.entries.filter { changedFileIDs.contains($0.id) }
            let new = entries.filter { changedFileIDs.contains($0.id) }
            unchanged = entries.count == self.entries.count && old.count == changedFileIDs.count
                && new.count == old.count && zip(old, new).allSatisfy { previous, current in
                    previous.isByteIdentical(to: current)
                }
        }
        guard !unchanged else {
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
                overlayHistory: overlayHistory,
                shadowControl: shadowControl
            )
        }

        if let projectedIndex {
            var resolvedFileIDs = Set<UUID>()
            for previous in self.entries where changedFileIDs.contains(previous.id) {
                resolvedFileIDs.insert(previous.id)
            }
            for current in entries where changedFileIDs.contains(current.id) {
                resolvedFileIDs.insert(current.id)
            }
            guard resolvedFileIDs == changedFileIDs else {
                return WorkspaceSearchRootPathIndex(identity: identity, rootPath: rootPath, entries: entries)
            }
            guard let nextProjectedIndex = projectedIndex.applyingPatch(
                entries: entries,
                policy: policy
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

        // An empty base has no reusable C keys; initialize the first nonempty base directly.
        guard let base, !base.entries.isEmpty else {
            return WorkspaceSearchRootPathIndex(identity: identity, rootPath: rootPath, entries: entries)
        }
        var suppressed = Set<UUID>()
        overlayHistory.visitNewestFirst { suppressed.formUnion($0.affectedEntryIDs) }
        suppressed.formUnion(changedFileIDs.filter { base.positionByID[$0] != nil })
        var segmentEntries: [WorkspaceSearchCatalogEntry] = []
        for entry in entries {
            guard let position = base.positionByID[entry.id] else {
                segmentEntries.append(entry)
                continue
            }
            if suppressed.contains(entry.id) {
                if base.entries[position].isByteIdentical(to: entry) {
                    suppressed.remove(entry.id)
                } else {
                    segmentEntries.append(entry)
                }
            }
        }
        guard base.entries.count - suppressed.count + segmentEntries.count == entries.count else {
            return WorkspaceSearchRootPathIndex(identity: identity, rootPath: rootPath, entries: entries)
        }
        let overlayBytes = segmentEntries.reduce(0) { $0 + $1.pathSearchKeyByteCount }
        if policy.shouldRebase(
            baseCount: base.entries.count, currentCount: entries.count,
            overlayCount: segmentEntries.count, suppressedCount: suppressed.count,
            retainedKeyBytes: base.index.keyByteCount + overlayBytes,
            freshKeyBytes: entries.reduce(0) { $0 + $1.pathSearchKeyByteCount }
        ) {
            return WorkspaceSearchRootPathIndex(identity: identity, rootPath: rootPath, entries: entries)
        }
        let nextOverlayHistory = suppressed.isEmpty && segmentEntries.isEmpty
            ? WorkspacePathSearchOverlayHistory<OverlaySegment>()
            : WorkspacePathSearchOverlayHistory().appending(OverlaySegment(
                entries: segmentEntries,
                affectedEntryIDs: suppressed
            ))
        return WorkspaceSearchRootPathIndex(
            identity: identity,
            rootPath: rootPath,
            entries: entries,
            buildKind: .overlay,
            base: base,
            overlayHistory: nextOverlayHistory,
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
        overlayHistory.visitNewestFirst { segment in
            let boundedSegmentLimit = min(limit, segment.entries.count)
            let segmentOverfetch = min(
                suppressedEntryIDs.count,
                segment.entries.count - boundedSegmentLimit
            )
            let candidates = segment.index?
                .searchSynchronously(
                    query,
                    limit: boundedSegmentLimit + segmentOverfetch
                )
                .compactMap { candidate -> Candidate? in
                    guard segment.entries.indices.contains(candidate.index) else { return nil }
                    let entry = segment.entries[candidate.index]
                    guard !suppressedEntryIDs.contains(entry.id) else { return nil }
                    return Candidate(entry: entry, score: candidate.score, tieBreakKey: candidate.tieBreakKey)
                } ?? []
            if !candidates.isEmpty { candidateLists.append(candidates) }
            suppressedEntryIDs.formUnion(segment.affectedEntryIDs)
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
                WorkspaceContextStartupInstrumentation.recordProjectedSearchComparison(
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
            WorkspaceContextStartupInstrumentation.recordProjectedSearchComparison(
                matched: matched,
                baseEntryCount: shadowProjection.baseEntryCount,
                overlayEntryCount: shadowProjection.overlayEntryCount,
                tombstoneCount: shadowProjection.tombstoneCount
            )
        }
    }

    var baseOwnerForTesting: AnyObject {
        if let projectedIndex { return projectedIndex.baseOwnerForTesting }
        return base!
    }

    var overlayOwnersForTesting: [AnyObject] {
        if let projectedIndex { return projectedIndex.overlayOwnersForTesting }
        var result: [AnyObject] = []
        overlayHistory.visitNewestFirst { if let index = $0.index { result.append(index) } }
        return result
    }

    var suppressionIsBaseSubsetForTesting: Bool {
        guard let base else { return true }
        var valid = true
        overlayHistory.visitNewestFirst { segment in
            valid = valid && segment.affectedEntryIDs.allSatisfy { base.positionByID[$0] != nil }
        }
        return valid
    }

    var projectedStorageOwnerForTesting: AnyObject? {
        projectedIndex
    }

    var usesSharedRelativeBaseForTesting: Bool {
        projectedIndex?.usesSharedBaseForTesting ?? false
    }

    var projectedEffectiveChangedPathCount: Int? {
        projectedIndex?.effectiveChangedRelativePathCount
    }

    var overlayHistoryMetricsForTesting: WorkspacePathSearchOverlayHistoryMetrics {
        projectedIndex?.overlayHistoryMetricsForTesting ?? overlayHistory.metricsForTesting
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

    private enum RelativeBase {
        case shared(WorkspaceSearchRelativePathBase)
        case local(PathSearchIndex)

        var index: PathSearchIndex {
            switch self {
            case let .shared(base): base.index
            case let .local(index): index
            }
        }

        var owner: AnyObject {
            switch self {
            case let .shared(base): base
            case let .local(index): index
            }
        }

        var isShared: Bool {
            if case .shared = self { return true }
            return false
        }
    }

    let entries: [WorkspaceSearchCatalogEntry]
    let baseEntryCount: Int
    let overlayEntryCount: Int
    let tombstoneCount: Int
    var effectiveChangedRelativePathCount: Int {
        tombstoneCount + overlayEntryCount
    }

    private let relativeBase: RelativeBase
    private let targetPositionsByBaseIndex: [Int]
    private let overlayEntries: [WorkspaceSearchCatalogEntry]
    private let overlayIndex: PathSearchIndex?
    private let displayPrefix: String
    private let absolutePrefix: String

    convenience init?(
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
            Self.hasExactPrefix(entry.displayPath, prefix: projectedDisplayPrefix, suffix: entry.standardizedRelativePath)
                && Self.hasExactPrefix(entry.standardizedFullPath, prefix: projectedAbsolutePrefix, suffix: entry.standardizedRelativePath)
        }), zip(authoritativeEntries, authoritativeEntries.dropFirst()).allSatisfy({ previous, next in
            WorkspaceFileContextStore.compareUTF8Binary(
                previous.standardizedRelativePath,
                next.standardizedRelativePath
            ) == .orderedAscending
        }), zip(snapshot.searchBase.stableOrdinals, snapshot.searchBase.stableOrdinals.dropFirst())
            .allSatisfy({ previous, next in previous < next })
        else { return nil }

        let additionalChanged = additionalChangedRelativePaths
        var resolvedBaseEntryCount = 0
        var validatedOverlayCount = 0
        var authoritativeIndex = 0

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
                    validatedOverlayCount += 1
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

                if record.disposition == .ordinaryFile, record.baseAction == .reuse {
                    guard let ordinal = record.baseOrdinal,
                          let position = Self.baseSearchIndex(for: ordinal, stableOrdinals: snapshot.searchBase.stableOrdinals),
                          snapshot.searchBase.relativePaths[position].utf8.elementsEqual(standardizedRelativePath.utf8)
                    else { return nil }
                }
                switch record.disposition {
                case .ordinaryFile:
                    switch record.baseAction {
                    case .reuse:
                        if try additionalChanged.contains(standardizedRelativePath) {
                            if matchedEntry != nil { validatedOverlayCount += 1 }
                        } else {
                            guard matchedEntry != nil,
                                  let baseOrdinal = record.baseOrdinal,
                                  let baseIndex = Self.baseSearchIndex(
                                      for: baseOrdinal,
                                      stableOrdinals: snapshot.searchBase.stableOrdinals
                                  ),
                                  snapshot.searchBase.relativePaths[baseIndex].utf8.elementsEqual(standardizedRelativePath.utf8)
                            else { return nil }
                            resolvedBaseEntryCount += 1
                        }
                    case .overlay, .none:
                        guard matchedEntry != nil else {
                            guard try additionalChanged.contains(standardizedRelativePath) else { return nil }
                            break
                        }
                        validatedOverlayCount += 1
                    case .tombstone:
                        return nil
                    }
                case .baseTombstone:
                    if try additionalChanged.contains(standardizedRelativePath) {
                        if matchedEntry != nil { validatedOverlayCount += 1 }
                    } else if matchedEntry != nil {
                        return nil
                    }
                case .ordinaryDirectory, .policyIgnoredTrackedFile:
                    if matchedEntry != nil {
                        guard try additionalChanged.contains(standardizedRelativePath) else { return nil }
                        validatedOverlayCount += 1
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
            validatedOverlayCount += 1
            authoritativeIndex += 1
        }
        guard resolvedBaseEntryCount + validatedOverlayCount == authoritativeEntries.count else { return nil }
        do {
            let changedReader = try additionalChanged.makeReader()
            while try changedReader.next() != nil {}
        } catch {
            return nil
        }

        self.init(
            relativeBase: .shared(snapshot.searchBase),
            displayPrefix: projectedDisplayPrefix,
            absolutePrefix: projectedAbsolutePrefix,
            authoritativeEntries: authoritativeEntries,
            policy: .production
        )
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

    #if DEBUG
        convenience init?(
            snapshot: WorkspaceRootReusableSnapshot,
            changedRelativeFilePaths: Set<String>,
            tombstonedBaseRelativeFilePaths: Set<String>,
            root: WorkspaceRootRecord,
            authoritativeEntries: [WorkspaceSearchCatalogEntry]
        ) {
            let changed = Set((Array(changedRelativeFilePaths) + Array(tombstonedBaseRelativeFilePaths)).map { Array(StandardizedPath.relative($0).utf8) })
            let live = Set(authoritativeEntries.map { Array($0.standardizedRelativePath.utf8) })
            guard snapshot.searchBase.relativePaths.allSatisfy({
                changed.contains(Array($0.utf8)) || live.contains(Array($0.utf8))
            }) else { return nil }
            self.init(
                relativeBase: .shared(snapshot.searchBase),
                displayPrefix: root.name + "/",
                absolutePrefix: root.standardizedFullPath + "/",
                authoritativeEntries: authoritativeEntries,
                policy: .production
            )
        }
    #endif

    private init?(
        relativeBase: RelativeBase,
        displayPrefix: String,
        absolutePrefix: String,
        authoritativeEntries: [WorkspaceSearchCatalogEntry],
        policy: WorkspacePathSearchCompactionPolicy,
        validateBaseOrder: Bool = true
    ) {
        let base = relativeBase.index
        guard authoritativeEntries.allSatisfy({
            Self.hasExactPrefix($0.displayPath, prefix: displayPrefix, suffix: $0.standardizedRelativePath)
                && Self.hasExactPrefix($0.standardizedFullPath, prefix: absolutePrefix, suffix: $0.standardizedRelativePath)
        }), zip(authoritativeEntries, authoritativeEntries.dropFirst()).allSatisfy({ previous, current in
            WorkspaceFileContextStore.compareUTF8Binary(previous.standardizedRelativePath, current.standardizedRelativePath) == .orderedAscending
        }) else { return nil }
        // Offsets reference the authoritative array rather than retaining a second copy of every row.
        var targets = [Int](repeating: -1, count: base.count)
        var overlay: [WorkspaceSearchCatalogEntry] = []
        var position = 0
        var previousPath: String?
        for basePosition in 0 ..< base.count {
            guard let path = base.path(at: basePosition) else { return nil }
            if validateBaseOrder {
                if let previousPath,
                   WorkspaceFileContextStore.compareUTF8Binary(previousPath, path) != .orderedAscending { return nil }
                previousPath = path
            }
            while position < authoritativeEntries.count,
                  WorkspaceFileContextStore.compareUTF8Binary(authoritativeEntries[position].standardizedRelativePath, path) == .orderedAscending
            {
                overlay.append(authoritativeEntries[position])
                position += 1
            }
            if position < authoritativeEntries.count,
               authoritativeEntries[position].standardizedRelativePath.utf8.elementsEqual(path.utf8)
            {
                targets[basePosition] = position
                position += 1
            }
        }
        overlay.append(contentsOf: authoritativeEntries.dropFirst(position))
        let tombstones = targets.lazy.count(where: { $0 < 0 })
        let freshBytes = authoritativeEntries.reduce(0) { $0 + $1.standardizedRelativePath.utf8.count }
        let overlayBytes = overlay.reduce(0) { $0 + $1.pathSearchKeyByteCount }
        if policy.shouldRebase(
            baseCount: base.count,
            currentCount: authoritativeEntries.count,
            overlayCount: overlay.count,
            suppressedCount: tombstones,
            retainedKeyBytes: base.keyByteCount + overlayBytes,
            freshKeyBytes: freshBytes
        ) {
            self.relativeBase = .local(PathSearchIndex(paths: authoritativeEntries.map(\.standardizedRelativePath)))
            targetPositionsByBaseIndex = Array(authoritativeEntries.indices)
            overlayEntries = []
            overlayIndex = nil
            baseEntryCount = authoritativeEntries.count
            overlayEntryCount = 0
            tombstoneCount = 0
        } else {
            self.relativeBase = relativeBase
            targetPositionsByBaseIndex = targets
            overlayEntries = overlay
            overlayIndex = overlay.isEmpty ? nil : PathSearchIndex(paths: overlay.map(\.pathSearchIndexKey))
            baseEntryCount = authoritativeEntries.count - overlay.count
            overlayEntryCount = overlay.count
            tombstoneCount = tombstones
        }
        entries = authoritativeEntries
        self.displayPrefix = displayPrefix
        self.absolutePrefix = absolutePrefix
    }

    private static func hasExactPrefix(_ value: String, prefix: String, suffix: String) -> Bool {
        value.utf8.count == prefix.utf8.count + suffix.utf8.count
            && value.utf8.starts(with: prefix.utf8)
            && value.utf8.dropFirst(prefix.utf8.count).elementsEqual(suffix.utf8)
    }

    func applyingPatch(
        entries: [WorkspaceSearchCatalogEntry],
        policy: WorkspacePathSearchCompactionPolicy = .production
    ) -> WorkspaceProjectedPathSearchIndex? {
        WorkspaceProjectedPathSearchIndex(
            relativeBase: relativeBase,
            displayPrefix: displayPrefix,
            absolutePrefix: absolutePrefix,
            authoritativeEntries: entries,
            policy: policy,
            validateBaseOrder: false
        )
    }

    private func overlayCandidates(_ query: String, limit: Int) -> [Candidate] {
        overlayIndex?.searchSynchronously(query, limit: limit).map {
            Candidate(entry: overlayEntries[$0.index], score: $0.score, tieBreakKey: $0.tieBreakKey)
        } ?? []
    }

    private func baseCandidates(_ candidates: [PathSearchIndex.Candidate]) -> [Candidate] {
        candidates.compactMap {
            guard targetPositionsByBaseIndex.indices.contains($0.index) else { return nil }
            let position = targetPositionsByBaseIndex[$0.index]
            guard entries.indices.contains(position) else { return nil }
            return Candidate(entry: entries[position], score: $0.score, tieBreakKey: $0.tieBreakKey)
        }
    }

    private func baseLimit(_ limit: Int) -> Int {
        let bounded = min(targetPositionsByBaseIndex.count, limit)
        return bounded + min(tombstoneCount, targetPositionsByBaseIndex.count - bounded)
    }

    func search(_ query: String, limit: Int) -> [Candidate] {
        guard limit > 0 else { return [] }
        let base = relativeBase.index.searchProjectedSynchronously(
            query,
            displayPrefix: displayPrefix,
            absolutePrefix: absolutePrefix,
            limit: baseLimit(limit)
        )
        return Self.merge([overlayCandidates(query, limit: limit), baseCandidates(base)], limit: limit)
    }

    func searchCancellable(_ query: String, limit: Int) async -> CancellableSearchOutcome {
        guard limit > 0 else {
            return .completed([], .init(
                examinedCount: 0,
                matchedCount: 0,
                heapPeakCount: 0,
                heapComparisonCount: 0,
                scratchBytes: 0
            ))
        }
        let overlay = overlayCandidates(query, limit: limit)
        let outcome = await relativeBase.index.searchProjected(
            query,
            displayPrefix: displayPrefix,
            absolutePrefix: absolutePrefix,
            limit: baseLimit(limit)
        )
        switch outcome {
        case let .cancelled(diagnostics): return .cancelled(diagnostics)
        case let .completed(candidates, diagnostics):
            guard !Task.isCancelled else { return .cancelled(diagnostics) }
            return .completed(Self.merge([overlay, baseCandidates(candidates)], limit: limit), diagnostics)
        }
    }

    var overlayHistoryMetricsForTesting: WorkspacePathSearchOverlayHistoryMetrics {
        .init(
            recentPayloadCount: overlayIndex == nil ? 0 : 1,
            compactedPageCount: 0,
            compactedPayloadCount: 0,
            maximumCompactedPagePayloadCount: 0
        )
    }

    var baseOwnerForTesting: AnyObject {
        relativeBase.owner
    }

    var overlayOwnersForTesting: [AnyObject] {
        overlayIndex.map { [$0] } ?? []
    }

    var usesSharedBaseForTesting: Bool {
        relativeBase.isShared
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
    var pathSearchKeyByteCount: Int {
        displayPath.utf8.count + 1 + standardizedFullPath.utf8.count
    }

    func isByteIdentical(to other: Self) -> Bool {
        id == other.id && rootID == other.rootID
            && rootPath.utf8.elementsEqual(other.rootPath.utf8)
            && rootName.utf8.elementsEqual(other.rootName.utf8)
            && name.utf8.elementsEqual(other.name.utf8)
            && relativePath.utf8.elementsEqual(other.relativePath.utf8)
            && standardizedRelativePath.utf8.elementsEqual(other.standardizedRelativePath.utf8)
            && fullPath.utf8.elementsEqual(other.fullPath.utf8)
            && standardizedFullPath.utf8.elementsEqual(other.standardizedFullPath.utf8)
            && displayPath.utf8.elementsEqual(other.displayPath.utf8)
    }

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
