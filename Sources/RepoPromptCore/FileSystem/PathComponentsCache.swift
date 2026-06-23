import Foundation

/// Caches `path.split(separator: "/")` results to avoid repeated
/// allocations during ignore-rule evaluation.
///
/// Designed to live for the duration of a directory walk; callers are
/// expected to discard the instance afterwards to keep memory bounded.
package struct PathComponentsCache {
    private var storage = [String: [Substring]]()

    /// Return the cached components for `path`, computing and storing
    /// them on first request.
    mutating func components(for path: String) -> [Substring] {
        if let cached = storage[path] {
            return cached
        }
        let comps = path.split(separator: "/")
        storage[path] = comps
        return comps
    }

    /// Clear all cached entries.
    mutating func removeAll() {
        storage.removeAll()
    }
}
