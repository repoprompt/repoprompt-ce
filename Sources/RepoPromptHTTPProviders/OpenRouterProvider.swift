import Foundation
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import SwiftOpenAI

package class OpenRouterProvider: AIProvider {
    private let cachedApiKey: String
    private let host: any OpenRouterHTTPHost
    private let sessionConfigurationFactory: (() -> URLSessionConfiguration)?

    package init(apiKey: String, host: any OpenRouterHTTPHost, sessionConfigurationFactory: (() -> URLSessionConfiguration)? = nil) {
        cachedApiKey = apiKey
        self.host = host
        self.sessionConfigurationFactory = sessionConfigurationFactory
    }

    private func getConfiguration() -> OpenRouterConfiguration {
        host.configuration()
    }

    private func getService() -> OpenAIService {
        let config = getConfiguration()

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

        let configuration = sessionConfigurationFactory?() ?? URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 21600 // 6 hours
        configuration.timeoutIntervalForResource = 21600 // 6 hours

        return OpenAIServiceFactory.service(
            apiKey: cachedApiKey,
            overrideBaseURL: "https://openrouter.ai",
            configuration: configuration,
            proxyPath: "api",
            extraHeaders: headers,
            debugEnabled: false
        )
    }

    package func streamMessage(_ aiMessage: RepoPromptDomainRuntime.AIMessage, model: AIModel, maxTokens: Int?) async throws -> AsyncThrowingStream<RepoPromptDomainRuntime.AIStreamResult, Error> {
        // If model streaming is disabled, use completeMessage instead
        if !host.canStream(for: model) {
            let result = try await completeMessage(aiMessage, model: model, maxTokens: maxTokens)
            return AsyncThrowingStream { continuation in
                continuation.yield(RepoPromptDomainRuntime.AIStreamResult(type: "content", text: result.text, reasoning: nil, promptTokens: nil, completionTokens: nil))
                switch result.completionOutcome {
                case .completed:
                    continuation.yield(RepoPromptDomainRuntime.AIStreamResult(type: "message_stop", text: nil, reasoning: nil, promptTokens: result.promptTokens, completionTokens: result.completionTokens, cost: result.cost))
                case let .incomplete(reason):
                    continuation.yield(RepoPromptDomainRuntime.AIStreamResult(type: RepoPromptDomainRuntime.AIStreamResult.incompleteType, text: nil, promptTokens: result.promptTokens, completionTokens: result.completionTokens, cost: result.cost, stopReason: reason))
                }
                continuation.finish()
            }
        }

        let messages = try aiMessage.openAIChatMessages(embedSystemPrompt: false)
        let config = getConfiguration()

        // Use configuration values only if useCustomSettings is true
        let effectiveMaxTokens = config.useCustomSettings ? (maxTokens ?? config.baseConfig.maxTokens) : 8192

        // Honour global & per-model overrides
        let effectiveTemperature = host.effectiveTemperature(for: aiMessage, model: model)

        let parameters = ChatCompletionParameters(
            messages: messages,
            model: .custom(host.modelName(for: model)),
            maxTokens: effectiveMaxTokens,
            temperature: effectiveTemperature
        )

        let service = getService()
        let stream = try await service.startStreamedChat(parameters: parameters)

        print("Model: \(host.modelName(for: model))")

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    var promptTokens: Int? = nil
                    var completionTokens: Int? = nil
                    var cost: Double? = nil
                    var observedCompletionOutcome: AIProviderCompletionOutcome?

                    for try await chunk in stream {
                        // Use optional chaining to unwrap the optional 'choices'
                        let choice = chunk.choices?.first
                        let content = choice?.delta?.content
                        let reasoning = choice?.delta?.reasoningContent
                        let finishReason = choice?.finishReason

                        // Extract token usage from the final response chunk if available
                        if let usage = chunk.usage {
                            promptTokens = usage.promptTokens
                            completionTokens = usage.completionTokens
                            cost = usage.cost
                        }

                        // Only yield if there's something
                        if let c = content, !c.isEmpty {
                            continuation.yield(RepoPromptDomainRuntime.AIStreamResult(type: "content", text: c, reasoning: reasoning, promptTokens: promptTokens, completionTokens: completionTokens, cost: cost))
                        } else if let r = reasoning, !r.isEmpty {
                            continuation.yield(RepoPromptDomainRuntime.AIStreamResult(type: "content", text: nil, reasoning: r))
                        }
                        if let completionOutcome = openAIChatCompletionOutcome(finishReason) {
                            observedCompletionOutcome = completionOutcome
                        }
                    }

                    switch observedCompletionOutcome {
                    case .completed:
                        continuation.yield(RepoPromptDomainRuntime.AIStreamResult(type: "message_stop", text: nil, reasoning: nil, promptTokens: promptTokens, completionTokens: completionTokens, cost: cost))
                    case let .incomplete(reason):
                        continuation.yield(RepoPromptDomainRuntime.AIStreamResult(type: RepoPromptDomainRuntime.AIStreamResult.incompleteType, text: nil, promptTokens: promptTokens, completionTokens: completionTokens, cost: cost, stopReason: reason))
                    case nil:
                        break
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    package func completeMessage(_ aiMessage: RepoPromptDomainRuntime.AIMessage, model: AIModel, maxTokens: Int?) async throws -> RepoPromptDomainRuntime.AICompletionResult {
        let messages = try aiMessage.openAIChatMessages(embedSystemPrompt: false)
        let config = getConfiguration()

        // Use configuration values only if useCustomSettings is true
        let effectiveMaxTokens = config.useCustomSettings ? (maxTokens ?? config.baseConfig.maxTokens) : maxTokens

        // Honour global & per-model overrides
        let effectiveTemperature = host.effectiveTemperature(for: aiMessage, model: model)

        let parameters = ChatCompletionParameters(
            messages: messages,
            model: .custom(host.modelName(for: model)),
            maxTokens: effectiveMaxTokens,
            temperature: effectiveTemperature
        )

        let service = getService()
        let completion = try await service.startChat(parameters: parameters)

        // Extract token usage if available
        let promptTokens = completion.usage?.promptTokens
        let completionTokens = completion.usage?.completionTokens
        let cost = completion.usage?.cost

        let choice = completion.choices?.first
        let content = choice?.message?.content ?? ""
        let completionOutcome = openAIChatCompletionOutcome(choice?.finishReason)
            ?? .incomplete(reason: "missing_finish_reason")

        return RepoPromptDomainRuntime.AICompletionResult(
            text: content,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            cost: cost,
            completionOutcome: completionOutcome
        )
    }

    /// Tests if the given API key is valid by issuing a short query
    package func testAPIKey(model: AIModel? = nil) async throws -> Bool {
        let testMessage = RepoPromptDomainRuntime.AIMessage(systemPrompt: "You are a helpful assistant.", userMessage: "Say hello")
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

    package func dispose() async {
        // No special cleanup needed
    }
}
