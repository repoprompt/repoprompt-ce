struct AIProviderStreamStart {
    let stream: AsyncThrowingStream<AIStreamResult, Error>
    let inputProjection: AIProviderInputProjection?
}

extension AIProvider {
    func streamMessageWithInputProjection(
        _ aiMessage: AIMessage,
        model: AIModel,
        maxTokens: Int?
    ) async throws -> AIProviderStreamStart {
        try await AIProviderStreamStart(
            stream: streamMessage(aiMessage, model: model, maxTokens: maxTokens),
            inputProjection: nil
        )
    }
}
