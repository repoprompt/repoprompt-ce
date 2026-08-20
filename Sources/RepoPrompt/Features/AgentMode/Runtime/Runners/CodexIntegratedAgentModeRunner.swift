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
        fallbackContext: AgentTabSession.CodexFallbackSubmissionContext?
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
        let attachmentReservationID = hooks.attachments.reserveAttachmentsForTurn(attachments, session)

        let sendTask = Task<CodexAgentModeCoordinator.NativeSendOutcome, Never> { [weak self, weak session] in
            guard let self, let session else {
                return .cancelled
            }
            defer { session.agentTask = nil }
            #if DEBUG || EDIT_FLOW_PERF
                let codexTurnMCPServerEnableState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPWindowToolCatalog.codexTurnMCPServerEnable)
            #endif
            let mcpServerReady = await mcpServerEnabler()
            #if DEBUG || EDIT_FLOW_PERF
                EditFlowPerf.end(EditFlowPerf.Stage.MCPWindowToolCatalog.codexTurnMCPServerEnable, codexTurnMCPServerEnableState)
            #endif
            let execution = await CodexIntegratedRunExecutionAdapter.execute {
                guard mcpServerReady else {
                    return .failed(message: "MCP catalog registration failed before Agent launch.")
                }
                let outcome = await self.codexCoordinator.sendCodexNativeMessage(
                    session: session,
                    text: initialMessageForRun,
                    attachments: attachments,
                    fallbackContext: fallbackContext,
                    attachmentReservationID: attachmentReservationID,
                    terminalizeRejectedSend: createdOwnership
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
            hooks.providerInput.recordPendingHandoffSendOutcome(session, outcome.didSend)
            if execution.didStartProviderRun {
                session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .running)
            } else if createdOwnership, execution.shouldReleaseCreatedOwnership {
                let source = mcpServerReady ? "codex.sendRejected" : "codex.mcpBootstrapRejected"
                session.endRunAttempt(ifCurrent: ownership, source: source)
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
