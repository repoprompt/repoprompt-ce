import Foundation

package enum SelectedGitDiffFolderPolicy {
    case filesOnly
    case expandFolders
}

package struct WorkspaceSelectedGitPathResolution: Equatable {
    package let paths: [String]
    package let unresolvedCandidates: [String]

    package init(paths: [String], unresolvedCandidates: [String]) {
        self.paths = paths
        self.unresolvedCandidates = unresolvedCandidates
    }
}
