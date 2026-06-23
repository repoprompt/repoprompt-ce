import Foundation
import RepoPromptCore

struct ReviewGitSelectedPathCheckout: Equatable {
    let checkoutRootPath: String
    let displayLabel: String
    let selectedPaths: [String]
    let repositoryID: String
    let repoKey: String
    let worktreeID: String
    let kind: FrozenVisibleGitCheckoutKind
}

struct ReviewGitSelectedPathOwnershipResolution: Equatable {
    let checkouts: [ReviewGitSelectedPathCheckout]
    let pathIssues: [ReviewGitPathIssue]
}

/// Resolves frozen selected paths to their nearest exact Git checkout.
///
/// This is the shared ownership boundary for automatic review diffs and Context Builder target
/// election. It never falls back to a workspace root or broadens an unresolved selection.
struct ReviewGitSelectedPathOwnershipResolver {
    struct Dependencies {
        var resolveRepo: @Sendable (URL) async -> VCSResolvedRepo?
        var resolveLayout: @Sendable (URL) -> GitRepositoryLayout?

        static func live(vcsService: VCSService = .shared) -> Dependencies {
            Dependencies(
                resolveRepo: { await vcsService.resolveRepo(from: $0) },
                resolveLayout: { GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: $0) }
            )
        }
    }

    private struct CheckoutGroup {
        let rootPath: String
        let baseDisplayLabel: String
        let repositoryID: String
        let repoKey: String
        let worktreeID: String
        let kind: FrozenVisibleGitCheckoutKind
        var selectedPaths: [String]
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies = .live()) {
        self.dependencies = dependencies
    }

    func resolve(
        _ pathResolution: WorkspaceSelectedGitPathResolution,
        displayContext: ReviewGitDisplayContext
    ) async throws -> ReviewGitSelectedPathOwnershipResolution {
        try Task.checkCancellation()
        var pathIssues = pathResolution.unresolvedCandidates.enumerated().map { index, path in
            ReviewGitPathIssue.unresolvedSelection(
                displayPath: displayContext.displayPath(for: path, fallbackIndex: index + 1)
            )
        }
        var groups: [String: CheckoutGroup] = [:]
        var seenPaths = Set<String>()

        for (index, rawPath) in pathResolution.paths.enumerated() {
            try Task.checkCancellation()
            let physicalPath = StandardizedPath.absolute((rawPath as NSString).expandingTildeInPath)
            guard seenPaths.insert(physicalPath).inserted else { continue }
            let displayPath = displayContext.displayPath(for: physicalPath, fallbackIndex: index + 1)

            guard let resolved = await dependencies.resolveRepo(URL(fileURLWithPath: physicalPath)) else {
                pathIssues.append(.noRepository(displayPath: displayPath))
                continue
            }
            try Task.checkCancellation()
            guard resolved.backendKind == .git else {
                pathIssues.append(.unsupportedBackend(displayPath: displayPath, backendKind: resolved.backendKind))
                continue
            }
            let resolvedRoot = resolved.rootURL.standardizedFileURL
            guard let layout = dependencies.resolveLayout(resolvedRoot) else {
                pathIssues.append(.invalidGitLayout(displayPath: displayPath))
                continue
            }
            let checkoutRoot = layout.workTreeRoot.standardizedFileURL.path
            guard resolvedRoot.path == checkoutRoot,
                  StandardizedPath.isDescendant(physicalPath, of: checkoutRoot),
                  physicalPath != checkoutRoot
            else {
                pathIssues.append(.invalidGitLayout(displayPath: displayPath))
                continue
            }

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
            if var group = groups[checkoutRoot] {
                group.selectedPaths.append(physicalPath)
                groups[checkoutRoot] = group
            } else {
                groups[checkoutRoot] = CheckoutGroup(
                    rootPath: checkoutRoot,
                    baseDisplayLabel: displayContext.checkoutLabel(for: checkoutRoot),
                    repositoryID: repositoryIdentity.repositoryID,
                    repoKey: GitRepoDescriptor(rootURL: layout.workTreeRoot).repoKey,
                    worktreeID: worktreeID,
                    kind: layout.isLinkedWorktree ? .linkedWorktree : .canonical,
                    selectedPaths: [physicalPath]
                )
            }
        }

        let sortedGroups = groups.values.sorted { lhs, rhs in
            if lhs.baseDisplayLabel != rhs.baseDisplayLabel {
                return lhs.baseDisplayLabel < rhs.baseDisplayLabel
            }
            if lhs.repoKey != rhs.repoKey { return lhs.repoKey < rhs.repoKey }
            if lhs.repositoryID != rhs.repositoryID { return lhs.repositoryID < rhs.repositoryID }
            if lhs.worktreeID != rhs.worktreeID { return lhs.worktreeID < rhs.worktreeID }
            return lhs.rootPath < rhs.rootPath
        }
        let labelCounts = Dictionary(grouping: sortedGroups, by: \.baseDisplayLabel).mapValues(\.count)
        var labelOrdinals: [String: Int] = [:]
        let checkouts = sortedGroups.map { group in
            let ordinal = labelOrdinals[group.baseDisplayLabel, default: 0] + 1
            labelOrdinals[group.baseDisplayLabel] = ordinal
            let label = labelCounts[group.baseDisplayLabel, default: 0] > 1
                ? "\(group.baseDisplayLabel) [\(ordinal)]"
                : group.baseDisplayLabel
            return ReviewGitSelectedPathCheckout(
                checkoutRootPath: group.rootPath,
                displayLabel: label,
                selectedPaths: Array(Set(group.selectedPaths)).sorted(),
                repositoryID: group.repositoryID,
                repoKey: group.repoKey,
                worktreeID: group.worktreeID,
                kind: group.kind
            )
        }
        return ReviewGitSelectedPathOwnershipResolution(checkouts: checkouts, pathIssues: pathIssues)
    }
}
