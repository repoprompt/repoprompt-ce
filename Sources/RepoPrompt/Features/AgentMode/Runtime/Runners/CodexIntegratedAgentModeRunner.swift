import Foundation

@MainActor
final class CodexIntegratedAgentModeRunner {
    private let mcpServerEnabler: AgentRunExecutionContracts.MCPServerEnabler
    private let codexCoordinator: CodexAgentModeCoordinator
    private let hooks: AgentModeRunService.Hooks

    init(
        mcpServerEnabler: @escaping AgentRunExecutionContracts.MCPServerEnabler,
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
        origin: AgentSessionRuntimeStore.Command,
        providerLaunchInput: AgentProviderLaunchInput? = nil,
        initialMessageForRun: String,
        attachments: [AgentFileAttachment],
        fallbackContext: AgentTabSession.CodexFallbackSubmissionContext?,
        autoEffortSelection: AutoEffortTurnSelection? = nil,
        selfCompactDispatchID: AgentSelfCompactionDispatchID? = nil,
        stopFence: AgentRunStartStopFence? = nil
    ) async -> CodexAgentModeCoordinator.NativeSendOutcome {
        guard case .restored = origin.requirement, origin.writer.session === session, origin.isCurrent,
              providerLaunchInput?.isCurrent(for: session) != false,
              let receipt = AgentSessionRuntimeStore.WriterReceipt(origin)
        else { return .stale(reason: "The originating Codex startup writer or attempt changed.") }
        let dedicatedNoteID = selfCompactDispatchID.flatMap { $0.stage == .note ? $0 : nil }
        var handedToRunTask = false
        defer {
            if let dedicatedNoteID, !handedToRunTask, receipt.disposition(for: session) != .claimLost {
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
        let isPeriodic = session.oversight.pendingAutoWake?.isPeriodic == true

        let sendTask = Task<CodexAgentModeCoordinator.NativeSendOutcome, Never> { [weak self, weak session, hooks] in
            guard let session else { return .cancelled }
            defer {
                if let dedicatedNoteID, receipt.disposition(for: session) != .claimLost,
                   Self.ownsActiveOrTerminalAttempt(session, ownership: ownership)
                {
                    AgentSelfCompactParkedPrefix.reparkUnattemptedDedicatedNote(dedicatedNoteID, session: session) {
                        hooks.persistence.scheduleSave(session)
                    }
                }
            }
            guard let self else { return .cancelled }
            #if DEBUG || EDIT_FLOW_PERF
                let codexTurnMCPServerEnableState = EditFlowPerf.begin(EditFlowPerf.Stage.MCPWindowToolCatalog.codexTurnMCPServerEnable)
            #endif
            let mayPrepare = receipt.disposition(for: session) == .current
                && providerLaunchInput?.isCurrent(for: session) != false
                && session.activeRunOwnership == ownership && !Task.isCancelled
                && (stopFence?.permitsStart(of: session) ?? true)
            var mcpServerReady = false
            if mayPrepare { mcpServerReady = await mcpServerEnabler() }
            #if DEBUG || EDIT_FLOW_PERF
                EditFlowPerf.end(EditFlowPerf.Stage.MCPWindowToolCatalog.codexTurnMCPServerEnable, codexTurnMCPServerEnableState)
            #endif
            guard receipt.disposition(for: session) != .claimLost else { return .stale(reason: "The originating Codex startup writer or attempt changed.") }
            guard session.activeRunOwnership == ownership else {
                if Task.isCancelled, session.activeRunOwnership == nil,
                   session.lastTerminalCommitRevision?.ownership == ownership { return .cancelled }
                return .stale(reason: "The originating Codex startup writer or attempt changed.")
            }
            // An actual Stop owns terminal settlement. Do not end its still-active attempt while
            // its barrier may be suspended. Retiring admission alone is a local startup refusal.
            guard !Task.isCancelled, stopFence?.permitsStart(of: session) ?? true else { return .cancelled }
            var coordinatorEntered = false
            let execution = await CodexIntegratedRunExecutionAdapter.execute {
                // The adapter preserves MainActor isolation. Recheck at the actual coordinator entry;
                // a terminal receipt is cleanup authority, never permission to start another send.
                guard receipt.disposition(for: session) != .claimLost,
                      session.activeRunOwnership == ownership else { return .stale(reason: "The originating Codex startup writer or attempt changed.") }
                guard receipt.disposition(for: session) == .current,
                      providerLaunchInput?.isCurrent(for: session) != false else { return .cancelled }
                guard mcpServerReady else {
                    return .failed(message: "MCP catalog registration failed before Agent launch.")
                }
                coordinatorEntered = true
                let outcome = await self.codexCoordinator.sendCodexNativeMessage(
                    session: session,
                    writerReceipt: receipt,
                    ownership: ownership,
                    text: initialMessageForRun,
                    attachments: attachments,
                    fallbackContext: fallbackContext,
                    stopFence: stopFence,
                    attachmentReservationID: attachmentReservationID,
                    terminalizeRejectedSend: createdOwnership,
                    autoEffortSelection: autoEffortSelection,
                    selfCompactDispatchID: selfCompactDispatchID,
                    providerLaunchInput: providerLaunchInput
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
            // Preserve the transport outcome, but never publish it or retire an attempt through a
            // replacement writer. Coordinator-internal awaits remain a separate routing boundary.
            guard receipt.disposition(for: session) != .claimLost,
                  Self.ownsActiveOrTerminalAttempt(session, ownership: ownership) else { return outcome }
            if !coordinatorEntered, session.activeRunOwnership == ownership {
                if let reservationID = attachmentReservationID,
                   case let .reserved(storedID, _) = session.attachmentTurnState, storedID == reservationID
                {
                    hooks.attachments.finalizeAttachmentsForTurn(session, reservationID, .restoreToPending)
                }
                if let dedicatedNoteID, receipt.disposition(for: session) != .claimLost,
                   session.activeRunOwnership == ownership
                {
                    AgentSelfCompactParkedPrefix.reparkUnattemptedDedicatedNote(dedicatedNoteID, session: session) {
                        hooks.persistence.scheduleSave(session)
                    }
                }
            }
            guard receipt.disposition(for: session) != .claimLost,
                  Self.ownsActiveOrTerminalAttempt(session, ownership: ownership) else { return outcome }
            if !isPeriodic, selfCompactDispatchID == nil {
                hooks.providerInput.recordPendingHandoffSendOutcome(session, outcome.didSend)
            }
            guard receipt.disposition(for: session) != .claimLost,
                  session.activeRunOwnership == ownership else { return outcome }
            if execution.didStartProviderRun {
                session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .running)
            } else if createdOwnership, execution.shouldReleaseCreatedOwnership {
                if let dedicatedNoteID {
                    AgentSelfCompactParkedPrefix.reparkUnattemptedDedicatedNote(dedicatedNoteID, session: session) {
                        hooks.persistence.scheduleSave(session)
                    }
                }
                guard receipt.disposition(for: session) != .claimLost,
                      session.activeRunOwnership == ownership else { return outcome }
                let source = receipt.disposition(for: session) == .ownedSuspended ? "codex.startSuspended" : (mcpServerReady ? "codex.sendRejected" : "codex.mcpBootstrapRejected")
                session.endRunAttempt(ifCurrent: ownership, source: source)
            }
            return outcome
        }
        handedToRunTask = true
        let wrapper = Task {
            await withTaskCancellationHandler {
                _ = await sendTask.value
            } onCancel: {
                sendTask.cancel()
            }
        }
        session.agentTask = wrapper
        let outcome = await sendTask.value
        // Clear only the slot installed by this invocation. A successor may have replaced it while
        // MCP preparation or the coordinator was suspended; the task retains only a weak receipt.
        if session.agentTask == wrapper, receipt.disposition(for: session) != .claimLost {
            session.agentTask = nil
        }
        return outcome
    }

    private static func ownsActiveOrTerminalAttempt(_ session: AgentTabSession, ownership: AgentRunOwnership) -> Bool {
        session.activeRunOwnership == ownership
            || (session.activeRunOwnership == nil && session.lastTerminalCommitRevision?.ownership == ownership)
    }
}
