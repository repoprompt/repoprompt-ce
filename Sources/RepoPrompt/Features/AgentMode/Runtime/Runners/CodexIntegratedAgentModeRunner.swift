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
        session: AgentModeViewModel.TabSession,
        initialMessageForRun: String,
        attachments: [AgentImageAttachment],
        fallbackContext: AgentModeViewModel.TabSession.CodexFallbackSubmissionContext?
    ) async -> CodexAgentModeCoordinator.NativeSendOutcome {
        let ownership: AgentRunOwnership
        let createdOwnership: Bool
        if let activeOwnership = session.activeRunOwnership {
            ownership = activeOwnership
            createdOwnership = false
        } else {
            ownership = session.beginRunAttempt(source: "codex")
            createdOwnership = true
            session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .preparingRuntime)
        }
        let attachmentReservationID = hooks.reserveAttachmentsForTurn(attachments, session)

        let sendTask = Task<CodexAgentModeCoordinator.NativeSendOutcome, Never> { [weak self, weak session] in
            guard let self, let session else {
                return .cancelled
            }
            defer { session.agentTask = nil }
            #if DEBUG || EDIT_FLOW_PERF
                let codexTurnMCPServerEnableState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPWindowToolCatalog.codexTurnMCPServerEnable)
            #endif
            await mcpServerEnabler()
            #if DEBUG || EDIT_FLOW_PERF
                EditFlowPerf.end(EditFlowPerf.Stage.MCPWindowToolCatalog.codexTurnMCPServerEnable, codexTurnMCPServerEnableState)
            #endif

            let outcome = await codexCoordinator.sendCodexNativeMessage(
                session: session,
                text: initialMessageForRun,
                attachments: attachments,
                fallbackContext: fallbackContext,
                attachmentReservationID: attachmentReservationID,
                terminalizeRejectedSend: createdOwnership
            )
            hooks.recordPendingHandoffSendOutcome(session, outcome.didSend)
            switch outcome {
            case .sent:
                session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .running)
            case .cancelled, .failed, .stale:
                if createdOwnership {
                    session.endRunAttempt(ifCurrent: ownership, source: "codex.sendRejected")
                }
            case .queuedFallback:
                break
            }
            return outcome
        }
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
