import Foundation

// MARK: - Selection Signature

/// Lightweight signature for a set of selected file paths.
/// Used as a cache key component; precomputed on MainActor to avoid work on worker.
struct SelectionSig: Equatable {
    let count: Int
    let hash: UInt64

    static let empty = SelectionSig(count: 0, hash: 0)
}

/// Computes a deterministic, order-independent signature for a set of paths.
/// - Uses FNV-1a per-path, combined with XOR and addition for true commutativity.
/// - O(n) in total string length; no sorting required.
/// - Do NOT replace with `Hasher` which uses per-process randomization.
///
/// Note: Previous implementation used rotate after XOR which made the result
/// order-dependent. This version uses separate XOR and sum accumulators
/// that are truly commutative.
func selectionSignature(for paths: Set<String>) -> SelectionSig {
    guard !paths.isEmpty else { return .empty }

    var xorAcc: UInt64 = 0
    var sumAcc: UInt64 = 0
    var count = 0

    for path in paths {
        count += 1
        // FNV-1a hash for this path
        var h: UInt64 = 0xCBF2_9CE4_8422_2325 // FNV-1a offset basis
        for b in path.utf8 {
            h = (h ^ UInt64(b)) &* 0x100_0000_01B3 // FNV-1a prime
        }
        // Order-independent combine: XOR is commutative, addition is commutative
        xorAcc ^= h
        sumAcc &+= (h &* 0x9E37_79B9_7F4A_7C15)
    }

    // Mix the two accumulators for better distribution
    let mixed = xorAcc ^ (sumAcc &<< 1) ^ (sumAcc &>> 63)
    return SelectionSig(count: count, hash: mixed)
}

// MARK: - PathMatchWorker

