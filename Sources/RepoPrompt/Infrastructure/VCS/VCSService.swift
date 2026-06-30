import Foundation

// MARK: - VCS Resolved Repo

/// Represents a resolved VCS repository with its backend.
public struct VCSResolvedRepo: Sendable {
    /// The repository root URL.
    public let rootURL: URL

    /// The kind of VCS backend.
    public let backendKind: VCSBackendKind

    public init(rootURL: URL, backendKind: VCSBackendKind) {
        self.rootURL = rootURL
        self.backendKind = backendKind
    }
}

// MARK: - VCS Service

/// Central service for VCS operations that auto-detects and caches backends.
///
/// This service determines whether to use git or jj for a given repository:
/// 1. If `.jj` directory exists at the path → use Jujutsu backend
/// 2. If `.git` directory exists → use Git backend
/// 3. Otherwise, try `jj root` then `git rev-parse --show-toplevel` to find repo root
///
/// Policy: When both `.git` and `.jj` exist, prefer Jujutsu (jj colocates with git).
public actor VCSService {
    // MARK: - Singleton

    /// Shared instance of VCSService.
    public static let shared = VCSService()

    // MARK: - Properties

    /// Git backend instance (lazy-initialized).
    private var _gitBackend: GitBackend?

    /// Jujutsu backend instance (lazy-initialized).
    private var _jjBackend: JujutsuBackend?

    /// JJ command runner for availability checks.
    private let jjRunner: JJCommandRunner

    /// Cache of resolved repos by path.
    /// Key: standardized absolute path, Value: resolved repo info.
    private var resolvedRepoCache: [String: VCSResolvedRepo] = [:]

    /// Cache of backend kind per repo root.
    /// Key: repo root path, Value: backend kind.
    private var backendKindCache: [String: VCSBackendKind] = [:]

    /// Cache of Git repository layouts (for worktree awareness).
    /// Key: repo root path, Value: resolved layout
    /// Only populated for confirmed Git repos; absence means not yet resolved.
    private var gitLayoutCache: [String: GitRepositoryLayout] = [:]

    /// Whether jj is available on this system (cached after first check).
    private var _jjAvailable: Bool?

    // MARK: - Initialization

    public init(jjRunner: JJCommandRunner = JJCommandRunner()) {
        self.jjRunner = jjRunner
    }

    // MARK: - Backend Access

    /// Get the Git backend instance.
    func gitBackend() -> GitBackend {
        if let existing = _gitBackend {
            return existing
        }
        let backend = GitBackend()
        _gitBackend = backend
        return backend
    }

    /// Get the Jujutsu backend instance.
    public func jjBackend() -> JujutsuBackend {
        if let existing = _jjBackend {
            return existing
        }
        let backend = JujutsuBackend(runner: jjRunner)
        _jjBackend = backend
        return backend
    }

    /// Get a backend by kind.
    public func backend(for kind: VCSBackendKind) -> any VCSBackend {
        switch kind {
        case .git:
            gitBackend()
        case .jujutsu:
            jjBackend()
        }
    }

    // MARK: - Availability

    /// Check if jj is available on this system.
    public func isJJAvailable() async -> Bool {
        if let cached = _jjAvailable {
            return cached
        }
        let available = await jjRunner.isAvailable()
        _jjAvailable = available
        return available
    }

    /// Check if git is available on this system.
    /// Git is assumed available via /usr/bin/git on macOS.
    public func isGitAvailable() -> Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/git")
    }

    // MARK: - Repository Resolution

    /// Resolve a path to its VCS repository information.
    /// Returns nil if the path is not in a VCS repository.
    ///
    /// - Parameter url: The starting path to search from.
    /// - Returns: The resolved repo info, or nil if not in a repo.
    public func resolveRepo(from url: URL) async -> VCSResolvedRepo? {
        let standardizedPath = url.standardizedFileURL.path

        // Check cache first
        if let cached = resolvedRepoCache[standardizedPath] {
            return cached
        }

        // Detect VCS type and find root
        if let result = await detectAndResolve(from: url) {
            // Cache by both the query path and the root path
            resolvedRepoCache[standardizedPath] = result
            resolvedRepoCache[result.rootURL.standardizedFileURL.path] = result
            backendKindCache[result.rootURL.standardizedFileURL.path] = result.backendKind
            return result
        }

        return nil
    }

    /// Get the backend for a known repository root.
    /// Use this when you already know the repo root from a previous resolve call.
    ///
    /// - Parameter rootURL: The repository root URL.
    /// - Returns: The appropriate backend for this repo.
    public func backend(forRepoRoot rootURL: URL) async -> any VCSBackend {
        let rootPath = rootURL.standardizedFileURL.path

        // Check cache first
        if let cachedKind = backendKindCache[rootPath] {
            return backend(for: cachedKind)
        }

        // Resolve to determine kind
        if let resolved = await resolveRepo(from: rootURL) {
            return backend(for: resolved.backendKind)
        }

        // Default to git if resolution fails
        return gitBackend()
    }

    /// Clear the resolution cache.
    /// Useful when workspace roots change.
    public func clearCache() {
        resolvedRepoCache.removeAll()
        backendKindCache.removeAll()
        gitLayoutCache.removeAll()
    }

    /// Remove a specific path from the cache.
    /// Also invalidates the resolved root if different from the input path.
    public func invalidateCache(for url: URL) {
        let path = url.standardizedFileURL.path

        // Get the resolved root path before removing (if cached)
        let rootPath = resolvedRepoCache[path]?.rootURL.standardizedFileURL.path

        // Remove caches for the input path
        resolvedRepoCache.removeValue(forKey: path)
        backendKindCache.removeValue(forKey: path)
        gitLayoutCache.removeValue(forKey: path)

        // Also remove caches for the resolved root if different
        if let rootPath, rootPath != path {
            resolvedRepoCache.removeValue(forKey: rootPath)
            backendKindCache.removeValue(forKey: rootPath)
            gitLayoutCache.removeValue(forKey: rootPath)
        }
    }

    // MARK: - Git Layout Access

    /// Get the Git repository layout for a known repo root.
    /// Returns nil for non-Git repos (including JJ colocated repos) or if layout cannot be resolved.
    ///
    /// This is useful for understanding worktree configurations:
    /// - `layout.isWorktree` indicates if this is a gitfile-based worktree
    /// - `layout.gitDir` is the actual git directory
    /// - `layout.commonDir` is the shared repo data (same as gitDir for non-worktrees)
    ///
    /// Note: For JJ colocated repos (where both .jj and .git exist), this returns nil
    /// because JJ is the preferred backend and Git layout details are not relevant.
    public func gitRepositoryLayout(forRepoRoot rootURL: URL) -> GitRepositoryLayout? {
        let rootPath = rootURL.standardizedFileURL.path

        // If we know this is a JJ repo, don't return Git layout
        // (JJ colocated repos have both .jj and .git, but JJ is preferred)
        if let knownKind = backendKindCache[rootPath], knownKind != .git {
            return nil
        }

        // Check cache first
        if let cached = gitLayoutCache[rootPath] {
            return cached
        }

        // Resolve layout
        guard let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: rootURL) else {
            return nil
        }

        // Cache and return
        gitLayoutCache[rootPath] = layout
        return layout
    }

    // MARK: - Detection Logic

    /// Detect the VCS type and find the repository root.
    private func detectAndResolve(from url: URL) async -> VCSResolvedRepo? {
        let fm = FileManager.default
        let startPath = url.standardizedFileURL.path

        // Walk up the directory tree looking for .jj or .git
        var currentURL = url.standardizedFileURL

        // Ensure we're starting from a directory
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: currentURL.path, isDirectory: &isDir) {
            if !isDir.boolValue {
                currentURL = currentURL.deletingLastPathComponent()
            }
        }

        while currentURL.path != "/", currentURL.path != "" {
            let jjPath = currentURL.appendingPathComponent(".jj").path
            let gitPath = currentURL.appendingPathComponent(".git").path

            let hasJJ = fm.fileExists(atPath: jjPath)
            let hasGit = fm.fileExists(atPath: gitPath)

            // Policy: prefer jj when both exist (jj colocates with git)
            if hasJJ {
                // Verify jj is actually available
                if await isJJAvailable() {
                    return VCSResolvedRepo(rootURL: currentURL, backendKind: .jujutsu)
                }
                // If jj not available but .jj exists, fall through to git check
            }

            if hasGit {
                // For .git files (worktrees/submodules), verify it's a valid gitfile
                // before treating as a Git repo. This avoids false positives from
                // arbitrary files named .git.
                var isGitDir: ObjCBool = false
                _ = fm.fileExists(atPath: gitPath, isDirectory: &isGitDir)

                if isGitDir.boolValue {
                    // .git is a directory - definitely a Git repo
                    let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: currentURL)
                    if let layout {
                        gitLayoutCache[currentURL.standardizedFileURL.path] = layout
                    }
                    return VCSResolvedRepo(rootURL: currentURL, backendKind: .git)
                } else {
                    // .git is a file - only treat as Git if it's a valid gitfile
                    if let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: currentURL) {
                        gitLayoutCache[currentURL.standardizedFileURL.path] = layout
                        return VCSResolvedRepo(rootURL: currentURL, backendKind: .git)
                    }
                    // Invalid gitfile - continue searching up the tree
                }
            }

            currentURL = currentURL.deletingLastPathComponent()
        }

        // No .jj or .git found in directory walk
        // Try command-based detection as fallback

        // Try jj first if available
        if await isJJAvailable() {
            let jj = jjBackend()
            if let root = try? await jj.findRepoRoot(from: url) {
                return VCSResolvedRepo(rootURL: root, backendKind: .jujutsu)
            }
        }

        // Try git
        let git = gitBackend()
        if let root = try? await git.findRepoRoot(from: url) {
            // Cache the Git layout for worktree awareness
            if let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: root) {
                gitLayoutCache[root.standardizedFileURL.path] = layout
            }
            return VCSResolvedRepo(rootURL: root, backendKind: .git)
        }

        return nil
    }

    // MARK: - Convenience Methods

    /// Check if a path is in a VCS repository.
    public func isRepository(at url: URL) async -> Bool {
        await resolveRepo(from: url) != nil
    }

    /// Get the repository root for a path, if any.
    public func repoRoot(from url: URL) async -> URL? {
        await resolveRepo(from: url)?.rootURL
    }

    /// Get the backend kind for a path.
    public func backendKind(for url: URL) async -> VCSBackendKind? {
        await resolveRepo(from: url)?.backendKind
    }
}

