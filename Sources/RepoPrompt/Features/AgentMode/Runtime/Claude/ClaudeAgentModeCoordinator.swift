import Foundation
import MCP
import OSLog

@MainActor
final class ClaudeAgentModeCoordinator {
    typealias ClaudeControllerFactory = (
        _ runID: UUID,
        _ tabID: UUID,
        _ windowID: Int,
        _ launchSettings: ControllerLaunchSettings
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

    private enum ControllerLifecycleError: Error {
        case superseded
    }

    struct DetachedClaudeController {
        fileprivate let controller: any NativeAgentRuntimeControlling
        fileprivate let toolHandler: ClaudeAgentToolTrackingHandler?
    }

    struct ControllerLaunchSettings: Equatable {
        let runtimeVariant: ClaudeCodeRuntimeVariant
        let workspacePath: String?
        let permissionMode: String?
        let allowNativeBashTool: Bool?
        let mcpStrictMode: Bool?
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
    private var controllerLaunchSettingsByTabID: [UUID: ControllerLaunchSettings] = [:]
    private var controllerRetirementGenerationByTabID: [UUID: UUID] = [:]
    private var pendingResumeTransferTasksByTabID: [UUID: Task<NativeAgentRuntimeSessionRef, Never>] = [:]
    private var pendingResumeTransferGenerationByTabID: [UUID: UUID] = [:]
    private var retiredResumeTransferTasksByTabID: [UUID: [Task<NativeAgentRuntimeSessionRef, Never>]] = [:]
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
        claudeControllerFactory: ClaudeControllerFactory? = nil,
        awaitNoActiveMCPTools: MCPToolIdleWaiter? = nil,
        toolEndedCount: @escaping MCPToolEndedCountProvider = { _ in 0 },
        hasActiveMCPTools: @escaping MCPActiveToolQuery = { _ in false },
        hasActiveChildAgentRunWaits: @escaping ActiveAgentRunWaitQuery = { _ in false },
        steeringInterruptSafePointTimeoutSeconds: TimeInterval = 2.0
    ) {
        self.windowID = windowID
        self.workspacePathProvider = workspacePathProvider
        self.claudeControllerFactory = claudeControllerFactory ?? Self.makeDefaultController
        self.awaitNoActiveMCPTools = awaitNoActiveMCPTools
        self.toolEndedCount = toolEndedCount
        self.hasActiveMCPTools = hasActiveMCPTools
        self.hasActiveChildAgentRunWaits = hasActiveChildAgentRunWaits
        self.steeringInterruptSafePointTimeoutSeconds = steeringInterruptSafePointTimeoutSeconds
    }

    private static func makeDefaultController(
        runID: UUID,
        tabID: UUID,
        windowID: Int,
        launchSettings: ControllerLaunchSettings
    ) -> any NativeAgentRuntimeControlling {
        let coreConfig = ClaudeCodeAgentConfig.agentMode(
            runtimeVariant: launchSettings.runtimeVariant,
            permissionMode: launchSettings.permissionMode,
            allowNativeBashTool: launchSettings.allowNativeBashTool,
            mcpStrictMode: launchSettings.mcpStrictMode
        )
        let runtimeConfig = ClaudeCompatiblePluginBridge.runtimeConfig(from: coreConfig, mode: .agentMode)
        return ClaudeCompatibleNativeSessionAdapter(runtimeConfig: runtimeConfig) {
            ClaudeNativeProcessSessionController(
                runID: runID,
                tabID: tabID,
                windowID: windowID,
                workspacePath: launchSettings.workspacePath,
                config: coreConfig
            )
        }
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
        controllerLaunchSettingsByTabID.removeAll()
        controllerRetirementGenerationByTabID.removeAll()
        let resumeTransferTasks = Array(pendingResumeTransferTasksByTabID.values)
            + retiredResumeTransferTasksByTabID.values.flatMap(\.self)
        resumeTransferTasks.forEach { $0.cancel() }
        pendingResumeTransferTasksByTabID.removeAll()
        pendingResumeTransferGenerationByTabID.removeAll()
        retiredResumeTransferTasksByTabID.removeAll()
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
        let runtimePermission = effectiveClaudeRuntimePermission(for: session)
        let effectivePermissionMode = effectiveClaudePermissionResolution(
            for: session,
            selectedModelRaw: launchModelRaw,
            runtimePermission: runtimePermission
        ).effectiveMode
        let effectiveAllowNativeBashTool = runtimePermission.allowNativeBashTool
        let effectiveMCPStrictMode = runtimePermission.mcpStrictMode

        // If the session's Claude runtime variant or effective permission mode no
        // longer matches the controller, recycle it so the next process launches
        // with the correct backend environment and permission behavior.
        // Skip if a turn is still in flight — the mismatch persists and we will
        // recycle on the next idle call.
        let currentLaunchSettings = controllerLaunchSettingsByTabID[session.tabID]
        let runtimeVariantChanged = currentLaunchSettings.map { $0.runtimeVariant != runtimeVariant } ?? false
        let permissionModeChanged = currentLaunchSettings?.permissionMode != effectivePermissionMode
        let bashToolChanged = currentLaunchSettings?.allowNativeBashTool != effectiveAllowNativeBashTool
        let mcpStrictModeChanged = currentLaunchSettings?.mcpStrictMode != effectiveMCPStrictMode
        if let existingController = session.claudeController,
           runtimeVariantChanged || permissionModeChanged || bashToolChanged || mcpStrictModeChanged
        {
            guard await !(existingController.hasTurnInFlight) else {
                return
            }
            await recycleClaudeControllerForLaunchSettingsChange(
                session: session,
                existingController: existingController,
                runtimeVariantChanged: runtimeVariantChanged
            )
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
           controllerLaunchSettingsByTabID[session.tabID]?.workspacePath != runtimeWorkspacePath
        {
            guard let detached = detachClaudeController(
                existingController,
                from: session,
                removeToolTracking: true
            ) else {
                return
            }
            _ = await retireClaudeController(
                detached,
                for: session,
                captureProviderSessionID: true
            )
        }

        if session.claudeController == nil {
            let launchSettings = ControllerLaunchSettings(
                runtimeVariant: runtimeVariant,
                workspacePath: runtimeWorkspacePath,
                permissionMode: effectivePermissionMode,
                allowNativeBashTool: effectiveAllowNativeBashTool,
                mcpStrictMode: effectiveMCPStrictMode
            )
            let createdController = claudeControllerFactory(
                runID,
                session.tabID,
                windowID,
                launchSettings
            )
            invalidateControllerRetirement(for: session)
            session.claudeController = createdController
            controllerLaunchSettingsByTabID[session.tabID] = launchSettings
            await createdController.ensureEventsStreamReady()
            guard sessionOwnsClaudeController(createdController, for: session) else {
                await createdController.shutdown()
                return
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
                effectivePermissionMode: effectivePermissionMode,
                effectiveAllowNativeBashTool: effectiveAllowNativeBashTool,
                effectiveMCPStrictMode: effectiveMCPStrictMode
            )
            updateProviderSessionIDIfNeeded(sessionRef.sessionID, for: session)
        } catch ControllerLifecycleError.superseded {
            return
        } catch {
            let errorItem = AgentChatItem.error(
                "Claude native start failed: \(error.localizedDescription)",
                sequenceIndex: session.nextSequenceIndex
            )
            session.appendItem(errorItem)
            finalizeSession(session, state: .failed, save: true)
        }
    }

    private func hasEffectiveClaudeControllerLaunchSettingsMismatch(
        for session: AgentModeViewModel.TabSession
    ) -> Bool {
        guard session.claudeController != nil else { return false }
        let runtimeVariant = session.selectedAgent.claudeRuntimeVariant ?? .standard
        let runtimeWorkspacePath: String?
        do {
            runtimeWorkspacePath = try workspacePathProvider(session)
        } catch {
            return true
        }
        let runtimePermission = effectiveClaudeRuntimePermission(for: session)
        let effectivePermissionMode = effectiveClaudePermissionResolution(
            for: session,
            selectedModelRaw: session.selectedModelRaw,
            runtimePermission: runtimePermission
        ).effectiveMode
        let expected = ControllerLaunchSettings(
            runtimeVariant: runtimeVariant,
            workspacePath: runtimeWorkspacePath,
            permissionMode: effectivePermissionMode,
            allowNativeBashTool: runtimePermission.allowNativeBashTool,
            mcpStrictMode: runtimePermission.mcpStrictMode
        )
        return controllerLaunchSettingsByTabID[session.tabID] != expected
    }

    private func effectiveClaudeRuntimeVariantChanged(
        for session: AgentModeViewModel.TabSession
    ) -> Bool {
        let runtimeVariant = session.selectedAgent.claudeRuntimeVariant ?? .standard
        return controllerLaunchSettingsByTabID[session.tabID].map { $0.runtimeVariant != runtimeVariant } ?? false
    }

    private func recycleClaudeControllerForLaunchSettingsChange(
        session: AgentModeViewModel.TabSession,
        existingController: any NativeAgentRuntimeControlling,
        runtimeVariantChanged: Bool
    ) async {
        guard let detached = detachClaudeController(
            existingController,
            from: session,
            removeToolTracking: true
        ) else {
            return
        }
        if runtimeVariantChanged {
            // Provider session IDs are backend-specific. Reusing a standard Claude
            // session when switching to CC Moonshot/CC Zai/CC Custom can keep the
            // old process/session alive and bypass the compatible backend env.
            session.providerSessionID = nil
            session.isDirty = true
            viewModel?.scheduleSave(for: session.tabID)
        }
        _ = await retireClaudeController(
            detached,
            for: session,
            captureProviderSessionID: !runtimeVariantChanged
        )
    }

    private func detachClaudeController(
        _ controller: any NativeAgentRuntimeControlling,
        from session: AgentModeViewModel.TabSession,
        removeToolTracking: Bool
    ) -> DetachedClaudeController? {
        guard sessionOwnsClaudeController(controller, for: session) else { return nil }
        let toolHandler = removeToolTracking ? toolHandlerByTabID.removeValue(forKey: session.tabID) : nil
        clearClaudeControllerLaunchMetadata(for: session)
        return DetachedClaudeController(controller: controller, toolHandler: toolHandler)
    }

    private func clearClaudeControllerLaunchMetadata(
        for session: AgentModeViewModel.TabSession
    ) {
        session.claudeController = nil
        controllerLaunchSettingsByTabID.removeValue(forKey: session.tabID)
    }

    private func stopToolTracking(
        _ detached: DetachedClaudeController,
        for session: AgentModeViewModel.TabSession
    ) async {
        await detached.toolHandler?.stopTracking(for: session)
    }

    @discardableResult
    private func retireClaudeController(
        _ detached: DetachedClaudeController,
        for session: AgentModeViewModel.TabSession,
        captureProviderSessionID: Bool,
        scheduleProviderSessionSave: Bool = true
    ) async -> Bool {
        let generation = UUID()
        controllerRetirementGenerationByTabID[session.tabID] = generation
        if captureProviderSessionID {
            let sessionRef = await detached.controller.currentSessionRef()
            if controllerRetirementGenerationByTabID[session.tabID] == generation,
               session.claudeController == nil
            {
                updateProviderSessionIDIfNeeded(
                    sessionRef.sessionID,
                    for: session,
                    scheduleSave: scheduleProviderSessionSave
                )
            }
        }
        await detached.controller.shutdown()
        await stopToolTracking(detached, for: session)
        guard controllerRetirementGenerationByTabID[session.tabID] == generation else {
            return false
        }
        controllerRetirementGenerationByTabID.removeValue(forKey: session.tabID)
        return true
    }

    private func invalidateControllerRetirement(for session: AgentModeViewModel.TabSession) {
        controllerRetirementGenerationByTabID.removeValue(forKey: session.tabID)
    }

    #if DEBUG
        func test_discardRuntimeState(for session: AgentModeViewModel.TabSession) {
            session.claudeController = nil
            controllerLaunchSettingsByTabID.removeValue(forKey: session.tabID)
            controllerRetirementGenerationByTabID.removeValue(forKey: session.tabID)
            pendingResumeTransferTasksByTabID.removeValue(forKey: session.tabID)?.cancel()
            pendingResumeTransferGenerationByTabID.removeValue(forKey: session.tabID)
            let retiredTasks = retiredResumeTransferTasksByTabID.removeValue(forKey: session.tabID) ?? []
            retiredTasks.forEach { $0.cancel() }
            if let toolHandler = toolHandlerByTabID.removeValue(forKey: session.tabID) {
                Task { await toolHandler.stopTracking(for: session) }
            }
        }

        func test_setControllerLaunchSettings(
            _ settings: ControllerLaunchSettings,
            for session: AgentModeViewModel.TabSession
        ) {
            if session.claudeController != nil {
                invalidateControllerRetirement(for: session)
            }
            controllerLaunchSettingsByTabID[session.tabID] = settings
        }

        func test_controllerLaunchSettings(
            for session: AgentModeViewModel.TabSession
        ) -> ControllerLaunchSettings? {
            controllerLaunchSettingsByTabID[session.tabID]
        }

        func test_hasPendingOrRetiredResumeTransfers(
            for session: AgentModeViewModel.TabSession
        ) -> Bool {
            hasPendingResumeTransfer(for: session)
                || pendingResumeTransferGenerationByTabID[session.tabID] != nil
        }
    #endif

    private func sessionOwnsClaudeController(
        _ controller: any NativeAgentRuntimeControlling,
        for session: AgentModeViewModel.TabSession
    ) -> Bool {
        guard let currentController = session.claudeController else { return false }
        return ObjectIdentifier(currentController as AnyObject) == ObjectIdentifier(controller as AnyObject)
    }

    private func startOrResumeWithFallback(
        controller: any NativeAgentRuntimeControlling,
        session: AgentModeViewModel.TabSession,
        runID: UUID,
        model: String?,
        runtimeVariant: ClaudeCodeRuntimeVariant,
        effectivePermissionMode: String,
        effectiveAllowNativeBashTool: Bool?,
        effectiveMCPStrictMode: Bool?
    ) async throws -> NativeAgentRuntimeSessionRef {
        let existingSessionID = session.providerSessionID
        let systemPromptOverride = agentModeSystemPromptOverride(for: session)
        let effortLevel = currentClaudeEffortLevel(for: session)
        do {
            let sessionRef = try await controller.startOrResume(
                existingSessionID: existingSessionID,
                model: model,
                effortLevel: effortLevel,
                systemPromptOverride: systemPromptOverride
            )
            guard sessionOwnsClaudeController(controller, for: session) else {
                await controller.shutdown()
                throw ControllerLifecycleError.superseded
            }
            return sessionRef
        } catch ControllerLifecycleError.superseded {
            throw ControllerLifecycleError.superseded
        } catch {
            guard sessionOwnsClaudeController(controller, for: session) else {
                await controller.shutdown()
                throw ControllerLifecycleError.superseded
            }
            guard shouldRetryFreshStartWithoutResume(after: error, existingSessionID: existingSessionID) else {
                throw error
            }

            await viewModel?.stageClaudeResumeRecoveryHandoffIfNeeded(for: session)
            guard sessionOwnsClaudeController(controller, for: session) else {
                await controller.shutdown()
                throw ControllerLifecycleError.superseded
            }
            await controller.shutdown()
            guard let detached = detachClaudeController(
                controller,
                from: session,
                removeToolTracking: true
            ) else {
                throw ControllerLifecycleError.superseded
            }
            await stopToolTracking(detached, for: session)
            session.runID = nil
            session.providerSessionID = nil
            session.isDirty = true
            viewModel?.scheduleSave(for: session.tabID)

            let freshRunID = UUID()
            session.runID = freshRunID
            let retryWorkspacePath = try workspacePathProvider(session)
            let launchSettings = ControllerLaunchSettings(
                runtimeVariant: runtimeVariant,
                workspacePath: retryWorkspacePath,
                permissionMode: effectivePermissionMode,
                allowNativeBashTool: effectiveAllowNativeBashTool,
                mcpStrictMode: effectiveMCPStrictMode
            )
            let freshController = claudeControllerFactory(
                freshRunID,
                session.tabID,
                windowID,
                launchSettings
            )
            invalidateControllerRetirement(for: session)
            session.claudeController = freshController
            controllerLaunchSettingsByTabID[session.tabID] = launchSettings
            let sessionRef = try await freshController.startOrResume(
                existingSessionID: nil,
                model: model,
                effortLevel: effortLevel,
                systemPromptOverride: systemPromptOverride
            )
            guard sessionOwnsClaudeController(freshController, for: session) else {
                await freshController.shutdown()
                throw ControllerLifecycleError.superseded
            }
            return sessionRef
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
        case .liveModelSwitchRequiresRestart:
            return false
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
        var handler = toolHandler(for: session)
        handler.resetTurnState(for: session)
        viewModel?.setAgentRunActive(session.tabID, isActive: true)
        viewModel?.requestUIRefresh(tabID: session.tabID, urgent: true)

        for _ in 0 ..< 3 {
            await ensureClaudeNativeSession(session: session)
            guard let controller = session.claudeController else {
                finalizeSession(session, state: .failed)
                return false
            }

            if hasEffectiveClaudeControllerLaunchSettingsMismatch(for: session) {
                guard await interruptClaudeTurnIfNeeded(
                    session: session,
                    controller: controller,
                    handler: handler
                ) else {
                    if !sessionOwnsClaudeController(controller, for: session) {
                        continue
                    }
                    return false
                }
                guard sessionOwnsClaudeController(controller, for: session) else {
                    continue
                }
                await recycleClaudeControllerForLaunchSettingsChange(
                    session: session,
                    existingController: controller,
                    runtimeVariantChanged: effectiveClaudeRuntimeVariantChanged(for: session)
                )
                if let runID = session.runID {
                    await ensureClaudeToolTrackingIfNeeded(for: session, runID: runID)
                    handler = toolHandler(for: session)
                }
                continue
            }

            let hasActiveSession = await controller.hasActiveSession
            guard sessionOwnsClaudeController(controller, for: session) else {
                continue
            }
            guard hasActiveSession else {
                finalizeSession(session, state: .failed)
                return false
            }

            guard await interruptClaudeTurnIfNeeded(
                session: session,
                controller: controller,
                handler: handler
            ) else {
                if !sessionOwnsClaudeController(controller, for: session) {
                    continue
                }
                return false
            }
            guard sessionOwnsClaudeController(controller, for: session) else {
                continue
            }

            // Ensure the events stream has a live continuation before sending. If a
            // previous cancel/EOF/reset cycle left eventsContinuation == nil, emit()
            // would silently drop every inbound event. The runner subscribes to the
            // stream *after* this method returns (send → release lease → events(for:)),
            // so events that arrive in between must be buffered in a live stream.
            // ensureEventsStreamReady is idempotent — it only recreates if nil.
            await controller.ensureEventsStreamReady()
            guard sessionOwnsClaudeController(controller, for: session) else {
                continue
            }

            // This is the final launch-settings validation before dispatch. There is
            // intentionally no suspension between this check and sendUserMessage, so a
            // Safe Managed tightening cannot enqueue a turn on the stale controller.
            if hasEffectiveClaudeControllerLaunchSettingsMismatch(for: session) {
                await recycleClaudeControllerForLaunchSettingsChange(
                    session: session,
                    existingController: controller,
                    runtimeVariantChanged: effectiveClaudeRuntimeVariantChanged(for: session)
                )
                if let runID = session.runID {
                    await ensureClaudeToolTrackingIfNeeded(for: session, runID: runID)
                    handler = toolHandler(for: session)
                }
                continue
            }

            do {
                let outboundText: String = if let viewModel {
                    viewModel.prependPendingHandoffIfNeeded(text, session: session)
                } else {
                    text
                }
                let instructions = agentModeInstructionInjection(for: session)
                let providerBoundText = providerBoundUserMessage(outboundText, instructions: instructions)
                let turnID = try await controller.sendUserMessage(providerBoundText)
                guard sessionOwnsClaudeController(controller, for: session) else {
                    await controller.shutdown()
                    return false
                }
                session.claudeExpectedTurnIDs.insert(turnID)
                return true
            } catch {
                guard sessionOwnsClaudeController(controller, for: session) else {
                    await controller.shutdown()
                    return false
                }
                let errorItem = AgentChatItem.error(
                    "Claude native send failed: \(error.localizedDescription)",
                    sequenceIndex: session.nextSequenceIndex
                )
                session.appendItem(errorItem)
                finalizeSession(session, state: .failed, save: true)
                return false
            }
        }

        let errorItem = AgentChatItem.error(
            "Claude native send failed because launch settings changed repeatedly before dispatch.",
            sequenceIndex: session.nextSequenceIndex
        )
        session.appendItem(errorItem)
        finalizeSession(session, state: .failed, save: true)
        return false
    }

    private func interruptClaudeTurnIfNeeded(
        session: AgentModeViewModel.TabSession,
        controller: any NativeAgentRuntimeControlling,
        handler: ClaudeAgentToolTrackingHandler
    ) async -> Bool {
        let hadTurnInFlight = await controller.hasTurnInFlight
        guard hadTurnInFlight else { return true }

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
            return true
        case .timedOut, .failed:
            // Race tolerance: the active turn may have naturally completed after our
            // initial hasTurnInFlight check but before the interrupt was acknowledged.
            // Re-check and only proceed if the turn has already ended.
            let stillInFlight = await controller.hasTurnInFlight
            return !stillInFlight
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

    /// Detaches the current Claude controller and its tool tracker synchronously
    /// so a replacement run cannot be affected by the old controller's async cleanup.
    func prepareClaudeCancelSync(_ session: AgentModeViewModel.TabSession) -> DetachedClaudeController? {
        guard session.selectedAgent.usesClaudeNativeRuntime else { return nil }
        invalidateControllerRetirement(for: session)
        let detached = session.claudeController.flatMap {
            detachClaudeController($0, from: session, removeToolTracking: true)
        }
        if detached == nil {
            clearClaudeControllerLaunchMetadata(for: session)
        }
        session.runID = nil
        session.pendingSupersedingTurnCompletions = 0
        session.claudeSupersedingProtectedTurnIDs.removeAll()
        return detached
    }

    private func prepareClaudeProviderIdentityResetSync(
        _ session: AgentModeViewModel.TabSession
    ) -> DetachedClaudeController? {
        let detached = prepareClaudeCancelSync(session)
        invalidatePendingClaudeResumeTransfer(for: session)
        session.providerSessionID = nil
        return detached
    }

    func handleProviderIdentityTransitionSync(
        session: AgentModeViewModel.TabSession,
        from previousAgent: AgentProviderKind,
        to nextAgent: AgentProviderKind
    ) {
        guard previousAgent.usesClaudeNativeRuntime,
              !nextAgent.usesClaudeNativeRuntime || previousAgent != nextAgent
        else {
            return
        }
        let detached = prepareClaudeProviderIdentityResetSync(session)
        Task { await cancelClaudeRun(session, oldController: detached) }
    }

    func handleProviderIdentityTransition(
        session: AgentModeViewModel.TabSession,
        from previousAgent: AgentProviderKind,
        to nextAgent: AgentProviderKind
    ) async {
        guard previousAgent.usesClaudeNativeRuntime,
              !nextAgent.usesClaudeNativeRuntime || previousAgent != nextAgent
        else {
            return
        }
        let detached = prepareClaudeProviderIdentityResetSync(session)
        await cancelClaudeRun(session, oldController: detached)
    }

    func prepareForConversationResetSync(_ session: AgentModeViewModel.TabSession) {
        let detached = prepareClaudeCancelSync(session)
        invalidatePendingClaudeResumeTransfer(for: session)
        Task { await cancelClaudeRun(session, oldController: detached) }
    }

    func beginClaudeResumeTransferIfNeeded(
        for session: AgentModeViewModel.TabSession,
        oldController: DetachedClaudeController?
    ) {
        guard let oldController else { return }
        guard pendingResumeTransferTasksByTabID[session.tabID] == nil else {
            let task = Task { @MainActor [self, session] in
                await cancelClaudeRunAndCaptureSessionRef(session, oldController: oldController)
            }
            retiredResumeTransferTasksByTabID[session.tabID, default: []].append(task)
            return
        }
        let generation = UUID()
        pendingResumeTransferGenerationByTabID[session.tabID] = generation
        pendingResumeTransferTasksByTabID[session.tabID] = Task { @MainActor [self, session] in
            await cancelClaudeRunAndCaptureSessionRef(session, oldController: oldController)
        }
    }

    func awaitPendingClaudeResumeTransferIfNeeded(
        for session: AgentModeViewModel.TabSession,
        scheduleProviderSessionSave: Bool = true
    ) async {
        let retiredTasks = retiredResumeTransferTasksByTabID.removeValue(forKey: session.tabID) ?? []
        for task in retiredTasks {
            _ = await task.value
        }

        guard let task = pendingResumeTransferTasksByTabID[session.tabID],
              let generation = pendingResumeTransferGenerationByTabID[session.tabID]
        else {
            return
        }
        let sessionRef = await task.value
        guard pendingResumeTransferGenerationByTabID[session.tabID] == generation else { return }
        pendingResumeTransferTasksByTabID.removeValue(forKey: session.tabID)
        pendingResumeTransferGenerationByTabID.removeValue(forKey: session.tabID)
        updateProviderSessionIDIfNeeded(
            sessionRef.sessionID,
            for: session,
            scheduleSave: scheduleProviderSessionSave
        )
    }

    func hasPendingResumeTransfer(
        for session: AgentModeViewModel.TabSession
    ) -> Bool {
        pendingResumeTransferTasksByTabID[session.tabID] != nil
            || retiredResumeTransferTasksByTabID[session.tabID]?.isEmpty == false
    }

    func invalidatePendingClaudeResumeTransfer(
        for session: AgentModeViewModel.TabSession
    ) {
        if let task = pendingResumeTransferTasksByTabID[session.tabID] {
            retiredResumeTransferTasksByTabID[session.tabID, default: []].append(task)
        }
        pendingResumeTransferTasksByTabID.removeValue(forKey: session.tabID)
        pendingResumeTransferGenerationByTabID.removeValue(forKey: session.tabID)
    }

    /// Async cleanup for a synchronously detached controller after cancel.
    func cancelClaudeRun(
        _ session: AgentModeViewModel.TabSession,
        oldController: DetachedClaudeController?
    ) async {
        guard let oldController else { return }
        _ = await cancelClaudeRunAndCaptureSessionRef(session, oldController: oldController)
    }

    private func cancelClaudeRunAndCaptureSessionRef(
        _ session: AgentModeViewModel.TabSession,
        oldController: DetachedClaudeController
    ) async -> NativeAgentRuntimeSessionRef {
        let controller = oldController.controller
        let interruptOutcome = await controller.interruptTurn(reason: "interrupt")
        await stopToolTracking(oldController, for: session)
        if interruptOutcome == .acknowledged {
            // Give Claude ~200 ms to persist any in-flight state before we
            // tear down the process. The UI doesn't block on this — the
            // controller was already detached by prepareClaudeCancelSync.
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let sessionRef = await controller.currentSessionRef()
        await controller.shutdown()
        return sessionRef
    }

    func shutdownClaudeSessionIfNeeded(_ session: AgentModeViewModel.TabSession) async {
        guard session.claudeController != nil
            || hasPendingResumeTransfer(for: session)
            || session.selectedAgent.usesClaudeNativeRuntime
        else {
            return
        }
        await shutdownClaudeSession(session)
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
            guard let detached = detachClaudeController(
                controller,
                from: session,
                removeToolTracking: clearTabScopedCoordinatorState
            ) else {
                return
            }
            guard await retireClaudeController(
                detached,
                for: session,
                captureProviderSessionID: true,
                scheduleProviderSessionSave: clearTabScopedCoordinatorState
            ) else {
                return
            }
        } else {
            invalidateControllerRetirement(for: session)
            clearClaudeControllerLaunchMetadata(for: session)
        }
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
        for session: AgentModeViewModel.TabSession
    ) async {
        guard let handler = toolHandlerByTabID.removeValue(forKey: session.tabID) else { return }
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

    private func effectiveClaudeRuntimePermission(
        for session: AgentModeViewModel.TabSession
    ) -> ClaudeControllerLaunchPolicy {
        guard let providerBindingService = viewModel?.providerBindingService else {
            return ClaudeControllerLaunchPolicy(
                permissionMode: session.permissionProfile.claudePermissionMode,
                allowNativeBashTool: session.permissionProfile == .mcpSafeDefaults ? false : nil,
                mcpStrictMode: session.permissionProfile == .mcpSafeDefaults ? true : nil
            )
        }
        let permissionMode = providerBindingService.runtimePermission(
            for: session.selectedAgent,
            profile: session.permissionProfile
        ).claudePermissionMode
        let preferences = providerBindingService.preferences
        return ClaudeControllerLaunchPolicy.resolve(
            permissionMode: permissionMode,
            profile: session.permissionProfile,
            defaults: preferences.defaults,
            securePermissions: preferences.securePermissions
        )
    }

    private func unsupportedAutoFallback(
        for session: AgentModeViewModel.TabSession
    ) -> ClaudeAgentToolPreferences.UnsupportedAutoPermissionFallback {
        session.parentSessionID == nil ? .autoApproveEdits : .fullAccess
    }

    private func effectiveClaudePermissionResolution(
        for session: AgentModeViewModel.TabSession,
        selectedModelRaw: String,
        runtimePermission: ClaudeControllerLaunchPolicy? = nil
    ) -> ClaudeAgentToolPreferences.PermissionModeResolution {
        ClaudeAgentToolPreferences.resolvePermissionMode(
            requestedMode: (runtimePermission ?? effectiveClaudeRuntimePermission(for: session)).permissionMode
                ?? session.permissionProfile.claudePermissionMode,
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
