/// Stable fan-out into the fair content scheduler. Physical workers additionally share
/// `HostResourceBudget`, which reduces new grants under memory/thermal/fd pressure.
package enum ContentReadConcurrencyCapacity {
    package static let maximumConcurrentReads = max(2, HostResourceCapacity.baseline.io)
    package static let maximumConcurrentBulkReads = min(
        maximumConcurrentReads - 1, HostResourceCapacity.baseline.background
    )
}
