import Foundation
import MCP
import RepoPromptSettingsCore

@MainActor
final class ACPIntegratedAgentModeRunner {
    private enum TransientOperationResult {
        case completed
        case cancelled
        case failed(errorText: String?)
        /// A provider control command refused before anything reached the provider. It fails the run
        /// like `.failed`, but the live controller it was addressed to is left in place: nothing about
        /// that session changed, so tearing it down would only discard the target's warm session.
        case refusedBeforeSend(errorText: String)
        case superseded

        var debugDescription: String {
            switch self {
            case .completed:
                "state=completed error=nil"
            case .cancelled:
                "state=cancelled error=nil"
            case let .failed(errorText):
                "state=failed error=\(errorText ?? "nil")"
            case let .refusedBeforeSend(errorText):
                "state=refusedBeforeSend error=\(errorText)"
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
    private let providerFactory: AgentModeViewModel.ACPProviderFactory
    private let controllerFactory: AgentModeViewModel.ACPControllerFactory
    private var toolTrackingByTabID: [UUID: AgentToolTrackingController] = [:]
    private var toolTrackingRunIDByTabID: [UUID: UUID] = [:]
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
        var refusedBeforeSend = false
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
            case let .failed(errorText):
                explicitFailureText = .some(errorText)
                throw ExplicitTerminalFailure(errorText: errorText)
            case let .refusedBeforeSend(errorText):
                refusedBeforeSend = true
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
            retainsController: refusedBeforeSend
        )
    }

    init(
        hooks: AgentModeRunService.Hooks,
        terminalCommitBarrier: AgentRunTerminalCommitBarrier,
        toolTrackingHooks: AgentToolTrackingHooks,
        providerFactory: @escaping AgentModeViewModel.ACPProviderFactory,
        controllerFactory: @escaping AgentModeViewModel.ACPControllerFactory
    ) {
        self.hooks = hooks
        self.terminalCommitBarrier = terminalCommitBarrier
        self.toolTrackingHooks = toolTrackingHooks
        self.providerFactory = providerFactory
        self.controllerFactory = controllerFactory
    }

