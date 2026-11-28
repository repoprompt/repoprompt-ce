import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime

/// Owns resume-recovery staging and ordinary handoff consumption. Workspace context is supplied
/// as a value by the host; neither a presentation nor its lifetime is delivery authority.
@MainActor
final class AgentSessionHandoffRuntime {
    enum RecoveryResult {
        case unchanged, staged(AgentPendingHandoffState), refused

        var permitsFreshSession: Bool {
            if case .refused = self { return false }
            return true
        }
    }

    @MainActor
    struct RecoveryPreparation {
        fileprivate let scope: AgentSessionRuntimeStore.Scope
        fileprivate let session: AgentTabSession
        fileprivate let binding: AgentPersistentSessionBindingIdentity?
        fileprivate let transitionGeneration: UInt64
        fileprivate let stopFence: AgentRunStartStopFence
        fileprivate let runID: UUID?
        fileprivate let ownership: AgentRunOwnership?
        fileprivate let agent: AgentProviderKind
        fileprivate let handoffRevision: UInt64
        fileprivate let sourceTabName: String
        fileprivate let sourceItemID: UUID?
        fileprivate let transcriptXML: String
    }

    struct ProviderSwitchMutation {
        enum Phase { case preparing, detached, staged }
        let id: UUID
        let tabID: UUID
        let writer: AgentSessionRuntimeStore.WriterIdentity
        let previewID: UUID
        let saveGenerationAtEntry: UInt64
        var phase: Phase = .preparing

        var allowsSave: Bool {
            phase == .staged
        }
    }

    private(set) var providerSwitchMutation: ProviderSwitchMutation?

    func beginProviderSwitchMutation(
        command: AgentSessionRuntimeStore.Command, previewID: UUID
    ) -> ProviderSwitchMutation? {
        guard providerSwitchMutation == nil, command.writer.scope === scope, command.isCurrent else { return nil }
        let session = command.writer.session
        let mutation = ProviderSwitchMutation(
            id: UUID(), tabID: session.tabID, writer: command.identity,
            previewID: previewID, saveGenerationAtEntry: session.saveRequestGeneration
        )
        providerSwitchMutation = mutation
        return mutation
    }

    @discardableResult
    func updateProviderSwitchMutation(_ id: UUID, phase: ProviderSwitchMutation.Phase) -> Bool {
        guard let scope, let mutation = providerSwitchMutation, mutation.id == id,
              let session = scope.sessions[mutation.tabID],
              scope.originatingWriter(identity: mutation.writer, session: session)?.isCurrent == true
        else { return false }
        providerSwitchMutation?.phase = phase
        return true
    }

    func endProviderSwitchMutation(_ id: UUID) {
        guard let mutation = providerSwitchMutation, mutation.id == id else { return }
        providerSwitchMutation = nil
        if !mutation.allowsSave, let scope, let session = scope.sessions[mutation.tabID],
           scope.originatingWriter(identity: mutation.writer, session: session)?.isCurrent == true,
           session.saveRequestGeneration != mutation.saveGenerationAtEntry, session.isDirty
        {
            scope.persistence.scheduleSave(for: session)
        }
    }

    func providerSwitchBlocksSave(for session: AgentTabSession) -> Bool {
        guard let mutation = providerSwitchMutation,
              mutation.tabID == session.tabID, !mutation.allowsSave else { return false }
        return scope?.originatingWriter(identity: mutation.writer, session: session)?.isCurrent == true
    }

    struct ProviderSwitchSummary {
        enum Outcome {
            case generated(String, sourceRevision: Int)
            case unavailable(String)
        }

        let requestRowID: UUID
        let destination: AgentProviderKind
        let model: String
        let outcome: Outcome?
    }

