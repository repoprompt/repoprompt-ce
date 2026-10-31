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

    func adoptProviderTurn(session: AgentTabSession, listener: ClaudeControllerEventListener, turnID: UUID) -> Bool {
        guard let runID = AgentModeProcessRunIdentity.existingProcessRunID(for: session),
              session.claudeController != nil, listener.pendingProviderTurnID == turnID,
              listener.subscription == nil, listener.isCurrent(),
              let subscription = listener.reserve()
        else { return false }
        let owner = session.beginRunAttempt(source: "claudeNative.providerInitiated")
        session.claudeTerminalAnchor = (owner, .none)
        session.beginProviderInitiatedTurnAccounting()
        session.activeReasoningItemID = nil
        session.reasoningItemIDsByGroupID.removeAll()
        session.codexReasoningSegmentsByKey.removeAll()
        session.pendingSupersedingTurnCompletions = 0
        session.claudeSupersedingProtectedTurnIDs.removeAll()
        session.claudeExpectedTurnIDs = [turnID]
        session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
        session.setRunningStatus("Thinking…", source: .transport)
        session.runState = .running
        session.recordRunProgress(ownership: owner, kind: .providerEvent, stage: .running)
        session.installRunAttemptTerminalResources(ownership: owner) { [weak session, claudeCoordinator] state in
            {
                guard let session, state == .cancelled || state == .failed else { return }
                await claudeCoordinator.cleanupAdoptedRun(session: session, runID: runID)
            }
        }
        hooks.presentation.setAgentRunActive(session, true)
        hooks.bindingObservation.updateBindings(session)
        hooks.persistence.scheduleSave(session)
        session.agentTask = Task { [weak self, weak session] in
            guard let self, let session else { listener.close(subscription, returningTail: false)
                return
            }
            defer {
                listener.close(subscription, returningTail: true)
                listener.terminalPublished(for: subscription)
            }
            await claudeCoordinator.ensureClaudeToolTrackingIfNeeded(for: session, runID: runID)
            let outcome = await consumeEvents(
                next: { await subscription.next() },
                close: { listener.close(subscription, returningTail: true) },
                session: session, runID: runID, runAttemptID: owner.attemptID
            )
            let state: AgentSessionRunState
            let error: String?
            switch outcome {
            case .completed: (state, error) = (.completed, nil)
            case .cancelled: (state, error) = (.cancelled, nil)
            case let .failed(message, _): (state, error) = (.failed, message)
            }
            await finalize(
                session: session,
                runID: runID,
                ownership: owner,
                attachmentReservationID: nil,
                terminalState: state,
                errorText: error,
                notifyTurnComplete: state == .completed,
                shouldShutdownSession: state == .failed
            )
        }
        return true
    }

    func startRun(
        tabID: UUID,
        session: AgentTabSession,
        initialUserMessage: String,
        initialMessageForRun: String,
        attachments: [AgentFileAttachment],
        makeLease: (_ runID: UUID) -> MCPBootstrapLease,
        autoEffortSelection: AutoEffortTurnSelection? = nil,
        providerControlCommand: AgentProviderControlCommand? = nil,
        selfCompactDispatchID: AgentSelfCompactionDispatchID? = nil,
        stopFence: AgentRunStartStopFence? = nil,
        localComposerCandidate: UUID? = nil,
        initialUserItemID: UUID? = nil,
        preparedEvents: ClaudeAttemptEventReservation? = nil,
        startOutcome: AgentRunStartOutcomeRecorder? = nil
    ) async {
        let dedicatedNoteID = selfCompactDispatchID.flatMap { $0.stage == .note ? $0 : nil }
        var handedToRunTask = false
        var reservedEvents = preparedEvents
        defer {
            if !handedToRunTask {
                session.settleLocalComposerOrigin(localComposerCandidate, disposition: .retained)
                if let reservedEvents {
                    reservedEvents.listener.close(reservedEvents.subscription, returningTail: true)
                    reservedEvents.listener.terminalPublished(for: reservedEvents.subscription)
                }
            }
            if let dedicatedNoteID, !handedToRunTask {
                AgentSelfCompactParkedPrefix.reparkUnattemptedDedicatedNote(dedicatedNoteID, session: session) {
                    hooks.persistence.scheduleSave(session)
                }
            }
        }
        guard stopFence?.permitsStart(of: session) ?? true else { return }
        let runID = session.claudeController.flatMap { _ in
            AgentModeProcessRunIdentity.existingProcessRunID(for: session)
        } ?? AgentModeProcessRunIdentity.startFreshProcessRun(for: session)
        if let current = reservedEvents,
           !current.listener.isCurrent() || current.listener.subscription !== current.subscription
        {
            current.listener.close(current.subscription, returningTail: true)
            current.listener.terminalPublished(for: current.subscription)
            reservedEvents = nil
        }
        if reservedEvents == nil { reservedEvents = claudeCoordinator.reserveEvents(for: session) }
        guard let (listener, subscription) = reservedEvents else {
            let message = ClaudeAgentModeCoordinator.inputNotSentMessage
            startOutcome?.recordStartFailure(message: message)
            if localComposerCandidate != nil {
                session.appendItem(.error(message, sequenceIndex: session.nextSequenceIndex))
                session.isDirty = true
                hooks.persistence.scheduleSave(session)
                hooks.bindingObservation.updateBindings(session)
            }
            return
        }
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

        let lease = makeLease(runID)
        guard stopFence?.permitsStart(of: session) ?? true else {
            Task { await lease.cancelAndCleanup() }
            return
        }
        let qualifiesQuietProvider = session.selectedAgent == .claudeCode
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
        let parkedIDs = listener.providerTurnIDs.union(listener.pendingProviderTurnID.map { [$0] } ?? [])
        session.claudeExpectedTurnIDs.formUnion(parkedIDs)
        session.claudeSupersedingProtectedTurnIDs.formUnion(parkedIDs)
        session.pendingSupersedingTurnCompletions = parkedIDs.count
        hooks.presentation.setAgentRunActive(session, true)
        hooks.bindingObservation.updateBindings(session)

        let isPeriodic = session.oversight.pendingAutoWake?.isPeriodic == true
        // Only the producer can identify its newly appended row. An Auto-wake can follow an
        // unanswered historical user row, so even a trailing-row check cannot establish ownership.
        let rollbackUserItemID = providerControlCommand == nil && selfCompactDispatchID == nil && !isPeriodic
            ? initialUserItemID
            : nil
        session.agentTask = Task { [weak self, weak session, hooks] in
            guard let session else { return }
            defer {
                session.settleLocalComposerOrigin(localComposerCandidate, disposition: .retained)
                if let dedicatedNoteID {
                    AgentSelfCompactParkedPrefix.reparkUnattemptedDedicatedNote(dedicatedNoteID, session: session) {
                        hooks.persistence.scheduleSave(session)
                    }
                }
            }
            guard let self else { listener.close(subscription, returningTail: false)
                return
            }
            defer {
                listener.close(subscription, returningTail: true)
                listener.terminalPublished(for: subscription)
            }
            await withTaskCancellationHandler {
                let acquired = await lease.acquire()
                guard acquired else {
                    listener.close(subscription, returningTail: true)
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
                var routeRefusalMessage: String?
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
                        // The reserved attempt inbox migrates with a replacement controller;
                        // only its old stream incarnation is retired.
                        allowsCatalogRouteControllerRecovery: true,
                        autoEffortSelection: autoEffortSelection,
                        providerControlCommand: providerControlCommand,
                        selfCompactDispatchID: selfCompactDispatchID,
                        // A replacement process's MCP child needs this run's one-shot admission
                        // policy re-armed; the lease that installed it still owns it here.
                        reinstallRunRoutingPolicy: { await lease.reinstallPolicyForReplacementProcess() }
                    )
                    if sendOutcome == .sent { session.settleLocalComposerOrigin(localComposerCandidate, disposition: .retained) }
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
                    case let .failed(message):
                        nativeFailureMetadata = (errorText: nil, shouldShutdownSession: false)
                        if ClaudeAgentModeCoordinator.isRouteVerificationFailure(message) {
                            routeRefusalMessage = message
                        }
                        throw NativeTerminalFailure()
                    case .superseded:
                        return .superseded
                    }

                    self.hooks.attachments.stageConsumedAttachmentFilesForDeferredCleanup(attachments, session)
                    self.hooks.attachments.markAttachmentsConsumed(session, attachmentReservationID)
                    _ = await lease.releaseWhenRouted()

                    session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .running)
                    switch await self.consumeEvents(
                        next: { await subscription.next() },
                        close: { listener.close(subscription, returningTail: true) },
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

                listener.close(subscription, returningTail: true)
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
                        classifiesQuietCheckIn: qualifiesQuietProvider && outcome.kind == .completed && providerControlCommand == nil && selfCompactDispatchID == nil,
                        shouldShutdownSession: outcome.kind == .failed
                            && (nativeFailureMetadata?.shouldShutdownSession == true || listener.runtimeFailure != nil)
                    )
                    // Route refusals happen before any provider write, so the user's message was never
                    // sent. Mirror Codex: withdraw the unsent row and hand the text back for a resend.
                    if outcome.kind == .failed, !didSendToProvider,
                       routeRefusalMessage != nil,
                       let rollbackUserItemID
                    {
                        self.hooks.queuedWorkRecovery.restoreRouteRefusedUnsentTurn(
                            session,
                            rollbackUserItemID,
                            "\(session.selectedAgent.displayName) did not send because the RepoPrompt MCP route could not be verified. Your message was restored."
                        )
                    }
                }
            } onCancel: {}
        }
        handedToRunTask = true
        startOutcome?.recordAccepted()
    }

    /// The Claude config directory the native `claude` process is launched with: the same
    /// environment composition as `ClaudeNativeProcessSessionController` (cached shell env
    /// layered over the app env), so `CLAUDE_CONFIG_DIR` set only in a shell profile counts.
    private static func claudeRunUsageProfileID() async -> String {
        let environment = await ProcessEnvironmentBuilder.build(ProcessEnvironmentRequest(purpose: .claudeNative)).environment
        let filtered = await ProviderEnvironmentFiltering.filter(environment, for: .claudeCode)
        return ClaudeUsageCredentialProfile.current(environment: filtered).id
    }

    #if DEBUG
        func testConsumeAndFinalizeQuietEvents(
            _ events: AsyncStream<NativeAgentRuntimeEvent>,
            session: AgentTabSession,
            runID: UUID,
            owner: AgentRunOwnership
        ) async -> AgentRunTerminalCommitRevision? {
            guard case .completed = await consumeEvents(events, session: session, runID: runID, runAttemptID: owner.attemptID) else { return nil }
            return await finalize(
                session: session,
                runID: runID,
                ownership: owner,
                attachmentReservationID: nil,
                terminalState: .completed,
                errorText: nil,
                notifyTurnComplete: true,
                classifiesQuietCheckIn: true
            )
        }

        @discardableResult
        func testConsumeQuietEvents(_ events: [NativeAgentRuntimeEvent], session: AgentTabSession, runID: UUID, owner: AgentRunOwnership) async -> Bool {
            if case .completed = await testConsumeTurnStatus(events, session: session, runID: runID, owner: owner) { return true }
            return false
        }

        func testConsumeTurnStatus(_ events: [NativeAgentRuntimeEvent], session: AgentTabSession, runID: UUID, owner: AgentRunOwnership) async -> ClaudeNativeProcessSessionController.TurnStatus {
            let stream = AsyncStream<NativeAgentRuntimeEvent> { continuation in
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
            switch await consumeEvents(stream, session: session, runID: runID, runAttemptID: owner.attemptID) {
            case .completed: return .completed
            case .cancelled: return .cancelled
            case .failed: return .failed
            }
        }
    #endif

    private func consumeEvents(
        _ events: AsyncStream<NativeAgentRuntimeEvent>,
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID
    ) async -> ConsumeEventsOutcome {
        var iterator = events.makeAsyncIterator()
        return await consumeEvents(next: { await iterator.next().map(ClaudeAttemptEvent.native) }, close: {}, session: session, runID: runID, runAttemptID: runAttemptID)
    }

    private func consumeEvents(
        next: () async -> ClaudeAttemptEvent?,
        close: () -> Void,
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID
    ) async -> ConsumeEventsOutcome {
        defer { close() }
        var exitedDueToAttemptMismatch = false
        // Keyed answers may settle several unprotected inputs across separate events.
        // Keep their strongest outcome until the existing settlement boundary is terminal.
        var unprotectedTurnStatus: ClaudeNativeProcessSessionController.TurnStatus = .completed
        var answeredUnprotected = false
        var hostIDsAtFirstSuccessor: Set<UUID>?
        // Only first-party Claude owns this subscription telemetry. No extra request or
        // process is started; compatible launchers cannot populate Claude account usage.
        var quotaLease: UUID?
        if session.selectedAgent == .claudeCode,
           session.runID == runID, session.activeRunAttemptID == runAttemptID,
           let ingressOwner = session.activeRunOwnership,
           session.isCurrentRunAttemptForCurrentBinding(ingressOwner)
        {
            // Diagnostics toggle OR connected Claude usage display (see
            // `GlobalSettingsStore.claudeRunTelemetryRecordingEnabled`): the pill stays current
            // during runs by default, and this per-run sync never switches that off.
            let recordsTelemetry = GlobalSettingsStore.shared.claudeRunTelemetryRecordingEnabled(
                profileID: ClaudeUsageCredentialProfile.current().id
            )
            await quotaService.setEnabled(recordsTelemetry)
            // Attribute the run to its Claude config directory so the usage pill only adopts
            // telemetry from the same profile it reads usage for.
            let profileID = recordsTelemetry ? await Self.claudeRunUsageProfileID() : nil
            if session.runID == runID, session.activeRunAttemptID == runAttemptID {
                quotaLease = await quotaService.beginObservation(credentialProfileID: profileID)
            }
        }

        func strongest(_ current: ClaudeNativeProcessSessionController.TurnStatus, _ next: ClaudeNativeProcessSessionController.TurnStatus) -> ClaudeNativeProcessSessionController.TurnStatus {
            switch (current, next) {
            case (.failed, _), (_, .failed): .failed
            case (.cancelled, _), (_, .cancelled): .cancelled
            default: .completed
            }
        }
        var completedProtectedStatuses: [UUID: ClaudeNativeProcessSessionController.TurnStatus] = [:]
        var abandonedProtectedIDs: Set<UUID> = []
        eventLoop: while let item = await next() {
            guard session.runID == runID,
                  session.activeRunAttemptID == runAttemptID,
                  let ingressOwner = session.activeRunOwnership,
                  session.isCurrentRunAttemptForCurrentBinding(ingressOwner)
            else {
                exitedDueToAttemptMismatch = true
                break eventLoop
            }

            if let ownership = session.activeRunOwnership, ownership.attemptID == runAttemptID {
                session.recordRunProgress(ownership: ownership, kind: .providerEvent, stage: .running)
            }

            let event: NativeAgentRuntimeEvent
            switch item {
            case let .native(value): event = value
            case let .steeringReleased(ids, inputWasAttempted):
                if inputWasAttempted { return .failed(errorText: nil, shouldShutdownSession: true) }
                abandonedProtectedIDs.formUnion(ids)
                for id in ids {
                    if let status = completedProtectedStatuses[id] {
                        unprotectedTurnStatus = strongest(unprotectedTurnStatus, status)
                    }
                }
                fallthrough
            case .settlementRecheck:
                if abandonedProtectedIDs.contains(where: { completedProtectedStatuses[$0] != nil }),
                   session.claudeExpectedTurnIDs.isEmpty, session.pendingClaudeSteeringInstructions.isEmpty,
                   session.claudeSteeringFlushTask == nil
                {
                    switch unprotectedTurnStatus {
                    case .completed: return .completed
                    case .cancelled: return .cancelled
                    case .failed: return .failed(errorText: nil, shouldShutdownSession: false)
                    }
                }
                continue eventLoop
            }
            if let knownHostIDs = hostIDsAtFirstSuccessor {
                let activeHostIDs = session.claudeAcceptedHostTurnIDs
                if !activeHostIDs.subtracting(knownHostIDs).isEmpty {
                    // A newly registered host input supersedes earlier provider work, not later starts.
                    session.claudeLiveSuccessorTurnIDs.removeAll()
                    hostIDsAtFirstSuccessor = activeHostIDs
                    answeredUnprotected = false
                    unprotectedTurnStatus = .completed
                    completedProtectedStatuses.removeAll()
                    abandonedProtectedIDs.removeAll()
                }
            }
            switch event {
            case let .providerTurnStarted(id):
                let hasLivePredecessor = !session.claudeExpectedTurnIDs.isEmpty
                    || answeredUnprotected || !session.pendingClaudeSteeringInstructions.isEmpty
                    || session.claudeSteeringFlushTask != nil
                if session.claudeExpectedTurnIDs.insert(id).inserted {
                    session.claudeSupersedingProtectedTurnIDs.insert(id)
                    session.pendingSupersedingTurnCompletions += 1
                    if hasLivePredecessor {
                        if hostIDsAtFirstSuccessor == nil {
                            hostIDsAtFirstSuccessor = session.claudeAcceptedHostTurnIDs
                        }
                        session.claudeLiveSuccessorTurnIDs.insert(id)
                    }
                    hooks.transcript.beginClaudeProviderOutputSegment(session)
                    session.claudeProviderOutputBoundary = (runAttemptID, session.nextSequenceIndex)
                }
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
                claudeCoordinator.observeRuntimeInit(status, session: session)
                if status.isRepoPromptServerFailed {
                    return .failed(
                        errorText: ClaudeAgentModeCoordinator.mcpInitializationFailureMessage(sessionID: status.sessionID),
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
            case .turnCompleted, .turnsCompleted:
                let ids: [UUID]
                let turnStatus: ClaudeNativeProcessSessionController.TurnStatus
                let keyed: Bool
                switch event {
                case let .turnCompleted(id, status): (ids, turnStatus, keyed) = ([id], status, false)
                case let .turnsCompleted(group, status): (ids, turnStatus, keyed) = (group, status, true)
                default: preconditionFailure("Expected Claude completion")
                }
                let protectedIDs = Set(ids).intersection(session.claudeExpectedTurnIDs).intersection(session.claudeSupersedingProtectedTurnIDs)
                let answersSuccessor = !session.claudeLiveSuccessorTurnIDs.isDisjoint(with: ids)
                guard let settlement = Self.settleCompletedTurnIDsWithProtection(
                    ids, session: session, waitForAllUnprotected: keyed,
                    previouslyAnsweredUnprotected: answeredUnprotected,
                    liveSuccessorProviderIDs: session.claudeLiveSuccessorTurnIDs
                ) else {
                    continue eventLoop
                }
                session.claudeLiveSuccessorTurnIDs.subtract(ids)
                for id in protectedIDs {
                    completedProtectedStatuses[id] = turnStatus
                }
                if settlement.answeredUnprotected {
                    answeredUnprotected = true
                }
                if settlement.answeredUnprotected || answersSuccessor {
                    if hostIDsAtFirstSuccessor == nil, !protectedIDs.isEmpty {
                        hostIDsAtFirstSuccessor = session.claudeAcceptedHostTurnIDs
                    }
                    unprotectedTurnStatus = strongest(unprotectedTurnStatus, turnStatus)
                }
                if !settlement.terminal {
                    if !session.runState.isActive { session.runState = .running }
                    hooks.presentation.setAgentRunActive(session, true)
                    hooks.bindingObservation.updateBindings(session)
                    continue eventLoop
                }
                switch unprotectedTurnStatus {
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
            errorText: ClaudeAgentModeCoordinator.unexpectedStreamEndMessage,
            shouldShutdownSession: false
        )
    }

    /// A plural answer is one boundary: retire every target before deciding whether to return.
    /// nil means stale; false means a protected/partial completion; true means terminal.
    static func settleCompletedTurnIDs(_ ids: [UUID], session: AgentTabSession, waitForAllUnprotected: Bool = true) -> Bool? {
        settleCompletedTurnIDsWithProtection(ids, session: session, waitForAllUnprotected: waitForAllUnprotected)?.terminal
    }

    private static func settleCompletedTurnIDsWithProtection(
        _ ids: [UUID], session: AgentTabSession, waitForAllUnprotected: Bool,
        previouslyAnsweredUnprotected: Bool = false,
        liveSuccessorProviderIDs: Set<UUID> = []
    ) -> (terminal: Bool, answeredUnprotected: Bool)? {
        let matched = Set(ids).intersection(session.claudeExpectedTurnIDs)
        guard !matched.isEmpty else { return nil }
        let explicitlyProtected = matched.intersection(session.claudeSupersedingProtectedTurnIDs)
        let legacyProtectedCount = session.claudeSupersedingProtectedTurnIDs.isEmpty
            && session.pendingSupersedingTurnCompletions > 0 ? 1 : 0
        session.claudeExpectedTurnIDs.subtract(matched)
        session.claudeSupersedingProtectedTurnIDs.subtract(matched)
        session.pendingSupersedingTurnCompletions = max(
            0, session.pendingSupersedingTurnCompletions - explicitlyProtected.count - legacyProtectedCount
        )
        let answeredUnprotected = matched.count > explicitlyProtected.count + legacyProtectedCount
        let otherUnprotected = session.claudeExpectedTurnIDs.subtracting(session.claudeSupersedingProtectedTurnIDs)
        // A later provider execution is already in this inbox. Keep its owner until
        // its result; an unread-tail handback cannot recover a consumed start event.
        // Pre-send predecessors remain protected but do not hold up the host answer.
        guard answeredUnprotected || previouslyAnsweredUnprotected,
              liveSuccessorProviderIDs.isDisjoint(with: session.claudeExpectedTurnIDs),
              answeredUnprotected || (session.pendingClaudeSteeringInstructions.isEmpty && session.claudeSteeringFlushTask == nil),
              !previouslyAnsweredUnprotected || otherUnprotected.isEmpty,
              !waitForAllUnprotected || otherUnprotected.isEmpty
        else {
            return (false, answeredUnprotected)
        }
        session.pendingSupersedingTurnCompletions = 0
        session.claudeSupersedingProtectedTurnIDs.removeAll()
        return (true, answeredUnprotected)
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
        classifiesQuietCheckIn: Bool = false,
        shouldShutdownSession: Bool = false
    ) async -> AgentRunTerminalCommitRevision? {
        await terminalCommitBarrier.commit(.init(
            binding: claudeCoordinator.bindingQuietDeclarationObservations(
                hooks.bindTerminalSession(session), session: session, owner: ownership, runID: runID
            ),
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
            classifiesQuietCheckIn: classifiesQuietCheckIn,
            terminalAnchor: session.terminalAnchor(for: ownership),
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
