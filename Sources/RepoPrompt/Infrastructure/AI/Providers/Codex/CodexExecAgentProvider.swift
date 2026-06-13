import Foundation

final class CodexExecAgentProvider: HeadlessAgentProvider {
    private enum StreamRetryAction {
        case none
        case modelFallback(String)
        case brokenServer(String)
    }

    private static let codexMCPClientID = AgentProviderKind.codexMCPClientID

    private let runner: CLIProcessRunner
    private let config: CodexExecAgentConfig
    private let configService = MCPConfigExportService.shared
    private let toolTracking = AgentToolTrackingController()
    private var streamTask: Task<Void, Never>?
    private var codexItemInvocationIDs: [String: UUID] = [:]

    private var enableDebugLogging: Bool {
        config.enableDebugLogging
    }

    init(runner: CLIProcessRunner, config: CodexExecAgentConfig) {
        self.runner = runner
        self.config = config
        if enableDebugLogging {
            print("[DEBUG] CodexExec: Initialized provider with model: \(config.modelString ?? "default")")
        }
    }

    static func codexModelCLIArgs(
        selectedModelString: String?
    ) -> (modelArgs: [String], configArgs: [String], specifier: CodexModelSpecifier) {
        let specifier = CodexModelSpecifier(raw: selectedModelString)
        return (
            specifier.cliModelArgs,
            specifier.cliReasoningConfigArgs + specifier.cliServiceTierConfigArgs,
            specifier
        )
    }

    static func buildCodexExecArguments(
        selectedModelString: String?,
        serverEntries: [MCPIntegrationHelper.CodexServerEntry],
        brokenServers: Set<String>
    ) -> (args: [String], modelSpecifier: CodexModelSpecifier) {
        var args: [String] = []
        let modelCLIArgs = codexModelCLIArgs(selectedModelString: selectedModelString)
        let modelSpecifier = modelCLIArgs.specifier

        // Add model argument BEFORE exec if specified (and not "default").
        if selectedModelString != nil, !modelCLIArgs.modelArgs.isEmpty {
            args.append(contentsOf: modelCLIArgs.modelArgs)
        }

        let toolPolicy = CodexOverrides.ToolPolicy(
            toolOutputTokenLimit: MCPIntegrationHelper.desiredCodexToolOutputTokenLimit,
            shellToolEnabled: false,
            webSearchRequestEnabled: nil,
            viewImageToolEnabled: false,
            includeApplyPatchTool: false,
            parallelToolCallsEnabled: false,
            multiAgentEnabled: false,
            modelReasoningSummary: nil
        )
        let toolOverrideArgs = CodexOverrides.cliConfigArgs(toolPolicy: toolPolicy)
        let serverOverrideArgs = CodexOverrides.cliMCPServerArgs(
            entries: serverEntries,
            policy: .enableOnlyRepoPrompt(
                repoPromptNormalizedName: MCPIntegrationHelper.repoPromptMCPServerName,
                exceptBroken: brokenServers
            )
        )

        // Add exec subcommand and its arguments.
        args.append("exec")
        args.append(contentsOf: modelCLIArgs.configArgs)
        args.append(contentsOf: toolOverrideArgs)
        args.append(contentsOf: serverOverrideArgs)
        args.append(contentsOf: [
            "--json",
            "--skip-git-repo-check",
            "--full-auto"
        ])

        return (args, modelSpecifier)
    }

    // MARK: - HeadlessAgentProvider

