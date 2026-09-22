import Foundation

/// Package-wide authority for machine-derived content-read concurrency.
package enum ContentReadConcurrencyCapacity {
    /// Scale foreground-capable content reads with the machine while retaining a useful minimum.
    package static let maximumConcurrentReads = max(2, ProcessInfo.processInfo.activeProcessorCount)

    /// Preserve one foreground permit and the historical maximum of three bulk/CodeMap reads.
    package static let maximumConcurrentBulkReads = bulkReadLimit(forReadCapacity: maximumConcurrentReads)

    package static func bulkReadLimit(forReadCapacity capacity: Int) -> Int {
        precondition(capacity > 0)
        return min(3, max(1, capacity - 1))
    }
}
