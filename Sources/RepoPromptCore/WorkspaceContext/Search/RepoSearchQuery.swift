import Foundation

package struct RepoSearchQuery: Equatable {
    package let raw: String
    package let lowered: String
    package let hasSlash: Bool
    package let isWildcard: Bool

    package var isEmpty: Bool {
        raw.isEmpty
    }
}

package enum RepoSearchQueryFactory {
    private static let defaultMaxLength = 1000

    package static func make(
        _ input: String,
        maxLength: Int = defaultMaxLength,
        supportsWildcards: Bool = true
    ) -> RepoSearchQuery {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded: String = if trimmed.count > maxLength {
            String(trimmed.prefix(maxLength))
        } else {
            trimmed
        }

        let normalized: String = if supportsWildcards {
            bounded
        } else {
            bounded
                .replacingOccurrences(of: "*", with: "")
                .replacingOccurrences(of: "?", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let lowered = normalized.lowercased()
        return RepoSearchQuery(
            raw: normalized,
            lowered: lowered,
            hasSlash: normalized.contains("/"),
            isWildcard: supportsWildcards && (normalized.contains("*") || normalized.contains("?"))
        )
    }
}
