import Foundation
import RepoPromptC

/// High-performance path search index using C implementation for binary search
/// Optimized for >1k files with O(log n + k*m) search complexity
package actor PathSearchIndex {
    // MARK: - Types

    package struct Candidate {
        package let index: Int
        package let path: String
        package let filename: String

        package init(index: Int, path: String, filename: String) {
            self.index = index
            self.path = path
            self.filename = filename
        }
    }

    // MARK: - Private State

    private var cIndex: UnsafeMutablePointer<path_search_index_t>?
    private var originalPaths: [String] = []
    private var filenames: [String] = []

    // MARK: - Initialization

    package init(paths: [String]) async {
        await rebuild(paths: paths)
    }

    package init() {
        cIndex = nil
    }

    deinit {
        if let index = cIndex {
            path_search_destroy(index)
        }
    }

    // MARK: - Public API

    /// Search for paths matching the given pattern
    /// - Parameters:
    ///   - pattern: Search pattern (supports wildcards and regex)
    ///   - limit: Maximum number of results to return
    /// - Returns: Array of matching candidates with indices
    package func search(_ pattern: String, limit: Int = 300) async -> [Candidate] {
        guard let index = cIndex else { return [] }

        // Call C implementation
        let result = pattern.withCString { patternCStr in
            path_search_find(index, patternCStr, limit)
        }

        guard let searchResult = result else { return [] }
        defer { search_result_destroy(searchResult) }

        // Convert C results to Swift candidates
        var candidates: [Candidate] = []
        let resultPtr = UnsafePointer(searchResult)
        let count = Int(resultPtr.pointee.count)
        candidates.reserveCapacity(count)

        guard let indices = resultPtr.pointee.indices else { return [] }

        for i in 0 ..< count {
            let idx = Int(indices[i])
            if idx < originalPaths.count {
                candidates.append(Candidate(
                    index: idx,
                    path: originalPaths[idx],
                    filename: filenames[idx]
                ))
            }
        }

        return candidates
    }

    /// Rebuild the index with new paths
    package func rebuild(paths: [String]) async {
        // Clean up old index
        if let oldIndex = cIndex {
            path_search_destroy(oldIndex)
            cIndex = nil
        }

        guard !paths.isEmpty else {
            originalPaths = []
            filenames = []
            return
        }

        // Store original paths
        originalPaths = paths

        // Extract filenames
        filenames = paths.map { path in
            URL(fileURLWithPath: path).lastPathComponent
        }

        // Create C string array
        let cPaths = paths.map { repo_strdup($0) }
        defer {
            cPaths.forEach { repo_free($0) }
        }

        // Create index using C implementation
        var cPathsPointers = cPaths.map { UnsafePointer<CChar>($0) }
        cPathsPointers.withUnsafeMutableBufferPointer { buffer in
            cIndex = path_search_create(buffer.baseAddress, paths.count)
        }
    }

    /// Get path at specific index
    package func path(at index: Int) -> String? {
        guard index >= 0, index < originalPaths.count else { return nil }
        return originalPaths[index]
    }

    /// Get filename at specific index
    package func filename(at index: Int) -> String? {
        guard index >= 0, index < filenames.count else { return nil }
        return filenames[index]
    }

    /// Get total number of indexed paths
    package var count: Int {
        originalPaths.count
    }
}

// MARK: - LRU Cache Actor

/// Thread-safe LRU cache implementation using actors
package actor LRUCacheActor<Key: Hashable, Value> {
    private struct Entry {
        let value: Value
        var timestamp: Date
    }

    private var cache: [Key: Entry] = [:]
    private let capacity: Int

    package init(capacity: Int) {
        self.capacity = capacity
    }

    package func value(for key: Key) -> Value? {
        if var entry = cache[key] {
            entry.timestamp = Date()
            cache[key] = entry
            return entry.value
        }
        return nil
    }

    package func set(_ value: Value, for key: Key) {
        cache[key] = Entry(value: value, timestamp: Date())

        // Evict oldest if over capacity
        if cache.count > capacity {
            let oldest = cache.min { $0.value.timestamp < $1.value.timestamp }
            if let oldestKey = oldest?.key {
                cache.removeValue(forKey: oldestKey)
            }
        }
    }

    package func clear() {
        cache.removeAll()
    }
}
