#if DEBUG
    import Foundation
    import RepoPromptDomainRuntime

    struct PromptExperimentConnectedModelCompletion: Equatable {
        let output: String
        let promptTokens: Int?
        let completionTokens: Int?
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
                    var output = ""
                    var finalOutput: String?
                    var promptTokens: Int?
                    var completionTokens: Int?
                    var reachedTerminal = false
                    for try await event in stream {
                        try Task.checkCancellation()
                        switch event.type {
                        case "content":
                            output += event.text ?? ""
                        case "final_content":
                            finalOutput = event.text
                        case "usage":
                            promptTokens = event.promptTokens ?? promptTokens
                            completionTokens = event.completionTokens ?? completionTokens
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
                    let effective = (finalOutput ?? output).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard reachedTerminal, !effective.isEmpty else {
                        throw PromptExperimentAuthorityError.runtimeUnavailable(
                            "The connected provider completed without a non-empty terminal response."
                        )
                    }
                    await provider.dispose()
                    return PromptExperimentConnectedModelCompletion(
                        output: effective,
                        promptTokens: promptTokens,
                        completionTokens: completionTokens
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
