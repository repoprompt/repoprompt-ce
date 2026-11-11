import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptShared
import RepoPromptVCS
import RepoPromptWorkspaceContext

extension AgentSessionWorktreeRuntime {
    /// Acknowledges effects without substituting a later occupant of the originating session.
    struct PartialMerge: LocalizedError {
        let writer: AgentSessionRuntimeStore.WriterIdentity
        let operationID: String?
        let targetPath: String?
        let physicalAttemptAdmitted: Bool
        let operationRecorded: Bool
        let requiredSaveAcknowledged: Bool
        let preview: GitWorktreeMergePreview?
        let applyResult: GitWorktreeMergeApplyResult?
        let abortResult: GitWorktreeMergeAbortResult?
        let abortCompleted: Bool?
        let artifactDirectory: URL?
        let detail: String

        var errorDescription: String? {
            "Worktree merge \(operationID ?? "preview") for session \(writer.sessionID): physical attempt admitted=\(physicalAttemptAdmitted), operation recorded=\(operationRecorded), required save acknowledged=\(requiredSaveAcknowledged). \(detail) Artifacts: \(artifactDirectory?.path ?? "none acknowledged"). Inspect the operation and target \(targetPath ?? "workspace") before retrying."
        }
    }

    @MainActor
    private final class MergeCommand {
        let admission: Admission
        let controller: DomainMutationCommitController?
        let revalidateAuthority: (@MainActor () async throws -> Void)?
        var expectedOperation: AgentSessionWorktreeMergeOperation?
        var recorded = false
        var saved = false
        var physicalAttemptAdmitted = false
        var artifactDirectory: URL?
        var preview: GitWorktreeMergePreview?
        var applyResult: GitWorktreeMergeApplyResult?
        var abortResult: GitWorktreeMergeAbortResult?

        init(_ admission: Admission, revalidateAuthority: (@MainActor () async throws -> Void)?) {
            self.admission = admission
            controller = MCPDomainMutationCommitContext.controller
            self.revalidateAuthority = revalidateAuthority
        }

        func requireCurrent() throws {
            try admission.requireCurrent()
            if let expectedOperation {
                guard admission.session.worktreeMergeOperations.first(where: { $0.id == expectedOperation.id }) == expectedOperation else {
                    throw TransitionError.stale
                }
            }
        }

        func authorize() async throws {
            try requireCurrent()
            try await revalidateAuthority?()
            try requireCurrent()
        }

        func beforeFirstEffect() async throws {
            try await authorize()
            try await controller?.willCommit()
            try await authorize()
        }

        func beforePhysicalAttempt() async throws {
            try await authorize()
            // This acknowledges admission, not proof that a process subsequently spawned or wrote.
            physicalAttemptAdmitted = true
        }

        var canRecordOrigin: Bool {
            let admission = admission
            guard admission.command.writer.isCurrent, admission.resources.isCurrent(),
                  admission.session.worktreeBindings == admission.bindings else { return false }
            guard let expectedOperation else { return true }
            return admission.session.worktreeMergeOperations.first(where: { $0.id == expectedOperation.id }) == expectedOperation
        }

        func partial(_ error: Error) -> PartialMerge {
            PartialMerge(
                writer: admission.command.identity,
                operationID: expectedOperation?.id ?? preview?.operationID,
                targetPath: applyResult?.target.path ?? abortResult?.target.path ?? expectedOperation?.target.path ?? preview?.inspection.target.path,
                physicalAttemptAdmitted: physicalAttemptAdmitted, operationRecorded: recorded,
                requiredSaveAcknowledged: saved, preview: preview, applyResult: applyResult,
                abortResult: abortResult,
                abortCompleted: (error as? VCSService.WorktreeMergeAbortCompletionFailure)?.aborted ?? abortResult?.aborted,
                artifactDirectory: artifactDirectory, detail: error.localizedDescription
            )
        }
    }

    private func acquireMerge(_ admission: Admission) throws -> UUID {
        guard admission.command.writer.scope.worktrees === self else { throw TransitionError.stale }
        try admission.requireCurrent()
        let id = admission.command.identity.sessionID
        guard mergeOwners[id] == nil, !admission.session.worktreeBindingTransitionInProgress else {
            throw MCPError.invalidParams("Another execution-location or merge operation is in progress for this session.")
        }
        let token = UUID()
        mergeOwners[id] = token
        return token
    }

    private func releaseMerge(_ admission: Admission, token: UUID) {
        if mergeOwners[admission.command.identity.sessionID] == token {
            mergeOwners[admission.command.identity.sessionID] = nil
        }
    }

