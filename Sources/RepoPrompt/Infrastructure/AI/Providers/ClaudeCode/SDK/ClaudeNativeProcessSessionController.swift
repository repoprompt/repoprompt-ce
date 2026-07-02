import Darwin
import Foundation

final actor ClaudeNativeProcessSessionController {
    private static let rawEventLogFilePathKey = "claudeRawEventLogFilePath"
    private static let lastRawEventLogFilePathKey = "claudeLastRawEventLogFilePath"
    private static let rawEventTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    enum TurnStatus {
        case completed
        case cancelled
        case failed
    }

    struct RuntimeInitStatus: Equatable {
        struct InitializeResponseSnapshot: Equatable {
            struct Command: Equatable {
                let name: String
                let description: String
                let argumentHint: String
            }

            struct Agent: Equatable {
                let name: String
                let description: String
                let model: String?
            }

            struct Account: Equatable {
                let email: String?
                let organization: String?
                let subscriptionType: String?
                let tokenSource: String?
                let apiKeySource: String?
                let apiProvider: String?
            }

            let commands: [Command]
            let agents: [Agent]
            let outputStyle: String?
            let availableOutputStyles: [String]
            let account: Account?
            let pid: Int?
            let modelsJSON: String?
            let fastModeStateJSON: String?
        }

        let sessionID: String?
        let tools: [String]
        let mcpServerStatuses: [String: String]
        let initializeResponse: InitializeResponseSnapshot?

        var repoPromptServerStatus: String? {
            mcpServerStatuses.first {
                $0.key.compare(MCPIntegrationHelper.repoPromptMCPServerName, options: .caseInsensitive) == .orderedSame
            }?.value
        }

        var isRepoPromptServerFailed: Bool {
            guard let status = repoPromptServerStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                return false
            }
            return status == "failed"
        }
    }

    enum Event {
        case stream(AIStreamResult)
        case runtimeInit(RuntimeInitStatus)
        case approvalRequest(AgentApprovalRequest)
        case approvalCancelled(requestID: String)
        case turnCompleted(turnID: UUID, status: TurnStatus)
        case error(String)
    }

    struct SessionRef {
        var sessionID: String?
    }

    /// Outcome of an interrupt control request, used by the coordinator to decide
    /// whether it is safe to proceed with a superseding user turn.
    enum InterruptOutcome: Equatable {
        /// Claude acknowledged the interrupt via control_response success.
        case acknowledged
        /// No turn was in flight; the turn likely completed naturally before the interrupt.
        case noTurnInFlight
        /// The interrupt control request timed out without an acknowledgement.
        case timedOut
        /// The interrupt request failed (e.g. process not running or write error).
        case failed
    }

    enum ControllerError: Error, LocalizedError {
        case processNotRunning
        case initializationFailed(String)
        case invalidControlResponse(String)
        case inputWriteFailed(String)
        case controlRequestTimedOut(requestID: String)
        case liveModelSwitchRequiresRestart

        var errorDescription: String? {
            switch self {
            case .processNotRunning:
                "Claude process is not running."
            case let .initializationFailed(message):
                "Claude initialization failed: \(message)"
            case let .invalidControlResponse(message):
                "Claude control response failed: \(message)"
            case let .inputWriteFailed(message):
                "Failed writing to Claude process stdin: \(message)"
            case let .controlRequestTimedOut(requestID):
                "Claude control request timed out: \(requestID)"
            case .liveModelSwitchRequiresRestart:
                "Changing to the selected model requires restarting Claude because its launch environment changes."
            }
        }
    }

    private struct PendingPermissionRequest {
        let requestID: String
        let request: [String: Any]
    }

    private struct LaunchEnvironmentSignature: Equatable {
        let environmentOverrides: [String: String]
        let removedEnvironmentKeys: Set<String>
        let backend: ClaudeCodeLaunchEnvironment.Backend

        init(_ launchEnvironment: ClaudeCodeLaunchEnvironment) {
            environmentOverrides = launchEnvironment.environmentOverrides
            removedEnvironmentKeys = launchEnvironment.removedEnvironmentKeys
            backend = launchEnvironment.backend
        }
    }

    private let runID: UUID
    private let tabID: UUID
    private let windowID: Int
    private let workspacePath: String?
    private let config: ClaudeCodeAgentConfig
    private let environmentResolver: any ClaudeCodeLaunchEnvironmentResolving
    private let configService = MCPConfigExportService.shared
    private let rawEventFileLoggingEnabled: Bool
    private var rawEventLogFileURL: URL?
    private var rawEventLogFileSessionID: String?
    private var hasWrittenRawEventLogHeader = false

    private var process: SpawnedProcess?
    private var registeredExpectedAgentPID: pid_t?
    private var stdoutFramer = LineFramer()
    private var stderrTail = Data()
    private var stdoutChunkChannel: FileHandleChunkChannel?
    private var stderrChunkChannel: FileHandleChunkChannel?
    private var stdoutConsumerTask: Task<Void, Never>?
    private var stderrConsumerTask: Task<Void, Never>?
    private var configLease: MCPConfigLease?
    private var configURL: URL? {
        configLease?.url
    }

    private var initialFlagSettingsRequest: [String: Any]?
    private var latestFlagSettingsIntentGeneration: UInt64 = 0
    private var activeLaunchEnvironmentSignature: LaunchEnvironmentSignature?
    private var flagSettingsRequestGeneration: UInt64 = 0
    private var hasCompletedInitialFlagSettings = false
    private var isInitialized = false
    private var isShuttingDown = false
    private var nextControlRequestID = 1
    private var pendingControlRequests: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var pendingControlRequestTimeoutTasks: [String: Task<Void, Never>] = [:]
    private var pendingPermissionRequests: [String: PendingPermissionRequest] = [:]
    private var translator: ClaudeSDKNDJSONTranslator
    private var sessionID: String?
    private var turnInFlight: Bool {
        pendingTurnIDHead < pendingTurnIDBuffer.count
    }

    /// FIFO queue of turn IDs (head-pointer deque to avoid O(n) removeFirst).
    private var pendingTurnIDBuffer: ContiguousArray<UUID> = []
    private var pendingTurnIDHead: Int = 0
    private var turnWasInterrupted = false

    // MARK: - Authoritative lifecycle (session_state_changed)

    /// True once the provider has emitted at least one `session_state_changed` event in this
    /// controller's lifetime.  When true, turn completion defers until `idle` (or a fallback
    /// timeout) rather than completing immediately on `result/message_stop`.
    private var observedSessionStateChangedEvents = false

    /// FIFO queue of result-derived turn statuses waiting for an `idle` signal.
    /// Turn IDs remain in `pendingTurnIDBuffer` until the deferred completion fires
    /// so that `turnInFlight` stays true during the result→idle window.
    private var pendingAuthoritativeTurnStatuses: [TurnStatus] = []

    /// Fallback task that fires when `idle` does not arrive within the expected window.
    private var authoritativeIdleFallbackTask: Task<Void, Never>?

    /// Generation token for the active fallback task. Stale tasks compare their token
    /// against this and no-op if they don't match (prevents race between cancel + reschedule).
    private var authoritativeIdleFallbackGeneration: UInt64 = 0

    /// Timeout before falling back to completing a turn without `idle`.
    private let authoritativeTurnIdleFallbackSeconds: TimeInterval

    // MARK: - Runtime init aggregation

    /// Parsed initialize response snapshot, stored after `initializeIfNeeded` succeeds.
    private var initializeResponseSnapshot: RuntimeInitStatus.InitializeResponseSnapshot?

    /// Tools list from the most recent `system/init` stream payload.
    private var latestRuntimeInitTools: [String] = []

    /// MCP server statuses from the most recent `system/init` stream payload.
    private var latestRuntimeInitMcpServerStatuses: [String: String] = [:]

    /// The last emitted runtime init status, used to deduplicate emissions.
    private var lastEmittedRuntimeInitStatus: RuntimeInitStatus?

    #if DEBUG
        private var decodeSkippedWarningCount = 0
    #endif

    private var eventsContinuation: AsyncStream<Event>.Continuation?
    private var eventsStream: AsyncStream<Event>
    var events: AsyncStream<Event> {
        eventsStream
    }

    var hasActiveSession: Bool {
        process != nil
    }

    deinit {
        performSynchronousDeinitCleanup()
    }

    /// Last-resort process cleanup for controller deallocation.
    ///
    /// Normal owners must call async `shutdown()`, which can reap the process and
    /// clear expected PID registrations. `deinit` cannot await that path, so this
    /// method releases file-handle callbacks, closes stdin, sends SIGTERM to any
    /// still-owned child process, and schedules expected-PID cleanup on the MCP actor.
    ///
    /// The non-blocking `waitpid(WNOHANG)` here will usually return before the
    /// child exits, leaving a zombie. A detached `Task` is scheduled to reap the
    /// process asynchronously via `ProcessTermination.terminateAndReap`, which
    /// sends a follow-up SIGTERM (harmless if the child already exited) and
    /// waits for exit so the zombie is collected.
    private func performSynchronousDeinitCleanup() {
        closeOutputChannelsAndInput()

        if let process {
            let pid = process.pid
            _ = Darwin.kill(pid, SIGTERM)
            var status: Int32 = 0
            _ = Darwin.waitpid(pid, &status, WNOHANG)
            // Schedule an async reap so the child is collected even if the
            // non-blocking waitpid above did not reap it. The detached task is
            // cancellation-shielded by design — the actor is already gone.
            Task.detached(priority: .utility) {
                _ = await ProcessTermination.terminateAndReap(pid: pid)
            }
        }

        scheduleExpectedAgentPIDDeinitClearIfNeeded()
    }

    private func closeOutputChannelsAndInput() {
        stdoutChunkChannel?.finish()
        stderrChunkChannel?.finish()
        stdoutConsumerTask?.cancel()
        stderrConsumerTask?.cancel()

        stdoutChunkChannel = nil
        stderrChunkChannel = nil
        stdoutConsumerTask = nil
        stderrConsumerTask = nil

        if let process {
            process.stdout.readabilityHandler = nil
            process.stderr.readabilityHandler = nil
            process.stdin?.closeFile()
        }
    }

    /// Clears MCP expected-agent PID registration when async `shutdown()` did not run.
    private func scheduleExpectedAgentPIDDeinitClearIfNeeded() {
        guard config.toolContext == .agentRun,
              let registeredExpectedAgentPID,
              let clientName = config.runtimeVariant.agentKind.mcpClientNameHint
        else {
            return
        }
        let pid = registeredExpectedAgentPID
        let runID = runID
        Task {
            await ServerNetworkManager.shared.clearExpectedAgentPID(pid, for: clientName, runID: runID)
        }
    }

    var hasTurnInFlight: Bool {
        pendingTurnIDHead < pendingTurnIDBuffer.count
    }

    #if DEBUG
        private func reasoningDebug(_ message: @autoclosure () -> String) {
            guard ClaudeReasoningExtractionFeature.isEnabled else { return }
            let line = "[ClaudeReasoningDebug][Controller] run=\(runID.uuidString) tab=\(tabID.uuidString) \(message())"
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
        runID: UUID,
        tabID: UUID,
        windowID: Int,
        workspacePath: String?,
        config: ClaudeCodeAgentConfig,
        environmentResolver: any ClaudeCodeLaunchEnvironmentResolving = ClaudeCodeLaunchEnvironmentResolver(),
        authoritativeTurnIdleFallbackSeconds: TimeInterval = 1.0
    ) {
        self.runID = runID
        self.tabID = tabID
        self.windowID = windowID
        self.workspacePath = workspacePath
        self.config = config
        self.environmentResolver = environmentResolver
        self.authoritativeTurnIdleFallbackSeconds = authoritativeTurnIdleFallbackSeconds
        rawEventFileLoggingEnabled = Self.isRawEventFileLoggingEnabled()
        rawEventLogFileURL = nil
        rawEventLogFileSessionID = nil
        translator = ClaudeSDKNDJSONTranslator(enableDebugLogging: config.enableDebugLogging)
        let stream = Self.makeEventsStream()
        eventsStream = stream.stream
        eventsContinuation = stream.continuation
    }

    func ensureEventsStreamReady() {
        guard eventsContinuation == nil else { return }
        let stream = Self.makeEventsStream()
        eventsStream = stream.stream
        eventsContinuation = stream.continuation
    }

    /// Finish the old events stream and create a fresh one.  Call this when starting a new
    /// run after a previous run was cancelled, to discard any buffered stale events and to
    /// avoid reusing an AsyncStream whose iterator may have been poisoned by task cancellation.
    func resetEventsStreamForNewRun() {
        eventsContinuation?.finish()
        eventsContinuation = nil
        let stream = Self.makeEventsStream()
        eventsStream = stream.stream
        eventsContinuation = stream.continuation
    }

    func startOrResume(
        existingSessionID: String?,
        model: String?,
        effortLevel: ClaudeCodeEffortLevel? = nil,
        systemPromptOverride: String? = nil
    ) async throws -> SessionRef {
        if process != nil, isInitialized {
            return SessionRef(sessionID: sessionID)
        }

        ensureEventsStreamReady()
        isShuttingDown = false
        ensureRawEventLogFileReadyIfNeeded(sessionIDHint: existingSessionID ?? sessionID)
        writeRawEventLogRecord(
            kind: "session.startOrResume",
            payload: [
                "existingSessionID": existingSessionID ?? NSNull(),
                "model": model ?? NSNull(),
                "effortLevel": effortLevel?.rawValue ?? NSNull(),
                "hasSystemPromptOverride": systemPromptOverride != nil
            ] as [String: Any]
        )
        do {
            try await prepareRuntimeIfNeeded()
            try await startProcessIfNeeded(existingSessionID: existingSessionID, model: model, effortLevel: effortLevel)
            try await initializeIfNeeded(systemPromptOverride: systemPromptOverride)
            return SessionRef(sessionID: sessionID)
        } catch {
            if process != nil || configURL != nil {
                await shutdown()
            }
            throw error
        }
    }

    func currentSessionRef() async -> SessionRef {
        SessionRef(sessionID: sessionID)
    }

    func applyModelAndEffort(model: String?, effortLevel: ClaudeCodeEffortLevel?) async throws {
        guard process != nil else { return }

        latestFlagSettingsIntentGeneration &+= 1
        let intentGeneration = latestFlagSettingsIntentGeneration
        let resolved = try await resolveLaunchFlagSettings(model: model, effortLevel: effortLevel)
        guard intentGeneration == latestFlagSettingsIntentGeneration else { return }
        if liveFlagSettingsRequiresProcessRestart(for: resolved.launchEnvironment) {
            writeRawEventLogRecord(kind: "session.flagSettingsDeferred", payload: [
                "reason": "launch_environment_changed",
                "model": model ?? NSNull()
            ] as [String: Any])
            throw ControllerError.liveModelSwitchRequiresRestart
        }
        storeFlagSettingsRequest(resolved.request)

        guard process != nil else { return }
        guard isInitialized || hasCompletedInitialFlagSettings else {
            writeRawEventLogRecord(kind: "session.flagSettingsPending", payload: [
                "settings": resolved.request?["settings"] ?? NSNull()
            ] as [String: Any])
            return
        }
        guard let request = resolved.request else { return }

        let flagSettingsResult = try await sendControlRequest(request: request, timeoutSeconds: 5.0)
        writeRawEventLogRecord(kind: "session.flagSettingsApplied", payload: [
            "settings": request["settings"] ?? NSNull(),
            "response": flagSettingsResult,
            "source": "live_update"
        ] as [String: Any])
    }

    @discardableResult
    func sendUserMessage(_ text: String) async throws -> UUID {
        guard process != nil else {
            throw ControllerError.processNotRunning
        }
        let payload = try ClaudeSDKProtocolCodec.encodeUserMessage(text: text, sessionID: sessionID)
        try sendLine(payload)
        return beginTurnTracking()
    }

    func interruptTurn(reason: String) async -> InterruptOutcome {
        guard process != nil else { return .failed }
        guard turnInFlight else { return .noTurnInFlight }
        do {
            // Wait for interrupt control-response ACK to confirm Claude received the interrupt.
            _ = try await sendControlRequest(
                request: ["subtype": "interrupt", "reason": reason],
                timeoutSeconds: 1.5
            )
            turnWasInterrupted = true
            writeRawEventLogRecord(kind: "turn.interrupted", payload: [
                "reason": reason
            ] as [String: Any])
            return .acknowledged
        } catch let controllerError as ControllerError {
            if case .controlRequestTimedOut = controllerError {
                writeRawEventLogRecord(kind: "turn.interrupt.timedOut", payload: [
                    "reason": reason
                ] as [String: Any])
                return .timedOut
            }
            writeRawEventLogRecord(kind: "turn.interrupt.failed", payload: [
                "reason": reason,
                "error": controllerError.localizedDescription
            ] as [String: Any])
            return .failed
        } catch {
            writeRawEventLogRecord(kind: "turn.interrupt.failed", payload: [
                "reason": reason,
                "error": error.localizedDescription
            ] as [String: Any])
            return .failed
        }
    }

    func respondToPermissionRequest(id: String, decision: AgentApprovalDecision) async {
        guard let pending = pendingPermissionRequests.removeValue(forKey: id) else {
            return
        }
        do {
            let response = permissionResponsePayload(decision: decision, pendingRequest: pending.request)
            writeRawEventLogRecord(kind: "approval.response.sent", payload: [
                "requestID": id,
                "decision": String(describing: decision),
                "response": response
            ] as [String: Any])
            let encoded = try ClaudeSDKProtocolCodec.encodeControlResponseSuccess(
                requestID: id,
                response: response
            )
            try sendLine(encoded, shutdownOnFailure: false)
        } catch {
            await failProtocolAndShutdown(
                message: "Failed to submit Claude approval decision: \(error.localizedDescription)"
            )
        }
    }

    func shutdown() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        writeRawEventLogRecord(kind: "session.shutdown")

        failPendingControlRequests(with: ControllerError.processNotRunning)
        pendingPermissionRequests.removeAll()
        clearTurnIDQueue()
        cancelAuthoritativeLifecycleState()

        closeOutputChannelsAndInput()

        if let process {
            let pid = process.pid
            _ = await ProcessTermination.terminateAndReap(
                pid: pid,
                logger: config.enableDebugLogging ? { print("[ClaudeNativeSession] \($0)") } : { _ in }
            )
        }
        await clearExpectedAgentPIDIfNeeded()
        process = nil
        activeLaunchEnvironmentSignature = nil
        isInitialized = false
        hasCompletedInitialFlagSettings = false
        stdoutFramer = LineFramer()

        if let configLease {
            configLease.release()
            self.configLease = nil
        }
        rawEventLogFileURL = nil
        rawEventLogFileSessionID = nil
        hasWrittenRawEventLogHeader = false
        finishEventsStreamIfNeeded()
    }

    private func prepareRuntimeIfNeeded() async throws {
        if configURL != nil {
            return
        }

        let isRunning = await ServerNetworkManager.shared.isRunning()
        guard isRunning else {
            throw AIProviderError.invalidConfiguration(detail: "Could not start MCP server. Check MCP settings and try again.")
        }
        configLease = try await configService.prepareLaunchConfig()
    }

    private func startProcessIfNeeded(
        existingSessionID: String?,
        model: String?,
        effortLevel: ClaudeCodeEffortLevel?
    ) async throws {
        guard process == nil else { return }

        latestFlagSettingsIntentGeneration = 0
        flagSettingsRequestGeneration = 0
        hasCompletedInitialFlagSettings = false

        let resolvedFlags = try await resolveLaunchFlagSettings(model: model, effortLevel: effortLevel)
        let launchEnvironment = resolvedFlags.launchEnvironment
        let environment = await resolvedLaunchEnvironment(
            resolverOverrides: launchEnvironment.environmentOverrides,
            resolverRemovedKeys: launchEnvironment.removedEnvironmentKeys
        )
        let resolvedCommand = CommandPathResolver.resolve(
            config.commandName,
            environment: environment,
            additionalPaths: CLIPathHints.nativeDefaultsSupplemented(with: config.additionalPathHints),
            logger: config.enableDebugLogging ? { print("[ClaudeNativeSession] \($0)") } : nil,
            preferredBasenames: [config.commandName]
        )
        storeFlagSettingsRequest(resolvedFlags.request)
        activeLaunchEnvironmentSignature = LaunchEnvironmentSignature(launchEnvironment)
        let arguments = buildArguments(
            existingSessionID: existingSessionID,
            model: nil
        )

        let workingDirectory = resolvedWorkingDirectory()
        let spawned = try ProcessLauncher.spawn(
            command: resolvedCommand,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory
        )
        writeRawEventLogRecord(
            kind: "process.spawned",
            payload: [
                "command": resolvedCommand,
                "arguments": arguments,
                "workingDirectory": workingDirectory
            ] as [String: Any]
        )
        stdoutFramer = LineFramer()
        stderrTail.removeAll(keepingCapacity: false)
        // Reset authoritative lifecycle state for the new transport instance so we
        // don't inherit the previous process's capability negotiation.
        observedSessionStateChangedEvents = false
        cancelAuthoritativeLifecycleState()
        // Reset runtime init aggregation state so stale metadata doesn't leak across runs.
        initializeResponseSnapshot = nil
        latestRuntimeInitTools = []
        latestRuntimeInitMcpServerStatuses = [:]
        lastEmittedRuntimeInitStatus = nil
        process = spawned
        do {
            try startStdoutReader(handle: spawned.stdout)
            try startStderrReader(handle: spawned.stderr)
        } catch {
            spawned.stdout.readabilityHandler = nil
            spawned.stderr.readabilityHandler = nil
            spawned.stdin?.closeFile()
            process = nil
            _ = await ProcessTermination.terminateAndReap(
                pid: spawned.pid,
                logger: config.enableDebugLogging ? { print("[ClaudeNativeSession] \($0)") } : { _ in }
            )
            throw ControllerError.initializationFailed("Failed to start Claude process readers: \(error.localizedDescription)")
        }
        await registerExpectedAgentPIDIfNeeded(spawned.pid)
    }

    private func initializeIfNeeded(systemPromptOverride: String?) async throws {
        guard !isInitialized else { return }

        let request = Self.buildInitializeRequest(systemPromptOverride: systemPromptOverride)

        let initializeResult = try await sendControlRequest(request: request)
        if let returnedSessionID = (initializeResult["session_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !returnedSessionID.isEmpty
        {
            recordObservedSessionID(returnedSessionID)
        }

        let snapshot = Self.parseInitializeResponseSnapshot(from: initializeResult)
        initializeResponseSnapshot = snapshot

        if config.enableDebugLogging {
            print("[ClaudeNativeSession] initialize response keys: \(initializeResult.keys.sorted())")
            if let account = snapshot.account {
                print("[ClaudeNativeSession] account: \(account.email ?? "none"), org: \(account.organization ?? "none"), sub: \(account.subscriptionType ?? "none")")
            }
        }
        writeRawEventLogRecord(kind: "session.initialized", payload: initializeResult)
        try await applyInitialFlagSettingsIfNeeded()
        try await applyInitialPermissionModeIfNeeded()
        isInitialized = true

        publishRuntimeInitIfChanged()
    }

    private func resolveLaunchFlagSettings(
        model: String?,
        effortLevel suppliedEffortLevel: ClaudeCodeEffortLevel?
    ) async throws -> (launchEnvironment: ClaudeCodeLaunchEnvironment, request: [String: Any]?) {
        let modelSpecifier = model.map { ClaudeModelSpecifier(raw: $0) }
        let requestedModel = modelSpecifier != nil
            ? model
            : config.modelString
        let effectiveEffortLevel = modelSpecifier?.explicitEffortLevel
            ?? suppliedEffortLevel
            ?? config.effortLevel
        let launchEnvironment = try await environmentResolver.resolve(
            variant: config.runtimeVariant,
            requestedModel: requestedModel
        )
        let requestEffortLevel = Self.shouldSuppressEffortSettings(for: launchEnvironment)
            ? nil
            : effectiveEffortLevel
        let request = Self.buildApplyFlagSettingsRequest(
            model: launchEnvironment.effectiveModel,
            effortLevel: requestEffortLevel
        )
        return (launchEnvironment, request)
    }

    private func liveFlagSettingsRequiresProcessRestart(for launchEnvironment: ClaudeCodeLaunchEnvironment) -> Bool {
        guard let activeLaunchEnvironmentSignature else {
            return false
        }
        return activeLaunchEnvironmentSignature != LaunchEnvironmentSignature(launchEnvironment)
    }

    private func storeFlagSettingsRequest(_ request: [String: Any]?) {
        flagSettingsRequestGeneration &+= 1
        initialFlagSettingsRequest = request
    }

    private func applyInitialFlagSettingsIfNeeded() async throws {
        while true {
            let requestGeneration = flagSettingsRequestGeneration
            guard let request = initialFlagSettingsRequest else {
                hasCompletedInitialFlagSettings = true
                return
            }
            let flagSettingsResult = try await sendControlRequest(request: request)
            writeRawEventLogRecord(kind: "session.flagSettingsApplied", payload: [
                "settings": request["settings"] ?? NSNull(),
                "response": flagSettingsResult
            ] as [String: Any])
            guard flagSettingsRequestGeneration != requestGeneration else {
                hasCompletedInitialFlagSettings = true
                return
            }
        }
    }

    private func applyInitialPermissionModeIfNeeded() async throws {
        guard let request = Self.buildSetPermissionModeRequest(permissionMode: config.permissionMode) else { return }
        let permissionModeResult = try await sendControlRequest(request: request)
        writeRawEventLogRecord(kind: "session.permissionModeInitialized", payload: [
            "requestedMode": request["mode"] ?? NSNull(),
            "response": permissionModeResult
        ] as [String: Any])
    }

    private static func buildInitializeRequest(systemPromptOverride: String?) -> [String: Any] {
        var request: [String: Any] = ["subtype": "initialize"]
        if let systemPromptOverride {
            request["systemPrompt"] = systemPromptOverride
        }
        return request
    }

    private static func shouldSuppressEffortSettings(for launchEnvironment: ClaudeCodeLaunchEnvironment) -> Bool {
        launchEnvironment.suppressesEffortSettings
    }

    private static func buildApplyFlagSettingsRequest(model: String?, effortLevel: ClaudeCodeEffortLevel?) -> [String: Any]? {
        var settings: [String: Any] = [:]
        if let model = normalizedFlagSettingsModel(model) {
            settings["model"] = model
        }
        if let effortLevel {
            settings["effortLevel"] = effortLevel.rawValue
        }
        guard !settings.isEmpty else { return nil }
        return [
            "subtype": "apply_flag_settings",
            "settings": settings
        ]
    }

    private static func normalizedFlagSettingsModel(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame else { return nil }
        return trimmed
    }

    private static func buildSetPermissionModeRequest(permissionMode: String) -> [String: Any]? {
        let trimmed = permissionMode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return [
            "subtype": "set_permission_mode",
            "mode": trimmed
        ]
    }

    private func sendControlRequest(
        request: [String: Any],
        timeoutSeconds: TimeInterval? = nil
    ) async throws -> [String: Any] {
        guard process != nil else {
            throw ControllerError.processNotRunning
        }
        let requestID = makeControlRequestID()
        let payload = try ClaudeSDKProtocolCodec.encodeControlRequest(requestID: requestID, request: request)
        writeRawEventLogRecord(
            kind: "control.request.sent",
            payload: [
                "requestID": requestID,
                "request": request,
                "expectsResponse": true
            ] as [String: Any]
        )
        // Register the continuation and optional timeout BEFORE writing to stdin.
        // This avoids a race where Claude replies before the continuation is stored,
        // which would silently lose the ACK.
        return try await withCheckedThrowingContinuation { continuation in
            pendingControlRequests[requestID] = continuation
            if let timeoutSeconds, timeoutSeconds > 0 {
                let timeoutNanos = UInt64(timeoutSeconds * 1_000_000_000)
                pendingControlRequestTimeoutTasks[requestID] = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: timeoutNanos)
                        await self?.handleControlRequestTimeout(requestID: requestID)
                    } catch {
                        return
                    }
                }
            }
            do {
                try sendLine(payload)
            } catch {
                // Writing failed — clean up the continuation and timeout, then resume with error.
                pendingControlRequests.removeValue(forKey: requestID)
                pendingControlRequestTimeoutTasks[requestID]?.cancel()
                pendingControlRequestTimeoutTasks.removeValue(forKey: requestID)
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendControlRequestWithoutResponse(request: [String: Any]) throws {
        guard process != nil else {
            throw ControllerError.processNotRunning
        }
        let requestID = makeControlRequestID()
        let payload = try ClaudeSDKProtocolCodec.encodeControlRequest(requestID: requestID, request: request)
        writeRawEventLogRecord(
            kind: "control.request.sent",
            payload: [
                "requestID": requestID,
                "request": request,
                "expectsResponse": false
            ] as [String: Any]
        )
        try sendLine(payload)
    }

    private func sendLine(_ lineData: Data, shutdownOnFailure: Bool = true) throws {
        guard let process else {
            throw ControllerError.processNotRunning
        }
        writeRawEventLogRecord(kind: "protocol.outbound.raw", payload: lineRecordPayload(from: lineData))
        do {
            // Combine JSON body and newline into a single write to ensure atomic
            // delivery to the CLI's stdin pipe. Two separate writes could theoretically
            // be split if the pipe reader consumes data between them.
            var frame = lineData
            frame.append(0x0A)
            try process.stdin?.write(contentsOf: frame)
        } catch {
            // Stdin is broken — the process is dead or dying. Schedule teardown so the
            // child process doesn't linger (mirrors Codex's terminateTransport behavior).
            // shutdown() is idempotent (guards on isShuttingDown).  Control-response
            // callers can disable this so they can emit failed turn completion before
            // shutdown clears the active MCP-controlled turn context.
            if shutdownOnFailure {
                Task { await self.shutdown() }
            }
            throw ControllerError.inputWriteFailed(error.localizedDescription)
        }
    }

    private func startStdoutReader(handle: FileHandle) throws {
        try ReadSourceFDPreflight.validateOpenFD(handle.fileDescriptor, label: "Claude stdout")
        let channel = FileHandleChunkChannel()
        stdoutChunkChannel = channel
        handle.readabilityHandler = { readable in
            let data = readable.availableData
            if data.isEmpty {
                channel.finish()
                readable.readabilityHandler = nil
            } else {
                channel.yield(data)
            }
        }
        stdoutConsumerTask = Task { [weak self] in
            for await chunk in channel.stream {
                guard let self else { break }
                await handleStdoutChunk(chunk)
            }
            // Stream ended (EOF or finish() called)
            guard let self else { return }
            await handleStdoutEOF()
        }
    }

    private func startStderrReader(handle: FileHandle) throws {
        try ReadSourceFDPreflight.validateOpenFD(handle.fileDescriptor, label: "Claude stderr")
        let channel = FileHandleChunkChannel()
        stderrChunkChannel = channel
        handle.readabilityHandler = { readable in
            let data = readable.availableData
            if data.isEmpty {
                channel.finish()
                readable.readabilityHandler = nil
            } else {
                channel.yield(data)
            }
        }
        stderrConsumerTask = Task { [weak self] in
            for await chunk in channel.stream {
                guard let self else { break }
                await handleStderrChunk(chunk)
            }
        }
    }

    private func handleStderrChunk(_ data: Data) {
        appendTail(&stderrTail, chunk: data, limit: 256 * 1024)
        writeRawEventLogRecord(kind: "process.stderr", payload: lineRecordPayload(from: data))
        if config.enableDebugLogging,
           let text = String(data: data, encoding: .utf8),
           !text.isEmpty
        {
            print("[ClaudeNativeSession][stderr] \(text)")
        }
    }

    private func handleStdoutChunk(_ data: Data) async {
        var lines: [Data] = []
        stdoutFramer.feed(data, onDiagnostic: { [self] diagnostic in
            switch diagnostic {
            case let .overflow(droppedBytes, retainedBytes):
                writeRawEventLogRecord(kind: "framer.overflow", payload: [
                    "droppedBytes": droppedBytes,
                    "retainedBytes": retainedBytes
                ] as [String: Any])
                if config.enableDebugLogging {
                    print("[ClaudeNativeSession] LineFramer overflow: dropped \(droppedBytes) bytes, retained \(retainedBytes) bytes")
                }
            case .nonJSONCandidateQuoteStateReset:
                writeRawEventLogRecord(kind: "framer.nonJSONCandidateReset")
            }
        }) { line in
            lines.append(line)
        }
        for line in lines {
            await handleLine(line)
        }
    }

    private func handleLine(_ lineData: Data) async {
        writeRawEventLogRecord(kind: "protocol.inbound.raw", payload: lineRecordPayload(from: lineData))
        do {
            guard let inbound = try ClaudeSDKProtocolCodec.decodeLine(lineData) else { return }
            routeInboundMessage(inbound)
        } catch let codecError as ClaudeSDKProtocolCodec.CodecError {
            if case .invalidJSON = codecError {
                if recoverConcatenatedInboundMessagesIfNeeded(from: lineData)
                    || recoverEmbeddedInboundTailIfNeeded(from: lineData)
                    || recoverInvalidJSONStringControlCharsIfNeeded(from: lineData)
                    || recoverPlaintextAssistantDeltaIfNeeded(from: lineData)
                {
                    return
                }
            }
            let preview = String(data: lineData.prefix(512), encoding: .utf8) ?? "<non-utf8>"
            writeRawEventLogRecord(kind: "protocol.decode.skipped", payload: [
                "preview": preview,
                "codecError": String(describing: codecError)
            ])
            emitDebugDecodeSkippedNotice(codecError: codecError, preview: preview)
            if config.enableDebugLogging {
                print("[ClaudeNativeSession] skipping undecodable protocol line: \(preview) | codecError=\(codecError)")
            }
            // Be tolerant of malformed/non-JSON protocol lines so one bad payload
            // doesn't kill an otherwise healthy Claude run.
            return
        } catch {
            let preview = String(data: lineData.prefix(512), encoding: .utf8) ?? "<non-utf8>"
            writeRawEventLogRecord(kind: "protocol.decode.failed", payload: [
                "preview": preview,
                "error": error.localizedDescription
            ])
            if config.enableDebugLogging {
                print("[ClaudeNativeSession] failed decoding line: \(preview) | error=\(error)")
            }
            await failProtocolAndShutdown(message: "Claude protocol decode failure: \(preview)")
        }
    }

    private func routeInboundMessage(_ inbound: ClaudeSDKProtocolCodec.InboundMessage) {
        switch inbound {
        case let .streamPayload(payload):
            writeRawEventLogRecord(kind: "protocol.inbound.streamPayload", payload: payload)
            handleStreamPayload(payload)
        case let .controlRequest(request):
            writeRawEventLogRecord(kind: "protocol.inbound.controlRequest", payload: [
                "requestID": request.requestID,
                "subtype": request.subtype,
                "request": request.request
            ] as [String: Any])
            handleControlRequest(request)
        case let .controlResponse(response):
            writeRawEventLogRecord(kind: "protocol.inbound.controlResponse", payload: [
                "requestID": response.requestID,
                "subtype": response.subtype,
                "response": response.response ?? NSNull(),
                "error": response.error ?? NSNull(),
                "pendingPermissionRequestsCount": response.pendingPermissionRequests.count
            ] as [String: Any])
            handleControlResponse(response)
        case let .controlCancelRequest(requestID):
            writeRawEventLogRecord(kind: "protocol.inbound.controlCancelRequest", payload: ["requestID": requestID])
            handleControlCancelRequest(requestID: requestID)
        case .keepAlive:
            writeRawEventLogRecord(kind: "protocol.inbound.keepAlive")
        }
    }

    /// Maximum line size (in bytes) for which we attempt concatenated-segment recovery.
    /// Beyond this threshold the String conversion + brace-depth scan is too expensive.
    private static let maxConcatenatedRecoveryBytes = 2 * 1024 * 1024 // 2 MB

    private func recoverConcatenatedInboundMessagesIfNeeded(from lineData: Data) -> Bool {
        // Skip expensive String conversion + brace-depth scan for very large payloads.
        guard lineData.count <= Self.maxConcatenatedRecoveryBytes else {
            writeRawEventLogRecord(kind: "protocol.decode.concatenatedRecoverySkipped", payload: [
                "byteCount": lineData.count,
                "threshold": Self.maxConcatenatedRecoveryBytes
            ])
            return false
        }
        let segments = Self.splitConcatenatedJSONObjectPayloads(lineData)
        guard segments.count > 1 else { return false }

        var recoveredCount = 0
        for segment in segments {
            do {
                guard let inbound = try ClaudeSDKProtocolCodec.decodeLine(segment) else { continue }
                recoveredCount += 1
                writeRawEventLogRecord(kind: "protocol.inbound.recoveredSegment", payload: lineRecordPayload(from: segment))
                routeInboundMessage(inbound)
            } catch {
                let preview = String(data: segment.prefix(256), encoding: .utf8) ?? "<non-utf8>"
                writeRawEventLogRecord(kind: "protocol.decode.recoveredSegmentSkipped", payload: [
                    "preview": preview,
                    "error": error.localizedDescription
                ])
            }
        }

        if recoveredCount > 0 {
            writeRawEventLogRecord(kind: "protocol.decode.recovered", payload: [
                "segments": segments.count,
                "recoveredSegments": recoveredCount
            ])
            return true
        }
        return false
    }

    /// Maximum number of trailing bytes to scan when attempting tail recovery.
    /// Prevents huge String allocations for multi-megabyte corrupted lines.
    private static let maxTailRecoveryScanBytes = 256 * 1024 // 256 KB

    private func recoverEmbeddedInboundTailIfNeeded(from lineData: Data) -> Bool {
        guard !lineData.isEmpty else { return false }

        // Only scan the last N bytes to limit worst-case cost.
        let scanWindow: Data
        let scanOffset: Int
        if lineData.count > Self.maxTailRecoveryScanBytes {
            scanOffset = lineData.count - Self.maxTailRecoveryScanBytes
            scanWindow = lineData.suffix(Self.maxTailRecoveryScanBytes)
        } else {
            scanOffset = 0
            scanWindow = lineData
        }

        // Search for the marker bytes in Data directly (avoid converting the entire payload to String).
        let markerOffsets = Self.jsonObjectStartOffsetsInData(scanWindow)
        guard !markerOffsets.isEmpty else { return false }

        // Skip the first offset if it points to the very start of the original lineData
        // (that's the same parse that already failed upstream).
        let candidateOffsets: [Int] = if markerOffsets.first == 0, scanOffset == 0 {
            Array(markerOffsets.dropFirst())
        } else {
            markerOffsets
        }
        guard !candidateOffsets.isEmpty else { return false }

        // Try candidates from the end (prefer the rightmost / latest embedded JSON).
        for offset in candidateOffsets.reversed() {
            let absoluteOffset = scanOffset + offset
            let suffixData = lineData.suffix(from: lineData.startIndex + absoluteOffset)
            do {
                guard let inbound = try ClaudeSDKProtocolCodec.decodeLine(suffixData) else { continue }
                let preview = makeUTF8Sample(from: suffixData, limit: 180)?.0 ?? "<non-utf8>"
                writeRawEventLogRecord(kind: "protocol.inbound.recoveredTail", payload: [
                    "startOffset": absoluteOffset,
                    "byteCount": suffixData.count,
                    "preview": preview
                ])
                routeInboundMessage(inbound)
                return true
            } catch {
                continue
            }
        }
        return false
    }

    /// Finds byte offsets of the NDJSON marker `{"type":"` in raw Data, without String conversion.
    private static let jsonObjectMarkerBytes: [UInt8] = Array("{\"type\":\"".utf8)

    private static func jsonObjectStartOffsetsInData(_ data: Data) -> [Int] {
        guard data.count >= jsonObjectMarkerBytes.count else { return [] }
        var offsets: [Int] = []
        let markerLength = jsonObjectMarkerBytes.count
        let searchLimit = data.count - markerLength
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0 ... searchLimit {
                var matches = true
                for j in 0 ..< markerLength {
                    if baseAddress[i + j] != jsonObjectMarkerBytes[j] {
                        matches = false
                        break
                    }
                }
                if matches {
                    offsets.append(i)
                }
            }
        }
        return offsets
    }

    private func recoverInvalidJSONStringControlCharsIfNeeded(from lineData: Data) -> Bool {
        guard let repaired = repairJSONStringControlCharacters(lineData) else { return false }
        do {
            guard let inbound = try ClaudeSDKProtocolCodec.decodeLine(repaired) else { return false }
            writeRawEventLogRecord(kind: "protocol.decode.recoveredJSONStringControlChars", payload: lineRecordPayload(from: repaired))
            routeInboundMessage(inbound)
            return true
        } catch {
            return false
        }
    }

    private func recoverPlaintextAssistantDeltaIfNeeded(from lineData: Data) -> Bool {
        guard turnInFlight else { return false }
        guard let text = Self.recoverablePlaintextAssistantFragment(from: lineData) else {
            return false
        }
        writeRawEventLogRecord(kind: "protocol.decode.recoveredPlaintext", payload: [
            "preview": String(text.prefix(200)),
            "length": text.count
        ] as [String: Any])
        emit(.stream(AIStreamResult(type: "content", text: text)))
        return true
    }

    private func emitDebugDecodeSkippedNotice(
        codecError: ClaudeSDKProtocolCodec.CodecError,
        preview: String
    ) {
        #if DEBUG
            decodeSkippedWarningCount += 1
            let compactPreview = preview
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = compactPreview.isEmpty ? "<empty>" : String(compactPreview.prefix(140))
            let warning = "⚠️ DEBUG: Claude skipped undecodable stream line #\(decodeSkippedWarningCount) (\(codecError)): \(snippet)"
            emit(.stream(AIStreamResult(type: "system", text: warning)))
        #endif
    }

    static func recoverablePlaintextAssistantFragment(from lineData: Data) -> String? {
        guard let rawText = String(data: lineData, encoding: .utf8) else {
            return nil
        }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              text.count >= 40,
              !text.contains("\t"),
              !text.hasPrefix("{"),
              !text.hasPrefix("["),
              !text.contains("{\"type\":\"")
        else {
            return nil
        }

        let letters = text.unicodeScalars.reduce(into: 0) { partialResult, scalar in
            if CharacterSet.letters.contains(scalar) {
                partialResult += 1
            }
        }
        guard letters >= 24 else { return nil }

        let longWordCount = text
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .count(where: { $0.count >= 4 })

        guard longWordCount >= 4 else { return nil }

        let braceSymbolCount = text.unicodeScalars.reduce(into: 0) { partialResult, scalar in
            if "{}[];".unicodeScalars.contains(scalar) {
                partialResult += 1
            }
        }
        guard braceSymbolCount <= 8 else { return nil }

        if text.hasPrefix(".") || text.hasPrefix("/") {
            return nil
        }
        return text
    }

    private static func splitConcatenatedJSONObjectPayloads(_ data: Data) -> [Data] {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return [] }
        var results: [Data] = []
        var start: String.Index?
        var depth = 0
        var inString = false
        var escaping = false

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if start == nil {
                if character == "{" {
                    start = index
                    depth = 1
                    inString = false
                    escaping = false
                }
                index = text.index(after: index)
                continue
            }

            if inString {
                if escaping {
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                if character == "\"" {
                    inString = true
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0, let segmentStart = start {
                        let segmentEnd = text.index(after: index)
                        let segment = String(text[segmentStart ..< segmentEnd])
                        if let segmentData = segment.data(using: .utf8), !segmentData.isEmpty {
                            results.append(segmentData)
                        }
                        start = nil
                    }
                }
            }
            index = text.index(after: index)
        }
        return results
    }

    private func handleStreamPayload(_ payload: [String: Any]) {
        recordObservedSessionID(Self.firstSessionIdentifier(in: payload))
        #if DEBUG
            if ClaudeReasoningExtractionFeature.isEnabled {
                let debugPayloadType = (payload["type"] as? String) ?? "<missing>"
                if debugPayloadType == "stream_event" || debugPayloadType == "assistant" || debugPayloadType == "message" || debugPayloadType == "result" {
                    let event = payload["event"] as? [String: Any]
                    let eventType = event?["type"] as? String
                    let delta = event?["delta"] as? [String: Any]
                    let deltaType = delta?["type"] as? String
                    reasoningDebug("payload type=\(debugPayloadType) eventType=\(eventType ?? "nil") deltaType=\(deltaType ?? "nil") keys=\(payload.keys.sorted())")
                }
            }
        #endif
        if let (tools, mcpStatuses) = Self.parseSystemInitFields(from: payload) {
            latestRuntimeInitTools = tools
            latestRuntimeInitMcpServerStatuses = mcpStatuses
            writeRawEventLogRecord(kind: "runtime.init.stream", payload: [
                "sessionID": sessionID ?? "",
                "tools": tools,
                "mcpServerStatuses": mcpStatuses
            ] as [String: Any])
            publishRuntimeInitIfChanged()
        }

        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return
        }
        let streamResults = translator.parseNDJSONLine(data)
        #if DEBUG
            if ClaudeReasoningExtractionFeature.isEnabled {
                let debugPayloadType = (payload["type"] as? String) ?? "<missing>"
                if streamResults.isEmpty {
                    let event = payload["event"] as? [String: Any]
                    let eventType = event?["type"] as? String
                    let delta = event?["delta"] as? [String: Any]
                    let deltaType = delta?["type"] as? String
                    if debugPayloadType == "stream_event" || deltaType?.contains("thinking") == true {
                        reasoningDebug("translator produced no results for payload type=\(debugPayloadType) eventType=\(eventType ?? "nil") deltaType=\(deltaType ?? "nil") deltaKeys=\(delta?.keys.sorted() ?? [])")
                    }
                } else if streamResults.contains(where: { $0.type == "reasoning" }) {
                    let summaries = streamResults.map { result in
                        "\(result.type):text=\(result.text?.count ?? 0):reasoning=\(result.reasoning?.count ?? 0)"
                    }.joined(separator: ",")
                    reasoningDebug("translator results include reasoning count=\(streamResults.count) summaries=\(summaries)")
                }
            }
        #endif
        if let translatorSessionID = translator.cliSessionID,
           !translatorSessionID.isEmpty
        {
            recordObservedSessionID(translatorSessionID)
        }

        // Only complete a turn when the original payload is a "result" type — the
        // authoritative turn-boundary signal from the SDK.  Forwarded stream events
        // (message_delta with stop_reason, message_stop) can also produce translated
        // "message_stop" results, but they are NOT turn boundaries; using them would
        // cause pendingTurnIDs to desynchronize when multiple message_stop results
        // arrive per turn.
        let payloadType = (payload["type"] as? String) ?? ""
        let isResultPayload = payloadType == "result"

        for result in streamResults {
            #if DEBUG
                if ClaudeReasoningExtractionFeature.isEnabled, result.type == "reasoning" {
                    let text = result.reasoning ?? result.text ?? ""
                    reasoningDebug("emitting reasoning stream result len=\(text.count) snippet=\(reasoningDebugSnippet(text))")
                }
            #endif
            if let providerSessionID = result.providerSessionID,
               !providerSessionID.isEmpty
            {
                recordObservedSessionID(providerSessionID)
            }
            let logPayload = streamResultLogPayload(result)

            // Track session_state_changed events for authoritative lifecycle gating.
            if result.type == "session_state_changed" {
                observedSessionStateChangedEvents = true
                writeRawEventLogRecord(kind: "translator.streamResult", payload: logPayload)
                emit(.stream(result))
                if result.text?.lowercased() == "idle" {
                    completeNextDeferredTurnIfPending()
                }
                continue
            }

            // task_progress events flow through as run-state updates, not transcript rows
            if result.type == "task_progress" {
                writeRawEventLogRecord(kind: "translator.streamResult", payload: logPayload)
                emit(.stream(result))
                continue
            }

            if Self.shouldSuppressUserFacingStreamResult(result) {
                writeRawEventLogRecord(kind: "translator.streamResultSuppressed", payload: logPayload)
                continue
            }
            writeRawEventLogRecord(kind: "translator.streamResult", payload: logPayload)
            emit(.stream(result))
            if isResultPayload, result.type == "message_stop" {
                guard hasPendingTurnIDs else {
                    assertionFailure("[ClaudeController] result message_stop with no pending turn IDs — possible protocol drift")
                    continue
                }
                let status = determineTurnStatus(from: payload, stopReasonHint: result.stopReason)
                if observedSessionStateChangedEvents {
                    // Defer completion until `idle` arrives or fallback timer fires.
                    // Do NOT dequeue the turn ID yet — keep turnInFlight == true so
                    // callers (e.g. coordinator steering) don't send a new user message
                    // before the authoritative idle boundary.
                    pendingAuthoritativeTurnStatuses.append(status)
                    scheduleAuthoritativeIdleFallbackIfNeeded()
                } else {
                    // Legacy mode: complete immediately on result/message_stop.
                    let completedTurnID = dequeueTurnID()
                    emit(.turnCompleted(turnID: completedTurnID, status: status))
                }
            }
        }
    }

    /// Completes the next deferred turn waiting for `idle`, if any, and reschedules/cancels
    /// the fallback timer as needed. Dequeues the turn ID from `pendingTurnIDBuffer` at
    /// this point so `turnInFlight` transitions to false.
    private func completeNextDeferredTurnIfPending() {
        guard !pendingAuthoritativeTurnStatuses.isEmpty else { return }
        let status = pendingAuthoritativeTurnStatuses.removeFirst()
        authoritativeIdleFallbackTask?.cancel()
        authoritativeIdleFallbackTask = nil
        guard hasPendingTurnIDs else {
            assertionFailure("[ClaudeController] deferred idle completion with no pending turn IDs — possible protocol drift")
            return
        }
        let turnID = dequeueTurnID()
        emit(.turnCompleted(turnID: turnID, status: status))
        // If more deferred completions remain, schedule a new fallback.
        scheduleAuthoritativeIdleFallbackIfNeeded()
    }

    /// Schedules a fallback timer for the head of the deferred completion queue.
    /// If `idle` does not arrive within `authoritativeTurnIdleFallbackSeconds`,
    /// the turn completes anyway. Each task carries a generation token so stale
    /// tasks that wake after cancellation are safely ignored.
    private func scheduleAuthoritativeIdleFallbackIfNeeded() {
        guard !pendingAuthoritativeTurnStatuses.isEmpty else {
            authoritativeIdleFallbackTask?.cancel()
            authoritativeIdleFallbackTask = nil
            return
        }
        // Only schedule if there is no active fallback task.
        guard authoritativeIdleFallbackTask == nil else { return }
        authoritativeIdleFallbackGeneration &+= 1
        let currentGeneration = authoritativeIdleFallbackGeneration
        let timeout = authoritativeTurnIdleFallbackSeconds
        authoritativeIdleFallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.handleAuthoritativeIdleFallbackFired(generation: currentGeneration)
        }
    }

    private func handleAuthoritativeIdleFallbackFired(generation: UInt64) {
        // Ignore stale firings from superseded tasks.
        guard generation == authoritativeIdleFallbackGeneration else { return }
        authoritativeIdleFallbackTask = nil
        guard !pendingAuthoritativeTurnStatuses.isEmpty else { return }
        let status = pendingAuthoritativeTurnStatuses.removeFirst()
        guard hasPendingTurnIDs else {
            assertionFailure("[ClaudeController] idle fallback with no pending turn IDs — possible protocol drift")
            return
        }
        let turnID = dequeueTurnID()
        writeRawEventLogRecord(kind: "lifecycle.idleFallback", payload: [
            "turnID": turnID.uuidString,
            "status": String(describing: status)
        ] as [String: Any])
        emit(.turnCompleted(turnID: turnID, status: status))
        scheduleAuthoritativeIdleFallbackIfNeeded()
    }

    /// Cancels and clears all authoritative lifecycle state. Called during shutdown/EOF.
    /// Preserves the stored turn status (e.g. `.completed`) rather than overwriting it
    /// with `.failed`, since the result was already observed.
    private func cancelAuthoritativeLifecycleState() {
        authoritativeIdleFallbackTask?.cancel()
        authoritativeIdleFallbackTask = nil
        // Emit deferred completions with their original status — the result/message_stop
        // already established the correct turn outcome; only idle was missing.
        for status in pendingAuthoritativeTurnStatuses {
            guard hasPendingTurnIDs else { break }
            let turnID = dequeueTurnID()
            emit(.turnCompleted(turnID: turnID, status: status))
        }
        pendingAuthoritativeTurnStatuses.removeAll()
    }

    static func shouldSuppressUserFacingStreamResult(_ result: AIStreamResult) -> Bool {
        // Reasoning is forwarded to Agent Mode as runtime-only status preview data.
        // Transcript suppression belongs in the view-model layer, not at this transport boundary.
        // Suppress Claude background task lifecycle notifications (task_started /
        // task_notification).  These are infrastructure-level events that Claude
        // processes internally; surfacing them in the transcript prematurely ends
        // the active assistant streaming segment (via endActiveAssistantSegment)
        // which makes the UI appear as if the turn completed while it is still
        // running.
        if result.type == "system", let text = result.text,
           text.hasPrefix("Task started") || text.hasPrefix("Task update")
        {
            return true
        }
        guard result.type == "error",
              let text = result.text,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }
        return ClaudeAbortArtifactFilter.shouldSuppressUserFacingError(text)
    }

    /// Extracts tools and MCP server statuses from a `system/init` stream payload.
    /// Returns `nil` if the payload is not a `system/init` event.
    private static func parseSystemInitFields(from payload: [String: Any]) -> (tools: [String], mcpStatuses: [String: String])? {
        guard (payload["type"] as? String) == "system",
              ((payload["subtype"] as? String)?.lowercased() == "init")
        else {
            return nil
        }

        let tools = (payload["tools"] as? [String]) ?? []
        var mcpStatuses: [String: String] = [:]
        if let mcpServers = payload["mcp_servers"] as? [[String: Any]] {
            for server in mcpServers {
                guard let name = server["name"] as? String,
                      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    continue
                }
                let status = (server["status"] as? String) ?? ""
                mcpStatuses[name] = status
            }
        }
        return (tools: tools, mcpStatuses: mcpStatuses)
    }

    // MARK: - Runtime init aggregation helpers

    /// Builds and emits a merged `RuntimeInitStatus` from all available sources.
    /// Deduplicates against the last emitted status.
    private func publishRuntimeInitIfChanged() {
        let status = RuntimeInitStatus(
            sessionID: sessionID,
            tools: latestRuntimeInitTools,
            mcpServerStatuses: latestRuntimeInitMcpServerStatuses,
            initializeResponse: initializeResponseSnapshot
        )
        guard status != lastEmittedRuntimeInitStatus else { return }
        lastEmittedRuntimeInitStatus = status
        emit(.runtimeInit(status))
    }

    /// Best-effort parser for the initialize control response.
    /// Malformed entries are skipped; missing fields become nil/empty.
    static func parseInitializeResponseSnapshot(
        from response: [String: Any]
    ) -> RuntimeInitStatus.InitializeResponseSnapshot {
        let commands: [RuntimeInitStatus.InitializeResponseSnapshot.Command] = if let rawCommands = response["commands"] as? [[String: Any]] {
            rawCommands.compactMap { cmd in
                guard let name = cmd["name"] as? String, !name.isEmpty else { return nil }
                return .init(
                    name: name,
                    description: (cmd["description"] as? String) ?? "",
                    argumentHint: (cmd["argumentHint"] as? String) ?? ""
                )
            }
        } else {
            []
        }

        let agents: [RuntimeInitStatus.InitializeResponseSnapshot.Agent] = if let rawAgents = response["agents"] as? [[String: Any]] {
            rawAgents.compactMap { agent in
                guard let name = agent["name"] as? String, !name.isEmpty else { return nil }
                return .init(
                    name: name,
                    description: (agent["description"] as? String) ?? "",
                    model: agent["model"] as? String
                )
            }
        } else {
            []
        }

        let account: RuntimeInitStatus.InitializeResponseSnapshot.Account? = if let rawAccount = response["account"] as? [String: Any] {
            .init(
                email: rawAccount["email"] as? String,
                organization: rawAccount["organization"] as? String,
                subscriptionType: rawAccount["subscriptionType"] as? String,
                tokenSource: rawAccount["tokenSource"] as? String,
                apiKeySource: rawAccount["apiKeySource"] as? String,
                apiProvider: rawAccount["apiProvider"] as? String
            )
        } else {
            nil
        }

        return .init(
            commands: commands,
            agents: agents,
            outputStyle: response["output_style"] as? String,
            availableOutputStyles: (response["available_output_styles"] as? [String]) ?? [],
            account: account,
            pid: response["pid"] as? Int,
            modelsJSON: Self.canonicalJSONString(from: response["models"]),
            fastModeStateJSON: Self.canonicalJSONString(from: response["fast_mode_state"])
        )
    }

    /// Returns a stable canonical JSON string for a value, or nil if the value is nil/not serializable.
    private static func canonicalJSONString(from value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard JSONSerialization.isValidJSONObject(["v": value]) else { return nil }
        guard let data = try? JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .fragmentsAllowed]
        ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func firstSessionIdentifier(in payload: [String: Any]) -> String? {
        if let sessionID = payload["session_id"] as? String {
            return sessionID
        }
        if let sessionID = payload["sessionId"] as? String {
            return sessionID
        }
        return nil
    }

    private func determineTurnStatus(from payload: [String: Any], stopReasonHint: String? = nil) -> TurnStatus {
        let subtype = ((payload["subtype"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let stopReason = ((payload["stop_reason"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // If we recently sent an interrupt control request for this turn,
        // any error_during_execution result is an abort side effect, not a real failure.
        if turnWasInterrupted {
            turnWasInterrupted = false
            return .cancelled
        }

        if Self.isCancelledTurnSignal(subtype)
            || Self.isCancelledTurnSignal(stopReason)
            || Self.isCancelledTurnSignal(stopReasonHint)
        {
            return .cancelled
        }
        if let streamEvent = payload["event"] as? [String: Any],
           let delta = streamEvent["delta"] as? [String: Any],
           let nestedStopReason = (delta["stop_reason"] as? String),
           Self.isCancelledTurnSignal(nestedStopReason)
        {
            return .cancelled
        }

        let resultErrors = Self.extractResultErrors(from: payload)
        if resultErrors.contains(where: { Self.isCancelledTurnSignal($0) }) {
            return .cancelled
        }

        if (payload["is_error"] as? Bool) == true
            || subtype.contains("error")
            || !resultErrors.isEmpty
        {
            return .failed
        }
        return .completed
    }

    #if DEBUG
        static func test_isRawEventFileLoggingEnabled() -> Bool {
            isRawEventFileLoggingEnabled()
        }

        func test_determineTurnStatus(payload: [String: Any], stopReasonHint: String? = nil) -> TurnStatus {
            determineTurnStatus(from: payload, stopReasonHint: stopReasonHint)
        }

        func test_setTurnWasInterrupted(_ value: Bool) {
            turnWasInterrupted = value
        }

        func test_effectiveLaunchEnvironment(
            base: [String: String],
            resolverOverrides: [String: String] = [:],
            resolverRemovedKeys: Set<String> = []
        ) -> [String: String] {
            effectiveLaunchEnvironment(
                base: base,
                resolverOverrides: resolverOverrides,
                resolverRemovedKeys: resolverRemovedKeys
            )
        }

        func test_liveFlagSettingsRequiresProcessRestart(
            activeLaunchEnvironment: ClaudeCodeLaunchEnvironment,
            nextLaunchEnvironment: ClaudeCodeLaunchEnvironment
        ) -> Bool {
            activeLaunchEnvironmentSignature = LaunchEnvironmentSignature(activeLaunchEnvironment)
            return liveFlagSettingsRequiresProcessRestart(for: nextLaunchEnvironment)
        }

        /// Build the initialize control request payload for testing.
        func test_buildInitializeRequest(systemPromptOverride: String? = nil) -> [String: Any] {
            Self.buildInitializeRequest(systemPromptOverride: systemPromptOverride)
        }

        /// Build the initial flag-settings control request payload for testing.
        func test_buildApplyFlagSettingsRequest(
            model: String? = nil,
            effortLevel: ClaudeCodeEffortLevel? = nil
        ) -> [String: Any]? {
            Self.buildApplyFlagSettingsRequest(model: model, effortLevel: effortLevel)
        }

        func test_resolveApplyFlagSettingsRequest(
            model: String? = nil,
            effortLevel: ClaudeCodeEffortLevel? = nil
        ) async throws -> [String: Any]? {
            try await resolveLaunchFlagSettings(model: model, effortLevel: effortLevel).request
        }

        /// Build the initial permission-mode control request payload for testing.
        func test_buildSetPermissionModeRequest(permissionMode: String? = nil) -> [String: Any]? {
            Self.buildSetPermissionModeRequest(permissionMode: permissionMode ?? config.permissionMode)
        }

        /// Build CLI arguments for testing (verifies prompt flags are absent).
        func test_buildArguments(
            existingSessionID: String?,
            model: String?
        ) -> [String] {
            buildArguments(existingSessionID: existingSessionID, model: model)
        }

        @discardableResult
        func test_beginTurnTracking() -> UUID {
            beginTurnTracking()
        }

        func test_storePendingPermissionRequest(id: String, request: [String: Any]) {
            pendingPermissionRequests[id] = PendingPermissionRequest(requestID: id, request: request)
        }

        func test_handleControlRequest(
            requestID: String,
            subtype: String,
            request: [String: Any]
        ) {
            handleControlRequest(
                ClaudeSDKProtocolCodec.ControlRequest(
                    requestID: requestID,
                    request: request,
                    subtype: subtype
                )
            )
        }
    #endif

    private static func extractResultErrors(from payload: [String: Any]) -> [String] {
        guard let errors = payload["errors"] as? [Any] else { return [] }
        return errors.compactMap { entry in
            switch entry {
            case let text as String:
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            case let object as [String: Any]:
                let message = (object["message"] as? String) ?? (object["error"] as? String)
                let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            default:
                return nil
            }
        }
    }

    private static func isCancelledTurnSignal(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty
        else {
            return false
        }
        return value.contains("interrupt")
            || value.contains("cancel")
            || value.contains("aborted")
            || value.contains("request was aborted")
    }

    private func handleControlRequest(_ request: ClaudeSDKProtocolCodec.ControlRequest) {
        writeRawEventLogRecord(kind: "control.request.received", payload: [
            "requestID": request.requestID,
            "subtype": request.subtype,
            "request": request.request
        ] as [String: Any])
        switch request.subtype {
        case "can_use_tool":
            let payload = request.request
            let toolName = (payload["tool_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let input = payload["input"] as? [String: Any] ?? [:]
            if let repoPromptMatch = Self.repoPromptPermissionAutoApprovalMatch(toolName: toolName, requestPayload: payload) {
                do {
                    let allowResponse = Self.allowPermissionResponsePayload(
                        pendingRequest: payload,
                        includeUpdatedPermissions: false
                    )
                    writeRawEventLogRecord(kind: "approval.autoApprove.repoPrompt", payload: [
                        "requestID": request.requestID,
                        "toolName": toolName,
                        "matchSource": repoPromptMatch.source.rawValue,
                        "normalizedToolName": repoPromptMatch.normalizedToolName ?? NSNull(),
                        "serverIdentifier": repoPromptMatch.serverIdentifier ?? NSNull(),
                        "response": allowResponse
                    ] as [String: Any])
                    let encoded = try ClaudeSDKProtocolCodec.encodeControlResponseSuccess(
                        requestID: request.requestID,
                        response: allowResponse
                    )
                    try sendLine(encoded, shutdownOnFailure: false)
                } catch {
                    failProtocolAndShutdownSoon(
                        message: "Failed auto-approving RepoPrompt Claude permission request: \(error.localizedDescription)"
                    )
                }
                return
            }
            if let approval = buildApprovalRequest(from: request) {
                pendingPermissionRequests[request.requestID] = PendingPermissionRequest(
                    requestID: request.requestID,
                    request: payload
                )
                writeRawEventLogRecord(kind: "approval.request.emitted", payload: [
                    "requestID": request.requestID,
                    "toolName": toolName,
                    "kind": String(describing: approval.kind)
                ] as [String: Any])
                emit(.approvalRequest(approval))
            } else {
                do {
                    let allowResponse = Self.allowPermissionResponsePayload(
                        pendingRequest: payload,
                        includeUpdatedPermissions: false
                    )
                    writeRawEventLogRecord(kind: "approval.autoApprove.fallback", payload: [
                        "requestID": request.requestID,
                        "toolName": toolName,
                        "response": allowResponse
                    ] as [String: Any])
                    let encoded = try ClaudeSDKProtocolCodec.encodeControlResponseSuccess(
                        requestID: request.requestID,
                        response: allowResponse
                    )
                    try sendLine(encoded, shutdownOnFailure: false)
                } catch {
                    failProtocolAndShutdownSoon(
                        message: "Failed auto-approving Claude permission request: \(error.localizedDescription)"
                    )
                }
            }
        default:
            do {
                let encoded = try ClaudeSDKProtocolCodec.encodeControlResponseError(
                    requestID: request.requestID,
                    error: "Unsupported control request subtype: \(request.subtype)"
                )
                try sendLine(encoded, shutdownOnFailure: false)
            } catch {
                failProtocolAndShutdownSoon(
                    message: "Failed replying to unsupported Claude control request (\(request.subtype)): \(error.localizedDescription)"
                )
            }
        }
    }

    private func handleControlCancelRequest(requestID: String) {
        writeRawEventLogRecord(kind: "control.request.cancelled", payload: ["requestID": requestID])
        if pendingPermissionRequests.removeValue(forKey: requestID) != nil {
            emit(.approvalCancelled(requestID: requestID))
        }
    }

    private func handleControlResponse(_ response: ClaudeSDKProtocolCodec.ControlResponse) {
        guard let continuation = pendingControlRequests.removeValue(forKey: response.requestID) else {
            return
        }
        if let timeoutTask = pendingControlRequestTimeoutTasks.removeValue(forKey: response.requestID) {
            timeoutTask.cancel()
        }
        writeRawEventLogRecord(kind: "control.response.received", payload: [
            "requestID": response.requestID,
            "subtype": response.subtype,
            "error": response.error ?? NSNull(),
            "pendingPermissionRequestsCount": response.pendingPermissionRequests.count
        ] as [String: Any])
        switch response.subtype {
        case "success":
            continuation.resume(returning: response.response ?? [:])
        case "error":
            let message = response.error ?? "Unknown Claude control error"
            continuation.resume(throwing: ControllerError.invalidControlResponse(message))
            for pending in response.pendingPermissionRequests {
                guard let requestID = pending["request_id"] as? String,
                      let request = pending["request"] as? [String: Any]
                else {
                    continue
                }
                let synthesized = ClaudeSDKProtocolCodec.ControlRequest(
                    requestID: requestID,
                    request: request,
                    subtype: (request["subtype"] as? String) ?? ""
                )
                handleControlRequest(synthesized)
            }
        default:
            continuation.resume(throwing: ControllerError.invalidControlResponse("Unsupported subtype: \(response.subtype)"))
        }
    }

    private func handleStdoutEOF() async {
        guard !isShuttingDown else { return }
        writeRawEventLogRecord(kind: "process.stdoutEOF")
        var remainingLines: [Data] = []
        stdoutFramer.flush { line in
            remainingLines.append(line)
        }
        for line in remainingLines {
            await handleLine(line)
        }
        failPendingControlRequests(with: ControllerError.processNotRunning)
        cancelAuthoritativeLifecycleState()
        process = nil
        isInitialized = false
        hasCompletedInitialFlagSettings = false
        let staleIDs = drainAllTurnIDs()
        if !staleIDs.isEmpty {
            emit(.error("Claude process exited unexpectedly."))
            for id in staleIDs {
                emit(.turnCompleted(turnID: id, status: .failed))
            }
        }
        finishEventsStreamIfNeeded()
    }

    private func failPendingControlRequests(with error: Error) {
        let pending = pendingControlRequests
        pendingControlRequests.removeAll()
        let timeoutTasks = pendingControlRequestTimeoutTasks
        pendingControlRequestTimeoutTasks.removeAll()
        for timeoutTask in timeoutTasks.values {
            timeoutTask.cancel()
        }
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
    }

    private func handleControlRequestTimeout(requestID: String) {
        guard let continuation = pendingControlRequests.removeValue(forKey: requestID) else {
            pendingControlRequestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
            return
        }
        pendingControlRequestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        continuation.resume(throwing: ControllerError.controlRequestTimedOut(requestID: requestID))
    }

    private func finishEventsStreamIfNeeded() {
        eventsContinuation?.finish()
        eventsContinuation = nil
    }

    private static func makeEventsStream() -> (stream: AsyncStream<Event>, continuation: AsyncStream<Event>.Continuation) {
        var capturedContinuation: AsyncStream<Event>.Continuation?
        let stream = AsyncStream<Event> { continuation in
            capturedContinuation = continuation
        }
        guard let continuation = capturedContinuation else {
            fatalError("Failed to initialize Claude events stream continuation")
        }
        return (stream, continuation)
    }

    /// Non-empty system-prompt suffix that makes the CLI emit its interactive `You are Claude Code…`
    /// identity preamble instead of the Agent SDK `You are a Claude agent…` form. z.ai (GLM)
    /// selectively rejects the Agent SDK self-identification under peak load with a misleading 529
    /// `overloaded` that exhausts the CLI's retry budget and fails the run; the interactive form is
    /// never shed. Empty/whitespace-only values are ignored by the CLI, so this must be a real token,
    /// and it deliberately avoids the trigger words ("Claude"/"Anthropic"/"agent"/"SDK") so it cannot
    /// reintroduce the shedding. See https://github.com/repoprompt/repoprompt-ce/issues/295.
    private static let glmZAIAppendSystemPrompt = "Running within RepoPrompt CE."

    private func buildArguments(
        existingSessionID: String?,
        model: String?
    ) -> [String] {
        var args: [String] = [
            "-p",
            "--verbose",
            "--output-format", "stream-json",
            "--input-format", "stream-json"
        ]

        args.append(contentsOf: ["--permission-prompt-tool", "stdio"])

        // GLM/z.ai sheds requests carrying the Agent SDK identity preamble under load (see #295).
        // Any non-empty --append-system-prompt flips the CLI onto the never-shed "Claude Code" preamble.
        if config.runtimeVariant == .glm {
            args.append(contentsOf: ["--append-system-prompt", Self.glmZAIAppendSystemPrompt])
        }

        if let existingSessionID, !existingSessionID.isEmpty {
            args.append(contentsOf: ["--resume", existingSessionID])
            // RepoPrompt instructions are delivered in provider-bound user messages,
            // so CLI prompt flags remain unused on both fresh starts and resumes.
        }

        if config.permissionMode.caseInsensitiveCompare("bypassPermissions") == .orderedSame {
            args.append("--allow-dangerously-skip-permissions")
        }
        if let configURL {
            args.append(contentsOf: ["--mcp-config", configURL.path])
            if config.mcpStrictMode {
                args.append("--strict-mcp-config")
            }
        }
        if !config.disallowedBuiltInTools.isEmpty {
            args.append(contentsOf: ["--disallowedTools", config.disallowedBuiltInTools.joined(separator: ",")])
        }
        return args
    }

    private func buildApprovalRequest(from request: ClaudeSDKProtocolCodec.ControlRequest) -> AgentApprovalRequest? {
        let payload = request.request
        let toolName = (payload["tool_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "tool"
        let input = payload["input"] as? [String: Any] ?? [:]
        let blockedPath = payload["blocked_path"] as? String
        let decisionReason = payload["decision_reason"] as? String
        let description = payload["description"] as? String
        let toolUseID = (payload["tool_use_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        let command = (input["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTool = toolName.lowercased()
        let kind: AgentApprovalKind = normalizedTool.contains("bash") || normalizedTool.contains("shell")
            ? .commandExecution
            : .fileChange

        let threadID = sessionID ?? "claude:\(tabID.uuidString.lowercased())"
        let turnID = "turn:\(runID.uuidString.lowercased())"
        let itemID = (toolUseID?.isEmpty == false ? toolUseID! : request.requestID)

        let approvalID = AgentApprovalRequest.stableID(
            requestID: .claudeControl(request.requestID),
            method: "control/can_use_tool",
            kind: kind,
            threadID: threadID,
            turnID: turnID,
            itemID: itemID
        )
        let detailSeed = approvalID.uuidString
        var details: [AgentApprovalDetail] = []
        var detailIndex = 0
        func appendDetail(label: String, value: String, isCode: Bool = false) {
            details.append(
                AgentApprovalDetail(
                    id: AgentApprovalDetail.stableID(
                        requestSeed: detailSeed,
                        index: detailIndex,
                        label: label,
                        value: value,
                        isCode: isCode
                    ),
                    label: label,
                    value: value,
                    isCode: isCode
                )
            )
            detailIndex += 1
        }
        appendDetail(label: "Tool", value: toolName, isCode: true)
        if let command, !command.isEmpty {
            appendDetail(label: "Command", value: command, isCode: true)
        }
        if let blockedPath, !blockedPath.isEmpty {
            appendDetail(label: "Blocked Path", value: blockedPath, isCode: true)
        }
        if let decisionReason, !decisionReason.isEmpty {
            appendDetail(label: "Reason", value: decisionReason)
        }
        if let description, !description.isEmpty {
            appendDetail(label: "Description", value: description)
        }

        return AgentApprovalRequest(
            id: approvalID,
            requestID: .claudeControl(request.requestID),
            method: "control/can_use_tool",
            kind: kind,
            threadID: threadID,
            turnID: turnID,
            itemID: itemID,
            reason: decisionReason,
            command: command,
            cwd: workspacePath,
            grantRoot: blockedPath,
            details: details
        )
    }

    private func permissionResponsePayload(
        decision: AgentApprovalDecision,
        pendingRequest: [String: Any]
    ) -> [String: Any] {
        switch decision {
        case .accept:
            Self.allowPermissionResponsePayload(
                pendingRequest: pendingRequest,
                includeUpdatedPermissions: false
            )
        case .acceptForSession, .acceptWithExecpolicyAmendment:
            Self.allowPermissionResponsePayload(
                pendingRequest: pendingRequest,
                includeUpdatedPermissions: true
            )
        case .decline:
            [
                "behavior": "deny",
                "message": "Permission denied by user."
            ]
        case .cancel:
            [
                "behavior": "deny",
                "message": "Permission cancelled by user.",
                "interrupt": true
            ]
        }
    }

    nonisolated static func allowPermissionResponsePayload(
        pendingRequest: [String: Any],
        includeUpdatedPermissions: Bool
    ) -> [String: Any] {
        var payload: [String: Any] = ["behavior": "allow"]
        payload["updatedInput"] = pendingRequest["input"] as? [String: Any] ?? [:]
        if includeUpdatedPermissions,
           let suggestions = pendingRequest["permission_suggestions"] as? [[String: Any]],
           !suggestions.isEmpty
        {
            payload["updatedPermissions"] = suggestions
        }
        if let toolUseID = (pendingRequest["tool_use_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !toolUseID.isEmpty
        {
            payload["toolUseID"] = toolUseID
        }
        return payload
    }

    nonisolated static func shouldAutoApproveRepoPromptPermissionRequest(
        toolName: String,
        input: [String: Any]
    ) -> Bool {
        repoPromptPermissionAutoApprovalMatch(toolName: toolName, requestPayload: input) != nil
    }

    nonisolated static func repoPromptPermissionAutoApprovalMatch(
        toolName: String,
        requestPayload: [String: Any]
    ) -> MCPIntegrationHelper.RepoPromptPermissionAutoApprovalMatch? {
        MCPIntegrationHelper.repoPromptPermissionAutoApprovalMatch(
            requestToolName: toolName,
            requestPayload: requestPayload
        )
    }

    private func resolvedWorkingDirectory() -> String {
        let trimmedWorkspace = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedWorkspace, !trimmedWorkspace.isEmpty {
            return trimmedWorkspace
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func registerExpectedAgentPIDIfNeeded(_ pid: pid_t) async {
        guard config.toolContext == .agentRun,
              let clientName = config.runtimeVariant.agentKind.mcpClientNameHint
        else {
            return
        }
        registeredExpectedAgentPID = pid
        await ServerNetworkManager.shared.registerExpectedAgentPID(pid, for: clientName, runID: runID)
        if isShuttingDown {
            await ServerNetworkManager.shared.clearExpectedAgentPID(pid, for: clientName, runID: runID)
            if registeredExpectedAgentPID == pid {
                registeredExpectedAgentPID = nil
            }
            return
        }
        if config.enableDebugLogging {
            print("[ClaudeNativeSession] Registered expected MCP parent PID \(pid) for \(clientName) runID=\(runID.uuidString)")
        }
    }

    private func clearExpectedAgentPIDIfNeeded() async {
        guard let registeredExpectedAgentPID,
              let clientName = config.runtimeVariant.agentKind.mcpClientNameHint
        else {
            return
        }
        await ServerNetworkManager.shared.clearExpectedAgentPID(registeredExpectedAgentPID, for: clientName, runID: runID)
        self.registeredExpectedAgentPID = nil
        if config.enableDebugLogging {
            print("[ClaudeNativeSession] Cleared expected MCP parent PID for \(clientName) runID=\(runID.uuidString)")
        }
    }

    private func failProtocolAndShutdownSoon(message: String) {
        Task { await self.failProtocolAndShutdown(message: message) }
    }

    private func failProtocolAndShutdown(message: String) async {
        guard !isShuttingDown else { return }
        writeRawEventLogRecord(kind: "session.failProtocol", payload: ["message": message])
        emit(.error(message))
        let staleIDs = drainAllTurnIDs()
        if !staleIDs.isEmpty {
            for id in staleIDs {
                emit(.turnCompleted(turnID: id, status: .failed))
            }
        }
        await shutdown()
    }

    private func resolvedLaunchEnvironment(
        resolverOverrides: [String: String],
        resolverRemovedKeys: Set<String>
    ) async -> [String: String] {
        let result = await ProcessEnvironmentBuilder.build(
            ProcessEnvironmentRequest(
                purpose: .claudeNative,
                additionalRemovedKeys: ["NODE_OPTIONS"],
                enableDebugLogging: config.enableDebugLogging
            )
        )
        return effectiveLaunchEnvironment(
            base: result.environment,
            resolverOverrides: resolverOverrides,
            resolverRemovedKeys: resolverRemovedKeys
        )
    }

    private func effectiveLaunchEnvironment(
        base: [String: String],
        resolverOverrides: [String: String],
        resolverRemovedKeys: Set<String> = []
    ) -> [String: String] {
        var env = base
        if env["CLAUDE_CODE_ENTRYPOINT"].map({ !$0.isEmpty }) != true {
            env["CLAUDE_CODE_ENTRYPOINT"] = "sdk-ts"
        }
        // Disable claude.ai web connector MCP servers unconditionally unless a Claude-specific override says otherwise.
        env["ENABLE_CLAUDEAI_MCP_SERVERS"] = "false"
        // Disable ToolSearch unless explicitly opted in.
        if !config.toolSearchEnabled {
            env["ENABLE_TOOL_SEARCH"] = "false"
        }
        for (key, value) in config.processEnvironmentOverrides {
            env[key] = value
        }
        for (key, value) in resolverOverrides {
            env[key] = value
        }
        return ProcessEnvironmentSanitizer.sanitizedForChildLaunch(
            env,
            additionalRemovedKeys: Set(["NODE_OPTIONS"]).union(resolverRemovedKeys)
        )
    }

    private func recordObservedSessionID(_ candidate: String?) {
        guard let candidate = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !candidate.isEmpty
        else {
            return
        }
        let changed = (sessionID != candidate)
        sessionID = candidate
        ensureRawEventLogFileReadyIfNeeded(sessionIDHint: candidate)
        if changed {
            publishRuntimeInitIfChanged()
        }
    }

    private static let rawEventLoggingEnabledKey = "claudeRawEventLoggingEnabled"

    private static func isRawEventFileLoggingEnabled(defaults: UserDefaults = .standard) -> Bool {
        #if DEBUG
            defaults.bool(forKey: rawEventLoggingEnabledKey)
        #else
            false
        #endif
    }

    #if DEBUG
        static func test_isRawEventFileLoggingEnabled(defaults: UserDefaults) -> Bool {
            isRawEventFileLoggingEnabled(defaults: defaults)
        }
    #endif

    private static func normalizedSessionIdentifier(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "unknown-session" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = trimmed.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        let normalized = String(scalars)
        return normalized.isEmpty ? "unknown-session" : normalized
    }

    private static func makeRawEventLogFileURL(
        workspacePath: String?,
        sessionID: String,
        defaults: UserDefaults = .standard
    ) -> URL? {
        let overridePath = defaults.string(forKey: rawEventLogFilePathKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseDirectory: URL = {
            if let overridePath, !overridePath.isEmpty {
                let expanded = NSString(string: overridePath).expandingTildeInPath
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
            return MCPFilesystemConstants.identity.temporaryRootURL()
                .appendingPathComponent("ClaudeRawEvents", isDirectory: true)
        }()
        do {
            try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let timestampFormatter = DateFormatter()
        timestampFormatter.locale = Locale(identifier: "en_US_POSIX")
        timestampFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        timestampFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = timestampFormatter.string(from: Date())
        let fileName = "claude-session-\(sessionID)-\(timestamp).jsonl"
        return baseDirectory.appendingPathComponent(fileName)
    }

    #if DEBUG
        static func test_makeRawEventLogFileURL(
            workspacePath: String?,
            sessionID: String,
            defaults: UserDefaults
        ) -> URL? {
            makeRawEventLogFileURL(workspacePath: workspacePath, sessionID: sessionID, defaults: defaults)
        }
    #endif

    private func ensureRawEventLogFileReadyIfNeeded(sessionIDHint: String?) {
        guard rawEventFileLoggingEnabled else { return }
        let effectiveSessionID = Self.normalizedSessionIdentifier(sessionIDHint ?? sessionID ?? tabID.uuidString)
        if rawEventLogFileURL != nil, rawEventLogFileSessionID == effectiveSessionID {
            return
        }
        guard let fileURL = Self.makeRawEventLogFileURL(workspacePath: workspacePath, sessionID: effectiveSessionID) else {
            return
        }
        rawEventLogFileURL = fileURL
        rawEventLogFileSessionID = effectiveSessionID
        hasWrittenRawEventLogHeader = false
        UserDefaults.standard.set(fileURL.path, forKey: Self.lastRawEventLogFilePathKey)
    }

    private func appendRawEventLogRecord(_ record: [String: Any]) {
        guard rawEventFileLoggingEnabled else { return }
        guard let rawEventLogFileURL else { return }
        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record, options: []),
              var line = String(data: data, encoding: .utf8)
        else {
            return
        }
        line.append("\n")
        if !FileManager.default.fileExists(atPath: rawEventLogFileURL.path) {
            _ = FileManager.default.createFile(atPath: rawEventLogFileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: rawEventLogFileURL) else { return }
        do {
            try handle.seekToEnd()
            if let lineData = line.data(using: .utf8) {
                handle.write(lineData)
            }
            try handle.close()
        } catch {
            try? handle.close()
        }
    }

    @inline(__always)
    private func writeRawEventLogRecord(kind: String, payload: @autoclosure () -> Any? = nil) {
        #if DEBUG
            guard rawEventFileLoggingEnabled else { return }
            let sessionHint = sessionID ?? rawEventLogFileSessionID
            ensureRawEventLogFileReadyIfNeeded(sessionIDHint: sessionHint)
            guard rawEventLogFileURL != nil else { return }
            let loggedSessionID = sessionID ?? rawEventLogFileSessionID ?? ""
            if !hasWrittenRawEventLogHeader {
                hasWrittenRawEventLogHeader = true
                appendRawEventLogRecord([
                    "kind": "session.header",
                    "timestamp": Self.rawEventTimestampFormatter.string(from: Date()),
                    "runID": runID.uuidString,
                    "tabID": tabID.uuidString,
                    "windowID": windowID,
                    "workspacePath": workspacePath ?? "",
                    "sessionID": loggedSessionID
                ])
            }
            var record: [String: Any] = [
                "kind": kind,
                "timestamp": Self.rawEventTimestampFormatter.string(from: Date()),
                "runID": runID.uuidString,
                "tabID": tabID.uuidString,
                "windowID": windowID,
                "sessionID": loggedSessionID
            ]
            if let payload = payload() {
                if JSONSerialization.isValidJSONObject(payload) {
                    record["payload"] = payload
                } else {
                    record["payloadDebugDescription"] = String(describing: payload)
                }
            }
            appendRawEventLogRecord(record)
        #endif
    }

    /// Maximum bytes to include verbatim in raw event log records.
    /// Larger payloads are sampled (prefix only) to avoid bloating log files and memory.
    private static let maxLogRecordTextBytes = 64 * 1024 // 64 KB

    private func lineRecordPayload(from data: Data) -> [String: Any] {
        let effectiveData = data.count <= Self.maxLogRecordTextBytes ? data : data.prefix(Self.maxLogRecordTextBytes)
        let truncated = data.count > Self.maxLogRecordTextBytes
        if let text = String(data: effectiveData, encoding: .utf8) {
            var result: [String: Any] = [
                "encoding": "utf8",
                "byteCount": data.count,
                "text": text
            ]
            if truncated { result["truncated"] = true }
            return result
        }
        return [
            "encoding": "base64",
            "byteCount": data.count,
            "base64": effectiveData.base64EncodedString(),
            "truncated": truncated
        ]
    }

    private func streamResultLogPayload(_ result: AIStreamResult) -> [String: Any] {
        var payload: [String: Any] = [
            "type": result.type,
            "text": result.text ?? NSNull(),
            "reasoning": result.reasoning ?? NSNull(),
            "toolName": result.toolName ?? NSNull(),
            "toolInvocationID": result.toolInvocationID?.uuidString ?? NSNull(),
            "toolIsError": result.toolIsError ?? NSNull(),
            "promptTokens": result.promptTokens ?? NSNull(),
            "completionTokens": result.completionTokens ?? NSNull(),
            "contextUsedTokens": result.contextUsedTokens ?? NSNull(),
            "providerSessionID": result.providerSessionID ?? NSNull(),
            "stopReason": result.stopReason ?? NSNull()
        ]
        if let toolArgsJSON = result.toolArgsJSON {
            payload["toolArgsJSON"] = toolArgsJSON
        }
        if let toolResultJSON = result.toolResultJSON {
            payload["toolResultJSON"] = toolResultJSON
        }
        return payload
    }

    private func makeControlRequestID() -> String {
        let value = nextControlRequestID
        nextControlRequestID += 1
        return "rp-claude-\(value)"
    }

    @discardableResult
    private func beginTurnTracking() -> UUID {
        let id = UUID()
        pendingTurnIDBuffer.append(id)
        return id
    }

    // MARK: - Pending turn ID deque helpers

    /// O(1) check whether the FIFO queue has entries.
    private var hasPendingTurnIDs: Bool {
        pendingTurnIDHead < pendingTurnIDBuffer.count
    }

    /// O(1) dequeue from the front.  Compacts the buffer when half is consumed.
    private func dequeueTurnID() -> UUID {
        let id = pendingTurnIDBuffer[pendingTurnIDHead]
        pendingTurnIDHead += 1
        compactTurnIDBufferIfNeeded()
        return id
    }

    /// Drain all remaining IDs and reset.
    private func drainAllTurnIDs() -> [UUID] {
        guard hasPendingTurnIDs else { return [] }
        let remaining = Array(pendingTurnIDBuffer[pendingTurnIDHead...])
        clearTurnIDQueue()
        return remaining
    }

    /// Reset the queue to empty.
    private func clearTurnIDQueue() {
        pendingTurnIDBuffer.removeAll(keepingCapacity: false)
        pendingTurnIDHead = 0
    }

    private func compactTurnIDBufferIfNeeded() {
        // Compact when more than half is consumed and at least 4 slots are wasted.
        if pendingTurnIDHead > 4, pendingTurnIDHead >= pendingTurnIDBuffer.count / 2 {
            pendingTurnIDBuffer.removeFirst(pendingTurnIDHead)
            pendingTurnIDHead = 0
        }
    }

    private func emit(_ event: Event) {
        #if DEBUG
            if ClaudeReasoningExtractionFeature.isEnabled,
               case let .stream(result) = event,
               result.type == "reasoning"
            {
                let text = result.reasoning ?? result.text ?? ""
                reasoningDebug("yield event=.stream(reasoning) len=\(text.count) continuationPresent=\(eventsContinuation != nil)")
            }
        #endif
        eventsContinuation?.yield(event)
    }
}
