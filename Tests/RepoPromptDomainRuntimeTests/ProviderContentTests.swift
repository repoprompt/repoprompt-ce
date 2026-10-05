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

    func testLocalImageReadsExactWhitespaceFilenameInsteadOfViableTrimmedDecoy() throws {
        let directory = try makeLocalImageFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (index, suffix) in [" ", "\n", "\t"].enumerated() {
            let exactURL = directory.appendingPathComponent("diagram\(suffix).png\(suffix)")
            let trimmedURL = URL(fileURLWithPath: exactURL.path.trimmingCharacters(in: .whitespacesAndNewlines))
            let expected = Data([0x10, 0x20, UInt8(index)])
            let decoy = Data([0xDE, 0xC0])
            try expected.write(to: exactURL)
            try decoy.write(to: trimmedURL)
            let block = try localImageBlock(path: exactURL.path, title: "diagram.png")
            XCTAssertEqual(block["data"] as? String, expected.base64EncodedString())
            XCTAssertNotEqual(block["data"] as? String, decoy.base64EncodedString())
            XCTAssertEqual(block["type"] as? String, "image")
            XCTAssertEqual(block["mimeType"] as? String, "image/png")
            let uri = try XCTUnwrap(block["uri"] as? String)
            XCTAssertEqual(uri, exactURL.absoluteString)
            XCTAssertEqual(try Array(XCTUnwrap(URL(string: uri)?.path).utf8), Array(exactURL.path.utf8))
        }
    }

    func testLocalImagePreservesUnicodePercentAndURLPunctuationAsNativeFilename() throws {
        let directory = try makeLocalImageFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exactURL = directory.appendingPathComponent("雪%20#?.png")
        let decodedDecoy = directory.appendingPathComponent("雪 #?.png")
        let expected = Data([1, 3, 5, 7])
        try expected.write(to: exactURL)
        try Data([2, 4, 6]).write(to: decodedDecoy)
        let block = try localImageBlock(path: exactURL.path)
        XCTAssertEqual(block["data"] as? String, expected.base64EncodedString())
        let uri = try XCTUnwrap(block["uri"] as? String)
        XCTAssertEqual(uri, exactURL.absoluteString)
        XCTAssertTrue(uri.contains("%2520%23%3F.png"))
        XCTAssertEqual(try Array(XCTUnwrap(URL(string: uri)?.path).utf8), Array(exactURL.path.utf8))
    }

    func testDecodedRelativeLocalImagePreservesLegacyCWDResolutionAndWhitespace() throws {
        let directory = try makeLocalImageFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("legacy.png ")
        let decoy = directory.appendingPathComponent("legacy.png")
        let expected = Data([11, 12, 13])
        try expected.write(to: target)
        try Data([99]).write(to: decoy)
        // Walk to / from the existing CWD without mutating process-wide CWD.
        let cwdDepth = FileManager.default.currentDirectoryPath.split(separator: "/").count
        let relative = String(repeating: "../", count: cwdDepth) + String(target.path.dropFirst())
        let attachment = AgentImageAttachment(source: .localFile(path: relative), title: "legacy.png")
        let decoded = try JSONDecoder().decode(AgentImageAttachment.self, from: JSONEncoder().encode(attachment))
        XCTAssertEqual(decoded.source, .localFile(path: relative))
        let block = try XCTUnwrap(ACPPromptContentBuilder.blocks(text: "", attachments: [decoded]).first)
        XCTAssertEqual(block["data"] as? String, expected.base64EncodedString())
        XCTAssertEqual(block["uri"] as? String, URL(fileURLWithPath: relative).absoluteString)
        XCTAssertEqual(block["mimeType"] as? String, "image/png")
    }

    func testLocalImageLeavesSymlinkAndDotTraversalToFilesystem() throws {
        let directory = try makeLocalImageFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let left = directory.appendingPathComponent("left", isDirectory: true)
        let right = directory.appendingPathComponent("right", isDirectory: true)
        let inside = right.appendingPathComponent("inside", isDirectory: true)
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: left.appendingPathComponent("link"), withDestinationURL: inside)
        let expected = Data([41, 42])
        try expected.write(to: right.appendingPathComponent("target.png"))
        try Data([81, 82]).write(to: left.appendingPathComponent("target.png"))
        let rawPath = left.path + "/link/../target.png"
        let block = try localImageBlock(path: rawPath)
        XCTAssertEqual(block["data"] as? String, expected.base64EncodedString())
        XCTAssertEqual(block["uri"] as? String, URL(fileURLWithPath: rawPath).absoluteString)
    }

    func testLocalImageRefusesInvalidOrMissingExactPathWithoutReadingDecoy() throws {
        let directory = try makeLocalImageFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let decoy = directory.appendingPathComponent("missing.png")
        try Data([91, 92]).write(to: decoy)
        for path in ["", decoy.path + " ", decoy.path + "\0ignored"] {
            XCTAssertThrowsError(try localImageBlock(path: path)) { error in
                XCTAssertEqual(error as? ACPPromptContentBuilder.Error, .unreadableLocalImage(path))
            }
        }
    }

    private func makeLocalImageFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("provider-content-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func localImageBlock(path: String, title: String? = nil) throws -> [String: Any] {
        let attachment = AgentImageAttachment(source: .localFile(path: path), title: title)
        let blocks = try ACPPromptContentBuilder.blocks(text: "", attachments: [attachment])
        return try XCTUnwrap(blocks.first)
    }

    private func encodedMessages(_ message: AIMessage) throws -> [[String: Any]] {
        let data = try JSONEncoder().encode(CustomOpenAIMessageBuilder.messages(for: message))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }
}