    private struct SummaryGeneration {
        let writer: AgentSessionRuntimeStore.WriterIdentity
        let sourceAgent: AgentProviderKind
        var sourceModel: String
        let sourceReasoningEffort: String?
        let sourceClaudeEffort: String?
        let sourceParameters: [ACPModelParameterSelection]
        let sourceInstructions: [String]
        let context: ProviderSwitchSummaryContext?
        let handoffRevision: UInt64
        let rowID: UUID
        let destination: AgentProviderKind
        let model: String
        var outcome: ProviderSwitchSummary.Outcome?

        var projection: ProviderSwitchSummary {
            .init(requestRowID: rowID, destination: destination, model: model, outcome: outcome)
        }
    }

    private var summaryBySessionID: [UUID: SummaryGeneration] = [:]

    struct ProviderSwitchSummaryContext: Equatable {
        let interviewPreference: Bool
        let includeCleanupGuidance: Bool
        let computerUseArmed: Bool
        let images: [AgentFileAttachment]
        let taggedFiles: [AgentTaggedFileAttachment]
    }

    struct ProviderSwitchSummaryRequest {
        let rowID: UUID
        let destination: AgentProviderKind
        let model: String
        let wordLimit: Int
        let stopFence: AgentRunStartStopFence
        var context: ProviderSwitchSummaryContext?
    }

    enum ProviderSwitchSummaryStart {
        case started
        case refused
        case failed(String)
    }

    /// Generate through the exact source writer. The request row, startup save and provider
    /// launch belong to this runtime even if the originating sheet is dismissed.
    func generateProviderSwitchSummary(
        _ request: ProviderSwitchSummaryRequest, command: AgentSessionRuntimeStore.Command,
        existingClaim: AgentSessionComposerSubmitClaim? = nil,
        testGenerate: (@MainActor (AgentTabSession, UUID, String) async -> Void)? = nil,
        testStart: (@MainActor (AgentTabSession, String, AgentRunStartOutcomeRecorder) async -> Void)? = nil
    ) async -> ProviderSwitchSummaryStart {
        guard let owner = scope, command.writer.scope === owner, command.isCurrent,
              let links = owner.linkExecution,
              let text = AgentProviderHandover.summaryRequest(wordLimit: request.wordLimit)
        else { return .refused }
        let session = command.writer.session
        let claim: AgentSessionComposerSubmitClaim
        if let existingClaim {
            guard owner.submissions.isCurrent(existingClaim), existingClaim.command?.identity == command.identity
            else { return .refused }
            claim = existingClaim
        } else {
            guard let target = owner.submissions.programmaticTarget(command),
                  case let .claimed(admitted) = owner.submissions.claim(
                      .init(id: UUID(), target: target, inputRevision: 0, noticeRevision: 0, rawDraftSnapshot: ""),
                      command: command, allowsPendingStartWithdrawal: false
                  ) else { return .refused }
            claim = admitted
        }
        defer { if existingClaim == nil { owner.submissions.release(claim) } }
        guard request.stopFence.permitsStart(of: session), !session.items.contains(where: { $0.id == request.rowID }),
              registerProviderSwitchSummary(
                  command: command, request: request, links: links
              )
        else { return .refused }
        let row = AgentChatItem(id: request.rowID, kind: .user, text: text, sequenceIndex: session.nextSequenceIndex)
        session.appendItem(row)
        session.isDirty = true
        let work = links.retainInputEffect(session: session, owner: owner) { [self] () -> ProviderSwitchSummaryStart in
            guard case .success = await owner.persistence.flushSaveRequired(writer: command.writer),
                  command.isCurrent, request.stopFence.permitsStart(of: session),
                  providerSwitchSummary(for: session)?.requestRowID == request.rowID
            else {
                let message = AgentSessionLinkSendFailure.persistenceIndeterminate.message
                failProviderSwitchSummary(session, rowID: request.rowID, message: message)
                return .failed(message)
            }
            if let testGenerate {
                await testGenerate(session, request.rowID, text)
                settleProviderSwitchSummary(session)
                return .started
            }
            let recorder = AgentRunStartOutcomeRecorder()
            if let testStart {
                await testStart(session, text, recorder)
            } else {
                _ = await links.startAgentRun(
                    command: command, initialMessage: text,
                    directStartOptions: .init(ignoresPendingHandoff: true, stopFence: request.stopFence, initialUserItemID: request.rowID),
                    startOutcome: recorder, providerSwitchPreparation: nil
                )
            }
            guard recorder.outcome.didStart else {
                let message = AgentSessionLinkSendFailure.targetNotIdle.message
                failProviderSwitchSummary(session, rowID: request.rowID, message: message)
                return .failed(message)
            }
            session.clearAgentSessionLinkWaitingOnAfterAcceptedTurn()
            return .started
        }
        return await work.value
    }

