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

    init(major: Int, minor: Int, patch: Int) {
        components = [major, minor, patch]
    }

    static func < (lhs: SparkleBuildVersion, rhs: SparkleBuildVersion) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

/// Single authority for comparing dotted marketing-version strings. Non-numeric
/// components are ignored, matching the historical passive-update comparison.
enum SparkleVersionComparison {
    static func isVersion(_ v1: String, newerThan v2: String) -> Bool {
        let v1Components = v1.split(separator: ".").compactMap { Int($0) }
        let v2Components = v2.split(separator: ".").compactMap { Int($0) }

        let maxLength = max(v1Components.count, v2Components.count)

        for index in 0 ..< maxLength {
            let v1Part = index < v1Components.count ? v1Components[index] : 0
            let v2Part = index < v2Components.count ? v2Components[index] : 0

            if v1Part > v2Part { return true }
            if v1Part < v2Part { return false }
        }
        return false
    }
}
