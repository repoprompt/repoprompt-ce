import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptShared
import RepoPromptVCS
import RepoPromptWorkspaceContext
import RepoPromptWorkspaceCore

struct WorktreeMergeReviewScope: Hashable {
    let windowID: Int
    let tabID: UUID
}

struct PendingWorktreeMergeReview: Identifiable, Equatable {
    let id: UUID
    let scope: WorktreeMergeReviewScope
    let operationID: String
    let sourceLabel: String
    let sourceBranch: String?
    let sourcePath: String
    let sourceHead: String
    let targetLabel: String
    let targetBranch: String?
    let targetPath: String
    let targetHead: String
    let mergeBase: String
    let visualization: String
    let summary: GitWorktreeMergeSummary?
    let artifacts: GitWorktreeMergePreviewArtifacts?
    let conflictPrediction: GitWorktreeMergeConflictPrediction
    let createdAt: Date

    init(
        id: UUID = UUID(),
        scope: WorktreeMergeReviewScope,
        preview: GitWorktreeMergePreview,
        createdAt: Date = Date()
    ) {
        let inspection = preview.inspection
        self.id = id
        self.scope = scope
        operationID = preview.operationID
        sourceLabel = inspection.source.displayName
        sourceBranch = inspection.source.branch
        sourcePath = inspection.source.path
        sourceHead = inspection.sourceHead
        targetLabel = inspection.target.displayName
        targetBranch = inspection.target.branch
        targetPath = inspection.target.path
        targetHead = inspection.targetHead
        mergeBase = inspection.mergeBase
        visualization = inspection.visualization
        summary = inspection.summary
        artifacts = preview.artifacts
        conflictPrediction = inspection.conflictPrediction
        self.createdAt = createdAt
    }
}

enum WorktreeMergeReviewDecision: Equatable {
    case accept
    case reject(reason: String)
    case timeout
    case cancelled(reason: String)

    var cancelledReason: String? {
        switch self {
        case .accept:
            nil
        case let .reject(reason):
            reason
        case .timeout:
            "Timed out while waiting for worktree merge approval."
        case let .cancelled(reason):
            reason
        }
    }
}

enum WorktreeMergeSourceBindingResolver {
    enum ResolverError: LocalizedError, Equatable {
        case noBindings
        case ambiguous([String])
        case notFound(String)
        case missingHead(String)

        var errorDescription: String? {
            switch self {
            case .noBindings:
                "This agent session is not bound to a source worktree. Bind a worktree before merging."
            case let .ambiguous(labels):
                "Multiple worktree bindings match this session (\(labels.joined(separator: ", "))). Pass repo_root to choose the source binding."
            case let .notFound(selector):
                "No worktree binding matches repo_root '\(selector)'."
            case let .missingHead(label):
                "Worktree binding '\(label)' does not have a recorded HEAD. Refresh or recreate the binding before merging."
            }
        }
    }

    static func resolve(
        bindings: [AgentSessionWorktreeBinding],
        repoRoot: String?
    ) throws -> AgentSessionWorktreeBinding {
        let available = bindings.filter { !$0.worktreeRootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !available.isEmpty else { throw ResolverError.noBindings }
        guard let repoRoot, !repoRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if available.count == 1 { return available[0] }
            throw ResolverError.ambiguous(available.map(displayLabel(for:)))
        }

        let selector = repoRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchedBindings = available.filter { matchesBinding($0, selector: selector) }
        if matchedBindings.count == 1 { return matchedBindings[0] }
        if matchedBindings.count > 1 { throw ResolverError.ambiguous(matchedBindings.map(displayLabel(for:))) }
        throw ResolverError.notFound(selector)
    }

    static func endpoint(from binding: AgentSessionWorktreeBinding) throws -> GitWorktreeMergeEndpoint {
        guard let head = binding.head?.trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty else {
            throw ResolverError.missingHead(displayLabel(for: binding))
        }
        return GitWorktreeMergeEndpoint(
            worktreeID: binding.worktreeID,
            repositoryID: binding.repositoryID,
            repoKey: binding.repoKey,
            path: binding.worktreeRootPath,
            name: binding.worktreeName ?? binding.visualLabel,
            branch: binding.branch,
            head: head,
            isMain: false
        )
    }

