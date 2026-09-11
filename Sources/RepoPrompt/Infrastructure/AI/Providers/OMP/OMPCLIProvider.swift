import Foundation

/// Oh My Pi provider for non-agent use (chat, Oracle, AI queries) backed by ACP.
/// Runs a fresh ACP session per request while preserving OMP's advertised model IDs.
final class OMPCLIProvider: AIProvider {
    private let activeProviders = ActiveACPCLIProviderStore<OMPACPHeadlessAgentProvider>()

    #if DEBUG
        static func test_makeHeadlessConfig(modelName: String?) -> OMPAgentConfig {
            makeHeadlessConfig(modelName: modelName)
        }

        static func test_makeAgentMessage(from aiMessage: AIMessage) -> AgentMessage {
            OMPCLIProvider().makeAgentMessage(from: aiMessage)
        }
    #endif

    func streamMessage(
        _ aiMessage: AIMessage,
        model: AIModel,
        maxTokens _: Int? = nil
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        let provider = OMPACPHeadlessAgentProvider(
            config: Self.makeHeadlessConfig(modelName: ompModelName(for: model)),
            workspacePath: nil
        )
        if let replacedProvider = activeProviders.replace(provider) {
            await replacedProvider.dispose()
        }

        let upstream: AsyncThrowingStream<AIStreamResult, Error>
        do {
            upstream = try await provider.streamAgentMessage(makeAgentMessage(from: aiMessage), runID: nil)
        } catch {
            activeProviders.remove(provider)
            await provider.dispose()
            throw error
        }
        guard activeProviders.contains(provider) else {
            await provider.dispose()
            throw CancellationError()
        }

        return AsyncThrowingStream { continuation in
            let bridgeTask = Task {
                do {
                    for try await result in upstream {
                        continuation.yield(result)
                    }
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
                if self.activeProviders.remove(provider) {
                    await provider.dispose()
                }
            }

            continuation.onTermination = { [activeProviders] termination in
                bridgeTask.cancel()
                guard case .cancelled = termination else { return }
                Task {
                    if activeProviders.remove(provider) {
                        await provider.dispose()
                    }
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
        var sawMessageStop = false

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
                sawMessageStop = true
                if let value = result.promptTokens { promptTokens = value }
                if let value = result.completionTokens { completionTokens = value }
                if let value = result.cost { cost = value }
            case "error":
                throw AIProviderError.invalidConfiguration(
                    detail: result.text ?? "Oh My Pi ACP reported an error"
                )
            default:
                continue
            }
        }

        let text = textParts.isEmpty ? (finalContent ?? "") : textParts.joined()
        guard sawMessageStop || !text.isEmpty else {
            throw AIProviderError.invalidResponse(detail: "Oh My Pi returned no completion")
        }

        return AICompletionResult(
            text: text,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            cost: cost
        )
    }

    func dispose() async {
        let providers = activeProviders.removeAll()
        for provider in providers {
            await provider.dispose()
        }
    }

    private static func makeHeadlessConfig(modelName: String?) -> OMPAgentConfig {
        OMPAgentConfig(
            enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
            modelString: modelName
        )
    }

    private func makeAgentMessage(from aiMessage: AIMessage) -> AgentMessage {
        AgentMessage(
            systemPrompt: aiMessage.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            userMessage: buildPrompt(from: aiMessage),
            transientImages: aiMessage.transientImages,
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

    private func ompModelName(for model: AIModel) -> String? {
        guard model.providerType == .omp else { return nil }
        let trimmed = model.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