    private func registerProviderSwitchSummary(
        command: AgentSessionRuntimeStore.Command, request: ProviderSwitchSummaryRequest,
        links: AgentSessionLinkExecutionRuntime
    ) -> Bool {
        guard command.writer.scope === scope, command.isCurrent,
              providerSwitchTransitionAdmission(command.writer.session, ownsComposerClaim: true).isAdmissible(forcing: false)
        else { return false }
        let session = command.writer.session
        if let current = currentSummaryGeneration(for: session), current.outcome == nil { return false }
        summaryBySessionID[command.identity.sessionID] = .init(
            writer: command.identity, sourceAgent: session.selectedAgent, sourceModel: session.selectedModelRaw,
            sourceReasoningEffort: session.selectedReasoningEffortRaw, sourceClaudeEffort: session.selectedClaudeEffortRaw,
            sourceParameters: session.acpModelParameterSelections,
            sourceInstructions: links.providerSwitchInstructionStrings(session, destination: request.destination, includeOwedContent: false),
            context: request.context, handoffRevision: session.pendingHandoffRevision,
            rowID: request.rowID, destination: request.destination, model: request.model
        )
        return true
    }

    func providerSwitchSummary(for session: AgentTabSession) -> ProviderSwitchSummary? {
        currentSummaryGeneration(for: session)?.projection
    }

    /// A later presenter can render a completed result when the source configuration and
    /// request context still match. Draft and workflow edits are measured when the carrier fits.
    func reusableProviderSwitchSummary(
        for session: AgentTabSession, context: ProviderSwitchSummaryContext
    ) -> ProviderSwitchSummary? {
        guard let generation = currentSummaryGeneration(for: session),
              generation.context == context,
              generation.sourceReasoningEffort == session.selectedReasoningEffortRaw,
              generation.sourceClaudeEffort == session.selectedClaudeEffortRaw,
              generation.sourceParameters == session.acpModelParameterSelections,
              let links = scope?.linkExecution,
              generation.sourceInstructions == links.providerSwitchInstructionStrings(
                  session, destination: generation.destination, includeOwedContent: false
              ) else { return nil }
        return generation.projection
    }

    /// ACP can resolve the default model while starting the Summary's original provider
    /// attempt. Carry that runtime transition forward under the existing writer and row.
    func providerSwitchSummaryResolvedSourceModel(
        _ session: AgentTabSession, rowID: UUID, previousModel: String, ownership: AgentRunOwnership
    ) {
        guard session.isCurrentRunAttemptForCurrentBinding(ownership),
              let generation = currentSummaryGeneration(for: session, expectedSourceModel: previousModel),
              generation.rowID == rowID, generation.outcome == nil
        else { return }
        summaryBySessionID[generation.writer.sessionID]?.sourceModel = session.selectedModelRaw
    }

    private func failProviderSwitchSummary(_ session: AgentTabSession, rowID: UUID, message: String) {
        guard let generation = currentSummaryGeneration(for: session), generation.rowID == rowID,
              generation.outcome == nil else { return }
        recordProviderSwitchSummary(.unavailable(message), generation: generation, session: session)
    }

