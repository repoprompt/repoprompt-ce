import Foundation

@MainActor
final class ClaudeIntegratedAgentModeRunner {
    private struct ConsumeEventsOutcome {
        let terminalState: AgentSessionRunState
        let errorText: String?
        let shouldShutdownSession: Bool
    }

    private let claudeCoordinator: ClaudeAgentModeCoordinator
    private let hooks: AgentModeRunService.Hooks

    #if DEBUG
        private func reasoningDebug(_ message: @autoclosure () -> String) {
            guard ClaudeReasoningExtractionFeature.isEnabled else { return }
            let line = "[ClaudeReasoningDebug][Runner] \(message())"
            print(line)
            ClaudeReasoningDebugLog.append(line)
        }
    #else
        private func reasoningDebug(_ message: @autoclosure () -> String) {}
    #endif

    private func reasoningDebugSnippet(_ text: String, limit: Int = 160) -> String {
        text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(limit)
            .description
    }

    init(
        claudeCoordinator: ClaudeAgentModeCoordinator,
        hooks: AgentModeRunService.Hooks
    ) {
        self.claudeCoordinator = claudeCoordinator
        self.hooks = hooks
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
        session.activeReasoningItemID = nil
        session.reasoningItemIDsByGroupID.removeAll()
        session.codexReasoningSegmentsByKey.removeAll()

        let runID = session.claudeController.flatMap { _ in
            AgentModeProcessRunIdentity.existingProcessRunID(for: session)
        } ?? AgentModeProcessRunIdentity.startFreshProcessRun(for: session)
        let lease = makeLease(runID)
        let ownership = session.beginRunAttempt(source: "claudeNative")
        let runAttemptID = ownership.attemptID
        session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .preparingRuntime)
        session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
        session.setRunningStatus("Thinking…", source: .transport)
        session.runState = .running
        session.pendingSupersedingTurnCompletions = 0
        session.claudeSupersedingProtectedTurnIDs.removeAll()
        session.claudeExpectedTurnIDs.removeAll()
        hooks.setAgentRunActive(tabID, true)
        hooks.updateBindings(session)

