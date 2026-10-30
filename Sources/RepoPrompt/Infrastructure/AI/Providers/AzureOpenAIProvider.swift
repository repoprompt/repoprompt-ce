import Foundation
import RepoPromptAgentProviderContracts
import RepoPromptAIContracts
import RepoPromptDomainRuntime
import RepoPromptFoundation
import RepoPromptHTTPProviders
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
    public let httpCredentialConsentEndpoint: String?

    public init(
        baseURL: URL,
        apiKey: String,
        apiVersion: String,
        extraHeaders: [String: String]? = nil,
        models: [ModelDescriptor] = [],
        defaultModelID: String? = nil,
        httpCredentialConsentEndpoint: String? = nil
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.apiVersion = apiVersion
        self.extraHeaders = extraHeaders
        self.models = models
        self.defaultModelID = defaultModelID
        self.httpCredentialConsentEndpoint = httpCredentialConsentEndpoint
    }

    private enum CodingKeys: String, CodingKey {
        case baseURL
        case apiKey
        case apiVersion
        case extraHeaders
        case models
        case defaultModelID
        case httpCredentialConsentEndpoint
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
        httpCredentialConsentEndpoint = try container.decodeIfPresent(String.self, forKey: .httpCredentialConsentEndpoint)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseURL.absoluteString, forKey: .baseURL)
        try container.encode(apiKey, forKey: .apiKey)
        try container.encode(apiVersion, forKey: .apiVersion)
        try container.encodeIfPresent(extraHeaders, forKey: .extraHeaders)
        try container.encode(models, forKey: .models)
        try container.encodeIfPresent(defaultModelID, forKey: .defaultModelID)
        try container.encodeIfPresent(httpCredentialConsentEndpoint, forKey: .httpCredentialConsentEndpoint)
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
}

extension AzureOpenAIProvider: ResponsesJobProvider {
    package func createBackgroundResponse(
        _ message: RepoPromptDomainRuntime.AIMessage,
        model: AIModel,
        maxTokens: Int?
    ) async throws -> ResponseModel {
        let (deploymentID, descriptor) = try deploymentInfo(for: model)
        let (baseModel, reasoningEffort) = resolveBaseModelAndEffort(for: deploymentID, descriptor: descriptor)
        let finalMaxTokens = resolvedMaxTokens(for: baseModel, override: maxTokens)
        let parameters = try buildBackgroundResponseParameters(
            for: message,
            model: model,
            deploymentID: deploymentID,
            baseModel: baseModel,
            reasoningEffort: reasoningEffort,
            maxTokens: finalMaxTokens
        )

        let response = try await checkedAzureService().responseCreate(parameters)
        if response.status == .failed {
            let detail = response.error?.message ?? response.incompleteDetails?.reason ?? "Responses API returned a failed status."
            throw AIProviderError.invalidResponse(detail: detail)
        }
        return response
    }

    package func fetchResponse(id: String) async throws -> ResponseModel {
        try await checkedAzureService().responseModel(id: id, parameters: nil)
    }