    /// Terminal events settle the original generation even when the session has no presentation.
    func settleProviderSwitchSummary(_ session: AgentTabSession) {
        guard let generation = currentSummaryGeneration(for: session), generation.outcome == nil else { return }
        AgentSessionTranscriptRefreshRuntime.refreshDerivedTranscriptState(for: session)
        guard let turn = session.transcript.turns.first(where: { $0.request?.id == generation.rowID }),
              turn.completedAt != nil, !(turn.terminalState?.isActive ?? false) else { return }
        let conclusion = turn.allActivities.first { $0.id == turn.conclusionActivityID }?.text
        let outcome: ProviderSwitchSummary.Outcome = if !AgentProviderHandover.isZeroEffectfulToolControlTurn(turn) {
            .unavailable("the model used tools")
        } else if turn.terminalState == .completed, let conclusion, !conclusion.isEmpty {
            .generated(conclusion, sourceRevision: session.sourceItemsRevision)
        } else {
            .unavailable(session.items.last(where: { $0.kind == .error })?.text ?? AgentSessionLinkSendFailure.targetNotIdle.message)
        }
        recordProviderSwitchSummary(outcome, generation: generation, session: session)
    }

    private func recordProviderSwitchSummary(
        _ outcome: ProviderSwitchSummary.Outcome, generation: SummaryGeneration, session: AgentTabSession
    ) {
        guard currentSummaryGeneration(for: session)?.rowID == generation.rowID else { return }
        summaryBySessionID[generation.writer.sessionID]?.outcome = outcome
        scope?.presentation.providerSwitchSummaryChanged(session)
    }

    private func currentSummaryGeneration(
        for session: AgentTabSession, expectedSourceModel: String? = nil
    ) -> SummaryGeneration? {
        guard let scope, let id = session.activeAgentSessionID, let generation = summaryBySessionID[id],
              session.selectedAgent == generation.sourceAgent,
              (expectedSourceModel ?? session.selectedModelRaw) == generation.sourceModel,
              session.pendingHandoffRevision == generation.handoffRevision,
              let writer = scope.originatingWriter(identity: generation.writer, session: session), writer.isCurrent
        else { return nil }
        return generation
    }

    private weak var scope: AgentSessionRuntimeStore.Scope?

    init(scope: AgentSessionRuntimeStore.Scope) {
        self.scope = scope
    }

    /// Capture before the host awaits context IO. The preparation retains the originating scope,
    /// not a window, and may only commit back to this exact object and unchanged incarnation.
    func prepareRecovery(
        for session: AgentTabSession,
        sourceTabName: String,
        transcriptXML: @autoclosure () -> String
    ) -> RecoveryPreparation? {
        guard let scope, !Task.isCancelled, !scope.isRetiring,
              scope.sessions[session.tabID] === session, !session.bindingTransitionInProgress,
              session.pendingHandoff.providerSwitchDelivery == nil,
              session.oversight.pendingAutoWake?.isPeriodic != true,
              session.pendingHandoff.payload?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        else { return nil }
        return RecoveryPreparation(
            scope: scope, session: session,
            binding: session.persistentSessionBindingIdentity,
            transitionGeneration: session.bindingTransitionGeneration,
            stopFence: .init(session: session), runID: session.runID,
            ownership: session.activeRunOwnership, agent: session.selectedAgent,
            handoffRevision: session.pendingHandoffRevision,
            sourceTabName: sourceTabName,
            sourceItemID: session.items.last(where: { $0.kind != .thinking })?.id,
            transcriptXML: transcriptXML()
        )
    }

