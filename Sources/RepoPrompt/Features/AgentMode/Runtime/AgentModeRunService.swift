import Foundation

@MainActor
final class AgentModeRunService {
    struct Dependencies {
        let windowID: Int
        let headlessProviderFactory: AgentModeViewModel.HeadlessProviderFactory
        let acpProviderFactory: AgentModeViewModel.ACPProviderFactory
        let acpControllerFactory: AgentModeViewModel.ACPControllerFactory
        let connectionPolicyInstaller: AgentModeViewModel.ConnectionPolicyInstaller
        let mcpServerEnabler: AgentModeViewModel.MCPServerEnabler
        let workspacePathProvider: (AgentModeViewModel.TabSession) throws -> String?
        let codexCoordinator: CodexAgentModeCoordinator
        let claudeCoordinator: ClaudeAgentModeCoordinator
        let shouldManageCodexTooling: Bool
        let providerRuntimePermissionResolver: (_ agent: AgentProviderKind, _ profile: AgentProviderPermissionProfile) -> AgentProviderRuntimePermissionBinding
        let cancelMCPToolsForRun: (_ runID: UUID, _ reason: String) -> Void
        /// Waits until the given runID has zero active MCP tool executions.
        /// Throws `CancellationError` if the calling Task is cancelled.
        let awaitNoActiveMCPTools: (_ runID: UUID) async throws -> Void
        /// Returns whether the parent run is currently blocked in child `agent_run.wait` scopes.
        let activeAgentRunWaitQuery: (_ runID: UUID) -> Bool
        /// Bounded wait for child `agent_run.wait` scopes to drain before Claude native interrupt.
        let childAgentRunWaitDrainTimeoutSeconds: TimeInterval
    }

    enum CancellationIntent {
        case userStop
        case executionLocationChange
    }

    enum CancellationCompletion: Equatable {
        /// Return after canonical terminal publication and synchronous provider detachment.
        case terminalPublished
        /// Also wait for the exactly-once attempt/provider teardown closure to return.
        case terminalTeardownCompleted
    }

    /// Strategy for restoring draft text back to the composer.
    enum DraftRestorationStrategy: Equatable {
        /// Only restore if the composer is currently empty.
        case replaceIfEmpty
        /// Always prepend the restored text, even if the user has started typing.
        case prependAlways
    }

    struct Hooks {
        let estimateRuntimeTokens: (String) -> Int
        let addUserInputTokensToActiveNonCodexTurn: (Int, AgentModeViewModel.TabSession) -> Void
        let startNonCodexTurnAccountingIfNeeded: (AgentModeViewModel.TabSession, String) -> Void
        let reserveAttachmentsForTurn: ([AgentImageAttachment], AgentModeViewModel.TabSession) -> UUID?
        let markAttachmentsConsumed: (AgentModeViewModel.TabSession, UUID?) -> Void
        let stageConsumedAttachmentFilesForDeferredCleanup: ([AgentImageAttachment], AgentModeViewModel.TabSession) -> Void
        let consumeDeferredAttachmentCleanup: (AgentModeViewModel.TabSession, Bool) -> Void
        let finalizeAttachmentsForTurn: (AgentModeViewModel.TabSession, UUID?, AgentModeViewModel.AttachmentTurnDisposition) -> Void
        let setAgentRunActive: (UUID, Bool) -> Void
        let updateBindings: (AgentModeViewModel.TabSession) -> Void
        let requestUIRefresh: (UUID, Bool) -> Void
        let scheduleSave: (UUID) -> Void
        let notifyAgentTurnComplete: (AgentModeViewModel.TabSession) -> Void
        let handleHeadlessStreamResult: (AIStreamResult, AgentModeViewModel.TabSession, UUID, UUID) async -> Void
        let buildHeadlessAgentMessage: (AgentModeViewModel.TabSession, String, UUID, [AgentImageAttachment]) -> AgentMessage
        let finalizeStreamingItems: (AgentModeViewModel.TabSession) -> Void
        let finalizePendingToolCalls: (AgentModeViewModel.TabSession, AgentSessionRunState) -> Void
        let finalizePendingToolCallsWithUpperBound: (AgentModeViewModel.TabSession, AgentSessionRunState, Int?) -> Void
        let finalizeNonCodexTurnUsage: (AgentModeViewModel.TabSession, Int?, Int?, Int?) -> Void
        let cancelPendingQuestion: (AgentModeViewModel.TabSession) -> Void
        let cancelPendingApproval: (AgentModeViewModel.TabSession) -> Void
        let cancelPendingApplyEditsReview: (AgentModeViewModel.TabSession, String) -> Void
        let cancelPendingWorktreeMergeReview: (AgentModeViewModel.TabSession, String) -> Void
        let flushPendingAssistantDelta: (AgentModeViewModel.TabSession) -> Void
        let clearPendingAssistantDelta: (AgentModeViewModel.TabSession) -> Void
        let prepareTerminalPublication: (AgentModeViewModel.TabSession) -> Void
        let makeTerminalPublicationEnvelope: (
            AgentModeViewModel.TabSession,
            AgentRunOwnership,
            AgentSessionRunState
        ) -> AgentRunTerminalPublicationEnvelope?
        let publishTerminalCommit: (
            AgentModeViewModel.TabSession,
            AgentRunTerminalCommitRevision,
            AgentRunEpochTransitionKind?
        ) async -> AgentRunTerminalPublicationResult
        let startFollowUpRun: (UUID, String) -> Void
        /// Restore queued steering draft text back to the composer.
        let restoreDraftText: (_ tabID: UUID, _ text: String, _ message: String, _ strategy: DraftRestorationStrategy) -> Void
        /// Augment queued steering text with skill context, tagged files, and attachment rendering before submit.
        let augmentUserMessageForProviderSend: (
            _ text: String,
            _ attachments: [AgentImageAttachment],
            _ taggedFileAttachments: [AgentTaggedFileAttachment],
            _ session: AgentModeViewModel.TabSession?
        ) async -> String
        /// Stages a transcript handoff for fresh-session resume recovery.
        let stageResumeRecoveryHandoffIfNeeded: (_ session: AgentModeViewModel.TabSession) async -> Void
        /// Prepends a staged handoff payload to provider-facing text.
        let prependPendingHandoffIfNeeded: (_ text: String, _ session: AgentModeViewModel.TabSession) -> String
        /// Records whether a staged handoff payload was accepted by the provider send attempt.
        let recordPendingHandoffSendOutcome: (_ session: AgentModeViewModel.TabSession, _ didSend: Bool) -> Void
        /// Wakes MCP waiters once a steering instruction has actually been delivered to the provider.
        let signalMCPInstructionDelivered: (_ session: AgentModeViewModel.TabSession) async -> Void
    }

