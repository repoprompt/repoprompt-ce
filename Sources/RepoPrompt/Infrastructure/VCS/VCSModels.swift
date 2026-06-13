import Foundation

// MARK: - VCS Backend Kind

/// The type of version control system backend.
public enum VCSBackendKind: String, Codable, Sendable {
    case git
    case jujutsu
}

// MARK: - VCS Capabilities

/// Describes the capabilities of a VCS backend.
/// Used to determine which operations are supported and how to handle semantic differences.
public struct VCSCapabilities: Sendable {
    /// Whether the VCS has a staging area (index) concept.
    /// Git: true, Jujutsu: false (working copy is auto-committed)
    public let hasStagingArea: Bool

    /// Whether the VCS has an "untracked files" concept.
    /// Git: true, Jujutsu: false (all files in working copy are tracked)
    public let hasUntrackedFilesConcept: Bool

    /// Whether the VCS supports fetching from remotes.
    public let supportsFetch: Bool

    /// Whether the VCS supports tags.
    public let supportsTags: Bool

    /// Whether the VCS supports remote branches (or tracked bookmarks).
    public let supportsRemoteBranches: Bool

    public init(
        hasStagingArea: Bool,
        hasUntrackedFilesConcept: Bool,
        supportsFetch: Bool,
        supportsTags: Bool,
        supportsRemoteBranches: Bool
    ) {
        self.hasStagingArea = hasStagingArea
        self.hasUntrackedFilesConcept = hasUntrackedFilesConcept
        self.supportsFetch = supportsFetch
        self.supportsTags = supportsTags
        self.supportsRemoteBranches = supportsRemoteBranches
    }

    /// Capabilities for Git backend.
    public static let git = VCSCapabilities(
        hasStagingArea: true,
        hasUntrackedFilesConcept: true,
        supportsFetch: true,
        supportsTags: true,
        supportsRemoteBranches: true
    )

    /// Capabilities for Jujutsu backend.
    public static let jujutsu = VCSCapabilities(
        hasStagingArea: false,
        hasUntrackedFilesConcept: false,
        supportsFetch: true, // via `jj git fetch`
        supportsTags: false, // jj doesn't have native tags (uses git backend)
        supportsRemoteBranches: true // tracked bookmarks
    )
}

// MARK: - VCS File Types

/// Represents a file with uncommitted changes.
public struct VCSUncommittedFile: Equatable, Sendable {
    /// The path of the file relative to the repository root.
    public let path: String

    /// The status code of the file.
    /// Common values: "M" (modified), "A" (added), "D" (deleted), "R" (renamed),
    /// "C" (copied), "U" (unmerged), "??" (untracked, git only)
    public let status: String

    /// Number of lines added (nil for binary files or when stats unavailable).
    public let additions: Int?

    /// Number of lines deleted (nil for binary files or when stats unavailable).
    public let deletions: Int?

    public init(
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

// MARK: - VCS Branch/Tag Types

/// Describes a local branch that is already checked out by another Git worktree.
public struct VCSBranchWorktreeOccupancy: Sendable, Equatable, Hashable {
    public let worktreePath: String
    public let worktreeName: String?
    public let worktreeID: String?

    public init(worktreePath: String, worktreeName: String? = nil, worktreeID: String? = nil) {
        self.worktreePath = worktreePath
        self.worktreeName = worktreeName
        self.worktreeID = worktreeID
    }
}

/// Represents a branch (git) or bookmark (jujutsu).
public struct VCSBranch: Identifiable, Sendable, Equatable {
    /// The name of the branch/bookmark.
    public let name: String

    /// Whether this is the current branch.
    public let isCurrent: Bool

    /// The date of the last commit on this branch (if available).
    public let lastCommitDate: Date?

    /// The other worktree currently occupying this branch, if any.
    public let checkedOutWorktree: VCSBranchWorktreeOccupancy?

    public var id: String {
        name
    }

    public var isCheckedOutInAnotherWorktree: Bool {
        checkedOutWorktree != nil
    }

    public var checkedOutWorktreeLabel: String? {
        guard let checkedOutWorktree else { return nil }
        if let name = checkedOutWorktree.worktreeName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty
        {
            return name
        }
        let fallback = URL(fileURLWithPath: checkedOutWorktree.worktreePath).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? nil : fallback
    }

    public init(
        name: String,
        isCurrent: Bool,
        lastCommitDate: Date? = nil,
        checkedOutWorktree: VCSBranchWorktreeOccupancy? = nil
    ) {
        self.name = name
        self.isCurrent = isCurrent
        self.lastCommitDate = lastCommitDate
        self.checkedOutWorktree = checkedOutWorktree
    }
}

public enum VCSBranchSortOrder: String, CaseIterable, Identifiable, Sendable, Equatable {
    case recent
    case name

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .recent:
            "Recent"
        case .name:
            "Name"
        }
    }
}

