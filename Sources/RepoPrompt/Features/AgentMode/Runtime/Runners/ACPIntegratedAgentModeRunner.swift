import Foundation
import MCP
import RepoPromptACPProviders
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptSettingsCore

@MainActor
final class ACPIntegratedAgentModeRunner {
    private enum PromptPhase { case setup, entered, providerDispatch }

    private enum TransientOperationResult {
        case completed
        case cancelled
        /// Reused setup was interrupted before sending; retain the warm controller.
        case cancelledBeforeSend
        case failed(errorText: String?)
        /// A provider control command refused before anything reached the provider. It fails the run
        /// like `.failed`, but the live controller it was addressed to is left in place: nothing about
        /// that session changed, so tearing it down would only discard the target's warm session.
        case refusedBeforeSend(errorText: String)
        /// The provider failed a dispatched turn but attests its session stayed open. The run fails,
        /// and the warm controller is kept so the next user message reuses it; the turn is not resent.
        case failedRetainingController(errorText: String?)
        case superseded

        var debugDescription: String {
            switch self {
            case .completed:
                "state=completed error=nil"
            case .cancelled:
                "state=cancelled error=nil"
            case .cancelledBeforeSend:
                "state=cancelledBeforeSend error=nil"
            case let .failed(errorText):
                "state=failed error=\(errorText ?? "nil")"
            case let .refusedBeforeSend(errorText):
                "state=refusedBeforeSend error=\(errorText)"
            case let .failedRetainingController(errorText):
                "state=failedRetainingController error=\(errorText ?? "nil")"
            case .superseded:
                "state=superseded error=nil"
            }
        }
    }

    private struct TransientExecutionClassification {
        let report: DomainAgentRunExecutionReport
        let errorText: String?
        var retainsController = false
    }

    /// Set when a provider control command's run ends without anything reaching the provider and
    /// its controller is retained, so the deferred lease is cleaned up as after a completed turn
    /// rather than signalling a routing failure for the run ID the retained controller keeps using.
    private final class ProviderControlLeaseDisposition {
        var controllerRetained = false
    }

    private struct ExplicitTerminalFailure: Error {
        let errorText: String?
    }

    /// A provider control command that completes in under this span with no transcript output is
    /// treated as fire-and-forget: the provider may still be working in the background. The bound
    /// exists to exclude a hypothetical in-turn compaction (real model work, many seconds), and is
    /// deliberately forgiving of main-actor stalls — a missed note only loses the hint, never
    /// misreports the outcome.
    private static let acpFireAndForgetCommandWindow: TimeInterval = 5

    /// How long a fire-and-forget ACP compaction is protected from a cancelling next prompt: the top
    /// of the provider's observed ~60–90 s background span.
    static let acpBackgroundCompactionSettleDuration: TimeInterval = 90

    private let hooks: AgentModeRunService.Hooks
    private let terminalCommitBarrier: AgentRunTerminalCommitBarrier
    private let toolTrackingHooks: AgentToolTrackingHooks
    private var toolTrackingByTabID: [UUID: AgentToolTrackingController] = [:]
    private var toolTrackingRunIDByTabID: [UUID: UUID] = [:]
    private enum ToolObservationSource: Equatable { case tracker, provider }
    private var acpTrackerInvocationIDsByTabID: [UUID: Set<UUID>] = [:]
    private var acpProviderInvocationIDsByTabID: [UUID: Set<UUID>] = [:]
    private var acpProviderInvocationByTrackerInvocationIDByTabID: [UUID: [UUID: UUID]] = [:]
    private var acpProviderPlaceholderInvocationIDsByTabID: [UUID: Set<UUID>] = [:]

    private func log(_ message: String, runID: UUID) {
        guard AgentRuntimeProviderService.enableDebugLogging else { return }
        print("[ACP-Runner] run=\(runID) \(message)")
    }

    private func displayText(for error: Error) -> String {
        Self.displayText(for: error)
    }

    private static func displayText(for error: Error) -> String {
        if let providerError = error as? AIProviderError {
            switch providerError {
            case .missingOllamaURL:
                return "Missing Ollama URL."
            case .missingAzureConfiguration:
                return "Missing Azure OpenAI configuration."
            case .missingAPIKey:
                return "Missing API key."
            case .missingURL:
                return "Missing provider URL."
            case .providerNotConfigured:
                return "Provider is not configured."
            case .invalidModel:
                return "Invalid model."
            case .invalidSystemPrompt:
                return "Invalid system prompt."
            case .messageCreationFailed:
                return "Failed to create provider message."
            case let .invalidResponse(detail), let .invalidConfiguration(detail):
                return detail
            case let .apiError(source), let .unknown(source):
                return source.map(displayText) ?? String(describing: providerError)
            }
        }
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty
        {
            return description
        }
        let nsError = error as NSError
        if nsError.domain != NSCocoaErrorDomain || nsError.code != 0 {
            let description = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            if !description.isEmpty, description != "The operation couldn’t be completed." {
                return description
            }
        }
        return String(describing: error)
    }

    private static func executeTransientOperation(
        _ operation: () async throws -> TransientOperationResult
    ) async -> TransientExecutionClassification {
        var explicitFailureText: String??
        var retainsController = false
        let report = await DomainAgentRunExecutionCore.execute(
            failureText: { error in
                if let failure = error as? ExplicitTerminalFailure {
                    return failure.errorText ?? ""
                }
                return displayText(for: error)
            }
        ) {
            switch try await operation() {
            case .completed:
                return .completed(assistantText: nil)
            case .cancelled:
                throw CancellationError()
            case .cancelledBeforeSend:
                retainsController = true
                throw CancellationError()
            case let .failed(errorText):
                explicitFailureText = .some(errorText)
                throw ExplicitTerminalFailure(errorText: errorText)
            case let .refusedBeforeSend(errorText):
                retainsController = true
                explicitFailureText = .some(errorText)
                throw ExplicitTerminalFailure(errorText: errorText)
            case let .failedRetainingController(errorText):
                retainsController = true
                explicitFailureText = .some(errorText)
                throw ExplicitTerminalFailure(errorText: errorText)
            case .superseded:
                return .superseded
            }
        }

        let errorText: String? = if case let .some(explicitText) = explicitFailureText {
            explicitText
        } else if case let .terminal(outcome) = report.result, outcome.kind == .failed {
            outcome.assistantText
        } else {
            nil
        }
        return TransientExecutionClassification(
            report: report,
            errorText: errorText,
            retainsController: retainsController
        )
    }

    init(
        hooks: AgentModeRunService.Hooks,
        terminalCommitBarrier: AgentRunTerminalCommitBarrier,
        toolTrackingHooks: AgentToolTrackingHooks
    ) {
        self.hooks = hooks
        self.terminalCommitBarrier = terminalCommitBarrier
        self.toolTrackingHooks = toolTrackingHooks
    }

    enum ExistingControllerProbe {
        case compatibility, reusability, replacementShutdown, controlCommand
    }

    enum StartupBoundary {
        case taskEntry, toolTrackingCompleted, leaseAcquired, acquireFailureOutcome
        case bootstrapStarting, bootstrapCompleted, resumeRecoveryStaged, configuration, routingReleased, prePromptFailure
        case reusabilityProbed, deferredLeaseAcquired, controlPromptAdmission, controlPromptPrepared
        case promptPrepared, promptStreamAcquired, providerInputProved
    }

    #if DEBUG
        var testAtStartupBoundary: ((StartupBoundary) -> Void)?
        var testPromptConsumerCreated: (() -> Void)?
        // Synchronous: tests invalidate ownership at a real post-await admission boundary.
        var testAfterExistingControllerProbe: ((ExistingControllerProbe) -> Void)?
    #endif

    func prepareRun(
        tabID: UUID,
        session: AgentTabSession,
        origin: AgentSessionRuntimeStore.Command,
        workspace: AgentRunWorkspaceInput,
        initialUserMessage: String,
        initialMessageForRun: String,
        attachments: [AgentFileAttachment],
        runRequest: ACPRunRequest,
        startOutcome: AgentRunStartOutcomeRecorder? = nil,
        providerControlCommand: AgentProviderControlCommand? = nil,
        makeLease: @escaping (_ runID: UUID) -> MCPBootstrapLease,
        stopFence: AgentRunStartStopFence? = nil,
        localComposerCandidate: UUID? = nil
    ) async -> AgentRunResourceRequest? {
        var candidateTransferred = false
        defer { if !candidateTransferred, origin.writer.session === session, origin.writer.ownsPersistentClaim { session.settleLocalComposerOrigin(localComposerCandidate, disposition: .retained) } }
        guard let receipt = AgentSessionRuntimeStore.WriterReceipt(origin),
              origin.writer.session === session, origin.isCurrent
        else { return nil }
        guard session.operationAdmissionFailureMessage == nil else { return nil }
        guard stopFence?.permitsStart(of: session) ?? true else { return nil }
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

        guard stopFence?.permitsStart(of: session) ?? true else { return nil }
        let binding = session.currentRestorationBindingToken
        let ownership = session.beginRunAttempt(source: "acp")
        session.acpWorkspaceAdmission = AgentACPWorkspaceAdmission(input: workspace, ownership: ownership, session: session)
        let runAttemptID = ownership.attemptID
        session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .preparingRuntime)
        session.runState = .running
        hooks.presentation.setAgentRunActive(session, true)
        setRunningStatus(initialTransportStatusText(for: runRequest.agentKind), source: .transport, session: session, urgent: true)

        let dedicatedNoteID = AgentSelfCompactParkedPrefix.preparedDedicatedNoteID(
            initialMessageForRun, session: session
        )
        var handedToRunTask = false
        defer {
            if let dedicatedNoteID, !handedToRunTask, origin.writer.ownsPersistentClaim {
                AgentSelfCompactParkedPrefix.reparkUnattemptedDedicatedNote(
                    dedicatedNoteID, session: session
                ) { hooks.persistence.scheduleSave(session) }
            }
        }
        let freshRunRequest = runRequest
        let admitExistingController: (ExistingControllerProbe, ACPAgentSessionController?) async -> Bool = { [self] probe, controller in
            #if DEBUG
                testAfterExistingControllerProbe?(probe)
            #endif
            guard isStartupStillCurrent(session: session, runAttemptID: runAttemptID) else {
                startOutcome?.recordStartFailure(message: nil)
                return false
            }
            if origin.isCurrent, session.acpController === controller { return true }
            startOutcome?.recordStartFailure(message: nil)
            // A lost claim cannot retire a controller or settle attachments now shared with a
            // successor. The still-exclusive original claim can cancel this unsent attempt.
            if origin.writer.ownsPersistentClaim, session.currentRestorationBindingToken == binding {
                await cancelExistingControllerStartupBeforeSend(
                    session: session, ownership: ownership, attachmentReservationID: attachmentReservationID
                )
            }
            return false
        }
        // A provider control command acts only on the live session that advertised it. It never
        // replaces, starts, or shuts down a controller, so it cannot fall through to a fresh one.
        if let providerControlCommand {
            await startProviderControlCommandRun(
                tabID: tabID,
                session: session,
                ownership: ownership,
                command: providerControlCommand,
                runRequest: runRequest,
                attachmentReservationID: attachmentReservationID,
                admitExistingController: admitExistingController,
                receipt: receipt,
                makeLease: makeLease
            )
            return nil
        }
        if dedicatedNoteID != nil, session.acpController == nil {
            await failProviderControlCommandBeforeSend(
                session: session,
                runAttemptID: runAttemptID,
                attachmentReservationID: attachmentReservationID,
                errorText: "The self-compaction note has no live ACP session, so it was not sent."
            )
            return nil
        }
        if let existingController = session.acpController {
            let isCompatible = await existingController.isCompatibleWith(request: runRequest)
            guard await admitExistingController(.compatibility, existingController) else { return nil }
            let hasReusableSession = isCompatible ? await existingController.hasReusableSession : false
            guard await admitExistingController(.reusability, existingController) else { return nil }
            if dedicatedNoteID != nil, !isCompatible || !hasReusableSession
                || AgentModeProcessRunIdentity.existingProcessRunID(for: session) == nil
            {
                await failProviderControlCommandBeforeSend(
                    session: session,
                    runAttemptID: runAttemptID,
                    attachmentReservationID: attachmentReservationID,
                    errorText: "The self-compaction note could not reuse its live ACP session, so it was not sent."
                )
                return nil
            }
            if isCompatible,
               hasReusableSession,
               let runID = AgentModeProcessRunIdentity.existingProcessRunID(for: session)
            {
                guard isStartupStillCurrent(session: session, runID: runID, runAttemptID: runAttemptID) else { return nil }
                launchReusedSessionRun(
                    tabID: tabID,
                    session: session,
                    ownership: ownership,
                    runID: runID,
                    initialMessageForRun: initialMessageForRun,
                    dedicatedNoteID: dedicatedNoteID,
                    attachments: attachments,
                    controller: existingController,
                    runRequest: runRequest,
                    attachmentReservationID: attachmentReservationID,
                    providerControlCommand: nil,
                    receipt: receipt,
                    makeLease: makeLease,
                    localComposerCandidate: localComposerCandidate
                )
                candidateTransferred = true
                handedToRunTask = true
                return nil
            }

            session.acpController = nil
            AgentModeProcessRunIdentity.clearProcessRunID(for: session)
            await existingController.shutdown()
            guard await admitExistingController(.replacementShutdown, nil) else { return nil }
        }
        guard origin.writer.ownsPersistentClaim else {
            startOutcome?.recordStartFailure(message: nil)
            return nil
        }
        let runID = AgentModeProcessRunIdentity.startFreshProcessRun(for: session)
        let lease = makeLease(runID)
        guard isStartupStillCurrent(session: session, runID: runID, runAttemptID: runAttemptID) else { return nil }

