import Foundation

struct HeadlessAgentContext {
    let runID: UUID
    let configURL: URL?
    let configLease: MCPConfigLease?
    /// Working directory for the agent. Defaults to temp directory to avoid macOS security popups.
    let workingDirectory: String
    let environment: [String: String]
    let launchEnvironment: ClaudeCodeLaunchEnvironment?

    init(
        runID: UUID,
        configURL: URL? = nil,
        configLease: MCPConfigLease? = nil,
        workingDirectory: String? = nil,
        environment: [String: String],
        launchEnvironment: ClaudeCodeLaunchEnvironment? = nil
    ) {
        self.runID = runID
        self.configLease = configLease
        self.configURL = configLease?.url ?? configURL
        self.workingDirectory = workingDirectory ?? FileManager.default.temporaryDirectory.path
        self.environment = environment
        self.launchEnvironment = launchEnvironment
    }
}

final class ClaudeCodeAgentProvider: HeadlessAgentProvider {
    private let runner: CLIProcessRunner
    private let config: ClaudeCodeAgentConfig
    private let environmentResolver: any ClaudeCodeLaunchEnvironmentResolving
    private let configService = MCPConfigExportService.shared
    private let toolTracking = AgentToolTrackingController()
    private var streamTask: Task<Void, Never>?

    private var enableDebugLogging: Bool {
        config.enableDebugLogging
    }

    // Built-in tool policy is configured in ClaudeCodeAgentConfig.
    // Agent mode can run with native Bash enabled/disabled based on tool preferences.

    init(
        runner: CLIProcessRunner,
        config: ClaudeCodeAgentConfig,
        environmentResolver: any ClaudeCodeLaunchEnvironmentResolving = ClaudeCodeLaunchEnvironmentResolver()
    ) {
        self.runner = runner
        self.config = config
        self.environmentResolver = environmentResolver
    }

    // MARK: - HeadlessAgentProvider

    func prepare(runID: UUID? = nil) async throws -> HeadlessAgentContext {
        let actualRunID = runID ?? UUID()
        if enableDebugLogging {
            print("[DEBUG] ClaudeCodeAgent: Preparing context for run \(actualRunID)")
        }
        do {
            if enableDebugLogging {
                print("[DEBUG] ClaudeCodeAgent: Verifying MCP server is running")
            }
            let isRunning = await ServerNetworkManager.shared.isRunning()
            if enableDebugLogging {
                print("[DEBUG] ClaudeCodeAgent: MCP server running: \(isRunning)")
            }
            guard isRunning else {
                throw AIProviderError.invalidConfiguration(detail: "Could not start MCP server. Check MCP settings and try again.")
            }
            if enableDebugLogging {
                print("[DEBUG] ClaudeCodeAgent: Preparing config file")
            }
            let configLease = try await configService.prepareLaunchConfig()
            if enableDebugLogging {
                print("[DEBUG] ClaudeCodeAgent: Config file at: \(configLease.url.path)")
            }
            let launchEnvironment = try await environmentResolver.resolve(
                variant: config.runtimeVariant,
                requestedModel: config.modelString
            )
            return HeadlessAgentContext(
                runID: actualRunID,
                configLease: configLease,
                environment: ProcessInfo.processInfo.environment,
                launchEnvironment: launchEnvironment
            )
        } catch let error as AIProviderError {
            if enableDebugLogging {
                print("[DEBUG] ClaudeCodeAgent: Preparation failed with AIProviderError: \(error)")
            }
            throw error
        } catch {
            if enableDebugLogging {
                print("[DEBUG] ClaudeCodeAgent: Preparation failed: \(error)")
            }
            throw AIProviderError.invalidConfiguration(detail: "Failed to prepare agent run: \(error.localizedDescription)")
        }
    }

