import Foundation
@testable import RepoPromptApp
import SwiftAnthropic
import XCTest

final class OracleImageSerializationTests: XCTestCase {
    func testAnthropicAttachesOnlyToFinalUserTurn() throws {
        let json = try jsonObject(AnthropicProvider.makeMessages(for: makeMessage()))
        let text = try jsonText(json)

        XCTAssertEqual(countObjects(type: "image", in: json), 1)
        XCTAssertTrue(text.contains("Image title: Diagram"))
        XCTAssertTrue(text.contains("AQID"))
        XCTAssertFalse(text.contains("/Users/secret.png"))
        let messages = try XCTUnwrap(json as? [[String: Any]])
        XCTAssertFalse(try jsonText(messages[0]).contains("AQID"))
        XCTAssertTrue(try jsonText(XCTUnwrap(messages.last)).contains("AQID"))
    }

    func testRouteAdmissionAllowsEveryOracleProviderTransport() {
        let models: [AIModel] = [
            .claude4Sonnet,
            .anthropicCustom(name: "custom"),
            .gpt5,
            .openAIServiceTierVariant(base: .gpt5, tier: "flex"),
            .openaiCustom(name: "custom"),
            .ollama,
            .azureCustom(name: "azure"),
            .openrouterCustom(name: "openrouter"),
            .geminiFlash25,
            .deepseekChat,
            .customProviderUser(name: "custom"),
            .fireworksDeepseekV3p1Terminus,
            .grokCodeFast1,
            .groqKimi,
            .zaiGLM45,
            .claudeCodeSonnet,
            .codexCustom(name: "codex"),
            .openCodeCustom(name: "opencode"),
            .cursorCustom(name: "cursor")
        ]
        for model in models {
            XCTAssertTrue(OracleImageRouteAdmission.supports(model), "Expected \(model) to admit images")
        }
        XCTAssertFalse(OracleImageRouteAdmission.supports(.grokBuildCustom(name: "grok")))
    }

