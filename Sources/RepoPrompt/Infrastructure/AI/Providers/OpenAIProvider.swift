import Foundation
import SwiftOpenAI

class OpenAIProvider: AIProvider {
    // Instance-level cache
    private let cachedApiKey: String?
    private let cachedBaseURL: URL?
    private var failedSetup: Bool = false
    private let configuredMaxTokens: Int? // Add property to store configured max tokens
    private let overrideVersion: String? // Add property for API version override
    private let includeUsageInStream: Bool // Whether to include usage in streamed responses
    private let serviceTier: String? // Service tier for Responses API (auto/default/flex/priority)

    init(apiKey: String? = nil, baseURL: URL? = nil, configuredMaxTokens: Int? = nil, overrideVersion: String? = nil, includeUsageInStream: Bool = true, serviceTier: String? = nil) {
        cachedApiKey = apiKey
        cachedBaseURL = baseURL
        self.configuredMaxTokens = configuredMaxTokens
        self.overrideVersion = overrideVersion
        self.includeUsageInStream = includeUsageInStream
        self.serviceTier = serviceTier
    }

    // MARK: - Provider-specific overrides

    /// Sub-classes can override to supply a model-specific token cap.
    /// Return `nil` to indicate "no special handling".
    open func providerSpecificMaxTokens(for model: AIModel) -> Int? {
        nil
    }

    /// Get service using cached values
    open func getService() -> OpenAIService {
        let apiKey = cachedApiKey ?? ""

        if let baseURL = cachedBaseURL {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 21600 // 6 hours
            configuration.timeoutIntervalForResource = 21600 // 6 hours

            return OpenAIServiceFactory.service(
                apiKey: apiKey,
                overrideBaseURL: baseURL.absoluteString,
                configuration: configuration,
                overrideVersion: overrideVersion,
                includeUsageInStream: includeUsageInStream,
                debugEnabled: false
            )
        }

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 21600 // 6 hours
        configuration.timeoutIntervalForResource = 21600 // 6 hours

        return OpenAIServiceFactory.service(
            apiKey: apiKey,
            configuration: configuration
        )
    }

    /// Returns a sensible default max token limit if caller has not provided one.
    private func defaultMaxTokens(for model: AIModel) -> Int {
        switch model {
        case .gpt41:
            16384
        case .o3:
            100_000
        case .o1Mini:
            65536
        case .o1Preview:
            32768
        case .gpt5Pro, .gpt5ProXHigh, .gpt54Pro, .gpt54ProXHigh:
            100_000
        // --- New o3/o3pro variants ---
        case .o3Low, .o3High:
            100_000 // same as o3
        case .gpt5, .gpt5Low, .gpt5High, .gpt5XHigh,
             .gpt54, .gpt54Low, .gpt54High, .gpt54XHigh,
             .gpt54Mini, .gpt54MiniLow, .gpt54MiniHigh, .gpt54MiniXHigh, .gpt54Nano,
             .gpt5CodexLow, .gpt5CodexMed, .gpt5CodexHigh, .gpt5CodexXHigh:
            128_000
        // Fallback: Let the API handle it by not setting a token limit.
        default:
            2048
        }
    }

    private func resolvedMaxTokens(for model: AIModel, override maxTokens: Int?) -> Int {
        configuredMaxTokens
            ?? maxTokens
            ?? providerSpecificMaxTokens(for: model)
            ?? defaultMaxTokens(for: model)
    }

    func resolvedResponseMaxTokens(for model: AIModel, override maxTokens: Int?) -> Int? {
        let explicitOrProviderMax = configuredMaxTokens
            ?? maxTokens
            ?? providerSpecificMaxTokens(for: model)
        if case .openaiCustomResponses = model {
            return explicitOrProviderMax
        }
        if case .openaiCustomReasoning = model {
            return explicitOrProviderMax
        }
        return explicitOrProviderMax ?? defaultMaxTokens(for: model)
    }

