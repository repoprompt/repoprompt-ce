import RepoPromptCore

enum AIProviderInputRole: Equatable {
    case system
    case user
    case assistant
}

struct AIProviderInputProjection: Equatable {
    enum RouteResolution: Equatable {
        case unresolved
        case preflightResolved
        case providerResolved
    }

    enum Transport: Equatable {
        case unresolved
        case openAIChat
        case openAIResponses
        case anthropicMessages
        case roleLabeledCLI
        case claudeCode
        case customOpenAILegacy
    }

    enum FallbackReason: Equatable {
        case providerRuntimeConfigurationRequired
        case providerProjectionUnavailable
    }

    struct Fragment: Equatable {
        enum Channel: Equatable {
            case system
            case instructions
            case message(role: AIProviderInputRole)
            case standardInput
            case nativeSystemOverride
        }

        let channel: Channel
        let text: String
    }

    let transport: Transport
    let routeResolution: RouteResolution
    let fragments: [Fragment]
    let fallbackReason: FallbackReason?

    var renderedText: String {
        fragments.map(\.text).joined()
    }

    private init(
        transport: Transport,
        routeResolution: RouteResolution,
        fragments: [Fragment],
        fallbackReason: FallbackReason?
    ) {
        self.transport = transport
        self.routeResolution = routeResolution
        self.fragments = fragments
        self.fallbackReason = fallbackReason
    }

    static func unresolved(
        neutralChatInput input: AIMessage.PreparedOpenAIChatInput,
        fallbackReason: FallbackReason
    ) -> AIProviderInputProjection {
        AIProviderInputProjection(
            transport: .unresolved,
            routeResolution: .unresolved,
            fragments: fragments(for: input),
            fallbackReason: fallbackReason
        )
    }

    static func preflightResolved(
        chatInput input: AIMessage.PreparedOpenAIChatInput
    ) -> AIProviderInputProjection {
        AIProviderInputProjection(
            transport: .openAIChat,
            routeResolution: .preflightResolved,
            fragments: fragments(for: input),
            fallbackReason: nil
        )
    }

    static func preflightResolved(
        responsesInput input: AIMessage.PreparedOpenAIResponsesInput
    ) -> AIProviderInputProjection {
        AIProviderInputProjection(
            transport: .openAIResponses,
            routeResolution: .preflightResolved,
            fragments: fragments(for: input),
            fallbackReason: nil
        )
    }

    static func providerResolved(
        chatInput input: AIMessage.PreparedOpenAIChatInput
    ) -> AIProviderInputProjection {
        AIProviderInputProjection(
            transport: .openAIChat,
            routeResolution: .providerResolved,
            fragments: fragments(for: input),
            fallbackReason: nil
        )
    }

    static func providerResolved(
        responsesInput input: AIMessage.PreparedOpenAIResponsesInput
    ) -> AIProviderInputProjection {
        AIProviderInputProjection(
            transport: .openAIResponses,
            routeResolution: .providerResolved,
            fragments: fragments(for: input),
            fallbackReason: nil
        )
    }

    private static func fragments(
        for input: AIMessage.PreparedOpenAIChatInput
    ) -> [Fragment] {
        input.messages.map {
            Fragment(channel: .message(role: $0.role), text: $0.content)
        }
    }

    private static func fragments(
        for input: AIMessage.PreparedOpenAIResponsesInput
    ) -> [Fragment] {
        var fragments: [Fragment] = []
        if let instructions = input.instructions {
            fragments.append(.init(channel: .instructions, text: instructions))
        }
        fragments.append(contentsOf: input.messages.map {
            .init(channel: .message(role: $0.role), text: $0.content)
        })
        return fragments
    }
}

struct ChatInputTokenEstimate: Equatable {
    let inputProjection: AIProviderInputProjection
    let tokenProjection: TokenProjection

    init(
        inputProjection: AIProviderInputProjection,
        source: TokenProjection.Source
    ) {
        self.inputProjection = inputProjection
        tokenProjection = TokenProjectionService.renderedPayloadEstimate(
            inputProjection.renderedText,
            view: .userConfigured,
            source: source
        )
    }
}

enum AIProviderInputProjectionResolver {
    static func preflight(
        message: AIMessage,
        model: AIModel
    ) -> AIProviderInputProjection {
        switch model.providerType {
        case .openAI:
            openAIProjection(message: message, model: model)
        case .openRouter:
            .preflightResolved(
                chatInput: message.preparedOpenAIChatInput(embedSystemPrompt: false)
            )
        case .azure, .customProvider:
            unresolvedProjection(
                for: message,
                fallbackReason: .providerRuntimeConfigurationRequired
            )
        case .anthropic, .ollama, .gemini, .deepseek, .fireworks, .grok, .groq, .zAI,
             .claudeCode, .codex, .openCode, .cursor:
            unresolvedProjection(
                for: message,
                fallbackReason: .providerProjectionUnavailable
            )
        }
    }

    private static func openAIProjection(
        message: AIMessage,
        model: AIModel
    ) -> AIProviderInputProjection {
        if model.usesResponsesAPI {
            return .preflightResolved(
                responsesInput: message.preparedOpenAIResponsesInput()
            )
        }
        let embedSystemPrompt = model == .o1Mini || model == .o1Preview
        return .preflightResolved(
            chatInput: message.preparedOpenAIChatInput(embedSystemPrompt: embedSystemPrompt)
        )
    }

    private static func unresolvedProjection(
        for message: AIMessage,
        fallbackReason: AIProviderInputProjection.FallbackReason
    ) -> AIProviderInputProjection {
        .unresolved(
            neutralChatInput: message.preparedOpenAIChatInput(embedSystemPrompt: false),
            fallbackReason: fallbackReason
        )
    }
}
