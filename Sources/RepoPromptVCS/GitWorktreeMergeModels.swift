import Foundation

// MARK: - Git Worktree Merge Models

public struct GitWorktreeMergeEndpoint: Codable, Sendable, Equatable, Hashable {
    public let worktreeID: String
    public let repositoryID: String
    public let repoKey: String
    public let path: String
    public let name: String?
    public let branch: String?
    public let head: String
    public let isMain: Bool

    public init(
        worktreeID: String,
        repositoryID: String,
        repoKey: String,
        path: String,
        name: String?,
        branch: String?,
        head: String,
        isMain: Bool
    ) {
        self.worktreeID = worktreeID
        self.repositoryID = repositoryID
        self.repoKey = repoKey
        self.path = path
        self.name = name
        self.branch = branch
        self.head = head
        self.isMain = isMain
    }

    public init(descriptor: GitWorktreeDescriptor) throws {
        guard let head = descriptor.head, !head.isEmpty else {
            throw VCSError.parseError(message: "Git worktree has no HEAD: \(descriptor.path)")
        }
        self.init(
            worktreeID: descriptor.worktreeID,
            repositoryID: descriptor.repository.repositoryID,
            repoKey: descriptor.repository.repoKey,
            path: GitRepoRootAuthorization.canonicalPath(descriptor.path),
            name: descriptor.name,
            branch: descriptor.branch,
            head: head,
            isMain: descriptor.isMain
        )
    }

    public var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    public var displayName: String {
        name ?? branch ?? (isMain ? "main" : URL(fileURLWithPath: path).lastPathComponent)
    }

    public var shortHead: String {
        String(head.prefix(7))
    }
}

public enum GitWorktreeMergeBlockerCode: String, Codable, Sendable, Equatable {
    case sourceDirty = "source_dirty"
    case targetDirty = "target_dirty"
    case sourceMergeInProgress = "source_merge_in_progress"
    case targetMergeInProgress = "target_merge_in_progress"
    case sourceUnavailable = "source_unavailable"
    case targetUnavailable = "target_unavailable"
    case differentRepository = "different_repository"
    case sameWorktree = "same_worktree"
    case unsupportedBackend = "unsupported_backend"
    case noSourceCommits = "no_source_commits"
}

public enum GitWorktreeMergeApplyStatus: String, Codable, Sendable, Equatable {
    case completed
    case conflicted
    case stale
    case failed
    case noOp = "no_op"
}

public struct GitWorktreeMergeBlocker: Codable, Sendable, Equatable {
    public let code: GitWorktreeMergeBlockerCode
    public let message: String
    public let paths: [String]

    public init(code: GitWorktreeMergeBlockerCode, message: String, paths: [String] = []) {
        self.code = code
        self.message = message
        self.paths = paths
    }
}

public struct GitWorktreeMergeConflictPrediction: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case clean
        case conflicts
        case unavailable
    }

    public let status: Status
    public let files: [String]
    public let message: String?

    public init(status: Status, files: [String] = [], message: String? = nil) {
        self.status = status
        self.files = files
        self.message = message
    }
}

public struct GitWorktreeMergeState: Codable, Sendable, Equatable {
    public let inProgress: Bool
    public let mergeHead: String?
    public let conflictFiles: [String]

    public init(inProgress: Bool, mergeHead: String?, conflictFiles: [String]) {
        self.inProgress = inProgress
        self.mergeHead = mergeHead
        self.conflictFiles = conflictFiles
    }
}

public struct GitWorktreeMergeSummary: Codable, Sendable, Equatable {
    public let commits: Int
    public let files: Int
    public let insertions: Int
    public let deletions: Int

    public init(commits: Int, files: Int, insertions: Int, deletions: Int) {
        self.commits = commits
        self.files = files
        self.insertions = insertions
        self.deletions = deletions
    }
}

public struct GitWorktreeMergeInspection: Codable, Sendable, Equatable {
    public let source: GitWorktreeMergeEndpoint
    public let target: GitWorktreeMergeEndpoint
    public let mergeBase: String
    public let sourceHead: String
    public let targetHead: String
    public let sourceFingerprint: GitDiffFingerprint
    public let targetFingerprint: GitDiffFingerprint
    public let blockers: [GitWorktreeMergeBlocker]
    public let conflictPrediction: GitWorktreeMergeConflictPrediction
    public let summary: GitWorktreeMergeSummary
    public let visualization: String

    public var isBlocked: Bool {
        !blockers.isEmpty
    }

    public init(
        source: GitWorktreeMergeEndpoint,
        target: GitWorktreeMergeEndpoint,
        mergeBase: String,
        sourceHead: String,
        targetHead: String,
        sourceFingerprint: GitDiffFingerprint,
        targetFingerprint: GitDiffFingerprint,
        blockers: [GitWorktreeMergeBlocker],
        conflictPrediction: GitWorktreeMergeConflictPrediction,
        summary: GitWorktreeMergeSummary,
        visualization: String
    ) {
        self.source = source
        self.target = target
        self.mergeBase = mergeBase
        self.sourceHead = sourceHead
        self.targetHead = targetHead
        self.sourceFingerprint = sourceFingerprint
        self.targetFingerprint = targetFingerprint
        self.blockers = blockers
        self.conflictPrediction = conflictPrediction
        self.summary = summary
        self.visualization = visualization
    }
}

public struct GitWorktreeMergePreviewArtifacts: Codable, Sendable, Equatable {
    public let snapshotID: String
    public let snapshotDirectory: String
    public let manifestPath: String
    public let mapPath: String
    public let allPatchPath: String?
    public let sidecarPath: String

