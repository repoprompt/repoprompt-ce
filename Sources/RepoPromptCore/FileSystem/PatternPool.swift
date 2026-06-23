import Foundation

/// A global pool that stores **unique** copies of pattern strings so every
/// identical pattern across thousands of ignore files is backed by a single
/// `String` instance. This can save tens of megabytes of RAM on large
/// repositories while remaining bounded across long-lived app sessions.
///
/// Thread-safety: `intern(_:)` uses an `NSLock`, which is perfectly adequate
/// here because pattern compilation happens far less frequently than pattern
/// matching.
package final class PatternPool {
    static let shared = PatternPool()

    private var set = Set<String>()
    private let lock = NSLock()
    private let maxEntries: Int

    private init(maxEntries: Int = 16384) {
        self.maxEntries = max(1, maxEntries)
    }

    /// Return the unique, interned string for the given pattern.
    /// If the pattern has already been seen, the previously stored instance
    /// is returned; otherwise the string is inserted and returned. When the
    /// pool reaches its maximum unique-string count, it is cleared before
    /// inserting the next new string. Clearing only reduces future deduplication;
    /// compiled rules already hold independent `String` values.
    func intern(_ pattern: String) -> String {
        lock.lock()
        defer { lock.unlock() }

        if let existingIndex = set.firstIndex(of: pattern) {
            return set[existingIndex]
        }

        if set.count >= maxEntries {
            set.removeAll(keepingCapacity: false)
        }

        let inserted = set.insert(pattern)
        return inserted.memberAfterInsert
    }

    #if DEBUG
        var countForTesting: Int {
            lock.lock()
            defer { lock.unlock() }
            return set.count
        }

        var capacityForTesting: Int {
            maxEntries
        }

        func resetForTesting() {
            lock.lock()
            defer { lock.unlock() }
            set.removeAll(keepingCapacity: false)
        }
    #endif
}
