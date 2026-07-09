import Foundation
import SwiftOpenAI

class OpenRouterProvider: AIProvider {
    private let cachedApiKey: String
    private let transportPool: OpenAIServiceTransportPool

    init(apiKey: String, transportPool: OpenAIServiceTransportPool = .shared) {
        cachedApiKey = apiKey
        self.transportPool = transportPool
    }

    private func getConfiguration() -> OpenRouterConfiguration {
        ProviderConfigurationManager.shared.getOpenRouterConfiguration()
    }

    func getService(configuration config: OpenRouterConfiguration) -> OpenAIService {
        // Merge default headers with custom headers
        var headers = [
            "HTTP-Referer": "https://repoprompt.com/",
            "X-Title": "Repo Prompt"
        ]

        // Add custom headers from configuration only if useCustomSettings is true
        if config.useCustomSettings {
            for (key, value) in config.customHeaders {
                headers[key] = value
            }
        }

        return transportPool.openAIService(
            owner: .openRouter,
            apiKey: cachedApiKey,
            baseURL: URL(string: "https://openrouter.ai")!,
            proxyPath: "api",
            apiVersion: nil,
            extraHeaders: headers,
            includeUsageInStream: true
        )
    }

    func streamMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens: Int?) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        // If model streaming is disabled, use completeMessage instead
        if !model.canStream {
            let result = try await completeMessage(aiMessage, model: model, maxTokens: maxTokens)
            return AsyncThrowingStream { continuation in
                continuation.yield(AIStreamResult(type: "content", text: result.text, reasoning: nil, promptTokens: nil, completionTokens: nil))
                continuation.yield(AIStreamResult(type: "message_stop", text: nil, reasoning: nil, promptTokens: result.promptTokens, completionTokens: result.completionTokens, cost: result.cost))
                continuation.finish()
            }
        }

        let messages = aiMessage.openAIChatMessages(embedSystemPrompt: false)
        let config = getConfiguration()

        // Use configuration values only if useCustomSettings is true
        let effectiveMaxTokens = config.useCustomSettings ? (maxTokens ?? config.baseConfig.maxTokens) : 8192

        // Honour global & per-model overrides
        let effectiveTemperature = aiMessage.effectiveTemperature(for: model)

        let parameters = ChatCompletionParameters(
            messages: messages,
            model: .custom(model.modelName),
            maxTokens: effectiveMaxTokens,
            temperature: effectiveTemperature
        )

        let service = getService(configuration: config)
        let stream = try await service.startStreamedChat(parameters: parameters)

        print("Model: \(model.modelName)")

        return bridgeStream(stream)
    }

    func bridgeStream(_ stream: AsyncThrowingStream<ChatCompletionChunkObject, Error>) -> AsyncThrowingStream<AIStreamResult, Error> {
        AsyncThrowingStream { continuation in
            let bridgeTask = Task {
                do {
                    var promptTokens: Int? = nil
                    var completionTokens: Int? = nil
                    var cost: Double? = nil

                    for try await chunk in stream {
                        if Task.isCancelled {
                            return
                        }

                        // Use optional chaining to unwrap the optional 'choices'
                        let content = chunk.choices?.first?.delta?.content
                        let reasoning = chunk.choices?.first?.delta?.reasoningContent

                        // Extract token usage from the final response chunk if available
                        if let usage = chunk.usage {
                            promptTokens = usage.promptTokens
                            completionTokens = usage.completionTokens
                            cost = usage.cost
                        }

                        // Only yield if there's something
                        if let c = content, !c.isEmpty {
                            continuation.yield(AIStreamResult(type: "content", text: c, reasoning: reasoning, promptTokens: promptTokens, completionTokens: completionTokens, cost: cost))
                        } else if let r = reasoning, !r.isEmpty {
                            continuation.yield(AIStreamResult(type: "content", text: nil, reasoning: r))
                        }
                    }

                    if Task.isCancelled {
                        return
                    }

                    // Indicate the message has ended with token counts
                    continuation.yield(AIStreamResult(type: "message_stop", text: nil, reasoning: nil, promptTokens: promptTokens, completionTokens: completionTokens, cost: cost))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in bridgeTask.cancel() }
        }
    }

    func completeMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens: Int?) async throws -> AICompletionResult {
        let messages = aiMessage.openAIChatMessages(embedSystemPrompt: false)
        let config = getConfiguration()

        // Use configuration values only if useCustomSettings is true
        let effectiveMaxTokens = config.useCustomSettings ? (maxTokens ?? config.baseConfig.maxTokens) : maxTokens

        // Honour global & per-model overrides
        let effectiveTemperature = aiMessage.effectiveTemperature(for: model)

        let parameters = ChatCompletionParameters(
            messages: messages,
            model: .custom(model.modelName),
            maxTokens: effectiveMaxTokens,
            temperature: effectiveTemperature
        )

        let service = getService(configuration: config)
        let completion = try await service.startChat(parameters: parameters)

        // Extract token usage if available
        let promptTokens = completion.usage?.promptTokens
        let completionTokens = completion.usage?.completionTokens
        let cost = completion.usage?.cost

        // Use optional chaining for 'choices'
        let content = completion.choices?.first?.message?.content ?? ""

        return AICompletionResult(
            text: content,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            cost: cost
        )
    }

    /// Tests if the given API key is valid by issuing a short query
    func testAPIKey(model: AIModel? = nil) async throws -> Bool {
        let testMessage = AIMessage(systemPrompt: "You are a helpful assistant.", userMessage: "Say hello")
        let testModel = model ?? .openrouterGpt5

        do {
            // We can do a streaming test or a completion test. Let's do streaming to see if it's correct.
            let stream = try await streamMessage(testMessage, model: testModel, maxTokens: nil)
            var response = ""

            for try await result in stream {
                if let text = result.text {
                    response += text
                }
                if result.type == "message_stop" {
                    break
                }
            }

            return response.lowercased().contains("hello")
        } catch {
            print("OpenRouter API Key Test Failed: \(error)")
            return false
        }
    }

    func dispose() async {
        // No special cleanup needed
    }
}