    func testOpenAITextOnlyMessagesRemainScalar() throws {
        let message = AIMessage(systemPrompt: "system", userMessage: "plain")
        let chat = try XCTUnwrap(try jsonObject(
            message.openAIChatMessages(embedSystemPrompt: false)
        ) as? [[String: Any]])
        XCTAssertTrue(chat.allSatisfy { $0["content"] is String })

        let provider = CustomOpenAIProvider(
            baseURL: "https://example.test/v1",
            apiKey: "key",
            defaultModel: "text-model"
        )
        let custom = try XCTUnwrap(try jsonObject(
            provider.serializedMessagesForTesting(message)
        ) as? [[String: Any]])
        XCTAssertTrue(custom.allSatisfy { $0["content"] is String })

        let assistantOnly = AIMessage(
            systemPrompt: "",
            fileTree: "root",
            conversationMessages: [.init(role: .assistant, content: "answer")],
            temperature: nil,
            promptSectionsOrder: [.fileMap],
            disabledPromptSections: []
        )
        let responses = try XCTUnwrap(try jsonObject(
            assistantOnly.openAIResponsesInput()
        ) as? [[String: Any]])
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses.first?["role"] as? String, "assistant")
    }

    func testOpenAIChatAttachesOnlyToFinalUserTurn() throws {
        let json = try jsonObject(makeMessage().openAIChatMessages(embedSystemPrompt: false))
        let text = try jsonText(json)
        let messages = try XCTUnwrap(json as? [[String: Any]])

        XCTAssertEqual(countObjects(type: "image_url", in: json), 1)
        XCTAssertTrue(
            text.contains("data:image/png;base64,AQID") ||
                text.contains("data:image\\/png;base64,AQID")
        )
        XCTAssertTrue(text.contains("Image title: Diagram"))
        XCTAssertFalse(try jsonText(messages[1]).contains("AQID"))
        XCTAssertTrue(try jsonText(XCTUnwrap(messages.last)).contains("AQID"))
    }

    func testOpenAIResponsesAttachesOnlyToFinalUserTurn() throws {
        let json = try jsonObject(makeMessage().openAIResponsesInput())
        let text = try jsonText(json)

        XCTAssertEqual(countObjects(type: "input_image", in: json), 1)
        XCTAssertTrue(
            text.contains("data:image/png;base64,AQID") ||
                text.contains("data:image\\/png;base64,AQID")
        )
        XCTAssertTrue(text.contains("Image title: Diagram"))
    }

    func testCustomOpenAIEncodesFinalUserAsContentArray() throws {
        let provider = CustomOpenAIProvider(
            baseURL: "https://example.test/v1",
            apiKey: "key",
            defaultModel: "vision-model"
        )
        let json = try jsonObject(provider.serializedMessagesForTesting(makeMessage()))
        let messages = try XCTUnwrap(json as? [[String: Any]])
        let earlierContent = messages[1]["content"]
        let finalMessage = try XCTUnwrap(messages.last)
        let finalContent = try XCTUnwrap(finalMessage["content"] as? [[String: Any]])

        XCTAssertTrue(earlierContent is String)
        XCTAssertEqual(countObjects(type: "image_url", in: finalContent), 1)
        let finalText = try jsonText(finalContent)
        XCTAssertTrue(
            finalText.contains("data:image/png;base64,AQID") ||
                finalText.contains("data:image\\/png;base64,AQID")
        )
    }

    func testCustomOpenAISynthesizedImageTurnKeepsAdditionsBeforeImages() throws {
        let provider = CustomOpenAIProvider(
            baseURL: "https://example.test/v1",
            apiKey: "key",
            defaultModel: "vision-model"
        )
        let message = AIMessage(
            systemPrompt: "system",
            fileTree: "root",
            conversationMessages: [.init(role: .assistant, content: "answer")],
            transientImages: [
                .init(bytes: Data([1, 2, 3]), mediaType: .png, title: "Diagram")
            ],
            temperature: nil,
            promptSectionsOrder: [.fileMap],
            disabledPromptSections: []
        )
        let json = try jsonObject(provider.serializedMessagesForTesting(message))
        let messages = try XCTUnwrap(json as? [[String: Any]])
        let synthesized = try XCTUnwrap(messages.last)
        let parts = try XCTUnwrap(synthesized["content"] as? [[String: Any]])

        XCTAssertEqual(synthesized["role"] as? String, "user")
        XCTAssertEqual(parts.first?["type"] as? String, "text")
        XCTAssertTrue((parts.first?["text"] as? String)?.contains("root") == true)
        XCTAssertEqual(parts.last?["type"] as? String, "image_url")
    }

    func testACPEncodesTransientImagesInlineWithoutURI() throws {
        let image = AITransientImage(bytes: Data([1, 2, 3]), mediaType: .png, title: "Diagram")
        let blocks = try ACPPromptContentBuilder.blocks(
            text: "Inspect",
            attachments: [],
            transientImages: [image]
        )
        let imageBlock = try XCTUnwrap(blocks.last)

        XCTAssertEqual(imageBlock["type"] as? String, "image")
        XCTAssertEqual(imageBlock["mimeType"] as? String, "image/png")
        XCTAssertEqual(imageBlock["data"] as? String, "AQID")
        XCTAssertNil(imageBlock["uri"])
    }

    func testACPCLIAdaptersPreserveTransientImages() {
        let message = makeMessage()
        let openCode = OpenCodeCLIProvider.test_makeAgentMessage(from: message)
        let cursor = CursorCLIProvider.test_makeAgentMessage(from: message)

        XCTAssertEqual(openCode.transientImages, message.transientImages)
        XCTAssertEqual(cursor.transientImages, message.transientImages)
    }

    func testCodexStagesTransientImagesWithOwnerOnlyPermissionsAndCleansUp() async throws {
        let bytes = Data([0xFF, 0xD8, 0xFF])
        var stagedFileURL: URL?
        var stagedDirectoryURL: URL?

        try await CodexCLIProvider.test_withStagedTransientImages([
            .init(bytes: bytes, mediaType: .jpeg, title: "  Reference  ")
        ]) { attachments in
            let attachment = try XCTUnwrap(attachments.first)
            XCTAssertEqual(attachments.count, 1)
            XCTAssertEqual(attachment.title, "Reference")
            guard case let .localFile(path) = attachment.source else {
                return XCTFail("Expected Codex staging to produce a local-file attachment")
            }

            let fileURL = URL(fileURLWithPath: path)
            let directoryURL = fileURL.deletingLastPathComponent()
            stagedFileURL = fileURL
            stagedDirectoryURL = directoryURL

            XCTAssertTrue(directoryURL.lastPathComponent.hasPrefix("RepoPromptOracleImages-"))
            XCTAssertEqual(fileURL.pathExtension, "jpg")
            XCTAssertEqual(try Data(contentsOf: fileURL), bytes)

            let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directoryURL.path)
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
            XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }

        let fileURL = try XCTUnwrap(stagedFileURL)
        let directoryURL = try XCTUnwrap(stagedDirectoryURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directoryURL.path))
    }

    func testClaudeStreamJSONEncodesTransientImages() throws {
        let line = try ClaudeCodeProvider.makeStreamJSONInput(
            prompt: "Inspect",
            images: [.init(bytes: Data([1, 2, 3]), mediaType: .png, title: "Diagram")]
        )
        XCTAssertTrue(line.hasSuffix("\n"))
        let data = try XCTUnwrap(line.dropLast().data(using: .utf8))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let message = try XCTUnwrap(payload["message"] as? [String: Any])
        let content = try XCTUnwrap(message["content"] as? [[String: Any]])
        let image = try XCTUnwrap(content.last)
        let source = try XCTUnwrap(image["source"] as? [String: Any])

        XCTAssertEqual(payload["type"] as? String, "user")
        XCTAssertEqual(image["type"] as? String, "image")
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, "AQID")

        var options = ClaudeCLIOptions()
        XCTAssertFalse(options.toTokens().contains("--input-format"))
        options.inputFormat = "stream-json"
        XCTAssertTrue(options.toTokens().contains("--input-format"))
        XCTAssertTrue(options.toTokens().contains("stream-json"))
    }

    private func makeMessage() -> AIMessage {
        AIMessage(
            systemPrompt: "system",
            conversationMessages: [
                .init(role: .user, content: "first"),
                .init(role: .assistant, content: "answer"),
                .init(role: .user, content: "final")
            ],
            transientImages: [
                .init(bytes: Data([1, 2, 3]), mediaType: .png, title: "Diagram")
            ],
            temperature: nil,
            promptSectionsOrder: [],
            disabledPromptSections: []
        )
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