// MARK: - VCS Service Extensions for Common Operations

public extension VCSService {
    /// Get the current HEAD ID for a repository.
    func getHeadID(at repoURL: URL) async throws -> String {
        let backend = await backend(forRepoRoot: repoURL)
        return try await backend.getHeadID(at: repoURL)
    }

    /// Get the status fingerprint for a repository.
    func getStatusFingerprint(at repoURL: URL, baseRef: String = "HEAD") async throws -> GitDiffFingerprint {
        let backend = await backend(forRepoRoot: repoURL)
        return try await backend.getStatusFingerprint(at: repoURL, baseRef: baseRef)
    }

    /// Get changed files with statistics.
    func getChangedFilesStats(
        compare: GitDiffCompareSpec,
        includeUntrackedWhenApplicable: Bool = true,
        detectRenames: Bool = false,
        at repoURL: URL
    ) async throws -> [VCSUncommittedFile] {
        let backend = await backend(forRepoRoot: repoURL)
        return try await backend.getChangedFilesStats(
            compare: compare,
            includeUntrackedWhenApplicable: includeUntrackedWhenApplicable,
            detectRenames: detectRenames,
            at: repoURL
        )
    }

    /// Get diff text for a comparison.
    func getDiffText(
        compare: GitDiffCompareSpec,
        paths: [String]? = nil,
        contextLines: Int = 3,
        detectRenames: Bool = false,
        at repoURL: URL
    ) async throws -> String {
        let backend = await backend(forRepoRoot: repoURL)
        return try await backend.getDiffText(
            compare: compare,
            paths: paths,
            contextLines: contextLines,
            detectRenames: detectRenames,
            at: repoURL
        )
    }