    func prepare(runID: UUID? = nil) async throws -> HeadlessAgentContext {
        let actualRunID = runID ?? UUID()
        if enableDebugLogging {
            print("[DEBUG] CodexExec: Preparing context for run \(actualRunID)")
        }

        // Verify MCP server is running
        if enableDebugLogging {
            print("[DEBUG] CodexExec: Verifying MCP server is running")
        }
        guard await ServerNetworkManager.shared.isRunning() else {
            throw AIProviderError.invalidConfiguration(detail: "Could not start MCP server. Check MCP settings and try again.")
        }
        if enableDebugLogging {
            print("[DEBUG] CodexExec: MCP server is running")
        }

        // Ensure the RepoPrompt MCP server entry exists
        if enableDebugLogging {
            print("[DEBUG] CodexExec: Ensuring Codex MCP server entry")
        }
        let (ensureSuccess, wasAlreadyPresent) = MCPIntegrationHelper.ensureCodexServerForDiscovery()
        guard ensureSuccess else {
            throw AIProviderError.invalidConfiguration(detail: "Failed to install RepoPrompt MCP config for Codex CLI.")
        }
        if enableDebugLogging {
            print("[DEBUG] CodexExec: MCP server ensured (wasAlreadyPresent: \(wasAlreadyPresent))")
        }

        return HeadlessAgentContext(
            runID: actualRunID,
            configURL: nil,
            environment: ProcessInfo.processInfo.environment
        )
    }

    func cleanup(context: HeadlessAgentContext) async {
        if enableDebugLogging {
            print("[DEBUG] CodexExec: Cleaning up context \(context.runID)")
        }
    }

    // MARK: - Streaming

