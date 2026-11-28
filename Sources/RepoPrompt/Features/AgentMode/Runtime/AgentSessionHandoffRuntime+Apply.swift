import Foundation
import RepoPromptAIContracts
import RepoPromptDomainRuntime

extension AgentSessionHandoffRuntime {
    struct ProviderSwitchDestination {
        struct ParameterChange {
            let writes: [ACPModelParameterSelection]
            let selections: [ACPModelParameterSelection]
        }

        let agent: AgentProviderKind
        let model: String
        let payload: String
        let cutoff: UUID?
        let parameters: ParameterChange?
    }

    enum ProviderSwitchCommit {
        case replace(ProviderSwitchDestination)
        case discard
    }

    enum ProviderSwitchCommitResult {
        case applied
        case refused
        case failed(String)
    }

    func detachProviderForSwitch(
        claim: AgentSessionComposerSubmitClaim, mutationID: UUID,
        retirementOverride: (@MainActor (AgentTabSession) async -> Void)?
    ) -> (@MainActor () async -> Void)? {
        guard let command = claim.command, switchWriterIsCurrent(claim, mutationID: mutationID),
              providerSwitchMutation?.phase == .preparing, let host = claim.scope.executableHost,
              updateProviderSwitchMutation(mutationID, phase: .detached)
        else { return nil }
        return host.detachProviderContextForProviderSwitch(command.writer.session, retirementOverride: retirementOverride)
    }

    /// Stage and persist an already-prepared switch against the original writer. An error after
    /// the write boundary leaves the result staged because the write may have taken effect.
    func commitProviderSwitch(
        _ change: ProviderSwitchCommit, claim: AgentSessionComposerSubmitClaim, mutationID: UUID,
        rollback: ProviderSwitchRollback, message: String, reportFailureInTranscript: Bool,
        beforeSave: (@MainActor (AgentTabSession) -> Void)?
    ) async -> ProviderSwitchCommitResult {
        guard let command = claim.command, switchWriterIsCurrent(claim, mutationID: mutationID) else { return .refused }
        let session = command.writer.session
        let owner = command.writer.scope
        guard session.pendingHandoff == rollback.handoff else { return .refused }
        let outcome: String
        switch change {
        case let .replace(destination):
            guard providerSwitchMutation?.phase == .detached,
                  let host = owner.executableHost, let links = owner.linkExecution else { return .refused }
            host.clearProviderContextForProviderSwitch(session)
            session.selectedAgent = destination.agent
            session.selectedModelRaw = destination.model
            if destination.agent.usesClaudeTooling,
               let effort = ClaudeModelSpecifier(raw: destination.model).explicitEffortLevel
            {
                session.selectedClaudeEffortRaw = effort.rawValue
            }
            if destination.agent != rollback.agent || destination.model != rollback.model {
                session.selectedReasoningEffortRaw = nil
            }
            if let parameters = destination.parameters {
                session.recordAcceptedACPModelParameterWrite(parameters.writes)
                session.acpModelParameterSelections = parameters.selections
            }
            session.pendingHandoff = .init(
                payload: destination.payload, createdAt: Date(), sourceItemID: destination.cutoff,
                providerSwitchDelivery: .ready
            )
            links.agentSessionLinkReoweSupplementForRebuiltProviderContext(for: session)
            outcome = "applied"
        case .discard:
            guard providerSwitchMutation?.phase == .preparing, rollback.handoff.providerSwitchDelivery != nil,
                  providerSwitchTransitionAdmission(session, ownsComposerClaim: true, resolvingHandoff: rollback.handoff).isAdmissible(forcing: false)
            else { return .refused }
            session.pendingHandoff.clearAfterSend()
            outcome = "discarded"
        }

        let staged = session.pendingHandoff
        let notice = AgentChatItem.system(
            message, sequenceIndex: session.nextSequenceIndex,
            recoveryDiagnostic: .init(reason: "providerSwitch", outcome: outcome, text: message)
        )
        session.appendItem(notice)
        session.isDirty = true
        _ = updateProviderSwitchMutation(mutationID, phase: .staged)
        owner.presentation.bindingChanged(session)
        beforeSave?(session)
        var phase: AgentSessionRequiredSavePhase = .beforeWrite
        let result = await owner.persistence.flushSaveRequired(writer: command.writer, observingSavePhase: { phase = $0 })
        switch result {
        case .success:
            guard switchWriterIsCurrent(claim, mutationID: mutationID), session.pendingHandoff == staged else { return .refused }
            owner.presentation.bindingChanged(session)
            return .applied
        case let .failure(failure):
            if switchWriterIsCurrent(claim, mutationID: mutationID), session.pendingHandoff == staged {
                if phase == .beforeWrite {
                    rollback.restore(session)
                    removeProviderSwitchNotice(noticeID: notice.id, from: session)
                }
                if reportFailureInTranscript {
                    session.appendItem(.error(failure.message, sequenceIndex: session.nextSequenceIndex))
                }
                owner.presentation.bindingChanged(session)
            }
            return .failed(failure.message)
        }
    }

