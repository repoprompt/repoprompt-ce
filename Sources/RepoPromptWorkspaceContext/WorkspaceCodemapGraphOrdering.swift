import Darwin
import Foundation

/// Canonical orderings shared by the root-local graph ledger and the selection graph.
///
/// Both orderings are byte-for-byte equivalent to the historical definitions
/// (`String.utf8.lexicographicallyPrecedes` and `UUID.uuidString` comparison) but avoid generic
/// UTF-8 view iteration and the `uuidString` allocation, which dominated graph-index profiles.
enum WorkspaceCodemapGraphOrdering {
    /// Unsigned byte-wise lexicographic order of the UTF-8 encodings. Shorter prefixes precede.
    @inline(__always)
    static func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
        let fastResult: Bool?? = lhs.utf8.withContiguousStorageIfAvailable { left in
            rhs.utf8.withContiguousStorageIfAvailable { right in
                bytesPrecede(UnsafeRawBufferPointer(left), UnsafeRawBufferPointer(right))
            }
        }
        if let outer = fastResult, let result = outer { return result }
        return lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    /// Equivalent to `lhs.uuidString < rhs.uuidString`: the canonical string is fixed-width
    /// uppercase hexadecimal with dashes at fixed offsets, so its order is the raw byte order.
    @inline(__always)
    static func uuidPrecedes(_ lhs: UUID, _ rhs: UUID) -> Bool {
        withUnsafeBytes(of: lhs.uuid) { left in
            withUnsafeBytes(of: rhs.uuid) { right in
                memcmp(left.baseAddress!, right.baseAddress!, 16) < 0
            }
        }
    }

    @inline(__always)
    private static func bytesPrecede(_ lhs: UnsafeRawBufferPointer, _ rhs: UnsafeRawBufferPointer) -> Bool {
        let common = Swift.min(lhs.count, rhs.count)
        if common > 0, let left = lhs.baseAddress, let right = rhs.baseAddress {
            let comparison = memcmp(left, right, common)
            if comparison != 0 { return comparison < 0 }
        }
        return lhs.count < rhs.count
    }
}