    private let dependencies: Dependencies
    private let hooks: Hooks
    private let headlessRunner: HeadlessAgentModeRunner
    private let codexRunner: CodexIntegratedAgentModeRunner
    private let claudeRunner: ClaudeIntegratedAgentModeRunner
    private let acpRunner: ACPIntegratedAgentModeRunner
    private let terminalCommitBarrier: AgentRunTerminalCommitBarrier

    private static let enableSteeringDebugLogging = false

    private func steeringDebugLog(_ message: @autoclosure () -> String) {
        #if DEBUG
            guard Self.enableSteeringDebugLogging else { return }
            print(message())
        #endif
    }

    init(
        dependencies: Dependencies,
        hooks: Hooks,
        toolTrackingHooks: AgentToolTrackingHooks
    ) {
        self.dependencies = dependencies
        self.hooks = hooks
        let terminalCommitBarrier = AgentRunTerminalCommitBarrier(hooks: hooks)
        self.terminalCommitBarrier = terminalCommitBarrier
        dependencies.codexCoordinator.installTerminalCommitBarrier(terminalCommitBarrier)
        headlessRunner = HeadlessAgentModeRunner(
            headlessProviderFactory: dependencies.headlessProviderFactory,
            hooks: hooks,
            terminalCommitBarrier: terminalCommitBarrier
        )
        codexRunner = CodexIntegratedAgentModeRunner(
            mcpServerEnabler: dependencies.mcpServerEnabler,
            codexCoordinator: dependencies.codexCoordinator,
            hooks: hooks
        )
        claudeRunner = ClaudeIntegratedAgentModeRunner(
            claudeCoordinator: dependencies.claudeCoordinator,
            hooks: hooks,
            terminalCommitBarrier: terminalCommitBarrier
        )
        acpRunner = ACPIntegratedAgentModeRunner(
            hooks: hooks,
            terminalCommitBarrier: terminalCommitBarrier,
            toolTrackingHooks: toolTrackingHooks,
            providerFactory: dependencies.acpProviderFactory,
            controllerFactory: dependencies.acpControllerFactory
        )
    }

    @discardableResult
    func startRun(
        tabID: UUID,
        session: AgentModeViewModel.TabSession,
        initialUserMessage: String,
        initialMessageForRun: String,
        attachments: [AgentImageAttachment],
        codexFallbackContext: AgentModeViewModel.TabSession.CodexFallbackSubmissionContext? = nil
    ) async -> CodexAgentModeCoordinator.NativeSendOutcome? {
        assert(session.tabID == tabID, "AgentModeRunService.startRun requires the originating tab ID to match the TabSession tab ID")
        let selectedAgent = session.selectedAgent
        let selectedModelString = session.selectedModelRaw == AgentModel.defaultModel.rawValue
            ? nil
            : session.selectedModelRaw
        let runtimePermission = dependencies.providerRuntimePermissionResolver(selectedAgent, session.permissionProfile)
        let workspacePath: String?
        do {
            workspacePath = try dependencies.workspacePathProvider(session)
        } catch {
            let message = Self.providerStartupFailureMessage(for: error)
            await failBeforeProviderStartup(session: session, message: message)
            return selectedAgent == .codexExec ? .failed(message: message) : nil
        }

        if selectedAgent == .codexExec {
            return await codexRunner.startRun(
                tabID: tabID,
                session: session,
                initialMessageForRun: initialMessageForRun,
                attachments: attachments,
                fallbackContext: codexFallbackContext
            )
        }

        let acpRunRequest: ACPRunRequest? = if selectedAgent.acpProviderID != nil {
            ACPRunRequest(
                agentKind: selectedAgent,
                modelString: selectedModelString,
                workspacePath: workspacePath,
                resumeSessionID: session.providerSessionID,
                attachments: attachments,
                taskLabelKind: session.mcpControlContext?.taskLabelKind,
                sessionModeID: runtimePermission.acpSessionModeID,
                autoApproveAllToolPermissions: runtimePermission.autoApproveAllACPToolPermissions
            )
        } else {
            nil
        }

        let windowID = dependencies.windowID
        let mcpServerEnabler = dependencies.mcpServerEnabler
        let connectionPolicyInstaller = dependencies.connectionPolicyInstaller
        let taskLabelKind = session.mcpControlContext?.taskLabelKind
        let allowsAgentExternalControlTools = session.mcpControlContext != nil && session.parentSessionID == nil
        let makeLease: (_ runID: UUID) -> MCPBootstrapLease = { runID in
            let leaseSpec = MCPBootstrapLeaseSpec.agentMode(
                tabID: tabID,
                runID: runID,
                gateID: UUID(),
                windowID: windowID,
                agent: selectedAgent,
                taskLabelKind: taskLabelKind,
                allowsAgentExternalControlTools: allowsAgentExternalControlTools
            )
            return MCPBootstrapLease(
                spec: leaseSpec,
                mcpServerEnabler: mcpServerEnabler,
                policyInstaller: MCPBootstrapLease.agentModePolicyInstaller(connectionPolicyInstaller)
            )
        }
        if selectedAgent.usesClaudeNativeRuntime {
            await claudeRunner.startRun(
                tabID: tabID,
                session: session,
                initialUserMessage: initialUserMessage,
                initialMessageForRun: initialMessageForRun,
                attachments: attachments,
                makeLease: makeLease
            )
            return nil
        }
        if let acpRunRequest {
            await acpRunner.startRun(
                tabID: tabID,
                session: session,
                initialUserMessage: initialUserMessage,
                initialMessageForRun: initialMessageForRun,
                attachments: attachments,
                runRequest: acpRunRequest,
                makeLease: makeLease
            )
            return nil
        }
        await headlessRunner.startRun(
            tabID: tabID,
            session: session,
            initialUserMessage: initialUserMessage,
            initialMessageForRun: initialMessageForRun,
            attachments: attachments,
            makeLease: makeLease
        )
        return nil
    }

