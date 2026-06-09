import Foundation
import MCP

@MainActor
final class ACPIntegratedAgentModeRunner {
    private struct ConsumeEventsOutcome {
        let terminalState: AgentSessionRunState
        let errorText: String?
    }

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
        session: AgentModeViewModel.TabSession,
        initialUserMessage: String,
        initialMessageForRun: String,
        attachments: [AgentImageAttachment],
        runRequest: ACPRunRequest,
        makeLease: @escaping (_ runID: UUID) -> MCPBootstrapLease
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

        let ownership = session.beginRunAttempt(source: "acp")
        let runAttemptID = ownership.attemptID
        session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .preparingRuntime)
        session.runState = .running
        hooks.setAgentRunActive(tabID, true)
        setRunningStatus(initialTransportStatusText(for: runRequest.agentKind), source: .transport, session: session, urgent: true)

        let freshRunRequest = runRequest
        if let existingController = session.acpController {
            let isCompatible = await existingController.isCompatibleWith(request: runRequest)
            guard isStartupStillCurrent(session: session, runAttemptID: runAttemptID) else { return }
            let hasReusableSession = isCompatible ? await existingController.hasReusableSession : false
            guard isStartupStillCurrent(session: session, runAttemptID: runAttemptID) else { return }
            if isCompatible,
               hasReusableSession,
               let runID = AgentModeProcessRunIdentity.existingProcessRunID(for: session)
            {
                guard isStartupStillCurrent(session: session, runID: runID, runAttemptID: runAttemptID) else { return }
                session.installRunAttemptTerminalResources(ownership: ownership) { [weak self] _ in
                    self?.prepareToolTrackingTeardown(for: session, matchingRunID: runID)
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
                            attachments: attachments,
                            controller: existingController,
                            runRequest: runRequest,
                            attachmentReservationID: attachmentReservationID
                        )
                    } onCancel: {}
                }
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

        guard let provider = providerFactory(runRequest.agentKind, runRequest.modelString) else {
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
        session.installRunAttemptTerminalResources(ownership: ownership) { [weak self] terminalState in
            let trackerTeardown = self?.prepareToolTrackingTeardown(for: session, matchingRunID: runID)
            return {
                await trackerTeardown?()
                switch terminalState {
                case .failed:
                    await lease.failAndRelease()
                case .cancelled:
                    await lease.cancelAndCleanup()
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

    func submitActivePrompt(
        session: AgentModeViewModel.TabSession,
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

        let agentMessage = hooks.buildHeadlessAgentMessage(
            session,
            messageForRun,
            runID,
            attachments
        )

        do {
            log("active steering session/prompt begin attempt=\(runAttemptID)", runID: runID)
            try await controller.prompt(agentMessage, request: runRequest)
            log("active steering session/prompt completed attempt=\(runAttemptID)", runID: runID)
            let identity = await controller.currentProviderSessionIdentity()
            applyProviderSessionIdentity(identity, session: session)
            // A successful prompt return means the steering prompt was delivered and
            // completed at the ACP layer. The event consumer may already have handled
            // the terminal and finalized the run, so do not require the original
            // activeRunAttemptID to still be present here.
            return true
        } catch {
            let identity = await controller.refreshProviderSessionIdentityAfterPromptInterruption()
            applyProviderSessionIdentity(identity, session: session)
            let normalized = await controller.normalizeError(error)
            let normalizedText = displayText(for: normalized)
            log("active steering session/prompt failed attempt=\(runAttemptID) raw=\(String(describing: error)) normalized=\(normalizedText)", runID: runID)
            return false
        }
    }

    private func isStartupStillCurrent(
        session: AgentModeViewModel.TabSession,
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
        session: AgentModeViewModel.TabSession,
        runID: UUID,
        runAttemptID: UUID,
        attachmentReservationID: UUID?,
        errorText: String
    ) async {
        guard isStartupStillCurrent(session: session, runID: runID, runAttemptID: runAttemptID),
              let ownership = session.activeRunOwnership,
              ownership.attemptID == runAttemptID
        else { return }
        hooks.recordPendingHandoffSendOutcome(session, false)
        await terminalCommitBarrier.commit(.init(
            session: session,
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
        session: AgentModeViewModel.TabSession,
        runID: UUID,
        runAttemptID: UUID,
        attachmentReservationID: UUID?
    ) async {
        guard isStartupStillCurrent(session: session, runID: runID, runAttemptID: runAttemptID),
              let ownership = session.activeRunOwnership,
              ownership.attemptID == runAttemptID
        else { return }
        hooks.recordPendingHandoffSendOutcome(session, false)
        await terminalCommitBarrier.commit(.init(
            session: session,
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
        session: AgentModeViewModel.TabSession,
        runID: UUID,
        runAttemptID: UUID,
        initialMessageForRun: String,
        attachments: [AgentImageAttachment],
        controller: ACPAgentSessionController,
        runRequest: ACPRunRequest,
        lease: MCPBootstrapLease,
        attachmentReservationID: UUID?
    ) async {
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

        do {
            log("bootstrap begin", runID: runID)
            let bootstrap = try await controller.bootstrap()
            log("bootstrap completed sessionID=\(bootstrap.sessionID)", runID: runID)
            guard session.runID == runID,
                  session.activeRunAttemptID == runAttemptID
            else {
                await controller.shutdown()
                return
            }
            var initialMessageForPromptTurn = initialMessageForRun
            if bootstrap.didFallbackToNewSessionAfterLoadFailure {
                await hooks.stageResumeRecoveryHandoffIfNeeded(session)
                initialMessageForPromptTurn = hooks.prependPendingHandoffIfNeeded(initialMessageForRun, session)
            }
            applyProviderSessionIdentity(
                bootstrap.providerSessionIdentity,
                invalidatedResumeSessionID: bootstrap.invalidatedResumeSessionID,
                session: session
            )
            _ = syncACPSelectedModelFromRegistryIfNeeded(agentKind: runRequest.agentKind, session: session)
            session.isDirty = true
            hooks.scheduleSave(session.tabID)
            hooks.updateBindings(session)

            try await applyExplicitSelectedModelIfNeeded(runRequest, controller: controller, runID: runID)
            await controller.setAutoApproveAllToolPermissions(runRequest.autoApproveAllToolPermissions)
            try await applyRequestedSessionModeIfNeeded(runRequest.sessionModeID, controller: controller, runID: runID)
            setRunningStatus(waitingForConnectionStatusText(for: runRequest.agentKind), source: .transport, session: session, urgent: true)

            let routed = await lease.releaseWhenRouted()
            log("releaseWhenRouted routed=\(routed)", runID: runID)
            guard routed else {
                await finalize(
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    controller: controller,
                    attachmentReservationID: attachmentReservationID,
                    terminalState: .failed,
                    errorText: "RepoPrompt MCP routing did not complete before \(runRequest.agentKind.displayName) ACP prompt submission.",
                    notifyTurnComplete: false,
                    shouldShutdownController: true
                )
                return
            }

            await runPromptTurn(
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
            log("fresh start cancelled", runID: runID)
            await finalize(
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                controller: controller,
                attachmentReservationID: attachmentReservationID,
                terminalState: .cancelled,
                errorText: nil,
                notifyTurnComplete: false,
                shouldShutdownController: true
            )
        } catch {
            let normalized = await controller.normalizeError(error)
            let normalizedText = displayText(for: normalized)
            log("fresh start failed raw=\(String(describing: error)) normalized=\(normalizedText)", runID: runID)
            await finalize(
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                controller: controller,
                attachmentReservationID: attachmentReservationID,
                terminalState: .failed,
                errorText: normalizedText,
                notifyTurnComplete: false,
                shouldShutdownController: true
            )
        }
    }

    private func continueRun(
        tabID: UUID,
        session: AgentModeViewModel.TabSession,
        runID: UUID,
        runAttemptID: UUID,
        initialMessageForRun: String,
        attachments: [AgentImageAttachment],
        controller: ACPAgentSessionController,
        runRequest: ACPRunRequest,
        attachmentReservationID: UUID?
    ) async {
        do {
            guard await controller.hasReusableSession else {
                await finalize(
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    controller: controller,
                    attachmentReservationID: attachmentReservationID,
                    terminalState: .failed,
                    errorText: "\(runRequest.agentKind.displayName) ACP session is no longer reusable.",
                    notifyTurnComplete: false,
                    shouldShutdownController: true
                )
                return
            }

            try await applyExplicitSelectedModelIfNeeded(runRequest, controller: controller, runID: runID)
            await controller.setAutoApproveAllToolPermissions(runRequest.autoApproveAllToolPermissions)
            try await applyRequestedSessionModeIfNeeded(runRequest.sessionModeID, controller: controller, runID: runID)

            await runPromptTurn(
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                initialMessageForRun: initialMessageForRun,
                attachments: attachments,
                controller: controller,
                runRequest: runRequest,
                attachmentReservationID: attachmentReservationID,
                prepareControllerForNextTurn: true
            )
        } catch is CancellationError {
            await finalize(
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                controller: controller,
                attachmentReservationID: attachmentReservationID,
                terminalState: .cancelled,
                errorText: nil,
                notifyTurnComplete: false,
                shouldShutdownController: true
            )
        } catch {
            let normalized = await controller.normalizeError(error)
            let normalizedText = displayText(for: normalized)
            log("continue failed raw=\(String(describing: error)) normalized=\(normalizedText)", runID: runID)
            await finalize(
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                controller: controller,
                attachmentReservationID: attachmentReservationID,
                terminalState: .failed,
                errorText: normalizedText,
                notifyTurnComplete: false,
                shouldShutdownController: true
            )
        }
    }

    private func runPromptTurn(
        session: AgentModeViewModel.TabSession,
        runID: UUID,
        runAttemptID: UUID,
        initialMessageForRun: String,
        attachments: [AgentImageAttachment],
        controller: ACPAgentSessionController,
        runRequest: ACPRunRequest,
        attachmentReservationID: UUID?,
        prepareControllerForNextTurn: Bool
    ) async {
        log("prompt turn begin prepare=\(prepareControllerForNextTurn)", runID: runID)
        setRunningStatus("Thinking…", source: .transport, session: session, urgent: true)
        let agentMessage = hooks.buildHeadlessAgentMessage(
            session,
            initialMessageForRun,
            runID,
            attachments
        )
        hooks.recordPendingHandoffSendOutcome(session, true)
        hooks.stageConsumedAttachmentFilesForDeferredCleanup(attachments, session)
        hooks.markAttachmentsConsumed(session, attachmentReservationID)

        if prepareControllerForNextTurn {
            let prepared = await controller.prepareForNextTurn()
            guard prepared else {
                await finalize(
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID,
                    controller: controller,
                    attachmentReservationID: attachmentReservationID,
                    terminalState: .failed,
                    errorText: "\(runRequest.agentKind.displayName) ACP session is no longer reusable.",
                    notifyTurnComplete: false,
                    shouldShutdownController: true
                )
                return
            }
        }
        let events = await controller.events
        let consumeTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else {
                return ConsumeEventsOutcome(terminalState: .failed, errorText: "ACP event consumer deallocated.")
            }
            return await consumeEvents(
                events,
                session: session,
                runID: runID,
                runAttemptID: runAttemptID
            )
        }

        do {
            log("controller.prompt begin", runID: runID)
            try await controller.prompt(agentMessage, request: runRequest)
            let identity = await controller.currentProviderSessionIdentity()
            applyProviderSessionIdentity(identity, session: session)
            log("controller.prompt returned; awaiting event consumer", runID: runID)
        } catch {
            let identity = await controller.refreshProviderSessionIdentityAfterPromptInterruption()
            applyProviderSessionIdentity(identity, session: session)
            let normalizedError = await controller.normalizeError(error)
            let normalizedText = displayText(for: normalizedError)
            log("controller.prompt failed raw=\(String(describing: error)) normalized=\(normalizedText)", runID: runID)
            let outcome = await consumeTask.value
            let errorText = promptFailureErrorText(outcome: outcome, fallback: normalizedText)
            await finalize(
                session: session,
                runID: runID,
                runAttemptID: runAttemptID,
                controller: controller,
                attachmentReservationID: attachmentReservationID,
                terminalState: .failed,
                errorText: errorText,
                notifyTurnComplete: false,
                shouldShutdownController: true
            )
            return
        }

        let outcome = await consumeTask.value
        let outcomeErrorDescription = outcome.errorText ?? "nil"
        log("event consumer completed state=\(outcome.terminalState.rawValue) error=\(outcomeErrorDescription)", runID: runID)
        await finalize(
            session: session,
            runID: runID,
            runAttemptID: runAttemptID,
            controller: controller,
            attachmentReservationID: attachmentReservationID,
            terminalState: outcome.terminalState,
            errorText: outcome.errorText,
            notifyTurnComplete: outcome.terminalState == .completed,
            shouldShutdownController: outcome.terminalState != .completed
        )
    }

    private func applyProviderSessionIdentity(
        _ identity: ACPProviderSessionIdentity,
        invalidatedResumeSessionID: String? = nil,
        session: AgentModeViewModel.TabSession
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
            changed = true
        }
        if session.providerSessionID != providerSessionID {
            session.providerSessionID = providerSessionID
            changed = true
        }
        guard changed else { return }
        session.isDirty = true
        hooks.scheduleSave(session.tabID)
        hooks.updateBindings(session)
    }

    private func applyRequestedSessionModeIfNeeded(
        _ requestedMode: String?,
        controller: ACPAgentSessionController,
        runID: UUID
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
        guard runRequest.agentKind == .openCode || runRequest.agentKind == .cursor else { return }
        guard let model = runRequest.modelString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty,
              model.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
        else {
            return
        }
        if runRequest.agentKind == .cursor,
           model.caseInsensitiveCompare(AgentModel.cursorAuto.rawValue) != .orderedSame,
           AgentACPModelRegistry.shared.resolvedSnapshot(for: .cursor)?.contains(rawModel: model) != true
        {
            return
        }
        log("applying \(runRequest.agentKind.displayName) selected model=\(model)", runID: runID)
        try await controller.setSessionModel(model)
    }

    private func promptFailureErrorText(
        outcome: ConsumeEventsOutcome,
        fallback: String
    ) -> String {
        let unexpectedStreamEnd = "ACP events stream ended unexpectedly."
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let outcomeError = outcome.errorText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !outcomeError.isEmpty,
              outcomeError != unexpectedStreamEnd
        else {
            return trimmedFallback.isEmpty ? unexpectedStreamEnd : trimmedFallback
        }
        return outcomeError
    }

    private func consumeEvents(
        _ events: AsyncStream<NormalizedAgentRuntimeEvent>,
        session: AgentModeViewModel.TabSession,
        runID: UUID,
        runAttemptID: UUID
    ) async -> ConsumeEventsOutcome {
        if let ownership = session.activeRunOwnership, ownership.attemptID == runAttemptID {
            session.recordRunProgress(ownership: ownership, kind: .stageTransition, stage: .running)
        }
        for await event in events {
            guard session.runID == runID,
                  session.activeRunAttemptID == runAttemptID
            else {
                return ConsumeEventsOutcome(terminalState: .cancelled, errorText: nil)
            }

            if let ownership = session.activeRunOwnership, ownership.attemptID == runAttemptID {
                session.recordRunProgress(ownership: ownership, kind: .providerEvent, stage: .running)
            }
            switch event {
            case let .stream(result):
                await hooks.handleHeadlessStreamResult(result, session, runID, runAttemptID)
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
                        hooks.updateBindings(session)
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
                return ConsumeEventsOutcome(terminalState: state, errorText: errorText)
            }
        }

        return ConsumeEventsOutcome(
            terminalState: .failed,
            errorText: "ACP events stream ended unexpectedly."
        )
    }

    private func handleAcquireFailure(
        tabID _: UUID,
        session: AgentModeViewModel.TabSession,
        runID: UUID,
        runAttemptID: UUID,
        controller: ACPAgentSessionController,
        lease _: MCPBootstrapLease,
        attachmentReservationID: UUID?
    ) async {
        guard let ownership = session.activeRunOwnership,
              ownership.attemptID == runAttemptID
        else { return }
        hooks.recordPendingHandoffSendOutcome(session, false)
        await terminalCommitBarrier.commit(.init(
            session: session,
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

    private func finalize(
        session: AgentModeViewModel.TabSession,
        runID: UUID,
        runAttemptID: UUID,
        controller: ACPAgentSessionController?,
        attachmentReservationID: UUID?,
        terminalState: AgentSessionRunState,
        errorText: String?,
        notifyTurnComplete: Bool,
        shouldShutdownController: Bool
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
            session: session,
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
                if terminalState != .completed {
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
        for session: AgentModeViewModel.TabSession,
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
        for session: AgentModeViewModel.TabSession,
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
        source: AgentModeViewModel.TabSession.RunningStatusSource?,
        session: AgentModeViewModel.TabSession,
        urgent: Bool = false
    ) {
        let normalized = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (normalized?.isEmpty == false) ? normalized : nil
        let normalizedSource = value == nil ? nil : source
        guard session.runningStatusText != value || session.runningStatusSource != normalizedSource else {
            if urgent {
                hooks.updateBindings(session)
                hooks.requestUIRefresh(session.tabID, true)
            }
            return
        }
        session.runningStatusText = value
        session.runningStatusSource = normalizedSource
        hooks.updateBindings(session)
        hooks.requestUIRefresh(session.tabID, urgent)
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
        session: AgentModeViewModel.TabSession
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
        session: AgentModeViewModel.TabSession
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

    private func correlatedToolCallItemIndex(
        in session: AgentModeViewModel.TabSession,
        storedToolName: String,
        invocationID: UUID?,
        argsJSON: String?,
        allowNameOnlyFallback: Bool
    ) -> Int? {
        if let invocationID,
           let index = lastCurrentTurnItemIndex(in: session, where: {
               $0.kind == .toolCall
                   && $0.toolInvocationID == invocationID
                   && shouldUpdateExistingToolCall($0, storedToolName: storedToolName, argsJSON: argsJSON, tabID: session.tabID)
           })
        {
            return index
        }
        if let argsJSON,
           let index = lastCurrentTurnItemIndex(in: session, where: {
               $0.kind == .toolCall
                   && toolInvocationSignature(toolName: $0.toolName, argsJSON: $0.toolArgsJSON)
                   == toolInvocationSignature(toolName: storedToolName, argsJSON: argsJSON)
           })
        {
            return index
        }
        if let argsJSON,
           hasAccountableToolPayload(argsJSON)
        {
            let placeholderCandidates = currentTurnItemIndices(in: session).filter { index in
                let item = session.items[index]
                return item.kind == .toolCall
                    && isProviderPlaceholderInvocation(item.toolInvocationID, tabID: session.tabID)
                    && isPlaceholderToolArgs(item.toolArgsJSON)
                    && MCPIntegrationHelper.normalizedRepoPromptToolName(item.toolName ?? "")
                    == MCPIntegrationHelper.normalizedRepoPromptToolName(storedToolName)
            }
            if placeholderCandidates.count == 1 {
                return placeholderCandidates[0]
            }
        }
        if allowNameOnlyFallback {
            return lastCurrentTurnItemIndex(in: session, where: {
                $0.kind == .toolCall
                    && MCPIntegrationHelper.normalizedRepoPromptToolName($0.toolName ?? "")
                    == MCPIntegrationHelper.normalizedRepoPromptToolName(storedToolName)
            })
        }
        return nil
    }

    private func correlatedToolResultItemIndex(
        in session: AgentModeViewModel.TabSession,
        storedToolName: String,
        invocationID: UUID?,
        argsJSON: String?,
        allowNameOnlyFallback: Bool
    ) -> Int? {
        if let invocationID,
           let index = lastCurrentTurnItemIndex(in: session, where: {
               $0.kind == .toolCall
                   && $0.toolInvocationID == invocationID
                   && shouldUpdateExistingToolCall($0, storedToolName: storedToolName, argsJSON: argsJSON, tabID: session.tabID)
           })
        {
            return index
        }
        if let invocationID,
           let index = lastCurrentTurnItemIndex(in: session, where: {
               $0.kind == .toolResult
                   && $0.toolInvocationID == invocationID
                   && shouldUpdateExistingToolResult($0, storedToolName: storedToolName, argsJSON: argsJSON, tabID: session.tabID)
           })
        {
            return index
        }
        let signature = toolInvocationSignature(toolName: storedToolName, argsJSON: argsJSON)
        if argsJSON != nil,
           let index = lastCurrentTurnItemIndex(in: session, where: {
               $0.kind == .toolCall
                   && toolInvocationSignature(toolName: $0.toolName, argsJSON: $0.toolArgsJSON) == signature
           })
        {
            return index
        }
        if argsJSON != nil,
           let index = lastCurrentTurnItemIndex(in: session, where: {
               $0.kind == .toolResult
                   && toolInvocationSignature(toolName: $0.toolName, argsJSON: $0.toolArgsJSON) == signature
           })
        {
            return index
        }
        if allowNameOnlyFallback {
            return lastCurrentTurnItemIndex(in: session, where: {
                $0.kind == .toolCall
                    && MCPIntegrationHelper.normalizedRepoPromptToolName($0.toolName ?? "")
                    == MCPIntegrationHelper.normalizedRepoPromptToolName(storedToolName)
            })
        }
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

    private func currentTurnItemIndices(in session: AgentModeViewModel.TabSession) -> Range<Int> {
        let start = currentTurnStartIndex(in: session)
        return start ..< session.items.endIndex
    }

    private func lastCurrentTurnItemIndex(
        in session: AgentModeViewModel.TabSession,
        where predicate: (AgentChatItem) -> Bool
    ) -> Int? {
        let start = currentTurnStartIndex(in: session)
        guard start < session.items.endIndex else { return nil }
        for index in stride(from: session.items.index(before: session.items.endIndex), through: start, by: -1) {
            if predicate(session.items[index]) {
                return index
            }
        }
        return nil
    }

    private func currentTurnStartIndex(in session: AgentModeViewModel.TabSession) -> Int {
        session.items.lastIndex(where: { $0.kind == .user }).map { $0 + 1 } ?? session.items.startIndex
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
        let normalizedToolName = MCPIntegrationHelper.normalizedRepoPromptToolName(toolName ?? "")
        let normalizedArgs = canonicalizedJSON(argsJSON) ?? ""
        return "\(normalizedToolName)|\(normalizedArgs)"
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
            session: AgentModeViewModel.TabSession
        ) {
            handleTrackerToolCall(invocationID: invocationID, toolName: toolName, args: args, session: session)
        }

        func testHandleTrackerToolResult(
            invocationID: UUID,
            toolName: String,
            args: [String: Value]?,
            resultJSON: String,
            isError: Bool,
            session: AgentModeViewModel.TabSession
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
            session: AgentModeViewModel.TabSession
        ) -> Bool {
            syncACPSelectedModelFromRegistryIfNeeded(agentKind: agentKind, session: session)
        }
    #endif

    // MARK: - Provider Stream Tool Event Handling

    private func syncACPSelectedModelFromRegistryIfNeeded(
        agentKind: AgentProviderKind,
        session: AgentModeViewModel.TabSession
    ) -> Bool {
        guard let providerID = agentKind.acpProviderID,
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
        session: AgentModeViewModel.TabSession
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