    func buildArguments(
        context: HeadlessAgentContext,
        resumeSessionID: String? = nil,
        systemPromptOverride: String? = nil
    ) -> [String] {
        if enableDebugLogging, let sessionID = resumeSessionID {
            print("[DEBUG] ClaudeCodeAgent: Resuming session: \(sessionID)")
        }
        if enableDebugLogging, let model = context.launchEnvironment?.effectiveModel {
            print("[DEBUG] ClaudeCodeAgent: Using model: \(model)")
        }
        let args = ClaudeCompatibleProviderRuntimeBridge.buildHeadlessArguments(
            config: config,
            context: context,
            resumeSessionID: resumeSessionID,
            systemPromptOverride: systemPromptOverride
        )
        if enableDebugLogging {
            print("[DEBUG] ClaudeCodeAgent: Built arguments (count: \(args.count))")
        }
        return args
    }

    func parseStreamEvents(_ lineData: Data) throws -> [AgentStreamEvent] {
        guard let trimmed = trimmedASCIIWhitespace(lineData), !trimmed.isEmpty else { return [] }
        let raw = try JSONSerialization.jsonObject(with: trimmed)
        if let json = raw as? [String: Any] {
            return parseEventDictionary(json)
        } else if let array = raw as? [Any] {
            var events: [AgentStreamEvent] = []
            for element in array {
                guard let dict = element as? [String: Any] else {
                    if enableDebugLogging,
                       let snippet = String(data: trimmed.prefix(100), encoding: .utf8)
                    {
                        print("[DEBUG] ClaudeCodeAgent: Skipping non-dictionary entry in array payload: \(snippet)")
                    }
                    continue
                }
                let parsed = parseEventDictionary(dict)
                events.append(contentsOf: parsed)
            }
            return events
        } else {
            if enableDebugLogging,
               let snippet = String(data: trimmed.prefix(100), encoding: .utf8)
            {
                print("[DEBUG] ClaudeCodeAgent: Unsupported JSON payload: \(snippet)")
            }
            return []
        }
    }

