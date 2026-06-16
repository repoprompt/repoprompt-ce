import Foundation

final class CodexCLIProvider: AIProvider {
    private struct StreamAttemptFailure: Error {
        let underlying: Error
        let emittedOutput: Bool
    }

    private actor TurnTimeoutState {
        private var didTimeout = false

        func markTimedOut() {
            didTimeout = true
        }

        func isTimedOut() -> Bool {
            didTimeout
        }
    }

    private struct TurnTimeoutMonitor {
        let state: TurnTimeoutState
        let task: Task<Void, Never>
    }

    private let workingDirectory: String?
    private let enableDebugLogging: Bool
    private let defaultRequestTimeout: TimeInterval
    private let testRequestTimeout: TimeInterval
    private let maxRetries: Int
    private let appServerReadyHook: (() async throws -> Void)?
    private let sessionControllerFactory: ((Set<String>, TimeInterval) -> CodexSessionControlling)?
    private let authRecovery: any CodexManagedAuthRecovering
    private let initialBackoff: TimeInterval = 1.0
    private let maxBackoff: TimeInterval = 8.0
    private let reminderBlock = """
    <codex reminder>You are operating in text only mode. No tool calls are permitted, as they will result in task failure. You must carefully read the system prompt, attached files and user message, and format your response as specified. Think carefully through your response and then answer comprehensively to address the user's task, specified in <user_instructions>.</codex reminder>
    """

    private let activeStreamTasksLock = NSLock()
    private var activeStreamTasks: [UUID: Task<Void, Never>] = [:]
    private let activeRequestClientsLock = NSLock()
    private var activeRequestClients: [UUID: CodexAppServerClient] = [:]

    init(
        workingDirectory: String? = nil,
        enableDebugLogging: Bool = false,
        defaultRequestTimeout: TimeInterval? = nil,
        testRequestTimeout: TimeInterval? = nil,
        maxRetries: Int? = nil,
        logCollector: CLIProcessLogCollector? = nil,
        appServerReadyHook: (() async throws -> Void)? = nil,
        authRecovery: any CodexManagedAuthRecovering = CodexManagedAuthRecoveryService.shared,
        sessionControllerFactory: ((Set<String>, TimeInterval) -> CodexSessionControlling)? = nil
    ) {
        self.workingDirectory = workingDirectory
        self.enableDebugLogging = enableDebugLogging
        self.defaultRequestTimeout = defaultRequestTimeout ?? (45 * 60)
        self.testRequestTimeout = testRequestTimeout ?? 30
        self.maxRetries = maxRetries ?? 2
        self.appServerReadyHook = appServerReadyHook
        self.authRecovery = authRecovery
        self.sessionControllerFactory = sessionControllerFactory
        _ = logCollector

        // Ensure RepoPrompt MCP server entry exists before building overrides.
        _ = MCPIntegrationHelper.ensureCodexServerForDiscovery()
    }

