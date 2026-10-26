import Foundation

@MainActor
final class CodexIntegratedAgentModeRunner {
    private let mcpServerEnabler: AgentModeViewModel.MCPServerEnabler
    private let codexCoordinator: CodexAgentModeCoordinator
    private let hooks: AgentModeRunService.Hooks

    init(
        mcpServerEnabler: @escaping AgentModeViewModel.MCPServerEnabler,
        codexCoordinator: CodexAgentModeCoordinator,
        hooks: AgentModeRunService.Hooks
    ) {
        self.mcpServerEnabler = mcpServerEnabler
        self.codexCoordinator = codexCoordinator
        self.hooks = hooks
    }

    func startRun(
        tabID: UUID,
        session: AgentTabSession,
        initialMessageForRun: String,
        attachments: [AgentImageAttachment],
        fallbackContext: AgentTabSession.CodexFallbackSubmissionContext?,
        autoEffortSelection: AutoEffortTurnSelection? = nil,
        selfCompactDispatchID: AgentSelfCompactionDispatchID? = nil,
        stopFence: AgentRunStartStopFence? = nil
    ) async -> CodexAgentModeCoordinator.NativeSendOutcome {
        let dedicatedNoteID = selfCompactDispatchID.flatMap { $0.stage == .note ? $0 : nil }
        var handedToRunTask = false
        defer {
            if let dedicatedNoteID, !handedToRunTask {
                AgentSelfCompactParkedPrefix.reparkUnattemptedDedicatedNote(dedicatedNoteID, session: session) {
                    hooks.persistence.scheduleSave(session)
                }
            }
        }
        guard stopFence?.permitsStart(of: session) ?? true else { return .cancelled }
        let ownership: AgentRunOwnership
        let createdOwnership: Bool
        if let activeOwnership = session.activeRunOwnership {
            ownership = activeOwnership
            createdOwnership = false
        } else {
            guard stopFence?.permitsStart(of: session) ?? true else { return .cancelled }
            ownership = session.beginRunAttempt(source: "codex")
            createdOwnership = true
            session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .preparingRuntime)
        }
        let attachmentReservationID = hooks.attachments.reserveAttachmentsForTurn(attachments, session)

        let sendTask = Task<CodexAgentModeCoordinator.NativeSendOutcome, Never> { [weak self, weak session, hooks] in
            guard let session else { return .cancelled }
            defer {
                if let dedicatedNoteID {
                    AgentSelfCompactParkedPrefix.reparkUnattemptedDedicatedNote(dedicatedNoteID, session: session) {
                        hooks.persistence.scheduleSave(session)
                    }
                }
                session.agentTask = nil
            }
            guard let self else { return .cancelled }
            #if DEBUG || EDIT_FLOW_PERF
                let codexTurnMCPServerEnableState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPWindowToolCatalog.codexTurnMCPServerEnable)
            #endif
            let mcpServerReady = await mcpServerEnabler()
            #if DEBUG || EDIT_FLOW_PERF
                EditFlowPerf.end(EditFlowPerf.Stage.MCPWindowToolCatalog.codexTurnMCPServerEnable, codexTurnMCPServerEnableState)
            #endif
            guard stopFence?.permitsStart(of: session) ?? true else { return .cancelled }
            let isPeriodic = session.oversight.pendingAutoWake?.isPeriodic == true
            let execution = await CodexIntegratedRunExecutionAdapter.execute {
                guard mcpServerReady else {
                    return .failed(message: "MCP catalog registration failed before Agent launch.")
                }
                let outcome = await self.codexCoordinator.sendCodexNativeMessage(
                    session: session,
                    text: initialMessageForRun,
                    attachments: attachments,
                    fallbackContext: fallbackContext,
                    stopFence: stopFence,
                    attachmentReservationID: attachmentReservationID,
                    terminalizeRejectedSend: createdOwnership,
                    autoEffortSelection: autoEffortSelection,
                    selfCompactDispatchID: selfCompactDispatchID
                )
                // Explicit cancellation can terminalize the original run before its
                // suspended send observes CancellationError. Preserve the caller-level
                // cancellation signal when there is no active successor to protect.
                if case .stale = outcome, Task.isCancelled, !session.runState.isActive {
                    return .cancelled
                }
                return outcome
            }
            let outcome = execution.nativeOutcome
            if !isPeriodic, selfCompactDispatchID == nil {
                hooks.providerInput.recordPendingHandoffSendOutcome(session, outcome.didSend)
            }
            if execution.didStartProviderRun {
                session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .running)
            } else if createdOwnership, execution.shouldReleaseCreatedOwnership {
                let source = mcpServerReady ? "codex.sendRejected" : "codex.mcpBootstrapRejected"
                session.endRunAttempt(ifCurrent: ownership, source: source)
            }
            return outcome
        }
        handedToRunTask = true
        session.agentTask = Task {
            await withTaskCancellationHandler {
                _ = await sendTask.value
            } onCancel: {
                sendTask.cancel()
            }
        }
        return await sendTask.value
    }
}
