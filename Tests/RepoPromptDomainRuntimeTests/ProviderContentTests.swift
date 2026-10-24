import Foundation
import RepoPromptDomainRuntime
import XCTest

final class ProviderContentTests: XCTestCase {
    func testTextOnlyContentAndPromptOrderingRemainStable() throws {
        let message = AIMessage(systemPrompt: "System", userMessage: "Question")
        let messages = try encodedMessages(message)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["content"] as? String, "System")
        XCTAssertEqual(messages[1]["content"] as? String, "Question")
        XCTAssertEqual(try ACPPromptContentBuilder.blocks(text: "Question", attachments: []).first?["text"] as? String, "Question")
        XCTAssertEqual(PromptAssemblyBuilder.build(
            order: [.metaPrompts, .userInstructions, .fileMap],
            disabled: [.fileMap],
            duplicateUserInstructionsAtTop: true,
            snippets: [.metaPrompts: "Meta", .userInstructions: "Question", .fileMap: "Tree"]
        ), "Question\nMeta\nQuestion\n")
        XCTAssertEqual(
            try JSONDecoder().decode([PromptSection].self, from: JSONEncoder().encode(PromptAssemblyBuilder.defaultSectionOrder)),
            [.fileMap, .fileContents, .gitDiff, .metaPrompts, .userInstructions]
        )
    }

    func testImagesAttachOnlyToFinalUserAndSupportImageOnlyTurns() throws {
        let image = AITransientImage(bytes: Data([1, 2, 3]), mediaType: .png, title: " Diagram ")
        let message = AIMessage(
            systemPrompt: "System",
            conversationMessages: [
                ConversationEntry(role: .user, content: "Earlier"),
                ConversationEntry(role: .assistant, content: "Answer"),
                ConversationEntry(role: .user, content: "Inspect")
            ],
            transientImages: [image],
            temperature: nil,
            promptSectionsOrder: PromptAssemblyBuilder.defaultSectionOrder,
            disabledPromptSections: []
        )
        let messages = try encodedMessages(message)
        XCTAssertEqual(messages[1]["content"] as? String, "Earlier")
        XCTAssertEqual(messages[2]["content"] as? String, "Answer")
        let parts = try XCTUnwrap(messages[3]["content"] as? [[String: Any]])
        XCTAssertEqual(parts.compactMap { $0["type"] as? String }, ["text", "text", "image_url"])
        XCTAssertEqual(parts[1]["text"] as? String, "Image title: Diagram")
        let imageURL = try XCTUnwrap(parts[2]["image_url"] as? [String: String])
        XCTAssertEqual(imageURL, ["url": "data:image/png;base64,AQID", "detail": "auto"])

        let imageOnly = AIMessage(
            systemPrompt: "", transientImages: [image], temperature: nil,
            promptSectionsOrder: [], disabledPromptSections: []
        )
        let imageOnlyMessages = try encodedMessages(imageOnly)
        XCTAssertEqual(imageOnlyMessages.count, 1)
        XCTAssertEqual(imageOnlyMessages.first?["role"] as? String, "user")
        let acp = try ACPPromptContentBuilder.blocks(text: "", attachments: [], transientImages: [image])
        XCTAssertEqual(acp.count, 2)
        XCTAssertEqual(acp[1]["type"] as? String, "image")
        XCTAssertEqual(acp[1]["mimeType"] as? String, "image/png")
        XCTAssertEqual(acp[1]["data"] as? String, "AQID")
    }

    func testResultValuesPreserveCleanupIdentityAndExplicitTerminalState() throws {
        let handle = ProviderConversationCleanupHandle(provider: "codex", conversationID: " conversation ", sessionID: "  ", rolloutPath: " rollout ")
        XCTAssertEqual(handle.conversationID, "conversation")
        XCTAssertNil(handle.sessionID)
        XCTAssertEqual(handle.rolloutPath, "rollout")
        XCTAssertEqual(try JSONDecoder().decode(ProviderConversationCleanupHandle.self, from: JSONEncoder().encode(handle)), handle)
        XCTAssertEqual(ProviderConversationCleanupHandle.resolved(
            provider: "codex", explicit: handle, providerSessionID: "ignored",
            codexConversationID: nil, codexRolloutPath: nil
        ), handle)
        let tokens = ChatTokenInfo(promptTokens: 5, completionTokens: 7, cost: 0.01)
        XCTAssertEqual(try JSONDecoder().decode(ChatTokenInfo.self, from: JSONEncoder().encode(tokens)), tokens)
        XCTAssertFalse(ChatStreamOutput(text: "", reasoning: nil, tokens: tokens).isFinal)
        XCTAssertTrue(ChatStreamOutput(text: "", reasoning: nil, tokens: tokens, terminalOutcome: .completed).isFinal)
        let incomplete = ChatStreamOutput(text: "partial", reasoning: nil, tokens: tokens, terminalOutcome: .incomplete(reason: "limit"), cleanupHandle: handle)
        XCTAssertFalse(incomplete.isFinal)
        XCTAssertEqual(incomplete.cleanupHandle, handle)
        XCTAssertEqual(AIStreamResult(type: "content", text: "partial", cleanupHandle: handle).cleanupHandle, handle)
        XCTAssertEqual(AICompletionResult(text: "complete").completionOutcome, .completed)
    }

    private func encodedMessages(_ message: AIMessage) throws -> [[String: Any]] {
        let data = try JSONEncoder().encode(CustomOpenAIMessageBuilder.messages(for: message))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }
}
