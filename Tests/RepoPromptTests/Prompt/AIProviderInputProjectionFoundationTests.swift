@testable import RepoPrompt
@testable import RepoPromptCore
import XCTest

final class AIProviderInputProjectionFoundationTests: XCTestCase {
    private let expectedTail = """
    <file_tree>
    TREE
    </file_tree>

    <file_contents>
    FILE

    </file_contents>

    <git_diff>
    DIFF
    </git_diff>

    META
    """

    func testPreparedChatInputFeedsSDKConversionWithoutChangingRolesOrBytes() {
        let message = makeMessage(conversation: [
            .init(role: .user, content: "EARLY"),
            .init(role: .assistant, content: "ASSISTANT"),
            .init(role: .user, content: "FINAL")
        ])

        let separateSystem = message.preparedOpenAIChatInput(embedSystemPrompt: false)
        XCTAssertEqual(separateSystem.messages, [
            .init(role: .system, content: "SYSTEM"),
            .init(role: .user, content: "EARLY"),
            .init(role: .assistant, content: "ASSISTANT"),
            .init(role: .user, content: expectedTail + "\nFINAL")
        ])
        assertPreparedChatFeedsSDK(message, embedSystemPrompt: false)

        let embeddedSystem = message.preparedOpenAIChatInput(embedSystemPrompt: true)
        XCTAssertEqual(embeddedSystem.messages, [
            .init(role: .user, content: "EARLY"),
            .init(role: .assistant, content: "ASSISTANT"),
            .init(role: .user, content: expectedTail + "\n\n\n\nSYSTEM\nFINAL")
        ])
        assertPreparedChatFeedsSDK(message, embedSystemPrompt: true)
    }

    func testPreparedResponsesInputFeedsSDKConversionAndPreservesEmptyConversationAndAssistantOnlyQuirks() {
        let conversationMessage = makeMessage(conversation: [
            .init(role: .assistant, content: "ASSISTANT-FIRST"),
            .init(role: .user, content: "FIRST-USER"),
            .init(role: .user, content: "SECOND-USER")
        ])
        XCTAssertEqual(conversationMessage.preparedOpenAIResponsesInput(), .init(
            instructions: "SYSTEM",
            messages: [
                .init(role: .assistant, content: "ASSISTANT-FIRST"),
                .init(role: .user, content: expectedTail + "\n\nFIRST-USER"),
                .init(role: .user, content: "SECOND-USER")
            ]
        ))
        assertPreparedResponsesFeedsSDK(conversationMessage)

        let emptyConversation = makeMessage(conversation: [])
        XCTAssertEqual(emptyConversation.preparedOpenAIResponsesInput(), .init(
            instructions: "SYSTEM",
            messages: [.init(role: .user, content: expectedTail + "\n\n")]
        ))
        assertPreparedResponsesFeedsSDK(emptyConversation)

        let assistantOnly = makeMessage(conversation: [
            .init(role: .assistant, content: "ASSISTANT-ONLY")
        ])
        XCTAssertEqual(assistantOnly.preparedOpenAIResponsesInput(), .init(
            instructions: "SYSTEM",
            messages: [.init(role: .assistant, content: "ASSISTANT-ONLY")]
        ))
        assertPreparedResponsesFeedsSDK(assistantOnly)

        let noTailEmptyConversation = AIMessage(
            systemPrompt: "",
            metaPrompts: [],
            fileTree: "",
            fileBlocks: [],
            conversationMessages: [],
            temperature: nil,
            promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
            disabledPromptSections: []
        )
        XCTAssertEqual(noTailEmptyConversation.preparedOpenAIResponsesInput(), .init(
            instructions: nil,
            messages: []
        ))
        assertPreparedResponsesFeedsSDK(noTailEmptyConversation)
    }

    func testPreflightResolverOnlyClaimsConfigurationIndependentOpenAIAndOpenRouterRoutes() {
        let message = makeMessage(conversation: [.init(role: .user, content: "FINAL")])

        let chat = AIProviderInputProjectionResolver.preflight(
            message: message,
            model: .openaiCustom(name: "chat-model")
        )
        XCTAssertEqual(chat.routeResolution, .preflightResolved)
        XCTAssertEqual(chat.transport, .openAIChat)
        XCTAssertEqual(chat.fragments.first?.channel, .message(role: .system))
        XCTAssertEqual(
            chat.renderedText,
            message.preparedOpenAIChatInput(embedSystemPrompt: false).messages.map(\.content).joined()
        )

        let responses = AIProviderInputProjectionResolver.preflight(message: message, model: .gpt5)
        XCTAssertEqual(responses.routeResolution, .preflightResolved)
        XCTAssertEqual(responses.transport, .openAIResponses)
        XCTAssertEqual(responses.fragments.first, .init(channel: .instructions, text: "SYSTEM"))
        XCTAssertEqual(
            responses.renderedText,
            "SYSTEM" + message.preparedOpenAIResponsesInput().messages.map(\.content).joined()
        )

        let openRouter = AIProviderInputProjectionResolver.preflight(
            message: message,
            model: .openrouterCustom(name: "router-model")
        )
        XCTAssertEqual(openRouter.routeResolution, .preflightResolved)
        XCTAssertEqual(openRouter.transport, .openAIChat)
    }

    func testPreflightResolverLeavesLegacyAzureRoutedModelsUnresolved() {
        let message = makeMessage(conversation: [.init(role: .user, content: "FINAL")])
        let legacyModels: [AIModel] = [.gpt4o, .o1Mini, .o1Preview, .o3, .o3Low, .o3High]

        for model in legacyModels {
            XCTAssertEqual(model.providerType, .azure)
            let projection = AIProviderInputProjectionResolver.preflight(message: message, model: model)
            XCTAssertEqual(projection.transport, .unresolved)
            XCTAssertEqual(projection.routeResolution, .unresolved)
            XCTAssertEqual(projection.fallbackReason, .providerRuntimeConfigurationRequired)
        }
    }

