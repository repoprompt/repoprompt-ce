#if DEBUG
    import Foundation
    import RepoPromptDomainRuntime

    struct PromptExperimentConnectedModelCompletion: Equatable {
        let output: String
        let promptTokens: Int?
        let completionTokens: Int?
    }

    /// Completion consumers need one assistant answer, not concatenated commentary + final messages.
    /// Preserve provider message boundaries; never repair output by guessing at JSON or deduplicating text.
    struct PromptExperimentCompletionAccumulator {
        private var streamedOutput = ""
        private var lastMessageID: String?
        private var finalOutput: String?
        private(set) var promptTokens: Int?
        private(set) var completionTokens: Int?

        var output: String {
            (finalOutput ?? streamedOutput).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        mutating func consume(_ event: AIStreamResult) {
            // Codex reports usage on message_stop; other providers may use a separate usage event.
            promptTokens = event.promptTokens ?? promptTokens
            completionTokens = event.completionTokens ?? completionTokens
            switch event.type {
            case "content":
                if let messageID = event.contentMessageID, !messageID.isEmpty, messageID != lastMessageID {
                    streamedOutput = ""
                    lastMessageID = messageID
                }
                streamedOutput += event.text ?? ""
            case "final_content":
                finalOutput = event.text
            default:
                break
            }
        }
    }

    /// One-shot model completion over the existing Agent provider/login stack.
    /// Every native and RepoPrompt tool is disabled by a run-scoped provider profile and policy.
    @MainActor
    final class PromptExperimentConnectedModelRunner {
        private weak var windowState: WindowState?
        private var activeProviders: [UUID: HeadlessAgentProvider] = [:]

        init(windowState: WindowState) {
            self.windowState = windowState
        }

        func complete(
            target: PromptExperimentResolvedTarget,
            systemPrompt: String,
            userPrompt: String,
            callbackRoot: URL
        ) async throws -> PromptExperimentConnectedModelCompletion {
            guard let windowState else {
                throw PromptExperimentAuthorityError.runtimeUnavailable("The bound Agent window is no longer available.")
            }
            guard let agent = AgentProviderKind(rawValue: target.agentRaw),
                  [.claudeCode, .claudeCodeGLM, .kimiCode, .customClaudeCompatible, .codexExec].contains(agent)
            else {
                throw PromptExperimentAuthorityError.targetUnavailable(
                    "The selected target has no proven prompt-only Prompt Experiment provider profile."
                )
            }
            try FileManager.default.createDirectory(at: callbackRoot, withIntermediateDirectories: true)
            let runID = UUID()
            await windowState.mcpServer.startServer()
            guard windowState.mcpServer.windowToolsEnabled else {
                throw PromptExperimentAuthorityError.runtimeUnavailable("RepoPrompt MCP is unavailable for the run-scoped provider policy.")
            }
            let spec = AgentRunSpec(
                type: .promptExperiment,
                runID: runID,
                agentKind: agent,
                modelString: target.modelRaw,
                windowID: windowState.windowID,
                restrictedTools: Set(MCPDomainToolCatalog.orderedToolNames),
                connectionTTL: 60
            )
            let lease = try await AgentRunCoordinator.shared.prepareAndInstallPolicy(
                spec,
                tabID: nil,
                additionalTools: [],
                reason: "prompt-experiment-model-callback",
                gateID: runID
            )
            let provider = AgentRunCoordinator.shared.makeProvider(
                agentKind: agent,
                modelString: target.modelRaw,
                runType: .promptExperiment,
                workspacePath: callbackRoot.path,
                codexRunConstraints: agent == .codexExec
                    ? .promptExperiment(workingDirectory: callbackRoot.path)
                    : nil
            )
            activeProviders[runID] = provider
            defer {
                activeProviders.removeValue(forKey: runID)
                try? FileManager.default.removeItem(at: callbackRoot)
            }

            return try await withTaskCancellationHandler {
                do {
                    let routeTask = Task { await lease.releaseWhenRouted(timeoutMs: 10000) }
                    let stream = try await provider.streamAgentMessage(
                        AgentMessage(systemPrompt: systemPrompt, userMessage: userPrompt),
                        runID: runID
                    )
                    var accumulator = PromptExperimentCompletionAccumulator()
                    var reachedTerminal = false
                    for try await event in stream {
                        try Task.checkCancellation()
                        accumulator.consume(event)
                        switch event.type {
                        case "tool_call", "tool_result":
                            throw PromptExperimentAuthorityError.runtimeUnavailable(
                                "A prompt-only experiment callback attempted to use a disabled tool."
                            )
                        case "error":
                            throw PromptExperimentAuthorityError.runtimeUnavailable(
                                event.text ?? "The connected provider returned an error."
                            )
                        case "message_incomplete":
                            throw PromptExperimentAuthorityError.runtimeUnavailable(
                                event.stopReason ?? "The connected provider reported incomplete output."
                            )
                        case "message_stop":
                            reachedTerminal = true
                        default:
                            break
                        }
                    }
                    guard await routeTask.value else {
                        throw PromptExperimentAuthorityError.runtimeUnavailable(
                            "The prompt-only provider did not establish its run-scoped no-tool routing policy."
                        )
                    }
                    let effective = accumulator.output
                    guard reachedTerminal, !effective.isEmpty else {
                        throw PromptExperimentAuthorityError.runtimeUnavailable(
                            "The connected provider completed without a non-empty terminal response."
                        )
                    }
                    await provider.dispose()
                    return PromptExperimentConnectedModelCompletion(
                        output: effective,
                        promptTokens: accumulator.promptTokens,
                        completionTokens: accumulator.completionTokens
                    )
                } catch {
                    await lease.failAndCleanup()
                    await provider.dispose()
                    throw error
                }
            } onCancel: {
                Task { await provider.dispose() }
            }
        }

        func cancelAll() async {
            let providers = Array(activeProviders.values)
            activeProviders.removeAll()
            for provider in providers {
                await provider.dispose()
            }
        }
    }
#endif
