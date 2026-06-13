import Foundation

/// Cursor CLI provider for non-agent use (chat, Oracle, AI queries) backed by ACP.
/// Runs a fresh ACP session per request, switches to Cursor's official `ask` mode (prompt-only/no tools), and never injects RepoPrompt MCP/tools.
final class CursorCLIProvider: AIProvider {
    typealias HeadlessProviderFactory = @Sendable (_ config: CursorAgentConfig, _ workspacePath: String?) -> CursorACPHeadlessAgentProvider

    private let activeProviders = ActiveCursorCLIProviderStore()
    private let headlessProviderFactory: HeadlessProviderFactory

    init(
        headlessProviderFactory: @escaping HeadlessProviderFactory = { config, workspacePath in
            CursorACPHeadlessAgentProvider(config: config, workspacePath: workspacePath)
        }
    ) {
        self.headlessProviderFactory = headlessProviderFactory
    }

    #if DEBUG
        static func test_makeHeadlessConfig(modelName: String?) -> CursorAgentConfig {
            makeHeadlessConfig(modelName: modelName)
        }
    #endif

    func streamMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens _: Int? = nil) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        let provider = headlessProviderFactory(
            Self.makeHeadlessConfig(modelName: cursorModelName(for: model)),
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

    func completeMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens: Int? = nil) async throws -> AICompletionResult {
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
                throw AIProviderError.invalidConfiguration(detail: result.text ?? "Cursor ACP reported an error")
            default:
                continue
            }
        }

        let text = textParts.isEmpty ? (finalContent ?? "") : textParts.joined()
        guard sawMessageStop || !text.isEmpty else {
            throw AIProviderError.invalidResponse(detail: "Cursor returned no completion")
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

    private static func makeHeadlessConfig(modelName: String?) -> CursorAgentConfig {
        CursorAgentConfig(
            enableDebugLogging: AgentRuntimeProviderService.enableDebugLogging,
            modelString: modelName,
            includeRepoPromptMCPServer: false,
            cleanupProjectMCPApproval: true,
            sessionModeID: CursorAgentConfig.promptOnlySessionModeID
        )
    }

    private static let noToolsSuffix = "\n\nIMPORTANT: Do not use any tools, function calls, or external commands. Respond with text only. Any tool invocation will cause task failure."

    private func makeAgentMessage(from aiMessage: AIMessage) -> AgentMessage {
        let systemPrompt = aiMessage.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentMessage(
            systemPrompt: systemPrompt.isEmpty ? systemPrompt : systemPrompt + Self.noToolsSuffix,
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

    private func cursorModelName(for model: AIModel) -> String? {
        guard model.providerType == .cursor else { return nil }
        let trimmed = model.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private final class ActiveCursorCLIProviderStore: @unchecked Sendable {
    private let lock = NSLock()
    private var providers: [ObjectIdentifier: CursorACPHeadlessAgentProvider] = [:]

    func insert(_ provider: CursorACPHeadlessAgentProvider) {
        lock.lock()
        providers[ObjectIdentifier(provider)] = provider
        lock.unlock()
    }

    func remove(_ provider: CursorACPHeadlessAgentProvider) {
        lock.lock()
        providers.removeValue(forKey: ObjectIdentifier(provider))
        lock.unlock()
    }

    func removeAll() -> [CursorACPHeadlessAgentProvider] {
        lock.lock()
        let current = Array(providers.values)
        providers.removeAll()
        lock.unlock()
        return current
    }
}
