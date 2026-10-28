import Foundation
import RepoPromptVCS

/// Persisted, compact Agent-session metadata for a worktree merge workflow.
///
/// The operation intentionally stores identifiers, endpoints, fingerprints, artifact references,
/// and resume state only. Full patch text remains in the published preview artifacts.
struct AgentSessionWorktreeMergeOperation: Codable, Equatable, Identifiable {
    enum Status: String, Codable, Equatable {
        case previewed
        case awaitingApproval = "awaiting_approval"
        case applying
        case conflicted
        case awaitingCommit = "awaiting_commit"
        case stale
        case completed
        case failed
        case cancelled
        case aborted

        var isTerminal: Bool {
            switch self {
            case .stale, .completed, .failed, .cancelled, .aborted:
                true
            case .previewed, .awaitingApproval, .applying, .conflicted, .awaitingCommit:
                false
            }
        }

        var isActive: Bool {
            !isTerminal
        }
    }

    let id: String
    var source: GitWorktreeMergeEndpoint
    var target: GitWorktreeMergeEndpoint
    var mergeBase: String
    var sourceHead: String
    var targetHeadBefore: String
    var sourceFingerprint: GitDiffFingerprint?
    var targetFingerprint: GitDiffFingerprint?
    var previewArtifacts: GitWorktreeMergePreviewArtifacts?
    var summary: GitWorktreeMergeSummary?
    var visualization: String?
    var status: Status
    var conflictFiles: [String]
    var resultCommit: String?
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
    var lastError: String?

    init(
        id: String,
        source: GitWorktreeMergeEndpoint,
        target: GitWorktreeMergeEndpoint,
        mergeBase: String,
        sourceHead: String,
        targetHeadBefore: String,
        sourceFingerprint: GitDiffFingerprint? = nil,
        targetFingerprint: GitDiffFingerprint? = nil,
        previewArtifacts: GitWorktreeMergePreviewArtifacts? = nil,
        summary: GitWorktreeMergeSummary? = nil,
        visualization: String? = nil,
        status: Status = .previewed,
        conflictFiles: [String] = [],
        resultCommit: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.source = source
        self.target = target
        self.mergeBase = mergeBase
        self.sourceHead = sourceHead
        self.targetHeadBefore = targetHeadBefore
        self.sourceFingerprint = sourceFingerprint
        self.targetFingerprint = targetFingerprint
        self.previewArtifacts = previewArtifacts
        self.summary = summary
        self.visualization = visualization
        self.status = status
        self.conflictFiles = conflictFiles.sorted()
        self.resultCommit = resultCommit
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.lastError = lastError
    }

    var activeSummary: AgentSessionWorktreeMergeSummary? {
        guard status.isActive else { return nil }
        return AgentSessionWorktreeMergeSummary(operation: self)
    }
}

/// Lightweight merge state copied into session-list/header/index data so restored sessions can
/// surface active merge attention without decoding transcripts or embedding patch contents.
struct AgentSessionWorktreeMergeSummary: Codable, Equatable, Identifiable {
    let id: String
    let status: AgentSessionWorktreeMergeOperation.Status
    let sourceWorktreeID: String
    let sourceLabel: String
    let sourceBranch: String?
    let sourcePath: String
    let targetWorktreeID: String
    let targetLabel: String
    let targetBranch: String?
    let targetPath: String
    let repositoryID: String
    let repoKey: String
    let conflictFileCount: Int
    let updatedAt: Date

    init(
        id: String,
        status: AgentSessionWorktreeMergeOperation.Status,
        sourceWorktreeID: String,
        sourceLabel: String,
        sourceBranch: String?,
        sourcePath: String,
        targetWorktreeID: String,
        targetLabel: String,
        targetBranch: String?,
        targetPath: String,
        repositoryID: String,
        repoKey: String,
        conflictFileCount: Int,
        updatedAt: Date
    ) {
        self.id = id
        self.status = status
        self.sourceWorktreeID = sourceWorktreeID
        self.sourceLabel = sourceLabel
        self.sourceBranch = sourceBranch
        self.sourcePath = sourcePath
        self.targetWorktreeID = targetWorktreeID
        self.targetLabel = targetLabel
        self.targetBranch = targetBranch
        self.targetPath = targetPath
        self.repositoryID = repositoryID
        self.repoKey = repoKey
        self.conflictFileCount = max(0, conflictFileCount)
        self.updatedAt = updatedAt
    }