    public init(
        snapshotID: String,
        snapshotDirectory: String,
        manifestPath: String,
        mapPath: String,
        allPatchPath: String?,
        sidecarPath: String
    ) {
        self.snapshotID = snapshotID
        self.snapshotDirectory = snapshotDirectory
        self.manifestPath = manifestPath
        self.mapPath = mapPath
        self.allPatchPath = allPatchPath
        self.sidecarPath = sidecarPath
    }
}

public struct GitWorktreeMergePreview: Codable, Sendable, Equatable {
    public let operationID: String
    public let inspection: GitWorktreeMergeInspection
    public let artifacts: GitWorktreeMergePreviewArtifacts?

    public init(operationID: String, inspection: GitWorktreeMergeInspection, artifacts: GitWorktreeMergePreviewArtifacts?) {
        self.operationID = operationID
        self.inspection = inspection
        self.artifacts = artifacts
    }
}

public struct GitWorktreeMergeApplyResult: Codable, Sendable, Equatable {
    public let status: GitWorktreeMergeApplyStatus
    public let source: GitWorktreeMergeEndpoint
    public let target: GitWorktreeMergeEndpoint
    public let sourceHead: String
    public let targetHeadBefore: String
    public let targetHeadAfter: String?
    public let mergeCommit: String?
    public let conflictFiles: [String]
    public let staleReason: String?
    public let errorMessage: String?

    public init(
        status: GitWorktreeMergeApplyStatus,
        source: GitWorktreeMergeEndpoint,
        target: GitWorktreeMergeEndpoint,
        sourceHead: String,
        targetHeadBefore: String,
        targetHeadAfter: String? = nil,
        mergeCommit: String? = nil,
        conflictFiles: [String] = [],
        staleReason: String? = nil,
        errorMessage: String? = nil
    ) {
        self.status = status
        self.source = source
        self.target = target
        self.sourceHead = sourceHead
        self.targetHeadBefore = targetHeadBefore
        self.targetHeadAfter = targetHeadAfter
        self.mergeCommit = mergeCommit
        self.conflictFiles = conflictFiles
        self.staleReason = staleReason
        self.errorMessage = errorMessage
    }
}

public struct GitWorktreeMergeAbortResult: Codable, Sendable, Equatable {
    public let aborted: Bool
    public let target: GitWorktreeMergeEndpoint
    public let targetHead: String
    public let message: String?

    public init(aborted: Bool, target: GitWorktreeMergeEndpoint, targetHead: String, message: String? = nil) {
        self.aborted = aborted
        self.target = target
        self.targetHead = targetHead
        self.message = message
    }
}

public struct GitWorktreeMergeInspectRequest: Sendable, Equatable {
    public let source: GitWorktreeMergeEndpoint
    public let target: GitWorktreeMergeEndpoint
    public let graphLimit: Int

    public init(source: GitWorktreeMergeEndpoint, target: GitWorktreeMergeEndpoint, graphLimit: Int = 24) {
        self.source = source
        self.target = target
        self.graphLimit = graphLimit
    }
}

public struct GitWorktreeMergePreviewRequest: Sendable, Equatable {
    public let source: GitWorktreeMergeEndpoint
    public let target: GitWorktreeMergeEndpoint
    public let workspaceDirectory: URL
    public let contextLines: Int
    public let detectRenames: Bool
    public let publishArtifacts: Bool
    public let snapshotIDOverride: String?
    public let tabID: UUID?
    public let graphLimit: Int

    public init(
        source: GitWorktreeMergeEndpoint,
        target: GitWorktreeMergeEndpoint,
        workspaceDirectory: URL,
        contextLines: Int = 3,
        detectRenames: Bool = false,
        publishArtifacts: Bool = true,
        snapshotIDOverride: String? = nil,
        tabID: UUID? = nil,
        graphLimit: Int = 24
    ) {
        self.source = source
        self.target = target
        self.workspaceDirectory = workspaceDirectory
        self.contextLines = contextLines
        self.detectRenames = detectRenames
        self.publishArtifacts = publishArtifacts
        self.snapshotIDOverride = snapshotIDOverride
        self.tabID = tabID
        self.graphLimit = graphLimit
    }
}

public struct GitWorktreeMergeApplyRequest: Sendable, Equatable {
    public let preview: GitWorktreeMergePreview
    public let commitMessage: String?

    public init(preview: GitWorktreeMergePreview, commitMessage: String? = nil) {
        self.preview = preview
        self.commitMessage = commitMessage
    }
}

public struct GitWorktreeMergeContinueRequest: Sendable, Equatable {
    public let source: GitWorktreeMergeEndpoint
    public let target: GitWorktreeMergeEndpoint
    public let sourceHead: String
    public let targetHeadBefore: String
    public let commitMessage: String?

    public init(
        source: GitWorktreeMergeEndpoint,
        target: GitWorktreeMergeEndpoint,
        sourceHead: String,
        targetHeadBefore: String,
        commitMessage: String? = nil
    ) {
        self.source = source
        self.target = target
        self.sourceHead = sourceHead
        self.targetHeadBefore = targetHeadBefore
        self.commitMessage = commitMessage
    }
}

public struct GitWorktreeMergeAbortRequest: Sendable, Equatable {
    public let target: GitWorktreeMergeEndpoint

    public init(target: GitWorktreeMergeEndpoint) {
        self.target = target
    }
}
