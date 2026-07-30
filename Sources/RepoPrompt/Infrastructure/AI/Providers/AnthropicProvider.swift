import Foundation
import SwiftAnthropic

class AnthropicProvider: AIProvider {
    private let service: AnthropicService

    init(apiKey: String, betaHeaders: [String] = ["messages-2023-12-15", "prompt-caching-2024-07-31", "output-128k-2025-02-19"]) {
        service = AnthropicServiceFactory.service(apiKey: apiKey, betaHeaders: betaHeaders)
    }

    private func createMessages(for aiMessage: AIMessage) -> [MessageParameter.Message] {
        let tail = aiMessage.buildTail(embedSystemPrompt: false)
        let lastUserIndex = aiMessage.conversationMessages.lastIndex { $0.role == .user }
        var messages: [MessageParameter.Message] = []

        for (idx, entry) in aiMessage.conversationMessages.enumerated() {
            let contentText: String = if let lastIdx = lastUserIndex,
                                         entry.role == .user,
                                         idx == lastIdx,
                                         !tail.isEmpty
            {
                "\(tail)\n\n\(entry.content)"
            } else {
                entry.content
            }

            let role: MessageParameter.Message.Role = (entry.role == .user) ? .user : .assistant
            messages.append(
                MessageParameter.Message(
                    role: role,
                    content: .text(contentText)
                )
            )
        }

        return messages
    }

    private func createSystemParameter(systemPrompt: String) -> MessageParameter.System {
        .list([
            MessageParameter.Cache(
                type: .text,
                text: systemPrompt,
                cacheControl: MessageParameter.CacheControl(type: .ephemeral)
            )
        ])
    }

