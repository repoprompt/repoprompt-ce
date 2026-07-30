import Foundation

enum FrozenVisibleGitCheckoutKind: Equatable, Hashable {
    case canonical
    case linkedWorktree
}

/// Immutable authority for one exact, currently loaded non-Agent workspace checkout.
///
/// This is deliberately separate from `FrozenBoundCheckoutIdentity`: visible roots describe source
/// workspace authority, while bound checkouts describe Agent session projection and inheritance.
struct FrozenVisibleGitCheckoutIdentity: Equatable, Hashable {
    let workspaceRoot: WorkspaceRootRef
    let visibleRootPath: String
    let repositoryRootPath: String
    let worktreeRootPath: String
    let commonGitDirectoryPath: String
    let mainWorktreeRootPath: String?
    let repositoryID: String
    let worktreeID: String
    let kind: FrozenVisibleGitCheckoutKind

    init(
        workspaceRoot: WorkspaceRootRef,
        visibleRootPath: String,
        repositoryRootPath: String,
        worktreeRootPath: String,
        commonGitDirectoryPath: String,
        mainWorktreeRootPath: String?,
        repositoryID: String,
        worktreeID: String,
        kind: FrozenVisibleGitCheckoutKind
    ) {
        self.workspaceRoot = workspaceRoot
        self.visibleRootPath = GitRepoRootAuthorization.canonicalPath(visibleRootPath)
        self.repositoryRootPath = GitRepoRootAuthorization.canonicalPath(repositoryRootPath)
        self.worktreeRootPath = GitRepoRootAuthorization.canonicalPath(worktreeRootPath)
        self.commonGitDirectoryPath = GitRepoRootAuthorization.canonicalPath(commonGitDirectoryPath)
        self.mainWorktreeRootPath = mainWorktreeRootPath.map(GitRepoRootAuthorization.canonicalPath)
        self.repositoryID = repositoryID
        self.worktreeID = worktreeID
        self.kind = kind
    }
}

/// Resolves only exact loaded non-Agent roots. It never enumerates sibling or main worktrees.
struct FrozenVisibleGitCheckoutResolver {
    private let vcsService: VCSService

    init(vcsService: VCSService = .shared) {
        self.vcsService = vcsService
    }

    func resolve(
        workspaceRootPaths: [String],
        bindings: [AgentSessionWorktreeBinding],
        store: WorkspaceFileContextStore
    ) async -> [FrozenVisibleGitCheckoutIdentity] {
        let boundLogicalRoots = Set(bindings.flatMap { binding in
            let standardized = StandardizedPath.absolute(
                (binding.logicalRootPath as NSString).expandingTildeInPath
            )
            return [standardized, GitRepoRootAuthorization.canonicalPath(standardized)]
        })

        var identitiesByVisiblePath: [String: [FrozenVisibleGitCheckoutIdentity]] = [:]
        var seenRootRefs = Set<WorkspaceRootRef>()

        for rawRoot in workspaceRootPaths {
            let standardizedRoot = StandardizedPath.absolute(
                (rawRoot as NSString).expandingTildeInPath
            )
            let canonicalRoot = GitRepoRootAuthorization.canonicalPath(standardizedRoot)
            guard !boundLogicalRoots.contains(standardizedRoot),
                  !boundLogicalRoots.contains(canonicalRoot),
                  let workspaceRoot = await store.exactRootRef(
                      path: standardizedRoot,
                      kind: .primaryWorkspace
                  ),
                  seenRootRefs.insert(workspaceRoot).inserted,
                  let resolved = await vcsService.resolveRepo(
                      from: URL(fileURLWithPath: standardizedRoot, isDirectory: true)
                  ),
                  resolved.backendKind == .git,
                  GitRepoRootAuthorization.canonicalPath(resolved.rootURL.path) == canonicalRoot,
                  let layout = await vcsService.gitRepositoryLayout(forRepoRoot: resolved.rootURL),
                  GitRepoRootAuthorization.canonicalPath(layout.workTreeRoot.path) == canonicalRoot
            else { continue }

            let repositoryIdentity = GitWorktreeIdentity.repositoryIdentity(
                commonGitDir: layout.commonDir,
                mainWorktreeRoot: layout.knownMainWorktreeRoot
            )
            let worktreeID = GitWorktreeIdentity.worktreeID(
                repositoryID: repositoryIdentity.repositoryID,
                gitDir: layout.gitDir,
                isMain: !layout.isLinkedWorktree,
                path: layout.workTreeRoot
            )
            let identity = FrozenVisibleGitCheckoutIdentity(
                workspaceRoot: workspaceRoot,
                visibleRootPath: canonicalRoot,
                repositoryRootPath: resolved.rootURL.path,
                worktreeRootPath: layout.workTreeRoot.path,
                commonGitDirectoryPath: layout.commonDir.path,
                mainWorktreeRootPath: layout.knownMainWorktreeRoot?.path,
                repositoryID: repositoryIdentity.repositoryID,
                worktreeID: worktreeID,
                kind: layout.isLinkedWorktree ? .linkedWorktree : .canonical
            )
            identitiesByVisiblePath[canonicalRoot, default: []].append(identity)
        }

        return identitiesByVisiblePath.values
            .compactMap { identities -> FrozenVisibleGitCheckoutIdentity? in
                let unique = Set(identities)
                guard unique.count == 1 else { return nil }
                return unique.first
            }
            .sorted { lhs, rhs in
                let left = [
                    lhs.visibleRootPath,
                    lhs.repositoryID,
                    lhs.worktreeID,
                    lhs.workspaceRoot.id.uuidString
                ].joined(separator: "\u{1f}")
                let right = [
                    rhs.visibleRootPath,
                    rhs.repositoryID,
                    rhs.worktreeID,
                    rhs.workspaceRoot.id.uuidString
                ].joined(separator: "\u{1f}")
                return left < right
            }
    }
}
