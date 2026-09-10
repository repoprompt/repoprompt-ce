import Foundation

/// Deterministic priority for choosing among eligible workspaces that contain one exact root.
/// Ascending order is selection order: most recently modified first, then stable lexical ties.
package struct WorkspaceExactRootCandidateRank: Comparable {
    package let dateModified: Date
    package let name: String
    package let workspaceID: UUID

    package init(dateModified: Date, name: String, workspaceID: UUID) {
        self.dateModified = dateModified
        self.name = name
        self.workspaceID = workspaceID
    }

    package static func < (lhs: WorkspaceExactRootCandidateRank, rhs: WorkspaceExactRootCandidateRank) -> Bool {
        if lhs.dateModified != rhs.dateModified {
            return lhs.dateModified > rhs.dateModified
        }
        let lhsFoldedName = lhs.name.lowercased()
        let rhsFoldedName = rhs.name.lowercased()
        if lhsFoldedName != rhsFoldedName {
            return lhsFoldedName < rhsFoldedName
        }
        if lhs.name != rhs.name {
            return lhs.name < rhs.name
        }
        return lhs.workspaceID.uuidString < rhs.workspaceID.uuidString
    }
}