    /// Get the current branch name.
    func getCurrentBranch(at repoURL: URL) async throws -> String? {
        let backend = await backend(forRepoRoot: repoURL)
        return try await backend.getCurrentBranch(at: repoURL)
    }

    /// Get local branches.
    func getLocalBranches(at repoURL: URL, limit: Int = 50) async throws -> [VCSBranch] {
        let backend = await backend(forRepoRoot: repoURL)
        return try await backend.getLocalBranches(at: repoURL, limit: limit)
    }
}

extension VCSService {
    func gitBranchSwitchOptions(at repoURL: URL) async throws -> GitBranchSwitchOptions {
        let resolved = try await requireGitBranchSwitchRepo(repoURL, operation: "branch_switch_options")
        return try await gitBackend().gitBranchSwitchOptions(at: resolved.rootURL)
    }

    func preflightGitBranchSwitch(branchName: String, at repoURL: URL) async throws -> GitBranchSwitchPreflight {
        let resolved = try await requireGitBranchSwitchRepo(repoURL, operation: "branch_switch_preflight")
        return try await gitBackend().preflightGitBranchSwitch(branchName: branchName, at: resolved.rootURL)
    }

    func switchGitBranch(_ request: GitBranchSwitchRequest, at repoURL: URL) async throws -> GitBranchSwitchResult {
        let resolved = try await requireGitBranchSwitchRepo(repoURL, operation: "branch_switch")
        let result = try await gitBackend().switchGitBranch(request, at: resolved.rootURL)
        invalidateCache(for: resolved.rootURL)
        return result
    }

