import Foundation
import RepoPromptDomainRuntime
import RepoPromptProcess
import RepoPromptProviderQuota
import RepoPromptSettingsCore

@MainActor
final class ClaudeIntegratedAgentModeRunner {
    private enum ConsumeEventsOutcome {
        case completed
        case cancelled
        case failed(errorText: String?, shouldShutdownSession: Bool)
    }

    /// Claude's native stream reports terminal cancellation and failure as values,
    /// while the shared transient execution core accepts those classifications as
    /// thrown errors. This marker is intentionally runner-local: the coordinator
    /// and native controller remain the authorities for the underlying terminal
    /// event and its provider-specific metadata.
    private struct NativeTerminalFailure: Error {}

    private let claudeCoordinator: ClaudeAgentModeCoordinator
    private let hooks: AgentModeRunService.Hooks
    private let terminalCommitBarrier: AgentRunTerminalCommitBarrier
    private let quotaService: ClaudeRunRateLimitTelemetryService

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
        hooks: AgentModeRunService.Hooks,
        terminalCommitBarrier: AgentRunTerminalCommitBarrier,
        quotaService: ClaudeRunRateLimitTelemetryService = WindowStatesManager.shared.providerQuotaRuntime.claudeTelemetry
    ) {
        self.claudeCoordinator = claudeCoordinator
        self.hooks = hooks
        self.terminalCommitBarrier = terminalCommitBarrier
        self.quotaService = quotaService
    }

    /// Whether cancelling an attempt on `runID` must keep that run's committed MCP route.
    ///
    /// True only while the session still owns this exact reused process run: its Claude controller is
    /// attached and its process run identity is still `runID`. That is the case for an attempt that
    /// ended before its provider call — for example a retracted Auto-wake — whose provider process and
    /// MCP connection outlive it. User Stop and provider identity resets detach the controller and
    /// clear the run identity first (`prepareClaudeCancelSync`), so their cancellation keeps revoking.
    static func cancellationPreservesRunRoute(session: AgentTabSession, runID: UUID) -> Bool {
        session.claudeController != nil
            && AgentModeProcessRunIdentity.existingProcessRunID(for: session) == runID
    }

    /// Cancels one attempt's bootstrap lease. Every cancellation in this runner goes through here so
    /// the run-ownership decision is made in exactly one place, at cleanup time.
    static func cancelAttemptLease(_ lease: MCPBootstrapLease, session: AgentTabSession?, runID: UUID) async {
        let preservesRoute = session.map { cancellationPreservesRunRoute(session: $0, runID: runID) } ?? false
        await lease.cancelAndCleanup(preservingCommittedRoute: preservesRoute)
    }

    func startRun(
        tabID: UUID,
        session: AgentTabSession,
        initialUserMessage: String,
        initialMessageForRun: String,
        attachments: [AgentImageAttachment],
        makeLease: (_ runID: UUID) -> MCPBootstrapLease,
        autoEffortSelection: AutoEffortTurnSelection? = nil,
        providerControlCommand: AgentProviderControlCommand? = nil,
        selfCompactDispatchID: AgentSelfCompactionDispatchID? = nil,
        stopFence: AgentRunStartStopFence? = nil
    ) async {
        let dedicatedNoteID = selfCompactDispatchID.flatMap { $0.stage == .note ? $0 : nil }
        var handedToRunTask = false
        defer {
            if let dedicatedNoteID, !handedToRunTask {
                AgentSelfCompactParkedPrefix.reparkUnattemptedDedicatedNote(dedicatedNoteID, session: session) {
                    hooks.persistence.scheduleSave(session)
                }
            }
        }
        guard stopFence?.permitsStart(of: session) ?? true else { return }
        let attachmentReservationID = hooks.attachments.reserveAttachmentsForTurn(attachments, session)

        if initialMessageForRun != initialUserMessage,
           !session.pendingNonCodexUserInputTokenQueue.isEmpty
        {
            session.pendingNonCodexUserInputTokenQueue[0] = hooks.usage.estimateRuntimeTokens(initialMessageForRun)
        }
        hooks.usage.startNonCodexTurnAccountingIfNeeded(session, initialMessageForRun)
        session.activeReasoningItemID = nil
        session.reasoningItemIDsByGroupID.removeAll()
        session.codexReasoningSegmentsByKey.removeAll()

        let runID = session.claudeController.flatMap { _ in
            AgentModeProcessRunIdentity.existingProcessRunID(for: session)
        } ?? AgentModeProcessRunIdentity.startFreshProcessRun(for: session)
        let lease = makeLease(runID)
        guard stopFence?.permitsStart(of: session) ?? true else {
            Task { await lease.cancelAndCleanup() }
            return
        }
        let ownership = session.beginRunAttempt(source: "claudeNative")
        session.installRunAttemptTerminalResources(ownership: ownership) { [weak session] terminalState in
            {
                switch terminalState {
                case .failed:
                    await lease.failAndRelease()
                case .cancelled:
                    await Self.cancelAttemptLease(lease, session: session, runID: runID)
                default:
                    break
                }
            }
        }
        let runAttemptID = ownership.attemptID
        if let dispatchID = providerControlCommand?.selfCompactDispatchID,
           dispatchID.stage == .compact
        {
            guard session.selfCompactDispatchIsCurrent?() != false,
                  session.selfCompactNativeCompletion?.bindCompact(
                      dispatchID, runID: runID, runAttemptID: runAttemptID
                  ) == true
            else {
                await finalize(
                    session: session, runID: runID, ownership: ownership,
                    attachmentReservationID: attachmentReservationID, terminalState: .failed,
                    errorText: nil, notifyTurnComplete: false
                )
                return
            }
        }
        session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .preparingRuntime)
        session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
        session.setRunningStatus("Thinking…", source: .transport)
        session.runState = .running
        session.pendingSupersedingTurnCompletions = 0
        session.claudeSupersedingProtectedTurnIDs.removeAll()
        session.claudeExpectedTurnIDs.removeAll()
        hooks.presentation.setAgentRunActive(session, true)
        hooks.bindingObservation.updateBindings(session)

        let isPeriodic = session.oversight.pendingAutoWake?.isPeriodic == true
        session.agentTask = Task { [weak self, weak session, hooks] in
            guard let session else { return }
            defer {
                if let dedicatedNoteID {
                    AgentSelfCompactParkedPrefix.reparkUnattemptedDedicatedNote(dedicatedNoteID, session: session) {
                        hooks.persistence.scheduleSave(session)
                    }
                }
            }
            guard let self else { return }
            await withTaskCancellationHandler {
                let acquired = await lease.acquire()
                guard acquired else {
                    await self.handleAcquireFailure(
                        tabID: tabID,
                        session: session,
                        runID: runID,
                        ownership: ownership,
                        attachmentReservationID: attachmentReservationID
                    )
                    return
                }

                await self.claudeCoordinator.ensureClaudeToolTrackingIfNeeded(
                    for: session,
                    runID: runID
                )

                let providerName = session.selectedAgent.rawValue
                var didSendToProvider = false
                var nativeFailureMetadata: (errorText: String?, shouldShutdownSession: Bool)?
                let report = await DomainAgentRunExecutionCore.execute(
                    failureText: { _ in nativeFailureMetadata?.errorText ?? "" }
                ) {
                    await lease.providerInitializationStarted(provider: providerName)
                    let sendOutcome = await self.claudeCoordinator.sendClaudeNativeMessage(
                        session: session,
                        text: initialMessageForRun,
                        attachments: attachments,
                        intent: .runAttempt(ownership: ownership, runID: runID),
                        // No event stream is owned until this send succeeds and the runner subscribes
                        // below, so replacing a route-stale controller is safe at this boundary.
                        allowsCatalogRouteControllerRecovery: true,
                        autoEffortSelection: autoEffortSelection,
                        providerControlCommand: providerControlCommand,
                        selfCompactDispatchID: selfCompactDispatchID
                    )
                    if let dedicatedNoteID, sendOutcome != .sent {
                        AgentSelfCompactParkedPrefix.reparkUnattemptedDedicatedNote(dedicatedNoteID, session: session) {
                            self.hooks.persistence.scheduleSave(session)
                        }
                    }
                    let providerInitializationOutcome = switch sendOutcome {
                    case .sent:
                        "ready"
                    case .failed:
                        Task.isCancelled ? "cancelled" : "failed"
                    case .superseded:
                        "superseded"
                    }
                    await lease.providerInitializationCompleted(
                        provider: providerName,
                        outcome: providerInitializationOutcome
                    )

                    switch sendOutcome {
                    case .sent:
                        didSendToProvider = true
                        if !isPeriodic, providerControlCommand == nil, selfCompactDispatchID == nil { self.hooks.providerInput.recordPendingHandoffSendOutcome(session, true) }
                    case .failed:
                        nativeFailureMetadata = (errorText: nil, shouldShutdownSession: false)
                        throw NativeTerminalFailure()
                    case .superseded:
                        return .superseded
                    }

                    self.hooks.attachments.stageConsumedAttachmentFilesForDeferredCleanup(attachments, session)
                    self.hooks.attachments.markAttachmentsConsumed(session, attachmentReservationID)
                    _ = await lease.releaseWhenRouted()

                    guard let events = await self.claudeCoordinator.events(for: session) else {
                        nativeFailureMetadata = (
                            errorText: "Claude native events stream not available.",
                            shouldShutdownSession: false
                        )
                        throw NativeTerminalFailure()
                    }

                    session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .running)
                    switch await self.consumeEvents(
                        events,
                        session: session,
                        runID: runID,
                        runAttemptID: runAttemptID
                    ) {
                    case .completed:
                        return .completed(assistantText: nil)
                    case .cancelled:
                        throw CancellationError()
                    case let .failed(errorText, shouldShutdownSession):
                        nativeFailureMetadata = (errorText, shouldShutdownSession)
                        throw NativeTerminalFailure()
                    }
                }

                switch report.result {
                case .superseded:
                    if self.claudeCoordinator.runAttemptIsCurrent(
                        ownership,
                        runID: runID,
                        for: session
                    ) {
                        if !isPeriodic, providerControlCommand == nil, selfCompactDispatchID == nil { self.hooks.providerInput.recordPendingHandoffSendOutcome(session, false) }
                        let revision = await self.finalize(
                            session: session,
                            runID: runID,
                            ownership: ownership,
                            attachmentReservationID: attachmentReservationID,
                            terminalState: .cancelled,
                            errorText: nil,
                            notifyTurnComplete: false
                        )
                        if revision == nil {
                            await Self.cancelAttemptLease(lease, session: session, runID: runID)
                        }
                    } else {
                        await Self.cancelAttemptLease(lease, session: session, runID: runID)
                    }
                case let .terminal(outcome):
                    let terminalState: AgentSessionRunState = switch outcome.kind {
                    case .completed: .completed
                    case .cancelled: .cancelled
                    case .failed: .failed
                    }
                    if !didSendToProvider {
                        if !isPeriodic, providerControlCommand == nil, selfCompactDispatchID == nil { self.hooks.providerInput.recordPendingHandoffSendOutcome(session, false) }
                    }
                    await self.finalize(
                        session: session,
                        runID: runID,
                        ownership: ownership,
                        attachmentReservationID: attachmentReservationID,
                        terminalState: terminalState,
                        errorText: outcome.kind == .failed ? nativeFailureMetadata?.errorText : nil,
                        notifyTurnComplete: outcome.kind == .completed,
                        shouldShutdownSession: outcome.kind == .failed
                            && nativeFailureMetadata?.shouldShutdownSession == true
                    )
                }
            } onCancel: {}
        }
        handedToRunTask = true
    }

    /// The Claude config directory the native `claude` process is launched with: the same
    /// environment composition as `ClaudeNativeProcessSessionController` (cached shell env
    /// layered over the app env), so `CLAUDE_CONFIG_DIR` set only in a shell profile counts.
    private static func claudeRunUsageProfileID() async -> String {
        let environment = await ProcessEnvironmentBuilder.build(ProcessEnvironmentRequest(purpose: .claudeNative)).environment
        return ClaudeUsageCredentialProfile.current(environment: environment).id
    }

    private func consumeEvents(
        _ events: AsyncStream<NativeAgentRuntimeEvent>,
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID
    ) async -> ConsumeEventsOutcome {
        var exitedDueToAttemptMismatch = false
        // Only first-party Claude owns this subscription telemetry. No extra request or
        // process is started; compatible launchers cannot populate Claude account usage.
        var quotaLease: UUID?
        if session.selectedAgent == .claudeCode,
           session.runID == runID, session.activeRunAttemptID == runAttemptID
        {
            let recordsTelemetry = GlobalSettingsStore.shared.claudeUsageQuotaEnabled()
            await quotaService.setEnabled(recordsTelemetry)
            // Attribute the run to its Claude config directory so the usage pill only adopts
            // telemetry from the same profile it reads usage for.
            let profileID = recordsTelemetry ? await Self.claudeRunUsageProfileID() : nil
            if session.runID == runID, session.activeRunAttemptID == runAttemptID {
                quotaLease = await quotaService.beginObservation(credentialProfileID: profileID)
            }
        }

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
                await hooks.transcript.handleHeadlessStreamResult(result, session, runID, runAttemptID)
            case let .rateLimit(info):
                if session.selectedAgent == .claudeCode, let quotaLease {
                    await quotaService.observe(ClaudeCompatibleProviderRuntimeBridge.quotaObservation(from: info), lease: quotaLease, observedAt: Date())
                }
            case let .runtimeInit(status):
                // Persist provider session ID as soon as it becomes available from
                // runtime init events (initialize response or system/init stream).
                if let newSessionID = status.sessionID,
                   !newSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   newSessionID != session.providerSessionID
                {
                    session.providerSessionID = newSessionID
                    session.providerCleanupHandle = ProviderConversationCleanupHandle.resolved(
                        provider: session.selectedAgent.rawValue,
                        explicit: nil,
                        providerSessionID: newSessionID,
                        codexConversationID: session.codexConversationID,
                        codexRolloutPath: session.codexRolloutPath
                    )
                    session.isDirty = true
                    hooks.persistence.scheduleSave(session)
                }
                if status.isRepoPromptServerFailed {
                    return .failed(
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
                hooks.bindingObservation.updateBindings(session)
            case let .approvalCancelled(requestID):
                if session.pendingApproval?.requestID == .claudeControl(requestID) {
                    session.pendingApproval = nil
                    if session.runState == .waitingForApproval {
                        session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
                        session.setRunningStatus("Thinking…", source: .transport)
                        session.runState = .running
                    }
                    hooks.bindingObservation.updateBindings(session)
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
                    hooks.presentation.setAgentRunActive(session, true)
                    hooks.bindingObservation.updateBindings(session)
                    continue eventLoop
                }
                // No superseding turn expected — terminal for this run.
                session.pendingSupersedingTurnCompletions = 0
                session.claudeSupersedingProtectedTurnIDs.removeAll()
                switch turnStatus {
                case .completed:
                    return .completed
                case .cancelled:
                    return .cancelled
                case .failed:
                    return .failed(errorText: nil, shouldShutdownSession: false)
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
                    hooks.bindingObservation.updateBindings(session)
                    hooks.persistence.scheduleSave(session)
                }
            }
        }

        // If we exited because the attempt changed (cancel / new attempt)
        // or the task was cancelled, this is expected — not a stream failure.
        if exitedDueToAttemptMismatch || Task.isCancelled {
            return .cancelled
        }

        // The events stream ended without a terminal turnCompleted event while this
        // attempt was still active.  This means the stream was finished or the Claude
        // process exited unexpectedly.
        return .failed(
            errorText: "Claude events stream ended unexpectedly. The run may need to be restarted.",
            shouldShutdownSession: false
        )
    }

    private func handleAcquireFailure(
        tabID _: UUID,
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
            source: "claudeNative.acquireFailure",
            attachmentReservationID: attachmentReservationID,
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: true,
            supportsFollowUp: true,
            notifyTurnComplete: false
        ))
    }

    @discardableResult
    private func finalize(
        session: AgentTabSession,
        runID: UUID,
        ownership: AgentRunOwnership,
        attachmentReservationID: UUID?,
        terminalState: AgentSessionRunState,
        errorText: String?,
        notifyTurnComplete: Bool,
        shouldShutdownSession: Bool = false
    ) async -> AgentRunTerminalCommitRevision? {
        await terminalCommitBarrier.commit(.init(
            binding: hooks.bindTerminalSession(session),
            ownership: ownership,
            expectedRunID: runID,
            terminalState: terminalState,
            source: "claudeNative.finalize",
            errorText: errorText,
            attachmentReservationID: attachmentReservationID,
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: true,
            supportsFollowUp: true,
            notifyTurnComplete: notifyTurnComplete,
            prepareProviderState: { [claudeCoordinator] in
                session.pendingSupersedingTurnCompletions = 0
                session.claudeSupersedingProtectedTurnIDs.removeAll()
                session.claudeExpectedTurnIDs.removeAll()
                guard shouldShutdownSession else { return nil }
                let oldController = claudeCoordinator.prepareClaudeCancelSync(session)
                return {
                    claudeCoordinator.beginClaudeResumeTransferIfNeeded(
                        for: session,
                        oldController: oldController
                    )
                    await claudeCoordinator.awaitPendingClaudeResumeTransferIfNeeded(for: session)
                }
            }
        ))
    }

    // MARK: - Error Filtering

    /// Returns `true` when the error message is a known non-actionable abort side
    /// effect (e.g. JSON parse errors from killed tool processes, MCP AbortErrors).
    /// These are suppressed in release builds to avoid alarming users.
    private static func isKnownNonActionableStreamError(_ message: String) -> Bool {
        ClaudeAbortArtifactFilter.shouldSuppressUserFacingError(message)
    }
}