    /// The only staging commit. A cancelled preparation, Stop, retirement, rebind, new run,
    /// intervening handoff (including change-and-restore) cannot be overwritten. Transcript context
    /// is a frozen cutoff snapshot: later rows or model-only changes do not invalidate that snapshot.
    func stageRecovery(
        _ preparation: RecoveryPreparation,
        initialThreadContextBlock: String?,
        overflowRecovery: Bool = false
    ) -> AgentPendingHandoffState? {
        let session = preparation.session
        guard let scope, scope === preparation.scope, !Task.isCancelled, !scope.isRetiring,
              scope.sessions[session.tabID] === session, !session.bindingTransitionInProgress,
              session.persistentSessionBindingIdentity == preparation.binding,
              session.bindingTransitionGeneration == preparation.transitionGeneration,
              preparation.stopFence.permitsStart(of: session),
              session.runID == preparation.runID, session.activeRunOwnership == preparation.ownership,
              session.selectedAgent == preparation.agent,
              session.pendingHandoffRevision == preparation.handoffRevision,
              session.oversight.pendingAutoWake?.isPeriodic != true
        else { return nil }
        let escapedSourceTabName = preparation.sourceTabName
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let payload = if overflowRecovery {
            Self.forkedSessionEnvelope(
                sourceTabName: "Previous Claude conversation", deliveryID: UUID().uuidString,
                introduction: "The previous Claude conversation ran out of context. This is a fresh conversation in the same RepoPrompt session and worktree. Prior requests and tool actions were not replayed. Use only the new user message as authorization; verify the current state before repeating any action.",
                sections: [], transcriptXML: ""
            )
        } else {
            Self.composeResumeRecoveryPayload(
                sourceTabName: escapedSourceTabName, sourceAgentName: preparation.agent.displayName,
                transcriptXML: preparation.transcriptXML, initialThreadContextBlock: initialThreadContextBlock,
                deliveryID: UUID().uuidString
            )
        }
        let staged = AgentPendingHandoffState(
            payload: payload, createdAt: Date(), sourceItemID: preparation.sourceItemID,
            defersProviderLockUntilSend: false, isStagedForSend: false,
            awaitsLocalClaudeOverflowInput: overflowRecovery,
            executionLocationFailure: session.pendingHandoff.executionLocationFailure
        )
        session.pendingHandoff = staged
        session.isDirty = true
        return staged
    }