        let stillCurrent = { [self] in
            origin.isCurrent && session.currentRestorationBindingToken == binding
                && isStartupStillCurrent(session: session, runID: runID, runAttemptID: runAttemptID)
                && (stopFence?.permitsStart(of: session) ?? true)
        }
        // Construction owns this not-yet-acquired lease and any uninstalled controller. Losing
        // the writer does not authorize terminal publication or attachment mutation on a new claim.
        let abandon: (String?) async -> Void = { [self] errorText in
            if origin.writer.ownsPersistentClaim, session.currentRestorationBindingToken == binding {
                session.settleLocalComposerOrigin(localComposerCandidate, disposition: .retained)
                if let errorText {
                    await failBeforeProviderSend(
                        tabID: tabID, session: session, runID: runID, runAttemptID: runAttemptID,
                        attachmentReservationID: attachmentReservationID, errorText: errorText
                    )
                } else {
                    await cancelBeforeProviderSend(
                        session: session, runID: runID, runAttemptID: runAttemptID,
                        attachmentReservationID: attachmentReservationID
                    )
                }
            }
            startOutcome?.recordStartFailure(message: nil)
            await lease.cancelAndCleanup()
        }
        let refuse: () async -> Void = { await abandon(nil) }
        candidateTransferred = true
        return .acpProvider(
            agent: runRequest.agentKind,
            model: runRequest.modelString,
            preparation: AgentRunResourcePreparation(
                isCurrent: stillCurrent,
                refused: refuse,
                receive: { [self, session] result in
                    var candidateTransferred = false
                    defer { if !candidateTransferred, origin.writer.session === session, origin.writer.ownsPersistentClaim { session.settleLocalComposerOrigin(localComposerCandidate, disposition: .retained) } }
                    guard stillCurrent() else {
                        await refuse()
                        return nil
                    }
                    let provider: any ACPAgentProvider
                    do {
                        guard let created = try result.get() else {
                            await abandon("No ACP provider is registered for \(runRequest.agentKind.displayName).")
                            return nil
                        }
                        provider = created
                    } catch {
                        await abandon("ACP provider construction failed: \(error.localizedDescription)")
                        return nil
                    }
                    let support: ACPSupportResult
                    do {
                        support = try await provider.support(for: freshRunRequest)
                    } catch is CancellationError {
                        await abandon(nil)
                        return nil
                    } catch {
                        await abandon("ACP support preflight failed: \(error.localizedDescription)")
                        return nil
                    }
                    guard stillCurrent() else {
                        await refuse()
                        return nil
                    }
                    guard support == .supported else {
                        await abandon(support.reason ?? "\(runRequest.agentKind.displayName) ACP is not available.")
                        return nil
                    }
                    candidateTransferred = true
                    return .acpController(
                        provider: provider,
                        request: freshRunRequest,
                        preparation: AgentRunResourcePreparation(
                            isCurrent: stillCurrent,
                            refused: refuse,
                            receive: { [self, session] result in
                                var candidateTransferred = false
                                defer { if !candidateTransferred, origin.writer.session === session, origin.writer.ownsPersistentClaim { session.settleLocalComposerOrigin(localComposerCandidate, disposition: .retained) } }
                                let controller: ACPAgentSessionController
                                do {
                                    controller = try result.get()
                                } catch {
                                    await abandon("ACP controller init failed: \(error.localizedDescription)")
                                    return nil
                                }

                                guard stillCurrent() else {
                                    await controller.shutdown()
                                    await refuse()
                                    return nil
                                }
                                await controller.setExpectedMCPRunID(runID)
                                guard stillCurrent() else {
                                    await controller.shutdown()
                                    await refuse()
                                    return nil
                                }
                                session.acpController = controller
                                let requiresPrePromptMCPRouting = runRequest.agentKind.requiresPrePromptAgentModeMCPRouting
                                session.installRunAttemptTerminalResources(ownership: ownership) { [weak self] terminalState in
                                    let trackerTeardown = self?.prepareToolTrackingTeardown(for: session, matchingRunID: runID)
                                    return {
                                        await trackerTeardown?()
                                        switch terminalState {
                                        case .failed:
                                            if requiresPrePromptMCPRouting {
                                                await lease.failAndRelease()
                                            } else {
                                                await lease.failAndCleanup()
                                            }
                                        case .cancelled:
                                            await lease.cancelAndCleanup()
                                        case .completed:
                                            if !requiresPrePromptMCPRouting {
                                                await lease.cleanupDeferredRouting()
                                            }
                                        default:
                                            break
                                        }
                                    }
                                }
                                session.agentTask = Task { [weak self, weak session] in
                                    guard let session else { return }
                                    defer {
                                        if receipt.disposition(for: session) != .claimLost {
                                            session.settleLocalComposerOrigin(localComposerCandidate, disposition: .retained)
                                        }
                                    }
                                    guard let self else { return }
                                    guard await admitStartupTask(
                                        .taskEntry, session: session, runID: runID, runAttemptID: runAttemptID,
                                        controller: controller, receipt: receipt, attachmentReservationID: attachmentReservationID,
                                        retainsController: false
                                    ) else { return }
                                    if let clientNameHint = runRequest.agentKind.mcpClientNameHint {
                                        await startToolTracking(for: session, runID: runID, clientNameHint: clientNameHint)
                                    }
                                    guard await admitStartupTask(
                                        .toolTrackingCompleted, session: session, runID: runID, runAttemptID: runAttemptID,
                                        controller: controller, receipt: receipt, attachmentReservationID: attachmentReservationID,
                                        retainsController: false
                                    ) else { return }
                                    await withTaskCancellationHandler {
                                        await self.startFreshRun(
                                            tabID: tabID,
                                            session: session,
                                            runID: runID,
                                            runAttemptID: runAttemptID,
                                            initialMessageForRun: initialMessageForRun,
                                            attachments: attachments,
                                            controller: controller,
                                            runRequest: freshRunRequest,
                                            lease: lease,
                                            receipt: receipt,
                                            attachmentReservationID: attachmentReservationID,
                                            localComposerCandidate: localComposerCandidate
                                        )
                                    } onCancel: {}
                                }
                                candidateTransferred = true
                                startOutcome?.recordAccepted()
                                return nil
                            }
                        )
                    )
                }
            )
        )
    }

    /// Runs one turn on the session's existing, reusable controller.
    private func launchReusedSessionRun(
        tabID: UUID,
        session: AgentTabSession,
        ownership: AgentRunOwnership,
        runID: UUID,
        initialMessageForRun: String,
        dedicatedNoteID: AgentSelfCompactionDispatchID?,
        attachments: [AgentFileAttachment],
        controller: ACPAgentSessionController,
        runRequest: ACPRunRequest,
        attachmentReservationID: UUID?,
        providerControlCommand: AgentProviderControlCommand?,
        receipt: AgentSessionRuntimeStore.WriterReceipt,
        makeLease: @escaping (_ runID: UUID) -> MCPBootstrapLease,
        localComposerCandidate: UUID? = nil
    ) {
        let runAttemptID = ownership.attemptID
        let deferredLease = runRequest.agentKind.requiresPrePromptAgentModeMCPRouting
            ? nil
            : makeLease(runID)
        let leaseDisposition = providerControlCommand == nil ? nil : ProviderControlLeaseDisposition()
        session.installRunAttemptTerminalResources(ownership: ownership) { [weak self] terminalState in
            let trackerTeardown = self?.prepareToolTrackingTeardown(for: session, matchingRunID: runID)
            return {
                await trackerTeardown?()
                switch terminalState {
                case .failed where leaseDisposition?.controllerRetained == true:
                    await deferredLease?.cleanupDeferredRouting()
                case .failed:
                    await deferredLease?.failAndCleanup()
                case .cancelled:
                    await deferredLease?.cancelAndCleanup()
                case .completed:
                    await deferredLease?.cleanupDeferredRouting()
                default:
                    break
                }
            }
        }
        session.agentTask = Task { [weak self, weak session] in
            guard let session else { return }
            defer {
                if receipt.disposition(for: session) != .claimLost {
                    session.settleLocalComposerOrigin(localComposerCandidate, disposition: .retained)
                }
            }
            guard let self else { return }
            guard await admitStartupTask(
                .taskEntry, session: session, runID: runID, runAttemptID: runAttemptID,
                controller: controller, receipt: receipt, attachmentReservationID: attachmentReservationID,
                retainsController: true, dedicatedNoteID: dedicatedNoteID
            ) else { return }
            if let clientNameHint = runRequest.agentKind.mcpClientNameHint {
                await startToolTracking(for: session, runID: runID, clientNameHint: clientNameHint)
            }
            guard await admitStartupTask(
                .toolTrackingCompleted, session: session, runID: runID, runAttemptID: runAttemptID,
                controller: controller, receipt: receipt, attachmentReservationID: attachmentReservationID,
                retainsController: true, dedicatedNoteID: dedicatedNoteID
            ) else { return }
            await withTaskCancellationHandler {
                await self.continueRun(
                    tabID: tabID,
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    initialMessageForRun: initialMessageForRun,
                    dedicatedNoteID: dedicatedNoteID,
                    attachments: attachments,
                    controller: controller,
                    runRequest: runRequest,
                    deferredLease: deferredLease,
                    receipt: receipt,
                    attachmentReservationID: attachmentReservationID,
                    providerControlCommand: providerControlCommand,
                    leaseDisposition: leaseDisposition,
                    localComposerCandidate: localComposerCandidate
                )
            } onCancel: {}
        }
    }

    /// Starts a provider control command on the live controller that advertised it, or fails the run
    /// without touching that controller. The command text is RepoPrompt's own (`/compact`).
    private func startProviderControlCommandRun(
        tabID: UUID,
        session: AgentTabSession,
        ownership: AgentRunOwnership,
        command: AgentProviderControlCommand,
        runRequest: ACPRunRequest,
        attachmentReservationID: UUID?,
        admitExistingController: (ExistingControllerProbe, ACPAgentSessionController?) async -> Bool,
        receipt: AgentSessionRuntimeStore.WriterReceipt,
        makeLease: @escaping (_ runID: UUID) -> MCPBootstrapLease
    ) async {
        let runAttemptID = ownership.attemptID
        let displayName = runRequest.agentKind.displayName
        // A control command never carries the staged handoff, on any path: it stays for the next
        // ordinary turn.
        hooks.providerInput.recordPendingHandoffSendOutcome(session, false)
        guard let controller = session.acpController else {
            await failProviderControlCommandBeforeSend(
                session: session,
                runAttemptID: runAttemptID,
                attachmentReservationID: attachmentReservationID,
                errorText: "\(displayName) has no live ACP session, so the requested command was not run."
            )
            return
        }
        let isCompatible = await controller.isCompatibleWith(request: runRequest)
        guard await admitExistingController(.compatibility, controller) else { return }
        let hasReusableSession = await controller.hasReusableSession
        let isRetired = hasReusableSession ? false : await controller.isRetired
        guard await admitExistingController(.controlCommand, controller) else { return }
        guard hasReusableSession else {
            // A controller that can never run another turn is retired as after any failed turn; one
            // that is merely busy is left alone.
            await failProviderControlCommandBeforeSend(
                session: session,
                runAttemptID: runAttemptID,
                attachmentReservationID: attachmentReservationID,
                errorText: isRetired
                    ? "\(displayName) ACP session is no longer reusable, so the requested command was not run."
                    : "\(displayName) ACP session was busy, so the requested command was not run.",
                retiring: isRetired ? controller : nil
            )
            return
        }
        guard isCompatible,
              session.acpController === controller,
              let runID = AgentModeProcessRunIdentity.existingProcessRunID(for: session)
        else {
            await failProviderControlCommandBeforeSend(
                session: session,
                runAttemptID: runAttemptID,
                attachmentReservationID: attachmentReservationID,
                errorText: "\(displayName) could not reuse the live ACP session the requested command was for, so it was not run."
            )
            return
        }
        // Bind before handing the run to a task. Preparation can refuse before the command's
        // physical send seam; its terminal publication must still identify and settle this attempt.
        if let dispatchID = command.selfCompactDispatchID, dispatchID.stage == .compact {
            guard session.selfCompactDispatchIsCurrent?() != false,
                  session.selfCompactNativeCompletion?.bindCompact(
                      dispatchID, runID: runID, runAttemptID: runAttemptID
                  ) == true
            else {
                await failProviderControlCommandBeforeSend(
                    session: session, runAttemptID: runAttemptID,
                    attachmentReservationID: attachmentReservationID,
                    errorText: "\(displayName) did not run the requested command because self-compaction was no longer admissible."
                )
                return
            }
        }
        launchReusedSessionRun(
            tabID: tabID,
            session: session,
            ownership: ownership,
            runID: runID,
            initialMessageForRun: command.providerText,
            dedicatedNoteID: nil,
            attachments: [],
            controller: controller,
            runRequest: runRequest,
            attachmentReservationID: attachmentReservationID,
            providerControlCommand: command,
            receipt: receipt,
            makeLease: makeLease
        )
    }

    /// Fails a provider control command's run before any provider work. The session's controller and
    /// process-run identity stay exactly as they were, unless `retiring` names a controller that can
    /// no longer run turns, which is detached and shut down as after any failed turn.
    private func failProviderControlCommandBeforeSend(
        session: AgentTabSession,
        runAttemptID: UUID,
        attachmentReservationID: UUID?,
        errorText: String,
        retiring deadController: ACPAgentSessionController? = nil
    ) async {
        guard isStartupStillCurrent(session: session, runAttemptID: runAttemptID),
              let ownership = session.activeRunOwnership,
              ownership.attemptID == runAttemptID
        else { return }
        await terminalCommitBarrier.commit(.init(
            binding: hooks.bindTerminalSession(session),
            ownership: ownership,
            expectedRunID: session.runID,
            terminalState: .failed,
            source: "acp.providerControlRefused",
            errorText: errorText,
            attachmentReservationID: attachmentReservationID,
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: true,
            supportsFollowUp: false,
            notifyTurnComplete: false,
            prepareProviderState: {
                guard let deadController else { return nil }
                // Only the session's own controller and run identity are retired; a controller that
                // replaced it meanwhile keeps both.
                if session.acpController === deadController {
                    session.acpController = nil
                    AgentModeProcessRunIdentity.clearProcessRunID(for: session)
                }
                return { await deadController.shutdown() }
            }
        ))
    }

    func submitActivePrompt(
        session: AgentTabSession,
        messageForRun: String,
        attachments: [AgentFileAttachment],
        runRequest: ACPRunRequest,
        targetRunID: UUID?,
        targetRunAttemptID: UUID?,
        targetController: ACPAgentSessionController,
        writeReceipt: ACPAgentSessionController.PromptWriteReceipt? = nil
    ) async -> Bool {
        guard session.operationAdmissionFailureMessage == nil else { return false }
        guard runRequest.agentKind == session.selectedAgent,
              runRequest.agentKind.acpProviderID != nil,
              session.runState == .running,
              let controller = session.acpController,
              controller === targetController,
              let runID = session.runID,
              runID == targetRunID,
              let runAttemptID = session.activeRunAttemptID,
              runAttemptID == targetRunAttemptID
        else {
            let diagnosticRunID = session.runID ?? targetRunID ?? UUID()
            log("active prompt preflight rejected selected=\(session.selectedAgent.rawValue) request=\(runRequest.agentKind.rawValue) state=\(session.runState.rawValue) runID=\(String(describing: session.runID)) targetRunID=\(String(describing: targetRunID)) attempt=\(String(describing: session.activeRunAttemptID)) targetAttempt=\(String(describing: targetRunAttemptID)) hasController=\(session.acpController != nil) controllerMatches=\(session.acpController === targetController)", runID: diagnosticRunID)
            return false
        }
        guard await controller.isCompatibleWith(request: runRequest) else {
            log("active prompt preflight rejected incompatible ACP request model=\(runRequest.modelString ?? "default") workspace=\(runRequest.workspacePath ?? "nil")", runID: runID)
            return false
        }
        guard session.runState == .running,
              session.runID == runID,
              session.activeRunAttemptID == runAttemptID,
              session.acpController === controller
        else {
            log("active prompt preflight became stale after compatibility check state=\(session.runState.rawValue) runID=\(String(describing: session.runID)) attempt=\(String(describing: session.activeRunAttemptID))", runID: runID)
            return false
        }

        setRunningStatus("Thinking…", source: .transport, session: session, urgent: true)
        // Active steering must not reconfigure ACP session mode/model. Agent-mode UI
        // locks provider selection while a run is active, and reapplying Cursor/OpenCode
        // dynamic model aliases (notably Cursor `auto`) can fail before session/cancel.

        setRunningStatus("Interrupting…", source: .transport, session: session, urgent: true)
        log("active steering interrupt begin attempt=\(runAttemptID)", runID: runID)
        do {
            try await controller.interruptActivePromptForSteering()
            log("active steering interrupt settled attempt=\(runAttemptID)", runID: runID)
        } catch {
            let normalized = await controller.normalizeError(error)
            let normalizedText = displayText(for: normalized)
            log("active steering interrupt failed attempt=\(runAttemptID) raw=\(String(describing: error)) normalized=\(normalizedText)", runID: runID)
            return false
        }

        guard session.runState == .running,
              session.runID == runID,
              session.activeRunAttemptID == runAttemptID,
              session.acpController === controller
        else {
            log("active steering became stale after interrupt state=\(session.runState.rawValue) currentRunID=\(String(describing: session.runID)) currentAttempt=\(String(describing: session.activeRunAttemptID))", runID: runID)
            return false
        }

        var carry = AgentSelfCompactParkedPrefix.prepare(messageForRun, session: session) {
            hooks.persistence.scheduleSave(session)
        }
        if let dispatchID = carry.dispatchID,
           !session.selfCompactNoteDispatchIsCurrent(dispatchID)
        {
            if carry.exactNote { return false }
            carry = .init(text: messageForRun, dispatchID: nil)
        }
        let agentMessage = carry.exactNote
            ? AgentMessage(systemPrompt: "", userMessage: carry.text, resumeSessionID: session.providerSessionID)
            : hooks.providerInput.buildHeadlessAgentMessage(
                session,
                carry.text,
                runID,
                attachments
            )
        // Active ACP steering is its own logical dispatch. A false return proves only that
        // completion was not observed. The caller must consult its write receipt before
        // requeueing: a written prompt with a lost response must never be replayed.
        let oversightDispatch = AgentSessionLinkPromptDispatchID.acpActiveSteering(runAttemptID: runAttemptID)
        var monitoring: AgentModeRunService.AgentSessionLinkDecoratedAgentMessage?
        defer { withExtendedLifetime(monitoring?.quietMarkerProducerLifetime) {} }
        var inputProof: AgentSessionLinkProviderInputRelease.Proof?
        if !carry.exactNote {
            let decorated = hooks.providerInput.decoratedAgentMessage(
                agentMessage,
                session: session,
                dispatchID: oversightDispatch
            )
            guard !decorated.mustAbortDispatch else {
                hooks.providerInput.recordAgentSessionLinkPhysicalDispatchNotAttempted(
                    session,
                    oversightDispatch
                )
                return false
            }
            inputProof = await hooks.providerInput.proveAgentSessionLinkProviderInput(session, decorated.claim)
            guard !Task.isCancelled, session.runID == runID,
                  session.activeRunAttemptID == runAttemptID, session.acpController === controller
            else {
                hooks.providerInput.recordAgentSessionLinkPhysicalDispatchNotAttempted(session, oversightDispatch)
                return false
            }
            guard hooks.providerInput.acquireAgentSessionLinkPhysicalDispatch(
                session,
                oversightDispatch
            ) else {
                hooks.providerInput.recordAgentSessionLinkPhysicalDispatchNotAttempted(
                    session,
                    oversightDispatch
                )
                return false
            }
            monitoring = decorated
        }
        if let dispatchID = carry.dispatchID {
            guard session.selfCompactNoteDispatchIsCurrent(dispatchID),
                  AgentSelfCompactParkedPrefix.markAttempted(dispatchID, session: session)
            else {
                // The failed claim does not own an attempt marker to clear.
                if !carry.exactNote {
                    hooks.providerInput.recordAgentSessionLinkPhysicalDispatchFailure(session, oversightDispatch)
                }
                return false
            }
            hooks.persistence.scheduleSave(session)
        }

        do {
            log("active steering session/prompt begin attempt=\(runAttemptID)", runID: runID)
            let released = inputProof.map { hooks.providerInput.handoffAgentSessionLinkProviderInput(session, oversightDispatch, monitoring?.claim, $0) }
            guard released?.mustAbortDispatch != true else { return false }
            let oracle = carry.exactNote ? nil : session.oracleBackgroundAwareness.reserve(session: session, providerID: ObjectIdentifier(controller))
            defer { session.oracleBackgroundAwareness.release(oracle) }
            let outbound = released?.message(agentMessage) ?? agentMessage
            try await controller.prompt(oracle?.decorating(outbound) ?? outbound, request: runRequest, writeReceipt: writeReceipt)
            session.oracleBackgroundAwareness.accept(oracle)
            if let monitoring {
                hooks.providerInput.acceptAgentSessionLinkPrompt(
                    session, monitoring.dispatchContext, released?.claim
                )
            }
            if let dispatchID = carry.dispatchID {
                if AgentSelfCompactParkedPrefix.markAccepted(dispatchID, session: session) {
                    hooks.presentation.requestUIRefresh(session, true)
                    hooks.bindingObservation.updateBindings(session)
                }
                hooks.persistence.scheduleSave(session)
            }
            log("active steering session/prompt completed attempt=\(runAttemptID)", runID: runID)
            let identity = await controller.currentProviderSessionIdentity()
            applyProviderSessionIdentity(identity, session: session)
            // A successful prompt return means the steering prompt was delivered and
            // completed at the ACP layer. The event consumer may already have handled
            // the terminal and finalized the run, so do not require the original
            // activeRunAttemptID to still be present here.
            return true
        } catch {
            if let dispatchID = carry.dispatchID {
                AgentSelfCompactParkedPrefix.markTransportFailed(dispatchID, session: session)
                hooks.persistence.scheduleSave(session)
            }
            if !carry.exactNote {
                hooks.providerInput.recordAgentSessionLinkPhysicalDispatchFailure(
                    session,
                    oversightDispatch
                )
            }
            let identity = await controller.refreshProviderSessionIdentityAfterPromptInterruption()
            applyProviderSessionIdentity(identity, session: session)
            let normalized = await controller.normalizeError(error)
            let normalizedText = displayText(for: normalized)
            log("active steering session/prompt failed attempt=\(runAttemptID) raw=\(String(describing: error)) normalized=\(normalizedText)", runID: runID)
            return false
        }
    }

    private func ownsOriginalAttemptOrTerminal(_ session: AgentTabSession, runID: UUID, runAttemptID: UUID) -> Bool {
        (session.activeRunOwnership?.attemptID == runAttemptID && session.runID == runID)
            || (
                session.activeRunOwnership == nil
                    && session.lastTerminalCommitRevision?.ownership.attemptID == runAttemptID
                    && session.lastTerminalCommitRevision?.expectedRunID == runID
            )
    }

    private func isStartupStillCurrent(
        session: AgentTabSession,
        runID: UUID? = nil,
        runAttemptID: UUID
    ) -> Bool {
        guard session.activeRunAttemptID == runAttemptID,
              session.runState.isActive
        else {
            return false
        }
        if let runID {
            return session.runID == runID
        }
        return true
    }

    private func failBeforeProviderSend(
        tabID _: UUID,
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID,
        attachmentReservationID: UUID?,
        errorText: String
    ) async {
        guard isStartupStillCurrent(session: session, runID: runID, runAttemptID: runAttemptID),
              let ownership = session.activeRunOwnership,
              ownership.attemptID == runAttemptID
        else { return }
        hooks.providerInput.recordPendingHandoffSendOutcome(session, false)
        await terminalCommitBarrier.commit(.init(
            binding: hooks.bindTerminalSession(session),
            ownership: ownership,
            expectedRunID: runID,
            terminalState: .failed,
            source: "acp.startupFailure",
            errorText: errorText,
            attachmentReservationID: attachmentReservationID,
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: true,
            supportsFollowUp: false,
            notifyTurnComplete: false,
            prepareProviderState: {
                session.acpController = nil
                AgentModeProcessRunIdentity.clearProcessRunID(for: session)
                return nil
            }
        ))
    }

    /// No provider work was admitted. Keep the warm controller and process identity: cancelling
    /// this attempt is not permission to retire a controller installed by another operation.
    private func cancelExistingControllerStartupBeforeSend(
        session: AgentTabSession,
        ownership: AgentRunOwnership,
        attachmentReservationID: UUID?
    ) async {
        guard isStartupStillCurrent(session: session, runAttemptID: ownership.attemptID),
              session.activeRunOwnership == ownership else { return }
        hooks.providerInput.recordPendingHandoffSendOutcome(session, false)
        await terminalCommitBarrier.commit(.init(
            binding: hooks.bindTerminalSession(session), ownership: ownership,
            expectedRunID: session.runID, terminalState: .cancelled,
            source: "acp.existingControllerStartupCancelled",
            attachmentReservationID: attachmentReservationID, attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: true, supportsFollowUp: false, notifyTurnComplete: false,
            prepareProviderState: { nil }
        ))
    }

    private func cancelBeforeProviderSend(
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID,
        attachmentReservationID: UUID?
    ) async {
        guard isStartupStillCurrent(session: session, runID: runID, runAttemptID: runAttemptID),
              let ownership = session.activeRunOwnership,
              ownership.attemptID == runAttemptID
        else { return }
        hooks.providerInput.recordPendingHandoffSendOutcome(session, false)
        await terminalCommitBarrier.commit(.init(
            binding: hooks.bindTerminalSession(session),
            ownership: ownership,
            expectedRunID: runID,
            terminalState: .cancelled,
            source: "acp.startupCancelled",
            attachmentReservationID: attachmentReservationID,
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: true,
            supportsFollowUp: false,
            notifyTurnComplete: false,
            prepareProviderState: {
                session.acpController = nil
                AgentModeProcessRunIdentity.clearProcessRunID(for: session)
                return nil
            }
        ))
    }

    /// Before prompt entry, only the admitted writer may publish or advance this
    /// attempt. Lost claims leave installed resources to the current owner's Stop path.
    private func admitStartupTask(
        _ boundary: StartupBoundary,
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID,
        controller: ACPAgentSessionController,
        receipt: AgentSessionRuntimeStore.WriterReceipt,
        attachmentReservationID: UUID?,
        retainsController: Bool,
        dedicatedNoteID: AgentSelfCompactionDispatchID? = nil
    ) async -> Bool {
        #if DEBUG
            testAtStartupBoundary?(boundary)
        #endif
        guard isStartupStillCurrent(session: session, runID: runID, runAttemptID: runAttemptID),
              session.acpController === controller
        else { return false }
        switch receipt.disposition(for: session) {
        case .current:
            return true
        case .claimLost:
            return false
        case .ownedSuspended:
            hooks.providerInput.recordPendingHandoffSendOutcome(session, false)
            if let dedicatedNoteID {
                AgentSelfCompactParkedPrefix.reparkUnattemptedDedicatedNote(
                    dedicatedNoteID, session: session
                ) { hooks.persistence.scheduleSave(session) }
            }
            await finalize(
                session: session, runID: runID, runAttemptID: runAttemptID,
                controller: controller, attachmentReservationID: attachmentReservationID,
                terminalState: .cancelled, errorText: nil, notifyTurnComplete: false,
                shouldShutdownController: !retainsController, retainsController: retainsController
            )
            return false
        }
    }

    private func startFreshRun(
        tabID: UUID,
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID,
        initialMessageForRun: String,
        attachments: [AgentFileAttachment],
        controller: ACPAgentSessionController,
        runRequest: ACPRunRequest,
        lease: MCPBootstrapLease,
        receipt: AgentSessionRuntimeStore.WriterReceipt,
        attachmentReservationID: UUID?,
        localComposerCandidate: UUID? = nil
    ) async {
        let isPeriodic = session.oversight.pendingAutoWake?.isPeriodic == true
        let modelDescription = runRequest.modelString ?? "default"
        let resumeDescription = runRequest.resumeSessionID ?? "nil"
        let workspaceDescription = runRequest.workspacePath ?? "nil"
        log("fresh start begin model=\(modelDescription) resume=\(resumeDescription) workspace=\(workspaceDescription)", runID: runID)
        let acquired = await lease.acquire()
        guard acquired else {
            log("lease acquire failed", runID: runID)
            await handleAcquireFailure(
                tabID: tabID,
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                controller: controller,
                lease: lease,
                receipt: receipt,
                attachmentReservationID: attachmentReservationID
            )
            return
        }
        guard await admitStartupTask(
            .leaseAcquired, session: session, runID: runID, runAttemptID: runAttemptID,
            controller: controller, receipt: receipt, attachmentReservationID: attachmentReservationID,
            retainsController: false
        ) else {
            // This lease's serialization gate is operation-local. Policy and controller cleanup
            // remain with the installed attempt's terminal resources, not the stale task.
            await lease.releaseGateForDeferredRouting()
            return
        }

        let admitFresh: @MainActor (StartupBoundary) async -> Bool = { [self] boundary in
            await admitStartupTask(
                boundary, session: session, runID: runID, runAttemptID: runAttemptID,
                controller: controller, receipt: receipt, attachmentReservationID: attachmentReservationID,
                retainsController: false
            )
        }
        var providerInitializationCompleted = false
        var phase = PromptPhase.setup
        let classification = await Self.executeTransientOperation {
            do {
                let providerName = runRequest.agentKind.rawValue
                await lease.providerInitializationStarted(provider: providerName)
                guard await admitFresh(.bootstrapStarting) else { return .superseded }
                log("bootstrap begin", runID: runID)
                let bootstrap = try await controller.bootstrap()
                providerInitializationCompleted = true
                await lease.providerInitializationCompleted(provider: providerName, outcome: "ready")
                log("bootstrap completed sessionID=\(bootstrap.sessionID)", runID: runID)
                guard await admitFresh(.bootstrapCompleted) else {
                    // Preserve cleanup of a late bootstrap after Stop detached this controller,
                    // but never retire the controller still reachable by a successor attempt.
                    if session.acpController !== controller { await controller.shutdown() }
                    return .superseded
                }
                guard let ingressOwner = session.activeRunOwnership,
                      session.isCurrentRunAttemptForCurrentBinding(ingressOwner)
                else { throw CancellationError() }
                var initialMessageForPromptTurn = initialMessageForRun
                if bootstrap.didFallbackToNewSessionAfterLoadFailure {
                    // Periodic turns preserve handoffs, so they cannot adopt a contextless replacement.
                    // Existing cancellation cleanup retires this unprompted controller.
                    guard !isPeriodic else { throw CancellationError() }

                    let stagedRecovery = await hooks.providerInput.stageResumeRecoveryHandoffIfNeeded(session)
                    guard await admitFresh(.resumeRecoveryStaged) else { return .superseded }
                    guard stagedRecovery, !Task.isCancelled,
                          session.isCurrentRunAttemptForCurrentBinding(ingressOwner, expectedRunID: runID)
                    else { throw CancellationError() }
                    initialMessageForPromptTurn = hooks.providerInput.prependPendingHandoffIfNeeded(initialMessageForRun, session)
                }
                applyProviderSessionIdentity(
                    bootstrap.providerSessionIdentity,
                    invalidatedResumeSessionID: bootstrap.invalidatedResumeSessionID,
                    session: session
                )
                _ = syncACPSelectedModelFromRegistryIfNeeded(agentKind: runRequest.agentKind, session: session)
                session.isDirty = true
                hooks.persistence.scheduleSave(session)
                hooks.bindingObservation.updateBindings(session)

                guard try await configureControllerForRun(
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    controller: controller,
                    runRequest: runRequest,
                    admission: { [self] in
                        #if DEBUG
                            testAtStartupBoundary?(.configuration)
                        #endif
                        return receipt.disposition(for: session) == .current
                            && isStartupStillCurrent(session: session, runID: runID, runAttemptID: runAttemptID)
                            && session.acpController === controller
                    }
                ) else {
                    // A temporary interruption must not resume a partially applied sequence.
                    guard await admitFresh(.configuration) else { return .superseded }
                    throw CancellationError()
                }
                setRunningStatus(waitingForConnectionStatusText(for: runRequest.agentKind), source: .transport, session: session, urgent: true)

                if runRequest.agentKind.requiresPrePromptAgentModeMCPRouting {
                    let routed = await lease.releaseWhenRouted()
                    log("releaseWhenRouted routed=\(routed)", runID: runID)
                    guard routed else {
                        return .failed(
                            errorText: "RepoPrompt MCP routing did not complete before \(runRequest.agentKind.displayName) ACP prompt submission."
                        )
                    }
                } else {
                    await lease.releaseGateForDeferredRouting()
                    log("deferred MCP routing until ACP prompt", runID: runID)
                }

                guard await admitFresh(.routingReleased) else { return .superseded }
                let events = await controller.events
                guard await admitFresh(.promptStreamAcquired) else { return .superseded }
                phase = .entered
                return await runPromptTurn(
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    initialMessageForRun: initialMessageForPromptTurn,
                    attachments: attachments,
                    controller: controller,
                    runRequest: runRequest,
                    attachmentReservationID: attachmentReservationID,
                    events: events, receipt: receipt, retainsControllerOnRefusal: false, phase: &phase,
                    localComposerCandidate: localComposerCandidate
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let normalized = await controller.normalizeError(error)
                let normalizedText = displayText(for: normalized)
                log("fresh start failed raw=\(String(describing: error)) normalized=\(normalizedText)", runID: runID)
                #if DEBUG
                    if phase == .setup { testAtStartupBoundary?(.prePromptFailure) }
                #endif
                return .failed(errorText: normalizedText)
            }
        }

        if !providerInitializationCompleted,
           case let .terminal(outcome) = classification.report.result,
           outcome.kind == .cancelled || outcome.kind == .failed
        {
            await lease.providerInitializationCompleted(
                provider: runRequest.agentKind.rawValue,
                outcome: outcome.kind == .cancelled ? "cancelled" : "failed"
            )
        }
        if case let .terminal(outcome) = classification.report.result, outcome.kind == .cancelled {
            log("fresh start cancelled", runID: runID)
        }
        // Normalize/diagnostic awaits can also lose the claim. Only this operation's gate
        // may be released; current-owner Stop retains installed policy/controller cleanup.
        if phase != .providerDispatch {
            if phase == .setup {
                if case .superseded = classification.report.result {
                    await lease.releaseGateForDeferredRouting()
                } else if receipt.disposition(for: session) == .claimLost {
                    await lease.releaseGateForDeferredRouting()
                }
            }
            guard receipt.disposition(for: session) != .claimLost else { return }
        }
        await settleTransientExecution(
            classification,
            session: session,
            runID: runID,
            runAttemptID: runAttemptID,
            controller: controller,
            attachmentReservationID: attachmentReservationID
        )
    }

    private func continueRun(
        tabID _: UUID,
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID,
        initialMessageForRun: String,
        dedicatedNoteID: AgentSelfCompactionDispatchID?,
        attachments: [AgentFileAttachment],
        controller: ACPAgentSessionController,
        runRequest: ACPRunRequest,
        deferredLease: MCPBootstrapLease?,
        receipt: AgentSessionRuntimeStore.WriterReceipt,
        attachmentReservationID: UUID?,
        providerControlCommand: AgentProviderControlCommand? = nil,
        leaseDisposition: ProviderControlLeaseDisposition? = nil,
        localComposerCandidate: UUID? = nil
    ) async {
        var phase = PromptPhase.setup
        let admitReused: (StartupBoundary) async -> Bool = { [self] boundary in
            await admitStartupTask(
                boundary, session: session, runID: runID, runAttemptID: runAttemptID,
                controller: controller, receipt: receipt, attachmentReservationID: attachmentReservationID,
                retainsController: true, dedicatedNoteID: dedicatedNoteID
            )
        }
        let classification = await Self.executeTransientOperation {
            defer {
                // Stop may already have ended this attempt. Its exact terminal receipt permits
                // re-parking, but a later attempt (even on the same writer) must remain untouched.
                let originalAttempt = session.activeRunOwnership?.attemptID == runAttemptID
                    || (
                        session.activeRunOwnership == nil
                            && session.lastTerminalCommitRevision?.ownership.attemptID == runAttemptID
                            && session.lastTerminalCommitRevision?.expectedRunID == runID
                    )
                if let dedicatedNoteID, phase == .setup, originalAttempt,
                   receipt.disposition(for: session) != .claimLost
                {
                    AgentSelfCompactParkedPrefix.reparkUnattemptedDedicatedNote(
                        dedicatedNoteID, session: session
                    ) { hooks.persistence.scheduleSave(session) }
                }
            }
            do {
                // A controller that can no longer run turns is retired as after any failed turn, even
                // when the turn was a control command that never got as far as sending.
                let reusable = await controller.hasReusableSession
                let retired = !reusable && providerControlCommand != nil ? await controller.isRetired : false
                guard await admitReused(.reusabilityProbed) else { return .superseded }
                guard reusable else {
                    guard providerControlCommand != nil else {
                        return .failed(errorText: "\(runRequest.agentKind.displayName) ACP session is no longer reusable.")
                    }
                    return Self.controlCommandUnreusableOutcome(isRetired: retired, runRequest: runRequest)
                }

                // A control command runs in the session exactly as it is: applying the run's model or
                // mode selections would be provider work the overseer never requested.
                if providerControlCommand == nil {
                    guard try await configureControllerForRun(
                        session: session,
                        runID: runID,
                        runAttemptID: runAttemptID,
                        controller: controller,
                        runRequest: runRequest,
                        admission: { [self] in
                            #if DEBUG
                                testAtStartupBoundary?(.configuration)
                            #endif
                            return isStartupStillCurrent(session: session, runID: runID, runAttemptID: runAttemptID)
                                && session.acpController === controller
                                && receipt.disposition(for: session) == .current
                        }
                    ) else {
                        guard await admitReused(.configuration) else { return .superseded }
                        // Admission returned after an interrupted sequence; do not send with
                        // partially applied configuration or discard the still-warm controller.
                        hooks.providerInput.recordPendingHandoffSendOutcome(session, false)
                        return .cancelledBeforeSend
                    }
                }

                if let deferredLease {
                    let acquired = await deferredLease.acquire()
                    guard await admitReused(.deferredLeaseAcquired) else { return .superseded }
                    guard acquired else {
                        let errorText = "RepoPrompt MCP routing policy could not be prepared before \(runRequest.agentKind.displayName) ACP prompt submission."
                        return providerControlCommand == nil
                            ? .failed(errorText: errorText)
                            : .refusedBeforeSend(errorText: errorText)
                    }
                    await deferredLease.releaseGateForDeferredRouting()
                    log("deferred MCP routing until ACP follow-up prompt", runID: runID)
                }

                guard await admitReused(.routingReleased) else { return .superseded }
                if let providerControlCommand {
                    phase = .entered
                    return await runProviderControlCommandTurn(
                        session: session, runID: runID, runAttemptID: runAttemptID,
                        command: providerControlCommand, controller: controller, runRequest: runRequest,
                        receipt: receipt, attachmentReservationID: attachmentReservationID, phase: &phase
                    )
                }
                let prepared = await controller.prepareForNextTurn()
                // Check the origin even on refusal: neither failure publication nor handoff
                // repair belongs to a writer that replaced the caller during preparation.
                guard await admitStartupTask(
                    .promptPrepared, session: session, runID: runID, runAttemptID: runAttemptID,
                    controller: controller, receipt: receipt, attachmentReservationID: attachmentReservationID,
                    retainsController: prepared, dedicatedNoteID: dedicatedNoteID
                ) else { return .superseded }
                guard prepared else {
                    hooks.providerInput.recordPendingHandoffSendOutcome(session, false)
                    return .failed(errorText: "\(runRequest.agentKind.displayName) ACP session is no longer reusable.")
                }
                let events = await controller.events
                guard await admitReused(.promptStreamAcquired) else { return .superseded }
                phase = .entered
                return await runPromptTurn(
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    initialMessageForRun: initialMessageForRun,
                    attachments: attachments,
                    controller: controller,
                    runRequest: runRequest,
                    attachmentReservationID: attachmentReservationID,
                    events: events, receipt: receipt, retainsControllerOnRefusal: true, phase: &phase,
                    dedicatedNoteID: dedicatedNoteID,
                    localComposerCandidate: localComposerCandidate
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let normalized = await controller.normalizeError(error)
                let normalizedText = displayText(for: normalized)
                log("continue failed raw=\(String(describing: error)) normalized=\(normalizedText)", runID: runID)
                #if DEBUG
                    if phase == .setup { testAtStartupBoundary?(.prePromptFailure) }
                #endif
                return .failed(errorText: normalizedText)
            }
        }

        if phase != .providerDispatch {
            let superseded = if case .superseded = classification.report.result { true } else { false }
            if phase == .setup, superseded || receipt.disposition(for: session) == .claimLost {
                await deferredLease?.releaseGateForDeferredRouting()
            }
            guard receipt.disposition(for: session) != .claimLost else { return }
        }
        if case .terminal = classification.report.result {
            leaseDisposition?.controllerRetained = classification.retainsController
        }
        await settleTransientExecution(
            classification,
            session: session,
            runID: runID,
            runAttemptID: runAttemptID,
            controller: controller,
            attachmentReservationID: attachmentReservationID
        )
    }

    private func runPromptTurn(
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID,
        initialMessageForRun: String,
        attachments: [AgentFileAttachment],
        controller: ACPAgentSessionController,
        runRequest: ACPRunRequest,
        attachmentReservationID: UUID?,
        events: AsyncStream<NormalizedAgentRuntimeEvent>,
        receipt: AgentSessionRuntimeStore.WriterReceipt,
        retainsControllerOnRefusal: Bool,
        phase: inout PromptPhase,
        dedicatedNoteID: AgentSelfCompactionDispatchID? = nil,
        localComposerCandidate: UUID? = nil
    ) async -> TransientOperationResult {
        log("prompt turn begin", runID: runID)
        setRunningStatus("Thinking…", source: .transport, session: session, urgent: true)
        var carry = AgentSelfCompactParkedPrefix.prepare(initialMessageForRun, session: session) {
            hooks.persistence.scheduleSave(session)
        }
        if let dispatchID = carry.dispatchID,
           !session.selfCompactNoteDispatchIsCurrent(dispatchID)
        {
            if dedicatedNoteID != nil { return .cancelled }
            carry = .init(text: initialMessageForRun, dispatchID: nil)
        }
        // This run was created only to send the captured note. If an ordinary local turn
        // consumed or superseded it while ACP setup suspended, never reinterpret its frame
        // as an ordinary prompt (which could send the already-accepted note twice).
        if let dedicatedNoteID,
           !carry.exactNote || carry.dispatchID != dedicatedNoteID
        {
            return .cancelled
        }
        let agentMessage = carry.exactNote
            ? AgentMessage(systemPrompt: "", userMessage: carry.text, resumeSessionID: session.providerSessionID)
            : hooks.providerInput.buildHeadlessAgentMessage(
                session,
                carry.text,
                runID,
                attachments
            )
        if !carry.exactNote {
            hooks.providerInput.recordPendingHandoffSendOutcome(session, true)
        }
        hooks.attachments.stageConsumedAttachmentFilesForDeferredCleanup(attachments, session)
        hooks.attachments.markAttachmentsConsumed(session, attachmentReservationID)

        // The callers prepare the controller and acquire its event stream before admitting
        // prompt entry. Compose after those awaits and after message construction: membership
        // may have changed during preparation or synchronous input projection. This covers the initial, resumed, reusable-session, and follow-up
        // routes, which all converge here. Resumed providers still omit `AgentMessage.systemPrompt`;
        // the supplement rides the user-message channel precisely because a resumed thread cannot
        // refresh system text.
        let oversightDispatch = AgentSessionLinkPromptDispatchID.acpPromptTurn(runAttemptID: runAttemptID)
        var monitoring: AgentModeRunService.AgentSessionLinkDecoratedAgentMessage?
        defer { withExtendedLifetime(monitoring?.quietMarkerProducerLifetime) {} }
        var inputProof: AgentSessionLinkProviderInputRelease.Proof?
        // The exact framed note is the whole provider input and must not be decorated.
        if !carry.exactNote {
            let decorated = hooks.providerInput.decoratedAgentMessage(
                agentMessage,
                session: session,
                dispatchID: oversightDispatch
            )
            // Required lane content is the turn's only new provider input. Refusal is a quiet
            // pre-acceptance cancellation, not an ACP prompt failure.
            guard !decorated.mustAbortDispatch else {
                hooks.providerInput.recordAgentSessionLinkPhysicalDispatchNotAttempted(
                    session,
                    oversightDispatch
                )
                return .cancelled
            }
            inputProof = await hooks.providerInput.proveAgentSessionLinkProviderInput(session, decorated.claim)
            #if DEBUG
                testAtStartupBoundary?(.providerInputProved)
            #endif
            let disposition = receipt.disposition(for: session)
            guard disposition != .claimLost else { return .superseded }
            guard !Task.isCancelled, session.runID == runID,
                  session.activeRunAttemptID == runAttemptID, session.acpController === controller
            else {
                // Cleanup hooks address the session's wake namespace. They are not permission
                // to cancel a later attempt merely because the writer itself stayed the same.
                guard ownsOriginalAttemptOrTerminal(session, runID: runID, runAttemptID: runAttemptID) else { return .superseded }
                hooks.providerInput.recordAgentSessionLinkPhysicalDispatchNotAttempted(session, oversightDispatch)
                return .cancelled
            }
            guard disposition == .current else {
                hooks.providerInput.recordAgentSessionLinkPhysicalDispatchNotAttempted(session, oversightDispatch)
                return retainsControllerOnRefusal ? .cancelledBeforeSend : .cancelled
            }
            guard hooks.providerInput.acquireAgentSessionLinkPhysicalDispatch(
                session,
                oversightDispatch
            ) else {
                hooks.providerInput.recordAgentSessionLinkPhysicalDispatchNotAttempted(
                    session,
                    oversightDispatch
                )
                return .cancelled
            }
            monitoring = decorated
        }
        if let dispatchID = carry.dispatchID {
            guard session.selfCompactNoteDispatchIsCurrent(dispatchID),
                  AgentSelfCompactParkedPrefix.markAttempted(dispatchID, session: session)
            else {
                // Another sender may already own this note's one-shot attempt. A stale dedicated
                // sender has no marker to clear and must not re-park an ordinary in-flight send.
                if !carry.exactNote {
                    hooks.providerInput.recordAgentSessionLinkPhysicalDispatchFailure(
                        session,
                        oversightDispatch
                    )
                }
                return .cancelled
            }
            hooks.persistence.scheduleSave(session)
        }

        log("controller.prompt begin", runID: runID)
        let released = inputProof.map { hooks.providerInput.handoffAgentSessionLinkProviderInput(session, oversightDispatch, monitoring?.claim, $0) }
        guard released?.mustAbortDispatch != true else { return .cancelled }
        // The stream buffers bootstrap/preparation events. Start its consumer only after every
        // pre-dispatch refusal, so an unsent turn cannot leave a task awaiting a terminal event.
        #if DEBUG
            testPromptConsumerCreated?()
        #endif
        let consumeTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else {
                return TransientOperationResult.failed(errorText: "ACP event consumer deallocated.")
            }
            return await consumeEvents(events, session: session, runID: runID, runAttemptID: runAttemptID)
        }
        do {
            let oracle = carry.exactNote ? nil : session.oracleBackgroundAwareness.reserve(session: session, providerID: ObjectIdentifier(controller))
            defer { session.oracleBackgroundAwareness.release(oracle) }
            let outbound = released?.message(agentMessage) ?? agentMessage
            phase = .providerDispatch
            try await controller.prompt(oracle?.decorating(outbound) ?? outbound, request: runRequest)
            session.oracleBackgroundAwareness.accept(oracle)
            // A non-throwing `controller.prompt` return is ACP's acceptance signal.
            session.settleLocalComposerOrigin(localComposerCandidate, disposition: .retained)
            if let monitoring {
                hooks.providerInput.acceptAgentSessionLinkPrompt(
                    session, monitoring.dispatchContext, released?.claim
                )
            }
            if let dispatchID = carry.dispatchID {
                if AgentSelfCompactParkedPrefix.markAccepted(dispatchID, session: session) {
                    hooks.presentation.requestUIRefresh(session, true)
                    hooks.bindingObservation.updateBindings(session)
                }
                hooks.persistence.scheduleSave(session)
            }
            let identity = await controller.currentProviderSessionIdentity()
            applyProviderSessionIdentity(identity, session: session)
            log("controller.prompt returned; awaiting event consumer", runID: runID)
        } catch {
            if let dispatchID = carry.dispatchID {
                AgentSelfCompactParkedPrefix.markTransportFailed(dispatchID, session: session)
                hooks.persistence.scheduleSave(session)
            }
            if !carry.exactNote {
                hooks.providerInput.recordAgentSessionLinkPhysicalDispatchFailure(
                    session,
                    oversightDispatch
                )
            }
            let identity = await controller.refreshProviderSessionIdentityAfterPromptInterruption()
            applyProviderSessionIdentity(identity, session: session)
            let normalizedError = await controller.normalizeError(error)
            let normalizedText = displayText(for: normalizedError)
            log("controller.prompt failed raw=\(String(describing: error)) normalized=\(normalizedText)", runID: runID)
            let outcome = await consumeTask.value
            return await retainingPreservedSession(
                .failed(errorText: promptFailureErrorText(outcome: outcome, fallback: normalizedText)),
                controller: controller, agentKind: runRequest.agentKind
            )
        }

        // A steering prompt's provider failure ends the run here, through the consumer's terminal.
        let outcome = await retainingPreservedSession(
            consumeTask.value, controller: controller, agentKind: runRequest.agentKind
        )
        log("event consumer completed \(outcome.debugDescription)", runID: runID)
        return outcome
    }

    /// Keeps the controller when the turn's failure left the provider session open, as the provider
    /// attested; every other outcome passes through unchanged. Only providers whose MCP routing
    /// settles before the prompt qualify: a deferred lease's failure cleanup would revoke routing for
    /// the run ID the kept controller goes on using.
    private func retainingPreservedSession(
        _ outcome: TransientOperationResult,
        controller: ACPAgentSessionController,
        agentKind: AgentProviderKind
    ) async -> TransientOperationResult {
        guard case let .failed(errorText) = outcome,
              agentKind.requiresPrePromptAgentModeMCPRouting,
              await controller.retainsSessionAfterLastPromptFailure
        else { return outcome }
        return .failedRetainingController(errorText: errorText)
    }

    /// One provider control command turn: exactly `/<command>` as the whole prompt, sent only while
    /// the admitted session still advertises it.
    ///
    /// Nothing RepoPrompt normally adds reaches the provider — no handoff, oversight supplement, lane
    /// content, dispatch claim, attachments, or system prompt — so there is no oversight dispatch to
    /// fence or accept; the supplement it skips stays owed to the next ordinary turn. The session's
    /// identity facts are re-proven here, and the controller re-proves its own (open, idle, same
    /// provider session, still advertised) in the same synchronous step as the write. A refusal from
    /// either sent nothing and leaves the controller in place.
    /// A control command's controller that cannot take a turn now: retired as after any failed turn
    /// when it can never run another, left in place (nothing was sent) when it is merely busy.
    private static func controlCommandUnreusableOutcome(
        isRetired: Bool,
        runRequest: ACPRunRequest
    ) -> TransientOperationResult {
        let displayName = runRequest.agentKind.displayName
        return isRetired
            ? .failed(errorText: "\(displayName) ACP session is no longer reusable, so the requested command was not run.")
            : .refusedBeforeSend(errorText: "\(displayName) ACP session was busy, so the requested command was not run.")
    }

    /// Preserve the existing orphan cleanup when a control admission gate refuses identity.
    /// Cleanup owns only the detached controller; terminal publication still needs this claim
    /// and attempt after shutdown's await, and must never adopt a replacement writer.
    private func controlPromptAdmissionRefusal(
        session: AgentTabSession, runID: UUID, runAttemptID: UUID,
        controller: ACPAgentSessionController, receipt: AgentSessionRuntimeStore.WriterReceipt,
        displayName: String
    ) async -> TransientOperationResult {
        guard isStartupStillCurrent(session: session, runID: runID, runAttemptID: runAttemptID),
              session.acpController !== controller else { return .superseded }
        await controller.shutdown()
        guard isStartupStillCurrent(session: session, runID: runID, runAttemptID: runAttemptID),
              receipt.disposition(for: session) != .claimLost else { return .superseded }
        return .refusedBeforeSend(errorText: "\(displayName) could not run the requested command because the session changed before it was sent.")
    }

    private func runProviderControlCommandTurn(
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID,
        command: AgentProviderControlCommand,
        controller: ACPAgentSessionController,
        runRequest: ACPRunRequest,
        receipt: AgentSessionRuntimeStore.WriterReceipt,
        attachmentReservationID: UUID?,
        phase: inout PromptPhase
    ) async -> TransientOperationResult {
        let displayName = runRequest.agentKind.displayName
        log("provider control command turn begin kind=\(command.kind.rawValue)", runID: runID)
        let statusText = switch command.kind {
        case .compact: "Compacting context…"
        }
        setRunningStatus(statusText, source: .transport, session: session, urgent: true)

        let prepared = await controller.prepareForNextTurn()
        let retired = prepared ? false : await controller.isRetired
        guard await admitStartupTask(
            .controlPromptPrepared, session: session, runID: runID, runAttemptID: runAttemptID,
            controller: controller, receipt: receipt, attachmentReservationID: attachmentReservationID,
            retainsController: !retired
        ) else {
            return await controlPromptAdmissionRefusal(session: session, runID: runID, runAttemptID: runAttemptID, controller: controller, receipt: receipt, displayName: displayName)
        }
        guard prepared else {
            return Self.controlCommandUnreusableOutcome(isRetired: retired, runRequest: runRequest)
        }
        let events = await controller.events
        guard await admitStartupTask(
            .controlPromptAdmission, session: session, runID: runID, runAttemptID: runAttemptID,
            controller: controller, receipt: receipt, attachmentReservationID: attachmentReservationID,
            retainsController: true
        ) else {
            return await controlPromptAdmissionRefusal(session: session, runID: runID, runAttemptID: runAttemptID, controller: controller, receipt: receipt, displayName: displayName)
        }

        // This run attempt and the admitted app-session incarnation and provider conversation, after
        // every await above. A cancelled or superseded attempt must never reach the write.
        guard isStartupStillCurrent(session: session, runID: runID, runAttemptID: runAttemptID) else {
            return .superseded
        }
        guard !Task.isCancelled else {
            return .cancelled
        }
        guard session.persistentSessionBindingIdentity == command.expectedBinding,
              !session.bindingTransitionInProgress,
              session.providerSessionID == command.expectedProviderConversation,
              command.selfCompactDispatchID == nil || session.selfCompactDispatchIsCurrent?() != false
        else {
            return .refusedBeforeSend(
                errorText: "\(displayName) could not run the requested command because the session changed before it was sent."
            )
        }

        // At dispatch, the count stops describing the context. ACP carries no verified compaction
        // signal, so only a later occupancy report (`usage_update`) may vouch for a count again; this
        // turn's billed prompt count cannot. The suspension ends on every exit from here.
        let withdrawnVouch = session.beginCompactionContextCountSuspension()
        defer { session.endCompactionContextCountSuspension() }
        // An ACP slash command can be fire-and-forget (Devin `/compact`): the provider ends the
        // turn instantly with no output while it keeps compacting in the background, where the
        // session's next prompt cancels the work. `dispatchedAt`/`transcriptItemsAtDispatch` detect
        // that signature so the transcript can name the invisible work rather than show a silent
        // empty turn.
        let dispatchedAt = Date()
        let transcriptItemsAtDispatch = session.items.count
        if command.selfCompactDispatchID?.stage == .compact {
            // Defensive recheck after withdrawing the count vouch; no await has intervened.
            guard session.selfCompactDispatchIsCurrent?() != false else {
                session.restoreContextCountVouchAfterUnsentCompaction(withdrawnVouch)
                return .refusedBeforeSend(
                    errorText: "\(displayName) did not run the requested command because self-compaction was no longer admissible."
                )
            }
            session.selfCompactACPCommandItemIDs = Set(session.items.map(\.id))
        }
        // As with an ordinary prompt, buffered events belong to a dispatched turn. Refusal
        // above must not create a consumer that advances shared state before admission.
        #if DEBUG
            testPromptConsumerCreated?()
        #endif
        let consumeTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else {
                return TransientOperationResult.failed(errorText: "ACP event consumer deallocated.")
            }
            return await consumeEvents(events, session: session, runID: runID, runAttemptID: runAttemptID)
        }
        /// Actor-side refusal still needs to cancel and join its dispatched consumer.
        func abandonConsumer() async {
            consumeTask.cancel()
            _ = await consumeTask.value
        }
        do {
            log("controller.promptAdvertisedCommand begin", runID: runID)
            phase = .providerDispatch
            try await controller.promptAdvertisedCommand(
                command.kind.rawValue,
                expectedSessionID: command.expectedProviderConversation,
                request: runRequest
            )
            let identity = await controller.currentProviderSessionIdentity()
            applyProviderSessionIdentity(identity, session: session)
        } catch let refusal as ACPAgentSessionController.ProviderCommandRefusal {
            // Nothing was sent, so the count still describes the context.
            await abandonConsumer()
            session.restoreContextCountVouchAfterUnsentCompaction(withdrawnVouch)
            log("provider control command refused: \(refusal.reason)", runID: runID)
            let errorText = "\(displayName) did not run the requested command: \(refusal.reason)"
            return refusal.sessionIsUsable ? .refusedBeforeSend(errorText: errorText) : .failed(errorText: errorText)
        } catch is ACPAgentSessionController.ProviderCommandCancelledBeforeSend {
            await abandonConsumer()
            session.restoreContextCountVouchAfterUnsentCompaction(withdrawnVouch)
            return .cancelled
        } catch is CancellationError {
            await abandonConsumer()
            return .cancelled
        } catch {
            // `submitPromptTurn` emits a terminal event for every non-cancellation failure it throws, so
            // the consumer is awaited uncancelled here for its verdict; a new throw path that skips the
            // terminal event must cancel the consumer instead.
            let identity = await controller.refreshProviderSessionIdentityAfterPromptInterruption()
            applyProviderSessionIdentity(identity, session: session)
            let normalizedText = await displayText(for: controller.normalizeError(error))
            log("provider control command failed normalized=\(normalizedText)", runID: runID)
            let outcome = await consumeTask.value
            return await retainingPreservedSession(
                .failed(errorText: promptFailureErrorText(outcome: outcome, fallback: normalizedText)),
                controller: controller, agentKind: runRequest.agentKind
            )
        }

        let outcome = await retainingPreservedSession(
            consumeTask.value, controller: controller, agentKind: runRequest.agentKind
        )
        if case .completed = outcome,
           command.kind == .compact,
           session.items.count == transcriptItemsAtDispatch,
           // Buffered assistant chunks land as an item only after a debounce flush; a pending
           // buffer means the turn did emit output, so it was not silent.
           session.pendingAssistantDelta.isEmpty,
           Date().timeIntervalSince(dispatchedAt) < Self.acpFireAndForgetCommandWindow
        {
            session.appendItem(AgentChatItem(
                kind: .system,
                text: AgentChatItem.acpBackgroundCompactionNoteText,
                sequenceIndex: session.nextSequenceIndex
            ))
            // Enforced, not only advised: overseer sends and compactions, parked `when_sendable`
            // sends, and automatic wakes all see this session as not idle until the span ends.
            session.beginACPBackgroundCompactionSettle(duration: Self.acpBackgroundCompactionSettleDuration)
            toolTrackingHooks.requestUIRefresh(session, false)
            toolTrackingHooks.scheduleSave(session)
        }
        log("provider control command turn completed \(outcome.debugDescription)", runID: runID)
        return outcome
    }

    private func applyProviderSessionIdentity(
        _ identity: ACPProviderSessionIdentity,
        invalidatedResumeSessionID: String? = nil,
        session: AgentTabSession
    ) {
        let providerSessionID = identity.loadSessionID ?? identity.runtimeSessionID
        var changed = false
        let invalidated = invalidatedResumeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let invalidated,
           !invalidated.isEmpty,
           session.providerSessionID?.trimmingCharacters(in: .whitespacesAndNewlines) == invalidated,
           providerSessionID != invalidated
        {
            session.providerSessionID = nil
            session.providerCleanupHandle = nil
            changed = true
        }
        if session.providerSessionID != providerSessionID {
            session.providerSessionID = providerSessionID
            session.providerCleanupHandle = ProviderConversationCleanupHandle.resolved(
                provider: session.selectedAgent.rawValue,
                explicit: nil,
                providerSessionID: providerSessionID,
                codexConversationID: session.codexConversationID,
                codexRolloutPath: session.codexRolloutPath
            )
            changed = true
        }
        guard changed else { return }
        session.isDirty = true
        hooks.persistence.scheduleSave(session)
        hooks.bindingObservation.updateBindings(session)
    }

    private func configureControllerForRun(
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID,
        controller: ACPAgentSessionController,
        runRequest: ACPRunRequest,
        admission: @escaping @MainActor () -> Bool
    ) async throws -> Bool {
        try await Self.performConfigurationSequenceIfCurrent(
            isCurrent: admission,
            operations: [
                { [self] in
                    try await applyExplicitSelectedModelIfNeeded(runRequest, controller: controller, runID: runID)
                },
                {
                    var selections = runRequest.modelParameterSelections
                    if runRequest.agentKind == .cursor, let raw = runRequest.modelString {
                        let specifier = try CursorAIModelCatalog.ModelSpecifier(raw: raw)
                        let explicit = ACPModelParameterSelection.selections(for: .cursor, activeBaseModelRaw: specifier.baseModelRaw, from: selections)
                        // New explicit intent replaces inherited pins before fresh validation.
                        let encoded = try await specifier.selections(in: controller.currentDiscoveredSessionModels(), excludingConfigIDs: Set(explicit.map(\.configID)), supersededKinds: Set(explicit.map(\.kind)))
                        guard admission() else { throw ConfigurationInterrupted() }
                        selections = ACPModelParameterSelection.normalized(encoded.map { ACPModelParameterSelection(providerID: .cursor, baseModelRaw: $0.baseModelRaw, kind: $0.kind, configID: $0.configID, valueRaw: $0.valueRaw) } + selections)
                    }
                    let report = try await controller.applySessionModelParameterSelections(selections)
                    try report.validateNoSkippedSelections()
                },
                {
                    await controller.setAutoApproveAllToolPermissions(
                        runRequest.autoApproveAllToolPermissions
                    )
                },
                { [self] in
                    try await applyRequestedSessionModeIfNeeded(
                        runRequest.sessionModeID,
                        controller: controller
                    )
                }
            ]
        )
    }

    private struct ConfigurationInterrupted: Error {}

    /// Configuration calls can suspend on provider RPCs. Re-check ownership before and after
    /// every step so an attempt superseded during one response cannot continue with later writes.
    private static func performConfigurationSequenceIfCurrent(
        isCurrent: () -> Bool,
        operations: [() async throws -> Void]
    ) async throws -> Bool {
        for operation in operations {
            guard isCurrent() else { return false }
            do {
                try await operation()
            } catch is ConfigurationInterrupted {
                return false
            }
            guard isCurrent() else { return false }
        }
        return true
    }

    private func applyRequestedSessionModeIfNeeded(
        _ requestedMode: String?,
        controller: ACPAgentSessionController
    ) async throws {
        if let requestedMode = requestedMode?.trimmingCharacters(in: .whitespacesAndNewlines), !requestedMode.isEmpty {
            try await controller.setSessionMode(requestedMode)
        }
    }

    private func applyExplicitSelectedModelIfNeeded(
        _ runRequest: ACPRunRequest,
        controller: ACPAgentSessionController,
        runID: UUID
    ) async throws {
        guard let model = try Self.explicitSelectedModel(
            agentKind: runRequest.agentKind,
            modelString: runRequest.modelString
        ) else {
            return
        }
        log("applying \(runRequest.agentKind.displayName) selected model=\(model)", runID: runID)
        // OpenCode advertises model-scoped parameter metadata (`effort`) only after a real model
        // set. When a pin is inherited, the ordinary same-model no-op skip would leave `effort`
        // unadvertised, the pin would land in `skipped`, and validation would throw before the
        // prompt. Force the selector RPC for OpenCode whenever selections are pending; other ACP
        // providers keep the skip. Covers fresh and continue runs (shared helper).
        try await controller.setSessionModel(
            runRequest.agentKind == .cursor ? CursorAIModelCatalog.ModelSpecifier(raw: model).baseModelRaw : model,
            forceRPC: runRequest.agentKind == .openCode && !runRequest.modelParameterSelections.isEmpty
        )
    }

    private static func explicitSelectedModel(
        agentKind: AgentProviderKind,
        modelString: String?
    ) throws -> String? {
        guard agentKind == .openCode || agentKind == .cursor || agentKind == .grokBuild || agentKind == .antigravity || agentKind == .devin else { return nil }
        guard let model = modelString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty,
              model.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
        else {
            return nil
        }
        if agentKind == .grokBuild || agentKind == .antigravity,
           let providerID = agentKind.acpProviderID,
           AgentModelCatalogRuntime.shared.acpRegistry.resolvedSnapshot(for: providerID)?.contains(rawModel: model) != true
        {
            // These ACP providers have no provider-side alias surface: an unknown
            // concrete model fails instead of silently running the provider's default.
            throw AIProviderError.invalidConfiguration(
                detail: "\(agentKind.displayName) model `\(model)` is not in the discovered model set. Refresh its models and retry."
            )
        }
        return model
    }

    private func promptFailureErrorText(
        outcome: TransientOperationResult,
        fallback: String
    ) -> String {
        let unexpectedStreamEnd = "ACP events stream ended unexpectedly."
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        let outcomeError: String? = if case let .failed(errorText) = outcome {
            errorText?.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            nil
        }
        guard let outcomeError,
              !outcomeError.isEmpty,
              outcomeError != unexpectedStreamEnd
        else {
            return trimmedFallback.isEmpty ? unexpectedStreamEnd : trimmedFallback
        }
        return outcomeError
    }

    private func consumeEvents(
        _ events: AsyncStream<NormalizedAgentRuntimeEvent>,
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID
    ) async -> TransientOperationResult {
        if let ownership = session.activeRunOwnership, ownership.attemptID == runAttemptID {
            session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .running)
        }
        for await event in events {
            guard session.runID == runID,
                  session.activeRunAttemptID == runAttemptID,
                  let ingressOwner = session.activeRunOwnership,
                  session.isCurrentRunAttemptForCurrentBinding(ingressOwner)
            else {
                return .superseded
            }

            if let ownership = session.activeRunOwnership, ownership.attemptID == runAttemptID {
                session.recordRunProgress(ownership: ownership, kind: .providerEvent, stage: .running)
            }
            switch event {
            case let .stream(result):
                await hooks.transcript.handleHeadlessStreamResult(result, session, runID, runAttemptID)
            case let .approvalRequested(request):
                if let owner = session.activeRunOwnership, owner.attemptID == runAttemptID {
                    session.recordRunProgress(ownership: owner, kind: .interaction, stage: .waitingForInteraction)
                }
                session.pendingApproval = request
                session.runState = .waitingForApproval
                setRunningStatus(nil, source: nil, session: session, urgent: true)
            case let .approvalCancelled(requestID):
                if session.pendingApproval?.requestID == requestID {
                    session.pendingApproval = nil
                    if session.runState == .waitingForApproval {
                        session.runState = .running
                        setRunningStatus("Thinking…", source: .transport, session: session, urgent: true)
                    } else {
                        hooks.bindingObservation.updateBindings(session)
                    }
                }
            case let .terminal(state, errorText):
                if session.pendingSupersedingTurnCompletions > 0 {
                    session.pendingSupersedingTurnCompletions -= 1
                    if session.runState.isActive {
                        session.runState = .running
                        setRunningStatus("Thinking…", source: .transport, session: session, urgent: true)
                    }
                    continue
                }
                switch state {
                case .completed:
                    return .completed
                case .cancelled:
                    return .cancelled
                case .failed:
                    return .failed(errorText: errorText)
                default:
                    assertionFailure("ACP terminal event must carry a terminal run state")
                    return .failed(errorText: errorText)
                }
            }
        }

        return .failed(errorText: "ACP events stream ended unexpectedly.")
    }

    private func handleAcquireFailure(
        tabID _: UUID,
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID,
        controller: ACPAgentSessionController,
        lease: MCPBootstrapLease,
        receipt: AgentSessionRuntimeStore.WriterReceipt,
        attachmentReservationID: UUID?
    ) async {
        let outcome = await lease.acquireFailureOutcome
        guard await admitStartupTask(
            .acquireFailureOutcome, session: session, runID: runID, runAttemptID: runAttemptID,
            controller: controller, receipt: receipt, attachmentReservationID: attachmentReservationID,
            retainsController: false
        ), let ownership = session.activeRunOwnership,
        ownership.attemptID == runAttemptID else { return }
        hooks.providerInput.recordPendingHandoffSendOutcome(session, false)
        await terminalCommitBarrier.commit(.init(
            binding: hooks.bindTerminalSession(session),
            ownership: ownership,
            expectedRunID: runID,
            terminalState: outcome.terminalState,
            source: "acp.acquireFailure",
            errorText: outcome.errorText,
            attachmentReservationID: attachmentReservationID,
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: true,
            supportsFollowUp: false,
            notifyTurnComplete: false,
            prepareProviderState: {
                if session.acpController === controller {
                    session.acpController = nil
                }
                AgentModeProcessRunIdentity.clearProcessRunID(for: session)
                return { await controller.shutdown() }
            }
        ))
    }

    private func settleTransientExecution(
        _ classification: TransientExecutionClassification,
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID,
        controller: ACPAgentSessionController,
        attachmentReservationID: UUID?
    ) async {
        guard case let .terminal(outcome) = classification.report.result else { return }
        let terminalState: AgentSessionRunState = switch outcome.kind {
        case .completed:
            .completed
        case .cancelled:
            .cancelled
        case .failed:
            .failed
        }
        await finalize(
            session: session,
            runID: runID,
            runAttemptID: runAttemptID,
            controller: controller,
            attachmentReservationID: attachmentReservationID,
            terminalState: terminalState,
            errorText: classification.errorText,
            notifyTurnComplete: terminalState == .completed,
            shouldShutdownController: terminalState != .completed && !classification.retainsController,
            retainsController: classification.retainsController
        )
    }

    private func finalize(
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID,
        controller: ACPAgentSessionController?,
        attachmentReservationID: UUID?,
        terminalState: AgentSessionRunState,
        errorText: String?,
        notifyTurnComplete: Bool,
        shouldShutdownController: Bool,
        retainsController: Bool = false
    ) async {
        let finalizeErrorDescription = errorText ?? "nil"
        log("finalize requested state=\(terminalState.rawValue) error=\(finalizeErrorDescription)", runID: runID)
        guard let ownership = session.activeRunOwnership,
              ownership.attemptID == runAttemptID
        else {
            log("finalize ignored; session no longer owns run", runID: runID)
            return
        }
        let supportsSessionResume = terminalState == .completed && controller != nil
        await terminalCommitBarrier.commit(.init(
            binding: hooks.bindTerminalSession(session),
            ownership: ownership,
            expectedRunID: runID,
            terminalState: terminalState,
            source: "acp.finalize",
            errorText: errorText,
            attachmentReservationID: attachmentReservationID,
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: true,
            supportsFollowUp: supportsSessionResume,
            notifyTurnComplete: notifyTurnComplete,
            prepareProviderState: {
                session.pendingSupersedingTurnCompletions = 0
                if retainsController {
                    // Nothing reached the provider, or the provider kept its session open after
                    // failing the turn; the session's controller and run identity stand.
                } else if terminalState != .completed {
                    if let controller, session.acpController === controller {
                        session.acpController = nil
                    }
                    AgentModeProcessRunIdentity.clearProcessRunID(for: session)
                } else if session.acpController == nil {
                    AgentModeProcessRunIdentity.clearProcessRunID(for: session)
                }
                return {
                    if shouldShutdownController, let controller {
                        await controller.shutdown()
                    }
                }
            }
        ))
    }

    // MARK: - Tool Tracking (per-tab, using shared AgentToolTrackingController)

    @MainActor private final class OracleToolAssociation {
        var rowID: UUID?
        var groupID: OracleGroupID?
        var turnID: OracleTurnID?
    }

    /// A provider abort may retire MCP observers before the canonical group finishes draining.
    /// Capture the exact row while correlation is live, then reconcile only that owned row.
    func oracleToolSettlementCallbacks(
        session: AgentTabSession,
        invocationID: UUID,
        toolName: String,
        isOwnerCurrent: @escaping @MainActor @Sendable () -> Bool
    ) -> OracleToolSettlementCallbacks? {
        guard let ownership = session.activeRunOwnership, let runID = session.runID,
              let sessionID = session.activeAgentSessionID else { return nil }
        let association = OracleToolAssociation()
        return OracleToolSettlementCallbacks(
            prepared: { [weak self, weak session] groupID, turnID in
                guard let self, let session else { return }
                await toolTrackingByTabID[session.tabID]?.waitForPendingEventDeliveries()
                guard association.rowID == nil, isOwnerCurrent(), session.activeAgentSessionID == sessionID,
                      session.runID == runID, session.activeRunOwnership == ownership else { return }
                let rowInvocation = providerInvocation(forTrackerInvocationID: invocationID, tabID: session.tabID) ?? invocationID
                guard let row = session.items.last(where: {
                    $0.toolInvocationID == rowInvocation && MCPIntegrationHelper.normalizedRepoPromptToolName($0.toolName ?? "") == toolName
                }) else { return }
                association.rowID = row.id
                association.groupID = groupID
                association.turnID = turnID
            },
            settled: { [weak self, weak session] result, turnID, reconciliationGuidance in
                guard let self, let session, isOwnerCurrent(), session.activeAgentSessionID == sessionID,
                      session.runID == nil || session.runID == runID,
                      result.groupID == association.groupID, turnID == association.turnID,
                      session.activeRunOwnership == ownership || (session.activeRunOwnership == nil && session.runLifecycle.lastTerminalCommitRevision?.ownership == ownership),
                      let rowID = association.rowID, let index = session.items.firstIndex(where: { $0.id == rowID }) else { return }
                var row = session.items[index]
                let hadResult = hasNonEmptyPayload(row.toolResultJSON)
                var fields = ContextBuilderOracleGroupReply(
                    result: result, reconciliationGuidance: reconciliationGuidance
                ).toMCPFields()
                fields["chat_id"] = .string(result.primary.chatID)
                if let response = result.primary.response { fields["response"] = .string(response) }
                let payload = ToolOutputFormatter.rawJSONString(.object(fields))
                row.kind = .toolResult
                row.toolResultJSON = payload
                row.text = payload
                // Group coverage does not undo the provider's cancelled transport terminal.
                row.toolIsError = row.toolIsError == true || session.runLifecycle.lastTerminalCommitRevision?.terminalState == .cancelled
                if !hadResult { toolTrackingHooks.addToolOutputTokens(payload, session) }
                session.replaceItem(at: index, with: row)
                toolTrackingHooks.requestUIRefresh(session, true)
                toolTrackingHooks.scheduleSave(session)
            }
        )
    }

    private func startToolTracking(
        for session: AgentTabSession,
        runID: UUID,
        clientNameHint: String
    ) async {
        guard session.runID == runID, session.runState.isActive else { return }
        #if DEBUG
            print("[ACPAgentRunToolTracking] ACP startToolTracking session=\(session.activeAgentSessionID?.uuidString ?? "nil") tab=\(session.tabID.uuidString) agent=\(session.selectedAgent.rawValue) runID=\(runID.uuidString) clientHint=\(clientNameHint)")
        #endif
        resetACPToolCorrelation(for: session.tabID)
        toolTrackingRunIDByTabID[session.tabID] = runID
        let controller = toolTrackingByTabID[session.tabID] ?? {
            let c = AgentToolTrackingController()
            toolTrackingByTabID[session.tabID] = c
            return c
        }()
        await controller.startTracking(
            runID: runID,
            clientNameHint: clientNameHint,
            onCalled: { [weak self, weak session] invocationID, toolName, args in
                guard let self, let session else { return }
                handleTrackerToolCall(invocationID: invocationID, toolName: toolName, args: args, session: session)
            },
            onCompleted: { [weak self, weak session] invocationID, toolName, args, resultJSON, isError in
                guard let self, let session else { return }
                handleTrackerToolResult(invocationID: invocationID, toolName: toolName, args: args, resultJSON: resultJSON, isError: isError, session: session)
            }
        )
    }

    private func prepareToolTrackingTeardown(
        for session: AgentTabSession,
        matchingRunID: UUID? = nil
    ) -> AgentRunAttemptTerminalResources.Teardown? {
        if let matchingRunID, toolTrackingRunIDByTabID[session.tabID] != matchingRunID {
            return nil
        }
        toolTrackingRunIDByTabID.removeValue(forKey: session.tabID)
        guard let controller = toolTrackingByTabID.removeValue(forKey: session.tabID) else { return nil }
        resetACPToolCorrelation(for: session.tabID)
        return { await controller.stopTracking() }
    }

    private func setRunningStatus(
        _ text: String?,
        source: AgentTabSession.RunningStatusSource?,
        session: AgentTabSession,
        urgent: Bool = false
    ) {
        let normalized = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (normalized?.isEmpty == false) ? normalized : nil
        let normalizedSource = value == nil ? nil : source
        guard session.runningStatusText != value || session.runningStatusSource != normalizedSource else {
            if urgent {
                hooks.bindingObservation.updateBindings(session)
                hooks.presentation.requestUIRefresh(session, true)
            }
            return
        }
        session.runningStatusText = value
        session.runningStatusSource = normalizedSource
        hooks.bindingObservation.updateBindings(session)
        hooks.presentation.requestUIRefresh(session, urgent)
    }

    private func initialTransportStatusText(for _: AgentProviderKind) -> String {
        "Preparing…"
    }

    private func waitingForConnectionStatusText(for _: AgentProviderKind) -> String {
        "Waiting for connection…"
    }

    // MARK: - Tracker Callbacks

    private func handleTrackerToolCall(
        invocationID: UUID,
        toolName: String,
        args: [String: Value]?,
        session: AgentTabSession
    ) {
        guard AgentToolTrackingSupport.isRepoPromptTool(toolName) else { return }
        guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName) else { return }
        #if DEBUG
            if MCPIntegrationHelper.normalizedRepoPromptToolName(toolName) == "agent_run" {
                print("[ACPAgentRunToolTracking] ACP tracker call session=\(session.activeAgentSessionID?.uuidString ?? "nil") invocation=\(invocationID.uuidString) tool=\(toolName) itemCountBefore=\(session.items.count)")
            }
        #endif
        toolTrackingHooks.flushPendingAssistantDelta(session)
        toolTrackingHooks.endActiveAssistantSegment(session)
        toolTrackingHooks.endActiveReasoningSegment(session)
        let argsJSON = AgentToolTrackingController.encodeArgsToJSON(args)
        let storedToolName = MCPIntegrationHelper.canonicalRepoPromptToolName(toolName) ?? toolName
        acpTrackerInvocationIDsByTabID[session.tabID, default: []].insert(invocationID)
        let resolvedInvocationID = providerInvocation(forTrackerInvocationID: invocationID, tabID: session.tabID) ?? invocationID
        if let index = correlatedToolItemIndex(
            in: session,
            storedToolName: storedToolName,
            invocationID: resolvedInvocationID,
            argsJSON: argsJSON,
            source: .tracker,
            allowNameOnlyFallback: false
        ) {
            var updated = session.items[index]
            let hadArgs = hasAccountableToolPayload(updated.toolArgsJSON)
            if let existingInvocationID = updated.toolInvocationID,
               existingInvocationID != invocationID
            {
                recordProviderInvocation(existingInvocationID, forTrackerInvocationID: invocationID, tabID: session.tabID)
                removeProviderPlaceholderInvocation(existingInvocationID, tabID: session.tabID)
            } else {
                updated.toolInvocationID = invocationID
            }
            updated.toolName = storedToolName
            updated.toolArgsJSON = argsJSON ?? updated.toolArgsJSON
            if updated.kind == .toolCall {
                updated.text = argsJSON ?? ""
            }
            if !hadArgs, hasAccountableToolPayload(argsJSON) {
                toolTrackingHooks.addToolInputTokens(argsJSON, session)
            }
            session.replaceItem(at: index, with: updated)

        } else {
            if hasAccountableToolPayload(argsJSON) {
                toolTrackingHooks.addToolInputTokens(argsJSON, session)
            }
            let toolItem = AgentChatItem.toolCall(
                name: storedToolName,
                invocationID: invocationID,
                argsJSON: argsJSON,
                sequenceIndex: session.nextSequenceIndex
            )
            session.appendItem(toolItem)
        }
        toolTrackingHooks.requestUIRefresh(session, false)
        toolTrackingHooks.scheduleSave(session)
    }

    private func handleTrackerToolResult(
        invocationID: UUID,
        toolName: String,
        args: [String: Value]?,
        resultJSON: String,
        isError: Bool,
        session: AgentTabSession
    ) {
        guard AgentToolTrackingSupport.isRepoPromptTool(toolName) else { return }
        guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName) else { return }
        #if DEBUG
            if MCPIntegrationHelper.normalizedRepoPromptToolName(toolName) == "agent_run" {
                print("[ACPAgentRunToolTracking] ACP tracker result session=\(session.activeAgentSessionID?.uuidString ?? "nil") invocation=\(invocationID.uuidString) tool=\(toolName) isError=\(isError) resultChars=\(resultJSON.count) itemCountBefore=\(session.items.count)")
            }
        #endif
        toolTrackingHooks.flushPendingAssistantDelta(session)
        toolTrackingHooks.endActiveAssistantSegment(session)
        toolTrackingHooks.endActiveReasoningSegment(session)
        let argsJSON = AgentToolTrackingController.encodeArgsToJSON(args)
        let storedToolName = MCPIntegrationHelper.canonicalRepoPromptToolName(toolName) ?? toolName
        acpTrackerInvocationIDsByTabID[session.tabID, default: []].insert(invocationID)
        let resolvedInvocationID = providerInvocation(forTrackerInvocationID: invocationID, tabID: session.tabID) ?? invocationID
        if let index = correlatedToolItemIndex(
            in: session,
            storedToolName: storedToolName,
            invocationID: resolvedInvocationID,
            argsJSON: argsJSON,
            source: .tracker,
            allowNameOnlyFallback: true
        ) {
            var updated = session.items[index]
            let hadResult = hasNonEmptyPayload(updated.toolResultJSON)
            updated.kind = .toolResult
            if let existingInvocationID = updated.toolInvocationID,
               existingInvocationID != resolvedInvocationID
            {
                recordProviderInvocation(existingInvocationID, forTrackerInvocationID: invocationID, tabID: session.tabID)
            } else {
                updated.toolInvocationID = resolvedInvocationID
            }
            updated.toolName = storedToolName
            updated.toolArgsJSON = argsJSON ?? updated.toolArgsJSON
            if let payload = AgentToolResultPayloadRetention.resolvedPayload(
                existing: updated.toolResultJSON,
                incoming: resultJSON,
                incomingIsError: isError,
                requireObjectReplacement: true
            ) {
                updated.toolResultJSON = payload
                updated.toolIsError = isError
                updated.text = payload
            }
            if !hadResult, hasNonEmptyPayload(resultJSON) {
                toolTrackingHooks.addToolOutputTokens(resultJSON, session)
            }
            session.replaceItem(at: index, with: updated)
        } else {
            if hasNonEmptyPayload(resultJSON) {
                toolTrackingHooks.addToolOutputTokens(resultJSON, session)
            }
            var toolResultItem = AgentChatItem.toolResult(
                name: storedToolName,
                invocationID: resolvedInvocationID,
                resultJSON: resultJSON,
                isError: isError,
                sequenceIndex: session.nextSequenceIndex
            )
            toolResultItem.toolArgsJSON = argsJSON
            session.appendItem(toolResultItem)
        }
        toolTrackingHooks.requestUIRefresh(session, false)
        toolTrackingHooks.scheduleSave(session)
    }

    private func indexedThenActiveTurnToolCandidates(
        indexedIndices: [Int],
        session: AgentTabSession,
        where predicate: (AgentChatItem) -> Bool
    ) -> (indices: [Int], inspectedItemCount: Int, usedFallbackScan: Bool) {
        let indexedMatches = indexedIndices.filter { predicate(session.items[$0]) }
        if !indexedMatches.isEmpty || !indexedIndices.isEmpty {
            return (indexedMatches, indexedIndices.count, false)
        }
        let fallback = session.activeTurnToolItemIndices(where: predicate)
        return (
            fallback.indices,
            indexedIndices.count + fallback.scannedItemCount,
            !fallback.indices.isEmpty
        )
    }

    private func correlatedToolItemIndex(
        in session: AgentTabSession,
        storedToolName: String,
        invocationID: UUID?,
        argsJSON: String?,
        source: ToolObservationSource,
        allowNameOnlyFallback: Bool
    ) -> Int? {
        var inspectedItemCount = 0
        if let invocationID {
            let callCandidates = indexedThenActiveTurnToolCandidates(
                indexedIndices: session.indexedToolItemIndices(invocationID: invocationID),
                session: session,
                where: {
                    $0.kind == .toolCall
                        && $0.toolInvocationID == invocationID
                        && self.shouldUpdateExistingToolCall(
                            $0,
                            storedToolName: storedToolName,
                            argsJSON: argsJSON,
                            tabID: session.tabID
                        )
                }
            )
            inspectedItemCount += callCandidates.inspectedItemCount
            if let index = callCandidates.indices.last {
                MCPToolObserverAttributionContext.record(
                    correlationPath: callCandidates.usedFallbackScan
                        ? "invocation_id_call_active_turn_scan"
                        : "invocation_id_call",
                    scannedItemCount: inspectedItemCount
                )
                return index
            }
            let resultCandidates = indexedThenActiveTurnToolCandidates(
                indexedIndices: session.indexedToolItemIndices(invocationID: invocationID),
                session: session,
                where: {
                    // An exact invocation ID identifies the same call even when a
                    // provider re-sends its completion with different or missing
                    // args (Devin over ACP), so it must not become a second card.
                    $0.kind == .toolResult
                        && $0.toolInvocationID == invocationID
                }
            )
            inspectedItemCount += resultCandidates.inspectedItemCount
            if let index = resultCandidates.indices.last {
                MCPToolObserverAttributionContext.record(
                    correlationPath: resultCandidates.usedFallbackScan
                        ? "invocation_id_result_active_turn_scan"
                        : "invocation_id_result",
                    scannedItemCount: inspectedItemCount
                )
                return index
            }
        }
        let signature = toolInvocationSignature(toolName: storedToolName, argsJSON: argsJSON)
        if argsJSON != nil {
            // Lifecycle state cannot override FIFO: a delayed start can belong
            // to an older completed row while an identical newer call is pending.
            let candidates = indexedThenActiveTurnToolCandidates(
                indexedIndices: session.indexedToolItemIndices(signature: signature),
                session: session,
                where: {
                    ($0.kind == .toolCall || $0.kind == .toolResult)
                        && self.canPairObservation($0, source: source, tabID: session.tabID)
                        && self.toolInvocationSignature(toolName: $0.toolName, argsJSON: $0.toolArgsJSON) == signature
                }
            )
            inspectedItemCount += candidates.inspectedItemCount
            if let index = candidates.indices.first {
                session.noteUncertainToolCorrelation()
                MCPToolObserverAttributionContext.record(
                    correlationPath: candidates.usedFallbackScan ? "signature_active_turn_scan" : "signature",
                    scannedItemCount: inspectedItemCount
                )
                return index
            }
        }
        if (source == .provider && isPlaceholderToolArgs(argsJSON))
            || source == .tracker
        {
            // Either observation may arrive after the other source's terminal row.
            // Missing inputs cannot identify a signature; pair oldest unpaired
            // observation without erasing real inputs or terminal state.
            let normalizedToolName = AgentTabSession.normalizedToolCorrelationName(storedToolName)
            let candidates = session.activeTurnToolItemIndices(where: {
                ($0.kind == .toolCall || $0.kind == .toolResult)
                    && (source == .provider || self.isPlaceholderToolArgs($0.toolArgsJSON))
                    && self.canPairObservation($0, source: source, tabID: session.tabID)
                    && AgentTabSession.normalizedToolCorrelationName($0.toolName) == normalizedToolName
            })
            inspectedItemCount += candidates.scannedItemCount
            if let index = candidates.indices.first {
                session.noteUncertainToolCorrelation()
                MCPToolObserverAttributionContext.record(correlationPath: "late_placeholder_active_turn_scan", scannedItemCount: inspectedItemCount)
                return index
            }
        }
        if allowNameOnlyFallback {
            let normalizedToolName = AgentTabSession.normalizedToolCorrelationName(storedToolName)
            let fallback = session.activeTurnToolItemIndices(where: {
                $0.kind == .toolCall
                    && self.canPairObservation($0, source: source, tabID: session.tabID)
                    && AgentTabSession.normalizedToolCorrelationName($0.toolName) == normalizedToolName
            })
            inspectedItemCount += fallback.scannedItemCount
            MCPToolObserverAttributionContext.record(
                correlationPath: fallback.indices.first == nil ? "none" : "name_active_turn_scan",
                scannedItemCount: inspectedItemCount
            )
            if !fallback.indices.isEmpty { session.noteUncertainToolCorrelation() }
            return fallback.indices.first
        }
        MCPToolObserverAttributionContext.record(
            correlationPath: "none",
            scannedItemCount: inspectedItemCount
        )
        return nil
    }

    private func shouldUpdateExistingToolCall(
        _ item: AgentChatItem,
        storedToolName: String,
        argsJSON: String?,
        tabID: UUID
    ) -> Bool {
        guard item.kind == .toolCall else { return false }
        return hasExactToolInvocationSignature(item, storedToolName: storedToolName, argsJSON: argsJSON)
            || hasSameNormalizedToolName(item.toolName, storedToolName)
            || isKnownProviderPlaceholder(item, tabID: tabID)
    }

    private func hasExactToolInvocationSignature(
        _ item: AgentChatItem,
        storedToolName: String,
        argsJSON: String?
    ) -> Bool {
        toolInvocationSignature(toolName: item.toolName, argsJSON: item.toolArgsJSON)
            == toolInvocationSignature(toolName: storedToolName, argsJSON: argsJSON)
    }

    private func hasSameNormalizedToolName(_ existingToolName: String?, _ incomingToolName: String) -> Bool {
        let existing = MCPIntegrationHelper.normalizedRepoPromptToolName(existingToolName ?? "")
        let incoming = MCPIntegrationHelper.normalizedRepoPromptToolName(incomingToolName)
        return !existing.isEmpty && existing == incoming
    }

    private func isKnownProviderPlaceholder(_ item: AgentChatItem, tabID: UUID) -> Bool {
        isProviderPlaceholderInvocation(item.toolInvocationID, tabID: tabID)
            && isPlaceholderToolArgs(item.toolArgsJSON)
    }

    private func recordProviderInvocation(_ providerInvocationID: UUID, forTrackerInvocationID trackerInvocationID: UUID, tabID: UUID) {
        var mappings = acpProviderInvocationByTrackerInvocationIDByTabID[tabID, default: [:]]
        mappings[trackerInvocationID] = providerInvocationID
        acpProviderInvocationByTrackerInvocationIDByTabID[tabID] = mappings
    }

    private func recordProviderPlaceholderInvocationIfNeeded(_ invocationID: UUID?, argsJSON: String?, tabID: UUID) {
        guard let invocationID, isPlaceholderToolArgs(argsJSON) else { return }
        var placeholders = acpProviderPlaceholderInvocationIDsByTabID[tabID, default: []]
        placeholders.insert(invocationID)
        acpProviderPlaceholderInvocationIDsByTabID[tabID] = placeholders
    }

    private func removeProviderPlaceholderInvocation(_ invocationID: UUID?, tabID: UUID) {
        guard let invocationID,
              var placeholders = acpProviderPlaceholderInvocationIDsByTabID[tabID] else { return }
        placeholders.remove(invocationID)
        acpProviderPlaceholderInvocationIDsByTabID[tabID] = placeholders.isEmpty ? nil : placeholders
    }

    private func isProviderPlaceholderInvocation(_ invocationID: UUID?, tabID: UUID) -> Bool {
        guard let invocationID else { return false }
        return acpProviderPlaceholderInvocationIDsByTabID[tabID]?.contains(invocationID) == true
    }

    private func providerInvocation(forTrackerInvocationID trackerInvocationID: UUID, tabID: UUID) -> UUID? {
        acpProviderInvocationByTrackerInvocationIDByTabID[tabID]?[trackerInvocationID]
    }

    /// Signatures pair observations, not invocations: two identical calls from
    /// the same source must remain distinct. Aliases stay valid until run reset.
    private func canPairObservation(_ item: AgentChatItem, source: ToolObservationSource, tabID: UUID) -> Bool {
        guard let id = item.toolInvocationID else { return true }
        let mappings = acpProviderInvocationByTrackerInvocationIDByTabID[tabID, default: [:]]
        switch source {
        case .tracker:
            return acpProviderInvocationIDsByTabID[tabID]?.contains(id) == true
                && acpTrackerInvocationIDsByTabID[tabID]?.contains(id) != true
                && !mappings.values.contains(id)
        case .provider:
            return acpTrackerInvocationIDsByTabID[tabID]?.contains(id) == true
                && acpProviderInvocationIDsByTabID[tabID]?.contains(id) != true
                && mappings[id] == nil
        }
    }

    private func resetACPToolCorrelation(for tabID: UUID) {
        acpProviderInvocationByTrackerInvocationIDByTabID[tabID] = nil
        acpProviderPlaceholderInvocationIDsByTabID[tabID] = nil
        acpTrackerInvocationIDsByTabID[tabID] = nil
        acpProviderInvocationIDsByTabID[tabID] = nil
    }

    private func toolInvocationSignature(toolName: String?, argsJSON: String?) -> String {
        AgentTabSession.canonicalToolInvocationSignature(
            toolName: toolName,
            argsJSON: argsJSON
        )
    }

    private func hasNonEmptyPayload(_ payload: String?) -> Bool {
        payload?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func hasAccountableToolPayload(_ payload: String?) -> Bool {
        hasNonEmptyPayload(payload) && !isPlaceholderToolArgs(payload)
    }

    private func isPlaceholderToolArgs(_ payload: String?) -> Bool {
        guard let payload = payload?.trimmingCharacters(in: .whitespacesAndNewlines), !payload.isEmpty else {
            return true
        }
        return canonicalizedJSON(payload) == "{}"
    }

    private func canonicalizedJSON(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard JSONSerialization.isValidJSONObject(object),
              let canonicalData = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let canonical = String(data: canonicalData, encoding: .utf8)
        else {
            return raw
        }
        return canonical
    }

    #if DEBUG
        func testConsumeQuietEvents(_ events: [NormalizedAgentRuntimeEvent], session: AgentTabSession, runID: UUID, owner: AgentRunOwnership) async {
            let stream = AsyncStream<NormalizedAgentRuntimeEvent> { continuation in
                for event in events {
                    continuation.yield(event)
                }
                continuation.finish()
            }
            _ = await consumeEvents(stream, session: session, runID: runID, runAttemptID: owner.attemptID)
        }

        func testRetireToolCorrelation(tabID: UUID) {
            resetACPToolCorrelation(for: tabID)
        }

        func testHandleTrackerToolCall(
            invocationID: UUID,
            toolName: String,
            args: [String: Value]?,
            session: AgentTabSession
        ) {
            handleTrackerToolCall(invocationID: invocationID, toolName: toolName, args: args, session: session)
        }

        func testHandleTrackerToolResult(
            invocationID: UUID,
            toolName: String,
            args: [String: Value]?,
            resultJSON: String,
            isError: Bool,
            session: AgentTabSession
        ) {
            handleTrackerToolResult(
                invocationID: invocationID,
                toolName: toolName,
                args: args,
                resultJSON: resultJSON,
                isError: isError,
                session: session
            )
        }

        func testSyncACPSelectedModelFromRegistryIfNeeded(
            agentKind: AgentProviderKind,
            session: AgentTabSession
        ) -> Bool {
            syncACPSelectedModelFromRegistryIfNeeded(agentKind: agentKind, session: session)
        }

        static func testClassifyTransientTerminal(
            state: AgentSessionRunState,
            errorText: String?
        ) async -> (
            result: DomainAgentRunExecutionResult,
            errorText: String?,
            trace: [DomainAgentRunExecutionTraceEvent]
        ) {
            let operationResult: TransientOperationResult = switch state {
            case .completed:
                .completed
            case .cancelled:
                .cancelled
            case .failed:
                .failed(errorText: errorText)
            default:
                fatalError("Test requires a terminal ACP state")
            }
            let classification = await executeTransientOperation { operationResult }
            return (
                classification.report.result,
                classification.errorText,
                classification.report.trace
            )
        }

        static func testClassifyTransientSupersession() async -> (
            result: DomainAgentRunExecutionResult,
            errorText: String?,
            trace: [DomainAgentRunExecutionTraceEvent]
        ) {
            let classification = await executeTransientOperation { .superseded }
            return (
                classification.report.result,
                classification.errorText,
                classification.report.trace
            )
        }

        static func testValidateModelParameterApplicationReport(
            _ report: ACPModelParameterApplicationReport
        ) throws {
            try report.validateNoSkippedSelections()
        }

        static func testPerformConfigurationSequenceIfCurrent(
            isCurrent: () -> Bool,
            operations: [() async throws -> Void]
        ) async throws -> Bool {
            try await performConfigurationSequenceIfCurrent(
                isCurrent: isCurrent,
                operations: operations
            )
        }

        static func testExplicitSelectedModel(
            agentKind: AgentProviderKind,
            modelString: String?
        ) throws -> String? {
            try explicitSelectedModel(agentKind: agentKind, modelString: modelString)
        }
    #endif

    // MARK: - Provider Stream Tool Event Handling

    private func syncACPSelectedModelFromRegistryIfNeeded(
        agentKind: AgentProviderKind,
        session: AgentTabSession
    ) -> Bool {
        guard let providerID = agentKind.acpProviderID,
              providerID != .cursor,
              let snapshot = AgentModelCatalogRuntime.shared.acpRegistry.resolvedSnapshot(for: providerID)
        else {
            return false
        }
        let selectedModelRaw = session.selectedModelRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedIsDefault = selectedModelRaw.isEmpty
            || selectedModelRaw.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) == .orderedSame
        let selectedOption = snapshot.option(matching: selectedModelRaw)
        let selectedIsPlaceholder = selectedIsDefault || selectedOption?.isPlaceholderDefault == true
        guard selectedIsPlaceholder else { return false }
        if let preferredModelRaw = snapshot.preferredModelRaw,
           session.selectedModelRaw.caseInsensitiveCompare(preferredModelRaw) != .orderedSame
        {
            session.selectedModelRaw = preferredModelRaw
            return true
        }
        if !snapshot.contains(rawModel: session.selectedModelRaw) {
            session.selectedModelRaw = AgentModelCatalog.defaultModelRaw(for: agentKind)
            return true
        }
        return false
    }

    @discardableResult
    func handleToolStreamEvent(
        _ event: AgentToolStreamEvent,
        session: AgentTabSession
    ) -> Bool {
        // ACP provider events carry the provider's tool invocation IDs, while the
        // MCP tracker sees RepoPrompt's internal invocation IDs. Render explicit
        // RepoPrompt tool cards here so AgentModeViewModel can remain provider-neutral.
        switch event {
        case let .toolCall(call):
            guard AgentToolTrackingSupport.isRepoPromptTool(call.toolName) else { return false }
            guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(call.toolName) else { return true }
            #if DEBUG
                if MCPIntegrationHelper.normalizedRepoPromptToolName(call.toolName) == "agent_run" {
                    print("[ACPAgentRunToolTracking] ACP provider tool_call session=\(session.activeAgentSessionID?.uuidString ?? "nil") invocation=\(call.invocationID?.uuidString ?? "nil") tool=\(call.toolName) argsChars=\(call.argsJSON?.count ?? 0) itemCountBefore=\(session.items.count)")
                }
            #endif
            toolTrackingHooks.flushPendingAssistantDelta(session)
            toolTrackingHooks.endActiveAssistantSegment(session)
            toolTrackingHooks.endActiveReasoningSegment(session)
            let storedToolName = MCPIntegrationHelper.canonicalRepoPromptToolName(call.toolName) ?? call.toolName
            if let id = call.invocationID { acpProviderInvocationIDsByTabID[session.tabID, default: []].insert(id) }
            if let index = correlatedToolItemIndex(
                in: session,
                storedToolName: storedToolName,
                invocationID: call.invocationID,
                argsJSON: call.argsJSON,
                source: .provider,
                allowNameOnlyFallback: false
            ) {
                var updated = session.items[index]
                let hadArgs = hasAccountableToolPayload(updated.toolArgsJSON)
                if let trackerInvocationID = updated.toolInvocationID,
                   let providerInvocationID = call.invocationID,
                   trackerInvocationID != providerInvocationID
                {
                    recordProviderInvocation(providerInvocationID, forTrackerInvocationID: trackerInvocationID, tabID: session.tabID)
                    updated.toolInvocationID = providerInvocationID
                } else {
                    updated.toolInvocationID = updated.toolInvocationID ?? call.invocationID
                }
                updated.toolName = storedToolName
                if !isPlaceholderToolArgs(call.argsJSON) || isPlaceholderToolArgs(updated.toolArgsJSON) {
                    updated.toolArgsJSON = call.argsJSON ?? updated.toolArgsJSON
                }
                if updated.kind == .toolCall { updated.text = updated.toolArgsJSON ?? "" }
                if !hadArgs, hasAccountableToolPayload(call.argsJSON) {
                    toolTrackingHooks.addToolInputTokens(call.argsJSON, session)
                }
                session.replaceItem(at: index, with: updated)
            } else {
                if hasAccountableToolPayload(call.argsJSON) {
                    toolTrackingHooks.addToolInputTokens(call.argsJSON, session)
                }
                let toolItem = AgentChatItem.toolCall(
                    name: storedToolName,
                    invocationID: call.invocationID,
                    argsJSON: call.argsJSON,
                    sequenceIndex: session.nextSequenceIndex
                )
                session.appendItem(toolItem)
                recordProviderPlaceholderInvocationIfNeeded(call.invocationID, argsJSON: call.argsJSON, tabID: session.tabID)
            }
            toolTrackingHooks.requestUIRefresh(session, false)
            toolTrackingHooks.scheduleSave(session)
            return true

        case let .toolResult(result):
            // ACP terminal updates can omit title/name. Only an exact invocation
            // already owned by RepoPrompt can supply that missing identity.
            let knownToolName = result.invocationID.flatMap { id in
                session.indexedToolItemIndices(invocationID: id).last.flatMap { session.items[$0].toolName }
            }
            let toolName = AgentToolTrackingSupport.isRepoPromptTool(result.toolName) ? result.toolName : (knownToolName ?? result.toolName)
            guard AgentToolTrackingSupport.isRepoPromptTool(toolName) else { return false }
            guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(toolName) else { return true }
            if let id = result.invocationID { acpProviderInvocationIDsByTabID[session.tabID, default: []].insert(id) }
            #if DEBUG
                if MCPIntegrationHelper.normalizedRepoPromptToolName(toolName) == "agent_run" {
                    print("[ACPAgentRunToolTracking] ACP provider tool_result session=\(session.activeAgentSessionID?.uuidString ?? "nil") invocation=\(result.invocationID?.uuidString ?? "nil") tool=\(result.toolName) isError=\(result.isError) resultChars=\(result.resultJSON.count) itemCountBefore=\(session.items.count)")
                }
            #endif
            toolTrackingHooks.flushPendingAssistantDelta(session)
            toolTrackingHooks.endActiveAssistantSegment(session)
            toolTrackingHooks.endActiveReasoningSegment(session)
            removeProviderPlaceholderInvocation(result.invocationID, tabID: session.tabID)
            let storedToolName = MCPIntegrationHelper.canonicalRepoPromptToolName(toolName) ?? toolName
            if let index = correlatedToolItemIndex(
                in: session,
                storedToolName: storedToolName,
                invocationID: result.invocationID,
                argsJSON: result.argsJSON,
                source: .provider,
                allowNameOnlyFallback: true
            ) {
                var updated = session.items[index]
                let hadResult = hasNonEmptyPayload(updated.toolResultJSON)
                updated.kind = .toolResult
                updated.toolName = storedToolName
                if let trackerID = updated.toolInvocationID, let providerID = result.invocationID, trackerID != providerID {
                    recordProviderInvocation(providerID, forTrackerInvocationID: trackerID, tabID: session.tabID)
                    updated.toolInvocationID = providerID
                } else {
                    updated.toolInvocationID = updated.toolInvocationID ?? result.invocationID
                }
                if !isPlaceholderToolArgs(result.argsJSON) || isPlaceholderToolArgs(updated.toolArgsJSON) {
                    updated.toolArgsJSON = result.argsJSON ?? updated.toolArgsJSON
                }
                if let payload = AgentToolResultPayloadRetention.resolvedPayload(
                    existing: updated.toolResultJSON,
                    incoming: result.resultJSON,
                    incomingIsError: result.isError,
                    requireObjectReplacement: true
                ) {
                    updated.toolResultJSON = payload
                    updated.toolIsError = result.isError
                    updated.text = payload
                }
                if result.isError == true { updated.toolIsError = true }
                if !hadResult, hasNonEmptyPayload(result.resultJSON) {
                    toolTrackingHooks.addToolOutputTokens(result.resultJSON, session)
                }
                session.replaceItem(at: index, with: updated)
            } else {
                if hasNonEmptyPayload(result.resultJSON) {
                    toolTrackingHooks.addToolOutputTokens(result.resultJSON, session)
                }
                var toolResultItem = AgentChatItem.toolResult(
                    name: storedToolName,
                    invocationID: result.invocationID,
                    resultJSON: result.resultJSON,
                    isError: result.isError,
                    sequenceIndex: session.nextSequenceIndex
                )
                toolResultItem.toolArgsJSON = result.argsJSON
                session.appendItem(toolResultItem)
            }
            toolTrackingHooks.requestUIRefresh(session, false)
            toolTrackingHooks.scheduleSave(session)
            return true

        case let .legacyEvent(legacy):
            guard AgentToolTrackingSupport.isRepoPromptTool(legacy.toolName) else { return false }
            guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(legacy.toolName) else { return true }
            toolTrackingHooks.flushPendingAssistantDelta(session)
            toolTrackingHooks.endActiveAssistantSegment(session)
            toolTrackingHooks.endActiveReasoningSegment(session)
            let storedToolName = MCPIntegrationHelper.canonicalRepoPromptToolName(legacy.toolName) ?? legacy.toolName
            let toolItem = AgentChatItem.toolCall(
                name: storedToolName,
                argsJSON: nil,
                sequenceIndex: session.nextSequenceIndex
            )
            session.appendItem(toolItem)
            toolTrackingHooks.requestUIRefresh(session, false)
            toolTrackingHooks.scheduleSave(session)
            return true
        }
    }
}