    init(operation: AgentSessionWorktreeMergeOperation) {
        self.init(
            id: operation.id,
            status: operation.status,
            sourceWorktreeID: operation.source.worktreeID,
            sourceLabel: operation.source.displayName,
            sourceBranch: operation.source.branch,
            sourcePath: operation.source.path,
            targetWorktreeID: operation.target.worktreeID,
            targetLabel: operation.target.displayName,
            targetBranch: operation.target.branch,
            targetPath: operation.target.path,
            repositoryID: operation.source.repositoryID,
            repoKey: operation.source.repoKey,
            conflictFileCount: operation.conflictFiles.count,
            updatedAt: operation.updatedAt
        )
    }
}

struct AgentSessionWorktreeMergeReconciliationInspection: Equatable {
    var targetMergeInProgress: Bool
    var targetHead: String?
    var conflictFiles: [String]
    var previewArtifactsAvailable: Bool?
    var previewFingerprintsMatch: Bool?

    init(
        targetMergeInProgress: Bool,
        targetHead: String?,
        conflictFiles: [String] = [],
        previewArtifactsAvailable: Bool? = nil,
        previewFingerprintsMatch: Bool? = nil
    ) {
        self.targetMergeInProgress = targetMergeInProgress
        self.targetHead = targetHead
        self.conflictFiles = conflictFiles.sorted()
        self.previewArtifactsAvailable = previewArtifactsAvailable
        self.previewFingerprintsMatch = previewFingerprintsMatch
    }
}

struct AgentSessionWorktreeMergeReconciliationHooks {
    var inspect: @Sendable (AgentSessionWorktreeMergeOperation) async throws -> AgentSessionWorktreeMergeReconciliationInspection

    static func live(
        vcsService: VCSService = .shared,
        fileManager: FileManager = .default
    ) -> AgentSessionWorktreeMergeReconciliationHooks {
        AgentSessionWorktreeMergeReconciliationHooks { operation in
            let git = await vcsService.gitBackend()
            async let targetMergeState = git.inspectMergeState(at: operation.target.url)
            async let targetHead = git.getHeadID(at: operation.target.url)
            let previewValidity = try await Self.previewValidity(
                for: operation,
                vcsService: vcsService,
                fileManager: fileManager
            )
            let state = try await targetMergeState
            return try await AgentSessionWorktreeMergeReconciliationInspection(
                targetMergeInProgress: state.inProgress,
                targetHead: targetHead,
                conflictFiles: state.conflictFiles,
                previewArtifactsAvailable: previewValidity.artifactsAvailable,
                previewFingerprintsMatch: previewValidity.fingerprintsMatch
            )
        }
    }

    private static func previewValidity(
        for operation: AgentSessionWorktreeMergeOperation,
        vcsService: VCSService,
        fileManager: FileManager
    ) async throws -> (artifactsAvailable: Bool, fingerprintsMatch: Bool) {
        let artifactsAvailable = operation.previewArtifacts.map { artifacts in
            let requiredPaths = [artifacts.manifestPath, artifacts.mapPath, artifacts.sidecarPath]
            let optionalPaths = [artifacts.allPatchPath].compactMap(\.self)
            return (requiredPaths + optionalPaths).allSatisfy { fileManager.fileExists(atPath: $0) }
        } ?? false

        guard operation.sourceFingerprint != nil || operation.targetFingerprint != nil else {
            return (artifactsAvailable, true)
        }

        let inspection = try await vcsService.inspectGitWorktreeMerge(.init(
            source: operation.source,
            target: operation.target
        ))
        let sourceMatches = operation.sourceFingerprint.map { $0 == inspection.sourceFingerprint } ?? true
        let targetMatches = operation.targetFingerprint.map { $0 == inspection.targetFingerprint } ?? true
        return (artifactsAvailable, sourceMatches && targetMatches)
    }
}