        session.agentTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            await withTaskCancellationHandler {
                let acquired = await lease.acquire()
                guard acquired else {
                    await self.handleAcquireFailure(
                        tabID: tabID,
                        session: session,
                        runID: runID,
                        runAttemptID: runAttemptID,
                        attachmentReservationID: attachmentReservationID
                    )
                    return
                }

                await self.claudeCoordinator.ensureClaudeToolTrackingIfNeeded(
                    for: session,
                    runID: runID
                )

                let sent = await self.claudeCoordinator.sendClaudeNativeMessage(
                    session: session,
                    text: initialMessageForRun,
                    attachments: attachments
                )
                self.hooks.recordPendingHandoffSendOutcome(session, sent)
                guard sent else {
                    await lease.failAndRelease()
                    await self.finalize(
                        session: session,
                        runID: runID,
                        runAttemptID: runAttemptID,
                        attachmentReservationID: attachmentReservationID,
                        terminalState: .failed,
                        errorText: nil,
                        notifyTurnComplete: false
                    )
                    return
                }

                self.hooks.stageConsumedAttachmentFilesForDeferredCleanup(attachments, session)
                self.hooks.markAttachmentsConsumed(session, attachmentReservationID)
                _ = await lease.releaseWhenRouted()

                guard let events = await self.claudeCoordinator.events(for: session) else {
                    await self.finalize(
                        session: session,
                        runID: runID,
                        runAttemptID: runAttemptID,
                        attachmentReservationID: attachmentReservationID,
                        terminalState: .failed,
                        errorText: "Claude native events stream not available.",
                        notifyTurnComplete: false
                    )
                    return
                }

                session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .running)
                let outcome = await self.consumeEvents(
                    events,
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID
                )
                await self.finalize(
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    attachmentReservationID: attachmentReservationID,
                    terminalState: outcome.terminalState,
                    errorText: outcome.errorText,
                    notifyTurnComplete: outcome.terminalState == .completed
                )
                if outcome.shouldShutdownSession {
                    await self.claudeCoordinator.shutdownClaudeSession(session)
                }
            } onCancel: {
                Task { await lease.cancelAndCleanup() }
            }
        }
    }

    private func consumeEvents(
        _ events: AsyncStream<NativeAgentRuntimeEvent>,
        session: AgentModeViewModel.TabSession,
        runID: UUID,
        runAttemptID: UUID
    ) async -> ConsumeEventsOutcome {
        var exitedDueToAttemptMismatch = false

        eventLoop: for await event in events {
            guard session.runID == runID,
                  session.activeRunAttemptID == runAttemptID
            else {
                exitedDueToAttemptMismatch = true
                break eventLoop
            }

            if let ownership = session.activeRunOwnership, ownership.attemptID == runAttemptID {
                session.recordRunProgress(ownership: ownership, kind: .providerEvent, stage: .running)
            }

            switch event {
            case let .stream(result):
                #if DEBUG
                    if ClaudeReasoningExtractionFeature.isEnabled, result.type == "reasoning" {
                        let text = result.reasoning ?? result.text ?? ""
                        reasoningDebug("stream reasoning run=\(runID.uuidString) attempt=\(runAttemptID.uuidString) tab=\(session.tabID.uuidString) len=\(text.count) snippet=\(reasoningDebugSnippet(text))")
                    }
                #endif
                await hooks.handleHeadlessStreamResult(result, session, runID, runAttemptID)
            case let .runtimeInit(status):
                // Persist provider session ID as soon as it becomes available from
                // runtime init events (initialize response or system/init stream).
                if let newSessionID = status.sessionID,
                   !newSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   newSessionID != session.providerSessionID
                {
                    session.providerSessionID = newSessionID
                    session.isDirty = true
                    hooks.scheduleSave(session.tabID)
                }
                if status.isRepoPromptServerFailed {
                    return ConsumeEventsOutcome(
                        terminalState: .failed,
                        errorText: "RepoPrompt MCP failed to initialize for Claude (session \(status.sessionID ?? "unknown")).",
                        shouldShutdownSession: true
                    )
                }
            case let .approvalRequest(request):
                if let ownership = session.activeRunOwnership, ownership.attemptID == runAttemptID {
                    session.recordRunProgress(ownership: ownership, kind: .interaction, stage: .waitingForInteraction)
                }
                session.pendingApproval = request
                session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
                session.setRunningStatus(nil, source: nil)
                session.runState = .waitingForApproval
                hooks.updateBindings(session)
            case let .approvalCancelled(requestID):
                if session.pendingApproval?.requestID == .claudeControl(requestID) {
                    session.pendingApproval = nil
                    if session.runState == .waitingForApproval {
                        session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
                        session.setRunningStatus("Thinking…", source: .transport)
                        session.runState = .running
                    }
                    hooks.updateBindings(session)
                }
            case let .turnCompleted(turnID, turnStatus):
                guard session.claudeExpectedTurnIDs.contains(turnID) else {
                    // Stale completion from a previous cancelled run attempt; ignore.
                    continue eventLoop
                }
                session.claudeExpectedTurnIDs.remove(turnID)

                let wasProtectedClaudeTurn = session.claudeSupersedingProtectedTurnIDs.remove(turnID) != nil
                let hasLegacyUnscopedProtection = session.claudeSupersedingProtectedTurnIDs.isEmpty
                    && session.pendingSupersedingTurnCompletions > 0
                if wasProtectedClaudeTurn || hasLegacyUnscopedProtection {
                    session.pendingSupersedingTurnCompletions = max(0, session.pendingSupersedingTurnCompletions - 1)
                    // Keep run alive for the next (superseding) turn regardless of the
                    // stale turn's reported terminal status. Old interrupted turns can land
                    // as .cancelled, .failed, or even .completed after the superseding send
                    // is already in flight.
                    if !session.runState.isActive {
                        session.runState = .running
                    }
                    hooks.setAgentRunActive(session.tabID, true)
                    hooks.updateBindings(session)
                    continue eventLoop
                }
                // No superseding turn expected — terminal for this run.
                session.pendingSupersedingTurnCompletions = 0
                session.claudeSupersedingProtectedTurnIDs.removeAll()
                switch turnStatus {
                case .completed:
                    return ConsumeEventsOutcome(terminalState: .completed, errorText: nil, shouldShutdownSession: false)
                case .cancelled:
                    return ConsumeEventsOutcome(terminalState: .cancelled, errorText: nil, shouldShutdownSession: false)
                case .failed:
                    return ConsumeEventsOutcome(terminalState: .failed, errorText: nil, shouldShutdownSession: false)
                }
            case let .error(message):
                session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
                session.setRunningStatus(nil, source: nil)
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    #if !DEBUG
                        // Suppress known non-actionable abort side-effect errors (e.g. JSON parse
                        // errors from killed tool processes) in release builds.
                        if Self.isKnownNonActionableStreamError(trimmed) { continue eventLoop }
                    #endif
                    let errorItem = AgentChatItem.error(trimmed, sequenceIndex: session.nextSequenceIndex)
                    session.appendItem(errorItem)
                    hooks.updateBindings(session)
                    hooks.scheduleSave(session.tabID)
                }
            }
        }

        // If we exited because the attempt changed (cancel / new attempt)
        // or the task was cancelled, this is expected — not a stream failure.
        if exitedDueToAttemptMismatch || Task.isCancelled {
            return ConsumeEventsOutcome(terminalState: .cancelled, errorText: nil, shouldShutdownSession: false)
        }

        // The events stream ended without a terminal turnCompleted event while this
        // attempt was still active.  This means the stream was finished or the Claude
        // process exited unexpectedly.
        let errorItem = AgentChatItem.error(
            "Claude events stream ended unexpectedly. The run may need to be restarted.",
            sequenceIndex: session.nextSequenceIndex
        )
        session.appendItem(errorItem)
        hooks.updateBindings(session)
        hooks.scheduleSave(session.tabID)
        return ConsumeEventsOutcome(terminalState: .failed, errorText: nil, shouldShutdownSession: false)
    }

    private func handleAcquireFailure(
        tabID: UUID,
        session: AgentModeViewModel.TabSession,
        runID: UUID,
        runAttemptID: UUID,
        attachmentReservationID: UUID?
    ) async {
        guard session.runID == runID,
              session.activeRunAttemptID == runAttemptID
        else {
            return
        }
        session.endRunAttempt(ifCurrentAttemptID: runAttemptID, source: "claudeNative.acquireFailure")
        session.agentTask = nil
        session.runState = .cancelled
        session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
        session.setRunningStatus(nil, source: nil)
        hooks.recordPendingHandoffSendOutcome(session, false)
        hooks.setAgentRunActive(tabID, false)
        hooks.finalizeAttachmentsForTurn(session, attachmentReservationID, .deleteFiles)
        hooks.updateBindings(session)
        hooks.scheduleSave(session.tabID)
    }

    private func finalize(
        session: AgentModeViewModel.TabSession,
        runID: UUID,
        runAttemptID: UUID,
        attachmentReservationID: UUID?,
        terminalState: AgentSessionRunState,
        errorText: String?,
        notifyTurnComplete: Bool
    ) async {
        guard session.runID == runID,
              session.activeRunAttemptID == runAttemptID
        else {
            return
        }

        hooks.finalizeStreamingItems(session)
        hooks.finalizePendingToolCalls(session, terminalState)
        hooks.finalizeNonCodexTurnUsage(session, nil, nil, nil)
        let queuedInstruction = terminalState == .completed ? session.pendingInstructions.first : nil
        if queuedInstruction != nil {
            session.pendingInstructions.removeFirst()
        }
        session.endRunAttempt(ifCurrentAttemptID: runAttemptID, source: "claudeNative.finalize")
        session.agentTask = nil
        session.runState = terminalState
        session.pendingSupersedingTurnCompletions = 0
        session.claudeSupersedingProtectedTurnIDs.removeAll()
        session.claudeExpectedTurnIDs.removeAll()
        session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
        session.setRunningStatus(nil, source: nil)
        hooks.cancelPendingQuestion(session)
        hooks.cancelPendingApproval(session)
        let pendingReviewCancellationReason = switch terminalState {
        case .completed:
            "Run completed before review decision"
        case .cancelled:
            "Run cancelled"
        case .failed:
            "Run failed"
        default:
            "Run finished"
        }
        hooks.cancelPendingApplyEditsReview(session, pendingReviewCancellationReason)
        hooks.cancelPendingWorktreeMergeReview(session, pendingReviewCancellationReason)
        hooks.setAgentRunActive(session.tabID, false)
        hooks.finalizeAttachmentsForTurn(session, attachmentReservationID, .deleteFiles)

        if let errorText {
            let trimmed = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let errorItem = AgentChatItem.error(trimmed, sequenceIndex: session.nextSequenceIndex)
                session.appendItem(errorItem)
            }
        }

        hooks.updateBindings(session)
        if notifyTurnComplete {
            hooks.notifyAgentTurnComplete(session)
        }
        hooks.scheduleSave(session.tabID)

        if let queuedInstruction {
            hooks.startFollowUpRun(session.tabID, queuedInstruction)
        }
    }

    // MARK: - Error Filtering

    /// Returns `true` when the error message is a known non-actionable abort side
    /// effect (e.g. JSON parse errors from killed tool processes, MCP AbortErrors).
    /// These are suppressed in release builds to avoid alarming users.
    private static func isKnownNonActionableStreamError(_ message: String) -> Bool {
        ClaudeAbortArtifactFilter.shouldSuppressUserFacingError(message)
    }
}
