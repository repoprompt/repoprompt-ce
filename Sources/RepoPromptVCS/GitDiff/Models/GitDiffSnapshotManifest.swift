import Foundation

public struct DiffHunkIndex: Codable, Sendable, Equatable {
    public let header: String
    public let startLine: Int
    public let endLine: Int

    public init(header: String, startLine: Int, endLine: Int) {
        self.header = header
        self.startLine = startLine
        self.endLine = endLine
    }
}

public struct GitDiffSnapshotManifest: Codable, Sendable, Equatable {
    public let snapshotID: String
    public let generatedAt: Date

    public let mode: GitDiffPublishMode
    public let compare: String
    public let compareInput: String?
    public let scope: GitDiffScope
    public let requestedPaths: [String]?
    public let fingerprint: GitDiffFingerprint

    public let contextLines: Int
    public let detectRenames: Bool

    public let summary: Summary
    public struct Summary: Codable, Sendable, Equatable {
        public let files: Int
        public let insertions: Int
        public let deletions: Int

        package init(
            files: Int,
            insertions: Int,
            deletions: Int
        ) {
            self.files = files
            self.insertions = insertions
            self.deletions = deletions
        }
    }

    public let files: [FileEntry]
    public struct FileEntry: Codable, Sendable, Equatable {
        public let gitPath: String
        public let status: String?
        public let additions: Int?
        public let deletions: Int?
        public let patchPath: String?
        public let bytes: Int?
        public let lines: Int?
        public let hunks: [DiffHunkIndex]?

        package init(
            gitPath: String,
            status: String? = nil,
            additions: Int? = nil,
            deletions: Int? = nil,
            patchPath: String? = nil,
            bytes: Int? = nil,
            lines: Int? = nil,
            hunks: [DiffHunkIndex]? = nil
        ) {
            self.gitPath = gitPath
            self.status = status
            self.additions = additions
            self.deletions = deletions
            self.patchPath = patchPath
            self.bytes = bytes
            self.lines = lines
            self.hunks = hunks
        }
    }

    // MARK: - Multi-root metadata (optional for backward compatibility)

    /// Stable repo key for multi-root identification (e.g., "repoprompt-a1b2c3d4")
    public let repoKey: String?

    /// Canonical repo root path (e.g., "/Users/name/Projects/RepoPrompt")
    public let repoRoot: String?

    // MARK: - Worktree metadata (optional)

    public let isWorktree: Bool?
    public let worktreeName: String?
    public let worktreeRoot: String?
    public let mainWorktreeRoot: String?
    public let commonGitDir: String?

    // MARK: - Tab tracking (for cleanup on tab close)

    /// The compose tab that created this snapshot (nil for legacy/migrated snapshots)
    public let tabID: UUID?

    // MARK: - Initializers

    /// Legacy initializer (without repo metadata) for backward compatibility
    public init(
        snapshotID: String,
        generatedAt: Date,
        mode: GitDiffPublishMode,
        compare: String,
        compareInput: String?,
        scope: GitDiffScope,
        requestedPaths: [String]?,
        fingerprint: GitDiffFingerprint,
        contextLines: Int,
        detectRenames: Bool,
        summary: Summary,
        files: [FileEntry]
    ) {
        isWorktree = nil
        worktreeName = nil
        worktreeRoot = nil
        mainWorktreeRoot = nil
        commonGitDir = nil
        self.snapshotID = snapshotID
        self.generatedAt = generatedAt
        self.mode = mode
        self.compare = compare
        self.compareInput = compareInput
        self.scope = scope
        self.requestedPaths = requestedPaths
        self.fingerprint = fingerprint
        self.contextLines = contextLines
        self.detectRenames = detectRenames
        self.summary = summary
        self.files = files
        repoKey = nil
        repoRoot = nil
        tabID = nil
    }

    /// Multi-root initializer with repo metadata
    public init(
        snapshotID: String,
        generatedAt: Date,
        mode: GitDiffPublishMode,
        compare: String,
        compareInput: String?,
        scope: GitDiffScope,
        requestedPaths: [String]?,
        fingerprint: GitDiffFingerprint,
        contextLines: Int,
        detectRenames: Bool,
        summary: Summary,
        files: [FileEntry],
        repoKey: String?,
        repoRoot: String?,
        isWorktree: Bool? = nil,
        worktreeName: String? = nil,
        worktreeRoot: String? = nil,
        mainWorktreeRoot: String? = nil,
        commonGitDir: String? = nil,
        tabID: UUID? = nil
    ) {
        self.isWorktree = isWorktree
        self.worktreeName = worktreeName
        self.worktreeRoot = worktreeRoot
        self.mainWorktreeRoot = mainWorktreeRoot
        self.commonGitDir = commonGitDir
        self.snapshotID = snapshotID
        self.generatedAt = generatedAt
        self.mode = mode
        self.compare = compare
        self.compareInput = compareInput
        self.scope = scope
        self.requestedPaths = requestedPaths
        self.fingerprint = fingerprint
        self.contextLines = contextLines
        self.detectRenames = detectRenames
        self.summary = summary
        self.files = files
        self.repoKey = repoKey
        self.repoRoot = repoRoot
        self.tabID = tabID
    }
}
