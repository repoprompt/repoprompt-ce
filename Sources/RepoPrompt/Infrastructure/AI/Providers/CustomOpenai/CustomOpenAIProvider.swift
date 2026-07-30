import Foundation

/// Common chat completion parameters
enum CompletionParams {
    struct Message {
        enum Role: String {
            case system
            case user
            case assistant
        }

        enum Content {
            case text(String)
            case contentArray([Content])
        }

        let role: Role
        let content: Content
    }
}

/// Provider-specific errors with detailed status codes and messages
enum CustomOpenAIProviderError: Error {
    case invalidToken(statusCode: Int = 401, message: String = "Invalid or missing authentication token")
    case invalidModel(statusCode: Int = 400, message: String = "The specified model is not available or invalid")
    case requestFailed(statusCode: Int, message: String)
    case invalidResponse(statusCode: Int = 500, message: String = "Failed to parse response from server")
    case streamingNotSupported(statusCode: Int = 422, message: String = "Streaming is not supported for this model")
    case rateLimitExceeded(statusCode: Int = 429, message: String = "Rate limit exceeded. Please try again later")
    case serverError(statusCode: Int = 500, message: String = "Internal server error")
    case serviceUnavailable(statusCode: Int = 503, message: String = "Service temporarily unavailable")
    case requestTooLarge(statusCode: Int = 413, message: String = "This model has very strict token limits, and the provided request is too large.")

    var statusCode: Int {
        switch self {
        case let .invalidToken(code, _): code
        case let .invalidModel(code, _): code
        case let .requestFailed(code, _): code
        case let .invalidResponse(code, _): code
        case let .streamingNotSupported(code, _): code
        case let .rateLimitExceeded(code, _): code
        case let .serverError(code, _): code
        case let .serviceUnavailable(code, _): code
        case let .requestTooLarge(statusCode: code, _): code
        }
    }

    var errorMessage: String {
        switch self {
        case let .invalidToken(_, message): message
        case let .invalidModel(_, message): message
        case let .requestFailed(_, message): message
        case let .invalidResponse(_, message): message
        case let .streamingNotSupported(_, message): message
        case let .rateLimitExceeded(_, message): message
        case let .serverError(_, message): message
        case let .serviceUnavailable(_, message): message
        case let .requestTooLarge(_, message): message
        }
    }
}

class CustomOpenAIProvider: AIProvider, AIModelGetter {
    // Configuration
    private let baseURL: String
    private let apiKey: String
    private let defaultModel: String
    private let defaultTemperature: Double
    private let customHeaders: [String: String]
    private let configuredMaxTokens: Int? // Store configured max tokens
    private let includeContentTypeHeader: Bool // Flag to include Content-Type header
    private let apiVersion: String?
    private let httpClient: HTTPClient
    private let streamingHttpClient: HTTPClient

    /// Shared response structures
    struct ModelsResponse: Codable {
        struct Model: Codable {
            let id: String
            let name: String?
            let friendly_name: String?
            let model_version: Int?
            let publisher: String?
            let model_family: String?
            let model_registry: String?
            let license: String?
            let task: String?
            let description: String?
            let summary: String?
            let tags: [String]?
        }

        let data: [Model]?
        let models: [Model]?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let arrayData = try? container.decode([Model].self) {
                data = arrayData
                models = nil
            } else {
                let keyedContainer = try decoder.container(keyedBy: CodingKeys.self)
                data = try? keyedContainer.decode([Model].self, forKey: .data)
                models = try? keyedContainer.decode([Model].self, forKey: .models)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case data, models
        }

        var allModels: [Model] {
            if let data {
                return data
            }
            if let models {
                return models
            }
            return []
        }
    }

    struct ChatMessage: Codable {
        let role: String
        let content: String
    }

    /// Added support for max_tokens and temperature in the request payload
    struct ChatRequest: Codable {
        let model: String
        let messages: [ChatMessage]
        let max_tokens: Int?
        let temperature: Double?
    }

    struct ChatStreamRequest: Codable {
        let model: String
        let messages: [ChatMessage]
        let stream: Bool
        let max_tokens: Int?
        let temperature: Double?
    }

    struct ChatResponse: Codable {
        struct Choice: Codable {
            struct Message: Codable {
                let role: String
                let content: String
            }

            let message: Message
            let finish_reason: String?
        }

        let choices: [Choice]
    }

    struct StreamResponse: Codable {
        struct Choice: Codable {
            struct Delta: Codable {
                let content: String?
            }