    private static func matchesBinding(_ binding: AgentSessionWorktreeBinding, selector: String) -> Bool {
        let lower = selector.lowercased()
        let canonicalSelector = standardizedPath(selector)
        let candidates = [
            binding.id,
            binding.repositoryID,
            binding.repoKey,
            binding.logicalRootName,
            binding.logicalRootPath,
            binding.worktreeID,
            binding.worktreeName,
            binding.worktreeRootPath,
            binding.branch,
            binding.visualLabel
        ].compactMap(\.self)
        return candidates.contains { candidate in
            candidate.lowercased() == lower || standardizedPath(candidate) == canonicalSelector
        }
    }

    private static func displayLabel(for binding: AgentSessionWorktreeBinding) -> String {
        binding.logicalRootName
            ?? binding.visualLabel
            ?? binding.worktreeName
            ?? binding.branch
            ?? binding.repoKey
    }

    private static func standardizedPath(_ raw: String) -> String {
        guard raw.contains("/") || raw.hasPrefix("~") || raw.hasPrefix(".") else { return raw }
        return ((raw as NSString).expandingTildeInPath as NSString).standardizingPath
    }
}

enum WorktreeMergeEndpointValidation {
    static func sameIdentity(
        _ lhs: GitWorktreeMergeEndpoint,
        _ rhs: GitWorktreeMergeEndpoint
    ) -> Bool {
        lhs.worktreeID == rhs.worktreeID
            && lhs.repositoryID == rhs.repositoryID
            && lhs.repoKey == rhs.repoKey
            && GitRepoRootAuthorization.canonicalPath(lhs.path)
            == GitRepoRootAuthorization.canonicalPath(rhs.path)
            && lhs.head == rhs.head
    }

    static func matches(
        _ endpoint: GitWorktreeMergeEndpoint,
        descriptor: GitWorktreeDescriptor
    ) -> Bool {
        guard let current = try? GitWorktreeMergeEndpoint(descriptor: descriptor) else {
            return false
        }
        return sameIdentity(endpoint, current)
    }

    static func resolveAuthorizedDescriptor(
        for endpoint: GitWorktreeMergeEndpoint,
        roots: [WorkspaceRootRef],
        resolver: GitRepoTargetResolver = GitRepoTargetResolver()
    ) async throws -> GitWorktreeDescriptor {
        let repo = GitRepoDescriptor(rootURL: endpoint.url)
        let descriptor = try await resolver.resolveWorktree(
            selector: "@id:\(endpoint.worktreeID)",
            repo: repo,
            allRepos: [repo],
            authorizedRoots: roots
        )
        guard matches(endpoint, descriptor: descriptor) else {
            throw GitRepoTargetResolverError.invalidParams(
                "Worktree endpoint identity changed before authorization: \(endpoint.path)"
            )
        }
        return descriptor
    }
}

/// Pure, MainActor-independent selectors that decide which worktree merge
/// state should drive Agent Mode attention surfaces (blocker stack, session
/// row badges, and root capsules). Kept side-effect-free so view-model and
/// view tests can pin behavior deterministically.
enum AgentWorktreeMergeBlockerSelector {
    /// Active conflict/awaiting-commit operation for a session. When the
    /// session has multiple non-terminal operations, the most recently updated
    /// one wins so the blocker tracks live activity.
    static func activeConflictOperation(
        in operations: [AgentSessionWorktreeMergeOperation]
    ) -> AgentSessionWorktreeMergeOperation? {
        operations
            .filter { $0.status == .conflicted || $0.status == .awaitingCommit }
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .first
    }

    /// Attention summary for sidebar/session-row markers. Returns `nil` when no
    /// active merge operation needs attention.
    static func sidebarAttention(
        in operations: [AgentSessionWorktreeMergeOperation]
    ) -> AgentWorktreeMergeAttention? {
        let candidates = operations.filter { operation in
            operation.status == .conflicted
                || operation.status == .awaitingCommit
                || operation.status == .awaitingApproval
        }
        guard let primary = candidates.sorted(by: { $0.updatedAt > $1.updatedAt }).first else {
            return nil
        }
        return AgentWorktreeMergeAttention(operation: primary)
    }
}

/// Lightweight, presentation-only summary of an active worktree merge
/// operation. Surfaces just enough for session row badges, workspace-root
/// `MERGE → <target>` capsules, and conflict tooltips without forcing
/// downstream views to depend on the full persistence record.
struct AgentWorktreeMergeAttention: Equatable {
    enum Kind: Equatable {
        case awaitingApproval
        case conflicted
        case awaitingCommit
    }

