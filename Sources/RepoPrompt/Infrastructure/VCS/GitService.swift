import CryptoKit
import Darwin
import Foundation

/// Async Git helper for fetching repository information
/// Based on the macOS 14+ Swift Git integration guide
actor GitService {
    private static let gitProcessTimeout: Duration = .seconds(120)
    private static let gitProcessTerminationGrace: Duration = .seconds(5)

    // MARK: - Types

    struct GitError: LocalizedError {
        let message: String
        var errorDescription: String? {
            GitService.friendlyErrorDescription(for: message)
        }
    }

    // MARK: - Worktree Layout Cache

    /// Cached Git repository layouts to avoid repeated filesystem checks.
    /// Key: standardized repo root path
    /// Value: resolved layout (only non-nil results are cached)
    private var worktreeLayoutCache: [String: GitRepositoryLayout] = [:]

    /// Get the repository layout for a given repo URL, using cache when available.
    /// Only caches successful resolutions to prevent unbounded cache growth from
    /// calls with non-repo paths.
    private func getLayout(for repoURL: URL) -> GitRepositoryLayout? {
        let key = repoURL.standardizedFileURL.path

        if let cached = worktreeLayoutCache[key] {
            return cached
        }

        let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: repoURL)
        // Only cache non-nil to avoid unbounded growth from failed lookups
        if let layout {
            worktreeLayoutCache[key] = layout
        }
        return layout
    }

    /// Clear the worktree layout cache (e.g., when workspace changes).
    func clearLayoutCache() {
        worktreeLayoutCache.removeAll()
    }

    private let worktreeMutationCoordinator = GitWorktreeMutationCoordinator()
    private let inheritedProcessEnvironment = ProcessInfo.processInfo.environment
    private var preparedBaseProcessEnvironment: [String: String]?

    struct UncommittedFile: Equatable {
        let path: String
        let status: String // M, A, D, R, C, U, ?, !
        let additions: Int?
        let deletions: Int?

        init(
            path: String,
            status: String,
            additions: Int? = nil,
            deletions: Int? = nil
        ) {
            self.path = path
            self.status = status
            self.additions = additions
            self.deletions = deletions
        }
    }

    struct Branch {
        let name: String
        let isCurrent: Bool
        let lastCommitDate: Date?
    }

    struct Tag {
        let name: String
        let commitDate: Date?
    }

    /// Determines which reference the working tree is compared against
    enum CompareBase {
        /// Compare working tree against HEAD (includes staged & unstaged changes)
        case head
        /// Compare working tree/current branch against the specified branch
        case branch(String)
    }

    // MARK: - Public API

    /// Find the git repository root starting from the given path
    func findGitRoot(from path: URL) async throws -> URL? {
        let (stdout, _, exitCode) = try await runGit(
            ["rev-parse", "--show-toplevel"],
            at: path
        )

        guard exitCode == 0 else {
            return nil // Not a git repository or not found
        }

        let rootPath = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: rootPath)
    }

    /// Check if the given path is within a git repository
    func isGitRepository(at path: URL) async -> Bool {
        do {
            let _ = try await findGitRoot(from: path)
            return true
        } catch {
            return false
        }
    }

    /// List Git worktrees for the repository using porcelain output.
    /// Prefers `--porcelain -z` and falls back to newline-delimited porcelain on older Git versions.
    func listWorktrees(at repoURL: URL) async throws -> [GitWorktreeDescriptor] {
        let (stdout, stderr, exitCode) = try await runGit(
            ["worktree", "list", "--porcelain", "-z"],
            at: repoURL
        )

        if exitCode == 0 {
            let records = try GitWorktreePorcelainParser.parse(stdout, format: .nulTerminated)
            return try await makeWorktreeDescriptors(from: records, currentRepoURL: repoURL)
        }

        guard Self.shouldFallbackFromWorktreeListZError(stderr) else {
            throw GitError(message: "git worktree list --porcelain -z failed: \(stderr)")
        }

        let (fallbackStdout, fallbackStderr, fallbackExitCode) = try await runGit(
            ["worktree", "list", "--porcelain"],
            at: repoURL
        )
        guard fallbackExitCode == 0 else {
            throw GitError(message: "git worktree list --porcelain failed: \(fallbackStderr)")
        }

        let records = try GitWorktreePorcelainParser.parse(fallbackStdout, format: .newlineTerminated)
        return try await makeWorktreeDescriptors(from: records, currentRepoURL: repoURL)
    }

    /// Create a Git worktree using the existing Git subprocess plumbing.
    func createWorktree(
        request: GitWorktreeCreateRequest,
        at repoURL: URL
    ) async throws -> GitWorktreeDescriptor {
        let result = try await createWorktreeWithResult(request: request, at: repoURL)
        return result.descriptor
    }

    /// Create a Git worktree and return best-effort `.worktreeinclude` copy details.
    func createWorktreeWithResult(
        request: GitWorktreeCreateRequest,
        at repoURL: URL
    ) async throws -> GitWorktreeCreateResult {
        let mutationKey = getLayout(for: repoURL)?.commonDir.standardizedFileURL.path
            ?? repoURL.standardizedFileURL.path

        let created = try await worktreeMutationCoordinator.withLock(key: mutationKey) { [weak self] in
            guard let self else {
                throw GitError(message: "git service was released before worktree creation")
            }
            if let mainWorktreeRoot = request.mainWorktreeRoot {
                try GitWorktreeDefaultPathPlanner.validate(
                    path: request.path,
                    mainWorktreeRoot: mainWorktreeRoot,
                    knownWorktreeRoots: request.knownWorktreeRoots,
                    appManagedContainer: request.appManagedContainer,
                    allowExternalPath: request.allowExternalPath
                )
            }
            var args = ["worktree", "add"]
            if request.force {
                args.append("--force")
            }
            if request.detach {
                args.append("--detach")
            }
            if let lockReason = request.lockReason {
                args.append("--lock")
                if !lockReason.isEmpty {
                    args.append("--reason")
                    args.append(lockReason)
                }
            }
            if let branch = request.branch, !branch.isEmpty {
                args.append("-b")
                args.append(branch)
            }
            args.append(request.path.standardizedFileURL.path)
            if let baseRef = request.baseRef, !baseRef.isEmpty {
                args.append(baseRef)
            }

            let (_, stderr, exitCode) = try await runGit(args, at: repoURL)
            guard exitCode == 0 else {
                throw GitError(message: "git worktree add failed: \(stderr)")
            }

            await clearLayoutCache()
            let createdPath = request.path.standardizedFileURL.path
            let worktrees = try await listWorktrees(at: repoURL)
            if let created = worktrees.first(where: { $0.path == createdPath }) {
                return created
            }

            throw GitError(message: "git worktree add succeeded but created worktree was not listed: \(createdPath)")
        }

        let destinationURL = URL(fileURLWithPath: created.path, isDirectory: true)
        let includeCopyResult = await copyWorktreeIncludeFilesIfRequested(
            request: request,
            sourceRepoURL: repoURL,
            destinationURL: destinationURL
        )
        return GitWorktreeCreateResult(descriptor: created, includeCopyResult: includeCopyResult)
    }

    private func copyWorktreeIncludeFilesIfRequested(
        request: GitWorktreeCreateRequest,
        sourceRepoURL: URL,
        destinationURL: URL
    ) async -> GitWorktreeIncludeCopyResult? {
        guard request.copyWorktreeIncludeFiles,
              let appManagedContainer = request.appManagedContainer,
              Self.isPath(destinationURL, equalToOrInside: appManagedContainer)
        else { return nil }
        let includeURL = sourceRepoURL.appendingPathComponent(".worktreeinclude", isDirectory: false)
        guard FileManager.default.fileExists(atPath: includeURL.path) else { return nil }

        do {
            let (stdout, stderr, exitCode) = try await runGit(
                ["ls-files", "--others", "--ignored", "--exclude-standard", "-z"],
                at: sourceRepoURL
            )
            guard exitCode == 0 else {
                return GitWorktreeIncludeCopyResult(
                    copiedCount: 0,
                    matchedCount: 0,
                    errorSummaries: ["could not list Git-ignored files: \(stderr)"]
                )
            }
            return GitWorktreeIncludeCopier.copyIncludedFiles(
                from: sourceRepoURL,
                to: destinationURL,
                ignoredFilesNULOutput: stdout,
                appManagedContainer: appManagedContainer
            )
        } catch {
            return GitWorktreeIncludeCopyResult(
                copiedCount: 0,
                matchedCount: 0,
                errorSummaries: ["could not copy .worktreeinclude files: \(error.localizedDescription)"]
            )
        }
    }

    private static func isPath(_ path: URL, equalToOrInside root: URL) -> Bool {
        StandardizedPath.isDescendant(
            StandardizedPath.absolute(path.path),
            of: StandardizedPath.absolute(root.path)
        )
    }

    // MARK: - Worktree Merge Primitives

    func getMergeBase(sourceHead: String, targetHead: String, at repoURL: URL) async throws -> String {
        let (stdout, stderr, exitCode) = try await runGit(
            ["merge-base", targetHead, sourceHead],
            at: repoURL
        )
        guard exitCode == 0 else {
            throw GitError(message: "git merge-base failed: \(stderr)")
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func isAncestor(_ ancestor: String, of descendant: String, at repoURL: URL) async throws -> Bool {
        let (_, stderr, exitCode) = try await runGit(
            ["merge-base", "--is-ancestor", ancestor, descendant],
            at: repoURL
        )
        if exitCode == 0 { return true }
        if exitCode == 1 { return false }
        throw GitError(message: "git merge-base --is-ancestor failed: \(stderr)")
    }

    func inspectMergeState(at repoURL: URL) async throws -> GitWorktreeMergeState {
        let layout = try requireLayout(for: repoURL)
        let mergeHeadURL = layout.gitDir.appendingPathComponent("MERGE_HEAD")
        let mergeHead: String? = if FileManager.default.fileExists(atPath: mergeHeadURL.path) {
            try String(contentsOf: mergeHeadURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            nil
        }
        let conflicts = try await getUnmergedConflictFiles(at: repoURL)
        return GitWorktreeMergeState(
            inProgress: mergeHead?.isEmpty == false,
            mergeHead: mergeHead?.isEmpty == false ? mergeHead : nil,
            conflictFiles: conflicts
        )
    }

    func predictWorktreeMergeConflicts(
        sourceHead: String,
        targetHead: String,
        at repoURL: URL
    ) async throws -> GitWorktreeMergeConflictPrediction {
        let (stdout, stderr, exitCode) = try await runGit(
            ["merge-tree", "--write-tree", "--name-only", "--no-messages", targetHead, sourceHead],
            at: repoURL
        )

        if exitCode == 0 {
            return GitWorktreeMergeConflictPrediction(status: .clean)
        }
        if exitCode == 1 {
            return GitWorktreeMergeConflictPrediction(
                status: .conflicts,
                files: parseMergeTreeConflictFiles(stdout),
                message: stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "git merge-tree predicted conflicts" : nil
            )
        }

        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "git merge-tree conflict prediction unavailable"
            : stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return GitWorktreeMergeConflictPrediction(status: .unavailable, message: message)
    }

    func getWorktreeMergeSummary(
        sourceHead: String,
        targetHead: String,
        mergeBase: String,
        at repoURL: URL,
        detectRenames: Bool = false
    ) async throws -> GitWorktreeMergeSummary {
        let sourceOnlyRevspec = "\(targetHead)..\(sourceHead)"
        let previewDiffRevspec = "\(mergeBase)..\(sourceHead)"
        let (commitCountOut, commitCountErr, commitCountExit) = try await runGit(
            ["rev-list", "--count", sourceOnlyRevspec],
            at: repoURL
        )
        guard commitCountExit == 0 else {
            throw GitError(message: "git rev-list --count failed: \(commitCountErr)")
        }
        let commits = Int(commitCountOut.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let files = try await getChangedFilesStats(
            compare: .revspec(previewDiffRevspec),
            includeUntrackedWhenApplicable: false,
            detectRenames: detectRenames,
            at: repoURL
        )
        return GitWorktreeMergeSummary(
            commits: commits,
            files: files.count,
            insertions: files.reduce(0) { $0 + ($1.additions ?? 0) },
            deletions: files.reduce(0) { $0 + ($1.deletions ?? 0) }
        )
    }

    func makeWorktreeMergeVisualization(
        source: GitWorktreeMergeEndpoint,
        target: GitWorktreeMergeEndpoint,
        summary: GitWorktreeMergeSummary,
        graphLimit: Int,
        at repoURL: URL
    ) async -> String {
        let header = """
        target \(target.branch ?? target.displayName)      \(target.shortHead)  \(target.path)
           \\
            +-- merge preview: \(summary.commits) commits, \(summary.files) files (+\(summary.insertions) -\(summary.deletions))
           /
        source \(source.branch ?? source.displayName)      \(source.shortHead)  \(source.path)
        """
        let limit = max(0, min(graphLimit, 80))
        guard limit > 0 else { return header }
        let graphRange = "\(target.head)..\(source.head)"
        do {
            let (stdout, _, exitCode) = try await runGit(
                ["log", "--graph", "--decorate", "--oneline", "--color=never", "-n", "\(limit)", graphRange],
                at: repoURL
            )
            let graph = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard exitCode == 0, !graph.isEmpty else { return header }
            return header + "\n\n" + graph
        } catch {
            return header
        }
    }

    func inspectWorktreeMerge(_ request: GitWorktreeMergeInspectRequest) async throws -> GitWorktreeMergeInspection {
        let sourceURL = request.source.url
        let targetURL = request.target.url
        try await validateCurrentEndpoint(request.source, label: "Source")
        try await validateCurrentEndpoint(request.target, label: "Target")
        let mergeBase = try await getMergeBase(
            sourceHead: request.source.head,
            targetHead: request.target.head,
            at: targetURL
        )
        async let sourceStatus = getWorkingStatus(at: sourceURL)
        async let targetStatus = getWorkingStatus(at: targetURL)
        async let sourceMergeState = inspectMergeState(at: sourceURL)
        async let targetMergeState = inspectMergeState(at: targetURL)
        async let sourceFingerprint = getStatusFingerprint(at: sourceURL, baseRef: "HEAD")
        async let targetFingerprint = getStatusFingerprint(at: targetURL, baseRef: "HEAD")
        async let conflictPrediction = predictWorktreeMergeConflicts(
            sourceHead: request.source.head,
            targetHead: request.target.head,
            at: targetURL
        )
        async let summary = getWorktreeMergeSummary(
            sourceHead: request.source.head,
            targetHead: request.target.head,
            mergeBase: mergeBase,
            at: targetURL
        )
        async let sourceAlreadyMerged = isAncestor(request.source.head, of: request.target.head, at: targetURL)

        var blockers: [GitWorktreeMergeBlocker] = []
        if request.source.repositoryID != request.target.repositoryID {
            blockers.append(.init(code: .differentRepository, message: "Source and target worktrees are from different repositories."))
        }
        if request.source.worktreeID == request.target.worktreeID {
            blockers.append(.init(code: .sameWorktree, message: "Source and target worktrees are the same worktree."))
        }

        let resolvedSourceStatus = try await sourceStatus
        let resolvedTargetStatus = try await targetStatus
        let resolvedSourceMergeState = try await sourceMergeState
        let resolvedTargetMergeState = try await targetMergeState
        if !resolvedSourceStatus.isClean {
            blockers.append(.init(
                code: .sourceDirty,
                message: "Source worktree must be clean and committed before merge.",
                paths: resolvedSourceStatus.changedPaths
            ))
        }
        if !resolvedTargetStatus.isClean {
            blockers.append(.init(
                code: .targetDirty,
                message: "Target worktree must be clean before merge.",
                paths: resolvedTargetStatus.changedPaths
            ))
        }
        if resolvedSourceMergeState.inProgress {
            blockers.append(.init(code: .sourceMergeInProgress, message: "Source worktree already has a merge in progress."))
        }
        if resolvedTargetMergeState.inProgress {
            blockers.append(.init(code: .targetMergeInProgress, message: "Target worktree already has a merge in progress."))
        }
        if try await sourceAlreadyMerged {
            blockers.append(.init(code: .noSourceCommits, message: "Source HEAD is already reachable from the target HEAD."))
        }

        let resolvedSummary = try await summary
        let visualization = await makeWorktreeMergeVisualization(
            source: request.source,
            target: request.target,
            summary: resolvedSummary,
            graphLimit: request.graphLimit,
            at: targetURL
        )

        return try await GitWorktreeMergeInspection(
            source: request.source,
            target: request.target,
            mergeBase: mergeBase,
            sourceHead: request.source.head,
            targetHead: request.target.head,
            sourceFingerprint: sourceFingerprint,
            targetFingerprint: targetFingerprint,
            blockers: blockers,
            conflictPrediction: conflictPrediction,
            summary: resolvedSummary,
            visualization: visualization
        )
    }

    func withWorktreeMergeAdvisoryLock<T: Sendable>(
        at repoURL: URL,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        let commonGitDir = try requireLayout(for: repoURL).commonDir.standardizedFileURL.path
        return try await worktreeMutationCoordinator.withLock(key: commonGitDir) {
            try await GitWorktreeMergeAdvisoryLock.withLock(commonGitDir: commonGitDir, operation: operation)
        }
    }

    func applyNoCommitWorktreeMerge(
        sourceHead: String,
        at targetRepoURL: URL
    ) async throws -> GitWorktreeMergeState {
        try await withWorktreeMergeAdvisoryLock(at: targetRepoURL) { [weak self] in
            guard let self else {
                throw GitError(message: "git service was released before merge apply")
            }
            let (_, stderr, exitCode) = try await runGit(
                ["merge", "--no-ff", "--no-commit", "--no-edit", sourceHead],
                at: targetRepoURL
            )
            if exitCode == 0 || exitCode == 1 {
                return try await inspectMergeState(at: targetRepoURL)
            }
            throw GitError(message: "git merge --no-commit failed: \(stderr)")
        }
    }

    func applyAndCommitWorktreeMerge(
        sourceHead: String,
        message: String,
        at targetRepoURL: URL
    ) async throws -> (state: GitWorktreeMergeState, commit: String?) {
        try await withWorktreeMergeAdvisoryLock(at: targetRepoURL) { [weak self] in
            guard let self else {
                throw GitError(message: "git service was released before merge apply")
            }
            let (_, stderr, exitCode) = try await runGit(
                ["merge", "--no-ff", "--no-commit", "--no-edit", sourceHead],
                at: targetRepoURL
            )
            if exitCode == 0 || exitCode == 1 {
                let state = try await inspectMergeState(at: targetRepoURL)
                guard state.conflictFiles.isEmpty else { return (state: state, commit: nil) }
                guard state.inProgress else { return (state: state, commit: nil) }
                let commit = try await commitCurrentMergeWithoutLock(message: message, at: targetRepoURL)
                return (state: state, commit: commit)
            }
            throw GitError(message: "git merge --no-commit failed: \(stderr)")
        }
    }

    func commitWorktreeMerge(message: String, at targetRepoURL: URL) async throws -> String {
        try await withWorktreeMergeAdvisoryLock(at: targetRepoURL) { [weak self] in
            guard let self else {
                throw GitError(message: "git service was released before merge commit")
            }
            return try await commitCurrentMergeWithoutLock(message: message, at: targetRepoURL)
        }
    }

    func continueWorktreeMerge(message: String, at targetRepoURL: URL) async throws -> String {
        try await withWorktreeMergeAdvisoryLock(at: targetRepoURL) { [weak self] in
            guard let self else {
                throw GitError(message: "git service was released before merge continue")
            }
            return try await commitCurrentMergeWithoutLock(message: message, at: targetRepoURL)
        }
    }

    func abortWorktreeMerge(at targetRepoURL: URL) async throws -> Bool {
        try await withWorktreeMergeAdvisoryLock(at: targetRepoURL) { [weak self] in
            guard let self else {
                throw GitError(message: "git service was released before merge abort")
            }
            let state = try await inspectMergeState(at: targetRepoURL)
            guard state.inProgress else { return false }
            let (_, stderr, exitCode) = try await runGit(["merge", "--abort"], at: targetRepoURL)
            guard exitCode == 0 else {
                throw GitError(message: "git merge --abort failed: \(stderr)")
            }
            return true
        }
    }

    private func commitCurrentMergeWithoutLock(message: String, at targetRepoURL: URL) async throws -> String {
        let state = try await inspectMergeState(at: targetRepoURL)
        guard state.inProgress else {
            throw GitError(message: "No Git merge is in progress at \(targetRepoURL.path)")
        }
        guard state.conflictFiles.isEmpty else {
            throw GitError(message: "Cannot commit merge with unresolved conflicts: \(state.conflictFiles.joined(separator: ", "))")
        }
        let (_, stderr, exitCode) = try await runGit(
            ["commit", "--no-gpg-sign", "-m", message],
            at: targetRepoURL
        )
        guard exitCode == 0 else {
            throw GitError(message: "git commit failed: \(stderr)")
        }
        return try await getHeadSHA(at: targetRepoURL)
    }

    private func requireLayout(for repoURL: URL) throws -> GitRepositoryLayout {
        guard let layout = getLayout(for: repoURL) else {
            throw GitError(message: "Not a Git worktree: \(repoURL.path)")
        }
        return layout
    }

    private func validateCurrentEndpoint(_ endpoint: GitWorktreeMergeEndpoint, label: String) async throws {
        let worktrees = try await listWorktrees(at: endpoint.url)
        let standardizedPath = endpoint.url.standardizedFileURL.path
        guard let current = worktrees.first(where: { $0.path == standardizedPath }) else {
            throw GitError(message: "\(label) worktree is unavailable: \(endpoint.path)")
        }
        guard current.worktreeID == endpoint.worktreeID else {
            throw GitError(message: "\(label) worktree identity changed since it was resolved: \(endpoint.path)")
        }
        guard current.repository.repositoryID == endpoint.repositoryID else {
            throw GitError(message: "\(label) repository identity changed since it was resolved: \(endpoint.path)")
        }
        guard current.head == endpoint.head else {
            throw GitError(message: "\(label) worktree HEAD changed since it was resolved: \(endpoint.path)")
        }
    }

    private func getUnmergedConflictFiles(at repoURL: URL) async throws -> [String] {
        let (stdout, stderr, exitCode) = try await runGit(
            ["diff", "--name-only", "--diff-filter=U", "-z"],
            at: repoURL
        )
        guard exitCode == 0 || exitCode == 1 else {
            throw GitError(message: "git diff --diff-filter=U failed: \(stderr)")
        }
        return stdout.split(separator: "\0", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }
            .sorted()
    }

    private func parseMergeTreeConflictFiles(_ stdout: String) -> [String] {
        stdout.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isHexObjectID($0) }
            .sorted()
    }

    private func isHexObjectID(_ text: String) -> Bool {
        guard text.count >= 40 else { return false }
        return text.allSatisfy { character in
            character.isNumber || ("a" ... "f").contains(character.lowercased())
        }
    }

    /// Get uncommitted modified files in the repository
    func getUncommittedFiles(at repoURL: URL) async throws -> [UncommittedFile] {
        let (stdout, stderr, exitCode) = try await runGit(
            ["status", "--porcelain", "--untracked-files=all"],
            at: repoURL
        )

        guard exitCode == 0 else {
            throw GitError(message: "git status failed: \(stderr)")
        }

        return parseStatusOutput(stdout)
    }

    /// Get the current HEAD SHA for the repository.
    func getHeadSHA(at repoURL: URL) async throws -> String {
        let (stdout, stderr, exitCode) = try await runGit(
            ["rev-parse", "HEAD"],
            at: repoURL
        )
        guard exitCode == 0 else {
            throw GitError(message: "git rev-parse HEAD failed: \(stderr)")
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resolve any ref (branch, tag, commit-ish) to a SHA.
    func getRefSHA(at repoURL: URL, ref: String) async throws -> String {
        let (stdout, stderr, exitCode) = try await runGit(
            ["rev-parse", ref],
            at: repoURL
        )
        guard exitCode == 0 else {
            throw GitError(message: "git rev-parse \(ref) failed: \(stderr)")
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Get git status output in porcelain format with NUL delimiters.
    func getStatusPorcelainZ(at repoURL: URL) async throws -> Data {
        let (stdout, stderr, exitCode) = try await runGit(
            ["status", "--porcelain", "-z", "--untracked-files=all"],
            at: repoURL
        )
        guard exitCode == 0 else {
            throw GitError(message: "git status --porcelain -z failed: \(stderr)")
        }
        return Data(stdout.utf8)
    }

    /// Get a status fingerprint for staleness detection.
    func getStatusFingerprint(at repoURL: URL, baseRef: String = "HEAD") async throws -> GitDiffFingerprint {
        let headSHA = try await getHeadSHA(at: repoURL)
        let baseRefSHA = if baseRef == "HEAD" {
            headSHA
        } else {
            try await getRefSHA(at: repoURL, ref: baseRef)
        }
        let statusData = try await getStatusPorcelainZ(at: repoURL)
        var fingerprintData = Data()
        fingerprintData.append(statusData)
        fingerprintData.append(0)
        fingerprintData.append(Data(baseRefSHA.utf8))
        fingerprintData.append(0)

        // Include per-path size/mtime to invalidate cache when modified file content changes.
        let paths = MCPToolWorkCountDiagnostics.measureGitParse {
            changedPathsFromPorcelainZ(statusData)
        }
        let fm = FileManager.default
        for path in Set(paths).sorted() {
            fingerprintData.append(Data(path.utf8))
            fingerprintData.append(0)
            let absPath = repoURL.appendingPathComponent(path).path
            if let attrs = try? fm.attributesOfItem(atPath: absPath) {
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
                let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
                fingerprintData.append(Data("\(size)\t\(mtime)".utf8))
            } else {
                fingerprintData.append(Data("missing".utf8))
            }
            fingerprintData.append(0)
        }
        let statusHash = MCPToolWorkCountDiagnostics.measureGitParse {
            sha256Hex(fingerprintData)
        }
        return GitDiffFingerprint(
            headSHA: headSHA,
            baseRef: baseRef,
            statusHash: statusHash,
            generatedAt: Date()
        )
    }

    private func changedPathsFromPorcelainZ(_ data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return []
        }

        let entries = text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var paths: [String] = []
        var i = 0
        while i < entries.count {
            let entry = entries[i]
            guard entry.count >= 3 else {
                i += 1
                continue
            }

            let indexStatus = entry[entry.startIndex]
            let pathStart = entry.index(entry.startIndex, offsetBy: 3)
            let path1 = String(entry[pathStart...])
            guard !path1.isEmpty else {
                i += 1
                continue
            }

            // Renames/copies include a second path after NUL; prefer destination.
            if indexStatus == "R" || indexStatus == "C" {
                if i + 1 < entries.count, !entries[i + 1].isEmpty {
                    paths.append(entries[i + 1])
                } else {
                    paths.append(path1)
                }
                i += 2
                continue
            }

            paths.append(path1)
            i += 1
        }

        return paths
    }

    /// Get diff between specified branch and working tree
    func getDiff(from branch: String, at repoURL: URL) async throws -> String {
        // Compare branch to working tree to include all uncommitted changes
        let (stdout, stderr, exitCode) = try await runGit(
            ["diff", branch],
            at: repoURL
        )

        guard exitCode == 0 || exitCode == 1 else {
            throw GitError(message: "git diff failed: \(stderr)")
        }

        return stdout
    }

    /// Get diff between specified branch and working tree for specific files
    func getDiff(from branch: String, for files: [String], at repoURL: URL) async throws -> String {
        // Prefer normal argv for smaller file sets (compatibility),
        // use pathspec-from-file when args are large, and chunk as a fallback.
        let maxChunk = 3000
        let pathspecByteLimit = 128 * 1024
        let pathspecBytes = files.reduce(0) { $0 + $1.lengthOfBytes(using: .utf8) + 1 }

        if !files.isEmpty, pathspecBytes >= pathspecByteLimit {
            do {
                let stdin = makePathspecStdinData(files)
                let args = ["diff", "--pathspec-from-file=-", "--pathspec-file-nul", branch]
                let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL, stdin: stdin)
                guard exitCode == 0 || exitCode == 1 else {
                    throw GitError(message: "git diff failed: \(stderr)")
                }
                return stdout
            } catch {
                if !shouldFallbackFromPathspecError(error) {
                    throw error
                }
            }
        }

        if files.count <= maxChunk {
            var args = ["diff", branch, "--"]
            args.append(contentsOf: files)
            let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
            guard exitCode == 0 || exitCode == 1 else {
                throw GitError(message: "git diff failed: \(stderr)")
            }
            return stdout
        }

        var combined = ""
        for chunk in files.chunked(into: maxChunk) {
            var args = ["diff", branch, "--"]
            args.append(contentsOf: chunk)
            let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
            guard exitCode == 0 || exitCode == 1 else {
                throw GitError(message: "git diff failed: \(stderr)")
            }
            if !stdout.isEmpty {
                combined += stdout
                if !combined.hasSuffix("\n") { combined += "\n" }
            }
        }
        return combined
    }

    /// Split a unified diff output into per-file diff strings.
    static func splitUnifiedDiffByFile(_ diff: String) -> [String: String] {
        guard !diff.isEmpty else { return [:] }
        let endsWithNewline = diff.hasSuffix("\n")
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [String: String] = [:]
        var currentBlock: [String] = []

        for line in lines {
            if line.hasPrefix("diff --git ") {
                finalizeUnifiedDiffBlock(currentBlock, endsWithNewline: endsWithNewline, into: &result)
                currentBlock = [line]
                continue
            }
            guard !currentBlock.isEmpty else { continue }
            currentBlock.append(line)
        }

        finalizeUnifiedDiffBlock(currentBlock, endsWithNewline: endsWithNewline, into: &result)
        return result
    }

    private static func finalizeUnifiedDiffBlock(
        _ block: [String],
        endsWithNewline: Bool,
        into result: inout [String: String]
    ) {
        guard !block.isEmpty, let path = canonicalPath(forUnifiedDiffBlock: block) else { return }
        var text = block.joined(separator: "\n")
        if endsWithNewline, !text.hasSuffix("\n") {
            text += "\n"
        }
        result[path] = text
    }

    private static func canonicalPath(forUnifiedDiffBlock block: [String]) -> String? {
        var headerPaths: (oldPath: String, newPath: String)?
        var renameToPath: String?
        var copyToPath: String?
        var plusPath: String?
        var minusPath: String?

        for line in block {
            if line.hasPrefix("diff --git ") {
                headerPaths = parseDiffGitHeaderPaths(line)
                continue
            }
            if line.hasPrefix("rename to ") {
                renameToPath = parseGitPathRemainder(String(line.dropFirst("rename to ".count)))
                continue
            }
            if line.hasPrefix("copy to ") {
                copyToPath = parseGitPathRemainder(String(line.dropFirst("copy to ".count)))
                continue
            }
            if line.hasPrefix("+++ ") {
                plusPath = parseGitPathRemainder(String(line.dropFirst("+++ ".count))).flatMap(normalizePatchHeaderPath(_:))
                continue
            }
            if line.hasPrefix("--- ") {
                minusPath = parseGitPathRemainder(String(line.dropFirst("--- ".count))).flatMap(normalizePatchHeaderPath(_:))
                continue
            }
            if line.hasPrefix("@@") {
                break
            }
        }

        return renameToPath ?? copyToPath ?? plusPath ?? minusPath ?? headerPaths?.newPath ?? headerPaths?.oldPath
    }

    private static func parseDiffGitHeaderPaths(_ line: String) -> (oldPath: String, newPath: String)? {
        let prefix = "diff --git "
        guard line.hasPrefix(prefix) else { return nil }
        let remainder = String(line.dropFirst(prefix.count))
        let tokens = parseDiffGitTokens(remainder)
        guard tokens.count >= 2,
              let oldPath = normalizePatchHeaderPath(tokens[0]),
              let newPath = normalizePatchHeaderPath(tokens[1])
        else {
            return nil
        }
        return (oldPath, newPath)
    }

    private static func parseGitPathRemainder(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.first == "\"" {
            return parseDiffGitTokens(trimmed).first
        }
        return trimmed
    }

    private static func normalizePatchHeaderPath(_ rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/dev/null" else { return nil }
        if trimmed.hasPrefix("a/") || trimmed.hasPrefix("b/") {
            return String(trimmed.dropFirst(2))
        }
        return trimmed
    }

    private static func parseDiffGitTokens(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var isQuoted = false
        var idx = input.startIndex

        while idx < input.endIndex {
            let ch = input[idx]
            if isQuoted {
                if ch == "\\" {
                    let next = input.index(after: idx)
                    if next >= input.endIndex { break }
                    let escaped = input[next]
                    if let octal = parseOctalEscape(escaped, input: input, start: next) {
                        current.append(octal.character)
                        idx = octal.nextIndex
                        continue
                    }
                    current.append(unescapeGitDiffCharacter(escaped))
                    idx = input.index(after: next)
                    continue
                }
                if ch == "\"" {
                    isQuoted = false
                    idx = input.index(after: idx)
                    continue
                }
                current.append(ch)
                idx = input.index(after: idx)
                continue
            }

            if ch == "\"" {
                isQuoted = true
                idx = input.index(after: idx)
                continue
            }
            if ch == " " {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                idx = input.index(after: idx)
                continue
            }
            current.append(ch)
            idx = input.index(after: idx)
        }

        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func unescapeGitDiffCharacter(_ ch: Character) -> Character {
        switch ch {
        case "n": "\n"
        case "t": "\t"
        case "r": "\r"
        case "\"": "\""
        case "\\": "\\"
        default: ch
        }
    }

    private static func parseOctalEscape(
        _ first: Character,
        input: String,
        start: String.Index
    ) -> (character: Character, nextIndex: String.Index)? {
        guard ("0" ... "7").contains(first) else { return nil }
        var digits = String(first)
        var nextIndex = input.index(after: start)
        while digits.count < 3, nextIndex < input.endIndex {
            let ch = input[nextIndex]
            guard ("0" ... "7").contains(ch) else { break }
            digits.append(ch)
            nextIndex = input.index(after: nextIndex)
        }
        guard let scalar = UInt8(digits, radix: 8) else { return nil }
        let scalarValue = UnicodeScalar(scalar)
        return (Character(scalarValue), nextIndex)
    }

    /// Get untracked-file patches in one no-index Git process.
    func getUntrackedDiff(for files: [String], contextLines: Int, at repoURL: URL) async throws -> String {
        guard !files.isEmpty else { return "" }

        let fileManager = FileManager.default
        let batchRoot = fileManager.temporaryDirectory
            .appendingPathComponent("RepoPrompt-GitUntrackedDiff-\(UUID().uuidString)", isDirectory: true)
        let emptyRoot = batchRoot.appendingPathComponent("empty", isDirectory: true)
        let mirrorRoot = batchRoot.appendingPathComponent("mirror", isDirectory: true)
        try fileManager.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: mirrorRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: batchRoot) }

        let standardizedRepo = repoURL.standardizedFileURL.path
        let repoPrefix = standardizedRepo.hasSuffix("/") ? standardizedRepo : standardizedRepo + "/"
        for file in files {
            let source = repoURL.appendingPathComponent(file).standardizedFileURL
            guard source.path.hasPrefix(repoPrefix) else {
                throw GitError(message: "untracked diff path escapes repository: \(file)")
            }
            let destination = mirrorRoot.appendingPathComponent(file)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: source, to: destination)
        }

        let args = [
            "diff", "--no-index", "--unified=\(contextLines)",
            "--no-ext-diff", "--no-textconv", "--color=never", "--", "../empty", "."
        ]
        let (stdout, stderr, exitCode) = try await runGit(
            args,
            at: mirrorRoot,
            requiresRepoContext: false,
            budgetRepoURL: repoURL
        )
        guard exitCode == 0 || exitCode == 1 else {
            throw GitError(message: "git diff --no-index failed: \(stderr)")
        }
        return Self.normalizeBatchedUntrackedDiffPaths(stdout)
    }

    nonisolated static func normalizeBatchedUntrackedDiffPaths(_ output: String) -> String {
        output.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let text = String(line)
            guard text.hasPrefix("diff --git ")
                || text.hasPrefix("--- ")
                || text.hasPrefix("+++ ")
                || text.hasPrefix("Binary files ")
            else { return text }
            return text
                .replacingOccurrences(of: "a/./", with: "a/")
                .replacingOccurrences(of: "b/./", with: "b/")
                .replacingOccurrences(of: "\"a/./", with: "\"a/")
                .replacingOccurrences(of: "\"b/./", with: "\"b/")
        }.joined(separator: "\n")
    }

    /// Get diff for specific files (all uncommitted changes - staged and unstaged)
    func getDiff(for files: [String]? = nil, at repoURL: URL) async throws -> String {
        var combined = ""
        if let files, !files.isEmpty {
            let maxChunk = 3000
            if files.count <= maxChunk {
                var args = ["diff", "--unified=3", "HEAD", "--"]
                args.append(contentsOf: files)
                let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
                guard exitCode == 0 || exitCode == 1 else {
                    throw GitError(message: "git diff failed: \(stderr)")
                }
                return stdout
            }
            for chunk in files.chunked(into: maxChunk) {
                var args = ["diff", "--unified=3", "HEAD", "--"]
                args.append(contentsOf: chunk)
                let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
                guard exitCode == 0 || exitCode == 1 else {
                    throw GitError(message: "git diff failed: \(stderr)")
                }
                if !stdout.isEmpty {
                    combined += stdout
                    if !combined.hasSuffix("\n") { combined += "\n" }
                }
            }
            return combined
        } else {
            let args = ["diff", "--unified=3", "HEAD"]
            let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
            guard exitCode == 0 || exitCode == 1 else {
                throw GitError(message: "git diff failed: \(stderr)")
            }
            return stdout
        }
    }

    private func runDiff(
        argsPrefix: [String],
        contextLines: Int?,
        detectRenames: Bool,
        refArg: String?,
        paths: [String]?,
        at repoURL: URL
    ) async throws -> String {
        let maxChunk = 3000
        let pathspecByteLimit = 128 * 1024
        let cleanedPaths = (paths ?? []).filter { !$0.isEmpty }
        let pathspecBytes = cleanedPaths.reduce(0) { $0 + $1.lengthOfBytes(using: .utf8) + 1 }
        let usePathspec = !cleanedPaths.isEmpty && pathspecBytes >= pathspecByteLimit

        func baseArgs() -> [String] {
            var args = argsPrefix
            if let contextLines {
                args.append("--unified=\(contextLines)")
            }
            if detectRenames {
                args.append("-M")
            }
            args.append("--no-ext-diff")
            args.append("--color=never")
            return args
        }

        if usePathspec {
            do {
                var args = baseArgs()
                args.append(contentsOf: ["--pathspec-from-file=-", "--pathspec-file-nul"])
                if let refArg, !refArg.isEmpty {
                    args.append(refArg)
                }
                let stdin = makePathspecStdinData(cleanedPaths)
                let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL, stdin: stdin)
                guard exitCode == 0 || exitCode == 1 else {
                    throw GitError(message: "git diff failed: \(stderr)")
                }
                return stdout
            } catch {
                if !shouldFallbackFromPathspecError(error) {
                    throw error
                }
            }
        }

        guard !cleanedPaths.isEmpty else {
            var args = baseArgs()
            if let refArg, !refArg.isEmpty {
                args.append(refArg)
            }
            let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
            guard exitCode == 0 || exitCode == 1 else {
                throw GitError(message: "git diff failed: \(stderr)")
            }
            return stdout
        }

        if cleanedPaths.count <= maxChunk {
            var args = baseArgs()
            if let refArg, !refArg.isEmpty {
                args.append(refArg)
            }
            args.append("--")
            args.append(contentsOf: cleanedPaths)
            let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
            guard exitCode == 0 || exitCode == 1 else {
                throw GitError(message: "git diff failed: \(stderr)")
            }
            return stdout
        }

        var combined = ""
        for chunk in cleanedPaths.chunked(into: maxChunk) {
            var args = baseArgs()
            if let refArg, !refArg.isEmpty {
                args.append(refArg)
            }
            args.append("--")
            args.append(contentsOf: chunk)
            let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
            guard exitCode == 0 || exitCode == 1 else {
                throw GitError(message: "git diff failed: \(stderr)")
            }
            if !stdout.isEmpty {
                combined += stdout
                if !combined.hasSuffix("\n") { combined += "\n" }
            }
        }
        return combined
    }

    func getDiffUncommitted(
        base: String,
        paths: [String]?,
        contextLines: Int,
        detectRenames: Bool,
        at repoURL: URL
    ) async throws -> String {
        try await runDiff(
            argsPrefix: ["diff"],
            contextLines: contextLines,
            detectRenames: detectRenames,
            refArg: base,
            paths: paths,
            at: repoURL
        )
    }

    func getDiffUncommittedMergeBase(
        base: String,
        paths: [String]?,
        contextLines: Int,
        detectRenames: Bool,
        at repoURL: URL
    ) async throws -> String {
        try await runDiff(
            argsPrefix: ["diff", "--merge-base"],
            contextLines: contextLines,
            detectRenames: detectRenames,
            refArg: base,
            paths: paths,
            at: repoURL
        )
    }

    func getDiffStaged(
        base: String,
        paths: [String]?,
        contextLines: Int,
        detectRenames: Bool,
        at repoURL: URL
    ) async throws -> String {
        try await runDiff(
            argsPrefix: ["diff", "--cached"],
            contextLines: contextLines,
            detectRenames: detectRenames,
            refArg: base,
            paths: paths,
            at: repoURL
        )
    }

    func getDiffStagedMergeBase(
        base: String,
        paths: [String]?,
        contextLines: Int,
        detectRenames: Bool,
        at repoURL: URL
    ) async throws -> String {
        try await runDiff(
            argsPrefix: ["diff", "--cached", "--merge-base"],
            contextLines: contextLines,
            detectRenames: detectRenames,
            refArg: base,
            paths: paths,
            at: repoURL
        )
    }

    func getDiffUnstaged(
        paths: [String]?,
        contextLines: Int,
        detectRenames: Bool,
        at repoURL: URL
    ) async throws -> String {
        try await runDiff(
            argsPrefix: ["diff"],
            contextLines: contextLines,
            detectRenames: detectRenames,
            refArg: nil,
            paths: paths,
            at: repoURL
        )
    }

    func getDiffRevspec(
        _ revspec: String,
        paths: [String]?,
        contextLines: Int,
        detectRenames: Bool,
        at repoURL: URL
    ) async throws -> String {
        try await runDiff(
            argsPrefix: ["diff"],
            contextLines: contextLines,
            detectRenames: detectRenames,
            refArg: revspec,
            paths: paths,
            at: repoURL
        )
    }

    /// Get diff for specific files with error handling per file
    /// Returns tuple of (combinedDiff, failedFiles)
    func getDiffWithFailures(for files: [String], at repoURL: URL) async -> (String, [String]) {
        var combinedDiff = ""
        var failedFiles: [String] = []

        // Try to get diff for all files at once first
        do {
            let diff = try await getDiff(for: files, at: repoURL)
            return (diff, [])
        } catch {
            // If batch diff fails, try each file individually
            for file in files {
                do {
                    let fileDiff = try await getDiff(for: [file], at: repoURL)
                    if !fileDiff.isEmpty {
                        combinedDiff += fileDiff
                        if !combinedDiff.hasSuffix("\n") {
                            combinedDiff += "\n"
                        }
                    }
                } catch {
                    failedFiles.append(file)
                }
            }
        }

        return (combinedDiff, failedFiles)
    }

    /// Get list of local branches with last commit dates
    func getLocalBranches(at repoURL: URL, limit: Int? = nil) async throws -> [Branch] {
        var arguments = [
            "for-each-ref",
            "--sort=-committerdate",
            "--format=%(refname:short)%09%(committerdate:iso8601)%09%(HEAD)"
        ]
        if let limit {
            arguments.append("--count=\(max(0, limit))")
        }
        arguments.append("refs/heads")

        let (stdout, stderr, exitCode) = try await runGit(
            arguments,
            at: repoURL
        )

        guard exitCode == 0 else {
            throw GitError(message: "git for-each-ref failed: \(stderr)")
        }

        return parseBranchOutputWithDates(stdout)
    }

    func gitBranchSwitchOptions(at repoURL: URL) async throws -> GitBranchSwitchOptions {
        let branches = try await getLocalBranches(at: repoURL)
        let currentBranch = try await currentBranchOrNil(at: repoURL)
        let currentHead = try await getHeadSHA(at: repoURL)
        let worktreeOccupancy = try await branchWorktreeOccupancyByBranchName(excludingCurrentCheckoutAt: repoURL)
        return GitBranchSwitchOptions(
            rootPath: repoURL.standardizedFileURL.path,
            repoRootPath: repoURL.standardizedFileURL.path,
            currentBranch: currentBranch,
            currentHead: currentHead,
            isDetached: currentBranch == nil,
            branches: branches.map { branch in
                VCSBranch(
                    name: branch.name,
                    isCurrent: branch.name == currentBranch || branch.isCurrent,
                    lastCommitDate: branch.lastCommitDate,
                    checkedOutWorktree: worktreeOccupancy[branch.name]
                )
            }
        )
    }

    func preflightGitBranchSwitch(branchName: String, at repoURL: URL) async throws -> GitBranchSwitchPreflight {
        try Self.validateLocalBranchName(branchName)
        try await requireLocalBranch(branchName, at: repoURL)
        try await requireBranchNotCheckedOutInAnotherWorktree(branchName, at: repoURL)
        let currentBranch = try await currentBranchOrNil(at: repoURL)
        let currentHead = try await getHeadSHA(at: repoURL)
        async let dirtyFilesTask = getUncommittedFiles(at: repoURL)
        async let mergeStateTask = inspectMergeState(at: repoURL)
        let dirtyFiles = try await dirtyFilesTask
        let mergeState = try await mergeStateTask
        var warnings: [GitBranchSwitchPreflightWarning] = []
        if currentBranch == nil {
            warnings.append(.detachedHead)
        }
        if !dirtyFiles.isEmpty {
            warnings.append(.uncommittedChanges)
        }
        if mergeState.inProgress {
            warnings.append(.mergeInProgress)
        }
        return GitBranchSwitchPreflight(
            rootPath: repoURL.standardizedFileURL.path,
            repoRootPath: repoURL.standardizedFileURL.path,
            targetBranch: branchName,
            currentBranch: currentBranch,
            currentHead: currentHead,
            isCurrentBranch: currentBranch == branchName,
            warnings: warnings
        )
    }

    func switchGitBranch(_ request: GitBranchSwitchRequest, at repoURL: URL) async throws -> GitBranchSwitchResult {
        let mutationKey = getLayout(for: repoURL)?.commonDir.standardizedFileURL.path
            ?? repoURL.standardizedFileURL.path

        return try await worktreeMutationCoordinator.withLock(key: mutationKey) { [weak self] in
            guard let self else {
                throw GitBranchSwitchError.unavailable("git service was released before branch switching")
            }
            try Self.validateLocalBranchName(request.branchName)
            try await requireLocalBranch(request.branchName, at: repoURL)

            let previousBranch = try await currentBranchOrNil(at: repoURL)
            let previousHead = try await getHeadSHA(at: repoURL)
            try Self.validateExpectedCheckout(
                expectedBranch: request.expectedCurrentBranch,
                expectedHead: request.expectedCurrentHead,
                actualBranch: previousBranch,
                actualHead: previousHead
            )
            if previousBranch == request.branchName {
                return GitBranchSwitchResult(
                    rootPath: repoURL.standardizedFileURL.path,
                    repoRootPath: repoURL.standardizedFileURL.path,
                    previousBranch: previousBranch,
                    previousHead: previousHead,
                    newBranch: request.branchName,
                    newHead: previousHead,
                    didSwitch: false
                )
            }

            try await requireBranchNotCheckedOutInAnotherWorktree(request.branchName, at: repoURL)

            let switchResult = try await runGit(["switch", "--no-guess", request.branchName], at: repoURL)
            if switchResult.2 != 0 {
                if Self.shouldFallbackFromGitSwitchError(switchResult.1) {
                    let checkoutResult = try await runGit(["checkout", request.branchName], at: repoURL)
                    guard checkoutResult.2 == 0 else {
                        throw GitBranchSwitchError.gitRefused("git checkout failed: \(checkoutResult.1)")
                    }
                } else {
                    throw GitBranchSwitchError.gitRefused("git switch failed: \(switchResult.1)")
                }
            }

            let newBranch = try await currentBranchOrNil(at: repoURL)
            let newHead = try await getHeadSHA(at: repoURL)
            guard newBranch == request.branchName else {
                throw GitBranchSwitchError.gitRefused("Git reported success, but the checkout is now on \(newBranch ?? "detached HEAD") instead of \(request.branchName).")
            }
            return GitBranchSwitchResult(
                rootPath: repoURL.standardizedFileURL.path,
                repoRootPath: repoURL.standardizedFileURL.path,
                previousBranch: previousBranch,
                previousHead: previousHead,
                newBranch: request.branchName,
                newHead: newHead,
                didSwitch: true
            )
        }
    }

    private func currentBranchOrNil(at repoURL: URL) async throws -> String? {
        let branch = try await getCurrentBranch(at: repoURL).trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty || branch == "HEAD" ? nil : branch
    }

    private static func validateLocalBranchName(_ branchName: String) throws {
        let trimmed = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == branchName,
              !branchName.isEmpty,
              !branchName.hasPrefix("-"),
              !branchName.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
        else {
            throw GitBranchSwitchError.invalidBranchName(branchName)
        }
    }

    private func requireLocalBranch(_ branchName: String, at repoURL: URL) async throws {
        let (_, _, exitCode) = try await runGit(
            ["show-ref", "--verify", "--quiet", "refs/heads/\(branchName)"],
            at: repoURL
        )
        guard exitCode == 0 else {
            throw GitBranchSwitchError.branchNotLocal(branchName)
        }
    }

    private func branchWorktreeOccupancyByBranchName(
        excludingCurrentCheckoutAt repoURL: URL
    ) async throws -> [String: VCSBranchWorktreeOccupancy] {
        let worktrees = try await listWorktrees(at: repoURL)
        var result: [String: VCSBranchWorktreeOccupancy] = [:]

        for descriptor in worktrees {
            guard let branch = descriptor.branch?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !branch.isEmpty,
                  !descriptor.isDetached,
                  !descriptor.isCurrent
            else { continue }

            result[branch] = VCSBranchWorktreeOccupancy(
                worktreePath: descriptor.path,
                worktreeName: descriptor.name,
                worktreeID: descriptor.worktreeID
            )
        }

        return result
    }

    private func requireBranchNotCheckedOutInAnotherWorktree(_ branchName: String, at repoURL: URL) async throws {
        let worktreeOccupancy = try await branchWorktreeOccupancyByBranchName(excludingCurrentCheckoutAt: repoURL)
        guard let occupied = worktreeOccupancy[branchName] else { return }
        throw GitBranchSwitchError.branchCheckedOutInWorktree(
            branch: branchName,
            worktreePath: occupied.worktreePath,
            worktreeName: occupied.worktreeName
        )
    }

    private static func validateExpectedCheckout(
        expectedBranch: String?,
        expectedHead: String?,
        actualBranch: String?,
        actualHead: String
    ) throws {
        if let expectedBranch, expectedBranch != actualBranch {
            throw GitBranchSwitchError.staleCheckout(
                expectedBranch: expectedBranch,
                actualBranch: actualBranch,
                expectedHead: expectedHead,
                actualHead: actualHead
            )
        }
        if let expectedHead, expectedHead != actualHead {
            throw GitBranchSwitchError.staleCheckout(
                expectedBranch: expectedBranch,
                actualBranch: actualBranch,
                expectedHead: expectedHead,
                actualHead: actualHead
            )
        }
    }

    private static func shouldFallbackFromGitSwitchError(_ stderr: String) -> Bool {
        let lowercased = stderr.lowercased()
        return lowercased.contains("'switch' is not a git command")
            || lowercased.contains("unknown command 'switch'")
            || lowercased.contains("unknown subcommand: switch")
    }

    /// Get list of remote branches with last commit dates, sorted by most recent
    /// Filters out symbolic HEAD refs (e.g., origin/HEAD)
    func getRemoteBranches(at repoURL: URL, limit: Int = 10) async throws -> [Branch] {
        let (stdout, stderr, exitCode) = try await runGit(
            ["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)%09%(committerdate:iso8601)", "refs/remotes", "--count=\(limit + 5)"],
            at: repoURL
        )

        guard exitCode == 0 else {
            throw GitError(message: "git for-each-ref failed: \(stderr)")
        }

        // Parse and filter out HEAD symbolic refs (e.g., origin/HEAD)
        // Reuse parseBranchOutputWithDates since it handles 2-field format (name + date)
        let branches = parseBranchOutputWithDates(stdout)
            .filter { !$0.name.hasSuffix("/HEAD") }

        // Return only up to limit after filtering
        return Array(branches.prefix(limit))
    }

    /// Fetch updates from all remotes
    /// Updates local tracking refs (e.g., origin/main) to match remote state
    func fetch(at repoURL: URL) async throws {
        let (_, stderr, exitCode) = try await runGit(
            ["fetch", "--all", "--prune"],
            at: repoURL
        )

        guard exitCode == 0 else {
            throw GitError(message: "git fetch failed: \(stderr)")
        }
    }

    /// Check if a given ref name exists under refs/remotes.
    func hasRemoteTrackingRef(named refName: String, at repoURL: URL) async -> Bool {
        let ref = "refs/remotes/\(refName)"
        do {
            let (_, _, exitCode) = try await runGit(
                ["show-ref", "--verify", "--quiet", ref],
                at: repoURL
            )
            return exitCode == 0
        } catch {
            return false
        }
    }

    /// Get recent tags sorted by commit date
    func getTags(at repoURL: URL, limit: Int = 10) async throws -> [Tag] {
        // Get tags with their commit dates using for-each-ref
        let (stdout, stderr, exitCode) = try await runGit(
            ["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)%09%(committerdate:iso8601)", "refs/tags", "--count=\(limit)"],
            at: repoURL
        )

        guard exitCode == 0 else {
            throw GitError(message: "git for-each-ref failed: \(stderr)")
        }

        return parseTagOutputWithDates(stdout)
    }

    /// Get current branch name
    func getCurrentBranch(at repoURL: URL) async throws -> String {
        // Try the symbolic-ref command first (more reliable)
        let (stdout, stderr, exitCode) = try await runGit(
            ["symbolic-ref", "--short", "HEAD"],
            at: repoURL
        )

        if exitCode == 0 {
            return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Fallback to branch --show-current
        let (stdout2, stderr2, exitCode2) = try await runGit(
            ["branch", "--show-current"],
            at: repoURL
        )

        if exitCode2 == 0 {
            return stdout2.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Final fallback to rev-parse
        let (stdout3, stderr3, exitCode3) = try await runGit(
            ["rev-parse", "--abbrev-ref", "HEAD"],
            at: repoURL
        )

        guard exitCode3 == 0 else {
            throw GitError(message: "All git branch commands failed. symbolic-ref: \(stderr), branch: \(stderr2), rev-parse: \(stderr3)")
        }

        return stdout3.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Get list of changed files with per-file additions / deletions statistics
    /// Get changed files with statistics, including untracked files
    /// - Parameters:
    ///   - base: Comparison baseline (`.head` or `.branch("main")`)
    ///   - repoURL: URL of the repository root
    /// - Returns: Array of `UncommittedFile` including tracked changes and untracked files
    func getChangedFilesStats(
        relativeTo base: CompareBase,
        at repoURL: URL
    ) async throws -> [UncommittedFile] {
        // Build argument lists ---------------------------------------------------
        let reference: [String] = switch base {
        case .head: ["HEAD"]
        case let .branch(ref): [ref]
        }

        let numstatArgs = ["diff"] + reference + ["--numstat"]
        let nameStatusArgs = ["diff"] + reference + ["--name-status"]

        // Run all commands in parallel -----------------------------------------
        async let numstatResult = runGit(numstatArgs, at: repoURL)
        async let nameStatResult = runGit(nameStatusArgs, at: repoURL)
        async let untrackedResult = runGit(["ls-files", "--others", "--exclude-standard"], at: repoURL)

        let (numOut, numErr, numExit) = try await numstatResult
        guard numExit == 0 || numExit == 1 else {
            throw GitError(message: "git diff --numstat failed: \(numErr)")
        }

        let (nameOut, nameErr, nameExit) = try await nameStatResult
        guard nameExit == 0 || nameExit == 1 else {
            throw GitError(message: "git diff --name-status failed: \(nameErr)")
        }

        let (untrackedOut, _, untrackedExit) = try await untrackedResult
        guard untrackedExit == 0 else {
            throw GitError(message: "git ls-files failed")
        }

        // Parse outputs ----------------------------------------------------------
        let (statsMap, statusMap) = MCPToolWorkCountDiagnostics.measureGitParse {
            (parseNumstatOutput(numOut), parseNameStatusOutput(nameOut))
        }

        // Merge into unified results --------------------------------------------
        var results: [UncommittedFile] = []
        let allPaths = Set(statsMap.keys).union(statusMap.keys)

        for path in allPaths {
            let status = statusMap[path] ?? "M"
            let tuple = statsMap[path]
            let additions = tuple?.0
            let deletions = tuple?.1
            results.append(
                UncommittedFile(
                    path: path,
                    status: status,
                    additions: additions,
                    deletions: deletions
                )
            )
        }

        // Add untracked files ----------------------------------------------------
        let untrackedFiles = untrackedOut
            .split(separator: "\n")
            .map { String($0) }
            .filter { !$0.isEmpty }

        for path in untrackedFiles {
            // Only add if not already in the results (avoid duplicates)
            if !allPaths.contains(path) {
                let stats = untrackedLineStats(for: path, repoURL: repoURL)
                results.append(
                    UncommittedFile(
                        path: path,
                        status: "??",
                        additions: stats.additions,
                        deletions: stats.deletions
                    )
                )
            }
        }

        // Stable, human-friendly order
        let keyed = results.map { file in
            (lower: file.path.lowercased(), original: file.path, file: file)
        }
        return keyed.sorted { lhs, rhs in
            if lhs.lower != rhs.lower {
                return lhs.lower < rhs.lower
            }
            return lhs.original < rhs.original
        }.map(\.file)
    }

    private enum DiffStatKind {
        case numstat
        case nameStatus
    }

    private func diffArgs(
        for compare: GitDiffCompareSpec,
        kind: DiffStatKind
    ) -> (argsPrefix: [String], refArg: String?) {
        var argsPrefix = ["diff"]
        switch compare {
        case .staged:
            argsPrefix.append("--cached")
        case .stagedMergeBase:
            argsPrefix.append("--cached")
            argsPrefix.append("--merge-base")
        case .uncommittedMergeBase:
            argsPrefix.append("--merge-base")
        default:
            break
        }
        switch kind {
        case .numstat:
            argsPrefix.append("--numstat")
        case .nameStatus:
            argsPrefix.append("--name-status")
        }

        let refArg: String? = switch compare {
        case let .uncommitted(base):
            base
        case let .uncommittedMergeBase(base):
            base
        case let .staged(base):
            base
        case let .stagedMergeBase(base):
            base
        case .unstaged:
            nil
        case let .revspec(revspec):
            revspec
        }
        return (argsPrefix, refArg)
    }

    func getDiffNumstat(
        compare: GitDiffCompareSpec,
        detectRenames: Bool = false,
        at repoURL: URL
    ) async throws -> String {
        let (argsPrefix, refArg) = diffArgs(for: compare, kind: .numstat)
        return try await runDiff(
            argsPrefix: argsPrefix,
            contextLines: nil,
            detectRenames: detectRenames,
            refArg: refArg,
            paths: nil,
            at: repoURL
        )
    }

    func getDiffNameStatus(
        compare: GitDiffCompareSpec,
        detectRenames: Bool = false,
        at repoURL: URL
    ) async throws -> String {
        let (argsPrefix, refArg) = diffArgs(for: compare, kind: .nameStatus)
        return try await runDiff(
            argsPrefix: argsPrefix,
            contextLines: nil,
            detectRenames: detectRenames,
            refArg: refArg,
            paths: nil,
            at: repoURL
        )
    }

    func getChangedFilesStats(
        compare: GitDiffCompareSpec,
        includeUntrackedWhenApplicable: Bool,
        detectRenames: Bool = false,
        at repoURL: URL
    ) async throws -> [UncommittedFile] {
        let includeUntracked = includeUntrackedWhenApplicable && {
            switch compare {
            case .uncommitted, .uncommittedMergeBase, .unstaged:
                true
            case .staged, .stagedMergeBase, .revspec:
                false
            }
        }()

        async let numOutTask = getDiffNumstat(compare: compare, detectRenames: detectRenames, at: repoURL)
        async let nameOutTask = getDiffNameStatus(compare: compare, detectRenames: detectRenames, at: repoURL)
        async let untrackedFilesTask = includeUntracked ? getUntrackedPaths(at: repoURL) : []
        let (numOut, nameOut, untrackedFiles) = try await (numOutTask, nameOutTask, untrackedFilesTask)
        let (statsMap, statusMap) = MCPToolWorkCountDiagnostics.measureGitParse {
            (parseNumstatOutput(numOut), parseNameStatusOutput(nameOut))
        }

        var results: [UncommittedFile] = []
        let allPaths = Set(statsMap.keys).union(statusMap.keys)

        for path in allPaths {
            let status = statusMap[path] ?? "M"
            let tuple = statsMap[path]
            let additions = tuple?.0
            let deletions = tuple?.1
            results.append(
                UncommittedFile(
                    path: path,
                    status: status,
                    additions: additions,
                    deletions: deletions
                )
            )
        }

        if includeUntracked {
            for path in untrackedFiles {
                if !allPaths.contains(path) {
                    let stats = untrackedLineStats(for: path, repoURL: repoURL)
                    results.append(
                        UncommittedFile(
                            path: path,
                            status: "??",
                            additions: stats.additions,
                            deletions: stats.deletions
                        )
                    )
                }
            }
        }

        let keyed = results.map { file in
            (lower: file.path.lowercased(), original: file.path, file: file)
        }
        return keyed.sorted { lhs, rhs in
            if lhs.lower != rhs.lower {
                return lhs.lower < rhs.lower
            }
            return lhs.original < rhs.original
        }.map(\.file)
    }

    private func getUntrackedPaths(at repoURL: URL) async throws -> [String] {
        let (stdout, stderr, exitCode) = try await runGit(
            ["ls-files", "--others", "--exclude-standard"],
            at: repoURL
        )
        guard exitCode == 0 else {
            throw GitError(message: "git ls-files failed: \(stderr)")
        }
        return stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    func getCommitGraph(maxLines: Int, at repoURL: URL) async throws -> String {
        let args = ["log", "--graph", "--decorate", "--oneline", "--color=never", "-n", "\(maxLines)"]
        let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
        guard exitCode == 0 else {
            throw GitError(message: "git log failed: \(stderr)")
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Return how many commits the current HEAD is ahead/behind the given branch.
    /// Positive `ahead` means local commits not in *branch*,
    /// positive `behind` means commits present in *branch* but not in HEAD.
    func getAheadBehind(
        vs branch: String,
        at repoURL: URL
    ) async throws -> (ahead: Int, behind: Int) {
        let args = ["rev-list", "--left-right", "--count", "\(branch)...HEAD"]
        let (stdout, stderr, exit) = try await runGit(args, at: repoURL)
        guard exit == 0 else {
            throw GitError(message: "git rev-list failed: \(stderr)")
        }
        let parts = stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t")
            .map(String.init)
        guard parts.count == 2,
              let behind = Int(parts[0]),
              let ahead = Int(parts[1])
        else {
            throw GitError(message: "Unexpected rev-list output: \(stdout)")
        }
        return (ahead: ahead, behind: behind)
    }

    // MARK: - Unified Git Tool Support

    /// Get the upstream tracking branch for the current branch.
    /// Returns nil if no upstream is set.
    func getUpstreamRef(at repoURL: URL) async throws -> String? {
        let args = ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]
        let (stdout, _, exitCode) = try await runGit(args, at: repoURL)
        guard exitCode == 0 else {
            return nil // No upstream configured
        }
        let result = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// Structured working directory status.
    struct WorkingStatus: Equatable {
        let staged: [String]
        let modified: [String]
        let untracked: [String]
    }

    struct RepositoryStatus: Equatable {
        let branch: String?
        let headID: String?
        let upstream: String?
        let ahead: Int?
        let behind: Int?
        let workingStatus: WorkingStatus
    }

    /// Read branch metadata and working-tree state from one porcelain-v2 snapshot.
    func getRepositoryStatus(at repoURL: URL) async throws -> RepositoryStatus {
        let args = ["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"]
        let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
        guard exitCode == 0 else {
            throw GitError(message: "git status --porcelain=v2 failed: \(stderr)")
        }
        let parsed = try MCPToolWorkCountDiagnostics.measureGitParse {
            try GitStatusPorcelainV2Parser.parse(stdout)
        }
        return RepositoryStatus(
            branch: parsed.branch,
            headID: parsed.headID,
            upstream: parsed.upstream,
            ahead: parsed.ahead,
            behind: parsed.behind,
            workingStatus: WorkingStatus(
                staged: parsed.staged,
                modified: parsed.modified,
                untracked: parsed.untracked
            )
        )
    }

    /// Compatibility wrapper for callers that only need working-tree paths.
    func getWorkingStatus(at repoURL: URL) async throws -> WorkingStatus {
        try await getRepositoryStatus(at: repoURL).workingStatus
    }

    /// Summary of a commit for log output.
    struct CommitSummary {
        let sha: String
        let shortSHA: String
        let author: String
        let dateISO: String
        let message: String
        let filesChanged: Int
        let insertions: Int
        let deletions: Int
    }

    /// Get commit log summaries with stats.
    func getLogSummaries(
        count: Int,
        path: String? = nil,
        at repoURL: URL
    ) async throws -> [CommitSummary] {
        // Use a custom format with a separator to parse commits
        // Format: __C__<sha>\t<short>\t<author>\t<date>\t<subject>
        // Followed by --numstat lines
        var args = [
            "log",
            "-n", "\(count)",
            "--date=iso-strict",
            "--pretty=format:__C__%H%x09%h%x09%an%x09%ad%x09%s",
            "--numstat",
            "--no-ext-diff",
            "--no-textconv",
            "--color=never"
        ]
        if let path, !path.isEmpty {
            args.append("--")
            args.append(path)
        }

        let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
        guard exitCode == 0 else {
            throw GitError(message: "git log failed: \(stderr)")
        }

        return parseLogSummaries(stdout)
    }

    private func parseLogSummaries(_ output: String) -> [CommitSummary] {
        var results: [CommitSummary] = []
        let blocks = output.components(separatedBy: "__C__").filter { !$0.isEmpty }

        for block in blocks {
            let lines = block.components(separatedBy: "\n")
            guard let headerLine = lines.first else { continue }

            let headerParts = headerLine.split(separator: "\t", maxSplits: 4).map(String.init)
            guard headerParts.count >= 5 else { continue }

            let sha = headerParts[0]
            let shortSHA = headerParts[1]
            let author = headerParts[2]
            let dateISO = headerParts[3]
            let message = headerParts[4]

            // Parse numstat lines for this commit
            var filesChanged = 0
            var insertions = 0
            var deletions = 0

            for i in 1 ..< lines.count {
                let line = lines[i].trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
                let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
                guard parts.count >= 2 else { continue }

                filesChanged += 1
                if let adds = Int(parts[0]) {
                    insertions += adds
                }
                if let dels = Int(parts[1]) {
                    deletions += dels
                }
            }

            results.append(CommitSummary(
                sha: sha,
                shortSHA: shortSHA,
                author: author,
                dateISO: dateISO,
                message: message,
                filesChanged: filesChanged,
                insertions: insertions,
                deletions: deletions
            ))
        }

        return results
    }

    /// Detailed commit info for `show` operation.
    struct CommitInfo {
        let sha: String
        let shortSHA: String
        let author: String
        let dateISO: String
        let message: String
    }

    /// Get commit info (metadata only, no diff).
    func commitInfo(ref: String, at repoURL: URL) async throws -> CommitInfo {
        let args = [
            "show",
            "-s",
            "--date=iso-strict",
            "--format=%H%x09%h%x09%an%x09%ad%x09%B",
            "--no-ext-diff",
            "--no-textconv",
            "--color=never",
            ref
        ]
        let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
        guard exitCode == 0 else {
            throw GitError(message: "git show failed: \(stderr)")
        }

        let parts = stdout.split(separator: "\t", maxSplits: 4).map(String.init)
        guard parts.count >= 5 else {
            throw GitError(message: "Unexpected git show output format")
        }

        return CommitInfo(
            sha: parts[0],
            shortSHA: parts[1],
            author: parts[2],
            dateISO: parts[3],
            message: parts[4].trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// A single line of blame output.
    struct BlameLine {
        let line: Int
        let sha: String
        let author: String
        let dateISO: String
        let content: String
    }

    /// Get blame for a file, optionally for a specific line range.
    func blame(
        path: String,
        lineRange: ClosedRange<Int>? = nil,
        at repoURL: URL
    ) async throws -> [BlameLine] {
        var args = [
            "blame",
            "--line-porcelain"
        ]
        if let range = lineRange {
            args.append("-L")
            args.append("\(range.lowerBound),\(range.upperBound)")
        }
        args.append("--")
        args.append(path)

        let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
        guard exitCode == 0 else {
            throw GitError(message: "git blame failed: \(stderr)")
        }

        return parseBlameOutput(stdout)
    }

    private func parseBlameOutput(_ output: String) -> [BlameLine] {
        var results: [BlameLine] = []
        let lines = output.components(separatedBy: "\n")

        var currentSHA: String?
        var currentAuthor: String?
        var currentAuthorTime: String?
        var currentLineNum: Int?
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // First line of a block: <sha> <origLine> <finalLine> [<numLines>]
            if line.count >= 40, !line.hasPrefix("\t") {
                let parts = line.split(separator: " ", maxSplits: 3).map(String.init)
                if parts.count >= 3, parts[0].count == 40 {
                    currentSHA = parts[0]
                    currentLineNum = Int(parts[2])
                }
            } else if line.hasPrefix("author ") {
                currentAuthor = String(line.dropFirst("author ".count))
            } else if line.hasPrefix("author-time ") {
                // Unix timestamp
                if let timestamp = Int(line.dropFirst("author-time ".count)) {
                    let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime]
                    currentAuthorTime = formatter.string(from: date)
                }
            } else if line.hasPrefix("\t") {
                // Content line
                let content = String(line.dropFirst())
                if let sha = currentSHA,
                   let author = currentAuthor,
                   let time = currentAuthorTime,
                   let lineNum = currentLineNum
                {
                    results.append(BlameLine(
                        line: lineNum,
                        sha: String(sha.prefix(7)),
                        author: author,
                        dateISO: time,
                        content: content
                    ))
                }
            }

            i += 1
        }

        return results
    }

    // MARK: - Private Implementation

    // Use AsyncStream to collect pipe output without locks/queues per chunk

    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func mergedProcessEnvironment(
        baseEnvironment: [String: String],
        shellEnvironment: [String: String]
    ) -> [String: String] {
        var environment = baseEnvironment
        environment.merge(shellEnvironment) { _, new in new }
        return environment
    }

    nonisolated static func friendlyErrorDescription(for rawMessage: String) -> String {
        let lowercased = rawMessage.lowercased()
        guard lowercased.contains("git-lfs"), lowercased.contains("command not found") else {
            return rawMessage
        }

        let action = if lowercased.hasPrefix("git diff") {
            "Git diff"
        } else if lowercased.hasPrefix("git fetch") {
            "Git fetch"
        } else if lowercased.hasPrefix("git status") {
            "Git status"
        } else {
            "Git"
        }

        return "\(action) couldn’t launch git-lfs from RepoPrompt’s subprocess environment. If git-lfs is installed, restart RepoPrompt and make sure it’s available from your login shell PATH.\n\nRaw error: \(rawMessage)"
    }

    private func processEnvironment() async -> [String: String] {
        if let preparedBaseProcessEnvironment {
            return preparedBaseProcessEnvironment
        }
        let shellEnvironment = await CLIEnvironmentCache.shared.environment(enableLogging: false)
        let environment = Self.mergedProcessEnvironment(
            baseEnvironment: inheritedProcessEnvironment,
            shellEnvironment: shellEnvironment
        )
        preparedBaseProcessEnvironment = environment
        return environment
    }

    nonisolated static func isVerifiedReadOnlyGitOperation(_ args: [String]) -> Bool {
        guard let command = args.first else { return false }
        switch command {
        case "rev-parse", "status", "ls-files", "diff", "merge-base", "merge-tree",
             "show-ref", "for-each-ref", "log", "rev-list", "show", "blame", "cat-file":
            return true
        case "worktree":
            return args.dropFirst().first == "list"
        case "symbolic-ref":
            return args.contains("--short") && args.last == "HEAD"
        case "branch":
            return args == ["branch", "--show-current"]
        case "config":
            return args.contains("--get")
        default:
            if command == "--git-dir", let configIndex = args.firstIndex(of: "config") {
                return args[configIndex...].contains("--get")
            }
            return false
        }
    }

    private func runGit(
        _ args: [String],
        at repoURL: URL,
        env: [String: String] = [:],
        stdin: Data? = nil,
        requiresRepoContext: Bool = true,
        budgetRepoURL: URL? = nil
    ) async throws -> (String, String, Int32) {
        var environment = await processEnvironment()
        environment["GIT_TERMINAL_PROMPT"] = "0"
        if Self.isVerifiedReadOnlyGitOperation(args) {
            environment["GIT_OPTIONAL_LOCKS"] = "0"
        }

        // For gitfile worktrees, inject GIT_DIR and GIT_WORK_TREE to ensure
        // git commands operate in the correct context.
        // Skip for commands that don't need repo context (e.g., --no-index diffs).
        if requiresRepoContext, let layout = getLayout(for: repoURL), layout.isWorktree {
            environment["GIT_DIR"] = layout.gitDir.path
            environment["GIT_WORK_TREE"] = layout.workTreeRoot.path
        }
        environment.merge(env) { _, new in new }

        let budgetURL = budgetRepoURL ?? repoURL
        let repositoryKey = getLayout(for: budgetURL)?.commonDir.standardizedFileURL.path
            ?? budgetURL.standardizedFileURL.path
        let lease = try await GitProcessAdmissionController.shared.acquire(repositoryKey: repositoryKey)
        do {
            try Task.checkCancellation()
            let result = try await runAdmittedGit(
                args,
                at: repoURL,
                environment: environment,
                stdin: stdin,
                diagnosticRepositoryPath: budgetURL.standardizedFileURL.path,
                processQueueWaitMicroseconds: lease.queueWaitMicroseconds
            )
            await GitProcessAdmissionController.shared.release(lease)
            return result
        } catch {
            await GitProcessAdmissionController.shared.release(lease)
            throw error
        }
    }

    private func runAdmittedGit(
        _ args: [String],
        at repoURL: URL,
        environment: [String: String],
        stdin: Data?,
        diagnosticRepositoryPath: String,
        processQueueWaitMicroseconds: Int
    ) async throws -> (String, String, Int32) {
        let process = Process()
        let timeoutController = GitProcessTimeoutController()
        let commandRecorder = MCPToolWorkCountDiagnostics.gitCommandRecorder()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = repoURL
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        var inPipe: Pipe?
        if let _ = stdin {
            let p = Pipe()
            process.standardInput = p
            inPipe = p
            // Suppress SIGPIPE on this write FD so closed readers won’t crash the app
            let fd = p.fileHandleForWriting.fileDescriptor
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        }

        // Build async streams for stdout/stderr and single consumer tasks to collect data.
        // GitProcessPipeDrain serializes readability callbacks with termination/cancellation
        // so a final chunk cannot be read by a callback and then dropped after stream closure.
        let (outStream, outDrain) = try GitProcessPipeDrain.makeStream(
            readingFrom: outPipe.fileHandleForReading
        )
        let (errStream, errDrain) = try GitProcessPipeDrain.makeStream(
            readingFrom: errPipe.fileHandleForReading
        )

        let processMetrics = GitProcessMetricsBox()
        let outCollector = Task(priority: .userInitiated) { () -> Data in
            var buf = Data()
            for await chunk in outStream {
                if !chunk.isEmpty { buf.append(chunk) }
            }
            return buf
        }
        let errCollector = Task(priority: .userInitiated) { () -> Data in
            var buf = Data()
            for await chunk in errStream {
                if !chunk.isEmpty { buf.append(chunk) }
            }
            return buf
        }

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                // Drain stdout
                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    if outDrain.consumeAvailableData() {
                        handle.readabilityHandler = nil
                    }
                }
                // Drain stderr
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    if errDrain.consumeAvailableData() {
                        handle.readabilityHandler = nil
                    }
                }

                process.terminationHandler = { proc in
                    timeoutController.cancel()

                    // Stop handlers to break strong reference cycles
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil

                    // Drain bytes that arrived between the last readability callback and
                    // process termination, then close each stream after any in-flight callback.
                    outDrain.finishReading()
                    errDrain.finishReading()

                    Task {
                        let stdoutData = await outCollector.value
                        let stderrData = await errCollector.value

                        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                        commandRecorder(
                            diagnosticRepositoryPath,
                            args,
                            processQueueWaitMicroseconds,
                            processMetrics.spawnMicroseconds,
                            stdoutData.count + stderrData.count
                        )

                        continuation.resume(returning: (stdout, stderr, proc.terminationStatus))
                    }
                }

                do {
                    let spawnStart = DispatchTime.now().uptimeNanoseconds
                    try process.run()
                    let processIdentifier = process.processIdentifier
                    timeoutController.schedule(
                        process: process,
                        processIdentifier: processIdentifier,
                        timeout: Self.gitProcessTimeout,
                        terminationGrace: Self.gitProcessTerminationGrace
                    )
                    let spawnEnd = DispatchTime.now().uptimeNanoseconds
                    processMetrics.spawnMicroseconds = Int(
                        clamping: spawnEnd >= spawnStart ? (spawnEnd - spawnStart) / 1000 : 0
                    )

                    // If stdin data was provided, write it after the process starts.
                    // Use raw FD writes via FDWriteSupport instead of FileHandle.write()
                    // because FileHandle.write() throws ObjC NSFileHandleOperationException
                    // on broken pipe, which Swift do/catch cannot intercept.
                    // If the write fails (e.g. child exited early or task was cancelled),
                    // we still let the process terminate normally so stderr and exit code
                    // are collected — this preserves fallback logic in runDiff.
                    if let stdin {
                        if let inPipe {
                            let fd = inPipe.fileHandleForWriting.fileDescriptor
                            do {
                                try FDWriteSupport.writeAll(stdin, to: fd)
                            } catch {
                                // Broken pipe / bad fd — child exited early or was terminated.
                                // Swallow the error; the process termination handler will
                                // still collect stdout, stderr, and exit code normally.
                                // This preserves runDiff's pathspec fallback behavior.
                            }
                            inPipe.fileHandleForWriting.closeFile()
                        }
                    }
                } catch {
                    commandRecorder(
                        diagnosticRepositoryPath,
                        args,
                        processQueueWaitMicroseconds,
                        processMetrics.spawnMicroseconds,
                        0
                    )
                    // Ensure handlers and collectors are released when launch fails.
                    timeoutController.cancel()
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    outDrain.cancel()
                    errDrain.cancel()
                    continuation.resume(throwing: error)
                }
            }
        }, onCancel: {
            timeoutController.cancel()
            // Stop callbacks and terminate before waiting on a drain lock. A callback may be
            // blocked in FileHandle.availableData until the child closes its pipe.
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
            }
            outDrain.cancel()
            errDrain.cancel()
        })
    }

    static func shouldFallbackFromWorktreeListZError(_ stderr: String) -> Bool {
        let lowercased = stderr.lowercased()
        return lowercased.contains("unknown option")
            || lowercased.contains("unknown switch")
            || lowercased.contains("invalid option")
            || lowercased.contains("usage: git worktree")
    }

    private func resolveMainWorktreeRoot(
        for layout: GitRepositoryLayout,
        at repoURL: URL
    ) async -> URL? {
        if let knownRoot = layout.knownMainWorktreeRoot {
            return knownRoot
        }

        let queries: [(arguments: [String], directory: URL, requiresRepoContext: Bool)] = [
            (["config", "--path", "--get", "core.worktree"], repoURL, true),
            (["--git-dir", layout.commonDir.path, "config", "--worktree", "--path", "--get", "core.worktree"], layout.commonDir, false)
        ]
        for query in queries {
            guard let result = try? await runGit(
                query.arguments,
                at: query.directory,
                requiresRepoContext: query.requiresRepoContext
            ), result.2 == 0
            else {
                continue
            }
            let rawPath = result.0.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawPath.isEmpty else { continue }

            let candidate = if rawPath.hasPrefix("/") {
                URL(fileURLWithPath: rawPath).standardizedFileURL
            } else {
                layout.commonDir.appendingPathComponent(rawPath).standardizedFileURL
            }
            guard let candidateLayout = getLayout(for: candidate),
                  !candidateLayout.isLinkedWorktree,
                  candidateLayout.commonDir.standardizedFileURL.path == layout.commonDir.standardizedFileURL.path
            else {
                continue
            }
            return candidate
        }
        return nil
    }

    private func normalizedWorktreeRecords(
        _ records: [GitWorktreePorcelainRecord],
        currentLayout: GitRepositoryLayout?,
        resolvedMainRoot: URL?
    ) -> [GitWorktreePorcelainRecord] {
        guard let currentLayout else { return records }
        let commonGitDirPath = currentLayout.commonDir.standardizedFileURL.path

        return records.compactMap { record in
            let recordPath = URL(fileURLWithPath: record.path).standardizedFileURL.path
            guard recordPath == commonGitDirPath else {
                return record
            }
            guard let resolvedMainRoot else {
                return nil
            }
            var normalized = record
            normalized.path = resolvedMainRoot.standardizedFileURL.path
            return normalized
        }
    }

    private func makeWorktreeDescriptors(
        from records: [GitWorktreePorcelainRecord],
        currentRepoURL: URL
    ) async throws -> [GitWorktreeDescriptor] {
        let currentLayout = getLayout(for: currentRepoURL)
        let resolvedMainRoot: URL? = if let currentLayout {
            await resolveMainWorktreeRoot(for: currentLayout, at: currentRepoURL)
        } else {
            nil
        }
        let worktreeRecords = normalizedWorktreeRecords(
            records.filter { !$0.isBare },
            currentLayout: currentLayout,
            resolvedMainRoot: resolvedMainRoot
        )
        guard !worktreeRecords.isEmpty else { return [] }

        let layoutsByPath: [String: GitRepositoryLayout] = Dictionary(
            uniqueKeysWithValues: worktreeRecords.compactMap { record -> (String, GitRepositoryLayout)? in
                let pathURL = URL(fileURLWithPath: record.path)
                guard let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: pathURL) else {
                    return nil
                }
                return (pathURL.standardizedFileURL.path, layout)
            }
        )

        let commonGitDir = currentLayout?.commonDir
            ?? layoutsByPath.values.first?.commonDir
        guard let commonGitDir else {
            throw GitError(message: "git worktree list succeeded but repository layout could not be resolved")
        }

        let discoveredMainRoot = worktreeRecords.first { record in
            let path = URL(fileURLWithPath: record.path).standardizedFileURL.path
            return layoutsByPath[path].map { !$0.isLinkedWorktree } ?? false
        }.map { URL(fileURLWithPath: $0.path).standardizedFileURL }
        let mainURL = resolvedMainRoot ?? discoveredMainRoot
        let repository = GitWorktreeIdentity.repositoryIdentity(
            commonGitDir: commonGitDir,
            mainWorktreeRoot: mainURL
        )
        let currentPath = currentRepoURL.standardizedFileURL.path

        return worktreeRecords.map { record in
            let pathURL = URL(fileURLWithPath: record.path).standardizedFileURL
            let path = pathURL.path
            let layout = layoutsByPath[path]
            let gitDir = layout?.gitDir.standardizedFileURL
            let isMain: Bool = if let layout {
                !layout.isLinkedWorktree
            } else {
                mainURL?.path == path && !record.isBare
            }
            let worktreeID = GitWorktreeIdentity.worktreeID(
                repositoryID: repository.repositoryID,
                gitDir: gitDir,
                isMain: isMain,
                path: pathURL
            )

            return GitWorktreeDescriptor(
                worktreeID: worktreeID,
                repository: repository,
                path: path,
                gitDir: gitDir?.path,
                name: pathURL.lastPathComponent.isEmpty ? nil : pathURL.lastPathComponent,
                branch: record.branch,
                head: record.head,
                isMain: isMain,
                isCurrent: path == currentPath,
                isDetached: record.isDetached,
                isLocked: record.isLocked,
                lockReason: record.lockReason,
                isPrunable: record.isPrunable,
                prunableReason: record.prunableReason
            )
        }
    }

    private func parseStatusOutput(_ output: String) -> [UncommittedFile] {
        output
            .split(separator: "\n")
            .compactMap { raw in
                let line = String(raw)

                guard line.count >= 3 else { return nil }

                let statusCode = String(line.prefix(2))
                let status = statusCode.trimmingCharacters(in: .whitespaces)

                let pathStart = line.index(line.startIndex, offsetBy: 3)
                var path = String(line[pathStart...])
                // Handle rename/copy lines which look like: "R  old/path -> new/path"
                if status.hasPrefix("R") || status.hasPrefix("C"),
                   let arrowRange = path.range(of: " -> ")
                {
                    path = String(path[arrowRange.upperBound...])
                }

                guard !path.hasSuffix("/") else { return nil }

                return UncommittedFile(path: path, status: status)
            }
    }

    private func makePathspecStdinData(_ files: [String]) -> Data {
        var data = Data()
        for path in files {
            if let encoded = path.data(using: .utf8) {
                data.append(encoded)
            }
            data.append(0)
        }
        return data
    }

    private func shouldFallbackFromPathspecError(_ error: Error) -> Bool {
        guard let gitError = error as? GitError else { return false }
        let message = gitError.message.lowercased()
        return message.contains("unknown option") || message.contains("pathspec-from-file")
    }

    private func parseBranchOutput(_ output: String) -> [Branch] {
        output
            .split(separator: "\n")
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }

                let isCurrent = trimmed.hasPrefix("*")
                let name = isCurrent ?
                    String(trimmed.dropFirst(2)) :
                    String(trimmed)

                return Branch(name: name, isCurrent: isCurrent, lastCommitDate: nil)
            }
    }

    private func parseBranchOutputWithDates(_ output: String) -> [Branch] {
        output
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
                guard parts.count >= 2 else { return nil }

                let name = parts[0]
                let dateString = parts[1]
                let isCurrent = parts.count > 2 && parts[2] == "*"
                let date = parseGitDate(dateString)

                return Branch(name: name, isCurrent: isCurrent, lastCommitDate: date)
            }
    }

    private func parseTagOutputWithDates(_ output: String) -> [Tag] {
        output
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                guard !parts.isEmpty else { return nil }

                let name = parts[0]
                let date = parts.count > 1 ? parseGitDate(parts[1]) : nil

                return Tag(name: name, commitDate: date)
            }
    }

    /// Accept both Git's "yyyy-MM-dd HH:mm:ss Z" (e.g. "+0000") and RFC3339
    private static let gitDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return df
    }()

    private static let rfc3339Formatter: ISO8601DateFormatter = {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withSpaceBetweenDateAndTime]
        return df
    }()

    private func parseGitDate(_ s: String) -> Date? {
        if let d = Self.gitDateFormatter.date(from: s) { return d }
        return Self.rfc3339Formatter.date(from: s)
    }

    private func untrackedLineStats(for path: String, repoURL: URL) -> (additions: Int?, deletions: Int?) {
        let fileURL = repoURL.appendingPathComponent(path)
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return (nil, nil)
        }
        defer {
            try? handle.close()
        }

        let chunkSize = 64 * 1024
        var sawData = false
        var lineCount = 0
        var lastByte: UInt8?

        while true {
            guard let data = try? handle.read(upToCount: chunkSize),
                  !data.isEmpty
            else {
                break
            }
            sawData = true
            for byte in data {
                if byte == 0 {
                    return (nil, nil)
                }
                if byte == 0x0A {
                    lineCount += 1
                }
                lastByte = byte
            }
        }

        if sawData {
            if let lastByte, lastByte != 0x0A {
                lineCount += 1
            }
        }

        return (lineCount, 0)
    }

    /// Parses `git diff --numstat` output into a map of path → (additions, deletions)
    nonisolated func parseNumstatOutput(_ output: String) -> [String: (Int?, Int?)] {
        var map: [String: (Int?, Int?)] = [:]

        for rawLine in output.split(separator: "\n") {
            let parts = rawLine.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }

            let addStr = parts[0]
            let delStr = parts[1]
            let pathRaw = parts[2]
            let path = normalizeRenamedPath(pathRaw)

            let additions = Int(addStr) // nil when "-"
            let deletions = Int(delStr)

            map[path] = (additions, deletions)
        }
        return map
    }

    /// Convert numstat rename formats to the final/new path so they line up with name-status.
    /// Handles:
    ///  - "old/path => new/path"
    ///  - "dir/{old => new}/file.swift"
    nonisolated func normalizeRenamedPath(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)

        // Brace segment renames: "a/{old => new}/b"
        if trimmed.contains("{"), trimmed.contains("}"), trimmed.contains(" => ") {
            var out = ""
            var i = trimmed.startIndex
            var handledBraceRename = false
            while i < trimmed.endIndex {
                if trimmed[i] == "{", let end = trimmed[i...].firstIndex(of: "}") {
                    let inner = trimmed[trimmed.index(after: i) ..< end]
                    if let sep = inner.range(of: " => ") {
                        handledBraceRename = true
                        out += inner[sep.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        out.append("{")
                        out += inner
                        out.append("}")
                    }
                    i = trimmed.index(after: end)
                } else {
                    out.append(trimmed[i])
                    i = trimmed.index(after: i)
                }
            }
            if handledBraceRename {
                return out
            }
        }

        // Simple "old/path => new/path" whole-path rename
        if let arrow = trimmed.range(of: " => ") {
            return String(trimmed[arrow.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmed
    }

    /// Parses `git diff --name-status` lines into a map of path → single-letter status
    nonisolated func parseNameStatusOutput(_ output: String) -> [String: String] {
        var map: [String: String] = [:]

        for rawLine in output.split(separator: "\n") {
            let parts = rawLine
                .split(separator: "\t", omittingEmptySubsequences: false)
                .map(String.init)
            guard !parts.isEmpty else { continue }

            let statusCode = parts[0].trimmingCharacters(in: .whitespaces)

            // Handle rename/copy which provide two paths
            let path: String = if statusCode.hasPrefix("R") || statusCode.hasPrefix("C") {
                // new path is last field
                parts.last ?? ""
            } else {
                parts.count > 1 ? parts[1] : ""
            }

            if !path.isEmpty {
                map[path] = String(statusCode.prefix(1)) // e.g. "M"
            }
        }
        return map
    }
}

/// Serializes pipe readability callbacks with process termination and cancellation.
private final class GitProcessMetricsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSpawnMicroseconds = 0

    var spawnMicroseconds: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedSpawnMicroseconds
        }
        set {
            lock.lock()
            storedSpawnMicroseconds = max(0, newValue)
            lock.unlock()
        }
    }
}

