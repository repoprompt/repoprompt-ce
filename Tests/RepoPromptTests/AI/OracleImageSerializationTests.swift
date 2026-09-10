import Foundation
@testable import RepoPromptApp
import SwiftAnthropic
import XCTest

/// Each image-capable Oracle transport must emit its own native image block, attach it to the
/// turn the image arrived with, and leave text-only requests byte-identical to before.
final class OracleImageSerializationTests: XCTestCase {
    func testAnthropicAttachesImageBlocksOnlyToFinalUserTurn() throws {
        let json = try jsonObject(AnthropicProvider.makeMessages(for: makeMessage()))
        let messages = try XCTUnwrap(json as? [[String: Any]])

        XCTAssertEqual(countObjects(type: "image", in: json), 1)
        XCTAssertTrue(try jsonText(json).contains("Image title: Diagram"))
        XCTAssertFalse(try jsonText(messages[0]).contains("AQID"))
        XCTAssertTrue(try jsonText(XCTUnwrap(messages.last)).contains("AQID"))
    }

    func testOpenAIChatAttachesImagePartsOnlyToFinalUserTurn() throws {
        let json = try jsonObject(makeMessage().openAIChatMessages(embedSystemPrompt: false))
        let messages = try XCTUnwrap(json as? [[String: Any]])

        XCTAssertEqual(countObjects(type: "image_url", in: json), 1)
        XCTAssertTrue(try containsPNGDataURL(jsonText(json)))
        XCTAssertTrue(try jsonText(json).contains("Image title: Diagram"))
        XCTAssertFalse(try jsonText(messages[1]).contains("AQID"))
        XCTAssertTrue(try jsonText(XCTUnwrap(messages.last)).contains("AQID"))
    }

    func testOpenAIResponsesAttachesImagePartsOnlyToFinalUserTurn() throws {
        let json = try jsonObject(makeMessage().openAIResponsesInput())
        let text = try jsonText(json)

        XCTAssertEqual(countObjects(type: "input_image", in: json), 1)
        XCTAssertTrue(containsPNGDataURL(text))
        XCTAssertTrue(text.contains("Image title: Diagram"))
    }

    func testCustomOpenAIEncodesFinalUserTurnAsPartArray() throws {
        let json = try jsonObject(customProvider().serializedMessagesForTesting(makeMessage()))
        let messages = try XCTUnwrap(json as? [[String: Any]])
        let finalContent = try XCTUnwrap(messages.last?["content"] as? [[String: Any]])

        XCTAssertTrue(messages[1]["content"] is String)
        XCTAssertEqual(countObjects(type: "image_url", in: finalContent), 1)
        XCTAssertTrue(try containsPNGDataURL(jsonText(finalContent)))
        XCTAssertEqual(finalContent.first?["type"] as? String, "text")
    }

    func testNativeTransportsReplayHistoricalImageOnItsOriginatingTurn() throws {
        let message = makeContinuationMessage()

        let anthropic = try jsonObject(AnthropicProvider.makeMessages(for: message))
        let anthropicMessages = try XCTUnwrap(anthropic as? [[String: Any]])
        XCTAssertEqual(countObjects(type: "image", in: anthropic), 1)
        XCTAssertTrue(try jsonText(anthropicMessages[0]).contains("AQID"))
        XCTAssertFalse(try jsonText(XCTUnwrap(anthropicMessages.last)).contains("AQID"))

        let chat = try jsonObject(message.openAIChatMessages(embedSystemPrompt: false))
        let chatMessages = try XCTUnwrap(chat as? [[String: Any]])
        XCTAssertEqual(countObjects(type: "image_url", in: chat), 1)
        XCTAssertTrue(try containsPNGDataURL(jsonText(chatMessages[1])))
        XCTAssertTrue(chatMessages.last?["content"] is String)

        let responses = try jsonObject(message.openAIResponsesInput())
        let responseItems = try XCTUnwrap(responses as? [[String: Any]])
        XCTAssertEqual(countObjects(type: "input_image", in: responses), 1)
        XCTAssertTrue(try containsPNGDataURL(jsonText(responseItems[0])))
        XCTAssertFalse(try containsPNGDataURL(jsonText(XCTUnwrap(responseItems.last))))

        let custom = try jsonObject(customProvider().serializedMessagesForTesting(message))
        let customMessages = try XCTUnwrap(custom as? [[String: Any]])
        XCTAssertEqual(countObjects(type: "image_url", in: custom), 1)
        XCTAssertTrue(customMessages[1]["content"] is [[String: Any]])
        XCTAssertTrue(customMessages.last?["content"] is String)
    }

