import Foundation

package struct IgnoreCacheStore {
    static let finalIgnoreCacheCapacity = 50000

    /// Compact key used by all internal caches – avoids repeated String concatenation.
    struct PathKey: Hashable {
        let path: String
        let isDirectory: Bool
    }

    // MARK: - Internal caches (Keyed by PathKey)

    /// For prefix short-circuit checks (directory hierarchy walk)
    private var prefixIgnoreCache = LRUCache<PathKey, Bool>(capacity: 4000)

    /// For final "isIgnored?" outcomes
    private var ignoreCheckCache = LRUCache<PathKey, Bool>(capacity: Self.finalIgnoreCacheCapacity)

    // MARK: - Prefix check ----------------------------------------------------

    mutating func isIgnoredPrefixCheck(
        relativePath: String,
        ignoreRules: IgnoreRules
    ) -> Bool {
        isIgnoredPrefixCheck(relativePath: relativePath, isDirectory: false, ignoreRules: ignoreRules)
    }

    mutating func isIgnoredPrefixCheck(
        relativePath: String,
        isDirectory: Bool,
        ignoreRules: IgnoreRules
    ) -> Bool {
        let components = relativePath.split(separator: "/")
        var pathSoFar = ""

        for (i, comp) in components.enumerated() {
            pathSoFar = (i == 0) ? String(comp) : "\(pathSoFar)/\(comp)"
            let isLast = i == components.count - 1
            let dirFlag = !isLast || isDirectory
            let key = PathKey(path: pathSoFar, isDirectory: dirFlag)

            let ignored: Bool
            if let cached = prefixIgnoreCache[key] {
                #if DEBUG
                    IgnoreDebugMetricsRecorder.recordPrefixCacheHit()
                #endif
                ignored = cached
            } else {
                #if DEBUG
                    IgnoreDebugMetricsRecorder.recordPrefixCacheMiss()
                #endif
                ignored = ignoreRules.isIgnored(
                    relativePath: pathSoFar,
                    isDirectory: dirFlag
                )
                prefixIgnoreCache[key] = ignored
            }

            if ignored {
                if !isLast, dirFlag, ignoreRules.requiresTraversal(for: pathSoFar) {
                    #if DEBUG
                        IgnoreDebugMetricsRecorder.recordPrefixCacheTraversalContinue()
                    #endif
                    continue
                }
                return true
            }
        }
        return false
    }

    // MARK: - Prefix check (pre-split components fast path) -------------------

    mutating func isIgnoredPrefixCheck(
        components comps: [Substring],
        ignoreRules: IgnoreRules
    ) -> Bool {
        isIgnoredPrefixCheck(components: comps, isDirectory: false, ignoreRules: ignoreRules)
    }

    mutating func isIgnoredPrefixCheck(
        components comps: [Substring],
        isDirectory: Bool,
        ignoreRules: IgnoreRules
    ) -> Bool {
        var pathSoFar = ""
        for (i, comp) in comps.enumerated() {
            pathSoFar = (i == 0) ? String(comp) : "\(pathSoFar)/\(comp)"
            let isLast = i == comps.count - 1
            let dirFlag = !isLast || isDirectory
            let key = PathKey(path: pathSoFar, isDirectory: dirFlag)

            let ignored: Bool
            if let cached = prefixIgnoreCache[key] {
                #if DEBUG
                    IgnoreDebugMetricsRecorder.recordPrefixCacheHit()
                #endif
                ignored = cached
            } else {
                #if DEBUG
                    IgnoreDebugMetricsRecorder.recordPrefixCacheMiss()
                #endif
                let slice = comps[0 ... i]
                ignored = ignoreRules.isIgnored(
                    relativePathComponents: Array(slice),
                    isDirectory: dirFlag
                )
                prefixIgnoreCache[key] = ignored
            }

            if ignored {
                if !isLast, dirFlag, ignoreRules.requiresTraversal(for: pathSoFar) {
                    #if DEBUG
                        IgnoreDebugMetricsRecorder.recordPrefixCacheTraversalContinue()
                    #endif
                    continue
                }
                return true
            }
        }
        return false
    }

    // MARK: - Snapshot / merge helpers (String API kept for compatibility) ---

    /// Return a *copy* of the final-decision cache, using the historical
    /// "`path|isDir`" key format so existing callers remain unchanged.
    func snapshotIgnoreCache() -> [String: Bool] {
        var out = [String: Bool]()
        out.reserveCapacity(ignoreCheckCache.count)
        for (k, v) in ignoreCheckCache.snapshot() {
            out["\(k.path)|\(k.isDirectory)"] = v
        }
        return out
    }

    /// Returns a snapshot of the ignore cache with PathKey preservation
    func snapshotIgnoreCacheWithPathKeys() -> [PathKey: Bool] {
        ignoreCheckCache.snapshot()
    }

    /// Merge a String-keyed cache (legacy callers) back into our
    /// PathKey-based storage.
    mutating func mergeIgnoreCache(_ localCache: [String: Bool]) {
        for (rawKey, val) in localCache {
            let split = rawKey.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard split.count == 2 else { continue }
            let path = String(split[0])
            let isDir = (split[1] == "true")
            let key = PathKey(path: path, isDirectory: isDir)
            ignoreCheckCache[key] = val
        }
    }

    /// Merge a typed cache without any intermediate string allocation.
    mutating func mergeIgnoreCache(_ localCache: [PathKey: Bool]) {
        guard !localCache.isEmpty else { return }
        for (key, value) in localCache {
            ignoreCheckCache[key] = value
        }
    }

    // MARK: - Static helpers --------------------------------------------------

    /// New preferred form – **struct key** cache (used by new call-sites).
    static func isIgnored(
        _ relPath: String,
        isDirectory: Bool,
        ignoreRules: IgnoreRules,
        localCache: inout [PathKey: Bool]
    ) -> Bool {
        let key = PathKey(path: relPath, isDirectory: isDirectory)
        if let cached = localCache[key] {
            return cached
        }
        let ignored = ignoreRules.isIgnored(
            relativePath: relPath,
            isDirectory: isDirectory
        )
        localCache[key] = ignored
        return ignored
    }

    /// Overload that takes **pre-split** components to avoid the path-split
    /// cost on every check.  Components are joined once to build the cache key.
    static func isIgnored(
        components: [Substring],
        isDirectory: Bool,
        ignoreRules: IgnoreRules,
        localCache: inout [PathKey: Bool]
    ) -> Bool {
        let relPath = components.joined(separator: "/")
        let key = PathKey(path: relPath, isDirectory: isDirectory)
        if let cached = localCache[key] {
            #if DEBUG
                IgnoreDebugMetricsRecorder.recordSnapshotIgnoreLocalCacheHit()
            #endif
            return cached
        }
        #if DEBUG
            IgnoreDebugMetricsRecorder.recordSnapshotIgnoreLocalCacheMiss()
        #endif
        let ignored = ignoreRules.isIgnored(
            relativePathComponents: components,
            isDirectory: isDirectory
        )
        localCache[key] = ignored
        return ignored
    }

    /// Snapshot overload for off-actor use.
    static func isIgnored(
        components: [Substring],
        isDirectory: Bool,
        ignoreRules: IgnoreRulesSnapshot,
        localCache: inout [PathKey: Bool]
    ) -> Bool {
        let relPath = components.joined(separator: "/")
        let key = PathKey(path: relPath, isDirectory: isDirectory)
        if let cached = localCache[key] {
            #if DEBUG
                IgnoreDebugMetricsRecorder.recordSnapshotIgnoreLocalCacheHit()
            #endif
            return cached
        }
        #if DEBUG
            IgnoreDebugMetricsRecorder.recordSnapshotIgnoreLocalCacheMiss()
        #endif
        let ignored = ignoreRules.isIgnored(
            relativePathComponents: components,
            isDirectory: isDirectory
        )
        localCache[key] = ignored
        return ignored
    }

    /// Optimized version with read-only base cache to avoid copy-on-write overhead
    static func isIgnored(
        components: [Substring],
        isDirectory: Bool,
        readOnlyBase: [PathKey: Bool],
        localCache: inout [PathKey: Bool],
        ignoreRules: IgnoreRules
    ) -> Bool {
        let relPath = components.joined(separator: "/")
        let key = PathKey(path: relPath, isDirectory: isDirectory)

        // Check local cache first, then read-only base
        if let cached = localCache[key] {
            #if DEBUG
                IgnoreDebugMetricsRecorder.recordSnapshotIgnoreLocalCacheHit()
            #endif
            return cached
        }
        if let cached = readOnlyBase[key] {
            #if DEBUG
                IgnoreDebugMetricsRecorder.recordSnapshotIgnoreReadOnlyBaseHit()
            #endif
            return cached
        }
        #if DEBUG
            IgnoreDebugMetricsRecorder.recordSnapshotIgnoreLocalCacheMiss()
        #endif

        let ignored = ignoreRules.isIgnored(
            relativePathComponents: components,
            isDirectory: isDirectory
        )
        localCache[key] = ignored // Store only new entry
        return ignored
    }

    /// Legacy overload – preserves the original String-keyed signature so
    /// existing code compiles without modification.
    static func isIgnored(
        _ relPath: String,
        isDirectory: Bool,
        ignoreRules: IgnoreRules,
        localCache: inout [String: Bool]
    ) -> Bool {
        let rawKey = "\(relPath)|\(isDirectory)"
        if let cached = localCache[rawKey] {
            return cached
        }
        let ignored = ignoreRules.isIgnored(
            relativePath: relPath,
            isDirectory: isDirectory
        )
        localCache[rawKey] = ignored
        return ignored
    }

    // MARK: - Global (actor-owned) final cache -------------------------------

    mutating func isIgnoredGlobal(
        _ relPath: String,
        isDirectory: Bool,
        ignoreRules: IgnoreRules
    ) -> Bool {
        let key = PathKey(path: relPath, isDirectory: isDirectory)
        if let cached = ignoreCheckCache[key] { return cached }

        let ignored = ignoreRules.isIgnored(
            relativePath: relPath,
            isDirectory: isDirectory
        )
        ignoreCheckCache[key] = ignored
        return ignored
    }
}

extension IgnoreCacheStore.PathKey: Sendable {}
