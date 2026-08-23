// Utility array helpers used across the app
import Foundation

public extension Array {
    /// Splits array into consecutive windows of at most `size`.
    /// Returns [] when size <= 0, per tests.
    public func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        var result: [[Element]] = []
        result.reserveCapacity((count + size - 1) / size)
        var idx = 0
        while idx < count {
            let end = Swift.min(idx + size, count)
            result.append(Array(self[idx ..< end]))
            idx = end
        }
        return result
    }
}

public extension Array where Element: Hashable {
    /// Removes duplicate elements while preserving the first occurrence order.
    /// Operates in-place and runs in O(n).
    mutating func removeDuplicatesInPlace() {
        var seen = Set<Element>()
        var write = 0
        for read in 0 ..< count {
            let value = self[read]
            if seen.insert(value).inserted {
                self[write] = value
                write += 1
            }
        }
        if write < count {
            removeSubrange(write ..< count)
        }
    }
}
