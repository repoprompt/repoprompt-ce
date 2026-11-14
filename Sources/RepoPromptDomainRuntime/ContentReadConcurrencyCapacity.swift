/// Stable fan-out into the fair content scheduler. Physical workers additionally share
/// `HostResourceBudget`, which reduces new grants under memory/thermal/fd pressure.
package enum ContentReadConcurrencyCapacity {
    package static let maximumConcurrentReads = max(2, HostResourceCapacity.baseline.io)
    package static let maximumConcurrentBulkReads = min(
        // Retain the existing main ceiling for background prefetch until a larger
        // bulk/CodeMap workload demonstrates a gain; host pressure can reduce it further.
        3, maximumConcurrentReads - 1, HostResourceCapacity.baseline.background
    )
}