    let operationID: String
    let kind: Kind
    let sourceLabel: String
    let targetLabel: String
    let targetPath: String
    let conflictFileCount: Int

    init(operation: AgentSessionWorktreeMergeOperation) {
        operationID = operation.id
        sourceLabel = operation.source.displayName
        targetLabel = operation.target.displayName
        targetPath = operation.target.path
        conflictFileCount = operation.conflictFiles.count
        switch operation.status {
        case .awaitingApproval:
            kind = .awaitingApproval
        case .awaitingCommit:
            kind = .awaitingCommit
        default:
            kind = .conflicted
        }
    }

    init(summary: AgentSessionWorktreeMergeSummary) {
        operationID = summary.id
        sourceLabel = summary.sourceLabel
        targetLabel = summary.targetLabel
        targetPath = summary.targetPath
        conflictFileCount = summary.conflictFileCount
        switch summary.status {
        case .awaitingApproval:
            kind = .awaitingApproval
        case .awaitingCommit:
            kind = .awaitingCommit
        default:
            kind = .conflicted
        }
    }

    var capsuleText: String {
        "MERGE → \(targetLabel)"
    }

    var tooltipText: String {
        let stateText: String = switch kind {
        case .awaitingApproval: "awaiting approval"
        case .conflicted: conflictFileCount > 0
            ? "\(conflictFileCount) conflict\(conflictFileCount == 1 ? "" : "s")"
            : "conflicts"
        case .awaitingCommit: "awaiting commit"
        }
        return "Merge \(sourceLabel) → \(targetLabel) · \(stateText) (operation \(operationID))"
    }
}

enum AgentWorktreeMergeCoordinator {
    static func makeOperation(
        preview: GitWorktreeMergePreview,
        status: AgentSessionWorktreeMergeOperation.Status = .previewed,
        now: Date = Date()
    ) -> AgentSessionWorktreeMergeOperation {
        let inspection = preview.inspection
        return AgentSessionWorktreeMergeOperation(
            id: preview.operationID,
            source: inspection.source,
            target: inspection.target,
            mergeBase: inspection.mergeBase,
            sourceHead: inspection.sourceHead,
            targetHeadBefore: inspection.targetHead,
            sourceFingerprint: inspection.sourceFingerprint,
            targetFingerprint: inspection.targetFingerprint,
            previewArtifacts: preview.artifacts,
            summary: inspection.summary,
            visualization: inspection.visualization,
            status: status,
            createdAt: now,
            updatedAt: now
        )
    }

    static func upsert(
        _ operation: AgentSessionWorktreeMergeOperation,
        in operations: inout [AgentSessionWorktreeMergeOperation]
    ) {
        if let index = operations.firstIndex(where: { $0.id == operation.id }) {
            operations[index] = operation
        } else {
            operations.append(operation)
        }
    }

    static func update(
        operationID: String,
        in operations: inout [AgentSessionWorktreeMergeOperation],
        now: Date = Date(),
        mutate: (inout AgentSessionWorktreeMergeOperation) -> Void
    ) throws {
        guard let index = operations.firstIndex(where: { $0.id == operationID }) else {
            throw MCPError.invalidParams("Unknown worktree merge operation_id: \(operationID)")
        }
        mutate(&operations[index])
        operations[index].updatedAt = now
    }

    static func apply(
        result: GitWorktreeMergeApplyResult,
        to operation: inout AgentSessionWorktreeMergeOperation,
        now: Date = Date()
    ) {
        operation.conflictFiles = result.conflictFiles.sorted()
        operation.resultCommit = result.mergeCommit ?? result.targetHeadAfter
        operation.lastError = result.errorMessage ?? result.staleReason
        operation.updatedAt = now
        switch result.status {
        case .completed, .noOp:
            operation.status = .completed
            operation.completedAt = now
            operation.conflictFiles = []
        case .conflicted:
            operation.status = .conflicted
            operation.completedAt = nil
        case .stale:
            operation.status = .stale
            operation.completedAt = now
        case .failed:
            operation.status = .failed
            operation.completedAt = now
        }
    }

    static func abort(
        result: GitWorktreeMergeAbortResult,
        operation: inout AgentSessionWorktreeMergeOperation,
        now: Date = Date()
    ) {
        operation.status = .aborted
        operation.resultCommit = nil
        operation.conflictFiles = []
        operation.completedAt = now
        operation.updatedAt = now
        operation.lastError = result.message
    }
}