    private func requireGitBranchSwitchRepo(_ repoURL: URL, operation: String) async throws -> VCSResolvedRepo {
        guard let resolved = await resolveRepo(from: repoURL) else {
            throw VCSError.notARepository(path: repoURL.path)
        }
        guard resolved.backendKind == .git else {
            throw VCSError.unsupportedOperation(operation: operation, backend: resolved.backendKind)
        }
        return resolved
    }
}

public extension VCSService {
    /// Get the working status.
    func getWorkingStatus(at repoURL: URL) async throws -> VCSWorkingStatus {
        let backend = await backend(forRepoRoot: repoURL)
        return try await backend.getWorkingStatus(at: repoURL)
    }

    /// Get commit log summaries.
    func getLogSummaries(
        count: Int = 10,
        path: String? = nil,
        at repoURL: URL
    ) async throws -> [VCSCommitSummary] {
        let backend = await backend(forRepoRoot: repoURL)
        return try await backend.getLogSummaries(count: count, path: path, at: repoURL)
    }

    /// Get the commit graph.
    func getCommitGraph(maxLines: Int = 20, at repoURL: URL) async throws -> String {
        let backend = await backend(forRepoRoot: repoURL)
        return try await backend.getCommitGraph(maxLines: maxLines, at: repoURL)
    }

    /// Get commit info.
    func commitInfo(ref: String, at repoURL: URL) async throws -> VCSCommitInfo {
        let backend = await backend(forRepoRoot: repoURL)
        return try await backend.commitInfo(ref: ref, at: repoURL)
    }

    /// Get blame for a file.
    func blame(
        path: String,
        lineRange: ClosedRange<Int>? = nil,
        at repoURL: URL
    ) async throws -> [VCSBlameLine] {
        let backend = await backend(forRepoRoot: repoURL)
        return try await backend.blame(path: path, lineRange: lineRange, at: repoURL)
    }

    /// Fetch from remotes.
    func fetch(at repoURL: URL) async throws {
        let backend = await backend(forRepoRoot: repoURL)
        try await backend.fetch(at: repoURL)
    }

    /// List Git worktrees for a repository.
    func listGitWorktrees(at repoURL: URL) async throws -> [GitWorktreeDescriptor] {
        let resolved = await resolveRepo(from: repoURL)
        guard let resolved else {
            throw VCSError.notARepository(path: repoURL.path)
        }
        return try await listGitWorktrees(for: resolved)
    }

    func listGitWorktrees(for resolved: VCSResolvedRepo) async throws -> [GitWorktreeDescriptor] {
        guard resolved.backendKind == .git else {
            throw VCSError.unsupportedOperation(operation: "list_worktrees", backend: resolved.backendKind)
        }
        return try await gitBackend().listWorktrees(at: resolved.rootURL)
    }

    /// Resolve the read-only Git repo/worktree/branch context for a filesystem path.
    ///
    /// The input may be either a worktree root or a subdirectory inside a worktree.
    /// Non-Git roots return `nil`; no checkout, branch switching, or worktree mutation
    /// is performed.
    func gitWorktreeContext(for url: URL) async -> GitWorktreeContextSummary? {
        guard let resolved = await resolveRepo(from: url) else { return nil }
        return await gitWorktreeContext(for: url, resolved: resolved)
    }

