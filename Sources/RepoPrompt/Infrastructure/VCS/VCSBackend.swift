import Foundation

// MARK: - VCS Backend Protocol

/// Protocol defining the interface for version control system backends.
/// Implementations include GitBackend and JujutsuBackend.
public protocol VCSBackend: Sendable {
    /// The kind of VCS this backend represents.
    var kind: VCSBackendKind { get }

    /// The capabilities of this backend.
    var capabilities: VCSCapabilities { get }

    // MARK: - Repository Discovery

    /// Find the repository root starting from the given path.
    /// - Parameter url: The starting path to search from.
    /// - Returns: The repository root URL, or nil if not in a repository.
    func findRepoRoot(from url: URL) async throws -> URL?

    /// Check if the given path is within a repository.
    /// - Parameter url: The path to check.
    /// - Returns: True if the path is in a repository.
    func isRepository(at url: URL) async -> Bool

    // MARK: - Reference Operations

    /// Get the current HEAD SHA/commit ID.
    /// - Parameter repoURL: The repository root URL.
    /// - Returns: The current HEAD commit ID.
    func getHeadID(at repoURL: URL) async throws -> String

    /// Resolve any ref (branch, tag, commit-ish) to a commit ID.
    /// - Parameters:
    ///   - ref: The reference to resolve.
    ///   - repoURL: The repository root URL.
    /// - Returns: The resolved commit ID.
    func getRefID(ref: String, at repoURL: URL) async throws -> String

    // MARK: - Status Operations

    /// Get the current branch name.
    /// - Parameter repoURL: The repository root URL.
    /// - Returns: The current branch name, or nil if in detached HEAD state.
    func getCurrentBranch(at repoURL: URL) async throws -> String?

    /// Get the list of local branches.
    /// - Parameters:
    ///   - repoURL: The repository root URL.
    ///   - limit: Maximum number of branches to return.
    /// - Returns: Array of local branches sorted by recent activity.
    func getLocalBranches(at repoURL: URL, limit: Int) async throws -> [VCSBranch]

    /// Get the list of remote branches (or tracked bookmarks for jj).
    /// - Parameters:
    ///   - repoURL: The repository root URL.
    ///   - limit: Maximum number of branches to return.
    /// - Returns: Array of remote branches sorted by recent activity.
    func getRemoteBranches(at repoURL: URL, limit: Int) async throws -> [VCSBranch]

    /// Get the list of tags.
    /// - Parameters:
    ///   - repoURL: The repository root URL.
    ///   - limit: Maximum number of tags to return.
    /// - Returns: Array of tags sorted by date.
    func getTags(at repoURL: URL, limit: Int) async throws -> [VCSTag]

    /// Get the upstream tracking branch for the current branch.
    /// - Parameter repoURL: The repository root URL.
    /// - Returns: The upstream ref name, or nil if no upstream is set.
    func getUpstreamRef(at repoURL: URL) async throws -> String?

    /// Get the ahead/behind count relative to a reference.
    /// - Parameters:
    ///   - ref: The reference to compare against.
    ///   - repoURL: The repository root URL.
    /// - Returns: Tuple of (ahead, behind) counts, or nil if not applicable.
    func getAheadBehind(vs ref: String, at repoURL: URL) async throws -> (ahead: Int, behind: Int)?

    /// Get one coherent branch/upstream/ahead-behind/working-tree status observation.
    func getRepositoryStatus(at repoURL: URL) async throws -> VCSRepositoryStatus

    /// Get structured working directory status.
    /// - Parameter repoURL: The repository root URL.
    /// - Returns: The working status with staged, modified, and untracked files.
    func getWorkingStatus(at repoURL: URL) async throws -> VCSWorkingStatus

    /// Check if a remote tracking ref exists.
    /// - Parameters:
    ///   - refName: The ref name to check.
    ///   - repoURL: The repository root URL.
    /// - Returns: True if the ref exists.
    func hasRemoteTrackingRef(named refName: String, at repoURL: URL) async -> Bool

    // MARK: - Remote Operations

    /// Fetch updates from all remotes.
    /// - Parameter repoURL: The repository root URL.
    func fetch(at repoURL: URL) async throws

    // MARK: - Fingerprint Operations

    /// Get a status fingerprint for staleness detection.
    /// - Parameters:
    ///   - repoURL: The repository root URL.
    ///   - baseRef: The base reference for the fingerprint.
    /// - Returns: A fingerprint capturing the current state.
    func getStatusFingerprint(at repoURL: URL, baseRef: String) async throws -> GitDiffFingerprint

    // MARK: - Diff Operations

