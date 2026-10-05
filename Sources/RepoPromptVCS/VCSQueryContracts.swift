import Foundation
import RepoPromptWorkspaceCore

/// The loaded-root authorization input needed by repository target queries. It carries no
/// workspace store, feature model, window, or selection authority.
public struct VCSRepositoryRoot: Hashable, Sendable {
    public let name: String
    public let standardizedFullPath: String

    public init(name: String, fullPath: String) {
        self.name = name
        standardizedFullPath = StandardizedPath.absolute(fullPath)
    }
}

/// Host-owned repository discovery and worktree enumeration. No app or UI authority is
/// captured by the library; the host supplies its existing backend rather than forking it.
public protocol GitRepositoryQuerying: Sendable {
    func resolveRepository(from url: URL) async -> GitRepoDescriptor?
    func listWorktrees(in repository: GitRepoDescriptor) async throws -> [GitWorktreeDescriptor]
}

/// Backend selection for diff operations, independent of the app's VCS service singleton.
package protocol VCSBackendResolving: Sendable {
    func backend(forRepoRoot rootURL: URL) async -> any VCSBackend
    func getStatusFingerprint(at repoURL: URL, baseRef: String) async throws -> GitDiffFingerprint
}

/// The two Git-specific operations the diff core needs. In the app these delegate to the
/// intact GitService, including its recovered-diff parser and process/lifecycle policy.
package struct GitDiffCommandClient {
    package let statusPorcelainZ: @Sendable (URL) async throws -> Data
    package let splitUnifiedDiffByFile: @Sendable (String) -> [String: String]

    package init(
        statusPorcelainZ: @escaping @Sendable (URL) async throws -> Data,
        splitUnifiedDiffByFile: @escaping @Sendable (String) -> [String: String]
    ) {
        self.statusPorcelainZ = statusPorcelainZ
        self.splitUnifiedDiffByFile = splitUnifiedDiffByFile
    }
}