    func streamMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens _: Int? = nil) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        let baseInstructions = buildBaseInstructions(from: aiMessage)
        let prompt = buildPrompt(from: aiMessage)
        let requestedModelIdentifier = modelIdentifier(for: model)
        let fallbackReasoningEffort = model.defaultReasoningEffort
        let serviceTier = model.codexServiceTier

        return AsyncThrowingStream { continuation in
            let streamID = UUID()
            let bridgeTask = Task { [weak self] in
                defer {
                    self?.unregisterActiveStreamTask(streamID)
                    self?.unregisterActiveRequestClient(streamID)
                }
                guard let self else {
                    continuation.finish(throwing: AIProviderError.invalidConfiguration(detail: "Codex provider was released before streaming started."))
                    return
                }

                do {
                    try await streamViaAppServer(
                        baseInstructions: baseInstructions,
                        prompt: prompt,
                        requestedModelIdentifier: requestedModelIdentifier,
                        fallbackReasoningEffort: fallbackReasoningEffort,
                        serviceTier: serviceTier,
                        requestID: streamID,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            registerActiveStreamTask(bridgeTask, id: streamID)
            continuation.onTermination = { @Sendable _ in
                bridgeTask.cancel()
            }
        }
    }

    func completeMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens: Int? = nil) async throws -> AICompletionResult {
        let stream = try await streamMessage(aiMessage, model: model, maxTokens: maxTokens)
        var textParts: [String] = []
        var promptTokens: Int?
        var completionTokens: Int?
        var cost: Double?
        var sawMessageStop = false

        for try await result in stream {
            switch result.type {
            case "content":
                if let text = result.text, !text.isEmpty {
                    textParts.append(text)
                }
            case "message_stop":
                sawMessageStop = true
                if let value = result.promptTokens { promptTokens = value }
                if let value = result.completionTokens { completionTokens = value }
                if let value = result.cost { cost = value }
            case "error":
                throw AIProviderError.invalidConfiguration(detail: result.text ?? "Codex app-server reported an error")
            default:
                continue
            }
        }

        guard sawMessageStop || !textParts.isEmpty else {
            throw AIProviderError.invalidResponse(detail: "Codex app-server returned no completion")
        }

        return AICompletionResult(
            text: textParts.joined(),
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            cost: cost
        )
    }

    func dispose() async {
        cancelActiveStreamTasks()
        let activeClients = snapshotActiveRequestClients()
        for client in activeClients {
            await client.stop()
        }
    }

    func testConnection(timeout: TimeInterval? = nil) async throws -> Bool {
        let initialExcludeSet = await CodexBrokenServersCache.shared.getAll()
        let requestID = UUID()
        return try await testConnectionImpl(
            timeout: timeout,
            excludeServers: initialExcludeSet,
            requestID: requestID
        )
    }

    private func testConnectionImpl(
        timeout: TimeInterval?,
        excludeServers: Set<String>,
        requestID: UUID
    ) async throws -> Bool {
        try await testConnectionWithDefaultModel(
            timeout: timeout,
            excludeServers: excludeServers,
            requestID: requestID
        )
    }

    private func testConnectionWithDefaultModel(
        timeout: TimeInterval?,
        excludeServers: Set<String>,
        requestID: UUID
    ) async throws -> Bool {
        let aiMessage = AIMessage(systemPrompt: "", userMessage: "Reply with OK only")
        let baseInstructions = buildBaseInstructions(from: aiMessage)
        let prompt = buildPrompt(from: aiMessage)
        let appliedTimeout = timeout ?? testRequestTimeout
        var currentExcludeServers = excludeServers
        var didRetryBrokenServer = false
        var didRetryManagedAuthRecovery = false

        while true {
            do {
                let text = try await withActiveRequestAppServerClient(id: requestID) { appServerClient in
                    try await runTurnCollectingText(
                        baseInstructions: baseInstructions,
                        prompt: prompt,
                        requestedModelIdentifier: nil,
                        fallbackReasoningEffort: nil,
                        excludeServers: currentExcludeServers,
                        appServerClient: appServerClient,
                        requestTimeout: appliedTimeout
                    )
                }
                return text.lowercased().contains("ok")
            } catch {
                let detail = appServerErrorDetail(from: error)
                if !didRetryManagedAuthRecovery,
                   CodexManagedAuthRecoveryClassifier.isRecoverable(message: detail)
                {
                    didRetryManagedAuthRecovery = true
                    switch await authRecovery.refreshManagedAccount() {
                    case .recovered:
                        continue
                    case let .requiresUserLogin(message):
                        throw AIProviderError.invalidConfiguration(detail: message)
                    case let .executableUnavailable(message):
                        throw AIProviderError.invalidConfiguration(detail: message)
                    }
                }
                if !didRetryBrokenServer,
                   let brokenServer = CodexProviderHelpers.extractBrokenServerName(from: detail),
                   !currentExcludeServers.contains(brokenServer)
                {
                    let isRepoPrompt = brokenServer.compare(MCPIntegrationHelper.repoPromptMCPServerName, options: .caseInsensitive) == .orderedSame
                    if !isRepoPrompt {
                        await CodexBrokenServersCache.shared.add(brokenServer)
                        currentExcludeServers.insert(brokenServer)
                    }
                    didRetryBrokenServer = true
                    continue
                }

                throw mapAppServerFailure(error: error, detail: detail, timeoutValue: appliedTimeout)
            }
        }
    }

    private func streamViaAppServer(
        baseInstructions: String,
        prompt: String,
        requestedModelIdentifier: String?,
        fallbackReasoningEffort: String?,
        serviceTier: String?,
        requestID: UUID,
        continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation
    ) async throws {
        var attempt = 0
        var delay = initialBackoff
        var activeModelIdentifier = requestedModelIdentifier
        var didRetryBrokenServer = false
        var didRetryModelFallback = false
        var didRetryManagedAuthRecovery = false
        let maxAttempts = maxRetries + 3

        while attempt < maxAttempts {
            try Task.checkCancellation()
            attempt += 1
            let brokenServers = await CodexBrokenServersCache.shared.getAll()

            do {
                try await withActiveRequestAppServerClient(id: requestID) { appServerClient in
                    try await runSingleStreamAttempt(
                        baseInstructions: baseInstructions,
                        prompt: prompt,
                        requestedModelIdentifier: activeModelIdentifier,
                        fallbackReasoningEffort: fallbackReasoningEffort,
                        serviceTier: serviceTier,
                        excludeServers: brokenServers,
                        appServerClient: appServerClient,
                        requestTimeout: defaultRequestTimeout,
                        continuation: continuation
                    )
                }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as StreamAttemptFailure {
                let detail = appServerErrorDetail(from: failure.underlying)

                if failure.emittedOutput,
                   CodexManagedAuthRecoveryClassifier.isRecoverable(message: detail)
                {
                    throw AIProviderError.invalidConfiguration(detail: CodexManagedAuthRecoveryClassifier.manualLoginGuidanceMessage)
                }

                if !failure.emittedOutput {
                    if !didRetryManagedAuthRecovery,
                       CodexManagedAuthRecoveryClassifier.isRecoverable(message: detail)
                    {
                        didRetryManagedAuthRecovery = true
                        switch await authRecovery.refreshManagedAccount() {
                        case .recovered:
                            continue
                        case let .requiresUserLogin(message):
                            throw AIProviderError.invalidConfiguration(detail: message)
                        case let .executableUnavailable(message):
                            throw AIProviderError.invalidConfiguration(detail: message)
                        }
                    }

                    if !didRetryBrokenServer,
                       let brokenServer = CodexProviderHelpers.extractBrokenServerName(from: detail)
                    {
                        let isRepoPrompt = brokenServer.compare(MCPIntegrationHelper.repoPromptMCPServerName, options: .caseInsensitive) == .orderedSame
                        if !isRepoPrompt {
                            await CodexBrokenServersCache.shared.add(brokenServer)
                        }
                        didRetryBrokenServer = true
                        continue
                    }

                    if !didRetryModelFallback,
                       let fallbackModel = CodexProviderHelpers.codexFallbackModelIfNeeded(
                           attemptedModel: activeModelIdentifier,
                           errorDetail: detail
                       )
                    {
                        activeModelIdentifier = fallbackModel
                        didRetryModelFallback = true
                        continue
                    }

                    if attempt <= maxRetries,
                       shouldRetry(detail: detail, timedOut: isTimeoutDetail(detail))
                    {
                        let jitter = Double.random(in: 0.8 ... 1.2)
                        let sleepSeconds = min(delay, maxBackoff) * jitter
                        try await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
                        delay = min(delay * 2, maxBackoff)
                        continue
                    }
                }

                throw mapAppServerFailure(error: failure.underlying, detail: detail, timeoutValue: defaultRequestTimeout)
            } catch {
                let detail = appServerErrorDetail(from: error)
                if !didRetryManagedAuthRecovery,
                   CodexManagedAuthRecoveryClassifier.isRecoverable(message: detail)
                {
                    didRetryManagedAuthRecovery = true
                    switch await authRecovery.refreshManagedAccount() {
                    case .recovered:
                        continue
                    case let .requiresUserLogin(message):
                        throw AIProviderError.invalidConfiguration(detail: message)
                    case let .executableUnavailable(message):
                        throw AIProviderError.invalidConfiguration(detail: message)
                    }
                }
                throw mapAppServerFailure(error: error, detail: detail, timeoutValue: defaultRequestTimeout)
            }
        }

        throw AIProviderError.invalidConfiguration(detail: "Codex app-server exhausted retry attempts.")
    }

    private func runSingleStreamAttempt(
        baseInstructions: String,
        prompt: String,
        requestedModelIdentifier: String?,
        fallbackReasoningEffort: String?,
        serviceTier: String?,
        excludeServers: Set<String>,
        appServerClient: CodexAppServerClient?,
        requestTimeout: TimeInterval,
        continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation
    ) async throws {
        let selection = appServerSelection(
            requestedModelIdentifier: requestedModelIdentifier,
            fallbackReasoningEffort: fallbackReasoningEffort,
            serviceTier: serviceTier
        )
        let controller = makeInteractiveSessionController(
            appServerClient: appServerClient,
            excludeServers: excludeServers,
            requestTimeout: requestTimeout
        )

        var emittedOutput = false
        let timeoutMonitor = startTurnTimeoutMonitor(timeout: requestTimeout, controller: controller)
        defer {
            timeoutMonitor?.task.cancel()
        }

        do {
            try await withTaskCancellationHandler(operation: {
                try await ensureAppServerReady(appServerClient: appServerClient)
                _ = try await controller.startOrResume(
                    existing: nil,
                    baseInstructions: baseInstructions,
                    model: selection.model,
                    reasoningEffort: selection.reasoningEffort,
                    serviceTier: selection.serviceTier
                )
                _ = try await controller.startUserTurn(
                    text: prompt,
                    images: [],
                    model: selection.model,
                    reasoningEffort: selection.reasoningEffort,
                    serviceTier: selection.serviceTier
                )

                var sawCompletion = false
                eventLoop: for await event in controller.events {
                    if Task.isCancelled {
                        throw CancellationError()
                    }

                    switch event {
                    case let .assistantDelta(delta):
                        guard !delta.isEmpty else { continue }
                        emittedOutput = true
                        continuation.yield(AIStreamResult(type: "content", text: delta))

                    case let .reasoningDelta(payload):
                        guard !payload.text.isEmpty else { continue }
                        emittedOutput = true
                        continuation.yield(AIStreamResult(type: "reasoning", text: nil, reasoning: payload.text))

                    case .turnCompleted(turnID: _, status: let status):
                        switch status {
                        case .completed:
                            sawCompletion = true
                            continuation.yield(Self.messageStopEvent())
                            break eventLoop
                        case .interrupted:
                            throw CancellationError()
                        case .failed:
                            throw AIProviderError.invalidResponse(detail: "Codex app-server turn failed.")
                        }

                    case .contextCompacted(turnID: _):
                        continue

                    case .livenessActivity:
                        continue

                    case let .errorNotification(notification):
                        let willRetry = notification.willRetry
                            ?? Self.isRetriableStreamErrorMessage(notification.message)
                        if willRetry {
                            continuation.yield(AIStreamResult(type: "status", text: notification.message))
                            continue
                        }
                        throw AIProviderError.invalidConfiguration(detail: notification.message)

                    case let .error(message):
                        if Self.isRetriableStreamErrorMessage(message) {
                            continuation.yield(AIStreamResult(type: "status", text: message))
                            continue
                        }
                        throw AIProviderError.invalidConfiguration(detail: message)

                    case let .serverRequestIssue(issue):
                        throw AIProviderError.invalidConfiguration(detail: issue.message)

                    case .requestUserInput:
                        await controller.cancelCurrentTurn()
                        throw AIProviderError.invalidConfiguration(detail: "Codex request_user_input prompts require Agent Mode UI. Retry this action in Agent Mode.")

                    case .mcpElicitationRequest:
                        await controller.cancelCurrentTurn()
                        throw AIProviderError.invalidConfiguration(detail: "Codex MCP elicitation prompts require Agent Mode UI. Retry this action in Agent Mode.")

                    case .approvalRequest:
                        throw AIProviderError.invalidConfiguration(detail: "Codex app-server requested tool approval while interactive chat tools are disabled.")

                    case .permissionsRequest:
                        await controller.cancelCurrentTurn()
                        throw AIProviderError.invalidConfiguration(detail: "Codex app-server requested permissions approval while interactive chat tools are disabled.")

                    case .toolCall, .toolResult, .commandExecutionRunning:
                        throw AIProviderError.invalidConfiguration(detail: "Codex app-server emitted tool events while interactive chat tools are disabled.")

                    case .tokenUsage, .turnStarted(turnID: _), .system:
                        continue
                    }
                }

                if !sawCompletion {
                    if await didTimeout(monitor: timeoutMonitor) {
                        throw timeoutError(for: requestTimeout)
                    }
                    throw AIProviderError.invalidResponse(detail: "Codex app-server stream ended before turn completion.")
                }
            }, onCancel: {
                Task {
                    await controller.cancelCurrentTurn()
                    await controller.shutdown()
                }
            })
            await controller.shutdown()
        } catch is CancellationError {
            await controller.cancelCurrentTurn()
            await controller.shutdown()
            throw CancellationError()
        } catch {
            await controller.shutdown()
            throw StreamAttemptFailure(underlying: error, emittedOutput: emittedOutput)
        }
    }

    private func runTurnCollectingText(
        baseInstructions: String,
        prompt: String,
        requestedModelIdentifier: String?,
        fallbackReasoningEffort: String?,
        serviceTier: String? = nil,
        excludeServers: Set<String>,
        appServerClient: CodexAppServerClient?,
        requestTimeout: TimeInterval
    ) async throws -> String {
        let selection = appServerSelection(
            requestedModelIdentifier: requestedModelIdentifier,
            fallbackReasoningEffort: fallbackReasoningEffort,
            serviceTier: serviceTier
        )
        let controller = makeInteractiveSessionController(
            appServerClient: appServerClient,
            excludeServers: excludeServers,
            requestTimeout: requestTimeout
        )

        let timeoutMonitor = startTurnTimeoutMonitor(timeout: requestTimeout, controller: controller)
        defer {
            timeoutMonitor?.task.cancel()
        }

        do {
            let text = try await withTaskCancellationHandler(operation: {
                try await ensureAppServerReady(appServerClient: appServerClient)
                _ = try await controller.startOrResume(
                    existing: nil,
                    baseInstructions: baseInstructions,
                    model: selection.model,
                    reasoningEffort: selection.reasoningEffort,
                    serviceTier: selection.serviceTier
                )
                _ = try await controller.startUserTurn(
                    text: prompt,
                    images: [],
                    model: selection.model,
                    reasoningEffort: selection.reasoningEffort,
                    serviceTier: selection.serviceTier
                )

                var textParts: [String] = []
                var sawCompletion = false
                eventLoop: for await event in controller.events {
                    if Task.isCancelled {
                        throw CancellationError()
                    }

                    switch event {
                    case let .assistantDelta(delta):
                        if !delta.isEmpty {
                            textParts.append(delta)
                        }

                    case .turnCompleted(turnID: _, status: let status):
                        switch status {
                        case .completed:
                            sawCompletion = true
                            break eventLoop
                        case .interrupted:
                            throw CancellationError()
                        case .failed:
                            throw AIProviderError.invalidResponse(detail: "Codex app-server turn failed.")
                        }

                    case .contextCompacted(turnID: _):
                        continue

                    case .livenessActivity:
                        continue

                    case let .errorNotification(notification):
                        let willRetry = notification.willRetry
                            ?? Self.isRetriableStreamErrorMessage(notification.message)
                        if willRetry {
                            continue
                        }
                        throw AIProviderError.invalidConfiguration(detail: notification.message)

                    case let .error(message):
                        if Self.isRetriableStreamErrorMessage(message) {
                            continue
                        }
                        throw AIProviderError.invalidConfiguration(detail: message)

                    case let .serverRequestIssue(issue):
                        throw AIProviderError.invalidConfiguration(detail: issue.message)

                    case .requestUserInput:
                        await controller.cancelCurrentTurn()
                        throw AIProviderError.invalidConfiguration(detail: "Codex request_user_input prompts require Agent Mode UI. Retry this action in Agent Mode.")

                    case .mcpElicitationRequest:
                        await controller.cancelCurrentTurn()
                        throw AIProviderError.invalidConfiguration(detail: "Codex MCP elicitation prompts require Agent Mode UI. Retry this action in Agent Mode.")

                    case .approvalRequest:
                        throw AIProviderError.invalidConfiguration(detail: "Codex app-server requested tool approval while interactive chat tools are disabled.")

                    case .permissionsRequest:
                        await controller.cancelCurrentTurn()
                        throw AIProviderError.invalidConfiguration(detail: "Codex app-server requested permissions approval while interactive chat tools are disabled.")

                    case .toolCall, .toolResult, .commandExecutionRunning:
                        throw AIProviderError.invalidConfiguration(detail: "Codex app-server emitted tool events while interactive chat tools are disabled.")

                    case .reasoningDelta, .tokenUsage, .turnStarted(turnID: _), .system:
                        continue
                    }
                }

                if !sawCompletion {
                    if await didTimeout(monitor: timeoutMonitor) {
                        throw timeoutError(for: requestTimeout)
                    }
                    throw AIProviderError.invalidResponse(detail: "Codex app-server stream ended before turn completion.")
                }
                return textParts.joined()
            }, onCancel: {
                Task {
                    await controller.cancelCurrentTurn()
                    await controller.shutdown()
                }
            })
            await controller.shutdown()
            return text
        } catch is CancellationError {
            await controller.cancelCurrentTurn()
            await controller.shutdown()
            throw CancellationError()
        } catch {
            await controller.shutdown()
            throw error
        }
    }

    private func ensureAppServerReady(appServerClient: CodexAppServerClient?) async throws {
        if let appServerReadyHook {
            try await appServerReadyHook()
            return
        }
        guard let appServerClient else { return }
        if enableDebugLogging {
            await appServerClient.updateConfig(
                CodexAppServerClient.Config(
                    commandName: "codex",
                    additionalPathHints: CLIPathHints.codex,
                    enableDebugLogging: true,
                    requestTimeout: nil
                )
            )
        }
        try await appServerClient.startIfNeeded()
    }

    private func startTurnTimeoutMonitor(
        timeout: TimeInterval,
        controller: CodexSessionControlling
    ) -> TurnTimeoutMonitor? {
        guard timeout > 0 else { return nil }
        let state = TurnTimeoutState()
        let sleepNanos = UInt64(timeout * 1_000_000_000)
        let task = Task {
            do {
                try await Task.sleep(nanoseconds: sleepNanos)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await state.markTimedOut()
            await controller.shutdown()
        }
        return TurnTimeoutMonitor(state: state, task: task)
    }

    private func didTimeout(monitor: TurnTimeoutMonitor?) async -> Bool {
        guard let monitor else { return false }
        return await monitor.state.isTimedOut()
    }

    private func timeoutError(for timeout: TimeInterval) -> AIProviderError {
        let seconds = Int(timeout)
        return AIProviderError.invalidConfiguration(detail: "Codex app-server timed out after \(seconds)s. Please try again shortly.")
    }

    private func makeInteractiveSessionController(
        appServerClient: CodexAppServerClient?,
        excludeServers: Set<String>,
        requestTimeout: TimeInterval
    ) -> CodexSessionControlling {
        if let sessionControllerFactory {
            return sessionControllerFactory(excludeServers, requestTimeout)
        }
        guard let appServerClient else {
            preconditionFailure("CodexCLIProvider requires an app-server client when no custom session controller factory is provided.")
        }

        let options = CodexNativeSessionController.Options(
            requestTimeout: requestTimeout,
            configOverridesProvider: { [weak self] in
                guard let self else { return [:] }
                return interactiveConfigOverrides(excludeServers: excludeServers)
            },
            approvalPolicyProvider: { .never },
            sandboxModeProvider: { .readOnly },
            approvalReviewerProvider: { .user },
            authTokensRefreshHandler: nil
        )

        return CodexNativeSessionController(
            client: appServerClient,
            runID: UUID(),
            tabID: UUID(),
            windowID: 0,
            workspacePath: workingDirectory,
            options: options,
            // The transport is owned by the outer request lifecycle, not by the
            // single-turn controller.
            clientShutdownBehavior: .none
        )
    }

    private func makeRequestAppServerClient() -> CodexAppServerClient? {
        guard sessionControllerFactory == nil else { return nil }
        return CodexProviderHelpers.makeOwnedNonAgentAppServerClient()
    }

    private func withActiveRequestAppServerClient<T>(
        id: UUID,
        operation: (CodexAppServerClient?) async throws -> T
    ) async throws -> T {
        let appServerClient = makeRequestAppServerClient()
        if let appServerClient {
            registerActiveRequestClient(appServerClient, id: id)
        }
        defer {
            unregisterActiveRequestClient(id)
        }
        do {
            let result = try await operation(appServerClient)
            await stopRequestAppServerClient(appServerClient)
            return result
        } catch {
            await stopRequestAppServerClient(appServerClient)
            throw error
        }
    }

    private func stopRequestAppServerClient(_ appServerClient: CodexAppServerClient?) async {
        guard let appServerClient else { return }
        await appServerClient.stop()
    }

    private func interactiveConfigOverrides(excludeServers: Set<String>) -> [String: Any] {
        let serverEntries = MCPIntegrationHelper.codexMCPServerEntries()
        let toolPolicy = CodexOverrides.ToolPolicy(
            toolOutputTokenLimit: MCPIntegrationHelper.desiredCodexToolOutputTokenLimit,
            shellToolEnabled: false,
            webSearchRequestEnabled: false,
            viewImageToolEnabled: false,
            includeApplyPatchTool: false,
            parallelToolCallsEnabled: false,
            multiAgentEnabled: false
        )
        var overrides = CodexOverrides.appServerConfigMap(toolPolicy: toolPolicy)
        let mcpOverrides = CodexOverrides.appServerMCPServerMap(
            entries: serverEntries,
            policy: .disableAll(exceptBroken: excludeServers)
        )
        for (key, value) in mcpOverrides {
            overrides[key] = value
        }
        overrides["approval_policy"] = CodexAgentToolPreferences.ApprovalPolicy.never.appServerConfigOverrideValue
        overrides["sandbox_mode"] = CodexAgentToolPreferences.SandboxMode.readOnly.appServerConfigOverrideValue
        return overrides
    }

    private func appServerSelection(
        requestedModelIdentifier: String?,
        fallbackReasoningEffort: String?,
        serviceTier: String? = nil
    ) -> (model: String?, reasoningEffort: String?, serviceTier: String?) {
        let specifier = CodexModelSpecifier(raw: requestedModelIdentifier)
        return (
            model: specifier.appServerModelParam,
            reasoningEffort: specifier.appServerEffortParam ?? fallbackReasoningEffort,
            serviceTier: specifier.appServerServiceTierParam ?? serviceTier
        )
    }

    private func buildBaseInstructions(from aiMessage: AIMessage) -> String {
        aiMessage.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func buildPrompt(from aiMessage: AIMessage) -> String {
        let tail = aiMessage.buildTail(embedSystemPrompt: false)
        var conversation = ""
        let lastUserIndex = aiMessage.conversationMessages.lastIndex { $0.role == .user }
        for (index, message) in aiMessage.conversationMessages.enumerated() {
            var text = message.content
            if message.role == .user,
               index == lastUserIndex,
               !tail.isEmpty
            {
                text = tail + "\n\n" + text
            }
            let prefix = message.role == .user ? "User" : "Assistant"
            if !conversation.isEmpty {
                conversation += "\n\n"
            }
            conversation += "\(prefix): \(text)"
        }
        if aiMessage.conversationMessages.isEmpty, !tail.isEmpty {
            conversation = "User: \(tail)"
        }

        var sections: [String] = [reminderBlock]
        if !conversation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(conversation)
        }
        return sections.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    private func modelIdentifier(for model: AIModel) -> String? {
        switch model {
        case .codexCliGpt5Low,
             .codexCliGpt5Medium,
             .codexCliGpt5High,
             .codexCliGpt5XHigh,
             .codexCliGpt5Mini,
             .codexCliGpt5CodexLow,
             .codexCliGpt5CodexMedium,
             .codexCliGpt5CodexHigh,
             .codexCliGpt5CodexXHigh,
             .codexCliGpt5CodexMini:
            model.modelName
        default:
            model.providerType == .codex ? model.modelName : nil
        }
    }

    private static func isRetriableStreamErrorMessage(_ message: String) -> Bool {
        let normalized = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }
        return normalized.hasPrefix("reconnecting")
            || normalized.contains("reconnecting...")
            || normalized.contains("will retry")
            || normalized.contains("retrying")
    }

    private func shouldRetry(detail: String, timedOut: Bool) -> Bool {
        if timedOut { return true }
        let lower = detail.lowercased()
        if lower.contains("429") || lower.contains("rate limit") || lower.contains("too many requests") { return true }
        if lower.contains("overload") || lower.contains("overloaded") || lower.contains("busy") { return true }
        if lower.contains("502") || lower.contains("503") || lower.contains("504") || lower.contains("gateway") { return true }
        if lower.contains("timeout") || lower.contains("timed out") || lower.contains("context deadline exceeded") { return true }
        if lower.contains("econnreset") || lower.contains("connection reset") { return true }
        if lower.contains("network") || lower.contains("unreachable") { return true }
        return false
    }

    private func isTimeoutDetail(_ detail: String) -> Bool {
        let lower = detail.lowercased()
        return lower.contains("timed out") || lower.contains("timeout")
    }

    private func mapAppServerFailure(error: Error, detail: String, timeoutValue: TimeInterval) -> Error {
        if let providerError = error as? AIProviderError {
            return providerError
        }

        let lower = detail.lowercased()
        if CodexProviderHelpers.isCodexExecutableUnavailableMessage(detail) {
            return AIProviderError.invalidConfiguration(detail: detail)
        }
        if isTimeoutDetail(detail) {
            return timeoutError(for: timeoutValue)
        }
        if lower.contains("command not found")
            || lower.contains("no such file")
            || lower.contains("spawnfailed(errno: 2)")
            || lower.contains("errno: 2")
        {
            return AIProviderError.invalidConfiguration(detail: "Codex CLI is not installed or not in PATH. Install it and run `codex login`.")
        }
        if lower.contains("permission denied") || lower.contains("spawnfailed(errno: 13)") || lower.contains("errno: 13") {
            return AIProviderError.invalidConfiguration(detail: "Permission denied. Ensure the 'codex' executable is accessible.")
        }
        if lower.contains("unauthorized") || lower.contains("not authenticated") {
            return AIProviderError.invalidConfiguration(detail: "Codex CLI is not authenticated. Run `codex login` in your terminal.")
        }
        if lower.contains("rate limit") || lower.contains("too many requests") || lower.contains("429") {
            return AIProviderError.invalidConfiguration(detail: "Codex CLI rate limited. Please wait a moment and try again.")
        }
        if lower.contains("overload") || lower.contains("overloaded") || lower.contains("busy") || lower.contains("503") {
            return AIProviderError.invalidConfiguration(detail: "Codex servers look overloaded. We attempted retries; please try again shortly.")
        }
        if detail.isEmpty {
            return AIProviderError.apiError(source: error)
        }
        return AIProviderError.apiError(
            source: NSError(
                domain: "CodexAppServer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: detail]
            )
        )
    }

    private func appServerErrorDetail(from error: Error) -> String {
        if let providerError = error as? AIProviderError {
            switch providerError {
            case let .invalidConfiguration(detail):
                return detail
            case let .invalidResponse(detail):
                return detail
            case let .apiError(source):
                return source?.localizedDescription ?? error.localizedDescription
            default:
                break
            }
        }
        if let clientError = error as? CodexAppServerClient.ClientError {
            switch clientError {
            case let .requestFailed(failure):
                return failure.message
            case let .executableUnavailable(message):
                return message
            case let .transportWriteFailed(message, _):
                return message
            case let .transportReadSetupFailed(message, _):
                return message
            case .processNotRunning:
                return "Codex app-server process is not running."
            case .invalidResponse:
                return "Codex app-server returned an invalid response."
            case .jsonDecodeFailed:
                return "Failed to decode Codex app-server JSON response."
            }
        }
        let localized = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !localized.isEmpty {
            return localized
        }
        return String(describing: error)
    }

    private static func messageStopEvent() -> AIStreamResult {
        AIStreamResult(
            type: "message_stop",
            text: nil,
            reasoning: nil,
            promptTokens: nil,
            completionTokens: nil,
            cost: nil
        )
    }

    private func registerActiveStreamTask(_ task: Task<Void, Never>, id: UUID) {
        activeStreamTasksLock.lock()
        activeStreamTasks[id] = task
        activeStreamTasksLock.unlock()
    }

    private func unregisterActiveStreamTask(_ id: UUID) {
        activeStreamTasksLock.lock()
        activeStreamTasks.removeValue(forKey: id)
        activeStreamTasksLock.unlock()
    }

    private func cancelActiveStreamTasks() {
        activeStreamTasksLock.lock()
        let tasks = Array(activeStreamTasks.values)
        activeStreamTasks.removeAll()
        activeStreamTasksLock.unlock()
        tasks.forEach { $0.cancel() }
    }

    private func registerActiveRequestClient(_ client: CodexAppServerClient, id: UUID) {
        activeRequestClientsLock.lock()
        activeRequestClients[id] = client
        activeRequestClientsLock.unlock()
    }

    private func unregisterActiveRequestClient(_ id: UUID) {
        activeRequestClientsLock.lock()
        activeRequestClients.removeValue(forKey: id)
        activeRequestClientsLock.unlock()
    }

    private func snapshotActiveRequestClients() -> [CodexAppServerClient] {
        activeRequestClientsLock.lock()
        let clients = Array(activeRequestClients.values)
        activeRequestClientsLock.unlock()
        return clients
    }
}