public extension [VCSBranch] {
    func sortedForDisplay(by order: VCSBranchSortOrder) -> [VCSBranch] {
        switch order {
        case .recent:
            sortedByRecentBranchActivity()
        case .name:
            sortedByBranchName()
        }
    }

    private func sortedByRecentBranchActivity() -> [VCSBranch] {
        sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            switch (lhs.lastCommitDate, rhs.lastCommitDate) {
            case let (left?, right?) where left != right:
                return left > right
            case (.some, nil):
                return true
            case (nil, .some):
                return false
            default:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private func sortedByBranchName() -> [VCSBranch] {
        sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

/// Represents a tag.
public struct VCSTag: Sendable {
    /// The name of the tag.
    public let name: String

    /// The date of the commit this tag points to (if available).
    public let commitDate: Date?

    public init(name: String, commitDate: Date? = nil) {
        self.name = name
        self.commitDate = commitDate
    }
}

// MARK: - VCS Status Types

/// Structured working directory status.
public struct VCSWorkingStatus: Sendable, Equatable {
    /// Files staged for commit (git only; empty for jujutsu).
    public let staged: [String]

    /// Files with modifications in the working tree.
    public let modified: [String]

    /// Untracked files (git only; empty for jujutsu).
    public let untracked: [String]

    public init(staged: [String], modified: [String], untracked: [String]) {
        self.staged = staged
        self.modified = modified
        self.untracked = untracked
    }

    /// Empty working status.
    public static let empty = VCSWorkingStatus(staged: [], modified: [], untracked: [])
}

/// One coherent repository status observation.
public struct VCSRepositoryStatus: Sendable, Equatable {
    public let branch: String?
    public let headID: String?
    public let upstream: String?
    public let ahead: Int?
    public let behind: Int?
    public let workingStatus: VCSWorkingStatus

    public init(
        branch: String?,
        headID: String?,
        upstream: String?,
        ahead: Int?,
        behind: Int?,
        workingStatus: VCSWorkingStatus
    ) {
        self.branch = branch
        self.headID = headID
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.workingStatus = workingStatus
    }
}

// MARK: - VCS Commit Types

/// Summary of a commit for log output.
public struct VCSCommitSummary: Sendable {
    /// The full commit/change ID.
    public let id: String

    /// The short commit/change ID (typically 7-12 characters).
    public let shortID: String

    /// The author name.
    public let author: String

    /// The commit date in ISO8601 format.
    public let dateISO: String

    /// The commit message (first line or full message).
    public let message: String

    /// Number of files changed in this commit.
    public let filesChanged: Int

    /// Total lines inserted.
    public let insertions: Int

    /// Total lines deleted.
    public let deletions: Int

    public init(
        id: String,
        shortID: String,
        author: String,
        dateISO: String,
        message: String,
        filesChanged: Int,
        insertions: Int,
        deletions: Int
    ) {
        self.id = id
        self.shortID = shortID
        self.author = author
        self.dateISO = dateISO
        self.message = message
        self.filesChanged = filesChanged
        self.insertions = insertions
        self.deletions = deletions
    }
}

/// Detailed commit info for `show` operation.
public struct VCSCommitInfo: Sendable {
    /// The full commit/change ID.
    public let id: String

    /// The short commit/change ID.
    public let shortID: String

    /// The author name.
    public let author: String

    /// The commit date in ISO8601 format.
    public let dateISO: String

    /// The full commit message.
    public let message: String

    public init(
        id: String,
        shortID: String,
        author: String,
        dateISO: String,
        message: String
    ) {
        self.id = id
        self.shortID = shortID
        self.author = author
        self.dateISO = dateISO
        self.message = message
    }
}

// MARK: - VCS Blame Types

/// A single line of blame output.
public struct VCSBlameLine: Sendable {
    /// The line number in the file.
    public let line: Int

    /// The commit/change ID that last modified this line (short form).
    public let id: String

    /// The author who last modified this line.
    public let author: String

    /// The date of the modification in ISO8601 format.
    public let dateISO: String

    /// The content of the line.
    public let content: String

    public init(
        line: Int,
        id: String,
        author: String,
        dateISO: String,
        content: String
    ) {
        self.line = line
        self.id = id
        self.author = author
        self.dateISO = dateISO
        self.content = content
    }
}

// MARK: - VCS Error Types

/// Errors that can occur during VCS operations.
public enum VCSError: LocalizedError {
    case notARepository(path: String)
    case commandFailed(command: String, message: String)
    case unsupportedOperation(operation: String, backend: VCSBackendKind)
    case parseError(message: String)
    case executableNotFound(name: String)

    public var errorDescription: String? {
        switch self {
        case let .notARepository(path):
            "Not a version control repository: \(path)"
        case let .commandFailed(command, message):
            "\(command) failed: \(message)"
        case let .unsupportedOperation(operation, backend):
            "Operation '\(operation)' is not supported by \(backend.rawValue) backend"
        case let .parseError(message):
            "Failed to parse VCS output: \(message)"
        case let .executableNotFound(name):
            "VCS executable not found: \(name)"
        }
    }
}