    func startRun(
        tabID: UUID,
        session: AgentTabSession,
        initialUserMessage: String,
        initialMessageForRun: String,
        attachments: [AgentImageAttachment],
        runRequest: ACPRunRequest,
        providerControlCommand: AgentProviderControlCommand? = nil,
        makeLease: @escaping (_ runID: UUID) -> MCPBootstrapLease,
        stopFence: AgentRunStartStopFence? = nil
    ) async {
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

        guard stopFence?.permitsStart(of: session) ?? true else { return }
        let ownership = session.beginRunAttempt(source: "acp")
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
            if let dedicatedNoteID, !handedToRunTask {
                AgentSelfCompactParkedPrefix.reparkUnattemptedDedicatedNote(
                    dedicatedNoteID, session: session
                ) { hooks.persistence.scheduleSave(session) }
            }
        }
        let freshRunRequest = runRequest
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
                makeLease: makeLease
            )
            return
        }
        if dedicatedNoteID != nil, session.acpController == nil {
            await failProviderControlCommandBeforeSend(
                session: session,
                runAttemptID: runAttemptID,
                attachmentReservationID: attachmentReservationID,
                errorText: "The self-compaction note has no live ACP session, so it was not sent."
            )
            return
        }
        if let existingController = session.acpController {
            let isCompatible = await existingController.isCompatibleWith(request: runRequest)
            guard isStartupStillCurrent(session: session, runAttemptID: runAttemptID) else { return }
            let hasReusableSession = isCompatible ? await existingController.hasReusableSession : false
            guard isStartupStillCurrent(session: session, runAttemptID: runAttemptID) else { return }
            if dedicatedNoteID != nil, !isCompatible || !hasReusableSession
                || AgentModeProcessRunIdentity.existingProcessRunID(for: session) == nil
            {
                await failProviderControlCommandBeforeSend(
                    session: session,
                    runAttemptID: runAttemptID,
                    attachmentReservationID: attachmentReservationID,
                    errorText: "The self-compaction note could not reuse its live ACP session, so it was not sent."
                )
                return
            }
            if isCompatible,
               hasReusableSession,
               let runID = AgentModeProcessRunIdentity.existingProcessRunID(for: session)
            {
                guard isStartupStillCurrent(session: session, runID: runID, runAttemptID: runAttemptID) else { return }
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
                    makeLease: makeLease
                )
                handedToRunTask = true
                return
            }

            session.acpController = nil
            AgentModeProcessRunIdentity.clearProcessRunID(for: session)
            await existingController.shutdown()
            guard isStartupStillCurrent(session: session, runAttemptID: runAttemptID) else { return }
        }
        let runID = AgentModeProcessRunIdentity.startFreshProcessRun(for: session)
        let lease = makeLease(runID)
        guard isStartupStillCurrent(session: session, runID: runID, runAttemptID: runAttemptID) else { return }

        let provider: any ACPAgentProvider
        do {
            guard let created = try await providerFactory(runRequest.agentKind, runRequest.modelString) else {
                await failBeforeProviderSend(
                    tabID: tabID,
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    attachmentReservationID: attachmentReservationID,
                    errorText: "No ACP provider is registered for \(runRequest.agentKind.displayName)."
                )
                return
            }
            provider = created
        } catch {
            await failBeforeProviderSend(
                tabID: tabID,
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                attachmentReservationID: attachmentReservationID,
                errorText: "ACP provider construction failed: \(error.localizedDescription)"
            )
            return
        }
        let support: ACPSupportResult
        do {
            support = try await provider.support(for: freshRunRequest)
        } catch is CancellationError {
            await cancelBeforeProviderSend(
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                attachmentReservationID: attachmentReservationID
            )
            return
        } catch {
            await failBeforeProviderSend(
                tabID: tabID,
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                attachmentReservationID: attachmentReservationID,
                errorText: "ACP support preflight failed: \(error.localizedDescription)"
            )
            return
        }
        guard isStartupStillCurrent(session: session, runID: runID, runAttemptID: runAttemptID) else { return }
        guard support == .supported else {
            await failBeforeProviderSend(
                tabID: tabID,
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                attachmentReservationID: attachmentReservationID,
                errorText: support.reason ?? "\(runRequest.agentKind.displayName) ACP is not available."
            )
            return
        }
        let controller: ACPAgentSessionController
        do {
            controller = try controllerFactory(provider, freshRunRequest)
        } catch {
            await failBeforeProviderSend(
                tabID: tabID,
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                attachmentReservationID: attachmentReservationID,
                errorText: "ACP controller init failed: \(error.localizedDescription)"
            )
            return
        }

        await controller.setExpectedMCPRunID(runID)
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
            guard let self, let session else { return }
            if let clientNameHint = runRequest.agentKind.mcpClientNameHint {
                await startToolTracking(for: session, runID: runID, clientNameHint: clientNameHint)
            }
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
                    attachmentReservationID: attachmentReservationID
                )
            } onCancel: {}
        }
    }

    /// Runs one turn on the session's existing, reusable controller.
    private func launchReusedSessionRun(
        tabID: UUID,
        session: AgentTabSession,
        ownership: AgentRunOwnership,
        runID: UUID,
        initialMessageForRun: String,
        dedicatedNoteID: AgentSelfCompactionDispatchID?,
        attachments: [AgentImageAttachment],
        controller: ACPAgentSessionController,
        runRequest: ACPRunRequest,
        attachmentReservationID: UUID?,
        providerControlCommand: AgentProviderControlCommand?,
        makeLease: @escaping (_ runID: UUID) -> MCPBootstrapLease
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
            guard let self, let session else { return }
            if let clientNameHint = runRequest.agentKind.mcpClientNameHint {
                await startToolTracking(for: session, runID: runID, clientNameHint: clientNameHint)
            }
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
                    attachmentReservationID: attachmentReservationID,
                    providerControlCommand: providerControlCommand,
                    leaseDisposition: leaseDisposition
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
        guard isStartupStillCurrent(session: session, runAttemptID: runAttemptID) else { return }
        let hasReusableSession = await controller.hasReusableSession
        let isRetired = hasReusableSession ? false : await controller.isRetired
        guard isStartupStillCurrent(session: session, runAttemptID: runAttemptID) else { return }
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
        attachments: [AgentImageAttachment],
        runRequest: ACPRunRequest,
        targetRunID: UUID?,
        targetRunAttemptID: UUID?,
        targetController: ACPAgentSessionController
    ) async -> Bool {
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
        // Active ACP steering is its own logical dispatch. If this send returns `false` the batch is
        // requeued as a follow-up, which composes again through `runPromptTurn` under a different
        // dispatch ID — correct, because this attempt was never accepted and the follow-up must
        // render whatever membership is current when it dispatches.
        let oversightDispatch = AgentSessionLinkPromptDispatchID.acpActiveSteering(runAttemptID: runAttemptID)
        var monitoring: AgentModeRunService.AgentSessionLinkDecoratedAgentMessage?
        let promptMessage: AgentMessage
        if carry.exactNote {
            promptMessage = agentMessage
        } else {
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
            promptMessage = decorated.message
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
            try await controller.prompt(promptMessage, request: runRequest)
            if let monitoring {
                hooks.providerInput.acceptAgentSessionLinkPrompt(
                    session, monitoring.dispatchContext, monitoring.claim
                )
            }
            if let dispatchID = carry.dispatchID {
                if AgentSelfCompactParkedPrefix.markAccepted(dispatchID, session: session) {
                    hooks.presentation.requestUIRefresh(session.tabID, true)
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

    private func startFreshRun(
        tabID: UUID,
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID,
        initialMessageForRun: String,
        attachments: [AgentImageAttachment],
        controller: ACPAgentSessionController,
        runRequest: ACPRunRequest,
        lease: MCPBootstrapLease,
        attachmentReservationID: UUID?
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
                attachmentReservationID: attachmentReservationID
            )
            return
        }

        var providerInitializationCompleted = false
        let classification = await Self.executeTransientOperation {
            do {
                let providerName = runRequest.agentKind.rawValue
                await lease.providerInitializationStarted(provider: providerName)
                log("bootstrap begin", runID: runID)
                let bootstrap = try await controller.bootstrap()
                providerInitializationCompleted = true
                await lease.providerInitializationCompleted(provider: providerName, outcome: "ready")
                log("bootstrap completed sessionID=\(bootstrap.sessionID)", runID: runID)
                guard session.runID == runID,
                      session.activeRunAttemptID == runAttemptID
                else {
                    await controller.shutdown()
                    return .superseded
                }
                var initialMessageForPromptTurn = initialMessageForRun
                if bootstrap.didFallbackToNewSessionAfterLoadFailure {
                    // Periodic turns preserve handoffs, so they cannot adopt a contextless replacement.
                    // Existing cancellation cleanup retires this unprompted controller.
                    guard !isPeriodic else { throw CancellationError() }

                    await hooks.providerInput.stageResumeRecoveryHandoffIfNeeded(session)
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
                    runRequest: runRequest
                ) else {
                    return .superseded
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

                return await runPromptTurn(
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    initialMessageForRun: initialMessageForPromptTurn,
                    attachments: attachments,
                    controller: controller,
                    runRequest: runRequest,
                    attachmentReservationID: attachmentReservationID,
                    prepareControllerForNextTurn: false
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let normalized = await controller.normalizeError(error)
                let normalizedText = displayText(for: normalized)
                log("fresh start failed raw=\(String(describing: error)) normalized=\(normalizedText)", runID: runID)
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
        attachments: [AgentImageAttachment],
        controller: ACPAgentSessionController,
        runRequest: ACPRunRequest,
        deferredLease: MCPBootstrapLease?,
        attachmentReservationID: UUID?,
        providerControlCommand: AgentProviderControlCommand? = nil,
        leaseDisposition: ProviderControlLeaseDisposition? = nil
    ) async {
        let classification = await Self.executeTransientOperation {
            var reachedPromptTurn = false
            defer {
                if let dedicatedNoteID, !reachedPromptTurn {
                    AgentSelfCompactParkedPrefix.reparkUnattemptedDedicatedNote(
                        dedicatedNoteID, session: session
                    ) { hooks.persistence.scheduleSave(session) }
                }
            }
            do {
                // A controller that can no longer run turns is retired as after any failed turn, even
                // when the turn was a control command that never got as far as sending.
                guard await controller.hasReusableSession else {
                    guard providerControlCommand != nil else {
                        return .failed(errorText: "\(runRequest.agentKind.displayName) ACP session is no longer reusable.")
                    }
                    // A control command retires a controller that can never run another turn, as after
                    // any failed turn, but leaves one that is merely busy alone.
                    return await Self.controlCommandUnreusableOutcome(controller: controller, runRequest: runRequest)
                }

                // A control command runs in the session exactly as it is: applying the run's model or
                // mode selections would be provider work the overseer never requested.
                if providerControlCommand == nil {
                    guard try await configureControllerForRun(
                        session: session,
                        runID: runID,
                        runAttemptID: runAttemptID,
                        controller: controller,
                        runRequest: runRequest
                    ) else {
                        return .superseded
                    }
                }

                if let deferredLease {
                    let acquired = await deferredLease.acquire()
                    guard acquired else {
                        let errorText = "RepoPrompt MCP routing policy could not be prepared before \(runRequest.agentKind.displayName) ACP prompt submission."
                        return providerControlCommand == nil
                            ? .failed(errorText: errorText)
                            : .refusedBeforeSend(errorText: errorText)
                    }
                    await deferredLease.releaseGateForDeferredRouting()
                    log("deferred MCP routing until ACP follow-up prompt", runID: runID)
                }

                reachedPromptTurn = true
                return await runPromptTurn(
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    initialMessageForRun: initialMessageForRun,
                    attachments: attachments,
                    controller: controller,
                    runRequest: runRequest,
                    attachmentReservationID: attachmentReservationID,
                    prepareControllerForNextTurn: true,
                    dedicatedNoteID: dedicatedNoteID,
                    providerControlCommand: providerControlCommand
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let normalized = await controller.normalizeError(error)
                let normalizedText = displayText(for: normalized)
                log("continue failed raw=\(String(describing: error)) normalized=\(normalizedText)", runID: runID)
                return .failed(errorText: normalizedText)
            }
        }

        leaseDisposition?.controllerRetained = classification.retainsController
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
        attachments: [AgentImageAttachment],
        controller: ACPAgentSessionController,
        runRequest: ACPRunRequest,
        attachmentReservationID: UUID?,
        prepareControllerForNextTurn: Bool,
        dedicatedNoteID: AgentSelfCompactionDispatchID? = nil,
        providerControlCommand: AgentProviderControlCommand? = nil
    ) async -> TransientOperationResult {
        if let providerControlCommand {
            return await runProviderControlCommandTurn(
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                command: providerControlCommand,
                controller: controller,
                runRequest: runRequest
            )
        }
        log("prompt turn begin prepare=\(prepareControllerForNextTurn)", runID: runID)
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

        if prepareControllerForNextTurn {
            let prepared = await controller.prepareForNextTurn()
            guard prepared else {
                if carry.exactNote, let dispatchID = carry.dispatchID {
                    if session.selfCompactNoteDispatchIsCurrent(dispatchID) {
                        AgentSelfCompactParkedPrefix.markNotAttempted(dispatchID, session: session)
                        hooks.persistence.scheduleSave(session)
                    }
                }
                return .failed(errorText: "\(runRequest.agentKind.displayName) ACP session is no longer reusable.")
            }
        }
        let events = await controller.events
        let consumeTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else {
                return TransientOperationResult.failed(errorText: "ACP event consumer deallocated.")
            }
            return await consumeEvents(
                events,
                session: session,
                runID: runID,
                runAttemptID: runAttemptID
            )
        }

        // Composed here, not next to `buildHeadlessAgentMessage`: `prepareForNextTurn()` and the
        // event-stream acquisition above both suspend, and an oversight link can be added or revoked while
        // they do. Reading membership before those awaits would ship enqueue-time inventory on every
        // reused/follow-up turn. This covers the initial, resumed, reusable-session, and follow-up
        // routes, which all converge here. Resumed providers still omit `AgentMessage.systemPrompt`;
        // the supplement rides the user-message channel precisely because a resumed thread cannot
        // refresh system text.
        let oversightDispatch = AgentSessionLinkPromptDispatchID.acpPromptTurn(runAttemptID: runAttemptID)
        var monitoring: AgentModeRunService.AgentSessionLinkDecoratedAgentMessage?
        let promptMessage: AgentMessage
        if carry.exactNote {
            // The framed note is the whole provider input. Decoration would change those bytes.
            promptMessage = agentMessage
        } else {
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
            promptMessage = decorated.message
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

        do {
            log("controller.prompt begin", runID: runID)
            try await controller.prompt(promptMessage, request: runRequest)
            // A non-throwing `controller.prompt` return is ACP's acceptance signal.
            if let monitoring {
                hooks.providerInput.acceptAgentSessionLinkPrompt(
                    session, monitoring.dispatchContext, monitoring.claim
                )
            }
            if let dispatchID = carry.dispatchID {
                if AgentSelfCompactParkedPrefix.markAccepted(dispatchID, session: session) {
                    hooks.presentation.requestUIRefresh(session.tabID, true)
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
            return .failed(errorText: promptFailureErrorText(outcome: outcome, fallback: normalizedText))
        }

        let outcome = await consumeTask.value
        log("event consumer completed \(outcome.debugDescription)", runID: runID)
        return outcome
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
        controller: ACPAgentSessionController,
        runRequest: ACPRunRequest
    ) async -> TransientOperationResult {
        let displayName = runRequest.agentKind.displayName
        return await controller.isRetired
            ? .failed(errorText: "\(displayName) ACP session is no longer reusable, so the requested command was not run.")
            : .refusedBeforeSend(errorText: "\(displayName) ACP session was busy, so the requested command was not run.")
    }

    private func runProviderControlCommandTurn(
        session: AgentTabSession,
        runID: UUID,
        runAttemptID: UUID,
        command: AgentProviderControlCommand,
        controller: ACPAgentSessionController,
        runRequest: ACPRunRequest
    ) async -> TransientOperationResult {
        let displayName = runRequest.agentKind.displayName
        log("provider control command turn begin kind=\(command.kind.rawValue)", runID: runID)
        let statusText = switch command.kind {
        case .compact: "Compacting context…"
        }
        setRunningStatus(statusText, source: .transport, session: session, urgent: true)

        guard await controller.prepareForNextTurn() else {
            return await Self.controlCommandUnreusableOutcome(controller: controller, runRequest: runRequest)
        }
        let events = await controller.events
        let consumeTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else {
                return TransientOperationResult.failed(errorText: "ACP event consumer deallocated.")
            }
            return await consumeEvents(
                events,
                session: session,
                runID: runID,
                runAttemptID: runAttemptID
            )
        }
        /// Stops the consumer of a turn that never started, so no terminal event is awaited.
        func abandonConsumer() async {
            consumeTask.cancel()
            _ = await consumeTask.value
        }

        // This run attempt and the admitted app-session incarnation and provider conversation, after
        // every await above. A cancelled or superseded attempt must never reach the write.
        guard isStartupStillCurrent(session: session, runID: runID, runAttemptID: runAttemptID) else {
            await abandonConsumer()
            return .superseded
        }
        guard !Task.isCancelled else {
            await abandonConsumer()
            return .cancelled
        }
        guard session.acpController === controller else {
            // An orphan: no longer the session's controller, so nothing else will retire it.
            await abandonConsumer()
            await controller.shutdown()
            return .refusedBeforeSend(
                errorText: "\(displayName) could not run the requested command because the session changed before it was sent."
            )
        }
        guard session.persistentSessionBindingIdentity == command.expectedBinding,
              !session.bindingTransitionInProgress,
              session.providerSessionID == command.expectedProviderConversation,
              command.selfCompactDispatchID == nil || session.selfCompactDispatchIsCurrent?() != false
        else {
            await abandonConsumer()
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
        do {
            log("controller.promptAdvertisedCommand begin", runID: runID)
            if command.selfCompactDispatchID?.stage == .compact {
                guard session.selfCompactDispatchIsCurrent?() != false else {
                    await abandonConsumer()
                    session.restoreContextCountVouchAfterUnsentCompaction(withdrawnVouch)
                    return .refusedBeforeSend(
                        errorText: "\(displayName) did not run the requested command because self-compaction was no longer admissible."
                    )
                }
                session.selfCompactACPCommandItemIDs = Set(session.items.map(\.id))
            }
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
            return .failed(errorText: promptFailureErrorText(outcome: outcome, fallback: normalizedText))
        }

        let outcome = await consumeTask.value
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
            toolTrackingHooks.requestUIRefresh(session.tabID, false)
            toolTrackingHooks.scheduleSave(session.tabID)
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
        runRequest: ACPRunRequest
    ) async throws -> Bool {
        let isCurrent = { [self] in
            isStartupStillCurrent(session: session, runID: runID, runAttemptID: runAttemptID)
                && session.acpController === controller
        }
        return try await Self.performConfigurationSequenceIfCurrent(
            isCurrent: isCurrent,
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

    /// Configuration calls can suspend on provider RPCs. Re-check ownership before and after
    /// every step so an attempt superseded during one response cannot continue with later writes.
    private static func performConfigurationSequenceIfCurrent(
        isCurrent: () -> Bool,
        operations: [() async throws -> Void]
    ) async throws -> Bool {
        for operation in operations {
            guard isCurrent() else { return false }
            try await operation()
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
           AgentACPModelRegistry.shared.resolvedSnapshot(for: providerID)?.contains(rawModel: model) != true
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
                  session.activeRunAttemptID == runAttemptID
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
        lease _: MCPBootstrapLease,
        attachmentReservationID: UUID?
    ) async {
        guard let ownership = session.activeRunOwnership,
              ownership.attemptID == runAttemptID
        else { return }
        hooks.providerInput.recordPendingHandoffSendOutcome(session, false)
        await terminalCommitBarrier.commit(.init(
            binding: hooks.bindTerminalSession(session),
            ownership: ownership,
            expectedRunID: runID,
            terminalState: .cancelled,
            source: "acp.acquireFailure",
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
                    // Nothing reached the provider; the session's controller and run identity stand.
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
                hooks.presentation.requestUIRefresh(session.tabID, true)
            }
            return
        }
        session.runningStatusText = value
        session.runningStatusSource = normalizedSource
        hooks.bindingObservation.updateBindings(session)
        hooks.presentation.requestUIRefresh(session.tabID, urgent)
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
        if let index = correlatedToolCallItemIndex(
            in: session,
            storedToolName: storedToolName,
            invocationID: invocationID,
            argsJSON: argsJSON,
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
        } else if let index = correlatedToolResultItemIndex(
            in: session,
            storedToolName: storedToolName,
            invocationID: invocationID,
            argsJSON: argsJSON,
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
        toolTrackingHooks.requestUIRefresh(session.tabID, false)
        toolTrackingHooks.scheduleSave(session.tabID)
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
        let resolvedInvocationID = consumeProviderInvocation(forTrackerInvocationID: invocationID, tabID: session.tabID) ?? invocationID
        if let index = correlatedToolResultItemIndex(
            in: session,
            storedToolName: storedToolName,
            invocationID: resolvedInvocationID,
            argsJSON: argsJSON,
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
            updated.toolResultJSON = resultJSON
            updated.toolArgsJSON = argsJSON ?? updated.toolArgsJSON
            updated.toolIsError = isError
            updated.text = resultJSON
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
        toolTrackingHooks.requestUIRefresh(session.tabID, false)
        toolTrackingHooks.scheduleSave(session.tabID)
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

    private func correlatedToolCallItemIndex(
        in session: AgentTabSession,
        storedToolName: String,
        invocationID: UUID?,
        argsJSON: String?,
        allowNameOnlyFallback: Bool
    ) -> Int? {
        var inspectedItemCount = 0
        if let invocationID {
            let candidates = indexedThenActiveTurnToolCandidates(
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
            inspectedItemCount += candidates.inspectedItemCount
            if let index = candidates.indices.last {
                MCPToolObserverAttributionContext.record(
                    correlationPath: candidates.usedFallbackScan ? "invocation_id_active_turn_scan" : "invocation_id",
                    scannedItemCount: inspectedItemCount
                )
                return index
            }
        }
        if let argsJSON {
            let signature = toolInvocationSignature(toolName: storedToolName, argsJSON: argsJSON)
            let candidates = indexedThenActiveTurnToolCandidates(
                indexedIndices: session.indexedToolItemIndices(
                    signature: signature,
                    pendingCallsOnly: true
                ),
                session: session,
                where: {
                    $0.kind == .toolCall
                        && self.toolInvocationSignature(toolName: $0.toolName, argsJSON: $0.toolArgsJSON) == signature
                }
            )
            inspectedItemCount += candidates.inspectedItemCount
            if let index = candidates.indices.last {
                MCPToolObserverAttributionContext.record(
                    correlationPath: candidates.usedFallbackScan ? "signature_active_turn_scan" : "signature",
                    scannedItemCount: inspectedItemCount
                )
                return index
            }
        }
        if let argsJSON,
           hasAccountableToolPayload(argsJSON)
        {
            let normalizedToolName = AgentTabSession.normalizedToolCorrelationName(storedToolName)
            let placeholderCandidates = session.activeTurnToolItemIndices(where: { item in
                item.kind == .toolCall
                    && self.isProviderPlaceholderInvocation(item.toolInvocationID, tabID: session.tabID)
                    && self.isPlaceholderToolArgs(item.toolArgsJSON)
                    && AgentTabSession.normalizedToolCorrelationName(item.toolName) == normalizedToolName
            })
            inspectedItemCount += placeholderCandidates.scannedItemCount
            if placeholderCandidates.indices.count == 1 {
                MCPToolObserverAttributionContext.record(
                    correlationPath: "placeholder_active_turn_scan",
                    scannedItemCount: inspectedItemCount
                )
                return placeholderCandidates.indices[0]
            }
        }
        if allowNameOnlyFallback {
            let normalizedToolName = AgentTabSession.normalizedToolCorrelationName(storedToolName)
            let fallback = session.activeTurnToolItemIndices(where: {
                $0.kind == .toolCall
                    && AgentTabSession.normalizedToolCorrelationName($0.toolName) == normalizedToolName
            })
            inspectedItemCount += fallback.scannedItemCount
            MCPToolObserverAttributionContext.record(
                correlationPath: fallback.lastIndex == nil ? "none" : "name_active_turn_scan",
                scannedItemCount: inspectedItemCount
            )
            return fallback.lastIndex
        }
        MCPToolObserverAttributionContext.record(
            correlationPath: "none",
            scannedItemCount: inspectedItemCount
        )
        return nil
    }

    private func correlatedToolResultItemIndex(
        in session: AgentTabSession,
        storedToolName: String,
        invocationID: UUID?,
        argsJSON: String?,
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
                    $0.kind == .toolResult
                        && $0.toolInvocationID == invocationID
                        && self.shouldUpdateExistingToolResult(
                            $0,
                            storedToolName: storedToolName,
                            argsJSON: argsJSON,
                            tabID: session.tabID
                        )
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
            let signatureIndices = session.indexedToolItemIndices(signature: signature)
            let callCandidates = indexedThenActiveTurnToolCandidates(
                indexedIndices: signatureIndices,
                session: session,
                where: {
                    $0.kind == .toolCall
                        && self.toolInvocationSignature(toolName: $0.toolName, argsJSON: $0.toolArgsJSON) == signature
                }
            )
            inspectedItemCount += callCandidates.inspectedItemCount
            if let index = callCandidates.indices.last {
                MCPToolObserverAttributionContext.record(
                    correlationPath: callCandidates.usedFallbackScan
                        ? "signature_call_active_turn_scan"
                        : "signature_call",
                    scannedItemCount: inspectedItemCount
                )
                return index
            }
            let resultCandidates = indexedThenActiveTurnToolCandidates(
                indexedIndices: signatureIndices,
                session: session,
                where: {
                    $0.kind == .toolResult
                        && self.toolInvocationSignature(toolName: $0.toolName, argsJSON: $0.toolArgsJSON) == signature
                }
            )
            inspectedItemCount += resultCandidates.inspectedItemCount
            if let index = resultCandidates.indices.last {
                MCPToolObserverAttributionContext.record(
                    correlationPath: resultCandidates.usedFallbackScan
                        ? "signature_result_active_turn_scan"
                        : "signature_result",
                    scannedItemCount: inspectedItemCount
                )
                return index
            }
        }
        if allowNameOnlyFallback {
            let normalizedToolName = AgentTabSession.normalizedToolCorrelationName(storedToolName)
            let fallback = session.activeTurnToolItemIndices(where: {
                $0.kind == .toolCall
                    && AgentTabSession.normalizedToolCorrelationName($0.toolName) == normalizedToolName
            })
            inspectedItemCount += fallback.scannedItemCount
            MCPToolObserverAttributionContext.record(
                correlationPath: fallback.lastIndex == nil ? "none" : "name_active_turn_scan",
                scannedItemCount: inspectedItemCount
            )
            return fallback.lastIndex
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

    private func shouldUpdateExistingToolResult(
        _ item: AgentChatItem,
        storedToolName: String,
        argsJSON: String?,
        tabID: UUID
    ) -> Bool {
        guard item.kind == .toolResult else { return false }
        if hasExactToolInvocationSignature(item, storedToolName: storedToolName, argsJSON: argsJSON) {
            return true
        }
        switch AgentTranscriptToolNormalizer.status(for: item) {
        case .pending, .running:
            return hasSameNormalizedToolName(item.toolName, storedToolName)
                || isKnownProviderPlaceholder(item, tabID: tabID)
        case .success, .warning, .failed, .cancelled, .unknown:
            return false
        }
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

    private func consumeProviderInvocation(forTrackerInvocationID trackerInvocationID: UUID, tabID: UUID) -> UUID? {
        guard var mappings = acpProviderInvocationByTrackerInvocationIDByTabID[tabID] else { return nil }
        let providerInvocationID = mappings.removeValue(forKey: trackerInvocationID)
        acpProviderInvocationByTrackerInvocationIDByTabID[tabID] = mappings.isEmpty ? nil : mappings
        return providerInvocationID
    }

    private func resetACPToolCorrelation(for tabID: UUID) {
        acpProviderInvocationByTrackerInvocationIDByTabID[tabID] = nil
        acpProviderPlaceholderInvocationIDsByTabID[tabID] = nil
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
              let snapshot = AgentACPModelRegistry.shared.resolvedSnapshot(for: providerID)
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
            if let index = correlatedToolCallItemIndex(
                in: session,
                storedToolName: storedToolName,
                invocationID: call.invocationID,
                argsJSON: call.argsJSON,
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
                updated.toolArgsJSON = call.argsJSON ?? updated.toolArgsJSON
                if updated.kind == .toolCall {
                    updated.text = call.argsJSON ?? ""
                }
                if !hadArgs, hasAccountableToolPayload(call.argsJSON) {
                    toolTrackingHooks.addToolInputTokens(call.argsJSON, session)
                }
                session.replaceItem(at: index, with: updated)
            } else if let index = correlatedToolResultItemIndex(
                in: session,
                storedToolName: storedToolName,
                invocationID: call.invocationID,
                argsJSON: call.argsJSON,
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
                updated.toolArgsJSON = call.argsJSON ?? updated.toolArgsJSON
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
            toolTrackingHooks.requestUIRefresh(session.tabID, false)
            toolTrackingHooks.scheduleSave(session.tabID)
            return true

        case let .toolResult(result):
            guard AgentToolTrackingSupport.isRepoPromptTool(result.toolName) else { return false }
            guard !AgentToolTrackingSupport.shouldHideToolFromTranscript(result.toolName) else { return true }
            #if DEBUG
                if MCPIntegrationHelper.normalizedRepoPromptToolName(result.toolName) == "agent_run" {
                    print("[ACPAgentRunToolTracking] ACP provider tool_result session=\(session.activeAgentSessionID?.uuidString ?? "nil") invocation=\(result.invocationID?.uuidString ?? "nil") tool=\(result.toolName) isError=\(result.isError) resultChars=\(result.resultJSON.count) itemCountBefore=\(session.items.count)")
                }
            #endif
            toolTrackingHooks.flushPendingAssistantDelta(session)
            toolTrackingHooks.endActiveAssistantSegment(session)
            toolTrackingHooks.endActiveReasoningSegment(session)
            removeProviderPlaceholderInvocation(result.invocationID, tabID: session.tabID)
            let storedToolName = MCPIntegrationHelper.canonicalRepoPromptToolName(result.toolName) ?? result.toolName
            if let index = correlatedToolResultItemIndex(
                in: session,
                storedToolName: storedToolName,
                invocationID: result.invocationID,
                argsJSON: result.argsJSON,
                allowNameOnlyFallback: true
            ) {
                var updated = session.items[index]
                let hadResult = hasNonEmptyPayload(updated.toolResultJSON)
                updated.kind = .toolResult
                updated.toolName = storedToolName
                updated.toolInvocationID = updated.toolInvocationID ?? result.invocationID
                updated.toolResultJSON = result.resultJSON
                updated.toolArgsJSON = result.argsJSON ?? updated.toolArgsJSON
                updated.toolIsError = result.isError
                updated.text = result.resultJSON
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
            toolTrackingHooks.requestUIRefresh(session.tabID, false)
            toolTrackingHooks.scheduleSave(session.tabID)
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
            toolTrackingHooks.requestUIRefresh(session.tabID, false)
            toolTrackingHooks.scheduleSave(session.tabID)
            return true
        }
    }
}
