import Foundation

/// Deterministic priority for choosing among eligible workspaces that contain one exact root.
/// Ascending order is selection order: most recently used first, then stable lexical ties.
package struct WorkspaceExactRootCandidateRank: Comparable {
    package let lastUsed: Date
    package let name: String
    package let workspaceID: UUID

    package init(lastUsed: Date, name: String, workspaceID: UUID) {
        self.lastUsed = lastUsed
        self.name = name
        self.workspaceID = workspaceID
    }

    package static func < (lhs: WorkspaceExactRootCandidateRank, rhs: WorkspaceExactRootCandidateRank) -> Bool {
        if lhs.lastUsed != rhs.lastUsed {
            return lhs.lastUsed > rhs.lastUsed
        }
        let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameOrder != .orderedSame {
            return nameOrder == .orderedAscending
        }
        return lhs.workspaceID.uuidString < rhs.workspaceID.uuidString
    }
}