///
/// `FileHandle.readabilityHandler` may already be executing when a process termination
/// handler clears it. Foundation may also invalidate its file handle before a queued callback
/// runs. The drain owns a close-on-exec duplicate descriptor so all reads and closure are
/// serialized independently of the `FileHandle` lifecycle.
final class GitProcessPipeDrain: @unchecked Sendable {
    private enum DescriptorReadResult {
        case data(Data)
        case unavailable
        case terminal
    }

    private static let readBufferSize = 64 * 1024

    private let lock = NSLock()
    private let continuation: AsyncStream<Data>.Continuation
    private var ownedDescriptor: Int32?
    private var isFinished = false

    private init(
        continuation: AsyncStream<Data>.Continuation,
        ownedDescriptor: Int32? = nil
    ) {
        self.continuation = continuation
        self.ownedDescriptor = ownedDescriptor
    }

    deinit {
        if let ownedDescriptor {
            _ = Darwin.close(ownedDescriptor)
        }
    }

    static func makeStream() -> (stream: AsyncStream<Data>, drain: GitProcessPipeDrain) {
        makeStream(ownedDescriptor: nil)
    }

    static func makeStream(
        readingFrom handle: FileHandle
    ) throws -> (stream: AsyncStream<Data>, drain: GitProcessPipeDrain) {
        let duplicateDescriptor = fcntl(handle.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicateDescriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        let statusFlags = fcntl(duplicateDescriptor, F_GETFL)
        guard statusFlags >= 0 else {
            let failureErrno = errno
            _ = Darwin.close(duplicateDescriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(failureErrno))
        }
        guard fcntl(duplicateDescriptor, F_SETFL, statusFlags | O_NONBLOCK) >= 0 else {
            let failureErrno = errno
            _ = Darwin.close(duplicateDescriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(failureErrno))
        }

        return makeStream(ownedDescriptor: duplicateDescriptor)
    }

    private static func makeStream(
        ownedDescriptor: Int32?
    ) -> (stream: AsyncStream<Data>, drain: GitProcessPipeDrain) {
        var drain: GitProcessPipeDrain?
        let stream = AsyncStream<Data>(bufferingPolicy: .unbounded) { continuation in
            drain = GitProcessPipeDrain(
                continuation: continuation,
                ownedDescriptor: ownedDescriptor
            )
        }
        return (stream, drain!)
    }

    /// Returns true when the `FileHandle` should stop monitoring readability.
    @discardableResult
    func consumeAvailableData() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished, let ownedDescriptor else { return true }

        switch Self.readChunk(from: ownedDescriptor) {
        case let .data(data):
            continuation.yield(data)
            return false
        case .unavailable:
            return false
        case .terminal:
            finishLocked()
            return true
        }
    }