    private func shouldOmitMaxOutputTokens(for model: AIModel) -> Bool {
        // Respect explicit user configuration
        if configuredMaxTokens != nil {
            return false
        }
        let baseModel = model.openAIServiceTierBase
        // Don't pass max_output_tokens for first-party OpenAI models — let the API handle defaults
        switch baseModel {
        case .gpt5Pro, .gpt5ProXHigh, .gpt54Pro, .gpt54ProXHigh,
             .o3, .o3Low, .o3High,
             .gpt5, .gpt5Low, .gpt5High, .gpt5XHigh,
             .gpt54, .gpt54Low, .gpt54High, .gpt54XHigh,
             .gpt54Mini, .gpt54MiniLow, .gpt54MiniHigh, .gpt54MiniXHigh, .gpt54Nano,
             .gpt5CodexLow, .gpt5CodexMed, .gpt5CodexHigh, .gpt5CodexXHigh:
            return true
        default:
            return false
        }
    }

    // The createMessages method has been removed in favor of using AIMessage.openAIChatMessages

    // MARK: Helper – build the `input` array for the Responses API

    private func createResponseInput(for aiMessage: AIMessage) -> SwiftOpenAI.InputType {
        // Forward to the centralised builder defined on AIMessage
        aiMessage.openAIResponsesInput()
    }

    // MARK: - Helper to decide whether to route via Responses-API

    private func shouldUseResponsesAPI(for model: AIModel) -> Bool {
        model.usesResponsesAPI
    }

    func buildForegroundResponseParameters(
        _ aiMessage: AIMessage,
        model: AIModel,
        maxTokens: Int?,
        stream: Bool
    ) -> ModelResponseParameter {
        let (baseModel, reasoningEffort) = resolveBaseModelAndEffort(for: model)

        var parameters = ModelResponseParameter(
            input: createResponseInput(for: aiMessage),
            model: baseModel.toProviderModel() as! SwiftOpenAI.Model
        )

        if !aiMessage.systemPrompt.isEmpty {
            parameters.instructions = aiMessage.systemPrompt
        }

        if !shouldOmitMaxOutputTokens(for: model) {
            parameters.maxOutputTokens = maxTokens
        }

        if let effort = reasoningEffort {
            parameters.reasoning = stream
                ? Reasoning(effort: effort, summary: "auto")
                : Reasoning(effort: effort)
        }

        parameters.stream = stream
        parameters.serviceTier = resolvedServiceTier(for: model)
        parameters.tools = nil
        parameters.toolChoice = nil
        return parameters
    }