enum AgentSessionWorktreeMergeReconciler {
    static func reconcile(
        _ operations: [AgentSessionWorktreeMergeOperation],
        now: Date = Date(),
        hooks: AgentSessionWorktreeMergeReconciliationHooks = .live()
    ) async -> [AgentSessionWorktreeMergeOperation] {
        var reconciled: [AgentSessionWorktreeMergeOperation] = []
        reconciled.reserveCapacity(operations.count)
        for operation in operations {
            await reconciled.append(reconcile(operation, now: now, hooks: hooks))
        }
        return reconciled
    }

    static func reconcile(
        _ operation: AgentSessionWorktreeMergeOperation,
        now: Date = Date(),
        hooks: AgentSessionWorktreeMergeReconciliationHooks
    ) async -> AgentSessionWorktreeMergeOperation {
        guard !operation.status.isTerminal else { return operation }

        var updated = operation
        switch operation.status {
        case .awaitingApproval:
            updated.status = .cancelled
            updated.updatedAt = now
            updated.completedAt = now
            updated.lastError = "Merge approval was cancelled because pending approval continuations do not survive relaunch."
            return updated
        case .previewed:
            do {
                let inspection = try await hooks.inspect(operation)
                if inspection.previewArtifactsAvailable == false || inspection.previewFingerprintsMatch == false {
                    updated.status = .stale
                    updated.updatedAt = now
                    updated.completedAt = now
                    updated.lastError = inspection.previewArtifactsAvailable == false
                        ? "Merge preview artifacts are no longer available."
                        : "Merge preview fingerprints are no longer current."
                }
                return updated
            } catch {
                updated.status = .stale
                updated.updatedAt = now
                updated.completedAt = now
                updated.lastError = "Merge preview could not be revalidated: \(error.localizedDescription)"
                return updated
            }
        case .applying, .conflicted, .awaitingCommit:
            do {
                let inspection = try await hooks.inspect(operation)
                return reconcileInFlight(updated, inspection: inspection, now: now)
            } catch {
                updated.status = .failed
                updated.updatedAt = now
                updated.completedAt = now
                updated.lastError = "Merge state could not be inspected: \(error.localizedDescription)"
                return updated
            }
        case .stale, .completed, .failed, .cancelled, .aborted:
            return operation
        }
    }

    private static func reconcileInFlight(
        _ operation: AgentSessionWorktreeMergeOperation,
        inspection: AgentSessionWorktreeMergeReconciliationInspection,
        now: Date
    ) -> AgentSessionWorktreeMergeOperation {
        var updated = operation
        updated.conflictFiles = inspection.conflictFiles
        updated.updatedAt = now

        if inspection.targetMergeInProgress {
            updated.resultCommit = nil
            updated.completedAt = nil
            updated.lastError = nil
            updated.status = inspection.conflictFiles.isEmpty ? .awaitingCommit : .conflicted
            return updated
        }

        if let targetHead = inspection.targetHead, targetHead != operation.targetHeadBefore {
            updated.status = .completed
            updated.resultCommit = targetHead
            updated.completedAt = now
            updated.lastError = nil
            updated.conflictFiles = []
            return updated
        }

        updated.status = .failed
        updated.completedAt = now
        updated.lastError = "No Git merge is in progress for the target worktree and no merge commit was detected."
        return updated
    }
}

extension Sequence<AgentSessionWorktreeMergeOperation> {
    var activeWorktreeMergeSummaries: [AgentSessionWorktreeMergeSummary] {
        compactMap(\.activeSummary)
    }
}
