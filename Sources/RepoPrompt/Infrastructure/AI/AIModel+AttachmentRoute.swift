import RepoPromptDomainRuntime

extension AIModel {
    /// Azure maps to chat whatever `usesResponsesAPI` says: `AzureOpenAIProvider` routes on the
    /// deployment descriptor first, so a flag disagreement would otherwise refuse after the turn exists.
    /// The Responses encoder carries everything chat carries, so a chat-admitted set encodes under it.
    /// `customProvider` maps to the custom row, the weakest of the three OpenAI-compatible encoders,
    /// because its provider may encode through `CustomOpenAIMessageBuilder` or through `OpenAIProvider`.
    var attachmentRoute: AttachmentRoute {
        switch providerType {
        case .anthropic: .anthropicMessages
        case .openAI: usesResponsesAPI ? .openAIResponses : .openAIChat
        case .azure: .openAIChat
        case .ollama, .openRouter, .gemini, .deepseek, .fireworks, .grok, .groq, .zAI: .openAIChat
        case .customProvider: .customOpenAI
        case .claudeCode: .claudeCodeStreamJSON
        case .codex: .codexAppServer
        case .openCode, .cursor, .devin: .acp
        case .grokBuild: .grokBuild
        }
    }
}