    private func switchWriterIsCurrent(_ claim: AgentSessionComposerSubmitClaim, mutationID: UUID) -> Bool {
        guard let command = claim.command, let mutation = providerSwitchMutation, mutation.id == mutationID,
              mutation.writer == command.identity, claim.scope.handoff === self,
              claim.scope.submissions.isCurrent(claim), command.isCurrent,
              let host = claim.scope.executableHost else { return false }
        return host.workspaceActivation?.owns(scope: claim.scope, route: host.route) ?? true
    }

    private func removeProviderSwitchNotice(noticeID: UUID, from session: AgentTabSession) {
        if let index = session.items.firstIndex(where: { $0.id == noticeID }) { _ = session.removeItem(at: index) }
        for turn in session.transcript.turns.indices {
            for span in session.transcript.turns[turn].responseSpans.indices {
                session.transcript.turns[turn].responseSpans[span].activities.removeAll { $0.id == noticeID }
            }
            session.transcript.turns[turn].summary?.recoveryDiagnostics?.removeAll { $0.id == noticeID }
        }
        AgentSessionTranscriptRefreshRuntime.refreshDerivedTranscriptState(for: session)
    }

    @MainActor
    struct ProviderSwitchRollback {
        let agent: AgentProviderKind
        let model: String
        let effort: String?
        let claudeEffort: String?
        let parameters: [ACPModelParameterSelection]
        let providerID: String?
        let cleanup: ProviderConversationCleanupHandle?
        let codexID: String?
        let rollout: String?
        let codexInstructionMode: CodexThreadInstructionMode?
        let codexModel: String?
        let codexEffort: String?
        let computerUseActivation: CodexComputerUseActivation?
        // In-flight arming IDs belong to the async arming call, not rollback.
        let context: AgentTabSession.ProviderSwitchContextSnapshot
        let handoff: AgentPendingHandoffState

        init(_ session: AgentTabSession) {
            agent = session.selectedAgent
            model = session.selectedModelRaw
            effort = session.selectedReasoningEffortRaw
            claudeEffort = session.selectedClaudeEffortRaw
            parameters = session.acpModelParameterSelections
            providerID = session.providerSessionID
            cleanup = session.providerCleanupHandle
            codexID = session.codexConversationID
            rollout = session.codexRolloutPath
            codexInstructionMode = session.codexInstructionMode
            codexModel = session.codexModel
            codexEffort = session.codexReasoningEffort
            computerUseActivation = session.pendingCodexComputerUseActivation
            context = session.captureProviderSwitchContext()
            handoff = session.pendingHandoff
        }

        func restore(_ session: AgentTabSession) {
            session.selectedAgent = agent
            session.selectedModelRaw = model
            session.selectedReasoningEffortRaw = effort
            session.selectedClaudeEffortRaw = claudeEffort
            session.acpModelParameterSelections = parameters
            session.providerSessionID = providerID
            session.providerCleanupHandle = cleanup
            session.codexConversationID = codexID
            session.codexRolloutPath = rollout
            session.codexInstructionMode = codexInstructionMode
            session.codexModel = codexModel
            session.codexReasoningEffort = codexEffort
            session.pendingCodexComputerUseActivation = computerUseActivation
            session.restoreProviderSwitchContext(context)
            session.pendingHandoff = handoff
            session.isDirty = true
        }
    }
}

private extension AgentSessionRuntimeHost {
    /// Transfers runtime ownership without suspension. The returned cleanup touches only captured
    /// instances, so a deadline may stop waiting without retiring a same-tab successor.
    func detachProviderContextForProviderSwitch(
        _ session: AgentTabSession, retirementOverride: (@MainActor (AgentTabSession) async -> Void)?
    ) -> (@MainActor () async -> Void) {
        let provider = session.provider
        session.provider = nil
        let acp = session.acpController
        session.acpController = nil
        let codex = codexCoordinator.detachForWorkspaceSwitchFinalizeSync(session, runIDs: [])
        let claude = claudeCoordinator.detachForWorkspaceSwitchFinalizeSync(session)
        let codexCoordinator = codexCoordinator
        let claudeCoordinator = claudeCoordinator
        return {
            if let retirementOverride {
                await retirementOverride(session)
                return
            }
            if let provider {
                await provider.dispose()
            }
            if let acp {
                await acp.cancelPrompt()
                await acp.shutdown()
            }
            if let codex {
                await codexCoordinator.retireDetachedControllerForWorkspaceSwitch(codex)
            }
            if let claude {
                await claudeCoordinator.retireDetachedControllerForWorkspaceSwitch(claude, discardedSession: session)
            }
        }
    }

    func clearProviderContextForProviderSwitch(_ session: AgentTabSession) {
        codexCoordinator.clearCodexSessionState(session)
        claudeCoordinator.rotateClaudeRuntimeEpoch(for: session)
        session.providerSessionID = nil
        session.providerCleanupHandle = nil
        session.contextUsageSnapshot = nil
        session.contextCompactedAt = nil
        session.pendingNonCodexUserInputTokenQueue.removeAll()
        session.activeNonCodexTurnTokenAccumulator = nil
        AgentModeProcessRunIdentity.clearProcessRunID(for: session)
    }
}
