import Foundation
import MCP
import OSLog

@MainActor
final class ClaudeAgentModeCoordinator {
    typealias ClaudeControllerFactory = (
        _ runID: UUID,
        _ tabID: UUID,
        _ windowID: Int,
        _ workspacePath: String?,
        _ runtimeVariant: ClaudeCodeRuntimeVariant,
        _ allowNativeBashTool: Bool?,
        _ permissionMode: String?
    ) -> any NativeAgentRuntimeControlling

    /// Closure that waits until the given runID has zero active MCP tool executions.
    /// Throws `CancellationError` if the calling Task is cancelled.
    typealias MCPToolIdleWaiter = (_ runID: UUID) async throws -> Void
    typealias MCPToolEndedCountProvider = (_ runID: UUID) -> Int
    typealias MCPActiveToolQuery = (_ runID: UUID) -> Bool
    typealias ActiveAgentRunWaitQuery = (_ runID: UUID) -> Bool

    private enum SteeringInterruptSafePointResult {
        case ready
        case cancelled
        case timedOut(
            snapshot: ClaudeAgentToolTrackingHandler.ExplicitProviderToolResultAckSnapshot,
            localCount: Int,
            stillActive: Bool
        )
    }

    private static let logger = Logger(subsystem: "com.repoprompt.agents", category: "ClaudeSteering")
    private static let flagSettingsLogger = Logger(subsystem: "com.repoprompt.agents", category: "ClaudeFlagSettings")

    private weak var viewModel: AgentModeViewModel?
    private let windowID: Int
    private let workspacePathProvider: (AgentModeViewModel.TabSession) throws -> String?
    private let claudeControllerFactory: ClaudeControllerFactory
    private let awaitNoActiveMCPTools: MCPToolIdleWaiter?
    private let toolEndedCount: MCPToolEndedCountProvider
    private let hasActiveMCPTools: MCPActiveToolQuery
    private let hasActiveChildAgentRunWaits: ActiveAgentRunWaitQuery
    private let steeringInterruptSafePointTimeoutSeconds: TimeInterval

    /// Per-tab tool tracking handler for Claude sessions.
    /// Each tab gets its own handler instance to isolate correlation state across concurrent sessions.
    private var toolHandlerByTabID: [UUID: ClaudeAgentToolTrackingHandler] = [:]
    var toolTrackingHooks: AgentToolTrackingHooks = .noOp {
        didSet {
            for handler in toolHandlerByTabID.values {
                handler.hooks = toolTrackingHooks
            }
        }
    }

    init(
        windowID: Int,
        workspacePathProvider: @escaping (AgentModeViewModel.TabSession) throws -> String?,
        claudeControllerFactory: @escaping ClaudeControllerFactory,
        awaitNoActiveMCPTools: MCPToolIdleWaiter? = nil,
        toolEndedCount: @escaping MCPToolEndedCountProvider = { _ in 0 },
        hasActiveMCPTools: @escaping MCPActiveToolQuery = { _ in false },
        hasActiveChildAgentRunWaits: @escaping ActiveAgentRunWaitQuery = { _ in false },
        steeringInterruptSafePointTimeoutSeconds: TimeInterval = 2.0
    ) {
        self.windowID = windowID
        self.workspacePathProvider = workspacePathProvider
        self.claudeControllerFactory = claudeControllerFactory
        self.awaitNoActiveMCPTools = awaitNoActiveMCPTools
        self.toolEndedCount = toolEndedCount
        self.hasActiveMCPTools = hasActiveMCPTools
        self.hasActiveChildAgentRunWaits = hasActiveChildAgentRunWaits
        self.steeringInterruptSafePointTimeoutSeconds = steeringInterruptSafePointTimeoutSeconds
    }

    @discardableResult
    private func updateProviderSessionIDIfNeeded(
        _ candidate: String?,
        for session: AgentModeViewModel.TabSession,
        scheduleSave: Bool = true
    ) -> Bool {
        guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty,
              session.providerSessionID != candidate
        else {
            return false
        }
        session.providerSessionID = candidate
        guard scheduleSave else { return true }
        session.isDirty = true
        viewModel?.scheduleSave(for: session.tabID)
        return true
    }

    func attach(viewModel: AgentModeViewModel) {
        self.viewModel = viewModel
    }