            let delta: Delta
            let finish_reason: String?
        }

        let choices: [Choice]
    }

    init(
        baseURL: String,
        apiKey: String,
        defaultModel: String,
        defaultTemperature: Double = 0.3,
        customHeaders: [String: String] = [:],
        configuredMaxTokens: Int? = nil,
        includeContentTypeHeader: Bool = false,
        apiVersion: String? = nil,
        httpClient: HTTPClient = DefaultHTTPClient.aiClient,
        streamingHttpClient: HTTPClient = DefaultHTTPClient.aiStreamingClient
    ) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.apiKey = apiKey
        self.defaultModel = defaultModel
        self.defaultTemperature = defaultTemperature
        self.customHeaders = customHeaders
        self.configuredMaxTokens = configuredMaxTokens
        self.includeContentTypeHeader = includeContentTypeHeader
        self.apiVersion = apiVersion
        self.httpClient = httpClient
        self.streamingHttpClient = streamingHttpClient
    }

    private func urlFor(path: String) -> URL? {
        if let v = apiVersion, !v.isEmpty {
            URL(string: "\(baseURL)/\(v)/\(path)")
        } else {
            URL(string: "\(baseURL)/\(path)")
        }
    }

    private func createHeaders(forPost: Bool = true) -> [String: String] {
        var headers: [String: String] = [:]

        // Content-Type handling for POST requests:
        // - Most OpenAI-compatible APIs REQUIRE Content-Type: application/json
        // - A few providers may reject it (rare)
        // - The includeContentTypeHeader flag in config indicates user explicitly wants it
        // - We default to INCLUDING it for POST since that's the HTTP standard for JSON bodies
        if forPost {
            // Check if user has explicitly set Content-Type in custom headers (override everything)
            let hasCustomContentType = customHeaders.keys.contains { $0.lowercased() == "content-type" }
            if !hasCustomContentType {
                // Default: include Content-Type for POST requests (standard HTTP practice)
                headers["Content-Type"] = "application/json"
            }
        }

        headers["Authorization"] = "Bearer \(apiKey)"
        headers.merge(customHeaders) { _, new in new }
        return headers
    }

    // MARK: - Error Handling Helpers

    /// Parses error details from an API response body.
    /// Supports OpenAI-style error format: {"error": {"message": "...", "type": "...", "code": "..."}}
    private func parseErrorBody(_ data: Data) -> String? {
        // Try OpenAI-style error format first
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any] {
                let message = error["message"] as? String
                let type = error["type"] as? String
                let code = error["code"] as? String

                var parts: [String] = []
                if let msg = message { parts.append(msg) }
                if let t = type { parts.append("Type: \(t)") }
                if let c = code { parts.append("Code: \(c)") }

                if !parts.isEmpty {
                    return parts.joined(separator: ". ")
                }
            }
            // Some APIs return error as a string directly
            if let errorString = json["error"] as? String {
                return errorString
            }
            // Try "message" at top level
            if let message = json["message"] as? String {
                return message
            }
        }
        // Fall back to raw string if JSON parsing fails
        if let rawString = String(data: data, encoding: .utf8), !rawString.isEmpty {
            // Truncate very long error messages
            return rawString.count > 500 ? String(rawString.prefix(500)) + "..." : rawString
        }
        return nil
    }

    /// Determines if an error is transient and worth retrying.
    private func isRetryableError(_ error: Error) -> Bool {
        if let customError = error as? CustomOpenAIProviderError {
            switch customError {
            case .serverError, .serviceUnavailable, .rateLimitExceeded:
                return true
            default:
                return false
            }
        }
        // Also retry on network errors
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
                return true
            default:
                return false
            }
        }
        return false
    }

    /// Maps HTTP status code and response data to appropriate error with parsed details.
    private func mapHTTPError(statusCode: Int, data: Data, context: String = "") -> CustomOpenAIProviderError {
        let parsedDetail = parseErrorBody(data)
        let contextPrefix = context.isEmpty ? "" : "\(context): "

        switch statusCode {
        case 401:
            return .invalidToken(message: parsedDetail ?? "Invalid or missing authentication token")
        case 400:
            return .invalidModel(message: parsedDetail ?? "Bad request - check model name and parameters")
        case 404:
            return .requestFailed(statusCode: 404, message: parsedDetail ?? "\(contextPrefix)Endpoint not found")
        case 413:
            return .requestTooLarge(message: parsedDetail ?? "Request payload too large")
        case 429:
            return .rateLimitExceeded(message: parsedDetail ?? "Rate limit exceeded. Please try again later")
        case 500:
            return .serverError(message: parsedDetail ?? "Internal server error")
        case 502:
            return .serverError(statusCode: 502, message: parsedDetail ?? "Bad gateway - upstream server error")
        case 503:
            return .serviceUnavailable(message: parsedDetail ?? "Service temporarily unavailable")
        case 504:
            return .serverError(statusCode: 504, message: parsedDetail ?? "Gateway timeout")
        default:
            return .requestFailed(statusCode: statusCode, message: parsedDetail ?? "\(contextPrefix)Request failed with status code: \(statusCode)")
        }
    }

    /// Executes an async operation with retry logic for transient errors.
    private func withRetry<T>(
        maxAttempts: Int = 3,
        initialDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 10.0,
        operation: () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        var currentDelay = initialDelay

        for attempt in 1 ... maxAttempts {
            if Task.isCancelled {
                throw CancellationError()
            }
            do {
                return try await operation()
            } catch {
                lastError = error

                if Task.isCancelled {
                    throw CancellationError()
                }

                // Don't retry on non-retryable errors
                guard isRetryableError(error), attempt < maxAttempts else {
                    throw error
                }

                // Log retry attempt (in debug builds)
                #if DEBUG
                    print("[CustomOpenAIProvider] Attempt \(attempt) failed: \(error.localizedDescription). Retrying in \(currentDelay)s...")
                #endif

                // Wait before retrying with exponential backoff
                try await Task.sleep(nanoseconds: UInt64(currentDelay * 1_000_000_000))
                currentDelay = min(currentDelay * 2, maxDelay)
            }
        }

        throw lastError ?? CustomOpenAIProviderError.serverError(message: "Retry failed after \(maxAttempts) attempts")
    }

    func getAvailableModels() async throws -> [String] {
        guard let url = urlFor(path: "models") else {
            throw CustomOpenAIProviderError.invalidResponse(message: "Invalid base URL: \(baseURL)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        for (key, value) in createHeaders(forPost: false) {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let response = try await httpClient.data(for: request)

        guard response.http.statusCode == 200 else {
            throw mapHTTPError(statusCode: response.http.statusCode, data: response.data, context: "Models endpoint at \(url)")
        }

        do {
            let modelsResponse = try await HTTPDecoding.decode(ModelsResponse.self, from: response.data)
            return modelsResponse.allModels.map(\.id)
        } catch {
            throw CustomOpenAIProviderError.invalidResponse(
                message: "Failed to decode models: \(error)"
            )
        }
    }

    // ---------------------------------------
    // NEW: createMessages(for:)
    // ---------------------------------------
    private func createMessages(for aiMessage: AIMessage) -> [CompletionParams.Message] {
        var results: [CompletionParams.Message] = []

        // 1) System prompt
        if !aiMessage.systemPrompt.isEmpty {
            results.append(
                CompletionParams.Message(
                    role: .system,
                    content: .text(aiMessage.systemPrompt)
                )
            )
        }

        // Collect file tree, file blocks, and meta instructions into one block
        var additionsForFinalUserMessage = ""
        if !aiMessage.fileTree.isEmpty {
            additionsForFinalUserMessage += aiMessage.fileTreeXML + "\n"
        }
        if !aiMessage.fileBlocks.isEmpty {
            additionsForFinalUserMessage += aiMessage.fileBlocksXML + "\n"
        }
        for meta in aiMessage.metaPrompts {
            additionsForFinalUserMessage += meta + "\n"
        }
        if !aiMessage.disabledPromptSections.contains(.gitDiff),
           !aiMessage.gitDiffXML.isEmpty
        {
            additionsForFinalUserMessage += aiMessage.gitDiffXML + "\n"
        }

        // Find the index of the last user message
        let conversation = aiMessage.conversationMessages
        let lastUserIndex = conversation.lastIndex { $0.role == .user }

        // Build the conversation in chronological order
        for (index, entry) in conversation.enumerated() {
            let role: CompletionParams.Message.Role = entry.role == .user ? .user : .assistant

            if role == .user {
                var userContent = ""

                // If this is the last user message, add context before the message
                if index == lastUserIndex, !additionsForFinalUserMessage.isEmpty {
                    userContent = additionsForFinalUserMessage + "\n" + entry.content
                } else {
                    userContent = entry.content
                }

                results.append(
                    CompletionParams.Message(
                        role: .user,
                        content: .text(userContent)
                    )
                )
            } else {
                results.append(
                    CompletionParams.Message(
                        role: .assistant,
                        content: .text(entry.content)
                    )
                )
            }
        }

        return results
    }

    #if DEBUG
        func serializedMessagesForTesting(
            _ aiMessage: AIMessage
        ) -> [CompletionParams.Message] {
            createMessages(for: aiMessage)
        }
    #endif

    /// completeMessage now accepts temperature as a param
    func completeMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens: Int?) async throws -> AICompletionResult {
        // Build message array using new approach
        let messages = createMessages(for: aiMessage)

        // Ensure there's at least a system prompt
        guard !messages.isEmpty else {
            throw AIProviderError.invalidSystemPrompt
        }

        // Use retry logic for transient errors (5xx, rate limits, network issues)
        return try await withRetry(maxAttempts: 3) {
            let request = try self.createCompletionRequest(
                messages: messages,
                modelName: model.modelName,
                maxTokens: maxTokens,
                temperature: aiMessage.effectiveTemperature(for: model)
            )

            let response = try await httpClient.data(for: request)

            guard response.http.statusCode == 200 else {
                throw self.mapHTTPError(statusCode: response.http.statusCode, data: response.data, context: "Chat completion")
            }

            do {
                let chatResponse = try await HTTPDecoding.decode(ChatResponse.self, from: response.data)
                guard let content = chatResponse.choices.first?.message.content else {
                    throw CustomOpenAIProviderError.invalidResponse(message: "No content in response")
                }
                return AICompletionResult(text: content, promptTokens: nil, completionTokens: nil)
            } catch let decodeError as DecodingError {
                // Try to extract error message from response if decoding fails
                let errorDetail = self.parseErrorBody(response.data)
                throw CustomOpenAIProviderError.invalidResponse(message: errorDetail ?? "Failed to decode response: \(decodeError.localizedDescription)")
            }
        }
    }

    /// streamMessage now accepts temperature as a param
    func streamMessage(_ aiMessage: AIMessage, model: AIModel, maxTokens: Int?) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        // Check if stream is supported by the model
        if !model.canStream {
            let completeText = try await completeMessage(aiMessage, model: model, maxTokens: maxTokens)
            return AsyncThrowingStream { continuation in
                continuation.yield(AIStreamResult(type: "content", text: completeText.text, reasoning: nil, promptTokens: nil, completionTokens: nil))
                continuation.yield(AIStreamResult(type: "message_stop", text: nil, reasoning: nil, promptTokens: nil, completionTokens: nil))
                continuation.finish()
            }
        }

        // Build message array once (outside the retry loop for efficiency)
        let messages = createMessages(for: aiMessage)
        guard !messages.isEmpty else {
            throw AIProviderError.invalidSystemPrompt
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                // Retry wrapper for stream establishment
                var lastError: Error?
                var currentDelay: TimeInterval = 1.0
                let maxAttempts = 3
                let maxDelay: TimeInterval = 10.0

                for attempt in 1 ... maxAttempts {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }

                    do {
                        let request = try self.createCompletionRequest(
                            messages: messages,
                            modelName: model.modelName,
                            stream: true,
                            maxTokens: maxTokens,
                            temperature: aiMessage.effectiveTemperature(for: model)
                        )
                        let (bytes, httpResponse) = try await self.streamingHttpClient.bytes(for: request)

                        // Handle non-200 status codes by reading error body from stream
                        guard httpResponse.statusCode == 200 else {
                            var errorData = Data()
                            do {
                                for try await byte in bytes {
                                    errorData.append(byte)
                                    // Limit error body size to prevent memory issues
                                    if errorData.count > 10000 { break }
                                }
                            } catch {
                                // Ignore read errors when collecting error body
                            }
                            throw self.mapHTTPError(statusCode: httpResponse.statusCode, data: errorData, context: "Stream request")
                        }

                        // Successfully connected - process the stream
                        for try await line in bytes.lines {
                            if Task.isCancelled {
                                throw CancellationError()
                            }

                            // Check for SSE error events
                            if line.hasPrefix("event: error") {
                                continue // Next line will contain the error data
                            }

                            guard line.hasPrefix("data: ") else { continue }

                            let payload = String(line.dropFirst(6))

                            // Handle [DONE] signal
                            if payload == "[DONE]" {
                                continuation.yield(AIStreamResult(type: "message_stop", text: nil, reasoning: nil, promptTokens: nil, completionTokens: nil))
                                break
                            }

                            guard let data = payload.data(using: .utf8) else { continue }

                            // Try to decode as error response first
                            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let error = errorJson["error"] as? [String: Any]
                            {
                                let errorMessage = self.parseErrorBody(data) ?? "Stream error"
                                throw CustomOpenAIProviderError.serverError(message: errorMessage)
                            }

                            // Decode normal stream response
                            guard let streamResponse = try? JSONDecoder().decode(StreamResponse.self, from: data),
                                  let choice = streamResponse.choices.first
                            else {
                                continue
                            }

                            if let content = choice.delta.content {
                                continuation.yield(AIStreamResult(type: "content", text: content, reasoning: nil, promptTokens: nil, completionTokens: nil))
                            }

                            if choice.finish_reason != nil {
                                continuation.yield(AIStreamResult(type: "message_stop", text: nil, reasoning: nil, promptTokens: nil, completionTokens: nil))
                                break
                            }
                        }

                        continuation.finish()
                        return // Success - exit retry loop

                    } catch {
                        lastError = error

                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }

                        // Check if error is retryable and we have attempts left
                        guard self.isRetryableError(error), attempt < maxAttempts else {
                            continuation.finish(throwing: error)
                            return
                        }

                        #if DEBUG
                            print("[CustomOpenAIProvider] Stream attempt \(attempt) failed: \(error.localizedDescription). Retrying in \(currentDelay)s...")
                        #endif

                        // Wait before retrying
                        try? await Task.sleep(nanoseconds: UInt64(currentDelay * 1_000_000_000))
                        currentDelay = min(currentDelay * 2, maxDelay)
                    }
                }

                // Should not reach here, but handle just in case
                continuation.finish(throwing: lastError ?? CustomOpenAIProviderError.serverError(message: "Stream failed after \(maxAttempts) attempts"))
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func testAPIKey() async throws -> Bool {
        let testMessage = AIMessage(systemPrompt: "You are a helpful assistant.", userMessage: "Say hello")
        do {
            let response = try await completeMessage(testMessage, model: .openrouterCustom(name: defaultModel), maxTokens: 10)
            return response.text.lowercased().contains("hello")
        } catch {
            throw CustomOpenAIProviderError.invalidToken(message: "API key validation failed: \(error.localizedDescription)")
        }
    }

    private func shouldSkipTemperature(for model: String) -> Bool {
        let lower = model.lowercased()
        // Skip for provider variants of o3 and o4-mini
        return lower.contains("openai/o3") || lower.contains("o4-mini")
    }

    private func createCompletionRequest(
        messages: [CompletionParams.Message],
        modelName: String,
        stream: Bool = false,
        maxTokens: Int? = nil,
        temperature: Double? = nil
    ) throws -> URLRequest {
        guard let url = urlFor(path: "chat/completions") else {
            throw CustomOpenAIProviderError.invalidResponse(message: "Invalid base URL: \(baseURL)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        for (key, value) in createHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let openAIMessages = messages.map { message -> ChatMessage in
            let content: String = switch message.content {
            case let .text(text):
                text
            case let .contentArray(array):
                array.compactMap { chunk -> String? in
                    if case let .text(part) = chunk {
                        return part
                    }
                    return nil
                }.joined(separator: "\n")
            }
            return ChatMessage(
                role: message.role.rawValue,
                content: content
            )
        }

        // Use the provided temperature if available, or fall back to the provider default
        let skipTemp = shouldSkipTemperature(for: modelName)
        let tempToSend = skipTemp ? nil : (temperature ?? defaultTemperature)

        // Determine final max tokens with priority: configured -> parameter -> null
        let finalMaxTokens = configuredMaxTokens ?? maxTokens

        // Only include max_tokens if not the default value
        let maxTokensToUse = (finalMaxTokens == 2048) ? nil : finalMaxTokens

        if stream {
            let chatRequest = ChatStreamRequest(
                model: modelName,
                messages: openAIMessages,
                stream: true,
                max_tokens: maxTokensToUse,
                temperature: tempToSend
            )
            request.httpBody = try JSONEncoder().encode(chatRequest)
        } else {
            let chatRequest = ChatRequest(
                model: modelName,
                messages: openAIMessages,
                max_tokens: maxTokensToUse,
                temperature: tempToSend
            )
            request.httpBody = try JSONEncoder().encode(chatRequest)
        }

        return request
    }
}
