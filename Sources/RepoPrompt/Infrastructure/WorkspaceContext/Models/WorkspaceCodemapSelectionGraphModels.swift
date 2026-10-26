import Foundation

struct WorkspaceCodemapSelectionGraphContributionGeneration: RawRepresentable, Hashable, Comparable {
    let rawValue: UInt64

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct WorkspaceCodemapSelectionGraphSizePolicy: Hashable {
    static let initial = Self(
        maxNodes: 100_000,
        maxPostings: 2_000_000,
        maxEdges: 1_000_000,
        maxBytes: 192 * 1024 * 1024,
        maxDefinitionCandidates: 4096
    )

    let maxNodes: UInt64
    let maxPostings: UInt64
    let maxEdges: UInt64
    let maxBytes: UInt64
    let maxDefinitionCandidates: UInt64
}

enum WorkspaceCodemapSelectionGraphSizeDimension: Hashable {
    case nodes
    case postings
    case edges
    case bytes
}

enum WorkspaceCodemapSelectionGraphSizeRejection: Error, Hashable {
    case arithmeticOverflow(WorkspaceCodemapSelectionGraphSizeDimension)
    case limitExceeded(
        dimension: WorkspaceCodemapSelectionGraphSizeDimension,
        attempted: UInt64,
        limit: UInt64
    )
}