    func streamAgentMessage(_ message: AgentMessage, runID: UUID? = nil) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        AsyncThrowingStream { continuation in
            // Cancel any previous lingering task (defensive)
            self.streamTask?.cancel()
            self.streamTask = Task { [weak self] in
                guard let self else { return }
                await withTaskCancellationHandler(operation: {
                    // Try up to 3 times total to allow one retry for model fallback and one for broken server.
                    var attemptNumber = 0
                    let maxAttempts = 3
                    var attemptModelString = self.config.modelString
                    var didRetryBrokenServer = false
                    var didRetryModelFallback = false

                    while attemptNumber < maxAttempts {
                        attemptNumber += 1
                        let selectedModelString = attemptModelString
                        var shouldRetryBrokenServer = false
                        var shouldRetryModelFallback = false
                        codexItemInvocationIDs = [:]

                        do {
                            if self.enableDebugLogging {
                                print("[DEBUG] CodexExec: Starting streamAgentMessage attempt \(attemptNumber) with runID: \(runID?.uuidString ?? "auto-generated"), model: \(selectedModelString ?? "default")")
                            }

                            let context = try await self.prepare(runID: runID)
                            try await AsyncScope.withCleanup({}, cleanup: {
                                await self.cleanup(context: context)
                            }) {
                                let systemPrompt = message.systemPrompt
                                let userMessage = message.userMessage

                                // Combine system prompt with user message
                                let combinedPrompt = """
                                \(systemPrompt)

                                \(userMessage)
                                """

                                let serverEntries = MCPIntegrationHelper.codexMCPServerEntries()
                                let brokenServers = await CodexBrokenServersCache.shared.getAll()
                                let command = Self.buildCodexExecArguments(
                                    selectedModelString: selectedModelString,
                                    serverEntries: serverEntries,
                                    brokenServers: brokenServers
                                )
                                let args = command.args
                                let modelSpecifier = command.modelSpecifier

                                if self.enableDebugLogging {
                                    if selectedModelString != nil, let baseModel = modelSpecifier.baseModel {
                                        print("[DEBUG] CodexExec: Using model: \(baseModel)")
                                    }
                                    print("[DEBUG] CodexExec: MCP servers detected: \(serverEntries.map(\.normalizedName))")
                                    if !brokenServers.isEmpty {
                                        print("[DEBUG] CodexExec: Broken servers (will not disable): \(brokenServers)")
                                    }
                                    if let reasoningEffort = modelSpecifier.reasoningEffort {
                                        print("[DEBUG] CodexExec: Using reasoning effort: \(reasoningEffort.rawValue)")
                                    }
                                    if !modelSpecifier.cliServiceTierConfigArgs.isEmpty,
                                       let serviceTier = modelSpecifier.appServerServiceTierParam
                                    {
                                        print("[DEBUG] CodexExec: Using service tier: \(serviceTier)")
                                    }
                                    print("[DEBUG] CodexExec: Running codex with args: \(args)")
                                    print("[DEBUG] CodexExec: Combined prompt length: \(combinedPrompt.count) characters")
                                }

                                // Register tool observer with cleanup
                                try await AsyncScope.withCleanup({}, cleanup: {
                                    await self.runner.cancelAll()
                                    await self.toolTracking.stopTracking()
                                }) {
                                    if self.enableDebugLogging {
                                        print("[DEBUG] CodexExec: CLI process streaming started")
                                    }

                                    self.toolTracking.startTracking(
                                        runID: context.runID,
                                        clientNameHint: Self.codexMCPClientID,
                                        continuation: continuation
                                    )

                                    if self.enableDebugLogging {
                                        print("[DEBUG] CodexExec: Starting stream with timeout 6000s")
                                    }

                                    let expectedPIDRunID = context.runID
                                    let stream = try await self.runner.runStreaming(
                                        args: args,
                                        stdin: combinedPrompt,
                                        outputMode: .none,
                                        timeout: 6000,
                                        onProcessStarted: { pid in
                                            await ServerNetworkManager.shared.registerExpectedAgentPID(
                                                pid,
                                                for: Self.codexMCPClientID,
                                                runID: expectedPIDRunID
                                            )
                                        },
                                        onProcessTerminated: { pid in
                                            await ServerNetworkManager.shared.clearExpectedAgentPID(
                                                pid,
                                                for: Self.codexMCPClientID,
                                                runID: expectedPIDRunID
                                            )
                                        }
                                    )

                                    var framer = LineFramer()
                                    var stderrFramer = LineFramer()
                                    var stdoutTail = Data()
                                    var stderrTail = Data()
                                    var exitStatus: Int32?
                                    var timedOut = false
                                    var sawCompletion = false

                                    if self.enableDebugLogging {
                                        print("[DEBUG] CodexExec: Stream started, reading events...")
                                    }

                                    outerLoop: for try await event in stream {
                                        switch event {
                                        case let .stdout(chunk):
                                            appendTail(&stdoutTail, chunk: chunk, limit: 128 * 1024)
                                            if self.enableDebugLogging {
                                                print("[DEBUG] CodexExec: Received stdout chunk: \(chunk.count) bytes")
                                            }
                                            var sawStopThisChunk = false
                                            framer.feed(chunk) { lineData in
                                                if sawStopThisChunk { return }
                                                if let streamResult = self.parseJSONLEvent(lineData) {
                                                    if self.enableDebugLogging {
                                                        print("[DEBUG] CodexExec: Parsed event type: \(streamResult.type)")
                                                    }
                                                    if streamResult.type == "message_stop" {
                                                        sawCompletion = true
                                                        sawStopThisChunk = true
                                                    }
                                                    continuation.yield(streamResult)
                                                }
                                            }
                                            if sawStopThisChunk {
                                                break outerLoop
                                            }
                                        case let .stderr(chunk):
                                            appendTail(&stderrTail, chunk: chunk, limit: 256 * 1024)
                                            stderrFramer.feed(chunk) { lineData in
                                                guard let message = String(data: lineData, encoding: .utf8)?
                                                    .trimmingCharacters(in: .whitespacesAndNewlines),
                                                    !message.isEmpty
                                                else { return }

                                                if self.enableDebugLogging {
                                                    print("[DEBUG] CodexExec: STDERR: \(message)")
                                                }

                                                if !CodexExecDiagnosticNoiseFilter.shouldSuppress(message) {
                                                    continuation.yield(
                                                        AIStreamResult(
                                                            type: "system",
                                                            text: message,
                                                            reasoning: nil,
                                                            promptTokens: nil,
                                                            completionTokens: nil,
                                                            cost: nil
                                                        )
                                                    )
                                                }
                                            }
                                        case let .terminated(status, didTimeout):
                                            exitStatus = status
                                            timedOut = didTimeout
                                            if self.enableDebugLogging {
                                                print("[DEBUG] CodexExec: Process terminated - status: \(status), timedOut: \(didTimeout)")
                                            }
                                        }
                                    }

                                    // If we saw completion but no explicit termination yet,
                                    // proactively stop the underlying process to finish quicker.
                                    if sawCompletion && exitStatus == nil {
                                        if self.enableDebugLogging {
                                            print("[DEBUG] CodexExec: Completion seen; cancelling runner to close pipes.")
                                        }
                                        await self.runner.cancelAll()
                                    }

                                    // Process any trailing data without newline
                                    framer.flush { line in
                                        if let trailing = self.parseJSONLEvent(line) {
                                            if self.enableDebugLogging {
                                                print("[DEBUG] CodexExec: Parsed trailing event type: \(trailing.type)")
                                            }
                                            if trailing.type == "message_stop" {
                                                sawCompletion = true
                                            }
                                            continuation.yield(trailing)
                                        }
                                    }

                                    // Flush any trailing stderr line
                                    stderrFramer.flush { lineData in
                                        guard let message = String(data: lineData, encoding: .utf8)?
                                            .trimmingCharacters(in: .whitespacesAndNewlines),
                                            !message.isEmpty
                                        else { return }
                                        if !CodexExecDiagnosticNoiseFilter.shouldSuppress(message) {
                                            continuation.yield(
                                                AIStreamResult(
                                                    type: "system",
                                                    text: message,
                                                    reasoning: nil,
                                                    promptTokens: nil,
                                                    completionTokens: nil,
                                                    cost: nil
                                                )
                                            )
                                        }
                                    }

                                    if exitStatus == nil && !sawCompletion {
                                        if self.enableDebugLogging {
                                            print("[DEBUG] CodexExec: ERROR - No exit status received")
                                        }
                                        throw AIProviderError.apiError(source: NSError(domain: "CodexCLI", code: -999, userInfo: [NSLocalizedDescriptionKey: "codex exec did not report a termination status."]))
                                    }

                                    // If we have an exit status, validate it
                                    let status = exitStatus ?? 0
                                    if status != 0 || timedOut {
                                        let stdoutMessage = self.extractCLIErrorDetail(fromStdout: stdoutTail)
                                        let stderrString = String(data: stderrTail, encoding: .utf8) ?? ""
                                        let retryAction = self.retryActionForProcessFailure(
                                            attemptedModel: selectedModelString,
                                            stdoutMessage: stdoutMessage,
                                            stderrString: stderrString,
                                            didRetryModelFallback: didRetryModelFallback,
                                            didRetryBrokenServer: didRetryBrokenServer
                                        )

                                        switch retryAction {
                                        case let .modelFallback(fallbackModel):
                                            didRetryModelFallback = true
                                            shouldRetryModelFallback = true
                                            attemptModelString = fallbackModel
                                            self.emitModelFallbackNotice(
                                                from: selectedModelString,
                                                to: fallbackModel,
                                                continuation: continuation
                                            )
                                        case let .brokenServer(brokenServer):
                                            await CodexBrokenServersCache.shared.add(brokenServer)
                                            didRetryBrokenServer = true
                                            shouldRetryBrokenServer = true
                                            if self.enableDebugLogging {
                                                print("[DEBUG] CodexExec: Detected broken MCP server: \(brokenServer), retrying with updated exclusions")
                                            }
                                        case .none:
                                            if let stdoutMessage {
                                                if self.enableDebugLogging {
                                                    print("[DEBUG] CodexExec: ERROR from stdout: \(stdoutMessage)")
                                                }
                                                throw AIProviderError.invalidConfiguration(detail: stdoutMessage)
                                            }
                                            if self.enableDebugLogging {
                                                print("[DEBUG] CodexExec: ERROR - Exit status: \(status), stderr: \(stderrString)")
                                            }
                                            throw self.mapProcessFailure(exitCode: status, stderr: stderrString, timedOut: timedOut)
                                        }
                                    }

                                    if !shouldRetryModelFallback, !shouldRetryBrokenServer, sawCompletion == false {
                                        if self.enableDebugLogging {
                                            print("[DEBUG] CodexExec: Injecting message_stop event")
                                        }
                                        continuation.yield(
                                            AIStreamResult(
                                                type: "message_stop",
                                                text: nil,
                                                reasoning: nil,
                                                promptTokens: nil,
                                                completionTokens: nil,
                                                cost: nil
                                            )
                                        )
                                    }

                                    if !shouldRetryModelFallback, !shouldRetryBrokenServer, self.enableDebugLogging {
                                        print("[DEBUG] CodexExec: Stream completed successfully")
                                    }
                                }
                            }
                            if shouldRetryModelFallback {
                                if self.enableDebugLogging {
                                    print("[DEBUG] CodexExec: Restarting Codex exec stream with fallback model \(attemptModelString ?? "default")")
                                }
                                continue
                            }

                            if shouldRetryBrokenServer {
                                if self.enableDebugLogging {
                                    print("[DEBUG] CodexExec: Restarting Codex exec stream after excluding broken server(s)")
                                }
                                continue
                            }

                            continuation.finish()
                            return
                        } catch is CancellationError {
                            if self.enableDebugLogging {
                                print("[DEBUG] CodexExec: Task was cancelled")
                            }
                            continuation.finish(throwing: AIProviderError.invalidConfiguration(detail: "Codex Exec run cancelled."))
                            return
                        } catch {
                            if self.enableDebugLogging {
                                print("[DEBUG] CodexExec: ERROR - \(error)")
                            }
                            continuation.finish(throwing: error)
                            return
                        }
                    } // end while loop
                }, onCancel: { [weak self] in
                    if self?.enableDebugLogging == true {
                        print("[DEBUG] CodexExec: stream task cancellation – cancelling runner")
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
            print("[DEBUG] CodexExec: Disposing provider, cancelling stream task & runners")
        }
        streamTask?.cancel()
        await runner.cancelAll()
    }

    func extractUserMessage(from aiMessage: AIMessage) -> String {
        if let lastUserIndex = aiMessage.conversationMessages.lastIndex(where: { $0.role == .user }) {
            return aiMessage.conversationMessages[lastUserIndex].content
        }
        return ""
    }

    private func retryActionForProcessFailure(
        attemptedModel: String?,
        stdoutMessage: String?,
        stderrString: String,
        didRetryModelFallback: Bool,
        didRetryBrokenServer: Bool
    ) -> StreamRetryAction {
        // Check stdout first for model-not-found fallback; otherwise preserve stdout as the primary error.
        if let stdoutMessage {
            if !didRetryModelFallback,
               let fallbackModel = CodexProviderHelpers.codexFallbackModelIfNeeded(
                   attemptedModel: attemptedModel,
                   errorDetail: stdoutMessage
               )
            {
                return .modelFallback(fallbackModel)
            }
            return .none
        }

        // Fall back to stderr checks.
        if !didRetryModelFallback,
           let fallbackModel = CodexProviderHelpers.codexFallbackModelIfNeeded(
               attemptedModel: attemptedModel,
               errorDetail: stderrString
           )
        {
            return .modelFallback(fallbackModel)
        }

        if !didRetryBrokenServer,
           let brokenServer = CodexProviderHelpers.extractBrokenServerName(from: stderrString)
        {
            return .brokenServer(brokenServer)
        }

        return .none
    }

    private func emitModelFallbackNotice(
        from attemptedModel: String?,
        to fallbackModel: String,
        continuation: AsyncThrowingStream<AIStreamResult, Error>.Continuation
    ) {
        let modelLabel = attemptedModel ?? "default"
        continuation.yield(
            AIStreamResult(
                type: "system",
                text: "Requested model \(modelLabel) is unavailable. Retrying with \(fallbackModel).",
                reasoning: nil,
                promptTokens: nil,
                completionTokens: nil,
                cost: nil
            )
        )
        if enableDebugLogging {
            print("[DEBUG] CodexExec: Model not found for \(modelLabel); retrying with \(fallbackModel)")
        }
    }

    func parseJSONLEvent(_ data: Data) -> AIStreamResult? {
        guard let trimmed = trimmedASCIIWhitespace(data) else { return nil }
        guard let raw = try? JSONSerialization.jsonObject(with: trimmed) as? [String: Any] else { return nil }

        // Current/legacy format (try this first): {"type":"item.completed","item":{...}}
        if let typeValue = raw["type"] as? String {
            let result = parseCurrentFormatExec(raw, typeValue: typeValue)
            if result != nil {
                return result
            }
        }

        // Newer format (fallback for future compatibility): {"id":"0","msg":{"type":"agent_message","message":"OK"}}
        if let msg = raw["msg"] as? [String: Any],
           let msgType = msg["type"] as? String
        {
            return parseNewerFormatExec(msg, msgType: msgType)
        }

        if let typeValue = raw["type"] as? String,
           typeValue == "done" || typeValue == "message_stop"
        {
            return AIStreamResult(type: "message_stop", text: nil)
        }

        if let message = (raw["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty
        {
            return AIStreamResult(type: "system", text: message)
        }

        return nil
    }

    private func parseCurrentFormatExec(_ raw: [String: Any], typeValue: String) -> AIStreamResult? {
        switch typeValue {
        case "item.started", "item.completed":
            guard let item = raw["item"] as? [String: Any],
                  let itemType = item["type"] as? String else { return nil }
            let isStarted = (typeValue == "item.started")
            let isCompleted = (typeValue == "item.completed")

            if isCompleted {
                switch itemType {
                case "agent_message", "message", "assistant":
                    if let text = item["text"] as? String, !text.isEmpty {
                        return AIStreamResult(type: "content", text: text, reasoning: nil, promptTokens: nil, completionTokens: nil, cost: nil)
                    }
                case "reasoning":
                    if let text = item["text"] as? String, !text.isEmpty {
                        return AIStreamResult(type: "reasoning", text: nil, reasoning: text, promptTokens: nil, completionTokens: nil, cost: nil)
                    }
                default:
                    break
                }
            }
            return parseCodexToolLifecycleItem(item: item, isStarted: isStarted, isCompleted: isCompleted)

        case "turn.completed":
            let usage = raw["usage"] as? [String: Any]
            let promptTokens = usage?["input_tokens"] as? Int
            let completionTokens = usage?["output_tokens"] as? Int
            let cost = raw["total_cost_usd"] as? Double
            return AIStreamResult(
                type: "message_stop",
                text: nil,
                reasoning: nil,
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                cost: cost
            )

        case "error":
            let message = (raw["message"] as? String) ?? (raw["content"] as? String) ?? "Codex CLI reported an error."
            return AIStreamResult(type: "error", text: message, reasoning: nil, promptTokens: nil, completionTokens: nil, cost: nil)

        default:
            return nil
        }
    }

    private func parseCodexToolLifecycleItem(
        item: [String: Any],
        isStarted: Bool,
        isCompleted: Bool
    ) -> AIStreamResult? {
        guard let itemTypeRaw = item["type"] as? String else { return nil }
        let itemType = itemTypeRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard itemType != "agent_message",
              itemType != "message",
              itemType != "assistant",
              itemType != "reasoning",
              itemType != "error" else { return nil }

        guard let toolName = codexToolName(from: item, itemType: itemType) else { return nil }
        guard !isRepoPromptTool(item: item, toolName: toolName) else { return nil }

        let itemID = (item["id"] as? String)
            ?? (item["item_id"] as? String)
            ?? (item["call_id"] as? String)
        let invocationID = invocationID(for: itemID)
        let argsJSON = codexToolArgsJSON(from: item, itemType: itemType)
        let resultJSON = codexToolResultJSON(from: item)
        let isError = codexItemIsError(item)

        if isStarted {
            if toolName == "bash" {
                return AIStreamResult(
                    type: "tool_result",
                    text: nil,
                    reasoning: nil,
                    promptTokens: nil,
                    completionTokens: nil,
                    cost: nil,
                    toolName: toolName,
                    toolArgs: argsJSON,
                    toolOutput: resultJSON,
                    toolInvocationID: invocationID,
                    toolResultJSON: resultJSON,
                    toolArgsJSON: argsJSON,
                    toolIsError: false
                )
            }
            return AIStreamResult(
                type: "tool_call",
                text: nil,
                reasoning: nil,
                promptTokens: nil,
                completionTokens: nil,
                cost: nil,
                toolName: toolName,
                toolArgs: argsJSON,
                toolOutput: nil,
                toolInvocationID: invocationID,
                toolResultJSON: nil,
                toolArgsJSON: argsJSON,
                toolIsError: nil
            )
        }

        if isCompleted {
            if let itemID {
                codexItemInvocationIDs.removeValue(forKey: itemID)
            }
            return AIStreamResult(
                type: "tool_result",
                text: nil,
                reasoning: nil,
                promptTokens: nil,
                completionTokens: nil,
                cost: nil,
                toolName: toolName,
                toolArgs: argsJSON,
                toolOutput: resultJSON,
                toolInvocationID: invocationID,
                toolResultJSON: resultJSON,
                toolArgsJSON: argsJSON,
                toolIsError: isError
            )
        }

        return nil
    }

    private func invocationID(for itemID: String?) -> UUID? {
        guard let itemID, !itemID.isEmpty else { return nil }
        if let existing = codexItemInvocationIDs[itemID] {
            return existing
        }
        let created = UUID()
        codexItemInvocationIDs[itemID] = created
        return created
    }

    private func codexToolName(from item: [String: Any], itemType: String) -> String? {
        if itemType == "command_execution" || itemType == "commandexecution" || itemType.contains("command") {
            return "bash"
        }

        let candidate =
            (item["name"] as? String)
                ?? (item["tool_name"] as? String)
                ?? (item["toolName"] as? String)
                ?? (item["function_name"] as? String)
                ?? (item["functionName"] as? String)
                ?? (item["tool"] as? String)
        guard let candidate, !candidate.isEmpty else { return nil }
        return normalizedToolName(candidate)
    }

    private func normalizedToolName(_ raw: String) -> String {
        let lowered = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.hasPrefix("functions.") {
            return String(lowered.dropFirst("functions.".count))
        }
        if lowered.hasPrefix("mcp__") {
            let components = lowered.components(separatedBy: "__")
            if components.count >= 3 {
                return components.dropFirst(2).joined(separator: "__")
            }
        }
        return lowered
    }

    private func codexToolArgsJSON(from item: [String: Any], itemType: String) -> String? {
        if itemType == "command_execution" || itemType == "commandexecution" || itemType.contains("command") {
            let command = (item["command"] as? String) ?? ""
            let args: [String: Any] = ["command": command]
            return encodeJSONObject(args)
        }

        if let args = item["arguments"] {
            if let argsString = args as? String, !argsString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return argsString
            }
            if let json = JSONDictionaryHelpers.prettyJSONString(from: args) {
                return json
            }
        }
        if let input = item["input"] {
            if let inputString = input as? String, !inputString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return inputString
            }
            if let json = JSONDictionaryHelpers.prettyJSONString(from: input) {
                return json
            }
        }
        return nil
    }

    private func codexToolResultJSON(from item: [String: Any]) -> String {
        encodeJSONObject(item) ?? "{}"
    }

    private func encodeJSONObject(_ object: Any) -> String? {
        JSONDictionaryHelpers.prettyJSONString(from: object)
    }

    private func codexItemIsError(_ item: [String: Any]) -> Bool? {
        let exitCode =
            (item["exit_code"] as? Int)
                ?? (item["exitCode"] as? Int)
        if let exitCode, exitCode < 0 {
            return nil
        }
        if let exitCode {
            return exitCode > 0
        }

        if let status = (item["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if status == "failed" || status == "error" || status == "failure" || status == "rejected" {
                return true
            }
            if status == "completed" || status == "success" || status == "ok" || status == "running" || status == "in_progress" || status == "pending" {
                return false
            }
        }
        return nil
    }

    private func isRepoPromptTool(item: [String: Any], toolName: String) -> Bool {
        if MCPIntegrationHelper.isRepoPromptToolNameWithServerPrefix(toolName) {
            return true
        }
        for key in ["name", "tool_name", "toolName", "function_name", "functionName", "call_name", "callName"] {
            if let value = item[key] as? String,
               MCPIntegrationHelper.isRepoPromptToolNameWithServerPrefix(value)
            {
                return true
            }
        }
        for key in ["server", "server_name", "serverName", "mcp_server", "mcpServer"] {
            if let value = item[key] as? String,
               MCPIntegrationHelper.isRepoPromptServerIdentifier(value)
            {
                return true
            }
        }
        return false
    }

    private func parseNewerFormatExec(_ msg: [String: Any], msgType: String) -> AIStreamResult? {
        switch msgType {
        case "agent_message":
            // Newer format uses "message" field instead of "text"
            if let text = msg["message"] as? String, !text.isEmpty {
                return AIStreamResult(type: "content", text: text, reasoning: nil, promptTokens: nil, completionTokens: nil, cost: nil)
            }
            return nil

        case "agent_reasoning":
            if let text = msg["text"] as? String, !text.isEmpty {
                return AIStreamResult(type: "reasoning", text: nil, reasoning: text, promptTokens: nil, completionTokens: nil, cost: nil)
            }
            return nil

        case "token_count":
            // Newer format for usage info
            if let info = msg["info"] as? [String: Any],
               let totalUsage = info["total_token_usage"] as? [String: Any]
            {
                let promptTokens = totalUsage["input_tokens"] as? Int
                let completionTokens = totalUsage["output_tokens"] as? Int
                // Cost is not in the newer format, set to nil
                return AIStreamResult(
                    type: "message_stop",
                    text: nil,
                    reasoning: nil,
                    promptTokens: promptTokens,
                    completionTokens: completionTokens,
                    cost: nil
                )
            }
            return nil

        default:
            return nil
        }
    }

    func extractCLIErrorDetail(fromStdout data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true).reversed()

        // First pass: look for Codex CLI structured errors
        for slice in lines {
            let candidate = Data(slice)
            guard let trimmed = trimmedASCIIWhitespace(candidate) else { continue }
            if let json = try? JSONSerialization.jsonObject(with: trimmed) as? [String: Any] {
                // Check for Codex CLI item.completed with error type
                if json["type"] as? String == "item.completed",
                   let item = json["item"] as? [String: Any],
                   let itemType = item["type"] as? String,
                   itemType == "error",
                   let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty
                {
                    return text
                }

                // Check for top-level error field
                if let text = (json["error"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    return text
                }

                // Check for message field
                if let text = (json["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    return text
                }
            }
        }

        // Second pass: return plain-text diagnostics (common when CLI fails before JSON mode)
        for slice in lines {
            let candidate = Data(slice)
            guard let trimmed = trimmedASCIIWhitespace(candidate) else { continue }
            if let plainText = String(data: trimmed, encoding: .utf8) {
                let cleaned = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                // Skip empty lines and JSON noise
                if !cleaned.isEmpty, !cleaned.hasPrefix("{"), !cleaned.hasPrefix("[") {
                    return cleaned
                }
            }
        }
        return nil
    }

    private func mapProcessFailure(exitCode: Int32, stderr: String, timedOut: Bool) -> Error {
        if timedOut {
            return AIProviderError.invalidConfiguration(detail: "codex exec timed out. Please retry shortly.")
        }
        let lower = stderr.lowercased()
        if lower.contains("command not found") || lower.contains("no such file") {
            return AIProviderError.invalidConfiguration(detail: "Codex CLI not found. Install it and ensure it is available on PATH.")
        }
        if lower.contains("not authenticated") || lower.contains("unauthorized") {
            return AIProviderError.invalidConfiguration(detail: "Codex CLI not authenticated. Run `codex login` in a terminal and try again.")
        }
        if lower.contains("rate limit") || lower.contains("too many requests") {
            return AIProviderError.invalidConfiguration(detail: "Codex CLI rate limited. Please wait and try again.")
        }
        if lower.contains("overload") || lower.contains("busy") || lower.contains("unavailable") {
            return AIProviderError.invalidConfiguration(detail: "Codex CLI backend overloaded. Please retry soon.")
        }
        if stderr.isEmpty {
            return AIProviderError.apiError(source: NSError(domain: "CodexCLI", code: Int(exitCode), userInfo: [NSLocalizedDescriptionKey: "codex exec exited with status \(exitCode)"]))
        }
        return AIProviderError.apiError(source: NSError(domain: "CodexCLI", code: Int(exitCode), userInfo: [NSLocalizedDescriptionKey: stderr]))
    }
}