    /// Get changed files with statistics.
    /// - Parameters:
    ///   - compare: The compare specification.
    ///   - includeUntrackedWhenApplicable: Whether to include untracked files.
    ///   - detectRenames: Whether to detect renames.
    ///   - repoURL: The repository root URL.
    /// - Returns: Array of changed files with stats.
    func getChangedFilesStats(
        compare: GitDiffCompareSpec,
        includeUntrackedWhenApplicable: Bool,
        detectRenames: Bool,
        at repoURL: URL
    ) async throws -> [VCSUncommittedFile]

    /// Get the diff text for the specified comparison.
    /// - Parameters:
    ///   - compare: The compare specification.
    ///   - paths: Optional paths to filter the diff.
    ///   - contextLines: Number of context lines.
    ///   - detectRenames: Whether to detect renames.
    ///   - repoURL: The repository root URL.
    /// - Returns: The unified diff text.
    func getDiffText(
        compare: GitDiffCompareSpec,
        paths: [String]?,
        contextLines: Int,
        detectRenames: Bool,
        at repoURL: URL
    ) async throws -> String

    /// Get diff for untracked files (git) or new files (jj).
    /// - Parameters:
    ///   - files: The files to diff.
    ///   - contextLines: Number of context lines.
    ///   - repoURL: The repository root URL.
    /// - Returns: The diff text.
    func getUntrackedDiff(
        for files: [String],
        contextLines: Int,
        at repoURL: URL
    ) async throws -> String

    // MARK: - Log Operations

    /// Get the commit graph (for visualization).
    /// - Parameters:
    ///   - maxLines: Maximum lines to return.
    ///   - repoURL: The repository root URL.
    /// - Returns: The ASCII commit graph.
    func getCommitGraph(maxLines: Int, at repoURL: URL) async throws -> String

    /// Get commit log summaries.
    /// - Parameters:
    ///   - count: Number of commits to return.
    ///   - path: Optional path to filter by.
    ///   - repoURL: The repository root URL.
    /// - Returns: Array of commit summaries.
    func getLogSummaries(
        count: Int,
        path: String?,
        at repoURL: URL
    ) async throws -> [VCSCommitSummary]

    /// Get detailed commit info.
    /// - Parameters:
    ///   - ref: The commit reference.
    ///   - repoURL: The repository root URL.
    /// - Returns: The commit info.
    func commitInfo(ref: String, at repoURL: URL) async throws -> VCSCommitInfo

    // MARK: - Blame Operations

    /// Get blame information for a file.
    /// - Parameters:
    ///   - path: The file path.
    ///   - lineRange: Optional line range to limit blame output.
    ///   - repoURL: The repository root URL.
    /// - Returns: Array of blame lines.
    func blame(
        path: String,
        lineRange: ClosedRange<Int>?,
        at repoURL: URL
    ) async throws -> [VCSBlameLine]

    // MARK: - Normalization

    /// Normalize a base reference for this backend.
    /// For example, Git keeps "HEAD" as-is, while Jujutsu maps "HEAD" to "@-".
    /// - Parameter baseRef: The base reference to normalize.
    /// - Returns: The normalized reference.
    func normalizeBaseRef(_ baseRef: String) -> String

    /// Normalize a compare specification for this backend.
    /// Handles backend-specific semantics like jj's lack of staging area.
    /// - Parameter spec: The compare specification.
    /// - Returns: The normalized specification.
    func normalizeCompareSpec(_ spec: GitDiffCompareSpec) -> GitDiffCompareSpec
}

// MARK: - Default Implementations

public extension VCSBackend {
    /// Default implementation checks if findRepoRoot returns non-nil.
    func isRepository(at url: URL) async -> Bool {
        do {
            return try await findRepoRoot(from: url) != nil
        } catch {
            return false
        }
    }

    /// Default normalization keeps the ref as-is.
    func normalizeBaseRef(_ baseRef: String) -> String {
        baseRef
    }

    /// Default normalization keeps the spec as-is.
    func normalizeCompareSpec(_ spec: GitDiffCompareSpec) -> GitDiffCompareSpec {
        spec
    }
}

// MARK: - Compare Spec Warning

/// Result of normalizing a compare spec, including any warnings.
public struct NormalizedCompareResult: Sendable {
    public let spec: GitDiffCompareSpec
    public let warning: String?

    public init(spec: GitDiffCompareSpec, warning: String? = nil) {
        self.spec = spec
        self.warning = warning
    }
}

// MARK: - Extended Backend Protocol

/// Extended protocol for backends that can provide warnings about normalization.
public protocol VCSBackendWithWarnings: VCSBackend {
    /// Normalize a compare specification and return any applicable warnings.
    /// - Parameter spec: The compare specification.
    /// - Returns: The normalized result with optional warning.
    func normalizeCompareSpecWithWarning(_ spec: GitDiffCompareSpec) -> NormalizedCompareResult
}
