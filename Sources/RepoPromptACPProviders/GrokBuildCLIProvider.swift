import Foundation
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
import RepoPromptDomainRuntime

/// Grok Build CLI provider for non-agent use (chat, Oracle, AI queries).
/// Runs a fresh prompt-only one-shot process per request without injecting RepoPrompt MCP/tools.
package final class GrokBuildCLIProvider: AIProvider {
    private let host: any GrokBuildCLIHost

    package init(host: any GrokBuildCLIHost) {
        self.host = host
    }

    private let activeProviders = ActiveGrokBuildCLIProviderStore()

    #if DEBUG
        package static func test_makeHeadlessConfig(modelName: String?, host: any GrokBuildCLIHost) -> GrokBuildAgentConfig {
            makeHeadlessConfig(modelName: modelName, host: host)
        }

        package static func test_makeAgentMessage(from aiMessage: RepoPromptDomainRuntime.AIMessage) -> AgentMessage {
            makeAgentMessage(from: aiMessage)
        }

        package static func test_normalizedTerminalResult(_ result: RepoPromptDomainRuntime.AIStreamResult) -> RepoPromptDomainRuntime.AIStreamResult {
            normalizedTerminalResult(result)
        }

        package static func test_resolvedCompletionText(
            streamedParts: [String],
            finalContent: String?
        ) -> String {
            resolvedCompletionText(streamedParts: streamedParts, finalContent: finalContent)
        }
    #endif

    package func streamMessage(
        _ aiMessage: RepoPromptDomainRuntime.AIMessage,
        model: AIModel,
        maxTokens _: Int? = nil
    ) async throws -> AsyncThrowingStream<RepoPromptDomainRuntime.AIStreamResult, Error> {
        let provider = host.makeOneShotProvider(
            config: Self.makeHeadlessConfig(modelName: host.modelName(for: model), host: host)
        )
        activeProviders.insert(provider)

        let upstream: AsyncThrowingStream<RepoPromptDomainRuntime.AIStreamResult, Error>
        do {
            upstream = try await provider.streamAgentMessage(Self.makeAgentMessage(from: aiMessage), runID: nil)
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

    package func completeMessage(
        _ aiMessage: RepoPromptDomainRuntime.AIMessage,
        model: AIModel,
        maxTokens: Int? = nil
    ) async throws -> RepoPromptDomainRuntime.AICompletionResult {
        let stream = try await streamMessage(aiMessage, model: model, maxTokens: maxTokens)
        var textParts: [String] = []
        var finalContent: String?
        var promptTokens: Int?
        var completionTokens: Int?
        var cost: Double?
        var completionOutcome: RepoPromptDomainRuntime.AIProviderCompletionOutcome?

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
            case RepoPromptDomainRuntime.AIStreamResult.incompleteType:
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
        let resolvedOutcome: RepoPromptDomainRuntime.AIProviderCompletionOutcome
        if let completionOutcome {
            resolvedOutcome = completionOutcome
        } else {
            guard !text.isEmpty else {
                throw AIProviderError.invalidResponse(detail: "Grok Build returned no completion")
            }
            resolvedOutcome = .incomplete(reason: "stream_ended_without_terminal")
        }

        return RepoPromptDomainRuntime.AICompletionResult(
            text: text,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            cost: cost,
            completionOutcome: resolvedOutcome
        )
    }

    package func dispose() async {
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

    private static func normalizedTerminalResult(_ result: RepoPromptDomainRuntime.AIStreamResult) -> RepoPromptDomainRuntime.AIStreamResult {
        guard result.type == "message_stop",
              let stopReason = result.stopReason?
              .trimmingCharacters(in: .whitespacesAndNewlines)
              .lowercased(),
              !stopReason.isEmpty,
              !successfulTerminalStopReasons.contains(stopReason)
        else {
            return result
        }

        return result.replacingType(RepoPromptDomainRuntime.AIStreamResult.incompleteType)
    }

    private static func resolvedCompletionText(
        streamedParts: [String],
        finalContent: String?
    ) -> String {
        finalContent ?? streamedParts.joined()
    }

    private static func makeHeadlessConfig(modelName: String?, host: any GrokBuildCLIHost) -> GrokBuildAgentConfig {
        host.makeHeadlessConfig(modelName: modelName)
    }

    private static let noToolsInstruction = "IMPORTANT: Do not use any tools, function calls, or external commands. Respond with text only. Any tool invocation will cause task failure."

    private static func makeAgentMessage(from aiMessage: RepoPromptDomainRuntime.AIMessage) -> AgentMessage {
        let systemPrompt = aiMessage.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonAgentSystemPrompt = systemPrompt.isEmpty
            ? Self.noToolsInstruction
            : "\(systemPrompt)\n\n\(Self.noToolsInstruction)"
        return AgentMessage(
            systemPrompt: nonAgentSystemPrompt,
            userMessage: buildPrompt(from: aiMessage),
            attachments: aiMessage.attachments,
            resumeSessionID: nil
        )
    }

    private static func buildPrompt(from aiMessage: RepoPromptDomainRuntime.AIMessage) -> String {
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
}

private extension RepoPromptDomainRuntime.AIStreamResult {
    func replacingType(_ type: String) -> RepoPromptDomainRuntime.AIStreamResult {
        RepoPromptDomainRuntime.AIStreamResult(
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
