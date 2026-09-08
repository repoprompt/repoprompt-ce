import Foundation
import RepoPromptDomainRuntime

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
        session: AgentTabSession,
        initialUserMessage: String,
        initialMessageForRun: String,
        attachments: [AgentImageAttachment],
        makeLease: (_ runID: UUID) -> MCPBootstrapLease
    ) async {
        let attachmentReservationID = hooks.attachments.reserveAttachmentsForTurn(attachments, session)

        if initialMessageForRun != initialUserMessage,
           !session.pendingNonCodexUserInputTokenQueue.isEmpty
        {
            session.pendingNonCodexUserInputTokenQueue[0] = hooks.usage.estimateRuntimeTokens(initialMessageForRun)
        }
        hooks.usage.startNonCodexTurnAccountingIfNeeded(session, initialMessageForRun)

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
        hooks.presentation.setAgentRunActive(session, true)
        hooks.bindingObservation.updateBindings(session)

        guard session.selectedAgent != .codexExec else {
            await terminalCommitBarrier.commit(.init(
                binding: hooks.bindTerminalSession(session),
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
                    session.clearRunID(ifCurrent: runID)
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
            session.clearRunID(ifCurrent: runID)
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

                // Undecorated: the oversight supplement is attached inside `executeHeadlessRun`,
                // after the lease's provider-initialization hop, because that hop is a suspension
                // during which link membership can change.
                let agentMessage = self.hooks.providerInput.buildHeadlessAgentMessage(
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
        session: AgentTabSession,
        runID: UUID,
        ownership: AgentRunOwnership,
        attachmentReservationID: UUID?
    ) async {
        hooks.providerInput.recordPendingHandoffSendOutcome(session, false)
        await terminalCommitBarrier.commit(.init(
            binding: hooks.bindTerminalSession(session),
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
                session.clearRunID(ifCurrent: runID)
                return nil
            }
        ))
    }

    private func executeHeadlessRun(
        session: AgentTabSession,
        provider: HeadlessAgentProvider,
        initialMessage: AgentMessage,
        runID: UUID,
        runAttemptID: UUID,
        ownership: AgentRunOwnership,
        attachments: [AgentImageAttachment],
        attachmentReservationID: UUID?,
        lease: MCPBootstrapLease
    ) async {
        var providerInitializationCompleted = false
        let report = await DomainAgentRunExecutionCore.execute(
            failureText: { "Agent failed: \($0.localizedDescription)" }
        ) {
            await lease.providerInitializationStarted(provider: session.selectedAgent.rawValue)
            // Composed here, after the lease hop and immediately before stream creation: that hop is
            // a suspension, so reading membership any earlier could dispatch inventory the user has
            // already changed. This is the last point before the provider sees the turn.
            let monitoring = hooks.providerInput.decoratedAgentMessage(
                initialMessage,
                session: session,
                dispatchID: .headlessRun(runID: runID)
            )
            // A dispatch that exists only to carry a lane batch has nothing to say without it, so it
            // is retracted here rather than sent empty. Cancellation is the quiet terminal: no
            // provider call, no error row, and the batch stays owed to a later dispatch.
            guard !monitoring.mustAbortDispatch else {
                hooks.providerInput.recordAgentSessionLinkPhysicalDispatchNotAttempted(
                    session,
                    .headlessRun(runID: runID)
                )
                throw CancellationError()
            }
            guard hooks.providerInput.acquireAgentSessionLinkPhysicalDispatch(
                session,
                .headlessRun(runID: runID)
            ) else {
                hooks.providerInput.recordAgentSessionLinkPhysicalDispatchNotAttempted(
                    session,
                    .headlessRun(runID: runID)
                )
                throw CancellationError()
            }
            let stream = try await provider.streamAgentMessage(monitoring.message, runID: runID)
            // Successful stream creation is the acceptance signal for every headless provider,
            // including Claude headless. A throwing creation leaves the claim pending for the retry.
            if let claim = monitoring.claim { hooks.providerInput.acceptAgentSessionLinkPrompt(claim) }
            providerInitializationCompleted = true
            await lease.providerInitializationCompleted(provider: session.selectedAgent.rawValue, outcome: "ready")
            hooks.providerInput.recordPendingHandoffSendOutcome(session, true)
            hooks.attachments.stageConsumedAttachmentFilesForDeferredCleanup(attachments, session)
            hooks.attachments.markAttachmentsConsumed(session, attachmentReservationID)
            _ = await lease.releaseWhenRouted()
            if let ownership = session.activeRunOwnership, ownership.attemptID == runAttemptID {
                session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .running)
            }

            for try await result in stream {
                guard !Task.isCancelled else { break }
                guard session.isCurrentRunAttempt(ownership, expectedRunID: runID) else {
                    return .superseded
                }
                session.recordRunProgress(ownership: ownership, kind: .providerEvent, stage: .running)
                await hooks.transcript.handleHeadlessStreamResult(result, session, runID, runAttemptID)
            }

            guard session.runID == runID,
                  session.activeRunAttemptID == runAttemptID
            else {
                return .superseded
            }
            return .completed(assistantText: nil)
        }

        guard case let .terminal(outcome) = report.result else { return }
        if !providerInitializationCompleted {
            hooks.providerInput.recordAgentSessionLinkPhysicalDispatchFailure(
                session,
                .headlessRun(runID: runID)
            )
        }
        let terminalState: AgentSessionRunState
        let source: String
        let notifyTurnComplete: Bool
        let errorText: String?
        switch outcome.kind {
        case .completed:
            terminalState = .completed
            source = "headless.completed"
            notifyTurnComplete = true
            errorText = nil
        case .cancelled:
            if !providerInitializationCompleted {
                await lease.providerInitializationCompleted(provider: session.selectedAgent.rawValue, outcome: "cancelled")
            }
            hooks.providerInput.recordPendingHandoffSendOutcome(session, false)
            terminalState = .cancelled
            source = "headless.cancelled"
            notifyTurnComplete = false
            errorText = nil
        case .failed:
            if !providerInitializationCompleted {
                await lease.providerInitializationCompleted(provider: session.selectedAgent.rawValue, outcome: "failed")
            }
            hooks.providerInput.recordPendingHandoffSendOutcome(session, false)
            terminalState = .failed
            source = "headless.failed"
            notifyTurnComplete = false
            errorText = outcome.assistantText
        }

        await terminalCommitBarrier.commit(.init(
            binding: hooks.bindTerminalSession(session),
            ownership: ownership,
            expectedRunID: runID,
            terminalState: terminalState,
            source: source,
            errorText: errorText,
            attachmentReservationID: attachmentReservationID,
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: true,
            supportsFollowUp: false,
            notifyTurnComplete: notifyTurnComplete,
            prepareProviderState: {
                session.provider = nil
                session.clearRunID(ifCurrent: runID)
                return nil
            }
        ))
    }
}
