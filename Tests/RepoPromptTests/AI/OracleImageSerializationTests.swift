import Foundation
@testable import RepoPromptApp
import SwiftAnthropic
import XCTest

/// Each image-capable Oracle transport must emit its own native image block, attach it
/// only to the final user turn, and leave text-only requests byte-identical to before.
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

    func testImagesWithoutAUserTurnSynthesizeOneCarryingTheContextTail() throws {
        let message = AIMessage(
            systemPrompt: "system",
            fileTree: "root",
            conversationMessages: [ConversationEntry(role: .assistant, content: "answer")],
            transientImages: [AITransientImage(bytes: Data([1, 2, 3]), mediaType: .png, title: "Diagram")],
            temperature: nil,
            promptSectionsOrder: [.fileMap],
            disabledPromptSections: []
        )

        let chat = try XCTUnwrap(try jsonObject(message.openAIChatMessages(embedSystemPrompt: false)) as? [[String: Any]])
        XCTAssertEqual(chat.last?["role"] as? String, "user")
        XCTAssertEqual(countObjects(type: "image_url", in: chat), 1)

        let responses = try jsonObject(message.openAIResponsesInput())
        XCTAssertEqual(countObjects(type: "input_image", in: responses), 1)

        let custom = try XCTUnwrap(
            try jsonObject(customProvider().serializedMessagesForTesting(message)) as? [[String: Any]]
        )
        let parts = try XCTUnwrap(custom.last?["content"] as? [[String: Any]])
        XCTAssertEqual(custom.last?["role"] as? String, "user")
        XCTAssertEqual(parts.first?["type"] as? String, "text")
        XCTAssertTrue((parts.first?["text"] as? String)?.contains("root") == true)
        XCTAssertEqual(parts.last?["type"] as? String, "image_url")
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

    // MARK: - Helpers

    private func makeMessage() -> AIMessage {
        AIMessage(
            systemPrompt: "system",
            conversationMessages: [
                ConversationEntry(role: .user, content: "first"),
                ConversationEntry(role: .assistant, content: "answer"),
                ConversationEntry(role: .user, content: "final")
            ],
            transientImages: [
                AITransientImage(bytes: Data([1, 2, 3]), mediaType: .png, title: "Diagram")
            ],
            temperature: nil,
            promptSectionsOrder: [],
            disabledPromptSections: []
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
