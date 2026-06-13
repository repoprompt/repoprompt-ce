import Foundation

/// Per-stream identifier for cancellation.
public typealias ChatStreamID = UUID

/// Groups all token-usage info so we can extend it later.
public struct ChatTokenInfo: Codable, Equatable {
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let cost: Double?

    public init(
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        cost: Double? = nil
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cost = cost
    }
}

/// The output of our Chat stream, now carrying a TokenInfo block.
public struct ChatStreamOutput {
    public let text: String
    public let reasoning: String?
    public let tokens: ChatTokenInfo
    public let isFinal: Bool
}

struct PartialBuffer {
    var chunks: [String] = []
    var charCount: Int = 0
    var reasoningChunks: [String] = [] // NEW: Buffer for reasoning text
    var reasoningCharCount: Int = 0 // NEW: Count of reasoning characters
    var lastFlushTime: Date = .init()

    // Token & cost tracking
    var promptTokens: Int?
    var completionTokens: Int?
    var cost: Double? // NEW: track cost
}

enum ReasoningTextFormatter {
    static func normalize(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        var normalized = text
        let replacements: [(pattern: String, template: String)] = [
            (#"\*\*([^\n*]+)\*\*\*\*([^\n*]+)\*\*"#, "**$1**\n\n**$2**"),
            (#"\*\*([^\n*]+)\*\*\*\*([^\n*]+)$"#, "**$1**\n\n**$2")
        ]

        var didChange = true
        while didChange {
            didChange = false
            for replacement in replacements {
                let updated = normalized.replacingOccurrences(
                    of: replacement.pattern,
                    with: replacement.template,
                    options: .regularExpression
                )
                if updated != normalized {
                    normalized = updated
                    didChange = true
                }
            }
        }

        return normalized
    }
}

/// Manages streaming tasks and partial output buffers for AI responses.
actor TaskManager {
    /// Store tasks as `Task<Void, Never>`, so they don't throw
    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// Each UUID has a PartialBuffer for storing streamed text and reasoning
    private var partialBuffers: [UUID: PartialBuffer] = [:]

    /// Keep track of each stream's continuation so we can explicitly finish it on cancel
    private var continuations: [UUID: AsyncThrowingStream<ChatStreamOutput, Error>.Continuation] = [:]

    /// Tracks streams that have been requested to cancel before the task or continuation existed.
    /// This prevents race conditions where cancelTask is called before addTask/storeContinuation.
    private var cancelledIDs: Set<UUID> = []

    // MARK: - Registering Tasks & Continuations

    func addTask(_ task: Task<Void, Never>, for id: UUID) {
        // If cancellation was requested before task was registered, cancel immediately
        if cancelledIDs.contains(id) {
            task.cancel()
            return
        }
        tasks[id] = task
    }

    /// Store the AsyncThrowingStream continuation so we can signal cancellation later.
    func storeContinuation(
        _ continuation: AsyncThrowingStream<ChatStreamOutput, Error>.Continuation,
        for id: UUID
    ) {
        // If cancellation was requested before continuation was stored, finish immediately
        if cancelledIDs.contains(id) {
            continuation.finish(throwing: CancellationError())
            return
        }
        continuations[id] = continuation
    }

    func removeTask(for id: UUID) {
        tasks[id] = nil
        partialBuffers[id] = nil
        continuations[id] = nil
        cancelledIDs.remove(id)
    }

    // MARK: - Partial Buffer

    func createPartialBuffer(for id: UUID) {
        // Clear any stale cancelled flag when starting fresh
        cancelledIDs.remove(id)
        partialBuffers[id] = PartialBuffer()
    }

    /// Check if a stream ID has been marked for cancellation
    func isCancelled(_ id: UUID) -> Bool {
        cancelledIDs.contains(id)
    }

    /// Accumulates text / reasoning / token counts in the partial buffer.
    /// Returns `true` if either buffer exceeds the threshold or the time-limit.
    func bufferChunk(
        _ text: String,
        for id: UUID,
        chunkSizeThreshold: Int,
        timeThreshold: TimeInterval,
        isReasoning: Bool = false,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        cost: Double? = nil // NEW parameter
    ) -> Bool {
        guard var buffer = partialBuffers[id] else { return false }

        if isReasoning {
            buffer.reasoningChunks.append(text)
            buffer.reasoningCharCount += text.count
        } else {
            buffer.chunks.append(text)
            buffer.charCount += text.count
        }

        // Keep the latest non-nil token counts and cost
        if let p = promptTokens { buffer.promptTokens = p }
        if let c = completionTokens { buffer.completionTokens = c }
        if let costValue = cost { buffer.cost = costValue } // NEW

        let now = Date()
        let elapsed = now.timeIntervalSince(buffer.lastFlushTime)

        let shouldYieldText = buffer.charCount >= chunkSizeThreshold
        let shouldYieldReasoning = buffer.reasoningCharCount >= chunkSizeThreshold
        let shouldYield = (shouldYieldText || shouldYieldReasoning) || (elapsed >= timeThreshold)

        partialBuffers[id] = buffer
        return shouldYield
    }

    /// Flushes the accumulated chunks and any stored token counts.
    /// Returns `(text, reasoning, tokenInfo, didReset)`.
    func flushBuffer(for id: UUID) -> (String, String?, ChatTokenInfo?, Bool) {
        guard var buffer = partialBuffers[id] else {
            return ("", nil, nil, false)
        }
        let combinedText = buffer.chunks.joined()
        let combinedReasoning = buffer.reasoningChunks.joined()

        // Include cost in token info if available
        let hasTokenInfo = buffer.promptTokens != nil || buffer.completionTokens != nil || buffer.cost != nil
        let tokenInfo: ChatTokenInfo? = hasTokenInfo
            ? ChatTokenInfo(
                promptTokens: buffer.promptTokens,
                completionTokens: buffer.completionTokens,
                cost: buffer.cost // NEW
            )
            : nil

        // Reset buffer
        buffer.chunks.removeAll()
        buffer.charCount = 0
        buffer.reasoningChunks.removeAll()
        buffer.reasoningCharCount = 0
        buffer.promptTokens = nil
        buffer.completionTokens = nil
        buffer.cost = nil // NEW reset cost
        buffer.lastFlushTime = Date()

        partialBuffers[id] = buffer
        let didReset = !(combinedText.isEmpty && combinedReasoning.isEmpty && tokenInfo == nil)
        return (combinedText, combinedReasoning.isEmpty ? nil : combinedReasoning, tokenInfo, didReset)
    }

    // MARK: - Cancellation

    /// Cancel only the given stream: task + stream continuation + buffer.
    /// Records the ID so that late-arriving task/continuation registrations are also cancelled.
    func cancelTask(for id: UUID) {
        // Record cancellation intent - handles race where cancel arrives before registration
        cancelledIDs.insert(id)

        if let task = tasks[id] {
            task.cancel()
        }
        if let cont = continuations.removeValue(forKey: id) {
            cont.finish(throwing: CancellationError())
        }
        tasks[id] = nil
        partialBuffers[id] = nil
    }

    /// Cancels all tasks by delegating to cancelTask(for:) for each.
    func cancelAllTasks() {
        let allIds = Array(tasks.keys)
        for id in allIds {
            cancelTask(for: id)
        }
    }
}

public class AIQueriesService {
    typealias SendPromptOverride = @Sendable (
        _ message: AIMessage,
        _ model: AIModel
    ) async throws -> (id: ChatStreamID, stream: AsyncThrowingStream<ChatStreamOutput, Error>)

    private let taskManager = TaskManager()
    private let chunkSizeThreshold = 8000 // e.g. 8KB
    private let timeThreshold: TimeInterval = 0.7 // 0.4 seconds
    private let providerPool: DisposableProviderPool
    private let keyManager: KeyManager
    private let sendPromptOverride: SendPromptOverride?
    private var currentModel: AIModel

    init(
        keyManager: KeyManager,
        sendPromptOverride: SendPromptOverride? = nil
    ) {
        currentModel = .claude4Sonnet
        self.keyManager = keyManager
        self.sendPromptOverride = sendPromptOverride
        providerPool = DisposableProviderPool(keyManager: keyManager)
    }

    init(
        model: AIModel,
        ollamaURL: URL? = nil,
        azureConfiguration: AzureOpenAIConfiguration? = nil,
        keyManager: KeyManager,
        sendPromptOverride: SendPromptOverride? = nil
    ) {
        currentModel = model
        self.keyManager = keyManager
        self.sendPromptOverride = sendPromptOverride
        providerPool = DisposableProviderPool(keyManager: keyManager)
    }

    /// Cancel all active streams. Prefer `cancelStream(id:)` for targeted cancellation.
    func cancelQuery() {
        Task {
            await taskManager.cancelAllTasks()
        }
    }

    static func shouldEagerlyFlushReasoningSummaries(for model: AIModel) -> Bool {
        switch model {
        case let .openAIServiceTierVariant(base, _):
            return shouldEagerlyFlushReasoningSummaries(for: base)
        case .openaiCustom:
            return false
        default:
            if model.providerType == .codex {
                return true
            }
            return model.providerType == .openAI && model.usesResponsesAPI
        }
    }

    private static func isLikelyReasoningSummaryChunk(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.hasPrefix("**") || trimmed.contains("****")
    }

    /// Cancel only the specified stream.
    func cancelStream(id: ChatStreamID) async {
        await taskManager.cancelTask(for: id)
    }

    func sendPrompt(
        _ aiMessage: AIMessage,
        model: AIModel
    ) async throws -> (id: ChatStreamID, stream: AsyncThrowingStream<ChatStreamOutput, Error>) {
        if let sendPromptOverride {
            return try await sendPromptOverride(aiMessage, model)
        }

        let taskId = UUID()
        await taskManager.createPartialBuffer(for: taskId)

        let stream = AsyncThrowingStream<ChatStreamOutput, Error> { continuation in
            // Store the continuation so we can call finish(throwing:) on cancel.
            Task {
                await self.taskManager.storeContinuation(continuation, for: taskId)
            }

            // Our "streamingTask" is a Task<Void, Never>
            let streamingTask = Task<Void, Never> {
                defer {
                    Task { await self.taskManager.removeTask(for: taskId) }
                }

                do {
                    // Build a provider
                    let provider = try await self.providerPool.createProvider(for: model)

                    // Ensure provider is always disposed, regardless of how we exit
                    defer {
                        Task { await provider.dispose() }
                    }

                    do {
                        let providerStream = try await provider.streamMessage(aiMessage, model: model)

                        var wasCancelled = false
                        var sawMessageStop = false
                        var lastTokenInfo: ChatTokenInfo?
                        let shouldEagerlyFlushReasoning = Self.shouldEagerlyFlushReasoningSummaries(for: model)

                        // Loop through the partial stream
                        streamLoop: for try await result in providerStream {
                            // Check cancellation - use flag + break pattern to ensure cleanup
                            // Note: Must check taskManager.isCancelled separately since await can't be used with ||
                            let managerCancelled = await self.taskManager.isCancelled(taskId)
                            if Task.isCancelled || managerCancelled {
                                wasCancelled = true
                                break streamLoop
                            }

                            var shouldYield = false

                            if let text = result.text, !text.isEmpty {
                                let yieldText = await self.taskManager.bufferChunk(
                                    text,
                                    for: taskId,
                                    chunkSizeThreshold: self.chunkSizeThreshold,
                                    timeThreshold: self.timeThreshold,
                                    isReasoning: false,
                                    promptTokens: result.promptTokens,
                                    completionTokens: result.completionTokens,
                                    cost: result.cost
                                )
                                shouldYield = shouldYield || yieldText
                            }

                            if let reasoning = result.reasoning, !reasoning.isEmpty {
                                let yieldReasoning = await self.taskManager.bufferChunk(
                                    reasoning,
                                    for: taskId,
                                    chunkSizeThreshold: self.chunkSizeThreshold,
                                    timeThreshold: self.timeThreshold,
                                    isReasoning: true,
                                    promptTokens: result.promptTokens,
                                    completionTokens: result.completionTokens,
                                    cost: result.cost
                                )
                                shouldYield = shouldYield || yieldReasoning
                                if shouldEagerlyFlushReasoning, Self.isLikelyReasoningSummaryChunk(reasoning) {
                                    shouldYield = true
                                }
                            }

                            // Track last known token info for final flush
                            let chunkTokenInfo = ChatTokenInfo(
                                promptTokens: result.promptTokens,
                                completionTokens: result.completionTokens,
                                cost: result.cost
                            )
                            if result.promptTokens != nil || result.completionTokens != nil || result.cost != nil {
                                lastTokenInfo = chunkTokenInfo
                            }

                            // If the provider signals end of message or buffers are ready to be flushed.
                            if result.type == "message_stop" || shouldYield {
                                let (combinedText, combinedReasoning, bufferedTokenInfo, _) = await self.taskManager.flushBuffer(for: taskId)
                                let isFinal = (result.type == "message_stop")
                                if isFinal { sawMessageStop = true }

                                // Prefer buffered counts; fall back to this chunk's counts
                                let tokenInfo = bufferedTokenInfo ?? chunkTokenInfo

                                continuation.yield(
                                    ChatStreamOutput(
                                        text: combinedText,
                                        reasoning: combinedReasoning.map(ReasoningTextFormatter.normalize),
                                        tokens: tokenInfo,
                                        isFinal: isFinal
                                    )
                                )
                                if isFinal {
                                    break streamLoop
                                }
                            }
                        }

                        // Handle stream exit conditions
                        if wasCancelled {
                            // Clear any pending buffer without emitting
                            _ = await self.taskManager.flushBuffer(for: taskId)
                            continuation.finish(throwing: CancellationError())
                        } else if !sawMessageStop {
                            // Stream ended without message_stop - flush any remaining buffer as final
                            let (combinedText, combinedReasoning, bufferedTokenInfo, didHaveContent) = await self.taskManager.flushBuffer(for: taskId)
                            if didHaveContent {
                                let tokenInfo = bufferedTokenInfo ?? lastTokenInfo ?? ChatTokenInfo()
                                continuation.yield(
                                    ChatStreamOutput(
                                        text: combinedText,
                                        reasoning: combinedReasoning.map(ReasoningTextFormatter.normalize),
                                        tokens: tokenInfo,
                                        isFinal: true
                                    )
                                )
                            }
                            continuation.finish()
                        } else {
                            // Normal completion - already emitted final chunk
                            continuation.finish()
                        }

                    } catch {
                        // Streaming error - provider disposal handled by defer
                        throw error
                    }

                } catch {
                    // Provider creation or streaming error
                    continuation.finish(throwing: error)
                }
            }

            // Register the streamingTask so we can cancel it later
            Task {
                await self.taskManager.addTask(streamingTask, for: taskId)
            }
        }

        return (id: taskId, stream: stream)
    }

    /// Retries for certain NSURLErrorDomain issues
    private func withRetry<T>(retryCount: Int = 1, operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as NSError where error.domain == NSURLErrorDomain {
            let retryableErrorCodes = [
                NSURLErrorTimedOut,
                NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorNotConnectedToInternet,
                NSURLErrorSecureConnectionFailed
            ]
            if retryableErrorCodes.contains(error.code), retryCount > 0 {
                print("Network error: \(error). Retrying... (\(retryCount) attempts left)")
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second delay
                return try await withRetry(retryCount: retryCount - 1, operation: operation)
            } else {
                throw error
            }
        }
    }

    // API Testing Methods

    func testAnthropicAPI(with apiKey: String? = nil) async throws -> Bool {
        if let providedKey = apiKey {
            let provider = try await AIProviderFactory.createProvider(for: .anthropic, key: providedKey) as! AnthropicProvider
            return try await withTimeout(seconds: 30) { try await provider.testAPIKey() }
        } else {
            let provider = try await AIProviderFactory.createProvider(for: .anthropic, keyManager: keyManager) as! AnthropicProvider
            return try await withTimeout(seconds: 30) { try await provider.testAPIKey() }
        }
    }

    func testOpenAIAPI(with apiKey: String? = nil, baseURL: String? = nil) async throws -> Bool {
        let key: String? = if let apiKey {
            apiKey
        } else {
            try await keyManager.getAPIKey(for: .openAI)
        }
        // If nil or empty, immediate false keeps behavior aligned with other validators
        guard let key, !key.isEmpty else { return false }

        // Pull fallback from UserDefaults if caller didn't provide baseURL
        let overrideRaw = baseURL ?? UserDefaults.standard.string(forKey: "customBaseURLOpenAI")
        let split = OpenAIURLHelper.splitBaseURLAndVersion(overrideRaw)
        let base = split.base
        // If a version is present in the override string, prefer it; otherwise look for stored override
        let storedVersion = UserDefaults.standard.string(forKey: "customOpenAIVersionOverride")
        let version = split.version ?? storedVersion

        // Build a one-off provider that uses the override + version
        let provider = OpenAIProvider(
            apiKey: key,
            baseURL: base,
            configuredMaxTokens: nil,
            overrideVersion: version
        )
        return try await withTimeout(seconds: 30) { try await provider.testAPIKey() }
    }

    func testModelCompletion(model: AIModel, message: AIMessage, expectedText: String) async throws -> Bool {
        let provider = try await providerPool.createProvider(for: model)
        defer {
            Task { await provider.dispose() }
        }

        let result = try await withTimeout(seconds: 30) {
            try await provider.completeMessage(message, model: model, maxTokens: nil)
        }
        return result.text.lowercased().contains(expectedText.lowercased())
    }

    func testOllamaAPI(url: URL, model: AIModel = .ollama) async throws -> Bool {
        let provider = try await AIProviderFactory.createProvider(for: .ollama, keyManager: keyManager, ollamaURL: url) as! OpenAIProvider
        return try await withTimeout(seconds: 30) { try await provider.testAPIKey(model: model) }
    }

    func testAzureOpenAIAPI(configuration: AzureOpenAIConfiguration) async throws -> Bool {
        let provider = try await AIProviderFactory.createProvider(for: .azure, keyManager: keyManager, azureConfiguration: configuration) as! AzureOpenAIProvider
        return try await withTimeout(seconds: 30) { try await provider.testAPIKey() }
    }

    func testGeminiAPI(with apiKey: String? = nil) async throws -> Bool {
        let provider: GeminiProvider = if let apiKey {
            try await AIProviderFactory.createProvider(for: .gemini, key: apiKey) as! GeminiProvider
        } else {
            try await AIProviderFactory.createProvider(for: .gemini, keyManager: keyManager) as! GeminiProvider
        }
        return try await withTimeout(seconds: 30) { try await provider.testAPIKey() }
    }

    func testOpenRouterAPI(with apiKey: String? = nil, model: AIModel = .openrouterGpt5) async throws -> Bool {
        let provider: OpenRouterProvider = if let apiKey {
            try await AIProviderFactory.createProvider(for: .openRouter, key: apiKey) as! OpenRouterProvider
        } else {
            try await AIProviderFactory.createProvider(for: .openRouter, keyManager: keyManager) as! OpenRouterProvider
        }

        do {
            return try await withTimeout(seconds: 30) {
                try await provider.testAPIKey(model: model)
            }
        } catch is TimeoutError {
            throw NSError(domain: "OpenRouterError", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Request timed out after 30 seconds. The model may be invalid or unavailable."
            ])
        }
    }

    /// NEW: testDeepSeekAPI
    func testDeepSeekAPI(with apiKey: String? = nil) async throws -> Bool {
        let provider: DeepSeekProvider = if let apiKey {
            try await AIProviderFactory.createProvider(for: .deepseek, key: apiKey) as! DeepSeekProvider
        } else {
            try await AIProviderFactory.createProvider(for: .deepseek, keyManager: keyManager) as! DeepSeekProvider
        }
        return try await withTimeout(seconds: 30) { try await provider.testAPIKey(model: .deepseekChat) }
    }

    /// Test Fireworks API key
    func testFireworksAPI(with apiKey: String? = nil) async throws -> Bool {
        let provider: FireworksProvider = if let apiKey {
            try await AIProviderFactory.createProvider(for: .fireworks, key: apiKey) as! FireworksProvider
        } else {
            try await AIProviderFactory.createProvider(for: .fireworks, keyManager: keyManager) as! FireworksProvider
        }
        return try await withTimeout(seconds: 30) { try await provider.testAPIKey() }
    }

    /// Test Grok API key
    func testGrokAPI(with apiKey: String? = nil) async throws -> Bool { // NEW
        let provider: GrokProvider = if let apiKey {
            try await AIProviderFactory.createProvider(for: .grok, key: apiKey) as! GrokProvider
        } else {
            try await AIProviderFactory.createProvider(for: .grok, keyManager: keyManager) as! GrokProvider
        }
        return try await withTimeout(seconds: 30) { try await provider.testAPIKey(model: .grokCodeFast1) }
    }

    func testGroqAPI(with apiKey: String? = nil) async throws -> Bool { // NEW
        let provider: GroqProvider = if let apiKey {
            try await AIProviderFactory.createProvider(for: .groq, key: apiKey) as! GroqProvider
        } else {
            try await AIProviderFactory.createProvider(for: .groq, keyManager: keyManager) as! GroqProvider
        }
        return try await withTimeout(seconds: 30) { try await provider.testAPIKey(model: .groqKimi) }
    }

    func testZAIAPI(with apiKey: String? = nil) async throws -> Bool {
        let provider: ZAIProvider = if let apiKey {
            try await AIProviderFactory.createProvider(for: .zAI, key: apiKey) as! ZAIProvider
        } else {
            try await AIProviderFactory.createProvider(for: .zAI, keyManager: keyManager) as! ZAIProvider
        }
        return try await withTimeout(seconds: 30) { try await provider.testAPIKey() }
    }

    func testZAICodingPlanAPI(with apiKey: String? = nil) async throws -> Bool {
        let key: String = if let apiKey {
            apiKey
        } else {
            try await keyManager.getAPIKey(for: .zAI) ?? ""
        }
        let provider = ZAIProvider(apiKey: key, endpoint: .codingPlan)
        let hasCodingPlanAccess = try await withTimeout(seconds: 30) { try await provider.testAPIKey(model: .zaiGLM47) }
        if hasCodingPlanAccess {
            return true
        }

        let generalProvider = ZAIProvider(apiKey: key, endpoint: .generalAPI)
        let hasGeneralAccess = try await withTimeout(seconds: 30) { try await generalProvider.testAPIKey() }
        if hasGeneralAccess {
            throw AIProviderError.invalidConfiguration(
                detail: "This Z.ai API key is valid, but it does not have an active GLM Coding Plan. CC Zai in Agent Mode requires a Z.ai GLM Coding Plan subscription."
            )
        }

        return false
    }

    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    struct TimeoutError: Error {}

    func testCustomProviderAPI(url: String, apiKey: String, model: String) async throws -> Bool {
        try await OpenAIProvider.testCustomProviderAPI(
            url: url,
            apiKey: apiKey,
            model: model,
            timeout: 30.0
        )
    }
}

extension OpenAIProvider {
    /// Quickly validates a custom OpenAI-compatible endpoint by making
    /// a tiny completion request and ensuring \"hello\" is returned.
    ///
    /// - Parameters:
    ///   - url:  Full base URL **including** or **excluding** the `/vN` suffix.
    ///   - apiKey: The bearer/API key to use. Pass an empty string for key-less endpoints.
    ///   - model: The model identifier to validate, e.g. \"gpt-4o\".
    ///   - timeout: Optional timeout (seconds) – defaults to 8 s.
    /// - Returns: `true` on success, otherwise an error is thrown.
    static func testCustomProviderAPI(
        url: String,
        apiKey: String,
        model: String,
        timeout: TimeInterval = 8.0
    ) async throws -> Bool {
        // ── 1. Normalize and split base + version ────────────────────────────────
        let split = OpenAIURLHelper.splitBaseURLAndVersion(url)
        guard let baseURL = split.base else {
            throw AIProviderError.missingURL
        }

        // ── 2. Spin-up a throw-away provider with optional overrideVersion ───
        let provider = OpenAIProvider(
            apiKey: apiKey,
            baseURL: baseURL,
            configuredMaxTokens: 16, // keep the test cheap
            overrideVersion: split.version
        )

        // ── 3. Perform a tiny completion call ───────────────────────────────
        let testMessage = AIMessage(
            systemPrompt: "You are a helpful assistant.",
            userMessage: "Say hello"
        )

        let modelEnum: AIModel = .openaiCustom(name: model)

        do {
            let result = try await provider.completeMessage(
                testMessage,
                model: modelEnum,
                maxTokens: 10
            )
            return result.text.lowercased().contains("hello")
        } catch {
            // Bubble-up a consistent provider error
            throw AIProviderError.apiError(source: error)
        }
    }
}
