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

    enum NativeSessionIntent: Equatable {
        case runAttempt(ownership: AgentRunOwnership, runID: UUID)
        case reconnect(
            runID: UUID,
            providerSessionID: String,
            currency: AgentModeViewModel.PersistentBindingTransitionToken
        )

        var runID: UUID {
            switch self {
            case let .runAttempt(_, runID), let .reconnect(runID, _, _):
                runID
            }
        }

        var allowsFreshStartRecovery: Bool {
            if case .runAttempt = self { return true }
            return false
        }

        @MainActor
        func isCurrent(for session: AgentTabSession) -> Bool {
            switch self {
            case let .runAttempt(ownership, runID):
                session.isCurrentRunAttemptForCurrentBinding(
                    ownership,
                    expectedRunID: runID
                )
            case let .reconnect(runID, providerSessionID, currency):
                session.persistentBindingTransitionToken() == currency
                    && session.activeRunOwnership == nil
                    && session.runID == runID
                    && session.providerSessionID == providerSessionID
            }
        }
    }

    enum EnsureSessionOutcome: Equatable {
        case ready
        case failed(message: String)
        case superseded
    }

    enum NativeSendOutcome: Equatable {
        case sent
        case failed(message: String)
        case superseded
    }

    struct HostCapabilities {
        let isSessionCurrent: @MainActor (_ session: AgentTabSession) -> Bool
        let requestUIRefresh: @MainActor (_ session: AgentTabSession, _ urgent: Bool) -> Void
        let scheduleSave: @MainActor (_ session: AgentTabSession) -> Void
        let stageClaudeResumeRecoveryHandoff: @MainActor (_ session: AgentTabSession) async -> Void
        let prependPendingHandoff: @MainActor (_ text: String, _ session: AgentTabSession) -> String

        static var noOp: Self {
            Self(
                isSessionCurrent: { _ in true },
                requestUIRefresh: { _, _ in },
                scheduleSave: { _ in },
                stageClaudeResumeRecoveryHandoff: { _ in },
                prependPendingHandoff: { text, _ in text }
            )
        }
    }

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

    private weak var providerBindingService: AgentModeProviderBindingService?
    private var hostCapabilities: HostCapabilities = .noOp
    private let windowID: Int
    private let workspacePathProvider: (AgentTabSession) throws -> String?
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
        workspacePathProvider: @escaping (AgentTabSession) throws -> String?,
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
        for session: AgentTabSession,
        scheduleSave: Bool = true
    ) -> Bool {
        guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty,
              session.providerSessionID != candidate
        else {
            return false
        }
        session.providerSessionID = candidate
        session.providerCleanupHandle = ProviderConversationCleanupHandle.resolved(
            provider: session.selectedAgent.rawValue,
            explicit: nil,
            providerSessionID: candidate,
            codexConversationID: session.codexConversationID,
            codexRolloutPath: session.codexRolloutPath
        )
        guard scheduleSave else { return true }
        session.isDirty = true
        hostCapabilities.scheduleSave(session)
        return true
    }

    func installHostCapabilities(
        _ hostCapabilities: HostCapabilities,
        providerBindingService: AgentModeProviderBindingService
    ) {
        self.hostCapabilities = hostCapabilities
        self.providerBindingService = providerBindingService
    }

    func stop() {
        controllerLaunchSettingsByTabID.removeAll()
        controllerRetirementGenerationByTabID.removeAll()
        let resumeTransferTasks = Array(pendingResumeTransferTasksByTabID.values)
            + retiredResumeTransferTasksByTabID.values.flatMap(\.self)
        resumeTransferTasks.forEach { $0.cancel() }
        pendingResumeTransferTasksByTabID.removeAll()
        pendingResumeTransferGenerationByTabID.removeAll()
        retiredResumeTransferTasksByTabID.removeAll()
    }

    /// Detaches every tab-scoped Claude tool tracker from the coordinator map without blocking.
    ///
    /// Call from workspace-switch discard before the foreground session map is cleared so
    /// recycled tab IDs do not inherit stale tracking state. Do not call from `stop()`, which
    /// also runs when agent mode UI is hidden while sessions remain alive.
    func detachAllClaudeToolTrackingHandlersForWorkspaceSwitch() {
        let handlers = toolHandlerByTabID
        toolHandlerByTabID.removeAll()
        for (tabID, handler) in handlers {
            let session = AgentTabSession(tabID: tabID)
            Task { await handler.stopTracking(for: session) }
        }
    }

    func events(for session: AgentTabSession) async -> AsyncStream<NativeAgentRuntimeEvent>? {
        guard let controller = session.claudeController else { return nil }
        // Ensure the stream has a live continuation before returning. This
        // handles the case where the stream was finished by handleStdoutEOF
        // or another path that called finishEventsStreamIfNeeded. Without
        // this, the runner would immediately see "stream ended unexpectedly".
        await controller.ensureEventsStreamReady()
        return await controller.events
    }

    func hasTurnInFlight(for session: AgentTabSession) async -> Bool {
        guard let controller = session.claudeController else { return false }
        return await controller.hasTurnInFlight
    }

    func scheduleApplyCurrentClaudeModelAndEffortIfPossible(
        for session: AgentTabSession,
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
        for session: AgentTabSession,
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

    func ensureClaudeToolTrackingIfNeeded(for session: AgentTabSession, runID: UUID) async {
        let handler = toolHandler(for: session)
        await handler.startTracking(runID: runID, session: session, clientNameHint: session.selectedAgent.mcpClientNameHint)
    }

    private func toolHandler(for session: AgentTabSession) -> ClaudeAgentToolTrackingHandler {
        if let existing = toolHandlerByTabID[session.tabID] {
            existing.hooks = toolTrackingHooks
            return existing
        }
        let handler = ClaudeAgentToolTrackingHandler(hooks: toolTrackingHooks)
        toolHandlerByTabID[session.tabID] = handler
        return handler
    }

    private func intentIsCurrent(
        _ intent: NativeSessionIntent,
        for session: AgentTabSession
    ) -> Bool {
        hostCapabilities.isSessionCurrent(session) && intent.isCurrent(for: session)
    }

    func runAttemptIsCurrent(
        _ ownership: AgentRunOwnership,
        runID: UUID,
        for session: AgentTabSession
    ) -> Bool {
        intentIsCurrent(
            .runAttempt(ownership: ownership, runID: runID),
            for: session
        )
    }

    func ensureClaudeNativeSession(
        session: AgentTabSession,
        intent: NativeSessionIntent
    ) async -> EnsureSessionOutcome {
        guard session.selectedAgent.usesClaudeNativeRuntime,
              intentIsCurrent(intent, for: session)
        else {
            return .superseded
        }

        switch intent {
        case .runAttempt:
            await awaitPendingClaudeResumeTransferIfNeeded(for: session)
        case .reconnect:
            guard !hasPendingResumeTransfer(for: session) else { return .superseded }
        }
        guard intentIsCurrent(intent, for: session) else { return .superseded }

        let runID = intent.runID
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
            let hasTurnInFlight = await existingController.hasTurnInFlight
            guard intentIsCurrent(intent, for: session),
                  sessionOwnsClaudeController(existingController, for: session)
            else {
                return .superseded
            }
            guard !hasTurnInFlight else { return .ready }
            if case .reconnect = intent, runtimeVariantChanged {
                return .failed(message: "Claude reconnect requires a fresh session after the runtime provider changed.")
            }
            await recycleClaudeControllerForLaunchSettingsChange(
                session: session,
                existingController: existingController,
                runtimeVariantChanged: runtimeVariantChanged
            )
            guard intentIsCurrent(intent, for: session) else { return .superseded }
        }

        let runtimeWorkspacePath: String?
        do {
            runtimeWorkspacePath = try workspacePathProvider(session)
        } catch {
            guard intentIsCurrent(intent, for: session) else { return .superseded }
            return .failed(message: Self.providerStartupFailureMessage(for: error))
        }

        if let existingController = session.claudeController,
           controllerLaunchSettingsByTabID[session.tabID]?.workspacePath != runtimeWorkspacePath
        {
            guard let detached = detachClaudeController(
                existingController,
                from: session,
                removeToolTracking: true
            ) else {
                return .superseded
            }
            _ = await retireClaudeController(
                detached,
                for: session,
                captureProviderSessionID: intent.allowsFreshStartRecovery
            )
            guard intentIsCurrent(intent, for: session) else { return .superseded }
        }

        if session.claudeController == nil {
            guard intentIsCurrent(intent, for: session) else { return .superseded }
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
            guard intentIsCurrent(intent, for: session),
                  sessionOwnsClaudeController(createdController, for: session)
            else {
                if !sessionOwnsClaudeController(createdController, for: session) {
                    await createdController.shutdown()
                }
                return .superseded
            }
        }

        guard let controller = session.claudeController else { return .superseded }
        do {
            let model = effectiveClaudeModel(selectedModelRaw: launchModelRaw)
            let sessionRef = try await startOrResumeWithFallback(
                controller: controller,
                session: session,
                intent: intent,
                model: model,
                runtimeVariant: runtimeVariant,
                effectivePermissionMode: effectivePermissionMode,
                effectiveAllowNativeBashTool: effectiveAllowNativeBashTool,
                effectiveMCPStrictMode: effectiveMCPStrictMode
            )
            guard intentIsCurrent(intent, for: session) else { return .superseded }
            updateProviderSessionIDIfNeeded(sessionRef.sessionID, for: session)
            return .ready
        } catch ControllerLifecycleError.superseded {
            return .superseded
        } catch {
            guard intentIsCurrent(intent, for: session) else { return .superseded }
            return .failed(message: "Claude native start failed: \(error.localizedDescription)")
        }
    }

    private func hasEffectiveClaudeControllerLaunchSettingsMismatch(
        for session: AgentTabSession
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
        for session: AgentTabSession
    ) -> Bool {
        let runtimeVariant = session.selectedAgent.claudeRuntimeVariant ?? .standard
        return controllerLaunchSettingsByTabID[session.tabID].map { $0.runtimeVariant != runtimeVariant } ?? false
    }

    private func recycleClaudeControllerForLaunchSettingsChange(
        session: AgentTabSession,
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
            session.providerCleanupHandle = nil
            session.isDirty = true
            hostCapabilities.scheduleSave(session)
        }
        _ = await retireClaudeController(
            detached,
            for: session,
            captureProviderSessionID: !runtimeVariantChanged
        )
    }

    private func detachClaudeController(
        _ controller: any NativeAgentRuntimeControlling,
        from session: AgentTabSession,
        removeToolTracking: Bool
    ) -> DetachedClaudeController? {
        guard sessionOwnsClaudeController(controller, for: session) else { return nil }
        let toolHandler = removeToolTracking ? toolHandlerByTabID.removeValue(forKey: session.tabID) : nil
        clearClaudeControllerLaunchMetadata(for: session)
        return DetachedClaudeController(controller: controller, toolHandler: toolHandler)
    }

    private func clearClaudeControllerLaunchMetadata(
        for session: AgentTabSession
    ) {
        session.claudeController = nil
        controllerLaunchSettingsByTabID.removeValue(forKey: session.tabID)
    }

    private func stopToolTracking(
        _ detached: DetachedClaudeController,
        for session: AgentTabSession
    ) async {
        await detached.toolHandler?.stopTracking(for: session)
    }

    @discardableResult
    private func retireClaudeController(
        _ detached: DetachedClaudeController,
        for session: AgentTabSession,
        captureProviderSessionID: Bool
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
                    for: session
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

    private func invalidateControllerRetirement(for session: AgentTabSession) {
        controllerRetirementGenerationByTabID.removeValue(forKey: session.tabID)
    }

    #if DEBUG
        func test_discardRuntimeState(for session: AgentTabSession) {
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
            for session: AgentTabSession
        ) {
            if session.claudeController != nil {
                invalidateControllerRetirement(for: session)
            }
            controllerLaunchSettingsByTabID[session.tabID] = settings
        }

        func test_controllerLaunchSettings(
            for session: AgentTabSession
        ) -> ControllerLaunchSettings? {
            controllerLaunchSettingsByTabID[session.tabID]
        }

        func test_hasPendingOrRetiredResumeTransfers(
            for session: AgentTabSession
        ) -> Bool {
            hasPendingResumeTransfer(for: session)
                || pendingResumeTransferGenerationByTabID[session.tabID] != nil
        }
    #endif

    private func sessionOwnsClaudeController(
        _ controller: any NativeAgentRuntimeControlling,
        for session: AgentTabSession
    ) -> Bool {
        guard let currentController = session.claudeController else { return false }
        return ObjectIdentifier(currentController as AnyObject) == ObjectIdentifier(controller as AnyObject)
    }

    private func startOrResumeWithFallback(
        controller: any NativeAgentRuntimeControlling,
        session: AgentTabSession,
        intent: NativeSessionIntent,
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
            guard intentIsCurrent(intent, for: session),
                  sessionOwnsClaudeController(controller, for: session)
            else {
                if !sessionOwnsClaudeController(controller, for: session) {
                    await controller.shutdown()
                }
                throw ControllerLifecycleError.superseded
            }
            return sessionRef
        } catch ControllerLifecycleError.superseded {
            throw ControllerLifecycleError.superseded
        } catch {
            guard intentIsCurrent(intent, for: session),
                  sessionOwnsClaudeController(controller, for: session)
            else {
                if !sessionOwnsClaudeController(controller, for: session) {
                    await controller.shutdown()
                }
                throw ControllerLifecycleError.superseded
            }
            guard intent.allowsFreshStartRecovery,
                  shouldRetryFreshStartWithoutResume(after: error, existingSessionID: existingSessionID)
            else {
                throw error
            }

            await hostCapabilities.stageClaudeResumeRecoveryHandoff(session)
            guard intentIsCurrent(intent, for: session),
                  let detached = detachClaudeController(
                      controller,
                      from: session,
                      removeToolTracking: true
                  )
            else {
                throw ControllerLifecycleError.superseded
            }
            await detached.controller.shutdown()
            await stopToolTracking(detached, for: session)
            guard intentIsCurrent(intent, for: session) else {
                throw ControllerLifecycleError.superseded
            }

            // A resume fallback is still the same canonical run attempt. Reuse
            // its process identity and retain the previous provider identity
            // until the fresh controller has actually started successfully.
            let retryWorkspacePath = try workspacePathProvider(session)
            let launchSettings = ControllerLaunchSettings(
                runtimeVariant: runtimeVariant,
                workspacePath: retryWorkspacePath,
                permissionMode: effectivePermissionMode,
                allowNativeBashTool: effectiveAllowNativeBashTool,
                mcpStrictMode: effectiveMCPStrictMode
            )
            let freshController = claudeControllerFactory(
                intent.runID,
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
            guard intentIsCurrent(intent, for: session),
                  sessionOwnsClaudeController(freshController, for: session)
            else {
                if !sessionOwnsClaudeController(freshController, for: session) {
                    await freshController.shutdown()
                }
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
        session: AgentTabSession,
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
        session: AgentTabSession,
        text: String,
        attachments _: [AgentImageAttachment],
        intent: NativeSessionIntent
    ) async -> NativeSendOutcome {
        guard intentIsCurrent(intent, for: session) else { return .superseded }
        var handler = toolHandler(for: session)
        handler.resetTurnState(for: session)

        for _ in 0 ..< 3 {
            switch await ensureClaudeNativeSession(session: session, intent: intent) {
            case .ready:
                break
            case let .failed(message):
                return recordSendFailure(message, session: session, intent: intent)
            case .superseded:
                return .superseded
            }
            guard intentIsCurrent(intent, for: session),
                  let controller = session.claudeController
            else {
                return .superseded
            }

            if hasEffectiveClaudeControllerLaunchSettingsMismatch(for: session) {
                guard await interruptClaudeTurnIfNeeded(
                    session: session,
                    controller: controller,
                    handler: handler
                ) else {
                    guard intentIsCurrent(intent, for: session),
                          sessionOwnsClaudeController(controller, for: session)
                    else {
                        return .superseded
                    }
                    return recordSendFailure(
                        "Claude native send failed because the active turn could not be interrupted safely.",
                        session: session,
                        intent: intent
                    )
                }
                guard intentIsCurrent(intent, for: session),
                      sessionOwnsClaudeController(controller, for: session)
                else {
                    return .superseded
                }
                await recycleClaudeControllerForLaunchSettingsChange(
                    session: session,
                    existingController: controller,
                    runtimeVariantChanged: effectiveClaudeRuntimeVariantChanged(for: session)
                )
                guard intentIsCurrent(intent, for: session) else { return .superseded }
                await ensureClaudeToolTrackingIfNeeded(for: session, runID: intent.runID)
                handler = toolHandler(for: session)
                continue
            }

            let hasActiveSession = await controller.hasActiveSession
            guard intentIsCurrent(intent, for: session),
                  sessionOwnsClaudeController(controller, for: session)
            else {
                return .superseded
            }
            guard hasActiveSession else {
                return recordSendFailure(
                    "Claude native send failed because the provider session is not active.",
                    session: session,
                    intent: intent
                )
            }

            guard await interruptClaudeTurnIfNeeded(
                session: session,
                controller: controller,
                handler: handler
            ) else {
                guard intentIsCurrent(intent, for: session),
                      sessionOwnsClaudeController(controller, for: session)
                else {
                    return .superseded
                }
                return recordSendFailure(
                    "Claude native send failed because the active turn could not be interrupted safely.",
                    session: session,
                    intent: intent
                )
            }
            guard intentIsCurrent(intent, for: session),
                  sessionOwnsClaudeController(controller, for: session)
            else {
                return .superseded
            }

            // Ensure the events stream has a live continuation before sending. If a
            // previous cancel/EOF/reset cycle left eventsContinuation == nil, emit()
            // would silently drop every inbound event. The runner subscribes to the
            // stream *after* this method returns (send → release lease → events(for:)),
            // so events that arrive in between must be buffered in a live stream.
            // ensureEventsStreamReady is idempotent — it only recreates if nil.
            await controller.ensureEventsStreamReady()
            guard intentIsCurrent(intent, for: session),
                  sessionOwnsClaudeController(controller, for: session)
            else {
                return .superseded
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
                guard intentIsCurrent(intent, for: session) else { return .superseded }
                await ensureClaudeToolTrackingIfNeeded(for: session, runID: intent.runID)
                handler = toolHandler(for: session)
                continue
            }

            do {
                let outboundText = hostCapabilities.prependPendingHandoff(text, session)
                let instructions = agentModeInstructionInjection(for: session)
                let providerBoundText = providerBoundUserMessage(outboundText, instructions: instructions)
                let turnID = try await controller.sendUserMessage(providerBoundText)
                guard intentIsCurrent(intent, for: session),
                      sessionOwnsClaudeController(controller, for: session)
                else {
                    if !sessionOwnsClaudeController(controller, for: session) {
                        await controller.shutdown()
                    }
                    return .superseded
                }
                session.claudeExpectedTurnIDs.insert(turnID)
                return .sent
            } catch {
                guard intentIsCurrent(intent, for: session),
                      sessionOwnsClaudeController(controller, for: session)
                else {
                    if !sessionOwnsClaudeController(controller, for: session) {
                        await controller.shutdown()
                    }
                    return .superseded
                }
                return recordSendFailure(
                    "Claude native send failed: \(error.localizedDescription)",
                    session: session,
                    intent: intent
                )
            }
        }

        return recordSendFailure(
            "Claude native send failed because launch settings changed repeatedly before dispatch.",
            session: session,
            intent: intent
        )
    }

    private func recordSendFailure(
        _ message: String,
        session: AgentTabSession,
        intent: NativeSessionIntent
    ) -> NativeSendOutcome {
        guard intentIsCurrent(intent, for: session) else { return .superseded }
        if session.items.last?.kind != .error || session.items.last?.text != message {
            session.appendItem(
                AgentChatItem.error(
                    message,
                    sequenceIndex: session.nextSequenceIndex
                )
            )
        }
        session.isDirty = true
        hostCapabilities.requestUIRefresh(session, true)
        hostCapabilities.scheduleSave(session)
        return .failed(message: message)
    }

    private func interruptClaudeTurnIfNeeded(
        session: AgentTabSession,
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
        session: AgentTabSession,
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
        hostCapabilities.requestUIRefresh(session, true)
        Task { [controller] in
            await controller.respondToPermissionRequest(id: requestID, decision: decision)
        }
    }

    /// Detaches the current Claude controller and its tool tracker synchronously
    /// so a replacement run cannot be affected by the old controller's async cleanup.
    func prepareClaudeCancelSync(_ session: AgentTabSession) -> DetachedClaudeController? {
        guard session.selectedAgent.usesClaudeNativeRuntime else { return nil }
        invalidateControllerRetirement(for: session)
        let detached = session.claudeController.flatMap {
            detachClaudeController($0, from: session, removeToolTracking: true)
        }
        if detached == nil {
            clearClaudeControllerLaunchMetadata(for: session)
        }
        // Force reset: user cancel / provider identity transition — no run
        // survives, and this synchronous path decides that authoritatively.
        AgentModeProcessRunIdentity.clearProcessRunID(for: session)
        session.pendingSupersedingTurnCompletions = 0
        session.claudeSupersedingProtectedTurnIDs.removeAll()
        return detached
    }

    private func prepareClaudeProviderIdentityResetSync(
        _ session: AgentTabSession
    ) -> DetachedClaudeController? {
        let detached = prepareClaudeCancelSync(session)
        invalidatePendingClaudeResumeTransfer(for: session)
        session.providerSessionID = nil
        session.providerCleanupHandle = nil
        return detached
    }

    func handleProviderIdentityTransitionSync(
        session: AgentTabSession,
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
        session: AgentTabSession,
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

    func prepareForConversationResetSync(_ session: AgentTabSession) {
        let detached = prepareClaudeCancelSync(session)
        invalidatePendingClaudeResumeTransfer(for: session)
        Task { await cancelClaudeRun(session, oldController: detached) }
    }

    func beginClaudeResumeTransferIfNeeded(
        for session: AgentTabSession,
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
        for session: AgentTabSession
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
            for: session
        )
    }

    func hasPendingResumeTransfer(
        for session: AgentTabSession
    ) -> Bool {
        pendingResumeTransferTasksByTabID[session.tabID] != nil
            || retiredResumeTransferTasksByTabID[session.tabID]?.isEmpty == false
    }

    func invalidatePendingClaudeResumeTransfer(
        for session: AgentTabSession
    ) {
        if let task = pendingResumeTransferTasksByTabID[session.tabID] {
            retiredResumeTransferTasksByTabID[session.tabID, default: []].append(task)
        }
        pendingResumeTransferTasksByTabID.removeValue(forKey: session.tabID)
        pendingResumeTransferGenerationByTabID.removeValue(forKey: session.tabID)
    }

    /// Async cleanup for a synchronously detached controller after cancel.
    func cancelClaudeRun(
        _ session: AgentTabSession,
        oldController: DetachedClaudeController?
    ) async {
        guard let oldController else { return }
        _ = await cancelClaudeRunAndCaptureSessionRef(session, oldController: oldController)
    }

    private func cancelClaudeRunAndCaptureSessionRef(
        _ session: AgentTabSession,
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

    func shutdownClaudeSessionIfNeeded(_ session: AgentTabSession) async {
        guard session.claudeController != nil
            || hasPendingResumeTransfer(for: session)
            || session.selectedAgent.usesClaudeNativeRuntime
        else {
            return
        }
        await shutdownClaudeSession(session)
    }

    /// Tab/context-terminal shutdown with force semantics: every caller is
    /// tab-terminal (window/tab close, session delete, execution-location
    /// change), so any run present — including one that started during the
    /// awaits below — must not survive. Workspace-switch discard does not use
    /// this path; it transfers ownership synchronously via
    /// `detachForWorkspaceSwitchFinalizeSync` and retires the handle in the
    /// background.
    func shutdownClaudeSession(_ session: AgentTabSession) async {
        await awaitPendingClaudeResumeTransferIfNeeded(for: session)
        if let controller = session.claudeController {
            guard let detached = detachClaudeController(
                controller,
                from: session,
                removeToolTracking: true
            ) else {
                return
            }
            guard await retireClaudeController(
                detached,
                for: session,
                captureProviderSessionID: true
            ) else {
                return
            }
        } else {
            invalidateControllerRetirement(for: session)
            clearClaudeControllerLaunchMetadata(for: session)
        }
        AgentModeProcessRunIdentity.clearProcessRunID(for: session)
        session.pendingSupersedingTurnCompletions = 0
        session.claudeSupersedingProtectedTurnIDs.removeAll()
        session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
        session.setRunningStatus(nil, source: nil)
        await clearClaudeToolTracking(for: session)
    }

    /// Synchronous half of workspace-switch discard: transfers ownership of the
    /// session's Claude runtime (controller + tool tracker) into a detached
    /// handle and clears the coordinator's tab-scoped metadata for the tab.
    /// Runs on the main actor with no suspension, after all cancellation awaits
    /// and before the session map is cleared, so the captured handle is provably
    /// the discarded session's own. The caller retires the handle with
    /// `retireDetachedControllerForWorkspaceSwitch`.
    func detachForWorkspaceSwitchFinalizeSync(
        _ session: AgentTabSession
    ) -> DetachedClaudeController? {
        invalidateControllerRetirement(for: session)
        invalidatePendingClaudeResumeTransfer(for: session)
        let detached = session.claudeController.flatMap {
            detachClaudeController($0, from: session, removeToolTracking: true)
        }
        if detached == nil {
            clearClaudeControllerLaunchMetadata(for: session)
        }
        session.pendingSupersedingTurnCompletions = 0
        session.claudeSupersedingProtectedTurnIDs.removeAll()
        session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
        session.setRunningStatus(nil, source: nil)
        return detached
    }

    /// Background half of workspace-switch discard: retires a handle captured by
    /// `detachForWorkspaceSwitchFinalizeSync`. Instance-scoped only — reads no
    /// live session state and touches no tab-keyed coordinator registries, so a
    /// same-tab successor can never be affected. `discardedSession` is the
    /// discarded session object the tool tracker was correlated with; it is no
    /// longer reachable from the session map.
    func retireDetachedControllerForWorkspaceSwitch(
        _ detached: DetachedClaudeController,
        discardedSession session: AgentTabSession
    ) async {
        await detached.controller.shutdown()
        await stopToolTracking(detached, for: session)
    }

    private func clearClaudeToolTracking(
        for session: AgentTabSession
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
        session: AgentTabSession
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
        session: AgentTabSession
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
    func resetToolCorrelation(for session: AgentTabSession) {
        toolHandler(for: session).resetTurnState(for: session)
    }

    /// Forward a tracker tool call to the per-tab handler (used by tests and internal paths).
    func handleClaudeTrackerToolCall(
        invocationID: UUID,
        toolName: String,
        args: [String: Value]?,
        session: AgentTabSession
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
        session: AgentTabSession
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
        session: AgentTabSession
    ) -> Bool {
        toolHandler(for: session).handleProviderToolEvent(event, session: session)
    }

    private func effectiveClaudeRuntimePermission(
        for session: AgentTabSession
    ) -> ClaudeControllerLaunchPolicy {
        guard let providerBindingService else {
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
        for session: AgentTabSession
    ) -> ClaudeAgentToolPreferences.UnsupportedAutoPermissionFallback {
        session.parentSessionID == nil ? .autoApproveEdits : .fullAccess
    }

    private func effectiveClaudePermissionResolution(
        for session: AgentTabSession,
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

    private func effectiveClaudeModel(for session: AgentTabSession) -> String? {
        effectiveClaudeModel(selectedModelRaw: session.selectedModelRaw)
    }

    private func effectiveClaudeModel(selectedModelRaw: String) -> String? {
        let selectedRaw = selectedModelRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedRaw.isEmpty, selectedRaw != AgentModel.defaultModel.rawValue else {
            return nil
        }
        return selectedRaw
    }

    private func currentClaudeEffortLevel(for session: AgentTabSession) -> ClaudeCodeEffortLevel {
        providerBindingService?.claudeEffortLevel(
            forModelRaw: session.selectedModelRaw,
            agentKind: session.selectedAgent
        ) ?? ClaudeAgentToolPreferences.effortLevel(
            forModelRaw: session.selectedModelRaw,
            agentKind: session.selectedAgent
        )
    }

    private func agentModeInstructionInjection(for session: AgentTabSession) -> String {
        SystemPromptService.agentModePrompt(
            agentKind: session.selectedAgent,
            taskLabelKind: session.mcpControlContext?.taskLabelKind,
            codeMapsDisabled: GlobalSettingsStore.shared.globalCodeMapsDisabled()
        )
    }

    private func agentModeSystemPromptOverride(for session: AgentTabSession) -> String? {
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