    func testPromptPackagingPreservesFinalTurnImagesThroughRewrap() {
        let packaged = PromptPackagingService.buildAIMessage(
            systemPrompt: "system",
            metaInstructions: [],
            fileTree: "",
            fileContents: [],
            conversation: [
                ConversationEntry(role: .user, content: "first", images: [makeImage(title: "History")]),
                ConversationEntry(role: .assistant, content: "answer"),
                ConversationEntry(role: .user, content: "final", images: [makeImage()])
            ],
            temperature: nil,
            promptSectionsOrder: [],
            disabledPromptSections: []
        )

        XCTAssertEqual(packaged.conversationMessages.count, 3)
        XCTAssertEqual(packaged.conversationMessages[0].images, [makeImage(title: "History")])
        XCTAssertEqual(packaged.conversationMessages[1].images, [])
        XCTAssertEqual(packaged.conversationMessages[2].images, [makeImage()])
        XCTAssertTrue(packaged.conversationMessages[2].content.contains("<user_instructions>"))
        XCTAssertEqual(packaged.conversationMessages[0].content, "first")
    }

    func testTextOnlyRequestsKeepScalarContent() throws {
        let message = AIMessage(systemPrompt: "system", userMessage: "plain")

        let chat = try XCTUnwrap(try jsonObject(message.openAIChatMessages(embedSystemPrompt: false)) as? [[String: Any]])
        XCTAssertTrue(chat.allSatisfy { $0["content"] is String })

        let custom = try XCTUnwrap(
            try jsonObject(customProvider().serializedMessagesForTesting(message)) as? [[String: Any]]
        )
        XCTAssertTrue(custom.allSatisfy { $0["content"] is String })

        let anthropic = try jsonObject(AnthropicProvider.makeMessages(for: message))
        XCTAssertEqual(countObjects(type: "image", in: anthropic), 0)

        let responses = try XCTUnwrap(try jsonObject(message.openAIResponsesInput()) as? [[String: Any]])
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses.first?["role"] as? String, "user")
    }

    func testACPCLIProjectionPreservesTransientImagesWithoutChangingText() {
        let engine = ompEngine()
        let withImages = engine.test_agentMessage(from: makeMessage())
        let withoutImages = engine.test_agentMessage(from: AIMessage(
            systemPrompt: "system",
            conversationMessages: [
                ConversationEntry(role: .user, content: "first"),
                ConversationEntry(role: .assistant, content: "answer"),
                ConversationEntry(role: .user, content: "final")
            ],
            temperature: nil,
            promptSectionsOrder: [],
            disabledPromptSections: []
        ))

        XCTAssertEqual(withImages.promptContentParts.last, .image(makeImage()))
        XCTAssertEqual(withImages.systemPrompt, withoutImages.systemPrompt)
        XCTAssertTrue(withImages.userMessage.hasSuffix("User: final"))
        XCTAssertEqual(withImages.userMessage, withoutImages.userMessage)
        XCTAssertTrue(withoutImages.promptContentParts.isEmpty)
    }

    func testACPCLIProjectionKeepsHistoricalImageOnItsOwnTurn() {
        let message = ompEngine().test_agentMessage(from: makeContinuationMessage())

        XCTAssertEqual(message.userMessage, "User: first\n\nAssistant: answer\n\nUser: final")
        XCTAssertEqual(message.promptContentParts, [
            .text("User: first"),
            .image(makeImage()),
            .text("Assistant: answer\n\nUser: final")
        ])
        XCTAssertEqual(
            message.promptContentParts.compactMap(\.text).joined(separator: "\n\n"),
            message.userMessage
        )
    }

    func testACPImageBearingPromptRendersIdenticalTextToTextOnlyComposition() {
        let padded = AIMessage(
            systemPrompt: "system",
            conversationMessages: [
                ConversationEntry(role: .user, content: "first  ", images: [makeImage()]),
                ConversationEntry(role: .assistant, content: "answer"),
                ConversationEntry(role: .user, content: "final  ")
            ],
            temperature: nil,
            promptSectionsOrder: [],
            disabledPromptSections: []
        )
        let message = ompEngine().test_agentMessage(from: padded)
        var textOnly = message
        textOnly.promptContentParts = []
        let request = runRequest(for: .omp)

        let ordered = ACPPromptComposition.promptContentParts(for: message, request: request)
        XCTAssertEqual(
            ordered.compactMap(\.text).joined(separator: "\n\n"),
            ACPPromptComposition.promptText(for: textOnly, request: request)
        )
        XCTAssertEqual(ordered.first?.text, "system\n\nUser: first  ")
    }

    func testOMPAndDevinEmitSchemaValidTransientImageBlocks() throws {
        let source = AIMessage(
            systemPrompt: "system",
            conversationMessages: [
                ConversationEntry(role: .user, content: "first"),
                ConversationEntry(role: .assistant, content: "answer"),
                ConversationEntry(role: .user, content: "final", images: [makeImage(title: " Diagram ")])
            ],
            temperature: nil,
            promptSectionsOrder: [],
            disabledPromptSections: []
        )
        for (provider, agentKind, message) in acpProviderCases(for: source) {
            let request = runRequest(for: agentKind)
            let blocks = try provider.buildPromptBlocks(for: message, request: request)

            XCTAssertEqual(blocks.count, 3)
            XCTAssertEqual(blocks[0]["type"] as? String, "text")
            XCTAssertEqual(blocks[1]["text"] as? String, "Image title: Diagram")
            XCTAssertEqual(blocks[2]["type"] as? String, "image")
            XCTAssertEqual(blocks[2]["mimeType"] as? String, "image/png")
            XCTAssertEqual(blocks[2]["data"] as? String, "AQID")
            XCTAssertNil(blocks[2]["uri"])

            var textOnlyMessage = message
            textOnlyMessage.promptContentParts = []
            let textOnlyBlocks = try provider.buildPromptBlocks(for: textOnlyMessage, request: request)
            XCTAssertEqual(textOnlyBlocks.count, 1)
            XCTAssertEqual(blocks[0]["text"] as? String, textOnlyBlocks[0]["text"] as? String)
            XCTAssertTrue((blocks[0]["text"] as? String)?.hasSuffix("User: final") == true)
        }
    }

    func testOMPAndDevinReplayHistoricalImageOnceInChronologicalOrder() throws {
        for (provider, agentKind, message) in acpProviderCases(for: makeContinuationMessage()) {
            let blocks = try provider.buildPromptBlocks(for: message, request: runRequest(for: agentKind))

            XCTAssertEqual(blocks.count, 4)
            XCTAssertEqual(blocks[0]["text"] as? String, "system\n\nUser: first")
            XCTAssertEqual(blocks[1]["text"] as? String, "Image title: Diagram")
            XCTAssertEqual(blocks[2]["type"] as? String, "image")
            XCTAssertEqual(blocks[2]["data"] as? String, "AQID")
            XCTAssertNil(blocks[2]["uri"])
            XCTAssertEqual(blocks[3]["text"] as? String, "Assistant: answer\n\nUser: final")
            XCTAssertEqual(countObjects(type: "image", in: blocks), 1)
        }
    }

    func testOMPAndDevinTextOnlyContinuationEmitsSingleFlattenedBlock() throws {
        let textOnly = AIMessage(
            systemPrompt: "system",
            conversationMessages: [
                ConversationEntry(role: .user, content: "first"),
                ConversationEntry(role: .assistant, content: "answer"),
                ConversationEntry(role: .user, content: "final")
            ],
            temperature: nil,
            promptSectionsOrder: [],
            disabledPromptSections: []
        )
        for (provider, agentKind, message) in acpProviderCases(for: textOnly) {
            XCTAssertTrue(message.promptContentParts.isEmpty)
            let blocks = try provider.buildPromptBlocks(for: message, request: runRequest(for: agentKind))

            XCTAssertEqual(blocks.count, 1)
            XCTAssertEqual(
                blocks[0]["text"] as? String,
                "system\n\nUser: first\n\nAssistant: answer\n\nUser: final"
            )
        }
    }

    func testACPRejectsRemoteImageAttachmentsInsteadOfEmittingInvalidBlocks() {
        let attachment = AgentImageAttachment(source: .url("https://example.test/image.png"))

        XCTAssertThrowsError(try ACPPromptContentBuilder.blocks(
            text: "inspect",
            attachments: [attachment]
        )) { error in
            XCTAssertEqual(
                error as? ACPPromptContentBuilder.Error,
                .unsupportedRemoteImage("https://example.test/image.png")
            )
        }
    }

    // MARK: - Helpers

    private func makeImage(title: String? = "Diagram") -> AITransientImage {
        AITransientImage(bytes: Data([1, 2, 3]), mediaType: .png, title: title)
    }

    private func makeMessage() -> AIMessage {
        makeMessage(imagesOnFirstUserTurn: false)
    }

    private func makeContinuationMessage() -> AIMessage {
        makeMessage(imagesOnFirstUserTurn: true)
    }

    private func makeMessage(imagesOnFirstUserTurn: Bool) -> AIMessage {
        let images = [makeImage()]
        return AIMessage(
            systemPrompt: "system",
            conversationMessages: [
                ConversationEntry(role: .user, content: "first", images: imagesOnFirstUserTurn ? images : []),
                ConversationEntry(role: .assistant, content: "answer"),
                ConversationEntry(role: .user, content: "final", images: imagesOnFirstUserTurn ? [] : images)
            ],
            temperature: nil,
            promptSectionsOrder: [],
            disabledPromptSections: []
        )
    }

    private func ompEngine() -> ACPCLIChatProviderEngine<OMPACPHeadlessAgentProvider> {
        ACPCLIChatProviderEngine<OMPACPHeadlessAgentProvider>(
            providerName: "Oh My Pi",
            providerType: .omp,
            makeProvider: { _ in OMPACPHeadlessAgentProvider(config: OMPAgentConfig()) }
        )
    }

    private func devinEngine() -> ACPCLIChatProviderEngine<DevinACPHeadlessAgentProvider> {
        ACPCLIChatProviderEngine<DevinACPHeadlessAgentProvider>(
            providerName: "Devin",
            providerType: .devin,
            makeProvider: { _ in DevinACPHeadlessAgentProvider(config: DevinAgentConfig()) }
        )
    }

    private func acpProviderCases(
        for source: AIMessage
    ) -> [(any ACPAgentProvider, AgentProviderKind, AgentMessage)] {
        [
            (OMPACPAgentProvider(config: OMPAgentConfig()), .omp, ompEngine().test_agentMessage(from: source)),
            (DevinACPAgentProvider(config: DevinAgentConfig()), .devin, devinEngine().test_agentMessage(from: source))
        ]
    }

    private func runRequest(for agentKind: AgentProviderKind) -> ACPRunRequest {
        ACPRunRequest(
            agentKind: agentKind,
            modelString: nil,
            workspacePath: nil,
            resumeSessionID: nil,
            attachments: [],
            taskLabelKind: nil
        )
    }

    private func customProvider() -> CustomOpenAIProvider {
        CustomOpenAIProvider(
            baseURL: "https://example.test/v1",
            apiKey: "key",
            defaultModel: "vision-model"
        )
    }

    private func containsPNGDataURL(_ text: String) -> Bool {
        text.contains("data:image/png;base64,AQID") || text.contains("data:image\\/png;base64,AQID")
    }

    private func jsonObject(_ value: some Encodable) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private func jsonText(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func countObjects(type: String, in value: Any) -> Int {
        if let object = value as? [String: Any] {
            return (object["type"] as? String == type ? 1 : 0)
                + object.values.reduce(0) { $0 + countObjects(type: type, in: $1) }
        }
        if let array = value as? [Any] {
            return array.reduce(0) { $0 + countObjects(type: type, in: $1) }
        }
        return 0
    }
}
