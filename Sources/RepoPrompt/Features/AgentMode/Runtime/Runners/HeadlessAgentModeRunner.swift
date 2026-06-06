import Foundation

@MainActor
final class HeadlessAgentModeRunner {
    private let headlessProviderFactory: AgentModeViewModel.HeadlessProviderFactory
    private let hooks: AgentModeRunService.Hooks
    private let terminalCommitBarrier: AgentRunTerminalCommitBarrier

    init(
        headlessProviderFactory: @escaping AgentModeViewModel.HeadlessProviderFactory,
        hooks: AgentModeRunService.Hooks,
        terminalCommitBarrier: AgentRunTerminalCommitBarrier
    ) {
        self.headlessProviderFactory = headlessProviderFactory
        self.hooks = hooks
        self.terminalCommitBarrier = terminalCommitBarrier
    }

    func startRun(
        tabID: UUID,
        session: AgentModeViewModel.TabSession,
        initialUserMessage: String,
        initialMessageForRun: String,
        attachments: [AgentImageAttachment],
        makeLease: (_ runID: UUID) -> MCPBootstrapLease
    ) async {
        let attachmentReservationID = hooks.reserveAttachmentsForTurn(attachments, session)

        if initialMessageForRun != initialUserMessage,
           !session.pendingNonCodexUserInputTokenQueue.isEmpty
        {
            session.pendingNonCodexUserInputTokenQueue[0] = hooks.estimateRuntimeTokens(initialMessageForRun)
        }
        hooks.startNonCodexTurnAccountingIfNeeded(session, initialMessageForRun)

        let runID = AgentModeProcessRunIdentity.startFreshProcessRun(for: session)
        let lease = makeLease(runID)

        session.activeReasoningItemID = nil
        session.reasoningItemIDsByGroupID.removeAll()
        session.codexReasoningSegmentsByKey.removeAll()

        let ownership = session.beginRunAttempt(source: "headless")
        let runAttemptID = ownership.attemptID
        session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .preparingRuntime)
        session.runningStatusText = nil
        session.runningStatusSource = nil
        session.runState = .running
        hooks.setAgentRunActive(tabID, true)
        hooks.updateBindings(session)

        guard session.selectedAgent != .codexExec else {
            await terminalCommitBarrier.commit(.init(
                session: session,
                ownership: ownership,
                expectedRunID: runID,
                terminalState: .failed,
                source: "headless.invalidRoute",
                errorText: "Internal routing error: Codex native run attempted to use headless provider path.",
                attachmentReservationID: attachmentReservationID,
                attachmentDisposition: .deleteFiles,
                finalizeNonCodexUsage: true,
                supportsFollowUp: false,
                notifyTurnComplete: false,
                prepareProviderState: {
                    session.provider = nil
                    session.runID = nil
                    return nil
                }
            ))
            return
        }

        let provider = headlessProviderFactory(
            session.selectedAgent,
            session.selectedModelRaw == AgentModel.defaultModel.rawValue
                ? nil
                : session.selectedModelRaw
        )
        session.provider = provider
        session.installRunAttemptTerminalResources(ownership: ownership) { terminalState in
            session.provider = nil
            if session.runID == runID {
                session.runID = nil
            }
            return {
                switch terminalState {
                case .failed:
                    await lease.failAndRelease()
                case .cancelled:
                    await lease.cancelAndCleanup()
                default:
                    break
                }
                await provider.dispose()
            }
        }

