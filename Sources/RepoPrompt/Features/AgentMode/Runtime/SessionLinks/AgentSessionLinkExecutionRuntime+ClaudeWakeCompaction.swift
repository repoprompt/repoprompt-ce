import Foundation
import RepoPromptSettingsCore

extension AgentSessionLinkExecutionRuntime {
    enum ClaudeWakePreparation {
        case unchanged
        case recheckAfterCompaction
        case withholdWake
    }

    /// Maintenance runs inside the existing wake producer, before any prompt claim exists. It
    /// cannot acknowledge or replay a lane update, and has no timer or separate wake reservation.
    func agentSessionLinkPrepareClaudeWake(
        _ attempt: AgentSessionLinkAutoWakeAttempt, session: TabSession
    ) async -> ClaudeWakePreparation {
        let endpoint = attempt.observerEndpoint
        guard !attempt.isManual, isIdleForClaudeWakeCompact(session),
              !session.pendingHandoff.hasPayload, session.pendingHandoff.providerSwitchDelivery == nil,
              session.selfCompactState.parkedNote == nil,
              let pressure = ClaudeWakeContextPressure.current(for: session),
              pressure.isHigh(thresholdPercent: GlobalSettingsStore.shared.claudeWakeCompactionThresholdPercent()),
              let conversation = session.providerSessionID,
              session.claudeWakeCompactionSpentConversation != conversation,
              let controller = session.claudeController,
              let binding = session.persistentSessionBindingIdentity,
              let command = admit(endpoint: endpoint), command.writer.session === session,
              let target = makeComposerSubmitTarget(tabID: endpoint.tabID, session: session),
              target.expectedSourceAgentSessionID == endpoint.sessionID
        else { return .unchanged }
        guard !attempt.isPeriodic || agentSessionLinkPeriodicWakeIsEligible(session, endpoint: endpoint) else { return .unchanged }
        let submission = AgentComposerSubmitAttempt(
            id: UUID(), target: target, inputRevision: 0, noticeRevision: 0, rawDraftSnapshot: ""
        )
        guard let claim = claimComposerSubmitAttempt(submission) else { return .unchanged }
        let admission = ClaudeWakeCompactionAdmission(
            wakeID: attempt.wakeID, composerAttemptID: submission.id,
            controllerID: ObjectIdentifier(controller as AnyObject), model: session.selectedModelRaw,
            pressure: pressure, boundaryID: session.claudeCompactBoundaryID,
            stopFence: attempt.stopFence ?? AgentRunStartStopFence(session: session),
            wakeIsStillEligible: { [weak self, weak session] in
                guard let self, let session, let current = session.oversight.pendingAutoWake else { return false }
                return agentSessionLinkAutoWakeAttemptIsStillEligible(current, session: session)
            }
        )
        guard admission.isCurrent(for: session) else {
            releaseComposerSubmitClaim(claim)
            return .withholdWake
        }
        // Reserve durably before any provider write. A refused/ambiguous start is intentionally
        // conservative: relaunch or a changed wake fingerprint cannot grant a second attempt.
        session.claudeWakeCompactionSpentConversation = conversation
        // The native leaf also checks this composer claim after its controller hop. Keep it until
        // the exact run has drained; returning from startAgentRun only installs the producer.
        defer { releaseComposerSubmitClaim(claim) }
        let recorder = AgentRunStartOutcomeRecorder()
        let didStart = await startDurablyReservedClaudeWakeCompact(
            command: command, claim: claim, admission: admission, binding: binding,
            conversation: conversation, attempt: attempt, recorder: recorder
        )
        guard didStart, let task = recorder.claudeWakeCompactionTask else { return .withholdWake }
        await task.value
        guard recorder.claudeWakeCompactionVerified,
              !Task.isCancelled, command.isCurrent, admission.stopFence.permitsStart(of: session),
              session.oversight.pendingAutoWake?.wakeID == attempt.wakeID,
              session.providerSessionID == conversation,
              session.claudeController.map({ ObjectIdentifier($0 as AnyObject) }) == admission.controllerID,
              session.selectedModelRaw == admission.model,
              ClaudeWakeContextPressure.current(for: session)?.isHigh(
                  thresholdPercent: GlobalSettingsStore.shared.claudeWakeCompactionThresholdPercent()
              ) != true
        else { return .withholdWake }
        // No input was delivered under this wake. Re-enter admission from scratch so revocation,
        // attention selection, snoozes, and membership changes are treated normally.
        return .recheckAfterCompaction
    }

    private func startDurablyReservedClaudeWakeCompact(
        command: AgentSessionRuntimeStore.Command, claim: AgentComposerSubmitClaim,
        admission: ClaudeWakeCompactionAdmission, binding: AgentPersistentSessionBindingIdentity,
        conversation: String, attempt: AgentSessionLinkAutoWakeAttempt,
        recorder: AgentRunStartOutcomeRecorder
    ) async -> Bool {
        let writer = command.writer
        let session = writer.session
        guard case .success = await writer.scope.persistence.flushSaveRequired(writer: writer),
              command.isCurrent, composerSubmitClaimIsCurrent(claim), admission.isCurrent(for: session),
              agentSessionLinkAutoWakeAttemptIsStillEligible(attempt, session: session),
              isIdleForClaudeWakeCompact(session, ignoringOwnComposerClaim: true)
        else { return false }
        let native = AgentProviderControlCommand.compact(
            expectedBinding: binding, expectedProviderConversation: conversation, claudeWakeCompaction: admission
        )
        _ = await startAgentRun(
            command: command, initialMessage: native.providerText,
            directStartOptions: .providerControl(native), startOutcome: recorder, providerSwitchPreparation: nil
        )
        return recorder.outcome.didStart
    }

    private func isIdleForClaudeWakeCompact(_ session: TabSession, ignoringOwnComposerClaim: Bool = false) -> Bool {
        guard session.runState == .completed, agentSessionLinkPeriodicPreparationIsUnblocked(session),
              !agentSelfCompactHoldsWakeAcquisition(session) else { return false }
        var readiness = Self.agentSessionLinkDeliveryReadinessSnapshot(
            session: session, endpointMatchesGrant: true, isClosing: false,
            ignoresComposerSubmissionInFlight: ignoringOwnComposerClaim
        )
        readiness.pendingOversightAutoWake = false // This producer owns that exact reservation.
        return AgentSessionLinkDeliveryReadiness.evaluate(snapshot: readiness).isReady
    }
}