    func gitWorktreeContext(for url: URL, resolved: VCSResolvedRepo) async -> GitWorktreeContextSummary? {
        guard resolved.backendKind == .git else { return nil }
        do {
            let worktrees = try await listGitWorktrees(for: resolved)
            return await gitWorktreeContext(for: url, resolved: resolved, worktrees: worktrees)
        } catch {
            return await gitWorktreeContext(for: url, resolved: resolved, worktrees: nil)
        }
    }

    func gitWorktreeContext(
        for url: URL,
        resolved: VCSResolvedRepo,
        worktrees: [GitWorktreeDescriptor]?
    ) async -> GitWorktreeContextSummary? {
        guard resolved.backendKind == .git else { return nil }

        if let worktrees,
           let summary = gitWorktreeContextFromList(
               for: url,
               resolved: resolved,
               worktrees: worktrees
           )
        {
            return summary
        }

        return await fallbackGitWorktreeContext(for: resolved.rootURL)
    }

    private nonisolated func gitWorktreeContextFromList(
        for url: URL,
        resolved: VCSResolvedRepo,
        worktrees: [GitWorktreeDescriptor]
    ) -> GitWorktreeContextSummary? {
        let inputPath = StandardizedPath.absolute(url.path)
        let resolvedRootPath = StandardizedPath.absolute(resolved.rootURL.path)
        if let exact = worktrees.first(where: { StandardizedPath.absolute($0.path) == resolvedRootPath }) {
            return GitWorktreeContextSummary(descriptor: exact)
        }
        if let contained = worktrees.first(where: { descriptor in
            let worktreePath = StandardizedPath.absolute(descriptor.path)
            return StandardizedPath.isDescendant(inputPath, of: worktreePath)
                || StandardizedPath.isDescendant(resolvedRootPath, of: worktreePath)
        }) {
            return GitWorktreeContextSummary(descriptor: contained)
        }
        return nil
    }

    private func fallbackGitWorktreeContext(for repoURL: URL) async -> GitWorktreeContextSummary? {
        let repoRootPath = StandardizedPath.absolute(repoURL.path)
        guard let layout = gitRepositoryLayout(forRepoRoot: repoURL) else {
            return nil
        }
        let isMain = !layout.isLinkedWorktree
        let identity = GitWorktreeIdentity.repositoryIdentity(
            commonGitDir: layout.commonDir,
            mainWorktreeRoot: layout.knownMainWorktreeRoot
        )
        let branch = try? await gitBackend().getCurrentBranch(at: repoURL)
        let head = try? await gitBackend().getHeadID(at: repoURL)
        let worktreeName = Self.fallbackName(from: repoRootPath, fallback: "worktree")
        let worktreeID = GitWorktreeIdentity.worktreeID(
            repositoryID: identity.repositoryID,
            gitDir: layout.gitDir,
            isMain: isMain,
            path: layout.workTreeRoot
        )
        return GitWorktreeContextSummary(
            repositoryID: identity.repositoryID,
            repoKey: identity.repoKey,
            repositoryDisplayName: identity.displayName,
            worktreeID: worktreeID,
            worktreePath: repoRootPath,
            worktreeName: worktreeName,
            isMain: isMain,
            branch: branch,
            head: head,
            isDetached: branch == nil && head != nil
        )
    }

    private nonisolated static func fallbackName(from path: String, fallback: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? fallback : name
    }

    /// Create a Git worktree for a repository.
    func createGitWorktree(
        request: GitWorktreeCreateRequest,
        at repoURL: URL
    ) async throws -> GitWorktreeDescriptor {
        let result = try await createGitWorktreeWithResult(request: request, at: repoURL)
        if let warning = result.includeCopyResult?.warningText {
            NSLog("RepoPrompt .worktreeinclude copy warning for worktree %@: %@", result.descriptor.path, warning)
        }
        return result.descriptor
    }

    /// Create a Git worktree and keep best-effort `.worktreeinclude` copy details.
    internal func createGitWorktreeWithResult(
        request: GitWorktreeCreateRequest,
        at repoURL: URL,
        initializationContext: GitWorktreeInitializationContext? = nil
    ) async throws -> GitWorktreeCreateResult {
        let resolved = await resolveRepo(from: repoURL)
        guard let resolved else {
            throw VCSError.notARepository(path: repoURL.path)
        }
        guard resolved.backendKind == .git else {
            throw VCSError.unsupportedOperation(operation: "create_worktree", backend: resolved.backendKind)
        }

        let result = try await gitBackend().createWorktreeWithResult(
            request: request,
            at: resolved.rootURL,
            initializationContext: initializationContext
        )
        invalidateCache(for: resolved.rootURL)
        invalidateCache(for: request.path)
        return result
    }