    /// Attempts to submit a prompt into an already-active ACP session.
    @discardableResult
    func submitActiveACPPromptIfSupported(
        session: AgentModeViewModel.TabSession,
        messageForRun: String,
        attachments: [AgentImageAttachment],
        targetRunID: UUID?,
        targetRunAttemptID: UUID?,
        targetController: ACPAgentSessionController
    ) async -> Bool {
        let selectedAgent = session.selectedAgent
        let selectedModelString = session.selectedModelRaw == AgentModel.defaultModel.rawValue
            ? nil
            : session.selectedModelRaw
        let runtimePermission = dependencies.providerRuntimePermissionResolver(selectedAgent, session.permissionProfile)
        guard selectedAgent.acpProviderID != nil,
              session.runState == .running,
              attachments.isEmpty,
              session.runID == targetRunID,
              session.activeRunAttemptID == targetRunAttemptID,
              session.acpController === targetController
        else {
            steeringDebugLog("[AgentRunSteeringWake] ACP active submit guard rejected agent=\(selectedAgent.rawValue) state=\(session.runState.rawValue) attachments=\(attachments.count) runID=\(String(describing: session.runID)) targetRunID=\(String(describing: targetRunID)) attempt=\(String(describing: session.activeRunAttemptID)) targetAttempt=\(String(describing: targetRunAttemptID)) hasController=\(session.acpController != nil) controllerMatches=\(session.acpController === targetController)")
            return false
        }
        let workspacePath: String?
        do {
            workspacePath = try dependencies.workspacePathProvider(session)
        } catch {
            let message = Self.providerStartupFailureMessage(for: error)
            await failBeforeProviderStartup(session: session, message: message)
            return false
        }
        let runRequest = ACPRunRequest(
            agentKind: selectedAgent,
            modelString: selectedModelString,
            workspacePath: workspacePath,
            resumeSessionID: session.providerSessionID,
            attachments: attachments,
            taskLabelKind: session.mcpControlContext?.taskLabelKind,
            sessionModeID: runtimePermission.acpSessionModeID,
            autoApproveAllToolPermissions: runtimePermission.autoApproveAllACPToolPermissions
        )
        let sent = await acpRunner.submitActivePrompt(
            session: session,
            messageForRun: messageForRun,
            attachments: attachments,
            runRequest: runRequest,
            targetRunID: targetRunID,
            targetRunAttemptID: targetRunAttemptID,
            targetController: targetController
        )
        steeringDebugLog("[AgentRunSteeringWake] ACP active submit runner returned sent=\(sent) agent=\(selectedAgent.rawValue) model=\(selectedModelString ?? "default") runID=\(String(describing: targetRunID)) attempt=\(String(describing: targetRunAttemptID))")
        return sent
    }