@MainActor
extension AgentModeViewModel {
    private func mergeAdmission(sessionID: UUID) throws -> AgentSessionWorktreeRuntime.Admission {
        guard let command = try runtimeCommand(sessionID: sessionID) else {
            throw MCPError.invalidParams("The requested agent session is not currently available.")
        }
        return try command.writer.scope.worktrees.admit(command)
    }

    func previewWorktreeMerge(
        sessionID: UUID, repoRoot: String? = nil, target: String? = "@main",
        workspaceDirectory: URL? = nil, contextLines: Int = 3, detectRenames: Bool = false,
        publishArtifacts: Bool = true, graphLimit: Int = 24
    ) async throws -> GitWorktreeMergePreview {
        let admission = try mergeAdmission(sessionID: sessionID)
        return try await admission.command.writer.scope.worktrees.previewMerge(
            admission: admission, repoRoot: repoRoot, target: target, workspaceDirectory: workspaceDirectory,
            contextLines: contextLines, detectRenames: detectRenames, publishArtifacts: publishArtifacts, graphLimit: graphLimit
        )
    }

    func requestWorktreeMergeReviewAndApply(
        sessionID: UUID, operationID: String,
        timeoutSeconds: TimeInterval = MCPTimeoutPolicy.worktreeMergeApprovalTimeoutSeconds,
        commitMessage: String? = nil
    ) async throws -> GitWorktreeMergeApplyResult {
        let admission = try mergeAdmission(sessionID: sessionID)
        return try await admission.command.writer.scope.worktrees.applyMerge(
            admission: admission, operationID: operationID, review: true,
            timeoutSeconds: timeoutSeconds, commitMessage: commitMessage
        )
    }

    func applyConfirmedWorktreeMerge(sessionID: UUID, operationID: String, commitMessage: String? = nil) async throws -> GitWorktreeMergeApplyResult {
        let admission = try mergeAdmission(sessionID: sessionID)
        return try await admission.command.writer.scope.worktrees.applyMerge(
            admission: admission, operationID: operationID, review: false, commitMessage: commitMessage
        )
    }

    func statusWorktreeMerge(sessionID: UUID, operationID: String?) throws -> AgentSessionWorktreeMergeOperation {
        guard let command = try runtimeCommand(sessionID: sessionID) else {
            throw MCPError.invalidParams("The requested agent session is not currently available.")
        }
        return try command.writer.scope.worktrees.statusMerge(command: command, operationID: operationID)
    }

    func continueWorktreeMerge(sessionID: UUID, operationID: String, confirmed: Bool = true, commitMessage: String? = nil) async throws -> GitWorktreeMergeApplyResult {
        guard confirmed else { throw MCPError.invalidParams("continue requires confirmation.") }
        let admission = try mergeAdmission(sessionID: sessionID)
        return try await admission.command.writer.scope.worktrees.continueMerge(admission: admission, operationID: operationID, commitMessage: commitMessage)
    }

    func abortWorktreeMerge(sessionID: UUID, operationID: String, confirmed: Bool = true) async throws -> GitWorktreeMergeAbortResult {
        guard confirmed else { throw MCPError.invalidParams("abort requires confirmation.") }
        let admission = try mergeAdmission(sessionID: sessionID)
        return try await admission.command.writer.scope.worktrees.abortMerge(admission: admission, operationID: operationID)
    }

    func pendingWorktreeMergeReview(for tabID: UUID?) -> PendingWorktreeMergeReview? {
        guard let tabID, let session = sessions[tabID] else { return nil }
        return session.uiPendingWorktreeMergeReview
    }

    func activeWorktreeMergeConflictOperation(for tabID: UUID?) -> AgentSessionWorktreeMergeOperation? {
        guard let tabID, let session = sessions[tabID] else { return nil }
        return AgentWorktreeMergeBlockerSelector.activeConflictOperation(in: session.worktreeMergeOperations)
    }

    func publishWorktreeMergeOperationsChange(in session: TabSession) {
        updateWorktreeMergeSummariesInIndex(for: session)
        syncSidebarUIState(refresh: true, reason: .metadataUpdated)
        if session.tabID == currentTabID { syncRunInteractionUIState() }
    }
}