    func statusMerge(command: AgentSessionRuntimeStore.Command, operationID: String?) throws -> AgentSessionWorktreeMergeOperation {
        guard command.writer.scope.worktrees === self, command.isCurrent else { throw TransitionError.stale }
        let operations = command.writer.session.worktreeMergeOperations
        if let operationID, !operationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let operation = operations.first(where: { $0.id == operationID }) else {
                throw MCPError.invalidParams("Unknown worktree merge operation_id: \(operationID)")
            }
            return operation
        }
        let active = operations.filter { !$0.status.isTerminal }
        guard active.count == 1 else {
            throw MCPError.invalidParams("operation_id is required unless exactly one active worktree merge operation exists.")
        }
        return active[0]
    }

    private func recordMerge(_ operation: AgentSessionWorktreeMergeOperation, context: MergeCommand) throws {
        guard context.canRecordOrigin else { throw TransitionError.stale }
        let session = context.admission.session
        AgentWorktreeMergeCoordinator.upsert(operation, in: &session.worktreeMergeOperations)
        session.isDirty = true
        context.expectedOperation = operation
        context.recorded = true
        context.saved = false
        let scope = context.admission.command.writer.scope
        scope.presentation.worktreeOperationsChanged(session)
        guard context.canRecordOrigin else { throw TransitionError.stale }
        scope.mcp.handleObservedMCPStateChange(for: session)
        guard context.canRecordOrigin else { throw TransitionError.stale }
        scope.presentation.bindingChanged(session)
    }

    private func saveMerge(_ context: MergeCommand) async throws {
        guard context.canRecordOrigin else { throw TransitionError.stale }
        let command = context.admission.command
        let result = await Task { @MainActor in
            guard context.canRecordOrigin else {
                return Result<Void, AgentSessionPersistenceFailure>.failure(.init(
                    operation: .save, tabID: context.admission.session.tabID,
                    message: "The originating merge writer or workspace changed before persistence."
                ))
            }
            return await command.writer.scope.persistence.flushSaveRequired(writer: command.writer)
        }.value
        switch result {
        case .success:
            context.saved = true
            guard context.canRecordOrigin else { throw TransitionError.stale }
        case let .failure(failure): throw failure
        }
    }

    func previewMerge(
        admission: Admission, repoRoot: String? = nil, target: String? = "@main",
        workspaceDirectory: URL? = nil, contextLines: Int = 3, detectRenames: Bool = false,
        publishArtifacts: Bool = true, graphLimit: Int = 24,
        revalidateAuthority: (@MainActor () async throws -> Void)? = nil
    ) async throws -> GitWorktreeMergePreview {
        let token = try acquireMerge(admission)
        beginPendingOperation()
        defer { endPendingOperation()
            releaseMerge(admission, token: token)
        }
        let context = MergeCommand(admission, revalidateAuthority: revalidateAuthority)
        do {
            let roots = try await mergeAuthorizedRoots(admission)
            let binding = try WorktreeMergeSourceBindingResolver.resolve(bindings: admission.bindings, repoRoot: repoRoot)
            let source = try await mergeEndpoint(from: binding)
            try await requireAuthorizedMergeEndpoint(source, roots: roots, label: "Source")
            let destination = try await resolveMergeTarget(selector: target, source: source, authorizedRoots: roots)
            try await requireAuthorizedMergeEndpoint(destination, roots: roots, label: "Target")
            try await context.authorize()
            let preview = try await VCSService.shared.previewGitWorktreeMerge(.init(
                source: source, target: destination,
                workspaceDirectory: workspaceDirectory ?? admission.resources.storageDirectory ?? FileManager.default.temporaryDirectory,
                contextLines: contextLines, detectRenames: detectRenames, publishArtifacts: publishArtifacts,
                tabID: admission.session.tabID, graphLimit: graphLimit
            ), beforeWrite: { try await context.beforeFirstEffect() })
            context.preview = preview
            if let artifacts = preview.artifacts { context.artifactDirectory = URL(fileURLWithPath: artifacts.manifestPath).deletingLastPathComponent() }
            // Artifact publication may have committed while this command was suspended. Preserve
            // that receipt even when the origin can no longer accept its operation record.
            try await context.beforeFirstEffect()
            let checked = try await revalidatedMergePreview(preview)
            try await context.authorize()
            try recordMerge(AgentWorktreeMergeCoordinator.makeOperation(preview: checked), context: context)
            try await saveMerge(context)
            return checked
        } catch {
            if let partial = error as? GitDiffSnapshotPublisher.PartialPublication {
                context.artifactDirectory = partial.snapshotDirectory
            }
            if context.recorded || context.artifactDirectory != nil { throw context.partial(error) }
            throw error
        }
    }

    func applyMerge(
        admission: Admission, operationID: String, review: Bool,
        timeoutSeconds: TimeInterval = MCPTimeoutPolicy.worktreeMergeApprovalTimeoutSeconds,
        commitMessage: String? = nil, revalidateAuthority: (@MainActor () async throws -> Void)? = nil
    ) async throws -> GitWorktreeMergeApplyResult {
        let token = try acquireMerge(admission)
        defer { releaseMerge(admission, token: token) }
        let context = MergeCommand(admission, revalidateAuthority: revalidateAuthority)
        let operation = try statusMerge(command: admission.command, operationID: operationID)
        guard operation.status == .previewed else { throw MCPError.invalidParams("apply is only valid for a previewed worktree merge operation.") }
        context.expectedOperation = operation
        let preview: GitWorktreeMergePreview
        beginPendingOperation()
        do {
            preview = try await mergePreview(from: operation, admission: admission)
            try await context.authorize()
            if review { try await context.beforeFirstEffect() }
            endPendingOperation()
        } catch {
            endPendingOperation()
            throw error
        }
        if review {
            // The interaction runtime owns the wait/expiry/cancellation. Do not hold a drain count
            // while waiting for a human: teardown must be able to settle this exact interaction.
            guard let interactions = admission.command.writer.scope.installedInteractions else {
                throw MCPError.invalidParams("The worktree merge review owner is unavailable.")
            }
            let decision = try await interactions.requestWorktreeMergeReview(
                command: admission.command, preview: preview, timeoutSeconds: timeoutSeconds
            )
            guard decision == .accept else {
                throw MCPError.invalidParams(decision.cancelledReason ?? "Worktree merge review was rejected.")
            }
            do {
                try admission.requireCurrent()
                let reviewed = try statusMerge(command: admission.command, operationID: operationID)
                guard reviewed.status == .awaitingApproval,
                      reviewed.source == preview.inspection.source, reviewed.target == preview.inspection.target,
                      reviewed.sourceHead == preview.inspection.sourceHead, reviewed.targetHeadBefore == preview.inspection.targetHead,
                      reviewed.sourceFingerprint == preview.inspection.sourceFingerprint,
                      reviewed.targetFingerprint == preview.inspection.targetFingerprint else { throw TransitionError.stale }
                context.expectedOperation = reviewed
                try await context.authorize()
            } catch {
                interactions.recordWorktreeMergeReviewAbandoned(command: admission.command, operationID: operationID, reason: error.localizedDescription)
                throw error
            }
        }
        beginPendingOperation()
        defer { endPendingOperation() }
        return try await mutateMerge(context, kind: .apply(preview), commitMessage: commitMessage).applyValue()
    }

    func continueMerge(
        admission: Admission, operationID: String, commitMessage: String? = nil,
        revalidateAuthority: (@MainActor () async throws -> Void)? = nil
    ) async throws -> GitWorktreeMergeApplyResult {
        let token = try acquireMerge(admission)
        beginPendingOperation()
        defer { endPendingOperation()
            releaseMerge(admission, token: token)
        }
        let context = MergeCommand(admission, revalidateAuthority: revalidateAuthority)
        let operation = try statusMerge(command: admission.command, operationID: operationID)
        guard operation.status == .conflicted || operation.status == .awaitingCommit else {
            throw MCPError.invalidParams("continue is only valid for a conflicted or awaiting_commit worktree merge operation.")
        }
        context.expectedOperation = operation
        return try await mutateMerge(context, kind: .resume, commitMessage: commitMessage).applyValue()
    }

    func abortMerge(
        admission: Admission, operationID: String,
        revalidateAuthority: (@MainActor () async throws -> Void)? = nil
    ) async throws -> GitWorktreeMergeAbortResult {
        let token = try acquireMerge(admission)
        beginPendingOperation()
        defer { endPendingOperation()
            releaseMerge(admission, token: token)
        }
        let context = MergeCommand(admission, revalidateAuthority: revalidateAuthority)
        let operation = try statusMerge(command: admission.command, operationID: operationID)
        guard operation.status == .conflicted || operation.status == .awaitingCommit || operation.status == .applying else {
            throw MCPError.invalidParams("abort is only valid for an active worktree merge operation.")
        }
        context.expectedOperation = operation
        switch try await mutateMerge(context, kind: .abort, commitMessage: nil) {
        case let .abort(result): return result
        case .apply: preconditionFailure("Abort returned an apply result")
        }
    }

    private enum MergeKind { case apply(GitWorktreeMergePreview), resume, abort }
    private enum MergeResult {
        case apply(GitWorktreeMergeApplyResult), abort(GitWorktreeMergeAbortResult)
        func applyValue() -> GitWorktreeMergeApplyResult {
            switch self {
            case let .apply(result): result
            case .abort: preconditionFailure("Apply returned an abort result")
            }
        }
    }

    private func mutateMerge(_ context: MergeCommand, kind: MergeKind, commitMessage: String?) async throws -> MergeResult {
        guard var previous = context.expectedOperation else { throw TransitionError.stale }
        // An accepted review no longer owns a waiter. A refusal before Git must return to an
        // actionable preview, not leave an approval state with nobody able to answer it.
        if previous.status == .awaitingApproval { previous.status = .previewed }
        let admission = context.admission
        do {
            let endpoints = try await checkedMergeEndpoints(source: previous.source, target: previous.target, admission: admission)
            try await context.beforeFirstEffect()
            var intent = previous
            intent.status = .applying
            intent.lastError = nil
            try recordMerge(intent, context: context)
            try await saveMerge(context)
            try await context.authorize()
            let result: MergeResult
            switch kind {
            case let .apply(preview):
                let checked = try await revalidatedMergePreview(preview)
                try await context.authorize()
                let value = try await VCSService.shared.applyGitWorktreeMerge(.init(preview: checked, commitMessage: commitMessage), beforeCommit: {
                    try await context.beforePhysicalAttempt()
                })
                context.applyResult = value
                result = .apply(value)
            case .resume:
                let value = try await VCSService.shared.continueGitWorktreeMerge(.init(
                    source: endpoints.source, target: endpoints.target, sourceHead: previous.sourceHead,
                    targetHeadBefore: previous.targetHeadBefore, commitMessage: commitMessage
                ), beforeCommit: { try await context.beforePhysicalAttempt() })
                context.applyResult = value
                result = .apply(value)
            case .abort:
                let value = try await VCSService.shared.abortGitWorktreeMerge(.init(target: endpoints.target), beforeCommit: {
                    try await context.beforePhysicalAttempt()
                })
                context.abortResult = value
                result = .abort(value)
            }
            // After Git returns, cancellation/revocation cannot erase the effect receipt. Only the
            // original writer/resources may receive bookkeeping, and its save is uncancelled.
            var completed = intent
            switch result {
            case let .apply(value): AgentWorktreeMergeCoordinator.apply(result: value, to: &completed)
            case let .abort(value): AgentWorktreeMergeCoordinator.abort(result: value, operation: &completed)
            }
            try recordMerge(completed, context: context)
            try await saveMerge(context)
            await refreshMergeTarget(previous.target, admission: admission)
            return result
        } catch {
            let acceptedReviewNeedsSettlement = context.expectedOperation?.status == .awaitingApproval
            if context.recorded || acceptedReviewNeedsSettlement, context.canRecordOrigin,
               context.applyResult == nil, context.abortResult == nil
            {
                var recovery = context.physicalAttemptAdmitted ? context.expectedOperation! : previous
                if let abort = error as? VCSService.WorktreeMergeAbortCompletionFailure, abort.aborted {
                    recovery.status = .aborted
                    recovery.completedAt = Date()
                    recovery.conflictFiles = []
                }
                recovery.lastError = error.localizedDescription
                // An admitted attempt with uncertain outcome stays `.applying`, so abort remains
                // available. A refused first process restores the previous actionable state.
                try? recordMerge(recovery, context: context)
                try? await saveMerge(context)
            }
            if context.physicalAttemptAdmitted { await refreshMergeTarget(previous.target, admission: admission) }
            if context.recorded || context.physicalAttemptAdmitted { throw context.partial(error) }
            throw error
        }
    }

    private func refreshMergeTarget(_ target: GitWorktreeMergeEndpoint, admission: Admission) async {
        await VCSService.shared.invalidateCache(for: target.url)
        guard admission.command.writer.isCurrent, admission.resources.isCurrent() else { return }
        if let store = admission.resources.store {
            _ = await store.awaitAppliedIngressForExplicitRequest(userPath: target.path, fallbackScope: .allLoaded)
        }
        guard admission.command.writer.isCurrent, admission.resources.isCurrent() else { return }
        let scope = admission.command.writer.scope
        scope.presentation.worktreeOperationsChanged(admission.session)
        guard admission.command.writer.isCurrent, admission.resources.isCurrent() else { return }
        scope.presentation.makeRunHooks().requestUIRefresh(admission.session, true)
    }
}
