import Foundation
import SwiftOpenAI

public struct AzureOpenAIConfiguration: Codable, Equatable {
    public struct ModelDescriptor: Codable, Equatable {
        public enum EndpointKind: String, Codable {
            case chatCompletions
            case responses
        }

        public let id: String
        public let displayName: String
        public let endpoint: EndpointKind?
        public let supportsStreaming: Bool?
        public let baseModelID: String?
        public let supportsChatCompletions: Bool?
        public let supportsResponses: Bool?

        public init(
            id: String,
            displayName: String? = nil,
            endpoint: EndpointKind? = nil,
            supportsStreaming: Bool? = nil,
            baseModelID: String? = nil,
            supportsChatCompletions: Bool? = nil,
            supportsResponses: Bool? = nil
        ) {
            self.id = id
            self.displayName = displayName ?? id
            self.endpoint = endpoint
            self.supportsStreaming = supportsStreaming
            self.baseModelID = baseModelID
            self.supportsChatCompletions = supportsChatCompletions
            self.supportsResponses = supportsResponses
        }
    }

    public let baseURL: URL
    public let apiKey: String
    public let apiVersion: String
    public let extraHeaders: [String: String]?
    public let models: [ModelDescriptor]
    public let defaultModelID: String?

    public init(
        baseURL: URL,
        apiKey: String,
        apiVersion: String,
        extraHeaders: [String: String]? = nil,
        models: [ModelDescriptor] = [],
        defaultModelID: String? = nil
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.apiVersion = apiVersion
        self.extraHeaders = extraHeaders
        self.models = models
        self.defaultModelID = defaultModelID
    }

    private enum CodingKeys: String, CodingKey {
        case baseURL
        case apiKey
        case apiVersion
        case extraHeaders
        case models
        case defaultModelID
        case supportsChatCompletions
        case supportsResponses
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let baseURLString = try container.decode(String.self, forKey: .baseURL)
        guard let resolvedURL = URL(string: baseURLString) else {
            throw DecodingError.dataCorruptedError(forKey: .baseURL, in: container, debugDescription: "Invalid Azure base URL.")
        }

        baseURL = resolvedURL
        apiKey = try container.decode(String.self, forKey: .apiKey)
        apiVersion = try container.decode(String.self, forKey: .apiVersion)
        extraHeaders = try container.decodeIfPresent([String: String].self, forKey: .extraHeaders)
        models = try container.decodeIfPresent([ModelDescriptor].self, forKey: .models) ?? []
        defaultModelID = try container.decodeIfPresent(String.self, forKey: .defaultModelID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseURL.absoluteString, forKey: .baseURL)
        try container.encode(apiKey, forKey: .apiKey)
        try container.encode(apiVersion, forKey: .apiVersion)
        try container.encodeIfPresent(extraHeaders, forKey: .extraHeaders)
        try container.encode(models, forKey: .models)
        try container.encodeIfPresent(defaultModelID, forKey: .defaultModelID)
    }

    var authorization: Authorization {
        .apiKey(apiKey)
    }