/// Dedicated actor for all PathMatcher operations.
/// Owns index building & caching; callers pass pure snapshot data.
/// Each WorkspaceFilesViewModel owns its own PathMatchWorker instance
/// to maintain per-window isolation in multi-window scenarios.
actor PathMatchWorker {
    // MARK: - Index Cache (single-entry, keyed by generation)

    private var lastIndexIdentity: PathMatchCacheIdentity?
    private var lastIndexes: PathMatchIndexes?

    // MARK: - Snapshot Cache (multi-entry for selection churn)

    private struct SnapshotKey: Equatable {
        let staticIdentity: PathMatchCacheIdentity
        let selectionSig: SelectionSig
    }

    private struct SnapshotEntry {
        let key: SnapshotKey
        let snapshot: PathMatchSnapshot
    }

    /// Small FIFO cache for snapshots (handles selection toggling)
    private var snapshotCache: [SnapshotEntry] = []
    private let maxSnapshotEntries = 4

    // MARK: - Index Building

    /// Builds or retrieves cached indexes for the given static data.
    private func indexes(for staticData: StaticPathMatchData) -> PathMatchIndexes {
        // Fast path: return cached indexes if generation matches
        if let cachedIdentity = lastIndexIdentity,
           cachedIdentity == staticData.cacheIdentity,
           let cached = lastIndexes
        {
            return cached
        }

        // Build indexes (this is the heavy work)
        let built = PathMatchIndexes.build(
            files: staticData.filesByFullPath,
            folders: staticData.foldersByFullPath,
            caseSensitive: staticData.caseSensitive
        )

        // Cache for next call
        lastIndexIdentity = staticData.cacheIdentity
        lastIndexes = built

        // Clear snapshot cache when indexes change (different generation)
        snapshotCache.removeAll(keepingCapacity: true)

        return built
    }

    // MARK: - Snapshot Building

    /// Builds or retrieves cached snapshot for the given inputs.
    private func snapshot(
        for staticData: StaticPathMatchData,
        selectedFileFullPaths: Set<String>,
        selectionSig: SelectionSig
    ) -> PathMatchSnapshot {
        let key = SnapshotKey(staticIdentity: staticData.cacheIdentity, selectionSig: selectionSig)

        // Check cache (linear scan is fine for small cache)
        if let idx = snapshotCache.firstIndex(where: { $0.key == key }) {
            // Move to end for LRU-ish behavior
            let entry = snapshotCache.remove(at: idx)
            snapshotCache.append(entry)
            return entry.snapshot
        }

        // Cache miss: build new snapshot
        let idx = indexes(for: staticData)
        let built = PathMatchSnapshot(
            staticData: staticData,
            selectedFileFullPaths: selectedFileFullPaths,
            indexes: idx
        )

        // Add to cache, evict oldest if full
        if snapshotCache.count >= maxSnapshotEntries {
            snapshotCache.removeFirst()
        }
        snapshotCache.append(SnapshotEntry(key: key, snapshot: built))

        return built
    }

    // MARK: - Public API

    /// Builds and caches indexes for the provided static snapshot without performing a lookup.
    /// Use this when a workspace catalog becomes search-ready so later lookup calls do not pay
    /// index construction cost on their first query.
    @discardableResult
    func prepare(staticData: StaticPathMatchData) -> UInt64 {
        _ = indexes(for: staticData)
        return staticData.id
    }

    /// Runs PathMatcher.locate off MainActor.
    /// - Parameters:
    ///   - selectionSig: Precomputed on MainActor via `selectionSignature(for:)`
    func locate(
        userPath: String,
        profile: PathLocateProfile,
        staticData: StaticPathMatchData,
        selectedFileFullPaths: Set<String>,
        selectionSig: SelectionSig
    ) -> PathMatchLocation? {
        let options = profile.options
        let effectiveSelection = options.useSelectedRootBias ? selectedFileFullPaths : []
        let effectiveSignature = options.useSelectedRootBias ? selectionSig : .empty
        let snap = snapshot(for: staticData, selectedFileFullPaths: effectiveSelection, selectionSig: effectiveSignature)
        return PathMatcher.locate(
            userPath: userPath,
            options: options,
            snapshot: snap
        )
    }

    func locate(
        userPath: String,
        exactMatchOnly: Bool,
        staticData: StaticPathMatchData,
        selectedFileFullPaths: Set<String>,
        selectionSig: SelectionSig
    ) -> PathMatchLocation? {
        locate(
            userPath: userPath,
            profile: exactMatchOnly ? .moveSourceExact : .uiAssisted,
            staticData: staticData,
            selectedFileFullPaths: selectedFileFullPaths,
            selectionSig: selectionSig
        )
    }

    func locateMany(
        userPaths: [String],
        profile: PathLocateProfile,
        staticData: StaticPathMatchData,
        selectedFileFullPaths: Set<String>,
        selectionSig: SelectionSig
    ) -> [String: PathMatchLocation] {
        let options = profile.options
        let effectiveSelection = options.useSelectedRootBias ? selectedFileFullPaths : []
        let effectiveSignature = options.useSelectedRootBias ? selectionSig : .empty
        let snap = snapshot(for: staticData, selectedFileFullPaths: effectiveSelection, selectionSig: effectiveSignature)
        var results: [String: PathMatchLocation] = [:]
        results.reserveCapacity(userPaths.count)
        for userPath in userPaths {
            if let location = PathMatcher.locate(userPath: userPath, options: options, snapshot: snap) {
                results[userPath] = location
            }
        }
        return results
    }

    /// Finds the best root folder for creating a new file.
    /// - Parameters:
    ///   - selectionSig: Precomputed on MainActor via `selectionSignature(for:)`
    func findCreationPath(
        userPath: String,
        staticData: StaticPathMatchData,
        selectedFileFullPaths: Set<String>,
        selectionSig: SelectionSig
    ) -> FileCreationResult? {
        let snap = snapshot(for: staticData, selectedFileFullPaths: selectedFileFullPaths, selectionSig: selectionSig)
        return PathMatcher.findCreationPath(
            userPath: userPath,
            snapshot: snap
        )
    }

    /// Resolves a creation path with optional ambiguity detection.
    /// - Parameters:
    ///   - mode: Resolution mode controlling tie-breaking behavior
    ///   - selectionSig: Precomputed on MainActor via `selectionSignature(for:)`
    func resolveCreationPath(
        userPath: String,
        staticData: StaticPathMatchData,
        selectedFileFullPaths: Set<String>,
        selectionSig: SelectionSig,
        mode: CreationResolutionMode
    ) -> FileCreationResolution? {
        let useSelectionBias = (mode == .bestEffort)
        let snap = snapshot(
            for: staticData,
            selectedFileFullPaths: useSelectionBias ? selectedFileFullPaths : [],
            selectionSig: useSelectionBias ? selectionSig : .empty
        )
        return PathMatcher.resolveCreationPath(
            userPath: userPath,
            snapshot: snap,
            mode: mode
        )
    }

    /// Removes only cached data built from stale scope snapshots.
    func invalidateCache(snapshotIdentities: Set<PathMatchCacheIdentity>) {
        guard !snapshotIdentities.isEmpty else { return }
        if let lastIndexIdentity, snapshotIdentities.contains(lastIndexIdentity) {
            self.lastIndexIdentity = nil
            lastIndexes = nil
        }
        snapshotCache.removeAll { snapshotIdentities.contains($0.key.staticIdentity) }
    }
}
