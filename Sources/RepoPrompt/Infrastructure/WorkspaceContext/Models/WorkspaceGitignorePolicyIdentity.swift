import Foundation

enum WorkspaceGitignorePolicyIdentity: String, Hashable {
    case gitIgnoreFloorV3 = "mandatory-gitignore-floor-reachable-controls-v3"

    static let current = WorkspaceGitignorePolicyIdentity.gitIgnoreFloorV3
}