        session.agentTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            await withTaskCancellationHandler {
                let acquired = await lease.acquire()
                guard acquired else {
                    await self.handleAcquireFailure(
                        session: session,
                        runID: runID,
                        ownership: ownership,
                        attachmentReservationID: attachmentReservationID
                    )
                    return
                }

                let agentMessage = self.hooks.buildHeadlessAgentMessage(
                    session,
                    initialMessageForRun,
                    runID,
                    attachments
                )
                await self.executeHeadlessRun(
                    session: session,
                    provider: provider,
                    initialMessage: agentMessage,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    ownership: ownership,
                    attachments: attachments,
                    attachmentReservationID: attachmentReservationID,
                    lease: lease
                )
            } onCancel: {}
        }
    }

    private func handleAcquireFailure(
        session: AgentModeViewModel.TabSession,
        runID: UUID,
        ownership: AgentRunOwnership,
        attachmentReservationID: UUID?
    ) async {
        hooks.recordPendingHandoffSendOutcome(session, false)
        await terminalCommitBarrier.commit(.init(
            session: session,
            ownership: ownership,
            expectedRunID: runID,
            terminalState: .cancelled,
            source: "headless.acquireFailure",
            attachmentReservationID: attachmentReservationID,
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: true,
            supportsFollowUp: false,
            notifyTurnComplete: false,
            prepareProviderState: {
                session.provider = nil
                session.runID = nil
                return nil
            }
        ))
    }

    private func executeHeadlessRun(
        session: AgentModeViewModel.TabSession,
        provider: HeadlessAgentProvider,
        initialMessage: AgentMessage,
        runID: UUID,
        runAttemptID: UUID,
        ownership: AgentRunOwnership,
        attachments: [AgentImageAttachment],
        attachmentReservationID: UUID?,
        lease: MCPBootstrapLease
    ) async {
        do {
            let stream = try await provider.streamAgentMessage(initialMessage, runID: runID)
            hooks.recordPendingHandoffSendOutcome(session, true)
            hooks.stageConsumedAttachmentFilesForDeferredCleanup(attachments, session)
            hooks.markAttachmentsConsumed(session, attachmentReservationID)
            _ = await lease.releaseWhenRouted()
            if let ownership = session.activeRunOwnership, ownership.attemptID == runAttemptID {
                session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .running)
            }

            for try await result in stream {
                guard !Task.isCancelled else { break }
                guard session.isCurrentRunAttempt(ownership, expectedRunID: runID) else { return }
                session.recordRunProgress(ownership: ownership, kind: .providerEvent, stage: .running)
                await hooks.handleHeadlessStreamResult(result, session, runID, runAttemptID)
            }

            guard session.runID == runID,
                  session.activeRunAttemptID == runAttemptID
            else {
                return
            }

            await terminalCommitBarrier.commit(.init(
                session: session,
                ownership: ownership,
                expectedRunID: runID,
                terminalState: .completed,
                source: "headless.completed",
                attachmentReservationID: attachmentReservationID,
                attachmentDisposition: .deleteFiles,
                finalizeNonCodexUsage: true,
                supportsFollowUp: false,
                notifyTurnComplete: true,
                prepareProviderState: {
                    session.provider = nil
                    session.runID = nil
                    return nil
                }
            ))
        } catch is CancellationError {
            hooks.recordPendingHandoffSendOutcome(session, false)
            await terminalCommitBarrier.commit(.init(
                session: session,
                ownership: ownership,
                expectedRunID: runID,
                terminalState: .cancelled,
                source: "headless.cancelled",
                attachmentReservationID: attachmentReservationID,
                attachmentDisposition: .deleteFiles,
                finalizeNonCodexUsage: true,
                supportsFollowUp: false,
                notifyTurnComplete: false,
                prepareProviderState: {
                    session.provider = nil
                    session.runID = nil
                    return nil
                }
            ))
        } catch {
            hooks.recordPendingHandoffSendOutcome(session, false)
            await terminalCommitBarrier.commit(.init(
                session: session,
                ownership: ownership,
                expectedRunID: runID,
                terminalState: .failed,
                source: "headless.failed",
                errorText: "Agent failed: \(error.localizedDescription)",
                attachmentReservationID: attachmentReservationID,
                attachmentDisposition: .deleteFiles,
                finalizeNonCodexUsage: true,
                supportsFollowUp: false,
                notifyTurnComplete: false,
                prepareProviderState: {
                    session.provider = nil
                    session.runID = nil
                    return nil
                }
            ))
        }
    }
}