    private var resourceName: String {
        if let host = baseURL.host, !host.isEmpty {
            return host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return baseURL.absoluteString
            .replacingOccurrences(of: "^https?://", with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func descriptor(for modelID: String) -> ModelDescriptor? {
        if let direct = models.first(where: { $0.id == modelID }) {
            return direct
        }
        let normalizedTarget = AzureOpenAIProvider.normalizedModelName(from: modelID).lowercased()
        return models.first {
            AzureOpenAIProvider.normalizedModelName(from: $0.id).lowercased() == normalizedTarget
        }
    }

    var toSwiftOpenAIConfiguration: SwiftOpenAI.AzureOpenAIConfiguration {
        SwiftOpenAI.AzureOpenAIConfiguration(
            resourceName: resourceName,
            openAIAPIKey: authorization,
            apiVersion: apiVersion,
            extraHeaders: extraHeaders
        )
    }

    static func inferredEndpoint(for modelID: String, baseModelID: String? = nil) -> ModelDescriptor.EndpointKind {
        let candidates = [baseModelID, modelID].compactMap(\.self)
        for name in candidates {
            if let equivalent = AIModel.fromModelName(name), equivalent.usesResponsesAPI {
                return .responses
            }
            let lowered = name.lowercased()
            if lowered.hasPrefix("gpt-5") || lowered == "o3" || lowered.hasPrefix("o3-") {
                return .responses
            }
        }
        return .chatCompletions
    }

    static func inferredSupportsStreaming(for modelID: String, baseModelID: String? = nil) -> Bool {
        if let baseModelID, let equivalent = AIModel.fromModelName(baseModelID) {
            return equivalent.canStream
        }
        if let equivalent = AIModel.fromModelName(modelID) {
            return equivalent.canStream
        }
        return !modelID.lowercased().contains("no-stream")
    }
}

extension AzureOpenAIProvider: ResponsesJobProvider {
    func createBackgroundResponse(
        _ message: AIMessage,
        model: AIModel,
        maxTokens: Int?
    ) async throws -> ResponseModel {
        let (deploymentID, descriptor) = try deploymentInfo(for: model)
        let (baseModel, reasoningEffort) = resolveBaseModelAndEffort(for: deploymentID, descriptor: descriptor)
        let finalMaxTokens = resolvedMaxTokens(for: baseModel, override: maxTokens)
        let parameters = buildBackgroundResponseParameters(
            for: message,
            model: model,
            deploymentID: deploymentID,
            baseModel: baseModel,
            reasoningEffort: reasoningEffort,
            maxTokens: finalMaxTokens
        )

        let response = try await azureService.responseCreate(parameters)
        if response.status == .failed {
            let detail = response.error?.message ?? response.incompleteDetails?.reason ?? "Responses API returned a failed status."
            throw AIProviderError.invalidResponse(detail: detail)
        }
        return response
    }

    func fetchResponse(id: String) async throws -> ResponseModel {
        try await azureService.responseModel(id: id, parameters: nil)
    }

    func streamResponse(id: String) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        let service = azureService

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
        try await azureService.responseCancel(id: id)
    }
}

final class AzureOpenAIProvider: AIProvider {
    static var enableDebugLogging: Bool = false
    static let discoveryAPIVersions: [String] = ["2023-03-15-preview"]

    static func debug(_ message: @autoclosure () -> String) {
        if enableDebugLogging {
            print("[Azure] \(message())")
        }
    }

    private let configuration: AzureOpenAIConfiguration
    private let transportPool: OpenAIServiceTransportPool

    private lazy var azureService: OpenAIService = transportPool.azureService(
        configuration: configuration,
        debugEnabled: Self.enableDebugLogging
    )

    init(configuration: AzureOpenAIConfiguration, transportPool: OpenAIServiceTransportPool = .shared) {
        self.configuration = configuration
        self.transportPool = transportPool
    }

    // MARK: - Helpers

    private func deploymentInfo(for model: AIModel) throws -> (id: String, descriptor: AzureOpenAIConfiguration.ModelDescriptor?) {
        switch model {
        case let .azureCustom(name):
            let normalizedName = Self.normalizedModelName(from: name)
            var descriptor = configuration.descriptor(for: name)
                ?? configuration.descriptor(for: normalizedName)
                ?? Self.defaultDescriptor(for: name)
            var deploymentID = descriptor?.id ?? name

            let descriptorMatchesRequested = descriptor.map {
                Self.normalizedModelName(from: $0.id).lowercased() == normalizedName.lowercased()
            } ?? false

            if descriptor == nil || descriptorMatchesRequested {
                if let aiModel = AIModel.fromModelName(normalizedName) {
                    let (baseModel, _) = resolveBaseModelAndEffort(for: aiModel)
                    if baseModel != aiModel {
                        let baseName = Self.normalizedModelName(from: baseModel.modelName)
                        let baseDescriptor = configuration.descriptor(for: baseName)
                            ?? Self.defaultDescriptor(for: baseName)

                        if let baseDescriptor {
                            let variantDisplay = AIModel.azureCustom(name: normalizedName).displayName
                            let resolvedDisplay = variantDisplay.isEmpty ? baseDescriptor.displayName : variantDisplay
                            descriptor = AzureOpenAIConfiguration.ModelDescriptor(
                                id: baseDescriptor.id,
                                displayName: resolvedDisplay,
                                endpoint: baseDescriptor.endpoint,
                                supportsStreaming: baseDescriptor.supportsStreaming,
                                baseModelID: normalizedName,
                                supportsChatCompletions: baseDescriptor.supportsChatCompletions,
                                supportsResponses: baseDescriptor.supportsResponses
                            )
                            deploymentID = baseDescriptor.id
                        } else {
                            deploymentID = baseName
                        }
                    }
                }
            }

            return (deploymentID, descriptor)
        default:
            if let defaultID = configuration.defaultModelID {
                return (defaultID, configuration.descriptor(for: defaultID))
            }
            throw AIProviderError.invalidConfiguration(detail: "Azure model identifier could not be resolved.")
        }
    }

    private func shouldUseResponsesAPI(descriptor: AzureOpenAIConfiguration.ModelDescriptor?, baseModel: AIModel?) -> Bool {
        if let endpoint = descriptor?.endpoint {
            return endpoint == .responses
        }
        if descriptor?.supportsResponses == true {
            return true
        }
        if let baseModel {
            return baseModel.usesResponsesAPI
        }
        return false
    }

    static func normalizedModelName(from deploymentID: String) -> String {
        let trimmed = deploymentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("azure/") {
            let dropCount = "azure/".count
            return String(trimmed.dropFirst(dropCount))
        }
        return trimmed
    }

    private func supportsStreaming(descriptor: AzureOpenAIConfiguration.ModelDescriptor?, baseModel: AIModel?) -> Bool {
        // Force background job path for "pro" deployments (e.g., o3-pro, gpt-5-pro)
        if let id = descriptor?.id, id.lowercased().contains("pro") {
            return false
        }

        if let explicit = descriptor?.supportsStreaming {
            return explicit
        }

        if let baseModel {
            return baseModel.canStream
        }

        return true
    }

    private func resolveBaseModelAndEffort(for deploymentID: String, descriptor: AzureOpenAIConfiguration.ModelDescriptor?) -> (AIModel?, String?) {
        let candidates = [
            descriptor?.baseModelID,
            descriptor?.id,
            deploymentID
        ].compactMap(\.self)

        for identifier in candidates {
            let normalized = Self.normalizedModelName(from: identifier)
            if let model = AIModel.fromModelName(normalized) {
                return resolveBaseModelAndEffort(for: model)
            }
        }

        return (nil, nil)
    }

    private func resolveBaseModelAndEffort(for model: AIModel) -> (AIModel, String?) {
        switch model {
        case .gpt5Pro:
            (.gpt5Pro, "high")
        case .gpt5ProXHigh:
            (.gpt5Pro, "xhigh")
        case .gpt54Pro:
            (.gpt54Pro, "high")
        case .gpt54ProXHigh:
            (.gpt54Pro, "xhigh")
        case .o3High:
            (.o3, "high")
        case .o3Low:
            (.o3, "low")
        case .o3:
            (.o3, "medium")
        case .gpt5XHigh:
            (.gpt5, "xhigh")
        case .gpt5High:
            (.gpt5, "high")
        case .gpt5Low:
            (.gpt5, "low")
        case .gpt5:
            (.gpt5, "medium")
        case .gpt54XHigh:
            (.gpt54, "xhigh")
        case .gpt54High:
            (.gpt54, "high")
        case .gpt54Low:
            (.gpt54, "low")
        case .gpt54:
            (.gpt54, "medium")
        case .gpt5CodexXHigh:
            (.gpt5CodexMed, "xhigh")
        case .gpt5CodexHigh:
            (.gpt5CodexMed, "high")
        case .gpt5CodexMed:
            (.gpt5CodexMed, "medium")
        case .gpt5CodexLow:
            (.gpt5CodexMed, "low")
        default:
            (model, nil)
        }
    }

    private func defaultMaxTokens(for model: AIModel) -> Int {
        switch model {
        case .gpt41:
            16384
        case .o3, .o3Low, .o3High:
            100_000
        case .o1Preview:
            32768
        case .o1Mini:
            65536
        case .gpt5Pro, .gpt5ProXHigh, .gpt54Pro, .gpt54ProXHigh:
            100_000
        case .gpt5, .gpt5Low, .gpt5High, .gpt5XHigh,
             .gpt54, .gpt54Low, .gpt54High, .gpt54XHigh,
             .gpt54Mini, .gpt54MiniLow, .gpt54MiniHigh, .gpt54MiniXHigh, .gpt54Nano,
             .gpt5CodexLow, .gpt5CodexMed, .gpt5CodexHigh, .gpt5CodexXHigh:
            128_000
        default:
            2048
        }
    }

    private func shouldOmitMaxOutputTokens(for model: AIModel?) -> Bool {
        guard let model else { return false }
        return [.gpt5Pro, .gpt5ProXHigh, .gpt54Pro, .gpt54ProXHigh].contains(model)
    }

    private func resolvedMaxTokens(for model: AIModel?, override: Int?) -> Int? {
        if let override {
            return override
        }
        guard let model else {
            return nil
        }
        let defaultValue = defaultMaxTokens(for: model)
        return defaultValue == 2048 ? nil : defaultValue
    }

    private func buildChatParameters(
        for message: AIMessage,
        model: AIModel,
        deploymentID: String,
        baseModel: AIModel?,
        reasoningEffort: String?,
        maxTokens: Int?
    ) -> ChatCompletionParameters {
        let embedSystemPrompt = baseModel == .o1Mini || baseModel == .o1Preview
        var params = ChatCompletionParameters(
            messages: message.openAIChatMessages(embedSystemPrompt: embedSystemPrompt),
            model: .custom(deploymentID)
        )

        if let temperature = message.effectiveTemperature(for: baseModel ?? model) {
            params.temperature = temperature
        }

        if let effort = reasoningEffort {
            params.reasoningEffort = effort
        }

        if let baseModel {
            switch baseModel {
            case .o3, .o1Mini, .o1Preview:
                if let tokenLimit = maxTokens {
                    params.maCompletionTokens = tokenLimit
                }
            default:
                if let tokenLimit = maxTokens {
                    params.maxTokens = tokenLimit
                }
            }
        } else if let tokenLimit = maxTokens {
            if reasoningEffort != nil {
                params.maCompletionTokens = tokenLimit
            } else {
                params.maxTokens = tokenLimit
            }
        }

        return params
    }

    private func buildResponseParameters(
        for message: AIMessage,
        model: AIModel,
        deploymentID: String,
        baseModel: AIModel?,
        reasoningEffort: String?,
        maxTokens: Int?,
        stream: Bool
    ) -> ModelResponseParameter {
        Self.debug("Building response parameters for model: \(model), deploymentID: \(deploymentID)")
        Self.debug("Base model: \(baseModel?.rawValue ?? "nil")")
        Self.debug("Reasoning effort: \(reasoningEffort ?? "nil")")
        var parameters = ModelResponseParameter(
            input: message.openAIResponsesInput(),
            model: SwiftOpenAI.Model.custom(deploymentID)
        )

        if !message.systemPrompt.isEmpty {
            parameters.instructions = message.systemPrompt
        }

        if let temperature = message.effectiveTemperature(for: baseModel ?? model) {
            parameters.temperature = temperature
        }

        if let tokenLimit = maxTokens, !shouldOmitMaxOutputTokens(for: baseModel ?? model) {
            parameters.maxOutputTokens = tokenLimit
        }

        if let effort = reasoningEffort {
            parameters.reasoning = Reasoning(effort: effort, summary: "auto")
        }

        parameters.stream = stream
        return parameters
    }

    private func buildBackgroundResponseParameters(
        for message: AIMessage,
        model: AIModel,
        deploymentID: String,
        baseModel: AIModel?,
        reasoningEffort: String?,
        maxTokens: Int?
    ) -> ModelResponseParameter {
        var parameters = buildResponseParameters(
            for: message,
            model: model,
            deploymentID: deploymentID,
            baseModel: baseModel,
            reasoningEffort: reasoningEffort,
            maxTokens: maxTokens,
            stream: false
        )
        parameters.background = true
        return parameters
    }

    private func bridgeResponseStream(_ stream: AsyncThrowingStream<ResponseStreamEvent, Error>) -> AsyncThrowingStream<AIStreamResult, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var promptTokens: Int?
                    var completionTokens: Int?

                    for try await event in stream {
                        if Task.isCancelled { break }
                        switch event {
                        case let .outputTextDelta(delta):
                            if !delta.delta.isEmpty {
                                continuation.yield(AIStreamResult(type: "content", text: delta.delta, reasoning: nil, promptTokens: nil, completionTokens: nil))
                            }
                        case let .reasoningSummaryTextDelta(delta):
                            if !delta.delta.isEmpty {
                                continuation.yield(AIStreamResult(type: "content", text: nil, reasoning: delta.delta, promptTokens: nil, completionTokens: nil))
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

                    continuation.yield(AIStreamResult(type: "message_stop", text: nil, reasoning: nil, promptTokens: promptTokens, completionTokens: completionTokens))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func performResponseCompletion(parameters: ModelResponseParameter) async throws -> ResponseModel {
        let response = try await azureService.responseCreate(parameters)
        guard response.status == .completed else {
            let status = response.status?.rawValue ?? "unknown"
            let detail = response.error?.message ?? response.incompleteDetails?.reason ?? "Response status was '\(status)'"
            throw AIProviderError.invalidResponse(detail: detail)
        }
        return response
    }

    // MARK: - AIProvider

    func streamMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens: Int?) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        let (deploymentID, descriptor) = try deploymentInfo(for: model)
        let (baseModel, reasoningEffort) = resolveBaseModelAndEffort(for: deploymentID, descriptor: descriptor)
        let finalMaxTokens = resolvedMaxTokens(for: baseModel, override: maxTokens)
        let useResponses = shouldUseResponsesAPI(descriptor: descriptor, baseModel: baseModel)
        let streamingSupported = supportsStreaming(descriptor: descriptor, baseModel: baseModel)

        // Route via Responses API when required
        if useResponses {
            if streamingSupported {
                // Real streaming via SSE (responseCreateStream)
                let parameters = buildResponseParameters(
                    for: aiMessage,
                    model: model,
                    deploymentID: deploymentID,
                    baseModel: baseModel,
                    reasoningEffort: reasoningEffort,
                    maxTokens: finalMaxTokens,
                    stream: true
                )
                let stream = try await azureService.responseCreateStream(parameters)
                return bridgeResponseStream(stream)
            } else {
                // Use background job + streaming attach for non-streaming Response API models.
                // This creates a queued job and then attaches via SSE for incremental output.
                let response = try await createBackgroundResponse(
                    aiMessage,
                    model: model,
                    maxTokens: finalMaxTokens
                )
                return try await streamResponse(id: response.id)
            }
        }

        // Handle non-Response API models that don't support streaming
        if !streamingSupported {
            let result = try await completeMessage(aiMessage, model: model, maxTokens: finalMaxTokens)
            return AsyncThrowingStream { continuation in
                continuation.yield(AIStreamResult(type: "content", text: result.text, reasoning: nil, promptTokens: nil, completionTokens: nil))
                continuation.yield(AIStreamResult(type: "message_stop", text: nil, reasoning: nil, promptTokens: result.promptTokens, completionTokens: result.completionTokens))
                continuation.finish()
            }
        }

        let parameters = buildChatParameters(
            for: aiMessage,
            model: model,
            deploymentID: deploymentID,
            baseModel: baseModel,
            reasoningEffort: reasoningEffort,
            maxTokens: finalMaxTokens
        )
        let stream = try await azureService.startStreamedChat(parameters: parameters)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var promptTokens: Int?
                    var completionTokens: Int?

                    for try await chunk in stream {
                        if Task.isCancelled { break }

                        if let usage = chunk.usage {
                            promptTokens = usage.promptTokens
                            completionTokens = usage.completionTokens
                        }

                        let content = chunk.choices?.first?.delta?.content ?? ""
                        let reasoning = chunk.choices?.first?.delta?.reasoningContent ?? ""

                        if !content.isEmpty || !reasoning.isEmpty {
                            continuation.yield(
                                AIStreamResult(
                                    type: "content",
                                    text: content.isEmpty ? nil : content,
                                    reasoning: reasoning.isEmpty ? nil : reasoning,
                                    promptTokens: promptTokens,
                                    completionTokens: completionTokens
                                )
                            )
                        }
                    }

                    continuation.yield(AIStreamResult(type: "message_stop", text: nil, reasoning: nil, promptTokens: promptTokens, completionTokens: completionTokens))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func completeMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens: Int?) async throws -> AICompletionResult {
        let (deploymentID, descriptor) = try deploymentInfo(for: model)
        let (baseModel, reasoningEffort) = resolveBaseModelAndEffort(for: deploymentID, descriptor: descriptor)
        let finalMaxTokens = resolvedMaxTokens(for: baseModel, override: maxTokens)

        if shouldUseResponsesAPI(descriptor: descriptor, baseModel: baseModel) {
            let parameters = buildResponseParameters(
                for: aiMessage,
                model: model,
                deploymentID: deploymentID,
                baseModel: baseModel,
                reasoningEffort: reasoningEffort,
                maxTokens: finalMaxTokens,
                stream: false
            )

            do {
                let response = try await performResponseCompletion(parameters: parameters)
                guard let text = response.outputText, !text.isEmpty else {
                    throw AIProviderError.invalidResponse(detail: "Responses API returned no content.")
                }

                let promptTokens = response.usage?.inputTokens
                let completionTokens = response.usage?.outputTokens

                return AICompletionResult(
                    text: text,
                    promptTokens: promptTokens,
                    completionTokens: completionTokens
                )
            } catch let error as APIError {
                throw AIProviderError.apiError(source: error)
            } catch let error as AIProviderError {
                throw error
            } catch {
                throw AIProviderError.unknown(source: error)
            }
        }

        let parameters = buildChatParameters(
            for: aiMessage,
            model: model,
            deploymentID: deploymentID,
            baseModel: baseModel,
            reasoningEffort: reasoningEffort,
            maxTokens: finalMaxTokens
        )
        let response = try await azureService.startChat(parameters: parameters)
        let text = response.choices?.first?.message?.content ?? ""

        return AICompletionResult(
            text: text,
            promptTokens: response.usage?.promptTokens,
            completionTokens: response.usage?.completionTokens
        )
    }

    func dispose() async {
        // nothing to clean up
    }

    func testAPIKey() async throws -> Bool {
        let targetModelID = configuration.defaultModelID ?? configuration.models.first?.id
        guard let modelID = targetModelID else {
            throw AIProviderError.invalidConfiguration(detail: "No Azure models discovered for validation.")
        }

        let testMessage = AIMessage(systemPrompt: "You are a helpful assistant.", userMessage: "Say hello")
        // Pass nil for maxTokens - Azure Responses API may reject max_output_tokens
        let result = try await completeMessage(testMessage, model: .azureCustom(name: modelID), maxTokens: nil)
        return result.text.lowercased().contains("hello")
    }
}

// MARK: - Deployment discovery helpers ------------------------------------------------------------

extension AzureOpenAIProvider {
    static let defaultModelDescriptors: [AzureOpenAIConfiguration.ModelDescriptor] = {
        let openAIModels = AIModel.modelsForProvider(.openAI)
            .sorted { lhs, rhs in lhs.displayName.lowercased() < rhs.displayName.lowercased() }

        let descriptors = openAIModels.map { model in
            let rawID = model.rawValue
            let display = AIModel.azureCustom(name: rawID).displayName
            let usesResponses = model.usesResponsesAPI
            let streams = model.canStream

            return AzureOpenAIConfiguration.ModelDescriptor(
                id: rawID,
                displayName: display,
                endpoint: usesResponses ? .responses : .chatCompletions,
                supportsStreaming: streams,
                baseModelID: rawID,
                supportsChatCompletions: usesResponses ? false : true,
                supportsResponses: usesResponses ? true : false
            )
        }

        return descriptors
            .map { normalizedDescriptor($0) }
    }()

    static func mergedWithDefaultDescriptors(_ descriptors: [AzureOpenAIConfiguration.ModelDescriptor]) -> [AzureOpenAIConfiguration.ModelDescriptor] {
        var merged: [String: AzureOpenAIConfiguration.ModelDescriptor] = [:]

        for descriptor in descriptors {
            let key = normalizedModelName(from: descriptor.id).lowercased()
            merged[key] = descriptor
        }

        for descriptor in defaultModelDescriptors {
            let key = normalizedModelName(from: descriptor.id).lowercased()
            if merged[key] == nil {
                merged[key] = descriptor
            }
        }

        return merged.values
            .map { normalizedDescriptor($0) }
            .sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
    }

    private static func normalizedDescriptor(_ descriptor: AzureOpenAIConfiguration.ModelDescriptor) -> AzureOpenAIConfiguration.ModelDescriptor {
        let normalizedID = Self.normalizedModelName(from: descriptor.id)
        let openAIModel = AIModel.fromModelName(normalizedID)
        let inferredEndpoint = descriptor.endpoint ?? AzureOpenAIConfiguration.inferredEndpoint(for: descriptor.id, baseModelID: descriptor.baseModelID)
        let usesResponses = descriptor.supportsResponses ?? openAIModel?.usesResponsesAPI ?? (inferredEndpoint == .responses)
        let endpoint: AzureOpenAIConfiguration.ModelDescriptor.EndpointKind = usesResponses ? .responses : .chatCompletions
        let supportsStreaming = descriptor.supportsStreaming ?? openAIModel?.canStream
        let resolvedBaseModelID: String = if let explicitBase = descriptor.baseModelID, !explicitBase.isEmpty {
            explicitBase
        } else if let openAIModel {
            openAIModel.rawValue
        } else {
            normalizedID
        }
        let azureDisplay = AIModel.azureCustom(name: normalizedID).displayName
        let resolvedDisplay = azureDisplay.isEmpty
            ? "azure/\(descriptor.displayName.isEmpty ? descriptor.id : descriptor.displayName)"
            : azureDisplay

        return AzureOpenAIConfiguration.ModelDescriptor(
            id: descriptor.id,
            displayName: resolvedDisplay,
            endpoint: endpoint,
            supportsStreaming: supportsStreaming,
            baseModelID: resolvedBaseModelID,
            supportsChatCompletions: descriptor.supportsChatCompletions ?? !usesResponses,
            supportsResponses: usesResponses
        )
    }

    private static func defaultDescriptor(for identifier: String) -> AzureOpenAIConfiguration.ModelDescriptor? {
        let normalized = normalizedModelName(from: identifier).lowercased()
        return defaultModelDescriptors.first {
            normalizedModelName(from: $0.id).lowercased() == normalized
        }
    }

    struct AzureDeploymentListResponse: Decodable {
        struct Deployment: Decodable {
            let id: String
            let model: String?
            let status: String?
        }

        let data: [Deployment]
    }

    static func discoverDeployments(
        baseURL: URL,
        apiKey: String,
        apiVersions: [String]
    ) async throws -> [AzureOpenAIConfiguration.ModelDescriptor] {
        let orderedVersions = apiVersions.reduce(into: [String]()) { acc, version in
            let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !acc.contains(trimmed) else { return }
            acc.append(trimmed)
        }

        Self.debug("Discovering Azure deployments using versions: \(orderedVersions)")
        var lastError: NSError?

        for version in orderedVersions {
            var components = URLComponents()
            components.scheme = baseURL.scheme ?? "https"
            components.host = baseURL.host
            components.port = baseURL.port
            components.path = "/openai/deployments"
            components.queryItems = [URLQueryItem(name: "api-version", value: version)]

            guard let url = components.url else {
                lastError = NSError(domain: "AzureDiscovery", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to construct Azure deployments endpoint."
                ])
                continue
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.addValue(apiKey, forHTTPHeaderField: "api-key")
            request.addValue("application/json", forHTTPHeaderField: "Accept")

            do {
                let response = try await DefaultHTTPClient.discoveryClient.data(for: request)
                let http = response.http

                if (200 ... 299).contains(http.statusCode) {
                    let decoded = try await HTTPDecoding.decode(AzureDeploymentListResponse.self, from: response.data)
                    Self.debug("Decoded \(decoded.data.count) total deployments from Azure")

                    let deployments = decoded.data.filter { deployment in
                        guard let status = deployment.status?.lowercased() else { return true }
                        return status == "succeeded" || status == "creating" || status == "running"
                    }
                    Self.debug("Filtered to \(deployments.count) deployments with valid status")

                    Self.debug("Deployments: \(deployments)")

                    let descriptors = deployments.map { deployment -> AzureOpenAIConfiguration.ModelDescriptor in
                        let normalizedID = Self.normalizedModelName(from: deployment.id)
                        let openAIModel = AIModel.fromModelName(normalizedID)
                        let inferredEndpoint = AzureOpenAIConfiguration.inferredEndpoint(for: deployment.id, baseModelID: deployment.model)
                        let usesResponses = openAIModel?.usesResponsesAPI ?? (inferredEndpoint == .responses)
                        let endpoint: AzureOpenAIConfiguration.ModelDescriptor.EndpointKind = usesResponses ? .responses : .chatCompletions
                        let supportsStreaming = openAIModel?.canStream
                        let resolvedBaseModelID = openAIModel?.rawValue ?? deployment.model ?? normalizedID
                        let displayName = AIModel.azureCustom(name: normalizedID).displayName

                        return AzureOpenAIConfiguration.ModelDescriptor(
                            id: deployment.id,
                            displayName: displayName,
                            endpoint: endpoint,
                            supportsStreaming: supportsStreaming,
                            baseModelID: resolvedBaseModelID,
                            supportsChatCompletions: usesResponses ? false : true,
                            supportsResponses: usesResponses ? true : false
                        )
                    }.sorted { $0.id < $1.id }

                    if !descriptors.isEmpty || version == orderedVersions.last {
                        Self.debug("Azure deployment discovery succeeded for \(version) with \(descriptors.count) deployments")
                        Self.debug("All descriptors: \(descriptors)")
                        return descriptors
                    }

                    Self.debug("Azure deployment discovery returned no deployments for \(version); continuing with fallback version")
                    lastError = NSError(domain: "AzureDiscovery", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "No Azure deployments were found."
                    ])
                } else {
                    let message = String(data: response.data, encoding: .utf8) ?? "Azure returned status \(http.statusCode)"
                    Self.debug("Azure deployment discovery failed for \(version) with status \(http.statusCode): \(message)")
                    lastError = NSError(domain: "AzureDiscovery", code: http.statusCode, userInfo: [
                        NSLocalizedDescriptionKey: "Azure deployments call failed: \(message)"
                    ])
                }
            } catch {
                Self.debug("Azure deployment discovery threw error for \(version): \(error)")
                lastError = error as NSError
            }
        }

        throw lastError ?? NSError(domain: "AzureDiscovery", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "Unable to fetch Azure deployments."
        ])
    }

    static func matchedModel(for descriptor: AzureOpenAIConfiguration.ModelDescriptor) -> AIModel? {
        if let baseModelID = descriptor.baseModelID,
           let model = AIModel.fromModelName(baseModelID)
        {
            return model
        }
        return AIModel.fromModelName(Self.normalizedModelName(from: descriptor.id))
    }

    static func prioritizedDeployments(from descriptors: [AzureOpenAIConfiguration.ModelDescriptor]) -> [AzureOpenAIConfiguration.ModelDescriptor] {
        let openAIModels = Set(AIModel.modelsForProvider(.openAI))
        return descriptors.filter { descriptor in
            guard let model = matchedModel(for: descriptor) else { return false }
            return openAIModels.contains(model)
        }
    }

    static func defaultDeploymentID(for descriptors: [AzureOpenAIConfiguration.ModelDescriptor]) -> String? {
        descriptors.sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }.first?.id
    }

    static func preferredDeploymentID(from descriptors: [AzureOpenAIConfiguration.ModelDescriptor]) -> String? {
        let priorityOrder = AIModel.wholePriorityModels
        for priority in priorityOrder {
            if let descriptor = descriptors.first(where: { matchedModel(for: $0) == priority }) {
                return descriptor.id
            }
        }
        for descriptor in descriptors {
            if let model = matchedModel(for: descriptor), model.providerType == .openAI {
                return descriptor.id
            }
        }
        return descriptors.first?.id
    }
}