    func inspectGitWorktreeMerge(_ request: GitWorktreeMergeInspectRequest) async throws -> GitWorktreeMergeInspection {
        try await requireGitMergeEndpoints(source: request.source, target: request.target)
        return try await gitBackend().inspectWorktreeMerge(request)
    }

    func previewGitWorktreeMerge(_ request: GitWorktreeMergePreviewRequest) async throws -> GitWorktreeMergePreview {
        let inspection = try await inspectGitWorktreeMerge(.init(
            source: request.source,
            target: request.target,
            graphLimit: request.graphLimit
        ))
        let operationID = "merge_\(UUID().uuidString.lowercased())"
        let artifacts = if request.publishArtifacts {
            try await GitWorktreeMergePreviewPublisher.shared.publish(
                request: request,
                inspection: inspection,
                operationID: operationID
            )
        } else {
            GitWorktreeMergePreviewArtifacts?.none
        }
        return GitWorktreeMergePreview(operationID: operationID, inspection: inspection, artifacts: artifacts)
    }

    func applyGitWorktreeMerge(_ request: GitWorktreeMergeApplyRequest) async throws -> GitWorktreeMergeApplyResult {
        let inspection = request.preview.inspection
        try await requireGitMergeEndpoints(source: inspection.source, target: inspection.target)
        guard inspection.blockers.isEmpty else {
            return GitWorktreeMergeApplyResult(
                status: .failed,
                source: inspection.source,
                target: inspection.target,
                sourceHead: inspection.sourceHead,
                targetHeadBefore: inspection.targetHead,
                errorMessage: inspection.blockers.map(\.message).joined(separator: "\n")
            )
        }
        if let staleReason = try await staleReason(for: inspection) {
            return GitWorktreeMergeApplyResult(
                status: .stale,
                source: inspection.source,
                target: inspection.target,
                sourceHead: inspection.sourceHead,
                targetHeadBefore: inspection.targetHead,
                staleReason: staleReason
            )
        }

        if try await gitBackend().isAncestor(inspection.sourceHead, of: inspection.targetHead, at: inspection.target.url) {
            return GitWorktreeMergeApplyResult(
                status: .noOp,
                source: inspection.source,
                target: inspection.target,
                sourceHead: inspection.sourceHead,
                targetHeadBefore: inspection.targetHead,
                targetHeadAfter: inspection.targetHead
            )
        }

        let message = mergeCommitMessage(
            request.commitMessage,
            source: inspection.source,
            target: inspection.target,
            sourceHead: inspection.sourceHead
        )
        let applied = try await gitBackend().applyAndCommitWorktreeMerge(
            sourceHead: inspection.sourceHead,
            message: message,
            at: inspection.target.url
        )
        if !applied.state.conflictFiles.isEmpty {
            return GitWorktreeMergeApplyResult(
                status: .conflicted,
                source: inspection.source,
                target: inspection.target,
                sourceHead: inspection.sourceHead,
                targetHeadBefore: inspection.targetHead,
                conflictFiles: applied.state.conflictFiles
            )
        }
        guard let commit = applied.commit else {
            return GitWorktreeMergeApplyResult(
                status: .noOp,
                source: inspection.source,
                target: inspection.target,
                sourceHead: inspection.sourceHead,
                targetHeadBefore: inspection.targetHead,
                targetHeadAfter: inspection.targetHead
            )
        }
        invalidateCache(for: inspection.target.url)
        return GitWorktreeMergeApplyResult(
            status: .completed,
            source: inspection.source,
            target: inspection.target,
            sourceHead: inspection.sourceHead,
            targetHeadBefore: inspection.targetHead,
            targetHeadAfter: commit,
            mergeCommit: commit
        )
    }