    func testPreflightResolverUsesExplicitUnresolvedFallbackOutsideNarrowRoutes() {
        let message = makeMessage(conversation: [.init(role: .user, content: "FINAL")])

        for model in [AIModel.azureCustom(name: "deployment"), .customProviderUser(name: "custom")] {
            let projection = AIProviderInputProjectionResolver.preflight(message: message, model: model)
            XCTAssertEqual(projection.transport, .unresolved)
            XCTAssertEqual(projection.routeResolution, .unresolved)
            XCTAssertEqual(projection.fallbackReason, .providerRuntimeConfigurationRequired)
        }

        for model in [AIModel.claude4Sonnet, .deepseekChat, .ollama] {
            let projection = AIProviderInputProjectionResolver.preflight(message: message, model: model)
            XCTAssertEqual(projection.transport, .unresolved)
            XCTAssertEqual(projection.routeResolution, .unresolved)
            XCTAssertEqual(projection.fallbackReason, .providerProjectionUnavailable)
        }
    }

    func testChatInputTokenEstimateKeepsRouteResolutionIndependentFromEstimateBasisAndSource() {
        let input = AIMessage(systemPrompt: "", userMessage: "12345678")
            .preparedOpenAIChatInput(embedSystemPrompt: false)
        let projections = [
            AIProviderInputProjection.unresolved(
                neutralChatInput: input,
                fallbackReason: .providerProjectionUnavailable
            ),
            .preflightResolved(chatInput: input),
            .providerResolved(chatInput: input)
        ]

        let estimates = projections.map {
            ChatInputTokenEstimate(inputProjection: $0, source: .immutableSnapshot)
        }
        XCTAssertEqual(estimates.map(\.inputProjection.routeResolution), [
            .unresolved,
            .preflightResolved,
            .providerResolved
        ])
        for estimate in estimates {
            XCTAssertEqual(estimate.tokenProjection.provenance.basis, .renderedPayloadEstimate)
            XCTAssertEqual(estimate.tokenProjection.provenance.source, .immutableSnapshot)
            XCTAssertEqual(estimate.tokenProjection.total, TokenCalculationService.estimateTokens(for: "12345678"))
        }
    }

    func testProviderStreamStartDefaultForwardsExistingStreamWithoutClaimingProjection() async throws {
        let provider = ForwardingProvider()
        let message = AIMessage(systemPrompt: "SYSTEM", userMessage: "USER")
        let start = try await provider.streamMessageWithInputProjection(
            message,
            model: .gpt4o,
            maxTokens: 42
        )

        XCTAssertNil(start.inputProjection)
        XCTAssertEqual(provider.receivedMaxTokens, 42)
        var resultTypes: [String] = []
        for try await result in start.stream {
            resultTypes.append(result.type)
        }
        XCTAssertEqual(resultTypes, ["message_stop"])
    }

    private func makeMessage(conversation: [ConversationEntry]) -> AIMessage {
        AIMessage(
            systemPrompt: "SYSTEM",
            metaPrompts: ["META"],
            fileTree: "TREE",
            fileBlocks: ["FILE"],
            gitDiff: "DIFF",
            conversationMessages: conversation,
            temperature: nil,
            promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
            disabledPromptSections: [],
            tailAssemblyStrategy: .coreStandardChat
        )
    }

    private func assertPreparedChatFeedsSDK(
        _ message: AIMessage,
        embedSystemPrompt: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let prepared = message.preparedOpenAIChatInput(embedSystemPrompt: embedSystemPrompt)
        let sdkMessages = message.openAIChatMessages(embedSystemPrompt: embedSystemPrompt).map { sdkMessage in
            let role: AIProviderInputRole = switch String(describing: sdkMessage.role) {
            case "system": .system
            case "user": .user
            default: .assistant
            }
            let content: String = switch sdkMessage.content {
            case let .text(text):
                text
            case let .contentArray(items):
                items.compactMap { item in
                    if case let .text(text) = item { return text }
                    return nil
                }.joined()
            }
            return AIMessage.PreparedMessage(role: role, content: content)
        }
        XCTAssertEqual(prepared.messages, sdkMessages, file: file, line: line)
    }

    private func assertPreparedResponsesFeedsSDK(
        _ message: AIMessage,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let prepared = message.preparedOpenAIResponsesInput()
        let sdkMessages: [AIMessage.PreparedMessage] = switch message.openAIResponsesInput() {
        case let .array(items):
            items.compactMap { item in
                guard case let .message(message) = item,
                      case let .text(text) = message.content
                else { return nil }
                return .init(
                    role: message.role == "user" ? .user : .assistant,
                    content: text
                )
            }
        default:
            []
        }
        XCTAssertEqual(prepared.messages, sdkMessages, file: file, line: line)
    }
}

private final class ForwardingProvider: AIProvider {
    var receivedMaxTokens: Int?

    func streamMessage(
        _: AIMessage,
        model _: AIModel,
        maxTokens: Int?
    ) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
        receivedMaxTokens = maxTokens
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(type: "message_stop", text: nil))
            continuation.finish()
        }
    }

    func completeMessage(
        _: AIMessage,
        model _: AIModel,
        maxTokens _: Int?
    ) async throws -> AICompletionResult {
        .init(text: "")
    }

    func dispose() async {}
}