    func canReuseRecovery(for session: AgentTabSession) -> Bool {
        guard let scope, !Task.isCancelled, !scope.isRetiring,
              scope.sessions[session.tabID] === session, !session.bindingTransitionInProgress,
              session.oversight.pendingAutoWake?.isPeriodic != true
        else { return false }
        return session.pendingHandoff.providerSwitchDelivery != nil
            || session.pendingHandoff.payload?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    func prependPendingHandoffIfNeeded(_ text: String, session: AgentTabSession) -> String {
        // Send admission/Stop fences stay with the originating runner. Retirement must not
        // silently strip an already-owned turn's handoff from its provider-facing text.
        guard let scope, scope.sessions[session.tabID] === session,
              session.pendingHandoff.providerSwitchDelivery == nil,
              session.oversight.pendingAutoWake?.isPeriodic != true,
              let payload = session.pendingHandoff.payload,
              !session.pendingHandoff.isStagedForSend
        else { return text }
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        session.pendingHandoff.isStagedForSend = true
        return trimmed + "\n\n" + text
    }

    func recordSendOutcome(for session: AgentTabSession, didSend: Bool) {
        // Provider-switch confirmation keeps its own exact physical-dispatch authority.
        guard let scope, scope.sessions[session.tabID] === session,
              session.pendingHandoff.providerSwitchDelivery == nil,
              session.oversight.pendingAutoWake?.isPeriodic != true,
              session.pendingHandoff.isStagedForSend
        else { return }
        if didSend {
            session.pendingHandoff.clearAfterSend()
            session.isDirty = true
            scope.persistence.scheduleSave(for: session)
        } else {
            session.pendingHandoff.isStagedForSend = false
        }
    }

    /// Switch admission separates hard blockers (integrity or a real pending handover) from
    /// forceable causes (the source session's own live state, which a confirmed Stop may end).
    /// Derived from existing state only; nothing here is persisted.
    enum ProviderSwitchAdmission: Equatable {
        enum ForceableCause: Equatable {
            case running
            case waitingForInput
            case compaction
            case finishingTurn
            case sessionTransfer
            case stopping
            case workInFlight

            func message(provider: String) -> String {
                switch self {
                case .running: "\(provider) is still working on its last turn."
                case .waitingForInput: "\(provider) is waiting for your input."
                case .compaction: "\(provider) is still finishing a compaction."
                case .finishingTurn: "\(provider) is still finishing its last turn."
                case .sessionTransfer: "\(provider) is still finishing a session transfer."
                case .stopping: "\(provider) is stopping."
                case .workInFlight: "\(provider) still has work in flight."
                }
            }
        }

        case clear
        case hard(String)
        case forceable(ForceableCause)

        func message(provider: String) -> String? {
            switch self {
            case .clear: nil
            case let .hard(message): message
            case let .forceable(cause): cause.message(provider: provider)
            }
        }

        func isAdmissible(forcing: Bool) -> Bool {
            switch self {
            case .clear: true
            case .hard: false
            case .forceable: forcing
            }
        }
    }

    /// Item 3's transition admission reads existing owners, ignoring only its own exact
    /// claim/slot. Every integrity guard evaluates before any source live-state classification;
    /// `.forceable` means the local sheet may offer the confirmed stop-and-switch gesture.
    /// No saved idle bit, waiting worker, binding transition or provider action is introduced here.
    func providerSwitchTransitionAdmission(
        _ session: AgentTabSession, ownsComposerClaim: Bool = false, resolvingHandoff: AgentPendingHandoffState? = nil
    ) -> ProviderSwitchAdmission {
        guard let scope, scope.sessions[session.tabID] === session,
              let host = scope.executableHost, let execution = scope.execution
        else {
            return .hard(AgentSessionLinkSendFailure.endpointInvalidated.message)
        }
        // Every integrity guard is evaluated before any source-liveness classification, so a
        // force can never run its quiesce while a protected state holds.
        // A worktree relocation mutates bindings, not provider state; it stays uninterruptible.
        if session.pendingSelfWorktreeRelocation != nil {
            return .hard("changing_execution_location")
        }
        var snapshot = AgentSessionLinkExecutionRuntime.agentSessionLinkDeliveryReadinessSnapshot(
            session: session, endpointMatchesGrant: true, isClosing: false,
            ignoresComposerSubmissionInFlight: ownsComposerClaim
        )
        if let resolvingHandoff, session.pendingHandoff == resolvingHandoff {
            snapshot.providerSwitchUnconfirmed = false
            snapshot.providerHandoverNeedsReview = false
        }
        let evaluation = AgentSessionLinkDeliveryReadiness.evaluate(snapshot: snapshot)
        if case let .blocked(reason) = evaluation {
            switch reason {
            case .targetNotIdle:
                break
            case .providerSwitchUnconfirmed, .providerHandoverNeedsReview,
                 .endpointInvalidated, .targetLoading, .targetRestoreUnavailable,
                 .targetCreationIncomplete:
                return .hard(AgentSessionLinkSendFailure(reason).message)
            }
        }
        // An execution-location or initial-worktree mutation in flight stays hard like the
        // relocation gate above; it must precede every live-state classification.
        if snapshot.isChangingExecutionLocation || snapshot.isPreparingInitialWorktree {
            return .hard(AgentSessionLinkSendFailure.targetNotIdle.message)
        }
        if session.pendingHandoff.hasPayload, session.pendingHandoff.providerSwitchDelivery == nil,
           !providerSwitchCanReplaceResumeRecovery(session)
        {
            return .hard(AgentSessionLinkSendFailure.targetBusy.message)
        }
        // A latched compact failure is integrity state (a failed required save or an unconfirmed
        // delivery), not live work — it stays hard. Only a compact still in flight is forceable.
        if session.selfCompactState.latest?.outcome == .recoveryRequired
            || session.selfCompactState.latest?.outcome == .deliveryUnknown
            || session.selfCompactState.latest?.noteDelivery == .deliveryUnknown
        {
            return .hard("pending_self_compact")
        }
        if host.claudeCoordinator.hasPendingResumeTransfer(for: session) { return .forceable(.sessionTransfer) }
        if session.selfCompactState.active != nil { return .forceable(.compaction) }
        if case .blocked(.targetNotIdle) = evaluation {
            if snapshot.hasWaitingPrompt || snapshot.hasPendingAskUser || snapshot.hasPendingUserInputRequest
                || snapshot.hasPendingApproval || snapshot.hasPendingPermissionsRequest
                || snapshot.hasPendingMCPElicitationRequest || snapshot.hasPendingApplyEditsReview
                || snapshot.hasPendingWorktreeMergeReview
            {
                return .forceable(.waitingForInput)
            }
            if snapshot.stopInProgress { return .forceable(.stopping) }
            if snapshot.pendingSelfCompact || snapshot.backgroundCompactionSettling { return .forceable(.compaction) }
            if snapshot.terminalCommitInProgress { return .forceable(.finishingTurn) }
            if snapshot.runStateIsActive { return .forceable(.running) }
            return .forceable(.workInFlight)
        }
        if !execution.providerSwitchTerminalIsSettled(session) { return .forceable(.finishingTurn) }
        return .clear
    }

    /// Recognize only the existing app-authored recovery shape. Fork/unknown legacy slots remain
    /// protected. Item 3 may replace this slot through its ordinary claimed Review/apply transaction.
    private func providerSwitchCanReplaceResumeRecovery(_ session: AgentTabSession) -> Bool {
        guard session.pendingHandoff.providerSwitchDelivery == nil,
              !session.pendingHandoff.defersProviderLockUntilSend,
              let payload = session.pendingHandoff.payload else { return false }
        let lines = payload.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, first.hasPrefix("<forked_session source=\""),
              first.contains("\" delivery_id=\""), first.hasSuffix("\">"), lines.count > 2,
              lines[1].hasPrefix("You are continuing a session that was restarted after a native resume failed for "),
              lines[1].hasSuffix(". Use the recovered transcript below, plus any preserved thread context, to continue seamlessly."),
              lines.last == "</forked_session>" else { return false }
        return true
    }

    nonisolated static func composeResumeRecoveryPayload(
        sourceTabName: String,
        sourceAgentName: String,
        transcriptXML: String,
        initialThreadContextBlock: String?,
        deliveryID: String
    ) -> String {
        let trimmedTranscriptXML = transcriptXML.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInitialThreadContextBlock = initialThreadContextBlock?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var payloadSections: [String] = []
        if let trimmedInitialThreadContextBlock,
           !trimmedInitialThreadContextBlock.isEmpty
        {
            payloadSections.append(
                """
                <original_thread_context>
                \(trimmedInitialThreadContextBlock)
                </original_thread_context>
                """
            )
        }
        return Self.forkedSessionEnvelope(
            sourceTabName: sourceTabName, deliveryID: deliveryID,
            introduction: "You are continuing a session that was restarted after a native resume failed for \(sourceAgentName). Use the recovered transcript below, plus any preserved thread context, to continue seamlessly.",
            sections: payloadSections, transcriptXML: trimmedTranscriptXML
        )
    }

    nonisolated static func forkedSessionEnvelope(
        sourceTabName: String, deliveryID: String, introduction: String,
        sections: [String], transcriptXML: String
    ) -> String {
        var sections = sections
        if !transcriptXML.isEmpty { sections.append(transcriptXML) }
        let payloadBody = sections.joined(separator: "\n\n")
        return """
        <forked_session source="\(sourceTabName)" delivery_id="\(deliveryID)">
        \(introduction)

        \(payloadBody)
        </forked_session>
        """
    }
}