    @discardableResult
    func submitQueuedACPSteeringIfSupported(session: AgentModeViewModel.TabSession) async -> Bool {
        guard session.selectedAgent.acpProviderID != nil,
              session.runState == .running
        else {
            return false
        }

        // If a flush task is already draining the queue, just return — it will
        // pick up the newly appended instruction on its next loop iteration.
        guard session.acpSteeringFlushTask == nil else {
            steeringDebugLog("[AgentRunSteeringWake] ACP flush already active tab=\(session.tabID) queue=\(session.pendingACPSteeringInstructions.count)")
            return true
        }
        guard !session.pendingACPSteeringInstructions.isEmpty else { return false }

        guard let runID = session.runID,
              let runAttemptID = session.activeRunAttemptID,
              let controller = session.acpController else { return false }

        let tabID = session.tabID
        steeringDebugLog("[AgentRunSteeringWake] ACP flush start tab=\(tabID) runID=\(runID) attempt=\(runAttemptID) queue=\(session.pendingACPSteeringInstructions.count)")
        session.acpSteeringFlushTask = Task { [weak self, weak session, controller] in
            guard let self, let session else { return }
            defer {
                session.acpSteeringFlushTask = nil
                if session.runState == .running,
                   session.selectedAgent.acpProviderID != nil,
                   !session.pendingACPSteeringInstructions.isEmpty
                {
                    Task { @MainActor [weak self, weak session] in
                        guard let self, let session else { return }
                        _ = await self.submitQueuedACPSteeringIfSupported(session: session)
                    }
                }
            }

            while true {
                guard isCurrentACPSteeringAttempt(session: session, runID: runID, runAttemptID: runAttemptID, controller: controller) else {
                    requeueQueuedACPSteeringAsFollowUp(
                        tabID: tabID,
                        session: session,
                        matching: { $0.targetRunID == runID && $0.targetRunAttemptID == runAttemptID },
                        reason: "stale ACP steering attempt before MCP idle wait"
                    )
                    return
                }
                guard !session.pendingACPSteeringInstructions.isEmpty else { return }

                if let first = session.pendingACPSteeringInstructions.first,
                   first.targetRunID != runID || first.targetRunAttemptID != runAttemptID
                {
                    requeueLeadingACPSteeringAsFollowUp(
                        tabID: tabID,
                        session: session,
                        while: { $0.targetRunID != runID || $0.targetRunAttemptID != runAttemptID },
                        reason: "queued ACP steering target no longer matches active run"
                    )
                    continue
                }

                // Protect the current turn before the MCP idle wait. ACP providers can
                // complete the original prompt while we are waiting for RepoPrompt tools
                // to drain; that terminal must be treated as superseded once steering has
                // been accepted into the serialized ACP queue, otherwise the run finalizes
                // before we can send the interrupt+prompt.
                let supersedingBaseline = session.pendingSupersedingTurnCompletions
                session.pendingSupersedingTurnCompletions += 1
                let releaseSupersedingProtectionIfUnused = {
                    if session.pendingSupersedingTurnCompletions > supersedingBaseline {
                        session.pendingSupersedingTurnCompletions -= 1
                    }
                }

                // Wait for all active MCP tool executions to finish before interrupting.
                steeringDebugLog("[AgentRunSteeringWake] ACP flush waiting MCP idle tab=\(tabID) runID=\(runID) attempt=\(runAttemptID) queue=\(session.pendingACPSteeringInstructions.count)")
                do {
                    try await dependencies.awaitNoActiveMCPTools(runID)
                    steeringDebugLog("[AgentRunSteeringWake] ACP flush MCP idle returned tab=\(tabID) runID=\(runID) attempt=\(runAttemptID) queue=\(session.pendingACPSteeringInstructions.count)")
                } catch {
                    releaseSupersedingProtectionIfUnused()
                    steeringDebugLog("[AgentRunSteeringWake] ACP flush MCP idle cancelled tab=\(tabID) runID=\(runID) attempt=\(runAttemptID) error=\(error)")
                    requeueAllQueuedACPSteeringAsFollowUp(
                        tabID: tabID,
                        session: session,
                        reason: "ACP steering MCP idle wait was cancelled"
                    )
                    return
                }

                guard isCurrentACPSteeringAttempt(session: session, runID: runID, runAttemptID: runAttemptID, controller: controller),
                      !session.pendingACPSteeringInstructions.isEmpty
                else {
                    releaseSupersedingProtectionIfUnused()
                    requeueQueuedACPSteeringAsFollowUp(
                        tabID: tabID,
                        session: session,
                        matching: { $0.targetRunID == runID && $0.targetRunAttemptID == runAttemptID },
                        reason: "stale ACP steering attempt after MCP idle wait"
                    )
                    return
                }

                let steeringBatch = Array(session.pendingACPSteeringInstructions.prefix(while: {
                    $0.targetRunID == runID && $0.targetRunAttemptID == runAttemptID
                }))
                guard !steeringBatch.isEmpty else { continue }
                session.pendingACPSteeringInstructions.removeFirst(steeringBatch.count)

                let providerTextForSend = coalescedACPProviderText(for: steeringBatch)
                var dequeuedUserInputTokens: [Int] = []
                for _ in steeringBatch {
                    guard !session.pendingNonCodexUserInputTokenQueue.isEmpty else { break }
                    dequeuedUserInputTokens.append(session.pendingNonCodexUserInputTokenQueue.removeFirst())
                }
                let steeringUserInputTokens = dequeuedUserInputTokens.count == steeringBatch.count
                    ? dequeuedUserInputTokens.reduce(0, +)
                    : hooks.estimateRuntimeTokens(providerTextForSend)
                hooks.addUserInputTokensToActiveNonCodexTurn(steeringUserInputTokens, session)

                let augmentedSteeringText = await hooks.augmentUserMessageForProviderSend(
                    providerTextForSend,
                    steeringBatch.flatMap(\.attachments),
                    steeringBatch.flatMap(\.taggedFileAttachments),
                    session
                )
                let sent = await submitActiveACPPromptIfSupported(
                    session: session,
                    messageForRun: augmentedSteeringText,
                    attachments: steeringBatch.flatMap(\.attachments),
                    targetRunID: runID,
                    targetRunAttemptID: runAttemptID,
                    targetController: controller
                )
                hooks.recordPendingHandoffSendOutcome(session, sent)
                if sent {
                    await hooks.signalMCPInstructionDelivered(session)
                }
                if !sent {
                    releaseSupersedingProtectionIfUnused()
                    session.pendingACPSteeringInstructions.insert(contentsOf: steeringBatch, at: 0)
                    if !dequeuedUserInputTokens.isEmpty {
                        session.pendingNonCodexUserInputTokenQueue.insert(contentsOf: dequeuedUserInputTokens, at: 0)
                    }
                    requeueAllQueuedACPSteeringAsFollowUp(
                        tabID: tabID,
                        session: session,
                        reason: "ACP interrupt+prompt send returned false"
                    )
                    return
                }
            }
        }

        return true
    }