    func stop() {
        // Stop all tracked sessions to prevent stale observer registrations.
        let handlers = toolHandlerByTabID
        toolHandlerByTabID.removeAll()
        for (tabID, handler) in handlers {
            let session = AgentModeViewModel.TabSession(tabID: tabID)
            Task { await handler.stopTracking(for: session) }
        }
    }

    private func finalizeSession(
        _ session: AgentModeViewModel.TabSession,
        state: AgentSessionRunState,
        save: Bool = false
    ) {
        session.runState = state
        session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
        session.setRunningStatus(nil, source: nil)
        viewModel?.setAgentRunActive(session.tabID, isActive: false)
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
        if save {
            viewModel?.scheduleSave(for: session.tabID)
        }
    }

    func events(for session: AgentModeViewModel.TabSession) async -> AsyncStream<NativeAgentRuntimeEvent>? {
        guard let controller = session.claudeController else { return nil }
        // Ensure the stream has a live continuation before returning. This
        // handles the case where the stream was finished by handleStdoutEOF
        // or another path that called finishEventsStreamIfNeeded. Without
        // this, the runner would immediately see "stream ended unexpectedly".
        await controller.ensureEventsStreamReady()
        return await controller.events
    }

    func hasTurnInFlight(for session: AgentModeViewModel.TabSession) async -> Bool {
        guard let controller = session.claudeController else { return false }
        return await controller.hasTurnInFlight
    }