    func continueGitWorktreeMerge(_ request: GitWorktreeMergeContinueRequest) async throws -> GitWorktreeMergeApplyResult {
        try await requireGitMergeEndpoints(source: request.source, target: request.target)
        let message = mergeCommitMessage(
            request.commitMessage,
            source: request.source,
            target: request.target,
            sourceHead: request.sourceHead
        )
        do {
            let commit = try await gitBackend().continueWorktreeMerge(message: message, at: request.target.url)
            invalidateCache(for: request.target.url)
            return GitWorktreeMergeApplyResult(
                status: .completed,
                source: request.source,
                target: request.target,
                sourceHead: request.sourceHead,
                targetHeadBefore: request.targetHeadBefore,
                targetHeadAfter: commit,
                mergeCommit: commit
            )
        } catch {
            let state = try? await gitBackend().inspectMergeState(at: request.target.url)
            return GitWorktreeMergeApplyResult(
                status: .failed,
                source: request.source,
                target: request.target,
                sourceHead: request.sourceHead,
                targetHeadBefore: request.targetHeadBefore,
                conflictFiles: state?.conflictFiles ?? [],
                errorMessage: error.localizedDescription
            )
        }
    }

    func abortGitWorktreeMerge(_ request: GitWorktreeMergeAbortRequest) async throws -> GitWorktreeMergeAbortResult {
        try await requireGitMergeEndpoint(request.target, operation: "abort_worktree_merge")
        let aborted = try await gitBackend().abortWorktreeMerge(at: request.target.url)
        let targetHead = try await gitBackend().getHeadID(at: request.target.url)
        invalidateCache(for: request.target.url)
        return GitWorktreeMergeAbortResult(
            aborted: aborted,
            target: request.target,
            targetHead: targetHead,
            message: aborted ? nil : "No Git merge was in progress."
        )
    }

    private func requireGitMergeEndpoints(source: GitWorktreeMergeEndpoint, target: GitWorktreeMergeEndpoint) async throws {
        try await requireGitMergeEndpoint(source, operation: "manage_worktree.merge")
        try await requireGitMergeEndpoint(target, operation: "manage_worktree.merge")
        guard source.repositoryID == target.repositoryID else {
            throw VCSError.commandFailed(command: "manage_worktree.merge", message: "Source and target worktrees are from different repositories.")
        }
        guard source.worktreeID != target.worktreeID else {
            throw VCSError.commandFailed(command: "manage_worktree.merge", message: "Source and target worktrees are the same worktree.")
        }
    }

    private func requireGitMergeEndpoint(_ endpoint: GitWorktreeMergeEndpoint, operation: String) async throws {
        let url = endpoint.url
        let resolved = await resolveRepo(from: url)
        guard let resolved else {
            throw VCSError.notARepository(path: endpoint.path)
        }
        guard resolved.backendKind == .git else {
            throw VCSError.unsupportedOperation(operation: operation, backend: resolved.backendKind)
        }
    }

    private func staleReason(for inspection: GitWorktreeMergeInspection) async throws -> String? {
        let git = gitBackend()
        let sourceFingerprint = try await git.getStatusFingerprint(at: inspection.source.url, baseRef: "HEAD")
        if sourceFingerprint != inspection.sourceFingerprint {
            return "Source worktree changed since preview."
        }
        let targetFingerprint = try await git.getStatusFingerprint(at: inspection.target.url, baseRef: "HEAD")
        if targetFingerprint != inspection.targetFingerprint {
            return "Target worktree changed since preview."
        }
        return nil
    }

    private func mergeCommitMessage(
        _ requested: String?,
        source: GitWorktreeMergeEndpoint,
        target: GitWorktreeMergeEndpoint,
        sourceHead: String
    ) -> String {
        let trimmed = requested?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { return trimmed }
        let sourceLabel = source.branch ?? source.displayName
        let targetLabel = target.branch ?? target.displayName
        return "Merge \(sourceLabel) into \(targetLabel)\n\nRepoPrompt-Source-Head: \(sourceHead)"
    }

    /// Get the capabilities for a repository.
    func capabilities(at repoURL: URL) async -> VCSCapabilities {
        let backend = await backend(forRepoRoot: repoURL)
        return backend.capabilities
    }

    /// Normalize a compare spec for a repository, returning any applicable warning.
    func normalizeCompareSpec(
        _ spec: GitDiffCompareSpec,
        at repoURL: URL
    ) async -> NormalizedCompareResult {
        let backend = await backend(forRepoRoot: repoURL)
        if let withWarnings = backend as? VCSBackendWithWarnings {
            return withWarnings.normalizeCompareSpecWithWarning(spec)
        }
        return NormalizedCompareResult(spec: backend.normalizeCompareSpec(spec), warning: nil)
    }
}