    private static func providerStartupFailureMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty
        {
            return description
        }
        let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? String(describing: error) : description
    }

    private func failBeforeProviderStartup(session: AgentModeViewModel.TabSession, message: String) async {
        let ownership = session.activeRunOwnership ?? session.beginRunAttempt(source: "runService.startupFailure")
        hooks.recordPendingHandoffSendOutcome(session, false)
        await terminalCommitBarrier.commit(.init(
            session: session,
            ownership: ownership,
            expectedRunID: session.runID,
            terminalState: .failed,
            source: "runService.startupFailure",
            errorText: message,
            attachmentDisposition: .deleteFiles,
            finalizeNonCodexUsage: session.selectedAgent != .codexExec,
            supportsFollowUp: false,
            notifyTurnComplete: false,
            prepareProviderState: {
                session.provider = nil
                return nil
            }
        ))
    }

    private func isCurrentACPSteeringAttempt(
        session: AgentModeViewModel.TabSession,
        runID: UUID,
        runAttemptID: UUID,
        controller: ACPAgentSessionController
    ) -> Bool {
        session.runState == .running
            && session.selectedAgent.acpProviderID != nil
            && session.runID == runID
            && session.activeRunAttemptID == runAttemptID
            && session.acpController === controller
    }

    private func requeueQueuedACPSteeringAsFollowUp(
        tabID: UUID,
        session: AgentModeViewModel.TabSession,
        matching shouldRequeue: (AgentModeViewModel.TabSession.ACPSteeringInstruction) -> Bool,
        reason: String
    ) {
        let instructions = session.pendingACPSteeringInstructions.filter(shouldRequeue)
        guard !instructions.isEmpty else { return }
        session.pendingACPSteeringInstructions.removeAll(where: shouldRequeue)
        requeueACPSteeringAsFollowUp(instructions, tabID: tabID, session: session, reason: reason)
    }

    private func requeueLeadingACPSteeringAsFollowUp(
        tabID: UUID,
        session: AgentModeViewModel.TabSession,
        while shouldRequeue: (AgentModeViewModel.TabSession.ACPSteeringInstruction) -> Bool,
        reason: String
    ) {
        let instructions = Array(session.pendingACPSteeringInstructions.prefix(while: shouldRequeue))
        guard !instructions.isEmpty else { return }
        session.pendingACPSteeringInstructions.removeFirst(instructions.count)
        requeueACPSteeringAsFollowUp(instructions, tabID: tabID, session: session, reason: reason)
    }

    private func requeueAllQueuedACPSteeringAsFollowUp(
        tabID: UUID,
        session: AgentModeViewModel.TabSession,
        reason: String
    ) {
        let instructions = session.pendingACPSteeringInstructions
        guard !instructions.isEmpty else { return }
        session.pendingACPSteeringInstructions.removeAll()
        requeueACPSteeringAsFollowUp(instructions, tabID: tabID, session: session, reason: reason)
    }

    private func coalescedACPProviderText(
        for instructions: [AgentModeViewModel.TabSession.ACPSteeringInstruction]
    ) -> String {
        let steeringTexts = instructions
            .map { $0.providerText.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !steeringTexts.isEmpty else { return "" }

        var seenInterruptedTexts = Set<String>()
        let steeringTextSet = Set(steeringTexts)
        let interruptedTexts = instructions.compactMap { instruction -> String? in
            guard let text = instruction.interruptedPromptProviderText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty,
                  !steeringTextSet.contains(text),
                  seenInterruptedTexts.insert(text).inserted
            else {
                return nil
            }
            return text
        }

        guard !interruptedTexts.isEmpty || steeringTexts.count > 1 else {
            return steeringTexts[0]
        }

        let interruptedSection = interruptedTexts.isEmpty ? "" : """
        <interrupted_user_messages>
        \(interruptedTexts.enumerated().map { index, text in
            "<message index=\"\(index + 1)\">\n\(text)\n</message>"
        }.joined(separator: "\n"))
        </interrupted_user_messages>

        """
        let steeringSection = """
        <steering_messages>
        \(steeringTexts.enumerated().map { index, text in
            "<message index=\"\(index + 1)\">\n\(text)\n</message>"
        }.joined(separator: "\n"))
        </steering_messages>
        """

        return """
        \(interruptedSection)\(steeringSection)

        The active ACP prompt was cancelled so this steering could be delivered. Treat the interrupted user messages, if any, followed by the steering messages above as the latest user messages in chronological order.
        """
    }

    private func requeueACPSteeringAsFollowUp(
        _ instructions: [AgentModeViewModel.TabSession.ACPSteeringInstruction],
        tabID: UUID,
        session: AgentModeViewModel.TabSession,
        reason: String
    ) {
        var providerTexts = [coalescedACPProviderText(for: instructions)]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !providerTexts.isEmpty else { return }
        if session.runState == .completed, session.acpController != nil {
            let first = providerTexts.removeFirst()
            if !providerTexts.isEmpty {
                session.pendingInstructions.insert(contentsOf: providerTexts, at: 0)
            }
            session.mcpFollowUpRunPending = true
            hooks.startFollowUpRun(tabID, first)
            return
        }
        session.pendingInstructions.insert(contentsOf: providerTexts, at: 0)
        session.isDirty = true
        hooks.updateBindings(session)
        hooks.scheduleSave(tabID)
    }

    /// Claims superseding protection for the currently outstanding Claude turn when
    /// a steering instruction has been accepted into the live queue. The claim is
    /// scoped to unprotected expected turn IDs rather than queued-message count so
    /// coalesced/stacked steering does not over-increment.
    func protectCurrentClaudeTurnForAcceptedSteeringIfNeeded(
        session: AgentModeViewModel.TabSession,
        steeringID: UUID
    ) {
        guard session.selectedAgent.usesClaudeNativeRuntime,
              session.runState == .running,
              let runID = session.runID,
              let runAttemptID = session.activeRunAttemptID,
              let steeringIndex = session.pendingClaudeSteeringInstructions.firstIndex(where: { $0.id == steeringID })
        else {
            return
        }
        let steering = session.pendingClaudeSteeringInstructions[steeringIndex]
        guard steering.targetRunID == runID,
              steering.targetRunAttemptID == runAttemptID
        else {
            return
        }

        let claimableTurnIDs = session.claudeExpectedTurnIDs.subtracting(session.claudeSupersedingProtectedTurnIDs)
        guard !claimableTurnIDs.isEmpty else { return }

        session.claudeSupersedingProtectedTurnIDs.formUnion(claimableTurnIDs)
        session.pendingClaudeSteeringInstructions[steeringIndex].supersedingProtectedTurnIDs.formUnion(claimableTurnIDs)
        session.pendingSupersedingTurnCompletions += claimableTurnIDs.count
    }

    private func releaseUnconsumedClaudeSupersedingProtection(
        for instructions: [AgentModeViewModel.TabSession.ClaudeSteeringInstruction],
        session: AgentModeViewModel.TabSession
    ) {
        let protectedTurnIDs = Set(instructions.flatMap(\.supersedingProtectedTurnIDs))
        guard !protectedTurnIDs.isEmpty else { return }

        let unconsumedTurnIDs = protectedTurnIDs
            .intersection(session.claudeExpectedTurnIDs)
            .intersection(session.claudeSupersedingProtectedTurnIDs)
        guard !unconsumedTurnIDs.isEmpty else { return }

        session.claudeSupersedingProtectedTurnIDs.subtract(unconsumedTurnIDs)
        session.pendingSupersedingTurnCompletions = max(
            0,
            session.pendingSupersedingTurnCompletions - unconsumedTurnIDs.count
        )
    }

    private func awaitClaudeChildAgentRunWaitScopesDrained(
        session: AgentModeViewModel.TabSession,
        runID: UUID,
        runAttemptID: UUID,
        timeoutSeconds: TimeInterval? = nil
    ) async -> Bool {
        let timeoutSeconds = timeoutSeconds ?? dependencies.childAgentRunWaitDrainTimeoutSeconds
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(timeoutSeconds * 1000)))
        while dependencies.activeAgentRunWaitQuery(runID) {
            guard isCurrentClaudeSteeringAttempt(session: session, runID: runID, runAttemptID: runAttemptID) else {
                return false
            }
            guard ContinuousClock.now < deadline else {
                steeringDebugLog("[AgentRunSteeringWake] Claude flush child agent_run wait drain timed out tab=\(session.tabID) runID=\(runID) attempt=\(runAttemptID)")
                return false
            }
            do {
                try await Task.sleep(nanoseconds: 25_000_000)
            } catch {
                return false
            }
        }
        await Task.yield()
        return true
    }

    @discardableResult
    func submitQueuedClaudeSteeringIfSupported(session: AgentModeViewModel.TabSession) async -> Bool {
        guard session.selectedAgent.usesClaudeNativeRuntime,
              session.runState == .running
        else {
            return false
        }

        // If a flush task is already draining the queue, just return — it will
        // pick up the newly appended instruction on its next loop iteration.
        guard session.claudeSteeringFlushTask == nil else {
            steeringDebugLog("[AgentRunSteeringWake] Claude flush already active tab=\(session.tabID) queue=\(session.pendingClaudeSteeringInstructions.count)")
            return true
        }

        guard !session.pendingClaudeSteeringInstructions.isEmpty else { return false }

        guard let runID = session.runID,
              let runAttemptID = session.activeRunAttemptID else { return false }

        if let firstQueuedSteeringID = session.pendingClaudeSteeringInstructions.first?.id {
            protectCurrentClaudeTurnForAcceptedSteeringIfNeeded(
                session: session,
                steeringID: firstQueuedSteeringID
            )
        }

        let tabID = session.tabID
        steeringDebugLog("[AgentRunSteeringWake] Claude flush start tab=\(tabID) runID=\(runID) attempt=\(runAttemptID) queue=\(session.pendingClaudeSteeringInstructions.count)")
        session.claudeSteeringFlushTask = Task { [weak self, weak session] in
            guard let self, let session else { return }
            defer {
                session.claudeSteeringFlushTask = nil
                if session.runState == .running,
                   session.selectedAgent.usesClaudeNativeRuntime,
                   !session.pendingClaudeSteeringInstructions.isEmpty
                {
                    Task { @MainActor [weak self, weak session] in
                        guard let self, let session else { return }
                        _ = await self.submitQueuedClaudeSteeringIfSupported(session: session)
                    }
                }
            }

            while true {
                guard isCurrentClaudeSteeringAttempt(session: session, runID: runID, runAttemptID: runAttemptID) else {
                    restoreQueuedClaudeSteeringDrafts(
                        tabID: tabID,
                        session: session,
                        strategy: .prependAlways,
                        matching: { $0.targetRunID == runID && $0.targetRunAttemptID == runAttemptID }
                    )
                    return
                }
                guard !session.pendingClaudeSteeringInstructions.isEmpty else { return }

                if let first = session.pendingClaudeSteeringInstructions.first,
                   first.targetRunID != runID || first.targetRunAttemptID != runAttemptID
                {
                    restoreLeadingQueuedClaudeSteeringDrafts(
                        tabID: tabID,
                        session: session,
                        strategy: .prependAlways,
                        while: { $0.targetRunID != runID || $0.targetRunAttemptID != runAttemptID }
                    )
                    continue
                }

                if let firstQueuedSteeringID = session.pendingClaudeSteeringInstructions.first?.id {
                    protectCurrentClaudeTurnForAcceptedSteeringIfNeeded(
                        session: session,
                        steeringID: firstQueuedSteeringID
                    )
                }

                // Wait for all active MCP tool executions to finish before interrupting.
                steeringDebugLog("[AgentRunSteeringWake] Claude flush waiting MCP idle tab=\(tabID) runID=\(runID) attempt=\(runAttemptID) queue=\(session.pendingClaudeSteeringInstructions.count)")
                do {
                    try await dependencies.awaitNoActiveMCPTools(runID)
                    steeringDebugLog("[AgentRunSteeringWake] Claude flush MCP idle returned tab=\(tabID) runID=\(runID) attempt=\(runAttemptID) queue=\(session.pendingClaudeSteeringInstructions.count)")
                } catch {
                    steeringDebugLog("[AgentRunSteeringWake] Claude flush MCP idle cancelled tab=\(tabID) runID=\(runID) attempt=\(runAttemptID) error=\(error)")
                    // Task cancelled (user cancelled the run) — restore all remaining drafts.
                    restoreAllQueuedClaudeSteeringDrafts(tabID: tabID, session: session, strategy: .prependAlways)
                    return
                }

                // `agent_run` / `agent_explore` control tools are intentionally excluded from
                // ordinary active MCP tool tracking. Before a Claude native interrupt, also
                // wait briefly for parent-owned child-agent wait scopes to drain after the
                // upstream steering wake has had a chance to return `interrupted_by_steering`.
                guard await awaitClaudeChildAgentRunWaitScopesDrained(
                    session: session,
                    runID: runID,
                    runAttemptID: runAttemptID
                ) else {
                    restoreQueuedClaudeSteeringDrafts(
                        tabID: tabID,
                        session: session,
                        strategy: .prependAlways,
                        matching: { $0.targetRunID == runID && $0.targetRunAttemptID == runAttemptID }
                    )
                    return
                }

                // Claude Code handles steering as interrupt + queue/send follow-up prompt.
                // Keep the local MCP-idle and child-agent wait-scope gates above, but do not
                // block the queue on a stream-derived provider tool_result ack parity signal here.

                // Re-check state after waiting — run may have been cancelled during the wait
                guard isCurrentClaudeSteeringAttempt(session: session, runID: runID, runAttemptID: runAttemptID),
                      !session.pendingClaudeSteeringInstructions.isEmpty
                else {
                    restoreQueuedClaudeSteeringDrafts(
                        tabID: tabID,
                        session: session,
                        strategy: .prependAlways,
                        matching: { $0.targetRunID == runID && $0.targetRunAttemptID == runAttemptID }
                    )
                    return
                }

                let steering = session.pendingClaudeSteeringInstructions.removeFirst()
                steeringDebugLog("[AgentRunSteeringWake] Claude flush dequeued steering id=\(steering.id) tab=\(tabID) runID=\(runID) attempt=\(runAttemptID) remaining=\(session.pendingClaudeSteeringInstructions.count)")
                let dequeuedUserInputTokens: Int? = {
                    guard !session.pendingNonCodexUserInputTokenQueue.isEmpty else { return nil }
                    return session.pendingNonCodexUserInputTokenQueue.removeFirst()
                }()

                let augmentedSteeringText = await hooks.augmentUserMessageForProviderSend(
                    steering.providerText,
                    steering.attachments,
                    steering.taggedFileAttachments,
                    session
                )
                steeringDebugLog("[AgentRunSteeringWake] Claude flush sending native interrupt id=\(steering.id) tab=\(tabID) runID=\(runID) attempt=\(runAttemptID)")
                let sent = await dependencies.claudeCoordinator.sendClaudeNativeMessage(
                    session: session,
                    text: augmentedSteeringText,
                    attachments: []
                )
                steeringDebugLog("[AgentRunSteeringWake] Claude flush send completed id=\(steering.id) tab=\(tabID) runID=\(runID) attempt=\(runAttemptID) sent=\(sent)")
                hooks.recordPendingHandoffSendOutcome(session, sent)
                if sent {
                    await hooks.signalMCPInstructionDelivered(session)
                }
                if !sent {
                    // Re-insert the failed instruction so it's included in the restore
                    session.pendingClaudeSteeringInstructions.insert(steering, at: 0)
                    if let dequeuedUserInputTokens {
                        session.pendingNonCodexUserInputTokenQueue.insert(dequeuedUserInputTokens, at: 0)
                    }
                    // Restore ALL remaining queued drafts (including the one that failed)
                    restoreAllQueuedClaudeSteeringDrafts(tabID: tabID, session: session, strategy: .prependAlways)
                    return
                }
            }
        }

        return true
    }

    private func isCurrentClaudeSteeringAttempt(
        session: AgentModeViewModel.TabSession,
        runID: UUID,
        runAttemptID: UUID
    ) -> Bool {
        session.runState == .running
            && session.selectedAgent.usesClaudeNativeRuntime
            && session.runID == runID
            && session.activeRunAttemptID == runAttemptID
    }

    /// Concatenates queued Claude steering draft texts and restores them to the composer.
    private func restoreQueuedClaudeSteeringDrafts(
        tabID: UUID,
        session: AgentModeViewModel.TabSession,
        strategy: DraftRestorationStrategy,
        matching shouldRestore: (AgentModeViewModel.TabSession.ClaudeSteeringInstruction) -> Bool
    ) {
        let instructions = session.pendingClaudeSteeringInstructions.filter(shouldRestore)
        let drafts = instructions
            .map(\.draftText)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        releaseUnconsumedClaudeSupersedingProtection(for: instructions, session: session)
        session.pendingClaudeSteeringInstructions.removeAll(where: shouldRestore)
        restoreClaudeSteeringDrafts(drafts, tabID: tabID, strategy: strategy)
    }

    /// Restores only the leading stale instructions so newer queued work remains eligible for a new flush task.
    private func restoreLeadingQueuedClaudeSteeringDrafts(
        tabID: UUID,
        session: AgentModeViewModel.TabSession,
        strategy: DraftRestorationStrategy,
        while shouldRestore: (AgentModeViewModel.TabSession.ClaudeSteeringInstruction) -> Bool
    ) {
        let instructions = Array(session.pendingClaudeSteeringInstructions.prefix(while: shouldRestore))
        guard !instructions.isEmpty else { return }
        session.pendingClaudeSteeringInstructions.removeFirst(instructions.count)
        let drafts = instructions
            .map(\.draftText)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        releaseUnconsumedClaudeSupersedingProtection(for: instructions, session: session)
        restoreClaudeSteeringDrafts(drafts, tabID: tabID, strategy: strategy)
    }

    private func restoreClaudeSteeringDrafts(
        _ drafts: [String],
        tabID: UUID,
        strategy: DraftRestorationStrategy
    ) {
        guard !drafts.isEmpty else { return }
        let combined = drafts.joined(separator: "\n")
        hooks.restoreDraftText(tabID, combined, "Restored queued steering messages", strategy)
    }

    private func restoreAllQueuedDraftsForExecutionLocationChange(
        tabID: UUID,
        session: AgentModeViewModel.TabSession,
        strategy: DraftRestorationStrategy
    ) {
        let drafts = (
            session.pendingClaudeSteeringInstructions.map(\.draftText)
                + session.pendingACPSteeringInstructions.map(\.draftText)
                + session.pendingInstructions
        )
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        guard !drafts.isEmpty else { return }
        hooks.restoreDraftText(tabID, drafts.joined(separator: "\n"), "Restored queued messages after changing execution location", strategy)
    }

    /// Concatenates all queued Claude steering draft texts and restores them to the composer.
    private func restoreAllQueuedClaudeSteeringDrafts(
        tabID: UUID,
        session: AgentModeViewModel.TabSession,
        strategy: DraftRestorationStrategy
    ) {
        restoreQueuedClaudeSteeringDrafts(
            tabID: tabID,
            session: session,
            strategy: strategy,
            matching: { _ in true }
        )
    }

    func cancelRun(
        tabID: UUID,
        session: AgentModeViewModel.TabSession,
        intent: CancellationIntent = .userStop,
        completion: CancellationCompletion = .terminalPublished
    ) async {
        if session.runState.isTerminalForCommit,
           let revision = session.lastTerminalCommitRevision
        {
            await terminalCommitBarrier.awaitTerminalPublication(
                for: revision.ownership,
                session: session
            )
            if completion == .terminalTeardownCompleted {
                await terminalCommitBarrier.awaitTerminalTeardown(
                    for: revision.ownership,
                    session: session
                )
            }
            return
        }
        hooks.cancelPendingQuestion(session)
        hooks.cancelPendingApproval(session)
        hooks.cancelPendingApplyEditsReview(session, "Run cancelled")
        hooks.cancelPendingWorktreeMergeReview(session, "Run cancelled")

        // Cancel steering flush tasks first so they don't race with cleanup.
        session.claudeSteeringFlushTask?.cancel()
        session.claudeSteeringFlushTask = nil
        session.acpSteeringFlushTask?.cancel()
        session.acpSteeringFlushTask = nil

        // Ordinary stop keeps existing behavior. A cwd-changing cancellation
        // restores every queued, undelivered draft once without replaying the
        // already-delivered active prompt.
        switch intent {
        case .userStop:
            restoreAllQueuedClaudeSteeringDrafts(tabID: tabID, session: session, strategy: .prependAlways)
        case .executionLocationChange:
            restoreAllQueuedDraftsForExecutionLocationChange(tabID: tabID, session: session, strategy: .prependAlways)
        }

        let hadPendingTokenQueue = !session.pendingNonCodexUserInputTokenQueue.isEmpty
        let hadActiveTurnAccumulator = session.activeNonCodexTurnTokenAccumulator != nil
        let hadPendingInstructions = !session.pendingInstructions.isEmpty
            || !session.pendingClaudeSteeringInstructions.isEmpty
            || !session.pendingACPSteeringInstructions.isEmpty
        session.pendingNonCodexUserInputTokenQueue.removeAll()
        session.activeNonCodexTurnTokenAccumulator = nil
        session.pendingInstructions.removeAll()
        session.pendingClaudeSteeringInstructions.removeAll()
        session.pendingACPSteeringInstructions.removeAll()
        session.pendingSupersedingTurnCompletions = 0
        session.claudeSupersedingProtectedTurnIDs.removeAll()
        session.claudeExpectedTurnIDs.removeAll()
        if hadPendingTokenQueue || hadActiveTurnAccumulator || hadPendingInstructions {
            session.isDirty = true
        }

        // Cancel all active MCP tool executions for this run (all providers) before stopping providers.
        cancelToolsBeforeStoppingProvider(
            session: session,
            reason: intent == .executionLocationChange ? "execution_location_change" : "user_stop"
        )

        let ownership = session.activeRunOwnership ?? session.beginRunAttempt(source: "runService.cancel")
        let expectedRunID = session.runID
        let provider = session.provider
        let acpController = session.acpController
        let hasAttemptTerminalResources = session.runAttemptTerminalResources?.ownership == ownership
        let codexCancellationTarget = session.selectedAgent == .codexExec
            ? dependencies.codexCoordinator.captureCodexCancellationTarget(
                session,
                expectedRunID: expectedRunID
            )
            : nil
        session.agentTask?.cancel()

        if session.selectedAgent == .codexExec {
            dependencies.codexCoordinator.drainCodexTerminalBuffersForCancellation(session)
        }

        await terminalCommitBarrier.commit(.init(
            session: session,
            ownership: ownership,
            expectedRunID: expectedRunID,
            terminalState: .cancelled,
            source: "runService.cancel",
            completion: completion,
            attachmentDisposition: session.selectedAgent == .codexExec ? .restoreToPending : .deleteFiles,
            finalizeNonCodexUsage: session.selectedAgent != .codexExec,
            supportsFollowUp: false,
            notifyTurnComplete: false,
            providerDrainGeneration: session.providerTerminalDrainGeneration,
            providerBuffersAreDrained: { [dependencies] in
                session.selectedAgent != .codexExec
                    || dependencies.codexCoordinator.codexTerminalBuffersAreDrained(session)
            },
            prepareProviderState: { [dependencies] in
                if session.selectedAgent == .codexExec {
                    return dependencies.codexCoordinator.prepareCodexCancellationTeardown(
                        session,
                        expectedRunID: expectedRunID,
                        capturedTarget: codexCancellationTarget
                    )
                }
                if session.selectedAgent.usesClaudeNativeRuntime {
                    let oldController = dependencies.claudeCoordinator.prepareClaudeCancelSync(session)
                    session.provider = nil
                    return {
                        dependencies.claudeCoordinator.beginClaudeResumeTransferIfNeeded(
                            for: session,
                            oldController: oldController
                        )
                        await dependencies.claudeCoordinator.awaitPendingClaudeResumeTransferIfNeeded(for: session)
                    }
                }
                if let acpController {
                    if session.acpController === acpController {
                        session.acpController = nil
                    }
                    AgentModeProcessRunIdentity.clearProcessRunID(for: session)
                    session.provider = nil
                    return {
                        await acpController.cancelPrompt()
                        await acpController.shutdown()
                    }
                }
                session.provider = nil
                session.runID = nil
                guard let provider, !hasAttemptTerminalResources else { return nil }
                return { await provider.dispose() }
            }
        ))
        if completion == .terminalTeardownCompleted {
            await terminalCommitBarrier.awaitTerminalTeardown(
                for: ownership,
                session: session
            )
        }
    }

    private func cancelToolsBeforeStoppingProvider(
        session: AgentModeViewModel.TabSession,
        reason: String
    ) {
        guard let runID = session.runID else { return }
        dependencies.cancelMCPToolsForRun(runID, reason)
    }

    // MARK: - Provider Tool Stream Event Routing

    /// Routes a provider-stream tool event to the appropriate provider handler.
    /// Returns `true` when the event was consumed or suppressed, signaling
    /// `handleStreamResult` to skip its default tool processing.
    @discardableResult
    func handleProviderToolStreamEvent(
        _ result: AIStreamResult,
        session: AgentModeViewModel.TabSession
    ) -> Bool {
        guard let event = AgentToolStreamEvent.from(result) else { return false }
        let agent = session.selectedAgent
        if agent.acpProviderID != nil {
            return acpRunner.handleToolStreamEvent(event, session: session)
        }
        if agent.usesClaudeNativeRuntime {
            return dependencies.claudeCoordinator.handleToolStreamEvent(event, session: session)
        }
        return false
    }
}
