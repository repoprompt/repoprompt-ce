import Foundation

/// Devin provider for non-agent use (chat, Oracle, AI queries), backed by `devin acp`.
/// Runs a fresh ACP session per request, never injects RepoPrompt MCP/tools, and instructs
/// Devin to answer with text only.
///
/// ACP is the only Devin transport that carries images: `devin acp` (3000.11.1) advertises
/// `promptCapabilities.image = true`, while the one-shot `devin --prompt-file … -p` CLI
/// exposes no attachment channel at all.
final class DevinCLIProvider: AIProvider {
    typealias HeadlessProviderFactory = @Sendable (_ config: DevinAgentConfig, _ workspacePath: String?) -> DevinACPHeadlessAgentProvider

    private let activeProviders = ActiveDevinCLIProviderStore()
    private let headlessProviderFactory: HeadlessProviderFactory

    init(
        headlessProviderFactory: @escaping HeadlessProviderFactory = { config, workspacePath in
            DevinACPHeadlessAgentProvider(config: config, workspacePath: workspacePath)
        }
    ) {
        self.headlessProviderFactory = headlessProviderFactory
    }

    #if DEBUG
        static func test_makeHeadlessConfig(modelName: String?) -> DevinAgentConfig {
            makeHeadlessConfig(modelName: modelName)
        }

        static func test_makeAgentMessage(from aiMessage: AIMessage) -> AgentMessage {
            DevinCLIProvider().makeAgentMessage(from: aiMessage)
        }
    #endif

    func streamMessage(
        _ aiMessage: AIMessage,
        model: AIModel,
        maxTokens _: Int? = nil
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        let provider = headlessProviderFactory(
            Self.makeHeadlessConfig(modelName: devinModelName(for: model)),
            nil
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
                throw AIProviderError.invalidConfiguration(detail: result.text ?? "Devin ACP reported an error")
            default:
                continue
            }
        }

        let text = textParts.isEmpty ? (finalContent ?? "") : textParts.joined()
        guard sawMessageStop || !text.isEmpty else {
            throw AIProviderError.invalidResponse(detail: "Devin returned no completion")
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

    private static func makeHeadlessConfig(modelName: String?) -> DevinAgentConfig {
        DevinAgentConfig(
            enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
            includeRepoPromptMCPServer: false,
            modelString: modelName
        )
    }

    private static let noToolsInstruction = "IMPORTANT: Do not use any tools, function calls, MCP servers, external commands, or workspace files. Return one final text answer only; preserve Markdown when useful."

    private func makeAgentMessage(from aiMessage: AIMessage) -> AgentMessage {
        let systemPrompt = aiMessage.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentMessage(
            systemPrompt: systemPrompt.isEmpty
                ? Self.noToolsInstruction
                : systemPrompt + "\n\n" + Self.noToolsInstruction,
            userMessage: buildPrompt(from: aiMessage),
            transientImages: aiMessage.transientImages,
            resumeSessionID: nil
        )
    }

    private func buildPrompt(from aiMessage: AIMessage) -> String {
        let tail = aiMessage.buildTail(embedSystemPrompt: false)
        var conversation = ""
        let lastUserIndex = aiMessage.conversationMessages.lastIndex { $0.role == .user }
        for (index, turn) in aiMessage.conversationMessages.enumerated() {
            var text = turn.content
            if turn.role == .user, index == lastUserIndex, !tail.isEmpty {
                text = tail + "\n\n" + text
            }
            if !conversation.isEmpty { conversation += "\n\n" }
            conversation += "\(turn.role == .user ? "User" : "Assistant"): \(text)"
        }
        if aiMessage.conversationMessages.isEmpty, !tail.isEmpty {
            conversation = "User: \(tail)"
        }
        return conversation
    }

    private func devinModelName(for model: AIModel) -> String? {
        guard model.providerType == .devin else { return nil }
        let value = model.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.caseInsensitiveCompare(AgentModel.defaultModel.rawValue) != .orderedSame
        else { return nil }
        return value
    }
}

private final class ActiveDevinCLIProviderStore: @unchecked Sendable {
    private let lock = NSLock()
    private var providers: [ObjectIdentifier: DevinACPHeadlessAgentProvider] = [:]

    func insert(_ provider: DevinACPHeadlessAgentProvider) {
        lock.lock()
        providers[ObjectIdentifier(provider)] = provider
        lock.unlock()
    }

    func remove(_ provider: DevinACPHeadlessAgentProvider) {
        lock.lock()
        providers.removeValue(forKey: ObjectIdentifier(provider))
        lock.unlock()
    }

    func removeAll() -> [DevinACPHeadlessAgentProvider] {
        lock.lock()
        let current = Array(providers.values)
        providers.removeAll()
        lock.unlock()
        return current
    }
}