    func finishReading() {
        finish { [self] in
            guard let ownedDescriptor else { return Data() }
            return Self.readToEnd(from: ownedDescriptor)
        }
    }

    func consume(read: () -> Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }

        let data = read()
        if !data.isEmpty {
            continuation.yield(data)
        }
    }

    func finish(
        readRemaining: () -> Data,
        onWillLock: (() -> Void)? = nil
    ) {
        onWillLock?()
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }

        let data = readRemaining()
        if !data.isEmpty {
            continuation.yield(data)
        }
        finishLocked()
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }

        finishLocked()
    }

    private func finishLocked() {
        isFinished = true
        if let ownedDescriptor {
            self.ownedDescriptor = nil
            _ = Darwin.close(ownedDescriptor)
        }
        continuation.finish()
    }

    private static func readToEnd(from descriptor: Int32) -> Data {
        var result = Data()
        while true {
            switch readChunk(from: descriptor) {
            case let .data(data):
                result.append(data)
            case .unavailable, .terminal:
                return result
            }
        }
    }

    private static func readChunk(from descriptor: Int32) -> DescriptorReadResult {
        var buffer = [UInt8](repeating: 0, count: readBufferSize)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                return .data(Data(buffer.prefix(Int(count))))
            }
            if count == 0 {
                return .terminal
            }
            if errno == EINTR {
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return .unavailable
            }
            return .terminal
        }
    }
}

