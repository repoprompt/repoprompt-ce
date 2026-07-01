import Foundation

// MARK: - Git Backend

/// VCS backend implementation that wraps the existing GitService.
/// This provides a bridge from the VCS abstraction layer to the existing git infrastructure.
actor GitBackend: VCSBackend {
    // MARK: - Properties

    nonisolated let kind: VCSBackendKind = .git
    nonisolated let capabilities: VCSCapabilities = .git

    private let gitService: GitService

    // MARK: - Initialization

    init(gitService: GitService = GitService()) {
        self.gitService = gitService
    }

    // MARK: - Repository Discovery

    func findRepoRoot(from url: URL) async throws -> URL? {
        try await gitService.findGitRoot(from: url)
    }

    func isRepository(at url: URL) async -> Bool {
        await gitService.isGitRepository(at: url)
    }

    // MARK: - Reference Operations

    func getHeadID(at repoURL: URL) async throws -> String {
        try await gitService.getHeadSHA(at: repoURL)
    }

    func getRefID(ref: String, at repoURL: URL) async throws -> String {
        try await gitService.getRefSHA(at: repoURL, ref: ref)
    }

    // MARK: - Status Operations

    func getCurrentBranch(at repoURL: URL) async throws -> String? {
        let branch = try await gitService.getCurrentBranch(at: repoURL)
        return branch.isEmpty ? nil : branch
    }

    func getLocalBranches(at repoURL: URL, limit: Int) async throws -> [VCSBranch] {
        let branches = try await gitService.getLocalBranches(at: repoURL, limit: limit)
        return branches.map { branch in
            VCSBranch(
                name: branch.name,
                isCurrent: branch.isCurrent,
                lastCommitDate: branch.lastCommitDate
            )
        }
    }

    func gitBranchSwitchOptions(at repoURL: URL) async throws -> GitBranchSwitchOptions {
        try await gitService.gitBranchSwitchOptions(at: repoURL)
    }

    func preflightGitBranchSwitch(branchName: String, at repoURL: URL) async throws -> GitBranchSwitchPreflight {
        try await gitService.preflightGitBranchSwitch(branchName: branchName, at: repoURL)
    }

    func switchGitBranch(_ request: GitBranchSwitchRequest, at repoURL: URL) async throws -> GitBranchSwitchResult {
        try await gitService.switchGitBranch(request, at: repoURL)
    }

    func getRemoteBranches(at repoURL: URL, limit: Int) async throws -> [VCSBranch] {
        let branches = try await gitService.getRemoteBranches(at: repoURL, limit: limit)
        return branches.map { branch in
            VCSBranch(
                name: branch.name,
                isCurrent: branch.isCurrent,
                lastCommitDate: branch.lastCommitDate
            )
        }
    }

    func getTags(at repoURL: URL, limit: Int) async throws -> [VCSTag] {
        let tags = try await gitService.getTags(at: repoURL, limit: limit)
        return tags.map { tag in
            VCSTag(name: tag.name, commitDate: tag.commitDate)
        }
    }

    func getUpstreamRef(at repoURL: URL) async throws -> String? {
        try await gitService.getUpstreamRef(at: repoURL)
    }

    func getAheadBehind(vs ref: String, at repoURL: URL) async throws -> (ahead: Int, behind: Int)? {
        try await gitService.getAheadBehind(vs: ref, at: repoURL)
    }

    func getRepositoryStatus(at repoURL: URL) async throws -> VCSRepositoryStatus {
        let status = try await gitService.getRepositoryStatus(at: repoURL)
        return VCSRepositoryStatus(
            branch: status.branch,
            headID: status.headID,
            upstream: status.upstream,
            ahead: status.ahead,
            behind: status.behind,
            workingStatus: VCSWorkingStatus(
                staged: status.workingStatus.staged,
                modified: status.workingStatus.modified,
                untracked: status.workingStatus.untracked
            )
        )
    }

    func getWorkingStatus(at repoURL: URL) async throws -> VCSWorkingStatus {
        let status = try await gitService.getWorkingStatus(at: repoURL)
        return VCSWorkingStatus(
            staged: status.staged,
            modified: status.modified,
            untracked: status.untracked
        )
    }

    func hasRemoteTrackingRef(named refName: String, at repoURL: URL) async -> Bool {
        await gitService.hasRemoteTrackingRef(named: refName, at: repoURL)
    }

    // MARK: - Worktree Operations

    func listWorktrees(at repoURL: URL) async throws -> [GitWorktreeDescriptor] {
        try await gitService.listWorktrees(at: repoURL)
    }

    func createWorktree(
        request: GitWorktreeCreateRequest,
        at repoURL: URL
    ) async throws -> GitWorktreeDescriptor {
        try await gitService.createWorktree(request: request, at: repoURL)
    }

    func createWorktreeWithResult(
        request: GitWorktreeCreateRequest,
        at repoURL: URL,
        initializationContext: GitWorktreeInitializationContext? = nil
    ) async throws -> GitWorktreeCreateResult {
        try await gitService.createWorktreeWithResult(
            request: request,
            at: repoURL,
            initializationContext: initializationContext
        )
    }

    // MARK: - Worktree Merge Operations

    func inspectWorktreeMerge(_ request: GitWorktreeMergeInspectRequest) async throws -> GitWorktreeMergeInspection {
        try await gitService.inspectWorktreeMerge(request)
    }

    func isAncestor(_ ancestor: String, of descendant: String, at repoURL: URL) async throws -> Bool {
        try await gitService.isAncestor(ancestor, of: descendant, at: repoURL)
    }

    func inspectMergeState(at repoURL: URL) async throws -> GitWorktreeMergeState {
        try await gitService.inspectMergeState(at: repoURL)
    }

    func applyNoCommitWorktreeMerge(sourceHead: String, at targetRepoURL: URL) async throws -> GitWorktreeMergeState {
        try await gitService.applyNoCommitWorktreeMerge(sourceHead: sourceHead, at: targetRepoURL)
    }

    func applyAndCommitWorktreeMerge(
        sourceHead: String,
        message: String,
        at targetRepoURL: URL
    ) async throws -> (state: GitWorktreeMergeState, commit: String?) {
        try await gitService.applyAndCommitWorktreeMerge(sourceHead: sourceHead, message: message, at: targetRepoURL)
    }

    func commitWorktreeMerge(message: String, at targetRepoURL: URL) async throws -> String {
        try await gitService.commitWorktreeMerge(message: message, at: targetRepoURL)
    }

    func continueWorktreeMerge(message: String, at targetRepoURL: URL) async throws -> String {
        try await gitService.continueWorktreeMerge(message: message, at: targetRepoURL)
    }

    func abortWorktreeMerge(at targetRepoURL: URL) async throws -> Bool {
        try await gitService.abortWorktreeMerge(at: targetRepoURL)
    }

    // MARK: - Remote Operations

    func fetch(at repoURL: URL) async throws {
        try await gitService.fetch(at: repoURL)
    }

    // MARK: - Fingerprint Operations

    func getStatusFingerprint(at repoURL: URL, baseRef: String) async throws -> GitDiffFingerprint {
        try await gitService.getStatusFingerprint(at: repoURL, baseRef: baseRef)
    }

    // MARK: - Diff Operations

    func getChangedFilesStats(
        compare: GitDiffCompareSpec,
        includeUntrackedWhenApplicable: Bool,
        detectRenames: Bool,
        at repoURL: URL
    ) async throws -> [VCSUncommittedFile] {
        let files = try await gitService.getChangedFilesStats(
            compare: compare,
            includeUntrackedWhenApplicable: includeUntrackedWhenApplicable,
            detectRenames: detectRenames,
            at: repoURL
        )
        return files.map { file in
            VCSUncommittedFile(
                path: file.path,
                status: file.status,
                additions: file.additions,
                deletions: file.deletions
            )
        }
    }

    func getDiffText(
        compare: GitDiffCompareSpec,
        paths: [String]?,
        contextLines: Int,
        detectRenames: Bool,
        at repoURL: URL
    ) async throws -> String {
        switch compare {
        case let .uncommitted(base):
            try await gitService.getDiffUncommitted(
                base: base,
                paths: paths,
                contextLines: contextLines,
                detectRenames: detectRenames,
                at: repoURL
            )
        case let .uncommittedMergeBase(base):
            try await gitService.getDiffUncommittedMergeBase(
                base: base,
                paths: paths,
                contextLines: contextLines,
                detectRenames: detectRenames,
                at: repoURL
            )
        case let .staged(base):
            try await gitService.getDiffStaged(
                base: base,
                paths: paths,
                contextLines: contextLines,
                detectRenames: detectRenames,
                at: repoURL
            )
        case let .stagedMergeBase(base):
            try await gitService.getDiffStagedMergeBase(
                base: base,
                paths: paths,
                contextLines: contextLines,
                detectRenames: detectRenames,
                at: repoURL
            )
        case .unstaged:
            try await gitService.getDiffUnstaged(
                paths: paths,
                contextLines: contextLines,
                detectRenames: detectRenames,
                at: repoURL
            )
        case let .revspec(revspec):
            try await gitService.getDiffRevspec(
                revspec,
                paths: paths,
                contextLines: contextLines,
                detectRenames: detectRenames,
                at: repoURL
            )
        }
    }

    func getUntrackedDiff(
        for files: [String],
        contextLines: Int,
        at repoURL: URL
    ) async throws -> String {
        try await gitService.getUntrackedDiff(for: files, contextLines: contextLines, at: repoURL)
    }

    // MARK: - Log Operations

    func getCommitGraph(maxLines: Int, at repoURL: URL) async throws -> String {
        try await gitService.getCommitGraph(maxLines: maxLines, at: repoURL)
    }

    func getLogSummaries(
        count: Int,
        path: String?,
        at repoURL: URL
    ) async throws -> [VCSCommitSummary] {
        let summaries = try await gitService.getLogSummaries(count: count, path: path, at: repoURL)
        return summaries.map { summary in
            VCSCommitSummary(
                id: summary.sha,
                shortID: summary.shortSHA,
                author: summary.author,
                dateISO: summary.dateISO,
                message: summary.message,
                filesChanged: summary.filesChanged,
                insertions: summary.insertions,
                deletions: summary.deletions
            )
        }
    }

    func commitInfo(ref: String, at repoURL: URL) async throws -> VCSCommitInfo {
        let info = try await gitService.commitInfo(ref: ref, at: repoURL)
        return VCSCommitInfo(
            id: info.sha,
            shortID: info.shortSHA,
            author: info.author,
            dateISO: info.dateISO,
            message: info.message
        )
    }

    // MARK: - Blame Operations

    func blame(
        path: String,
        lineRange: ClosedRange<Int>?,
        at repoURL: URL
    ) async throws -> [VCSBlameLine] {
        let lines = try await gitService.blame(path: path, lineRange: lineRange, at: repoURL)
        return lines.map { line in
            VCSBlameLine(
                line: line.line,
                id: line.sha,
                author: line.author,
                dateISO: line.dateISO,
                content: line.content
            )
        }
    }

    // MARK: - Normalization

    nonisolated func normalizeBaseRef(_ baseRef: String) -> String {
        // Git uses refs as-is
        baseRef
    }

    nonisolated func normalizeCompareSpec(_ spec: GitDiffCompareSpec) -> GitDiffCompareSpec {
        // Git uses all compare specs as-is
        spec
    }
}

// MARK: - Git Backend with Warnings

extension GitBackend: VCSBackendWithWarnings {
    nonisolated func normalizeCompareSpecWithWarning(_ spec: GitDiffCompareSpec) -> NormalizedCompareResult {
        // Git supports all compare specs natively, no warnings needed
        NormalizedCompareResult(spec: spec, warning: nil)
    }
}