    /// Parse a single event dictionary into one or more AgentStreamEvents.
    /// Returns an array because some events (like `result`) emit multiple events.
    private func parseEventDictionary(_ json: [String: Any]) -> [AgentStreamEvent] {
        guard let type = json["type"] as? String else {
            if enableDebugLogging {
                print("[DEBUG] ClaudeCodeAgent: Missing type field in event payload")
            }
            return []
        }
        if enableDebugLogging {
            print("[DEBUG] ClaudeCodeAgent: Parsing event type: \(type)")
        }
        switch type {
        case "init":
            return [.lifecycle(.initialized)]
        case "message", "assistant":
            // Claude Code CLI format: content is nested at message.content as array of blocks.
            if let messageObj = json["message"] as? [String: Any],
               let contentArray = messageObj["content"] as? [[String: Any]]
            {
                var events: [AgentStreamEvent] = []
                for block in contentArray {
                    switch block["type"] as? String {
                    case "text":
                        if let text = block["text"] as? String, !text.isEmpty {
                            events.append(.message(content: text, reasoning: nil))
                        }
                    case "thinking":
                        guard ClaudeReasoningExtractionFeature.isEnabled else { continue }
                        if let thinking = block["thinking"] as? String, !thinking.isEmpty {
                            events.append(.message(content: "", reasoning: thinking))
                        }
                    case "tool_use":
                        let name = (block["name"] as? String) ?? "tool"
                        let args = (block["input"] as? [String: Any]) ?? [:]
                        events.append(.toolCall(name: name, args: args))
                    case "tool_result":
                        let name = ClaudeEventParser.extractString(block["name"]) ?? "tool"
                        let output = ClaudeEventParser.extractString(block["content"])
                            ?? encodeAnyToJSON(block["content"])
                            ?? ""
                        events.append(.toolResult(name: name, result: output))
                    default:
                        continue
                    }
                }
                if events.isEmpty {
                    if enableDebugLogging {
                        print("[DEBUG] ClaudeCodeAgent: Skipping empty assistant message")
                    }
                    return []
                }
                return events
            } else {
                // Fallback to old format for compatibility
                let content = ClaudeEventParser.extractString(json["content"]) ?? ""
                let reasoning = ClaudeReasoningExtractionFeature.isEnabled ? ClaudeEventParser.extractString(json["reasoning"]) : nil
                if !content.isEmpty || reasoning != nil {
                    return [.message(content: content, reasoning: reasoning)]
                }
                if enableDebugLogging {
                    print("[DEBUG] ClaudeCodeAgent: Skipping empty assistant message")
                }
                return []
            }
        case "tool_use":
            let name = ClaudeEventParser.extractString(json["tool_name"]) ?? "tool"
            let args = ClaudeEventParser.extractDictionary(json["tool_args"])
            return [.toolCall(name: name, args: args)]
        case "tool_result":
            let name = ClaudeEventParser.extractString(json["tool_name"]) ?? "tool"
            let result = ClaudeEventParser.extractString(json["tool_result"]) ?? ""
            return [.toolResult(name: name, result: result)]
        case "stream_event":
            guard
                let event = json["event"] as? [String: Any],
                let eventType = event["type"] as? String,
                eventType == "content_block_delta",
                let delta = event["delta"] as? [String: Any],
                let deltaType = delta["type"] as? String
            else {
                return []
            }
            switch deltaType {
            case "text_delta":
                guard let text = delta["text"] as? String, !text.isEmpty else { return [] }
                return [.message(content: text, reasoning: nil)]
            case "thinking_delta":
                guard ClaudeReasoningExtractionFeature.isEnabled else { return [] }
                guard let thinking = delta["thinking"] as? String, !thinking.isEmpty else { return [] }
                return [.message(content: "", reasoning: thinking)]
            default:
                return []
            }
        case "result":
            // Parse usage and cost
            let usageDict = json["usage"] as? [String: Any]
            let usage = ClaudeEventParser.parseUsage(usageDict)
            let cost = json["total_cost_usd"] as? Double
            let stopReason = (json["stop_reason"] as? String ?? json["stopReason"] as? String)

            // Extract session_id for resumption (check both snake_case and camelCase)
            let sessionID = json["session_id"] as? String ?? json["sessionId"] as? String
            if enableDebugLogging, sessionID != nil {
                print("[DEBUG] ClaudeCodeAgent: Captured session_id for resumption: \(sessionID!)")
            }

            // Extract final result text if present
            let finalText = json["result"] as? String

            // Build events: optional stop-reason system message, final message, then completion
            var events: [AgentStreamEvent] = []
            if let stopReason = stopReason?.trimmingCharacters(in: .whitespacesAndNewlines),
               !stopReason.isEmpty,
               stopReason.lowercased() != "end_turn"
            {
                events.append(.system(message: "Claude stop reason: \(stopReason)"))
            }
            if let text = finalText, !text.isEmpty {
                events.append(.finalMessage(content: text))
            }
            events.append(.completion(usage: usage, cost: cost, providerSessionID: sessionID))
            return events
        case "system":
            // Check for subtype (e.g., "init") which doesn't have a message field
            let subtype = json["subtype"] as? String
            if subtype == "init" {
                return [.lifecycle(.initialized)]
            }
            let message = ClaudeEventParser.extractString(json["message"]) ?? ""
            // Skip empty system messages to avoid showing empty info icons
            if message.isEmpty {
                if enableDebugLogging {
                    print("[DEBUG] ClaudeCodeAgent: Skipping empty system message")
                }
                return []
            }
            return [.system(message: message)]
        case "tool_progress":
            if let progress = ClaudeEventParser.extractString(json["message"]) ?? ClaudeEventParser.extractString(json["progress"]) {
                let trimmed = progress.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return [.system(message: trimmed)]
                }
            }
            return []
        case "auth_status":
            let status = ClaudeEventParser.extractString(json["status"]) ?? ClaudeEventParser.extractString(json["auth_status"]) ?? ClaudeEventParser.extractString(json["authStatus"])
            let message = ClaudeEventParser.extractString(json["message"])
            let fragments = [status, message].compactMap { value -> String? in
                guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                    return nil
                }
                return value
            }
            if !fragments.isEmpty {
                return [.system(message: fragments.joined(separator: " — "))]
            }
            return []
        case "user":
            if enableDebugLogging {
                print("[DEBUG] ClaudeCodeAgent: Skipping user echo message")
            }
            return []
        default:
            if enableDebugLogging {
                print("[DEBUG] ClaudeCodeAgent: Unknown event type: \(type)")
            }
            return []
        }
    }

    func cleanup(context: HeadlessAgentContext) async {
        if enableDebugLogging {
            print("[DEBUG] ClaudeCodeAgent: Cleaning up context \(context.runID)")
        }
        if let configLease = context.configLease {
            let configURL = configLease.url
            configLease.release()
            if enableDebugLogging {
                print("[DEBUG] ClaudeCodeAgent: Cleaned up config file at \(configURL.path)")
            }
        }
    }

    // MARK: - Streaming

    func streamAgentMessage(_ message: AgentMessage, runID: UUID? = nil) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        AsyncThrowingStream { continuation in
            // Cancel any previous lingering task (defensive)
            self.streamTask?.cancel()
            self.streamTask = Task {
                await withTaskCancellationHandler(operation: {
                    do {
                        if self.enableDebugLogging {
                            print("[DEBUG] ClaudeCodeAgent: Starting streamAgentMessage with runID: \(runID?.uuidString ?? "auto-generated")")
                        }
                        let context = try await self.prepare(runID: runID)
                        try await AsyncScope.withCleanup({}, cleanup: {
                            await self.cleanup(context: context)
                        }) {
                            let nativePromptMode = ClaudeAgentToolPreferences.agentModePromptDelivery()
                            let userMessage = ClaudeCompatibleProviderRuntimeBridge.providerBoundUserMessage(
                                message.userMessage,
                                instructions: message.systemPrompt,
                                delivery: nativePromptMode
                            )
                            if self.enableDebugLogging {
                                print("[DEBUG] ClaudeCodeAgent: User message length: \(userMessage.count)")
                            }
                            let args = self.buildArguments(
                                context: context,
                                resumeSessionID: message.resumeSessionID,
                                systemPromptOverride: nativePromptMode.nativeSystemPromptOverride(instructions: message.systemPrompt)
                            )

                            if self.enableDebugLogging {
                                print("[DEBUG] ClaudeCodeAgent: Running CLI process")
                            }
                            let additionalEnvironment = self.config.effortEnvironmentOverrides.merging(
                                context.launchEnvironment?.environmentOverrides ?? [:]
                            ) { _, resolverValue in resolverValue }
                            let expectedPIDRunID = context.runID
                            let expectedPIDClientName = self.config.runtimeVariant.agentKind.mcpClientNameHint
                            let stream = try await self.runner.runStreaming(
                                args: args,
                                stdin: userMessage, // Pass the user message via stdin
                                outputMode: .auto(.streamJson),
                                timeout: 6000, // 100 minute timeout (matches Codex)
                                additionalEnvironment: additionalEnvironment,
                                additionalRemovedKeys: context.launchEnvironment?.removedEnvironmentKeys ?? [],
                                onProcessStarted: { pid in
                                    guard let expectedPIDClientName else { return }
                                    await ServerNetworkManager.shared.registerExpectedAgentPID(
                                        pid,
                                        for: expectedPIDClientName,
                                        runID: expectedPIDRunID
                                    )
                                },
                                onProcessTerminated: { pid in
                                    guard let expectedPIDClientName else { return }
                                    await ServerNetworkManager.shared.clearExpectedAgentPID(
                                        pid,
                                        for: expectedPIDClientName,
                                        runID: expectedPIDRunID
                                    )
                                }
                            )
                            try await AsyncScope.withCleanup({}, cleanup: {
                                await self.runner.cancelAll()
                                await self.toolTracking.stopTracking()
                            }) {
                                if self.enableDebugLogging {
                                    print("[DEBUG] ClaudeCodeAgent: CLI process streaming started")
                                }

                                self.toolTracking.startTracking(
                                    runID: context.runID,
                                    clientNameHint: "claude-code",
                                    continuation: continuation
                                )
                                var framer = LineFramer()
                                var stdoutTail = Data()
                                var stderrTail = Data()
                                var exitStatus: Int32?
                                var timedOut = false
                                var eventCount = 0
                                var sawCompletion = false

                                do {
                                    outerLoop: for try await event in stream {
                                        try Task.checkCancellation()
                                        switch event {
                                        case let .stdout(chunk):
                                            appendTail(&stdoutTail, chunk: chunk, limit: 128 * 1024)
                                            var sawStopThisChunk = false
                                            framer.feed(chunk) { lineData in
                                                if sawStopThisChunk { return }
                                                guard !lineData.isEmpty else { return }
                                                if Task.isCancelled {
                                                    return
                                                }
                                                if let events = try? self.parseStreamEvents(lineData), !events.isEmpty {
                                                    for event in events {
                                                        let mapped = self.mapToAIStreamResult(event)
                                                        if mapped.type == "message_stop" {
                                                            sawCompletion = true
                                                            sawStopThisChunk = true
                                                        }
                                                        continuation.yield(mapped)
                                                        eventCount += 1
                                                        if sawStopThisChunk { break }
                                                    }
                                                }
                                            }
                                            if sawStopThisChunk {
                                                break outerLoop
                                            }
                                        case let .stderr(chunk):
                                            appendTail(&stderrTail, chunk: chunk, limit: 256 * 1024)
                                        case let .terminated(status, didTimeout):
                                            exitStatus = status
                                            timedOut = didTimeout
                                        }
                                    }
                                } catch {
                                    if self.enableDebugLogging {
                                        print("[DEBUG] ClaudeCodeAgent: Streaming loop error: \(error)")
                                    }
                                    throw error
                                }

                                framer.flush { lineData in
                                    guard !lineData.isEmpty else { return }
                                    if let events = try? self.parseStreamEvents(lineData), !events.isEmpty {
                                        for event in events {
                                            let mapped = self.mapToAIStreamResult(event)
                                            if mapped.type == "message_stop" {
                                                sawCompletion = true
                                            }
                                            continuation.yield(mapped)
                                            eventCount += 1
                                        }
                                    }
                                }

                                // If we saw completion but no explicit termination yet,
                                // proactively stop the underlying process to finish quicker.
                                if sawCompletion && exitStatus == nil {
                                    if self.enableDebugLogging {
                                        print("[DEBUG] ClaudeCodeAgent: Completion seen; cancelling runner to close pipes.")
                                    }
                                    await self.runner.cancelAll()
                                }

                                if self.enableDebugLogging {
                                    print("[DEBUG] ClaudeCodeAgent: Yielded \(eventCount) events")
                                }
                                if exitStatus == nil {
                                    if sawCompletion {
                                        if self.enableDebugLogging {
                                            print("[DEBUG] ClaudeCodeAgent: No termination status, but completion event observed. Treating as success.")
                                        }
                                        continuation.finish()
                                        return
                                    } else {
                                        throw AIProviderError.apiError(source: NSError(domain: "ClaudeCLI", code: -999, userInfo: [NSLocalizedDescriptionKey: "Claude CLI did not report a termination status."]))
                                    }
                                }

                                // If we have an exit status, validate it
                                let status = exitStatus ?? 0
                                if status != 0 || timedOut {
                                    if let humanMessage = self.extractCLIErrorDetail(fromStdout: stdoutTail) {
                                        // Check for credit balance error and provide helpful guidance
                                        let lowerMessage = humanMessage.lowercased()
                                        if lowerMessage.contains("credit balance") || lowerMessage.contains("balance too low") || lowerMessage.contains("api balance") {
                                            throw AIProviderError.invalidConfiguration(detail: "Credit balance is too low. To use Claude Code with your Max plan via RepoPrompt, remove the ANTHROPIC_API_KEY from your environment variables and restart the app. The CLI will then use your Max plan subscription instead of the API key.")
                                        }
                                        throw AIProviderError.invalidConfiguration(detail: humanMessage)
                                    }
                                    let stderrString = String(data: stderrTail, encoding: .utf8) ?? ""
                                    if self.enableDebugLogging {
                                        print("[DEBUG] ClaudeCodeAgent: Process failed with stderr: \(stderrString)")
                                    }
                                    throw self.mapProcessFailure(exitCode: status, stderr: stderrString, timedOut: timedOut)
                                }

                                continuation.finish()
                            }
                        }
                    } catch {
                        if self.enableDebugLogging {
                            print("[DEBUG] ClaudeCodeAgent: Stream error: \(error)")
                        }
                        continuation.finish(throwing: self.mapError(error))
                    }
                }, onCancel: { [weak self] in
                    if self?.enableDebugLogging == true {
                        print("[DEBUG] ClaudeCodeAgent: stream task cancellation – cancelling runner")
                    }
                    Task { [weak self] in
                        // Kill the child aggressively, then ensure our outer stream ends.
                        await self?.runner.cancelAll()
                        continuation.finish()
                    }
                })
            }
            // If the consumer drops the outer stream, stop our task immediately.
            continuation.onTermination = { [weak self] _ in
                self?.streamTask?.cancel()
            }
        }
    }

    func dispose() async {
        if enableDebugLogging {
            print("[DEBUG] ClaudeCodeAgent: Disposing provider, cancelling stream task & runners")
        }
        streamTask?.cancel()
        await runner.cancelAll()
    }

    // MARK: - Helpers

    private func mapToAIStreamResult(_ event: AgentStreamEvent) -> AIStreamResult {
        switch event {
        case let .message(content, reasoning):
            if content.isEmpty, let reasoning, !reasoning.isEmpty {
                return AIStreamResult(type: "reasoning", text: nil, reasoning: reasoning)
            }
            return AIStreamResult(type: "content", text: content, reasoning: reasoning)
        case let .finalMessage(content):
            // Final authoritative message content - replaces streaming content
            return AIStreamResult(type: "final_content", text: content)
        case let .toolCall(name, args):
            // Emit structured tool_call event with args preserved
            let argsJSON = encodeArgsToJSON(args)
            return AIStreamResult(type: "tool_call", text: nil, toolName: name, toolArgs: argsJSON, toolArgsJSON: argsJSON)
        case let .toolResult(name, result):
            // Emit structured tool_result event with full result preserved
            return AIStreamResult(type: "tool_result", text: nil, toolName: name, toolOutput: result, toolResultJSON: result)
        case let .system(message):
            return AIStreamResult(type: "system", text: message)
        case let .lifecycle(lifecycle):
            return AIStreamResult(type: AIStreamResult.lifecycleType, text: String(describing: lifecycle))
        case let .completion(usage, cost, providerSessionID):
            return AIStreamResult(
                type: "message_stop",
                text: nil,
                promptTokens: usage?.inputTokens,
                completionTokens: usage?.outputTokens,
                cost: cost,
                providerSessionID: providerSessionID
            )
        }
    }

    /// Encode tool arguments dictionary to JSON string for display
    private func encodeArgsToJSON(_ args: [String: Any]) -> String? {
        guard !args.isEmpty else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: args, options: [.prettyPrinted, .sortedKeys]),
              let jsonString = String(data: data, encoding: .utf8)
        else { return nil }
        return jsonString
    }

    private func encodeAnyToJSON(_ value: Any?) -> String? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func mapError(_ error: Error) -> Error {
        if let runnerError = error as? CLIProcessRunnerError {
            switch runnerError {
            case let .commandNotFound(command):
                return AIProviderError.invalidConfiguration(detail: "Claude CLI not found (\(command)). Install it with `brew install claude` and retry.")
            case let .spawnFailed(message):
                return AIProviderError.invalidConfiguration(detail: message)
            default:
                return runnerError
            }
        }
        return error
    }

    func extractCLIErrorDetail(fromStdout data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true).reversed()

        // First pass: look for structured JSON errors
        for slice in lines {
            let candidate = Data(slice)
            guard let trimmed = trimmedASCIIWhitespace(candidate) else { continue }
            if let message = try? decoder.decode(ClaudeResultMessage.self, from: trimmed),
               let text = message.result?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty
            {
                return text
            }
            if let json = try? JSONSerialization.jsonObject(with: trimmed) as? [String: Any] {
                if let text = (json["result"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    return text
                }
                if let text = (json["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    return text
                }
                if let text = (json["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    return text
                }
            }
        }

        // Second pass: if no JSON found, return plain-text diagnostics (common when CLI fails before JSON mode)
        for slice in lines {
            let candidate = Data(slice)
            guard let trimmed = trimmedASCIIWhitespace(candidate) else { continue }
            if let plainText = String(data: trimmed, encoding: .utf8) {
                let cleaned = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                // Skip empty lines and common noise
                if !cleaned.isEmpty, !cleaned.hasPrefix("{"), !cleaned.hasPrefix("[") {
                    return cleaned
                }
            }
        }
        return nil
    }

    private func mapProcessFailure(exitCode: Int32, stderr: String, timedOut: Bool) -> Error {
        if timedOut {
            return AIProviderError.invalidConfiguration(detail: "Claude CLI timed out. Please retry shortly.")
        }
        let lower = stderr.lowercased()
        if lower.contains("command not found") || lower.contains("no such file") {
            return AIProviderError.invalidConfiguration(detail: "Claude CLI not found. Install it and ensure it is available on PATH.")
        }
        if lower.contains("unauthorized") || lower.contains("login") {
            return AIProviderError.invalidConfiguration(detail: "Claude CLI not authenticated. Run `claude login` in a terminal and try again.")
        }
        if lower.contains("rate limit") || lower.contains("too many requests") {
            return AIProviderError.invalidConfiguration(detail: "Claude CLI rate limited. Please wait and retry.")
        }
        if lower.contains("overload") || lower.contains("busy") || lower.contains("unavailable") {
            return AIProviderError.invalidConfiguration(detail: "Claude CLI backend overloaded. Please retry soon.")
        }
        if stderr.isEmpty {
            return AIProviderError.apiError(source: NSError(domain: "ClaudeCLI", code: Int(exitCode), userInfo: [NSLocalizedDescriptionKey: "Claude CLI exited with status \(exitCode)"]))
        }
        return AIProviderError.apiError(source: NSError(domain: "ClaudeCLI", code: Int(exitCode), userInfo: [NSLocalizedDescriptionKey: stderr]))
    }
}

private enum ClaudeEventParser {
    static func extractString(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let dict as [String: Any]:
            if let text = dict["text"] as? String { return text }
            return nil
        case let array as [Any]:
            return array.compactMap { extractString($0) }.joined(separator: "")
        default:
            return nil
        }
    }

    static func extractDictionary(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    static func parseUsage(_ value: [String: Any]?) -> TokenUsage? {
        guard let value else { return nil }
        let input = Self.numberToInt(value["input_tokens"]) ?? Self.numberToInt(value["inputTokens"])
        let output = Self.numberToInt(value["output_tokens"]) ?? Self.numberToInt(value["outputTokens"])
        if let input, let output {
            return TokenUsage(inputTokens: input, outputTokens: output)
        }
        return nil
    }

    private static func numberToInt(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            int
        case let double as Double:
            Int(double)
        case let string as String:
            Int(string)
        default:
            nil
        }
    }
}
