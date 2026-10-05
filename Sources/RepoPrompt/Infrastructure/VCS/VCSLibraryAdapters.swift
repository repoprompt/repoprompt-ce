import Foundation
import RepoPromptVCS
import RepoPromptWorkspaceCore

extension VCSService: GitRepositoryQuerying, VCSBackendResolving {
    public func resolveRepository(from url: URL) async -> GitRepoDescriptor? {
        guard let resolved = await resolveRepo(from: url) else { return nil }
        return GitRepoDescriptor(rootURL: resolved.rootURL)
    }

    public func listWorktrees(in repository: GitRepoDescriptor) async throws -> [GitWorktreeDescriptor] {
        try await listGitWorktrees(at: repository.rootURL)
    }
}

extension GitRepoTargetResolver.Dependencies {
    static let live = Self(
        resolveRepo: { await VCSService.shared.resolveRepository(from: $0) },
        listWorktrees: { try await VCSService.shared.listWorktrees(in: $0) }
    )
}

extension GitRepoTargetResolver {
    init() {
        self.init(dependencies: .live)
    }
}

extension GitDiffEngine {
    static let shared = GitDiffEngine()

    init(
        vcsService: VCSService = .shared,
        gitService: GitService = GitService(),
        cacheLimits: CacheLimits = .production
    ) {
        self.init(
            backendResolver: vcsService,
            gitCommands: GitDiffCommandClient(
                statusPorcelainZ: { try await gitService.getStatusPorcelainZ(at: $0) },
                splitUnifiedDiffByFile: { GitService.splitUnifiedDiffByFile($0) }
            ),
            cacheLimits: cacheLimits
        )
    }
}

extension GitDiffSnapshotPublisher {
    static let shared = GitDiffSnapshotPublisher()

    init(
        engine: GitDiffEngine = .shared,
        store: GitDiffSnapshotStore = GitDiffSnapshotStore(),
        vcsService: VCSService = .shared
    ) {
        self.init(engine: engine, store: store, backendResolver: vcsService)
    }
}

/// The app translates its existing workspace-root projection at the module boundary.
/// Repository/worktree authorization remains implemented once, in RepoPromptVCS.
extension GitRepoTargetResolver {
    func resolveRepoRoots(
        explicitRootTokens: [String]?,
        allRepos: [GitRepoDescriptor],
        visibleRoots: [WorkspaceRootRef],
        defaultRepo: GitRepoDescriptor
    ) async throws -> [GitRepoDescriptor] {
        try await resolveRepoRoots(
            explicitRootTokens: explicitRootTokens,
            allRepos: allRepos,
            visibleRoots: visibleRoots.map { VCSRepositoryRoot(name: $0.name, fullPath: $0.fullPath) },
            defaultRepo: defaultRepo
        )
    }

    func resolveRepoRootToken(
        _ token: String,
        allRepos: [GitRepoDescriptor],
        visibleRoots: [WorkspaceRootRef],
        defaultRepo: GitRepoDescriptor
    ) async throws -> GitRepoDescriptor {
        try await resolveRepoRootToken(
            token,
            allRepos: allRepos,
            visibleRoots: visibleRoots.map { VCSRepositoryRoot(name: $0.name, fullPath: $0.fullPath) },
            defaultRepo: defaultRepo
        )
    }

    func resolveWorktree(
        selector: String?,
        repo: GitRepoDescriptor,
        allRepos: [GitRepoDescriptor],
        authorizedRoots: [WorkspaceRootRef]?
    ) async throws -> GitWorktreeDescriptor {
        try await resolveWorktree(
            selector: selector,
            repo: repo,
            allRepos: allRepos,
            authorizedRoots: authorizedRoots.map { roots in
                roots.map { VCSRepositoryRoot(name: $0.name, fullPath: $0.fullPath) }
            }
        )
    }
}
