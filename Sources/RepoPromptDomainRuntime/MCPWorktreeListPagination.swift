import Foundation

/// Single owner of the `manage_worktree` `op=list` page contract shared by the app provider
/// and the canonical tool definition. Repositories with hundreds of worktrees otherwise
/// produce list replies larger than typical client tool-result limits.
package enum MCPWorktreeListPagination {
    package static let defaultLimit = 100
    package static let maxLimit = 200

    package static let limitPropertyDescription =
        "List: maximum worktrees to return. Default \(defaultLimit); clamped to 1...\(maxLimit). Page with offset."
    package static let offsetPropertyDescription =
        "List: zero-based index of the first worktree to return. Default 0. Continue with the reply's next_offset."
    package static let outputDescriptionLine =
        "- `list` returns at most `limit` worktrees (default \(defaultLimit), max \(maxLimit)) with `total_count`; when more remain it sets `truncated: true` and `next_offset`."

    package struct Page: Equatable {
        package let offset: Int
        package let limit: Int
        package let range: Range<Int>
        package let totalCount: Int

        package var hasMore: Bool {
            range.upperBound < totalCount
        }

        package var nextOffset: Int? {
            hasMore ? range.upperBound : nil
        }
    }

    /// Clamps caller input and computes the page window. Negative offsets clamp to 0; an
    /// offset past the end yields an empty range rather than an error.
    package static func page(totalCount: Int, limit requestedLimit: Int?, offset requestedOffset: Int?) -> Page {
        let total = max(0, totalCount)
        let limit = min(max(requestedLimit ?? defaultLimit, 1), maxLimit)
        let offset = max(requestedOffset ?? 0, 0)
        let lower = min(offset, total)
        let upper = min(lower + limit, total)
        return Page(offset: offset, limit: limit, range: lower ..< upper, totalCount: total)
    }
}