    package func streamResponse(id: String) async throws -> AsyncThrowingStream<RepoPromptDomainRuntime.AIStreamResult, Error> {
        let service = try checkedAzureService()

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
                        RepoPromptDomainRuntime.AIStreamResult(
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
                                    RepoPromptDomainRuntime.AIStreamResult(
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
                        case .completed, .incomplete:
                            // Extract any available output before reporting the terminal outcome
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
                                    RepoPromptDomainRuntime.AIStreamResult(
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
                                    RepoPromptDomainRuntime.AIStreamResult(
                                        type: "content",
                                        text: outputText,
                                        reasoning: nil,
                                        promptTokens: nil,
                                        completionTokens: nil,
                                        cost: nil
                                    )
                                )
                            }

                            let didComplete = response.status == .completed
                            continuation.yield(
                                RepoPromptDomainRuntime.AIStreamResult(
                                    type: didComplete ? "message_stop" : RepoPromptDomainRuntime.AIStreamResult.incompleteType,
                                    text: nil,
                                    reasoning: nil,
                                    promptTokens: response.usage?.inputTokens,
                                    completionTokens: response.usage?.outputTokens,
                                    cost: nil,
                                    stopReason: didComplete ? nil : response.incompleteDetails?.reason ?? "unknown"
                                )
                            )
                            continuation.finish()
                            return

                        case .failed:
                            let message = response.error?.message ?? "Background job failed."
                            throw AIProviderError.invalidResponse(detail: message)

                        case .cancelled:
                            throw AIProviderError.invalidResponse(detail: "Background job was cancelled.")

                        case .queued, .inProgress, .none:
                            // Continue polling with exponential backoff
                            if let pollSleep {
                                try await pollSleep(pollInterval())
                            } else {
                                try await Task.sleep(for: pollInterval())
                            }
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

    package func cancelResponse(id: String) async throws -> ResponseModel {
        try await checkedAzureService().responseCancel(id: id)
    }
}

package final class AzureOpenAIProvider: AIProvider {
    package static var enableDebugLogging: Bool = false
    package static let discoveryAPIVersions: [String] = ["2023-03-15-preview"]

    package static func debug(_ message: @autoclosure () -> String) {
        if enableDebugLogging {
            print("[Azure] \(message())")
        }
    }

    private let configuration: AzureOpenAIConfiguration
    private let host: any AzureOpenAIHTTPHost
    private let sessionConfigurationFactory: (() -> URLSessionConfiguration)?
    private let pollSleep: (@Sendable (Duration) async throws -> Void)?
    private lazy var urlSessionConfiguration: URLSessionConfiguration = {
        if let sessionConfigurationFactory { return sessionConfigurationFactory() }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 21600 // 6 hours
        config.timeoutIntervalForResource = 21600 // 6 hours
        return config
    }()

    private lazy var azureService: OpenAIService = OpenAIServiceFactory.service(
        azureConfiguration: configuration.toSwiftOpenAIConfiguration,
        urlSessionConfiguration: urlSessionConfiguration,
        debugEnabled: Self.enableDebugLogging
    )

    package init(configuration: AzureOpenAIConfiguration, host: any AzureOpenAIHTTPHost, sessionConfigurationFactory: (() -> URLSessionConfiguration)? = nil, pollSleep: (@Sendable (Duration) async throws -> Void)? = nil) {
        self.configuration = configuration
        self.host = host
        self.sessionConfigurationFactory = sessionConfigurationFactory
        self.pollSleep = pollSleep
    }

    private func checkedAzureService() throws -> OpenAIService {
        try host.validateEndpoint(configuration.baseURL, apiKey: configuration.apiKey, customHeaders: configuration.extraHeaders ?? [:], consentEndpoint: configuration.httpCredentialConsentEndpoint)
        return azureService
    }

    // MARK: - Helpers

    private func deploymentInfo(for model: AIModel) throws -> (id: String, descriptor: AzureOpenAIConfiguration.ModelDescriptor?) {
        switch model {
        case let .azureCustom(name):
            let normalizedName = Self.normalizedModelName(from: name)
            var descriptor = configuration.descriptor(for: name)
                ?? configuration.descriptor(for: normalizedName)
                ?? host.defaultDescriptor(for: name)
            var deploymentID = descriptor?.id ?? name

            let descriptorMatchesRequested = descriptor.map {
                Self.normalizedModelName(from: $0.id).lowercased() == normalizedName.lowercased()
            } ?? false

            if descriptor == nil || descriptorMatchesRequested {
                if let aiModel = host.modelFromName(normalizedName) {
                    let (baseModel, _) = resolveBaseModelAndEffort(for: aiModel)
                    if baseModel != aiModel {
                        let baseName = Self.normalizedModelName(from: host.modelName(for: baseModel))
                        let baseDescriptor = configuration.descriptor(for: baseName)
                            ?? host.defaultDescriptor(for: baseName)

                        if let baseDescriptor {
                            let variantDisplay = host.displayName(for: .azureCustom(name: normalizedName))
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
            return host.usesResponsesAPI(for: baseModel)
        }
        return false
    }

    package static func normalizedModelName(from deploymentID: String) -> String {
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
            return host.canStream(for: baseModel)
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
            if let model = host.modelFromName(normalized) {
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
        case .gpt61Terra, .gpt61TerraNone, .gpt61TerraLow, .gpt61TerraHigh, .gpt61TerraXHigh, .gpt61TerraMax:
            (.gpt61Terra, host.defaultReasoningEffort(for: model))
        case .gpt61Sol, .gpt61SolLow, .gpt61SolHigh, .gpt61SolXHigh, .gpt61SolMax:
            (.gpt61Sol, host.defaultReasoningEffort(for: model))
        case .gpt6Astra, .gpt6AstraLow, .gpt6AstraHigh, .gpt6AstraXHigh, .gpt6AstraMax:
            (.gpt6Astra, host.defaultReasoningEffort(for: model))
        case .gpt6Luna, .gpt6LunaLow, .gpt6LunaHigh, .gpt6LunaXHigh:
            (.gpt6Luna, host.defaultReasoningEffort(for: model))
        case .gpt6Sol:
            (.gpt6Sol, "medium")
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
             .gpt61Sol, .gpt61SolLow, .gpt61SolHigh, .gpt61SolXHigh, .gpt61SolMax,
             .gpt61Terra, .gpt61TerraNone, .gpt61TerraLow, .gpt61TerraHigh, .gpt61TerraXHigh, .gpt61TerraMax,
             .gpt6Astra, .gpt6AstraLow, .gpt6AstraHigh, .gpt6AstraXHigh, .gpt6AstraMax,
             .gpt6Luna, .gpt6LunaLow, .gpt6LunaHigh, .gpt6LunaXHigh, .gpt6Sol,
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
        for message: RepoPromptDomainRuntime.AIMessage,
        model: AIModel,
        deploymentID: String,
        baseModel: AIModel?,
        reasoningEffort: String?,
        maxTokens: Int?
    ) throws -> ChatCompletionParameters {
        let embedSystemPrompt = baseModel == .o1Mini || baseModel == .o1Preview
        var params = try ChatCompletionParameters(
            messages: message.openAIChatMessages(embedSystemPrompt: embedSystemPrompt),
            model: .custom(deploymentID)
        )

        if let temperature = host.effectiveTemperature(for: message, model: baseModel ?? model) {
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
        for message: RepoPromptDomainRuntime.AIMessage,
        model: AIModel,
        deploymentID: String,
        baseModel: AIModel?,
        reasoningEffort: String?,
        maxTokens: Int?,
        stream: Bool
    ) throws -> ModelResponseParameter {
        Self.debug("Building response parameters for model: \(model), deploymentID: \(deploymentID)")
        Self.debug("Base model: \(baseModel.map { host.rawValue(for: $0) } ?? "nil")")
        Self.debug("Reasoning effort: \(reasoningEffort ?? "nil")")
        var parameters = try ModelResponseParameter(
            input: message.openAIResponsesInput(),
            model: SwiftOpenAI.Model.custom(deploymentID)
        )

        if !message.systemPrompt.isEmpty {
            parameters.instructions = message.systemPrompt
        }

        if let temperature = host.effectiveTemperature(for: message, model: baseModel ?? model) {
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
        for message: RepoPromptDomainRuntime.AIMessage,
        model: AIModel,
        deploymentID: String,
        baseModel: AIModel?,
        reasoningEffort: String?,
        maxTokens: Int?
    ) throws -> ModelResponseParameter {
        var parameters = try buildResponseParameters(
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

    private func bridgeResponseStream(_ stream: AsyncThrowingStream<ResponseStreamEvent, Error>) -> AsyncThrowingStream<RepoPromptDomainRuntime.AIStreamResult, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var promptTokens: Int?
                    var completionTokens: Int?
                    var observedCompletionOutcome: AIProviderCompletionOutcome?

                    for try await event in stream {
                        if Task.isCancelled { break }
                        switch event {
                        case let .outputTextDelta(delta):
                            if !delta.delta.isEmpty {
                                continuation.yield(RepoPromptDomainRuntime.AIStreamResult(type: "content", text: delta.delta, reasoning: nil, promptTokens: nil, completionTokens: nil))
                            }
                        case let .reasoningSummaryTextDelta(delta):
                            if !delta.delta.isEmpty {
                                continuation.yield(RepoPromptDomainRuntime.AIStreamResult(type: "content", text: nil, reasoning: delta.delta, promptTokens: nil, completionTokens: nil))
                            }
                        case let .responseCompleted(completed):
                            observedCompletionOutcome = .completed
                            if let usage = completed.response.usage {
                                promptTokens = usage.inputTokens
                                completionTokens = usage.outputTokens
                            }
                        case let .responseFailed(failed):
                            let message = failed.response.error?.message ?? "Responses API returned a failure."
                            throw AIProviderError.invalidResponse(detail: message)
                        case let .responseIncomplete(incomplete):
                            let reason = incomplete.response.incompleteDetails?.reason ?? "unknown"
                            observedCompletionOutcome = .incomplete(reason: reason)
                        case let .error(errorEvent):
                            throw APIError.requestFailed(description: errorEvent.prettyDescription)
                        default:
                            continue
                        }
                    }

                    switch observedCompletionOutcome {
                    case .completed:
                        continuation.yield(RepoPromptDomainRuntime.AIStreamResult(type: "message_stop", text: nil, reasoning: nil, promptTokens: promptTokens, completionTokens: completionTokens))
                    case let .incomplete(reason):
                        continuation.yield(RepoPromptDomainRuntime.AIStreamResult(type: RepoPromptDomainRuntime.AIStreamResult.incompleteType, text: nil, promptTokens: promptTokens, completionTokens: completionTokens, stopReason: reason))
                    case nil:
                        break
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func performResponseCompletion(parameters: ModelResponseParameter) async throws -> ResponseModel {
        let response = try await checkedAzureService().responseCreate(parameters)
        guard response.status == .completed || response.status == .incomplete else {
            let status = response.status?.rawValue ?? "unknown"
            let detail = response.error?.message ?? "Response status was '\(status)'"
            throw AIProviderError.invalidResponse(detail: detail)
        }
        return response
    }

    // MARK: - AIProvider

    package func streamMessage(_ aiMessage: RepoPromptDomainRuntime.AIMessage, model: AIModel, maxTokens: Int?) async throws -> AsyncThrowingStream<RepoPromptDomainRuntime.AIStreamResult, Error> {
        let (deploymentID, descriptor) = try deploymentInfo(for: model)
        let (baseModel, reasoningEffort) = resolveBaseModelAndEffort(for: deploymentID, descriptor: descriptor)
        let finalMaxTokens = resolvedMaxTokens(for: baseModel, override: maxTokens)
        let useResponses = shouldUseResponsesAPI(descriptor: descriptor, baseModel: baseModel)
        let streamingSupported = supportsStreaming(descriptor: descriptor, baseModel: baseModel)

        // Route via Responses API when required
        if useResponses {
            if streamingSupported {
                // Real streaming via SSE (responseCreateStream)
                let parameters = try buildResponseParameters(
                    for: aiMessage,
                    model: model,
                    deploymentID: deploymentID,
                    baseModel: baseModel,
                    reasoningEffort: reasoningEffort,
                    maxTokens: finalMaxTokens,
                    stream: true
                )
                let stream = try await checkedAzureService().responseCreateStream(parameters)
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
                continuation.yield(RepoPromptDomainRuntime.AIStreamResult(type: "content", text: result.text, reasoning: nil, promptTokens: nil, completionTokens: nil))
                switch result.completionOutcome {
                case .completed:
                    continuation.yield(RepoPromptDomainRuntime.AIStreamResult(type: "message_stop", text: nil, reasoning: nil, promptTokens: result.promptTokens, completionTokens: result.completionTokens))
                case let .incomplete(reason):
                    continuation.yield(RepoPromptDomainRuntime.AIStreamResult(type: RepoPromptDomainRuntime.AIStreamResult.incompleteType, text: nil, promptTokens: result.promptTokens, completionTokens: result.completionTokens, stopReason: reason))
                }
                continuation.finish()
            }
        }

        let parameters = try buildChatParameters(
            for: aiMessage,
            model: model,
            deploymentID: deploymentID,
            baseModel: baseModel,
            reasoningEffort: reasoningEffort,
            maxTokens: finalMaxTokens
        )
        let stream = try await checkedAzureService().startStreamedChat(parameters: parameters)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var promptTokens: Int?
                    var completionTokens: Int?
                    var observedCompletionOutcome: AIProviderCompletionOutcome?

                    for try await chunk in stream {
                        if Task.isCancelled { break }

                        if let usage = chunk.usage {
                            promptTokens = usage.promptTokens
                            completionTokens = usage.completionTokens
                        }

                        let choice = chunk.choices?.first
                        let content = choice?.delta?.content ?? ""
                        let reasoning = choice?.delta?.reasoningContent ?? ""
                        let finishReason = choice?.finishReason

                        if !content.isEmpty || !reasoning.isEmpty {
                            continuation.yield(
                                RepoPromptDomainRuntime.AIStreamResult(
                                    type: "content",
                                    text: content.isEmpty ? nil : content,
                                    reasoning: reasoning.isEmpty ? nil : reasoning,
                                    promptTokens: promptTokens,
                                    completionTokens: completionTokens
                                )
                            )
                        }
                        if let completionOutcome = openAIChatCompletionOutcome(finishReason) {
                            observedCompletionOutcome = completionOutcome
                        }
                    }

                    switch observedCompletionOutcome {
                    case .completed:
                        continuation.yield(RepoPromptDomainRuntime.AIStreamResult(type: "message_stop", text: nil, reasoning: nil, promptTokens: promptTokens, completionTokens: completionTokens))
                    case let .incomplete(reason):
                        continuation.yield(RepoPromptDomainRuntime.AIStreamResult(type: RepoPromptDomainRuntime.AIStreamResult.incompleteType, text: nil, promptTokens: promptTokens, completionTokens: completionTokens, stopReason: reason))
                    case nil:
                        break
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    package func completeMessage(_ aiMessage: RepoPromptDomainRuntime.AIMessage, model: AIModel, maxTokens: Int?) async throws -> RepoPromptDomainRuntime.AICompletionResult {
        let (deploymentID, descriptor) = try deploymentInfo(for: model)
        let (baseModel, reasoningEffort) = resolveBaseModelAndEffort(for: deploymentID, descriptor: descriptor)
        let finalMaxTokens = resolvedMaxTokens(for: baseModel, override: maxTokens)

        if shouldUseResponsesAPI(descriptor: descriptor, baseModel: baseModel) {
            let parameters = try buildResponseParameters(
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

                let completionOutcome: AIProviderCompletionOutcome = if response.status == .completed {
                    .completed
                } else {
                    .incomplete(reason: response.incompleteDetails?.reason ?? "unknown")
                }

                return RepoPromptDomainRuntime.AICompletionResult(
                    text: text,
                    promptTokens: promptTokens,
                    completionTokens: completionTokens,
                    completionOutcome: completionOutcome
                )
            } catch let error as APIError {
                throw AIProviderError.apiError(source: error)
            } catch let error as AIProviderError {
                throw error
            } catch {
                throw AIProviderError.unknown(source: error)
            }
        }

        let parameters = try buildChatParameters(
            for: aiMessage,
            model: model,
            deploymentID: deploymentID,
            baseModel: baseModel,
            reasoningEffort: reasoningEffort,
            maxTokens: finalMaxTokens
        )
        let response = try await checkedAzureService().startChat(parameters: parameters)
        let choice = response.choices?.first
        let text = choice?.message?.content ?? ""
        let completionOutcome = openAIChatCompletionOutcome(choice?.finishReason)
            ?? .incomplete(reason: "missing_finish_reason")

        return RepoPromptDomainRuntime.AICompletionResult(
            text: text,
            promptTokens: response.usage?.promptTokens,
            completionTokens: response.usage?.completionTokens,
            completionOutcome: completionOutcome
        )
    }

    package func dispose() async {
        // nothing to clean up
    }

    package func testAPIKey() async throws -> Bool {
        let targetModelID = configuration.defaultModelID ?? configuration.models.first?.id
        guard let modelID = targetModelID else {
            throw AIProviderError.invalidConfiguration(detail: "No Azure models discovered for validation.")
        }

        let testMessage = RepoPromptDomainRuntime.AIMessage(systemPrompt: "You are a helpful assistant.", userMessage: "Say hello")
        // Pass nil for maxTokens - Azure Responses API may reject max_output_tokens
        let result = try await completeMessage(testMessage, model: .azureCustom(name: modelID), maxTokens: nil)
        return result.text.lowercased().contains("hello")
    }
}

// MARK: - Deployment discovery helpers ------------------------------------------------------------

extension AzureOpenAIProvider {
    struct AzureDeploymentListResponse: Decodable {
        struct Deployment: Decodable {
            let id: String
            let model: String?
            let status: String?
        }

        let data: [Deployment]
    }

    package static func discoverDeployments(
        baseURL: URL,
        apiKey: String,
        apiVersions: [String],
        httpCredentialConsentEndpoint: String? = nil,
        host: any AzureOpenAIHTTPHost,
        httpClient: (any RepoPromptFoundation.HTTPClient)? = nil
    ) async throws -> [AzureOpenAIConfiguration.ModelDescriptor] {
        try host.validateEndpoint(baseURL, apiKey: apiKey, customHeaders: [:], consentEndpoint: httpCredentialConsentEndpoint)
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
                let response = try await (httpClient ?? DefaultHTTPClient.discoveryClient).data(for: request)
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
                        host.discoveryDescriptor(id: deployment.id, baseModelID: deployment.model)
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
}
