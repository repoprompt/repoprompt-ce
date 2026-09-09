import Foundation

/// Shared non-agent (chat / Oracle / AI queries) adapter for ACP-backed CLI providers.
/// Every request runs a fresh headless ACP session; the only provider-specific parts are
/// the per-request config, the name used in error text, and the `AIProviderType` whose
/// advertised model IDs may be forwarded.
///
/// OpenCode and Oh My Pi share this engine rather than each carrying its own copy of the
/// stream bridge, replacement/disposal bookkeeping, and conversation flattening.
final class ACPCLIChatProviderEngine<Provider: AnyObject & HeadlessAgentProvider>: AIProvider {
    typealias ProviderFactory = @Sendable (_ modelName: String?) -> Provider

    private let providerName: String
    private let providerType: AIProviderType
    private let makeProvider: ProviderFactory
    private let activeProviders = ActiveACPCLIProviderStore<Provider>()

    init(
        providerName: String,
        providerType: AIProviderType,
        makeProvider: @escaping ProviderFactory
    ) {
        self.providerName = providerName
        self.providerType = providerType
        self.makeProvider = makeProvider
    }

    func streamMessage(
        _ aiMessage: AIMessage,
        model: AIModel,
        maxTokens _: Int? = nil
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        let provider = makeProvider(modelName(for: model))
        if let replacedProvider = activeProviders.replace(provider) {
            await replacedProvider.dispose()
        }

        let upstream: AsyncThrowingStream<AIStreamResult, Error>
        do {
            upstream = try await provider.streamAgentMessage(agentMessage(from: aiMessage), runID: nil)
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
                    detail: result.text ?? "\(providerName) ACP reported an error"
                )
            default:
                continue
            }
        }

        let text = textParts.isEmpty ? (finalContent ?? "") : textParts.joined()
        guard sawMessageStop || !text.isEmpty else {
            throw AIProviderError.invalidResponse(detail: "\(providerName) returned no completion")
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

    #if DEBUG
        func test_agentMessage(from aiMessage: AIMessage) -> AgentMessage {
            agentMessage(from: aiMessage)
        }
    #endif

    /// A model ID is forwarded only when it came from this provider's own catalog; anything
    /// else leaves the CLI on its configured default.
    private func modelName(for model: AIModel) -> String? {
        guard model.providerType == providerType else { return nil }
        let trimmed = model.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func agentMessage(from aiMessage: AIMessage) -> AgentMessage {
        AgentMessage(
            systemPrompt: aiMessage.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines),
            userMessage: flattenedPrompt(from: aiMessage),
            resumeSessionID: nil
        )
    }

    /// ACP takes a single prompt string, so the conversation is flattened with the packaged
    /// context tail attached to the final user turn.
    private func flattenedPrompt(from aiMessage: AIMessage) -> String {
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

/// Tracks the headless providers a chat engine has in flight so a superseded or cancelled
/// request is disposed exactly once.
final class ActiveACPCLIProviderStore<Provider: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private var providers: [ObjectIdentifier: Provider] = [:]
    private var currentProviderID: ObjectIdentifier?

    func replace(_ provider: Provider) -> Provider? {
        lock.lock()
        let providerID = ObjectIdentifier(provider)
        let previousProvider = currentProviderID.flatMap { providers[$0] }
        providers[providerID] = provider
        currentProviderID = providerID
        lock.unlock()
        guard let previousProvider,
              previousProvider !== provider
        else {
            return nil
        }
        return previousProvider
    }

    func contains(_ provider: Provider) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return providers[ObjectIdentifier(provider)] != nil
    }

    @discardableResult
    func remove(_ provider: Provider) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let providerID = ObjectIdentifier(provider)
        let removedProvider = providers.removeValue(forKey: providerID)
        if currentProviderID == providerID {
            currentProviderID = nil
        }
        return removedProvider != nil
    }

    func removeAll() -> [Provider] {
        lock.lock()
        let currentProviders = Array(providers.values)
        providers.removeAll()
        currentProviderID = nil
        lock.unlock()
        return currentProviders
    }
}