    func streamMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens: Int? = nil) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        // Check if streaming is enabled for the model
        if !model.canStream {
            let result = try await completeMessage(aiMessage, model: model, maxTokens: maxTokens)
            return AsyncThrowingStream { continuation in
                continuation.yield(AIStreamResult(type: "content", text: result.text, reasoning: nil, promptTokens: nil, completionTokens: nil))
                continuation.yield(AIStreamResult(type: "message_stop", text: nil, reasoning: nil, promptTokens: result.promptTokens, completionTokens: result.completionTokens))
                continuation.finish()
            }
        }
        guard !aiMessage.systemPrompt.isEmpty else {
            throw AIProviderError.invalidSystemPrompt
        }

        // Get the model name and strip thinking suffix if present
        let modelName = model.modelName
        let baseModelName: String
        let isThinkingMode: Bool
        let thinkingBudget: Int
        var overrideMaxTokens = 8192

        if modelName.hasSuffix("-thinking-max") {
            baseModelName = String(modelName.dropLast("-thinking-max".count))
            isThinkingMode = true
            thinkingBudget = 32000
            overrideMaxTokens = 64000
        } else if modelName.hasSuffix("-thinking") {
            baseModelName = String(modelName.dropLast("-thinking".count))
            isThinkingMode = true
            // Check if it's Opus thinking (different budget)
            if modelName.contains("opus") {
                thinkingBudget = 16000
                overrideMaxTokens = 32000
            } else {
                // Sonnet thinking
                thinkingBudget = 16000
                overrideMaxTokens = 64000
            }
        } else {
            baseModelName = modelName
            isThinkingMode = false
            thinkingBudget = 0
        }

        let anthropicModel = SwiftAnthropic.Model.other(baseModelName)

        // Use your existing helper functions
        let systemParameter = createSystemParameter(systemPrompt: aiMessage.systemPrompt)
        let messages = createMessages(for: aiMessage)

        var temperature: Double? = 0
        // Skip temperature setting for thinking models
        if isThinkingMode {
            temperature = nil
        }
        // Apply user-defined temperature if override is enabled (for non-thinking models)
        else if let messageTemperature = aiMessage.effectiveTemperature(for: model) {
            temperature = messageTemperature
        }

        // Create parameters with thinking mode if needed
        let parameters = MessageParameter(
            model: anthropicModel,
            messages: messages,
            maxTokens: overrideMaxTokens,
            system: systemParameter,
            stream: true,
            temperature: temperature,
            thinking: isThinkingMode ? MessageParameter.Thinking(budgetTokens: thinkingBudget) : nil
        )

        let stream = try await service.streamMessage(parameters)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    // Track current thinking content
                    var currentThinking = ""
                    // Track token counts
                    var promptTokens: Int? = nil
                    var completionTokens: Int? = nil

                    for try await result in stream {
                        var reasoning: String? = nil

                        // Handle different stream events
                        switch result.streamEvent {
                        case .contentBlockStart:
                            // Check if this is a thinking block starting
                            if let contentBlock = result.contentBlock, contentBlock.type == "thinking" {
                                if let thinking = contentBlock.thinking {
                                    currentThinking = thinking
                                    reasoning = thinking
                                }
                            }

                        case .contentBlockDelta:
                            // Check for thinking delta updates
                            if let delta = result.delta, delta.type == "thinking_delta" {
                                if let thinking = delta.thinking {
                                    reasoning = thinking
                                }
                            }

                        case .contentBlockStop:
                            // If we're stopping a thinking block, include the final thinking
                            if currentThinking.count > 0 {
                                reasoning = currentThinking
                                currentThinking = ""
                            }

                        case .messageStop:
                            // Extract token usage from the end of stream
                            if let usage = result.usage {
                                promptTokens = usage.inputTokens
                                // Combine outputTokens and thinkingTokens for completion tokens
                                let outputTokens = usage.outputTokens
                                let thinkingTokens = usage.thinkingTokens ?? 0
                                completionTokens = outputTokens + thinkingTokens
                            }

                        default:
                            break
                        }

                        // Create AIStreamResult with text and reasoning
                        let aiResult = AIStreamResult(
                            type: result.type,
                            text: result.contentBlock?.text ?? result.delta?.text,
                            reasoning: reasoning,
                            promptTokens: promptTokens, // Only include tokens in final message_stop
                            completionTokens: completionTokens
                        )

                        continuation.yield(aiResult)
                    }

                    // Send final message_stop with token counts
                    continuation.yield(AIStreamResult(
                        type: "message_stop",
                        text: nil,
                        reasoning: nil,
                        promptTokens: promptTokens,
                        completionTokens: completionTokens
                    ))

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func completeMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens: Int? = nil) async throws -> AICompletionResult {
        // Get the model name and strip thinking suffix if present
        let modelName = model.modelName
        let baseModelName: String
        let isThinkingMode: Bool
        let thinkingBudget: Int
        var overrideMaxTokens = maxTokens ?? 4096

        if modelName.hasSuffix("-thinking-max") {
            baseModelName = String(modelName.dropLast("-thinking-max".count))
            isThinkingMode = true
            thinkingBudget = 32000
            if maxTokens == nil {
                overrideMaxTokens = 64000
            }
        } else if modelName.hasSuffix("-thinking") {
            baseModelName = String(modelName.dropLast("-thinking".count))
            isThinkingMode = true
            // Check if it's Opus thinking (different budget)
            if modelName.contains("opus") {
                thinkingBudget = 16000
                if maxTokens == nil {
                    overrideMaxTokens = 32000
                }
            } else {
                // Sonnet thinking
                thinkingBudget = 16000
                if maxTokens == nil {
                    overrideMaxTokens = 64000
                }
            }
        } else {
            baseModelName = modelName
            isThinkingMode = false
            thinkingBudget = 0
        }

        let anthropicModel = SwiftAnthropic.Model.other(baseModelName)
        return try await completeMessage(aiMessage, model: anthropicModel, maxTokens: overrideMaxTokens, isThinkingMode: isThinkingMode, thinkingBudget: thinkingBudget)
    }

    private func completeMessage(_ aiMessage: AIMessage, model: SwiftAnthropic.Model, maxTokens: Int? = nil, isThinkingMode: Bool = false, thinkingBudget: Int = 0) async throws -> AICompletionResult {
        guard !aiMessage.systemPrompt.isEmpty else {
            throw AIProviderError.invalidSystemPrompt
        }

        let systemParameter = createSystemParameter(systemPrompt: aiMessage.systemPrompt)
        let messages = createMessages(for: aiMessage)

        let parameters = MessageParameter(
            model: model,
            messages: messages,
            maxTokens: maxTokens ?? 4096,
            system: systemParameter,
            stream: false,
            thinking: isThinkingMode ? MessageParameter.Thinking(budgetTokens: thinkingBudget) : nil
        )

        let response = try await service.createMessage(parameters)

        let text = response.content.compactMap { contentItem in
            switch contentItem {
            case let .text(text, _):
                text
            case .toolUse:
                nil
            case let .thinking(thinking):
                thinking.thinking
            case .serverToolUse:
                nil
            case .webSearchToolResult:
                nil
            case .toolResult:
                nil
            case .codeExecutionToolResult:
                nil
            }
        }.joined()

        // Extract token counts from the response
        let promptTokens = response.usage.inputTokens
        // Combine outputTokens and thinkingTokens for completion tokens
        let outputTokens = response.usage.outputTokens
        let thinkingTokens = response.usage.thinkingTokens ?? 0
        let completionTokens = outputTokens + thinkingTokens

        return AICompletionResult(
            text: text,
            promptTokens: promptTokens,
            completionTokens: completionTokens
        )
    }

    func testAPIKey() async throws -> Bool {
        let testMessage = AIMessage(systemPrompt: "You are a helpful assistant.", userMessage: "Say hello")
        let result = try await completeMessage(testMessage, model: .claude3Haiku)
        return result.text.lowercased().contains("hello")
    }
}