private extension GitService.WorkingStatus {
    var isClean: Bool {
        staged.isEmpty && modified.isEmpty && untracked.isEmpty
    }

    var changedPaths: [String] {
        Array(Set(staged + modified + untracked)).sorted()
    }
}

private final class GitProcessTimeoutController: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func schedule(
        process: Process,
        processIdentifier: pid_t,
        timeout: Duration,
        terminationGrace: Duration
    ) {
        lock.lock()
        defer { lock.unlock() }
        task?.cancel()
        task = Task {
            do {
                try await Task.sleep(for: timeout)
                guard !Task.isCancelled, process.isRunning else { return }
                process.terminate()
                try await Task.sleep(for: terminationGrace)
                guard !Task.isCancelled, process.isRunning else { return }
                kill(processIdentifier, SIGKILL)
            } catch {
                return
            }
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        task?.cancel()
        task = nil
    }
}

// MARK: - Worktree Merge Advisory Lock

private enum GitWorktreeMergeAdvisoryLock {
    static func withLock<T: Sendable>(
        commonGitDir: String,
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        let fileManager = FileManager.default
        let mutexDir = URL(fileURLWithPath: commonGitDir, isDirectory: true)
            .appendingPathComponent("repoprompt-mutex", isDirectory: true)
        try fileManager.createDirectory(at: mutexDir, withIntermediateDirectories: true)
        let lockPath = mutexDir.appendingPathComponent("worktree.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw GitService.GitError(message: "Unable to open Git worktree merge lock at \(lockPath): errno \(errno)")
        }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else {
            throw GitService.GitError(message: "Unable to acquire Git worktree merge lock at \(lockPath): errno \(errno)")
        }
        defer { _ = flock(fd, LOCK_UN) }
        return try await operation()
    }
}

// MARK: - Shell Escaping Extension

private extension String {
    /// Returns a single-quoted string the shell treats as one token
    var shellEscaped: String {
        replacingOccurrences(of: "'", with: "'\\''").surrounding(with: "'")
    }

    func surrounding(with quote: String) -> String {
        quote + self + quote
    }
}

private extension Sequence<String> {
    func shellEscaped() -> [String] {
        map(\.shellEscaped)
    }
}
