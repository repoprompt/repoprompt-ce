import Foundation
import MCP
import RepoPromptShared

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
    func previewWorktreeMerge(
        sessionID: UUID,
        repoRoot: String? = nil,
        target: String? = "@main",
        workspaceDirectory: URL? = nil,
        contextLines: Int = 3,
        detectRenames: Bool = false,
        publishArtifacts: Bool = true,
        graphLimit: Int = 24
    ) async throws -> GitWorktreeMergePreview {
        let session = try worktreeMergeSession(sessionID: sessionID)
        let sourceBinding = try WorktreeMergeSourceBindingResolver.resolve(
            bindings: session.worktreeBindings,
            repoRoot: repoRoot
        )
        let source = try await worktreeMergeEndpoint(from: sourceBinding)
        let targetEndpoint = try await resolveWorktreeMergeTargetEndpoint(
            selector: target,
            source: source
        )
        let directory = workspaceDirectory
            ?? workspaceManager?.activeWorkspace?.customStoragePath
            ?? FileManager.default.temporaryDirectory
        let preview = try await VCSService.shared.previewGitWorktreeMerge(.init(
            source: source,
            target: targetEndpoint,
            workspaceDirectory: directory,
            contextLines: contextLines,
            detectRenames: detectRenames,
            publishArtifacts: publishArtifacts,
            tabID: session.tabID,
            graphLimit: graphLimit
        ))
        upsertWorktreeMergeOperation(
            AgentWorktreeMergeCoordinator.makeOperation(preview: preview),
            in: session
        )
        return preview
    }

    func requestWorktreeMergeReviewAndApply(
        preview: GitWorktreeMergePreview,
        sessionID: UUID,
        timeoutSeconds: TimeInterval = MCPTimeoutPolicy.worktreeMergeApprovalTimeoutSeconds,
        commitMessage: String? = nil
    ) async throws -> GitWorktreeMergeApplyResult {
        let session = try worktreeMergeSession(sessionID: sessionID)
        let decision = await requestWorktreeMergeReview(
            preview: preview,
            session: session,
            timeoutSeconds: timeoutSeconds
        )
        guard decision == .accept else {
            let reason = decision.cancelledReason ?? "Worktree merge review was rejected."
            markWorktreeMergeOperationCancelled(operationID: preview.operationID, session: session, reason: reason)
            throw MCPError.invalidParams(reason)
        }

        try updateWorktreeMergeOperation(operationID: preview.operationID, in: session) { operation in
            operation.status = .applying
            operation.lastError = nil
        }
        do {
            let result = try await VCSService.shared.applyGitWorktreeMerge(.init(
                preview: preview,
                commitMessage: commitMessage
            ))
            applyWorktreeMergeResult(result, operationID: preview.operationID, session: session)
            if result.status == .completed || result.status == .conflicted || result.status == .noOp {
                await refreshAfterWorktreeMergeMutation(session: session, target: result.target)
            }
            return result
        } catch {
            markWorktreeMergeOperationFailed(operationID: preview.operationID, session: session, error: error)
            await refreshAfterWorktreeMergeMutation(session: session, target: preview.inspection.target)
            throw error
        }
    }

    func requestWorktreeMergeReviewAndApply(
        sessionID: UUID,
        operationID: String,
        timeoutSeconds: TimeInterval = MCPTimeoutPolicy.worktreeMergeApprovalTimeoutSeconds,
        commitMessage: String? = nil
    ) async throws -> GitWorktreeMergeApplyResult {
        let session = try worktreeMergeSession(sessionID: sessionID)
        let operation = try worktreeMergeOperation(operationID: operationID, in: session)
        guard operation.status == .previewed else {
            throw MCPError.invalidParams("apply is only valid for a previewed worktree merge operation.")
        }
        let preview = try await worktreeMergePreview(from: operation)
        return try await requestWorktreeMergeReviewAndApply(
            preview: preview,
            sessionID: sessionID,
            timeoutSeconds: timeoutSeconds,
            commitMessage: commitMessage
        )
    }

    func applyConfirmedWorktreeMerge(
        sessionID: UUID,
        operationID: String,
        commitMessage: String? = nil
    ) async throws -> GitWorktreeMergeApplyResult {
        let session = try worktreeMergeSession(sessionID: sessionID)
        let operation = try worktreeMergeOperation(operationID: operationID, in: session)
        guard operation.status == .previewed else {
            throw MCPError.invalidParams("apply is only valid for a previewed worktree merge operation.")
        }
        let preview = try await worktreeMergePreview(from: operation)
        try updateWorktreeMergeOperation(operationID: operationID, in: session) { pending in
            pending.status = .applying
            pending.lastError = nil
        }
        do {
            let result = try await VCSService.shared.applyGitWorktreeMerge(.init(
                preview: preview,
                commitMessage: commitMessage
            ))
            applyWorktreeMergeResult(result, operationID: operationID, session: session)
            if result.status == .completed || result.status == .conflicted || result.status == .noOp {
                await refreshAfterWorktreeMergeMutation(session: session, target: result.target)
            }
            return result
        } catch {
            markWorktreeMergeOperationFailed(operationID: operationID, session: session, error: error)
            await refreshAfterWorktreeMergeMutation(session: session, target: operation.target)
            throw error
        }
    }

    func statusWorktreeMerge(
        sessionID: UUID,
        operationID: String?
    ) throws -> AgentSessionWorktreeMergeOperation {
        let session = try worktreeMergeSession(sessionID: sessionID)
        if let operationID, !operationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try worktreeMergeOperation(operationID: operationID, in: session)
        }
        let active = session.worktreeMergeOperations.filter { !$0.status.isTerminal }
        if active.count == 1 { return active[0] }
        if active.isEmpty {
            throw MCPError.invalidParams("operation_id is required because this session has no active worktree merge operation.")
        }
        throw MCPError.invalidParams("operation_id is required because multiple active worktree merge operations exist: \(active.map(\.id).joined(separator: ", "))")
    }

    func continueWorktreeMerge(
        sessionID: UUID,
        operationID: String,
        confirmed: Bool = true,
        commitMessage: String? = nil
    ) async throws -> GitWorktreeMergeApplyResult {
        guard confirmed else { throw MCPError.invalidParams("continue requires confirmation.") }
        let session = try worktreeMergeSession(sessionID: sessionID)
        let operation = try worktreeMergeOperation(operationID: operationID, in: session)
        guard operation.status == .conflicted || operation.status == .awaitingCommit else {
            throw MCPError.invalidParams("continue is only valid for a conflicted or awaiting_commit worktree merge operation.")
        }
        try updateWorktreeMergeOperation(operationID: operationID, in: session) { pending in
            pending.status = .applying
            pending.lastError = nil
        }
        do {
            let result = try await VCSService.shared.continueGitWorktreeMerge(.init(
                source: operation.source,
                target: operation.target,
                sourceHead: operation.sourceHead,
                targetHeadBefore: operation.targetHeadBefore,
                commitMessage: commitMessage
            ))
            applyWorktreeMergeResult(result, operationID: operationID, session: session)
            if result.status == .completed || result.status == .noOp {
                await refreshAfterWorktreeMergeMutation(session: session, target: result.target)
            }
            return result
        } catch {
            markWorktreeMergeOperationFailed(operationID: operationID, session: session, error: error)
            await refreshAfterWorktreeMergeMutation(session: session, target: operation.target)
            throw error
        }
    }

    func abortWorktreeMerge(
        sessionID: UUID,
        operationID: String,
        confirmed: Bool = true
    ) async throws -> GitWorktreeMergeAbortResult {
        guard confirmed else { throw MCPError.invalidParams("abort requires confirmation.") }
        let session = try worktreeMergeSession(sessionID: sessionID)
        let operation = try worktreeMergeOperation(operationID: operationID, in: session)
        guard operation.status == .conflicted || operation.status == .awaitingCommit || operation.status == .applying else {
            throw MCPError.invalidParams("abort is only valid for an active worktree merge operation.")
        }
        do {
            let result = try await VCSService.shared.abortGitWorktreeMerge(.init(target: operation.target))
            try updateWorktreeMergeOperation(operationID: operationID, in: session) { pending in
                AgentWorktreeMergeCoordinator.abort(result: result, operation: &pending)
            }
            await refreshAfterWorktreeMergeMutation(session: session, target: operation.target)
            return result
        } catch {
            try? updateWorktreeMergeOperation(operationID: operationID, in: session) { pending in
                pending.lastError = "Abort failed: \(error.localizedDescription)"
            }
            await refreshAfterWorktreeMergeMutation(session: session, target: operation.target)
            throw error
        }
    }

    func submitWorktreeMergeReviewDecision(
        tabID: UUID,
        reviewID: UUID,
        decision: WorktreeMergeReviewDecision
    ) {
        guard let session = sessions[tabID],
              session.pendingWorktreeMergeReview?.id == reviewID,
              let continuation = session.worktreeMergeReviewContinuation
        else { return }
        finishPendingWorktreeMergeReview(session: session)
        continuation.resume(returning: decision)
    }

    func pendingWorktreeMergeReview(for tabID: UUID?) -> PendingWorktreeMergeReview? {
        guard let tabID, let session = sessions[tabID] else { return nil }
        return session.uiPendingWorktreeMergeReview
    }

    /// Returns the most-recent active worktree merge operation in
    /// `.conflicted` or `.awaitingCommit` state for the given tab, used by the
    /// Agent Mode blocker stack to surface the conflict/awaiting-commit card.
    /// Returns `nil` when no such operation exists.
    func activeWorktreeMergeConflictOperation(for tabID: UUID?) -> AgentSessionWorktreeMergeOperation? {
        guard let tabID, let session = sessions[tabID] else { return nil }
        return AgentWorktreeMergeBlockerSelector.activeConflictOperation(
            in: session.worktreeMergeOperations
        )
    }

    func cancelPendingWorktreeMergeReview(for session: TabSession, reason: String) {
        let operationID = session.pendingWorktreeMergeReview?.operationID
        guard let continuation = session.worktreeMergeReviewContinuation else {
            finishPendingWorktreeMergeReview(session: session)
            if let operationID {
                markWorktreeMergeOperationCancelled(operationID: operationID, session: session, reason: reason)
            }
            return
        }
        finishPendingWorktreeMergeReview(session: session)
        if let operationID {
            markWorktreeMergeOperationCancelled(operationID: operationID, session: session, reason: reason)
        }
        continuation.resume(returning: .cancelled(reason: reason))
    }

    private func requestWorktreeMergeReview(
        preview: GitWorktreeMergePreview,
        session: TabSession,
        timeoutSeconds: TimeInterval
    ) async -> WorktreeMergeReviewDecision {
        cancelPendingWorktreeMergeReview(for: session, reason: "Replaced by newer worktree merge review")
        let review = PendingWorktreeMergeReview(
            scope: WorktreeMergeReviewScope(windowID: 0, tabID: session.tabID),
            preview: preview
        )
        upsertWorktreeMergeOperation(
            AgentWorktreeMergeCoordinator.makeOperation(preview: preview, status: .awaitingApproval),
            in: session
        )
        session.pendingWorktreeMergeReview = review
        reconcileInteractiveRunState(session)
        requestUIRefresh(tabID: session.tabID, urgent: true)

        return await withCheckedContinuation { continuation in
            guard session.worktreeMergeReviewContinuation == nil else {
                continuation.resume(returning: .cancelled(reason: "A worktree merge review is already pending."))
                return
            }
            session.worktreeMergeReviewContinuation = continuation
            if timeoutSeconds > 0 {
                session.worktreeMergeReviewTimeoutTask = Task { @MainActor [weak self, weak session] in
                    do {
                        try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    } catch {
                        return
                    }
                    guard let self, let session, session.pendingWorktreeMergeReview?.id == review.id else { return }
                    submitWorktreeMergeReviewDecision(
                        tabID: session.tabID,
                        reviewID: review.id,
                        decision: .timeout
                    )
                }
            }
        }
    }

    private func finishPendingWorktreeMergeReview(session: TabSession) {
        session.worktreeMergeReviewTimeoutTask?.cancel()
        session.worktreeMergeReviewTimeoutTask = nil
        session.worktreeMergeReviewContinuation = nil
        session.pendingWorktreeMergeReview = nil
        reconcileInteractiveRunState(session)
        requestUIRefresh(tabID: session.tabID, urgent: true)
    }

    private func worktreeMergePreview(from operation: AgentSessionWorktreeMergeOperation) async throws -> GitWorktreeMergePreview {
        guard let sourceFingerprint = operation.sourceFingerprint,
              let targetFingerprint = operation.targetFingerprint
        else {
            throw MCPError.invalidParams("Worktree merge preview fingerprints are unavailable; run manage_worktree preview again.")
        }
        let current = try await VCSService.shared.inspectGitWorktreeMerge(.init(
            source: operation.source,
            target: operation.target
        ))
        let inspection = GitWorktreeMergeInspection(
            source: operation.source,
            target: operation.target,
            mergeBase: operation.mergeBase,
            sourceHead: operation.sourceHead,
            targetHead: operation.targetHeadBefore,
            sourceFingerprint: sourceFingerprint,
            targetFingerprint: targetFingerprint,
            blockers: current.blockers,
            conflictPrediction: current.conflictPrediction,
            summary: operation.summary ?? current.summary,
            visualization: operation.visualization ?? current.visualization
        )
        return GitWorktreeMergePreview(
            operationID: operation.id,
            inspection: inspection,
            artifacts: operation.previewArtifacts
        )
    }

    private func worktreeMergeSession(sessionID: UUID) throws -> TabSession {
        guard let session = try authoritativeLiveSession(for: sessionID) else {
            throw MCPError.invalidParams("The requested agent session is not currently available.")
        }
        return session
    }

    private func worktreeMergeOperation(
        operationID: String,
        in session: TabSession
    ) throws -> AgentSessionWorktreeMergeOperation {
        guard let operation = session.worktreeMergeOperations.first(where: { $0.id == operationID }) else {
            throw MCPError.invalidParams("Unknown worktree merge operation_id: \(operationID)")
        }
        return operation
    }

    private func updateWorktreeMergeOperation(
        operationID: String,
        in session: TabSession,
        mutate: (inout AgentSessionWorktreeMergeOperation) -> Void
    ) throws {
        try AgentWorktreeMergeCoordinator.update(
            operationID: operationID,
            in: &session.worktreeMergeOperations,
            mutate: mutate
        )
        persistWorktreeMergeOperationsChange(in: session)
    }

    private func upsertWorktreeMergeOperation(
        _ operation: AgentSessionWorktreeMergeOperation,
        in session: TabSession
    ) {
        AgentWorktreeMergeCoordinator.upsert(operation, in: &session.worktreeMergeOperations)
        persistWorktreeMergeOperationsChange(in: session)
    }

    private func applyWorktreeMergeResult(
        _ result: GitWorktreeMergeApplyResult,
        operationID: String,
        session: TabSession
    ) {
        try? updateWorktreeMergeOperation(operationID: operationID, in: session) { operation in
            AgentWorktreeMergeCoordinator.apply(result: result, to: &operation)
        }
    }

    private func markWorktreeMergeOperationCancelled(
        operationID: String,
        session: TabSession,
        reason: String
    ) {
        try? updateWorktreeMergeOperation(operationID: operationID, in: session) { operation in
            operation.status = .cancelled
            operation.completedAt = Date()
            operation.lastError = reason
        }
    }

    private func markWorktreeMergeOperationFailed(
        operationID: String,
        session: TabSession,
        error: Error
    ) {
        try? updateWorktreeMergeOperation(operationID: operationID, in: session) { operation in
            operation.status = .failed
            operation.completedAt = Date()
            operation.lastError = error.localizedDescription
        }
    }

    private func persistWorktreeMergeOperationsChange(in session: TabSession) {
        session.isDirty = true
        updateWorktreeMergeSummariesInIndex(for: session)
        syncSidebarUIState(refresh: true, reason: .metadataUpdated)
        // Surface conflict/awaiting-commit attention in the blocker stack and
        // workspace-root capsules whenever the persisted merge state changes.
        if session.tabID == currentTabID {
            syncRunInteractionUIState()
        }
        publishMCPStateChange(for: session)
        updateBindingsFromSession(session)
        scheduleSave(for: session.tabID)
    }

    private func worktreeMergeEndpoint(from binding: AgentSessionWorktreeBinding) async throws -> GitWorktreeMergeEndpoint {
        if let head = binding.head, !head.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try WorktreeMergeSourceBindingResolver.endpoint(from: binding)
        }
        let descriptors = try await VCSService.shared.listGitWorktrees(at: URL(fileURLWithPath: binding.worktreeRootPath))
        guard let descriptor = descriptors.first(where: { $0.worktreeID == binding.worktreeID || samePath($0.path, binding.worktreeRootPath) }) else {
            throw MCPError.invalidParams("Source worktree binding is no longer available: \(binding.worktreeRootPath)")
        }
        return try GitWorktreeMergeEndpoint(descriptor: descriptor)
    }

    private func resolveWorktreeMergeTargetEndpoint(
        selector: String?,
        source: GitWorktreeMergeEndpoint
    ) async throws -> GitWorktreeMergeEndpoint {
        let resolver = GitRepoTargetResolver()
        let sourceRepo = GitRepoDescriptor(rootURL: source.url)
        do {
            let descriptor = try await resolver.resolveWorktree(
                selector: selector ?? "@main",
                repo: sourceRepo,
                allRepos: [sourceRepo]
            )
            return try GitWorktreeMergeEndpoint(descriptor: descriptor)
        } catch let error as GitRepoTargetResolverError {
            throw MCPError.invalidParams(error.message)
        }
    }

    private func refreshAfterWorktreeMergeMutation(
        session: TabSession,
        target: GitWorktreeMergeEndpoint
    ) async {
        await VCSService.shared.invalidateCache(for: target.url)
        if let store = promptManager?.workspaceFileContextStore {
            _ = await store.awaitAppliedIngressForExplicitRequest(
                userPath: target.path,
                fallbackScope: .allLoaded
            )
        }
        updateWorktreeMergeSummariesInIndex(for: session)
        syncSidebarUIState(refresh: true, reason: .metadataUpdated)
        requestUIRefresh(tabID: session.tabID, urgent: true)
        publishMCPStateChange(for: session)
    }

    private func samePath(_ lhs: String, _ rhs: String) -> Bool {
        ((lhs as NSString).expandingTildeInPath as NSString).standardizingPath
            == ((rhs as NSString).expandingTildeInPath as NSString).standardizingPath
    }
}
