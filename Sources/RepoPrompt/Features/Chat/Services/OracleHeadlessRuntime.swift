import Foundation

private actor OracleHeadlessCleanupHandleBox {
    private var handle: ProviderConversationCleanupHandle?

    func update(_ handle: ProviderConversationCleanupHandle) {
        self.handle = handle
    }

    func current() -> ProviderConversationCleanupHandle? {
        handle
    }
}

/// Executes Oracle requests that do not participate in the live chat transcript.
///
/// This runtime owns only provider-stream lifecycle. Prompt construction, chat-session
/// persistence, transcript state, and presentation remain with `OracleViewModel`.
@MainActor
final class OracleHeadlessRuntime {
    struct Output {
        let text: String
        let tokenInfo: ChatTokenInfo
        let providerCleanupHandle: ProviderConversationCleanupHandle?
    }

    typealias SendPrompt = (
        _ message: AIMessage,
        _ model: AIModel
    ) async throws -> (
        id: ChatStreamID,
        stream: AsyncThrowingStream<ChatStreamOutput, Error>
    )
    typealias CancelStream = (_ id: ChatStreamID) async -> Void
    typealias CleanupConversation = (
        _ handle: ProviderConversationCleanupHandle,
        _ model: AIModel
    ) async -> Void

    private let sendPrompt: SendPrompt
    private let cancelStream: CancelStream
    private let cleanupConversation: CleanupConversation
    private let timeout: Duration
    private var streamIDsByTabID: [UUID: ChatStreamID] = [:]

    convenience init(aiQueriesService: AIQueriesService) {
        self.init(
            sendPrompt: { message, model in
                try await aiQueriesService.sendPrompt(message, model: model)
            },
            cancelStream: { streamID in
                await aiQueriesService.cancelStream(id: streamID)
            },
            cleanupConversation: { handle, model in
                let outcome = await aiQueriesService.cleanupProviderConversation(
                    handle: handle,
                    model: model,
                    action: .delete
                )
                #if DEBUG
                    print(
                        "[OracleHeadlessRuntime] provider conversation cleanup action=delete " +
                            "provider=\(handle.provider) status=\(outcome.status) " +
                            "message=\(outcome.message ?? "")"
                    )
                #endif
            }
        )
    }

    init(
        sendPrompt: @escaping SendPrompt,
        cancelStream: @escaping CancelStream,
        cleanupConversation: @escaping CleanupConversation,
        timeout: Duration = .seconds(4 * 60 * 60)
    ) {
        self.sendPrompt = sendPrompt
        self.cancelStream = cancelStream
        self.cleanupConversation = cleanupConversation
        self.timeout = timeout
    }

    func execute(
        message: AIMessage,
        model: AIModel,
        tabID: UUID,
        completionPolicy: OracleResponseCompletionPolicy,
        onProgress: ((_ text: String, _ reasoning: String?) -> Void)? = nil
    ) async throws -> Output {
        try Task.checkCancellation()

        let (streamID, stream) = try await sendPrompt(message, model)
        let cleanupHandleBox = OracleHeadlessCleanupHandleBox()
        var completedSuccessfully = false
        defer {
            if !completedSuccessfully {
                Task {
                    await self.cleanup(
                        cleanupHandleBox.current(),
                        model: model
                    )
                }
            }
        }

        streamIDsByTabID[tabID] = streamID
        defer {
            streamIDsByTabID.removeValue(forKey: tabID)
        }

        let timeout = timeout
        let (finalText, _, finalTokenInfo, providerCleanupHandle, terminalOutcome) = try await withThrowingTaskGroup(
            of: (String, String, ChatTokenInfo, ProviderConversationCleanupHandle?, ChatStreamTerminalOutcome?).self
        ) { group in
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ChatToolError.internalError("Stream timed out before completion.")
            }

            group.addTask { [stream, onProgress, cleanupHandleBox] in
                var accumulatedText = ""
                var accumulatedReasoning = ""
                var tokens = ChatTokenInfo()
                var cleanupHandle: ProviderConversationCleanupHandle?
                var terminalOutcome: ChatStreamTerminalOutcome?
                var iterator = stream.makeAsyncIterator()

                while let chunk = try await iterator.next() {
                    accumulatedText += chunk.text
                    if let reasoning = chunk.reasoning, !reasoning.isEmpty {
                        accumulatedReasoning += reasoning
                        accumulatedReasoning = ReasoningTextFormatter.normalize(accumulatedReasoning)
                    }
                    if chunk.tokens.promptTokens != nil ||
                        chunk.tokens.completionTokens != nil ||
                        chunk.tokens.cost != nil
                    {
                        tokens = chunk.tokens
                    }
                    if let handle = chunk.cleanupHandle {
                        cleanupHandle = handle
                        await cleanupHandleBox.update(handle)
                    }
                    if let onProgress {
                        let text = accumulatedText
                        let reasoning = accumulatedReasoning.isEmpty ? nil : accumulatedReasoning
                        await MainActor.run { onProgress(text, reasoning) }
                    }
                    if let outcome = chunk.terminalOutcome {
                        terminalOutcome = outcome
                        break
                    }
                }
                return (
                    accumulatedText,
                    accumulatedReasoning,
                    tokens,
                    cleanupHandle,
                    terminalOutcome
                )
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        if completionPolicy == .contextBuilderStrict {
            switch terminalOutcome {
            case .completed:
                break
            case let .incomplete(reason):
                throw OracleContextBuilderCompletionError.providerTerminatedIncomplete(reason: reason)
            case nil:
                throw OracleContextBuilderCompletionError.streamEndedWithoutProviderCompletion
            }
        }

        let trimmedResponse = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedResponse.isEmpty else {
            if completionPolicy == .contextBuilderStrict {
                throw OracleContextBuilderCompletionError.emptyProcessedContent
            }
            throw ChatToolError.internalError("Request produced no content.")
        }

        completedSuccessfully = true
        return Output(
            text: trimmedResponse,
            tokenInfo: finalTokenInfo,
            providerCleanupHandle: providerCleanupHandle
        )
    }

    func hasActiveStream(for tabID: UUID) -> Bool {
        streamIDsByTabID[tabID] != nil
    }

    func cancelStream(for tabID: UUID) async {
        guard let streamID = streamIDsByTabID.removeValue(forKey: tabID) else { return }
        await cancelStream(streamID)
    }

    func cancelAllStreams() async {
        let streamIDs = Array(streamIDsByTabID.values)
        streamIDsByTabID.removeAll(keepingCapacity: false)
        for streamID in streamIDs {
            await cancelStream(streamID)
        }
    }

    func cleanup(
        _ handle: ProviderConversationCleanupHandle?,
        model: AIModel
    ) async {
        guard let handle else { return }
        await cleanupConversation(handle, model)
    }
}
