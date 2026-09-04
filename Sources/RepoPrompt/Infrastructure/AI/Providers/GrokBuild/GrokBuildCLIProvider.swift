import Foundation

/// Grok Build CLI provider for non-agent use (chat, Oracle, AI queries).
/// Runs a fresh prompt-only one-shot process per request without injecting RepoPrompt MCP/tools.
final class GrokBuildCLIProvider: AIProvider {
    private let activeProviders = ActiveGrokBuildCLIProviderStore()

    #if DEBUG
        static func test_makeHeadlessConfig(modelName: String?) -> GrokBuildAgentConfig {
            makeHeadlessConfig(modelName: modelName)
        }

        static func test_makeAgentMessage(from aiMessage: AIMessage) -> AgentMessage {
            GrokBuildCLIProvider().makeAgentMessage(from: aiMessage)
        }

        static func test_normalizedTerminalResult(_ result: AIStreamResult) -> AIStreamResult {
            normalizedTerminalResult(result)
        }

        static func test_resolvedCompletionText(
            streamedParts: [String],
            finalContent: String?
        ) -> String {
            resolvedCompletionText(streamedParts: streamedParts, finalContent: finalContent)
        }
    #endif

    func streamMessage(
        _ aiMessage: AIMessage,
        model: AIModel,
        maxTokens _: Int? = nil
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        let provider = GrokBuildOneShotHeadlessAgentProvider(
            config: Self.makeHeadlessConfig(modelName: grokBuildModelName(for: model))
        )
        activeProviders.insert(provider)

        let upstream: AsyncThrowingStream<AIStreamResult, Error>
        do {
            upstream = try await provider.streamAgentMessage(makeAgentMessage(from: aiMessage), runID: nil)
        } catch {
            activeProviders.remove(provider)
            await provider.dispose()
            throw error
        }

        return AsyncThrowingStream { continuation in
            let bridgeTask = Task {
                do {
                    for try await result in upstream {
                        continuation.yield(Self.normalizedTerminalResult(result))
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
                await provider.dispose()
                self.activeProviders.remove(provider)
            }

            continuation.onTermination = { _ in
                bridgeTask.cancel()
                Task {
                    await provider.dispose()
                    self.activeProviders.remove(provider)
                }
            }
        }
    }

    func completeMessage(
        _ aiMessage: AIMessage,
        model: AIModel,
        maxTokens: Int? = nil
    ) async throws -> AICompletionResult {
        let stream = try await streamMessage(aiMessage, model: model, maxTokens: maxTokens)
        var textParts: [String] = []
        var finalContent: String?
        var promptTokens: Int?
        var completionTokens: Int?
        var cost: Double?
        var completionOutcome: AIProviderCompletionOutcome?

        for try await result in stream {
            switch result.type {
            case "content":
                if let text = result.text, !text.isEmpty {
                    textParts.append(text)
                }
            case "final_content":
                if let text = result.text, !text.isEmpty {
                    finalContent = text
                }
            case "message_stop":
                completionOutcome = .completed
                if let value = result.promptTokens { promptTokens = value }
                if let value = result.completionTokens { completionTokens = value }
                if let value = result.cost { cost = value }
            case AIStreamResult.incompleteType:
                guard let reason = result.stopReason?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !reason.isEmpty
                else {
                    throw AIProviderError.invalidResponse(
                        detail: "Grok Build reported incomplete termination without a reason"
                    )
                }
                completionOutcome = .incomplete(reason: reason)
                if let value = result.promptTokens { promptTokens = value }
                if let value = result.completionTokens { completionTokens = value }
                if let value = result.cost { cost = value }
            case "error":
                throw AIProviderError.invalidConfiguration(
                    detail: result.text ?? "Grok Build reported an error"
                )
            default:
                continue
            }
        }

        let text = Self.resolvedCompletionText(
            streamedParts: textParts,
            finalContent: finalContent
        )
        let resolvedOutcome: AIProviderCompletionOutcome
        if let completionOutcome {
            resolvedOutcome = completionOutcome
        } else {
            guard !text.isEmpty else {
                throw AIProviderError.invalidResponse(detail: "Grok Build returned no completion")
            }
            resolvedOutcome = .incomplete(reason: "stream_ended_without_terminal")
        }

        return AICompletionResult(
            text: text,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            cost: cost,
            completionOutcome: resolvedOutcome
        )
    }

    func dispose() async {
        let providers = activeProviders.removeAll()
        for provider in providers {
            await provider.dispose()
        }
    }

    private static let successfulTerminalStopReasons: Set<String> = [
        "end_turn",
        "stop",
        "stop_sequence",
        "completed",
        "complete"
    ]

    private static func normalizedTerminalResult(_ result: AIStreamResult) -> AIStreamResult {
        guard result.type == "message_stop",
              let stopReason = result.stopReason?
              .trimmingCharacters(in: .whitespacesAndNewlines)
              .lowercased(),
              !stopReason.isEmpty,
              !successfulTerminalStopReasons.contains(stopReason)
        else {
            return result
        }

        return result.replacingType(AIStreamResult.incompleteType)
    }

    private static func resolvedCompletionText(
        streamedParts: [String],
        finalContent: String?
    ) -> String {
        finalContent ?? streamedParts.joined()
    }

    private static func makeHeadlessConfig(modelName: String?) -> GrokBuildAgentConfig {
        GrokBuildAgentConfig(
            enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
            modelString: modelName,
            includeRepoPromptMCPServer: false,
            alwaysApproveTools: false
        )
    }

    private static let noToolsInstruction = "IMPORTANT: Do not use any tools, function calls, or external commands. Respond with text only. Any tool invocation will cause task failure."

    private func makeAgentMessage(from aiMessage: AIMessage) -> AgentMessage {
        let systemPrompt = aiMessage.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonAgentSystemPrompt = systemPrompt.isEmpty
            ? Self.noToolsInstruction
            : "\(systemPrompt)\n\n\(Self.noToolsInstruction)"
        return AgentMessage(
            systemPrompt: nonAgentSystemPrompt,
            userMessage: buildPrompt(from: aiMessage),
            resumeSessionID: nil
        )
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
        return conversation
    }

    private func grokBuildModelName(for model: AIModel) -> String? {
        guard model.providerType == .grokBuild else { return nil }
        let trimmed = model.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension AIStreamResult {
    func replacingType(_ type: String) -> AIStreamResult {
        AIStreamResult(
            type: type,
            text: text,
            reasoning: reasoning,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            cost: cost,
            toolName: toolName,
            toolArgs: toolArgs,
            toolOutput: toolOutput,
            toolInvocationID: toolInvocationID,
            toolResultJSON: toolResultJSON,
            toolArgsJSON: toolArgsJSON,
            toolIsError: toolIsError,
            providerSessionID: providerSessionID,
            stopReason: stopReason,
            modelContextWindow: modelContextWindow,
            contextUsedTokens: contextUsedTokens,
            contentMessageID: contentMessageID,
            cleanupHandle: cleanupHandle
        )
    }
}

private final class ActiveGrokBuildCLIProviderStore: @unchecked Sendable {
    private let lock = NSLock()
    private var providers: [ObjectIdentifier: GrokBuildOneShotHeadlessAgentProvider] = [:]

    func insert(_ provider: GrokBuildOneShotHeadlessAgentProvider) {
        lock.lock()
        providers[ObjectIdentifier(provider)] = provider
        lock.unlock()
    }

    func remove(_ provider: GrokBuildOneShotHeadlessAgentProvider) {
        lock.lock()
        providers.removeValue(forKey: ObjectIdentifier(provider))
        lock.unlock()
    }

    func removeAll() -> [GrokBuildOneShotHeadlessAgentProvider] {
        lock.lock()
        let current = Array(providers.values)
        providers.removeAll()
        lock.unlock()
        return current
    }
}