    func scheduleApplyCurrentClaudeModelAndEffortIfPossible(
        for session: AgentModeViewModel.TabSession,
        reason: String
    ) {
        guard session.selectedAgent.usesClaudeNativeRuntime,
              session.claudeController != nil
        else {
            return
        }
        Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            await applyCurrentClaudeModelAndEffortIfPossible(for: session, reason: reason)
        }
    }

    func applyCurrentClaudeModelAndEffortIfPossible(
        for session: AgentModeViewModel.TabSession,
        reason: String
    ) async {
        guard session.selectedAgent.usesClaudeNativeRuntime,
              let controller = session.claudeController
        else {
            return
        }
        let model = effectiveClaudeModel(for: session)
        let effortLevel = currentClaudeEffortLevel(for: session)
        do {
            try await controller.applyModelAndEffort(model: model, effortLevel: effortLevel)
            Self.flagSettingsLogger.debug(
                "Applied Claude flag settings for tab=\(session.tabID.uuidString, privacy: .public) reason=\(reason, privacy: .public) model=\(model ?? "default", privacy: .public) effort=\(effortLevel.rawValue, privacy: .public)"
            )
        } catch {
            Self.flagSettingsLogger.error(
                "Failed applying Claude flag settings for tab=\(session.tabID.uuidString, privacy: .public) reason=\(reason, privacy: .public) model=\(model ?? "default", privacy: .public) effort=\(effortLevel.rawValue, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func ensureClaudeToolTrackingIfNeeded(for session: AgentModeViewModel.TabSession, runID: UUID) async {
        let handler = toolHandler(for: session)
        await handler.startTracking(runID: runID, session: session, clientNameHint: session.selectedAgent.mcpClientNameHint)
    }

    private func toolHandler(for session: AgentModeViewModel.TabSession) -> ClaudeAgentToolTrackingHandler {
        if let existing = toolHandlerByTabID[session.tabID] {
            existing.hooks = toolTrackingHooks
            return existing
        }
        let handler = ClaudeAgentToolTrackingHandler(hooks: toolTrackingHooks)
        toolHandlerByTabID[session.tabID] = handler
        return handler
    }

    func ensureClaudeNativeSession(
        session: AgentModeViewModel.TabSession
    ) async {
        guard session.selectedAgent.usesClaudeNativeRuntime else { return }
        await awaitPendingClaudeResumeTransferIfNeeded(for: session)

        let runID = session.runID ?? UUID()
        session.runID = runID
        let launchModelRaw = session.selectedModelRaw
        let runtimeVariant = session.selectedAgent.claudeRuntimeVariant ?? .standard
        let effectivePermissionMode = effectiveClaudePermissionResolution(
            for: session,
            selectedModelRaw: launchModelRaw
        ).effectiveMode

        // If the session's Claude runtime variant or effective permission mode no
        // longer matches the controller, recycle it so the next process launches
        // with the correct backend environment and permission behavior.
        // Skip if a turn is still in flight — the mismatch persists and we will
        // recycle on the next idle call.
        let runtimeVariantChanged = session.claudeControllerRuntimeVariant.map { $0 != runtimeVariant } ?? false
        let permissionModeChanged = session.claudeControllerPermissionMode != effectivePermissionMode
        if let existingController = session.claudeController,
           runtimeVariantChanged || permissionModeChanged
        {
            guard await !(existingController.hasTurnInFlight) else {
                return
            }
            if runtimeVariantChanged {
                // Provider session IDs are backend-specific. Reusing a standard Claude
                // session when switching to CC Moonshot/CC Zai/CC Custom can keep the
                // old process/session alive and bypass the compatible backend env.
                session.providerSessionID = nil
                session.isDirty = true
                viewModel?.scheduleSave(for: session.tabID)
            } else {
                let sessionRef = await existingController.currentSessionRef()
                if let sessionID = sessionRef.sessionID {
                    session.providerSessionID = sessionID
                    session.isDirty = true
                    viewModel?.scheduleSave(for: session.tabID)
                }
            }
            await existingController.shutdown()
            await clearClaudeToolTracking(for: session)
            session.claudeController = nil
            session.claudeControllerRuntimeVariant = nil
            session.claudeControllerWorkspacePath = nil
            session.claudeControllerPermissionMode = nil
        }

        let runtimeWorkspacePath: String?
        do {
            runtimeWorkspacePath = try workspacePathProvider(session)
        } catch {
            let message = Self.providerStartupFailureMessage(for: error)
            let errorItem = AgentChatItem.error(message, sequenceIndex: session.nextSequenceIndex)
            session.appendItem(errorItem)
            finalizeSession(session, state: .failed, save: true)
            return
        }

        if let existingController = session.claudeController,
           session.claudeControllerWorkspacePath != runtimeWorkspacePath
        {
            if let sessionID = await (existingController.currentSessionRef()).sessionID {
                session.providerSessionID = sessionID
                session.isDirty = true
                viewModel?.scheduleSave(for: session.tabID)
            }
            await existingController.shutdown()
            await clearClaudeToolTracking(for: session)
            session.claudeController = nil
            session.claudeControllerRuntimeVariant = nil
            session.claudeControllerWorkspacePath = nil
            session.claudeControllerPermissionMode = nil
        }

        if session.claudeController == nil {
            session.claudeController = claudeControllerFactory(
                runID,
                session.tabID,
                windowID,
                runtimeWorkspacePath,
                runtimeVariant,
                nil,
                effectivePermissionMode
            )
            session.claudeControllerRuntimeVariant = runtimeVariant
            session.claudeControllerWorkspacePath = runtimeWorkspacePath
            session.claudeControllerPermissionMode = effectivePermissionMode
            if let controller = session.claudeController {
                await controller.ensureEventsStreamReady()
            }
        }

        guard let controller = session.claudeController else { return }
        do {
            let model = effectiveClaudeModel(selectedModelRaw: launchModelRaw)
            let sessionRef = try await startOrResumeWithFallback(
                controller: controller,
                session: session,
                runID: runID,
                model: model,
                runtimeVariant: runtimeVariant,
                effectivePermissionMode: effectivePermissionMode
            )
            updateProviderSessionIDIfNeeded(sessionRef.sessionID, for: session)
        } catch {
            let errorItem = AgentChatItem.error(
                "Claude native start failed: \(error.localizedDescription)",
                sequenceIndex: session.nextSequenceIndex
            )
            session.appendItem(errorItem)
            finalizeSession(session, state: .failed, save: true)
        }
    }

    private func startOrResumeWithFallback(
        controller: any NativeAgentRuntimeControlling,
        session: AgentModeViewModel.TabSession,
        runID: UUID,
        model: String?,
        runtimeVariant: ClaudeCodeRuntimeVariant,
        effectivePermissionMode: String
    ) async throws -> NativeAgentRuntimeSessionRef {
        let existingSessionID = session.providerSessionID
        let systemPromptOverride = agentModeSystemPromptOverride(for: session)
        let effortLevel = currentClaudeEffortLevel(for: session)
        do {
            return try await controller.startOrResume(
                existingSessionID: existingSessionID,
                model: model,
                effortLevel: effortLevel,
                systemPromptOverride: systemPromptOverride
            )
        } catch {
            guard shouldRetryFreshStartWithoutResume(after: error, existingSessionID: existingSessionID) else {
                throw error
            }

            await viewModel?.stageClaudeResumeRecoveryHandoffIfNeeded(for: session)
            await controller.shutdown()
            session.claudeController = nil
            session.claudeControllerRuntimeVariant = nil
            session.claudeControllerWorkspacePath = nil
            session.claudeControllerPermissionMode = nil
            session.runID = nil
            session.providerSessionID = nil
            session.isDirty = true
            viewModel?.scheduleSave(for: session.tabID)

            let freshRunID = UUID()
            session.runID = freshRunID
            let retryWorkspacePath = try workspacePathProvider(session)
            let freshController = claudeControllerFactory(
                freshRunID,
                session.tabID,
                windowID,
                retryWorkspacePath,
                runtimeVariant,
                nil,
                effectivePermissionMode
            )
            session.claudeController = freshController
            session.claudeControllerRuntimeVariant = runtimeVariant
            session.claudeControllerWorkspacePath = retryWorkspacePath
            session.claudeControllerPermissionMode = effectivePermissionMode
            return try await freshController.startOrResume(
                existingSessionID: nil,
                model: model,
                effortLevel: effortLevel,
                systemPromptOverride: systemPromptOverride
            )
        }
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

    private func shouldRetryFreshStartWithoutResume(
        after error: Error,
        existingSessionID: String?
    ) -> Bool {
        guard
            let existingSessionID,
            !existingSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let controllerError = error as? NativeAgentRuntimeControllerError
        else {
            return false
        }
        switch controllerError {
        // Any controller startup/handshake failure while attempting to resume an
        // existing Claude session is safer to recover by starting fresh and
        // injecting a handoff than by hard-failing the run. Fresh starts do not
        // take this path because they have no existing session ID.
        case .processNotRunning,
             .inputWriteFailed,
             .initializationFailed,
             .invalidControlResponse,
             .controlRequestTimedOut:
            return true
        }
    }

    private func awaitSteeringInterruptSafePoint(
        session: AgentModeViewModel.TabSession,
        runID: UUID,
        handler: ClaudeAgentToolTrackingHandler,
        timeoutSeconds: TimeInterval? = nil
    ) async -> SteeringInterruptSafePointResult {
        let effectiveTimeoutSeconds = timeoutSeconds ?? steeringInterruptSafePointTimeoutSeconds
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(effectiveTimeoutSeconds * 1000)))
        while true {
            guard session.runID == runID, session.runState.isActive else {
                return .cancelled
            }

            do {
                if let awaitNoActiveMCPTools {
                    let reachedLocalIdle = try await awaitOperationUntilDeadline(deadline: deadline) {
                        try await awaitNoActiveMCPTools(runID)
                    }
                    guard reachedLocalIdle else {
                        let snapshot = handler.explicitProviderToolResultAckSnapshot(for: runID)
                        let localCount = toolEndedCount(runID)
                        let stillActive = hasActiveMCPTools(runID) || hasActiveChildAgentRunWaits(runID)
                        logSteeringInterruptSafePointTimeout(
                            runID: runID,
                            snapshot: snapshot,
                            localCount: localCount,
                            stillActive: stillActive
                        )
                        return .timedOut(snapshot: snapshot, localCount: localCount, stillActive: stillActive)
                    }
                }

                let requiredAckCount = toolEndedCount(runID)
                let reachedAckParity = try await awaitOperationUntilDeadline(deadline: deadline) {
                    try await handler.awaitExplicitProviderToolResultAcks(
                        for: runID,
                        atLeast: requiredAckCount
                    )
                }
                let snapshot = handler.explicitProviderToolResultAckSnapshot(for: runID)
                let currentLocalCount = toolEndedCount(runID)
                let ordinaryMCPActive = hasActiveMCPTools(runID)
                let childWaitActive = hasActiveChildAgentRunWaits(runID)
                let stillActive = ordinaryMCPActive || childWaitActive

                guard reachedAckParity else {
                    logSteeringInterruptSafePointTimeout(
                        runID: runID,
                        snapshot: snapshot,
                        localCount: currentLocalCount,
                        stillActive: stillActive
                    )
                    return .timedOut(snapshot: snapshot, localCount: currentLocalCount, stillActive: stillActive)
                }

                if !stillActive,
                   currentLocalCount == requiredAckCount,
                   snapshot.ackCount >= requiredAckCount
                {
                    await Task.yield()
                    return .ready
                }

                guard ContinuousClock.now < deadline else {
                    logSteeringInterruptSafePointTimeout(
                        runID: runID,
                        snapshot: snapshot,
                        localCount: currentLocalCount,
                        stillActive: stillActive
                    )
                    return .timedOut(snapshot: snapshot, localCount: currentLocalCount, stillActive: stillActive)
                }
                try await Task.sleep(nanoseconds: 25_000_000)
            } catch is CancellationError {
                return .cancelled
            } catch {
                let snapshot = handler.explicitProviderToolResultAckSnapshot(for: runID)
                let localCount = toolEndedCount(runID)
                let stillActive = hasActiveMCPTools(runID) || hasActiveChildAgentRunWaits(runID)
                logSteeringInterruptSafePointTimeout(
                    runID: runID,
                    snapshot: snapshot,
                    localCount: localCount,
                    stillActive: stillActive,
                    error: error
                )
                return .timedOut(snapshot: snapshot, localCount: localCount, stillActive: stillActive)
            }
        }
    }

    private func awaitOperationUntilDeadline(
        deadline: ContinuousClock.Instant,
        operation: @escaping @MainActor () async throws -> Void
    ) async throws -> Bool {
        guard ContinuousClock.now < deadline else { return false }
        return try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                try await operation()
                return true
            }
            group.addTask {
                try await Task.sleep(until: deadline, clock: .continuous)
                return false
            }
            let result = try await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func logSteeringInterruptSafePointTimeout(
        runID: UUID,
        snapshot: ClaudeAgentToolTrackingHandler.ExplicitProviderToolResultAckSnapshot,
        localCount: Int,
        stillActive: Bool,
        error: Error? = nil
    ) {
        let recent = snapshot.recentObservations.map { observation in
            "\(observation.toolName)#\(observation.invocationID?.uuidString ?? "nil"):\(observation.reason):\(observation.ackCountAfterEvent)"
        }.joined(separator: ", ")
        let errorDescription = error.map { String(describing: $0) } ?? "none"
        Self.logger.error(
            "Claude steering safe-point timed out runID=\(runID.uuidString, privacy: .public) localCount=\(localCount) ackCount=\(snapshot.ackCount) stillActive=\(stillActive) trackedRunID=\(snapshot.trackedRunID?.uuidString ?? "nil", privacy: .public) recent=\(recent, privacy: .public) error=\(errorDescription, privacy: .public)"
        )
    }

    @discardableResult
    func sendClaudeNativeMessage(
        session: AgentModeViewModel.TabSession,
        text: String,
        attachments _: [AgentImageAttachment]
    ) async -> Bool {
        session.waitingPrompt = nil
        session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
        session.setRunningStatus("Thinking…", source: .transport)
        session.runState = .running
        let handler = toolHandler(for: session)
        handler.resetTurnState(for: session)
        viewModel?.setAgentRunActive(session.tabID, isActive: true)
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)

        await ensureClaudeNativeSession(
            session: session
        )
        guard let controller = session.claudeController else {
            finalizeSession(session, state: .failed)
            return false
        }
        guard await controller.hasActiveSession else {
            finalizeSession(session, state: .failed)
            return false
        }

        let hadTurnInFlight = await controller.hasTurnInFlight
        if hadTurnInFlight {
            if let runID = session.runID {
                switch await awaitSteeringInterruptSafePoint(
                    session: session,
                    runID: runID,
                    handler: handler
                ) {
                case .ready:
                    break
                case let .timedOut(_, _, stillActive) where !stillActive:
                    // Local MCP execution is already idle; a lagging provider ACK should not
                    // bounce the queued steer if Claude accepts the native interrupt/resend.
                    break
                case .cancelled, .timedOut:
                    return false
                }
            }

            let interruptOutcome = await controller.interruptTurn(reason: "interrupt")
            switch interruptOutcome {
            case .acknowledged, .noTurnInFlight:
                break // Safe to proceed with the superseding send
            case .timedOut, .failed:
                // Race tolerance: the active turn may have naturally completed after our
                // initial hasTurnInFlight check but before the interrupt was acknowledged.
                // Re-check and only proceed if the turn has already ended.
                let stillInFlight = await controller.hasTurnInFlight
                if stillInFlight {
                    return false
                }
            }
        }
        // Ensure the events stream has a live continuation before sending. If a
        // previous cancel/EOF/reset cycle left eventsContinuation == nil, emit()
        // would silently drop every inbound event. The runner subscribes to the
        // stream *after* this method returns (send → release lease → events(for:)),
        // so events that arrive in between must be buffered in a live stream.
        // ensureEventsStreamReady is idempotent — it only recreates if nil.
        await controller.ensureEventsStreamReady()
        do {
            let outboundText: String = if let viewModel {
                viewModel.prependPendingHandoffIfNeeded(text, session: session)
            } else {
                text
            }
            let instructions = agentModeInstructionInjection(for: session)
            let providerBoundText = providerBoundUserMessage(outboundText, instructions: instructions)
            let turnID = try await controller.sendUserMessage(providerBoundText)
            session.claudeExpectedTurnIDs.insert(turnID)
            return true
        } catch {
            let errorItem = AgentChatItem.error(
                "Claude native send failed: \(error.localizedDescription)",
                sequenceIndex: session.nextSequenceIndex
            )
            session.appendItem(errorItem)
            finalizeSession(session, state: .failed, save: true)
            return false
        }
    }

    func submitApprovalDecision(
        session: AgentModeViewModel.TabSession,
        decision: AgentApprovalDecision
    ) {
        guard let request = session.pendingApproval,
              let controller = session.claudeController,
              case let .claudeControl(requestID) = request.requestID
        else {
            return
        }
        session.pendingApproval = nil
        session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
        session.setRunningStatus("Thinking…", source: .transport)
        session.runState = .running
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)
        Task { [controller] in
            await controller.respondToPermissionRequest(id: requestID, decision: decision)
        }
    }

    /// Prepare a Claude cancel by immediately nil-ing the controller reference
    /// so the next startRun creates a fresh process. Returns the old controller
    /// for async cleanup. Must be called before dispatching cancelClaudeRun.
    func prepareClaudeCancelSync(_ session: AgentModeViewModel.TabSession) -> (any NativeAgentRuntimeControlling)? {
        guard session.selectedAgent.usesClaudeNativeRuntime else { return nil }
        let controller = session.claudeController
        // Nil the controller immediately — before any awaits — so the next
        // startRun always creates a fresh process. providerSessionID is
        // preserved so the new process resumes the conversation via --resume.
        session.claudeController = nil
        session.claudeControllerRuntimeVariant = nil
        session.claudeControllerWorkspacePath = nil
        session.claudeControllerPermissionMode = nil
        session.runID = nil
        session.pendingSupersedingTurnCompletions = 0
        session.claudeSupersedingProtectedTurnIDs.removeAll()
        return controller
    }

    func beginClaudeResumeTransferIfNeeded(
        for session: AgentModeViewModel.TabSession,
        oldController: (any NativeAgentRuntimeControlling)?
    ) {
        guard let oldController else { return }
        guard session.pendingClaudeResumeTransferTask == nil else { return }
        session.pendingClaudeResumeTransferTask = Task { @MainActor [self, session] in
            return await cancelClaudeRunAndCaptureSessionRef(session, oldController: oldController)
        }
    }

    func awaitPendingClaudeResumeTransferIfNeeded(
        for session: AgentModeViewModel.TabSession,
        scheduleProviderSessionSave: Bool = true
    ) async {
        guard let task = session.pendingClaudeResumeTransferTask else { return }
        let sessionRef = await task.value
        updateProviderSessionIDIfNeeded(
            sessionRef.sessionID,
            for: session,
            scheduleSave: scheduleProviderSessionSave
        )
        if session.pendingClaudeResumeTransferTask != nil {
            session.pendingClaudeResumeTransferTask = nil
        }
    }

    /// Async cleanup for the old controller after cancel. Interrupts the current
    /// turn, gives Claude a brief window to persist state, then shuts down the
    /// CLI process and cleans up tool tracking.
    func cancelClaudeRun(_ session: AgentModeViewModel.TabSession, oldController: (any NativeAgentRuntimeControlling)?) async {
        guard let controller = oldController else { return }
        _ = await cancelClaudeRunAndCaptureSessionRef(session, oldController: controller)
    }

    private func cancelClaudeRunAndCaptureSessionRef(
        _ session: AgentModeViewModel.TabSession,
        oldController: any NativeAgentRuntimeControlling
    ) async -> NativeAgentRuntimeSessionRef {
        let controller = oldController
        let capturedToolHandler = toolHandlerByTabID[session.tabID]
        let interruptOutcome = await controller.interruptTurn(reason: "interrupt")
        // Clean up the handler this cancel path owned immediately — no need to
        // wait for the grace period. If a new same-tab session installed a
        // replacement handler while the old interrupt was in flight, leave it alone.
        await clearClaudeToolTracking(for: session, matching: capturedToolHandler)
        if interruptOutcome == .acknowledged {
            // Give Claude ~200 ms to persist any in-flight state before we
            // tear down the process. The UI doesn't block on this — the
            // controller reference was already nil'd by prepareClaudeCancelSync.
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let sessionRef = await controller.currentSessionRef()
        await controller.shutdown()
        return sessionRef
    }

    func shutdownClaudeSession(
        _ session: AgentModeViewModel.TabSession,
        clearTabScopedCoordinatorState: Bool = true
    ) async {
        await awaitPendingClaudeResumeTransferIfNeeded(
            for: session,
            scheduleProviderSessionSave: clearTabScopedCoordinatorState
        )
        if let controller = session.claudeController {
            let sessionRef = await controller.currentSessionRef()
            updateProviderSessionIDIfNeeded(
                sessionRef.sessionID,
                for: session,
                scheduleSave: clearTabScopedCoordinatorState
            )
            await controller.shutdown()
        }
        session.claudeController = nil
        session.claudeControllerRuntimeVariant = nil
        session.claudeControllerWorkspacePath = nil
        session.claudeControllerPermissionMode = nil
        session.runID = nil
        session.pendingSupersedingTurnCompletions = 0
        session.claudeSupersedingProtectedTurnIDs.removeAll()
        session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
        session.setRunningStatus(nil, source: nil)
        if clearTabScopedCoordinatorState {
            await clearClaudeToolTracking(for: session)
        }
    }

    private func clearClaudeToolTracking(
        for session: AgentModeViewModel.TabSession,
        matching expectedHandler: ClaudeAgentToolTrackingHandler? = nil
    ) async {
        guard let handler = toolHandlerByTabID[session.tabID] else { return }
        if let expectedHandler {
            guard handler === expectedHandler else { return }
        }
        toolHandlerByTabID.removeValue(forKey: session.tabID)
        await handler.stopTracking(for: session)
    }

    // MARK: - Tool Tracking Delegation

    /// Forwarding wrapper for callers that still reference the coordinator for provider tool calls.
    func handleClaudeProviderRepoPromptToolCall(
        invocationID: UUID?,
        toolName: String,
        argsJSON: String?,
        session: AgentModeViewModel.TabSession
    ) {
        toolHandler(for: session).handleClaudeProviderRepoPromptToolCall(
            invocationID: invocationID,
            toolName: toolName,
            argsJSON: argsJSON,
            session: session
        )
    }

    /// Forwarding wrapper for callers that still reference the coordinator for suppression checks.
    func shouldSuppressClaudeProviderToolResult(
        toolName: String,
        argsJSON: String?,
        outputJSON: String,
        invocationID: UUID?,
        session: AgentModeViewModel.TabSession
    ) -> Bool {
        toolHandler(for: session).shouldSuppressClaudeProviderToolResult(
            toolName: toolName,
            argsJSON: argsJSON,
            outputJSON: outputJSON,
            invocationID: invocationID,
            session: session
        )
    }

    // MARK: - Tool Tracking Public API

    /// Reset turn-scoped correlation state for the given session.
    func resetToolCorrelation(for session: AgentModeViewModel.TabSession) {
        toolHandler(for: session).resetTurnState(for: session)
    }

    /// Forward a tracker tool call to the per-tab handler (used by tests and internal paths).
    func handleClaudeTrackerToolCall(
        invocationID: UUID,
        toolName: String,
        args: [String: Value]?,
        session: AgentModeViewModel.TabSession
    ) {
        toolHandler(for: session).handleTrackerToolCall(
            invocationID: invocationID,
            toolName: toolName,
            args: args,
            session: session
        )
    }

    /// Forward a tracker tool result to the per-tab handler (used by tests and internal paths).
    func handleClaudeTrackerToolResult(
        invocationID: UUID,
        toolName: String,
        args: [String: Value]?,
        resultJSON: String,
        isError: Bool,
        session: AgentModeViewModel.TabSession
    ) {
        toolHandler(for: session).handleTrackerToolResult(
            invocationID: invocationID,
            toolName: toolName,
            args: args,
            resultJSON: resultJSON,
            isError: isError,
            session: session
        )
    }

    // MARK: - Provider Stream Tool Event Handling

    /// Handle tool events from the Claude provider stream.
    /// Returns `true` when the event was consumed or suppressed.
    @discardableResult
    func handleToolStreamEvent(
        _ event: AgentToolStreamEvent,
        session: AgentModeViewModel.TabSession
    ) -> Bool {
        toolHandler(for: session).handleProviderToolEvent(event, session: session)
    }

    private func requestedClaudePermissionMode(for session: AgentModeViewModel.TabSession) -> String {
        viewModel?.providerBindingService.runtimePermission(
            for: session.selectedAgent,
            profile: session.permissionProfile
        ).claudePermissionMode
            ?? session.permissionProfile.claudePermissionMode
    }

    private func unsupportedAutoFallback(
        for session: AgentModeViewModel.TabSession
    ) -> ClaudeAgentToolPreferences.UnsupportedAutoPermissionFallback {
        session.parentSessionID == nil ? .autoApproveEdits : .fullAccess
    }

    private func effectiveClaudePermissionResolution(
        for session: AgentModeViewModel.TabSession,
        selectedModelRaw: String
    ) -> ClaudeAgentToolPreferences.PermissionModeResolution {
        ClaudeAgentToolPreferences.resolvePermissionMode(
            requestedMode: requestedClaudePermissionMode(for: session),
            agentKind: session.selectedAgent,
            selectedModelRaw: selectedModelRaw,
            unsupportedAutoFallback: unsupportedAutoFallback(for: session)
        )
    }

    private func effectiveClaudeModel(for session: AgentModeViewModel.TabSession) -> String? {
        effectiveClaudeModel(selectedModelRaw: session.selectedModelRaw)
    }

    private func effectiveClaudeModel(selectedModelRaw: String) -> String? {
        let selectedRaw = selectedModelRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedRaw.isEmpty, selectedRaw != AgentModel.defaultModel.rawValue else {
            return nil
        }
        return selectedRaw
    }

    private func currentClaudeEffortLevel(for session: AgentModeViewModel.TabSession) -> ClaudeCodeEffortLevel {
        viewModel?.providerBindingService.claudeEffortLevel(
            forModelRaw: session.selectedModelRaw,
            agentKind: session.selectedAgent
        ) ?? ClaudeAgentToolPreferences.effortLevel(
            forModelRaw: session.selectedModelRaw,
            agentKind: session.selectedAgent
        )
    }

    private func agentModeInstructionInjection(for session: AgentModeViewModel.TabSession) -> String {
        SystemPromptService.agentModePrompt(
            agentKind: session.selectedAgent,
            taskLabelKind: session.mcpControlContext?.taskLabelKind,
            codeMapsDisabled: GlobalSettingsStore.shared.globalCodeMapsDisabled()
        )
    }

    private func agentModeSystemPromptOverride(for session: AgentModeViewModel.TabSession) -> String? {
        ClaudeAgentToolPreferences.agentModePromptDelivery().nativeSystemPromptOverride(
            instructions: agentModeInstructionInjection(for: session)
        )
    }

    private func providerBoundUserMessage(_ outboundText: String, instructions: String) -> String {
        ClaudeCompatiblePluginBridge.providerBoundUserMessage(
            outboundText,
            instructions: instructions,
            delivery: ClaudeAgentToolPreferences.agentModePromptDelivery()
        )
    }
}
