import Foundation

struct SparkleBuildVersion: Comparable {
    private let components: [Int]

    init?(_ rawValue: String) {
        let parts = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard (1 ... 3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else {
            return nil
        }

        var parsed = parts.compactMap { Int($0) }
        guard parsed.count == parts.count else { return nil }
        parsed.append(contentsOf: repeatElement(0, count: 3 - parsed.count))
        components = parsed
    }

    static func < (lhs: SparkleBuildVersion, rhs: SparkleBuildVersion) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}