    func streamMessage(
        _ aiMessage: AIMessage,
        model: AIModel,
        maxTokens: Int?
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        let finalMaxTokens = resolvedMaxTokens(for: model, override: maxTokens)

        // Honour user / model override that disables streaming entirely
        let forceCompletion = !model.canStream

        // Route via Responses-API when required
        if shouldUseResponsesAPI(for: model) {
            let responseMaxTokens = resolvedResponseMaxTokens(for: model, override: maxTokens)
            // Use *background job + streaming attach* when the model forbids direct streaming.
            // This creates a queued job and then attaches via SSE for incremental output.
            if forceCompletion {
                let response = try await createBackgroundResponse(
                    aiMessage,
                    model: model,
                    maxTokens: responseMaxTokens
                )
                return try await streamResponse(id: response.id)
            } else {
                // Real streaming via SSE (responseCreateStream)
                return try await getResponseStreamViaResponsesAPI(
                    aiMessage,
                    model: model,
                    maxTokens: responseMaxTokens
                )
            }
        }

        // Handle other non-streaming models via completeMessage
        if !model.canStream {
            let result = try await completeMessage(aiMessage, model: model, maxTokens: finalMaxTokens)
            return AsyncThrowingStream { continuation in
                continuation.yield(AIStreamResult(type: "content", text: result.text, reasoning: nil, promptTokens: nil, completionTokens: result.completionTokens))
                continuation.yield(AIStreamResult(type: "message_stop", text: nil, reasoning: nil, promptTokens: result.promptTokens, completionTokens: result.completionTokens))
                continuation.finish()
            }
        }

        // Existing streaming logic follows...
        // NEW o3 flags
        let modelIsO3High = (model == .o3High)
        let modelIsO3Low = (model == .o3Low)

        // Decide base model
        let effectiveModel: AIModel = if modelIsO3High || modelIsO3Low {
            .o3
        } else {
            model
        }

        print("Effective model: \(effectiveModel)")

        let isO1PreviewOrMini = (effectiveModel == .o1Mini || effectiveModel == .o1Preview)
        let messages = aiMessage.openAIChatMessages(embedSystemPrompt: isO1PreviewOrMini)
        var parameters = ChatCompletionParameters(
            messages: messages,
            model: effectiveModel.toProviderModel() as! SwiftOpenAI.Model
        )

        if finalMaxTokens != 2048 {
            switch effectiveModel {
            case .o3, .o1Mini, .o1Preview:
                parameters.maCompletionTokens = finalMaxTokens
            default:
                parameters.maxTokens = finalMaxTokens
            }
        }

        if modelIsO3High {
            parameters.reasoningEffort = "high"
        } else if modelIsO3Low {
            parameters.reasoningEffort = "low"
        }

        // Apply temperature from AIMessage if provided for models that support it
        if let messageTemperature = aiMessage.effectiveTemperature(for: effectiveModel),
           ![.o3, .o1Mini, .o1Preview].contains(effectiveModel)
        {
            parameters.temperature = messageTemperature
        }

        let service = getService()
        let stream = try await service.startStreamedChat(parameters: parameters)

        return AsyncThrowingStream { continuation in
            let bridgeTask = Task {
                do {
                    var promptTokens: Int? = nil
                    var completionTokens: Int? = nil

                    for try await result in stream {
                        // Check cancellation to exit promptly when consumer stops reading
                        if Task.isCancelled {
                            break
                        }

                        let content = result.choices?.first?.delta?.content ?? ""
                        let reasoning = result.choices?.first?.delta?.reasoningContent ?? ""

                        // Extract token usage from the final response chunk if available
                        if let usage = result.usage {
                            promptTokens = usage.promptTokens
                            completionTokens = usage.completionTokens
                        }

                        if !content.isEmpty || !reasoning.isEmpty {
                            continuation.yield(
                                AIStreamResult(type: "content", text: content, reasoning: reasoning, promptTokens: promptTokens, completionTokens: completionTokens)
                            )
                        }
                    }
                    continuation.yield(AIStreamResult(type: "message_stop", text: nil, reasoning: nil, promptTokens: promptTokens, completionTokens: completionTokens))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Propagate cancellation when consumer stops reading the stream
            continuation.onTermination = { _ in bridgeTask.cancel() }
        }
    }

    /// Method to handle o1pro using the Responses API
    private func getResponseViaResponsesAPI(
        _ aiMessage: AIMessage,
        model: AIModel, // Keep model parameter for clarity and potential future use
        maxTokens: Int? // Keep maxTokens parameter
    ) async throws -> AICompletionResult {
        let service = getService()
        let parameters = buildForegroundResponseParameters(
            aiMessage,
            model: model,
            maxTokens: maxTokens,
            stream: false
        )

        do {
            // Assuming responseCreate exists in the service layer as per previous code.
            let response = try await service.responseCreate(parameters)

            // Check response status and potential errors before extracting text
            guard response.status == .completed else {
                let statusString = response.status?.rawValue ?? "unknown"
                let errorDetail = response.error?.message ?? response.incompleteDetails?.reason ?? "Response status was '\(statusString)'"
                throw AIProviderError.invalidResponse(detail: "Responses API call did not complete successfully. Status: \(statusString). Detail: \(errorDetail)")
            }

            // Extract text content using the convenience property
            guard let responseText = response.outputText, !responseText.isEmpty else {
                // Handle cases where the response completed but has no text output
                throw AIProviderError.invalidResponse(detail: "Responses API call completed but returned no text content.")
            }

            var promptTokens: Int? = nil
            var completionTokens: Int? = nil

            if let usage = response.usage {
                promptTokens = usage.inputTokens
                completionTokens = usage.outputTokens
            }

            return AICompletionResult(
                text: responseText,
                promptTokens: promptTokens,
                completionTokens: completionTokens
            )

        } catch let error as APIError {
            // Handle specific API errors from the SwiftOpenAI library
            throw AIProviderError.apiError(source: error) // Wrap the original APIError

        } catch let error as AIProviderError {
            // Re-throw known provider errors
            throw error
        } catch {
            // Handle other unexpected errors during the API call
            throw AIProviderError.unknown(source: error) // Wrap unknown errors
        }
    }

    // MARK: – Streaming helper for the Responses API

    /// Creates an *async* stream backed by the `responseCreateStream` SSE
    /// endpoint and converts `ResponseStreamEvent`s into `AIStreamResult`s.
    private func getResponseStreamViaResponsesAPI(
        _ aiMessage: AIMessage,
        model: AIModel,
        maxTokens: Int?
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        let service = getService()
        let parameters = buildForegroundResponseParameters(
            aiMessage,
            model: model,
            maxTokens: maxTokens,
            stream: true
        )

        let sseStream = try await service.responseCreateStream(parameters)
        return bridgeResponseStream(sseStream)
    }

    func completeMessage(
        _ aiMessage: AIMessage,
        model: AIModel,
        maxTokens: Int? = nil
    ) async throws -> AICompletionResult {
        let finalMaxTokens = resolvedMaxTokens(for: model, override: maxTokens)

        if shouldUseResponsesAPI(for: model) {
            return try await getResponseViaResponsesAPI(
                aiMessage,
                model: model,
                maxTokens: resolvedResponseMaxTokens(for: model, override: maxTokens)
            )
        }

        let isO1PreviewOrMini = (model == .o1Mini || model == .o1Preview)
        let messages = aiMessage.openAIChatMessages(embedSystemPrompt: isO1PreviewOrMini)
        var parameters = ChatCompletionParameters(
            messages: messages,
            model: model.toProviderModel() as! SwiftOpenAI.Model
        )

        // NEW o3 flags
        let modelIsO3High = (model == .o3High)
        let modelIsO3Low = (model == .o3Low)

        // Decide base model
        let effectiveModel: AIModel = if modelIsO3High || modelIsO3Low {
            .o3
        } else {
            model
        }

        if finalMaxTokens != 2048 {
            switch effectiveModel {
            case .o3, .o1Mini, .o1Preview:
                parameters.maCompletionTokens = finalMaxTokens
            default:
                parameters.maxTokens = finalMaxTokens
            }
        }

        if modelIsO3High {
            parameters.reasoningEffort = "high"
        } else if modelIsO3Low {
            parameters.reasoningEffort = "low"
        }

        // Apply user-defined temperature if override is enabled for models that support it
        if let messageTemperature = aiMessage.effectiveTemperature(for: effectiveModel),
           ![.o3, .o1Mini, .o1Preview].contains(effectiveModel)
        {
            parameters.temperature = messageTemperature
        }

        let service = getService()
        let response = try await service.startChat(parameters: parameters)

        // Extract token usage if available
        let promptTokens = response.usage?.promptTokens
        let completionTokens = response.usage?.completionTokens

        let content = response.choices?.first?.message?.content ?? ""

        // Return an AICompletionResult with content and token counts
        return AICompletionResult(
            text: content,
            promptTokens: promptTokens,
            completionTokens: completionTokens
        )
    }

    /// Example testKey usage
    func testAPIKey(model: AIModel = .gpt54Mini) async throws -> Bool {
        let testMessage = AIMessage(systemPrompt: "You are a helpful assistant.", userMessage: "Say hello")
        // Don't set max tokens for test - let the API use defaults to avoid minimum token errors

        // Try the requested model first
        do {
            let response = try await callAppropriateCompletion(for: model, message: testMessage, nil)
            if response.lowercased().contains("hello") {
                return true
            }
        } catch {
            print("Initial model \(model.displayName) failed in testAPIKey: \(error)")
        }

        // Fallback chain: gpt41 -> gpt5Low
        let fallbacks: [AIModel] = [.gpt41, .gpt5Low].filter { $0 != model }
        for fallback in fallbacks {
            do {
                print("Falling back to \(fallback.displayName) in testAPIKey...")
                let response = try await callAppropriateCompletion(for: fallback, message: testMessage, nil)
                if response.lowercased().contains("hello") {
                    return true
                }
            } catch {
                print("Fallback model \(fallback.displayName) failed in testAPIKey: \(error)")
            }
        }

        // All attempts failed
        print("All models failed in testAPIKey.")
        return false
    }

    private func bridgeResponseStream(_ stream: AsyncThrowingStream<ResponseStreamEvent, Error>) -> AsyncThrowingStream<AIStreamResult, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var promptTokens: Int?
                    var completionTokens: Int?

                    for try await event in stream {
                        if Task.isCancelled {
                            break
                        }
                        switch event {
                        case let .outputTextDelta(delta):
                            if !delta.delta.isEmpty {
                                continuation.yield(
                                    AIStreamResult(
                                        type: "content",
                                        text: delta.delta,
                                        reasoning: nil,
                                        promptTokens: nil,
                                        completionTokens: nil,
                                        cost: nil
                                    )
                                )
                            }
                        case let .reasoningSummaryTextDelta(delta):
                            if !delta.delta.isEmpty {
                                continuation.yield(
                                    AIStreamResult(
                                        type: "content",
                                        text: nil,
                                        reasoning: delta.delta,
                                        promptTokens: nil,
                                        completionTokens: nil,
                                        cost: nil
                                    )
                                )
                            }
                        case let .responseCompleted(completed):
                            if let usage = completed.response.usage {
                                promptTokens = usage.inputTokens
                                completionTokens = usage.outputTokens
                            }
                        case let .responseFailed(failed):
                            let message = failed.response.error?.message ?? "Responses API returned a failure."
                            throw AIProviderError.invalidResponse(detail: message)
                        case let .responseIncomplete(incomplete):
                            let detail = incomplete.response.incompleteDetails?.reason ?? "Responses API marked the response as incomplete."
                            throw AIProviderError.invalidResponse(detail: detail)
                        case let .error(errorEvent):
                            throw APIError.requestFailed(description: errorEvent.prettyDescription)
                        default:
                            continue
                        }
                    }

                    continuation.yield(
                        AIStreamResult(
                            type: "message_stop",
                            text: nil,
                            reasoning: nil,
                            promptTokens: promptTokens,
                            completionTokens: completionTokens,
                            cost: nil
                        )
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func buildBackgroundResponseParameters(
        _ aiMessage: AIMessage,
        model: AIModel,
        maxTokens: Int?
    ) -> ModelResponseParameter {
        let (baseModel, reasoningEffort) = resolveBaseModelAndEffort(for: model)
        var parameters = ModelResponseParameter(
            input: aiMessage.openAIResponsesInput(),
            model: baseModel.toProviderModel() as! SwiftOpenAI.Model
        )

        if !aiMessage.systemPrompt.isEmpty {
            parameters.instructions = aiMessage.systemPrompt
        }

        // Don't pass max_output_tokens for Pro models — the API rejects it.
        if !shouldOmitMaxOutputTokens(for: model) {
            parameters.maxOutputTokens = maxTokens
        }

        if let effort = reasoningEffort {
            parameters.reasoning = Reasoning(effort: effort)
        }

        // Only apply temperature for non-reasoning models (reasoning models don't support it)
        if reasoningEffort == nil, let temperature = aiMessage.effectiveTemperature(for: baseModel) {
            parameters.temperature = temperature
        }

        // Apply service tier if configured (per-model override takes precedence)
        parameters.serviceTier = resolvedServiceTier(for: model)

        parameters.background = true
        parameters.stream = false
        return parameters
    }

    /// Helper function to decide whether to use completeMessage or getResponseViaResponsesAPI
    private func callAppropriateCompletion(for model: AIModel, message: AIMessage, _ maxTokens: Int?) async throws -> String {
        if shouldUseResponsesAPI(for: model) {
            // Pass the AIMessage and maxTokens directly
            let result = try await getResponseViaResponsesAPI(message, model: model, maxTokens: maxTokens)
            return result.text
        } else {
            // Assuming other non-streaming models should use completeMessage
            // Note: This assumes completeMessage doesn't internally try to stream.
            // If completeMessage *can* handle streaming models, this logic might need adjustment.
            // For now, assume completeMessage is for non-streaming, non-o1pro models.
            let result = try await completeMessage(message, model: model, maxTokens: maxTokens)
            return result.text
        }
    }

    func dispose() async {
        // No resources to free in this example
    }

    // MARK: - Service Tier Resolution

    /// Returns the effective service tier for a request - prefers per-model override over global setting
    private func resolvedServiceTier(for model: AIModel) -> String? {
        switch model.openAIServiceTierBase {
        case .openaiCustomResponses, .openaiCustomReasoning:
            return nil
        default:
            break
        }
        return model.openAIServiceTierOverride ?? serviceTier
    }

    // MARK: - Variant Mapping Helper

    /// Returns the canonical base model and its associated reasoning effort
    /// string ("high", "medium", "low" or `nil` when not applicable).
    private func resolveBaseModelAndEffort(for model: AIModel)
        -> (baseModel: AIModel, reasoningEffort: String?)
    {
        // Unwrap tier variants first
        let model = model.openAIServiceTierBase
        switch model {
        case .gpt5Pro: return (.gpt5Pro, "high")
        case .gpt5ProXHigh: return (.gpt5Pro, "xhigh")
        case .gpt54Pro: return (.gpt54Pro, "high")
        case .gpt54ProXHigh: return (.gpt54Pro, "xhigh")
        case .o3High: return (.o3, "high")
        case .o3Low: return (.o3, "low")
        case .o3: return (.o3, "medium")
        case .gpt5XHigh: return (.gpt5, "xhigh")
        case .gpt5High: return (.gpt5, "high")
        case .gpt5Low: return (.gpt5, "low")
        case .gpt5: return (.gpt5, "medium")
        case .gpt54XHigh: return (.gpt54, "xhigh")
        case .gpt54High: return (.gpt54, "high")
        case .gpt54Low: return (.gpt54, "low")
        case .gpt54: return (.gpt54, "medium")
        // ── gpt5-codex-max family (Responses API) ──
        case .gpt5CodexXHigh: return (.gpt5CodexMed, "xhigh")
        case .gpt5CodexHigh: return (.gpt5CodexMed, "high")
        case .gpt5CodexMed: return (.gpt5CodexMed, "medium")
        case .gpt5CodexLow: return (.gpt5CodexMed, "low")
        // ── gpt-5.4-mini family ──
        case .gpt54MiniXHigh: return (.gpt54Mini, "xhigh")
        case .gpt54MiniHigh: return (.gpt54Mini, "high")
        case .gpt54MiniLow: return (.gpt54Mini, "low")
        case .gpt54Mini: return (.gpt54Mini, "medium")
        case .openaiCustomReasoning:
            return (model, model.defaultReasoningEffort)
        default: return (model, nil)
        }
    }
}

extension OpenAIProvider: ResponsesJobProvider {
    func createBackgroundResponse(
        _ message: AIMessage,
        model: AIModel,
        maxTokens: Int?
    ) async throws -> ResponseModel {
        let parameters = buildBackgroundResponseParameters(message, model: model, maxTokens: maxTokens)
        let response = try await getService().responseCreate(parameters)

        if response.status == .failed {
            let detail = response.error?.message ?? response.incompleteDetails?.reason ?? "Responses API returned a failed status."
            throw AIProviderError.invalidResponse(detail: detail)
        }
        return response
    }

    func fetchResponse(id: String) async throws -> ResponseModel {
        try await getService().responseModel(id: id, parameters: nil)
    }

    func streamResponse(id: String) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        let service = getService()

        // Use polling instead of SSE for more reliable background job monitoring
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var lastStatus: ResponseModel.Status?
                    var pollCount = 0

                    /// Exponential backoff: 2s, 3s, 4s, 5s... capped at 10s
                    func pollInterval() -> Duration {
                        .seconds(min(2 + pollCount, 10))
                    }

                    continuation.yield(
                        AIStreamResult(
                            type: "content",
                            text: nil,
                            reasoning: "Background job started, polling for updates...\n",
                            promptTokens: nil,
                            completionTokens: nil,
                            cost: nil
                        )
                    )

                    while !Task.isCancelled {
                        let response = try await service.responseModel(id: id, parameters: nil)
                        pollCount += 1

                        // Emit status change updates
                        if response.status != lastStatus {
                            lastStatus = response.status
                            let statusMessage = switch response.status {
                            case .queued:
                                "Job queued, waiting for processing...\n"
                            case .inProgress:
                                "Processing started...\n"
                            case .completed, .failed, .incomplete, .cancelled, .none:
                                "" // Will be handled below
                            }
                            if !statusMessage.isEmpty {
                                continuation.yield(
                                    AIStreamResult(
                                        type: "content",
                                        text: nil,
                                        reasoning: statusMessage,
                                        promptTokens: nil,
                                        completionTokens: nil,
                                        cost: nil
                                    )
                                )
                            }
                        }

                        // Check for terminal states
                        switch response.status {
                        case .completed:
                            // Extract the output text from the response
                            var outputText = ""
                            var reasoningText = ""
                            for item in response.output {
                                switch item {
                                case let .message(msg):
                                    for content in msg.content {
                                        if case let .outputText(textContent) = content {
                                            outputText += textContent.text
                                        }
                                    }
                                case let .reasoning(reasoning):
                                    for summary in reasoning.summary {
                                        reasoningText += summary.text
                                    }
                                default:
                                    break
                                }
                            }

                            if !reasoningText.isEmpty {
                                continuation.yield(
                                    AIStreamResult(
                                        type: "content",
                                        text: nil,
                                        reasoning: reasoningText,
                                        promptTokens: nil,
                                        completionTokens: nil,
                                        cost: nil
                                    )
                                )
                            }

                            if !outputText.isEmpty {
                                continuation.yield(
                                    AIStreamResult(
                                        type: "content",
                                        text: outputText,
                                        reasoning: nil,
                                        promptTokens: nil,
                                        completionTokens: nil,
                                        cost: nil
                                    )
                                )
                            }

                            continuation.yield(
                                AIStreamResult(
                                    type: "message_stop",
                                    text: nil,
                                    reasoning: nil,
                                    promptTokens: response.usage?.inputTokens,
                                    completionTokens: response.usage?.outputTokens,
                                    cost: nil
                                )
                            )
                            continuation.finish()
                            return

                        case .failed:
                            let message = response.error?.message ?? "Background job failed."
                            throw AIProviderError.invalidResponse(detail: message)

                        case .incomplete:
                            let detail = response.incompleteDetails?.reason ?? "Background job incomplete."
                            throw AIProviderError.invalidResponse(detail: detail)

                        case .cancelled:
                            throw AIProviderError.invalidResponse(detail: "Background job was cancelled.")

                        case .queued, .inProgress, .none:
                            // Continue polling with exponential backoff
                            try await Task.sleep(for: pollInterval())
                        }
                    }

                    // If we exit the loop due to cancellation
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { termination in
                task.cancel()
                // Cancel the background job on the server to prevent wasted tokens
                if case .cancelled = termination {
                    Task {
                        _ = try? await service.responseCancel(id: id)
                    }
                }
            }
        }
    }

    func cancelResponse(id: String) async throws -> ResponseModel {
        try await getService().responseCancel(id: id)
    }
}
